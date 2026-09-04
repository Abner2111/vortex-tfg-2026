#!/usr/bin/env python3
# Copyright © 2019-2023
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# System roofline for the four NN-kernel regression benchmarks: sgemm
# (matmul), conv3 (3x3 convolution), softmax, relu. Runs each once via
# ci/blackbox.sh under a single hardware config and plots all four points
# on one FLOP/cycle roofline, so their compute- vs memory-bound placement
# is directly comparable. Reuses roofline.py's knob table, CONFIGS builder,
# and blackbox runner instead of reimplementing them.
#
# Example:
#   python3 ci/roofline_suite.py --driver=simx --threads=8 --warps=4 \
#     --output=system_roofline.png

import argparse
import os
import sys
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from roofline import (KNOBS, build_configs_env, find_blackbox, run_trial)

# key, app, default problem size, FLOPs(size), args(size)
# conv3: 3x3 kernel -> 9 mul + 9 add per output pixel, size*size output pixels.
# softmax: sub + exp + sum + div per element, treating exp as 1 FLOP.
# relu: 1 compare per element, counted as 1 nominal FLOP (memory-bound by design).
BENCHMARKS = [
    ("matmul",  "sgemm",   128,  lambda n: 2 * n ** 3, lambda n: f"-n{n}"),
    ("conv",    "conv3",   64,   lambda n: 18 * n * n, lambda n: f"-n{n}"),
    ("softmax", "softmax", 128,  lambda n: 4 * n * n,  lambda n: f"-n{n}"),
    ("relu",    "relu",    65536, lambda n: n,         lambda n: f"-n{n}"),
]

COLORS = {"matmul": "red", "conv": "darkorange", "softmax": "purple", "relu": "green"}


def parse_args():
    p = argparse.ArgumentParser(description="Vortex system roofline (matmul/conv/softmax/relu)")
    p.add_argument("--driver", default="simx", choices=["rtlsim", "simx", "opae", "xrt"])
    p.add_argument("--perf", type=int, default=7, choices=range(0, 17))
    p.add_argument("--configs", default="", metavar="str", help="Extra CONFIGS macros")
    p.add_argument("--build-dir", default=None, metavar="dir")
    p.add_argument("--timeout", type=int, default=3600, metavar="n")
    p.add_argument("--sizes", default="", metavar="str",
                   help="Override problem sizes, e.g. matmul=256,conv=128")
    p.add_argument("--freq", type=float, default=0, metavar="f",
                   help="Clock frequency in MHz (0 = cycle-domain plot)")
    p.add_argument("--bw", type=float, default=None, metavar="f",
                   help="Peak memory bandwidth in GB/s (default: platform peak)")
    p.add_argument("--peak-flops", type=float, default=None, metavar="f",
                   help="Peak compute in FLOP/cycle (default 2*cores*threads*fpu_blocks)")
    p.add_argument("--output", default="system_roofline.png", metavar="file")

    for name, _, flag, _, is_bool in KNOBS:
        p.add_argument(flag, default=None, metavar="n")

    return p.parse_args()


def parse_sizes(raw):
    out = {}
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        k, v = tok.split("=")
        out[k.strip()] = int(v)
    return out


def main():
    args = parse_args()
    sizes = parse_sizes(args.sizes)

    cfg = {}
    for name, _, _, pow2, is_bool in KNOBS:
        v = getattr(args, name)
        if v is not None:
            cfg[name] = bool(int(v)) if is_bool else int(v)

    blackbox, cwd = find_blackbox(SimpleNamespace(build_dir=args.build_dir))
    print(f"Blackbox: {blackbox}\nCWD     : {cwd}")

    points = []
    for key, app, default_size, flops_fn, args_fn in BENCHMARKS:
        n = sizes.get(key, default_size)
        app_args = args_fn(n)
        trial_args = SimpleNamespace(driver=args.driver, app=app, app_args=app_args,
                                      perf=args.perf, configs=args.configs,
                                      timeout=args.timeout)
        print(f"\n── {key} ({app} {app_args}) " + "─" * 40)
        ipc, instrs, cycles, total_bytes, output = run_trial(trial_args, cfg, blackbox, cwd, False)
        print(output)
        if ipc is None:
            sys.exit(f"ERROR: {key} trial failed, aborting suite")
        flops = flops_fn(n)
        ai = (flops / total_bytes) if total_bytes else None
        points.append((key, ipc, flops, cycles, ai))

    plot_system_roofline(args, cfg, points, args.output)


def plot_system_roofline(args, cfg, points, outfile):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    by_cycle = (args.freq == 0)
    freq_hz = args.freq * 1e6 if args.freq > 0 else 1.0

    cores = cfg.get("cores", 1) or 1
    threads = cfg.get("threads", 4) or 4
    fpu_blocks = cfg.get("fpu_blocks", 1) or 1
    mem_bytes = cfg.get("mem_data_size", 64) or 64
    mem_banks = cfg.get("mem_banks", 2) or 2

    PLATFORM_PEAK_BW_GBS = 460.0

    peak_flops_per_cycle = (args.peak_flops if args.peak_flops is not None
                             else 2.0 * cores * threads * fpu_blocks)
    peak_bw_GBs = args.bw if args.bw is not None else PLATFORM_PEAK_BW_GBS
    peak_bw_per_cycle = peak_bw_GBs * 1e9 / freq_hz if args.freq > 0 else mem_bytes * mem_banks

    if by_cycle:
        peak_perf, peak_bw = peak_flops_per_cycle, peak_bw_per_cycle
        y_label = "Performance (FLOP/cycle)"
    else:
        peak_perf = peak_flops_per_cycle * freq_hz / 1e9
        peak_bw = peak_bw_GBs
        y_label = "Performance (GFLOP/s)"

    ridge = peak_perf / peak_bw

    fig, ax = plt.subplots(figsize=(12, 7))
    ai_range = np.logspace(-3, 4, 3000)
    roof = np.minimum(peak_bw * ai_range, np.full_like(ai_range, peak_perf))
    ax.loglog(ai_range, roof, "b-", linewidth=2.5, label="Roofline")
    ax.axhline(peak_perf, color="blue", linestyle="--", linewidth=1, alpha=0.5,
               label=f"Peak compute {peak_perf:.1f}")
    ax.axvline(ridge, color="green", linestyle=":", alpha=0.6,
               label=f"Ridge {ridge:.2f} FLOP/B")

    for key, ipc, flops, cycles, ai in points:
        if ai is None:
            continue
        act_perf = flops / cycles if by_cycle else flops / (cycles / freq_hz) / 1e9
        ax.plot(ai, act_perf, "o", color=COLORS[key], markersize=12, zorder=6,
                label=f"{key}  AI={ai:.2f}  perf={act_perf:.2f}  IPC={ipc:.3f}")

    domain = "cycle domain" if by_cycle else f"{args.freq:.0f} MHz"
    cfg_str = ", ".join(f"{k}={v}" for k, v in sorted(cfg.items()) if v is not None)
    ax.set_xlabel("Arithmetic Intensity (FLOP/byte)")
    ax.set_ylabel(y_label)
    ax.set_title(f"Vortex System Roofline — {args.driver}, {domain}\n{cfg_str}",
                 fontsize=10, fontweight="bold")
    ax.legend(fontsize=9, loc="upper left")
    ax.grid(True, which="both", alpha=0.25)
    plt.tight_layout()
    plt.savefig(outfile, dpi=150)
    plt.close(fig)
    print(f"\nSystem roofline saved → {os.path.abspath(outfile)}")


if __name__ == "__main__":
    main()
