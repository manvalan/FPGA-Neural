module int8_memory_access #(
    parameter ADDR_WIDTH = 22
)(
    input  wire                  clk,
    input  wire                  rst,

    // ============================================================
    // INT8 interface
    //
    // addr is BYTE address
    // ============================================================

    input  wire                  req,
    input  wire                  wr,
    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire signed [7:0]     wdata,

    output reg  signed [7:0]     rdata,
    output reg                   ready,

    // ============================================================
    // 16-bit memory interface
    // ============================================================

    output reg                   mem_req,
    output reg                   mem_wr,
    output reg  [ADDR_WIDTH-1:0] mem_addr,
    output reg  [15:0]            mem_wdata,
    output reg                    mem_lb_n,
    output reg                    mem_ub_n,

    input  wire [15:0]             mem_rdata,
    input  wire                    mem_ready
);

    // ============================================================
    // State machine
    // ============================================================

    localparam STATE_IDLE = 2'd0;
    localparam STATE_WAIT = 2'd1;

    reg [1:0] state;

    // ============================================================
    // Latched byte address
    // ============================================================

    reg [ADDR_WIDTH-1:0] addr_reg;

    // ============================================================
    // Main state machine
    // ============================================================

    always @(posedge clk) begin

        if (rst) begin

            state <= STATE_IDLE;

            addr_reg <= {ADDR_WIDTH{1'b0}};

            rdata <= 8'sd0;
            ready <= 1'b0;

            mem_req   <= 1'b0;
            mem_wr    <= 1'b0;
            mem_addr  <= {ADDR_WIDTH{1'b0}};
            mem_wdata <= 16'h0000;

            // Active-low byte enables:
            // 1 = disabled
            mem_lb_n <= 1'b1;
            mem_ub_n <= 1'b1;

        end else begin

            // ready is a one-cycle pulse
            ready <= 1'b0;

            // mem_req is a one-cycle pulse
            mem_req <= 1'b0;

            case (state)

                // =================================================
                // IDLE
                // =================================================

                STATE_IDLE: begin

                    if (req) begin

                        addr_reg <= addr;

                        mem_req <= 1'b1;
                        mem_wr  <= wr;

                        // ------------------------------------------------
                        // Byte address -> 16-bit word address
                        //
                        // addr[0] = 0 -> low byte
                        // addr[0] = 1 -> high byte
                        // ------------------------------------------------

                        mem_addr <= addr >> 1;

                        // ------------------------------------------------
                        // Select byte
                        // ------------------------------------------------

                        if (addr[0] == 1'b0) begin

                            // Low byte
                            mem_lb_n <= 1'b0;
                            mem_ub_n <= 1'b1;

                            // Data goes into DQ[7:0]
                            mem_wdata <= {8'h00, wdata};

                        end else begin

                            // High byte
                            mem_lb_n <= 1'b1;
                            mem_ub_n <= 1'b0;

                            // Data goes into DQ[15:8]
                            mem_wdata <= {wdata, 8'h00};

                        end

                        state <= STATE_WAIT;

                    end
                end

                // =================================================
                // WAIT
                // =================================================

                STATE_WAIT: begin

                    if (mem_ready) begin

                        // ------------------------------------------------
                        // Extract requested byte
                        // ------------------------------------------------

                        if (addr_reg[0] == 1'b0)
                            rdata <= mem_rdata[7:0];
                        else
                            rdata <= mem_rdata[15:8];

                        ready <= 1'b1;

                        state <= STATE_IDLE;

                    end
                end

                // =================================================
                // Default
                // =================================================

                default: begin

                    state <= STATE_IDLE;

                    mem_req   <= 1'b0;
                    mem_lb_n  <= 1'b1;
                    mem_ub_n  <= 1'b1;

                end

            endcase
        end
    end

endmodule