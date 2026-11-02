// Wrapper de puertos planos para Verilator (las interfaces SV no cruzan
// limpio el límite C++/DPI) -- mismo patrón que
// hw/unittest/core/VX_core_top.sv (A-9), ahora para compute_unit.sv
// (A-14: NUM_CORES=4 núcleos reales + l2_cache.sv compartida + árbitro
// global real). NUM_CORES=4 fijo (no parametrizable: Verilator no genera
// nombres de puerto dinámicamente).
//
// ICACHE_WORD_SIZE/ICACHE_ADDR_WIDTH/ICACHE_TAG_WIDTH y
// TFG_L1_MEM_ADDR_WIDTH/TFG_ARB_MEM_ADDR_WIDTH vienen del mismo cálculo
// que ya usaba VX_core_top.sv -- ver ahí para la justificación completa.

module VX_compute_unit_top import VX_gpu_pkg::*; #(
    parameter TFG_L1_LINE_SIZE      = 16,
    parameter TFG_L1_MEM_TAG_WIDTH  = 8,
    parameter TFG_L2_BANK_SIZE      = 64,
    parameter TFG_L2_NUM_WAYS       = 2,
    parameter TFG_L2_MEM_TAG_WIDTH  = 8,
    parameter TFG_L1_MEM_ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(TFG_L1_LINE_SIZE),
    // El árbitro global (VX_mem_bus_arb, 4 bancos -> 1) ensancha el tag
    // en $clog2(NUM_BANKS) bits -- ver compute_unit.sv.
    parameter TFG_ARB_MEM_TAG_WIDTH = TFG_L2_MEM_TAG_WIDTH + 2
) (
    input wire clk,
    input wire reset,

    input wire start,
    output wire [3:0] busy,

    input wire                          dcr_req_valid,
    input wire                          dcr_req_rw,
    input wire [VX_DCR_ADDR_WIDTH-1:0]  dcr_req_addr,
    input wire [VX_DCR_DATA_WIDTH-1:0]  dcr_req_data,
    output wire                         dcr_rsp_valid,
    output wire [VX_DCR_DATA_WIDTH-1:0] dcr_rsp_data,

    // icache por núcleo (4 instrucciones-memoria mockeadas en C++, mismo
    // contenido de programa en las 4 -- de solo lectura, sin problema de
    // coherencia).
    output wire                          icache0_req_valid,
    output wire [ICACHE_ADDR_WIDTH-1:0]  icache0_req_addr,
    output wire [ICACHE_TAG_WIDTH-1:0]   icache0_req_tag,
    input  wire                          icache0_req_ready,
    input  wire                          icache0_rsp_valid,
    input  wire [ICACHE_WORD_SIZE*8-1:0] icache0_rsp_data,
    input  wire [ICACHE_TAG_WIDTH-1:0]   icache0_rsp_tag,
    output wire                          icache0_rsp_ready,

    output wire                          icache1_req_valid,
    output wire [ICACHE_ADDR_WIDTH-1:0]  icache1_req_addr,
    output wire [ICACHE_TAG_WIDTH-1:0]   icache1_req_tag,
    input  wire                          icache1_req_ready,
    input  wire                          icache1_rsp_valid,
    input  wire [ICACHE_WORD_SIZE*8-1:0] icache1_rsp_data,
    input  wire [ICACHE_TAG_WIDTH-1:0]   icache1_rsp_tag,
    output wire                          icache1_rsp_ready,

    output wire                          icache2_req_valid,
    output wire [ICACHE_ADDR_WIDTH-1:0]  icache2_req_addr,
    output wire [ICACHE_TAG_WIDTH-1:0]   icache2_req_tag,
    input  wire                          icache2_req_ready,
    input  wire                          icache2_rsp_valid,
    input  wire [ICACHE_WORD_SIZE*8-1:0] icache2_rsp_data,
    input  wire [ICACHE_TAG_WIDTH-1:0]   icache2_rsp_tag,
    output wire                          icache2_rsp_ready,

    output wire                          icache3_req_valid,
    output wire [ICACHE_ADDR_WIDTH-1:0]  icache3_req_addr,
    output wire [ICACHE_TAG_WIDTH-1:0]   icache3_req_tag,
    input  wire                          icache3_req_ready,
    input  wire                          icache3_rsp_valid,
    input  wire [ICACHE_WORD_SIZE*8-1:0] icache3_rsp_data,
    input  wire [ICACHE_TAG_WIDTH-1:0]   icache3_rsp_tag,
    output wire                          icache3_rsp_ready,

    // Único puerto hacia "memoria", ya del otro lado del árbitro global.
    output wire                           mem_req_valid,
    output wire                           mem_req_rw,
    output wire [TFG_L1_LINE_SIZE-1:0]    mem_req_byteen,
    output wire [TFG_L1_MEM_ADDR_WIDTH-1:0] mem_req_addr,
    output wire [TFG_L1_LINE_SIZE*8-1:0]  mem_req_data,
    output wire [TFG_ARB_MEM_TAG_WIDTH-1:0] mem_req_tag,
    input  wire                           mem_req_ready,
    input  wire                           mem_rsp_valid,
    input  wire [TFG_L1_LINE_SIZE*8-1:0]  mem_rsp_data,
    input  wire [TFG_ARB_MEM_TAG_WIDTH-1:0] mem_rsp_tag,
    output wire                           mem_rsp_ready,

    output wire [3:0]        dbg_dst_found,
    output wire [3:0]        dbg_dst_dirty,
    output wire [3:0][63:0]  dbg_dst_word0
);
    VX_mem_bus_if #(
        .DATA_SIZE (ICACHE_WORD_SIZE),
        .TAG_WIDTH (ICACHE_TAG_WIDTH)
    ) icache_bus_if [4] ();

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (TFG_ARB_MEM_TAG_WIDTH)
    ) mem_bus_if ();

    // icache: solo lectura en este testbench (el programa de prueba no
    // auto-modifica código) -- mismo patrón que VX_core_top.sv.
    assign icache0_req_valid = icache_bus_if[0].req_valid;
    assign icache0_req_addr  = icache_bus_if[0].req_data.addr;
    assign icache0_req_tag   = icache_bus_if[0].req_data.tag;
    assign icache_bus_if[0].req_ready    = icache0_req_ready;
    assign icache_bus_if[0].rsp_valid    = icache0_rsp_valid;
    assign icache_bus_if[0].rsp_data.data = icache0_rsp_data;
    assign icache_bus_if[0].rsp_data.tag  = icache0_rsp_tag;
    assign icache0_rsp_ready = icache_bus_if[0].rsp_ready;
    `UNUSED_VAR (icache_bus_if[0].req_data.attr)

    assign icache1_req_valid = icache_bus_if[1].req_valid;
    assign icache1_req_addr  = icache_bus_if[1].req_data.addr;
    assign icache1_req_tag   = icache_bus_if[1].req_data.tag;
    assign icache_bus_if[1].req_ready    = icache1_req_ready;
    assign icache_bus_if[1].rsp_valid    = icache1_rsp_valid;
    assign icache_bus_if[1].rsp_data.data = icache1_rsp_data;
    assign icache_bus_if[1].rsp_data.tag  = icache1_rsp_tag;
    assign icache1_rsp_ready = icache_bus_if[1].rsp_ready;
    `UNUSED_VAR (icache_bus_if[1].req_data.attr)

    assign icache2_req_valid = icache_bus_if[2].req_valid;
    assign icache2_req_addr  = icache_bus_if[2].req_data.addr;
    assign icache2_req_tag   = icache_bus_if[2].req_data.tag;
    assign icache_bus_if[2].req_ready    = icache2_req_ready;
    assign icache_bus_if[2].rsp_valid    = icache2_rsp_valid;
    assign icache_bus_if[2].rsp_data.data = icache2_rsp_data;
    assign icache_bus_if[2].rsp_data.tag  = icache2_rsp_tag;
    assign icache2_rsp_ready = icache_bus_if[2].rsp_ready;
    `UNUSED_VAR (icache_bus_if[2].req_data.attr)

    assign icache3_req_valid = icache_bus_if[3].req_valid;
    assign icache3_req_addr  = icache_bus_if[3].req_data.addr;
    assign icache3_req_tag   = icache_bus_if[3].req_data.tag;
    assign icache_bus_if[3].req_ready    = icache3_req_ready;
    assign icache_bus_if[3].rsp_valid    = icache3_rsp_valid;
    assign icache_bus_if[3].rsp_data.data = icache3_rsp_data;
    assign icache_bus_if[3].rsp_data.tag  = icache3_rsp_tag;
    assign icache3_rsp_ready = icache_bus_if[3].rsp_ready;
    `UNUSED_VAR (icache_bus_if[3].req_data.attr)

    assign mem_req_valid  = mem_bus_if.req_valid;
    assign mem_req_rw     = mem_bus_if.req_data.rw;
    assign mem_req_byteen = mem_bus_if.req_data.byteen;
    assign mem_req_addr   = mem_bus_if.req_data.addr;
    assign mem_req_data   = mem_bus_if.req_data.data;
    assign mem_req_tag    = mem_bus_if.req_data.tag;
    assign mem_bus_if.req_ready = mem_req_ready;
    assign mem_bus_if.rsp_valid     = mem_rsp_valid;
    assign mem_bus_if.rsp_data.data = mem_rsp_data;
    assign mem_bus_if.rsp_data.tag  = mem_rsp_tag;
    assign mem_rsp_ready = mem_bus_if.rsp_ready;

    compute_unit #(
        .NUM_CORES             (4),
        .NUM_BANKS             (4),
        .TFG_L1_LINE_SIZE      (TFG_L1_LINE_SIZE),
        .TFG_L1_MEM_TAG_WIDTH  (TFG_L1_MEM_TAG_WIDTH),
        .TFG_L2_BANK_SIZE      (TFG_L2_BANK_SIZE),
        .TFG_L2_NUM_WAYS       (TFG_L2_NUM_WAYS),
        .TFG_L2_MEM_TAG_WIDTH  (TFG_L2_MEM_TAG_WIDTH)
    ) dut (
        .clk            (clk),
        .reset          (reset),
        .start          (start),
        .busy           (busy),
        .dcr_req_valid  (dcr_req_valid),
        .dcr_req_rw     (dcr_req_rw),
        .dcr_req_addr   (dcr_req_addr),
        .dcr_req_data   (dcr_req_data),
        .dcr_rsp_valid  (dcr_rsp_valid),
        .dcr_rsp_data   (dcr_rsp_data),
        .icache_bus_if  (icache_bus_if),
        .mem_bus_if     (mem_bus_if),
        .dbg_dst_found  (dbg_dst_found),
        .dbg_dst_dirty  (dbg_dst_dirty),
        .dbg_dst_word0  (dbg_dst_word0)
    );

endmodule
