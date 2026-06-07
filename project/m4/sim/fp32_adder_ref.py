#!/usr/bin/env python3
import struct
import random
import sys


def fp32_bits(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def bits_to_fp32(u):
    return struct.unpack('<f', struct.pack('<I', u & 0xFFFFFFFF))[0]


def fp32_add_ref(a_bits, b_bits):
    a_sign = (a_bits >> 31) & 1
    a_exp  = (a_bits >> 23) & 0xFF
    a_mant =  a_bits        & 0x7FFFFF
    b_sign = (b_bits >> 31) & 1
    b_exp  = (b_bits >> 23) & 0xFF
    b_mant =  b_bits        & 0x7FFFFF

    a_is_zero = (a_exp == 0) or (a_exp == 255)
    b_is_zero = (b_exp == 0) or (b_exp == 255)

    ea_sign = 0  if a_is_zero else a_sign
    ea_exp  = 0  if a_is_zero else a_exp
    ea_sig  = 0  if a_is_zero else ((1 << 23) | a_mant)
    eb_sign = 0  if b_is_zero else b_sign
    eb_exp  = 0  if b_is_zero else b_exp
    eb_sig  = 0  if b_is_zero else ((1 << 23) | b_mant)

    a_is_bigger = (ea_exp > eb_exp) or (ea_exp == eb_exp and ea_sig >= eb_sig)
    big_sign    = ea_sign if a_is_bigger else eb_sign
    big_exp     = ea_exp  if a_is_bigger else eb_exp
    big_sig_ext = (ea_sig if a_is_bigger else eb_sig) << 3
    sml_sign    = eb_sign if a_is_bigger else ea_sign
    sml_sig_ext = (eb_sig if a_is_bigger else ea_sig) << 3
    exp_diff    = (ea_exp - eb_exp) if a_is_bigger else (eb_exp - ea_exp)
    exp_diff   &= 0xFF

    diff_too_big = (exp_diff >= 27)
    if diff_too_big:
        sml_aligned_pre = 0
        sticky_shift    = 1 if sml_sig_ext != 0 else 0
    else:
        mask            = (1 << exp_diff) - 1
        sticky_shift    = 1 if (sml_sig_ext & mask) != 0 else 0
        sml_aligned_pre = sml_sig_ext >> exp_diff
    sml_aligned_sticky = sml_aligned_pre | sticky_shift

    same_sign = (big_sign == sml_sign)
    if same_sign:
        raw_result = (big_sig_ext + sml_aligned_sticky) & 0xFFFFFFF
    else:
        raw_result = (big_sig_ext - sml_aligned_sticky) & 0xFFFFFFF

    raw_low   = raw_result & 0x7FFFFFF
    carry_out = (raw_result >> 27) & 1

    if raw_low == 0:
        lz = 27
    else:
        lz = 0
        v  = raw_low
        while (v & (1 << 26)) == 0:
            lz += 1
            v <<= 1
            v &= 0x7FFFFFF

    all_zero      = (raw_low == 0)
    all_zero_real = all_zero and not carry_out

    rsh_sig = ((raw_result >> 1) & 0xFFFFFFF) | (raw_result & 1)
    lsh_low = (raw_low << lz) & 0x7FFFFFF
    lsh_sig = lsh_low & 0xFFFFFFF

    if carry_out:
        norm_sig = rsh_sig
    elif all_zero:
        norm_sig = 0
    else:
        norm_sig = lsh_sig

    sub_underflow = (big_exp <= lz)
    if carry_out:
        norm_exp = big_exp + 1
    elif all_zero:
        norm_exp = 0
    elif sub_underflow:
        norm_exp = 0
    else:
        norm_exp = big_exp - lz
    norm_exp &= 0x1FF

    guard    = (norm_sig >> 2) & 1
    round_b  = (norm_sig >> 1) & 1
    sticky   =  norm_sig       & 1
    mant_pre = (norm_sig >> 3) & 0x7FFFFF

    round_up = guard & (round_b | sticky | (mant_pre & 1))
    mant_added = (mant_pre + round_up) & 0xFFFFFF
    round_carry = (mant_added >> 23) & 1

    if round_carry:
        mant_final = (mant_added >> 1) & 0x7FFFFF
        exp_final  = (norm_exp + 1) & 0x1FF
    else:
        mant_final =  mant_added      & 0x7FFFFF
        exp_final  =  norm_exp

    out_underflow = (exp_final == 0) or ((exp_final >> 8) & 1)
    out_overflow  = (exp_final >= 255)

    both_zero   = a_is_zero and b_is_zero
    only_a_zero = a_is_zero and not b_is_zero
    only_b_zero = b_is_zero and not a_is_zero
    force_zero  = both_zero or all_zero_real or out_underflow or out_overflow

    if force_zero:
        return 0
    if only_a_zero:
        return b_bits & 0xFFFFFFFF
    if only_b_zero:
        return a_bits & 0xFFFFFFFF
    return ((big_sign & 1) << 31) | ((exp_final & 0xFF) << 23) | (mant_final & 0x7FFFFF)


def directed_vectors():
    cases = []
    cases.append((fp32_bits(0.03125),   fp32_bits(0.03125),   "same_sign_eq_mag_pos"))
    cases.append((fp32_bits(-0.03125),  fp32_bits(-0.03125),  "same_sign_eq_mag_neg"))
    cases.append((fp32_bits(1.0),       fp32_bits(1.0),       "one_plus_one"))
    cases.append((fp32_bits(0.5),       fp32_bits(0.5),       "half_plus_half"))
    cases.append((fp32_bits(1.0),       fp32_bits(-1.0),      "cancel_to_zero"))
    cases.append((fp32_bits(1.000001),  fp32_bits(-1.0),      "near_cancel"))
    cases.append((fp32_bits(1.0e20),    fp32_bits(1.0e-20),   "large_exp_diff_pos"))
    cases.append((fp32_bits(1.0e20),    fp32_bits(-1.0e-20),  "large_exp_diff_neg"))
    cases.append((fp32_bits(0.0),       fp32_bits(0.0),       "both_zero"))
    cases.append((fp32_bits(0.0),       fp32_bits(3.14),      "only_a_zero"))
    cases.append((fp32_bits(3.14),      fp32_bits(0.0),       "only_b_zero"))
    cases.append((0x00000001,           fp32_bits(1.0),       "subnormal_a"))
    cases.append((fp32_bits(3.14159),   fp32_bits(2.71828),   "pi_plus_e"))
    cases.append((fp32_bits(100.0),     fp32_bits(0.001),     "magnitude_separated"))
    cases.append((fp32_bits(0.125),     fp32_bits(0.0625),    "small_fp16_range"))
    cases.append((fp32_bits(-0.25),     fp32_bits(0.5),       "mixed_sign_small"))
    return cases


def random_vectors(n, seed=42):
    rng = random.Random(seed)
    out = []
    while len(out) < n:
        a_sign = rng.randint(0, 1)
        a_exp  = rng.randint(10, 240)
        a_mant = rng.randint(0, (1 << 23) - 1)
        b_sign = rng.randint(0, 1)
        b_exp  = rng.randint(10, 240)
        b_mant = rng.randint(0, (1 << 23) - 1)
        a_bits = (a_sign << 31) | (a_exp << 23) | a_mant
        b_bits = (b_sign << 31) | (b_exp << 23) | b_mant
        out.append((a_bits, b_bits, f"rand_{len(out)}"))
    return out


def write_vectors(path, cases):
    with open(path, 'w') as f:
        for a, b, label in cases:
            s = fp32_add_ref(a, b)
            f.write(f"{a:08x} {b:08x} {s:08x}  // {label}\n")
    print(f"Wrote {len(cases)} vectors to {path}")


if __name__ == "__main__":
    cases = directed_vectors() + random_vectors(256, seed=42)
    write_vectors("fp32_add_vectors.mem", cases)
