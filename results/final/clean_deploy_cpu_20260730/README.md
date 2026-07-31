# 干净路径部署验收

执行：

```bash
GPUC_VALIDATE_GPU=0 bash tests/clean_deploy_validation.sh
```

脚本在新的临时路径中排除原有 `.git`、`bin` 和历史结果，使用仓库随附依赖重新
生成构建产物。`make check-env`、`make smoke-test`、`make docs-check` 全部 PASS，
总耗时约 4 秒。受当前执行通道 GPU 可见性限制，本记录只验收 CPU 部署；GPU build
与 `make test` 仍需在可见 V100 的主机会话执行，不能写成已验收。
