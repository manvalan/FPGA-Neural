`timescale 1ns/1ps

// ================================================================
// Isolated unit regression for spi_host_bridge.v (STEP20).
//
// Emulates: (1) dependency_manager.v's reg_ready contract (a level,
// asserted only when the target node is free -- here deliberately
// delayed for a few cycles on the first job to prove reg_valid is
// HELD, not pulsed blind); (2) the host-arb slot_mem_arbiter's
// mem_ready contract (one clean req/ready handshake, SDRAM-like fixed
// latency, backed by a simple associative model array standing in for
// real SDRAM content).
//
// Per spi_host_bridge.v's own documented protocol: CS must stay
// asserted (low) for the WHOLE WRITE_MEM/READ_MEM transaction,
// including the internal wait for mem_ready -- SCLK may be idled
// (held low, no toggling) during that wait without losing state. This
// testbench's SPI master BFM does exactly that.
// ================================================================

module tb_spi_host_bridge;

    localparam ADDR_WIDTH = 26; // AS4C32M16SA memory upgrade: 25-bit word address + 1 byte-select bit
    localparam N_NODES    = 16;
    localparam MAX_DEPS   = 4;
    localparam NODEW = $clog2(N_NODES);
    localparam REQW  = $clog2(MAX_DEPS+1);

    reg clk = 0, rst = 1;
    always #5 clk = ~clk; // 100MHz sim clock (arbitrary, faster than SPI)

    reg sclk = 0, mosi = 0, cs_n = 1;
    wire miso;

    reg reg_ready_model = 0;
    wire                          reg_valid;
    wire [NODEW-1:0]              reg_node_id;
    wire [REQW-1:0]               reg_required;
    wire [MAX_DEPS*NODEW-1:0]     reg_producer_ids;
    wire [ADDR_WIDTH-1:0]         reg_x_base, reg_w_base, reg_result_addr;
    wire [15:0]                   reg_n_tiles;

    wire                    mem_req, mem_wr, mem_lb_n, mem_ub_n;
    wire [ADDR_WIDTH-1:0]   mem_addr;
    wire [15:0]             mem_wdata;
    reg  [15:0]             mem_rdata_model;
    reg                     mem_ready_model = 0;

    wire soft_rst_pulse;

    spi_host_bridge #(
        .ADDR_WIDTH(ADDR_WIDTH), .N_NODES(N_NODES), .MAX_DEPS(MAX_DEPS)
    ) dut (
        .clk(clk), .rst(rst),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n),
        .reg_valid(reg_valid), .reg_ready(reg_ready_model),
        .reg_node_id(reg_node_id), .reg_required(reg_required),
        .reg_producer_ids(reg_producer_ids),
        .reg_x_base(reg_x_base), .reg_w_base(reg_w_base),
        .reg_n_tiles(reg_n_tiles), .reg_result_addr(reg_result_addr),
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

    // ---- SPI master BFM: mode 0, MSB-first ----
    // Bit period = 500ns (2MHz SPI clock) against a 100MHz sim `clk`:
    // a 50x margin over the ~4-clk-cycle CDC synchronizer latency,
    // representative of a REAL deployment (system clock 64-80MHz vs a
    // practical SPI clock in the low single-digit MHz -- see this
    // module's own header for the documented minimum ratio). A torture
    // rate close to the CDC latency (as an earlier draft of this
    // testbench used) is not a realistic operating point and is not
    // what this module is specified against.
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
    reg [ADDR_WIDTH-1:0] exp_addr;

    initial begin
        rst = 1; cs_n = 1; sclk = 0; mosi = 0;
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        // ================= Test A: WRITE_JOB, delayed reg_ready =====
        reg_ready_model = 0;
        cs_n = 0; #20;
        spi_byte(8'h10, rxb);              // opcode WRITE_JOB
        spi_byte(8'h05, rxb);              // node_id=5
        spi_byte(8'h02, rxb);              // required=2
        spi_byte(8'hAB, rxb);              // producer_ids[15:8]
        spi_byte(8'hCD, rxb);              // producer_ids[7:0]
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

        // reg_valid must now be held (reg_ready still 0). Allow for the
        // CDC synchronizer latency on the LAST bit before sampling.
        repeat (8) @(posedge clk);
        check(reg_valid == 1'b1, "A: reg_valid asserted after 15th payload byte");
        check(reg_node_id == 5, "A: reg_node_id");
        check(reg_required == 2, "A: reg_required");
        check(reg_producer_ids == 16'hABCD, "A: reg_producer_ids");
        check(reg_x_base == 26'h001000, "A: reg_x_base");
        check(reg_w_base == 26'h002000, "A: reg_w_base");
        check(reg_n_tiles == 16'h0004, "A: reg_n_tiles");
        check(reg_result_addr == 26'h003000, "A: reg_result_addr");

        repeat (3) begin
            @(posedge clk);
            check(reg_valid == 1'b1, "A: reg_valid still held while reg_ready=0");
        end
        reg_ready_model = 1;
        @(posedge clk);
        #1;
        check(reg_valid == 1'b0, "A: reg_valid drops the cycle after reg_ready seen");
        reg_ready_model = 0;
        cs_n = 1; #40;

        // ================= Test B: STATUS after accepted job ========
        cs_n = 0; #20;
        spi_byte(8'h20, rxb);               // opcode STATUS
        spi_byte(8'h00, rxb);               // clocks out status byte
        $monitoroff;
        check(rxb[2] == 1'b1, "B: STATUS last_job_accepted=1");
        check(rxb[0] == 1'b0, "B: STATUS job_busy=0 (already accepted)");
        cs_n = 1; #40;

        // ================= Test C: WRITE_MEM, single word ===========
        cs_n = 0; #20;
        spi_byte(8'h01, rxb);               // opcode WRITE_MEM
        spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h55, rxb); // addr=0x000055
        spi_byte(8'h00, rxb); spi_byte(8'h01, rxb); // len_words=1
        spi_byte(8'h12, rxb); spi_byte(8'h34, rxb); // data=0x1234
        // hold CS low, idle SCLK, while the memory model latency elapses
        #200;
        cs_n = 1; #40;
        check(mem_model[16'h0055] == 16'h1234, "C: WRITE_MEM wrote 0x1234 @ 0x000055");

        // ================= Test D: READ_MEM, single word =============
        cs_n = 0; #20;
        spi_byte(8'h02, rxb);               // opcode READ_MEM
        spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h00, rxb); spi_byte(8'h55, rxb); // addr=0x000055
        spi_byte(8'h00, rxb); spi_byte(8'h01, rxb); // len_words=1
        #200; // idle SCLK while the read latency elapses
        spi_byte(8'h00, rxb); exp_addr = rxb; // MSB
        check(rxb == 8'h12, "D: READ_MEM MSB byte == 0x12");
        spi_byte(8'h00, rxb);
        check(rxb == 8'h34, "D: READ_MEM LSB byte == 0x34");
        cs_n = 1; #40;

        // ================= Test E: RESET opcode ======================
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
            check(seen, "E: soft_rst_pulse asserted after CS rises (within CDC latency)");
        end

        $display("=== tb_spi_host_bridge: %0d/%0d PASS ===", tests-errors, tests);
        if (errors != 0) $display("*** %0d FAILURES ***", errors);
        $finish;
    end

endmodule
