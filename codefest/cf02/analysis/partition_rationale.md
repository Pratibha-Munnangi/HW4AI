# HW/SW Partition Rationale — QKT Accelerator Chiplet
**ECE 410/510: Hardware for AI and ML, Spring 2026**  
**File:** `codefest/cf02/analysis/partition_rationale.md`

---

## (a) Which kernel(s) to accelerate in hardware and why the roofline supports that choice

The QKT kernel — `scores = Q @ K^T * scale` — is the sole target for hardware
acceleration. cProfile over 10 runs confirms it consumes 91% of total runtime
(0.010s out of 0.011s), making it the clear computational bottleneck. The
roofline analysis further supports this choice: with an arithmetic intensity of
2.67 FLOP/byte sitting just above the ridge point of 2.29 FLOP/byte, the kernel
is compute-bound on the i5-1235U. However, the software baseline achieves only
4.16 GFLOP/s — just 2.4% of the 176 GFLOP/s attainable ceiling — revealing a
~42× performance gap caused by Python interpreter overhead and lack of
fine-grained parallelism. A dedicated systolic MAC array eliminates this
overhead by executing all multiply-accumulate operations in parallel directly in
silicon, closing the gap to the compute ceiling.

## (b) What the software baseline will continue to handle

All operations outside the QKT kernel remain in software on the host CPU. This
includes tokenization, embedding lookup, positional encoding, Q/K/V linear
projections, softmax normalization of the attention scores, the attention
weighted sum (AV), feed-forward layers, layer normalization, loss computation,
and the Adam optimizer update. These operations are either too irregular for
fixed-function hardware (softmax, layer norm), too infrequent to justify silicon
area (embeddings), or already efficient enough in software relative to QKT.

## (c) Interface bandwidth required to avoid becoming interface-bound

The QKT kernel transfers 1.573 MB per call (Q: 262,144 bytes + K: 262,144 bytes
+ scores output: 1,048,576 bytes). The target accelerator runs at 256 GFLOP/s
with an arithmetic intensity of 2.67 FLOP/byte, implying a required interface
bandwidth of:

```
Required BW = Attainable GFLOP/s / AI
            = 256 GFLOP/s / 2.67 FLOP/byte
            = 95.9 GB/s
```

An AXI4 Stream interface at 128-bit width running at 500 MHz delivers
approximately 8 GB/s, which is insufficient for this throughput target. A
PCIe Gen4 ×4 link (~8 GB/s) would similarly bottleneck the design. To avoid
becoming interface-bound, the accelerator must use on-chip SRAM buffering
(targeting 512 GB/s internal bandwidth) and load Q/K tiles once per computation
rather than streaming them repeatedly from DRAM. The host-to-chiplet interface
only needs to sustain the data loading rate, not the full internal bandwidth.

## (d) Compute-bound or memory-bound, and whether the accelerator changes that

On the i5-1235U, the QKT kernel is compute-bound (AI = 2.67 > ridge = 2.29
FLOP/byte) but achieves only 2.4% of the attainable ceiling due to software
overhead. On the proposed accelerator (P_hw = 256 GFLOP/s, B_hw = 512 GB/s,
ridge_hw = 0.50 FLOP/byte), the kernel remains compute-bound since AI = 2.67 >
ridge_hw = 0.50. This is the desired outcome: the kernel is naturally
compute-intensive, and the accelerator is designed with sufficient on-chip
bandwidth (512 GB/s) to ensure memory access never becomes the bottleneck. The
accelerator therefore targets the compute ceiling directly, achieving a projected
1.5× improvement over the theoretical SW ceiling and a ~62× improvement over
the measured SW performance.
