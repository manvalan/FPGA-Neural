`timescale 1ns/1ps

// ================================================================
// Isolated unit regression for spi_host_bridge_v3.v (V3 SPI opcode
// re-audit, this session). Mirrors hardware/v2/sim/tb_spi_host_
// bridge.v's own proven BFM/latency-model structure exactly, adapted
// for the new job_in_*/mem_* port shapes (16-byte WRITE_JOB, no
// required/producer_ids fields; 4-byte WRITE_MEM/READ_MEM address).
//
// Emulates: (1) neural_director_packed.v's job_in_ready contract (a
// level, deliberately delayed for a few cycles on the first job to
// prove job_in_valid is HELD, not pulsed blind); (2) host_mem_
// bridge.v's mem_ready contract (one clean req/ready handshake, fixed
// latency, backed by a simple model array standing in for real DDR3
// content -- host_mem_bridge.v itself is already independently
// verified in EXP-0071, so this test only needs to prove
// spi_host_bridge_v3.v drives ITS OWN side of that same word-
// granularity contract correctly).
// ================================================================

module tb_spi_host_bridge_v3;

    localparam JOB_ADDR_WIDTH = 26;
    localparam MEM_ADDR_WIDTH = 25;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk; // 100MHz sim clock

    reg sclk = 0, mosi = 0, cs_n = 1;
    wire miso;

    reg job_in_ready_model = 0;
    wire                        job_in_valid;
    wire [JOB_ADDR_WIDTH-1:0]   job_in_x_base, job_in_w_base, job_in_result_addr;
    wire [15:0]                 job_in_n_tiles, job_in_node_id;

    wire                     mem_req, mem_wr, mem_lb_n, mem_ub_n;
    wire [MEM_ADDR_WIDTH-1:0] mem_addr;
    wire [15:0]              mem_wdata;
    reg  [15:0]              mem_rdata_model;
    reg                      mem_ready_model = 0;

    wire soft_rst_pulse;
    reg init_calib_complete_model = 0;
    reg dir_error_model = 0;

    spi_host_bridge_v3 #(
        .JOB_ADDR_WIDTH(JOB_ADDR_WIDTH), .MEM_ADDR_WIDTH(MEM_ADDR_WIDTH), .N_SLOTS(2)
    ) dut (
        .clk(clk), .rst(rst),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .init_calib_complete(init_calib_complete_model), .dir_error(dir_error_model),
        .job_in_valid(job_in_valid), .job_in_ready(job_in_ready_model),
        .job_in_x_base(job_in_x_base), .job_in_w_base(job_in_w_base),
        .job_in_n_tiles(job_in_n_tiles), .job_in_result_addr(job_in_result_addr),
        .job_in_node_id(job_in_node_id),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_lb_n(mem_lb_n), .mem_ub_n(mem_ub_n),
        .mem_rdata(mem_rdata_model), .mem_ready(mem_ready_model),
        .soft_rst_pulse(soft_rst_pulse)
    );

    // ---- simple backing memory model: fixed 6-cycle mem_ready latency ----
    reg [15:0] mem_model [0:1023];
    integer mem_latency_cnt;
    reg     mem_pending;
    always @(posedge clk) begin
        if (rst) begin
            mem_ready_model <= 1'b0; mem_pending <= 1'b0; mem_latency_cnt <= 0;
        end else begin
            mem_ready_model <= 1'b0;
            if (mem_req && !mem_pending) begin
                mem_pending <= 1'b1;
                mem_latency_cnt <= 6;
            end else if (mem_pending) begin
                if (mem_latency_cnt == 0) begin
                    mem_pending <= 1'b0;
                    mem_ready_model <= 1'b1;
                    if (mem_wr) mem_model[mem_addr[9:0]] <= mem_wdata;
                    else        mem_rdata_model <= mem_model[mem_addr[9:0]];
                end else begin
                    mem_latency_cnt <= mem_latency_cnt - 1;
                end
            end
        end
    end

    // ---- SPI master BFM: mode 0, MSB-first (same timing as tb_spi_host_bridge.v) ----
    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer i;
        begin
            rx = 8'h00;
            for (i = 7; i >= 0; i = i - 1) begin
                mosi = tx[i];
                #200; sclk = 1; #50; rx = {rx[6:0], miso}; #50; sclk = 0; #200;
            end
        end
    endtask

    integer errors = 0, tests = 0;
    task check(input cond, input [255:0] name);
        begin
            tests = tests + 1;
            if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
            else $display("PASS: %0s", name);
        end
    endtask

    reg [7:0] rxb;

    initial begin
        rst = 1; cs_n = 1; sclk = 0; mosi = 0;
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // ================= Test A: WRITE_JOB (16 bytes), delayed job_in_ready =====
        job_in_ready_model = 0;
        cs_n = 0; #20;
        spi_byte(8'h10, rxb);              // opcode WRITE_JOB
        spi_byte(8'h00, rxb);              // node_id[15:8]
        spi_byte(8'h05, rxb);              // node_id[7:0]  -> node_id=5
        spi_byte(8'h00, rxb);              // x_base[25:24]
        spi_byte(8'h00, rxb);              // x_base[23:16]
        spi_byte(8'h10, rxb);              // x_base[15:8]
        spi_byte(8'h00, rxb);              // x_base[7:0]  -> x_base=0x001000
        spi_byte(8'h00, rxb);              // w_base[25:24]
        spi_byte(8'h00, rxb);              // w_base[23:16]
        spi_byte(8'h20, rxb);              // w_base[15:8]
        spi_byte(8'h00, rxb);              // w_base[7:0]  -> w_base=0x002000
        spi_byte(8'h00, rxb);              // n_tiles[15:8]
        spi_byte(8'h04, rxb);              // n_tiles[7:0] -> n_tiles=4
        spi_byte(8'h00, rxb);              // result_addr[25:24]
        spi_byte(8'h00, rxb);              // result_addr[23:16]
        spi_byte(8'h30, rxb);              // result_addr[15:8]
        spi_byte(8'h00, rxb);              // result_addr[7:0] -> result_addr=0x003000

        repeat (8) @(posedge clk);
        check(job_in_valid == 1'b1, "A: job_in_valid asserted after 16th payload byte");
        check(job_in_node_id == 16'h0005, "A: job_in_node_id");
        check(job_in_x_base == 26'h001000, "A: job_in_x_base");
        check(job_in_w_base == 26'h002000, "A: job_in_w_base");
        check(job_in_n_tiles == 16'h0004, "A: job_in_n_tiles");
        check(job_in_result_addr == 26'h003000, "A: job_in_result_addr");

        repeat (3) begin
            @(posedge clk);
            check(job_in_valid == 1'b1, "A: job_in_valid still held while job_in_ready=0");
        end
        job_in_ready_model = 1;
        @(posedge clk);
        #1;
        check(job_in_valid == 1'b0, "A: job_in_valid drops the cycle after job_in_ready seen");
        job_in_ready_model = 0;
        cs_n = 1; #40;

        // ================= Test B: STATUS after accepted job ========
        cs_n = 0; #20;
        spi_byte(8'h20, rxb);               // opcode STATUS
        spi_byte(8'h00, rxb);               // clocks out status byte
        check(rxb[2] == 1'b1, "B: STATUS last_job_accepted=1");
        check(rxb[0] == 1'b0, "B: STATUS job_busy=0 (already accepted)");
        cs_n = 1; #40;

        // ================= Test C: WRITE_MEM, single word (4-byte addr) =====
        cs_n = 0; #20;
        spi_byte(8'h01, rxb);               // opcode WRITE_MEM
        spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h55, rxb); // addr=0x000055
        spi_byte(8'h00, rxb); spi_byte(8'h01, rxb); // len_words=1
        spi_byte(8'h12, rxb); spi_byte(8'h34, rxb); // data=0x1234
        #200;
        cs_n = 1; #40;
        check(mem_model[16'h0055] == 16'h1234, "C: WRITE_MEM wrote 0x1234 @ 0x000055");

        // ================= Test D: READ_MEM, single word =============
        cs_n = 0; #20;
        spi_byte(8'h02, rxb);               // opcode READ_MEM
        spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h55, rxb); // addr=0x000055
        spi_byte(8'h00, rxb); spi_byte(8'h01, rxb); // len_words=1
        #200;
        spi_byte(8'h00, rxb);
        check(rxb == 8'h12, "D: READ_MEM MSB byte == 0x12");
        spi_byte(8'h00, rxb);
        check(rxb == 8'h34, "D: READ_MEM LSB byte == 0x34");
        cs_n = 1; #40;

        // ================= Test E: multi-word WRITE_MEM/READ_MEM, exercising
        // the 25-bit MEM_ADDR_WIDTH's own top bit (addr near 2^24) =========
        cs_n = 0; #20;
        spi_byte(8'h01, rxb);               // opcode WRITE_MEM
        spi_byte(8'h01, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); // addr=0x1000000 (bit24=1)
        spi_byte(8'h00, rxb); spi_byte(8'h02, rxb); // len_words=2
        spi_byte(8'hAA, rxb); spi_byte(8'hBB, rxb); // word0=0xAABB
        spi_byte(8'hCC, rxb); spi_byte(8'hDD, rxb); // word1=0xCCDD
        #400;
        cs_n = 1; #40;
        check(mem_model[(25'h1000000) & 10'h3FF] == 16'hAABB, "E: WRITE_MEM word0 @ addr bit24 set");
        check(mem_model[((25'h1000000)+1) & 10'h3FF] == 16'hCCDD, "E: WRITE_MEM word1 @ addr bit24 set");

        // ================= Test G: REG_READ, DEVICE_ID (0x00) ========
        cs_n = 0; #20;
        spi_byte(8'h31, rxb);               // opcode REG_READ
        spi_byte(8'h00, rxb);               // reg_addr=0x00 DEVICE_ID
        spi_byte(8'h00, rxb); check(rxb == 8'h4E, "G: DEVICE_ID byte0 == 'N'");
        spi_byte(8'h00, rxb); check(rxb == 8'h50, "G: DEVICE_ID byte1 == 'P'");
        spi_byte(8'h00, rxb); check(rxb == 8'h56, "G: DEVICE_ID byte2 == 'V'");
        spi_byte(8'h00, rxb); check(rxb == 8'h01, "G: DEVICE_ID byte3 == version 1");
        cs_n = 1; #40;

        // ================= Test H: REG_READ, N_SLOTS (0x03) ==========
        cs_n = 0; #20;
        spi_byte(8'h31, rxb);
        spi_byte(8'h03, rxb);
        spi_byte(8'h00, rxb); check(rxb == 8'h00, "H: N_SLOTS byte0 == 0");
        spi_byte(8'h00, rxb); check(rxb == 8'h00, "H: N_SLOTS byte1 == 0");
        spi_byte(8'h00, rxb); check(rxb == 8'h00, "H: N_SLOTS byte2 == 0");
        spi_byte(8'h00, rxb); check(rxb == 8'h02, "H: N_SLOTS byte3 == 2 (matches N_SLOTS param)");
        cs_n = 1; #40;

        // ================= Test I: REG_READ, STATUS (0x02), with
        // init_calib_complete and dir_error both driven high by the
        // model, confirming they land in the right bits ============
        init_calib_complete_model = 1'b1;
        dir_error_model = 1'b1;
        cs_n = 0; #20;
        spi_byte(8'h31, rxb);
        spi_byte(8'h02, rxb);
        spi_byte(8'h00, rxb); check(rxb == 8'h00, "I: STATUS byte0 == 0 (bits[31:8] reserved)");
        spi_byte(8'h00, rxb); check(rxb == 8'h00, "I: STATUS byte1 == 0");
        spi_byte(8'h00, rxb); check(rxb == 8'h00, "I: STATUS byte2 == 0");
        spi_byte(8'h00, rxb); check(rxb[3] == 1'b1, "I: STATUS bit3 == init_calib_complete");
        check(rxb[4] == 1'b1, "I: STATUS bit4 == dir_error");
        cs_n = 1; #40;
        init_calib_complete_model = 1'b0;
        dir_error_model = 1'b0;

        // ================= Test J: REG_READ, unknown address =========
        cs_n = 0; #20;
        spi_byte(8'h31, rxb);
        spi_byte(8'hEE, rxb);               // unmapped register
        spi_byte(8'h00, rxb); check(rxb == 8'hFF, "J: unmapped reg byte0 == 0xFF");
        spi_byte(8'h00, rxb); check(rxb == 8'hFF, "J: unmapped reg byte1 == 0xFF");
        spi_byte(8'h00, rxb); check(rxb == 8'hFF, "J: unmapped reg byte2 == 0xFF");
        spi_byte(8'h00, rxb); check(rxb == 8'hFF, "J: unmapped reg byte3 == 0xFF (distinct from a real 0)");
        cs_n = 1; #40;

        // ================= Test K: REG_WRITE to CONTROL (0x01) bit0
        // pulses soft_rst_pulse, same physical effect as RESET.
        // UNLIKE the RESET opcode (which pulses only after CS rises),
        // REG_WRITE applies immediately when its last data byte
        // lands -- no backend handshake to wait on (see this module's
        // own header). The watchdog must therefore run CONCURRENTLY
        // with the last data byte's own spi_byte() call (a `fork`,
        // same technique as tb_sdram_arbiter_n.v's own one-shot-pulse
        // watchers), not after CS has already risen -- a first draft
        // of this test watched only after CS rose and missed the
        // pulse entirely (a testbench-timing bug, not an RTL one,
        // confirmed via a DUT-internal trace before writing this). ==
        cs_n = 0; #20;
        spi_byte(8'h30, rxb);               // opcode REG_WRITE
        spi_byte(8'h01, rxb);               // reg_addr=0x01 CONTROL
        spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); // value bytes 31:8 = 0
        begin : wait_reg_soft_rst
            reg seen;
            seen = 1'b0;
            fork
                spi_byte(8'h01, rxb);           // value byte 7:0 = 1 (bit0 set) -- triggers the pulse
                begin : watcher
                    integer wi;
                    for (wi = 0; wi < 410; wi = wi + 1) begin // covers spi_byte's own ~400-clk duration plus margin
                        @(posedge clk);
                        if (soft_rst_pulse) seen = 1'b1;
                    end
                end
            join
            check(seen, "K: REG_WRITE CONTROL bit0 pulses soft_rst_pulse");
        end
        cs_n = 1; #40;

        // ================= Test L: RESET opcode ======================
        cs_n = 0; #20;
        spi_byte(8'h0F, rxb);               // opcode RESET
        cs_n = 1;
        begin : wait_soft_rst
            integer wi; reg seen;
            seen = 1'b0;
            for (wi = 0; wi < 10; wi = wi + 1) begin
                @(posedge clk);
                if (soft_rst_pulse) seen = 1'b1;
            end
            check(seen, "L: soft_rst_pulse asserted after CS rises (within CDC latency)");
        end

        // ================= Test M: READ_MEM regression for the ROUT-
        // exit bit_count==0 corruption (found via REG_READ this
        // session, see spi_host_bridge_v3.v's own header note) --
        // Test C/D's word 0x1234 has LSB byte 0x34 (bit0=0), which
        // coincidentally matched the corrupted substitute's bit7=0
        // and masked the bug. Use 0x5679 instead: LSB byte 0x79 =
        // 0111_1001, bit0=1, which the (now-fixed) bug would have
        // flipped to 0 (reading back 0x78 instead of 0x79). =========
        cs_n = 0; #20;
        spi_byte(8'h01, rxb);
        spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h60, rxb); // addr=0x60
        spi_byte(8'h00, rxb); spi_byte(8'h01, rxb); // len_words=1
        spi_byte(8'h56, rxb); spi_byte(8'h79, rxb); // data=0x5679
        #200;
        cs_n = 1; #40;
        cs_n = 0; #20;
        spi_byte(8'h02, rxb);
        spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h60, rxb);
        spi_byte(8'h00, rxb); spi_byte(8'h01, rxb);
        #200;
        spi_byte(8'h00, rxb); check(rxb == 8'h56, "M: READ_MEM MSB byte == 0x56");
        spi_byte(8'h00, rxb); check(rxb == 8'h79, "M: READ_MEM LSB byte == 0x79 (bit0=1, catches the ROUT-exit bug)");
        cs_n = 1; #40;

        $display("=== tb_spi_host_bridge_v3: %0d/%0d PASS ===", tests-errors, tests);
        if (errors != 0) $display("*** %0d FAILURES ***", errors);
        $finish;
    end

endmodule
