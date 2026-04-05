\# ResNet-18 Profiling Analysis



\## Top 5 Layers by MAC Count



> Note: Multiple layers share the highest MAC count of 115,605,504. The first 5 in network order are listed below.



| Rank | Layer Name | Input Shape | Output Shape | MACs | Params |

|------|-----------|-------------|--------------|------|--------|

| 1 | Conv2d: 3-1 (layer1.0.conv1) | \[1, 64, 56, 56] | \[1, 64, 56, 56] | 115,605,504 | 36,864 |

| 2 | Conv2d: 3-4 (layer1.0.conv2) | \[1, 64, 56, 56] | \[1, 64, 56, 56] | 115,605,504 | 36,864 |

| 3 | Conv2d: 3-7 (layer1.1.conv1) | \[1, 64, 56, 56] | \[1, 64, 56, 56] | 115,605,504 | 36,864 |

| 4 | Conv2d: 3-10 (layer1.1.conv2) | \[1, 64, 56, 56] | \[1, 64, 56, 56] | 115,605,504 | 36,864 |

| 5 | Conv2d: 3-16 (layer2.0.conv2) | \[1, 128, 28, 28] | \[1, 128, 28, 28] | 115,605,504 | 147,456 |



\## Arithmetic Intensity — Most MAC-Intensive Layer



\*\*Layer:\*\* Conv2d 3-1 (layer1.0.conv1) — 3×3 conv, 64 input channels → 64 output channels, 56×56 feature map



\*\*MACs:\*\* 115,605,504 → \*\*FLOPs:\*\* 231,211,008



\*\*Memory (no reuse, all loaded from DRAM):\*\*

\- Weights:  3×3×64×64 × 4B = 147,456 B

\- Input activations:  64×56×56 × 4B = 802,816 B

\- Output activations: 64×56×56 × 4B = 802,816 B

\- \*\*Total: 1,753,088 B\*\*



\*\*Arithmetic Intensity = 231,211,008 / 1,753,088 ≈ 131.9 FLOPs/byte\*\*

