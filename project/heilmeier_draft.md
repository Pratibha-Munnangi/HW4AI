# Heilmeier Questions — Project Draft

**Project:** Hardware Accelerator for QKᵀ Matrix Multiplication in Transformer Self-Attention
**Author:** Pratibha Munnangi
**Course:** ECE 410/510 — Spring 2026

---

## 1. What are you trying to do?

We aim to design and implement a hardware accelerator for **QKᵀ matrix multiplication**, a core compute kernel in transformer self-attention mechanisms. This accelerator will improve execution efficiency of attention computations by:

- Parallelizing multiply-accumulate operations in hardware,
- Reducing execution time compared to software baselines, and
- Demonstrating a feasible chiplet design that can be synthesized with an open-source ASIC flow.

---

## 2. How is it done today, and what are the limits of current practice?

Today, transformer self-attention computations are typically executed on CPUs, GPUs, or high-end AI accelerators. While GPUs and dedicated AI hardware provide high performance, they are:

- **Power-hungry** and not optimized for low-power embedded acceleration.
- **General-purpose**, resulting in inefficiencies for specific kernels like QKᵀ.
- **Software dependent**, requiring optimized libraries and high memory bandwidth to achieve performance.

There is limited work demonstrating a simple, synthesizable hardware accelerator specifically for matrix multiplication kernels used in attention, especially within an academic ASIC design flow. Existing solutions may not be suitable for custom ASIC integration or detailed RTL implementation within a fixed semester timeframe.

---

## 3. What is new in your approach and why do you think it will be successful?

Our approach implements the QKᵀ kernel directly in hardware using a parallel array of MAC units and a lightweight control interface. The accelerator is structured with:

- A **parallel MAC array** to exploit hardware concurrency,
- **Local memory buffering** to reduce data movement overhead,
- A **standard host interface** (e.g., AXI-Lite).

With this design, we can achieve improved compute throughput for the attention kernel compared to a software baseline. The approach is successful because it:

1. Focuses on a well-defined, high-arithmetic-intensity kernel,
2. Maintains architectural simplicity for fast delivery, and
3. Fits naturally into an RTL-to-GDSII flow, allowing both functional verification and synthesis with open-source physical design tools.
