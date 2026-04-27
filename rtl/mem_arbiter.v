`timescale 1ns / 1ps

// DDR2 memory arbiter — 4-port, read + write support.
//
// Requestors (priority order, highest first):
//   Port 0: VGA reader      — DDR2 reads to fill pixel_fifo (cannot miss pixels)
//   Port 1: Frame renderer  — DDR2 writes during screen transitions
//   Port 2: Prime plus      — 6k+1 bitmap writes from FIFO (round-robin with minus)
//   Port 3: Prime minus     — 6k-1 bitmap writes from FIFO (round-robin with plus)
//
// MIG write handshake (per Xilinx UG586):
//   Command accepted when app_en=1 AND app_rdy=1 on same posedge.
//   Data    accepted when app_wdf_wren=1 AND app_wdf_rdy=1 on same posedge.
//   Command and data may be accepted on different cycles; both must complete
//   before the transaction is done. cmd_sent_ff / data_sent_ff track this.
//
// MIG read handshake:
//   Command accepted same as write (app_en + app_rdy), but no write data phase.
//   Read data returns later via app_rd_data / app_rd_data_valid.
//   Since VGA reader is the only read requestor, rd_data/rd_data_valid are
//   directly passed through — no routing needed.
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
    input  wire         bitmap_reset,       // pulse: reset write pointers for new run

    // ---- Port 0: VGA read (highest priority) --------------------------------
    input  wire         vga_rd_req,         // pulse: request one 128-bit read
    input  wire [26:0]  vga_rd_addr,        // byte address for the read
    output reg          vga_rd_grant_ff,    // pulse: read command accepted by MIG

    // ---- Port 1: Frame renderer write ---------------------------------------
    input  wire         render_wr_req,      // pulse: request one 128-bit write
    input  wire [26:0]  render_wr_addr,     // byte address for the write
    input  wire [127:0] render_wr_data,     // 128-bit data to write
    output reg          render_wr_grant_ff, // pulse: write transaction complete

    // ---- Port 2: 6k+1 prime writes (auto-address from FIFO) -----------------
    input  wire [127:0] prime_plus_rd_data,
    input  wire         prime_plus_empty,
    output reg          prime_plus_rd_en_ff,

    // ---- Port 3: 6k-1 prime writes (auto-address from FIFO) -----------------
    input  wire [127:0] prime_minus_rd_data,
    input  wire         prime_minus_empty,
    output reg          prime_minus_rd_en_ff,

    // ---- MIG native user interface ------------------------------------------
    output reg  [26:0]  app_addr_ff,
    output reg  [2:0]   app_cmd_ff,
    output reg          app_en_ff,
    output reg  [127:0] app_wdf_data_ff,
    output reg          app_wdf_end_ff,
    output reg  [15:0]  app_wdf_mask_ff,
    output reg          app_wdf_wren_ff,
    input  wire         app_rdy,
    input  wire         app_wdf_rdy,

    // ---- MIG read data (directly passed through to VGA reader) --------------
    input  wire [127:0] app_rd_data,
    input  wire         app_rd_data_valid,
    input  wire         app_rd_data_end,
    output wire [127:0] rd_data,
    output wire         rd_data_valid
);

    // -----------------------------------------------------------------------
    // Address regions (byte addresses; 16 bytes per 128-bit transaction)
    // Each prime region: 0x28_0000 bytes = 2,621,440 bytes = 20,971,520 bits
    // -----------------------------------------------------------------------
    localparam [26:0] BASE_PLUS  = 27'h000_0000;
    localparam [26:0] BASE_MINUS = 27'h028_0000;

    localparam [2:0] CMD_WRITE = 3'b000;
    localparam [2:0] CMD_READ  = 3'b001;

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [1:0] S_IDLE     = 2'd0,
                     S_ISSUE    = 2'd1,
                     S_COOLDOWN = 2'd2;

    // Requestor select encoding
    localparam [1:0] SEL_VGA_RD = 2'd0,
                     SEL_RENDER = 2'd1,
                     SEL_PLUS   = 2'd2,
                     SEL_MINUS  = 2'd3;

    // -----------------------------------------------------------------------
    // State registers
    // -----------------------------------------------------------------------
    reg [1:0]  state_ff;
    reg [1:0]  sel_ff;              // which requestor owns current transaction
    reg [26:0] wr_ptr_plus_ff;
    reg [26:0] wr_ptr_minus_ff;
    reg        rr_ff;               // 0 = prefer plus, 1 = prefer minus
    reg        cmd_sent_ff;
    reg        data_sent_ff;

    // -----------------------------------------------------------------------
    // Next-state
    // -----------------------------------------------------------------------
    reg [1:0]  next_state;
    reg [1:0]  next_sel;
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

    // Next grant/pop signals
    reg         next_vga_rd_grant;
    reg         next_render_wr_grant;
    reg         next_prime_plus_rd_en;
    reg         next_prime_minus_rd_en;

    // -----------------------------------------------------------------------
    // Convenience signals
    // -----------------------------------------------------------------------
    wire plus_has_data  = !prime_plus_empty;
    wire minus_has_data = !prime_minus_empty;

    wire cmd_accepted   = app_en_ff       && app_rdy;
    wire data_accepted  = app_wdf_wren_ff && app_wdf_rdy;

    // Read data passthrough (VGA reader is the only read requestor)
    assign rd_data       = app_rd_data;
    assign rd_data_valid = app_rd_data_valid;

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
        next_app_cmd      = app_cmd_ff;
        next_app_en       = 1'b0;
        next_app_wdf_data = app_wdf_data_ff;
        next_app_wdf_end  = 1'b0;
        next_app_wdf_mask = 16'd0;
        next_app_wdf_wren = 1'b0;

        // Grant/pop defaults off (one-cycle pulses)
        next_vga_rd_grant      = 1'b0;
        next_render_wr_grant   = 1'b0;
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
            next_app_cmd      = CMD_WRITE;
            next_app_wdf_data = 128'd0;
        end else if (!init_calib_complete) begin
            next_state = S_IDLE;
        end else begin
            case (state_ff)

                // ---------------------------------------------------------
                // IDLE: pick highest-priority requestor with pending work.
                //   Priority: VGA read > renderer write > prime (round-robin)
                // ---------------------------------------------------------
                S_IDLE: begin
                    next_cmd_sent  = 1'b0;
                    next_data_sent = 1'b0;

                    // Reset bitmap write pointers on new computation run.
                    // Safe here: FIFOs are empty between runs, arbiter is idle.
                    if (bitmap_reset) begin
                        next_wr_ptr_plus  = BASE_PLUS;
                        next_wr_ptr_minus = BASE_MINUS;
                    end

                    if (vga_rd_req) begin
                        // --- VGA read (highest priority) ---
                        next_sel          = SEL_VGA_RD;
                        next_app_addr     = vga_rd_addr;
                        next_app_cmd      = CMD_READ;
                        next_app_en       = 1'b1;
                        // No write data for reads
                        next_data_sent    = 1'b1;
                        next_state        = S_ISSUE;

                    end else if (render_wr_req) begin
                        // --- Frame renderer write ---
                        next_sel          = SEL_RENDER;
                        next_app_addr     = render_wr_addr;
                        next_app_cmd      = CMD_WRITE;
                        next_app_en       = 1'b1;
                        next_app_wdf_data = render_wr_data;
                        next_app_wdf_wren = 1'b1;
                        next_app_wdf_end  = 1'b1;
                        next_state        = S_ISSUE;

                    end else if (plus_has_data && (!rr_ff || !minus_has_data)) begin
                        // --- Prime plus write ---
                        next_sel          = SEL_PLUS;
                        next_app_addr     = wr_ptr_plus_ff;
                        next_app_cmd      = CMD_WRITE;
                        next_app_en       = 1'b1;
                        next_app_wdf_data = prime_plus_rd_data;
                        next_app_wdf_wren = 1'b1;
                        next_app_wdf_end  = 1'b1;
                        next_state        = S_ISSUE;

                    end else if (minus_has_data) begin
                        // --- Prime minus write ---
                        next_sel          = SEL_MINUS;
                        next_app_addr     = wr_ptr_minus_ff;
                        next_app_cmd      = CMD_WRITE;
                        next_app_en       = 1'b1;
                        next_app_wdf_data = prime_minus_rd_data;
                        next_app_wdf_wren = 1'b1;
                        next_app_wdf_end  = 1'b1;
                        next_state        = S_ISSUE;
                    end
                end

                // ---------------------------------------------------------
                // ISSUE: hold command/data until MIG accepts.
                //
                // For reads:  only command acceptance needed (data_sent
                //             is pre-set to 1 in IDLE).
                // For writes: both command and data must be accepted.
                // ---------------------------------------------------------
                S_ISSUE: begin
                    // -- Command handshake --
                    if (!cmd_sent_ff) begin
                        if (cmd_accepted) begin
                            next_cmd_sent = 1'b1;
                        end else begin
                            next_app_en = 1'b1;
                        end
                    end

                    // -- Data handshake (skipped for reads via data_sent=1) --
                    if (!data_sent_ff) begin
                        if (data_accepted) begin
                            next_data_sent = 1'b1;
                        end else begin
                            next_app_wdf_wren = 1'b1;
                            next_app_wdf_end  = 1'b1;
                        end
                    end

                    // -- Transaction complete --
                    if ((cmd_sent_ff  || cmd_accepted) &&
                        (data_sent_ff || data_accepted)) begin

                        case (sel_ff)
                            SEL_VGA_RD: begin
                                next_vga_rd_grant = 1'b1;
                            end
                            SEL_RENDER: begin
                                next_render_wr_grant = 1'b1;
                            end
                            SEL_PLUS: begin
                                next_prime_plus_rd_en = 1'b1;
                                next_wr_ptr_plus      = wr_ptr_plus_ff + 27'd16;
                                next_rr               = 1'b1;
                            end
                            SEL_MINUS: begin
                                next_prime_minus_rd_en = 1'b1;
                                next_wr_ptr_minus      = wr_ptr_minus_ff + 27'd16;
                                next_rr                = 1'b0;
                            end
                        endcase

                        next_state = S_COOLDOWN;
                    end
                end

                // ---------------------------------------------------------
                // COOLDOWN: 1-cycle wait for FWFT empty to settle.
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

        vga_rd_grant_ff      <= next_vga_rd_grant;
        render_wr_grant_ff   <= next_render_wr_grant;
        prime_plus_rd_en_ff  <= next_prime_plus_rd_en;
        prime_minus_rd_en_ff <= next_prime_minus_rd_en;
    end

endmodule
