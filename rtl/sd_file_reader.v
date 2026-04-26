//--------------------------------------------------------------------------------------------------------
// Module  : sdcmd_ctrl
// Type    : synthesizable, IP's sub module
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: sdcmd signal control,
//           instantiated by sd_reader
//--------------------------------------------------------------------------------------------------------

module sdcmd_ctrl (
    input  wire         rstn,
    input  wire         clk,
    // SDcard signals (sdclk and sdcmd)
    output reg          sdclk,
    inout               sdcmd,
    // config clk freq
    input  wire  [15:0] clkdiv,
    // user input signal
    input  wire         start,
    input  wire  [15:0] precnt,
    input  wire  [ 5:0] cmd,
    input  wire  [31:0] arg,
    // user output signal
    output reg          busy,
    output reg          done,
    output reg          timeout,
    output reg          syntaxe,
    output wire  [31:0] resparg
);


initial {busy, done, timeout, syntaxe} = 0;
initial sdclk = 1'b0;

localparam [7:0] TIMEOUT = 8'd250;

reg sdcmdoe  = 1'b0;
reg sdcmdout = 1'b1;

// sdcmd tri-state driver
assign sdcmd = sdcmdoe ? sdcmdout : 1'bz;
wire sdcmdin = sdcmdoe ? 1'b1 : sdcmd;

function  [6:0] CalcCrc7;
    input [6:0] crc;
    input [0:0] inbit;
begin
    CalcCrc7 = ( {crc[5:0],crc[6]^inbit} ^ {3'b0,crc[6]^inbit,3'b0} );
end
endfunction

reg  [ 5:0] req_cmd = 6'd0;    // request[45:40]
reg  [31:0] req_arg = 0;       // request[39: 8]
reg  [ 6:0] req_crc = 7'd0;    // request[ 7: 1]
wire [51:0] request = {6'b111101, req_cmd, req_arg, req_crc, 1'b1};

reg         resp_st;
reg  [ 5:0] resp_cmd;
reg  [31:0] resp_arg;

assign resparg = resp_arg;

reg  [17:0] clkdivr = 18'h3FFFF;
reg  [17:0] clkcnt  = 0;
reg  [15:0] cnt1 = 0;
reg  [ 5:0] cnt2 = 6'h3F;
reg  [ 7:0] cnt3 = 0;
reg  [ 7:0] cnt4 = 8'hFF;


always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        {busy, done, timeout, syntaxe} <= 0;
        sdclk <= 1'b0;
        {sdcmdoe, sdcmdout} <= 2'b01;
        {req_cmd, req_arg, req_crc} <= 0;
        {resp_st, resp_cmd, resp_arg} <= 0;
        clkdivr <= 18'h3FFFF;
        clkcnt  <= 0;
        cnt1 <= 0;
        cnt2 <= 6'h3F;
        cnt3 <= 0;
        cnt4 <= 8'hFF;
    end else begin
        {done, timeout, syntaxe} <= 0;

        clkcnt <= ( clkcnt < {clkdivr[16:0],1'b1} ) ? (clkcnt+18'd1) : 18'd0;

        if     (clkcnt == 18'd0)
            clkdivr <= {2'h0, clkdiv} + 18'd1;

        if (clkcnt == clkdivr)
            sdclk <= 1'b0;
        else if (clkcnt == {clkdivr[16:0],1'b1} )
            sdclk <= 1'b1;

        if(~busy) begin
            if(start) busy <= 1'b1;
            req_cmd <= cmd;
            req_arg <= arg;
            req_crc <= 0;
            cnt1 <= precnt;
            cnt2 <= 6'd51;
            cnt3 <= TIMEOUT;
            cnt4 <= 8'd134;
        end else if(done) begin
            busy <= 1'b0;
        end else if( clkcnt == clkdivr) begin
            {sdcmdoe, sdcmdout} <= 2'b01;
            if     (cnt1 != 16'd0) begin
                cnt1 <= cnt1 - 16'd1;
            end else if(cnt2 != 6'h3F) begin
                cnt2 <= cnt2 - 6'd1;
                {sdcmdoe, sdcmdout} <= {1'b1, request[cnt2]};
                if(cnt2>=8 && cnt2<48) req_crc <= CalcCrc7(req_crc, request[cnt2]);
            end
        end else if( clkcnt == {clkdivr[16:0],1'b1} && cnt1==16'd0 && cnt2==6'h3F ) begin
            if(cnt3 != 8'd0) begin
                cnt3 <= cnt3 - 8'd1;
                if(~sdcmdin)
                    cnt3 <= 8'd0;
                else if(cnt3 == 8'd1)
                    {done, timeout, syntaxe} <= 3'b110;
            end else if(cnt4 != 8'hFF) begin
                cnt4 <= cnt4 - 8'd1;
                if(cnt4 >= 8'd96)
                    {resp_st, resp_cmd, resp_arg} <= {resp_cmd, resp_arg, sdcmdin};
                if(cnt4 == 8'd0) begin
                    {done, timeout} <= 2'b10;
                    syntaxe <= resp_st || ((resp_cmd!=req_cmd) && (resp_cmd!=6'h3F) && (resp_cmd!=6'd0));
                end
            end
        end
    end

endmodule


//--------------------------------------------------------------------------------------------------------
// Module  : sd_reader
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A SD-host to initialize SD-card and read sector
//           Support CardType   : SDv1.1 , SDv2  or SDHCv2
//--------------------------------------------------------------------------------------------------------

module sd_reader # (
    parameter [2:0] CLK_DIV = 3'd2,     // when clk =   0~ 25MHz , set CLK_DIV = 3'd1,
                                        // when clk =  25~ 50MHz , set CLK_DIV = 3'd2,
                                        // when clk =  50~100MHz , set CLK_DIV = 3'd3,
                                        // when clk = 100~200MHz , set CLK_DIV = 3'd4,
                                        // ......
    parameter       SIMULATE = 0
) (
    // rstn active-low, 1:working, 0:reset
    input  wire         rstn,
    // clock
    input  wire         clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    output wire         sdclk,
    inout               sdcmd,
    input  wire         sddat0,            // FPGA only read SDDAT signal but never drive it
    // show card status
    output wire [ 3:0]  card_stat,         // show the sdcard initialize status
    output reg  [ 1:0]  card_type,         // 0=UNKNOWN    , 1=SDv1    , 2=SDv2  , 3=SDHCv2
    // user read sector command interface (sync with clk)
    input  wire         rstart,
    input  wire [31:0]  rsector,
    output wire         rbusy,
    output wire         rdone,
    // sector data output interface (sync with clk)
    output reg          outen,             // when outen=1, a byte of sector content is read out from outbyte
    output reg  [ 8:0]  outaddr,           // outaddr from 0 to 511, because the sector size is 512
    output reg  [ 7:0]  outbyte            // a byte of sector content
);


initial {outen, outaddr, outbyte} = 0;

localparam [1:0] UNKNOWN = 2'd0,      // SD card type
                 SDv1    = 2'd1,
                 SDv2    = 2'd2,
                 SDHCv2  = 2'd3;

localparam [15:0] FASTCLKDIV = (16'd1 << CLK_DIV) ;
localparam [15:0] SLOWCLKDIV = FASTCLKDIV * (SIMULATE ? 16'd5 : 16'd48);

reg        start  = 1'b0;
reg [15:0] precnt = 0;
reg [ 5:0] cmd    = 0;
reg [31:0] arg    = 0;
reg [15:0] clkdiv = SLOWCLKDIV;
reg [31:0] rsectoraddr = 0;

wire       busy, done, timeout, syntaxe;
wire[31:0] resparg;

reg        sdv1_maybe = 1'b0;
reg [ 2:0] cmd8_cnt   = 0;
reg [15:0] rca = 0;

localparam [3:0] CMD0      = 4'd0,
                 CMD8      = 4'd1,
                 CMD55_41  = 4'd2,
                 ACMD41    = 4'd3,
                 CMD2      = 4'd4,
                 CMD3      = 4'd5,
                 CMD7      = 4'd6,
                 CMD16     = 4'd7,
                 CMD17     = 4'd8,
                 READING   = 4'd9,
                 READING2  = 4'd10;

reg [3:0] sdcmd_stat = CMD0;

reg        sdclkl = 1'b0;

localparam [2:0] RWAIT    = 3'd0,
                 RDURING  = 3'd1,
                 RTAIL    = 3'd2,
                 RDONE    = 3'd3,
                 RTIMEOUT = 3'd4;

reg [2:0] sddat_stat = RWAIT;

reg [31:0] ridx   = 0;

assign     rbusy  = (sdcmd_stat != CMD17) ;
assign     rdone  = (sdcmd_stat == READING2) && (sddat_stat==RDONE);

assign card_stat = sdcmd_stat;


sdcmd_ctrl u_sdcmd_ctrl (
    .rstn        ( rstn         ),
    .clk         ( clk          ),
    .sdclk       ( sdclk        ),
    .sdcmd       ( sdcmd        ),
    .clkdiv      ( clkdiv       ),
    .start       ( start        ),
    .precnt      ( precnt       ),
    .cmd         ( cmd          ),
    .arg         ( arg          ),
    .busy        ( busy         ),
    .done        ( done         ),
    .timeout     ( timeout      ),
    .syntaxe     ( syntaxe      ),
    .resparg     ( resparg      )
);


task set_cmd;
    input [ 0:0] _start;
    input [15:0] _precnt;
    input [ 5:0] _cmd;
    input [31:0] _arg;
begin
    start  <= _start;
    precnt <= _precnt;
    cmd    <= _cmd;
    arg    <= _arg;
end
endtask




always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        set_cmd(0,0,0,0);
        clkdiv      <= SLOWCLKDIV;
        rsectoraddr <= 0;
        rca         <= 0;
        sdv1_maybe  <= 1'b0;
        card_type   <= UNKNOWN;
        sdcmd_stat  <= CMD0;
        cmd8_cnt    <= 0;
    end else begin
        set_cmd(0,0,0,0);
        if(sdcmd_stat == READING2) begin
            if(sddat_stat==RTIMEOUT) begin
                set_cmd(1, 96, 17, rsectoraddr);
                sdcmd_stat <= READING;
            end else if(sddat_stat==RDONE)
                sdcmd_stat <= CMD17;
        end else if(~busy) begin
            case(sdcmd_stat)
                CMD0    :   set_cmd(1, (SIMULATE?512:64000),  0,  'h00000000);
                CMD8    :   set_cmd(1,                 512 ,  8,  'h000001aa);
                CMD55_41:   set_cmd(1,                 512 , 55,  'h00000000);
                ACMD41  :   set_cmd(1,                 256 , 41,  'h40100000);
                CMD2    :   set_cmd(1,                 256 ,  2,  'h00000000);
                CMD3    :   set_cmd(1,                 256 ,  3,  'h00000000);
                CMD7    :   set_cmd(1,                 256 ,  7, {rca,16'h0});
                CMD16   :   set_cmd(1, (SIMULATE?512:64000), 16,  'h00000200);
                CMD17   :   if(rstart) begin
                                set_cmd(1, 96, 17, (card_type==SDHCv2) ? rsector : (rsector<<9) );
                                rsectoraddr <= (card_type==SDHCv2) ? rsector : (rsector<<9);
                                sdcmd_stat <= READING;
                            end
            endcase
        end else if(done) begin
            case(sdcmd_stat)
                CMD0    :   sdcmd_stat <= CMD8;
                CMD8    :   if(~timeout && ~syntaxe && resparg[7:0]==8'haa) begin
                                sdcmd_stat <= CMD55_41;
                            end else if(timeout) begin
                                cmd8_cnt <= cmd8_cnt + 3'd1;
                                if (cmd8_cnt == 3'b111) begin
                                    sdv1_maybe <= 1'b1;
                                    sdcmd_stat <= CMD55_41;
                                end
                            end
                CMD55_41:   if(~timeout && ~syntaxe)
                                sdcmd_stat <= ACMD41;
                ACMD41  :   if(~timeout && ~syntaxe && resparg[31]) begin
                                card_type <= sdv1_maybe ? SDv1 : (resparg[30] ? SDHCv2 : SDv2);
                                sdcmd_stat <= CMD2;
                            end else begin
                                sdcmd_stat <= CMD55_41;
                            end
                CMD2    :   if(~timeout && ~syntaxe)
                                sdcmd_stat <= CMD3;
                CMD3    :   if(~timeout && ~syntaxe) begin
                                rca <= resparg[31:16];
                                sdcmd_stat <= CMD7;
                            end
                CMD7    :   if(~timeout && ~syntaxe) begin
                                clkdiv  <= FASTCLKDIV;
                                sdcmd_stat <= CMD16;
                            end
                CMD16   :   if(~timeout && ~syntaxe)
                                sdcmd_stat <= CMD17;
                default : //READING :
                            if(~timeout && ~syntaxe)
                                sdcmd_stat <= READING2;
                            else
                                set_cmd(1, 128, 17, rsectoraddr);
            endcase
        end
    end


always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        outen   <= 1'b0;
        outaddr <= 0;
        outbyte <= 0;
        sdclkl  <= 1'b0;
        sddat_stat <= RWAIT;
        ridx    <= 0;
    end else begin
        outen   <= 1'b0;
        outaddr <= 0;
        sdclkl  <= sdclk;
        if(sdcmd_stat!=READING && sdcmd_stat!=READING2) begin
            sddat_stat <= RWAIT;
            ridx   <= 0;
        end else if(~sdclkl & sdclk) begin
            case(sddat_stat)
                RWAIT   : begin
                    if(~sddat0) begin
                        sddat_stat <= RDURING;
                        ridx   <= 0;
                    end else begin
                        if(ridx > 1000000)      // according to SD datasheet, 1ms is enough to wait for DAT result, here, we set timeout to 1000000 clock cycles = 80ms (when SDCLK=12.5MHz)
                            sddat_stat <= RTIMEOUT;
                        ridx   <= ridx + 1;
                    end
                end
                RDURING : begin
                    outbyte[3'd7 - ridx[2:0]] <= sddat0;
                    if(ridx[2:0] == 3'd7) begin
                        outen  <= 1'b1;
                        outaddr<= ridx[11:3];
                    end
                    if(ridx >= 512*8-1) begin
                        sddat_stat <= RTAIL;
                        ridx   <= 0;
                    end else begin
                        ridx   <= ridx + 1;
                    end
                end
                RTAIL   : begin
                    if (ridx >= 8*8-1)
                        sddat_stat <= RDONE;
                    ridx   <= ridx + 1;
                end
            endcase
        end
    end


endmodule


//--------------------------------------------------------------------------------------------------------
// Module  : sd_file_reader
// Type    : synthesizable, IP's top
// Standard: Verilog 2001 (IEEE1364-2001)
// Function: A SD-card host to initialize SD-card and read files
//           Specify a filename, sd_file_reader will read out file content
//           Support CardType   : SDv1.1 , SDv2  or SDHCv2
//           Support FileSystem : FAT16 or FAT32
//--------------------------------------------------------------------------------------------------------

module sd_file_reader #(
    parameter            FILE_NAME_LEN = 8           , // length of FILE_NAME (in bytes). Since the length of "example.txt" is 11, so here is 11.
    parameter [52*8-1:0] FILE_NAME     = "data.txt", // file name to read, ignore upper and lower case
                                                        // For example, if you want to read a file named "HeLLo123.txt", this parameter can be "hello123.TXT", "HELLO123.txt" or "HEllo123.Txt"
    parameter      [2:0] CLK_DIV       = 3'd2,          // when clk =   0~ 25MHz , set CLK_DIV = 3'd1,
                                                        // when clk =  25~ 50MHz , set CLK_DIV = 3'd2,
                                                        // when clk =  50~100MHz , set CLK_DIV = 3'd3,
                                                        // when clk = 100~200MHz , set CLK_DIV = 3'd4,
                                                        // ......
    parameter            SIMULATE      = 0              // 0:normal use.         1:only for simulation
) (
    // rstn active-low, 1:working, 0:reset
    input  wire       rstn,
    // clock
    input  wire       clk,
    // SDcard signals (connect to SDcard), this design do not use sddat1~sddat3.
    output wire       sdclk,
    inout             sdcmd,
    input  wire       sddat0,            // FPGA only read SDDAT signal but never drive it
    // status output (optional for user)
    output wire [3:0] card_stat,         // show the sdcard initialize status
    output wire [1:0] card_type,         // 0=UNKNOWN    , 1=SDv1    , 2=SDv2  , 3=SDHCv2
    output wire [1:0] filesystem_type,   // 0=UNASSIGNED , 1=UNKNOWN , 2=FAT16 , 3=FAT32
    output reg        file_found,        // 0=file not found, 1=file found
    // file content data output (sync with clk)
    output reg        outen,             // when outen=1, a byte of file content is read out from outbyte
    output reg  [7:0] outbyte,            // a byte of file content
    output reg  [2:0] filesystem_state
);



function  [7:0] toUpperCase;
    input [7:0] in;
begin
    toUpperCase = (in>=8'h61 && in<=8'h7A) ? (in & 8'b11011111) : in;
end
endfunction



wire [52*8-1:0] FILE_NAME_UPPER;

generate genvar k;
    for (k=0; k<52; k=k+1) begin : convert_fname_to_upper
        assign FILE_NAME_UPPER[k*8 +: 8] = toUpperCase( FILE_NAME[k*8 +: 8] );
    end
endgenerate



initial file_found = 1'b0;
initial {outen,outbyte} = 0;


reg         read_start     = 1'b0;
reg  [31:0] read_sector_no = 0;
wire        read_done;

wire        rvalid;
wire [ 8:0] raddr;
wire [ 7:0] rdata;

reg  [31:0] rootdir_sector = 0 , rootdir_sector_t;             // rootdir sector number (FAT16 only)
reg  [15:0] rootdir_sectorcount = 0 , rootdir_sectorcount_t;   // (FAT16 only)

reg  [31:0] curr_cluster = 0 , curr_cluster_t;    // current reading cluster number

wire [ 6:0] curr_cluster_fat_offset;
wire [24:0] curr_cluster_fat_no;
assign {curr_cluster_fat_no,curr_cluster_fat_offset} = curr_cluster;

wire [ 7:0] curr_cluster_fat_offset_fat16;
wire [23:0] curr_cluster_fat_no_fat16;
assign {curr_cluster_fat_no_fat16,curr_cluster_fat_offset_fat16} = curr_cluster;

reg  [31:0] target_cluster = 0;           // target cluster number item in FAT32 table
reg  [15:0] target_cluster_fat16 = 16'h0; // target cluster number item in FAT16 table
reg  [ 7:0] cluster_sector_offset=8'h0 , cluster_sector_offset_t;   // current sector number in cluster

reg  [31:0] file_cluster = 0;
reg  [31:0] file_size = 0;

reg  [ 7:0] cluster_size = 0 , cluster_size_t;
reg  [31:0] first_fat_sector_no = 0 , first_fat_sector_no_t;
reg  [31:0] first_data_sector_no= 0 , first_data_sector_no_t;

reg         search_fat = 1'b0;

localparam [2:0] RESET         = 3'd0,
                 SEARCH_MBR    = 3'd1,
                 SEARCH_DBR    = 3'd2,
                 LS_ROOT_FAT16 = 3'd3,
                 LS_ROOT_FAT32 = 3'd4,
                 READ_A_FILE   = 3'd5,
                 DONE          = 3'd6;

reg        [2:0] filesystem_state = RESET;

localparam [1:0] UNASSIGNED = 2'd0,
                 UNKNOWN    = 2'd1,
                 FAT16      = 2'd2,
                 FAT32      = 2'd3;

reg        [1:0] filesystem = UNASSIGNED,
                 filesystem_parsed;


assign filesystem_type = filesystem;


//----------------------------------------------------------------------------------------------------------------------
// loop variables
integer ii, i;


//----------------------------------------------------------------------------------------------------------------------
// store MBR or DBR fields
//----------------------------------------------------------------------------------------------------------------------
reg [ 7:0] sector_content [0:511];
initial for (ii=0; ii<512; ii=ii+1) sector_content[ii] = 0;

always @ (posedge clk)
    if (rvalid)
        sector_content[raddr] <= rdata;



//----------------------------------------------------------------------------------------------------------------------
// parse MBR or DBR fields
//----------------------------------------------------------------------------------------------------------------------
wire        is_boot_sector     = ( {sector_content['h1FE],sector_content['h1FF]}==16'h55AA );
wire        is_dbr             =    sector_content[0]==8'hEB || sector_content[0]==8'hE9;
wire [31:0] dbr_sector_no      =   {sector_content['h1C9],sector_content['h1C8],sector_content['h1C7],sector_content['h1C6]};
wire [15:0] bytes_per_sector   =   {sector_content['hC],sector_content['hB]};
wire [ 7:0] sector_per_cluster =    sector_content['hD];
wire [15:0] resv_sectors       =   {sector_content['hF],sector_content['hE]};
wire [ 7:0] number_of_fat      =    sector_content['h10];
wire [15:0] rootdir_itemcount  =   {sector_content['h12],sector_content['h11]};   // root dir item count (FAT16 Only)

reg  [31:0] sectors_per_fat = 0;
reg  [31:0] root_cluster    = 0;

always @ (*) begin
    sectors_per_fat   = {16'h0, sector_content['h17], sector_content['h16]};
    root_cluster      = 0;
    if(sectors_per_fat>0) begin                     // FAT16 case
        filesystem_parsed = FAT16;
    end else if(sector_content['h56]==8'h32) begin  // FAT32 case
        filesystem_parsed = FAT32;
        sectors_per_fat   = {sector_content['h27],sector_content['h26],sector_content['h25],sector_content['h24]};
        root_cluster      = {sector_content['h2F],sector_content['h2E],sector_content['h2D],sector_content['h2C]};
    end else begin   // Unknown FileSystem
        filesystem_parsed = UNKNOWN;
    end
end



//----------------------------------------------------------------------------------------------------------------------
// main FSM
//----------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        read_start <= 1'b0;
        read_sector_no <= 0;
        filesystem_state <= RESET;
        filesystem <= UNASSIGNED;
        search_fat <= 1'b0;
        cluster_size <= 8'h0;
        first_fat_sector_no   <= 0;
        first_data_sector_no  <= 0;
        curr_cluster          <= 0;
        cluster_sector_offset <= 8'h0;
        rootdir_sector        <= 0;
        rootdir_sectorcount   <= 16'h0;
    end else begin
        cluster_size_t = cluster_size;
        first_fat_sector_no_t  = first_fat_sector_no;
        first_data_sector_no_t = first_data_sector_no;
        curr_cluster_t = curr_cluster;
        cluster_sector_offset_t = cluster_sector_offset;
        rootdir_sector_t = rootdir_sector;
        rootdir_sectorcount_t = rootdir_sectorcount;

        read_start <= 1'b0;

        if (read_done) begin
            case(filesystem_state)
            SEARCH_MBR :    if(is_boot_sector) begin
                                filesystem_state <= SEARCH_DBR;
                                if(~is_dbr) read_sector_no <= dbr_sector_no;
                            end else begin
                                read_sector_no <= read_sector_no + 1;
                            end
            SEARCH_DBR :    if(is_boot_sector && is_dbr ) begin
                                if(bytes_per_sector!=16'd512) begin
                                    filesystem_state <= DONE;
                                end else begin
                                    filesystem <= filesystem_parsed;
                                    if(filesystem_parsed==FAT16) begin
                                        cluster_size_t        = sector_per_cluster;
                                        first_fat_sector_no_t = read_sector_no + resv_sectors;

                                        rootdir_sectorcount_t = rootdir_itemcount / (16'd512/16'd32);
                                        rootdir_sector_t      = first_fat_sector_no_t + sectors_per_fat * number_of_fat;
                                        first_data_sector_no_t= rootdir_sector_t + rootdir_sectorcount_t - cluster_size_t*2;

                                        cluster_sector_offset_t = 8'h0;
                                        read_sector_no      <= rootdir_sector_t + cluster_sector_offset_t;
                                        filesystem_state <= LS_ROOT_FAT16;
                                    end else if(filesystem_parsed==FAT32) begin
                                        cluster_size_t        = sector_per_cluster;
                                        first_fat_sector_no_t = read_sector_no + resv_sectors;

                                        first_data_sector_no_t= first_fat_sector_no_t + sectors_per_fat * number_of_fat - cluster_size_t * 2;

                                        curr_cluster_t        = root_cluster;
                                        cluster_sector_offset_t = 8'h0;
                                        read_sector_no      <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                        filesystem_state <= LS_ROOT_FAT32;
                                    end else begin
                                        filesystem_state <= DONE;
                                    end
                                end
                            end
            LS_ROOT_FAT16 :     if(file_found) begin
                                    curr_cluster_t = file_cluster;
                                    cluster_sector_offset_t = 8'h0;
                                    read_sector_no <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                    filesystem_state <= READ_A_FILE;
                                end else if(cluster_sector_offset_t<rootdir_sectorcount_t) begin
                                    cluster_sector_offset_t = cluster_sector_offset_t + 8'd1;
                                    read_sector_no <= rootdir_sector_t + cluster_sector_offset_t;
                                end else begin
                                    filesystem_state <= DONE;   // cant find target file
                                end
            LS_ROOT_FAT32 : if(~search_fat) begin
                                if(file_found) begin
                                    curr_cluster_t = file_cluster;
                                    cluster_sector_offset_t = 8'h0;
                                    read_sector_no <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                    filesystem_state <= READ_A_FILE;
                                end else if(cluster_sector_offset_t<(cluster_size_t-1)) begin
                                    cluster_sector_offset_t = cluster_sector_offset_t + 8'd1;
                                    read_sector_no <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                end else begin   // read FAT to get next cluster
                                    search_fat <= 1'b1;
                                    cluster_sector_offset_t = 8'h0;
                                    read_sector_no <= first_fat_sector_no_t + curr_cluster_fat_no;
                                end
                            end else begin
                                search_fat <= 1'b0;
                                cluster_sector_offset_t = 8'h0;
                                if(target_cluster=='h0FFF_FFFF || target_cluster=='h0FFF_FFF8 || target_cluster=='hFFFF_FFFF || target_cluster<2) begin
                                    filesystem_state <= DONE;   // cant find target file
                                end else begin
                                    curr_cluster_t = target_cluster;
                                    read_sector_no <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                end
                            end
            READ_A_FILE  :
                            if(~search_fat) begin
                                if(cluster_sector_offset_t<(cluster_size_t-1)) begin
                                    cluster_sector_offset_t = cluster_sector_offset_t + 8'd1;
                                    read_sector_no <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                end else begin   // read FAT to get next cluster
                                    search_fat <= 1'b1;
                                    cluster_sector_offset_t = 8'h0;
                                    read_sector_no <= first_fat_sector_no_t + (filesystem==FAT16 ? curr_cluster_fat_no_fat16 : curr_cluster_fat_no);
                                end
                            end else begin
                                search_fat <= 1'b0;
                                cluster_sector_offset_t = 8'h0;
                                if(filesystem==FAT16) begin
                                    if(target_cluster_fat16>=16'hFFF0 || target_cluster_fat16<16'h2) begin
                                        filesystem_state <= DONE;   // read to the end of file, done
                                    end else begin
                                        curr_cluster_t = {16'h0,target_cluster_fat16};
                                        read_sector_no <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                    end
                                end else begin
                                    if(target_cluster=='h0FFF_FFFF || target_cluster=='h0FFF_FFF8 || target_cluster=='hFFFF_FFFF || target_cluster<2) begin
                                        filesystem_state <= DONE;   // read to the end of file, done
                                    end else begin
                                        curr_cluster_t = target_cluster;
                                        read_sector_no <= first_data_sector_no_t + cluster_size_t * curr_cluster_t + cluster_sector_offset_t;
                                    end
                                end
                            end
            endcase
        end else begin
            case (filesystem_state)
                RESET         : filesystem_state  <= SEARCH_MBR;
                SEARCH_MBR    : read_start <= 1'b1;
                SEARCH_DBR    : read_start <= 1'b1;
                LS_ROOT_FAT16 : read_start <= 1'b1;
                LS_ROOT_FAT32 : read_start <= 1'b1;
                READ_A_FILE   : read_start <= 1'b1;
                //DONE          : $finish;
            endcase
        end

        cluster_size <= cluster_size_t;
        first_fat_sector_no <= first_fat_sector_no_t;
        first_data_sector_no <= first_data_sector_no_t;
        curr_cluster <= curr_cluster_t;
        cluster_sector_offset <= cluster_sector_offset_t;
        rootdir_sector <= rootdir_sector_t;
        rootdir_sectorcount <= rootdir_sectorcount_t;
    end


generate if (SIMULATE) begin
    always @ (posedge clk)
        if (read_done) begin
        end else begin
            if (filesystem_state == DONE) $finish;   // only for finish simulation, will be ignore when synthesize
        end
end endgenerate




//----------------------------------------------------------------------------------------------------------------------
// capture data in FAT table
//----------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn) begin
    if(~rstn) begin
        target_cluster <= 0;
        target_cluster_fat16 <= 16'h0;
    end else begin
        if(search_fat && rvalid) begin
            if(filesystem==FAT16) begin
                if(raddr[8:1]==curr_cluster_fat_offset_fat16)
                    target_cluster_fat16[8*raddr[0] +: 8] <= rdata;
            end else if(filesystem==FAT32) begin
                if(raddr[8:2]==curr_cluster_fat_offset)
                    target_cluster[8*raddr[1:0] +: 8] <= rdata;
            end
        end
    end
end


sd_reader #(
    .CLK_DIV    ( CLK_DIV        ),
    .SIMULATE   ( SIMULATE       )
) u_sd_reader (
    .rstn       ( rstn           ),
    .clk        ( clk            ),
    .sdclk      ( sdclk          ),
    .sdcmd      ( sdcmd          ),
    .sddat0     ( sddat0         ),
    .card_type  ( card_type      ),
    .card_stat  ( card_stat      ),
    .rstart     ( read_start     ),
    .rsector    ( read_sector_no ),
    .rbusy      (                ),
    .rdone      ( read_done      ),
    .outen      ( rvalid         ),
    .outaddr    ( raddr          ),
    .outbyte    ( rdata          )
);



//----------------------------------------------------------------------------------------------------------------------
// parse root dir
//----------------------------------------------------------------------------------------------------------------------
reg         fready = 1'b0;            // a file is find when fready = 1
reg  [ 7:0] fnamelen = 0;
reg  [15:0] fcluster = 0;
reg  [31:0] fsize = 0;
reg  [ 7:0] fname [0:51];
reg  [ 7:0] file_name [0:51];
reg         isshort=1'b0, islongok=1'b0, islong=1'b0, longvalid=1'b0;
reg         isshort_t   , islongok_t   , islong_t   , longvalid_t   ;
reg  [ 5:0] longno = 6'h0 , longno_t;
reg  [ 7:0] lastchar = 8'h0;
reg  [ 7:0] fdtnamelen = 8'h0 , fdtnamelen_t;
reg  [ 7:0] sdtnamelen = 8'h0 , sdtnamelen_t;
reg  [ 7:0] file_namelen = 8'h0;
reg  [15:0] file_1st_cluster = 16'h0 , file_1st_cluster_t;
reg  [31:0] file_1st_size = 0 , file_1st_size_t;

initial for(i=0;i<52;i=i+1) begin file_name[i]=8'h0; fname[i]=8'h0; end

always @ (posedge clk or negedge rstn) begin
    if(~rstn) begin
        fready<=1'b0;  fnamelen<=8'h0; file_namelen<=8'h0;
        fcluster<=16'h0;  fsize<=0;
        for(i=0;i<52;i=i+1) begin file_name[i]<=8'h0; fname[i]<=8'h0; end

        {isshort, islongok, islong, longvalid} <= 4'b0000;

        longno     <= 6'h0;
        lastchar   <= 8'h0;
        fdtnamelen <= 8'h0;
        sdtnamelen <= 8'h0;
        file_1st_cluster <= 16'h0;
        file_1st_size <= 0;
    end else begin
        {isshort_t, islongok_t, islong_t, longvalid_t} = {isshort, islongok, islong, longvalid};
        longno_t = longno;
        fdtnamelen_t = fdtnamelen;
        sdtnamelen_t = sdtnamelen;
        file_1st_cluster_t = file_1st_cluster;
        file_1st_size_t = file_1st_size;

        fready<=1'b0;  fnamelen<=8'h0;
        for(i=0;i<52;i=i+1) fname[i]<=8'h0;
        fcluster<=16'h0;  fsize<=0;

        if( rvalid && (filesystem_state==LS_ROOT_FAT16||filesystem_state==LS_ROOT_FAT32) && ~search_fat ) begin
            case (raddr[4:0])
                5'h1A : file_1st_cluster_t[ 0+:8] = rdata;
                5'h1B : file_1st_cluster_t[ 8+:8] = rdata;
                5'h1C :    file_1st_size_t[ 0+:8] = rdata;
                5'h1D :    file_1st_size_t[ 8+:8] = rdata;
                5'h1E :    file_1st_size_t[16+:8] = rdata;
                5'h1F :    file_1st_size_t[24+:8] = rdata;
            endcase

            if(raddr[4:0]==5'h0) begin
                {islongok_t, isshort_t} = 2'b00;
                fdtnamelen_t = 8'h0;  sdtnamelen_t=8'h0;

                if(rdata!=8'hE5 && rdata!=8'h2E && rdata!=8'h00) begin
                    if(islong_t && longno_t==6'h1)
                        islongok_t = 1'b1;
                    else
                        isshort_t = 1'b1;
                end

                if(rdata[7]==1'b0 && ~islongok_t) begin
                    if(rdata[6]) begin
                        {islong_t,longvalid_t} = 2'b11;
                        longno_t = rdata[5:0];
                    end else if(islong_t) begin
                        if(longno_t>6'h1 && (rdata[5:0]+6'h1==longno_t) ) begin
                            islong_t = 1'b1;
                            longno_t = rdata[5:0];
                        end else begin
                            islong_t = 1'b0;
                        end
                    end else
                        islong_t = 1'b0;
                end else
                    islong_t = 1'b0;
            end else if(raddr[4:0]==5'hB) begin
                if(rdata!=8'h0F)
                    islong_t = 1'b0;
                if(rdata!=8'h20)
                    {isshort_t, islongok_t} = 2'b00;
            end else if(raddr[4:0]==5'h1F) begin
                if(islongok_t && longvalid_t || isshort_t) begin
                    fready <= 1'b1;
                    fnamelen <= file_namelen;
                    for(i=0;i<52;i=i+1) fname[i] <= (i<file_namelen) ? file_name[i] : 8'h0;
                    fcluster <= file_1st_cluster_t;
                    fsize <= file_1st_size_t;
                end
            end

            if(islong_t) begin
                if(raddr[4:0]>5'h0&&raddr[4:0]<5'hB || raddr[4:0]>=5'hE&&raddr[4:0]<5'h1A || raddr[4:0]>=5'h1C)begin
                    if(raddr[4:0]<5'hB ? raddr[0] : ~raddr[0]) begin
                        lastchar <= rdata;
                        fdtnamelen_t = fdtnamelen_t + 8'd1;
                    end else begin
                        if({rdata,lastchar} == 16'h0000) begin
                            file_namelen <= fdtnamelen_t-8'd1 + (longno_t-8'd1)*8'd13;
                        end else if({rdata,lastchar} != 16'hFFFF) begin
                            if(rdata == 8'h0) begin
                                file_name[fdtnamelen_t-8'd1+(longno_t-8'd1)*8'd13] <= (lastchar>=8'h61 && lastchar<=8'h7A) ? lastchar&8'b11011111 : lastchar;
                            end else begin
                                longvalid_t = 1'b0;
                            end
                        end
                    end
                end
            end

            if(isshort_t) begin
                if(raddr[4:0]<5'h8) begin
                    if(rdata!=8'h20) begin
                        file_name[sdtnamelen_t] <= rdata;
                        sdtnamelen_t = sdtnamelen_t + 8'd1;
                    end
                end else if(raddr[4:0]<5'hB) begin
                    if(raddr[4:0]==5'h8) begin
                        file_name[sdtnamelen_t] <= 8'h2E;
                        sdtnamelen_t = sdtnamelen_t + 8'd1;
                    end
                    if(rdata!=8'h20) begin
                        file_name[sdtnamelen_t] <= rdata;
                        sdtnamelen_t = sdtnamelen_t + 8'd1;
                    end
                end else if(raddr[4:0]==5'hB) begin
                    file_namelen <= sdtnamelen_t;
                end
            end

        end

        {isshort, islongok, islong, longvalid} <= {isshort_t, islongok_t, islong_t, longvalid_t};
        longno <= longno_t;
        fdtnamelen <= fdtnamelen_t;
        sdtnamelen <= sdtnamelen_t;
        file_1st_cluster <= file_1st_cluster_t;
        file_1st_size <= file_1st_size_t;
    end
end



//----------------------------------------------------------------------------------------------------------------------
// compare Target filename with Parsed filename
//----------------------------------------------------------------------------------------------------------------------
always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        file_found <= 1'b0;
        file_cluster <= 0;
        file_size <= 0;
    end else begin
        if (fready && fnamelen==FILE_NAME_LEN) begin
            file_found <= 1'b1;
            file_cluster <= fcluster;
            file_size <= fsize;
            for (ii=0; ii<FILE_NAME_LEN; ii=ii+1) begin
                if( fname[FILE_NAME_LEN-1-ii] != FILE_NAME_UPPER[ii*8+:8] ) begin
                    file_found <= 1'b0;
                    file_cluster <= 0;
                    file_size <= 0;
                end
            end
        end
    end



//----------------------------------------------------------------------------------------------------------------------
// output file content
//----------------------------------------------------------------------------------------------------------------------
reg [31:0] fptr = 0;

always @ (posedge clk or negedge rstn)
    if(~rstn) begin
        fptr <= 0;
        {outen,outbyte} <= 0;
    end else begin
        if(rvalid && filesystem_state==READ_A_FILE && ~search_fat && fptr<file_size) begin
            fptr <= fptr + 1;
            {outen,outbyte} <= {1'b1,rdata};
        end else
            {outen,outbyte} <= 0;
    end


endmodule
