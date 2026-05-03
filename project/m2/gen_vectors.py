#!/usr/bin/env python3
# =============================================================================
# File   : gen_vectors.py
# Purpose: Generate the FP16 Q, K input vectors and the FP32 QK^T reference
#          consumed by tb_compute_core.sv.
#
# Outputs (written into project/m2/sim/):
#   q_hex.mem        : N*D lines, FP16 hex (4 chars), row-major Q matrix
#   k_hex.mem        : N*D lines, FP16 hex (4 chars), row-major K matrix
#   ref_hex.mem      : N*N lines, FP32 hex (8 chars), row-major QK^T
#   vectors_meta.txt : human-readable Q, K, and reference dump for sanity check
#
# Independence of the reference (rubric requirement, Section 2):
#   The reference QK^T is computed entirely in Python/NumPy and is NEVER
#   derived from a prior run of the DUT. Operands are promoted from FP16 to
#   FP32 before the multiply, and accumulated in the SAME k-major order the
#   hardware uses (k = 0..D-1).
#
# Reproducibility:
#   Default seed is 410 (course number). Re-running this script with
#   identical args produces byte-identical .mem files.
#
# Usage:
#   python gen_vectors.py                    # default N=4 D=4 seed=410
#   python gen_vectors.py --N 16 --D 16      # M3 scale-up vectors
#
# Dependencies: numpy (any 1.x or 2.x). Tested with numpy 2.x on Python 3.10+.
# =============================================================================

import argparse
import struct
import numpy as np
from pathlib import Path


def fp16_to_hex(x):
    """Return the 4-hex-char IEEE 754 binary16 bit pattern."""
    bits = np.frombuffer(np.float16(x).tobytes(), dtype=np.uint16)[0]
    return f"{bits:04x}"


def fp32_to_hex(x):
    """Return the 8-hex-char IEEE 754 binary32 bit pattern."""
    bits = struct.unpack(">I", struct.pack(">f", float(x)))[0]
    return f"{bits:08x}"


def write_mem(path, hex_strings):
    with path.open("w") as f:
        for h in hex_strings:
            f.write(h + "\n")


def main():
    ap = argparse.ArgumentParser(description="Generate Q, K, QK^T vectors for tb_compute_core.")
    ap.add_argument("--N", type=int, default=4, help="Q rows / K rows / output side length.")
    ap.add_argument("--D", type=int, default=4, help="Inner dimension d_k.")
    ap.add_argument("--seed", type=int, default=410, help="RNG seed (course number default).")
    ap.add_argument("--scale", type=float, default=0.5, help="Std-dev of input distribution.")
    ap.add_argument("--outdir", type=str, default="sim", help="Output directory (relative to script).")
    args = ap.parse_args()

    here = Path(__file__).resolve().parent
    outdir = (here / args.outdir).resolve()
    outdir.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(args.seed)

    # Inputs are sampled in FP32 then cast down to FP16. This mimics how a
    # real model feeds the accelerator: post-LayerNorm activations are FP32,
    # cast to FP16 just before the systolic array consumes them.
    Q_fp32 = rng.normal(0.0, args.scale, size=(args.N, args.D)).astype(np.float32)
    K_fp32 = rng.normal(0.0, args.scale, size=(args.N, args.D)).astype(np.float32)
    Q_fp16 = Q_fp32.astype(np.float16)
    K_fp16 = K_fp32.astype(np.float16)

    # Independent FP32 reference computed in the SAME accumulation order as
    # the hardware (k as the innermost loop). FP add isn't associative, so
    # changing this order would shift the reference bit-for-bit.
    ref = np.zeros((args.N, args.N), dtype=np.float32)
    for i in range(args.N):
        for j in range(args.N):
            acc = np.float32(0.0)
            for k in range(args.D):
                a = np.float32(Q_fp16[i, k])
                b = np.float32(K_fp16[j, k])
                acc = np.float32(acc + np.float32(a * b))
            ref[i, j] = acc

    # Flat row-major dumps consumed by $readmemh in tb_compute_core.sv:
    #   q_mem[i*D + k] = Q[i][k]
    #   k_mem[j*D + k] = K[j][k]
    #   ref_mem[i*N + j] = ref[i][j]
    q_lines = [fp16_to_hex(Q_fp16[i, k]) for i in range(args.N) for k in range(args.D)]
    k_lines = [fp16_to_hex(K_fp16[j, k]) for j in range(args.N) for k in range(args.D)]
    r_lines = [fp32_to_hex(ref[i, j])    for i in range(args.N) for j in range(args.N)]

    write_mem(outdir / "q_hex.mem",   q_lines)
    write_mem(outdir / "k_hex.mem",   k_lines)
    write_mem(outdir / "ref_hex.mem", r_lines)

    # Human-readable companion file. Useful when diagnosing a FAIL.
    meta = outdir / "vectors_meta.txt"
    with meta.open("w") as f:
        f.write(f"# QK^T testbench vectors\n")
        f.write(f"N (rows) : {args.N}\n")
        f.write(f"D (inner): {args.D}\n")
        f.write(f"seed     : {args.seed}\n")
        f.write(f"scale    : {args.scale}\n")
        f.write(f"\n# Q (FP16, row-major)\n")
        for i in range(args.N):
            f.write("  " + " ".join(f"{Q_fp16[i,k]:+.4f}" for k in range(args.D)) + "\n")
        f.write(f"\n# K (FP16, row-major)\n")
        for j in range(args.N):
            f.write("  " + " ".join(f"{K_fp16[j,k]:+.4f}" for k in range(args.D)) + "\n")
        f.write(f"\n# Reference QK^T (FP32, row-major)\n")
        for i in range(args.N):
            f.write("  " + " ".join(f"{ref[i,j]:+.6e}" for j in range(args.N)) + "\n")

    print(f"Wrote vectors to {outdir}")
    print(f"Reference QK^T value range: [{ref.min():+.4e}, {ref.max():+.4e}]")


if __name__ == "__main__":
    main()
