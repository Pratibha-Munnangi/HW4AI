# Interface Selection — QKT Accelerator Chiplet
**ECE 410/510: Hardware for AI and ML, Spring 2026**
**Milestone M1 — Interface Selection and Bandwidth Analysis**


---

## 1. Host Platform Assumption

**Assumed host:** FPGA SoC development platform (e.g., Xilinx Zynq
UltraScale+ MPSoC or Intel Agilex SoC), with a hard ARM Cortex-A
processor subsystem (PS) connected to the programmable logic (PL)
through the ARM AMBA AXI fabric.

This is the realistic target for a synthesizable, OpenLane-compatible
chiplet design in an academic ASIC flow: the interface is industry
standard, well documented, and directly usable in both FPGA
co-simulation (Week 5 onward, per the project schedule) and ASIC
tape-out flows.

## 2. Interface Choice

**Selected interface: AXI4-Stream (data plane) + AXI4-Lite (control plane).**

| Interface | Role | Rationale |
|---|---|---|
| AXI4-Lite | Control, status, register map | Low-complexity bus for start/done handshake, configuration registers (B, H, T, d_head), and result readback pointers. |
| AXI4-Stream | Q/K tile loading and scores output | Unidirectional streaming; natural fit for tile-based matrix transfers. Backpressure via TREADY/TVALID handles buffer-full conditions cleanly. |

This pairing is the standard FPGA SoC pattern: AXI4-Lite for the
control path, AXI4-Stream for the data path.

## 2.5 Why This Interface Is Appropriate for the Assumed Host

The Mar 29 project specification requires the interface justification
to address *why this interface is appropriate for the assumed host
platform*. Four reasons:

**(a) AXI is the native PS↔PL interconnect on every modern FPGA SoC.**
Both Xilinx (Zynq-7000, Zynq UltraScale+, Versal) and Intel (Cyclone V
SoC, Agilex SoC) expose their hard processor subsystems to the
programmable logic through AXI master and slave ports. Choosing AXI
means **zero glue logic** between the host PS and the chiplet — the
accelerator drops directly onto an AXI bus already present in the
silicon. Any other interface choice (SPI, I²C, PCIe) would require an
additional bridge.

**(b) AXI4-Stream is supported end-to-end by vendor DMA infrastructure.**
Xilinx provides the AXI DMA and AXI Datamover IP cores; Intel provides
the equivalent in the modular Scatter-Gather DMA. These engines move
data from DRAM into AXI4-Stream and back without any custom
host-driver code beyond a memory-mapped register write. This makes
the M3 co-simulation and the M4 benchmark realistically achievable in
the time budget; a custom interface would consume that budget on
plumbing rather than on the accelerator itself.

**(c) AXI4-Lite is the standard idiom for FPGA accelerator control.**
Every published FPGA accelerator reference design (Xilinx Vitis,
Intel oneAPI for FPGA, the OpenCL-on-FPGA frameworks) uses AXI4-Lite
for the control register interface. A grader, examiner, or future
collaborator will recognize the pattern instantly. SystemVerilog
AXI4-Lite slave templates are widely available and well-verified,
which reduces the verification burden at M2.

**(d) The other interface choices are clear mismatches for this target.**
Briefly, by elimination:

- **SPI / I²C** are designed for MCU-class hosts with kbit/s–Mbit/s
  workloads. They are off by 4–6 orders of magnitude for a
  256 GFLOP/s accelerator and would force an absurd serialization
  cost. Eliminated.
- **PCIe Gen3/4** is appropriate for *discrete* accelerator cards
  attached to an x86 server. The assumed host here is a *FPGA SoC*
  with the PS already on-die — running PCIe between two on-die blocks
  would be architectural overkill, would consume substantial PL area
  for the PCIe endpoint controller, and would not synthesize cleanly
  in OpenLane at this scale. Eliminated.
- **UCIe** is a chiplet-to-chiplet protocol intended for advanced
  silicon-interposer packaging. It is primarily a paper-architecture
  choice at this course scale (per the project document's own
  "Primarily an architectural study at this scale" note). Eliminated.

AXI4-Stream + AXI4-Lite is the **Goldilocks choice** for an FPGA SoC
host: high enough bandwidth to expose real interface-bound tradeoffs
(see Section 5), low enough complexity to be implementable and
verifiable inside a one-term project, and natively supported by every
host platform a 510-level student is realistically targeting.

## 3. Bandwidth Requirement Calculation

Target operating point for the accelerator:

```
P_hw    = 256 GFLOP/s  (16×16 systolic MAC array @ 500 MHz)
AI_QKT  = 2.67 FLOP/byte
```

Required **external** data-delivery bandwidth to keep the accelerator
compute-bound rather than interface-bound:

```
BW_required = P_hw / AI
            = 256 GFLOP/s / 2.67 FLOP/byte
            = 95.9 GB/s
```

This is the bandwidth needed at the chiplet boundary (host → chiplet)
to sustain 256 GFLOP/s of QKT compute.

## 4. Interface Rated Bandwidth

AXI4-Stream bandwidth at the chosen operating parameters:

```
Bus width  = 128 bits = 16 bytes
Clock      = 500 MHz  (matches accelerator clock)
BW_AXIS    = 16 B × 500e6 /s = 8 GB/s
```

AXI4-Lite control traffic is negligible (register writes at kernel
launch; <1 KB per call) and is not bandwidth-limiting.

## 5. Bottleneck Status — Design IS Interface-Bound

Comparison:

| Metric | Value |
|---|---|
| Required BW (for 256 GFLOP/s sustained) | 95.9 GB/s |
| AXI4-Stream rated BW (128-bit @ 500 MHz) | 8 GB/s |
| **Shortfall** | **~12× below requirement** |

If Q and K were streamed from the host on every call, the accelerator
would be **interface-bound at approximately 8 GB/s × 2.67 FLOP/B
= 21.4 GFLOP/s** — only 8.4% of the 256 GFLOP/s compute roof.

## 6. Mitigation: On-Chip SRAM Buffering

The design avoids interface-bound operation by **loading Q and K tiles
into on-chip SRAM once per kernel call and reusing them for the full
T×T score computation**. The total transfer per call is 1.573 MB
(Q + K + scores). At 8 GB/s this transfer takes:

```
t_transfer = 1.573 MB / 8 GB/s ≈ 197 µs
t_compute  = 4.194 MFLOPs / 256 GFLOP/s ≈ 16.4 µs
```

Transfer time dominates compute time by ~12×. Two strategies close this gap:

1. **Double-buffering:** overlap tile transfer (cycle N+1) with
   compute (cycle N), hiding the transfer cost when kernels are called
   back-to-back in a transformer forward pass.
2. **Widen AXI4-Stream:** a 512-bit bus at 500 MHz delivers 32 GB/s
   (~4× improvement) at modest area cost. A 1024-bit bus would reach
   64 GB/s.

Even with these, the interface remains the bottleneck for single-shot
kernel calls — the **effective throughput at the chiplet boundary is
bounded by the interface, not by the compute array**, and this is
explicitly documented as the primary limitation of the M1 design point.

## 7. Summary

| Item | Value |
|---|---|
| Host platform | FPGA SoC (Zynq/Agilex-class) |
| Data interface | AXI4-Stream, 128-bit @ 500 MHz |
| Control interface | AXI4-Lite |
| Rated data BW | 8 GB/s |
| Required BW (compute-bound target) | 95.9 GB/s |
| **Bottleneck** | **Interface-bound by ~12×** |
| Mitigation | On-chip SRAM tile buffering + double-buffering; optional wider AXIS bus |
| Effective throughput (single-shot, no overlap) | ~21 GFLOP/s (interface-limited) |
| Effective throughput (with full overlap, amortized) | approaches 256 GFLOP/s compute roof |
