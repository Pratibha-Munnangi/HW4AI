# GEMM Analysis: Naive vs. Tiled (T=8) on NVIDIA T4

**Measured (1024×1024 FP32, `cudaEventRecord`, 20-iter average, steady-state warm runs):**
- Naive: 4.04 ms, **527.6 GFLOP/s** (6.5% of T4 FP32 peak ≈ 8.1 TFLOP/s)
- Tiled (T=8): 3.68 ms, **583.2 GFLOP/s** (7.2% of peak)
- Speedup: **1.11×**

**Nsight Compute key metrics:**

| Metric | Naive | Tiled (T=8) |
|---|---|---|
| L1/TEX throughput | 93.7% | 98.3% |
| L1 hit rate | 87.4% | 22.0% |
| L2 hit rate | 81.1% | 95.4% |
| DRAM throughput | 23.3 GB/s (7.3%) | 19.5 GB/s (6.1%) |
| Eligible warps/sched | 0.74 | 0.51 |
| Top stall reason | LG memory queue (80.7%) | MIO/shared-mem queue (57.7%) |

## (a) Why the naive kernel is memory-bound

Each thread computes one output element via `C[i][j] = Σ A[i][k]·B[k][j]`, issuing 2N global-memory loads for 2N FLOPs — a theoretical arithmetic intensity of only ~0.25 FLOP/byte, far below the T4's ridge point of ~25 FLOP/byte. T4's L1 cache absorbs most of A's row reuse (87% L1 hit rate), but the cache itself becomes the bottleneck: L1/TEX throughput sits at 93.7%, warps spend ~80% of their stall cycles waiting on the LG memory queue, and Nsight reports only 18 of 32 bytes per sector are utilized — B's column accesses are uncoalesced (stride N along k). The kernel is memory-system-bound, not compute-bound.

## (b) How tiling reduces DRAM traffic

The tiled kernel cooperatively stages T×T tiles of A and B into shared memory before any FMAs execute. Each shared-memory load is then reused T times by the threads in the same row/column of the block, cutting DRAM traffic to ~1/T of the naive uncached case. The profile confirms this works as designed: DRAM throughput drops from 23.3 → 19.5 GB/s while delivering more FLOPs per second, and the L2 hit rate rises from 81% to 95% because shared-memory staging produces fully coalesced 32-byte loads.

## (c) Did tiling hit the expected improvement? Remaining bottleneck

A 1.11× speedup is much smaller than the ~4× one might naïvely hope for from T-fold reuse — tiling barely helped. Two reasons. First, the naive kernel was *not actually DRAM-bound*: T4's L1 cache was already serving 87% of accesses, hiding most DRAM traffic. Second, the bottleneck simply moved. With T=8: (1) blocks are 8×8 = 64 threads (only 2 warps), so eligible-warps-per-scheduler dropped from 0.74 to 0.51, starving the issue slots; (2) each thread does only T=8 FMAs per shared-memory round-trip, not enough math to amortize the load+`__syncthreads()` cost; (3) the dominant stall reason shifted to **MIO/shared-memory queue saturation** (L1/TEX throughput 98.3%). The kernel is now shared-memory-bandwidth-bound. A larger tile (T=32) with thread coarsening would raise FMAs-per-load and unblock the MIO pipe, pushing performance toward the compute roof.
