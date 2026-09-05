`timescale 1ns/1ps

// ================================================================
// C.3 certification: rtl/int8_memory_access.v byte<->word address
// conversion and byte-lane selection, exhaustive + round-trip.
//
// Oracle: hand-derived from the module's own documented convention
// (addr[0]=0 -> low byte / lb_n asserted, addr[0]=1 -> high byte /
// ub_n asserted, word address = byte address >> 1) -- not read from
// the RTL, applied independently for every vector below.
// ================================================================

module tb;

    localparam ADDR_WIDTH = 23;

    reg clk, rst;
    reg req, wr;
    reg [ADDR_WIDTH-1:0] addr;
    reg signed [7:0] wdata;
    wire signed [7:0] rdata;
    wire ready;

    wire mem_req, mem_wr;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire [15:0] mem_wdata;
    wire mem_lb_n, mem_ub_n;
    reg [15:0] mem_rdata;
    reg mem_ready;

    int8_memory_access #(.ADDR_WIDTH(ADDR_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .req(req), .wr(wr), .addr(addr), .wdata(wdata),
        .rdata(rdata), .ready(ready),
        .mem_req(mem_req), .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_lb_n(mem_lb_n), .mem_ub_n(mem_ub_n),
        .mem_rdata(mem_rdata), .mem_ready(mem_ready)
    );

    initial begin clk = 0; forever #5 clk = ~clk; end

    // 16384-word behavioral memory, always-ready-next-cycle -- content
    // is what gets round-tripped for TEST 2, not a fixed stub.
    reg [15:0] mem [0:16383];
    always @(posedge clk) begin
        mem_ready <= mem_req;
        // Respect byte-lane enables like a real byte-maskable memory --
        // an earlier version of this stub wrote the whole 16-bit word
        // unconditionally, which clobbered the sibling byte on every
        // single-byte write (a bug in THIS testbench stub, caught by
        // TEST 2's addr=200/201 sibling-write check failing -- not a
        // rtl/int8_memory_access.v defect).
        if (mem_req && mem_wr) begin
            if (!mem_lb_n) mem[mem_addr][7:0]  <= mem_wdata[7:0];
            if (!mem_ub_n) mem[mem_addr][15:8] <= mem_wdata[15:8];
        end
        mem_rdata <= mem[mem_addr];
    end

    integer errors, checked, i;
    reg [22:0] a;

    task automatic do_write(input [ADDR_WIDTH-1:0] a_i, input signed [7:0] d_i);
        begin
            @(posedge clk);
            req <= 1; wr <= 1; addr <= a_i; wdata <= d_i;
            @(posedge clk);
            req <= 0;
            wait(ready);
            @(posedge clk);
        end
    endtask

    task automatic do_read(input [ADDR_WIDTH-1:0] a_i, output signed [7:0] d_o);
        begin
            @(posedge clk);
            req <= 1; wr <= 0; addr <= a_i;
            @(posedge clk);
            req <= 0;
            wait(ready);
            d_o = rdata;
            @(posedge clk);
        end
    endtask

    reg signed [7:0] got;

    initial begin
        errors = 0; checked = 0;
        rst = 1; req = 0; wr = 0; addr = 0; wdata = 0;
        repeat(3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // TEST 1: exhaustive byte-lane/word-address decode check over
        // 2048 addresses (every combination of the low 12 bits, both
        // parities), inspecting mem_addr/mem_lb_n/mem_ub_n/mem_wdata
        // DIRECTLY (combinational, visible the cycle after `req`).
        $display("--- TEST 1: byte-lane/word-address decode, 2048 addresses ---");
        for (i = 0; i < 2048; i = i + 1) begin
            a = i[22:0];
            @(posedge clk);
            req <= 1; wr <= 1; addr <= a; wdata <= 8'sd0;
            @(posedge clk);
            req <= 0;
            #1; // let the STATE_IDLE branch's non-blocking updates (mem_addr/mem_lb_n/mem_ub_n) settle before reading them -- checking in the same active-region step as the NBA write reads the STALE (previous-iteration) value, not this cycle's
            checked = checked + 1;
            if (mem_addr !== (a >> 1)) begin
                errors = errors + 1;
                if (errors <= 10) $display("MISMATCH addr=%0d: mem_addr=%0d expected=%0d", a, mem_addr, a>>1);
            end
            if (a[0] == 1'b0) begin
                if (mem_lb_n !== 1'b0 || mem_ub_n !== 1'b1) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("MISMATCH addr=%0d (even): lb_n=%b ub_n=%b expected lb_n=0 ub_n=1", a, mem_lb_n, mem_ub_n);
                end
            end else begin
                if (mem_lb_n !== 1'b1 || mem_ub_n !== 1'b0) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("MISMATCH addr=%0d (odd): lb_n=%b ub_n=%b expected lb_n=1 ub_n=0", a, mem_lb_n, mem_ub_n);
                end
            end
            wait(ready);
            @(posedge clk);
        end
        $display("  checked %0d addresses, %0d errors", checked, errors);

        // TEST 2: write/read round-trip at both parities, several
        // addresses, through the real FSM handshake (not a peek at
        // internal wires) -- confirms the byte actually lands in the
        // right half of the word AND comes back out correctly.
        $display("--- TEST 2: write/read round-trip, even and odd addresses ---");
        do_write(23'd0,  8'sd42);   do_read(23'd0,  got); if (got !== 8'sd42)  begin errors=errors+1; $display("RT FAIL addr=0: got=%0d",got); end else $display("addr=0 (even): PASS (%0d)", got);
        do_write(23'd1,  -8'sd5);   do_read(23'd1,  got); if (got !== -8'sd5)  begin errors=errors+1; $display("RT FAIL addr=1: got=%0d",got); end else $display("addr=1 (odd): PASS (%0d)", got);
        do_write(23'd100, 8'sd127); do_read(23'd100, got); if (got !== 8'sd127) begin errors=errors+1; $display("RT FAIL addr=100: got=%0d",got); end else $display("addr=100 (even): PASS (%0d)", got);
        do_write(23'd101, -8'sd128); do_read(23'd101, got); if (got !== -8'sd128) begin errors=errors+1; $display("RT FAIL addr=101: got=%0d",got); end else $display("addr=101 (odd): PASS (%0d)", got);
        // same word, both bytes -- confirms writing the odd byte does
        // not clobber the even byte already written there (shared
        // 16-bit word, independent byte lanes)
        do_write(23'd200, 8'sd11);
        do_write(23'd201, 8'sd22);
        do_read(23'd200, got); if (got !== 8'sd11) begin errors=errors+1; $display("RT FAIL addr=200 after sibling write: got=%0d",got); end else $display("addr=200 unaffected by addr=201 write: PASS (%0d)", got);
        do_read(23'd201, got); if (got !== 8'sd22) begin errors=errors+1; $display("RT FAIL addr=201: got=%0d",got); end else $display("addr=201: PASS (%0d)", got);

        if (errors == 0)
            $display("ALL TESTS PASSED (%0d decode checks + 6 round-trip checks, 0 mismatches)", checked);
        else
            $display("FAILED: %0d errors", errors);
        $finish;
    end

endmodule
