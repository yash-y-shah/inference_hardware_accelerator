# RTL Design Notes: Processing Element & Systolic Array

> These notes explain every design decision in `processing_element_ws.v` and
> `systolic_array_core.sv` — the theory behind each choice, the bugs that existed,
> why they were bugs, and how they were fixed. Read this alongside the source files.

---

## Part 1: Processing Element (`processing_element_ws.v`)

### What a PE Does

A Processing Element is the atomic unit of computation. It does exactly one thing:

```
op_partsum = ip_partsum + (ip_act × wgt)
```

That's a **Multiply-Accumulate (MAC)** operation. Every neural network's inner loop
reduces to this. The PE does it in hardware, in one clock cycle, using a DSP48E1 slice.

### Bug 1 — Missing `parameter` keyword

**Old code:**
```verilog
module processing_element_ws #(
    IP_WIDTH = 8,    // ← no 'parameter' keyword
    WT_WIDTH = 8,
    PS_WIDTH = 32
)
```

**Why this is wrong:**

In Verilog/SystemVerilog, the `#( )` block after the module name is the
**parameter port list**. Every entry must explicitly say `parameter` (or
`localparam` for internal constants). Without the keyword, behavior is
tool-dependent — some tools accept it, others error, and it violates the
standard. This is a common mistake when reading examples online.

**Fixed:**
```verilog
module processing_element_ws #(
    parameter IP_WIDTH = 8,
    parameter WT_WIDTH = 8,
    parameter PS_WIDTH = 32
)
```

**Interview note:** The difference between `parameter` and `localparam`:
- `parameter`: can be overridden from outside (at instantiation time)
- `localparam`: fixed constant, cannot be overridden. Use for derived values.

---

### Bug 2 — `output wire` driven from `always` block

**Old code:**
```verilog
output [IP_WIDTH-1:0]         ip_fwd,       // ← implicitly 'wire'
output [IP_WIDTH+WT_WIDTH-1:0] op_partsum   // ← implicitly 'wire'
```

...and then in the `always` block:
```verilog
ip_fwd <= ip_act;
op_partsum <= ip_partsum + prod;
```

**Why this is wrong:**

In Verilog, there are two fundamental signal types:
- **`wire`**: driven by a continuous assignment (`assign` statement) or
  by a module port connection. It's a **combinational** connection.
- **`reg`**: driven by a procedural block (`always`, `initial`). Despite
  the name "reg", it doesn't always synthesize to a flip-flop — only when
  it's inside an `always @(posedge clk)` block.

You **cannot** use the `<=` operator (non-blocking assignment) to drive a
`wire`. The `<=` operator belongs to procedural blocks, which require `reg`.

The error message you'd see:
```
ERROR: "ip_fwd" is not a valid l-value in a procedural assignment.
Assign procedural assignments to variables (reg/integer/...).
```

**Fixed:**
```verilog
output reg signed [IP_WIDTH-1:0]  ip_fwd,
output reg signed [PS_WIDTH-1:0]  op_partsum
```

**Mental model:** Think of it this way:
- `wire` = a physical wire in silicon. You can connect two things with it, but you can't "store" a value.
- `reg` = a flip-flop. It stores a value on every clock edge.

In SystemVerilog (not Verilog), you can use `logic` for both — the tool figures out from context whether to infer a wire or a flip-flop. This is why modern RTL uses `logic` everywhere in SV.

---

### Bug 3 — Accumulator Width Mismatch (the silent data corruption bug)

This is the most dangerous bug because **it compiles without error and simulates without warning**, but produces completely wrong numerical results.

**Old code:**
```verilog
input  signed [PS_WIDTH-1:0]      ip_partsum,  // 32-bit input
output reg signed [IP_WIDTH+WT_WIDTH-1:0] op_partsum  // 16-bit output ← BUG
...
wire signed [PS_WIDTH-1:0] prod;      // 32-bit product
...
op_partsum <= ip_partsum + prod;      // 32-bit + 32-bit → TRUNCATED to 16-bit
```

**Why this is wrong — step by step:**

1. `ip_partsum` is 32 bits wide. Its value can be up to ±2,147,483,647.
2. `prod` (ip_act × wgt) is declared as 32 bits, value up to ±16,129.
3. Their sum can be up to ±2,147,499,776 — still fits in 32 bits.
4. But `op_partsum` is only `IP_WIDTH + WT_WIDTH = 8 + 8 = 16` bits wide.
5. Verilog evaluates `ip_partsum + prod` as a 32-bit expression (based on the widest operand), then **silently truncates the upper 16 bits** before storing into `op_partsum`.

**Example of the corruption:**
```
ip_partsum = 32'h0001_0000  (= 65536)
prod       = 32'h0000_0064  (= 100)
Sum        = 32'h0001_0064  (= 65636)
Stored as: 16'h0064         (= 100 — the upper 16 bits were cut off!)
```

The result looks reasonable (100), but it's completely wrong (should be 65636).
This bug would cause your neural network to produce nonsensical output — all values
would wrap around after about 32,767 — with no error anywhere in the toolchain.

**Fixed:**
```verilog
output reg signed [PS_WIDTH-1:0] op_partsum  // Now 32 bits — matches input
```

The output width must **always match** the input partial sum width, because this
output feeds the `ip_partsum` input of the PE below. It's a chain: if any link
in the chain has the wrong width, every subsequent PE computes garbage.

**Rule of thumb for accumulators:** Always size the accumulator to accommodate
the worst-case sum across all accumulation steps. For INT8 × INT8 × 9 elements:
max sum = 127 × 127 × 9 = 145,161. Needs 18 bits minimum. Use 32 bits (standard).

---

### Bug 4 — Incomplete Reset

**Old code:**
```verilog
if (rst) wgt <= 0;  // only wgt is reset
```

**Why this is wrong:**

After reset deasserts, `ip_fwd` and `op_partsum` contain **X** (unknown) in
simulation, and **random initial state** in hardware (FPGA flip-flops power up
to a known state, but after a reset, only explicitly-reset registers are
guaranteed to be 0).

In a systolic array, stale values in one PE propagate to all downstream PEs.
If the accumulator at the bottom of a column has a stale non-zero value when
the first valid computation begins, every output for that column is corrupted.

**Fixed:**
```verilog
if (rst) begin
    wgt        <= {WT_WIDTH{1'b0}};
    ip_fwd     <= {IP_WIDTH{1'b0}};
    op_partsum <= {PS_WIDTH{1'b0}};
end
```

**`{N{1'b0}}` vs `0`:** Both work, but `{PS_WIDTH{1'b0}}` is explicit about
the width and won't accidentally produce a width mismatch. `<= 0` is zero-extended
to the width of the target — fine for positive numbers but less readable and
can hide bugs with signed types.

---

### Why `$signed()` Matters

```verilog
assign prod = $signed(ip_act) * $signed(wgt);
```

Without `$signed()`:

| ip_act | ip_wgt | Without $signed() | With $signed() |
|--------|--------|------------------|----------------|
| 8'hFF (-1) | 8'h01 (+1) | 8'hFF × 8'h01 = 16'h00FF = **+255** | $signed: -1 × 1 = **-1** |
| 8'h80 (-128) | 8'h02 (+2) | 8'h80 × 8'h02 = **+256** | **-256** |

Neural network weights are signed — negative weights are essential for learning.
Without `$signed()`, your hardware computes the completely wrong multiplication
for any negative weight or activation.

**DSP48E1 inference:**

The Vivado synthesis tool recognizes this pattern:
```verilog
// In same always @(posedge clk) block:
P <= $signed(A) * $signed(B) + $signed(C);
```
and maps it to a single DSP48E1 in signed mode. The DSP48E1 has native support
for signed 18×27-bit multiplies with a 48-bit accumulator. Our 8×8 computation
sits entirely within this capability.

---

## Part 2: Systolic Array (`systolic_array_core.sv`)

### Bug 1 — `parameter` keyword and semicolons in parameter list

Same as PE. Additionally, the old code used **semicolons** between parameters:

```verilog
module systolic_array_core #(
    IP_WIDTH = 8;    // ← semicolon wrong
    WT_WIDTH = 8;    // ← semicolon wrong
```

Semicolons are **statement terminators** in Verilog (end of an always block, end of
an assign statement, etc.). Inside a parameter list, entries are separated by **commas**.
The last entry has no trailing comma. This is identical to a function argument list in C.

---

### Bug 2 — Nested `generate`/`endgenerate` (Illegal in SystemVerilog)

**Old code:**
```verilog
generate                        // outer generate
    for (i=0; i<GRID_DIM; i++) begin : systolic_pes
        genvar j;               // ← genvar inside generate
        generate                // ← INNER generate (illegal!)
            for (j=0; j<GRID_DIM; j++) begin : systolic_pes
```

**Why this is wrong:**

`generate`/`endgenerate` are block delimiters, like `begin`/`end` for a special
context. You only need ONE pair of them to wrap your entire generate region.
Inner for loops are automatically part of that generate context — they don't need
their own `generate`/`endgenerate`.

Adding an inner pair causes: `"generate blocks cannot be nested"` error.

Also: `genvar j` must be declared OUTSIDE the generate block, alongside `genvar i`.

**Fixed:**
```verilog
genvar row, col;    // declared outside generate
generate
    for (row = 0; row < GRID_DIM; row = row + 1) begin : row_gen
        for (col = 0; col < GRID_DIM; col = col + 1) begin : col_gen
            // PE instantiation here
        end
    end
endgenerate
```

---

### Bug 3 — Duplicate Generate Block Names

**Old code:**
```verilog
for (i=0; ...) begin : systolic_pes    // outer block name
    for (j=0; ...) begin : systolic_pes // inner block — SAME NAME!
```

Generate block names create **hierarchical namespaces** in the design.
The outer loop `systolic_pes[0]`, `systolic_pes[1]`, etc. must be unique.
If the inner loop has the same name, the elaborator cannot build a unique
hierarchy and errors out.

**Why names matter for debug:** In simulation, when a signal fails, the
tool reports it as `tb.dut.row_gen[2].col_gen[5].pe.wgt`. Without unique
names, you'd see `tb.dut.systolic_pes[?].systolic_pes[?].pe.wgt` — ambiguous.

**Fixed:** Use descriptive, unique names: `row_gen` and `col_gen`.

---

### Bug 4 — `load_wgt` connected to PE index (not a control signal)

**Old code:**
```verilog
.load_wgt(GRID_DIM*i+j),   // This is 8*i+j = 0,1,2,3,...,63
```

This is connecting the PE's single-bit control port to an INTEGER CONSTANT.
In Verilog, when you connect a multi-bit integer to a 1-bit port, only bit 0
of the integer is used. So:
- PE[0][0]: `load_wgt = (8*0+0)[0] = 0` → **never loads weights**
- PE[0][1]: `load_wgt = (8*0+1)[0] = 1` → **always loading weights**
- PE[0][2]: `load_wgt = (8*0+2)[0] = 0` → never loads
- PE[0][3]: `load_wgt = (8*0+3)[0] = 1` → always loading

This is physically nonsensical. The weight loading behavior would be random
and PE-position-dependent.

**Fixed:**
```verilog
.load_wgt(weight_load),   // all PEs share the same 1-bit control signal
```

---

### Bug 5 — `ip_wgt` connected to entire weight bus per PE

**Old code:**
```verilog
input [WT_WIDTH-1:0] ip_wgt [NUM_PES-1:0],   // 64-element bus
...
.ip_wgt(ip_wgt),   // ALL 64 weights sent to EVERY PE
```

**Two problems:**

**Problem A — Logical:** PE[row][col] should receive ONE weight: `W[row][col]`.
Connecting all 64 weights means each PE has 64 inputs but only uses 8 bits of it.
Which 8 bits? Ambiguous. The intent was completely undefined.

**Problem B — Physical (fanout):** If you broadcast 64×8 = 512 bits to
64 PEs simultaneously, each bit has **64 loads**. On FPGA, a single LUT output
can typically drive ~50 loads before timing degrades. This would fail timing
at any meaningful frequency.

**Fixed (2D weight bus approach):**
```verilog
input signed [WT_WIDTH-1:0] weight_matrix [GRID_DIM-1:0][GRID_DIM-1:0],
...
.ip_wgt(weight_matrix[row][col]),   // each PE gets exactly its own weight
```

Fanout per bit: 1 (only one PE receives each weight value). Clean.

---

### Bug 6 — Wrong activation input connection

**Old code:**
```verilog
.ip_act((j == 0) ? ip_act : act_fwd_chain[i + GRID_DIM*(j-1)])
```

**Problem:** For `j=0`, this uses `ip_act` (without indexing — the whole array).
But `ip_act` is a `GRID_DIM`-wide unpacked array. Passing the entire array where
a single element is expected is a type mismatch.

For `j=1, row=0`: `act_fwd_chain[0 + 8*(1-1)] = act_fwd_chain[0]` — OK.
For `j=1, row=1`: `act_fwd_chain[1 + 8*(0)] = act_fwd_chain[1]` — but this is
not the activation from the PE to the LEFT of [1][1]. The PE to the left is [1][0],
whose output should be `act_fwd_chain[1*8 + 0] = act_fwd_chain[8]`. The index `1`
is completely wrong.

**Fixed:**
```verilog
.ip_act((col == 0) ? ip_act[row] : act_wire[row][col-1])
```

The logic in English:
- If I am in the leftmost column (`col == 0`): take from external input `ip_act[row]`
- Otherwise: take from the PE to my left, which is `act_wire[row][col-1]`

The `col-1` for `col=0` would underflow, but the ternary operator prevents the
right-hand side from being evaluated when `col == 0`. Synthesis tools understand
this and generate the correct mux.

---

### Bug 7 — Wrong partial sum connection

**Old code:**
```verilog
.ip_partsum((i == 0) ? {PS_WIDTH{1'b0}} : partsum_chain[GRID_DIM*(i-1)+j])
```

For `i=0` (safe — zero is injected). But for `i=1, j=0`:
`partsum_chain[GRID_DIM*(1-1)+0] = partsum_chain[0]` — this is PE[0][0]'s output.
But PE[1][0] is directly below PE[0][0], so this is actually correct!

Wait — but the 1D index `GRID_DIM*(i-1)+j` for row-major means:
- PE directly above [row][col] is PE[row-1][col]
- In flat index: (row-1)*GRID_DIM + col = GRID_DIM*(row-1) + col ✓

This part was actually correct. But the concern was that when `i=0`, evaluating
`GRID_DIM*(0-1)+j` = `GRID_DIM*(-1)+j` = `-8+j` is a negative index,
which wraps to a huge positive value in Verilog. The ternary prevents *evaluation*
of the wrong branch, but synthesis tools may still emit it.

**Fixed:**
```verilog
.ip_partsum((row == 0) ? {PS_WIDTH{1'b0}} : psum_wire[row-1][col])
```

Now the 2D indexing makes it unambiguous and safe.

---

### Bug 8 — `op_partsum` declared as `input` (should be `output`)

**Old code:**
```verilog
input [PS_WIDTH-1:0] op_partsum [GRID_DIM-1:0],   // ← INPUT?!
```

And then:
```verilog
assign op_partsum = partsum_chain[...];   // ← driving an input
```

This is physically impossible. An `input` port receives data from OUTSIDE the module.
You cannot drive it from inside. The compiler would error: "cannot drive input port".

The naming `op_partsum` should have been the giveaway: `op_` = output, `ip_` = input.
These naming conventions are your first line of defense in catching port direction bugs.

**Fixed:**
```verilog
output signed [PS_WIDTH-1:0] result [GRID_DIM-1:0],
```

---

### Bug 9 — Scalar output `ip_fwd` (should be array)

**Old code:**
```verilog
output [IP_WIDTH-1:0] ip_fwd   // scalar — only 8 bits
```

And then:
```verilog
assign ip_fwd = act_fwd_chain[NUM_PES-1:NUM_PES-GRID_DIM];  // 8-element array slice!
```

Assigning 8 × 8 = 64 bits to an 8-bit output is a width mismatch.

In our redesign, the activation forwarding outputs are consumed entirely internally
via `act_wire`. There is no need to expose them at the module boundary — we removed
the `ip_fwd` output from the top-level ports entirely.

---

### Bug 10 — Illegal part-select of unpacked array

**Old code:**
```verilog
wire [IP_WIDTH-1:0] act_fwd_chain [NUM_PES-1:0];   // unpacked array
...
assign ip_fwd = act_fwd_chain[NUM_PES-1:NUM_PES-GRID_DIM];  // ILLEGAL
```

In Verilog, `array[high:low]` selects a **bit range** from a **packed** (contiguous)
signal. For an **unpacked** array (array of separate elements), this syntax is illegal.
You can only access individual elements: `act_fwd_chain[7]`, not `act_fwd_chain[7:0]`.

The fix: use a generate loop with individual `assign` statements, or switch to
2D indexing (as we did), which makes element access natural.

---

## Part 3: Systolic Array Architecture — The Full Picture

### The Matrix Multiply This Computes

For our Conv1 layer (3×3 kernel, 8 output channels, 1 input channel):
- Kernel size: 3×3 = 9 elements
- Input activations: a 9-element vector (one im2col window)
- Weight matrix: 9×8 (9 kernel elements × 8 output channels)
- Output: 8-element vector (one output pixel per channel)

Our 8×8 array with GRID_DIM=8:
- Processes one 8-element row of activations per cycle
- After 2 tiles (9 elements = 8 + 1), the accumulator adds tile results
- Produces result[0..7] = one complete output pixel across all 8 channels

### The Timing Diagram (4×4 for clarity)

```
Legend: A[i][k] = activation from im2col window i, element k
        W[r][c] = weight at row r, column c

Skewed input (after FIFOs):
  cycle:    0    1    2    3    4    5    6  ...
  row 0:  A[0]  A[1]  A[2]  A[3]  ...
  row 1:   0   A[0]  A[1]  A[2]  A[3]  ...
  row 2:   0    0   A[0]  A[1]  A[2]  A[3]  ...
  row 3:   0    0    0   A[0]  A[1]  A[2]  A[3]  ...

Without skewing, row 3 would arrive 3 cycles LATE relative to row 0,
meaning PE[0][3] would multiply A[3] with a partial sum that already
includes A[0], A[1], A[2] — wrong. With skewing, all activations arrive
at the correct PE at the correct time.

After LATENCY = 2*(4-1) = 6 cycles, result[0..3] are valid:
  result[col] = A[0]*W[0][col] + A[1]*W[1][col] + A[2]*W[2][col] + A[3]*W[3][col]
```

### Resource Estimate (GRID_DIM=8)

| Resource | Count | Reason |
|----------|-------|--------|
| DSP48E1 | 64 | One per PE (8×8 array) |
| Flip-Flops | ~64×(8+8+32) = ~3072 | Per PE: act_reg + wgt + psum |
| LUTs | ~200 | Control logic, muxes |
| BRAM | 0 | Weights in registers, not BRAM |

Zynq-7020 has 220 DSP48E1s. Our 64-DSP array uses 29% — plenty of headroom.

### Interview Questions and Answers

**Q: Why weight-stationary over output-stationary?**

A: Weight-stationary maximizes weight reuse. In inference, you process many images
but the weights never change. Loading weights once and streaming all 196 activation
windows through minimizes off-chip memory bandwidth for weights. Output-stationary
would require loading every weight for every output — much more memory traffic.

**Q: What is the throughput of your array?**

A: The array performs 8×8 = 64 MACs per clock cycle. At 100 MHz, that's 6.4 GMAC/s
for INT8 operations. Effective throughput for Conv1 (784 windows × 9 elements × 8 channels
= 56,448 MACs total) is 56,448 / 64 = 882 cycles ≈ 8.8 µs at 100 MHz.

**Q: What is the pipeline latency and does it matter?**

A: The pipeline latency is 2*(GRID_DIM-1) = 14 cycles. For inference on a single image,
this is negligible (14 cycles vs. 882 cycles of useful computation). It matters more
in training (where gradients must flow back through the pipeline) and in applications
requiring ultra-low latency (like HFT or autonomous vehicles). For our MNIST classifier,
it's irrelevant.

**Q: How would you scale this to a larger network?**

A: Three approaches:
1. **Tiling:** Run the current 8×8 array multiple times. Already supported via the
   accumulator module that combines tile partial sums.
2. **Larger array:** Increase GRID_DIM. Zynq-7020 supports up to ~18×18 with DSPs.
3. **Multiple arrays:** Instantiate multiple accelerator blocks in the top-level,
   each handling different output channels in parallel.

**Q: Why use a 2D weight bus instead of the TPU's shift-register loading?**

A: For this implementation, simplicity and verifiability. The TPU uses shift-register
loading because it has 256×256 = 65,536 PEs — a 2D bus would have enormous fanout.
For our 8×8 array, a 2D bus has fanout of 1 per weight bit. In a production design,
I would implement shift-register loading to minimize the weight loading bus and
allow streaming weight updates (enabling efficient batch processing of multiple
images with different weights per image, e.g., for personalization).

---

## Part 4: Verilog/SV Language Concepts — Quick Reference

### `wire` vs `reg` vs `logic`

| Type | Driven by | Used when |
|------|-----------|-----------|
| `wire` | `assign` or module output | Combinational connections |
| `reg` | `always` block | Sequential (clocked) or combinational (always_comb) |
| `logic` (SV) | Either | Recommended for all SV signals |

**Rule:** In SystemVerilog, use `logic` everywhere. In Verilog, use `reg` for `always` blocks, `wire` for `assign`.

### Packed vs Unpacked Arrays

```verilog
wire [7:0] packed_array [3:0];   // 4 elements, each 8 bits wide
// Accessing: packed_array[2]      → element 2 (8 bits)
//            packed_array[2][4:0] → lower 5 bits of element 2
//            packed_array[3:0]    → ILLEGAL (range select on unpacked)

wire [31:0][7:0] fully_packed;   // 32 bytes in a single 256-bit vector
// Accessing: fully_packed[2]      → byte 2 (8 bits) ← legal packed select
//            fully_packed[3:0]    → bytes 0-3      ← legal range select
```

Unpacked arrays cannot be range-selected. Use `generate` loops to work
with individual elements.

### Generate Block Syntax

```verilog
genvar i, j;   // declare OUTSIDE generate

generate
    for (i = 0; i < N; i = i + 1) begin : outer_name   // : name required
        for (j = 0; j < M; j = j + 1) begin : inner_name  // unique name
            // instantiation or assign here
        end
    end
endgenerate
```

### Ternary in Port Connections

```verilog
.port_name( (condition) ? value_if_true : value_if_false )
```

When `condition` involves only `genvar` and `parameter` values, it is
**statically evaluated at elaboration time**. Synthesis generates different
wiring for different instances — no actual mux is inferred. This is a standard
technique for conditional first/last element wiring in arrays.
