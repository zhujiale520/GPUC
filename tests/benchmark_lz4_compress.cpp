#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <string>
#include <sys/resource.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include "gpu_compress_api.h"

namespace {

constexpr size_t kBlockBytes = 128 * 1024;
constexpr size_t kOutputBytes = kBlockBytes + 4096;

void fill_workset(std::vector<uint8_t> *input, unsigned compressible_pct) {
    for (size_t page = 0; page < input->size() / 4096; ++page) {
        uint8_t *dst = input->data() + page * 4096;
        if (page % 100 < compressible_pct) {
            uint8_t value =
                static_cast<uint8_t>(((page * 131 + 17) % 251) + 1);
            std::memset(dst, value, 4096);
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

double timeval_seconds(const timeval &value) {
    return static_cast<double>(value.tv_sec) +
           static_cast<double>(value.tv_usec) / 1e6;
}

double realtime_seconds() {
    timespec now{};
    clock_gettime(CLOCK_REALTIME, &now);
    return static_cast<double>(now.tv_sec) +
           static_cast<double>(now.tv_nsec) / 1e9;
}

void write_marker(const char *path) {
    if (!path || !*path) return;
    std::ofstream marker(path);
    marker << "ready\n";
}

void wait_for_start(const char *path) {
    if (!path || !*path) return;
    while (access(path, F_OK) != 0)
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
}

void write_phase(const char *path, double start, double end) {
    if (!path || !*path) return;
    std::ofstream phase(path);
    phase << std::fixed << std::setprecision(6);
    phase << "start," << start << "\n";
    phase << "end," << end << "\n";
}

uint64_t mix_checksum(uint64_t checksum, size_t length,
                      const uint8_t *output) {
    checksum ^= static_cast<uint64_t>(length) + 0x9e3779b97f4a7c15ULL +
                (checksum << 6) + (checksum >> 2);
    if (length > 0) {
        checksum ^= static_cast<uint64_t>(output[0]) << 8;
        checksum ^= static_cast<uint64_t>(output[length - 1]) << 24;
    }
    return checksum;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc != 5) {
        std::fprintf(stderr,
                     "usage: %s cpu|gpu RUNTIME_S WORKSET_MIB BATCH_BLOCKS\n",
                     argv[0]);
        return 2;
    }
    const std::string backend = argv[1];
    const int runtime_s = std::atoi(argv[2]);
    const size_t workset_mib = std::strtoull(argv[3], nullptr, 10);
    const size_t batch_blocks = std::strtoull(argv[4], nullptr, 10);
    const char *target_env = std::getenv("GPUC_TARGET_MIB_S");
    const double target_mib_s =
        target_env && *target_env ? std::strtod(target_env, nullptr) : 0.0;
    const char *compressible_env = std::getenv("GPUC_COMPRESSIBLE_PCT");
    const unsigned compressible_pct = compressible_env && *compressible_env
        ? std::strtoul(compressible_env, nullptr, 10) : 100;
    if ((backend != "cpu" && backend != "gpu") || runtime_s < 1 ||
        workset_mib < 1 || batch_blocks < 1 || batch_blocks > 1024 ||
        compressible_pct > 100) {
        std::fprintf(stderr, "invalid benchmark arguments\n");
        return 2;
    }

    size_t workset_bytes = workset_mib * 1024 * 1024;
    workset_bytes = (workset_bytes / kBlockBytes) * kBlockBytes;
    if (workset_bytes < batch_blocks * kBlockBytes) {
        std::fprintf(stderr, "workset must contain at least one full batch\n");
        return 2;
    }
    const size_t total_blocks = workset_bytes / kBlockBytes;

    std::vector<uint8_t> input(workset_bytes);
    fill_workset(&input, compressible_pct);
    std::vector<uint8_t> output(batch_blocks * kOutputBytes);
    std::vector<uint8_t> verify(batch_blocks * kBlockBytes);
    std::vector<const uint8_t *> in_ptrs(batch_blocks);
    std::vector<uint8_t *> out_ptrs(batch_blocks);
    std::vector<uint8_t *> verify_ptrs(batch_blocks);
    std::vector<const uint8_t *> stored_ptrs(batch_blocks);
    std::vector<size_t> input_lens(batch_blocks, kBlockBytes);
    std::vector<size_t> output_caps(batch_blocks, kOutputBytes);
    std::vector<size_t> output_lens(batch_blocks);
    std::vector<size_t> verify_lens(batch_blocks, kBlockBytes);

    auto prepare_batch = [&](size_t first_block) {
        for (size_t i = 0; i < batch_blocks; ++i) {
            size_t block = (first_block + i) % total_blocks;
            in_ptrs[i] = input.data() + block * kBlockBytes;
            out_ptrs[i] = output.data() + i * kOutputBytes;
            verify_ptrs[i] = verify.data() + i * kBlockBytes;
        }
    };
    auto compress = [&]() {
        if (backend == "cpu")
            return cpu_lz4_compress_batch(
                static_cast<int>(batch_blocks), in_ptrs.data(),
                input_lens.data(), out_ptrs.data(), output_caps.data(),
                output_lens.data());
        return gpu_lz4_compress_batch(
            static_cast<int>(batch_blocks), in_ptrs.data(), input_lens.data(),
            out_ptrs.data(), output_caps.data(), output_lens.data());
    };

    if (backend == "cpu") {
        if (cpu_lz4_init() != 0) return 1;
    } else if (gpu_lz4_init() != 0) {
        return 1;
    }

    prepare_batch(0);
    if (compress() < 0) {
        std::fprintf(stderr, "warmup compression failed\n");
        return 1;
    }
    for (size_t i = 0; i < batch_blocks; ++i)
        stored_ptrs[i] = out_ptrs[i];
    if (cpu_lz4_decompress_batch(
            static_cast<int>(batch_blocks), stored_ptrs.data(),
            output_lens.data(), verify_ptrs.data(), verify_lens.data()) < 0) {
        std::fprintf(stderr, "warmup verification decompression failed\n");
        return 1;
    }
    for (size_t i = 0; i < batch_blocks; ++i) {
        if (std::memcmp(in_ptrs[i], verify_ptrs[i], kBlockBytes) != 0) {
            std::fprintf(stderr, "warmup verification mismatch block=%zu\n", i);
            return 1;
        }
    }

    const char *ready_file = std::getenv("GPUC_READY_FILE");
    const char *start_file = std::getenv("GPUC_START_FILE");
    const char *phase_file = std::getenv("GPUC_PHASE_FILE");
    write_marker(ready_file);
    wait_for_start(start_file);

    rusage before{}, after{};
    getrusage(RUSAGE_SELF, &before);
    const double phase_start = realtime_seconds();
    const auto begin = std::chrono::steady_clock::now();
    size_t first_block = 0;
    uint64_t logical_bytes = 0;
    uint64_t stored_bytes = 0;
    uint64_t batches = 0;
    uint64_t checksum = 0xcbf29ce484222325ULL;
    double elapsed = 0.0;
    do {
        prepare_batch(first_block);
        if (compress() < 0) {
            std::fprintf(stderr, "measured compression failed\n");
            return 1;
        }
        for (size_t i = 0; i < batch_blocks; ++i) {
            stored_bytes += output_lens[i];
            checksum = mix_checksum(checksum, output_lens[i], out_ptrs[i]);
        }
        logical_bytes += batch_blocks * kBlockBytes;
        batches++;
        first_block = (first_block + batch_blocks) % total_blocks;
        elapsed = std::chrono::duration<double>(
                      std::chrono::steady_clock::now() - begin)
                      .count();
        if (target_mib_s > 0) {
            double logical_mib =
                static_cast<double>(logical_bytes) / (1024.0 * 1024.0);
            double expected = logical_mib / target_mib_s;
            if (expected > elapsed)
                std::this_thread::sleep_for(
                    std::chrono::duration<double>(expected - elapsed));
            elapsed = std::chrono::duration<double>(
                          std::chrono::steady_clock::now() - begin)
                          .count();
        }
    } while (elapsed < runtime_s);
    const double phase_end = realtime_seconds();
    getrusage(RUSAGE_SELF, &after);
    write_phase(phase_file, phase_start, phase_end);

    const double user_s =
        timeval_seconds(after.ru_utime) - timeval_seconds(before.ru_utime);
    const double sys_s =
        timeval_seconds(after.ru_stime) - timeval_seconds(before.ru_stime);
    const double mib_s =
        static_cast<double>(logical_bytes) / (1024.0 * 1024.0) / elapsed;
    const double ratio =
        logical_bytes ? static_cast<double>(stored_bytes) / logical_bytes : 0;
    const double cpu_cores = (user_s + sys_s) / elapsed;
    std::printf(
        "%s,%.6f,%.6f,%llu,%llu,%.9f,%.6f,%.6f,%.6f,%ld,%ld,%ld,%ld,%ld,"
        "%llu,%llu\n",
        backend.c_str(), elapsed, mib_s,
        static_cast<unsigned long long>(logical_bytes),
        static_cast<unsigned long long>(stored_bytes), ratio, user_s, sys_s,
        cpu_cores, after.ru_maxrss, after.ru_minflt - before.ru_minflt,
        after.ru_majflt - before.ru_majflt,
        after.ru_nvcsw - before.ru_nvcsw,
        after.ru_nivcsw - before.ru_nivcsw,
        static_cast<unsigned long long>(batches),
        static_cast<unsigned long long>(checksum));

    if (backend == "cpu")
        cpu_lz4_fini();
    else
        gpu_lz4_fini();
    return 0;
}
