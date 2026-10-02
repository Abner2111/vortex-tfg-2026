// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

`ifdef VX_CFG_EXT_F_ENABLE
`include "VX_fpu_define.vh"
`endif

module VX_core_top import VX_gpu_pkg::*;
`ifdef VX_CFG_EXT_DXA_ENABLE
    import VX_dxa_pkg::*;
`endif
#(
    parameter CORE_ID = 0,

    // A-9: l1_cache.sv (TFG) se empalma en el camino de datos, entre
    // VX_core y "memoria" -- estos parametros describen ESE puerto (el
    // lado mem_bus_if de nuestra L1), no el dcache_bus_if original de
    // VX_core (que sigue existiendo puertas adentro, sin cambios, como
    // el lado core_bus_if de nuestra L1). LINE_SIZE=16 (no el default de
    // l1_cache.sv, 64, ni el real de VX_CFG_DCACHE_LINE_SIZE) porque acá
    // hace falta que quepa en un tipo escalar de Verilator para el mock
    // de memoria en C++ -- con WORD_SIZE=DCACHE_WORD_SIZE=8 (fijo, no lo
    // elegimos nosotros) el mínimo válido es 16 (2 palabras por línea;
    // LINE_SIZE==WORD_SIZE colapsaría OFFSET_BITS a 0, inválido en
    // l1_cache.sv) -- ya da 128 bits, más ancho que un QData de 64 bits,
    // así que main.cpp igual tiene que manejarlo como palabras de 32 bits
    // (VlWide), no como un escalar simple.
    parameter TFG_L1_LINE_SIZE      = 16,
    parameter TFG_L1_MEM_TAG_WIDTH  = 8,
    parameter TFG_L1_MEM_ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(TFG_L1_LINE_SIZE)
) (
    // Clock
    input wire                              clk,
    input wire                              reset,

    // A-9: arranque de kernel via VX_kmu (ver más abajo) -- pulsar un
    // ciclo después de programar los DCR de VX_DCR_KMU_*.
    input wire                              start,

    // Puerto de memoria de nuestra L1 (después del splice) -- un solo
    // canal, no DCACHE_NUM_REQS: ver el chequeo de elaboración más abajo
    // (g_check_num_reqs) que exige DCACHE_NUM_REQS==1 para esta config.
    output wire                              dcache_req_valid,
    output wire                              dcache_req_rw,
    output wire [TFG_L1_LINE_SIZE-1:0]       dcache_req_byteen,
    output wire [TFG_L1_MEM_ADDR_WIDTH-1:0]  dcache_req_addr,
    output wire [MEM_ATTR_WIDTH-1:0]         dcache_req_attr,
    output wire [TFG_L1_LINE_SIZE*8-1:0]     dcache_req_data,
    output wire [TFG_L1_MEM_TAG_WIDTH-1:0]   dcache_req_tag,
    input  wire                              dcache_req_ready,

    input wire                               dcache_rsp_valid,
    input wire  [TFG_L1_LINE_SIZE*8-1:0]     dcache_rsp_data,
    input wire  [TFG_L1_MEM_TAG_WIDTH-1:0]   dcache_rsp_tag,
    output wire                              dcache_rsp_ready,

    output wire                             icache_req_valid,
    output wire                             icache_req_rw,
    output wire [ICACHE_WORD_SIZE-1:0]      icache_req_byteen,
    output wire [ICACHE_ADDR_WIDTH-1:0]     icache_req_addr,
    output wire [ICACHE_WORD_SIZE*8-1:0]    icache_req_data,
    output wire [ICACHE_TAG_WIDTH-1:0]      icache_req_tag,
    input  wire                             icache_req_ready,

    input wire                              icache_rsp_valid,
    input wire  [ICACHE_WORD_SIZE*8-1:0]    icache_rsp_data,
    input wire  [ICACHE_TAG_WIDTH-1:0]      icache_rsp_tag,
    output wire                             icache_rsp_ready,

    output wire                             gbar_req_valid,
    output wire [NB_WIDTH-1:0]              gbar_req_id,
    output wire [NC_WIDTH-1:0]              gbar_req_size_m1,
    output wire [NC_WIDTH-1:0]              gbar_req_core_id,
    input wire                              gbar_req_ready,
    input wire                              gbar_rsp_valid,
    input wire [NB_WIDTH-1:0]               gbar_rsp_id,
    output wire                             gbar_rsp_ready,

    input wire                              dcr_req_valid,
    input wire                              dcr_req_rw,
    input wire [VX_DCR_ADDR_WIDTH-1:0]      dcr_req_addr,
    input wire [VX_DCR_DATA_WIDTH-1:0]      dcr_req_data,

    output wire                             dcr_rsp_valid,
    output wire [VX_DCR_DATA_WIDTH-1:0]     dcr_rsp_data,

    // Status
    output wire                             busy,

    // TEMP DEBUG (A-9): estado interno del scheduler, para diagnosticar
    // por que el store nunca llega a dcache_bus_if.
    output wire [`VX_CFG_NUM_WARPS-1:0]     dbg_active_warps,
    output wire [`VX_CFG_NUM_WARPS-1:0]     dbg_stalled_warps,
    output wire [PC_BITS-1:0]               dbg_warp_pc0,
    output wire                             dbg_lsu_execute_valid,
    output wire                             dbg_lsu_mem_req_valid,
    output wire                             dbg_lsu_is_store,
    output wire                             dbg_lsu_no_rsp_buf_ready
);

    VX_gbar_bus_if gbar_bus_if();
    assign gbar_req_valid           = gbar_bus_if.req_valid;
    assign gbar_req_id              = gbar_bus_if.req_data.id;
    assign gbar_req_size_m1         = gbar_bus_if.req_data.size_m1;
    assign gbar_req_core_id         = gbar_bus_if.req_data.core_id;
    assign gbar_bus_if.req_ready    = gbar_req_ready;
    assign gbar_bus_if.rsp_valid    = gbar_rsp_valid;
    assign gbar_bus_if.rsp_data.id  = gbar_rsp_id;
    assign gbar_rsp_ready = gbar_bus_if.rsp_ready;

`ifdef VX_CFG_EXT_DXA_ENABLE
    VX_dxa_req_bus_if dxa_req_bus_if();
    VX_mem_bus_if #(
        .DATA_SIZE   (DXA_LMEM_WORD_SIZE),
        .TAG_WIDTH   (UUID_WIDTH+1),
        .ATTR_WIDTH (DXA_LMEM_ATTR_W),
        .ADDR_WIDTH  (DXA_LMEM_ADDR_W)
    ) dxa_lmem_bus_if();

    // VX_core is master on dxa_req_bus_if; tie off the slave side here.
    assign dxa_req_bus_if.req_ready = 1'b1;

    assign dxa_lmem_bus_if.req_valid = 1'b0;
    assign dxa_lmem_bus_if.req_data  = '0;
    assign dxa_lmem_bus_if.rsp_ready = 1'b1;
`endif

    // Graphics cluster-bus tie-offs. VX_core exposes these interfaces to the
    // cluster; the standalone DUT sinks the master directions and drives the
    // slave/response directions idle.
`ifdef VX_CFG_EXT_TEX_ENABLE
    VX_tex_bus_if #(
        .NUM_LANES (`VX_CFG_NUM_SFU_LANES),
        .TAG_WIDTH (TEX_REQ_TAG_WIDTH)
    ) tex_bus_if();
    assign tex_bus_if.req_ready = 1'b1;
    assign tex_bus_if.rsp_valid = 1'b0;
    assign tex_bus_if.rsp_data  = '0;
`endif

    // OM and RASTER have no core buses: a fragment export is an ordinary
    // store into the aperture, and a fragment wave arrives as a kernel launch.

`ifdef VX_CFG_EXT_RTU_ENABLE
    VX_rtu_bus_if #(
        .NUM_LANES (`VX_CFG_NUM_SFU_LANES),
        .TAG_WIDTH (RTU_REQ_TAG_WIDTH)
    ) rtu_bus_if();
    assign rtu_bus_if.arm_ready = 1'b1;
    assign rtu_bus_if.req_ready = 1'b1;
    assign rtu_bus_if.win_valid = 1'b0;
    assign rtu_bus_if.win_data  = '0;
`endif

`ifdef EXT_GFX_ANY_ENABLE
    VX_dcr_flush_if cluster_flush_if();
    assign cluster_flush_if.done = 1'b1;
`endif

    // A-9: VX_kmu real (no atado en reposo) -- es lo único que puede
    // arrancar un warp (programa PC inicial / grid / block via los DCR
    // VX_DCR_KMU_*, ver hw/unittest/kmu/main.cpp para la secuencia
    // exacta). dcr_req_* se comparte tal cual con dcr_bus_if de VX_core
    // más abajo -- cada consumidor filtra su propio rango de direcciones,
    // mismo patrón que el sistema real (ver VX_socket.sv: VX_kmu y
    // VX_core cuelgan del mismo bus de DCR).
    VX_kmu_bus_if kmu_bus_if();
    wire kmu_busy;
    `UNUSED_VAR (kmu_busy)

    VX_kmu #(
        .INSTANCE_ID (`SFORMATF(("kmu")))
    ) kmu (
        .clk           (clk),
        .reset         (reset),
        .dcr_req_valid (dcr_req_valid),
        .dcr_req_rw    (dcr_req_rw),
        .dcr_req_addr  (dcr_req_addr),
        .dcr_req_data  (dcr_req_data),
        .start         (start),
        .busy          (kmu_busy),
        .kmu_bus_if    (kmu_bus_if)
    );

    VX_dcr_bus_if dcr_bus_if();

    assign dcr_bus_if.req_valid = dcr_req_valid;
    assign dcr_bus_if.req_data  = '{rw: dcr_req_rw, addr: dcr_req_addr, data: dcr_req_data};

    assign dcr_rsp_valid = dcr_bus_if.rsp_valid;
    assign dcr_rsp_data  = dcr_bus_if.rsp_data.data;

    // l1_cache.sv es de una sola instancia (un tag/data array) -- con más
    // de un canal dcache habría que compartir uno solo entre todos para
    // no terminar con copias divergentes de la misma línea sin
    // coherencia entre canales (el snoop_bus.sv de A-7 resuelve
    // coherencia entre CORES, no entre canales del mismo core). Falla
    // fuerte en vez de generar hardware silenciosamente incorrecto si
    // esta config cambia (p.ej. subir NUM_THREADS) y deja de valer.
    if (DCACHE_NUM_REQS != 1) begin : g_check_num_reqs
        initial $fatal(1, "VX_core_top (A-9): l1_cache.sv splice necesita DCACHE_NUM_REQS==1 (dio %0d) -- ver comentario junto a este chequeo", DCACHE_NUM_REQS);
    end

    VX_mem_bus_if #(
        .DATA_SIZE (DCACHE_WORD_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) dcache_bus_if[DCACHE_NUM_REQS]();

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (TFG_L1_MEM_TAG_WIDTH)
    ) l1_mem_bus_if();

    VX_snoop_bus_if #(
        .ADDR_WIDTH (TFG_L1_MEM_ADDR_WIDTH),
        .LINE_SIZE  (TFG_L1_LINE_SIZE)
    ) l1_snoop_bus_if();

    VX_snoop_bus_if #(
        .ADDR_WIDTH (TFG_L1_MEM_ADDR_WIDTH),
        .LINE_SIZE  (TFG_L1_LINE_SIZE)
    ) l1_snoop_mst_if();

    // Un solo VX_core en este testbench -- no hay ningún otro L1 posible,
    // así que se ata directo acá (no hace falta que main.cpp lo maneje,
    // a diferencia de hw/unittest/l1_cache donde sí podía haber "otro
    // L1" real del otro lado). El snooper nunca ve una consulta real; la
    // consulta propia siempre resuelve "nadie más la tiene".
    assign l1_snoop_bus_if.snoop_valid  = 1'b0;
    assign l1_snoop_bus_if.snoop_addr   = '0;
    assign l1_snoop_bus_if.snoop_rw     = 1'b0;

    assign l1_snoop_mst_if.snoop_ready  = 1'b1;
    assign l1_snoop_mst_if.snoop_hit    = 1'b0;
    assign l1_snoop_mst_if.snoop_state  = 2'b00;
    assign l1_snoop_mst_if.snoop_dirty  = 1'b0;
    assign l1_snoop_mst_if.snoop_data   = '0;

    l1_cache #(
        .CACHE_SIZE     (`VX_CFG_DCACHE_SIZE),
        .LINE_SIZE      (TFG_L1_LINE_SIZE),
        .NUM_WAYS       (`VX_CFG_DCACHE_NUM_WAYS),
        .WORD_SIZE      (DCACHE_WORD_SIZE),
        .CORE_TAG_WIDTH (DCACHE_TAG_WIDTH),
        .MEM_TAG_WIDTH  (TFG_L1_MEM_TAG_WIDTH)
    ) tfg_l1 (
        .clk          (clk),
        .reset        (reset),
        .core_bus_if  (dcache_bus_if[0]),
        .mem_bus_if   (l1_mem_bus_if),
        .snoop_bus_if (l1_snoop_bus_if),
        .snoop_mst_if (l1_snoop_mst_if)
    );

    assign dcache_req_valid  = l1_mem_bus_if.req_valid;
    assign dcache_req_rw     = l1_mem_bus_if.req_data.rw;
    assign dcache_req_byteen = l1_mem_bus_if.req_data.byteen;
    assign dcache_req_addr   = l1_mem_bus_if.req_data.addr;
    assign dcache_req_attr   = l1_mem_bus_if.req_data.attr;
    assign dcache_req_data   = l1_mem_bus_if.req_data.data;
    assign dcache_req_tag    = l1_mem_bus_if.req_data.tag;
    assign l1_mem_bus_if.req_ready = dcache_req_ready;

    assign l1_mem_bus_if.rsp_valid     = dcache_rsp_valid;
    assign l1_mem_bus_if.rsp_data.tag  = dcache_rsp_tag;
    assign l1_mem_bus_if.rsp_data.data = dcache_rsp_data;
    assign dcache_rsp_ready = l1_mem_bus_if.rsp_ready;

    VX_mem_bus_if #(
        .DATA_SIZE (ICACHE_WORD_SIZE),
        .TAG_WIDTH (ICACHE_TAG_WIDTH)
    ) icache_bus_if();

    assign icache_req_valid = icache_bus_if.req_valid;
    assign icache_req_rw = icache_bus_if.req_data.rw;
    assign icache_req_byteen = icache_bus_if.req_data.byteen;
    assign icache_req_addr = icache_bus_if.req_data.addr;
    assign icache_req_data = icache_bus_if.req_data.data;
    assign icache_req_tag = icache_bus_if.req_data.tag;
    assign icache_bus_if.req_ready = icache_req_ready;
    `UNUSED_VAR (icache_bus_if.req_data.attr)

    assign icache_bus_if.rsp_valid = icache_rsp_valid;
    assign icache_bus_if.rsp_data.tag = icache_rsp_tag;
    assign icache_bus_if.rsp_data.data = icache_rsp_data;
    assign icache_rsp_ready = icache_bus_if.rsp_ready;

`ifdef PERF_ENABLE
    sysmem_perf_t mem_perf;
    assign mem_perf.icache  = '0;
    assign mem_perf.dcache  = '0;
    assign mem_perf.l2cache = '0;
    assign mem_perf.l3cache = '0;
    assign mem_perf.lmem    = '0;
    assign mem_perf.mem     = '0;
`endif

`ifdef SCOPE
    wire [0:0] scope_reset_w = 1'b0;
    wire [0:0] scope_bus_in_w = 1'b0;
    wire [0:0] scope_bus_out_w;
    `UNUSED_VAR (scope_bus_out_w)
`endif

    VX_core #(
        .INSTANCE_ID (`SFORMATF(("core"))),
        .CORE_ID (CORE_ID)
    ) core (
        `SCOPE_IO_BIND (0)
        .clk            (clk),
        .reset          (reset),

    `ifdef PERF_ENABLE
        .sysmem_perf    (sysmem_perf),
    `endif

        .dcr_bus_if     (dcr_bus_if),

        .dcache_bus_if  (dcache_bus_if),

        .icache_bus_if  (icache_bus_if),

        .gbar_bus_if    (gbar_bus_if),

    `ifdef VX_CFG_EXT_DXA_ENABLE
        .dxa_req_bus_if (dxa_req_bus_if),
        .dxa_lmem_bus_if(dxa_lmem_bus_if),
    `endif

    `ifdef VX_CFG_EXT_TEX_ENABLE
        .tex_bus_if     (tex_bus_if),
    `endif
    `ifdef VX_CFG_EXT_RTU_ENABLE
        .rtu_bus_if     (rtu_bus_if),
    `endif
    `ifdef EXT_GFX_ANY_ENABLE
        .cluster_flush_if(cluster_flush_if),
    `endif

        .kmu_bus_if     (kmu_bus_if),
        .busy           (busy)
    );

    assign dbg_active_warps  = core.scheduler.active_warps;
    assign dbg_stalled_warps = core.scheduler.stalled_warps;
    assign dbg_warp_pc0      = core.scheduler.warp_pcs[0];
    assign dbg_lsu_execute_valid   = core.execute.lsu_unit.g_blocks[0].lsu_slice.execute_if.valid;
    assign dbg_lsu_mem_req_valid   = core.execute.lsu_unit.g_blocks[0].lsu_slice.mem_req_valid;
    assign dbg_lsu_is_store        = core.execute.lsu_unit.g_blocks[0].lsu_slice.execute_if.data.op_args.lsu.is_store;
    assign dbg_lsu_no_rsp_buf_ready = core.execute.lsu_unit.g_blocks[0].lsu_slice.no_rsp_buf_ready;

endmodule
