// Wrapper de puertos planos para Verilator (las interfaces SV no cruzan
// limpio el límite C++/DPI) -- mismo patrón que
// hw/unittest/l1_cache/VX_l1_cache_top.sv. NUM_CORES=2/NUM_BANKS=2 fijos
// (no parametrizados): con N puertos habría que generar los nombres de
// puerto dinámicamente, lo que Verilator no soporta vía top-level ports
// -- 2 y 2 alcanza para probar lo que pide A-10.6 (bancos distintos en
// paralelo, contención en el mismo banco, miss hacia el árbitro global,
// eviction) sin esa complicación.
//
// LINE_SIZE=8 (no el default de l2_cache.sv) para que el bus de datos
// quepa en un escalar de 64 bits manejable desde main.cpp (igual
// justificación que usa VX_l1_cache_top.sv para su propio LINE_SIZE
// achicado). BANK_SIZE=32, NUM_WAYS=2 -> NUM_SETS=2 por banco.

module VX_l2_cache_top import VX_gpu_pkg::*; #(
    parameter BANK_SIZE  = 32,
    parameter LINE_SIZE  = 8,
    parameter NUM_WAYS   = 2,
    parameter CORE_TAG_WIDTH = 8,
    parameter MEM_TAG_WIDTH  = 8,
    parameter ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(LINE_SIZE)
) (
    input wire clk,
    input wire reset,

    // Core 0 request/response (L1 #0 -> L2)
    input  wire                      core0_req_valid,
    input  wire                      core0_req_rw,
    input  wire [LINE_SIZE-1:0]      core0_req_byteen,
    input  wire [ADDR_WIDTH-1:0]     core0_req_addr,
    input  wire [LINE_SIZE*8-1:0]    core0_req_data,
    input  wire [CORE_TAG_WIDTH-1:0] core0_req_tag,
    output wire                      core0_req_ready,
    output wire                      core0_rsp_valid,
    output wire [LINE_SIZE*8-1:0]    core0_rsp_data,
    output wire [CORE_TAG_WIDTH-1:0] core0_rsp_tag,
    input  wire                      core0_rsp_ready,

    // Core 1 request/response (L1 #1 -> L2)
    input  wire                      core1_req_valid,
    input  wire                      core1_req_rw,
    input  wire [LINE_SIZE-1:0]      core1_req_byteen,
    input  wire [ADDR_WIDTH-1:0]     core1_req_addr,
    input  wire [LINE_SIZE*8-1:0]    core1_req_data,
    input  wire [CORE_TAG_WIDTH-1:0] core1_req_tag,
    output wire                      core1_req_ready,
    output wire                      core1_rsp_valid,
    output wire [LINE_SIZE*8-1:0]    core1_rsp_data,
    output wire [CORE_TAG_WIDTH-1:0] core1_rsp_tag,
    input  wire                      core1_rsp_ready,

    // Banco 0 <-> árbitro global (mock en main.cpp)
    output wire                      mem0_req_valid,
    output wire                      mem0_req_rw,
    output wire [LINE_SIZE-1:0]      mem0_req_byteen,
    output wire [ADDR_WIDTH-1:0]     mem0_req_addr,
    output wire [LINE_SIZE*8-1:0]    mem0_req_data,
    output wire [MEM_TAG_WIDTH-1:0]  mem0_req_tag,
    input  wire                      mem0_req_ready,
    input  wire                      mem0_rsp_valid,
    input  wire [LINE_SIZE*8-1:0]    mem0_rsp_data,
    input  wire [MEM_TAG_WIDTH-1:0]  mem0_rsp_tag,
    output wire                      mem0_rsp_ready,

    // Banco 1 <-> árbitro global (mock en main.cpp)
    output wire                      mem1_req_valid,
    output wire                      mem1_req_rw,
    output wire [LINE_SIZE-1:0]      mem1_req_byteen,
    output wire [ADDR_WIDTH-1:0]     mem1_req_addr,
    output wire [LINE_SIZE*8-1:0]    mem1_req_data,
    output wire [MEM_TAG_WIDTH-1:0]  mem1_req_tag,
    input  wire                      mem1_req_ready,
    input  wire                      mem1_rsp_valid,
    input  wire [LINE_SIZE*8-1:0]    mem1_rsp_data,
    input  wire [MEM_TAG_WIDTH-1:0]  mem1_rsp_tag,
    output wire                      mem1_rsp_ready
);
    VX_mem_bus_if #(
        .DATA_SIZE (LINE_SIZE),
        .TAG_WIDTH (CORE_TAG_WIDTH)
    ) core_bus_if [2] ();

    VX_mem_bus_if #(
        .DATA_SIZE (LINE_SIZE),
        .TAG_WIDTH (MEM_TAG_WIDTH)
    ) mem_bus_if [2] ();

    assign core_bus_if[0].req_valid       = core0_req_valid;
    assign core_bus_if[0].req_data.rw     = core0_req_rw;
    assign core_bus_if[0].req_data.byteen = core0_req_byteen;
    assign core_bus_if[0].req_data.addr   = core0_req_addr;
    assign core_bus_if[0].req_data.data   = core0_req_data;
    assign core_bus_if[0].req_data.attr   = '0;
    assign core_bus_if[0].req_data.tag    = core0_req_tag;
    assign core0_req_ready                = core_bus_if[0].req_ready;
    assign core0_rsp_valid                = core_bus_if[0].rsp_valid;
    assign core0_rsp_data                 = core_bus_if[0].rsp_data.data;
    assign core0_rsp_tag                  = core_bus_if[0].rsp_data.tag;
    assign core_bus_if[0].rsp_ready       = core0_rsp_ready;

    assign core_bus_if[1].req_valid       = core1_req_valid;
    assign core_bus_if[1].req_data.rw     = core1_req_rw;
    assign core_bus_if[1].req_data.byteen = core1_req_byteen;
    assign core_bus_if[1].req_data.addr   = core1_req_addr;
    assign core_bus_if[1].req_data.data   = core1_req_data;
    assign core_bus_if[1].req_data.attr   = '0;
    assign core_bus_if[1].req_data.tag    = core1_req_tag;
    assign core1_req_ready                = core_bus_if[1].req_ready;
    assign core1_rsp_valid                = core_bus_if[1].rsp_valid;
    assign core1_rsp_data                 = core_bus_if[1].rsp_data.data;
    assign core1_rsp_tag                  = core_bus_if[1].rsp_data.tag;
    assign core_bus_if[1].rsp_ready       = core1_rsp_ready;

    assign mem0_req_valid                 = mem_bus_if[0].req_valid;
    assign mem0_req_rw                    = mem_bus_if[0].req_data.rw;
    assign mem0_req_byteen                = mem_bus_if[0].req_data.byteen;
    assign mem0_req_addr                  = mem_bus_if[0].req_data.addr;
    assign mem0_req_data                  = mem_bus_if[0].req_data.data;
    assign mem0_req_tag                   = mem_bus_if[0].req_data.tag;
    assign mem_bus_if[0].req_ready        = mem0_req_ready;
    assign mem_bus_if[0].rsp_valid        = mem0_rsp_valid;
    assign mem_bus_if[0].rsp_data.data    = mem0_rsp_data;
    assign mem_bus_if[0].rsp_data.tag     = mem0_rsp_tag;
    assign mem0_rsp_ready                 = mem_bus_if[0].rsp_ready;

    assign mem1_req_valid                 = mem_bus_if[1].req_valid;
    assign mem1_req_rw                    = mem_bus_if[1].req_data.rw;
    assign mem1_req_byteen                = mem_bus_if[1].req_data.byteen;
    assign mem1_req_addr                  = mem_bus_if[1].req_data.addr;
    assign mem1_req_data                  = mem_bus_if[1].req_data.data;
    assign mem1_req_tag                   = mem_bus_if[1].req_data.tag;
    assign mem_bus_if[1].req_ready        = mem1_req_ready;
    assign mem_bus_if[1].rsp_valid        = mem1_rsp_valid;
    assign mem_bus_if[1].rsp_data.data    = mem1_rsp_data;
    assign mem_bus_if[1].rsp_data.tag     = mem1_rsp_tag;
    assign mem1_rsp_ready                 = mem_bus_if[1].rsp_ready;

    l2_cache #(
        .NUM_CORES      (2),
        .NUM_BANKS      (2),
        .BANK_SIZE      (BANK_SIZE),
        .NUM_WAYS       (NUM_WAYS),
        .LINE_SIZE      (LINE_SIZE),
        .CORE_TAG_WIDTH (CORE_TAG_WIDTH),
        .MEM_TAG_WIDTH  (MEM_TAG_WIDTH)
    ) dut (
        .clk         (clk),
        .reset       (reset),
        .core_bus_if (core_bus_if),
        .mem_bus_if  (mem_bus_if)
    );

endmodule
