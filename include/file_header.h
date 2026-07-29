#ifndef FILE_HEADER_H
#define FILE_HEADER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * GPU-Compress File Header (GPUC)
 * 
 * 每个被管理的文件开头附加此Header，描述文件的压缩状态和分块信息。
 * 设计目标：
 *   - 固定大小头，便于快速读取判断
 *   - 128KB分块，对齐GPU处理粒度
 *   - 支持稀疏文件（逻辑对齐，物理空洞优化）
 */

#define GPUC_MAGIC       0x47505543   /* "GPUC" in little-endian */
#define GPUC_VERSION     1
#define GPUC_BLOCK_SIZE  (128 * 1024) /* 128KB 固定块大小 */
#define GPUC_MAX_BLOCKS  (1024 * 1024) /* 支持最大 128GB 文件 */

/* 压缩算法标识 */
#define GPUC_ALGO_NONE   0   /* 未压缩 / 存储原数据 */
#define GPUC_ALGO_SGLZ   1   /* Simple-GPU-LZ (自定义GPU压缩) */
#define GPUC_ALGO_LZ4    2   /* LZ4 (预留) */
#define GPUC_ALGO_SNAPPY 3   /* Snappy (预留) */

/* 文件状态 */
#define GPUC_STATE_RAW       0   /* 原始数据，未压缩 */
#define GPUC_STATE_COMPRESSED 1  /* 已压缩 */
#define GPUC_STATE_BUSY      2   /* 正在被Daemon压缩中 */
#define GPUC_STATE_INLINE    3   /* 小文件内联存储（<=1KB，数据直接跟在header后） */

/* 小文件内联阈值：<=1KB 的文件直接内联到 header 后，无需 block entry */
#define GPUC_INLINE_THRESHOLD 1024
#define GPUC_IO_ALIGNMENT 4096u
#define GPUC_HEADER_FLAG_DIRECT_ALIGNED 0x0001u

static inline uint64_t gpuc_align_up_u64(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) / alignment * alignment;
}

/*
 * 文件头部结构（固定大小，便于 open() 时一次性读取）
 * 总大小 = 64 字节（不含块索引表）
 */
struct gpuc_header {
    uint32_t magic;          /* 魔数 GPUC_MAGIC */
    uint32_t version;        /* 版本号 */
    uint64_t orig_size;      /* 原始文件逻辑大小（字节） */
    uint32_t block_size;     /* 块大小（固定 128KB） */
    uint32_t num_blocks;     /* 总块数 */
    uint8_t  state;          /* 文件状态: RAW / COMPRESSED / BUSY */
    uint8_t  comp_algo;      /* 压缩算法标识 */
    uint16_t reserved;       /* 预留对齐 */
    uint64_t header_size;    /* 头+索引表总大小（字节） */
    uint64_t mtime;          /* 最后修改时间（用于Daemon判断） */
    uint64_t ctime;          /* 创建时间 */
};

/*
 * 块索引表条目（每个128KB块一个）
 * 总大小 = num_blocks * sizeof(struct gpuc_block_entry)
 *
 * 向后兼容说明：
 *   - 旧格式（V1）：entry 大小 = 16 字节（无 crc32）
 *   - 新格式（V2）：entry 大小 = 24 字节（含 crc32）
 *   - hook 读取时根据 header_size 自动判断 entry 大小
 */
struct gpuc_block_entry {
    uint32_t orig_len;       /* 原始长度（通常 128K，最后一块可能不足） */
    uint32_t comp_len;       /* 压缩后长度 */
    uint64_t offset;         /* 该块在文件中的物理偏移（相对文件开头） */
    uint32_t crc32;          /* 数据校验（0 = 未计算） */
    uint32_t reserved;       /* 对齐预留 */
};

/* 计算头部总大小 */
static inline size_t gpuc_header_total_size(uint32_t num_blocks) {
    return sizeof(struct gpuc_header) + num_blocks * sizeof(struct gpuc_block_entry);
}

/* 计算块数 */
static inline uint32_t gpuc_num_blocks(uint64_t file_size) {
    return (uint32_t)((file_size + GPUC_BLOCK_SIZE - 1) / GPUC_BLOCK_SIZE);
}

/* CRC32 查表（IEEE 802.3） */
static const uint32_t gpuc_crc32_table[256] = {
    0x00000000u, 0x77073096u, 0xEE0E612Cu, 0x990951BAu, 0x076DC419u, 0x706AF48Fu, 0xE963A535u, 0x9E6495A3u,
    0x0EDB8832u, 0x79DCB8A4u, 0xE0D5E91Eu, 0x97D2D988u, 0x09B64C2Bu, 0x7EB17CBDu, 0xE7B82D07u, 0x90BF1D91u,
    0x1DB71064u, 0x6AB020F2u, 0xF3B97148u, 0x84BE41DEu, 0x1ADAD47Du, 0x6DDDE4EBu, 0xF4D4B551u, 0x83D385C7u,
    0x136C9856u, 0x646BA8C0u, 0xFD62F97Au, 0x8A65C9ECu, 0x14015C4Fu, 0x63066CD9u, 0xFA0F3D63u, 0x8D080DF5u,
    0x3B6E20C8u, 0x4C69105Eu, 0xD56041E4u, 0xA2677172u, 0x3C03E4D1u, 0x4B04D447u, 0xD20D85FDu, 0xA50AB56Bu,
    0x35B5A8FAu, 0x42B2986Cu, 0xDBBBC9D6u, 0xACBCF940u, 0x32D86CE3u, 0x45DF5C75u, 0xDCD60DCFu, 0xABD13D59u,
    0x26D930ACu, 0x51DE003Au, 0xC8D75180u, 0xBFD06116u, 0x21B4F4B5u, 0x56B3C423u, 0xCFBA9599u, 0xB8BDA50Fu,
    0x2802B89Eu, 0x5F058808u, 0xC60CD9B2u, 0xB10BE924u, 0x2F6F7C87u, 0x58684C11u, 0xC1611DABu, 0xB6662D3Du,
    0x76DC4190u, 0x01DB7106u, 0x98D220BCu, 0xEFD5102Au, 0x71B18589u, 0x06B6B51Fu, 0x9FBFE4A5u, 0xE8B8D433u,
    0x7807C9A2u, 0x0F00F934u, 0x9609A88Eu, 0xE10E9818u, 0x7F6A0DBBu, 0x086D3D2Du, 0x91646C97u, 0xE6635C01u,
    0x6B6B51F4u, 0x1C6C6162u, 0x856530D8u, 0xF262004Eu, 0x6C0695EDu, 0x1B01A57Bu, 0x8208F4C1u, 0xF50FC457u,
    0x65B0D9C6u, 0x12B7E950u, 0x8BBEB8EAu, 0xFCB9887Cu, 0x62DD1DDFu, 0x15DA2D49u, 0x8CD37CF3u, 0xFBD44C65u,
    0x4DB26158u, 0x3AB551CEu, 0xA3BC0074u, 0xD4BB30E2u, 0x4ADFA541u, 0x3DD895D7u, 0xA4D1C46Du, 0xD3D6F4FBu,
    0x4369E96Au, 0x346ED9FCu, 0xAD678846u, 0xDA60B8D0u, 0x44042D73u, 0x33031DE5u, 0xAA0A4C5Fu, 0xDD0D7CC9u,
    0x5005713Cu, 0x270241AAu, 0xBE0B1010u, 0xC90C2086u, 0x5768B525u, 0x206F85B3u, 0xB966D409u, 0xCE61E49Fu,
    0x5EDEF90Eu, 0x29D9C998u, 0xB0D09822u, 0xC7D7A8B4u, 0x59B33D17u, 0x2EB40D81u, 0xB7BD5C3Bu, 0xC0BA6CADu,
    0xEDB88320u, 0x9ABFB3B6u, 0x03B6E20Cu, 0x74B1D29Au, 0xEAD54739u, 0x9DD277AFu, 0x04DB2615u, 0x73DC1683u,
    0xE3630B12u, 0x94643B84u, 0x0D6D6A3Eu, 0x7A6A5AA8u, 0xE40ECF0Bu, 0x9309FF9Du, 0x0A00AE27u, 0x7D079EB1u,
    0xF00F9344u, 0x8708A3D2u, 0x1E01F268u, 0x6906C2FEu, 0xF762575Du, 0x806567CBu, 0x196C3671u, 0x6E6B06E7u,
    0xFED41B76u, 0x89D32BE0u, 0x10DA7A5Au, 0x67DD4ACCu, 0xF9B9DF6Fu, 0x8EBEEFF9u, 0x17B7BE43u, 0x60B08ED5u,
    0xD6D6A3E8u, 0xA1D1937Eu, 0x38D8C2C4u, 0x4FDFF252u, 0xD1BB67F1u, 0xA6BC5767u, 0x3FB506DDu, 0x48B2364Bu,
    0xD80D2BDAu, 0xAF0A1B4Cu, 0x36034AF6u, 0x41047A60u, 0xDF60EFC3u, 0xA867DF55u, 0x316E8EEFu, 0x4669BE79u,
    0xCB61B38Cu, 0xBC66831Au, 0x256FD2A0u, 0x5268E236u, 0xCC0C7795u, 0xBB0B4703u, 0x220216B9u, 0x5505262Fu,
    0xC5BA3BBEu, 0xB2BD0B28u, 0x2BB45A92u, 0x5CB36A04u, 0xC2D7FFA7u, 0xB5D0CF31u, 0x2CD99E8Bu, 0x5BDEAE1Du,
    0x9B64C2B0u, 0xEC63F226u, 0x756AA39Cu, 0x026D930Au, 0x9C0906A9u, 0xEB0E363Fu, 0x72076785u, 0x05005713u,
    0x95BF4A82u, 0xE2B87A14u, 0x7BB12BAEu, 0x0CB61B38u, 0x92D28E9Bu, 0xE5D5BE0Du, 0x7CDCEFB7u, 0x0BDBDF21u,
    0x86D3D2D4u, 0xF1D4E242u, 0x68DDB3F8u, 0x1FDA836Eu, 0x81BE16CDu, 0xF6B9265Bu, 0x6FB077E1u, 0x18B74777u,
    0x88085AE6u, 0xFF0F6A70u, 0x66063BCAu, 0x11010B5Cu, 0x8F659EFFu, 0xF862AE69u, 0x616BFFD3u, 0x166CCF45u,
    0xA00AE278u, 0xD70DD2EEu, 0x4E048354u, 0x3903B3C2u, 0xA7672661u, 0xD06016F7u, 0x4969474Du, 0x3E6E77DBu,
    0xAED16A4Au, 0xD9D65ADCu, 0x40DF0B66u, 0x37D83BF0u, 0xA9BCAE53u, 0xDEBB9EC5u, 0x47B2CF7Fu, 0x30B5FFE9u,
    0xBDBDF21Cu, 0xCABAC28Au, 0x53B39330u, 0x24B4A3A6u, 0xBAD03605u, 0xCDD70693u, 0x54DE5729u, 0x23D967BFu,
    0xB3667A2Eu, 0xC4614AB8u, 0x5D681B02u, 0x2A6F2B94u, 0xB40BBE37u, 0xC30C8EA1u, 0x5A05DF1Bu, 0x2D02EF8Du,
};

static inline uint32_t gpuc_crc32(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc = gpuc_crc32_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

/* 判断一个buffer是否以GPUC头开头 */
static inline int gpuc_is_header(const void *buf) {
    const struct gpuc_header *h = (const struct gpuc_header *)buf;
    return h->magic == GPUC_MAGIC && h->version == GPUC_VERSION;
}

#ifdef __cplusplus
}
#endif

#endif /* FILE_HEADER_H */
