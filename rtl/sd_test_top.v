`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// sd_test_top.v
//
// Standalone test top for SD card reading on Nexys A7.
// Reads CSEE4280Primes.txt from SD card, displays each decimal prime
// on the seven-segment display. Press BTNC to advance to the next prime.
//
// LEDs show SD card status:
//   LED[3:0]  = card_stat (init state machine)
//   LED[5:4]  = card_type (0=UNK, 1=SDv1, 2=SDv2, 3=SDHC)
//   LED[7:6]  = filesystem_type (0=none, 1=UNK, 2=FAT16, 3=FAT32)
//   LED[8]    = file_found
//   LED[9]    = pll_locked
//   LED[10]   = values ready (at least one prime loaded)
//   LED[15:11]= 0
//////////////////////////////////////////////////////////////////////////////

module sd_test_top (
    input  wire        clk,         // 100 MHz board clock
    input  wire        cpu_rst_n,   // active-low reset (CPU_RESET button)
    input  wire        BTNC,        // center button: advance to next prime

    // SD card
    output wire        sdcard_pwr_n,
    output wire        sdclk,
    inout              sdcmd,
    input  wire        sddat0,
    output wire        sddat1,
    output wire        sddat2,
    output wire        sddat3,

    // Seven-segment display
    output wire [6:0]  SEG,
    output wire [7:0]  AN,
    output wire        DP_n,

    // LEDs
    output wire [15:0] LED
);

    // =========================================================
    // SD card active-low power & unused data lines
    // =========================================================
    assign sdcard_pwr_n = 1'b0;
    assign {sddat1, sddat2, sddat3} = 3'b111;

    // =========================================================
    // PLL: 100 MHz -> clk_sd (50 MHz), clk_vga (25 MHz, unused)
    // =========================================================
    wire clk_mem, clk_sd, clk_vga, pll_locked;

    pll u_pll (
        .clk_in  (clk),
        .resetn  (cpu_rst_n),
        .clk_mem (clk_mem),
        .clk_sd  (clk_sd),
        .clk_vga (clk_vga),
        .locked  (pll_locked)
    );

    wire sys_rst_n = cpu_rst_n & pll_locked;

    // =========================================================
    // SD file reader (runs in clk_sd domain, 50 MHz)
    // Reads "CSEE4280Primes.txt" — filename length = 19
    // =========================================================
    wire       sd_outen;
    wire [7:0] sd_outbyte;
    wire [3:0] card_stat;
    wire [1:0] card_type;
    wire [1:0] filesystem_type;
    wire       file_found;
    wire [2:0] filesystem_state;

    sd_file_reader #(
        .FILE_NAME_LEN (18),
        .FILE_NAME     ("CSEE4280Primes.txt"),
        .CLK_DIV       (3'd2),          // 50 MHz -> CLK_DIV=2
        .SIMULATE      (0)
    ) u_sd_file_reader (
        .rstn            (sys_rst_n),
        .clk             (clk_sd),
        .sdclk           (sdclk),
        .sdcmd           (sdcmd),
        .sddat0          (sddat0),
        .card_stat       (card_stat),
        .card_type       (card_type),
        .filesystem_type (filesystem_type),
        .file_found      (file_found),
        .outen           (sd_outen),
        .outbyte         (sd_outbyte),
        .filesystem_state(filesystem_state),
        .pause           (sd_pause)
    );

    // =========================================================
    // Line parser: decimal ASCII -> binary (clk_sd domain)
    // =========================================================
    wire [31:0] parsed_value;
    wire        parsed_valid;

    sd_line_parser u_parser (
        .clk       (clk_sd),
        .rst_n     (sys_rst_n),
        .byte_en   (sd_outen),
        .byte_data (sd_outbyte),
        .value     (parsed_value),
        .valid     (parsed_valid)
    );

    // =========================================================
    // Prime buffer (clk_sd domain)
    //
    // We hold the "current" and "next" values. When BTNC is
    // pressed, current <= next, and we allow the next value to
    // be captured from the parser.
    //
    // Flow control: we only capture parsed values when we have
    // room (need_next=1). The SD file reader streams continuously,
    // so we gate capture with need_next.
    //
    // Since the SD reader streams all bytes without pause, we
    // buffer all parsed primes into a small FIFO so none are lost.
    // =========================================================

    // FIFO: 256 x 32-bit, single-clock (clk_sd).
    // Sector-level backpressure via pause keeps this from overflowing.
    // One sector can produce up to ~170 small primes, so 256 entries
    // absorbs the in-flight sector while pause takes effect (~2 BRAMs).
    (* ram_style = "block" *) reg [31:0] fifo_mem [0:255];
    reg [7:0] fifo_wr_ptr = 8'd0;
    reg [7:0] fifo_rd_ptr = 8'd0;
    wire      fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
    wire      fifo_full  = (fifo_wr_ptr + 8'd1 == fifo_rd_ptr);

    // Fill level for backpressure: pause SD reader when FIFO is half full.
    // This leaves 128 slots to absorb the in-flight sector (~170 primes worst case
    // for small primes, but sectors with larger primes have fewer entries).
    wire [8:0] fifo_fill = {1'b0, fifo_wr_ptr} - {1'b0, fifo_rd_ptr};
    wire       sd_pause  = (fifo_fill[7:0] >= 8'd128);

    // Registered BRAM read output
    reg [31:0] fifo_rd_data = 32'd0;

    // Write side (clk_sd domain)
    always @(posedge clk_sd) begin
        if (parsed_valid && !fifo_full) begin
            fifo_mem[fifo_wr_ptr] <= parsed_value;
        end
    end

    always @(posedge clk_sd or negedge sys_rst_n) begin
        if (!sys_rst_n)
            fifo_wr_ptr <= 8'd0;
        else if (parsed_valid && !fifo_full)
            fifo_wr_ptr <= fifo_wr_ptr + 8'd1;
    end

    // Registered read: data appears one cycle after address
    always @(posedge clk_sd) begin
        fifo_rd_data <= fifo_mem[fifo_rd_ptr];
    end

    // =========================================================
    // Clock domain crossing: BTNC debounce is in clk (100MHz),
    // FIFO read is in clk_sd (50MHz).
    // We'll do the FIFO read in clk_sd and cross the display
    // value to the 100MHz domain for the SSD.
    // =========================================================

    // Debounce BTNC in 100 MHz domain
    wire btnc_rising;
    debounce #(.DEBOUNCE_CYCLES(500_000)) u_debounce_btnc (
        .clk             (clk),
        .rst_n           (sys_rst_n),
        .btn_in          (BTNC),
        .btn_state_ff    (),
        .rising_pulse_ff (btnc_rising),
        .falling_pulse_ff()
    );

    // Synchronize btnc_rising pulse into clk_sd domain
    // Use toggle approach for CDC
    reg btnc_toggle_100 = 1'b0;
    always @(posedge clk) begin
        if (!sys_rst_n)
            btnc_toggle_100 <= 1'b0;
        else if (btnc_rising)
            btnc_toggle_100 <= ~btnc_toggle_100;
    end

    reg [2:0] btnc_sync_sd = 3'b0;
    always @(posedge clk_sd) begin
        if (!sys_rst_n)
            btnc_sync_sd <= 3'b0;
        else
            btnc_sync_sd <= {btnc_sync_sd[1:0], btnc_toggle_100};
    end
    wire btnc_pulse_sd = btnc_sync_sd[2] ^ btnc_sync_sd[1];

    // Read side (clk_sd domain): current display value
    // Two-cycle read: cycle 1 = address presented (fifo_rd_ptr),
    //                 cycle 2 = fifo_rd_data valid, latch into display_val_sd
    reg [31:0] display_val_sd = 32'd0;
    reg        has_value_sd   = 1'b0;
    reg        first_load     = 1'b1;  // auto-load first value
    reg        rd_pending     = 1'b0;  // waiting for BRAM read latency

    always @(posedge clk_sd or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            fifo_rd_ptr    <= 8'd0;
            display_val_sd <= 32'd0;
            has_value_sd   <= 1'b0;
            first_load     <= 1'b1;
            rd_pending     <= 1'b0;
        end else begin
            if (rd_pending) begin
                // Cycle 2: BRAM data is now valid
                display_val_sd <= fifo_rd_data;
                has_value_sd   <= 1'b1;
                first_load     <= 1'b0;
                rd_pending     <= 1'b0;
            end else if ((first_load || btnc_pulse_sd) && !fifo_empty) begin
                // Cycle 1: advance pointer, BRAM will output data next cycle
                fifo_rd_ptr <= fifo_rd_ptr + 8'd1;
                rd_pending  <= 1'b1;
            end
        end
    end

    // =========================================================
    // Cross display value from clk_sd -> clk (100 MHz)
    // The value changes slowly (on button press), so double-FF
    // on a "new data" toggle is sufficient.
    // =========================================================
    // Cross display_val_sd to 100 MHz domain.
    // display_val_sd only changes on button press (very slow), so
    // a simple double-FF on a toggle + value grab is safe.
    // Toggle when rd_pending completes (display_val_sd is updated)
    reg        val_toggle_sd = 1'b0;

    always @(posedge clk_sd or negedge sys_rst_n) begin
        if (!sys_rst_n)
            val_toggle_sd <= 1'b0;
        else if (rd_pending)
            val_toggle_sd <= ~val_toggle_sd;
    end

    // val_toggle_sd fires same cycle as display_val_sd update.
    // The 100MHz synchronizer adds 2-3 cycle latency, so display_val_sd
    // is stable well before we sample it.
    reg [2:0]  val_sync_100 = 3'b0;
    reg [31:0] display_val  = 32'd0;
    reg        has_value     = 1'b0;

    always @(posedge clk) begin
        if (!sys_rst_n) begin
            val_sync_100 <= 3'b0;
            display_val  <= 32'd0;
            has_value    <= 1'b0;
        end else begin
            val_sync_100 <= {val_sync_100[1:0], val_toggle_sd};
            if (val_sync_100[2] ^ val_sync_100[1]) begin
                display_val <= display_val_sd;
                has_value   <= 1'b1;
            end
        end
    end

    // =========================================================
    // Binary to BCD conversion (100 MHz domain)
    // =========================================================
    wire [31:0] bcd_out;
    wire        bcd_valid;
    reg         bcd_start = 1'b0;
    reg         bcd_pending = 1'b0;
    reg [31:0]  last_display_val = 32'd0;

    // Trigger BCD conversion when display value changes
    always @(posedge clk) begin
        if (!sys_rst_n) begin
            bcd_start       <= 1'b0;
            bcd_pending     <= 1'b0;
            last_display_val <= 32'd0;
        end else begin
            bcd_start <= 1'b0;
            if (display_val != last_display_val && has_value) begin
                if (!bcd_pending) begin
                    bcd_start       <= 1'b1;
                    bcd_pending     <= 1'b1;
                    last_display_val <= display_val;
                end
            end
            if (bcd_valid)
                bcd_pending <= 1'b0;
        end
    end

    bin_to_bcd u_bcd (
        .clk        (clk),
        .rst_n      (sys_rst_n),
        .bin_in     (display_val[26:0]),
        .start      (bcd_start),
        .bcd_out_ff (bcd_out),
        .valid_ff   (bcd_valid),
        .toggle_ff  ()
    );

    // Latch BCD output
    reg [31:0] bcd_display = 32'd0;
    always @(posedge clk) begin
        if (!sys_rst_n)
            bcd_display <= 32'd0;
        else if (bcd_valid)
            bcd_display <= bcd_out;
    end

    // =========================================================
    // Seven-segment display (100 MHz domain)
    // Shows decimal value. Blank leading zeros by only enabling
    // digits that have non-zero value in higher nibbles.
    // =========================================================

    // Determine which digits to blank (leading zero suppression)
    // Always show at least digit 0
    wire [7:0] digit_active;
    assign digit_active[0] = 1'b1;  // always show ones digit
    assign digit_active[1] = (bcd_display[31:4]  != 28'd0);
    assign digit_active[2] = (bcd_display[31:8]  != 24'd0);
    assign digit_active[3] = (bcd_display[31:12] != 20'd0);
    assign digit_active[4] = (bcd_display[31:16] != 16'd0);
    assign digit_active[5] = (bcd_display[31:20] != 12'd0);
    assign digit_active[6] = (bcd_display[31:24] != 8'd0);
    assign digit_active[7] = (bcd_display[31:28] != 4'd0);

    // For blanking, we set unused digit nibbles to a "blank" value.
    // The ssd module displays hex, so we'll use 0xF for blank and
    // modify the approach: just pass BCD directly to ssd since
    // digits 0-9 map correctly. Leading zeros will show as '0' but
    // that's fine for a test display.

    ssd #(
        .CLK_FREQ_HZ  (100_000_000),
        .REFRESH_RATE  (500)
    ) u_ssd (
        .clk   (clk),
        .rst_n (sys_rst_n),
        .value (bcd_display),
        .dp_en (8'b0),
        .SEG   (SEG),
        .AN    (AN),
        .DP_n  (DP_n)
    );

    // =========================================================
    // LED status
    // =========================================================
    // Synchronize SD-domain signals to 100MHz for LEDs
    reg [3:0] card_stat_sync;
    reg [1:0] card_type_sync;
    reg [1:0] fs_type_sync;
    reg       file_found_sync;

    always @(posedge clk) begin
        card_stat_sync  <= card_stat;
        card_type_sync  <= card_type;
        fs_type_sync    <= filesystem_type;
        file_found_sync <= file_found;
    end

    assign LED[3:0]   = card_stat_sync;
    assign LED[5:4]   = card_type_sync;
    assign LED[7:6]   = fs_type_sync;
    assign LED[8]     = file_found_sync;
    assign LED[9]     = pll_locked;
    assign LED[10]    = has_value;
    assign LED[15:11] = 5'd0;

endmodule
