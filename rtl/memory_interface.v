module memory_interface #(
    parameter ADDR_WIDTH = 22,
    parameter DATA_WIDTH = 16
)(
    input  wire                   clk,
    input  wire                   rst,

    input  wire                   req,
    input  wire                   wr,
    input  wire [ADDR_WIDTH-1:0]  addr,
    input  wire [DATA_WIDTH-1:0]  wdata,
    input  wire                   lb_n,
    input  wire                   ub_n,

    output reg  [DATA_WIDTH-1:0]  rdata,
    output reg                    ready,

    output reg                    mem_req,
    output reg                    mem_wr,
    output reg  [ADDR_WIDTH-1:0]  mem_addr,
    output reg  [DATA_WIDTH-1:0]  mem_wdata,
    output reg                    mem_lb_n,
    output reg                    mem_ub_n,

    input  wire [DATA_WIDTH-1:0]  mem_rdata,
    input  wire                   mem_ready
);
    localparam STATE_IDLE   = 2'd0;
    localparam STATE_WAIT   = 2'd1;

    reg [1:0] state;

    always @(posedge clk) begin
        if (rst) begin
            state     <= STATE_IDLE;

            rdata     <= {DATA_WIDTH{1'b0}};
            ready     <= 1'b0;

            mem_lb_n <= 1'b1;
            mem_ub_n <= 1'b1;

            mem_req   <= 1'b0;
            mem_wr    <= 1'b0;
            mem_addr  <= {ADDR_WIDTH{1'b0}};
            mem_wdata <= {DATA_WIDTH{1'b0}};

        end else begin

            // Default: pulses
            ready   <= 1'b0;
            mem_req <= 1'b0;

            case (state)

                STATE_IDLE: begin
                    if (req) begin

                        // Latch transaction
                        mem_wr    <= wr;
                        mem_addr  <= addr;
                        mem_wdata <= wdata;
                        mem_lb_n <= lb_n;
                        mem_ub_n <= ub_n;
                        // Issue exactly one-cycle request
                        mem_req <= 1'b1;

                        state <= STATE_WAIT;
                    end
                end

                STATE_WAIT: begin

                    // Wait for memory completion
                    if (mem_ready) begin

                        if (!mem_wr)
                            rdata <= mem_rdata;

                        ready <= 1'b1;

                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end

            endcase
        end
    end

endmodule