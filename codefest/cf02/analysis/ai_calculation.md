# Arithmetic Intensity Calculation — QKT Kernel
**ECE 410/510: Hardware for AI and ML, Spring 2026**  
**Project: QKT Matrix Multiplication Hardware Accelerator**  
**File:** `codefest/cf02/analysis/ai_calculation.md`

---

## Dominant Kernel Identification

From cProfile profiling over 10 runs of `qkt_kernel()`:

```
22 function calls in 0.011 seconds

   ncalls  tottime  percall  cumtime  percall  function
        1    0.001    0.001    0.011    0.011  run_qkt_n_times
       10    0.010    0.001    0.010    0.001  qkt_kernel        ← 91% of runtime
        1    0.000    0.000    0.000    0.000  profiler.disable
       10    0.000    0.000    0.000    0.000  numpy.transpose
```

**Dominant kernel:** `qkt_kernel()` in `qkt_baseline.py`

**Operation:**
```python
scores = Q @ K.transpose(0, 1, 3, 2) * scale
```

This computes the scaled dot-product attention scores:

```
scores[b, h, i, j] = (1/sqrt(d_head)) * sum_k Q[b,h,i,k] * K[b,h,j,k]
```

**Why it dominates:**
- Accounts for 91% of total runtime (0.010s / 0.011s)
- Scales as O(T² × d_head) with sequence length
- Is the heaviest operation per attention layer in a transformer

---

## Configuration

| Parameter | Symbol | Value |
|---|---|---|
| Batch size | B | 8 |
| Sequence length | T | 64 |
| Model dimension | D | 64 |
| Number of heads | H | 4 |
| Head dimension | d_head = D/H | 16 |
| Data type | — | FP64 (8 bytes) |
| Scale factor | 1/√d_head | 0.25 |

---

## FLOPs Derivation

Each output element `scores[b, h, i, j]` requires:
- `d_head` multiplications (one per k)
- `d_head - 1` additions (accumulate partial products)
- ≈ **2 × d_head FLOPs** per output element

Total output elements = B × H × T × T

Therefore:

```
FLOPs = 2 × B × H × T² × d_head
```

Substituting values:

```
FLOPs = 2 × 8 × 4 × 64² × 16
      = 2 × 8 × 4 × 4,096 × 16
      = 4,194,304 FLOPs
      ≈ 4.194 MFLOPs
```

---

## Bytes Transferred Derivation

Assuming all operands loaded from DRAM with **no cache reuse**:

**Q matrix** — shape (B, H, T, d_head), FP64:
```
Bytes_Q = B × H × T × d_head × 8
        = 8 × 4 × 64 × 16 × 8
        = 262,144 bytes
```

**K matrix** — shape (B, H, T, d_head), FP64:
```
Bytes_K = B × H × T × d_head × 8
        = 8 × 4 × 64 × 16 × 8
        = 262,144 bytes
```

**scores (output)** — shape (B, H, T, T), FP64:
```
Bytes_scores = B × H × T × T × 8
             = 8 × 4 × 64 × 64 × 8
             = 1,048,576 bytes
```

**Total bytes transferred:**
```
Total = Bytes_Q + Bytes_K + Bytes_scores
      = 262,144 + 262,144 + 1,048,576
      = 1,572,864 bytes
      ≈ 1.573 MB
```

---

## Arithmetic Intensity

```
I = FLOPs / Bytes
  = 4,194,304 / 1,572,864
  = 2.6667 FLOP/byte
```

---

## Roofline Analysis — Intel Core i5-1235U

### Hardware Specifications

| Parameter | Value | Source |
|---|---|---|
| Peak compute (P_peak) | 176.0 GFLOP/s | 2 P-cores × 8 FP64 FLOPs/cycle × 4.4 GHz + 8 E-cores × 4 FP64 FLOPs/cycle × 3.3 GHz |
| Peak bandwidth (B_peak) | 76.8 GB/s | LPDDR5-5200 dual-channel spec |
| Ridge point (I*) | 2.2917 FLOP/byte | P_peak / B_peak = 176.0 / 76.8 |

### Bound Classification

```
AI = 2.6667 FLOP/byte
I* = 2.2917 FLOP/byte

AI (2.6667) > I* (2.2917) → COMPUTE-BOUND on i5-1235U
```

### Attainable Performance

```
Attainable = min(P_peak, AI × B_peak)
           = min(176.0, 2.6667 × 76.8)
           = min(176.0, 204.8)
           = 176.0 GFLOP/s
```

### Measured Performance (from profiling)

```
Mean execution time : 1008.57 µs (over 10 runs)
Std deviation       : 86.21 µs
Min                 : 888.50 µs
Max                 : 1179.40 µs
Measured throughput : 4,194,304 FLOPs / 0.00100857 s / 1e9
                    = 4.1587 GFLOP/s
HW utilization      : 4.1587 / 176.0 = 2.4%
```

**Key finding:** The software baseline achieves only **2.4% of the attainable
ceiling**. This large gap is due to Python/NumPy interpreter overhead, lack
of vectorization, and memory latency at this problem size. This directly
motivates hardware acceleration.

---

## Summary Table

| Metric | Value |
|---|---|
| Dominant kernel | `qkt_kernel()` — 91% of runtime |
| FLOPs | 4,194,304 (4.194 MFLOPs) |
| Bytes transferred | 1,572,864 (1.573 MB) |
| Arithmetic Intensity | **2.6667 FLOP/byte** |
| Ridge point (i5-1235U) | 2.2917 FLOP/byte |
| Bound classification | **Compute-bound** |
| Attainable performance | 176.0 GFLOP/s |
| Measured performance | 4.1587 GFLOP/s |
| HW utilization | **2.4%** |

---

## Conclusion

The QKᵀ kernel is compute-bound on the i5-1235U with an arithmetic intensity
of 2.67 FLOP/byte, sitting just above the ridge point of 2.29 FLOP/byte.
However, the software baseline achieves only 2.4% of the attainable ceiling,
leaving a ~42× performance gap that a dedicated hardware accelerator can
exploit by eliminating Python overhead and executing MAC operations in parallel
using a systolic array.
