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
    std::vector<const uint8_t *> in;
    std::vector<size_t> in_lens;
    std::vector<uint8_t *> out;
    std::vector<size_t> out_lens;
};

static void pin_this_thread(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    (void)pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

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
    uint64_t bytes = 0;
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
    }
    ctx->decoded_bytes.store(bytes, std::memory_order_relaxed);
}

static double timeval_sec(const timeval &tv) {
    return tv.tv_sec + tv.tv_usec / 1e6;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: %s baseline|cpu|gpu DURATION_SEC BUSINESS_WORKERS\n", argv[0]);
        return 2;
    }
    const char *scenario = argv[1];
    double duration = std::atof(argv[2]);
    int workers = std::atoi(argv[3]);
    if ((std::strcmp(scenario, "baseline") != 0 &&
         std::strcmp(scenario, "cpu") != 0 &&
         std::strcmp(scenario, "gpu") != 0) ||
        duration <= 0 || workers <= 0) return 2;

    uint8_t *src = (uint8_t *)aligned_alloc(4096, TOTAL);
    uint8_t *decoded = (uint8_t *)aligned_alloc(4096, TOTAL);
    if (!src || !decoded) return 1;
    for (size_t p = 0; p < TOTAL / 4096; p++)
        std::memset(src + p * 4096, 1 + (p * 37) % 251, 4096);

    Context ctx;
    ctx.scenario = scenario;
    ctx.cpu = 0;
    ctx.in.resize(BLOCKS);
    ctx.in_lens.resize(BLOCKS);
    ctx.out.resize(BLOCKS);
    ctx.out_lens.assign(BLOCKS, BLOCK);
    std::vector<uint8_t *> comp(BLOCKS);
    std::vector<size_t> caps(BLOCKS, CAP), comp_lens(BLOCKS);
    std::vector<const uint8_t *> plain(BLOCKS);
    for (int i = 0; i < BLOCKS; i++) {
        comp[i] = (uint8_t *)aligned_alloc(4096, CAP);
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
    std::printf("%s,%.6f,%d,%.3f,%.3f,%.6f,%.6f\n",
                scenario, elapsed, workers, business, decomp, user, sys);

    if (std::strcmp(scenario, "gpu") == 0) gpu_lz4_fini();
    for (auto p : comp) std::free(p);
    std::free(src);
    std::free(decoded);
    return 0;
}
