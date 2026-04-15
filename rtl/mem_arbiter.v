`timescale 1ns / 1ps

// DDR2 memory arbiter.
// Owns the MIG Native app port and multiplexes four streams onto it:
//   A  6k+1 prime bitmap writes        (LIVE this build)
//   B  6k-1 prime bitmap writes        (stub — ports present, tie-offs drive idle)
//   C  Pixel (write) FIFO -> Write Buf (stub)
//   D  Read Buf -> Pixel (read) FIFO   (stub)
//
// Priority (highest -> lowest):
//   1. Pixel read fill  (deadline-critical: VGA starvation = tearing)
//   2. Pixel write drain
//   3. Round-robin between 6k+1 / 6k-1 prime writes
//
// Burst policy: once a stream is selected, keep servicing it while its FIFO
// can sustain transfers (has data for writes, has room for reads) AND no
// higher-priority stream is demanding service. This amortizes read latency
// and keeps DDR2 rows open across consecutive same-stream transactions.
//
// Clock/reset: single domain `ui_clk`; `rst_n` is active-low (tie to
// ~ui_clk_sync_rst at the top level).
//
// Coding style matches prime_accumulator.v:
//   - One always @(*) with all combinational logic, reset handled as !rst_n
//   - One always @(posedge ui_clk) containing ONLY `*_ff <= next_*;`
//   - Every output port is a direct flop.

module mem_arbiter (
    input  wire         ui_clk,
    input  wire         rst_n,
    input  wire         init_calib_complete,

    // ---- Stream A: 6k+1 prime writes (LIVE) -------------------------------
    input  wire [127:0] prime_plus_rd_data,
    input  wire         prime_plus_empty,
    output reg          prime_plus_rd_en_ff,

    // ---- Stream B: 6k-1 prime writes (STUB) -------------------------------
    input  wire [127:0] prime_minus_rd_data,
    input  wire         prime_minus_empty,
    output reg          prime_minus_rd_en_ff,

    // ---- Stream C: pixel write FIFO -> DDR2 (STUB) ------------------------
    input  wire [127:0] pixel_wr_rd_data,
    input  wire         pixel_wr_empty,
    output reg          pixel_wr_rd_en_ff,

    // ---- Stream D: DDR2 -> pixel read FIFO (STUB) -------------------------
    input  wire         pixel_rd_almost_full,  // stop issuing reads when high
    output reg  [127:0] pixel_rd_wr_data_ff,
    output reg          pixel_rd_wr_en_ff,

    // ---- VGA buffer-swap pulse (STUB input) -------------------------------
    input  wire         vsync_pulse,

    // ---- MIG Native user interface ----------------------------------------
    output reg  [26:0]  app_addr_ff,
    output reg  [2:0]   app_cmd_ff,
    output reg          app_en_ff,
    output reg  [127:0] app_wdf_data_ff,
    output reg          app_wdf_end_ff,
    output reg  [15:0]  app_wdf_mask_ff,
    output reg          app_wdf_wren_ff,
    input  wire [127:0] app_rd_data,
    input  wire         app_rd_data_valid,
    input  wire         app_rdy,
    input  wire         app_wdf_rdy
);

    // -----------------------------------------------------------------------
    // Address regions (byte addresses; 16B per 128-bit transaction)
    // Mirror of NEXT_STEPS.md §2 address map.
    // -----------------------------------------------------------------------
    localparam [26:0] BASE_PLUS   = 27'h000_0000;
    localparam [26:0] BASE_MINUS  = 27'h020_0000;
    localparam [26:0] BASE_FRAME_A= 27'h040_0000;
    localparam [26:0] BASE_FRAME_B= 27'h050_0000;
    localparam [26:0] FRAME_SIZE  = 27'h009_6000;  // 640*480*2 = 614400 B

    localparam [2:0] CMD_WRITE = 3'b000;
    localparam [2:0] CMD_READ  = 3'b001;

    // -----------------------------------------------------------------------
    // Stream selector
    // -----------------------------------------------------------------------
    localparam [2:0] SEL_IDLE  = 3'd0,
                     SEL_PXRD  = 3'd1,   // pixel read fill
                     SEL_PXWR  = 3'd2,   // pixel write drain
                     SEL_PPLUS = 3'd3,
                     SEL_PMIN  = 3'd4;

    reg [2:0] sel_ff, next_sel;

    // Four independent write-address pointers
    reg [26:0] wr_ptr_plus_ff,   next_wr_ptr_plus;
    reg [26:0] wr_ptr_minus_ff,  next_wr_ptr_minus;
    reg [26:0] wr_ptr_frame_ff,  next_wr_ptr_frame;
    reg [26:0] rd_ptr_frame_ff,  next_rd_ptr_frame;

    // Frame buffer role: 0 = A is read / B is write, 1 = swapped
    reg        frame_role_ff,    next_frame_role;

    // Round-robin bit between the two prime streams (0 = prefer plus)
    reg        rr_prime_ff,      next_rr_prime;

    // Outstanding read counter (for Stream D flow control). Each read command
    // issued bumps this; each app_rd_data_valid decrements. Keeps us from
    // issuing reads that would overflow the pixel RD FIFO.
    reg [5:0]  rd_inflight_ff,   next_rd_inflight;

    // -----------------------------------------------------------------------
    // Per-stream "has work?" flags
    // -----------------------------------------------------------------------
    wire want_pxrd  = !pixel_rd_almost_full && (rd_inflight_ff < 6'd32);
    wire want_pxwr  = !pixel_wr_empty;
    wire want_pplus = !prime_plus_empty;
    wire want_pmin  = !prime_minus_empty;

    // Priority-encoded "who should own the bus right now"
    function [2:0] pick_stream;
        input pxrd_v, pxwr_v, pplus_v, pmin_v, rr;
        begin
            if      (pxrd_v)              pick_stream = SEL_PXRD;
            else if (pxwr_v)              pick_stream = SEL_PXWR;
            else if (pplus_v && !rr)      pick_stream = SEL_PPLUS;
            else if (pmin_v  &&  rr)      pick_stream = SEL_PMIN;
            else if (pplus_v)             pick_stream = SEL_PPLUS;
            else if (pmin_v)              pick_stream = SEL_PMIN;
            else                          pick_stream = SEL_IDLE;
        end
    endfunction

    wire [2:0] priority_pick = pick_stream(want_pxrd, want_pxwr,
                                           want_pplus, want_pmin, rr_prime_ff);

    // Stay on current stream while it still has work AND no higher-priority
    // stream is demanding service. This is the "burst" behavior.
    wire current_still_has_work =
        (sel_ff == SEL_PXRD  && want_pxrd)  ||
        (sel_ff == SEL_PXWR  && want_pxwr)  ||
        (sel_ff == SEL_PPLUS && want_pplus) ||
        (sel_ff == SEL_PMIN  && want_pmin);

    wire higher_priority_pending =
        (sel_ff != SEL_PXRD && want_pxrd) ||
        (sel_ff == SEL_PPLUS && want_pxwr) ||
        (sel_ff == SEL_PMIN  && want_pxwr);

    // -----------------------------------------------------------------------
    // Combinational block — all next-state, all outputs, reset as !rst_n
    // -----------------------------------------------------------------------
    always @(*) begin
        // Defaults
        next_sel           = sel_ff;
        next_wr_ptr_plus   = wr_ptr_plus_ff;
        next_wr_ptr_minus  = wr_ptr_minus_ff;
        next_wr_ptr_frame  = wr_ptr_frame_ff;
        next_rd_ptr_frame  = rd_ptr_frame_ff;
        next_frame_role    = frame_role_ff;
        next_rr_prime      = rr_prime_ff;
        next_rd_inflight   = rd_inflight_ff;

        app_addr_ff        = 27'd0;
        app_cmd_ff         = CMD_WRITE;
        app_en_ff          = 1'b0;
        app_wdf_data_ff    = 128'd0;
        app_wdf_end_ff     = 1'b1;       // single beat per transaction (4:1 / BL8)
        app_wdf_mask_ff    = 16'd0;      // write all bytes
        app_wdf_wren_ff    = 1'b0;

        prime_plus_rd_en_ff  = 1'b0;
        prime_minus_rd_en_ff = 1'b0;
        pixel_wr_rd_en_ff    = 1'b0;
        pixel_rd_wr_data_ff  = app_rd_data;
        pixel_rd_wr_en_ff    = 1'b0;

        if (!rst_n) begin
            next_sel          = SEL_IDLE;
            next_wr_ptr_plus  = BASE_PLUS;
            next_wr_ptr_minus = BASE_MINUS;
            next_wr_ptr_frame = BASE_FRAME_B;   // role 0: write to B
            next_rd_ptr_frame = BASE_FRAME_A;   // role 0: read from A
            next_frame_role   = 1'b0;
            next_rr_prime     = 1'b0;
            next_rd_inflight  = 6'd0;
        end else if (!init_calib_complete) begin
            // Hold everything idle until the MIG is ready.
            next_sel = SEL_IDLE;
        end else begin
            // -------------------------------------------------------------
            // Stream selection (burst-aware)
            // -------------------------------------------------------------
            if (sel_ff == SEL_IDLE || !current_still_has_work || higher_priority_pending)
                next_sel = priority_pick;

            // -------------------------------------------------------------
            // Drive the MIG port for the currently selected stream
            // -------------------------------------------------------------
            case (next_sel)
                // ----- Stream A: 6k+1 write (LIVE) ------------------------
                SEL_PPLUS: begin
                    app_addr_ff     = wr_ptr_plus_ff;
                    app_cmd_ff      = CMD_WRITE;
                    app_wdf_data_ff = prime_plus_rd_data;

                    // Issue command + data together; advance pointer/FIFO
                    // only when BOTH handshakes accept this cycle.
                    if (want_pplus && app_rdy && app_wdf_rdy) begin
                        app_en_ff             = 1'b1;
                        app_wdf_wren_ff       = 1'b1;
                        prime_plus_rd_en_ff   = 1'b1;
                        next_wr_ptr_plus      = wr_ptr_plus_ff + 27'd16;
                        next_rr_prime         = 1'b1;    // next prime slot -> minus
                    end
                end

                // ----- Stream B: 6k-1 write (STUB) ------------------------
                SEL_PMIN: begin
                    app_addr_ff     = wr_ptr_minus_ff;
                    app_cmd_ff      = CMD_WRITE;
                    app_wdf_data_ff = prime_minus_rd_data;
                    if (want_pmin && app_rdy && app_wdf_rdy) begin
                        app_en_ff             = 1'b1;
                        app_wdf_wren_ff       = 1'b1;
                        prime_minus_rd_en_ff  = 1'b1;
                        next_wr_ptr_minus     = wr_ptr_minus_ff + 27'd16;
                        next_rr_prime         = 1'b0;
                    end
                end

                // ----- Stream C: pixel write drain (STUB) -----------------
                SEL_PXWR: begin
                    app_addr_ff     = wr_ptr_frame_ff;
                    app_cmd_ff      = CMD_WRITE;
                    app_wdf_data_ff = pixel_wr_rd_data;
                    if (want_pxwr && app_rdy && app_wdf_rdy) begin
                        app_en_ff         = 1'b1;
                        app_wdf_wren_ff   = 1'b1;
                        pixel_wr_rd_en_ff = 1'b1;
                        next_wr_ptr_frame = (wr_ptr_frame_ff + 27'd16);
                        // TODO: wrap at end of current write-buffer region
                    end
                end

                // ----- Stream D: pixel read fill (STUB) -------------------
                SEL_PXRD: begin
                    app_addr_ff = rd_ptr_frame_ff;
                    app_cmd_ff  = CMD_READ;
                    if (want_pxrd && app_rdy) begin
                        app_en_ff         = 1'b1;
                        next_rd_ptr_frame = (rd_ptr_frame_ff + 27'd16);
                        next_rd_inflight  = rd_inflight_ff + 6'd1;
                        // TODO: wrap at end of current read-buffer region
                    end
                end

                default: ; // SEL_IDLE
            endcase

            // -------------------------------------------------------------
            // Returning read data -> pixel RD FIFO (always routed, independent
            // of which stream currently owns the issue port).
            // -------------------------------------------------------------
            if (app_rd_data_valid) begin
                pixel_rd_wr_en_ff = 1'b1;
                if (next_rd_inflight != 6'd0)
                    next_rd_inflight = next_rd_inflight - 6'd1;
            end

            // -------------------------------------------------------------
            // vsync swap: flip which physical buffer is read vs write,
            // reset the frame pointers to the new bases.
            // -------------------------------------------------------------
            if (vsync_pulse) begin
                next_frame_role   = ~frame_role_ff;
                next_wr_ptr_frame = (~frame_role_ff) ? BASE_FRAME_A : BASE_FRAME_B;
                next_rd_ptr_frame = (~frame_role_ff) ? BASE_FRAME_B : BASE_FRAME_A;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops only
    // -----------------------------------------------------------------------
    always @(posedge ui_clk) begin
        sel_ff           <= next_sel;
        wr_ptr_plus_ff   <= next_wr_ptr_plus;
        wr_ptr_minus_ff  <= next_wr_ptr_minus;
        wr_ptr_frame_ff  <= next_wr_ptr_frame;
        rd_ptr_frame_ff  <= next_rd_ptr_frame;
        frame_role_ff    <= next_frame_role;
        rr_prime_ff      <= next_rr_prime;
        rd_inflight_ff   <= next_rd_inflight;
    end

endmodule
