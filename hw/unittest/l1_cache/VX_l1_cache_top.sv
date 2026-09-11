// Wrapper de puertos planos para Verilator (las interfaces SV no cruzan
// limpio el límite C++/DPI). Instancia l1_cache.sv y expone cada señal de
// VX_mem_bus_if / VX_snoop_bus_if como wire individual, mismo patrón que
// hw/unittest/cache/VX_cache_top.sv usa para VX_cache_cluster.

module VX_l1_cache_top import VX_gpu_pkg::*; #(
    parameter CACHE_SIZE     = 4096,
    parameter LINE_SIZE      = 64,
    parameter NUM_WAYS       = 4,
    parameter WORD_SIZE      = 4,
    parameter CORE_TAG_WIDTH = 8,
    parameter MEM_TAG_WIDTH  = 8,
    parameter CORE_ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(WORD_SIZE),
    parameter MEM_ADDR_WIDTH  = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(LINE_SIZE)
) (
    input wire clk,
    input wire reset,

    // Core request
    input  wire                        core_req_valid,
    input  wire                        core_req_rw,
    input  wire [WORD_SIZE-1:0]        core_req_byteen,
    input  wire [CORE_ADDR_WIDTH-1:0]  core_req_addr,
    input  wire [WORD_SIZE*8-1:0]      core_req_data,
    input  wire [CORE_TAG_WIDTH-1:0]   core_req_tag,
    output wire                        core_req_ready,

    // Core response
    output wire                        core_rsp_valid,
    output wire [WORD_SIZE*8-1:0]      core_rsp_data,
    output wire [CORE_TAG_WIDTH-1:0]   core_rsp_tag,
    input  wire                        core_rsp_ready,

    // Memory (L2-facing) request
    output wire                        mem_req_valid,
    output wire                        mem_req_rw,
    output wire [LINE_SIZE-1:0]        mem_req_byteen,
    output wire [MEM_ADDR_WIDTH-1:0]   mem_req_addr,
    output wire [LINE_SIZE*8-1:0]      mem_req_data,
    output wire [MEM_TAG_WIDTH-1:0]    mem_req_tag,
    input  wire                        mem_req_ready,

    // Memory (L2-facing) response
    input  wire                        mem_rsp_valid,
    input  wire [LINE_SIZE*8-1:0]      mem_rsp_data,
    input  wire [MEM_TAG_WIDTH-1:0]    mem_rsp_tag,
    output wire                        mem_rsp_ready,

    // Snoop bus (sin otro L1 real en el testbench: se ata en reposo)
    output wire                        snoop_valid,
    output wire [MEM_ADDR_WIDTH-1:0]   snoop_addr,
    output wire                        snoop_rw,
    input  wire                        snoop_ready,
    input  wire                        snoop_hit,
    input  wire [1:0]                  snoop_state,
    input  wire                        snoop_dirty,
    input  wire [LINE_SIZE*8-1:0]      snoop_data
);
    VX_mem_bus_if #(
        .DATA_SIZE (WORD_SIZE),
        .TAG_WIDTH (CORE_TAG_WIDTH)
    ) core_bus_if();

    VX_mem_bus_if #(
        .DATA_SIZE (LINE_SIZE),
        .TAG_WIDTH (MEM_TAG_WIDTH)
    ) mem_bus_if();

    VX_snoop_bus_if #(
        .ADDR_WIDTH (MEM_ADDR_WIDTH),
        .LINE_SIZE  (LINE_SIZE)
    ) snoop_bus_if();

    assign core_bus_if.req_valid       = core_req_valid;
    assign core_bus_if.req_data.rw     = core_req_rw;
    assign core_bus_if.req_data.byteen = core_req_byteen;
    assign core_bus_if.req_data.addr   = core_req_addr;
    assign core_bus_if.req_data.data   = core_req_data;
    assign core_bus_if.req_data.attr   = '0;
    assign core_bus_if.req_data.tag    = core_req_tag;
    assign core_req_ready              = core_bus_if.req_ready;

    assign core_rsp_valid              = core_bus_if.rsp_valid;
    assign core_rsp_data               = core_bus_if.rsp_data.data;
    assign core_rsp_tag                = core_bus_if.rsp_data.tag;
    assign core_bus_if.rsp_ready       = core_rsp_ready;

    assign mem_req_valid               = mem_bus_if.req_valid;
    assign mem_req_rw                  = mem_bus_if.req_data.rw;
    assign mem_req_byteen              = mem_bus_if.req_data.byteen;
    assign mem_req_addr                = mem_bus_if.req_data.addr;
    assign mem_req_data                = mem_bus_if.req_data.data;
    assign mem_req_tag                 = mem_bus_if.req_data.tag;
    assign mem_bus_if.req_ready        = mem_req_ready;

    assign mem_bus_if.rsp_valid        = mem_rsp_valid;
    assign mem_bus_if.rsp_data.data    = mem_rsp_data;
    assign mem_bus_if.rsp_data.tag     = mem_rsp_tag;
    assign mem_rsp_ready               = mem_bus_if.rsp_ready;

    assign snoop_valid                 = snoop_bus_if.snoop_valid;
    assign snoop_addr                  = snoop_bus_if.snoop_addr;
    assign snoop_rw                    = snoop_bus_if.snoop_rw;
    assign snoop_bus_if.snoop_ready    = snoop_ready;
    assign snoop_bus_if.snoop_hit      = snoop_hit;
    assign snoop_bus_if.snoop_state    = snoop_state;
    assign snoop_bus_if.snoop_dirty    = snoop_dirty;
    assign snoop_bus_if.snoop_data     = snoop_data;

    l1_cache #(
        .CACHE_SIZE     (CACHE_SIZE),
        .LINE_SIZE      (LINE_SIZE),
        .NUM_WAYS       (NUM_WAYS),
        .WORD_SIZE      (WORD_SIZE),
        .CORE_TAG_WIDTH (CORE_TAG_WIDTH),
        .MEM_TAG_WIDTH  (MEM_TAG_WIDTH)
    ) dut (
        .clk          (clk),
        .reset        (reset),
        .core_bus_if  (core_bus_if),
        .mem_bus_if   (mem_bus_if),
        .snoop_bus_if (snoop_bus_if)
    );

endmodule
