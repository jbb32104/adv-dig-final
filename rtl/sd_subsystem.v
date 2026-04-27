`timescale 1ns / 1ps

// sd_subsystem — groups all SD card infrastructure:
//   sd_file_reader  : reads CSEE4280Primes.txt from SD card
//   sd_line_parser  : parses ASCII decimal lines to binary values
//   sd_prime_bridge : FIFO + handshake bridge from clk_sd to ui_clk
//
// Also handles SD pin constant ties and sd_file_done detection.
//
// Clock domains: clk_sd (50 MHz), ui_clk (~75 MHz).

module sd_subsystem (
    input  wire        clk_sd,
    input  wire        sys_rst_n,
    input  wire        ui_clk,
    input  wire        arb_rst_n,

    // SD card pins
    output wire        sdclk,
    inout              sdcmd,
    input  wire        sddat0,
    output wire        sdcard_pwr_n,
    output wire        sddat1,
    output wire        sddat2,
    output wire        sddat3,

    // Test interface (ui_clk domain)
    input  wire        test_start,
    input  wire        consume,
    output wire [31:0] prime_data,
    output wire        prime_valid,
    output wire        prime_eof,

    // Status
    output wire        file_found
);

    // -------------------------------------------------------------------
    // SD pin constant ties
    // -------------------------------------------------------------------
    assign sdcard_pwr_n = 1'b0;
    assign sddat1       = 1'b1;
    assign sddat2       = 1'b1;
    assign sddat3       = 1'b1;

    // -------------------------------------------------------------------
    // SD file reader
    // -------------------------------------------------------------------
    wire       sd_outen;
    wire [7:0] sd_outbyte;
    wire [2:0] sd_filesystem_state;
    wire       sd_pause;

    sd_file_reader #(
        .FILE_NAME_LEN (18),
        .FILE_NAME     ("CSEE4280Primes.txt"),
        .CLK_DIV       (3'd2),
        .SIMULATE      (0)
    ) u_sd_file_reader (
        .rstn            (sys_rst_n),
        .clk             (clk_sd),
        .sdclk           (sdclk),
        .sdcmd           (sdcmd),
        .sddat0          (sddat0),
        .card_stat       (),
        .card_type       (),
        .filesystem_type (),
        .file_found      (file_found),
        .outen           (sd_outen),
        .outbyte         (sd_outbyte),
        .filesystem_state(sd_filesystem_state),
        .pause           (sd_pause)
    );

    // -------------------------------------------------------------------
    // SD line parser — ASCII decimal to binary
    // -------------------------------------------------------------------
    wire [31:0] sd_parsed_value;
    wire        sd_parsed_valid;

    sd_line_parser u_sd_parser (
        .clk       (clk_sd),
        .rst_n     (sys_rst_n),
        .byte_en   (sd_outen),
        .byte_data (sd_outbyte),
        .value     (sd_parsed_value),
        .valid     (sd_parsed_valid)
    );

    // -------------------------------------------------------------------
    // File-done detection (filesystem_state == DONE)
    // -------------------------------------------------------------------
    reg sd_file_done;

    always @(*) begin
        sd_file_done = (sd_filesystem_state == 3'd6);
    end

    // -------------------------------------------------------------------
    // SD prime bridge — clk_sd FIFO -> ui_clk handshake
    // -------------------------------------------------------------------
    sd_prime_bridge u_sd_bridge (
        .clk_sd       (clk_sd),
        .rst_sd_n     (sys_rst_n),
        .parsed_value (sd_parsed_value),
        .parsed_valid (sd_parsed_valid),
        .file_done    (sd_file_done),
        .sd_pause     (sd_pause),
        .ui_clk       (ui_clk),
        .rst_ui_n     (arb_rst_n),
        .start        (test_start),
        .consume      (consume),
        .prime_data   (prime_data),
        .prime_valid  (prime_valid),
        .prime_eof    (prime_eof)
    );

endmodule
