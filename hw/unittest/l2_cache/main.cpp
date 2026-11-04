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
//
// TFG: A-14 paso 0, escalado a 4 núcleos / 4 bancos reales (desde los 2/2
// de A-11) -- verifica que l2_cache.sv generaliza de verdad ANTES de
// subirlo a compute_unit.sv (donde un bug sería mucho más caro de
// localizar). VX_l2_cache_top.sv fija NUM_CORES=NUM_BANKS=4.
// Direccionamiento (LINE_SIZE=8, BANK_SIZE=32, NUM_WAYS=2 ->
// NUM_SETS=2 por banco; ADDR_WIDTH=29): addr[1:0]=banco (2 bits),
// addr[2]=set, addr[3:]=tag.
//
// Escenarios (1-4 heredados de A-11, direcciones recalculadas para
// BANK_BITS=2; 5 es nuevo, exclusivo de este paso 0):
//   1) Bancos distintos en paralelo: dos escrituras al mismo ciclo exacto
//      sobre bancos distintos -- confirma que no se arbitran entre sí.
//   2) Contención en el mismo banco: dos escrituras al mismo ciclo exacto
//      sobre el MISMO banco (sets distintos) -- confirma que el árbitro
//      round-robin atiende a las dos sin corromper ninguna.
//   3) Miss hacia el árbitro global: una lectura sobre una línea nunca
//      cacheada trae el dato del mock de "memoria" -- y una segunda
//      lectura de la MISMA línea ya no genera tráfico hacia el árbitro
//      global (quedó cacheada).
//   4) Eviction: llenar las NUM_WAYS=2 vías de un set a fuerza de
//      writebacks, y un tercer writeback al mismo set fuerza desalojar la
//      vía víctima (política placeholder: vía 0) -- confirma que el dato
//      desalojado se volcó bien al mock de memoria antes de perderse.
//   5) Los 4 bancos a la vez: 4 núcleos, 4 bancos distintos, mismo ciclo
//      exacto -- confirma paralelismo real de N=4, no solo N=2.

#include "vl_simulator.h"
#include "VVX_l2_cache_top.h"
#include <cstdio>
#include <cstdlib>
#include <unordered_map>

using Sim = vl_simulator<VVX_l2_cache_top>;
using MemMap = std::unordered_map<uint32_t, uint64_t>;

enum MemPhase { WAIT_REQ, DELAY, RESPONDING };

struct MemPortState {
  MemPhase phase = WAIT_REQ;
  uint32_t cap_addr = 0;
  uint64_t cap_wdata = 0;
  uint8_t  cap_tag = 0;  // MEM_TAG_WIDTH=8 -> Verilator lo expone como CData (uint8_t)
  bool cap_rw = false;
};

// Mismo criterio de "decidir antes de step()" que hw/unittest/snoop_bus:
// se llama con los valores de req_valid/addr/rw/data tal como están ANTES
// del próximo flanco.
static void service_mem_port(MemPortState &st, uint8_t req_valid, uint32_t req_addr,
                              uint8_t req_rw, uint64_t req_data, uint8_t req_tag,
                              uint8_t &req_ready, uint8_t &rsp_valid, uint64_t &rsp_data,
                              uint8_t &rsp_tag, MemMap &mem, int *req_count) {
  switch (st.phase) {
    case WAIT_REQ:
      req_ready = 1;
      if (req_valid) {
        st.cap_addr  = req_addr;
        st.cap_rw    = req_rw;
        st.cap_wdata = req_data;
        st.cap_tag   = req_tag;
        st.phase     = DELAY;
        if (req_count) ++(*req_count);
        // Memoria real (sim/rtlsim/processor.cpp) escribe *ram_ en el
        // mismo ciclo que acepta el request (req_valid && req_ready),
        // no cuando arma la respuesta -- confirmado leyendo ese archivo
        // en Fase B. Si este mock escribiera recién en DELAY (como antes),
        // un bank de l2_cache.sv que avanza al aceptarse el write (sin
        // esperar rsp_valid, fix de Fase B: la memoria real nunca ackea
        // una escritura) podría leer ESTA MISMA dirección de vuelta antes
        // de que el mock la hubiera comprometido -- encontrado como
        // regresión real al agregar soporte de fence en l1_cache.sv.
        if (req_rw) mem[req_addr] = req_data;
      }
      break;
    case DELAY: {
      req_ready = 0;
      if (st.cap_rw) {
        // Memoria real (sim/rtlsim/processor.cpp) NUNCA levanta
        // mem_rsp_valid para una escritura -- fire-and-forget de
        // verdad, no una demora (confirmado en Fase B). Si este mock
        // igual ackeara la escritura (como antes), un bank de
        // l2_cache.sv que ya avanzó sin esperar ese ack (mismo fix de
        // Fase B) podía confundir ese ack sobrante con la respuesta de
        // la SIGUIENTE transacción que emite apenas avanza -- carrera
        // real, encontrada como regresión al agregar soporte de fence
        // en l1_cache.sv.
        st.phase = WAIT_REQ;
      } else {
        auto it   = mem.find(st.cap_addr);
        rsp_valid = 1;
        rsp_data  = (it != mem.end()) ? it->second : 0;
        // El árbitro global (VX_mem_bus_arb, A-14) ensancha el tag de
        // salida para poder enrutar la respuesta al banco correcto --
        // el mock de memoria tiene que ecoar EXACTAMENTE el tag que
        // recibió, nunca hardcodear 0 (eso solo valía con un pedido en
        // vuelo a la vez, antes de A-14).
        rsp_tag   = st.cap_tag;
        st.phase  = RESPONDING;
      }
      break;
    }
    case RESPONDING:
      rsp_valid = 0;
      st.phase  = WAIT_REQ;
      break;
  }
}

// Un ciclo completo: sirve los 4 bancos (siempre, sin importar a cuáles
// apunte el escenario en curso) y avanza el reloj. mem*_reqs, si no son
// null, cuentan cuántas peticiones acepta cada banco -- usado en el
// escenario 3 para confirmar que un hit NO genera tráfico nuevo.
static void step_all_mem(Sim &sim, uint64_t &ticks, MemPortState st[4], MemMap &mem,
                          int *mem_reqs[4] = nullptr) {
  service_mem_port(st[0], sim->mem0_req_valid, sim->mem0_req_addr, sim->mem0_req_rw,
                    sim->mem0_req_data, sim->mem0_req_tag, sim->mem0_req_ready,
                    sim->mem0_rsp_valid, sim->mem0_rsp_data, sim->mem0_rsp_tag, mem,
                    mem_reqs ? mem_reqs[0] : nullptr);
  service_mem_port(st[1], sim->mem1_req_valid, sim->mem1_req_addr, sim->mem1_req_rw,
                    sim->mem1_req_data, sim->mem1_req_tag, sim->mem1_req_ready,
                    sim->mem1_rsp_valid, sim->mem1_rsp_data, sim->mem1_rsp_tag, mem,
                    mem_reqs ? mem_reqs[1] : nullptr);
  service_mem_port(st[2], sim->mem2_req_valid, sim->mem2_req_addr, sim->mem2_req_rw,
                    sim->mem2_req_data, sim->mem2_req_tag, sim->mem2_req_ready,
                    sim->mem2_rsp_valid, sim->mem2_rsp_data, sim->mem2_rsp_tag, mem,
                    mem_reqs ? mem_reqs[2] : nullptr);
  service_mem_port(st[3], sim->mem3_req_valid, sim->mem3_req_addr, sim->mem3_req_rw,
                    sim->mem3_req_data, sim->mem3_req_tag, sim->mem3_req_ready,
                    sim->mem3_rsp_valid, sim->mem3_rsp_data, sim->mem3_rsp_tag, mem,
                    mem_reqs ? mem_reqs[3] : nullptr);
  ticks = sim.step(ticks, 2);
}

// Un write es fire-and-forget a nivel de bus (ver l1_cache.sv /
// l2_cache.sv: solo las lecturas devuelven respuesta) -- completa cuando
// req_ready vuelve a 1 (la FSM del banco volvió a S_IDLE).
template <typename ReqReadyFn, typename StepFn>
static bool wait_write_done(ReqReadyFn get_req_ready, int max_cycles, StepFn step_fn) {
  bool accepted = false;
  for (int i = 0; i < max_cycles; ++i) {
    step_fn();
    if (!accepted) {
      if (!get_req_ready()) accepted = true;
    } else if (get_req_ready()) {
      return true;
    }
  }
  return false;
}

#define DEFINE_CORE_HELPERS(N)                                                               \
  static bool do_write##N(Sim &sim, uint64_t &ticks, MemPortState st[4], MemMap &mem,         \
                           uint32_t addr, uint64_t data, uint32_t tag, const char *label,      \
                           int max_cycles = 40) {                                              \
    sim->core##N##_req_valid  = 1;                                                             \
    sim->core##N##_req_rw     = 1;                                                             \
    sim->core##N##_req_addr   = addr;                                                          \
    sim->core##N##_req_data   = data;                                                          \
    sim->core##N##_req_byteen = 0xFF;                                                          \
    sim->core##N##_req_tag    = tag;                                                           \
    std::printf("=== %s ===\n", label);                                                        \
    bool got = wait_write_done([&]{ return (bool)sim->core##N##_req_ready; }, max_cycles,       \
                               [&]{ step_all_mem(sim, ticks, st, mem); });                      \
    sim->core##N##_req_valid = 0;                                                              \
    return got;                                                                                \
  }                                                                                             \
  static bool do_read##N(Sim &sim, uint64_t &ticks, MemPortState st[4], MemMap &mem,          \
                          uint32_t addr, uint32_t tag, uint64_t &rsp_data, const char *label,   \
                          int max_cycles = 40) {                                                \
    sim->core##N##_req_valid  = 1;                                                              \
    sim->core##N##_req_rw     = 0;                                                              \
    sim->core##N##_req_addr   = addr;                                                           \
    sim->core##N##_req_byteen = 0xFF;                                                           \
    sim->core##N##_req_tag    = tag;                                                            \
    std::printf("=== %s ===\n", label);                                                         \
    bool got = false;                                                                           \
    for (int i = 0; i < max_cycles && !got; ++i) {                                              \
      step_all_mem(sim, ticks, st, mem);                                                        \
      if (sim->core##N##_rsp_valid) { got = true; rsp_data = sim->core##N##_rsp_data; }         \
    }                                                                                            \
    sim->core##N##_req_valid = 0;                                                               \
    return got;                                                                                 \
  }

DEFINE_CORE_HELPERS(0)
DEFINE_CORE_HELPERS(1)
DEFINE_CORE_HELPERS(2)
DEFINE_CORE_HELPERS(3)

#undef DEFINE_CORE_HELPERS

static void reset_all(Sim &sim, uint64_t &ticks, MemPortState st[4], MemMap &mem) {
  ticks = sim.reset(ticks);
  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;
  sim->core2_rsp_ready = 1;
  sim->core3_rsp_ready = 1;
  for (int i = 0; i < 4; ++i) st[i] = MemPortState();
  mem.clear();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Sim sim;
  uint64_t ticks = 0;
  MemPortState st[4];
  MemMap mem;
  reset_all(sim, ticks, st, mem);

  int fails = 0;
  auto check = [&](bool cond, const char *what) {
    if (!cond) { std::printf("FAIL: %s\n", what); ++fails; }
    else       { std::printf("ok: %s\n", what); }
  };

  // Direcciones (ver descomposición en el comentario de arriba,
  // BANK_BITS=2: addr[1:0]=banco, addr[2]=set, addr[3:]=tag):
  const uint32_t kAddrA = 0;   // banco0, set0, tag0
  const uint32_t kAddrB = 1;   // banco1, set0, tag0
  const uint32_t kAddr2 = 2;   // banco2, set0, tag0
  const uint32_t kAddr3 = 3;   // banco3, set0, tag0
  const uint32_t kAddrC = 4;   // banco0, set1, tag0 (mismo banco que A)
  const uint32_t kAddrD = 5;   // banco1, set1, tag0
  const uint32_t kAddrE = 8;   // banco0, set0, tag1 (2da vía del mismo set que A)
  const uint32_t kAddrF = 16;  // banco0, set0, tag2 (fuerza desalojo en ese set)

  // ------------------------------------------------------------------
  // Escenario 1: bancos distintos, mismo ciclo exacto.
  // ------------------------------------------------------------------
  const uint64_t kDataA = 0xAAAAAAAAAAAAAAAAull;
  const uint64_t kDataB = 0xBBBBBBBBBBBBBBBBull;

  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 1;
  sim->core0_req_addr   = kAddrA;
  sim->core0_req_data   = kDataA;
  sim->core0_req_byteen = 0xFF;
  sim->core0_req_tag    = 1;

  sim->core1_req_valid  = 1;
  sim->core1_req_rw     = 1;
  sim->core1_req_addr   = kAddrB;
  sim->core1_req_data   = kDataB;
  sim->core1_req_byteen = 0xFF;
  sim->core1_req_tag    = 2;

  std::printf("=== Escenario 1: write addrA (banco0) y addrB (banco1), mismo ciclo ===\n");
  bool got0 = false, got1 = false, acc0 = false, acc1 = false;
  for (int i = 0; i < 60 && !(got0 && got1); ++i) {
    step_all_mem(sim, ticks, st, mem);
    if (!got0) { if (!acc0) { if (!sim->core0_req_ready) acc0 = true; } else if (sim->core0_req_ready) got0 = true; }
    if (!got1) { if (!acc1) { if (!sim->core1_req_ready) acc1 = true; } else if (sim->core1_req_ready) got1 = true; }
  }
  sim->core0_req_valid = 0;
  sim->core1_req_valid = 0;
  check(got0 && got1, "las dos escrituras (bancos distintos) respondieron");

  uint64_t rback;
  bool ok = do_read0(sim, ticks, st, mem, kAddrA, 10, rback, "read0 addrA");
  check(ok && rback == kDataA, "core0 recupera su propio dato (A)");
  ok = do_read1(sim, ticks, st, mem, kAddrB, 11, rback, "read1 addrB");
  check(ok && rback == kDataB, "core1 recupera su propio dato (B), sin cruzarse con A");

  // ------------------------------------------------------------------
  // Escenario 2: MISMO banco, mismo ciclo exacto (contención real).
  // ------------------------------------------------------------------
  reset_all(sim, ticks, st, mem);

  const uint64_t kDataC = 0xCCCCCCCCCCCCCCCCull;
  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 1;
  sim->core0_req_addr   = kAddrA;
  sim->core0_req_data   = kDataA;
  sim->core0_req_byteen = 0xFF;
  sim->core0_req_tag    = 3;

  sim->core1_req_valid  = 1;
  sim->core1_req_rw     = 1;
  sim->core1_req_addr   = kAddrC;
  sim->core1_req_data   = kDataC;
  sim->core1_req_byteen = 0xFF;
  sim->core1_req_tag    = 4;

  std::printf("=== Escenario 2: write addrA y addrC (MISMO banco0, sets distintos), mismo ciclo ===\n");
  got0 = got1 = acc0 = acc1 = false;
  for (int i = 0; i < 60 && !(got0 && got1); ++i) {
    step_all_mem(sim, ticks, st, mem);
    if (!got0) { if (!acc0) { if (!sim->core0_req_ready) acc0 = true; } else if (sim->core0_req_ready) got0 = true; }
    if (!got1) { if (!acc1) { if (!sim->core1_req_ready) acc1 = true; } else if (sim->core1_req_ready) got1 = true; }
  }
  sim->core0_req_valid = 0;
  sim->core1_req_valid = 0;
  check(got0 && got1, "las dos escrituras (mismo banco, contencion) respondieron -- sin deadlock");

  ok = do_read0(sim, ticks, st, mem, kAddrA, 12, rback, "read0 addrA (post-contencion)");
  check(ok && rback == kDataA, "core0 recupera su dato (A) sin corrupcion");
  ok = do_read1(sim, ticks, st, mem, kAddrC, 13, rback, "read1 addrC (post-contencion)");
  check(ok && rback == kDataC, "core1 recupera su dato (C) sin corrupcion");

  // ------------------------------------------------------------------
  // Escenario 3: read-miss hacia el arbitro global, y confirmar que un
  // hit posterior ya no genera trafico nuevo.
  // ------------------------------------------------------------------
  reset_all(sim, ticks, st, mem);

  const uint64_t kDataD = 0xDDDDDDDDDDDDDDDDull;
  mem[kAddrD] = kDataD;  // precarga: "ya existe" en la memoria de atras, L2 nunca la cacheo

  // Lectura manual (no via do_read1) para poder contar cuántas
  // peticiones acepta banco1 en cada intento -- un miss real dispara
  // exactamente 1; un hit no deberia disparar ninguna.
  auto read1_counting = [&](uint32_t addr, uint32_t tag, int &bank1_count,
                             const char *label) -> uint64_t {
    sim->core1_req_valid  = 1;
    sim->core1_req_rw     = 0;
    sim->core1_req_addr   = addr;
    sim->core1_req_byteen = 0xFF;
    sim->core1_req_tag    = tag;
    std::printf("=== %s ===\n", label);
    uint64_t data = 0;
    bool got = false;
    int *mem_reqs[4] = { nullptr, &bank1_count, nullptr, nullptr };
    for (int i = 0; i < 40 && !got; ++i) {
      step_all_mem(sim, ticks, st, mem, mem_reqs);
      if (sim->core1_rsp_valid) { got = true; data = sim->core1_rsp_data; }
    }
    sim->core1_req_valid = 0;
    if (!got) std::printf("  (nunca respondio)\n");
    return data;
  };

  int bank1_count_miss = 0;
  rback = read1_counting(kAddrD, 14, bank1_count_miss, "read1 addrD (miss -> va al arbitro global, banco1)");
  check(rback == kDataD, "el miss trajo el dato correcto del mock de memoria");
  check(bank1_count_miss == 1, "el miss disparo exactamente 1 peticion al arbitro global");

  int bank1_count_hit = 0;
  rback = read1_counting(kAddrD, 15, bank1_count_hit, "read1 addrD otra vez (deberia ser hit)");
  check(rback == kDataD, "el hit sigue trayendo el dato correcto");
  check(bank1_count_hit == 0, "el hit NO genero trafico nuevo hacia el arbitro global");

  // ------------------------------------------------------------------
  // Escenario 4: eviction dentro de un banco -- llenar las 2 vias del
  // set (A, E), despues F fuerza desalojar la victima (via 0 = A).
  // ------------------------------------------------------------------
  reset_all(sim, ticks, st, mem);

  const uint64_t kDataE = 0xEEEEEEEEEEEEEEEEull;
  const uint64_t kDataF = 0xF0F0F0F0F0F0F0F0ull;

  ok = do_write0(sim, ticks, st, mem, kAddrA, kDataA, 20, "write addrA (llena via 0 del set)");
  check(ok, "write addrA respondio");
  ok = do_write0(sim, ticks, st, mem, kAddrE, kDataE, 21, "write addrE (llena via 1 del mismo set)");
  check(ok, "write addrE respondio");

  ok = do_write0(sim, ticks, st, mem, kAddrF, kDataF, 22,
                "write addrF (mismo set, fuerza desalojo de la victima dirty)");
  check(ok, "write addrF (con desalojo) respondio");

  ok = do_read0(sim, ticks, st, mem, kAddrA, 23, rback, "read addrA (post-desalojo)");
  check(ok && rback == kDataA, "el write-back guardo el dato desalojado -- no se perdio");

  ok = do_read0(sim, ticks, st, mem, kAddrE, 24, rback, "read addrE (nunca desalojada)");
  check(ok && rback == kDataE, "addrE sigue cacheada, dato correcto");

  // ------------------------------------------------------------------
  // Escenario 5 (nuevo, A-14 paso 0): los 4 bancos a la vez -- 4
  // núcleos, 4 bancos distintos, mismo ciclo exacto. Confirma
  // paralelismo real de N=4 (el escenario 1 solo probaba N=2).
  // ------------------------------------------------------------------
  reset_all(sim, ticks, st, mem);

  const uint64_t kData0 = 0x1111111111111111ull;
  const uint64_t kData1 = 0x2222222222222222ull;
  const uint64_t kData2 = 0x3333333333333333ull;
  const uint64_t kData3 = 0x4444444444444444ull;

  sim->core0_req_valid  = 1; sim->core0_req_rw = 1; sim->core0_req_addr = kAddrA;
  sim->core0_req_data   = kData0; sim->core0_req_byteen = 0xFF; sim->core0_req_tag = 30;

  sim->core1_req_valid  = 1; sim->core1_req_rw = 1; sim->core1_req_addr = kAddrB;
  sim->core1_req_data   = kData1; sim->core1_req_byteen = 0xFF; sim->core1_req_tag = 31;

  sim->core2_req_valid  = 1; sim->core2_req_rw = 1; sim->core2_req_addr = kAddr2;
  sim->core2_req_data   = kData2; sim->core2_req_byteen = 0xFF; sim->core2_req_tag = 32;

  sim->core3_req_valid  = 1; sim->core3_req_rw = 1; sim->core3_req_addr = kAddr3;
  sim->core3_req_data   = kData3; sim->core3_req_byteen = 0xFF; sim->core3_req_tag = 33;

  std::printf("=== Escenario 5: 4 nucleos, 4 bancos distintos, mismo ciclo exacto ===\n");
  bool got[4] = {false, false, false, false};
  bool acc[4] = {false, false, false, false};
  auto ready_of = [&](int c) -> bool {
    switch (c) {
      case 0: return sim->core0_req_ready;
      case 1: return sim->core1_req_ready;
      case 2: return sim->core2_req_ready;
      default: return sim->core3_req_ready;
    }
  };
  for (int i = 0; i < 80 && !(got[0] && got[1] && got[2] && got[3]); ++i) {
    step_all_mem(sim, ticks, st, mem);
    for (int c = 0; c < 4; ++c) {
      if (got[c]) continue;
      if (!acc[c]) { if (!ready_of(c)) acc[c] = true; }
      else if (ready_of(c)) got[c] = true;
    }
  }
  sim->core0_req_valid = 0;
  sim->core1_req_valid = 0;
  sim->core2_req_valid = 0;
  sim->core3_req_valid = 0;
  check(got[0] && got[1] && got[2] && got[3], "las 4 escrituras (4 bancos distintos) respondieron, mismo ciclo");

  ok = do_read0(sim, ticks, st, mem, kAddrA, 34, rback, "read0 addrA");
  check(ok && rback == kData0, "core0 recupera su dato sin cruzarse con los otros 3");
  ok = do_read1(sim, ticks, st, mem, kAddrB, 35, rback, "read1 addrB");
  check(ok && rback == kData1, "core1 recupera su dato sin cruzarse con los otros 3");
  ok = do_read2(sim, ticks, st, mem, kAddr2, 36, rback, "read2 addr2");
  check(ok && rback == kData2, "core2 recupera su dato sin cruzarse con los otros 3");
  ok = do_read3(sim, ticks, st, mem, kAddr3, 37, rback, "read3 addr3");
  check(ok && rback == kData3, "core3 recupera su dato sin cruzarse con los otros 3");

  if (fails) {
    std::printf("l2_cache isolation test (4/4): FAILED (%d fallo(s))\n", fails);
    return 1;
  }
  std::printf("l2_cache isolation test (4/4): PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
