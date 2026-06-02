import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import torch.quantization as quantization
import struct

# 1. Define a Simple CNN (Matches the logic you will implement in RTL)
class SimpleCNN(nn.Module):
    def __init__(self):
        super(SimpleCNN, self).__init__()
        # Conv1: 1 input channel, 16 output channels, 5x5 kernel
        self.conv1 = nn.Conv2d(1, 16, kernel_size=5)
        # Conv2: 16 input channels, 32 output channels, 5x5 kernel
        self.conv2 = nn.Conv2d(16, 32, kernel_size=5)
        self.fc1 = nn.Linear(32 * 4 * 4, 128) # 4x4 is output size after 2x pooling
        self.fc2 = nn.Linear(128, 10)
        self.relu = nn.ReLU()
        self.pool = nn.MaxPool2d(2, 2)

    def forward(self, x):
        x = self.pool(self.relu(self.conv1(x)))
        x = self.pool(self.relu(self.conv2(x)))
        x = x.view(-1, 32 * 4 * 4)
        x = self.relu(self.fc1(x))
        x = self.fc2(x)
        return x

# 2. Train the Model (Minimal training for demonstration)
print("Training simple model...")
model = SimpleCNN()
criterion = nn.CrossEntropyLoss()
optimizer = optim.SGD(model.parameters(), lr=0.01)

# Load a tiny subset of MNIST for speed (or full dataset if preferred)
transform = transforms.Compose([transforms.ToTensor(), transforms.Normalize((0.1307,), (0.3081,))])
train_loader = DataLoader(datasets.MNIST(root='./data', train=True, download=True, transform=transform), batch_size=64, shuffle=True)

for epoch in range(2): # Train for just 2 epochs for speed
    for data, target in train_loader:
        optimizer.zero_grad()
        output = model(data)
        loss = criterion(output, target)
        loss.backward()
        optimizer.step()

# 3. Post-Training Quantization (FP32 -> INT8)
# This is the critical step for FPGA implementation
print("Quantizing model to INT8...")
model.eval()
model_qconfig = quantization.get_default_qconfig('fbgemm')
model_prepared = quantization.prepare(model, inplace=False)
model_qconfig = quantization.get_default_qconfig('fbgemm')
model_prepared = quantization.prepare(model, inplace=False)
# Note: For a real project, you'd calibrate with a few samples here. 
# For this script, we assume standard quantization defaults for simplicity.
model_quantized = quantization.convert(model_prepared, inplace=False)

# 4. Extract Weights and Save as C Header
print("Exporting weights to weights.h...")
with open('weights.h', 'w') as f:
    f.write("#include <stdint.h>\n\n")
    
    # Helper to write weights
    def write_layer(name, layer):
        if hasattr(layer, 'weight'):
            w = layer.weight.detach().numpy().flatten()
            # Convert float weights to INT8 (approximate scaling for demo)
            # In a real rigorous flow, you use the quantization observer scales/zeros
            # Here we simply cast for the sake of the header format demonstration
            # *Better approach for production*: Use torch.export or manual scale extraction
            f.write(f"const int8_t {name}_weights[] = {{")
            # Simple scaling logic for demo purposes (not production grade quantization)
            # Real hardware needs exact scale/zero-point handling
            vals = [int(w * 127) for w in w] 
            f.write(", ".join(map(str, vals)))
            f.write("};\n\n")
            
        if hasattr(layer, 'bias') and layer.bias is not None:
            b = layer.bias.detach().numpy().flatten()
            f.write(f"const int8_t {name}_bias[] = {{")
            vals = [int(b * 127) for b in b]
            f.write(", ".join(map(str, vals)))
            f.write("};\n\n")

    # Write Conv and FC layers
    write_layer("conv1", model_quantized.conv1)
    write_layer("conv2", model_quantized.conv2)
    write_layer("fc1", model_quantized.fc1)
    write_layer("fc2", model_quantized.fc2)

print("Done! 'weights.h' is ready to be included in your Vitis C project.")