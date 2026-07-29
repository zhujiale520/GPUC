#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <pthread.h>
#include <sched.h>
#include <sys/resource.h>
#include <thread>
#include <vector>

#include "gpu_compress_api.h"

static constexpr size_t BLOCK = 128u * 1024u;
static constexpr int BLOCKS = 128;
static constexpr size_t TOTAL = BLOCK * BLOCKS;
static constexpr size_t CAP = BLOCK + BLOCK / 255u + 32u;

struct Context {
    std::atomic<bool> start{false};
    std::atomic<bool> stop{false};
    std::atomic<uint64_t> business_ops{0};
    std::atomic<uint64_t> decoded_bytes{0};
    const char *scenario = nullptr;
    int cpu = 0;
    double target_mib_s = 0.0;
    std::vector<const uint8_t *> in;
    std::vector<size_t> in_lens;
    std::vector<uint8_t *> out;
    std::vector<size_t> out_lens;
    uint64_t decomp_calls = 0;
    double submit_user_sec = 0.0;
    double submit_sys_sec = 0.0;
    gpu_lz4_profile_t profile_sum{};
};

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
        int rc;
        if (std::strcmp(ctx->scenario, "cpu") == 0) {
            rc = cpu_lz4_decompress_batch(BLOCKS, ctx->in.data(), ctx->in_lens.data(),
                                          ctx->out.data(), ctx->out_lens.data());
        } else {
            rc = gpu_lz4_decompress_batch(BLOCKS, ctx->in.data(), ctx->in_lens.data(),
                                          ctx->out.data(), ctx->out_lens.data());
        }
        if (rc < 0) {
            std::fprintf(stderr, "decompression failed\n");
            std::abort();
        }
        bytes += TOTAL;
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

    uint8_t *src = nullptr;
    uint8_t *decoded = nullptr;
    bool pinned = gpu_lz4_host_alloc((void **)&src, TOTAL) == 0 &&
                  gpu_lz4_host_alloc((void **)&decoded, TOTAL) == 0;
    if (!pinned) {
        if (src) gpu_lz4_host_free(src);
        if (decoded) gpu_lz4_host_free(decoded);
        src = (uint8_t *)aligned_alloc(4096, TOTAL);
        decoded = (uint8_t *)aligned_alloc(4096, TOTAL);
    }
    if (!src || !decoded) return 1;
    for (size_t p = 0; p < TOTAL / 4096; p++)
        std::memset(src + p * 4096, 1 + (p * 37) % 251, 4096);

    Context ctx;
    ctx.scenario = scenario;
    ctx.cpu = decomp_cpu;
    ctx.target_mib_s = target_mib_s;
    ctx.in.resize(BLOCKS);
    ctx.in_lens.resize(BLOCKS);
    ctx.out.resize(BLOCKS);
    ctx.out_lens.assign(BLOCKS, BLOCK);
    std::vector<uint8_t *> comp(BLOCKS);
    std::vector<size_t> caps(BLOCKS, CAP), comp_lens(BLOCKS);
    std::vector<const uint8_t *> plain(BLOCKS);
    for (int i = 0; i < BLOCKS; i++) {
        if (pinned && gpu_lz4_host_alloc((void **)&comp[i], CAP) != 0)
            return 1;
        if (!pinned) comp[i] = (uint8_t *)aligned_alloc(4096, CAP);
        plain[i] = src + (size_t)i * BLOCK;
        ctx.out[i] = decoded + (size_t)i * BLOCK;
        if (!comp[i]) return 1;
    }
    std::vector<size_t> plain_lens(BLOCKS, BLOCK);
    if (cpu_lz4_compress_batch(BLOCKS, plain.data(), plain_lens.data(),
                               comp.data(), caps.data(), comp_lens.data()) < 0)
        return 1;
    for (int i = 0; i < BLOCKS; i++) {
        ctx.in[i] = comp[i];
        ctx.in_lens[i] = comp_lens[i];
    }

    if (std::strcmp(scenario, "gpu") == 0 && gpu_lz4_init() != 0) return 1;
    if (std::strcmp(scenario, "cpu") != 0 && std::strcmp(scenario, "gpu") != 0) {
        /* no decompression warmup */
    } else {
        int rc = std::strcmp(scenario, "cpu") == 0
            ? cpu_lz4_decompress_batch(BLOCKS, ctx.in.data(), ctx.in_lens.data(),
                                       ctx.out.data(), ctx.out_lens.data())
            : gpu_lz4_decompress_batch(BLOCKS, ctx.in.data(), ctx.in_lens.data(),
                                       ctx.out.data(), ctx.out_lens.data());
        if (rc < 0 || std::memcmp(src, decoded, TOTAL) != 0) return 1;
    }

    std::vector<std::thread> threads;
    for (int i = 0; i < workers; i++)
        threads.emplace_back(business_worker, &ctx, i);
    if (std::strcmp(scenario, "baseline") != 0)
        threads.emplace_back(decompression_worker, &ctx);

    rusage before{}, after{};
    getrusage(RUSAGE_SELF, &before);
    auto begin = std::chrono::steady_clock::now();
    ctx.start.store(true, std::memory_order_release);
    std::this_thread::sleep_for(std::chrono::duration<double>(duration));
    ctx.stop.store(true, std::memory_order_release);
    for (auto &t : threads) t.join();
    auto end = std::chrono::steady_clock::now();
    getrusage(RUSAGE_SELF, &after);
    double elapsed = std::chrono::duration<double>(end - begin).count();
    double user = timeval_sec(after.ru_utime) - timeval_sec(before.ru_utime);
    double sys = timeval_sec(after.ru_stime) - timeval_sec(before.ru_stime);
    double business = ctx.business_ops.load() / elapsed;
    double decomp = ctx.decoded_bytes.load() / 1048576.0 / elapsed;
    double calls = ctx.decomp_calls ? (double)ctx.decomp_calls : 1.0;
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
    for (auto p : comp) {
        if (pinned) gpu_lz4_host_free(p);
        else std::free(p);
    }
    if (pinned) {
        gpu_lz4_host_free(src);
        gpu_lz4_host_free(decoded);
    } else {
        std::free(src);
        std::free(decoded);
    }
    return 0;
}
