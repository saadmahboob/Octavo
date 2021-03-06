
// Programmable Offsets and Increments (PO/PI) Memory for the Address Module.
// This memory internally self-increments when we access an indirect memory
// location. We can also externally write to update a PO entry, with priority
// over the self-increment.

`default_nettype none

module Address_Module_PO_Memory
#(
    // Offsets are address-wide to reach all memory
    parameter       ADDR_WIDTH                  = 0,
    // Multiple Programmed Offset/Increment per Thread
    parameter       PO_INCR_WIDTH               = 0,
    parameter       PO_ADDR_WIDTH               = 0,
    parameter       PO_ENTRY_COUNT              = 0,
    parameter       PO_ENTRY_WIDTH              = 0,
    parameter       PO_INIT_FILE                = "",
    // Common RAM parameters
    parameter       RAMSTYLE                    = "",
    parameter       READ_NEW_DATA               = 0,
    // Multithreading
    parameter       THREAD_COUNT                = 0,
    parameter       THREAD_COUNT_WIDTH          = 0
)
(
    input   wire                                clock,
    input   wire    [THREAD_COUNT_WIDTH-1:0]    read_thread,
    input   wire    [THREAD_COUNT_WIDTH-1:0]    write_thread,
    input   wire    [ADDR_WIDTH-1:0]            raw_addr,
    input   wire                                IO_Ready_current,
    input   wire                                Cancel_current,
    input   wire                                IO_Ready_previous,
    input   wire                                Cancel_previous,
    // External write port 
    input   wire                                po_wren,
    input   wire    [PO_ADDR_WIDTH-1:0]         po_write_addr,
    input   wire    [PO_ENTRY_WIDTH-1:0]        po_write_data,
    // Raw address accessed indirect memory, so enable self-increment
    input   wire                                po_incr_enable,
    output  reg     [ADDR_WIDTH-1:0]            programmed_offset
);

// ---------------------------------------------------------------------

    initial begin
        programmed_offset = 0;
    end

    // Stages from input to output
    localparam MODULE_PIPE_DEPTH = 2;

    localparam PO_MEM_ADDR_WIDTH = PO_ADDR_WIDTH  + THREAD_COUNT_WIDTH;
    localparam PO_MEM_DEPTH      = PO_ENTRY_COUNT * THREAD_COUNT;

// ---------------------------------------------------------------------
// ---------------------------------------------------------------------
// Stage 0

// ---------------------------------------------------------------------
// Read PO/PI entry based on raw address LSBs and read thread.

    reg [PO_ADDR_WIDTH-1:0]     po_mem_read_addr_base   = 0;
    reg [PO_MEM_ADDR_WIDTH-1:0] po_mem_read_addr        = 0;

    always @(*) begin
        po_mem_read_addr_base   = raw_addr[PO_ADDR_WIDTH-1:0];
        po_mem_read_addr        = {read_thread, po_mem_read_addr_base};
    end

// ---------------------------------------------------------------------

// Pass the read address back to the input as the internal write address for
// self-increment. Make sure it arrives at the same write thread number as the
// past read thread number that read it.

    wire [PO_ADDR_WIDTH-1:0] po_int_write_addr;

    Delay_Line 
    #(
        .DEPTH  (MODULE_PIPE_DEPTH),
        .WIDTH  (PO_ADDR_WIDTH)
    ) 
    INT_WRITE_ADDR
    (
        .clock   (clock),
        .in      (po_mem_read_addr_base),
        .out     (po_int_write_addr)
    );

// Do the same for the self-incremented entry itself, delayed by one less
// cycle since it's generated one cycle later

    reg  [PO_ENTRY_WIDTH-1:0]    new_po_entry       = 0;
    wire [PO_ENTRY_WIDTH-1:0]    po_int_write_data;

    Delay_Line 
    #(
        .DEPTH  (MODULE_PIPE_DEPTH-1),
        .WIDTH  (PO_ENTRY_WIDTH)
    ) 
    INT_WRITE_DATA
    (
        .clock   (clock),
        .in      (new_po_entry),
        .out     (po_int_write_data)
    );

// ---------------------------------------------------------------------

    // External writes (from previous thread instruction updating an entry)
    // have priority over internal writes (from current instruction read
    // causing post-increment), which means be careful not to prevent an
    // internal write to another entry.

    wire                            po_ext_wren;
    wire                            po_int_wren;

    localparam PO_WRITE_SOURCE_COUNT = 2;

    Priority_Arbiter
    #(
        .WORD_WIDTH     (PO_WRITE_SOURCE_COUNT)
    )
    PO_WREN_SELECT
    (
        .requests       ({po_incr_enable, po_wren}),
        .grant          ({po_int_wren,    po_ext_wren})
    );

// ---------------------------------------------------------------------

    // Don't self-increment if the current instruction was Annulled or
    // Cancelled. Don't update an entry if the previous instruction was
    // Annulled or Cancelled.

    reg po_int_wren_masked = 0;
    reg po_ext_wren_masked = 0;
    reg po_mem_wren        = 0;

    always @(*) begin
        po_int_wren_masked  = (po_int_wren == 1'b1) & (IO_Ready_current == 1'b1)  & (Cancel_current == 1'b0);
        po_ext_wren_masked  = (po_ext_wren == 1'b1) & (IO_Ready_previous == 1'b1) & (Cancel_previous == 1'b0);
        po_mem_wren         = (po_int_wren_masked == 1'b1) | (po_ext_wren_masked == 1'b1);
    end

// ---------------------------------------------------------------------

    // Use the arbitrated po_*_wren to select the other write inputs

    wire [PO_ADDR_WIDTH-1:0] po_mem_write_addr_base;

    One_Hot_Mux
    #(
        .WORD_WIDTH     (PO_ADDR_WIDTH),
        .WORD_COUNT     (PO_WRITE_SOURCE_COUNT)
    )
    PO_WRITE_ADDR_SELECT
    (
        .selectors      ({po_int_wren,       po_ext_wren}),
        .in             ({po_int_write_addr, po_write_addr}),
        .out            (po_mem_write_addr_base)
    );

// ----

    reg [PO_MEM_ADDR_WIDTH-1:0] po_mem_write_addr = 0;

    always @(*) begin
        po_mem_write_addr <= {write_thread, po_mem_write_addr_base};
    end

// ----

    wire [PO_ENTRY_WIDTH-1:0] po_mem_write_data;

    One_Hot_Mux
    #(
        .WORD_WIDTH     (PO_ENTRY_WIDTH),
        .WORD_COUNT     (PO_WRITE_SOURCE_COUNT)
    )
    PO_WRITE_DATA_SELECT
    (
        .selectors      ({po_int_wren,       po_ext_wren}),
        .in             ({po_int_write_data, po_write_data}),
        .out            (po_mem_write_data)
    );

// ---------------------------------------------------------------------

    wire    [PO_ENTRY_WIDTH-1:0]    po_mem_read_data;

    RAM_SDP 
    #(
        .WORD_WIDTH     (PO_ENTRY_WIDTH),
        .ADDR_WIDTH     (PO_MEM_ADDR_WIDTH),
        .DEPTH          (PO_MEM_DEPTH),
        .RAMSTYLE       (RAMSTYLE),
        .READ_NEW_DATA  (READ_NEW_DATA),
        // Force init file use to simplify setup
        .USE_INIT_FILE  (1),
        .INIT_FILE      (PO_INIT_FILE)
    )
    PO_MEM
    (
        .clock          (clock),
        .wren           (po_mem_wren),
        .write_addr     (po_mem_write_addr),
        .write_data     (po_mem_write_data),
        .rden           (1'b1),
        .read_addr      (po_mem_read_addr),
        .read_data      (po_mem_read_data)
    );

// ---------------------------------------------------------------------
// ---------------------------------------------------------------------
// Stage 1

// The Post-increment Programmed Offset (po) is a two's-complement signed
// number. The programmed Increment (pi) is in signed-magnitude representation
// for range symmetry.

// The offset is in the LSB position, so by default the increment and sign are
// zero, resulting in a plain pointer without post-increment.  This
// arrangement should avoid overhead when pointer-chasing instead of
// array-walking.

    reg [ADDR_WIDTH-1:0]        po_raw          = 0;
    reg [ADDR_WIDTH-1:0]        po_post_inc     = 0;
    reg                         pi_sign         = 0;
    reg [PO_INCR_WIDTH-2:0]     pi              = 0;

    always @(*) begin
        {pi_sign, pi, po_raw}   = po_mem_read_data;
        po_post_inc             = (pi_sign == 1'b0) ? (po_raw + pi) : (po_raw - pi);
        new_po_entry            = {pi_sign, pi, po_post_inc};
    end

    always @(posedge clock) begin
        programmed_offset <= po_raw;
    end

endmodule

