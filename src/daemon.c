/*
 * daemon.c - 离线 GPU 压缩后台程序
 *
 * 用法：
 *   gpu_compress_daemon [-r] [-d] <directory>
 *
 *   -r    递归扫描子目录
 *   -d    以守护进程方式运行（周期性扫描）
 *
 * 工作流程：
 *   1. 扫描目录，发现后缀不是 .gpuc_tmp 的普通文件
 *   2. 打开文件，检查是否为 RAW 状态
 *   3. 逐块读取 → GPU 压缩 → 写入临时文件
 *   4. 用 rename 原子替换原文件
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <time.h>
#include <signal.h>
#include <libgen.h>
#include <sys/file.h>

#include "file_header.h"
#include "gpu_compress_api.h"
#include "gpu_compress.cuh"

#define TMP_SUFFIX   ".gpuc_tmp"
#define SCAN_INTERVAL_SEC  60

static volatile int g_running = 1;
static int g_use_lz4 = 0;

/* ============================================================
 *  增量扫描：记录已处理文件的路径和 mtime，避免重复检查
 * ============================================================ */
struct processed_entry {
    char *path;
    time_t mtime;
    struct processed_entry *next;
};

/* 查找已处理记录，返回 1 如果 mtime 匹配（可跳过） */
static int is_skippable(const char *path, time_t mtime,
                        struct processed_entry *list) {
    for (struct processed_entry *p = list; p; p = p->next) {
        if (strcmp(p->path, path) == 0 && p->mtime == mtime)
            return 1;
    }
    return 0;
}

/* 标记文件为已处理（更新或新增） */
static void mark_processed(const char *path, time_t mtime,
                           struct processed_entry **list) {
    struct processed_entry *p = *list;
    while (p) {
        if (strcmp(p->path, path) == 0) {
            p->mtime = mtime;
            return;
        }
        p = p->next;
    }
    p = (struct processed_entry *)malloc(sizeof(*p));
    p->path = strdup(path);
    p->mtime = mtime;
    p->next = *list;
    *list = p;
}

/* 释放已处理列表 */
static void free_processed_list(struct processed_entry *list) {
    while (list) {
        struct processed_entry *next = list->next;
        free(list->path);
        free(list);
        list = next;
    }
}

static void sigint_handler(int sig) {
    (void)sig;
    g_running = 0;
}

/* 检查文件名是否以 suffix 结尾 */
static int ends_with(const char *str, const char *suffix) {
    size_t len = strlen(str);
    size_t slen = strlen(suffix);
    if (len < slen) return 0;
    return strcmp(str + len - slen, suffix) == 0;
}

/* 判断文件是否为 RAW 状态 */
static int is_raw_file(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;

    struct gpuc_header hdr;
    ssize_t n = read(fd, &hdr, sizeof(hdr));
    close(fd);

    if (n != (ssize_t)sizeof(hdr)) return 0;
    return gpuc_is_header(&hdr) && hdr.state == GPUC_STATE_RAW;
}

/*
 * 压缩单个文件
 *
 * 步骤：
 *   1. 读取原文件 header 和数据
 *   2. 创建临时文件
 *   3. 逐块 GPU 压缩，写入临时文件（保持 128KB 逻辑对齐）
 *   4. 回填 header 和块索引表
 *   5. rename 替换
 */
static int compress_one_file(const char *path) {
    int fd_src = open(path, O_RDONLY);
    if (fd_src < 0) {
        perror("open src");
        return -1;
    }

    /* 尝试获取非阻塞独占文件锁；若文件正被其他进程使用则跳过 */
    if (flock(fd_src, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK || errno == EAGAIN) {
            printf("[daemon] File busy, skipping: %s\n", path);
        } else {
            perror("flock");
        }
        close(fd_src);
        return -1;
    }

    struct gpuc_header old_hdr;
    if (read(fd_src, &old_hdr, sizeof(old_hdr)) != (ssize_t)sizeof(old_hdr)) {
        close(fd_src);
        return -1;
    }
    if (!gpuc_is_header(&old_hdr) || old_hdr.state != GPUC_STATE_RAW) {
        close(fd_src);
        return -1;
    }

    off64_t phys_size = lseek64(fd_src, 0, SEEK_END);
    if (phys_size <= (off64_t)old_hdr.header_size) {
        close(fd_src);
        return -1;
    }

    off64_t data_size = phys_size - old_hdr.header_size;

    /* ---- 小文件内联：<=1KB 直接内联存储，无需 block entry 和 GPU 压缩 ---- */
    if (data_size <= GPUC_INLINE_THRESHOLD) {
        struct gpuc_header new_hdr;
        memset(&new_hdr, 0, sizeof(new_hdr));
        new_hdr.magic = GPUC_MAGIC;
        new_hdr.version = GPUC_VERSION;
        new_hdr.orig_size = (uint64_t)data_size;
        new_hdr.block_size = GPUC_BLOCK_SIZE;
        new_hdr.num_blocks = 0;
        new_hdr.state = GPUC_STATE_INLINE;
        new_hdr.comp_algo = GPUC_ALGO_NONE;
        new_hdr.header_size = sizeof(new_hdr) + (uint64_t)data_size;
        new_hdr.mtime = (uint64_t)time(NULL);

        char tmp_path[PATH_MAX + 16];
        snprintf(tmp_path, sizeof(tmp_path), "%s%s", path, TMP_SUFFIX);
        int fd_tmp = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd_tmp < 0) {
            perror("open tmp");
            flock(fd_src, LOCK_UN);
            close(fd_src);
            return -1;
        }

        if (write(fd_tmp, &new_hdr, sizeof(new_hdr)) != (ssize_t)sizeof(new_hdr)) {
            close(fd_tmp); unlink(tmp_path);
            flock(fd_src, LOCK_UN); close(fd_src);
            return -1;
        }

        uint8_t inline_buf[GPUC_INLINE_THRESHOLD];
        lseek64(fd_src, old_hdr.header_size, SEEK_SET);
        ssize_t nr = read(fd_src, inline_buf, (size_t)data_size);
        if (nr != (ssize_t)data_size) {
            close(fd_tmp); unlink(tmp_path);
            flock(fd_src, LOCK_UN); close(fd_src);
            return -1;
        }
        if (write(fd_tmp, inline_buf, (size_t)data_size) != (ssize_t)data_size) {
            close(fd_tmp); unlink(tmp_path);
            flock(fd_src, LOCK_UN); close(fd_src);
            return -1;
        }

        close(fd_src);
        close(fd_tmp);

        if (rename(tmp_path, path) != 0) {
            perror("rename");
            unlink(tmp_path);
            return -1;
        }
        printf("[daemon] Inline: %s (%ld bytes)\n", path, (long)data_size);
        return 0;
    }

    uint32_t num_blocks = gpuc_num_blocks((uint64_t)data_size);

    printf("[daemon] Compressing: %s (%ld bytes, %u blocks)\n",
           path, (long)data_size, num_blocks);

    /* 分配块索引表 */
    struct gpuc_block_entry *blocks =
        (struct gpuc_block_entry *)calloc(num_blocks, sizeof(*blocks));
    if (!blocks) {
        close(fd_src);
        return -1;
    }

    /* 创建临时文件 */
    char tmp_path[PATH_MAX + 16];
    snprintf(tmp_path, sizeof(tmp_path), "%s%s", path, TMP_SUFFIX);
    int fd_tmp = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd_tmp < 0) {
        perror("open tmp");
        free(blocks);
        close(fd_src);
        return -1;
    }

    /* 构建新 header */
    struct gpuc_header new_hdr;
    memset(&new_hdr, 0, sizeof(new_hdr));
    new_hdr.magic = GPUC_MAGIC;
    new_hdr.version = GPUC_VERSION;
    new_hdr.orig_size = (uint64_t)data_size;
    new_hdr.block_size = GPUC_BLOCK_SIZE;
    new_hdr.num_blocks = num_blocks;
    new_hdr.state = GPUC_STATE_COMPRESSED;
    new_hdr.comp_algo = g_use_lz4 ? GPUC_ALGO_LZ4 : GPUC_ALGO_SGLZ;
    new_hdr.header_size = sizeof(new_hdr) + num_blocks * sizeof(*blocks);
    new_hdr.mtime = (uint64_t)time(NULL);

    #define MIN_COMP_RATIO_PCT 85  /* 至少压缩 15% 才值得存压缩数据 */

    /* 先写入 header 占位（最后回填） */
    if (write(fd_tmp, &new_hdr, sizeof(new_hdr)) != (ssize_t)sizeof(new_hdr)) {
        goto fail;
    }
    if (write(fd_tmp, blocks, num_blocks * sizeof(*blocks)) !=
        (ssize_t)(num_blocks * sizeof(*blocks))) {
        goto fail;
    }

    /* 批量压缩配置 */
    const uint32_t BATCH_SIZE = 32;
    uint8_t **batch_in = (uint8_t **)calloc(BATCH_SIZE, sizeof(uint8_t *));
    uint8_t **batch_out = (uint8_t **)calloc(BATCH_SIZE, sizeof(uint8_t *));
    size_t *batch_in_lens = (size_t *)calloc(BATCH_SIZE, sizeof(size_t));
    size_t *batch_out_caps = (size_t *)calloc(BATCH_SIZE, sizeof(size_t));
    size_t *batch_out_lens = (size_t *)calloc(BATCH_SIZE, sizeof(size_t));
    for (uint32_t b = 0; b < BATCH_SIZE; b++) {
        batch_in[b] = (uint8_t *)malloc(GC_BLOCK_SIZE);
        if (g_use_lz4) {
            /* LZ4: [1B flag] + compressed payload, worst-case <= orig + small overhead */
            batch_out_caps[b] = GC_BLOCK_SIZE + 4096;
        } else {
            batch_out_caps[b] = GC_NCHUNKS * GC_SLOT_SIZE;
        }
        batch_out[b] = (uint8_t *)malloc(batch_out_caps[b]);
    }

    off64_t phys_off = (off64_t)new_hdr.header_size;
    off64_t src_data_off = (off64_t)old_hdr.header_size;

    size_t total_orig = 0;
    size_t total_comp = 0;

    uint32_t i = 0;
    while (i < num_blocks) {
        uint32_t batch_end = i + BATCH_SIZE;
        if (batch_end > num_blocks) batch_end = num_blocks;
        uint32_t batch_count = batch_end - i;

        /* 读取一批 block */
        for (uint32_t bi = 0; bi < batch_count; bi++) {
            uint32_t block_id = i + bi;
            size_t to_read = GC_BLOCK_SIZE;
            if (src_data_off + (off64_t)to_read > phys_size)
                to_read = (size_t)(phys_size - src_data_off);

            ssize_t nr = pread64(fd_src, batch_in[bi], to_read, src_data_off);
            if (nr != (ssize_t)to_read) {
                fprintf(stderr, "[daemon] pread failed at block %u\n", block_id);
                for (uint32_t b = 0; b < BATCH_SIZE; b++) {
                    free(batch_in[b]); free(batch_out[b]);
                }
                free(batch_in); free(batch_out);
                free(batch_in_lens); free(batch_out_caps); free(batch_out_lens);
                goto fail;
            }
            batch_in_lens[bi] = to_read;
            src_data_off += to_read;
        }

        /* GPU 批量压缩 */
        int sret;
        if (g_use_lz4) {
            sret = gpu_lz4_compress_batch((int)batch_count,
                                          (const uint8_t **)batch_in, batch_in_lens,
                                          batch_out, batch_out_caps, batch_out_lens);
        } else {
            sret = sglz_compress_batch((int)batch_count,
                                       (const uint8_t **)batch_in, batch_in_lens,
                                       batch_out, batch_out_caps, batch_out_lens);
        }
        (void)sret;

        /* DEBUG */
        if (!g_use_lz4 && batch_count > 0) {
            uint16_t s0 = *(uint16_t *)batch_out[0];
            uint16_t s1 = *(uint16_t *)(batch_out[0] + GC_SLOT_SIZE);
            fprintf(stderr, "[DEBUG] batch_count=%u batch_out_lens[0]=%zu slot0=%u slot1=%u\n",
                    batch_count, batch_out_lens[0], s0, s1);
        }

        /* 逐个处理输出 */
        for (uint32_t bi = 0; bi < batch_count; bi++) {
            uint32_t block_id = i + bi;
            size_t to_read = batch_in_lens[bi];
            uint8_t *out_buf = batch_out[bi];
            size_t comp_size = batch_out_lens[bi];

            blocks[block_id].orig_len = (uint32_t)to_read;
            blocks[block_id].offset = (uint64_t)phys_off;
            /* CRC32 始终对原始数据计算（压缩前） */
            blocks[block_id].crc32 = gpuc_crc32(batch_in[bi], to_read);

            if (comp_size > 0 && comp_size < to_read * MIN_COMP_RATIO_PCT / 100) {
                if (g_use_lz4) {
                    /* LZ4: 直接写入 [flag][payload] */
                    if (write(fd_tmp, out_buf, comp_size) != (ssize_t)comp_size) {
                        fprintf(stderr, "[daemon] write LZ4 block failed at block %u\n", block_id);
                        for (uint32_t b = 0; b < BATCH_SIZE; b++) {
                            free(batch_in[b]); free(batch_out[b]);
                        }
                        free(batch_in); free(batch_out);
                        free(batch_in_lens); free(batch_out_caps); free(batch_out_lens);
                        goto fail;
                    }
                    blocks[block_id].comp_len = (uint32_t)comp_size;
                } else {
                    int file_pos = 0;
                    for (int j = 0; j < GC_NCHUNKS; j++) {
                        uint16_t slot_len = *(uint16_t *)(out_buf + j * GC_SLOT_SIZE);
                        if (slot_len == 0xFFFF) slot_len = 2 + GC_CHUNK_SIZE;
                        if (slot_len < 2 || slot_len > GC_SLOT_SIZE) {
                            fprintf(stderr, "[daemon] Invalid slot_len %u at block %u chunk %d\n",
                                    slot_len, block_id, j);
                            for (uint32_t b = 0; b < BATCH_SIZE; b++) {
                                free(batch_in[b]); free(batch_out[b]);
                            }
                            free(batch_in); free(batch_out);
                            free(batch_in_lens); free(batch_out_caps); free(batch_out_lens);
                            goto fail;
                        }
                        uint8_t *chunk_data = out_buf + j * GC_SLOT_SIZE;
                        if (write(fd_tmp, chunk_data, slot_len) != slot_len) {
                            for (uint32_t b = 0; b < BATCH_SIZE; b++) {
                                free(batch_in[b]); free(batch_out[b]);
                            }
                            free(batch_in); free(batch_out);
                            free(batch_in_lens); free(batch_out_caps); free(batch_out_lens);
                            goto fail;
                        }
                        file_pos += slot_len;
                    }
                    blocks[block_id].comp_len = (uint32_t)file_pos;
                }
            } else {
                /* 未压缩或压缩失败：存储原始数据 */
                blocks[block_id].comp_len = (uint32_t)to_read;
                if (write(fd_tmp, batch_in[bi], to_read) != (ssize_t)to_read) {
                    for (uint32_t b = 0; b < BATCH_SIZE; b++) {
                        free(batch_in[b]); free(batch_out[b]);
                    }
                    free(batch_in); free(batch_out);
                    free(batch_in_lens); free(batch_out_caps); free(batch_out_lens);
                    goto fail;
                }
            }

            total_orig += to_read;
            total_comp += blocks[block_id].comp_len;

            /* 保持 128KB 逻辑对齐 */
            off64_t next_phys_off = phys_off + GPUC_BLOCK_SIZE;
            off64_t cur_end = lseek64(fd_tmp, 0, SEEK_CUR);
            if (cur_end < next_phys_off) {
                lseek64(fd_tmp, next_phys_off - 1, SEEK_SET);
                if (write(fd_tmp, "", 1) != 1) { /* ignore */ }
            }
            phys_off = next_phys_off;
        }

        i = batch_end;
    }

    for (uint32_t b = 0; b < BATCH_SIZE; b++) {
        free(batch_in[b]); free(batch_out[b]);
    }
    free(batch_in); free(batch_out);
    free(batch_in_lens); free(batch_out_caps); free(batch_out_lens);

    /* 文件级自适应 fallback：整体压缩率不足时保持 RAW */
    int min_file_ratio = 85;
    const char *ratio_env = getenv("GPUC_MIN_FILE_COMP_RATIO_PCT");
    if (ratio_env) {
        int v = atoi(ratio_env);
        if (v > 0 && v <= 100) min_file_ratio = v;
    }
    if (total_orig > 0 && total_comp >= total_orig * (size_t)min_file_ratio / 100) {
        fprintf(stderr, "[daemon] Low compression ratio %zu/%zu (threshold %d%%), keeping RAW: %s\n",
                total_comp, total_orig, min_file_ratio, path);
        close(fd_src);
        close(fd_tmp);
        free(blocks);
        unlink(tmp_path);
        /* 可选：记录到跳过列表避免反复重试（当前 daemon 的增量扫描会基于 mtime 跳过） */
        printf("[daemon] Kept RAW (low ratio): %s\n", path);
        return 0;
    }

    /* 回填块索引表 */
    lseek64(fd_tmp, sizeof(new_hdr), SEEK_SET);
    if (write(fd_tmp, blocks, num_blocks * sizeof(*blocks)) !=
        (ssize_t)(num_blocks * sizeof(*blocks))) {
        goto fail;
    }

    /* 回填 header */
    lseek64(fd_tmp, 0, SEEK_SET);
    if (write(fd_tmp, &new_hdr, sizeof(new_hdr)) != (ssize_t)sizeof(new_hdr)) {
        goto fail;
    }

    close(fd_src);
    close(fd_tmp);
    free(blocks);

    /* 原子替换 */
    if (rename(tmp_path, path) != 0) {
        perror("rename");
        unlink(tmp_path);
        return -1;
    }

    printf("[daemon] Done: %s\n", path);
    return 0;

fail:
    flock(fd_src, LOCK_UN);
    close(fd_src);
    close(fd_tmp);
    free(blocks);
    unlink(tmp_path);
    return -1;
}

/* 扫描目录（带增量过滤） */
static void scan_directory(const char *dirpath, int recursive,
                           struct processed_entry **processed_list) {
    DIR *dir = opendir(dirpath);
    if (!dir) {
        perror("opendir");
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        if (ends_with(entry->d_name, TMP_SUFFIX)) continue;

        char fullpath[PATH_MAX];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", dirpath, entry->d_name);

        struct stat st;
        if (stat(fullpath, &st) != 0) continue;

        if (S_ISDIR(st.st_mode) && recursive) {
            scan_directory(fullpath, recursive, processed_list);
        } else if (S_ISREG(st.st_mode)) {
            /* 增量扫描：若文件 mtime 未变则跳过，避免重复 open/read header */
            if (is_skippable(fullpath, st.st_mtime, *processed_list))
                continue;

            if (is_raw_file(fullpath)) {
                if (compress_one_file(fullpath) == 0) {
                    mark_processed(fullpath, st.st_mtime, processed_list);
                }
            } else {
                /* 非 RAW 文件（已压缩或其他）也标记，避免下次重复检查 */
                mark_processed(fullpath, st.st_mtime, processed_list);
            }
        }
    }

    closedir(dir);
}

static void print_usage(const char *prog) {
    printf("Usage: %s [-r] [-d] <directory>\n", prog);
    printf("  -r    Recursive scan\n");
    printf("  -d    Daemon mode (periodic scan every %d seconds)\n", SCAN_INTERVAL_SEC);
}

int main(int argc, char **argv) {
    int recursive = 0;
    int daemon_mode = 0;
    const char *directory = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-r") == 0) {
            recursive = 1;
        } else if (strcmp(argv[i], "-d") == 0) {
            daemon_mode = 1;
        } else if (argv[i][0] == '-') {
            print_usage(argv[0]);
            return 1;
        } else {
            directory = argv[i];
        }
    }

    if (!directory) {
        print_usage(argv[0]);
        return 1;
    }

    const char *algo_env = getenv("GPUC_ALGO");
    if (algo_env && strcmp(algo_env, "lz4") == 0) {
        g_use_lz4 = 1;
        fprintf(stderr, "[daemon] Using LZ4 compression backend (nvCOMP)\n");
    }

    /* 初始化 GPU */
    if (gpu_compress_init() != 0) {
        fprintf(stderr, "Failed to initialize GPU compression\n");
        return 1;
    }

    signal(SIGINT, sigint_handler);
    signal(SIGTERM, sigint_handler);

    struct processed_entry *processed_list = NULL;

    if (daemon_mode) {
        printf("[daemon] Starting in daemon mode, scanning every %d seconds\n",
               SCAN_INTERVAL_SEC);
        while (g_running) {
            scan_directory(directory, recursive, &processed_list);
            for (int i = 0; i < SCAN_INTERVAL_SEC && g_running; i++) {
                sleep(1);
            }
        }
        printf("[daemon] Shutting down\n");
    } else {
        scan_directory(directory, recursive, &processed_list);
    }

    free_processed_list(processed_list);
    gpu_compress_fini();
    return 0;
}
