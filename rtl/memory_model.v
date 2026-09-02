module memory_model #(
    parameter ADDR_WIDTH   = 23,
    parameter DATA_WIDTH   = 16,
    parameter DEPTH        = 4096,
    parameter READ_LATENCY = 2
)(
    input  wire                   clk,
    input  wire                   rst,

    input  wire                   req,
    input  wire                   wr,
    input  wire [ADDR_WIDTH-1:0]  addr,
    input  wire [DATA_WIDTH-1:0]  wdata,

    output reg  [DATA_WIDTH-1:0]  rdata,
    output reg                    ready
);

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    reg                   busy;
    reg                   pending_wr;
    reg [ADDR_WIDTH-1:0]  pending_addr;
    reg [DATA_WIDTH-1:0]  pending_wdata;

    integer delay_count;
    integer i;

    always @(posedge clk) begin
        if (rst) begin

            rdata         <= {DATA_WIDTH{1'b0}};
            ready         <= 1'b0;

            busy          <= 1'b0;
            pending_wr    <= 1'b0;
            pending_addr  <= {ADDR_WIDTH{1'b0}};
            pending_wdata <= {DATA_WIDTH{1'b0}};

            delay_count   <= 0;

            for (i = 0; i < DEPTH; i = i + 1)
                mem[i] <= {DATA_WIDTH{1'b0}};

        end else begin

            // ready is a one-cycle pulse
            ready <= 1'b0;

            // ----------------------------------------------------
            // Accept request
            // ----------------------------------------------------

            if (!busy) begin

                if (req) begin

                    busy          <= 1'b1;
                    pending_wr    <= wr;
                    pending_addr  <= addr;
                    pending_wdata <= wdata;

                    delay_count   <= READ_LATENCY;
                end

            end else begin

                // ------------------------------------------------
                // Wait
                // ------------------------------------------------

                if (delay_count > 0) begin

                    delay_count <= delay_count - 1;

                end else begin

                    // --------------------------------------------
                    // Complete transaction
                    // --------------------------------------------

                    if (pending_wr) begin

                        // WRITE
                        if (pending_addr < DEPTH)
                            mem[pending_addr] <= pending_wdata;

                    end else begin

                        // READ
                        if (pending_addr < DEPTH)
                            rdata <= mem[pending_addr];
                        else
                            rdata <= {DATA_WIDTH{1'b0}};

                    end

                    ready <= 1'b1;
                    busy  <= 1'b0;
                end
            end
        end
    end

endmodule