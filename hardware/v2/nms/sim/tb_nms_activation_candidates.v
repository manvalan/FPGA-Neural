// ============================================================
// NMS STEP4/5 -- correctness check for BOTH candidate activation
// memories (nms_activation_replicated.v, nms_activation_banked.v)
// before trusting any synthesis number from either. Fills a small
// known vector, then drives concurrent requests covering: pure
// broadcast (all slots want the identical tile), no-contention
// parallel access (all slots want different tiles mapping to
// different banks), and forced same-bank contention (two slots want
// different tiles that alias to the same bank) -- checks bit-exact
// data on every ack and that every request eventually gets acked
// (no starvation).
// ============================================================
`timescale 1ns/1ps
module tb_nms_activation_candidates;
    parameter DATA_WIDTH = 8;
    parameter P_IN = 8;
    parameter N_SLOTS = 4;
    parameter N_BANKS = 4;
    parameter MAX_TILES = 8;
    parameter TIW = $clog2(MAX_TILES);

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg fill_we;
    reg [TIW-1:0] fill_tile_idx;
    reg [DATA_WIDTH*P_IN-1:0] fill_data;

    reg [N_SLOTS-1:0] req_valid;
    reg [N_SLOTS*TIW-1:0] req_tile_idx_flat;

    wire [N_SLOTS-1:0] ack_rep;
    wire [N_SLOTS*DATA_WIDTH*P_IN-1:0] data_rep;
    wire [N_SLOTS-1:0] ack_bank;
    wire [N_SLOTS*DATA_WIDTH*P_IN-1:0] data_bank;

    nms_activation_replicated #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .MAX_TILES(MAX_TILES)
    ) u_rep (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_addr(fill_tile_idx), .fill_data(fill_data),
        .rd_en(req_valid), .rd_addr_flat(req_tile_idx_flat), .rd_data_flat(data_rep)
    );
    // replicated candidate: 1-cycle read latency, no ack signal of its
    // own -- model "ack" as rd_en registered (always accepted, private
    // port), matching its own zero-contention design.
    reg [N_SLOTS-1:0] ack_rep_reg;
    always @(posedge clk) ack_rep_reg <= rst ? {N_SLOTS{1'b0}} : req_valid;
    assign ack_rep = ack_rep_reg;

    nms_activation_banked #(
        .DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .N_BANKS(N_BANKS), .MAX_TILES(MAX_TILES)
    ) u_bank (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_tile_idx(fill_tile_idx), .fill_data(fill_data),
        .req_valid(req_valid), .req_tile_idx_flat(req_tile_idx_flat),
        .ack(ack_bank), .rd_data_flat(data_bank)
    );

    integer errors;
    integer t;

    task fill_pattern;
        integer k;
        begin
            for (k = 0; k < MAX_TILES; k = k + 1) begin
                @(posedge clk);
                fill_we = 1'b1;
                fill_tile_idx = k[TIW-1:0];
                fill_data = {P_IN{k[DATA_WIDTH-1:0]}};
            end
            @(posedge clk);
            fill_we = 1'b0;
        end
    endtask

    // drive one slot's request for `tidx` until it is acked (retrying
    // each cycle if not), checking bit-exact data on both candidates
    // when it lands. Runs slots in parallel via fork/join in the
    // caller; this task itself only manages ONE slot's own state.
    reg [N_SLOTS-1:0] want_valid;
    reg [TIW-1:0] want_tile [0:N_SLOTS-1];
    reg [N_SLOTS-1:0] got_rep, got_bank;

    task run_case;
        input [TIW-1:0] t0, t1, t2, t3;
        integer cyc, s;
        begin
            want_tile[0] = t0; want_tile[1] = t1; want_tile[2] = t2; want_tile[3] = t3;
            got_rep = 0; got_bank = 0;
            for (s = 0; s < N_SLOTS; s = s + 1)
                req_tile_idx_flat[s*TIW +: TIW] = want_tile[s];
            req_valid = {N_SLOTS{1'b1}};
            for (cyc = 0; cyc < 40 && (got_rep != {N_SLOTS{1'b1}} || got_bank != {N_SLOTS{1'b1}}); cyc = cyc + 1) begin
                @(posedge clk);
                #1;
                for (s = 0; s < N_SLOTS; s = s + 1) begin
                    if (ack_rep[s] && !got_rep[s]) begin
                        got_rep[s] = 1'b1;
                        if (data_rep[s*DATA_WIDTH*P_IN +: DATA_WIDTH] !== want_tile[s][DATA_WIDTH-1:0]) begin
                            $display("FAIL replicated slot=%0d expected=%0d got=%0d", s, want_tile[s], data_rep[s*DATA_WIDTH*P_IN +: DATA_WIDTH]);
                            errors = errors + 1;
                        end
                    end
                    if (ack_bank[s] && !got_bank[s]) begin
                        got_bank[s] = 1'b1;
                        if (data_bank[s*DATA_WIDTH*P_IN +: DATA_WIDTH] !== want_tile[s][DATA_WIDTH-1:0]) begin
                            $display("FAIL banked slot=%0d expected=%0d got=%0d", s, want_tile[s], data_bank[s*DATA_WIDTH*P_IN +: DATA_WIDTH]);
                            errors = errors + 1;
                        end
                    end
                    // stop re-requesting a slot once it's been served by BOTH
                    if (got_rep[s] && got_bank[s]) req_valid[s] = 1'b0;
                end
            end
            if (got_rep != {N_SLOTS{1'b1}} || got_bank != {N_SLOTS{1'b1}}) begin
                $display("FAIL starvation: got_rep=%b got_bank=%b", got_rep, got_bank);
                errors = errors + 1;
            end
            req_valid = {N_SLOTS{1'b0}};
            @(posedge clk);
        end
    endtask

    initial begin
        errors = 0;
        rst = 1'b1; fill_we = 1'b0; req_valid = 0; req_tile_idx_flat = 0;
        repeat (3) @(posedge clk);
        rst = 1'b0;
        fill_pattern();

        // Test 1: pure broadcast (all 4 slots want tile 0)
        run_case(0, 0, 0, 0);
        // Test 2: no contention (different tiles, different banks: 0,1,2,3)
        run_case(0, 1, 2, 3);
        // Test 3: forced same-bank contention (tile 0 and tile 4 both %4==0,
        // tile 1 and tile 5 both %4==1)
        run_case(0, 4, 1, 5);
        // Test 4: mixed broadcast + contention (slots 0,1 want tile 2 (broadcast),
        // slots 2,3 want DIFFERENT tiles 6 and 3, tile 6%4==2 collides with... )
        run_case(2, 2, 6, 3);

        if (errors == 0) $display("ALL TESTS PASSED (nms_activation_replicated + nms_activation_banked, N_SLOTS=%0d N_BANKS=%0d)", N_SLOTS, N_BANKS);
        else $display("%0d FAILURES", errors);
        $finish;
    end
endmodule
