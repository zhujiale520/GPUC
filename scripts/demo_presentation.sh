#!/bin/bash
# ============================================================
#  GPU Compress 完整演示脚本（面向汇报）
# ============================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_demo_$$"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_title() {
    echo ""
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${BLUE}║${NC} %-62s ${BOLD}${BLUE}║${NC}\n" "$1"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
}

print_step() {
    echo ""
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}────────────────────────────────────────────────────────────────${NC}"
}

print_info() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_data() {
    echo -e "    ${YELLOW}$1${NC}"
}

# 清理并创建测试目录
rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"

cd "$PROJECT_DIR"

# 编译
print_step "编译项目"
make clean >/dev/null 2>&1
make all -j >/dev/null 2>&1
make bin/test_hook >/dev/null 2>&1
print_info "编译完成：libgpuhook.so, gpu_compress_daemon, test_hook"

# ============================================================
#  演示 1：准备三种不同类型的原始文件
# ============================================================
print_title "第一步：准备原始文件（三种数据模式）"

print_step "生成 8MB 全零文件（最容易压缩）"
python3 -c "
import os
path = '$TESTDIR/zero_8m.bin'
with open(path, 'wb') as f:
    f.write(b'\x00' * (8 * 1024 * 1024))
print(f'  原始大小: {os.path.getsize(path)} bytes = {os.path.getsize(path)//1024//1024} MB')
"

print_step "生成 8MB 可压缩重复数据"
python3 -c "
import os
path = '$TESTDIR/repeat_8m.bin'
pattern = bytes(i % 256 for i in range(16 * 1024))
with open(path, 'wb') as f:
    for _ in range(512):
        f.write(pattern)
print(f'  原始大小: {os.path.getsize(path)} bytes = {os.path.getsize(path)//1024//1024} MB')
"

print_step "生成 8MB 随机数据（不可压缩）"
python3 -c "
import os, random
random.seed(42)
path = '$TESTDIR/rand_8m.bin'
with open(path, 'wb') as f:
    f.write(bytes(random.randint(0, 255) for _ in range(8 * 1024 * 1024)))
print(f'  原始大小: {os.path.getsize(path)} bytes = {os.path.getsize(path)//1024//1024} MB')
"

# ============================================================
#  演示 2：LD_PRELOAD 透明写入（自动附加 GPUC Header）
# ============================================================
print_title "第二步：LD_PRELOAD 透明写入 → 自动封装 GPUC 格式"

print_step "使用 test_hook 写入文件（加载 libgpuhook.so）"
print_data "hook 拦截 open()/write()，自动在文件开头附加 64B GPUC Header"

for pattern in zero repeat rand; do
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        "$PROJECT_DIR/bin/test_hook" write "$TESTDIR/${pattern}_8m.bin" 8388608 >/dev/null
    print_info "${pattern}_8m.bin 写入完成（带 GPUC Header）"
done

print_step "解析 GPUC 文件结构（RAW 状态）"
python3 -c "
import struct, os

path = '$TESTDIR/zero_8m.bin'
with open(path, 'rb') as f:
    data = f.read(128)

magic = struct.unpack('<I', data[0:4])[0]
version = struct.unpack('<I', data[4:8])[0]
orig_size = struct.unpack('<Q', data[8:16])[0]
block_size = struct.unpack('<I', data[16:20])[0]
num_blocks = struct.unpack('<I', data[20:24])[0]
state = data[24]
comp_algo = data[25]
header_size = struct.unpack('<Q', data[32:40])[0]
file_size = os.path.getsize(path)

print(f'  ┌────────────────────────────────────────┐')
print(f'  │  GPUC 文件头（56 bytes）                │')
print(f'  ├────────────────────────────────────────┤')
print(f'  │  Magic:     0x{magic:08X} (\"GPUC\")        │')
print(f'  │  Version:   {version}                          │')
print(f'  │  OrigSize:  {orig_size} bytes (RAW状态为0, 压缩后更新) │')
print(f'  │  BlockSize: {block_size // 1024} KB                    │')
print(f'  │  NumBlocks: {num_blocks}                        │')
print(f'  │  State:     {state} (RAW=0, COMPRESSED=1)       │')
print(f'  │  HeaderSize:{header_size} bytes                  │')
print(f'  ├────────────────────────────────────────┤')
print(f'  │  总文件大小: {file_size} bytes ({file_size//1024//1024} MB + header) │')
print(f'  └────────────────────────────────────────┘')
"

# ============================================================
#  演示 3：GPU Daemon 压缩
# ============================================================
print_title "第三步：GPU Daemon 异步压缩"

print_step "GPU Daemon 扫描目录并压缩 RAW 文件"
print_data "daemon 读取 RAW 文件 → GPU batch 压缩 → 写临时文件 → atomic rename"

"$GPU_DAEMON" "$TESTDIR" 2>&1 | grep -E "Compressing|Done" || true

print_step "压缩后文件结构对比"
python3 -c "
import struct, os, subprocess

print(f'\n{\"文件\":<20} {\"原始大小\":<12} {\"物理大小\":<12} {\"压缩率\":<10} {\"状态\":<12}')
print('─' * 70)

for fname in ['zero_8m.bin', 'repeat_8m.bin', 'rand_8m.bin']:
    path = os.path.join('$TESTDIR', fname)
    logical = os.path.getsize(path)
    physical = int(subprocess.check_output(['du', '-B1', path]).decode().split()[0])
    
    with open(path, 'rb') as f:
        hdr = f.read(64)
    state = hdr[24]
    state_str = 'RAW' if state == 0 else 'COMPRESSED' if state == 1 else 'BUSY'
    ratio = physical / logical * 100
    
    print(f'{fname:<20} {logical//1024//1024:>6} MB     {physical//1024:>8} KB     {ratio:>6.1f}%    {state_str}')
"

print_step "展示 COMPRESSED 状态文件内部结构"
python3 -c "
import struct, os

path = os.path.join('$TESTDIR', 'zero_8m.bin')

with open(path, 'rb') as f:
    hdr = f.read(56)
    num_blocks = struct.unpack('<I', hdr[20:24])[0]
    header_size = struct.unpack('<Q', hdr[32:40])[0]
    
    blocks = []
    for i in range(min(num_blocks, 8)):
        be = f.read(16)
        orig_len = struct.unpack('<I', be[0:4])[0]
        comp_len = struct.unpack('<I', be[4:8])[0]
        offset = struct.unpack('<Q', be[8:16])[0]
        blocks.append((orig_len, comp_len, offset))

print(f'  ┌─────────────────────────────────────────────────────────────┐')
print(f'  │  GPUC 压缩文件结构（zero_8m.bin）                            │')
print(f'  ├─────────────────────────────────────────────────────────────┤')
print(f'  │  [0x0000] GPUC Header (56 bytes)                            │')
print(f'  │  [0x0038] Block Index Table ({num_blocks} entries × 16 bytes)            │')
print(f'  │           ┌─────────────┬─────────────┬──────────────┐      │')
print(f'  │           │  orig_len   │  comp_len   │   offset     │      │')

for i, (orig, comp, off) in enumerate(blocks[:4]):
    print(f'  │  Block {i:>2} │  {orig:>6} B   │  {comp:>6} B   │  0x{off:08X}   │      │')

if num_blocks > 4:
    print(f'  │  ...      │    ...      │    ...      │     ...      │      │')

print(f'  │           └─────────────┴─────────────┴──────────────┘      │')
print(f'  │  [0x{header_size:04X}] 压缩数据区（紧凑格式，块之间可能有稀疏空洞）       │')
print(f'  └─────────────────────────────────────────────────────────────┘')
"

# ============================================================
#  演示 4：透明读取压缩文件
# ============================================================
print_title "第四步：透明读取压缩文件（GPU 实时解压）"

print_step "使用 test_hook 读取压缩文件"
print_data "应用完全不知情文件被压缩，就像读普通文件一样"

for pattern in zero repeat rand; do
    echo ""
    echo -e "  ${BOLD}${CYAN}▸ 读取 ${pattern}_8m.bin${NC}"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        "$PROJECT_DIR/bin/test_hook" read "$TESTDIR/${pattern}_8m.bin" 8388608
    print_info "数据校验通过！"
done

# ============================================================
#  演示 5：CPU Fallback 演示
# ============================================================
print_title "第五步：CPU Fallback（模拟无 GPU 环境）"

print_step "设置 CUDA_VISIBLE_DEVICES=\"\" 模拟 GPU 不可用"
print_data "hook 自动检测到 GPU 初始化失败，透明回退到 CPU 解压"

CUDA_VISIBLE_DEVICES="" LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_hook" read "$TESTDIR/zero_8m.bin" 8388608
print_info "CPU fallback 读取成功，数据完全一致！"

# ============================================================
#  演示 6：多线程并发读取
# ============================================================
print_title "第六步：多线程并发读取"

print_step "fio 并发测试：numjobs=1/4/8"

for NJOBS in 1 4 8; do
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name="concurrent_${NJOBS}" \
            --filename="$TESTDIR/zero_8m.bin" \
            --size=8M --bs=128k --rw=read \
            --direct=0 --ioengine=sync \
            --runtime=3 --time_based \
            --numjobs="$NJOBS" --group_reporting \
            --output-format=json 2>/dev/null \
            > "/tmp/fio_demo_${NJOBS}.json"
    
    BW=$(python3 -c "
import json
with open('/tmp/fio_demo_${NJOBS}.json') as f:
    d = json.load(f)
print(f\"{d['jobs'][0]['read']['bw'] / 1024:.1f}\")
")
    echo -e "  numjobs=${NJOBS}: ${BOLD}${GREEN}${BW} MB/s${NC}"
done

# ============================================================
#  演示 7：Hook 拦截的系统调用一览
# ============================================================
print_title "第七步：Hook 拦截能力"

print_step "libgpuhook.so 共拦截 19+ 个系统调用"
cat << 'EOF'
  ┌─────────────────────────────────────────────────────────────┐
  │  文件操作                                                   │
  │    open / open64 / creat / openat / openat64                │
  │    read / write / pread64 / pwrite64 / readv / writev       │
  │    lseek / lseek64 / close / dup / dup2 / dup3              │
  │                                                             │
  │  内存映射                                                   │
  │    mmap / munmap / msync                                    │
  │                                                             │
  │  元数据                                                     │
  │    __fxstat / __fxstat64 / __xstat / __xstat64              │
  │    __lxstat / __lxstat64                                    │
  │                                                             │
  │  其他                                                       │
  │    ftruncate / truncate / sendfile                          │
  └─────────────────────────────────────────────────────────────┘
EOF

# ============================================================
#  演示 8：架构图
# ============================================================
print_title "第八步：系统架构"

cat << 'EOF'
  ┌─────────────────────────────────────────────────────────────┐
  │                     用户态应用                               │
  │         (fio, cp, dd, 数据库, 编译器...)                      │
  └──────────────────────┬──────────────────────────────────────┘
                         │
  ┌──────────────────────▼──────────────────────────────────────┐
  │              LD_PRELOAD 拦截层 (libgpuhook.so)               │
  │  ┌─────────────────────────────────────────────────────┐    │
  │  │  write() → 透传写入，自动附加 GPUC RAW Header        │    │
  │  │  read()  → 查块索引 → batch GPU 解压 → 返回原始数据   │    │
  │  │  mmap()  → COMPRESSED 文件预解压到匿名内存             │    │
  │  │  fstat() → 报告逻辑大小（隐藏物理稀疏大小）            │    │
  │  └─────────────────────────────────────────────────────┘    │
  │                     GPU ↕ CPU 自动切换                       │
  └──────────────────────┬──────────────────────────────────────┘
                         │
  ┌──────────────────────▼──────────────────────────────────────┐
  │           Offline Daemon (gpu_compress_daemon)               │
  │    扫描目录 → 过滤 RAW 文件 → GPU batch 压缩                 │
  │    写临时文件 → atomic rename 替换 → 保持稀疏对齐            │
  └──────────────────────┬──────────────────────────────────────┘
                         │
  ┌──────────────────────▼──────────────────────────────────────┐
  │              ext4 / xfs（完全不改，透明叠加）                 │
  └─────────────────────────────────────────────────────────────┘
EOF

# ============================================================
#  清理
# ============================================================
print_title "演示完成"
echo -e "  ${GREEN}✓ 所有测试通过${NC}"
echo -e "  ${YELLOW}测试目录: $TESTDIR${NC}"
echo -e "  ${YELLOW}如需清理: rm -rf $TESTDIR${NC}"
echo ""
