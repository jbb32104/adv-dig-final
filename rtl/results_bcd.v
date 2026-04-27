`timescale 1ns / 1ps

// Results BCD converter — after computation completes, reads all engine primes
// from prime_tracker into a local register file, sorts them in descending order
// (bubble sort), then sequentially converts each to 9-digit BCD, storing results
// in a dual-port RAM for cross-domain reading.
//
// The tracker stores up to 40 entries (to handle engine lag), but we only
// display the top 20 primes. The sort puts the largest first, then we
// convert only the first 20 (or fewer if tracker_count < 20).
//
// Write port: clk (100 MHz) — conversion FSM writes here.
// Read port:  ui_clk (~75 MHz) — frame_renderer reads here.
//
// Memory layout (32 entries x 36 bits):
//   [0..19]  prime BCD values, index 0 = largest prime
//   [20]     seconds BCD (4 digits, zero-padded to 36 bits)
//   [21]     reserved
//
// Also outputs display_count (total primes including 2/3) and done flag.
//
// Clock domains: clk (write/control), ui_clk (read).

module results_bcd #(
    parameter WIDTH = 27
) (
    // Write domain (clk, 100 MHz)
    input  wire        clk,
    input  wire        rst_n,

    // Trigger
    input  wire        start,            // pulse: begin conversion

    // Prime tracker interface (clk domain)
    input  wire [6:0]  tracker_count,    // engine primes stored (0-64)
    input  wire [WIDTH-1:0] tracker_data,// selected prime value
    output reg  [5:0]  tracker_idx_ff,   // read index into tracker

    // Configuration (clk domain, stable during conversion)
    input  wire [WIDTH-1:0] n_limit,     // for 2/3 inclusion logic
    input  wire [15:0] seconds_bcd,      // already BCD (from sw_bcd upper 4 digits)

    // Status (clk domain)
    output reg  [4:0]  display_count_ff, // total primes to display (incl. 2,3)
    output reg         done_ff,

    // Read domain (ui_clk, ~75 MHz)
    input  wire        ui_clk,
    input  wire [4:0]  rd_addr,          // 0-19: prime, 20: seconds
    output reg  [35:0] rd_data_ff        // 9 BCD digits (registered read)
);

    // -----------------------------------------------------------------------
    // Dual-port RAM: write on clk, read on ui_clk
    // Vivado infers true dual-port BRAM or distributed RAM.
    // -----------------------------------------------------------------------
    reg [35:0] bcd_mem [0:31];

    // Port B: registered read (ui_clk domain)
    always @(posedge ui_clk) begin
        rd_data_ff <= bcd_mem[rd_addr];
    end

    // -----------------------------------------------------------------------
    // bin_to_bcd9 converter instance (clk domain)
    // -----------------------------------------------------------------------
    reg         conv_start_ff;
    reg  [26:0] conv_bin_ff;
    wire [35:0] conv_bcd;
    wire        conv_valid;

    bin_to_bcd9 u_conv (
        .clk       (clk),
        .rst       (~rst_n),
        .bin_in    (conv_bin_ff),
        .start     (conv_start_ff),
        .bcd_out_ff(conv_bcd),
        .valid_ff  (conv_valid)
    );

    // -----------------------------------------------------------------------
    // Local register file for sorting (40 x WIDTH bits)
    // Must be registers (not BRAM) — sort logic reads combinationally.
    // -----------------------------------------------------------------------
    (* ram_style = "register" *) reg [WIDTH-1:0] sorted_mem [0:63];

    // -----------------------------------------------------------------------
    // FSM states
    // -----------------------------------------------------------------------
    localparam [3:0]
        S_IDLE       = 4'd0,
        S_READ_REQ   = 4'd1,   // set tracker read index
        S_READ_WAIT  = 4'd2,   // wait for registered read to propagate
        S_READ_STORE = 4'd3,   // store tracker value in sorted_mem
        S_SORT_CMP   = 4'd4,   // bubble sort: compare adjacent entries
        S_CVT_START  = 4'd5,   // start BCD conversion for sorted_mem[cvt_idx] or 2/3
        S_CVT_WAIT   = 4'd6,   // wait for conversion to complete
        S_SEC_STORE  = 4'd7,   // store seconds BCD
        S_DONE       = 4'd8;

    // -----------------------------------------------------------------------
    // Registered state
    // -----------------------------------------------------------------------
    reg [3:0]  state_ff;
    reg [4:0]  slot_ff;         // current BCD memory slot being written (0-21)
    reg [6:0]  eng_total_ff;    // total engine primes read from tracker (0-64)
    reg        include_3_ff;
    reg        include_2_ff;

    // Read phase
    reg [6:0]  rd_cnt_ff;       // tracker read counter (0 to eng_total-1)

    // Sort phase
    reg [6:0]  sort_j_ff;       // inner loop index
    reg [6:0]  sort_end_ff;     // inner loop end (eng_total - 1 - pass)
    reg        sort_swapped_ff; // any swap in current pass?

    // Convert phase — only convert top 20 after sort
    reg [4:0]  cvt_idx_ff;      // index into sorted_mem for current conversion (0-19)
    reg [1:0]  cvt_phase_ff;    // 0=engine primes, 1=hardcoded 3, 2=hardcoded 2

    // How many engine primes to actually convert (min(eng_total, 20))
    reg [4:0]  cvt_limit_ff;

    // -----------------------------------------------------------------------
    // Combinational next-state
    // -----------------------------------------------------------------------
    reg [3:0]  next_state;
    reg [4:0]  next_slot;
    reg [6:0]  next_eng_total;
    reg        next_include_3;
    reg        next_include_2;
    reg [5:0]  next_tracker_idx;  // 6-bit: tracker read index (0-63)
    reg        next_conv_start;
    reg [26:0] next_conv_bin;
    reg [4:0]  next_display_count;
    reg        next_done;
    reg [6:0]  next_rd_cnt;
    reg [6:0]  next_sort_j;
    reg [6:0]  next_sort_end;
    reg        next_sort_swapped;
    reg [4:0]  next_cvt_idx;
    reg [1:0]  next_cvt_phase;
    reg [4:0]  next_cvt_limit;

    // Memory write signals
    reg        mem_wr_en;
    reg [4:0]  mem_wr_addr;
    reg [35:0] mem_wr_data;

    // Sort: swap control
    reg        sort_do_swap;
    reg [6:0]  sort_swap_idx;      // index of element to swap (swap idx and idx+1)
    reg [WIDTH-1:0] sort_val_lo;   // smaller value (goes to idx+1)
    reg [WIDTH-1:0] sort_val_hi;   // larger value (goes to idx)

    // Read phase: store control
    reg        rd_store_en;
    reg [6:0]  rd_store_idx;
    reg [WIDTH-1:0] rd_store_val;

    always @(*) begin
        // Defaults: hold
        next_state         = state_ff;
        next_slot          = slot_ff;
        next_eng_total     = eng_total_ff;
        next_include_3     = include_3_ff;
        next_include_2     = include_2_ff;
        next_tracker_idx   = tracker_idx_ff;
        next_conv_start    = 1'b0;
        next_conv_bin      = conv_bin_ff;
        next_display_count = display_count_ff;
        next_done          = done_ff;
        next_rd_cnt        = rd_cnt_ff;
        next_sort_j        = sort_j_ff;
        next_sort_end      = sort_end_ff;
        next_sort_swapped  = sort_swapped_ff;
        next_cvt_idx       = cvt_idx_ff;
        next_cvt_phase     = cvt_phase_ff;
        next_cvt_limit     = cvt_limit_ff;
        mem_wr_en          = 1'b0;
        mem_wr_addr        = 5'd0;
        mem_wr_data        = 36'd0;
        sort_do_swap       = 1'b0;
        sort_swap_idx      = 7'd0;
        sort_val_lo        = {WIDTH{1'b0}};
        sort_val_hi        = {WIDTH{1'b0}};
        rd_store_en        = 1'b0;
        rd_store_idx       = 7'd0;
        rd_store_val       = {WIDTH{1'b0}};

        if (!rst_n) begin
            next_state         = S_IDLE;
            next_slot          = 5'd0;
            next_eng_total     = 7'd0;
            next_include_3     = 1'b0;
            next_include_2     = 1'b0;
            next_tracker_idx   = 6'd0;
            next_conv_start    = 1'b0;
            next_conv_bin      = 27'd0;
            next_display_count = 5'd0;
            next_done          = 1'b0;
            next_rd_cnt        = 7'd0;
            next_sort_j        = 7'd0;
            next_sort_end      = 7'd0;
            next_sort_swapped  = 1'b0;
            next_cvt_idx       = 5'd0;
            next_cvt_phase     = 2'd0;
            next_cvt_limit     = 5'd0;
        end else begin
            case (state_ff)

                S_IDLE: begin
                    if (start) begin
                        // Read up to 64 entries from tracker
                        next_eng_total = (tracker_count > 7'd64) ? 7'd64 : tracker_count;
                        next_include_3 = (n_limit >= {{WIDTH-2{1'b0}}, 2'd3});
                        next_include_2 = (n_limit >= {{WIDTH-2{1'b0}}, 2'd2});
                        next_slot      = 5'd0;
                        next_rd_cnt    = 7'd0;
                        next_cvt_idx   = 5'd0;
                        next_cvt_phase = 2'd0;
                        // Convert at most 20 engine primes for display
                        if (tracker_count > 7'd20)
                            next_cvt_limit = 5'd20;
                        else
                            next_cvt_limit = tracker_count[4:0];

                        if (tracker_count > 7'd0)
                            next_state = S_READ_REQ;
                        else
                            // No engine primes; skip to conversion (2/3 or done)
                            next_state = S_CVT_START;
                    end
                end

                // ---- Phase 1: Read all tracker entries into sorted_mem ----

                // Set tracker read index; 2-cycle latency: idx reg + read reg
                S_READ_REQ: begin
                    next_tracker_idx = rd_cnt_ff[5:0];
                    next_state       = S_READ_WAIT;
                end

                // Wait for tracker registered read to propagate
                S_READ_WAIT: begin
                    next_state = S_READ_STORE;
                end

                // Store tracker value in sorted_mem and advance counter
                S_READ_STORE: begin
                    rd_store_en  = 1'b1;
                    rd_store_idx = rd_cnt_ff;
                    rd_store_val = tracker_data;
                    next_rd_cnt  = rd_cnt_ff + 7'd1;

                    if (rd_cnt_ff + 7'd1 >= eng_total_ff) begin
                        // All entries read; start sorting if > 1 entry
                        if (eng_total_ff > 7'd1) begin
                            next_sort_j       = 7'd0;
                            next_sort_end     = eng_total_ff - 7'd1;
                            next_sort_swapped = 1'b0;
                            next_state        = S_SORT_CMP;
                        end else begin
                            // 0 or 1 entries: already sorted
                            next_cvt_idx   = 5'd0;
                            next_cvt_phase = 2'd0;
                            next_state     = S_CVT_START;
                        end
                    end else begin
                        next_state = S_READ_REQ;
                    end
                end

                // ---- Phase 2: Bubble sort (descending order) ----
                // One comparison + optional swap per cycle.
                // We want sorted_mem[0] = largest, sorted_mem[N-1] = smallest.
                // Swap when sorted_mem[j] < sorted_mem[j+1].

                S_SORT_CMP: begin
                    if (sorted_mem[sort_j_ff] < sorted_mem[sort_j_ff + 7'd1]) begin
                        // Out of order: swap
                        sort_do_swap      = 1'b1;
                        sort_swap_idx     = sort_j_ff;
                        sort_val_hi       = sorted_mem[sort_j_ff + 7'd1];
                        sort_val_lo       = sorted_mem[sort_j_ff];
                        next_sort_swapped = 1'b1;
                    end

                    if (sort_j_ff + 7'd1 >= sort_end_ff) begin
                        // End of pass
                        if (next_sort_swapped && sort_end_ff > 7'd1) begin
                            // More passes needed
                            next_sort_j       = 7'd0;
                            next_sort_end     = sort_end_ff - 7'd1;
                            next_sort_swapped = 1'b0;
                        end else begin
                            // Sorted (no swaps or single-element pass)
                            next_cvt_idx   = 5'd0;
                            next_cvt_phase = 2'd0;
                            next_state     = S_CVT_START;
                        end
                    end else begin
                        next_sort_j = sort_j_ff + 7'd1;
                    end
                end

                // ---- Phase 3: Convert top 20 sorted entries + 2/3 to BCD ----

                S_CVT_START: begin
                    if (cvt_phase_ff == 2'd0 && cvt_idx_ff < cvt_limit_ff) begin
                        // Convert engine prime from sorted_mem
                        next_conv_bin   = sorted_mem[cvt_idx_ff][26:0];
                        next_conv_start = 1'b1;
                        next_cvt_idx    = cvt_idx_ff + 5'd1;
                        next_state      = S_CVT_WAIT;
                    end else if (cvt_phase_ff == 2'd0) begin
                        // Done with engine primes; check for hardcoded 3
                        if (include_3_ff && slot_ff < 5'd20) begin
                            next_conv_bin   = {{WIDTH-2{1'b0}}, 2'd3};
                            next_conv_start = 1'b1;
                            next_cvt_phase  = 2'd1;
                            next_state      = S_CVT_WAIT;
                        end else if (include_2_ff && slot_ff < 5'd20) begin
                            next_conv_bin   = {{WIDTH-2{1'b0}}, 2'd2};
                            next_conv_start = 1'b1;
                            next_cvt_phase  = 2'd2;
                            next_state      = S_CVT_WAIT;
                        end else begin
                            next_state = S_SEC_STORE;
                        end
                    end else if (cvt_phase_ff == 2'd1) begin
                        // After converting 3, check for 2
                        if (include_2_ff && slot_ff < 5'd20) begin
                            next_conv_bin   = {{WIDTH-2{1'b0}}, 2'd2};
                            next_conv_start = 1'b1;
                            next_cvt_phase  = 2'd2;
                            next_state      = S_CVT_WAIT;
                        end else begin
                            next_state = S_SEC_STORE;
                        end
                    end else begin
                        // After converting 2
                        next_state = S_SEC_STORE;
                    end
                end

                // Wait for bin_to_bcd9 to finish
                S_CVT_WAIT: begin
                    if (conv_valid) begin
                        mem_wr_en   = 1'b1;
                        mem_wr_addr = slot_ff;
                        mem_wr_data = conv_bcd;
                        next_slot   = slot_ff + 5'd1;
                        next_state  = S_CVT_START;
                    end
                end

                // Store seconds BCD and compute display count
                S_SEC_STORE: begin
                    mem_wr_en   = 1'b1;
                    mem_wr_addr = 5'd20;
                    mem_wr_data = {20'd0, seconds_bcd};
                    next_display_count = slot_ff;  // slot_ff = number of primes stored
                    next_state  = S_DONE;
                end

                S_DONE: begin
                    next_done = ~done_ff;  // toggle (not level) so renderer always re-renders
                    next_state = S_IDLE;
                end

                default: next_state = S_IDLE;

            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Sequential block — flops + memory write port + sorted_mem writes
    // -----------------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        state_ff         <= next_state;
        slot_ff          <= next_slot;
        eng_total_ff     <= next_eng_total;
        include_3_ff     <= next_include_3;
        include_2_ff     <= next_include_2;
        tracker_idx_ff   <= next_tracker_idx;
        conv_start_ff    <= next_conv_start;
        conv_bin_ff      <= next_conv_bin;
        display_count_ff <= next_display_count;
        done_ff          <= next_done;
        rd_cnt_ff        <= next_rd_cnt;
        sort_j_ff        <= next_sort_j;
        sort_end_ff      <= next_sort_end;
        sort_swapped_ff  <= next_sort_swapped;
        cvt_idx_ff       <= next_cvt_idx;
        cvt_phase_ff     <= next_cvt_phase;
        cvt_limit_ff     <= next_cvt_limit;

        // Memory write port (clk domain)
        if (mem_wr_en)
            bcd_mem[mem_wr_addr] <= mem_wr_data;

        // Sorted register file writes
        if (!rst_n) begin
            for (i = 0; i < 64; i = i + 1)
                sorted_mem[i] <= {WIDTH{1'b0}};
        end else begin
            if (rd_store_en)
                sorted_mem[rd_store_idx] <= rd_store_val;
            if (sort_do_swap) begin
                sorted_mem[sort_swap_idx]        <= sort_val_hi;
                sorted_mem[sort_swap_idx + 7'd1] <= sort_val_lo;
            end
        end
    end

endmodule
