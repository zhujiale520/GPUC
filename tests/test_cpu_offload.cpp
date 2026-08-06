#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <pthread.h>
#include <sched.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include <thread>
#include <vector>

#include "gpu_compress_api.h"

static constexpr size_t BLOCK = 128u * 1024u;
static constexpr int DEFAULT_BATCH_BLOCKS = 128;
static constexpr size_t CAP = BLOCK + BLOCK / 255u + 32u;

static void fill_workset(uint8_t *data, size_t bytes,
                         unsigned compressible_pct) {
    const size_t pages = bytes / 4096;
    for (size_t page = 0; page < pages; page++) {
        uint8_t *dst = data + page * 4096;
        if (page % 100 < compressible_pct) {
            std::memset(dst, 1 + (page * 37) % 251, 4096);
            continue;
        }
        uint64_t state = 0x9e3779b97f4a7c15ULL ^
                         (static_cast<uint64_t>(page) *
                          0xd1b54a32d192ed03ULL);
        for (size_t offset = 0; offset < 4096; offset += sizeof(state)) {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            uint64_t value = state * 0x2545f4914f6cdd1dULL;
            std::memcpy(dst + offset, &value, sizeof(value));
        }
    }
}

struct PerfCounter {
    const char *name;
    uint64_t config;
    int fd = -1;
    uint64_t value = 0;
};

struct Context {
    std::atomic<bool> start{false};
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> business_ops{0};
    std::atomic<uint64_t> decoded_bytes{0};
    const char *scenario = nullptr;
    int cpu = 0;
    double target_mib_s = 0.0;
    size_t batch_blocks = DEFAULT_BATCH_BLOCKS;
    size_t workset_blocks = DEFAULT_BATCH_BLOCKS;
    size_t next_block = 0;
    const std::vector<uint8_t *> *comp_bank = nullptr;
    const std::vector<size_t> *comp_lens_bank = nullptr;
    uint8_t *decoded = nullptr;
    std::vector<const uint8_t *> in;
    std::vector<size_t> in_lens;
    std::vector<uint8_t *> out;
    std::vector<size_t> out_lens;
    uint64_t decomp_calls = 0;
    double submit_user_sec = 0.0;
    double submit_sys_sec = 0.0;
    gpu_lz4_profile_t profile_sum{};
};

static long perf_event_open(perf_event_attr *attr) {
    return syscall(SYS_perf_event_open, attr, 0, -1, -1, 0);
}

static bool open_perf_counters(std::vector<PerfCounter> *counters) {
    if (!std::getenv("GPUC_PERF_COUNTERS_FILE")) return false;
    *counters = {
        {"cycles", PERF_COUNT_HW_CPU_CYCLES},
        {"instructions", PERF_COUNT_HW_INSTRUCTIONS},
        {"cache_references", PERF_COUNT_HW_CACHE_REFERENCES},
        {"cache_misses", PERF_COUNT_HW_CACHE_MISSES},
    };
    for (auto &counter : *counters) {
        perf_event_attr attr{};
        attr.type = PERF_TYPE_HARDWARE;
        attr.size = sizeof(attr);
        attr.config = counter.config;
        attr.disabled = 1;
        attr.inherit = 1;
        attr.exclude_kernel = 1;
        attr.exclude_hv = 1;
        counter.fd = (int)perf_event_open(&attr);
        if (counter.fd < 0) {
            std::fprintf(stderr, "perf_event_open(%s): %s\n",
                         counter.name, std::strerror(errno));
            for (auto &item : *counters)
                if (item.fd >= 0) close(item.fd);
            counters->clear();
            return false;
        }
    }
    return true;
}

static void control_perf_counters(std::vector<PerfCounter> *counters,
                                  unsigned long request) {
    for (auto &counter : *counters)
        if (counter.fd >= 0) (void)ioctl(counter.fd, request, 0);
}

static void write_perf_counters(std::vector<PerfCounter> *counters,
                                const char *scenario, double elapsed) {
    const char *path = std::getenv("GPUC_PERF_COUNTERS_FILE");
    if (!path || counters->empty()) return;
    for (auto &counter : *counters) {
        if (read(counter.fd, &counter.value, sizeof(counter.value)) !=
            (ssize_t)sizeof(counter.value))
            counter.value = 0;
        close(counter.fd);
        counter.fd = -1;
    }
    FILE *f = std::fopen(path, "w");
    if (!f) return;
    std::fprintf(f, "scenario,elapsed_s");
    for (const auto &counter : *counters) std::fprintf(f, ",%s", counter.name);
    std::fprintf(f, "\n%s,%.9f", scenario, elapsed);
    for (const auto &counter : *counters)
        std::fprintf(f, ",%llu", (unsigned long long)counter.value);
    std::fprintf(f, "\n");
    std::fclose(f);
}

static void write_phase_timestamp(const char *label) {
    const char *path = std::getenv("GPUC_PHASE_FILE");
    if (!path) return;
    timespec now{};
    clock_gettime(CLOCK_REALTIME, &now);
    FILE *f = std::fopen(path, "a");
    if (!f) return;
    std::fprintf(f, "%s,%lld.%09ld\n", label, (long long)now.tv_sec, now.tv_nsec);
    std::fclose(f);
}

static bool touch_ready_and_wait() {
    const char *ready = std::getenv("GPUC_READY_FILE");
    const char *start = std::getenv("GPUC_START_FILE");
    if (!ready && !start) return true;
    if (!ready || !start) {
        std::fprintf(stderr, "GPUC_READY_FILE and GPUC_START_FILE must be set together\n");
        return false;
    }
    int fd = open(ready, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) return false;
    close(fd);
    while (access(start, F_OK) != 0) {
        if (errno != ENOENT) return false;
        timespec delay{0, 10000000};
        nanosleep(&delay, nullptr);
    }
    return true;
}

static void pin_this_thread(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    (void)pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

static double timeval_sec(const timeval &tv);

static void business_worker(Context *ctx, int cpu) {
    pin_this_thread(cpu);
    while (!ctx->start.load(std::memory_order_acquire)) std::this_thread::yield();
    uint64_t x = 0x9e3779b97f4a7c15ULL ^ (uint64_t)cpu;
    uint64_t local = 0;
    while (!ctx->stop.load(std::memory_order_relaxed)) {
        for (int i = 0; i < 4096; i++) {
            x ^= x >> 12;
            x ^= x << 25;
            x ^= x >> 27;
            x *= 0x2545F4914F6CDD1DULL;
        }
        local += 4096;
    }
    if (x == 0) std::fprintf(stderr, "impossible\n");
    ctx->business_ops.fetch_add(local, std::memory_order_relaxed);
}

static void decompression_worker(Context *ctx) {
    pin_this_thread(ctx->cpu);
    while (!ctx->start.load(std::memory_order_acquire)) std::this_thread::yield();
    rusage before{}, after{};
    getrusage(RUSAGE_THREAD, &before);
    uint64_t bytes = 0;
    uint64_t calls = 0;
    gpu_lz4_profile_t sum{};
    auto throttle_begin = std::chrono::steady_clock::now();
    while (!ctx->stop.load(std::memory_order_relaxed)) {
        size_t first = ctx->next_block;
        for (size_t i = 0; i < ctx->batch_blocks; i++) {
            size_t block = (first + i) % ctx->workset_blocks;
            ctx->in[i] = (*ctx->comp_bank)[block];
            ctx->in_lens[i] = (*ctx->comp_lens_bank)[block];
            ctx->out[i] = ctx->decoded + block * BLOCK;
        }
        ctx->next_block = (first + ctx->batch_blocks) % ctx->workset_blocks;
        int rc;
        if (std::strcmp(ctx->scenario, "cpu") == 0) {
            rc = cpu_lz4_decompress_batch((int)ctx->batch_blocks,
                                          ctx->in.data(), ctx->in_lens.data(),
                                          ctx->out.data(), ctx->out_lens.data());
        } else {
            rc = gpu_lz4_decompress_batch((int)ctx->batch_blocks,
                                          ctx->in.data(), ctx->in_lens.data(),
                                          ctx->out.data(), ctx->out_lens.data());
        }
        if (rc < 0) {
            std::fprintf(stderr, "decompression failed\n");
            std::abort();
        }
        bytes += ctx->batch_blocks * BLOCK;
        calls++;
        if (std::strcmp(ctx->scenario, "gpu") == 0) {
            gpu_lz4_profile_t p{};
            if (gpu_lz4_get_last_profile(&p) == 0) {
                sum.queue_ms += p.queue_ms;
                sum.pack_ms += p.pack_ms;
                sum.h2d_ms += p.h2d_ms;
                sum.kernel_ms += p.kernel_ms;
                sum.d2h_ms += p.d2h_ms;
                sum.unpack_ms += p.unpack_ms;
                sum.total_ms += p.total_ms;
                sum.worker_user_ms += p.worker_user_ms;
                sum.worker_sys_ms += p.worker_sys_ms;
            }
        }
        if (ctx->target_mib_s > 0.0) {
            double target_seconds = (bytes / 1048576.0) / ctx->target_mib_s;
            auto wake = throttle_begin +
                std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                    std::chrono::duration<double>(target_seconds));
            std::this_thread::sleep_until(wake);
        }
    }
    getrusage(RUSAGE_THREAD, &after);
    ctx->decoded_bytes.store(bytes, std::memory_order_relaxed);
    ctx->decomp_calls = calls;
    ctx->submit_user_sec = timeval_sec(after.ru_utime) - timeval_sec(before.ru_utime);
    ctx->submit_sys_sec = timeval_sec(after.ru_stime) - timeval_sec(before.ru_stime);
    ctx->profile_sum = sum;
}

static double timeval_sec(const timeval &tv) {
    return tv.tv_sec + tv.tv_usec / 1e6;
}

int main(int argc, char **argv) {
    if (argc < 4 || argc > 6) {
        std::fprintf(stderr,
                     "usage: %s baseline|cpu|gpu DURATION_SEC BUSINESS_WORKERS "
                     "[DECOMP_CPU] [TARGET_MIB_S]\n", argv[0]);
        return 2;
    }
    const char *scenario = argv[1];
    double duration = std::atof(argv[2]);
    int workers = std::atoi(argv[3]);
    int decomp_cpu = argc >= 5 ? std::atoi(argv[4]) : 0;
    double target_mib_s = argc >= 6 ? std::atof(argv[5]) : 0.0;
    if ((std::strcmp(scenario, "baseline") != 0 &&
         std::strcmp(scenario, "cpu") != 0 &&
         std::strcmp(scenario, "gpu") != 0) ||
        duration <= 0 || workers < 0) return 2;

    size_t workset_mib = 16;
    size_t batch_blocks = DEFAULT_BATCH_BLOCKS;
    unsigned compressible_pct = 100;
    if (const char *value = std::getenv("GPUC_WORKSET_MIB"))
        workset_mib = std::strtoull(value, nullptr, 10);
    if (const char *value = std::getenv("GPUC_BATCH_BLOCKS"))
        batch_blocks = std::strtoull(value, nullptr, 10);
    if (const char *value = std::getenv("GPUC_COMPRESSIBLE_PCT"))
        compressible_pct = std::strtoul(value, nullptr, 10);
    size_t workset_bytes = workset_mib * 1024u * 1024u;
    size_t workset_blocks = workset_bytes / BLOCK;
    if (workset_mib == 0 || workset_bytes % BLOCK != 0 ||
        batch_blocks == 0 || batch_blocks > workset_blocks ||
        batch_blocks > (size_t)INT32_MAX || compressible_pct > 100) {
        std::fprintf(stderr,
                     "invalid GPUC_WORKSET_MIB/GPUC_BATCH_BLOCKS/"
                     "GPUC_COMPRESSIBLE_PCT\n");
        return 2;
    }

    uint8_t *src = nullptr;
    uint8_t *decoded = nullptr;
    /* The full workset is only a GPU DMA buffer.  Pinning it for the CPU
     * comparator neither helps CPU LZ4 nor fairly represents the GPU path's
     * host-memory cost.  GPUC_PIN_WORKSET=1 explicitly enables it for large
     * GPU worksets; the conservative <=64 MiB default remains unchanged. */
    bool request_pinned = std::strcmp(scenario, "gpu") == 0 && workset_mib <= 64;
    if (const char *value = std::getenv("GPUC_PIN_WORKSET"))
        request_pinned = std::strcmp(scenario, "gpu") == 0 &&
                         std::strcmp(value, "1") == 0;
    bool pinned = request_pinned &&
                  gpu_lz4_host_alloc((void **)&src, workset_bytes) == 0 &&
                  gpu_lz4_host_alloc((void **)&decoded, workset_bytes) == 0;
    if (!pinned) {
        if (src) gpu_lz4_host_free(src);
        if (decoded) gpu_lz4_host_free(decoded);
        src = (uint8_t *)aligned_alloc(4096, workset_bytes);
        decoded = (uint8_t *)aligned_alloc(4096, workset_bytes);
    }
    if (!src || !decoded) return 1;
    fill_workset(src, workset_bytes, compressible_pct);

    Context ctx;
    ctx.scenario = scenario;
    ctx.cpu = decomp_cpu;
    ctx.target_mib_s = target_mib_s;
    ctx.batch_blocks = batch_blocks;
    ctx.workset_blocks = workset_blocks;
    ctx.decoded = decoded;
    ctx.in.resize(batch_blocks);
    ctx.in_lens.resize(batch_blocks);
    ctx.out.resize(batch_blocks);
    ctx.out_lens.assign(batch_blocks, BLOCK);
    std::vector<uint8_t *> comp(workset_blocks);
    std::vector<size_t> comp_lens(workset_blocks);
    size_t comp_arena_size = workset_blocks * CAP;
    uint8_t *comp_arena = (uint8_t *)aligned_alloc(4096,
        (comp_arena_size + 4095u) & ~4095u);
    if (!comp_arena) return 1;
    for (size_t i = 0; i < workset_blocks; i++)
        comp[i] = comp_arena + i * CAP;
    std::vector<size_t> caps(batch_blocks, CAP), plain_lens(batch_blocks, BLOCK);
    std::vector<const uint8_t *> plain(batch_blocks);
    uint64_t compressed_bytes = 0;
    for (size_t first = 0; first < workset_blocks; first += batch_blocks) {
        size_t count = std::min(batch_blocks, workset_blocks - first);
        std::vector<uint8_t *> chunk_out(count);
        std::vector<size_t> chunk_caps(count, CAP), chunk_lens(count);
        std::vector<const uint8_t *> chunk_plain(count);
        std::vector<size_t> chunk_plain_lens(count, BLOCK);
        for (size_t i = 0; i < count; i++) {
            chunk_plain[i] = src + (first + i) * BLOCK;
            chunk_out[i] = comp[first + i];
        }
        if (cpu_lz4_compress_batch((int)count, chunk_plain.data(),
                                   chunk_plain_lens.data(), chunk_out.data(),
                                   chunk_caps.data(), chunk_lens.data()) < 0)
            return 1;
        for (size_t i = 0; i < count; i++) {
            comp_lens[first + i] = chunk_lens[i];
            compressed_bytes += chunk_lens[i];
        }
    }
    if (const char *path = std::getenv("GPUC_DATA_INFO_FILE")) {
        FILE *info = std::fopen(path, "w");
        if (!info) {
            std::fprintf(stderr, "cannot write GPUC_DATA_INFO_FILE: %s\n",
                         std::strerror(errno));
            return 1;
        }
        std::fprintf(info,
                     "workset_mib,requested_compressible_pct,logical_bytes,"
                     "stored_bytes,stored_ratio\n%zu,%u,%zu,%llu,%.9f\n",
                     workset_mib, compressible_pct, workset_bytes,
                     static_cast<unsigned long long>(compressed_bytes),
                     static_cast<double>(compressed_bytes) / workset_bytes);
        std::fclose(info);
    }
    for (size_t i = 0; i < batch_blocks; i++) {
        ctx.in[i] = comp[i];
        ctx.in_lens[i] = comp_lens[i];
        ctx.out[i] = decoded + i * BLOCK;
    }
    ctx.comp_bank = &comp;
    ctx.comp_lens_bank = &comp_lens;

    std::vector<PerfCounter> perf_counters;
    (void)open_perf_counters(&perf_counters);
    if (std::strcmp(scenario, "gpu") == 0 && gpu_lz4_init() != 0) return 1;
    if (std::strcmp(scenario, "cpu") != 0 && std::strcmp(scenario, "gpu") != 0) {
        /* no decompression warmup */
    } else {
        int rc = std::strcmp(scenario, "cpu") == 0
            ? cpu_lz4_decompress_batch((int)batch_blocks,
                                       ctx.in.data(), ctx.in_lens.data(),
                                       ctx.out.data(), ctx.out_lens.data())
            : gpu_lz4_decompress_batch((int)batch_blocks,
                                       ctx.in.data(), ctx.in_lens.data(),
                                       ctx.out.data(), ctx.out_lens.data());
        if (rc < 0 || std::memcmp(src, decoded, batch_blocks * BLOCK) != 0) return 1;
    }

    std::vector<std::thread> threads;
    for (int i = 0; i < workers; i++)
        threads.emplace_back(business_worker, &ctx, i);
    if (std::strcmp(scenario, "baseline") != 0)
        threads.emplace_back(decompression_worker, &ctx);

    if (!touch_ready_and_wait()) {
        ctx.start.store(true, std::memory_order_release);
        ctx.stop.store(true, std::memory_order_release);
        for (auto &t : threads) t.join();
        return 1;
    }
    rusage before{}, after{};
    getrusage(RUSAGE_SELF, &before);
    control_perf_counters(&perf_counters, PERF_EVENT_IOC_RESET);
    control_perf_counters(&perf_counters, PERF_EVENT_IOC_ENABLE);
    auto begin = std::chrono::steady_clock::now();
    write_phase_timestamp("start");
    ctx.start.store(true, std::memory_order_release);
    std::this_thread::sleep_for(std::chrono::duration<double>(duration));
    ctx.stop.store(true, std::memory_order_release);
    for (auto &t : threads) t.join();
    write_phase_timestamp("end");
    auto end = std::chrono::steady_clock::now();
    control_perf_counters(&perf_counters, PERF_EVENT_IOC_DISABLE);
    getrusage(RUSAGE_SELF, &after);
    double elapsed = std::chrono::duration<double>(end - begin).count();
    double user = timeval_sec(after.ru_utime) - timeval_sec(before.ru_utime);
    double sys = timeval_sec(after.ru_stime) - timeval_sec(before.ru_stime);
    double business = ctx.business_ops.load() / elapsed;
    double decomp = ctx.decoded_bytes.load() / 1048576.0 / elapsed;
    double calls = ctx.decomp_calls ? (double)ctx.decomp_calls : 1.0;
    write_perf_counters(&perf_counters, scenario, elapsed);
    std::printf(
        "%s,%.6f,%d,%.3f,%.3f,%.6f,%.6f,%.6f,%.6f,%ld,%ld,%ld,%ld,%ld,"
        "%llu,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d\n",
        scenario, elapsed, workers, business, decomp, user, sys,
        ctx.submit_user_sec, ctx.submit_sys_sec, after.ru_maxrss,
        after.ru_minflt - before.ru_minflt, after.ru_majflt - before.ru_majflt,
        after.ru_nvcsw - before.ru_nvcsw, after.ru_nivcsw - before.ru_nivcsw,
        (unsigned long long)ctx.decomp_calls,
        ctx.profile_sum.queue_ms / calls, ctx.profile_sum.pack_ms / calls,
        ctx.profile_sum.h2d_ms / calls, ctx.profile_sum.kernel_ms / calls,
        ctx.profile_sum.d2h_ms / calls, ctx.profile_sum.unpack_ms / calls,
        ctx.profile_sum.total_ms / calls,
        ctx.profile_sum.worker_user_ms / 1000.0,
        ctx.profile_sum.worker_sys_ms / 1000.0, pinned ? 1 : 0);

    if (std::strcmp(scenario, "gpu") == 0) gpu_lz4_fini();
    std::free(comp_arena);
    if (pinned) {
        gpu_lz4_host_free(src);
        gpu_lz4_host_free(decoded);
    } else {
        std::free(src);
        std::free(decoded);
    }
    return 0;
}
