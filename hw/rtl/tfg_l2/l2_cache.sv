// Interfaces:
//   core_bus_if[NUM_CORES] : L2 <-> L1 (una por núcleo). Reutiliza
//                            VX_mem_bus_if, igual convención que
//                            l1_cache.sv (hw/rtl/tfg_l1/l1_cache.sv) -- L2
//                            es slave, cada L1 es master hacia su banco.
//   mem_bus_if[NUM_BANKS]  : L2 <-> árbitro global, UN puerto POR banco.
//
// Paso 1 (de 6, implementación incremental con commits graduales):
// bancos BRAM independientes. Solo las estructuras de almacenamiento --
// tag array + data array por banco, mismo patrón que l1_cache.sv (NUM_WAYS
// memorias síncronas independientes por banco). Todavía NO hay lógica de
// acceso (arbitraje, hit/miss, FSM) ni cableado de los puertos -- eso entra
// en los próximos pasos. clk/reset y los puertos están declarados para fijar
// la interfaz desde ahora, pero no se usan todavía.
`include "VX_define.vh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module l2_cache import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",

    parameter NUM_CORES = 4,      // puertos L1 servidos
    parameter NUM_BANKS = 4,      // bancos independientes -- debe ser potencia de 2
    parameter BANK_SIZE = 16384,  // bytes, POR banco
    parameter NUM_WAYS  = 4,      // vías por banco
    parameter LINE_SIZE = 16,     // bytes -- tiene que calzar con el LINE_SIZE
                                   // de mem_bus_if de la L1 que conecta acá
                                   // (ver hw/rtl/tfg_l1/l1_cache.sv)
    parameter CORE_TAG_WIDTH = 8,
    parameter MEM_TAG_WIDTH  = 8
) (
    input wire clk,
    input wire reset,

    VX_mem_bus_if.slave  core_bus_if [NUM_CORES],
    VX_mem_bus_if.master mem_bus_if  [NUM_BANKS]
);
    // ------------------------------------------------------------------
    // Direccionamiento (todavía sin usar -- queda fijado acá porque
    // NUM_SETS/TAG_BITS lo necesitan para dimensionar el storage de este
    // paso): bancos intercalados por los bits más bajos de la dirección
    // de línea (después de banco vienen set, después tag).
    // ------------------------------------------------------------------
    localparam ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(LINE_SIZE);
    localparam LINE_BITS  = LINE_SIZE * 8;
    localparam BANK_BITS  = `CLOG2(NUM_BANKS);
    localparam NUM_SETS   = BANK_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam SET_BITS   = `CLOG2(NUM_SETS);
    localparam TAG_BITS   = ADDR_WIDTH - BANK_BITS - SET_BITS;
    localparam WAY_BITS   = `LOG2UP(NUM_WAYS);

    `STATIC_ASSERT((NUM_BANKS >= 2) && (NUM_BANKS == (1 << BANK_BITS)),
                   ("l2_cache: NUM_BANKS debe ser potencia de 2, >= 2"))

    typedef struct packed {
        logic                 valid;
        logic                 dirty;
        logic [TAG_BITS-1:0]  tag;
    } tag_entry_t;

    // ------------------------------------------------------------------
    // Bancos BRAM independientes (paso 1): cada banco, su propio tag array
    // y, por vía, su propia memoria síncrona de datos -- mismo patrón que
    // l1_cache.sv (hw/rtl/tfg_l1/l1_cache.sv: "NUM_WAYS memorias síncronas
    // independientes... lectura Y escritura registradas en el flanco de
    // reloj, para que el sintetizador infiera BRAM real"). Sin lógica de
    // acceso todavía: nadie lee ni escribe estos arrays en este paso.
    // ------------------------------------------------------------------
    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank

        tag_entry_t tag_array [NUM_SETS][NUM_WAYS];

        for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_data_way
            logic [LINE_BITS-1:0] mem [NUM_SETS];
        end

    end

endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
