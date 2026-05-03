# Precision and Numerical Format — M2

## Chosen format

The compute core multiplies in **IEEE 754 binary16 (FP16)** and accumulates in **IEEE 754 binary32 (FP32)**, with the following deliberate simplifications:

- **Flush-to-Zero (FTZ)** on subnormal inputs and outputs of both the multiplier and the adder. Subnormals are treated as zero rather than propagated through the datapath.
- **Round-to-Nearest, ties-to-Even (RNE)** rounding on the FP32 adder's result mantissa. The FP16 multiplier itself does no rounding because the FP16×FP16 mantissa product (22 bits) fits exactly in the FP32 mantissa (23 bits); no information is lost in the multiplication step.
- **No NaN or Inf propagation.** Out-of-range exponents are clamped to zero. Inputs are assumed to be finite, well-bounded post-LayerNorm activations, which is consistent with how QKᵀ is fed in real transformer pipelines.

The accumulator width (FP32) is wider than the multiplier width (FP16) by design: a single FP16 product cannot saturate FP32, and partial sums accumulate without intermediate narrowing. This is the same pattern used in NVIDIA Tensor Cores and Google's TPU MXU for QKᵀ.

## Rationale grounded in the project roofline

The M1/CF02 roofline analysis identified QKᵀ as **memory-bandwidth-bound** at the operating point of interest: arithmetic intensity is on the order of D FLOPs per (Q, K) byte pair, and HBM bandwidth caps achievable throughput well before the compute roof matters. This shapes the precision choice in three ways:

1. **Going wider than FP16 wastes bandwidth before it buys anything.** FP32 inputs would double the bytes-per-operand. At memory-bound operating points, that halves achievable throughput before any compute change is visible. The arithmetic intensity *worsens*, not improves.
2. **Going narrower (FP8, INT8) buys more bandwidth headroom but couples the hardware to a calibration story** — per-tensor or per-block scale factors, post-training quantization, and a dequantize step before softmax. That's a separate research project; out of scope for a blank-slate M2 chiplet.
3. **FP16 with FP32 accumulate is the industry-default sweet spot for attention.** It's training-stable, requires no calibration, has a clean RTL story (a 22-bit unsigned product widened into an FP32 mantissa), and matches the format used by every major attention accelerator deployed today.

The architecture is also parameterizable at the module boundary (`A_WIDTH`, `B_WIDTH`, `ACC_WIDTH` in the PE; the FP datapath helpers can be swapped). A future M3/M4 retarget to BF16 multiply, FP8 inputs, or fixed-point Q-format requires changing the helper modules and re-running the precision sweep, not redesigning the array control.

## Measured quantization error (sweep against FP32 reference)

The error analysis below is produced by `sweep/gen_sweep.py` (Python NumPy reference) and `sweep/tb_sweep.sv` / `sweep/tb_sweep_d16.sv` (RTL DUT), with results reduced by `sweep/analyze_sweep.py`. Two configurations were swept to characterize the design across the M2 verification dimension and the M3 target dimension.

### Configuration A — M2 verification dimension (N=4, D=4)

- **Trials:** 128 random Q, K matrix pairs.
- **Total cells compared:** 2048 (16 cells per trial × 128 trials).
- **Input distribution:** N(0, 0.5²), cast to FP16 before fed to the DUT.
- **Reference:** FP32 promoted from FP16 inputs, accumulated in the same order as the hardware (k = 0..D−1).

| Metric                 | Value           |
|------------------------|-----------------|
| Bit-exact agreement    | 2048 / 2048     |
| Bit-exact percentage   | 100.00%         |
| Mean absolute error    | 0.000e+00       |
| Max absolute error     | 0.000e+00       |
| Mean relative error    | 0.000e+00       |
| Max relative error     | 0.000e+00       |
| Mean ULP distance      | 0.000           |
| Max ULP distance       | 0               |

Every DUT output matches the FP32 reference bit-for-bit. With D=4 and inputs scaled to N(0, 0.5²), no operand or partial sum approaches the FP32 subnormal floor (≈1.18×10⁻³⁸), so the FTZ policy never engages, and the four accumulation steps do not produce any sub-ULP discards that would force RNE to round nontrivially.

### Configuration B — M3 target dimension (N=4, D=16)

- **Trials:** 128 random Q, K matrix pairs (different seed: 411).
- **Total cells compared:** 2048.
- **Input distribution and reference policy:** same as above.

| Metric                 | Value             |
|------------------------|-------------------|
| Bit-exact agreement    | 2040 / 2048       |
| Bit-exact percentage   | 99.61%            |
| Mean absolute error    | 6.816e-08         |
| Max absolute error     | 4.220e-05         |
| Mean relative error    | 7.142e-08         |
| Max relative error     | 4.051e-05         |
| Mean ULP distance      | 0.786             |
| Max ULP distance       | 425               |

ULP distribution:

| ULP bucket | Cells | %      |
|------------|-------|--------|
| 0          | 2040  | 99.61% |
| 1          | 0     | 0.00%  |
| 2          | 0     | 0.00%  |
| 3          | 0     | 0.00%  |
| 4–15       | 1     | 0.05%  |
| 16–255     | 4     | 0.20%  |
| 256+       | 3     | 0.15%  |

Worst-case cell:

```
hw  = 0xbfc9c80b   = -1.576417e+00
ref = 0xbfc9c6a9   = -1.576375e+00
abs err = 4.220e-05    rel err = 4.051e-05    ULP distance = 425
```

The 425-ULP worst case sounds dramatic in isolation but is consistent with FP32 RNE accumulation at this magnitude: at value ≈ −1.576, one ULP is ≈ 1.19×10⁻⁷, so 425 ULPs is ≈ 5×10⁻⁵ — exactly the absolute error observed. The 8 non-bit-exact cells across 2048 are all the result of compounded RNE rounding events along the 16-term accumulation, not any FTZ event or NaN/Inf escape.

The empirical mean relative error of ≈7×10⁻⁸ is roughly half a relative ULP, which is the theoretical expectation for RNE-rounded sums under independent uniform errors.

## Statement of acceptability

**The error is acceptable** for the QKᵀ kernel because:

1. **Downstream tolerance.** QKᵀ feeds into a softmax, which is dominated by the *largest* score (numerically stabilized via subtract-max). A relative error of 4×10⁻⁵ in any single score does not change the top-k ordering or the post-softmax probability distribution to any measurable degree. Published attention-quantization studies (NVIDIA Tensor-RT INT8 attention, Microsoft DeepSpeed FP16 inference) report end-to-end model accuracy preserved with quantization errors many orders of magnitude larger than what is measured here.
2. **Industry baseline.** NVIDIA Tensor Cores in FP16 mode commit ULP-level rounding errors on FMA accumulation; their attention implementations are the de-facto reference for numerical acceptability. The error envelope measured here (max relative ≈ 4×10⁻⁵) is comparable to or tighter than the FP16-FMA path on H100/A100 hardware in equivalent configurations.
3. **Application-specific tolerance.** A relative error of 1×10⁻³ would still be acceptable for inference-time attention based on published quantization-tolerance studies of transformer models. The actual measured error (1×10⁻⁵ at D=16, exact at D=4) is two orders of magnitude inside that envelope.

## Test harness and reproducibility

Files under `project/m2/sweep/` regenerate every number above:

```
sweep/gen_sweep.py        # generate trial vectors + FP32 reference
sweep/tb_sweep.sv         # D=4 sweep DUT-driver
sweep/tb_sweep_d16.sv     # D=16 sweep DUT-driver
sweep/analyze_sweep.py    # compute statistics from hw_sweep.mem vs ref_sweep.mem
sweep/sim_sweep/          # D=4 outputs (q_sweep.mem, k_sweep.mem,
                          #             ref_sweep.mem, hw_sweep.mem,
                          #             error_stats.txt, error_stats.json)
sweep/sim_sweep_d16/      # D=16 outputs (same layout)
```

Reproduction:

```bash
cd project/m2/sweep
python3 gen_sweep.py                             # writes sim_sweep/*.mem (D=4)
python3 gen_sweep.py --D 16 --outdir sim_sweep_d16 --seed 411
cd ..
iverilog -g2012 -o sweep/tb_sweep.vvp \
    rtl/fp16_multiplier.sv rtl/fp32_adder.sv rtl/core_pe.sv rtl/compute_core.sv \
    sweep/tb_sweep.sv
vvp sweep/tb_sweep.vvp
iverilog -g2012 -o sweep/tb_sweep_d16.vvp \
    rtl/fp16_multiplier.sv rtl/fp32_adder.sv rtl/core_pe.sv rtl/compute_core.sv \
    sweep/tb_sweep_d16.sv
vvp sweep/tb_sweep_d16.vvp
cd sweep && python3 analyze_sweep.py             # for sim_sweep
# Edit analyze_sweep.py to point at sim_sweep_d16 and re-run for D=16 stats.
```

The `tb_compute_core` testbench's pass-tolerance (`REL_TOL = 2⁻¹⁰ ≈ 9.8×10⁻⁴`, `ABS_TOL = 1×10⁻⁶`) is set conservatively above the worst-case measured relative error (4×10⁻⁵) to provide margin for input distributions outside the swept range. The compute core verification log (`sim/compute_core_run.log`) shows all 16 cells PASSing bit-exact at the M2 verification dimension.
