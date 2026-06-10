#!/usr/bin/env python3
"""GPU compute hog — keeps GPU busy with matrix multiplication."""
import torch
import sys
import time

# Default: run indefinitely
size = 8192
if len(sys.argv) > 1:
    size = int(sys.argv[1])

x = torch.randn(size, size, device='cuda')
y = torch.randn(size, size, device='cuda')
print(f"[gpu_hog] Starting {size}x{size} matmul loop on GPU...")
while True:
    z = torch.matmul(x, y)
    torch.cuda.synchronize()
