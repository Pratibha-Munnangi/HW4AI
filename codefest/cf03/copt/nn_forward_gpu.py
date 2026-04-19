# nn_forward_gpu.py
# CF03 COPT — Forward pass of a simple neural network on the GPU
#
# Network: 4 inputs → 5 hidden (ReLU) → 1 output (linear)
# Batch size: 16
# No training — just forward pass and shape verification.

import sys
import torch
import torch.nn as nn

# --- Step 1: Detect GPU ---
if torch.cuda.is_available():
    device = torch.device("cuda")
    print(f"CUDA GPU detected: {torch.cuda.get_device_name(0)}")
else:
    print("No CUDA GPU found. Exiting.")
    sys.exit(1)

# --- Step 2: Define the network and move to GPU ---
model = nn.Sequential(
    nn.Linear(4, 5),
    nn.ReLU(),
    nn.Linear(5, 1)
)
model.to(device)
print(f"Model moved to: {next(model.parameters()).device}")

# --- Step 3: Forward pass ---
x = torch.randn(16, 4).to(device)
print(f"Input shape : {x.shape}")
print(f"Input device: {x.device}")

output = model(x)
print(f"Output shape : {output.shape}")
print(f"Output device: {output.device}")
