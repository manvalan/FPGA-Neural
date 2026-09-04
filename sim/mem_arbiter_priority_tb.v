`timescale 1ns/1ps

// ================================================================
// C.4 certification: rtl/mem_arbiter.v priority (B>C>A>D), grant
// correctness, and starvation behavior.
//
// Oracle: the priority order is a design DECISION stated in the
// module's own header (not derived from behavior) -- these tests
// check the RTL actually implements that stated order, and probe the
// starvation claim's exact wording ("D simply gets stretched out,
// never starves OR CORRUPTS A/B/C" -- a claim about protecting A/B/C,
// NOT a claim that D itself can never starve under sustained
// contention. This test checks both readings explicitly instead of
// assuming one).
//
// Testbench note: request signals are driven with NON-BLOCKING
// assignments throughout. An earlier version used blocking
// assignments to clear a request in the same `@(posedge clk)` step
// that was meant to grant it -- a real race with the DUT's own
// synchronous always block sampling the same edge (whichever process
// happens to run first in that Active-region step wins; Icarus
// resolved it in the DUT's disfavor here, silently losing every
// grant, `owner` never leaving SEL_NONE, every `wait(x_ready)`
// blocking forever). Caught via a hierarchical trace of `dut.owner`
// showing it never changed from 0 despite requests being driven --
// not an RTL defect, a testbench race, same class as the one found in
// C.1/C.2 (see docs/validation/04-arbiter.md).
// ================================================================

module tb;

    localparam ADDR_WIDTH = 23;

    reg clk, rst;
    reg a_req, b_req, c_req, d_req;
    reg a_wr, b_wr, c_wr, d_wr;
    reg [ADDR_WIDTH-1:0] a_addr, b_addr, c_addr, d_addr;
    reg signed [7:0] a_wdata, b_wdata, c_wdata, d_wdata;
    wire signed [7:0] a_rdata, b_rdata, c_rdata, d_rdata;
    wire a_ready, b_ready, c_ready, d_ready;

    wire m_req, m_wr;
    wire [ADDR_WIDTH-1:0] m_addr;
    wire signed [7:0] m_wdata;
    reg signed [7:0] m_rdata;
    reg m_ready;

    mem_arbiter #(.ADDR_WIDTH(ADDR_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .a_req(a_req), .a_wr(a_wr), .a_addr(a_addr), .a_wdata(a_wdata), .a_rdata(a_rdata), .a_ready(a_ready),
        .b_req(b_req), .b_wr(b_wr), .b_addr(b_addr), .b_wdata(b_wdata), .b_rdata(b_rdata), .b_ready(b_ready),
        .c_req(c_req), .c_wr(c_wr), .c_addr(c_addr), .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ready(c_ready),
        .d_req(d_req), .d_wr(d_wr), .d_addr(d_addr), .d_wdata(d_wdata), .d_rdata(d_rdata), .d_ready(d_ready),
        .m_req(m_req), .m_wr(m_wr), .m_addr(m_addr), .m_wdata(m_wdata), .m_rdata(m_rdata), .m_ready(m_ready)
    );

    initial begin clk = 0; forever #5 clk = ~clk; end

    initial begin
        #200000;
        $display("WATCHDOG TIMEOUT -- simulation did not finish in time");
        $finish;
    end

    // Single-cycle-latency downstream memory stub: grants m_ready one
    // cycle after m_req, echoes m_addr as the "data" (distinguishable
    // per-port response, used to confirm rdata routes to the RIGHT
    // requester and not a sibling).
    always @(posedge clk) begin
        m_ready <= m_req;
        m_rdata <= m_addr[7:0];
    end

    integer errors;

    initial begin
        errors = 0;
        rst <= 1;
        a_req <= 0; b_req <= 0; c_req <= 0; d_req <= 0;
        a_wr <= 0; b_wr <= 0; c_wr <= 0; d_wr <= 0;
        a_wdata <= 0; b_wdata <= 0; c_wdata <= 0; d_wdata <= 0;
        a_addr <= 23'h001; b_addr <= 23'h002; c_addr <= 23'h003; d_addr <= 23'h004;
        repeat(3) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        // ------------------------------------------------------------
        // TEST 1: all four request simultaneously -- B must win first.
        // ------------------------------------------------------------
        $display("--- TEST 1: simultaneous A+B+C+D request -- B must win ---");
        a_req <= 1; b_req <= 1; c_req <= 1; d_req <= 1;
        @(posedge clk); // this edge: DUT samples all 4 (still their pre-edge values), grants B
        a_req <= 0; b_req <= 0; c_req <= 0; d_req <= 0; // withdraw next cycle (one-cycle-pulse contract)
        wait(b_ready);
        if (b_rdata !== b_addr[7:0]) begin errors=errors+1; $display("FAIL: b_rdata=%0d expected=%0d", b_rdata, b_addr[7:0]); end
        if (a_ready || c_ready || d_ready) begin errors=errors+1; $display("FAIL: a/c/d_ready asserted when B should have been the sole grantee"); end
        else $display("PASS: B granted alone, correct data routed back");
        @(posedge clk);

        // ------------------------------------------------------------
        // TEST 2: A+C+D request (no B) -- C must win.
        // ------------------------------------------------------------
        $display("--- TEST 2: A+C+D request (no B) -- C must win ---");
        a_req <= 1; c_req <= 1; d_req <= 1;
        @(posedge clk);
        a_req <= 0; c_req <= 0; d_req <= 0;
        wait(c_ready);
        if (c_rdata !== c_addr[7:0]) begin errors=errors+1; $display("FAIL: c_rdata=%0d expected=%0d", c_rdata, c_addr[7:0]); end
        else $display("PASS: C granted (B absent), correct data");
        @(posedge clk);

        // ------------------------------------------------------------
        // TEST 3: A+D request (no B, no C) -- A must win.
        // ------------------------------------------------------------
        $display("--- TEST 3: A+D request (no B, no C) -- A must win ---");
        a_req <= 1; d_req <= 1;
        @(posedge clk);
        a_req <= 0; d_req <= 0;
        wait(a_ready);
        if (a_rdata !== a_addr[7:0]) begin errors=errors+1; $display("FAIL: a_rdata=%0d expected=%0d", a_rdata, a_addr[7:0]); end
        else $display("PASS: A granted (B,C absent), correct data");
        @(posedge clk);

        // ------------------------------------------------------------
        // TEST 4: D alone -- must be granted (lowest priority does not
        // mean "never granted").
        // ------------------------------------------------------------
        $display("--- TEST 4: D alone -- must still be granted ---");
        d_req <= 1;
        @(posedge clk);
        d_req <= 0;
        wait(d_ready);
        if (d_rdata !== d_addr[7:0]) begin errors=errors+1; $display("FAIL: d_rdata=%0d expected=%0d", d_rdata, d_addr[7:0]); end
        else $display("PASS: D granted alone, correct data");
        @(posedge clk);

        // ------------------------------------------------------------
        // TEST 5: sustained back-to-back B requests (held continuously)
        // vs. continuous D requests -- does D ever get a turn? This
        // checks the exact wording of the header's starvation claim,
        // not an assumption.
        // ------------------------------------------------------------
        $display("--- TEST 5: continuous B contention vs continuous D -- does D starve? ---");
        begin : starvation_check
            integer cyc;
            reg d_ever_granted;
            d_ever_granted = 0;
            d_req <= 1;
            b_req <= 1;
            for (cyc = 0; cyc < 500; cyc = cyc + 1) begin
                @(posedge clk);
                if (d_ready) d_ever_granted = 1;
            end
            if (d_ever_granted)
                $display("OBSERVED: D was eventually granted within %0d cycles despite continuous B contention -- D does not starve under this exact pattern", cyc);
            else
                $display("OBSERVED: D was NEVER granted in %0d cycles of continuous B contention -- D CAN starve indefinitely under sustained higher-priority load (a literal 'gets stretched out' reading; does not contradict the header if read as only promising A/B/C's protection, not D's own)", cyc);
        end
        d_req <= 0; b_req <= 0;
        @(posedge clk);

        if (errors == 0)
            $display("ALL TESTS PASSED (priority order B>C>A>D confirmed; TEST 5 is an observation, not a pass/fail claim about starvation, since the header's wording is ambiguous about D's own guarantee)");
        else
            $display("FAILED: %0d error(s)", errors);
        $finish;
    end

endmodule
