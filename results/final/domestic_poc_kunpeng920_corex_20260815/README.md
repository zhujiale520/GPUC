# 鲲鹏 920 / CoreX 国产平台最小可行性验证

验证时间：2026-08-15（UTC 运行标记 `20260815T040530Z`）。

平台为 openEuler 22.03 LTS-SP1、Linux
`5.10.0-136.108.0.188.oe2203sp1.aarch64`，CPU 是 2 路 64 核 Kunpeng-920。
PCIe 设备 `1e3e:0002` 已绑定 `iluvatar 4.4.0` 驱动。

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
gpu_sglz_unit=BLOCKED
gpu_reason=CoreX GPU is not accessible (check device-node mapping)
```

CPU smoke 覆盖 POSIX 语义、损坏格式拒绝、2000 个确定性 malformed-format case 和
真实扫描 workload。端到端样本为 16 MiB、128 个逻辑块，CPU Daemon 压缩后通过
Hook 透明读取，内容模式验证和 SHA-256 均通过。

GPU 未判定为通过：当前运行环境没有 CoreX GPU 设备节点，`ixsmi` 返回
`No supported GPUs were found`；同时安装的 `nvcc` 是不能生成目标文件的版本占位
脚本。补齐设备映射与完整 CoreX 编译组件后，执行
`bash scripts/deploy_domestic_poc.sh --require-gpu` 完成最终 GPU 证据。
