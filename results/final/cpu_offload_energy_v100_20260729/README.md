# CPU offload and V100 board-energy boundary

Five repeats at a target 4096 MiB/s with four competing business workers.
Energy is integrated from 200 ms `nvidia-smi` board-power samples. Both total
GPU-board J/GiB and incremental J/GiB above the no-decompression idle-board
power are reported. These values exclude CPU package, DRAM and the rest of the
system and must not be presented as whole-system energy.
