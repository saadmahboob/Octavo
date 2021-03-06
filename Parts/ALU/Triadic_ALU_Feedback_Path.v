
// Triadic ALU Feedback Path

// Returns previous result (R) and stored previous result (S) to ALU Forward
// Path, as well as some flags if R is zero or negative.

module Triadic_ALU_Feedback_Path
#(
    parameter       WORD_WIDTH          = 0,
    parameter       ADDR_WIDTH          = 0,
    parameter       S_WRITE_ADDR        = 0
)
(
    input   wire                        clock,

    input   wire    [WORD_WIDTH-1:0]    Ra,         // ALU First Result
    input   wire    [WORD_WIDTH-1:0]    Rb,         // ALU Second Result
    input   wire    [ADDR_WIDTH-1:0]    DB,         // Write Address for Rb
    input   wire                        IO_Ready,
    input   wire                        Cancel,

    output  wire    [WORD_WIDTH-1:0]    R,          // Previous Result (Ra from prev instr.)
    output  wire                        R_zero,     // Is R zero? (all-1 if true)
    output  wire                        R_negative, // Is R negative? (all-1 if true)
    output  wire    [WORD_WIDTH-1:0]    S           // Stored Previous Result (from Rb)
);

// --------------------------------------------------------------------

    localparam INPUT_SYNC_DEPTH  = 2;
    localparam INPUT_SYNC_WIDTH  = 1 + 1 + ADDR_WIDTH + WORD_WIDTH + WORD_WIDTH;

    localparam OUTPUT_SYNC_DEPTH = 1;
    localparam OUTPUT_SYNC_WIDTH = 1 + 1 + WORD_WIDTH + WORD_WIDTH;

// --------------------------------------------------------------------
// Stage 3 and 2 (going backwards)

    // Synchronize inputs to Stage 1

    wire                    IO_Ready_stage1;
    wire                    Cancel_stage1;
    wire [WORD_WIDTH-1:0]   DB_stage1;
    wire [WORD_WIDTH-1:0]   Ra_stage1
    wire [WORD_WIDTH-1:0]   Rb_stage1

    Delay_Line 
    #(
        .DEPTH  (INPUT_SYNC_DEPTH), 
        .WIDTH  (INPUT_SYNC_WIDTH)
    ) 
    Input_Sync
    (
        .clock  (clock),
        .in     (IO_Ready,          Cancel,         DB,         Ra,         Rb),
        .out    (IO_Ready_stage1,   Cancel_stage1,  DB_stage1,  Ra_stage1   Rb_stage1)
    );

// --------------------------------------------------------------------
// Stage 1

    // Store Rb into S if DB matches S_WRITE_ADDR and not a NOP

    reg not_nop = 0;

    always @(*) begin
        not_nop <= (IO_Ready_stage1 == 1'b1) & (Cancel_stage1 == 1'b0);
    end

// --------------------------------------------------------------------

    wire wren;

    Address_Range_Decoder_Static
    #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .ADDR_BASE      (S_WRITE_ADDR),
        .ADDR_BOUND     (S_WRITE_ADDR) 
    )
    S_ADDR_MATCH
    (
        .enable         (not_nop),
        .addr           (DB_stage1),
        .hit            (wren)   
    );

    // For now, S is only a single register
    // Expressing it this way leaves the door open to expansion

    wire [WORD_WIDTH-1:0] S_stage0;

    RAM_SDP 
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .ADDR_WIDTH     (1),
        .DEPTH          (1),
        .RAMSTYLE       ("logic"),
        .READ_NEW_DATA  (0),
        .USE_INIT_FILE  (0),
        .INIT_FILE      ()
    )
    S_reg
    (
        .clock          (clock),
        .wren           (wren),
        .write_addr     (0),
        .write_data     (Rb_stage1),
        .rden           (1),
        .read_addr      (0),
        .read_data      (S_stage0)
    );

// --------------------------------------------------------------------

    // Compute R flags

    wire R_zero_stage0;
    wire R_negative_stage0;

    R_Flags
    #(
        .WORD_WIDTH (WORD_WIDTH)
    )
    R_Flags
    (
        .clock      (clock)
        .R          (Ra_stage1),
        .R_zero     (R_zero_stage0),
        .R_negative (R_negative_stage0)
    );

// --------------------------------------------------------------------

    // Pass along Ra_stage1

    reg [WORD_WIDTH-1:0] Ra_stage0 = 0;

    always @(posedge clock) begin
        Ra_stage0 <= Ra_stage1
    end

// --------------------------------------------------------------------
// Stage 0

    // Synchronize outputs

    Delay_Line 
    #(
        .DEPTH  (OUTPUT_SYNC_DEPTH), 
        .WIDTH  (OUTPUT_SYNC_WIDTH)
    ) 
    Output_Sync
    (
        .clock  (clock),
        .in     (Ra_stage0, R_zero_stage0,  R_negative_stage0,  S_stage0),
        .out    (R,         R_zero,         R_negative,         S)
    );



