# 干净路径 CPU/GPU 部署验收

命令：

```bash
GPUC_VALIDATE_GPU=1 bash tests/clean_deploy_validation.sh
```

脚本在新的临时路径中排除原 `.git`、`bin`、历史结果、PPT、Node modules 和
手工许可包，从仓库随附依赖重新生成构建产物。所有阶段均通过：

| 阶段 | 状态 | 耗时 |
|---|---|---:|
| 环境检查 | PASS | <1 s |
| CPU smoke | PASS | 3 s |
| 文档链接 | PASS | <1 s |
| GPU 全量构建 | PASS | 19 s |
| GPU unit/integration | PASS | 24 s |

总耗时约 46 秒。GPU 测试包含 SGLZ 重复/随机/全零、普通集成、混合压缩/RAW、
INLINE、共享 fd 并发 `pread` 和空只读 procfs 透传；原始 stdout/stderr 保存在
本目录。该结果验证路径独立性和随仓依赖，但不等价于全新操作系统上从网络重新
下载 CUDA/nvCOMP。
