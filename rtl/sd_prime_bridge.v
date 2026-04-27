`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// sd_prime_bridge.v
//
// CDC bridge: buffers parsed prime values from the SD card (clk_sd domain)
// and delivers them one at a time to the test_prime_checker (ui_clk domain)
// via a toggle-based handshake.
//
// Contains a 16384x32 BRAM FIFO (holds entire SD file, ~9592 primes).
// No backpressure needed — FIFO is large enough for the full prime list.
// The clk_sd side pops from the FIFO on request; the ui_clk side presents
// one prime at a time to the checker.
//
// Protocol (ui_clk side):
//   start   -> fetch first prime
//   consume -> fetch next prime
//   prime_valid + prime_data = current prime ready for checker
//   prime_eof = no more primes (file fully read, FIFO drained)
//////////////////////////////////////////////////////////////////////////////

module sd_prime_bridge (
    // clk_sd domain (write side)
    input  wire        clk_sd,
    input  wire        rst_sd_n,
    input  wire [31:0] parsed_value,     // from sd_line_parser
    input  wire        parsed_valid,     // from sd_line_parser
    input  wire        file_done,        // filesystem_state == DONE
    output wire        sd_pause,         // backpressure to sd_file_reader

    // ui_clk domain (read side)
    input  wire        ui_clk,
    input  wire        rst_ui_n,
    input  wire        start,            // pulse: begin delivering primes
    input  wire        consume,          // pulse: checker used current prime
    output reg  [31:0] prime_data,       // current prime value
    output reg         prime_valid,      // data ready for checker
    output reg         prime_eof         // no more primes
);

    // =================================================================
    // FIFO (clk_sd domain, 16384 x 32-bit, BRAM)
    // Holds the entire SD prime file (~9592 primes). No pause needed.
    // =================================================================
    (* ram_style = "block" *) reg [31:0] fifo_mem [0:16383];
    reg [13:0] fifo_wr_ptr = 14'd0;
    reg [13:0] fifo_rd_ptr = 14'd0;
    wire       fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
    wire       fifo_full  = (fifo_wr_ptr + 14'd1 == fifo_rd_ptr);

    // No backpressure — FIFO is large enough for the full file
    assign sd_pause = 1'b0;

    // Write side
    always @(posedge clk_sd) begin
        if (parsed_valid && !fifo_full)
            fifo_mem[fifo_wr_ptr] <= parsed_value;
    end

    always @(posedge clk_sd) begin
        if (!rst_sd_n)
            fifo_wr_ptr <= 14'd0;
        else if (parsed_valid && !fifo_full)
            fifo_wr_ptr <= fifo_wr_ptr + 14'd1;
    end

    // Registered BRAM read (1-cycle latency)
    reg [31:0] fifo_rd_data;
    always @(posedge clk_sd) begin
        fifo_rd_data <= fifo_mem[fifo_rd_ptr];
    end

    // =================================================================
    // CDC: ui_clk -> clk_sd request toggle
    // =================================================================
    reg        req_toggle_ui = 1'b0;
    reg [2:0]  req_sync_sd   = 3'b0;
    wire       req_pulse_sd  = req_sync_sd[2] ^ req_sync_sd[1];

    always @(posedge clk_sd) begin
        if (!rst_sd_n)
            req_sync_sd <= 3'b0;
        else
            req_sync_sd <= {req_sync_sd[1:0], req_toggle_ui};
    end

    // CDC: ui_clk -> clk_sd start/rewind toggle
    // Tells the clk_sd side to rewind fifo_rd_ptr to 0 before serving.
    reg        start_toggle_ui = 1'b0;
    reg [2:0]  start_sync_sd   = 3'b0;
    wire       start_pulse_sd  = start_sync_sd[2] ^ start_sync_sd[1];

    always @(posedge clk_sd) begin
        if (!rst_sd_n)
            start_sync_sd <= 3'b0;
        else
            start_sync_sd <= {start_sync_sd[1:0], start_toggle_ui};
    end

    // =================================================================
    // CDC: clk_sd -> ui_clk ack toggle + data
    // =================================================================
    reg        ack_toggle_sd = 1'b0;
    reg [31:0] xfer_data_sd  = 32'd0;
    reg        xfer_eof_sd   = 1'b0;
    reg [2:0]  ack_sync_ui   = 3'b0;
    wire       ack_pulse_ui  = ack_sync_ui[2] ^ ack_sync_ui[1];

    always @(posedge ui_clk) begin
        if (!rst_ui_n)
            ack_sync_ui <= 3'b0;
        else
            ack_sync_ui <= {ack_sync_ui[1:0], ack_toggle_sd};
    end

    // =================================================================
    // clk_sd side: FIFO read FSM
    // On req_pulse_sd: pop from FIFO, present data, ack.
    // If FIFO empty and file not done: wait for data.
    // If FIFO empty and file done: signal EOF.
    // =================================================================
    localparam [1:0] SD_IDLE = 2'd0,
                     SD_WAIT = 2'd1,
                     SD_POP  = 2'd2;

    reg [1:0] sd_state = SD_IDLE;

    always @(posedge clk_sd) begin
        if (!rst_sd_n) begin
            sd_state      <= SD_IDLE;
            fifo_rd_ptr   <= 14'd0;
            ack_toggle_sd <= 1'b0;
            xfer_data_sd  <= 32'd0;
            xfer_eof_sd   <= 1'b0;
        end else begin
            // Rewind on start — always reset read pointer to beginning.
            // This fires independently of the FSM state so it works even
            // when the FIFO is not empty (checker stopped early on previous run).
            if (start_pulse_sd) begin
                fifo_rd_ptr <= 14'd0;
                xfer_eof_sd <= 1'b0;
            end

            case (sd_state)
                SD_IDLE: begin
                    if (req_pulse_sd) begin
                        if (!fifo_empty) begin
                            // BRAM read starts (data valid next cycle)
                            fifo_rd_ptr <= fifo_rd_ptr + 14'd1;
                            sd_state    <= SD_POP;
                        end else if (file_done && fifo_wr_ptr != 14'd0) begin
                            // Re-run: FIFO drained but data exists — rewind
                            fifo_rd_ptr <= 14'd0;
                            xfer_eof_sd <= 1'b0;
                            sd_state    <= SD_WAIT; // 1-cycle BRAM latency
                        end else if (file_done) begin
                            // No data and file is done -> EOF
                            xfer_eof_sd   <= 1'b1;
                            ack_toggle_sd <= ~ack_toggle_sd;
                        end else begin
                            // FIFO empty, file still reading -> wait
                            sd_state <= SD_WAIT;
                        end
                    end
                end

                SD_WAIT: begin
                    if (!fifo_empty) begin
                        fifo_rd_ptr <= fifo_rd_ptr + 14'd1;
                        sd_state    <= SD_POP;
                    end else if (file_done) begin
                        xfer_eof_sd   <= 1'b1;
                        ack_toggle_sd <= ~ack_toggle_sd;
                        sd_state      <= SD_IDLE;
                    end
                    // else: keep waiting
                end

                SD_POP: begin
                    // BRAM data is now valid (1 cycle after rd_ptr advance)
                    xfer_data_sd  <= fifo_rd_data;
                    xfer_eof_sd   <= 1'b0;
                    ack_toggle_sd <= ~ack_toggle_sd;
                    sd_state      <= SD_IDLE;
                end

                default: sd_state <= SD_IDLE;
            endcase
        end
    end

    // =================================================================
    // ui_clk side: request/response state machine
    // =================================================================
    reg req_pending_ff  = 1'b0;
    reg started_ff      = 1'b0;
    reg start_defer_ff  = 1'b0;  // defers first req by 1 cycle after rewind

    always @(posedge ui_clk) begin
        if (!rst_ui_n) begin
            req_toggle_ui   <= 1'b0;
            start_toggle_ui <= 1'b0;
            prime_data      <= 32'd0;
            prime_valid     <= 1'b0;
            prime_eof       <= 1'b0;
            req_pending_ff  <= 1'b0;
            started_ff      <= 1'b0;
            start_defer_ff  <= 1'b0;
        end else begin
            // Handle ack from clk_sd side (lowest priority, can be overridden by start)
            if (ack_pulse_ui && req_pending_ff) begin
                req_pending_ff <= 1'b0;
                if (xfer_eof_sd)
                    prime_eof <= 1'b1;
                else begin
                    prime_data  <= xfer_data_sd;
                    prime_valid <= 1'b1;
                end
            end

            // Deferred first request: fires 1 cycle after start so the
            // rewind toggle reaches clk_sd before the first read request.
            if (start_defer_ff) begin
                req_toggle_ui  <= ~req_toggle_ui;
                req_pending_ff <= 1'b1;
                start_defer_ff <= 1'b0;
            end

            // Handle start (highest priority — overrides in-flight ack)
            if (start) begin
                start_toggle_ui <= ~start_toggle_ui;  // rewind FIFO rd_ptr
                prime_valid     <= 1'b0;
                prime_eof       <= 1'b0;
                started_ff      <= 1'b1;
                start_defer_ff  <= 1'b1;              // defer req by 1 cycle
            end
            // Handle consume (only when not already pending)
            else if (consume && started_ff && !req_pending_ff) begin
                req_toggle_ui  <= ~req_toggle_ui;
                prime_valid    <= 1'b0;
                req_pending_ff <= 1'b1;
            end
        end
    end

endmodule
