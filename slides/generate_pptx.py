#!/usr/bin/env python3
"""
GPUC 答辩 PPT 生成脚本
基于 slides/presentation_content.md 生成 GPUC_presentation.pptx
"""

from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from pptx.oxml.ns import nsmap
from pptx.oxml import parse_xml
import os

# ============== 配置 ==============
SLIDES_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SLIDES_DIR)
OUTPUT_PPTX = os.path.join(SLIDES_DIR, "GPUC_presentation.pptx")

# 图片路径
ARCH_IMG = os.path.join(PROJECT_DIR, "docs", "architecture.png")
MULTITHREAD_IMG = os.path.join(PROJECT_DIR, "docs", "figures", "multithread_scalability.png")
MMAP_IMG = os.path.join(PROJECT_DIR, "docs", "figures", "mmap_size_sweep.png")

# 配色（深色科技风）
BG_COLOR = RGBColor(0x1A, 0x1A, 0x2E)      # 深蓝黑背景
TITLE_COLOR = RGBColor(0x00, 0xD4, 0xFF)    # 青色标题
TEXT_COLOR = RGBColor(0xF0, 0xF0, 0xF0)     # 浅灰正文
ACCENT_COLOR = RGBColor(0xFF, 0x6B, 0x35)   # 橙色强调

def set_slide_bg(slide, color):
    """设置幻灯片背景色"""
    background = slide.background
    fill = background.fill
    fill.solid()
    fill.fore_color.rgb = color

def add_title_slide(prs, title, subtitle):
    """封面页"""
    slide_layout = prs.slide_layouts[6]  # 空白布局
    slide = prs.slides.add_slide(slide_layout)
    set_slide_bg(slide, BG_COLOR)

    # 标题
    title_box = slide.shapes.add_textbox(Inches(0.5), Inches(2.5), Inches(9), Inches(1.5))
    tf = title_box.text_frame
    p = tf.paragraphs[0]
    p.text = title
    p.font.size = Pt(40)
    p.font.bold = True
    p.font.color.rgb = TITLE_COLOR
    p.alignment = PP_ALIGN.CENTER

    # 副标题
    sub_box = slide.shapes.add_textbox(Inches(0.5), Inches(4.2), Inches(9), Inches(1.5))
    tf = sub_box.text_frame
    p = tf.paragraphs[0]
    p.text = subtitle
    p.font.size = Pt(20)
    p.font.color.rgb = TEXT_COLOR
    p.alignment = PP_ALIGN.CENTER

    return slide

def add_section_slide(prs, title):
    """章节分隔页"""
    slide_layout = prs.slide_layouts[6]
    slide = prs.slides.add_slide(slide_layout)
    set_slide_bg(slide, BG_COLOR)

    # 装饰条
    shape = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, Inches(0), Inches(3), Inches(10), Inches(1.2))
    shape.fill.solid()
    shape.fill.fore_color.rgb = TITLE_COLOR
    shape.line.fill.background()

    title_box = slide.shapes.add_textbox(Inches(0.5), Inches(3.1), Inches(9), Inches(1))
    tf = title_box.text_frame
    p = tf.paragraphs[0]
    p.text = title
    p.font.size = Pt(36)
    p.font.bold = True
    p.font.color.rgb = BG_COLOR
    p.alignment = PP_ALIGN.CENTER

    return slide

def add_content_slide(prs, title, bullets, image_path=None, image_left=Inches(5), image_top=Inches(1.5), image_width=Inches(4.5)):
    """内容页"""
    slide_layout = prs.slide_layouts[6]
    slide = prs.slides.add_slide(slide_layout)
    set_slide_bg(slide, BG_COLOR)

    # 标题
    title_box = slide.shapes.add_textbox(Inches(0.5), Inches(0.3), Inches(9), Inches(0.8))
    tf = title_box.text_frame
    p = tf.paragraphs[0]
    p.text = title
    p.font.size = Pt(28)
    p.font.bold = True
    p.font.color.rgb = TITLE_COLOR

    # 内容
    content_width = Inches(4.5) if image_path else Inches(9)
    content_box = slide.shapes.add_textbox(Inches(0.5), Inches(1.2), content_width, Inches(6))
    tf = content_box.text_frame
    tf.word_wrap = True

    for i, bullet in enumerate(bullets):
        if i == 0:
            p = tf.paragraphs[0]
        else:
            p = tf.add_paragraph()
        p.text = bullet
        p.font.size = Pt(16)
        p.font.color.rgb = TEXT_COLOR
        p.space_after = Pt(10)
        p.level = 0

    # 图片
    if image_path and os.path.exists(image_path):
        slide.shapes.add_picture(image_path, image_left, image_top, width=image_width)

    return slide

def add_table_slide(prs, title, headers, rows, col_widths=None):
    """表格页"""
    slide_layout = prs.slide_layouts[6]
    slide = prs.slides.add_slide(slide_layout)
    set_slide_bg(slide, BG_COLOR)

    # 标题
    title_box = slide.shapes.add_textbox(Inches(0.5), Inches(0.3), Inches(9), Inches(0.8))
    tf = title_box.text_frame
    p = tf.paragraphs[0]
    p.text = title
    p.font.size = Pt(28)
    p.font.bold = True
    p.font.color.rgb = TITLE_COLOR

    rows_count = len(rows) + 1
    cols_count = len(headers)
    table = slide.shapes.add_table(rows_count, cols_count, Inches(0.5), Inches(1.2), Inches(9), Inches(0.6 * rows_count)).table

    # 设置表头
    for i, header in enumerate(headers):
        cell = table.cell(0, i)
        cell.text = header
        cell.text_frame.paragraphs[0].font.size = Pt(14)
        cell.text_frame.paragraphs[0].font.bold = True
        cell.text_frame.paragraphs[0].font.color.rgb = BG_COLOR
        cell.fill.solid()
        cell.fill.fore_color.rgb = TITLE_COLOR

    # 填充数据
    for r_idx, row in enumerate(rows, start=1):
        for c_idx, val in enumerate(row):
            cell = table.cell(r_idx, c_idx)
            cell.text = str(val)
            cell.text_frame.paragraphs[0].font.size = Pt(12)
            cell.text_frame.paragraphs[0].font.color.rgb = TEXT_COLOR
            cell.fill.solid()
            cell.fill.fore_color.rgb = RGBColor(0x25, 0x25, 0x3A)

    return slide

# ============== 生成 PPT ==============
prs = Presentation()
prs.slide_width = Inches(10)
prs.slide_height = Inches(7.5)

# 第 1 页：封面
add_title_slide(prs,
    "基于 GPU 的服务资源卸载技术探索",
    "透明存储压缩卸载系统 GPUC\n西安交通大学 · 404notfound\n2026 全国大学生计算机系统能力大赛 — OS 功能挑战赛道")

# 第 2 页：项目背景与问题
add_content_slide(prs, "项目背景与问题", [
    "大数据、日志、数据库、编译缓存等场景中，磁盘 I/O 是关键瓶颈",
    "存储压缩可减少磁盘占用、提升有效读带宽",
    "现有方案局限：",
    "  • 文件系统内置压缩（btrfs/zstd）：需格式化迁移，侵入性强",
    "  • 应用层压缩：需修改业务代码，无法通用",
    "  • FUSE / device-mapper / 内核模块：部署复杂或风险高",
    "核心问题：如何在不修改内核、文件系统、应用的前提下，透明地把压缩/解压卸载到 GPU？"
])

# 第 3 页：核心思路
add_content_slide(prs, "核心思路：非侵入式透明 GPU 压缩卸载", [
    "LD_PRELOAD 用户态拦截层（libgpuhook.so）",
    "写路径：应用透明写入，后台 Daemon 异步 GPU 压缩",
    "读路径：对压缩文件自动 GPU 批量解压，用户无感知",
    "mmap 路径：压缩文件透明映射到匿名内存",
    "可插拔后端：默认自研 SGLZ，可选 NVIDIA nvCOMP LZ4",
    "高可用：GPU 失败时自动 fallback 到 CPU 后端"
], ARCH_IMG)

# 第 4 页：系统架构
add_content_slide(prs, "系统架构", [
    "用户态应用（fio, cp, dd, 数据库...）",
    "LD_PRELOAD Hook 层：open/read/write/mmap/fstat 拦截",
    "Offline Daemon：扫描 RAW 文件 → GPU batch 压缩 → atomic rename",
    "底层文件系统 ext4/xfs：完全不改，透明叠加"
], ARCH_IMG)

# 第 5 页：GPUC 文件格式
add_content_slide(prs, "GPUC 文件格式", [
    "Header（56 B）：magic、version、orig_size、state、comp_algo、header_size",
    "Block Index Table：num_blocks × 24 B，记录每块 orig_len / comp_len / offset",
    "压缩数据：紧凑格式存储，稀疏文件空洞保持 128 KB 逻辑对齐",
    "状态机：RAW → Daemon 压缩 → COMPRESSED / INLINE",
    "小文件内联：≤1 KB 文件直接内联到 header 后，避免空间放大"
])

# 第 6 页：SGLZ 压缩算法
add_content_slide(prs, "自研 SGLZ 压缩算法", [
    "128 KB block = 32 × 4 KB chunks，每 chunk 独立压缩/解压",
    "LZ77 变体：3-byte hash，256 槽位，滑动窗口 2048 B",
    "最小匹配 4 B，最大匹配 255 B",
    "不可压缩 chunk 用 0xFFFF 标记 fallback",
    "不依赖闭源 nvCOMP，体现 GPU 通用算力",
    "全零数据压缩率：3.2%"
])

# 第 7 页：LZ4 后端
add_table_slide(prs, "nvCOMP LZ4 后端（Linux headers ~35.7 MB）",
    ["方案", "压缩率", "128k 顺序读带宽"],
    [["GPUC (SGLZ)", "82.5%", "279 MB/s"],
     ["GPUC (LZ4)", "38.6%", "581 MB/s"]])

# 第 8 页：核心优化
add_content_slide(prs, "核心优化体系", [
    "16 CUDA Stream + TLS：消除 32 线程同步瓶颈",
    "Device Memory Pool：消除 cudaMalloc/cudaFree 动态分配开销",
    "io_uring 批量 pread：减少 syscall 次数",
    "自适应 Read-Ahead：顺序检测，动态窗口 0→4→8→16 blocks",
    "Pinned Memory：消除 driver 中转 memcpy",
    "Compact Kernel：GPU 内直接解析紧凑格式，消除 CPU memcpy",
    "mmap 按需解压：前 16 MB 同步 + 后台异步，返回时间 2414 ms → 231 ms"
])

# 第 9 页：顺序读性能
add_table_slide(prs, "fio 顺序读 128k（512 MB，page cache 命中）",
    ["场景", "zero", "rand", "rep"],
    [["Baseline", "450.9 MB/s", "448.0 MB/s", "451.5 MB/s"],
     ["Hook RAW", "451.7 MB/s", "443.0 MB/s", "447.2 MB/s"],
     ["GPU Compressed", "458.3 MB/s", "433.0 MB/s", "442.4 MB/s"]])

# 第 10 页：高并发扩展性
add_table_slide(prs, "jobs=32 高并发（direct=1）",
    ["数据", "bs", "Baseline", "GPUC", "比例"],
    [["zero", "128k", "4900.2 MB/s", "4889.1 MB/s", "99.8%"],
     ["zero", "1M", "414.3 MB/s", "412.9 MB/s", "99.7%"],
     ["rand", "128k", "396.6 MB/s", "395.8 MB/s", "99.8%"],
     ["rand", "1M", "435.2 MB/s", "425.2 MB/s", "97.7%"]])

# 第 11 页：mmap 优化
add_table_slide(prs, "mmap 按需解压效果",
    ["文件大小", "优化前", "优化后", "提升"],
    [["64 MB", "420.9 ms", "226.3 ms", "1.9x"],
     ["256 MB", "1263.3 ms", "229.8 ms", "5.5x"],
     ["512 MB", "2414.5 ms", "231.4 ms", "10.4x"]])

# 第 12 页：真实 Workload
add_content_slide(prs, "真实 Workload 评估", [
    "SQLite：建表/插入/SELECT → PASS（数据库白名单修复后）",
    "LevelDB：fillseq/readseq/readrandom → PASS",
    "ccache：cold compile 86.4%，hot compile 79.7%",
    "ML 小文件加载：大量 1 MB 文件场景 overhead 较大（15–17%）",
    "数据库文件白名单：.db / .wal / .log / .ldb / .sst / CURRENT / MANIFEST-*"
])

# 第 13 页：生产级指标
add_content_slide(prs, "生产级指标与稳定性", [
    "尾延迟（randread 128k）：p99 = 457 µs，p999 = 578 µs",
    "IOPS：~3355，均低于 Baseline",
    "容错边界测试 5 项全 PASS：",
    "  • Daemon 压缩时应用并发读/写",
    "  • GPU 显存不足自动 fallback CPU",
    "  • 磁盘空间不足正确返回 ENOSPC",
    "  • kill -9 后文件一致性",
    "  • fsync 语义正确",
    "30 分钟稳定性：带宽稳定 159.2 MB/s，零 CRC32 错误"
])

# 第 14 页：与现有方案对比
add_table_slide(prs, "与现有方案对比",
    ["维度", "btrfs zstd", "应用层压缩", "GPUC"],
    [["侵入性", "高", "高", "无"],
     ["部署难度", "中", "高", "低"],
     ["性能上限", "高（内核态）", "取决于实现", "中（用户态+GPU）"],
     ["GPU 卸载", "否", "可选", "是"],
     ["适用场景", "新建系统", "特定应用", "现有系统透明叠加"]])

# 第 15 页：创新点
add_content_slide(prs, "创新点", [
    "非侵入式 GPU 存储压缩卸载：LD_PRELOAD 实现，无需改内核/文件系统/应用",
    "自研 SGLZ CUDA 算法：不依赖 nvCOMP，高重复数据压缩率 3.2%",
    "完整性能优化体系：16-stream、内存池、io_uring、read-ahead，jobs=32 达 Baseline 99.8%",
    "mmap 按需解压：512 MB 文件 mmap 返回时间从 2414 ms 降至 231 ms",
    "可插拔双后端：SGLZ 与 nvCOMP LZ4 共存",
    "自适应高可用：GPU 高负载/显存不足/低可压缩率自动降级",
    "完整工程化测试体系：17+ 自动化测试脚本"
])

# 第 16 页：团队分工
add_table_slide(prs, "团队分工",
    ["角色", "职责", "成员"],
    [["队长 / 系统架构", "整体架构、Hook 与 Daemon、项目整合", "朱嘉乐"],
     ["GPU 后端开发", "SGLZ CUDA kernel、nvCOMP LZ4 集成", "队员 B"],
     ["存储与 I/O 优化", "io_uring、内存池、read-ahead、mmap", "队员 C"],
     ["测试与评测", "fio 基准、消融实验、稳定性测试", "队员 D"],
     ["文档与答辩材料", "README、开发文档、PPT、视频", "队员 E"]])

# 第 17 页：开发时间线
add_content_slide(prs, "开发时间线", [
    "2026-05-05：立项与调研，项目架构方案、README 初稿",
    "2026-06-09：核心系统，LD_PRELOAD Hook + GPU Daemon + SGLZ",
    "2026-06-10：全面评测，消融实验、Batch Size 扫描、workload 测试",
    "2026-06-11：性能优化，多 CUDA Stream、mmap 按需解压 10.4x",
    "2026-06-12 ~ 06-16：生产验证，真实负载、DB 白名单、自适应降级、稳定性",
    "2026-06-17：集成 NVIDIA nvCOMP LZ4 GPU 后端",
    "2026-06-26：补齐设计方案开发文档与 PPT",
    "Git 提交：20+ 次，完整记录迭代过程"
])

# 第 18 页：合规声明
add_content_slide(prs, "合规声明", [
    "源代码许可证：Apache-2.0",
    "文档/答辩材料许可证：CC BY-SA 4.0",
    "第三方依赖说明：docs/THIRD_PARTY.md",
    "AI 工具使用声明：docs/AI_TOOL_DECLARATION.md",
    "项目为原创，未基于往届作品或开源项目"
])

# 第 19 页：复现方式
add_content_slide(prs, "一键复现", [
    "bash scripts/check_env.sh",
    "make clean && make all",
    "make test",
    "bash tests/nvcomp_lz4.sh      # LZ4 后端验证",
    "bash tests/benchmark_fio.sh   # 性能基准",
    "bash scripts/demo.sh          # 一键演示"
])

# 第 20 页：总结与展望
add_content_slide(prs, "总结与展望", [
    "通过 LD_PRELOAD 实现非侵入式 GPU 存储压缩卸载",
    "多 CUDA Stream、内存池、io_uring、read-ahead 使读性能达到 Baseline 水平",
    "nvCOMP LZ4 后端将文本类数据压缩率从 82.5% 降至 38.6%，读带宽提升至 581 MB/s",
    "具备 CPU fallback、CRC32、原子替换、并发安全等生产级基础",
    "未来方向：CUDA Graph、userfaultfd 页级 mmap、写路径实时压缩、多 block LRU cache"
])

# 保存
prs.save(OUTPUT_PPTX)
print(f"PPT 已生成：{OUTPUT_PPTX}")
print(f"总页数：{len(prs.slides)}")
