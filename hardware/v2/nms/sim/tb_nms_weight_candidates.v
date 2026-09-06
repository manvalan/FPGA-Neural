// ============================================================
// NMS Weight SRAM candidates -- correctness check before trusting any
// synthesis number. No contention/arbitration exists in either
// candidate (private per-slot), so this just verifies a fill-then-
// read round trip is bit-exact per slot, per lane.
// ============================================================
`timescale 1ns/1ps
module tb_nms_weight_candidates;
    parameter DATA_WIDTH = 8;
    parameter P_IN = 8;
    parameter N_SLOTS = 4;
    parameter MAX_TILES = 8;
    parameter TIW = $clog2(MAX_TILES);

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst;

    reg [N_SLOTS-1:0] fill_we;
    reg [N_SLOTS*TIW-1:0] fill_addr_flat;
    reg [N_SLOTS*DATA_WIDTH*P_IN-1:0] fill_data_flat;
    reg [N_SLOTS-1:0] rd_en;
    reg [N_SLOTS*TIW-1:0] rd_addr_flat;
    wire [N_SLOTS*DATA_WIDTH*P_IN-1:0] rd_data_direct;
    wire [N_SLOTS*DATA_WIDTH*P_IN-1:0] rd_data_packed;

    nms_weight_direct #(.DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .MAX_TILES(MAX_TILES)) u_direct (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_addr_flat(fill_addr_flat), .fill_data_flat(fill_data_flat),
        .rd_en(rd_en), .rd_addr_flat(rd_addr_flat), .rd_data_flat(rd_data_direct)
    );
    nms_weight_packed #(.DATA_WIDTH(DATA_WIDTH), .P_IN(P_IN), .N_SLOTS(N_SLOTS), .MAX_TILES(MAX_TILES)) u_packed (
        .clk(clk), .rst(rst),
        .fill_we(fill_we), .fill_addr_flat(fill_addr_flat), .fill_data_flat(fill_data_flat),
        .rd_en(rd_en), .rd_addr_flat(rd_addr_flat), .rd_data_flat(rd_data_packed)
    );

    integer errors, s, t;
    reg [DATA_WIDTH*P_IN-1:0] expected_val [0:N_SLOTS-1][0:MAX_TILES-1];

    initial begin
        errors = 0;
        rst = 1'b1; fill_we = 0; rd_en = 0; fill_addr_flat = 0; fill_data_flat = 0; rd_addr_flat = 0;
        repeat (3) @(posedge clk);
        rst = 1'b0;

        // fill every slot with a distinct pattern per tile
        for (t = 0; t < MAX_TILES; t = t + 1) begin
            @(posedge clk);
            for (s = 0; s < N_SLOTS; s = s + 1) begin
                fill_we[s] = 1'b1;
                fill_addr_flat[s*TIW +: TIW] = t[TIW-1:0];
                fill_data_flat[s*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] = {P_IN{(s[3:0]<<4) | t[3:0]}};
                expected_val[s][t] = {P_IN{(s[3:0]<<4) | t[3:0]}};
            end
        end
        @(posedge clk);
        fill_we = 0;

        // read back every slot/tile combination, checking both candidates
        for (t = 0; t < MAX_TILES; t = t + 1) begin
            @(posedge clk);
            for (s = 0; s < N_SLOTS; s = s + 1) begin
                rd_en[s] = 1'b1;
                rd_addr_flat[s*TIW +: TIW] = t[TIW-1:0];
            end
            @(posedge clk);
            #1;
            for (s = 0; s < N_SLOTS; s = s + 1) begin
                if (rd_data_direct[s*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] !== expected_val[s][t]) begin
                    $display("FAIL direct slot=%0d tile=%0d expected=%h got=%h", s, t, expected_val[s][t], rd_data_direct[s*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]);
                    errors = errors + 1;
                end
                if (rd_data_packed[s*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN] !== expected_val[s][t]) begin
                    $display("FAIL packed slot=%0d tile=%0d expected=%h got=%h", s, t, expected_val[s][t], rd_data_packed[s*DATA_WIDTH*P_IN +: DATA_WIDTH*P_IN]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0) $display("ALL TESTS PASSED (nms_weight_direct + nms_weight_packed, N_SLOTS=%0d MAX_TILES=%0d)", N_SLOTS, MAX_TILES);
        else $display("%0d FAILURES", errors);
        $finish;
    end
endmodule
