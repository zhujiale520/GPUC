# 鲲鹏 920 / CoreX 国产平台最小可行性验证

验证时间：2026-08-15（最终 UTC 运行标记 `20260815T044238Z`）。

平台为 openEuler 22.03 LTS-SP1、Linux
`5.10.0-136.108.0.188.oe2203sp1.aarch64`，CPU 是 2 路 64 核 Kunpeng-920。
PCIe 设备 `1e3e:0002` 已绑定 `iluvatar 4.4.0` 驱动，`ixsmi` 识别为
Iluvatar MR-V100 32 GiB。CoreX Clang 18.1.8 使用 `ivcore11` 设备架构。

执行命令：

```bash
bash scripts/deploy_domestic_poc.sh
```

结果：

```text
cpu_build=PASS
cpu_smoke=PASS
cpu_e2e_sha=PASS
source_sha256=341aacac661ccb210720bedaa9ead5d668fe5ea41a73532fc147c71e34040df1
gpu_sglz_unit=PASS
gpu_e2e_sha=PASS
gpu_model=Iluvatar MR-V100
corex_arch=ivcore11
```

CPU smoke 覆盖 POSIX 语义、损坏格式拒绝、2000 个确定性 malformed-format case 和
真实扫描 workload。端到端样本为 16 MiB、128 个逻辑块，CPU Daemon 压缩后通过
Hook 透明读取，内容模式验证和 SHA-256 均通过。

CoreX GPU 验证包含三层证据：最小 CUDA kernel 正确执行；SGLZ 单元测试中重复数据
压缩至 8.7%、全零数据压缩至 2.2%、随机数据正确回退；16 MiB、128 blocks 经
GPU Daemon 压缩后由 GPU Hook 透明读取，内容模式与 SHA-256 均一致。
此外，`make GPU_PLATFORM=corex test` 的原有单元及集成测试套件全部通过，覆盖普通、
混合可压缩、INLINE、小文件复制、共享 fd 并发 `pread` 和 procfs passthrough。

CoreX `ivcore11` 的 CUDA `atomicAdd` 兼容行为与 NVIDIA 不同，原 SGLZ 长度汇总会
返回 0。实现已改为每个线程独立写 chunk 长度、Host 端归并，去除该原子依赖。
Codex 默认 bwrap 沙箱使用隔离 `/dev`，所以 GPU 运行验证必须在宿主机 Shell 或
获批的沙箱外命令中执行。
