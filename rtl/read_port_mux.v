`timescale 1ns / 1ps

// read_port_mux — arbitrates the DDR2 read port between the test
// checker and VGA reader, with test taking priority.
//
// Manages test_active state (blocks VGA reads during test), tracks
// in-flight reads to route rd_data_valid correctly, and provides
// pre-computed enable/valid signals for the VGA reader and test checker
// so the top level has no logical port connections.
//
// Clock domain: ui_clk (~75 MHz).

module read_port_mux (
    input  wire        ui_clk,
    input  wire        rst_n,

    // Test control
    input  wire        test_start,       // pulse: begin test sequence
    input  wire        test_done,        // level: test checker finished
    input  wire        vs_sync,          // CDC'd vsync (from double_buffer_ctrl)
    input  wire        vs_prev,          // previous vsync

    // VGA reader requests
    input  wire        vga_enable,       // from double_buffer_ctrl
    input  wire        vga_rd_req,
    input  wire [26:0] vga_rd_addr,

    // Test checker requests
    input  wire        test_rd_req,
    input  wire [26:0] test_rd_addr,

    // Arbiter read port
    output reg         mux_rd_req,
    output reg  [26:0] mux_rd_addr,
    input  wire        mux_rd_grant,
    input  wire        arb_rd_data_valid,

    // Routed grants
    output reg         vga_rd_grant,
    output reg         test_rd_grant,

    // Pre-computed signals for consumer modules
    output reg         vga_reader_enable,    // vga_enable && !test_active
    output reg         vga_rd_data_valid,    // arb_rd_data_valid when VGA owns read
    output reg         test_rd_data_valid,   // arb_rd_data_valid when test owns read

    // Status
    output wire        test_active
);

    // -------------------------------------------------------------------
    // Test active FSM — blocks VGA reader during test
    // Waits for vsync edge after test_start before activating (clean
    // boundary), clears on test_done.
    // -------------------------------------------------------------------
    reg test_active_ff, test_pending_ff;
    reg test_active_next, test_pending_next;

    always @(*) begin
        test_active_next  = test_active_ff;
        test_pending_next = test_pending_ff;

        if (test_start)
            test_pending_next = 1'b1;
        else if (test_pending_ff && vs_sync && !vs_prev) begin
            test_active_next  = 1'b1;
            test_pending_next = 1'b0;
        end else if (test_done && !test_pending_ff)
            test_active_next = 1'b0;

        if (!rst_n) begin
            test_active_next  = 1'b0;
            test_pending_next = 1'b0;
        end
    end

    always @(posedge ui_clk) begin
        test_active_ff  <= test_active_next;
        test_pending_ff <= test_pending_next;
    end

    assign test_active = test_active_ff;

    // -------------------------------------------------------------------
    // In-flight read tracking — VGA
    // -------------------------------------------------------------------
    reg vga_inflight_ff, vga_inflight_next;

    always @(*) begin
        vga_inflight_next = vga_inflight_ff;
        if (vga_rd_grant)
            vga_inflight_next = 1'b1;
        else if (arb_rd_data_valid && vga_inflight_ff)
            vga_inflight_next = 1'b0;
        if (!rst_n)
            vga_inflight_next = 1'b0;
    end

    always @(posedge ui_clk) begin
        vga_inflight_ff <= vga_inflight_next;
    end

    // -------------------------------------------------------------------
    // In-flight read tracking — test checker
    // -------------------------------------------------------------------
    reg test_inflight_ff, test_inflight_next;

    always @(*) begin
        test_inflight_next = test_inflight_ff;
        if (test_rd_req && mux_rd_grant && rd_owner_ff)
            test_inflight_next = 1'b1;
        else if (arb_rd_data_valid && test_inflight_ff && !vga_inflight_ff)
            test_inflight_next = 1'b0;
        if (!rst_n || test_start)
            test_inflight_next = 1'b0;
    end

    always @(posedge ui_clk) begin
        test_inflight_ff <= test_inflight_next;
    end

    // -------------------------------------------------------------------
    // Request mux: test > VGA
    // -------------------------------------------------------------------
    reg test_needs_port;

    always @(*) begin
        test_needs_port = test_active_ff && (test_rd_req || test_inflight_ff);
        if (test_needs_port) begin
            mux_rd_req  = test_rd_req;
            mux_rd_addr = test_rd_addr;
        end else begin
            mux_rd_req  = vga_rd_req;
            mux_rd_addr = vga_rd_addr;
        end
    end

    // -------------------------------------------------------------------
    // Owner tracking — remembers who issued the pending request
    // 0 = VGA, 1 = test
    // -------------------------------------------------------------------
    reg rd_owner_ff, rd_owner_valid_ff;
    reg rd_owner_next, rd_owner_valid_next;

    always @(*) begin
        rd_owner_next       = rd_owner_ff;
        rd_owner_valid_next = rd_owner_valid_ff;

        if (mux_rd_grant)
            rd_owner_valid_next = 1'b0;
        else if (mux_rd_req && !rd_owner_valid_ff) begin
            rd_owner_valid_next = 1'b1;
            rd_owner_next       = test_needs_port;
        end

        if (!rst_n) begin
            rd_owner_next       = 1'b0;
            rd_owner_valid_next = 1'b0;
        end
    end

    always @(posedge ui_clk) begin
        rd_owner_ff       <= rd_owner_next;
        rd_owner_valid_ff <= rd_owner_valid_next;
    end

    // -------------------------------------------------------------------
    // Grant routing
    // -------------------------------------------------------------------
    always @(*) begin
        if (rd_owner_ff) begin
            test_rd_grant = mux_rd_grant;
            vga_rd_grant  = 1'b0;
        end else begin
            test_rd_grant = 1'b0;
            vga_rd_grant  = mux_rd_grant;
        end
    end

    // -------------------------------------------------------------------
    // Pre-computed enables / valids for consumers
    // -------------------------------------------------------------------
    always @(*) begin
        vga_reader_enable  = vga_enable && !test_active_ff;
        vga_rd_data_valid  = arb_rd_data_valid & vga_inflight_ff;
        test_rd_data_valid = arb_rd_data_valid & test_inflight_ff & ~vga_inflight_ff;
    end

endmodule
