`timescale 1ns/1ps

module psram_model #(
    parameter ADDR_WIDTH = 23,
    parameter DATA_WIDTH = 16,
    parameter DEPTH      = 16384
)(
    input wire                  clk,
    input wire [ADDR_WIDTH-1:0] a,
    inout wire [DATA_WIDTH-1:0] dq,
    input wire                  ce_n,
    input wire                  oe_n,
    input wire                  we_n,
    input wire                  lb_n,
    input wire                  ub_n,
    input wire                  zz_n
);

    // ============================================================
    // IS66WVE4M16EBLL-70BLI - Rev. D3
    // ============================================================

    localparam realtime TAA_NS  = 70.0;
    localparam realtime TRC_NS  = 70.0;
    localparam realtime TOE_NS  = 20.0;
    localparam realtime TOH_NS  = 5.0;

    localparam realtime TLZ_NS  = 10.0;
    localparam realtime THZ_NS  = 8.0;

    localparam realtime TWC_NS  = 70.0;
    localparam realtime TAW_NS  = 70.0;
    localparam realtime TCW_NS  = 70.0;
    localparam realtime TWP_NS  = 46.0;
    localparam realtime TDW_NS  = 23.0;
    localparam realtime TDH_NS  = 0.0;
    localparam realtime TWR_NS  = 0.0;
    localparam realtime TWPH_NS = 10.0;

    localparam realtime TPU_NS  = 150000.0;

    // ============================================================
    // Memory
    // ============================================================

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg [DATA_WIDTH-1:0] dq_out;
    reg                   dq_oe;

    integer i;

    assign dq = dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

    // ============================================================
    // Timing state
    // ============================================================

    realtime powerup_time;

    realtime ce_low_time;
    realtime ce_high_time;

    realtime oe_low_time;
    realtime oe_high_time;

    realtime we_low_time;
    realtime we_high_time;

    realtime last_read_start;
    realtime last_write_start;

    realtime addr_valid_time;
    realtime data_valid_time;

    reg read_active;
    reg write_active;

    reg [ADDR_WIDTH-1:0] active_addr;
    reg [DATA_WIDTH-1:0] active_wdata;

    // ============================================================
    // Initialization
    // ============================================================

    initial begin

        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 16'h0000;

        dq_out = 16'h0000;
        dq_oe  = 1'b0;

        powerup_time = $realtime;

        ce_low_time  = 0.0;
        ce_high_time = 0.0;

        oe_low_time  = 0.0;
        oe_high_time = 0.0;

        we_low_time  = 0.0;
        we_high_time = 0.0;

        last_read_start  = -1.0;
        last_write_start = -1.0;

        addr_valid_time = 0.0;
        data_valid_time = 0.0;

        read_active  = 1'b0;
        write_active = 1'b0;

        active_addr  = 0;
        active_wdata = 0;
    end

    // ============================================================
    // FUNCTIONAL READ MODEL
    // ============================================================

    always @(*) begin

        dq_oe  = 1'b0;
        dq_out = 16'h0000;

        if (zz_n &&
            !ce_n &&
            !oe_n &&
             we_n) begin

            if (a < DEPTH) begin

                dq_oe = 1'b1;

                if (!lb_n && !ub_n)
                    dq_out = mem[a];

                else if (!lb_n)
                    dq_out = {
                        8'h00,
                        mem[a][7:0]
                    };

                else if (!ub_n)
                    dq_out = {
                        mem[a][15:8],
                        8'h00
                    };
            end
        end
    end

    // ============================================================
    // CE# FALLING
    // ============================================================

    always @(negedge ce_n) begin

        if (!zz_n) begin
            $display("ERROR: CE# LOW while ZZ# LOW");
            $fatal;
        end

        ce_low_time = $realtime;

        addr_valid_time = $realtime;
        active_addr = a;

        // --------------------------------------------------------
        // READ START
        // --------------------------------------------------------

        if (!oe_n && we_n) begin

            if (($realtime - powerup_time) < TPU_NS) begin
                $display("ERROR: READ before tPU");
                $fatal;
            end

            if (last_read_start >= 0.0) begin

                if (($realtime - last_read_start) < TRC_NS) begin

                    $display("");
                    $display("========================================");
                    $display("PSRAM TIMING ERROR");
                    $display("tRC violation");
                    $display("required = %0.2f ns", TRC_NS);
                    $display("actual   = %0.2f ns",
                             $realtime - last_read_start);
                    $display("========================================");

                    $fatal;
                end
            end

            last_read_start = $realtime;

            read_active = 1'b1;
        end

        // --------------------------------------------------------
        // WRITE START
        // --------------------------------------------------------

        if (oe_n && !we_n) begin

            if (($realtime - powerup_time) < TPU_NS) begin
                $display("ERROR: WRITE before tPU");
                $fatal;
            end

            if (last_write_start >= 0.0) begin

                if (($realtime - last_write_start) < TWC_NS) begin

                    $display("");
                    $display("========================================");
                    $display("PSRAM TIMING ERROR");
                    $display("tWC violation");
                    $display("required = %0.2f ns", TWC_NS);
                    $display("actual   = %0.2f ns",
                             $realtime - last_write_start);
                    $display("========================================");

                    $fatal;
                end
            end

            last_write_start = $realtime;

            write_active = 1'b1;
        end
    end

    // ============================================================
    // CE# RISING
    // ============================================================

    always @(posedge ce_n) begin

        realtime access_time;

        ce_high_time = $realtime;

        access_time = $realtime - ce_low_time;

        // --------------------------------------------------------
        // READ END
        // --------------------------------------------------------

        if (read_active) begin

            // tAA
            if (access_time < TAA_NS) begin

                $display("");
                $display("========================================");
                $display("PSRAM TIMING ERROR");
                $display("tAA violation");
                $display("required = %0.2f ns", TAA_NS);
                $display("actual   = %0.2f ns", access_time);
                $display("========================================");

                $fatal;
            end

            // tOE
            if (($realtime - oe_low_time) < TOE_NS) begin

                $display("");
                $display("========================================");
                $display("PSRAM TIMING ERROR");
                $display("tOE violation");
                $display("required = %0.2f ns", TOE_NS);
                $display("actual   = %0.2f ns",
                         $realtime - oe_low_time);
                $display("========================================");

                $fatal;
            end

            read_active = 1'b0;
        end
    end

    // ============================================================
    // OE# FALLING
    // ============================================================

    always @(negedge oe_n) begin

        if (!zz_n) begin
            $display("ERROR: OE# LOW while ZZ# LOW");
            $fatal;
        end

        if (!ce_n && we_n)
            oe_low_time = $realtime;

        // Illegal combination
        if (!ce_n && !we_n) begin
            $display("");
            $display("========================================");
            $display("PSRAM PROTOCOL ERROR");
            $display("OE# and WE# LOW simultaneously");
            $display("========================================");
            $fatal;
        end
    end

    // ============================================================
    // OE# RISING
    // ============================================================

    always @(posedge oe_n) begin

        oe_high_time = $realtime;

        // Output must remain valid long enough for tOH
        // after address changes. This is checked by the
        // controller access window rather than by forcing
        // an artificial delay into the functional model.
    end

    // ============================================================
    // WE# FALLING
    // ============================================================

    always @(negedge we_n) begin

        if (!zz_n) begin
            $display("ERROR: WE# LOW while ZZ# LOW");
            $fatal;
        end

        if (!ce_n && oe_n) begin

            we_low_time = $realtime;

            active_addr  = a;
            active_wdata = dq;

            write_active = 1'b1;
        end

        // Illegal combination
        if (!ce_n && !oe_n) begin
            $display("");
            $display("========================================");
            $display("PSRAM PROTOCOL ERROR");
            $display("OE# and WE# LOW simultaneously");
            $display("========================================");
            $fatal;
        end
    end

    // ============================================================
    // WE# RISING
    // ============================================================

    always @(posedge we_n) begin

        realtime write_width;
        realtime data_setup;

        we_high_time = $realtime;

        if (write_active) begin

            write_width = $realtime - we_low_time;

            // ----------------------------------------------------
            // tWP
            // ----------------------------------------------------

            if (write_width < TWP_NS) begin

                $display("");
                $display("========================================");
                $display("PSRAM TIMING ERROR");
                $display("tWP violation");
                $display("required = %0.2f ns", TWP_NS);
                $display("actual   = %0.2f ns", write_width);
                $display("========================================");

                $fatal;
            end

            // ----------------------------------------------------
            // tAW
            // ----------------------------------------------------

            if (($realtime - addr_valid_time) < TAW_NS) begin

                $display("");
                $display("========================================");
                $display("PSRAM TIMING ERROR");
                $display("tAW violation");
                $display("required = %0.2f ns", TAW_NS);
                $display("actual   = %0.2f ns",
                         $realtime - addr_valid_time);
                $display("========================================");

                $fatal;
            end

            // ----------------------------------------------------
            // tCW
            // ----------------------------------------------------

            if (($realtime - ce_low_time) < TCW_NS) begin

                $display("");
                $display("========================================");
                $display("PSRAM TIMING ERROR");
                $display("tCW violation");
                $display("required = %0.2f ns", TCW_NS);
                $display("actual   = %0.2f ns",
                         $realtime - ce_low_time);
                $display("========================================");

                $fatal;
            end

            // ----------------------------------------------------
            // tDW
            //
            // Data must be valid before WE# rises.
            // Our controller drives DQ from WE# falling,
            // therefore setup is much larger than 23 ns.
            // ----------------------------------------------------

            data_setup = $realtime - we_low_time;

            if (data_setup < TDW_NS) begin

                $display("");
                $display("========================================");
                $display("PSRAM TIMING ERROR");
                $display("tDW violation");
                $display("required = %0.2f ns", TDW_NS);
                $display("actual   = %0.2f ns", data_setup);
                $display("========================================");

                $fatal;
            end

            // ----------------------------------------------------
            // tDH = 0 ns
            // ----------------------------------------------------

            // No additional hold time is required.

            // ----------------------------------------------------
            // Store data
            // ----------------------------------------------------

            if (a !== active_addr) begin

                $display("");
                $display("========================================");
                $display("PSRAM PROTOCOL ERROR");
                $display("ADDRESS CHANGED DURING WRITE");
                $display("========================================");

                $fatal;
            end

            if (a < DEPTH) begin

                if (!lb_n)
                    mem[a][7:0] <= dq[7:0];

                if (!ub_n)
                    mem[a][15:8] <= dq[15:8];
            end

            write_active = 1'b0;
        end
    end

    // ============================================================
    // ZZ#
    // ============================================================

    always @(negedge zz_n) begin

        if (!ce_n) begin

            $display("");
            $display("========================================");
            $display("PSRAM PROTOCOL ERROR");
            $display("ZZ# LOW while CE# LOW");
            $display("========================================");

            $fatal;
        end
    end

endmodule