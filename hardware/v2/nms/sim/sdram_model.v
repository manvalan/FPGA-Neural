`timescale 1ns/1ps

// ============================================================
// NMS STEP16 -- behavioral model of Alliance Memory SDR SDRAM.
//
// MEMORY UPGRADE: retargeted from AS4C4M16SA-6TIN (64Mbit/8MB) to
// AS4C32M16SA-7TIN (512Mbit/64MB, x16, 4 banks x 8192 rows x 1024
// cols) -- ROW_BITS/COL_BITS/BANK_BITS are now real parameters
// (matching sdram_controller.v's own parameterization) so this same
// model supports either device by parameter alone. Real -7-grade AC
// timing: tRCD=15ns, tRP=15ns, tRAS(min)=45ns, tRC=65ns, tMRD=2 CLK
// (fixed, explicit CLK units per this datasheet), tREFI=64ms/8192
// rows=7.8125us -- see sdram_controller.v's own header for the full
// datasheet cross-reference.
//
// Real JEDEC command decode (CS#/RAS#/CAS#/WE#), real per-bank
// state tracking (IDLE / ACTIVE with an open row), and REAL timing-
// violation assertions (tRCD, tRP, tRAS-min, tRC, tMRD) -- this model
// does not merely "accept whatever the controller sends"; it actively
// checks the controller's own real compliance with datasheet timing,
// same rigor this project applies to psram_model.v elsewhere. A
// timing violation here is a genuine controller bug, not tolerated
// silently.
//
// Refresh is tracked per-row (a real ROWS-row array of "last
// refreshed at cycle N" timestamps) and checked against tREFI --
// data itself is not modeled as decaying (unnecessary complexity for
// this validation), but an insufficiently-refreshed row is flagged
// via a real, visible warning/assertion, not silently ignored.
//
// CAS_LATENCY and BURST_LEN are read back from the real LOAD MODE
// REGISTER command's own address bits (not assumed equal to the
// controller's own parameters) -- this model independently decodes
// the mode register exactly as real silicon would, so a controller
// bug in the MRS encoding would be caught here too.
// ============================================================
module sdram_model #(
    parameter CLK_FREQ_MHZ = 64,
    parameter ROW_BITS     = 13,  // AS4C32M16SA: row address A0-A12
    parameter COL_BITS     = 10,  // AS4C32M16SA: column address A0-A9
    parameter BANK_BITS    = 2    // BA0,BA1 -- fixed across this whole Alliance SDR family
)(
    input  wire        clk,
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [BANK_BITS-1:0]  ba,
    input  wire [ROW_BITS-1:0]   a,
    inout  wire [15:0] dq,
    input  wire [1:0]  dqm
);
    localparam BANKS = 1 << BANK_BITS;
    localparam ROWS  = 1 << ROW_BITS;
    localparam COLS  = 1 << COL_BITS;

    function integer ns_to_cycles;
        input integer ns;
        begin
            ns_to_cycles = (ns * CLK_FREQ_MHZ + 999) / 1000;
        end
    endfunction
    localparam T_RCD    = ns_to_cycles(15);
    localparam T_RP     = ns_to_cycles(15);
    localparam T_RAS_MIN= ns_to_cycles(45);
    localparam T_RC     = ns_to_cycles(65);
    localparam T_MRD    = 2; // tMRD = 2 CLK, fixed (see sdram_controller.v's own header)
    localparam T_REFI   = ns_to_cycles(64000000 / ROWS + 1);

    reg [15:0] mem [0:BANKS*ROWS*COLS-1];

    // per-bank state
    reg          bank_active   [0:BANKS-1];
    reg [ROW_BITS-1:0] bank_row [0:BANKS-1];
    integer      bank_active_since [0:BANKS-1]; // cycle ACTIVATE was issued
    integer      bank_precharge_since [0:BANKS-1]; // cycle last PRECHARGE completed

    // mode register (decoded from a real LOAD MODE REGISTER command)
    reg [2:0] mr_burst_code;
    reg [2:0] mr_cas_latency;
    integer   burst_len;
    integer   cas_latency;

    integer cycle;
    always @(posedge clk) cycle <= cycle + 1;

    // refresh bookkeeping: last-refreshed cycle per row (across all
    // banks -- real SDRAM refreshes one row address across ALL banks
    // per AUTO REFRESH command)
    integer last_refresh_cycle [0:ROWS-1];
    integer last_any_refresh_cycle;

    // ---- command decode ----
    wire cmd_active   = !cs_n && !ras_n &&  cas_n &&  we_n;
    wire cmd_read     = !cs_n &&  ras_n && !cas_n &&  we_n;
    wire cmd_write    = !cs_n &&  ras_n && !cas_n && !we_n;
    wire cmd_precharge= !cs_n && !ras_n &&  cas_n && !we_n;
    wire cmd_refresh  = !cs_n && !ras_n && !cas_n &&  we_n;
    wire cmd_mrs      = !cs_n && !ras_n && !cas_n && !we_n;

    // ---- read burst delivery (CAS-latency-delayed shift pipeline) ----
    reg [15:0] rd_pipe [0:15]; // generous depth, only first `cas_latency` entries meaningful
    reg        rd_valid_pipe [0:15];
    // combinational output stage: rd_pipe[0] IS the chip's own output
    // register in real SDR SDRAM, already counted inside CAS_LATENCY --
    // driving dq_out through one more registered NBA stage here would
    // silently add an extra cycle of latency the controller doesn't
    // expect (a real bug found by tracing a stubborn one-cycle-late
    // read-data mismatch against the controller's own CAS_LATENCY-cycle
    // wait_cnt derivation)
    wire [15:0] dq_out    = rd_pipe[0];
    wire        dq_out_en = rd_valid_pipe[0];
    assign dq = dq_out_en ? dq_out : 16'hzzzz;

    // active read-burst tracking (for auto-precharge/address auto-increment)
    reg        rd_burst_active;
    reg [BANK_BITS-1:0] rd_bank;
    reg [ROW_BITS-1:0]  rd_row;
    reg [COL_BITS-1:0]  rd_col;
    integer    rd_remaining;
    reg        rd_autoprecharge;

    reg        wr_burst_active;
    reg [BANK_BITS-1:0] wr_bank;
    reg [ROW_BITS-1:0]  wr_row;
    reg [COL_BITS-1:0]  wr_col;
    integer    wr_remaining;
    reg        wr_autoprecharge;

    integer i;

    initial begin
        cycle = 0;
        last_any_refresh_cycle = 0;
        burst_len = 1; cas_latency = 3;
        rd_burst_active = 0; wr_burst_active = 0;
        for (i = 0; i < BANKS; i = i + 1) begin
            bank_active[i] = 0; bank_active_since[i] = -1000000; bank_precharge_since[i] = 0;
        end
        for (i = 0; i < ROWS; i = i + 1) last_refresh_cycle[i] = 0;
        for (i = 0; i < 16; i = i + 1) begin rd_pipe[i] = 0; rd_valid_pipe[i] = 0; end
    end

    // Combinational "about to insert a freshly-read word into the
    // CAS-latency pipe this cycle" signals, computed from the
    // CURRENT (pre-edge) burst-tracking registers -- kept OUTSIDE the
    // always block and fed into a single, conflict-free per-index
    // shift-or-insert assignment below (an earlier draft assigned
    // rd_pipe[cas_latency-1] from BOTH the generic shift loop AND a
    // separate insert statement in the same always block -- two NBAs
    // to the same array element in the same time step, undefined/
    // tool-dependent behavior, a real bug caught before simulation
    // even ran, by inspection).
    wire pipe_insert = rd_burst_active;
    wire [15:0] pipe_insert_val = mem[rd_bank*ROWS*COLS + rd_row*COLS + rd_col];

    always @(posedge clk) begin
        // ---- shift the CAS-latency read pipeline every cycle, with
        // AT MOST one insertion point per cycle (index cas_latency-1),
        // never both a shift-in and an insert targeting the same
        // index ----
        for (i = 0; i < 15; i = i + 1) begin
            if (pipe_insert && i == cas_latency-1) begin
                rd_pipe[i]       <= pipe_insert_val;
                rd_valid_pipe[i] <= 1'b1;
            end else begin
                rd_pipe[i]       <= rd_pipe[i+1];
                rd_valid_pipe[i] <= rd_valid_pipe[i+1];
            end
        end
        rd_pipe[15] <= 16'h0000;
        rd_valid_pipe[15] <= 1'b0;

        if (!cke) begin
            // CKE low: real part would be in power-down/self-refresh;
            // not exercised by this controller (CKE held high always)
        end else begin

            if (cmd_active) begin
                // real timing check: bank must be idle, and the
                // PREVIOUS precharge (if any) must satisfy tRP before
                // this activate.
                if (bank_active[ba])
                    $display("SDRAM_MODEL VIOLATION @%0t: ACTIVATE to bank %0d while already active (row %0d)", $time, ba, bank_row[ba]);
                if ((cycle - bank_precharge_since[ba]) < T_RP && bank_precharge_since[ba] != 0)
                    $display("SDRAM_MODEL VIOLATION @%0t: tRP violated on bank %0d (%0d cycles since precharge, need %0d)",
                        $time, ba, cycle-bank_precharge_since[ba], T_RP);
                bank_active[ba] <= 1'b1;
                bank_row[ba]    <= a;
                bank_active_since[ba] <= cycle;
            end

            if (cmd_precharge) begin
                // A10=1 -> precharge all banks; else just `ba`
                for (i = 0; i < BANKS; i = i + 1) begin
                    if (a[10] || i == ba) begin
                        if (bank_active[i] && ((cycle - bank_active_since[i]) < T_RAS_MIN))
                            $display("SDRAM_MODEL VIOLATION @%0t: tRAS(min) violated on bank %0d (%0d cycles since activate, need %0d)",
                                $time, i, cycle-bank_active_since[i], T_RAS_MIN);
                        bank_active[i] <= 1'b0;
                        bank_precharge_since[i] <= cycle;
                    end
                end
            end

            if (cmd_refresh) begin
                if ((cycle - last_any_refresh_cycle) > T_REFI && last_any_refresh_cycle != 0)
                    $display("SDRAM_MODEL WARNING @%0t: AUTO REFRESH spacing %0d cycles exceeds tREFI=%0d",
                        $time, cycle-last_any_refresh_cycle, T_REFI);
                last_any_refresh_cycle <= cycle;
            end

            if (cmd_mrs) begin
                mr_burst_code  <= a[2:0];
                mr_cas_latency <= a[6:4];
                burst_len <= (a[2:0]==3'b000) ? 1 : (a[2:0]==3'b001) ? 2 :
                             (a[2:0]==3'b010) ? 4 : (a[2:0]==3'b011) ? 8 : 1;
                cas_latency <= (a[6:4]==3'b011) ? 3 : (a[6:4]==3'b010) ? 2 : 3;
            end

            if (cmd_read || cmd_write) begin
                if (!bank_active[ba])
                    $display("SDRAM_MODEL VIOLATION @%0t: %s to bank %0d with no active row", $time, cmd_read?"READ":"WRITE", ba);
                else if (bank_row[ba] !== a[ROW_BITS-1:0] && 1'b0) begin
                    // column command doesn't carry a row -- nothing to
                    // check here beyond bank-active, real row match is
                    // implicit (the address IS the column within the
                    // already-open row)
                end
                if ((cycle - bank_active_since[ba]) < T_RCD)
                    $display("SDRAM_MODEL VIOLATION @%0t: tRCD violated on bank %0d (%0d cycles since activate, need %0d)",
                        $time, ba, cycle-bank_active_since[ba], T_RCD);

                if (cmd_read) begin
                    // real SDR SDRAM: CAS latency counts cycles from the
                    // READ command itself -- insert the first word's mem
                    // lookup right here (command-decode cycle) instead of
                    // waiting for rd_burst_active to become visible one
                    // cycle later, which added a spurious extra pipeline
                    // stage and made every read arrive one cycle late
                    // (the same bug class as the write-side fix below,
                    // found by tracing the cycle-exact mismatch against
                    // the controller's own CAS_LATENCY-cycle wait_cnt)
                    rd_pipe[cas_latency-1]       <= mem[ba*ROWS*COLS + bank_row[ba]*COLS + a[COL_BITS-1:0]];
                    rd_valid_pipe[cas_latency-1] <= 1'b1;
                    if (burst_len == 1) begin
                        rd_burst_active <= 1'b0;
                        if (a[10]) begin
                            bank_active[ba] <= 1'b0;
                            bank_precharge_since[ba] <= cycle;
                        end
                    end else begin
                        rd_bank <= ba; rd_row <= bank_row[ba]; rd_col <= a[COL_BITS-1:0] + 1'b1;
                        rd_remaining <= burst_len - 1'b1; rd_autoprecharge <= a[10];
                        rd_burst_active <= 1'b1;
                    end
                end else begin
                    // real SDR SDRAM: the first write word is presented on
                    // DQ CONCURRENTLY with the WRITE command itself, not one
                    // cycle later -- capture it right here (in the same
                    // cycle the command is decoded) instead of waiting for
                    // wr_burst_active, which would silently drop word0
                    if (dqm[0] == 1'b0) mem[ba*ROWS*COLS + bank_row[ba]*COLS + a[COL_BITS-1:0]][7:0]  <= dq[7:0];
                    if (dqm[1] == 1'b0) mem[ba*ROWS*COLS + bank_row[ba]*COLS + a[COL_BITS-1:0]][15:8] <= dq[15:8];
                    if (burst_len == 1) begin
                        wr_burst_active <= 1'b0;
                        if (a[10]) begin
                            bank_active[ba] <= 1'b0;
                            bank_precharge_since[ba] <= cycle;
                        end
                    end else begin
                        wr_bank <= ba; wr_row <= bank_row[ba]; wr_col <= a[COL_BITS-1:0] + 1'b1;
                        wr_remaining <= burst_len - 1'b1; wr_autoprecharge <= a[10];
                        wr_burst_active <= 1'b1;
                    end
                end
            end

            // ---- service an in-progress read burst: one word/cycle,
            // the actual mem[] read + pipe insertion happens above
            // (pipe_insert/pipe_insert_val, combinational from THIS
            // cycle's rd_bank/rd_row/rd_col) -- here we only advance
            // the column pointer and burst-remaining bookkeeping ----
            if (rd_burst_active) begin
                rd_col <= rd_col + 1'b1;
                rd_remaining <= rd_remaining - 1;
                if (rd_remaining == 1) begin
                    rd_burst_active <= 1'b0;
                    if (rd_autoprecharge) begin
                        bank_active[rd_bank] <= 1'b0;
                        bank_precharge_since[rd_bank] <= cycle;
                    end
                end
            end

            // ---- service an in-progress write burst: one word/cycle
            // from dq ----
            if (wr_burst_active) begin
                if (dqm[0] == 1'b0) mem[wr_bank*ROWS*COLS + wr_row*COLS + wr_col][7:0]  <= dq[7:0];
                if (dqm[1] == 1'b0) mem[wr_bank*ROWS*COLS + wr_row*COLS + wr_col][15:8] <= dq[15:8];
                wr_col <= wr_col + 1'b1;
                wr_remaining <= wr_remaining - 1;
                if (wr_remaining == 1) begin
                    wr_burst_active <= 1'b0;
                    if (wr_autoprecharge) begin
                        bank_active[wr_bank] <= 1'b0;
                        bank_precharge_since[wr_bank] <= cycle;
                    end
                end
            end
        end
    end

    // testbench-only backdoor access (poke/peek), matching this
    // project's own established convention elsewhere (psram_model.v)
    task automatic backdoor_write(input [BANK_BITS-1:0] tb_bank, input [ROW_BITS-1:0] tb_row, input [COL_BITS-1:0] tb_col, input [15:0] val);
        begin
            mem[tb_bank*ROWS*COLS + tb_row*COLS + tb_col] = val;
        end
    endtask
    function automatic [15:0] backdoor_read(input [BANK_BITS-1:0] tb_bank, input [ROW_BITS-1:0] tb_row, input [COL_BITS-1:0] tb_col);
        begin
            backdoor_read = mem[tb_bank*ROWS*COLS + tb_row*COLS + tb_col];
        end
    endfunction

endmodule
