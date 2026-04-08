# CF01 — CMAN Workload Accounting

**Course:** ECE 410/510 — HW4AI
**Author:** Pratibha Munnangi
**Network:** 3-layer fully-connected, dimensions [784 → 256 → 128 → 10]
**Configuration:** Batch size = 1, FP32 (4 bytes per value), no bias terms

---

## (a) Per-layer MAC Table

| Layer  | Input | Output | MAC Formula | MACs    |
|--------|-------|--------|-------------|---------|
| Layer 1 | 784   | 256    | 784 × 256   | 200,704 |
| Layer 2 | 256   | 128    | 256 × 128   | 32,768  |
| Layer 3 | 128   | 10     | 128 × 10    | 1,280   |

---

## (b) Total MACs (one forward pass)

```
Total MACs = MACs(Layer 1) + MACs(Layer 2) + MACs(Layer 3)
           = 200,704 + 32,768 + 1,280
           = 234,752 MACs
```

---

## (c) Total Trainable Parameters (weights only, no biases)

For a fully-connected layer with no bias:

```
params = input_size × output_size
```

```
Total params = (784 × 256) + (256 × 128) + (128 × 10)
             = 200,704 + 32,768 + 1,280
             = 234,752 parameters
```

---

## (d) Total Weight Memory (FP32)

```
Weight memory = total params × 4 bytes
              = 234,752 × 4
              = 939,008 bytes
```

---

## (e) Total Activation Memory (FP32)

Activation memory must hold the input plus all layer outputs simultaneously:

```
Activation memory = (input + layer1_out + layer2_out + layer3_out) × 4 bytes
                  = (784 + 256 + 128 + 10) × 4
                  = 1,178 × 4
                  = 4,712 bytes
```

---

## (f) Arithmetic Intensity

```
Arithmetic Intensity = (2 × total MACs) / (weight bytes + activation bytes)

                     = (2 × 234,752) / (939,008 + 4,712)

                     = 469,504 / 943,720

                     ≈ 0.497 FLOPs/byte
```

---

## Summary

| Quantity              | Value                |
|-----------------------|----------------------|
| Total MACs            | 234,752              |
| Total Parameters      | 234,752              |
| Weight Memory         | 939,008 bytes        |
| Activation Memory     | 4,712 bytes          |
| Arithmetic Intensity  | ≈ 0.497 FLOPs/byte   |
