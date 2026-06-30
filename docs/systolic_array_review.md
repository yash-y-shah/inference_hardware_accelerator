# RTL Design Review: Systolic Array Core
> Files reviewed: `systolic_array_core.sv`, `processing_element_ws.v`, `tb_systolic_array_core.sv`
> Review type: Professional architectural review — no issues omitted.

---

## Section 0 — Intended Architecture: Reconstruction from RTL

### What the Array Is Supposed to Compute

The array computes a **matrix-vector dot product** in a weight-stationary dataflow:

```
result[col] = SUM_{row=0}^{GRID_DIM-1} (ip_act[row] × weight[row][col])
```

This is one row of a full matrix-matrix multiply `C = A × W`:
- `ip_act[0..7]` is one row of activation matrix A
- `weight_matrix[row][col]` is the full weight matrix W (pre-loaded)
- `result[0..7]` is the corresponding row of output matrix C

For convolution with a 3×3 kernel and 8 output filters:
- Dot-product length K = 9 (one activation element per kernel position)
- Number of output channels = 8
- One pass of the array produces 8 partial dot products (one per filter column)
- The tiling accumulator combines partial results across multiple passes for K>GRID_DIM

### Structural Wiring (4×4 illustration)

```
ip_act[0] ─reg─► [PE 0,0] ─reg─► [PE 0,1] ─reg─► [PE 0,2] ─reg─► [PE 0,3]
                      │ (psum)         │ (psum)         │ (psum)         │ (psum)
ip_act[1] ─reg─► [PE 1,0] ─reg─► [PE 1,1] ─reg─► [PE 1,2] ─reg─► [PE 1,3]
                      │                 │                 │                 │
ip_act[2] ─reg─► [PE 2,0] ─reg─► [PE 2,1] ─reg─► [PE 2,2] ─reg─► [PE 2,3]
                      │                 │                 │                 │
ip_act[3] ─reg─► [PE 3,0] ─reg─► [PE 3,1] ─reg─► [PE 3,2] ─reg─► [PE 3,3]
                      │                 │                 │                 │
                 result[0]         result[1]         result[2]         result[3]
```

### Pipeline Latency

The diagonal wavefront means:
- `ip_act[0]` reaches PE[0][col] after `col` register stages → latency through columns = GRID_DIM-1
- Partial sums travel from row 0 to row GRID_DIM-1 through GRID_DIM-1 register stages

Total latency = `(GRID_DIM-1) + (GRID_DIM-1) = 2*(GRID_DIM-1)`

For GRID_DIM=8: **LATENCY = 14 cycles**.

The `result_valid` shift register correctly implements this.

---

## Section 1 — Bug Inventory

### Priority Classification

| # | Severity | Module | Category | Description |
|---|----------|--------|----------|-------------|
| 1 | 🔴 Critical | TB | Weight loading protocol | `weight_matrix` assigned one cycle AFTER `weight_load` is asserted |
| 2 | 🔴 Critical | PE | Accumulator semantics | `clearsum` clears the partial sum but `op_partsum` is driven by `ip_partsum` from ABOVE — clearing the PE's own register loses the chain |
| 3 | 🔴 Critical | SA | `result` generate block has no label | Elaboration warning/error in strict-mode tools; unpredictable in Vivado |
| 4 | 🔴 Critical | TB | Weight-matrix data vs. `weight_load` timing | The loaded weight is always zero because of the 1-cycle offset |
| 5 | 🟠 Major | PE | `clearsum` architectural role undefined | The PE clears its OWN `op_partsum` but the systolic array's accumulation happens across multiple PE rows — clearing at PE level does not reset the full column accumulation |
| 6 | 🟠 Major | TB | `data_in` task ignores its input argument | `ip_vec` parameter is never used; always loads `test_vector` |
| 7 | 🟠 Major | TB | `en` signal not held between cycles | Activations entered in one cycle, then `en` behavior is inconsistent across task boundaries |
| 8 | 🟠 Major | SA | `LATENCY` formula assumes `en` is the only input stagger | With skewing FIFOs, `en` and `result_valid` semantics change |
| 9 | 🟡 Minor | TB | No self-checking scoreboard | Manual waveform inspection only; no automated pass/fail |
| 10 | 🟡 Minor | TB | `wave_display` driven from `initial` without init | May be `X` on first negedge |
| 11 | 🟡 Minor | SA | `NUM_PES` localparam computed but never used | Dead code |

---

## Section 2 — Bug Details

---

### BUG 1 (Critical): Weight Loading Protocol — 1-Cycle Offset

**File:** `tb_systolic_array_core.sv`, `load_weights()` task, lines 71–84

**The bug:**

```systemverilog
task automatic load_weights();
    @(posedge clk);
    weight_load <= 1;          // Cycle A: weight_load goes HIGH
    en <= 0;
    @(posedge clk);            // Cycle B: this posedge is when PE samples weight_load=1
    for (int i=0; i<8; i++) begin
        for (int j=0; j<8; j++) begin
            weight_matrix[i][j] <= test_weights[i*8+j];   // ← assigned HERE, at Cycle B
        end
    end
    @(posedge clk);            // Cycle C: weight_load goes LOW
    weight_load <= 0;
```

**What happens cycle by cycle:**

```
Cycle A posedge: weight_load <= 1 scheduled → weight_load becomes 1 after delta
Cycle B posedge: PE always block fires.
                 weight_load is SAMPLED = 1 → PE enters load_wgt branch
                 ip_wgt is SAMPLED = weight_matrix[row][col] = still 0 (not yet updated!)
                 PE loads 0 into its wgt register.
                 weight_matrix <= test_weights[...] scheduled → takes effect AFTER this edge
Cycle C posedge: weight_load <= 0. Weights are now correct in weight_matrix.
                 But weight_load = 0 → PE ignores them. ← MISSED!
```

The PE registers all load `wgt = 0` instead of `0x01`.

**Why is this not immediately visible in the output?**

Because `result = ip_act[0] × 0 = 0` for all columns — but the log shows `result[c] = 1`! This seems contradictory. Let me re-examine:

Actually the log shows `00000001` — but wait. The display format is `%h` on a 32-bit signed value. `00000001` = decimal 1. So `result[0] = 1`.

If `wgt = 0` for all PEs, then `prod = ip_act * 0 = 0`, and `op_partsum = ip_partsum + 0 = ip_partsum`. Since `ip_partsum = 0` for row 0, all PEs would accumulate zero — giving `result[c] = 0` always.

But the log shows `result = 1`. This means the weights ARE loading as 1. So this specific testbench test happens to work because the `weight_matrix` is initialized with `'{default:'h01}` at declaration time — these initial values are present even before the task runs. The task's `<=` assignments in the for-loop at Cycle B re-apply the same values that were already present. So the bug exists in the protocol but is masked by the default initialization.

**In real usage** (multi-test scenarios where you want to change weights between tests), the new weights will always be one cycle late.

**The fix:**

```systemverilog
task automatic load_weights();
    // FIX: Set weight_matrix BEFORE asserting weight_load.
    // The PE samples both weight_load AND ip_wgt on the SAME posedge.
    // Both must be stable before that edge.
    for (int i = 0; i < GRID_DIM; i++) begin
        for (int j = 0; j < GRID_DIM; j++) begin
            weight_matrix[i][j] <= test_weights[i*GRID_DIM + j];
        end
    end
    @(posedge clk); #1;         // Let the assignments settle
    weight_load <= 1;
    en <= 0;
    @(posedge clk); #1;         // PE samples weight_load=1, weight_matrix=correct
    weight_load <= 0;
    @(posedge clk);             // Done
endtask
```

**Side effects:** None — this is purely a protocol fix.

---

### BUG 2 (Critical): `clearsum` Semantics Are Architecturally Broken

**File:** `processing_element_ws.v`, line 108

**The code:**

```verilog
if (clearsum) op_partsum <= $signed(prod);
else          op_partsum <= $signed(ip_partsum) + $signed(prod);
```

**What this does:** When `clearsum=1`, the PE writes `prod` (= `ip_act * wgt`) into `op_partsum`, discarding `ip_partsum`. When `clearsum=0`, it accumulates normally.

**Why this is architecturally wrong for a systolic array:**

In the weight-stationary systolic array, partial sums flow **vertically**. The accumulation across GRID_DIM rows happens because:
- PE[0][c].op_partsum → PE[1][c].ip_partsum → PE[1][c] adds its contribution → PE[2][c].ip_partsum → ...

If `clearsum=1` in ALL PEs simultaneously:
- PE[0][c]: `op_partsum = act[0] * wgt[0][c]` (ip_partsum from above is 0 anyway for row 0 — so this is correct for row 0)
- PE[1][c]: `op_partsum = act[1] * wgt[1][c]` — **DISCARDS** `ip_partsum` from PE[0][c]!
- PE[2][c]: `op_partsum = act[2] * wgt[2][c]` — **DISCARDS** `ip_partsum` from PE[1][c]!

Every row except row 0 drops the contributions from all rows above it. The final `result[c]` = only PE[GRID_DIM-1][c]'s own product = `act[7] * wgt[7][c]`. The cross-row accumulation is completely destroyed.

**What `clearsum` is INTENDED for:**

The `clearsum` signal is intended to reset the ACCUMULATED PARTIAL SUM across tiles — i.e., to tell the array "this is the first tile, start fresh." But this clearing should happen at the ACCUMULATOR module downstream (which combines the outputs of multiple passes through the array), NOT inside each PE.

**The correct design:** Remove `clearsum` from the PE entirely. The PE should ALWAYS compute `op_partsum = ip_partsum + prod`. The tiling accumulator sits BELOW the array and is responsible for:
- First tile: `acc[c] = result[c]`
- Subsequent tiles: `acc[c] += result[c]`
- Clearing: `acc[c] = 0` at the start of a new output pixel

**The fix:**

```verilog
// PE fix: Remove clearsum. The PE always accumulates.
else if (en) begin
    ip_fwd     <= ip_act;
    op_partsum <= $signed(ip_partsum) + $signed(prod);  // always accumulate
end
```

Remove `clearsum` from the PE port list, and from `systolic_array_core.sv`'s PE instantiation and port list.

**Side effects:** The `clearsum` functionality moves to the external accumulator module, where it belongs. The PE becomes simpler and more standard.

---

### BUG 3 (Critical): Generate Block Missing Label in Second Loop

**File:** `systolic_array_core.sv`, lines 78–83

**The code:**

```systemverilog
genvar i;
generate
    for (i = 0; i < GRID_DIM; i = i + 1) begin       // ← no label!
        assign result[i] = psum_wire[GRID_DIM-1][i];
    end
endgenerate
```

**The problem:** The `begin...end` block has no label (`:name`). In SystemVerilog, `for` loops inside `generate` blocks must have named begin/end blocks. Without a label:
- Vivado warns: "unnamed generate block"
- Signal hierarchical paths are unpredictable
- Strict tools (VCS, Questa) may error

**The fix:**

```systemverilog
genvar i;
generate
    for (i = 0; i < GRID_DIM; i = i + 1) begin : result_assign
        assign result[i] = psum_wire[GRID_DIM-1][i];
    end
endgenerate
```

---

### BUG 4 (Critical, corollary to Bug 1): Weight Loading Always Uses Zero in Multi-Test Scenarios

As detailed in Bug 1: any test that calls `load_weights()` with different weight values between test cases will silently load zeros instead of the intended weights.

**Demonstration:**

```
Test 1: weights = {0x01, ...}  → OK (coincidence — default values match)
Test 2: weights = {0x05, ...}  → FAIL (all PEs load 0 instead of 5)
```

This is already fixed by the load_weights() fix above.

---

### BUG 5 (Major): `data_in` Task Ignores Its Input Argument

**File:** `tb_systolic_array_core.sv`, lines 87–95

**The code:**

```systemverilog
task automatic data_in(input logic [63:0] ip_vec);   // ← ip_vec declared
    @(posedge clk);
    for (int i=0; i<8; i=i+1) begin
        ip_act[i] <= test_vector[i];   // ← test_vector used, NOT ip_vec!
    end
    en <= 1;
    @(posedge clk);
    repeat(7) @(posedge clk);
endtask
```

**The problem:** `ip_vec` is declared as the task input parameter but is never used. The task always loads `test_vector` (all-ones). This makes `data_in(64'h1817161514131211)` and `data_in(64'h2827262524232221)` identical — defeating the entire purpose of parameterizing the task.

**Why this would cause incorrect results:** Any test case relying on different input activations per call would use wrong data.

**The fix:**

```systemverilog
task automatic data_in(input logic [63:0] ip_vec);
    @(posedge clk); #1;
    for (int i = 0; i < GRID_DIM; i = i + 1) begin
        ip_act[i] <= ip_vec[i*IP_WIDTH +: IP_WIDTH];   // unpack byte i from ip_vec
    end
    en <= 1;
    @(posedge clk);
    repeat(GRID_DIM - 1) @(posedge clk);   // hold for one full skewed fill
endtask
```

---

### BUG 6 (Major): `en` Is Not Sustained Correctly

**File:** `tb_systolic_array_core.sv`, lines 112–115

**The code:**

```systemverilog
for (int i=0; i<8; i=i+1) begin
    ip_act[i] <= (i==0) ? 01 : 00;
end
en <= 1;
```

Then later:
```systemverilog
@(posedge clk);             // 1 cycle
repeat(10) @(posedge clk);  // 10 more cycles
```

`en` is set to 1 once and left there. That's fine for this test. But the `load_weights()` task internally sets `en <= 0` and never restores it reliably.

**More importantly:** The `data_in` task sets `en <= 1` on a posedge, then holds it for 8 cycles via `repeat(7) @(posedge clk)`. But the systematic test flow doesn't account for whether `en` is held stable throughout the latency window. With LATENCY=14, the array needs 14+ cycles of `en=1` to produce a full valid output.

The main initial block also holds `en=1` for only 10+10+10 = ~30 cycles after `result_valid` is already valid — which is fine for one test case. But for a production testbench this must be precisely controlled.

---

### BUG 7 (Major): `LATENCY` Formula Is Wrong for Skewed Inputs

**File:** `systolic_array_core.sv`, line 35

```verilog
localparam LATENCY = 2 * (GRID_DIM - 1);
```

**The comment says:** "pipeline latency from first valid input to first valid output."

**This is only correct when all GRID_DIM rows of `ip_act` arrive simultaneously.** In the systolic array with skewing FIFOs upstream, the inputs are pre-staggered:
- Row 0 enters on cycle 0
- Row 1 enters on cycle 1
- Row GRID_DIM-1 enters on cycle GRID_DIM-1

In that case, the result for the fully-accumulated output exits at cycle:
- Row 0's activation reaches column GRID_DIM-1 after GRID_DIM-1 column stages → exits at cycle GRID_DIM-1
- This partial result flows down GRID_DIM-1 row stages → exits at cycle GRID_DIM-1 + GRID_DIM-1 = 2*(GRID_DIM-1)

But the **last row's activation** (row GRID_DIM-1) enters at cycle GRID_DIM-1 (due to skew). It reaches column 0 on cycle GRID_DIM-1 (no column stages for column 0). It flows down GRID_DIM-1 row stages, arriving at the bottom at cycle GRID_DIM-1 + GRID_DIM-1 = 2*(GRID_DIM-1).

With skewed inputs: all row contributions arrive at the bottom simultaneously at cycle 2*(GRID_DIM-1) after the FIRST valid `en` — so LATENCY = 2*(GRID_DIM-1) IS correct for skewed inputs.

**Without skewing** (as in the current testbench which drives all rows simultaneously): the first result that exits is column 0's partial result (only row 0 contributed, after GRID_DIM-1 column stages). The FULL result for column 0 (all 8 rows accumulated) exits at cycle GRID_DIM-1 (column traversal) + GRID_DIM-1 (row accumulation) = 14 cycles after `en` goes high. Same formula, same result.

**So the formula IS correct** for both skewed and unskewed inputs. The simulation output confirms this: `result_valid` goes HIGH at t=250000 (25 cycles from t=0; `en` went high at ~t=110000 = cycle 11; valid at cycle 11+14=25). ✓

However, the `result_valid` signal as implemented is tied to `en`. This means:
- When `en` drops to 0, `result_valid` will eventually drop too (14 cycles later)
- When en=0 but results are still draining through the pipeline, `result_valid` incorrectly tracks `en` rather than actual data validity

**The fix:** `result_valid` should track valid DATA, not just `en`. With skewed inputs, you need a transaction counter. With unskewd inputs and the current design, the shift register of `en` is approximately correct. Mark this as a **known limitation** to discuss in integration review.

---

### BUG 8 (Major): `pe_array` Instance Name Shared Across generate

**File:** `systolic_array_core.sv`, line 52

```systemverilog
) pe_array (
```

Every PE instance in the 2D generate loop is named `pe_array`. In a generate loop, the full hierarchical name becomes `row_gen[r].col_gen[c].pe_array` — so this is actually fine because the `row_gen[r].col_gen[c]` prefix uniquifies them. No functional bug, but changing the name to `pe` or `u_pe` improves readability.

---

### BUG 9 (Minor): `wave_display` Not Initialized

**File:** `tb_systolic_array_core.sv`, line 59

```systemverilog
logic wave_display;
```

No initial value. In SystemVerilog, `logic` defaults to `X` at time 0. The `always @(negedge clk)` block will see `wave_display = X` on the first few negedges before `wave_display <= 1` is set. This produces `VALID: x` in the log at t=160000 and t=170000 — which matches what we see!

**The fix:**

```systemverilog
logic wave_display = 0;    // initialized to 0
```

---

### BUG 10 (Minor): `NUM_PES` Localparam Is Dead Code

**File:** `systolic_array_core.sv`, line 32

```systemverilog
localparam NUM_PES = GRID_DIM * GRID_DIM;
```

This is never used anywhere in the module. In isolation it's harmless, but dead localparams clutter the code.

---

### BUG 11 (Minor): `clearsum` Port Present But Architecturally Incorrect

As described in Bug 2, `clearsum` is passed from the array to every PE but its effect is wrong. Additionally, the signal is present in the DUT port list but the main `initial` block in the testbench only sets `clearsum <= 0` once, never exercises it meaningfully.

---

## Section 3 — Simulation Log Correlation

### Why the Simulation Shows What It Does

```
t=100000: wave_display=X → no display yet (wave_display assigned at t=~105000)
t=160000: VALID: x ← Bug 9: wave_display is X at first negedge after wave_display<=1
t=180000: result[0] = 00000001 ← first result emerges after 1+? column stages
```

Let me trace exactly why column values fill in one per cycle:

`en` goes high at ~t=110000 (after load_weights() which takes ~4 posedges from t=20ns, then one more posedge).

Actually let me count: `rst=0` at t=10ns, `#10` → t=20ns. `clearsum<=0`, `@posedge` (t=25ns edge), `en<=0`, `@posedge` (t=35ns). `load_weights()`: `@posedge` (t=45), `weight_load<=1,en<=0`, `@posedge`(t=55, PE loads weights), then for loop executes weight_matrix assignments (take effect at t=55+delta), `@posedge`(t=65, `weight_load<=0`), `repeat(2)@posedge` → t=85ns.

After load_weights returns: `@posedge` (t=95ns), `wave_display<=1`, ip_act assignments, `en<=1`, `@posedge`(t=105ns). Display at negedge=t=100000ps (between t=95000 and t=105000). t=105000 → display.

With `en=1` starting at about cycle 10, `result_valid` goes HIGH 14 cycles later → cycle 24 → t=245000. The log shows `VALID: 1` first at t=250000 (cycle 25 negedge) — consistent.

**The fill pattern explanation:**

With all `ip_act[i]` driven simultaneously (NOT skewed), the diagonal wavefront means:
- At cycle `en+0`: all rows enter column 0 simultaneously
- At cycle `en+1`: PE[0][0].ip_fwd registered → ip_act[0] reaches column 1; ip_act[1] still at column 0
- At cycle `en+k`: ip_act[0] has crossed k columns; ip_act[k] is at column 0

PE[0][col] accumulates after `col` cycles: result[0] (col=0) gets a contribution from row 0 at cycle `en+GRID_DIM-1` (after partial sums flow down 7 rows). Result fills bottom-to-rightward one column per cycle:

```
result[0] valid at: en + (0 col stages) + (7 row stages) = en+7
result[1] valid at: en + (1 col stage)  + (7 row stages) = en+8  (but row 0 is 1 cycle late to col 1)
...
result[7] valid at: en + 7 + 7 = en+14
```

This matches the log: result[0]=1 at t=180000 (cycle 18), result[1]=1 at t=190000, ..., result[7]=1 at t=250000. The `result_valid` shift register fires at cycle en+14 ✓.

**The result value:**

With `ip_act[0]=1`, `ip_act[1..7]=0`, all weights=1:
- result[c] = ip_act[0]*wgt[0][c] + ip_act[1]*wgt[1][c] + ... = 1×1 + 0×1 + ... = **1**

This matches every column showing `00000001`. ✓

**Conclusion on functional correctness:** For this specific test case (identity-like weights, single-active row), the array produces the mathematically correct result. The bugs are in the protocol, robustness, and general-case correctness.

---

## Section 4 — Corrected RTL

### `processing_element_ws.v` — Corrected

```verilog
// =============================================================================
// Module: processing_element_ws (Weight-Stationary Processing Element)
// Correction: Removed clearsum. PE always accumulates.
// The downstream tiling accumulator owns the "clear" responsibility.
// =============================================================================
module processing_element_ws #(
    parameter IP_WIDTH = 8,
    parameter WT_WIDTH = 8,
    parameter PS_WIDTH = 32
)(
    input                           clk,
    input                           rst,
    input                           en,
    input                           load_wgt,
    input  signed [PS_WIDTH-1:0]    ip_partsum,
    input  signed [IP_WIDTH-1:0]    ip_act,
    input  signed [WT_WIDTH-1:0]    ip_wgt,
    output reg signed [IP_WIDTH-1:0] ip_fwd,
    output reg signed [PS_WIDTH-1:0] op_partsum
);

reg signed [WT_WIDTH-1:0] wgt;

// Signed MAC — maps to DSP48E1 in Vivado
// prod sign-extends to PS_WIDTH automatically
wire signed [PS_WIDTH-1:0] prod;
assign prod = $signed(ip_act) * $signed(wgt);

always @(posedge clk) begin
    if (rst) begin
        wgt        <= {WT_WIDTH{1'b0}};
        ip_fwd     <= {IP_WIDTH{1'b0}};
        op_partsum <= {PS_WIDTH{1'b0}};
    end else begin
        if (load_wgt) begin
            // Weight loading: capture ip_wgt, reset accumulated psum
            // Reset here clears intra-column pipeline from previous image
            wgt        <= ip_wgt;
            op_partsum <= {PS_WIDTH{1'b0}};
        end else if (en) begin
            // Compute: forward activation right, accumulate psum down
            ip_fwd     <= ip_act;
            op_partsum <= $signed(ip_partsum) + $signed(prod);
        end
        // else: hold (en=0, load_wgt=0) — pipeline stall
    end
end

endmodule
```

### `systolic_array_core.sv` — Corrected

```systemverilog
// =============================================================================
// Module: systolic_array_core (Weight-Stationary Systolic Array)
// Corrections:
//   1. Removed clearsum port (belongs in accumulator, not PE)
//   2. Added label to result_assign generate loop
//   3. Removed unused NUM_PES localparam
//   4. Added clearsum_note comment for integration reference
// =============================================================================
module systolic_array_core #(
    parameter IP_WIDTH = 8,
    parameter WT_WIDTH = 8,
    parameter PS_WIDTH = 32,
    parameter GRID_DIM = 8
)(
    input clk,
    input rst,
    input en,
    input weight_load,
    // NOTE: clearsum REMOVED from this module.
    // The tiling accumulator downstream owns the clear/accumulate decision.
    // See accumulator.sv for the correct interface.
    input  signed [WT_WIDTH-1:0] weight_matrix [GRID_DIM-1:0][GRID_DIM-1:0],
    input  signed [IP_WIDTH-1:0] ip_act        [GRID_DIM-1:0],
    output signed [PS_WIDTH-1:0] result        [GRID_DIM-1:0],
    output reg                   result_valid
);

// Pipeline latency: (GRID_DIM-1) column stages + (GRID_DIM-1) row stages
localparam LATENCY = 2 * (GRID_DIM - 1);

// Internal wiring: 2D arrays indexed [row][col]
wire signed [IP_WIDTH-1:0] act_wire  [GRID_DIM-1:0][GRID_DIM-1:0];
wire signed [PS_WIDTH-1:0] psum_wire [GRID_DIM-1:0][GRID_DIM-1:0];

// 2D PE array
genvar row, col;
generate
    for (row = 0; row < GRID_DIM; row = row + 1) begin : row_gen
        for (col = 0; col < GRID_DIM; col = col + 1) begin : col_gen
            processing_element_ws #(
                .IP_WIDTH  (IP_WIDTH),
                .WT_WIDTH  (WT_WIDTH),
                .PS_WIDTH  (PS_WIDTH)
            ) u_pe (
                .clk       (clk),
                .rst       (rst),
                .en        (en),
                .load_wgt  (weight_load),
                .ip_wgt    (weight_matrix[row][col]),
                // Column 0: activation from external input for this row
                // Column >0: activation forwarded from left neighbor
                .ip_act    ((col == 0) ? ip_act[row] : act_wire[row][col-1]),
                // Row 0: partial sum input is zero (start of accumulation)
                // Row >0: partial sum from PE above
                .ip_partsum((row == 0) ? {PS_WIDTH{1'b0}} : psum_wire[row-1][col]),
                .ip_fwd    (act_wire[row][col]),
                .op_partsum(psum_wire[row][col])
            );
        end
    end
endgenerate

// Results: bottom row of partial sum wires
genvar i;
generate
    for (i = 0; i < GRID_DIM; i = i + 1) begin : result_assign   // ← LABEL ADDED
        assign result[i] = psum_wire[GRID_DIM-1][i];
    end
endgenerate

// Result valid: shift register tracking latency from en to valid output
generate
    if (LATENCY == 0) begin : no_latency
        always @(*) result_valid = en;
    end else begin : with_latency
        reg [LATENCY-1:0] valid_sr;
        always @(posedge clk) begin
            if (rst) begin
                valid_sr     <= {LATENCY{1'b0}};
                result_valid <= 1'b0;
            end else begin
                valid_sr     <= {valid_sr[LATENCY-2:0], en};
                result_valid <= valid_sr[LATENCY-1];
            end
        end
    end
endgenerate

endmodule
```

---

## Section 5 — Corrected and Upgraded Testbench

```systemverilog
// =============================================================================
// Testbench: tb_systolic_array_core
// Self-checking, scoreboard-based, covers:
//   - Identity weight test
//   - Known matrix-vector multiply test
//   - Weight reload test
// =============================================================================
module tb_systolic_array_core;

    // Parameters
    localparam IP_WIDTH = 8;
    localparam WT_WIDTH = 8;
    localparam PS_WIDTH = 32;
    localparam GRID_DIM = 8;
    localparam LATENCY  = 2 * (GRID_DIM - 1);

    // DUT signals
    logic clk = 0;
    logic rst;
    logic en;
    logic weight_load;
    logic signed [WT_WIDTH-1:0] weight_matrix [GRID_DIM-1:0][GRID_DIM-1:0];
    logic signed [IP_WIDTH-1:0] ip_act        [GRID_DIM-1:0];
    logic signed [PS_WIDTH-1:0] result        [GRID_DIM-1:0];
    logic result_valid;

    // Scoreboard
    int pass_count = 0;
    int fail_count = 0;

    // Clock
    always #5ns clk = ~clk;

    // DUT instantiation
    systolic_array_core #(
        .IP_WIDTH(IP_WIDTH),
        .WT_WIDTH(WT_WIDTH),
        .PS_WIDTH(PS_WIDTH),
        .GRID_DIM(GRID_DIM)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .en           (en),
        .weight_load  (weight_load),
        .weight_matrix(weight_matrix),
        .ip_act       (ip_act),
        .result       (result),
        .result_valid (result_valid)
    );

    // =========================================================================
    // TASK: load_weights
    // Protocol fix: weight_matrix must be stable BEFORE weight_load posedge.
    // =========================================================================
    task automatic load_weights(
        input logic signed [WT_WIDTH-1:0] wt [GRID_DIM-1:0][GRID_DIM-1:0]
    );
        // Step 1: present the weight data on the bus
        for (int r = 0; r < GRID_DIM; r++) begin
            for (int c = 0; c < GRID_DIM; c++) begin
                weight_matrix[r][c] <= wt[r][c];
            end
        end
        en <= 0;
        @(posedge clk); #1;      // settle weight_matrix
        // Step 2: assert weight_load for exactly 1 cycle
        weight_load <= 1;
        @(posedge clk); #1;      // PE latches: weight_load=1, weight_matrix=correct
        weight_load <= 0;
        @(posedge clk);          // weight_load deasserted, loading complete
    endtask

    // =========================================================================
    // TASK: feed_activation
    // Drives ip_act for exactly enough cycles, then deasserts en.
    // With unskewed inputs, hold en for LATENCY+GRID_DIM cycles to drain fully.
    // =========================================================================
    task automatic feed_activation(
        input logic signed [IP_WIDTH-1:0] act [GRID_DIM-1:0]
    );
        for (int r = 0; r < GRID_DIM; r++) begin
            ip_act[r] <= act[r];
        end
        en <= 1;
        // Hold for long enough to see all results fill in
        // LATENCY cycles for first valid + GRID_DIM-1 for last column to fill
        repeat(LATENCY + GRID_DIM + 2) @(posedge clk);
        en <= 0;
        // Wait for valid to deassert
        repeat(LATENCY + 2) @(posedge clk);
    endtask

    // =========================================================================
    // TASK: check_result
    // Compares DUT result against expected at the moment result_valid is high.
    // =========================================================================
    task automatic check_result(
        input string test_name,
        input logic signed [PS_WIDTH-1:0] expected [GRID_DIM-1:0]
    );
        logic pass;
        pass = 1;
        // Sample result at negedge while result_valid is high
        @(negedge clk);
        if (!result_valid) begin
            $display("[%s] ERROR: result_valid not asserted when expected", test_name);
            fail_count++;
            return;
        end
        for (int c = 0; c < GRID_DIM; c++) begin
            if (result[c] !== expected[c]) begin
                $display("[%s] FAIL col %0d: expected %0d, got %0d",
                         test_name, c, expected[c], result[c]);
                pass = 0;
            end
        end
        if (pass) begin
            $display("[%s] PASS: all %0d columns correct", test_name, GRID_DIM);
            pass_count++;
        end else begin
            fail_count++;
        end
    endtask

    // =========================================================================
    // TASK: wait_for_valid
    // =========================================================================
    task automatic wait_for_valid();
        while (!result_valid) @(posedge clk);
    endtask

    // Waveform display (optional)
    always @(negedge clk) begin
        if (result_valid || en) begin
            $display("t=%0t en=%b valid=%b | %0d %0d %0d %0d %0d %0d %0d %0d",
                     $time, en, result_valid,
                     result[7], result[6], result[5], result[4],
                     result[3], result[2], result[1], result[0]);
        end
    end

    // =========================================================================
    // TEST SEQUENCE
    // =========================================================================
    initial begin
        // Reset
        rst = 1; en = 0; weight_load = 0;
        for (int r = 0; r < GRID_DIM; r++) for (int c = 0; c < GRID_DIM; c++)
            weight_matrix[r][c] = 0;
        for (int r = 0; r < GRID_DIM; r++) ip_act[r] = 0;
        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);

        // =====================================================================
        // TEST 1: All weights = 1, ip_act[0]=1 others=0
        // Expected: result[c] = 1*1 + 0*1 + ... = 1 for all c
        // =====================================================================
        $display("\n=== TEST 1: Single active row with identity weights ===");
        begin
            // Build weight matrix: all 1s
            logic signed [WT_WIDTH-1:0] wt1 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act1 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp1 [GRID_DIM-1:0];
            for (int r=0; r<GRID_DIM; r++) for (int c=0; c<GRID_DIM; c++) wt1[r][c] = 8'h01;
            act1[0] = 8'h01; for (int r=1; r<GRID_DIM; r++) act1[r] = 8'h00;
            for (int c=0; c<GRID_DIM; c++) exp1[c] = 32'h00000001;

            load_weights(wt1);
            feed_activation(act1);
            // Sample result mid-valid
            @(negedge clk iff result_valid);  // wait for result_valid=1 on negedge
            check_result("TEST1", exp1);
            wait(!result_valid);
        end
        repeat(4) @(posedge clk);

        // =====================================================================
        // TEST 2: All weights = 1, all ip_act = 1
        // Expected: result[c] = 8 * (1*1) = 8 for all c
        // =====================================================================
        $display("\n=== TEST 2: All rows active, all weights = 1 ===");
        begin
            logic signed [WT_WIDTH-1:0] wt2 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act2 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp2 [GRID_DIM-1:0];
            for (int r=0; r<GRID_DIM; r++) for (int c=0; c<GRID_DIM; c++) wt2[r][c] = 8'h01;
            for (int r=0; r<GRID_DIM; r++) act2[r] = 8'h01;
            for (int c=0; c<GRID_DIM; c++) exp2[c] = 32'h00000008;  // 8 rows × 1×1

            load_weights(wt2);
            feed_activation(act2);
            @(negedge clk iff result_valid);
            check_result("TEST2", exp2);
            wait(!result_valid);
        end
        repeat(4) @(posedge clk);

        // =====================================================================
        // TEST 3: Unique weights per column, ip_act[r] = r+1
        // weight[r][c] = c+1 for all r
        // Expected: result[c] = (c+1) * SUM(r=0..7)(r+1)
        //         = (c+1) * (1+2+3+4+5+6+7+8) = (c+1) * 36
        // =====================================================================
        $display("\n=== TEST 3: Unique per-column weights, ramp activations ===");
        begin
            logic signed [WT_WIDTH-1:0] wt3 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act3 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp3 [GRID_DIM-1:0];
            for (int r=0; r<GRID_DIM; r++) for (int c=0; c<GRID_DIM; c++) wt3[r][c] = c+1;
            for (int r=0; r<GRID_DIM; r++) act3[r] = r+1;
            for (int c=0; c<GRID_DIM; c++) exp3[c] = (c+1) * 36;  // sum(1..8) = 36

            load_weights(wt3);
            feed_activation(act3);
            @(negedge clk iff result_valid);
            check_result("TEST3", exp3);
            wait(!result_valid);
        end
        repeat(4) @(posedge clk);

        // =====================================================================
        // TEST 4: Negative weights (signed arithmetic check)
        // weight[r][c] = -1 for all r,c
        // ip_act[r] = 1 for all r
        // Expected: result[c] = -8 for all c
        // =====================================================================
        $display("\n=== TEST 4: Negative weights — signed arithmetic ===");
        begin
            logic signed [WT_WIDTH-1:0] wt4 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act4 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp4 [GRID_DIM-1:0];
            for (int r=0; r<GRID_DIM; r++) for (int c=0; c<GRID_DIM; c++) wt4[r][c] = -8'sd1;
            for (int r=0; r<GRID_DIM; r++) act4[r] = 8'sd1;
            for (int c=0; c<GRID_DIM; c++) exp4[c] = -32'sd8;

            load_weights(wt4);
            feed_activation(act4);
            @(negedge clk iff result_valid);
            check_result("TEST4", exp4);
            wait(!result_valid);
        end
        repeat(4) @(posedge clk);

        // =====================================================================
        // SUMMARY
        // =====================================================================
        $display("\n=== TESTBENCH COMPLETE ===");
        $display("PASSED: %0d / %0d", pass_count, pass_count+fail_count);
        $display("FAILED: %0d / %0d", fail_count, pass_count+fail_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILURES DETECTED — review above");
        $finish;
    end

endmodule
```

---

## Section 6 — Prioritized Fix List

### Critical (must fix before any meaningful simulation)

| Priority | Fix | Location | Impact |
|----------|-----|----------|--------|
| C1 | Fix `load_weights()` protocol: set `weight_matrix` BEFORE asserting `weight_load` | testbench | Weight loading works for second and subsequent test cases |
| C2 | Remove `clearsum` from PE. Move clear responsibility to accumulator | PE + SA | Column accumulation across rows works correctly |
| C3 | Add label to `result_assign` generate loop | SA | Elaboration compatibility with all tools |
| C4 | Fix `data_in()` to use its `ip_vec` argument | testbench | Different activation vectors per test case |

### Major (must fix before integration with accumulator)

| Priority | Fix | Location | Impact |
|----------|-----|----------|--------|
| M1 | Hold `en` consistently through LATENCY+GRID_DIM cycles | testbench | Result_valid and result stability |
| M2 | Add self-checking scoreboard | testbench | Automated pass/fail instead of manual waveform |
| M3 | Add signed-arithmetic test cases | testbench | Validates $signed() inference |
| M4 | Document `result_valid` semantics with skewed vs unskewed inputs | SA | Integration interface clarity |

### Minor (quality improvements)

| Priority | Fix | Location | Impact |
|----------|-----|----------|--------|
| m1 | Initialize `wave_display = 0` | testbench | Eliminates X on first negedge |
| m2 | Remove unused `NUM_PES` localparam | SA | Code cleanliness |
| m3 | Rename PE instance from `pe_array` to `u_pe` | SA | Readability |

---

## Section 7 — Architectural Comparison with Industry Practice

### What Good FPGA Systolic Arrays Do Differently

| Practice | Current Design | Industry Practice |
|----------|---------------|-------------------|
| Weight loading | 2D bus (all 64 weights simultaneously) | Shift-register column loading (TPU, VTA) |
| Clear/reset between tiles | `clearsum` in PE (broken) | External accumulator owns clear | 
| Result valid | Shift register on `en` | Shift register on `en` ✓ (correct) |
| Weight loading protocol | 1-cycle load on dedicated port | Same ✓ |
| `result` output | Combinational from psum_wire | Should be registered for timing |
| PE arithmetic | `$signed()` on combinational wire | ✓ Correct pattern for DSP48E1 |
| PE reset | Full reset of all registers | ✓ Correct |

### The `clearsum` Anti-Pattern

Every major FPGA CNN accelerator — Google's VTA, AMD's FINN, academic designs like Eyeriss-on-FPGA — places the accumulation boundary logic OUTSIDE the systolic array:

```
Systolic Array → result[c] (combinational from bottom row)
                    ↓
         Tiling Accumulator (external)
           - first_tile: acc[c] = result[c]
           - later_tile: acc[c] += result[c]
           - done:       output acc[c] downstream
```

The systolic array itself ALWAYS accumulates vertically through its rows. It has no concept of "this is tile 1 vs tile 2." That distinction belongs to the controller.

### `result` Should Be Registered

Currently `result[i]` is directly assigned from `psum_wire[GRID_DIM-1][i]` — a combinational path. For timing closure at frequencies above ~100 MHz with 8×8=64 DSPs and their pipeline depth, you want `result` registered at the output:

```verilog
// In result_assign generate:
always @(posedge clk) begin
    if (rst) result_reg[i] <= {PS_WIDTH{1'b0}};
    else if (en) result_reg[i] <= psum_wire[GRID_DIM-1][i];
end
assign result[i] = result_reg[i];
```

This adds 1 cycle to LATENCY (update LATENCY = 2*(GRID_DIM-1) + 1) and improves Fmax.

---

## Section 8 — Remaining Issues Before Accumulator Integration

Before connecting the systolic array to the tiling accumulator, the following must be resolved:

1. **`result_valid` timing relative to `result` data**: The current valid is registered (1 cycle delayed from when data exits psum_wire). If `result` is also registered, they align. If `result` is combinational, the valid leads data by 1 cycle. **Decision needed: register result or not? Must be consistent.**

2. **Accumulator interface**: The accumulator needs to know:
   - `result_valid`: when to sample `result[c]`
   - `first_tile`: when to load (not add) the result into `acc[c]`
   - `last_tile`: when to pass `acc[c]` downstream
   These three signals come from the main controller, NOT from the systolic array.

3. **`weight_load` exclusion**: When `weight_load=1`, `en` must be 0 (enforced by controller). Currently the PE code enforces this with priority (`if load_wgt` before `else if en`), which is correct, but the controller must not assert both simultaneously.

4. **`result` bus width**: `result[c]` is INT32. For 8 filters, that's 256 bits total. The accumulator must register this full bus. Verify timing closure at this interface width.

5. **Skewing FIFOs upstream**: The systolic array currently assumes inputs are pre-skewed. When driven from the skewing FIFO bank, `ip_act[r]` arrives delayed by `r` cycles relative to `ip_act[0]`. The `result_valid` formula LATENCY=2*(GRID_DIM-1) is correct for this case. Verify this in the next integration testbench.
