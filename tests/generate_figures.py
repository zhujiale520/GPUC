#!/usr/bin/env python3
"""Generate figures for the experiment report."""
import os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

OUTDIR = os.path.join(os.path.dirname(__file__), '..', 'docs', 'figures')
os.makedirs(OUTDIR, exist_ok=True)


def plot_ablation():
    """Bar chart for ablation study."""
    configs = [
        'Baseline\n(full opt)',
        'No io_uring',
        'No read-ahead',
        'No pipeline',
        'No pinned',
        'No batch',
        'All off',
    ]
    bw = [147.9, 135.1, 122.1, 147.9, 150.6, 123.1, 123.6]
    colors = ['#2ca02c', '#ff7f0e', '#ff7f0e', '#1f77b4', '#1f77b4', '#d62728', '#d62728']

    fig, ax = plt.subplots(figsize=(9, 5))
    bars = ax.bar(configs, bw, color=colors, edgecolor='black')
    ax.set_ylabel('Sequential Read BW (MB/s)', fontsize=11)
    ax.set_title('Ablation Study: Impact of Each Optimization (128k bs, 512MB zero)', fontsize=12)
    ax.set_ylim(0, 170)
    ax.axhline(147.3, color='green', linestyle='--', linewidth=1, label='Baseline')

    for bar, val in zip(bars, bw):
        height = bar.get_height()
        ax.annotate(f'{val:.1f}',
                    xy=(bar.get_x() + bar.get_width() / 2, height),
                    xytext=(0, 3),
                    textcoords="offset points",
                    ha='center', va='bottom', fontsize=9)

    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'ablation_study.png'), dpi=150)
    print('Saved', os.path.join(OUTDIR, 'ablation_study.png'))


def plot_batch_size():
    """Line chart for batch size sweep."""
    batch = [1, 2, 4, 8, 16, 32]
    bw = [121.4, 133.2, 156.6, 147.6, 147.3, 147.5]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(batch, bw, marker='o', linewidth=2, markersize=8, color='#1f77b4')
    ax.set_xlabel('Batch Size (blocks)', fontsize=11)
    ax.set_ylabel('Sequential Read BW (MB/s)', fontsize=11)
    ax.set_title('Batch Size Sensitivity (128k bs, 512MB zero)', fontsize=12)
    ax.set_xticks(batch)
    ax.set_ylim(0, 180)
    ax.grid(True, linestyle='--', alpha=0.5)

    # Annotate sweet spot
    ax.annotate('Sweet spot\nbatch=4 saturates',
                xy=(4, 156.6), xytext=(8, 170),
                arrowprops=dict(arrowstyle='->', color='red'),
                fontsize=10, color='red')

    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'batch_size_sweep.png'), dpi=150)
    print('Saved', os.path.join(OUTDIR, 'batch_size_sweep.png'))


def plot_mem_pressure():
    """Line chart for GPU memory pressure scan."""
    mem = [0, 1, 2, 4, 8, 14, 20, 28]
    bw = [148.7, 151.2, 157.6, 154.2, 156.1, 148.0, 150.1, 158.7]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(mem, bw, marker='s', linewidth=2, markersize=7, color='#9467bd')
    ax.set_xlabel('GPU Memory Occupied (GB)', fontsize=11)
    ax.set_ylabel('Sequential Read BW (MB/s)', fontsize=11)
    ax.set_title('GPU Memory Pressure Scan (no sustained compute load)', fontsize=12)
    ax.set_xticks(mem)
    ax.set_ylim(140, 165)
    ax.grid(True, linestyle='--', alpha=0.5)

    fig.tight_layout()
    fig.savefig(os.path.join(OUTDIR, 'mem_pressure_scan.png'), dpi=150)
    print('Saved', os.path.join(OUTDIR, 'mem_pressure_scan.png'))


if __name__ == '__main__':
    plot_ablation()
    plot_batch_size()
    plot_mem_pressure()
