# Project: Neural Network Inference Accelerator on Zedboard - AMD Zynq 7000

# Overview

## **Verilog Part**

- Systolic Array - 2D grid (8x8) of PEs, each PE has a multiplier, accumulator, and internal registers. neural network weights are pre-loaded into the registers of the PEs
- Im2Col (Image-to-Column) Memory - An RTL block using BRAM as FIFOs - flattens the 2D overlapping convolution windows into 1D vectors, and feeds them to Systolic Array as continuous matrices.
- Activation function (ReLU) Datapath - Truncation logic and a simple conditional multiplexer.

## **Role of ARM Cortex-A9 Processor**

If i have no SD card, i will use Xilinx Vitis debugger to push compiled .elf (C code executable) directly into the ZedBoard SRAM via JTAG.

## **The C Code:**

- Initialize the UART driver to listen to your laptop.
- Write the received image bytes into the DDR3 memory
- Initialize the Xilinx AXI DMA engine, pass the source and destination DDR3 address, and the transfer length.
- Trigger the DMA - takes data from DDR3, converts it to an AXI-Stream, and gives to Verilog array
- Wait for the DMA "Transfer Complete" hardware interrupt.
- Read the resulting classification from DDR3 and printf it back to the UART terminal.

## Model

- pre-trained PyTorch model for the MNIST or CIFAR-10 dataset.
- Write a Python script to perform Post-Training Quantization (PTQ) to convert all FP32 weights to INT8 - Export as a weights.h
- Concepts covered: AXI, DMA, RTL, Pipelining, Systolic Arrays, Hardware-Software Co-Design, and Timing Closure

# Complete Project Decomposition

### **1. ARM Cortex-A9 Software (Bare-Metal C)**

Role: Acts as the host controller. Initializes DMA, orchestrates Python-UART communication, manages DDR3 memory buffers.

Dependencies: xaxidma.h, xparameters.h, xuartps.h.

I/O: Receives image via UART, pushes to DDR3 via CPU, pushes to PL via DMA.

Implementation Difficulty: Low. (Already largely completed).

Testing Difficulty: Medium. Requires physical hardware to test UART stability and cache invalidations.

### **2. AXI4-Stream Top-Level Wrapper**

Role: The protocol bridge. Translates AXI handshakes (tvalid, tready, tlast) into internal accelerator enable signals.

Dependencies: Zynq PS reset/clock generation.

I/O: 32-bit AXI-Stream in/out.

Implementation Difficulty: High. Managing backpressure without dropping data packets is notoriously difficult.

Testing Difficulty: High. Requires AXI Verification IP (VIP) in simulation.

### **3. Im2Col (Image-to-Column) BRAM Buffers**

Role: Caches incoming streamed pixels and flattens $3 \times 3$ sliding windows into continuous 1D data streams to feed the systolic array continuously.

Dependencies: Vivado Block Memory Generator (Dual-Port RAM).

I/O: Streamed pixel inputs, parallel vector outputs.

Implementation Difficulty: High. Requires complex read/write pointer management to handle overlapping convolution strides.

Testing Difficulty: Medium. Can be fully simulated using standard Verilog testbenches.

### **4. Weight-Stationary Systolic Array (16x16)**

Role: The compute core. A grid of Processing Elements (PEs) that propagates activations horizontally and partial sums vertically.

Dependencies: None (pure combinational/sequential logic).

I/O: 16-element activation vector in, 16-element partial sum vector out.

Implementation Difficulty: Medium. Heavy use of generate blocks and skewed shift-registers.

Testing Difficulty: Low/Medium. Highly deterministic math; easily verified in Vivado simulation.

### **5. MAC Processing Elements (PE)**

Role: Computes (Activation * Weight) + Partial_Sum.

Dependencies: DSP48E1 slices (inferred by synthesis).

I/O: 8-bit INT8 inputs, 32-bit accumulator outputs.

Implementation Difficulty: Low. Basic synchronous math.

Testing Difficulty: Low.

### **6. ReLU & Requantization Logic**

Role: Truncates the 32-bit accumulated sum back to 8-bit INT8 and clamps negative values to zero.

Dependencies: Systolic Array output.

I/O: 32-bit array in, 8-bit array out.

Implementation Difficulty: Low. Simple bit-shifting and multiplexing.

Testing Difficulty: Low.

This is the **foundational mathematical operation** your hardware accelerator must perform. Understanding this transformation is critical because it defines the **Input Matrix** for your Im2Col block and the **Weight Matrix** for your Systolic Array.

Here is the rigorous, step-by-step breakdown of the $3 \times 3$ Convolution with Stride 2 and Padding 1 on a $28 \times 28$ input.

---

### 1. The Mathematical Formula

The core operation is a **discrete 2D cross-correlation** (often called convolution in deep learning).

For a single output pixel $Y[i, j]$ at row $i$ and column $j$, and a single filter $k$:

$$
Y_k[i, j] = \text{Activation} \left( \sum_{r=0}^{2} \sum_{c=0}^{2} \left( \text{Input}[2i + r, 2j + c] \times \text{Weight}_k[r, c] \right) + \text{Bias}_k \right)
$$

**Key Variables:**
*   **Input:** $28 \times 28$ matrix (Zero-padded to $30 \times 30$).
*   **Filter ($W_k$):** $3 \times 3$ matrix of learned weights.
*   **Stride ($S$):** 2. This means we jump **2 pixels** in the input for every **1 pixel** in the output.
*   **Padding ($P$):** 1. We add a border of zeros around the $28 \times 28$ image to make it $30 \times 30$, ensuring the edges are processed.
*   **Output Size ($H_{out}$):** Calculated as $\lfloor \frac{H_{in} + 2P - K}{S} \rfloor + 1$.
    *   $\lfloor \frac{28 + 2(1) - 3}{2} \rfloor + 1 = \lfloor \frac{27}{2} \rfloor + 1 = 13 + 1 = \mathbf{14}$.

---

### 2. The "Padding" Step (Preprocessing)

Before any math happens, the hardware must handle the border.

*   **Input:** $28 \times 28$ (Indices $0 \dots 27$).
*   **Padded Input:** $30 \times 30$ (Indices $-1 \dots 28$, where $-1$ and $28$ are zeros).

**Visual Representation of the Padded Grid:**
```text
   0  1  2 ... 27 28 29
0  .  .  .  .  .  .  .  (Row -1: All Zeros)
1  .  I  I  I ... I  I  (Row 0 of original input)
2  .  I  I  I ... I  I
...
28 .  I  I  I ... I  I  (Row 27 of original input)
29 .  .  .  .  .  .  .  (Row 28: All Zeros)
```
*Why?* Without padding, a $3 \times 3$ kernel centered on pixel $(0,0)$ would hang off the edge. Padding ensures the kernel can be centered on every original pixel.

---

### 3. The Sliding Window (Stride 2)

This is the most critical part for your **Im2Col** logic. The kernel does not move 1 step at a time; it **jumps 2 steps**.

#### Step-by-Step Execution for Filter 1 ($k=0$):

**Iteration 1: Output Pixel $(0, 0)$**
*   **Target Output:** $Y[0, 0]$.
*   **Kernel Position:** Top-left corner of the padded image.
*   **Input Region Covered:** Rows $0, 1, 2$ and Columns $0, 1, 2$ of the *padded* image.
    *   *Note:* Since padding is 1, this region includes the top-left corner of the original image (indices $0,0$ to $2,2$) plus the zero-padding on the top and left.
*   **Operation:**
    $$
    \text{Sum} = \sum_{r=0}^{2} \sum_{c=0}^{2} (\text{Input}[r, c] \times W[r, c])
    $$
*   **Result:** $Y[0, 0] = \text{ReLU}(\text{Sum} + \text{Bias})$.

**Iteration 2: Output Pixel $(0, 1)$**
*   **Target Output:** $Y[0, 1]$.
*   **Stride Jump:** Move **2 columns** to the right.
*   **Kernel Position:** Centered at original pixel $(0, 2)$.
*   **Input Region Covered:** Rows $0, 1, 2$ and Columns $2, 3, 4$.
*   **Operation:**
    $$
    \text{Sum} = \sum_{r=0}^{2} \sum_{c=0}^{2} (\text{Input}[r, c+2] \times W[r, c])
    $$
*   **Result:** $Y[0, 1] = \text{ReLU}(\text{Sum} + \text{Bias})$.

**Iteration 3: Output Pixel $(0, 2)$**
*   **Target Output:** $Y[0, 2]$.
*   **Stride Jump:** Move **2 columns** to the right.
*   **Kernel Position:** Centered at original pixel $(0, 4)$.
*   **Input Region Covered:** Rows $0, 1, 2$ and Columns $4, 5, 6$.

... (This continues until column 13) ...

**Iteration 14: Output Pixel $(0, 13)$**
*   **Target Output:** $Y[0, 13]$.
*   **Kernel Position:** Centered at original pixel $(0, 26)$.
*   **Input Region Covered:** Rows $0, 1, 2$ and Columns $26, 27, 28$.
    *   *Note:* Column 28 is the right-side zero-padding.

**Next Row:** Move **2 rows** down.
**Iteration 15: Output Pixel $(1, 0)$**
*   **Target Output:** $Y[1, 0]$.
*   **Kernel Position:** Centered at original pixel $(2, 0)$.
*   **Input Region Covered:** Rows $2, 3, 4$ and Columns $0, 1, 2$.

---

### 4. The Im2Col Transformation (Hardware View)

Your FPGA does not have nested `for` loops. It uses the **Im2Col** block to flatten this process into a matrix multiplication.

**The Transformation Logic:**
The hardware scans the padded $30 \times 30$ image and extracts every $3 \times 3$ block defined by the stride.

1.  **Total Windows:** $14 \times 14 = 196$ windows.
2.  **Window Size:** $3 \times 3 = 9$ pixels.
3.  **The Matrix:**
    *   **Row 0:** Flattened pixels of Window $(0,0)$.
    *   **Row 1:** Flattened pixels of Window $(0,1)$.
    *   ...
    *   **Row 195:** Flattened pixels of Window $(13,13)$.

**Visualizing the Im2Col Output Matrix ($M_{im2col}$):**

| Row Index | Window Location | Padded Image Pixels Extracted (Flattened) |
| :--- | :--- | :--- |
| **0** | $(0,0)$ | $P[0,0], P[0,1], P[0,2], P[1,0], \dots, P[2,2]$ |
| **1** | $(0,1)$ | $P[0,2], P[0,3], P[0,4], P[1,2], \dots, P[2,4]$ |
| **2** | $(0,2)$ | $P[0,4], P[0,5], P[0,6], P[1,4], \dots, P[2,6]$ |
| ... | ... | ... |
| **13** | $(0,13)$ | $P[0,26], P[0,27], P[0,28], \dots, P[2,28]$ |
| **14** | $(1,0)$ | $P[2,0], P[2,1], P[2,2], P[3,0], \dots, P[4,2]$ |

**Resulting Dimensions:**
$$
M_{im2col} = \mathbf{196 \times 9}
$$
*   **196 Rows:** One for every output spatial position.
*   **9 Columns:** The 9 pixels in the kernel window.

---

### 5. The Systolic Array Execution

Now, the hardware performs the multiplication.

**Weight Matrix ($W$):**
For a single filter, the weights are also flattened into a column vector.
$$
W_{flat} = \begin{bmatrix} w_{0,0} \\ w_{0,1} \\ \vdots \\ w_{2,2} \end{bmatrix} \quad (\text{Dimensions: } 9 \times 1)
$$

**The Matrix Multiplication (GEMM):**
$$
\text{Output}_{single\_filter} = M_{im2col} \times W_{flat}
$$
$$
\begin{bmatrix} 196 \times 9 \end{bmatrix} \times \begin{bmatrix} 9 \times 1 \end{bmatrix} = \begin{bmatrix} 196 \times 1 \end{bmatrix}
$$

**The Result:**
A vector of 196 values. Reshaped to $14 \times 14$.
This is the **Feature Map** for Filter 0.

**Repeating for 8 Filters:**
Since you have 8 filters, you perform this operation 8 times (or in parallel if you have 8 systolic arrays).
$$
\text{Total Output} = \text{Reshape}(196 \times 1) \rightarrow 14 \times 14 \times 8
$$

---

### 6. Hardware Implementation Implications

This mathematical breakdown dictates your RTL design:

1.  **Im2Col Logic (BRAM FSM):**
    *   Must read the $30 \times 30$ padded image.
    *   Must calculate the **non-linear stride** addresses: `addr = (row * 30 + col) + (offset)`.
    *   Must handle the **overlap**: Notice that `Row 0` and `Row 1` share pixels (e.g., `P[0,2]` is in both). The hardware must read the same memory location twice. This is why BRAM (dual-port) or a cache is needed.

2.  **Systolic Array Input:**
    *   The array must accept a stream of 9 values per "row" of the Im2Col matrix.
    *   The **Weight Stationary** logic must load 9 weights into the 9 columns of the array (using tiling if the array is smaller, e.g., 8x8).

3.  **Data Reuse:**
    *   In the Im2Col matrix, pixel `P[0,2]` appears in Row 0, Row 1, Row 14 (next row of windows), etc.
    *   If you had **Line Buffers** instead of Im2Col, you would store the image rows in BRAM and shift them.
    *   With **Im2Col**, you are explicitly duplicating data in the matrix to simplify the multiply logic. This is the **Space-Time Tradeoff**: More BRAM usage (duplicated data) for simpler Control Logic (no complex shifting logic).

### Summary of the Flow

1.  **Input:** $28 \times 28$ Image.
2.  **Pad:** Add 1 pixel zero border $\rightarrow$ $30 \times 30$.
3.  **Slide:** Move $3 \times 3$ window, jumping 2 pixels at a time.
    *   Total windows: $14 \times 14 = 196$.
4.  **Flatten:** Convert each $3 \times 3$ window into a $1 \times 9$ vector.
5.  **Stack:** Create $196 \times 9$ matrix.
6.  **Multiply:** $196 \times 9$ (Im2Col) $\times$ $9 \times 8$ (Weights) $\rightarrow$ $196 \times 8$.
7.  **Reshape:** $196 \times 8 \rightarrow 14 \times 14 \times 8$.
8.  **Output:** $14 \times 14 \times 8$ Feature Map.

# Project History and Design Specification

## Project Overview

Project Title:

Neural Network Inference Accelerator on AMD Zynq-7000 FPGA

Target Platform:

Originally:

* Digilent ZedBoard (Zynq-7020)

Current Target:

* Digilent PYNQ-Z1 (Zynq-7020)

Primary Objective:

Design and implement a complete hardware accelerator for convolutional neural network (CNN) inference using SystemVerilog RTL on the programmable logic (PL) of the Zynq-7000 SoC, while using the ARM Cortex-A9 processing system (PS) for accelerator control, DMA management, and benchmarking.

The project emphasizes:

* RTL design
* FPGA architecture
* Digital VLSI concepts
* Computer architecture
* Hardware-software co-design
* Accelerator architecture
* Embedded systems
* ASIC-oriented design methodology

The implementation is intentionally educational: every RTL module is designed from scratch rather than relying on vendor IP wherever practical.

---

## Design Philosophy

The project is optimized for:

* deep understanding rather than fastest implementation
* parameterizable RTL
* reusable architecture
* interview readiness
* resume value
* industry-standard engineering practices

Every architectural decision is expected to be technically defensible during interviews.

The implementation avoids unnecessary abstraction and instead focuses on exposing important architectural concepts such as:

* memory hierarchy
* dataflow architecture
* systolic computation
* AXI protocols
* DMA
* timing closure
* BRAM inference
* parameterized RTL
* hardware/software partitioning

---

## Target CNN

Dataset:
MNIST

Data Type:

* INT8 activations
* INT8 weights
* INT32 accumulators

Network:

Layer 1
Input:
28×28×1

Convolution:
3×3

Filters:
8

Padding:
1

Activation:
ReLU

Output:
28×28×8

---

Layer 2

MaxPool

2×2

Stride 2

Output:
14×14×8

---

Layer 3

Input:
14×14×8

Convolution:
3×3

Filters:
16

Padding:
0

Activation:
ReLU

Output:
12×12×16

---

Layer 4

MaxPool

Output:
6×6×16

Flatten:
576

---

Layer 5

Fully Connected

576 → 10

Output:
classification logits

---

## Accelerator Architecture

Complete accelerator pipeline:

Input Image

↓

AXI DMA

↓

AXI4-Stream

↓

ip_stream_controller

↓

input_bram

↓

im2col

↓

skewing FIFOs

↓

weight-stationary systolic array

↓

tiling accumulator

↓

bias addition

↓

ReLU

↓

quantization

↓

classification output

---

## Module Responsibilities

### ip_stream_controller

Responsibilities:

* receive AXI4-Stream from AXI DMA
* unpack 32-bit words into 8-bit pixels
* generate write interface for BRAM
* manage transfer completion
* provide synchronization with downstream modules

Key Concepts:

* AXI4-Stream protocol
* DMA integration
* packet handling
* handshake logic
* BRAM write interface

---

### input_bram

Simple Dual-Port inferred Block RAM.

Responsibilities:

* image storage
* write interface from stream controller
* read interface for Im2Col

Features:

* inferred RAMB18 primitives
* parameterized dimensions
* bank selection using MSB
* synchronous read behavior

---

### im2col

Responsibilities:

* generate convolution windows
* convert spatial image representation into matrix representation
* parameterized kernel size
* parameterized image dimensions
* output vectors for systolic array

Major architectural learning:

* address generation
* nested counters
* sliding windows
* memory traversal
* parameterized RTL

---

### skewing FIFOs

Responsibilities:

* temporal alignment
* wavefront generation
* delay activations before entering systolic array

Purpose:

Provide correct timing relationship between processing elements.

---

### Systolic Array

Architecture:

Weight-stationary

Processing Elements:

parameterized grid

Each PE:

* multiplier
* accumulator
* registers

Concepts:

* matrix multiplication
* weight reuse
* activation propagation
* partial sums
* spatial computation

---

### Accumulator

Responsibilities:

* combine tiled partial sums
* produce complete outputs
* support layers larger than the systolic array dimensions

---

### Bias + ReLU + Quantization

Responsibilities:

* add learned bias
* perform ReLU
* quantize back to INT8

---

## Hardware/Software Partitioning

Programmable Logic

* accelerator pipeline
* BRAM
* dataflow
* computation

Processing System

* DMA initialization
* accelerator control
* UART
* benchmarking
* inference orchestration

Software Stack:

Bare-metal C using AMD Vitis.

Reason:

Maximum control over

* cache coherency
* physical memory
* DMA
* interrupts
* performance measurement

while minimizing project risk.

---

## Verification Philosophy

Every module is verified individually before integration.

Verification methodology includes:

* self-checking testbenches
* scoreboards
* assertions where appropriate
* corner-case testing
* integration testing

Simulation is used to validate:

* functionality
* interfaces
* timing assumptions

Hardware is used to validate:

* DMA integration
* synthesis
* timing closure
* performance
* end-to-end execution

---

## Engineering Goals

The project is intended to demonstrate:

* RTL design
* FPGA implementation
* accelerator architecture
* hardware/software co-design
* computer architecture
* parameterized SystemVerilog
* verification methodology
* performance optimization

The design should be sufficiently rigorous to withstand technical discussion during interviews for FPGA, ASIC, RTL, accelerator, and digital hardware roles.


This is the exact data flow your **Im2Col** and **Systolic Array** modules must implement.