# 确定性故障恢复

`tests/fault_recovery.sh` 无需 root，五项全部 PASS：

1. Daemon 两块后注入 ENOSPC：原 RAW 与逻辑 SHA 保持，临时文件删除；
2. 写一块后 SIGKILL：原 inode 内容与 SHA 保持；
3. 重启遇到残留临时文件：重建并原子生成有效 COMPRESSED；
4. 隐藏 GPU：GPU Hook 初始化失败后 CPU fallback，逻辑 SHA 一致；
5. `/dev/full`：内核 ENOSPC 正确向上传播。

真实 GPU reset 和主机断电需要隔离且具有管理员权限的环境，本目录不宣称覆盖。
