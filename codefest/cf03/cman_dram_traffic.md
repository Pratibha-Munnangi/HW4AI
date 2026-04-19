# CMAN — DRAM Traffic Analysis: Naive vs. Tiled Matrix Multiply

**Given data:** N = 32, FP32 = 4 bytes, DRAM bandwidth = 320 GB/s, Compute = 10 TFLOPS

---

## Task 1: Naive Triple Loop (ijk order)

Each element B[k][j] is accessed N = 32 times (once per row of A).

- A accesses: N³ = 32³ = 32,768
- B accesses: N³ = 32³ = 32,768
- Total element accesses = 2N³ = 2 × (32)³ = 65,536
- Total DRAM traffic = 2N³ × 4 = 65,536 × 4 = 262,144 bytes ≈ 256 KB

**Total DRAM traffic = 256 KB**

---

## Task 2: Tiled Loop (T = 8)

Tile size T = 8. Number of tiles per dimension = N/T = 32/8 = 4.

A tile loads: each A and B tile is used N/T times (once per tile column of B).

- A loads = (N/T)³ × T² = (4)³ × 8² = 64 × 64 = 4,096 elements
- B tile also same = 4,096 elements
- Total DRAM traffic = 2 × 4,096 × 4 = 32,768 bytes = 32 KB

**Total DRAM traffic = 32 KB**

---

## Task 3: Traffic Ratio

- Naive traffic = 262,144 bytes
- Tiled traffic = 32,768 bytes
- Traffic ratio = Naive / Tiled = 262,144 / 32,768 = 8 (T)

Tiled traffic = Naive traffic ÷ N = 262,144 ÷ 32 = 8,192 bytes

Ratio = 262,144 / 8,192 = 32 = N

In the naive traffic, we reload matrix B from memory 32 times because every row of A needs to read all of B again. Tiling fixes this by keeping B in fast memory and reusing it, so we only load B once. That is why the naive method uses 32 times more memory traffic — exactly N times more.

---

## Task 4: Execution Time and Bound Classification

- Bandwidth = 320 GB/s
- Compute = 10 TFLOPS
- Total FLOPs = 2 × N³ = 2 × 32³ = 65,536 FLOPs

**Naive case:**

- t_memory = Traffic / BW = 262,144 / (320 × 10⁹) = 8.192 × 10⁻⁷ s = 0.819 µs
- t_compute = FLOPs / P = 65,536 / (1.0 × 10¹³) = 6.554 × 10⁻⁹ s = 0.00655 µs
- t_memory (0.819 µs) >> t_compute (0.00655 µs)
- **t_exec (naive) = 0.819 µs**
- **Bottleneck: Memory-bound**

**Tiled case (T = 8):**

- t_memory = Traffic / BW = 32,768 / (3.2 × 10¹¹) = 1.024 × 10⁻⁷ s = 0.1024 µs
- t_compute = FLOPs / P = 65,536 / (1.0 × 10¹³) = 6.554 × 10⁻⁹ s = 0.00655 µs
- t_memory (0.1024 µs) >> t_compute (0.00655 µs)
- **t_exec (tiled) = 0.1024 µs**
- **Bottleneck: Memory-bound**
