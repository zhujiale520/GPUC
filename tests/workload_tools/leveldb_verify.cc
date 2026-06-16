#include <leveldb/db.h>
#include <cstdio>
#include <string>
#include <chrono>

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "Usage: %s <db_path>\n", argv[0]); return 1; }
    leveldb::DB* db;
    leveldb::Options options;
    options.create_if_missing = false;
    leveldb::Status status = leveldb::DB::Open(options, argv[1], &db);
    if (!status.ok()) { fprintf(stderr, "Open failed: %s\n", status.ToString().c_str()); return 1; }

    auto t0 = std::chrono::steady_clock::now();
    int errors = 0;
    for (int i = 0; i < 1000; i++) {
        char k[32];
        snprintf(k, sizeof(k), "key-%08d", i);
        std::string v;
        status = db->Get(leveldb::ReadOptions(), k, &v);
        if (!status.ok()) { errors++; continue; }
        char expected[64];
        snprintf(expected, sizeof(expected), "value-%010d-", i);
        if (v.rfind(expected, 0) != 0) { errors++; }
    }
    auto t1 = std::chrono::steady_clock::now();
    printf("verify: errors=%d time=%.3fs\n", errors, std::chrono::duration<double>(t1-t0).count());
    delete db;
    return 0;
}
