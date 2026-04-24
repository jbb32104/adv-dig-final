`timescale 1ns / 1ps

// DDR2 memory arbiter — write-only, two prime streams.
// Reads from two FWFT FIFOs (6k+1 and 6k-1 prime bitmaps) and writes
// their contents to separate DDR2 address regions via the MIG native port.
//
// Round-robin arbitration between the two streams.
// All MIG and FIFO outputs are properly registered.
//
// MIG write handshake (per Xilinx UG586):
//   Command accepted when app_en=1 AND app_rdy=1 on same posedge.
//   Data    accepted when app_wdf_wren=1 AND app_wdf_rdy=1 on same posedge.
//   Command and data may be accepted on different cycles; both must complete
//   before the transaction is done. cmd_sent_ff / data_sent_ff track this.
//
// FIFO contract: FWFT mode — dout is valid whenever empty=0.
//   rd_en pops the current word and advances to the next.
//   Pop only fires after the MIG has accepted both command and data.
//
// Clock/reset: single domain ui_clk; rst_n is active-low (tie to
// ~ui_clk_sync_rst at the top level).

module mem_arbiter (
    input  wire         ui_clk,
    input  wire         rst_n,
    input  wire         init_calib_complete,

    // ---- Stream A: 6k+1 prime writes ------------------------------------
    input  wire [127:0] prime_plus_rd_data,
    input  wire         prime_plus_empty,
    output reg          prime_plus_rd_en_ff,

    // ---- Stream B: 6k-1 prime writes ------------------------------------
    input  wire [127:0] prime_minus_rd_data,
    input  wire         prime_minus_empty,
    output reg          prime_minus_rd_en_ff,

    // ---- MIG native user interface --------------------------------------
    output reg  [26:0]  app_addr_ff,
    output reg  [2:0]   app_cmd_ff,
    output reg          app_en_ff,
    output reg  [127:0] app_wdf_data_ff,
    output reg          app_wdf_end_ff,
    output reg  [15:0]  app_wdf_mask_ff,
    output reg          app_wdf_wren_ff,
    input  wire         app_rdy,
    input  wire         app_wdf_rdy
);

    // -----------------------------------------------------------------------
    // Address regions (byte addresses; 16 bytes per 128-bit transaction)
    // -----------------------------------------------------------------------
    localparam [26:0] BASE_PLUS  = 27'h000_0000;
    localparam [26:0] BASE_MINUS = 27'h020_0000;
    localparam [2:0]  CMD_WRITE  = 3'b000;

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [1:0] S_IDLE     = 2'd0,
                     S_ISSUE    = 2'd1,
                     S_COOLDOWN = 2'd2;  // 1-cycle wait for FWFT empty to settle

    localparam SEL_PLUS  = 1'b0,
               SEL_MINUS = 1'b1;

    // -----------------------------------------------------------------------
    // State registers
    // -----------------------------------------------------------------------
    reg [1:0]  state_ff;
    reg        sel_ff;              // which stream owns current transaction
    reg [26:0] wr_ptr_plus_ff;
    reg [26:0] wr_ptr_minus_ff;
    reg        rr_ff;               // 0 = prefer plus, 1 = prefer minus
    reg        cmd_sent_ff;         // command accepted this transaction
    reg        data_sent_ff;        // write data accepted this transaction

    // -----------------------------------------------------------------------
    // Next-state
    // -----------------------------------------------------------------------
    reg [1:0]  next_state;
    reg        next_sel;
    reg [26:0] next_wr_ptr_plus;
    reg [26:0] next_wr_ptr_minus;
    reg        next_rr;
    reg        next_cmd_sent;
    reg        next_data_sent;

    // Next MIG outputs
    reg [26:0]  next_app_addr;
    reg [2:0]   next_app_cmd;
    reg         next_app_en;
    reg [127:0] next_app_wdf_data;
    reg         next_app_wdf_end;
    reg [15:0]  next_app_wdf_mask;
    reg         next_app_wdf_wren;

    // Next FIFO pops
    reg         next_prime_plus_rd_en;
    reg         next_prime_minus_rd_en;

    // -----------------------------------------------------------------------
    // Convenience signals
    // -----------------------------------------------------------------------
    wire plus_has_data  = !prime_plus_empty;
    wire minus_has_data = !prime_minus_empty;

    // These are true when the registered output was accepted THIS cycle.
    wire cmd_accepted   = app_en_ff       && app_rdy;
    wire data_accepted  = app_wdf_wren_ff && app_wdf_rdy;

    // -----------------------------------------------------------------------
    // Combinational block
    // -----------------------------------------------------------------------
    always @(*) begin
        // Hold state by default
        next_state        = state_ff;
        next_sel          = sel_ff;
        next_wr_ptr_plus  = wr_ptr_plus_ff;
        next_wr_ptr_minus = wr_ptr_minus_ff;
        next_rr           = rr_ff;
        next_cmd_sent     = cmd_sent_ff;
        next_data_sent    = data_sent_ff;

        // MIG defaults: deassert enables, hold address/data
        next_app_addr     = app_addr_ff;
        next_app_cmd      = CMD_WRITE;
        next_app_en       = 1'b0;
        next_app_wdf_data = app_wdf_data_ff;
        next_app_wdf_end  = 1'b0;
        next_app_wdf_mask = 16'd0;
        next_app_wdf_wren = 1'b0;

        // FIFO pops default off (one-cycle pulses)
        next_prime_plus_rd_en  = 1'b0;
        next_prime_minus_rd_en = 1'b0;

        if (!rst_n) begin
            next_state        = S_IDLE;
            next_sel          = SEL_PLUS;
            next_wr_ptr_plus  = BASE_PLUS;
            next_wr_ptr_minus = BASE_MINUS;
            next_rr           = 1'b0;
            next_cmd_sent     = 1'b0;
            next_data_sent    = 1'b0;
            next_app_addr     = 27'd0;
            next_app_wdf_data = 128'd0;
        end else if (!init_calib_complete) begin
            next_state = S_IDLE;
        end else begin
            case (state_ff)

                // ---------------------------------------------------------
                // IDLE: pick a FIFO with data, capture its word and address,
                //       present command + data to MIG on the next edge.
                // ---------------------------------------------------------
                S_IDLE: begin
                    next_cmd_sent  = 1'b0;
                    next_data_sent = 1'b0;

                    if (plus_has_data && (!rr_ff || !minus_has_data)) begin
                        next_sel          = SEL_PLUS;
                        next_app_addr     = wr_ptr_plus_ff;
                        next_app_wdf_data = prime_plus_rd_data;
                        next_app_en       = 1'b1;
                        next_app_wdf_wren = 1'b1;
                        next_app_wdf_end  = 1'b1;
                        next_state        = S_ISSUE;
                    end else if (minus_has_data) begin
                        next_sel          = SEL_MINUS;
                        next_app_addr     = wr_ptr_minus_ff;
                        next_app_wdf_data = prime_minus_rd_data;
                        next_app_en       = 1'b1;
                        next_app_wdf_wren = 1'b1;
                        next_app_wdf_end  = 1'b1;
                        next_state        = S_ISSUE;
                    end
                end

                // ---------------------------------------------------------
                // ISSUE: hold command/data until MIG accepts both halves.
                // Once both are accepted, pop the FIFO and advance the
                // write pointer.
                // ---------------------------------------------------------
                S_ISSUE: begin
                    // -- Command handshake --
                    if (!cmd_sent_ff) begin
                        if (cmd_accepted) begin
                            next_cmd_sent = 1'b1;
                            // next_app_en stays 0 (default)
                        end else begin
                            next_app_en = 1'b1;     // hold until accepted
                        end
                    end

                    // -- Data handshake --
                    if (!data_sent_ff) begin
                        if (data_accepted) begin
                            next_data_sent = 1'b1;
                            // next_app_wdf_wren stays 0 (default)
                        end else begin
                            next_app_wdf_wren = 1'b1;
                            next_app_wdf_end  = 1'b1;
                        end
                    end

                    // -- Transaction complete --
                    if ((cmd_sent_ff  || cmd_accepted) &&
                        (data_sent_ff || data_accepted)) begin
                        if (sel_ff == SEL_PLUS) begin
                            next_prime_plus_rd_en = 1'b1;
                            next_wr_ptr_plus      = wr_ptr_plus_ff + 27'd16;
                            next_rr               = 1'b1;   // next: prefer minus
                        end else begin
                            next_prime_minus_rd_en = 1'b1;
                            next_wr_ptr_minus      = wr_ptr_minus_ff + 27'd16;
                            next_rr                = 1'b0;   // next: prefer plus
                        end
                        next_state = S_COOLDOWN;
                    end
                end

                // ---------------------------------------------------------
                // COOLDOWN: wait one cycle after FIFO pop for the FWFT
                // empty flag to settle through the output register.
                // Without this, a stale empty=0 can cause a phantom
                // re-read of the last word.
                // ---------------------------------------------------------
                S_COOLDOWN: begin
                    next_state = S_IDLE;
                end

                default: next_state = S_IDLE;

            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — all flops
    // -----------------------------------------------------------------------
    always @(posedge ui_clk) begin
        state_ff        <= next_state;
        sel_ff          <= next_sel;
        wr_ptr_plus_ff  <= next_wr_ptr_plus;
        wr_ptr_minus_ff <= next_wr_ptr_minus;
        rr_ff           <= next_rr;
        cmd_sent_ff     <= next_cmd_sent;
        data_sent_ff    <= next_data_sent;

        app_addr_ff     <= next_app_addr;
        app_cmd_ff      <= next_app_cmd;
        app_en_ff       <= next_app_en;
        app_wdf_data_ff <= next_app_wdf_data;
        app_wdf_end_ff  <= next_app_wdf_end;
        app_wdf_mask_ff <= next_app_wdf_mask;
        app_wdf_wren_ff <= next_app_wdf_wren;

        prime_plus_rd_en_ff  <= next_prime_plus_rd_en;
        prime_minus_rd_en_ff <= next_prime_minus_rd_en;
    end

endmodule
