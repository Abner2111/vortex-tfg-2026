// TFG: jerarquía de memoria L1+L2 con coherencia MESI.
// Interfaz L1 <-> snoop bus (A-4). DRAFT — revisar con el asesor antes de
// usarla en la implementación (A-5+): señales y anchos sujetos a cambio.
//
// Contrato (borrador):
//   - Un L1 que hace miss o pide acceso exclusivo (write) publica una
//     petición de snoop (snoop_valid/addr/rw) al bus compartido.
//   - Cada otro L1 en el snoop_bus_if.snooper observa la petición y responde
//     en el mismo ciclo (o los que defina el bus árbitro) si tiene la línea
//     y en qué estado MESI, y si tiene que expulsarla (dirty -> flush).
//   - snoop_ready indica que el snooper terminó de resolver esta petición
//     (pudo tomar más de un ciclo si hubo que hacer flush).
// Pendiente de A-4: definir si el arbitraje entre múltiples snoopers
// respondiendo a la vez es prioridad fija o round-robin, y si el flush de
// una línea dirty viaja por este mismo bus o por el puerto hacia L2.

// Placeholder: snoop_dirty/snoop_data quedan sin driver real hasta que
// l1_cache.sv implemente write-back (A-5). Quitar el waiver entonces.
/* verilator lint_off UNUSEDSIGNAL */
interface VX_snoop_bus_if import VX_gpu_pkg::*; #(
    parameter ADDR_WIDTH = 32,
    parameter LINE_SIZE  = 64
) ();

    typedef enum logic [1:0] {
        MESI_I = 2'b00,  // Invalid
        MESI_S = 2'b01,  // Shared
        MESI_E = 2'b10,  // Exclusive
        MESI_M = 2'b11   // Modified
    } mesi_state_t;

    // petición de snoop (broadcast hacia todos los L1 del clúster)
    logic                   snoop_valid;
    logic [ADDR_WIDTH-1:0]  snoop_addr;
    logic                   snoop_rw;    // 0 = read (necesita S en el resto), 1 = write (necesita I en el resto)
    logic                   snoop_ready;

    // respuesta por-snooper (snoop_state codifica mesi_state_t; se deja como
    // logic crudo en el puerto para evitar la conversión implícita de enum
    // entre módulos que Verilator exige castear explícitamente — usar
    // mesi_state_t'(snoop_state) puertas adentro donde haga falta el enum)
    logic                   snoop_hit;
    logic [1:0]             snoop_state;
    logic                   snoop_dirty;
    logic [LINE_SIZE*8-1:0] snoop_data;  // válido solo si snoop_hit && snoop_dirty

    modport master (
        output snoop_valid,
        output snoop_addr,
        output snoop_rw,
        input  snoop_ready,
        input  snoop_hit,
        input  snoop_state,
        input  snoop_dirty,
        input  snoop_data
    );

    modport snooper (
        input  snoop_valid,
        input  snoop_addr,
        input  snoop_rw,
        output snoop_ready,
        output snoop_hit,
        output snoop_state,
        output snoop_dirty,
        output snoop_data
    );

endinterface
/* verilator lint_on UNUSEDSIGNAL */
