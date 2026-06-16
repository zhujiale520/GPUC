#include <leveldb/db.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <chrono>
#include <random>

static std::string make_key(int i) {
    char buf[32];
    snprintf(buf, sizeof(buf), "key-%08d", i);
    return std::string(buf);
}

static std::string make_value(int i, int value_size) {
    std::string v(value_size, 'x');
    char prefix[64];
    snprintf(prefix, sizeof(prefix), "value-%010d-", i);
    v.replace(0, strlen(prefix), prefix);
    return v;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <db_path> <num> [value_size]\n", argv[0]);
        return 1;
    }
    std::string db_path = argv[1];
    int num = atoi(argv[2]);
    int value_size = (argc > 3) ? atoi(argv[3]) : 100;

    leveldb::DB* db;
    leveldb::Options options;
    options.create_if_missing = true;
    options.compression = leveldb::kNoCompression;
    leveldb::Status status = leveldb::DB::Open(options, db_path, &db);
    if (!status.ok()) {
        fprintf(stderr, "Open failed: %s\n", status.ToString().c_str());
        return 1;
    }

    // fillseq
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < num; i++) {
        status = db->Put(leveldb::WriteOptions(), make_key(i), make_value(i, value_size));
        if (!status.ok()) {
            fprintf(stderr, "Put failed: %s\n", status.ToString().c_str());
            return 1;
        }
    }
    auto t1 = std::chrono::steady_clock::now();
    double fill_us = std::chrono::duration<double, std::micro>(t1 - t0).count() / num;
    printf("fillseq : %.3f micros/op\n", fill_us);

    // readseq
    t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < num; i++) {
        std::string value;
        status = db->Get(leveldb::ReadOptions(), make_key(i), &value);
    }
    t1 = std::chrono::steady_clock::now();
    double readseq_us = std::chrono::duration<double, std::micro>(t1 - t0).count() / num;
    printf("readseq : %.3f micros/op\n", readseq_us);

    // readrandom
    std::mt19937 rng(42);
    std::uniform_int_distribution<int> dist(0, num - 1);
    t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < num; i++) {
        std::string value;
        status = db->Get(leveldb::ReadOptions(), make_key(dist(rng)), &value);
    }
    t1 = std::chrono::steady_clock::now();
    double readrandom_us = std::chrono::duration<double, std::micro>(t1 - t0).count() / num;
    printf("readrandom : %.3f micros/op\n", readrandom_us);

    delete db;
    return 0;
}
