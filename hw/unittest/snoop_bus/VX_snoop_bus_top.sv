// A-7: wrapper de puertos planos para Verilator (mismo patrón que
// hw/unittest/l1_cache/VX_l1_cache_top.sv), pero con DOS l1_cache reales
// conectados a un snoop_bus real -- para probar arbitraje y coherencia
// end-to-end, no solo el lado snooper de un L1 aislado.
//
// Mismos parámetros achicados que el testbench de l1_cache (2 palabras
// por línea, 2 vías, 2 sets) para poder reusar los mismos escenarios de
// direcciones desde main.cpp.

module VX_snoop_bus_top import VX_gpu_pkg::*; #(
    parameter CACHE_SIZE     = 32,
    parameter LINE_SIZE      = 8,
    parameter NUM_WAYS       = 2,
    parameter WORD_SIZE      = 4,
    parameter CORE_TAG_WIDTH = 8,
    parameter MEM_TAG_WIDTH  = 8,
    parameter NUM_L1          = 2,
    parameter CORE_ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(WORD_SIZE),
    parameter MEM_ADDR_WIDTH  = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(LINE_SIZE)
) (
    input wire clk,
    input wire reset,

    // ---- L1 #0 ----
    input  wire                        core0_req_valid,
    input  wire                        core0_req_rw,
    input  wire [WORD_SIZE-1:0]        core0_req_byteen,
    input  wire [CORE_ADDR_WIDTH-1:0]  core0_req_addr,
    input  wire [WORD_SIZE*8-1:0]      core0_req_data,
    input  wire [CORE_TAG_WIDTH-1:0]   core0_req_tag,
    output wire                        core0_req_ready,
    output wire                        core0_rsp_valid,
    output wire [WORD_SIZE*8-1:0]      core0_rsp_data,
    output wire [CORE_TAG_WIDTH-1:0]   core0_rsp_tag,
    input  wire                        core0_rsp_ready,

    output wire                        mem0_req_valid,
    output wire                        mem0_req_rw,
    output wire [LINE_SIZE-1:0]        mem0_req_byteen,
    output wire [MEM_ADDR_WIDTH-1:0]   mem0_req_addr,
    output wire [LINE_SIZE*8-1:0]      mem0_req_data,
    output wire [MEM_TAG_WIDTH-1:0]    mem0_req_tag,
    input  wire                        mem0_req_ready,
    input  wire                        mem0_rsp_valid,
    input  wire [LINE_SIZE*8-1:0]      mem0_rsp_data,
    input  wire [MEM_TAG_WIDTH-1:0]    mem0_rsp_tag,
    output wire                        mem0_rsp_ready,

    // ---- L1 #1 (mismo shape) ----
    input  wire                        core1_req_valid,
    input  wire                        core1_req_rw,
    input  wire [WORD_SIZE-1:0]        core1_req_byteen,
    input  wire [CORE_ADDR_WIDTH-1:0]  core1_req_addr,
    input  wire [WORD_SIZE*8-1:0]      core1_req_data,
    input  wire [CORE_TAG_WIDTH-1:0]   core1_req_tag,
    output wire                        core1_req_ready,
    output wire                        core1_rsp_valid,
    output wire [WORD_SIZE*8-1:0]      core1_rsp_data,
    output wire [CORE_TAG_WIDTH-1:0]   core1_rsp_tag,
    input  wire                        core1_rsp_ready,

    output wire                        mem1_req_valid,
    output wire                        mem1_req_rw,
    output wire [LINE_SIZE-1:0]        mem1_req_byteen,
    output wire [MEM_ADDR_WIDTH-1:0]   mem1_req_addr,
    output wire [LINE_SIZE*8-1:0]      mem1_req_data,
    output wire [MEM_TAG_WIDTH-1:0]    mem1_req_tag,
    input  wire                        mem1_req_ready,
    input  wire                        mem1_rsp_valid,
    input  wire [LINE_SIZE*8-1:0]      mem1_rsp_data,
    input  wire [MEM_TAG_WIDTH-1:0]    mem1_rsp_tag,
    output wire                        mem1_rsp_ready,

    // Debug (solo test, no sintetizable): estado MESI/valid del set 0 de
    // cada L1 -- mismo criterio que hw/unittest/l1_cache/VX_l1_cache_top.sv.
    output wire [1:0] dbg0_mesi_way0,
    output wire       dbg0_valid_way0,
    output wire [1:0] dbg0_mesi_way1,
    output wire       dbg0_valid_way1,
    output wire [1:0] dbg1_mesi_way0,
    output wire       dbg1_valid_way0,
    output wire [1:0] dbg1_mesi_way1,
    output wire       dbg1_valid_way1
);
    VX_mem_bus_if #(.DATA_SIZE(WORD_SIZE), .TAG_WIDTH(CORE_TAG_WIDTH)) core0_bus_if();
    VX_mem_bus_if #(.DATA_SIZE(LINE_SIZE), .TAG_WIDTH(MEM_TAG_WIDTH)) mem0_bus_if();
    VX_mem_bus_if #(.DATA_SIZE(WORD_SIZE), .TAG_WIDTH(CORE_TAG_WIDTH)) core1_bus_if();
    VX_mem_bus_if #(.DATA_SIZE(LINE_SIZE), .TAG_WIDTH(MEM_TAG_WIDTH)) mem1_bus_if();

    // snp_if[i]: puerto .snooper de l1_cache[i] (recibe broadcast del bus).
    // mst_if[i]: puerto .master  de l1_cache[i] (su propia consulta).
    VX_snoop_bus_if #(.ADDR_WIDTH(MEM_ADDR_WIDTH), .LINE_SIZE(LINE_SIZE)) snp_if [NUM_L1] ();
    VX_snoop_bus_if #(.ADDR_WIDTH(MEM_ADDR_WIDTH), .LINE_SIZE(LINE_SIZE)) mst_if [NUM_L1] ();

    // ---- L1 #0 <-> puertos planos ----
    assign core0_bus_if.req_valid       = core0_req_valid;
    assign core0_bus_if.req_data.rw     = core0_req_rw;
    assign core0_bus_if.req_data.byteen = core0_req_byteen;
    assign core0_bus_if.req_data.addr   = core0_req_addr;
    assign core0_bus_if.req_data.data   = core0_req_data;
    assign core0_bus_if.req_data.attr   = '0;
    assign core0_bus_if.req_data.tag    = core0_req_tag;
    assign core0_req_ready              = core0_bus_if.req_ready;
    assign core0_rsp_valid              = core0_bus_if.rsp_valid;
    assign core0_rsp_data               = core0_bus_if.rsp_data.data;
    assign core0_rsp_tag                = core0_bus_if.rsp_data.tag;
    assign core0_bus_if.rsp_ready       = core0_rsp_ready;

    assign mem0_req_valid               = mem0_bus_if.req_valid;
    assign mem0_req_rw                  = mem0_bus_if.req_data.rw;
    assign mem0_req_byteen              = mem0_bus_if.req_data.byteen;
    assign mem0_req_addr                = mem0_bus_if.req_data.addr;
    assign mem0_req_data                = mem0_bus_if.req_data.data;
    assign mem0_req_tag                 = mem0_bus_if.req_data.tag;
    assign mem0_bus_if.req_ready        = mem0_req_ready;
    assign mem0_bus_if.rsp_valid        = mem0_rsp_valid;
    assign mem0_bus_if.rsp_data.data    = mem0_rsp_data;
    assign mem0_bus_if.rsp_data.tag     = mem0_rsp_tag;
    assign mem0_rsp_ready               = mem0_bus_if.rsp_ready;

    // ---- L1 #1 <-> puertos planos ----
    assign core1_bus_if.req_valid       = core1_req_valid;
    assign core1_bus_if.req_data.rw     = core1_req_rw;
    assign core1_bus_if.req_data.byteen = core1_req_byteen;
    assign core1_bus_if.req_data.addr   = core1_req_addr;
    assign core1_bus_if.req_data.data   = core1_req_data;
    assign core1_bus_if.req_data.attr   = '0;
    assign core1_bus_if.req_data.tag    = core1_req_tag;
    assign core1_req_ready              = core1_bus_if.req_ready;
    assign core1_rsp_valid              = core1_bus_if.rsp_valid;
    assign core1_rsp_data               = core1_bus_if.rsp_data.data;
    assign core1_rsp_tag                = core1_bus_if.rsp_data.tag;
    assign core1_bus_if.rsp_ready       = core1_rsp_ready;

    assign mem1_req_valid               = mem1_bus_if.req_valid;
    assign mem1_req_rw                  = mem1_bus_if.req_data.rw;
    assign mem1_req_byteen              = mem1_bus_if.req_data.byteen;
    assign mem1_req_addr                = mem1_bus_if.req_data.addr;
    assign mem1_req_data                = mem1_bus_if.req_data.data;
    assign mem1_req_tag                 = mem1_bus_if.req_data.tag;
    assign mem1_bus_if.req_ready        = mem1_req_ready;
    assign mem1_bus_if.rsp_valid        = mem1_rsp_valid;
    assign mem1_bus_if.rsp_data.data    = mem1_rsp_data;
    assign mem1_bus_if.rsp_data.tag     = mem1_rsp_tag;
    assign mem1_rsp_ready               = mem1_bus_if.rsp_ready;

    l1_cache #(
        .CACHE_SIZE     (CACHE_SIZE),
        .LINE_SIZE      (LINE_SIZE),
        .NUM_WAYS       (NUM_WAYS),
        .WORD_SIZE      (WORD_SIZE),
        .CORE_TAG_WIDTH (CORE_TAG_WIDTH),
        .MEM_TAG_WIDTH  (MEM_TAG_WIDTH)
    ) dut0 (
        .clk          (clk),
        .reset        (reset),
        .core_bus_if  (core0_bus_if),
        .mem_bus_if   (mem0_bus_if),
        .snoop_bus_if (snp_if[0]),
        .snoop_mst_if (mst_if[0])
    );

    l1_cache #(
        .CACHE_SIZE     (CACHE_SIZE),
        .LINE_SIZE      (LINE_SIZE),
        .NUM_WAYS       (NUM_WAYS),
        .WORD_SIZE      (WORD_SIZE),
        .CORE_TAG_WIDTH (CORE_TAG_WIDTH),
        .MEM_TAG_WIDTH  (MEM_TAG_WIDTH)
    ) dut1 (
        .clk          (clk),
        .reset        (reset),
        .core_bus_if  (core1_bus_if),
        .mem_bus_if   (mem1_bus_if),
        .snoop_bus_if (snp_if[1]),
        .snoop_mst_if (mst_if[1])
    );

    snoop_bus #(
        .NUM_L1     (NUM_L1),
        .ADDR_WIDTH (MEM_ADDR_WIDTH),
        .LINE_SIZE  (LINE_SIZE)
    ) bus (
        .clk    (clk),
        .reset  (reset),
        .req_if (mst_if),  // consulta propia de cada L1 -> el bus la recibe
        .rsp_if (snp_if)   // broadcast del bus -> puerto snooper de cada L1
    );

    assign dbg0_mesi_way0  = dut0.tag_array[0][0].mesi;
    assign dbg0_valid_way0 = dut0.tag_array[0][0].valid;
    assign dbg0_mesi_way1  = dut0.tag_array[0][1].mesi;
    assign dbg0_valid_way1 = dut0.tag_array[0][1].valid;
    assign dbg1_mesi_way0  = dut1.tag_array[0][0].mesi;
    assign dbg1_valid_way0 = dut1.tag_array[0][0].valid;
    assign dbg1_mesi_way1  = dut1.tag_array[0][1].mesi;
    assign dbg1_valid_way1 = dut1.tag_array[0][1].valid;

endmodule
