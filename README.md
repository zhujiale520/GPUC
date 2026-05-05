# proj35 - 基于GPU的服务资源卸载技术探索

## 题目信息
- **选题编号**: proj35
- **题目内容**: 基于GPU的服务资源卸载技术探索（Exploration of GPU-based Service Resource Off-loading Technology）
- **高校名称**: 西安交通大学
- **队伍ID**: T2026106989910286
- **队伍名**: 404notfound

## 赛题背景
高性能服务器处理很多业务的CPU消耗很高，例如全闪存的存储服务器，随着NVME盘的性能迅速提升，仅仅处理IO本身就已经对CPU消耗巨大。希望通过GPU offload部分计算密集型的任务，减小主CPU的资源消耗。

## 赛题任务
- 通过 dm 在 block 层作压缩
- 通过 btrfs、zfs 在文件系统层作压缩
- GPU offload 实现的 CPU、DRAM 开销优化
- 跨架构性能比较（x86、aarch64等）

## 技术平台
- GPU: RTX3060/4060/5060
- CPU: 华为鲲鹏 920
- 编程框架: CUDA SDK

## 文档链接
- [设计文档](待补充)
- [演示视频](百度网盘链接待补充)

## 参考资料
- [NVIDIA nvCOMP](https://github.com/NVIDIA/CUDALibrarySamples/tree/master/nvCOMP)
- [ZFS Hardware Acceleration with QAT](https://openzfs.org/wiki/ZFS_Hardware_Acceleration_with_QAT)
- [XRP: In-Kernel Storage Functions with eBPF](https://github.com/xrp-project/XRP)

---
参赛项目：2026年全国大学生计算机系统能力大赛-操作系统设计赛(全国)-OS功能挑战赛道
