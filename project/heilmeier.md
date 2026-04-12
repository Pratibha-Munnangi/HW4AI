# Heilmeier Questions — QKT Accelerator Chiplet
**ECE 410/510: Hardware for AI and ML, Spring 2026**  

---

## Q1. What are you trying to do? *(no jargon)*

Transformer models — the backbone of modern AI systems like ChatGPT and
translation tools — contain a step called "attention" where every word in a
sentence compares itself to every other word to understand context. The core
math behind this is a matrix multiplication called QKᵀ, where two rectangular
grids of numbers are multiplied together to produce a score table. This one
operation is the single biggest bottleneck in running a transformer: it consumes
91% of execution time in our measurements and scales quadratically with sentence
length, meaning doubling the sentence length quadruples the compute cost.

The goal of this project is to design a small, specialized piece of silicon — a
chiplet — that performs this QKᵀ multiplication much faster and more efficiently
than a general-purpose laptop CPU. The chiplet will sit alongside the main
processor, take in the two input matrices, compute the result in hardware using
a grid of parallel multiply-and-add units, and return the output. We will design
the hardware, verify it works correctly, and measure how much faster it is
compared to running the same computation in software.

---

## Q2. How is it done today, and what are the limits of current practice?

Today, QKᵀ is executed in software on general-purpose processors using NumPy
matrix operations. We profiled this directly on an Intel Core i5-1235U laptop
CPU using cProfile and wall-clock timing over 10 runs.

**Measured results:**

| Metric | Value |
|---|---|
| Mean execution time per call | 1,008.57 µs |
| Std deviation | 86.21 µs |
| Measured throughput | 4.1587 GFLOP/s |
| Theoretical attainable ceiling | 176.0 GFLOP/s |
| Hardware utilization | **2.4%** |
| Runtime share of total execution | **91% of total runtime** |

The profiler output confirms that `qkt_kernel()` accounts for 0.010s out of
0.011s total across 10 runs — it is unambiguously the dominant bottleneck.

The arithmetic intensity of the QKᵀ kernel is:

```
FLOPs  = 2 × B × H × T² × d_head = 2 × 8 × 4 × 64² × 16 = 4,194,304 FLOPs
Bytes  = 1,572,864 bytes (Q + K + scores, FP64, no reuse)
AI     = 4,194,304 / 1,572,864 = 2.67 FLOP/byte
```

On the i5-1235U (ridge point = 2.29 FLOP/byte), the kernel is compute-bound.
Yet the software achieves only **2.4% of the 176 GFLOP/s attainable ceiling**
due to Python interpreter overhead, sequential execution, and the inability of
NumPy to exploit fine-grained parallelism at this problem scale.

The fundamental limit of current practice is not the hardware ceiling — it is
the inability of general-purpose software execution to approach that ceiling for
this specific, highly structured computation. The software baseline achieves
only **2.4% of the 176 GFLOP/s attainable ceiling** — a ~42× gap that
motivates dedicated hardware. GPUs solve this at high cost and power; there is
no simple, synthesizable, open-source hardware implementation targeting this
specific kernel for academic ASIC design flows.

---

## Q3. What is new in your approach and why do you think it will be successful?

Our approach implements the QKᵀ kernel as a dedicated hardware accelerator —
a 16×16 systolic MAC array running at 500 MHz — designed from the ground up
for this specific computation rather than borrowing a general-purpose solution.

**What is new:**

Unlike GPU-based solutions, our accelerator is:
- **Kernel-specific:** hardwired for QKᵀ only, eliminating all control overhead
- **Open-source RTL:** designed in synthesizable Verilog, targeting an
  open-source ASIC flow (OpenLane/Sky130)
- **Architecturally transparent:** every design decision is driven by the
  roofline analysis of the actual measured kernel

**Why it will be successful:**

The roofline analysis provides a clear quantitative target. The hypothetical
accelerator design point sits at:

```
P_hw    = 16 × 16 × 2 × 500 MHz = 256 GFLOP/s
B_hw    = 512 GB/s (on-chip SRAM, eliminates DRAM bottleneck)
Ridge   = 256 / 512 = 0.50 FLOP/byte
AI      = 2.67 > 0.50 → compute-bound on accelerator (desired)
```

Required interface bandwidth to avoid being interface-bound:
```
BW_required = P_hw / AI = 256 / 2.67 = 95.9 GB/s
```

This confirms on-chip SRAM buffering is necessary — AXI4 Stream at 128-bit/500
MHz delivers only ~8 GB/s, which would bottleneck the design. The accelerator
therefore buffers Q and K tiles entirely on-chip before computing, using the
internal 512 GB/s SRAM bandwidth for all matrix accesses.

**Projected outcomes:**

| Metric | SW baseline | HW accelerator | Improvement |
|---|---|---|---|
| Measured throughput | 4.16 GFLOP/s | — | — |
| Attainable ceiling | 176.0 GFLOP/s | 256.0 GFLOP/s | 1.5× ceiling |
| vs. measured SW | 4.16 GFLOP/s | ~256 GFLOP/s | ~62× |
| HW utilization | 2.4% | ~100% (target) | 42× |

The approach is successful because the kernel is mathematically regular
(no branches, no data-dependent control flow), the data dimensions are fixed
at design time, and the arithmetic intensity is high enough to keep a systolic
array compute-bound rather than memory-bound. These three properties together
make QKᵀ one of the most hardware-friendly kernels in modern AI workloads.
