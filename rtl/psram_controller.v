module psram_controller #(
    parameter ADDR_WIDTH   = 23,
    parameter DATA_WIDTH   = 16,
    parameter CLK_FREQ_MHZ = 80
)(
    input  wire                   clk,
    input  wire                   rst,

    // ============================================================
    // Memory Interface side
    // ============================================================

    input  wire                   mem_req,
    input  wire                   mem_wr,
    input  wire [ADDR_WIDTH-1:0]  mem_addr,
    input  wire [DATA_WIDTH-1:0]  mem_wdata,
    input  wire                   mem_lb_n,
    input  wire                   mem_ub_n,

    output reg  [DATA_WIDTH-1:0]  mem_rdata,
    output reg                    mem_ready,

    // ============================================================
    // PSRAM physical interface
    // ============================================================

    output reg  [ADDR_WIDTH-1:0]  psram_a,

    inout  wire [DATA_WIDTH-1:0]  psram_dq,

    output reg                    psram_ce_n,
    output reg                    psram_oe_n,
    output reg                    psram_we_n,
    output reg                    psram_lb_n,
    output reg                    psram_ub_n,
    output reg                    psram_zz_n
);

    // ============================================================
    // Timing
    // ============================================================

    localparam integer ACCESS_CYCLES =
        ((70 * CLK_FREQ_MHZ) + 999) / 1000;

    localparam integer INIT_CYCLES =
        150 * CLK_FREQ_MHZ;

    localparam integer COUNTER_WIDTH =
        (INIT_CYCLES <= 1) ? 1 : $clog2(INIT_CYCLES + 1);

    // ============================================================
    // State machine
    // ============================================================

    localparam [2:0]
        STATE_INIT       = 3'd0,
        STATE_IDLE       = 3'd1,
        STATE_READ       = 3'd2,
        STATE_WRITE      = 3'd3,
        STATE_WRITE_WAIT = 3'd4;

    reg [2:0] state;
    reg [COUNTER_WIDTH-1:0] counter;

    // ============================================================
    // Latched transaction
    // ============================================================

    reg [ADDR_WIDTH-1:0] address_reg;
    reg [DATA_WIDTH-1:0] wdata_reg;
    reg                   wr_reg;

    // ============================================================
    // Latched byte enables
    //
    // Active LOW:
    //   0 = byte enabled
    //   1 = byte disabled
    // ============================================================

    reg lb_reg;
    reg ub_reg;

    // ============================================================
    // PSRAM data bus control
    // ============================================================

    reg [DATA_WIDTH-1:0] dq_out;
    reg                   dq_oe;

    assign psram_dq =
        dq_oe ? dq_out : {DATA_WIDTH{1'bz}};

    // ============================================================
    // Main state machine
    // ============================================================

    always @(posedge clk) begin

        if (rst) begin

            // ----------------------------------------------------
            // State
            // ----------------------------------------------------

            state   <= STATE_INIT;
            counter <= 0;

            // ----------------------------------------------------
            // Transaction registers
            // ----------------------------------------------------

            address_reg <= {ADDR_WIDTH{1'b0}};
            wdata_reg   <= {DATA_WIDTH{1'b0}};
            wr_reg      <= 1'b0;

            // Byte enables disabled during reset
            lb_reg <= 1'b1;
            ub_reg <= 1'b1;

            // ----------------------------------------------------
            // Memory interface
            // ----------------------------------------------------

            mem_rdata <= {DATA_WIDTH{1'b0}};
            mem_ready <= 1'b0;

            // ----------------------------------------------------
            // PSRAM address
            // ----------------------------------------------------

            psram_a <= {ADDR_WIDTH{1'b0}};

            // ----------------------------------------------------
            // PSRAM control
            // ----------------------------------------------------

            psram_ce_n <= 1'b1;
            psram_oe_n <= 1'b1;
            psram_we_n <= 1'b1;

            psram_lb_n <= 1'b1;
            psram_ub_n <= 1'b1;

            psram_zz_n <= 1'b1;

            // ----------------------------------------------------
            // Data bus
            // ----------------------------------------------------

            dq_out <= {DATA_WIDTH{1'b0}};
            dq_oe  <= 1'b0;

        end else begin

            // mem_ready is a one-cycle pulse
            mem_ready <= 1'b0;

            case (state)

                // =================================================
                // PSRAM power-up initialization
                // =================================================

                STATE_INIT: begin

                    psram_ce_n <= 1'b1;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    if (counter == INIT_CYCLES - 1) begin

                        counter <= 0;
                        state   <= STATE_IDLE;

                    end else begin

                        counter <= counter + 1'b1;

                    end
                end

                // =================================================
                // Idle
                // =================================================

                STATE_IDLE: begin

                    psram_ce_n <= 1'b1;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    if (mem_req) begin

                        // ------------------------------------------------
                        // Latch transaction
                        // ------------------------------------------------

                        address_reg <= mem_addr;
                        wdata_reg   <= mem_wdata;
                        wr_reg      <= mem_wr;

                        // ------------------------------------------------
                        // Latch byte enables
                        // ------------------------------------------------

                        lb_reg <= mem_lb_n;
                        ub_reg <= mem_ub_n;

                        // ------------------------------------------------
                        // Address
                        // ------------------------------------------------

                        psram_a <= mem_addr;

                        // ------------------------------------------------
                        // Apply byte enables immediately
                        // ------------------------------------------------

                        psram_lb_n <= mem_lb_n;
                        psram_ub_n <= mem_ub_n;

                        psram_ce_n <= 1'b0;

                        counter <= 0;

                        // =================================================
                        // WRITE
                        // =================================================

                        if (mem_wr) begin

                            dq_out <= mem_wdata;
                            dq_oe  <= 1'b1;

                            psram_we_n <= 1'b0;
                            psram_oe_n <= 1'b1;

                            state <= STATE_WRITE;

                        end

                        // =================================================
                        // READ
                        // =================================================

                        else begin

                            dq_oe <= 1'b0;

                            psram_we_n <= 1'b1;
                            psram_oe_n <= 1'b0;

                            state <= STATE_READ;

                        end
                    end
                end

                // =================================================
                // READ
                // =================================================

                STATE_READ: begin

                    psram_ce_n <= 1'b0;
                    psram_oe_n <= 1'b0;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    if (counter == ACCESS_CYCLES - 1) begin

                        // ------------------------------------------------
                        // Capture PSRAM data
                        // ------------------------------------------------

                        mem_rdata <= psram_dq;
                        mem_ready <= 1'b1;

                        // ------------------------------------------------
                        // End transaction
                        // ------------------------------------------------

                        psram_ce_n <= 1'b1;
                        psram_oe_n <= 1'b1;

                        psram_lb_n <= 1'b1;
                        psram_ub_n <= 1'b1;

                        counter <= 0;
                        state   <= STATE_IDLE;

                    end else begin

                        counter <= counter + 1'b1;

                    end
                end

                // =================================================
                // WRITE
                // =================================================

                STATE_WRITE: begin

                    psram_ce_n <= 1'b0;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b0;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b1;

                    if (counter == ACCESS_CYCLES - 1) begin

                        // ------------------------------------------------
                        // End WE# pulse
                        // ------------------------------------------------

                        psram_we_n <= 1'b1;

                        counter <= 0;
                        state   <= STATE_WRITE_WAIT;

                    end else begin

                        counter <= counter + 1'b1;

                    end
                end

                // =================================================
                // WRITE WAIT
                //
                // Keep CE#/LB#/UB# active for the final write hold
                // interval before releasing the transaction.
                // =================================================

                STATE_WRITE_WAIT: begin

                    psram_ce_n <= 1'b0;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= lb_reg;
                    psram_ub_n <= ub_reg;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    // ------------------------------------------------
                    // Release PSRAM
                    // ------------------------------------------------

                    psram_ce_n <= 1'b1;
                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    // ------------------------------------------------
                    // Transaction complete
                    // ------------------------------------------------

                    mem_ready <= 1'b1;

                    state <= STATE_IDLE;
                end

                // =================================================
                // Default recovery
                // =================================================

                default: begin

                    state   <= STATE_INIT;
                    counter <= 0;

                    psram_ce_n <= 1'b1;
                    psram_oe_n <= 1'b1;
                    psram_we_n <= 1'b1;

                    psram_lb_n <= 1'b1;
                    psram_ub_n <= 1'b1;

                    psram_zz_n <= 1'b1;

                    dq_oe <= 1'b0;

                    lb_reg <= 1'b1;
                    ub_reg <= 1'b1;

                end

            endcase
        end
    end

endmodule