# V100 连续 D2H 合并 A/B

- 命令：`GPUC_RUNTIME=3 GPUC_REPEATS=5 GPUC_WORKSET_MIB=512 bash tests/d2h_coalesce_ab.sh`
- `legacy`：`GPUC_D2H_COALESCE=0`，每个 128 KiB block 提交一次 D2H。
- `coalesced`：默认路径，把连续 host 输出合并为一次 D2H。
- 两组均使用相同 512 MiB 轮转工作集、每批 128 blocks，不限速，交替执行五轮。

该实验用于隔离 D2H 提交策略的影响，不代表文件系统端到端吞吐。
