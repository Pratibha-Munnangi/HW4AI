from torchvision.models import resnet18
from torchinfo import summary

model = resnet18()
model.eval()
info = summary(
    model,
    input_size=(1, 3, 224, 224),
    col_names=("input_size", "output_size", "num_params", "mult_adds"),
    verbose=1
)

# Save full profile
with open("resnet18_profile.txt", "w", encoding="utf-8") as f:
    f.write(str(info))

# Top 5 Conv2d layers by MACs
layers = [(l.var_name, l.macs, l.num_params)
          for l in info.summary_list
          if 'Conv2d' in str(l.class_name) and l.macs > 0]

layers.sort(key=lambda x: x[1], reverse=True)

print("\n--- Top 5 Layers by MAC Count ---")
for i, (name, macs, params) in enumerate(layers[:5]):
    print(f"{i+1}. {name} | MACs: {macs:,} | Params: {params:,}")