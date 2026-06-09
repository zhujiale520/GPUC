#!/bin/bash
# ============================================================
# 系统资源监控脚本
# 用途：在运行性能测试时后台采样 CPU / GPU / 内存 使用情况
# ============================================================

INTERVAL=${1:-1}       # 采样间隔（秒）
DURATION=${2:-60}      # 总采样时长（秒）
OUTDIR=${3:-./logs}    # 输出目录

mkdir -p "$OUTDIR"

CPU_LOG="$OUTDIR/cpu_usage.log"
GPU_LOG="$OUTDIR/gpu_usage.log"
MEM_LOG="$OUTDIR/mem_usage.log"

echo "[monitor] Starting resource monitor..."
echo "[monitor] Interval: ${INTERVAL}s, Duration: ${DURATION}s"
echo "[monitor] Output: $OUTDIR"

# 清理旧日志
> "$CPU_LOG"
> "$GPU_LOG"
> "$MEM_LOG"

# 写表头
echo "timestamp,cpu_percent,usr,sys,iowait,idle" > "$CPU_LOG"
echo "timestamp,gpu_util,gpu_mem_util,gpu_mem_used_mb" > "$GPU_LOG"
echo "timestamp,mem_total_mb,mem_used_mb,mem_free_mb,mem_avail_mb" > "$MEM_LOG"

END_TIME=$(($(date +%s) + DURATION))

while [ $(date +%s) -lt $END_TIME ]; do
    TS=$(date +%s.%N)

    # CPU (使用 top 的一行采样)
    TOP_LINE=$(top -bn1 | grep "Cpu(s)" | head -1)
    if [ -n "$TOP_LINE" ]; then
        # 提取 us, sy, wa, id
        US=$(echo "$TOP_LINE" | sed 's/.*us,//' | awk '{print $1}')
        SY=$(echo "$TOP_LINE" | sed 's/.*sy,//' | awk '{print $1}')
        WA=$(echo "$TOP_LINE" | sed 's/.*wa,//' | awk '{print $1}')
        ID=$(echo "$TOP_LINE" | sed 's/.*id,//' | awk '{print $1}')
        # 计算 used = 100 - idle
        USED=$(echo "100 - ${ID%.*}" | bc)
        echo "$TS,$USED,$US,$SY,$WA,$ID" >> "$CPU_LOG"
    fi

    # GPU
    if which nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used \
                   --format=csv,noheader,nounits 2>/dev/null | while IFS=, read -r gu gm gmu; do
            echo "$TS,$(echo $gu | tr -d ' '),$(echo $gm | tr -d ' '),$(echo $gmu | tr -d ' ')" >> "$GPU_LOG"
        done
    fi

    # Memory
    MEMINFO=$(free -m | awk '/^Mem:/{print $2","$3","$4","$7}')
    echo "$TS,$MEMINFO" >> "$MEM_LOG"

    sleep "$INTERVAL"
done

echo "[monitor] Done. Logs saved to $OUTDIR"
