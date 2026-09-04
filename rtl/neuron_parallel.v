module neuron_parallel #(
    parameter DATA_WIDTH = 8,
    parameter N_INPUTS   = 32,
    parameter PARALLEL   = 8,
    parameter ACC_WIDTH  = 32
)(
    input clk,
    input rst,
    input start,

    input signed [DATA_WIDTH*N_INPUTS-1:0] x_bus,
    input signed [DATA_WIDTH*N_INPUTS-1:0] w_bus,
    input signed [DATA_WIDTH-1:0] bias,

    // Activation function applied to the final accumulator before
    // the INT8 saturate, see ACT_* localparams below. Defaults to
    // ACT_RELU (2'd1) -- the ONLY behavior this module had before
    // this port existed -- so every pre-existing caller that leaves
    // it unconnected (rtl/layer.v and its testbenches) is completely
    // unaffected.
    input [1:0] activation = 2'd1,

    // Real (runtime) input width for THIS run, in elements -- must
    // be a multiple of PARALLEL (same constraint N_INPUTS itself is
    // held to at elaboration time, just now the caller's runtime
    // responsibility instead of a build-time guard: an n_inputs_real
    // that isn't a PARALLEL multiple, or is 0, reproduces the same
    // "wrong result" / "hangs forever" failure modes documented
    // below for a bad N_INPUTS/PARALLEL pair). Defaults to N_INPUTS
    // (the full build-time width), so any caller that leaves this
    // unconnected processes every group exactly as before this port
    // existed.
    input [15:0] n_inputs_real = N_INPUTS[15:0],

    output reg signed [DATA_WIDTH-1:0] y,
    output reg busy,
    output reg done
);

    // ============================================================
    // ACTIVATION ENCODING
    // ============================================================

    localparam ACT_NONE = 2'd0; // linear: saturate both directions, no clamp
    localparam ACT_RELU = 2'd1; // max(0, x), then saturate positive (default)

    // ============================================================
    // PARAMETER GUARD
    //
    // PARALLEL must evenly divide N_INPUTS. If it does not:
    //
    //   - GROUPS = N_INPUTS / PARALLEL truncates (integer division),
    //     and the remainder inputs are silently never read by the
    //     accumulator: WRONG result, no error, no warning.
    //
    //   - If PARALLEL > N_INPUTS, GROUPS = 0 and the controller's
    //     terminal condition (group_index == GROUPS-1) is never
    //     satisfied: the neuron hangs forever (busy stays high,
    //     done is never asserted).
    //
    // Both failure modes were confirmed empirically in
    // sim/parameter_sweep_tb.v (Phase 2 of the roadmap). Rather than
    // changing the validated datapath, this forces an elaboration-
    // time failure in BOTH simulation and synthesis by instantiating
    // a deliberately undefined module when the condition is
    // violated. When N_INPUTS % PARALLEL == 0 this generate branch
    // is never elaborated, so valid configurations are unaffected.
    // ============================================================

    generate
        // BUG-002 fix (docs/validation/bugs.md): N_INPUTS=0 satisfies
        // `0 % PARALLEL == 0` for any PARALLEL, so the original
        // modulo-only check never fired for this case -- yet GROUPS
        // = 0/PARALLEL = 0 is exactly the degenerate condition this
        // guard exists to prevent. x_bus/w_bus (declared
        // [DATA_WIDTH*N_INPUTS-1:0]) also do not collapse to a true
        // zero-width vector for N_INPUTS=0 ([-1:0] is treated as a
        // real 2-bit vector by both Icarus and Yosys), confirmed to
        // leave `start` silently ineffective on both simulation and
        // real synthesis. Explicit `N_INPUTS == 0` check closes the
        // gap without changing behavior for any N_INPUTS >= 1.
        if (N_INPUTS == 0 || N_INPUTS % PARALLEL != 0) begin : PARAMETER_ERROR_N_INPUTS_NOT_MULTIPLE_OF_PARALLEL
            neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL invalid_parameter_combination();
        end
    endgenerate

    localparam GROUPS = N_INPUTS / PARALLEL;
    localparam GROUP_INDEX_WIDTH =
        (GROUPS <= 1) ? 1 : $clog2(GROUPS);

    reg [GROUP_INDEX_WIDTH-1:0] group_index;

    // Runtime group count for this run: n_inputs_real / PARALLEL.
    // PARALLEL is a build-time constant, so this divide is a fixed
    // combinational block sized once at synthesis (a shift when
    // PARALLEL is a power of two, as in every config this project
    // uses today), evaluated only at the start of a run -- not on
    // the per-group critical path.
    wire [15:0] groups_real = n_inputs_real / PARALLEL[15:0];

    reg signed [ACC_WIDTH-1:0] acc;

    wire signed [DATA_WIDTH*PARALLEL-1:0] x_group;
    wire signed [DATA_WIDTH*PARALLEL-1:0] w_group;

    wire signed [ACC_WIDTH-1:0] acc_next;

    wire signed [ACC_WIDTH-1:0] bias_ext;
    wire signed [ACC_WIDTH-1:0] final_acc;

    assign x_group =
        x_bus[
            group_index*PARALLEL*DATA_WIDTH
            +: PARALLEL*DATA_WIDTH
        ];

    assign w_group =
        w_bus[
            group_index*PARALLEL*DATA_WIDTH
            +: PARALLEL*DATA_WIDTH
        ];

    mac8 #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .PARALLEL(PARALLEL)
    ) u_mac8 (
        .x_bus(x_group),
        .w_bus(w_group),
        .acc_in(acc),
        .acc_out(acc_next)
    );

    // Sign extension INT8 -> INT32
    assign bias_ext =
        {{(ACC_WIDTH-DATA_WIDTH){bias[DATA_WIDTH-1]}}, bias};

    // Accumulazione finale + bias
    //
    // PIPELINE STAGE (timing closure, step 2): this now adds bias to
    // the ALREADY-REGISTERED `acc` (the complete sum, latched at the
    // end of the last MAC group -- see the `finishing` stage below),
    // not to `acc_next` combinationally chained onto the same cycle
    // as the last group's own MAC-tree add. Measured on real
    // place&route (see WORKLOG.md "Timing closure"): the previous
    // same-cycle chain [mac8 tree add] -> [bias add] -> [saturate]
    // was the critical path; splitting the bias-add+saturate half
    // into its own cycle (operating on a value already settled in a
    // register) breaks that chain by construction, independent of
    // synthesis/placement heuristics -- unlike the bit-test rewrite
    // below, which measurably shortens the logic but was swamped by
    // seed-to-seed placement noise on its own. Adds exactly one
    // cycle of latency per neuron (`start` to `done`), transparent
    // to every caller's busy/done handshake (neuron_memory.v,
    // layer_sequencer.v, graph_engine.v) -- no protocol change, no
    // caller-visible interface change, only one extra `finishing`
    // clock edge already absorbed by that handshake.
    assign final_acc = acc + bias_ext;

    // ============================================================
    // SATURATION / ACTIVATION -- bit-test form (timing closure)
    //
    // final_acc (ACC_WIDTH bits) fits the signed DATA_WIDTH range
    // iff bits [ACC_WIDTH-1:DATA_WIDTH-1] are all equal (all 0 ->
    // non-negative and in range, all 1 -> negative and in range) --
    // exactly what sign-extending the truncated DATA_WIDTH-bit value
    // back up to ACC_WIDTH bits would reproduce. Bit-exact
    // equivalent of the previous arithmetic comparisons in every
    // case (verified in sim/neuron_parallel_saturation_bounds_tb.v);
    // no ACT_NONE/ACT_RELU behavior change. NOTE (measured, see
    // WORKLOG.md): on this device/toolchain, Yosys's abc9 mapper
    // maps this wide AND/OR reduction onto CCU2C carry-chain cells
    // too, not a shallow LUT tree -- so on its own this rewrite only
    // trims the chain slightly (fewer CCU2C hops, ~0.2-0.9ns less
    // logic delay measured) rather than eliminating it; kept anyway
    // as a genuine, bit-exact-verified simplification, with the
    // pipeline stage above doing the real timing-closure work.
    // ============================================================

    wire final_acc_sign       = final_acc[ACC_WIDTH-1];
    wire final_acc_upper_all0 = ~(|final_acc[ACC_WIDTH-1:DATA_WIDTH-1]);
    wire final_acc_upper_all1 =  &final_acc[ACC_WIDTH-1:DATA_WIDTH-1];
    wire final_acc_in_range   = final_acc_upper_all0 | final_acc_upper_all1;
    wire final_acc_le_zero    = final_acc_sign | ~(|final_acc);

    // ACT_NONE: saturate to [-2^(DATA_WIDTH-1), 2^(DATA_WIDTH-1)-1]
    wire signed [DATA_WIDTH-1:0] y_none =
        final_acc_in_range ? final_acc[DATA_WIDTH-1:0]
                            : (final_acc_sign ? {1'b1, {(DATA_WIDTH-1){1'b0}}}
                                               : {1'b0, {(DATA_WIDTH-1){1'b1}}});

    // ACT_RELU: max(0, final_acc), then saturate positive
    wire signed [DATA_WIDTH-1:0] y_relu =
        final_acc_le_zero ? {DATA_WIDTH{1'b0}}
                           : (final_acc_upper_all0 ? final_acc[DATA_WIDTH-1:0]
                                                    : {1'b0, {(DATA_WIDTH-1){1'b1}}});

    // `finishing`: one-cycle pipeline stage between the last MAC
    // group's accumulate and the bias-add+saturate/activation step
    // (see the `final_acc` comment above). `busy` stays high through
    // it, so it is invisible to every existing start/busy/done
    // caller -- just one extra clock of latency.
    reg finishing;

    always @(posedge clk) begin

        if (rst) begin

            group_index <= 0;
            acc         <= 0;
            y           <= 0;
            busy        <= 0;
            done        <= 0;
            finishing   <= 0;

        end else begin

            done <= 0;

            if (start && !busy) begin

                group_index <= 0;
                acc         <= 0;
                busy        <= 1;

                // BUG-003 fix (docs/validation/bugs.md): with no
                // guard, n_inputs_real=0 made groups_real=0 wrap the
                // group-loop termination check to an unreachable (or,
                // depending on GROUP_INDEX_WIDTH, silently
                // full-width-processing) value -- confirmed
                // inconsistent behavior across repeated runs, never a
                // correct one. Zero real inputs has a well-defined
                // correct answer (the empty sum is 0, so
                // final_acc=bias_ext alone) -- go straight to
                // `finishing` next cycle with acc still at its
                // just-cleared 0, reusing the existing
                // activation/saturation logic unchanged instead of
                // entering the group-processing loop at all.
                finishing <= (n_inputs_real == 16'h0);

            end else if (finishing) begin

                case (activation)

                    ACT_NONE: y <= y_none; // linear: saturate both directions

                    default:  y <= y_relu; // ACT_RELU (also the fallback for any reserved encoding)

                endcase

                busy      <= 0;
                done      <= 1;
                finishing <= 0;

            end else if (busy) begin

                if (group_index == groups_real[GROUP_INDEX_WIDTH-1:0] - 1'b1) begin

                    acc       <= acc_next; // complete sum, bias not yet added
                    finishing <= 1;

                end else begin

                    acc <= acc_next;
                    group_index <= group_index + 1'b1;

                end
            end
        end
    end

endmodule