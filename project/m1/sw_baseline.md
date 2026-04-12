# Software Baseline Benchmark — QKT Kernel
**ECE 410/510: Hardware for AI and ML, Spring 2026**
**Milestone M1 — Software Baseline**
**File:** `project/m1/sw_baseline.md`

---

## 1. Platform and Configuration

| Item | Value | Source |
|---|---|---|
| CPU | Intel Core i5-1235U (12th Gen Alder Lake) | Intel ARK |
| Cores | 2 P-cores @ 4.4 GHz + 8 E-cores @ 3.3 GHz | Intel ARK |
| Memory | LPDDR5-5200, dual-channel, 76.8 GB/s peak | Intel ARK |
| OS | Windows 11 | — |
| Python | 3.x (CPython) | `python --version` |
| NumPy | 2.4.4 | `np.__version__` |
| Data type | FP64 (float64) | — |

## 2. Workload Configuration

| Parameter | Symbol | Value |
|---|---|---|
| Batch size | B | 8 |
| Sequence length | T | 64 |
| Model dimension | D | 64 |
| Number of heads | H | 4 |
| Head dimension | d_head | 16 |
| Scale factor | 1/√d_head | 0.25 |
| Measurement runs | N | 10 |

**Kernel under test:** `qkt_kernel(Q, K, scale)` in `qkt_baseline.py`
computing `scores = Q @ K.transpose(0,1,3,2) * scale`, output shape `(B, H, T, T)`.

## 3. Execution Time (wall-clock, 10 runs)

Per-run wall-clock timings (`time.perf_counter`):

| Run | Time (µs) |
|---|---|
| 1 | 888.50 |
| 2 | 1100.70 |
| 3 | 1105.00 |
| 4 | 999.20 |
| 5 | 981.90 |
| 6 | 960.10 |
| 7 | 982.30 |
| 8 | 923.80 |
| 9 | 964.80 |
| 10 | 1179.40 |

**Summary statistics:**

| Metric | Value |
|---|---|
| Mean | 1008.57 µs |
| **Median** | **981.10 µs** |
| Std dev | 86.21 µs |
| Min | 888.50 µs |
| Max | 1179.40 µs |

## 4. Throughput

```
FLOPs per call  = 2 × B × H × T² × d_head
                = 2 × 8 × 4 × 64² × 16
                = 4,194,304 FLOPs

Throughput (mean)   = 4,194,304 / 1008.57e-6 / 1e9 = 4.16 GFLOP/s
Throughput (median) = 4,194,304 /  981.10e-6 / 1e9 = 4.27 GFLOP/s
```

**Reported throughput: 4.27 GFLOP/s (median).**

Attainable ceiling on the i5-1235U = 176 GFLOP/s (compute roof, since
AI = 2.67 FLOP/B > ridge = 2.29 FLOP/B). **HW utilization = 2.4%.**

## 5. Memory Usage

Measured via `psutil` (process RSS) and `tracemalloc` (Python heap allocations)
across the 10-run kernel loop:

| Metric | Value |
|---|---|
| Process RSS before kernel loop | 35.36 MB |
| **Peak process RSS (after loop)** | **36.47 MB** |
| RSS delta attributable to kernel | 1.12 MB |
| Python peak allocation (tracemalloc) | 3.15 MB |

**Interpretation:**

- **Peak RSS = 36.47 MB.** Total resident memory of the Python interpreter
  plus NumPy plus the QKT working set. The bulk (~35 MB) is interpreter
  and library overhead, not the kernel itself.
- **RSS delta = 1.12 MB.** Additional resident memory the kernel
  consumes during execution.
- **Python peak alloc = 3.15 MB.** Largest in-flight Python-heap
  allocation observed by `tracemalloc`. Larger than the RSS delta
  because tracemalloc captures transient intermediate buffers
  (e.g., the transposed K view materialized for the matmul) that
  NumPy frees back to the allocator before the loop exits.

**Analytical lower bound (operand footprint only):**

```
Q       : 8 × 4 × 64 × 16 × 8 B = 262,144 B ≈ 0.25 MB
K       : 8 × 4 × 64 × 16 × 8 B = 262,144 B ≈ 0.25 MB
scores  : 8 × 4 × 64 × 64 × 8 B = 1,048,576 B ≈ 1.00 MB
Total   : ≈ 1.57 MB of tensor data per call
```

The measured 1.12 MB RSS delta and 3.15 MB tracemalloc peak both sit in
the same order of magnitude as the 1.57 MB analytical footprint,
confirming the kernel's working set is small and tile-cacheable —
which is exactly what motivates on-chip SRAM buffering in the
accelerator design.

## 6. Reproducibility

To reproduce timing:

```bash
python qkt_baseline.py
```

To reproduce memory measurement:

```bash
python -m pip install psutil
python qkt_memcheck.py
```

Both scripts use the same fixed random seed (`np.random.default_rng(42)`),
so data values are deterministic across runs. Wall-clock timing has
~10% run-to-run variance due to OS scheduling.

## 7. Baseline Target for M4

This **4.27 GFLOP/s median throughput** and **36.47 MB peak RSS** are the
reference points for the M4 speedup and efficiency comparison. The
hypothetical 16×16 systolic MAC array at 500 MHz targets **256 GFLOP/s**
attainable, giving a projected **~60× speedup** over this software baseline
with a fraction of the memory footprint (the accelerator's working set is
~1.5 MB on-chip SRAM, vs. ~36 MB of host process state for the SW path).
