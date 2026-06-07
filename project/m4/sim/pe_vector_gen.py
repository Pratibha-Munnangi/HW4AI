#!/usr/bin/env python3
"""
pe_vector_gen.py — generate test vectors for tb_core_pe.

For each test case, picks 4 FP16 (a, b) pairs, computes products via an
FP16 multiplier model, then reduces them in the SAME ORDER as the
hardware tree-reduce: ((p0+p1) + (p2+p3)). This matches what the
hardware will compute bit-for-bit.
"""

import struct
import random
import sys

# Import the bit-exact FP32 adder from the adder test
sys.path.insert(0, '.')
from fp32_adder_ref import fp32_add_ref, fp32_bits, bits_to_fp32


# =============================================================================
# FP16 utilities
# =============================================================================

def fp16_to_float(h):
    """Convert 16-bit FP16 pattern to Python float (no FTZ)."""
    s = (h >> 15) & 1
    e = (h >> 10) & 0x1F
    m =  h        & 0x3FF
    if e == 0:
        # subnormal
        f = (m / 1024.0) * (2 ** -14)
    elif e == 31:
        # NaN/Inf
        f = float('inf') if m == 0 else float('nan')
    else:
        f = (1 + m / 1024.0) * (2 ** (e - 15))
    return -f if s else f


def float_to_fp16(f):
    """Convert Python float to FP16 bit pattern (round-to-nearest, no special-case
    handling for subnormals/NaN — we keep it within normal range)."""
    if f == 0.0:
        return 0
    s = 0 if f >= 0 else 1
    fa = abs(f)
    # Find exponent
    import math
    e_unbiased = int(math.floor(math.log2(fa)))
    e_biased = e_unbiased + 15
    if e_biased <= 0:
        return 0  # FTZ subnormals
    if e_biased >= 31:
        return (s << 15) | (30 << 10) | 0x3FF  # clamp to max normal
    mantissa = fa / (2 ** e_unbiased) - 1.0
    m = int(round(mantissa * 1024)) & 0x3FF
    return (s << 15) | (e_biased << 10) | m


def fp16_multiply(a_bits, b_bits):
    """Model of the fp16_multiplier module. Returns 32-bit FP32 pattern.
    Mirrors RTL: FTZ subnormals/specials to 0."""
    # Same FTZ classification as the RTL
    a_exp = (a_bits >> 10) & 0x1F
    b_exp = (b_bits >> 10) & 0x1F
    if a_exp in (0, 31) or b_exp in (0, 31):
        return 0  # any FTZ input → zero product

    # Otherwise convert to float, multiply, convert back to FP32 bits
    a_f = fp16_to_float(a_bits)
    b_f = fp16_to_float(b_bits)
    prod = a_f * b_f
    # Convert to FP32 bits (with Python's native rounding)
    prod_bits = fp32_bits(prod)
    # Apply FP32 FTZ classification too (subnormals/NaN/Inf → 0)
    pe = (prod_bits >> 23) & 0xFF
    if pe in (0, 255):
        return 0
    return prod_bits


def pe_tree_reduce(prods):
    """Compute tree-reduce sum: ((p0+p1) + (p2+p3))."""
    s01 = fp32_add_ref(prods[0], prods[1])
    s23 = fp32_add_ref(prods[2], prods[3])
    return fp32_add_ref(s01, s23)


# =============================================================================
# Vector generation
# =============================================================================

def directed_cases():
    """Hand-picked corner cases."""
    cases = []

    # Simple: 1*1 + 1*1 + 1*1 + 1*1 = 4
    cases.append(([float_to_fp16(1.0)]*4, [float_to_fp16(1.0)]*4, "all_ones"))

    # All zeros: result 0
    cases.append(([0]*4, [0]*4, "all_zeros"))

    # Mix of zeros and ones
    cases.append(
        ([float_to_fp16(1.0), 0, float_to_fp16(2.0), 0],
         [float_to_fp16(1.0), float_to_fp16(99.0), float_to_fp16(2.0), float_to_fp16(99.0)],
         "alternating_zero")
    )

    # Positive accumulation: 0.5*0.5 + 0.25*0.25 + 0.125*0.125 + 0.0625*0.0625
    cases.append(
        ([float_to_fp16(0.5), float_to_fp16(0.25), float_to_fp16(0.125), float_to_fp16(0.0625)],
         [float_to_fp16(0.5), float_to_fp16(0.25), float_to_fp16(0.125), float_to_fp16(0.0625)],
         "decreasing_pos")
    )

    # Cancellation: 1*1 + 1*(-1) + 1*1 + 1*(-1) = 0
    cases.append(
        ([float_to_fp16(1.0)]*4,
         [float_to_fp16(1.0), float_to_fp16(-1.0), float_to_fp16(1.0), float_to_fp16(-1.0)],
         "cancel_to_zero")
    )

    # Small magnitudes typical of QK^T after scaling
    cases.append(
        ([float_to_fp16(0.1), float_to_fp16(0.2), float_to_fp16(0.3), float_to_fp16(0.4)],
         [float_to_fp16(0.5), float_to_fp16(0.4), float_to_fp16(0.3), float_to_fp16(0.2)],
         "small_mix")
    )

    return cases


def random_cases(n, seed=42):
    """Random FP16 pairs in a moderate range."""
    rng = random.Random(seed)
    out = []
    for i in range(n):
        a = [float_to_fp16(rng.uniform(-2.0, 2.0)) for _ in range(4)]
        b = [float_to_fp16(rng.uniform(-2.0, 2.0)) for _ in range(4)]
        out.append((a, b, f"rand_{i}"))
    return out


def write_vectors(path, cases):
    with open(path, 'w') as f:
        for a, b, label in cases:
            prods = [fp16_multiply(a[k], b[k]) for k in range(4)]
            expected = pe_tree_reduce(prods)
            f.write(
                f"{a[0]:04x} {b[0]:04x} "
                f"{a[1]:04x} {b[1]:04x} "
                f"{a[2]:04x} {b[2]:04x} "
                f"{a[3]:04x} {b[3]:04x} "
                f"{expected:08x}  // {label}\n"
            )
    print(f"Wrote {len(cases)} PE test cases to {path}")


if __name__ == "__main__":
    cases = directed_cases() + random_cases(128, seed=42)
    write_vectors("pe_vectors.mem", cases)
