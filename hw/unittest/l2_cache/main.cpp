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
// TFG: A-10.6 (plan de l2_cache), prueba en aislamiento de l2_cache.sv con
// DOS núcleos (L1 mockeados) y DOS bancos reales -- VX_l2_cache_top.sv fija
// NUM_CORES=NUM_BANKS=2. Direccionamiento (LINE_SIZE=8, BANK_SIZE=32,
// NUM_WAYS=2 -> NUM_SETS=2 por banco; ADDR_WIDTH=29): addr[0]=banco,
// addr[1]=set, addr[2:]=tag.
//
// Escenarios:
//   1) Bancos distintos en paralelo: dos escrituras al mismo ciclo exacto
//      sobre bancos distintos -- confirma que no se arbitran entre sí.
//   2) Contención en el mismo banco: dos escrituras al mismo ciclo exacto
//      sobre el MISMO banco (sets distintos) -- confirma que el árbitro
//      round-robin atiende a las dos sin corromper ninguna.
//   3) Miss hacia el árbitro global: una lectura sobre una línea nunca
//      cacheada trae el dato del mock de "memoria" (mem0/mem1) -- y una
//      segunda lectura de la MISMA línea ya no genera tráfico hacia el
//      árbitro global (quedó cacheada).
//   4) Eviction: llenar las NUM_WAYS=2 vías de un set a fuerza de
//      writebacks, y un tercer writeback al mismo set fuerza desalojar la
//      vía víctima (política placeholder: vía 0) -- confirma que el dato
//      desalojado se volcó bien al mock de memoria antes de perderse.

#include "vl_simulator.h"
#include "VVX_l2_cache_top.h"
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <unordered_map>

using Sim = vl_simulator<VVX_l2_cache_top>;
using MemMap = std::unordered_map<uint32_t, uint64_t>;

enum MemPhase { WAIT_REQ, DELAY, RESPONDING };

struct MemPortState {
  MemPhase phase = WAIT_REQ;
  uint32_t cap_addr = 0;
  uint64_t cap_wdata = 0;
  bool cap_rw = false;
};

// Mismo criterio de "decidir antes de step()" que hw/unittest/snoop_bus:
// se llama con los valores de req_valid/addr/rw/data tal como están ANTES
// del próximo flanco.
static void service_mem_port(MemPortState &st, uint8_t req_valid, uint32_t req_addr,
                              uint8_t req_rw, uint64_t req_data, uint8_t &req_ready,
                              uint8_t &rsp_valid, uint64_t &rsp_data, uint8_t &rsp_tag,
                              MemMap &mem, int *req_count) {
  switch (st.phase) {
    case WAIT_REQ:
      req_ready = 1;
      if (req_valid) {
        st.cap_addr  = req_addr;
        st.cap_rw    = req_rw;
        st.cap_wdata = req_data;
        st.phase     = DELAY;
        if (req_count) ++(*req_count);
      }
      break;
    case DELAY: {
      req_ready = 0;
      if (st.cap_rw) mem[st.cap_addr] = st.cap_wdata;
      auto it   = mem.find(st.cap_addr);
      rsp_valid = 1;
      rsp_data  = (it != mem.end()) ? it->second : 0;
      rsp_tag   = 0;
      st.phase  = RESPONDING;
      break;
    }
    case RESPONDING:
      rsp_valid = 0;
      st.phase  = WAIT_REQ;
      break;
  }
}

// Un ciclo completo: sirve mem0 y mem1 (siempre, sin importar a cuál
// banco apunte el escenario en curso) y avanza el reloj. mem0_reqs/
// mem1_reqs, si no son null, cuentan cuántas peticiones acepto cada
// banco -- usado en el escenario 3 para confirmar que un hit NO genera
// tráfico nuevo hacia el árbitro global.
static void step_both_mem(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1,
                           MemMap &mem, int *mem0_reqs = nullptr, int *mem1_reqs = nullptr) {
  service_mem_port(st0, sim->mem0_req_valid, sim->mem0_req_addr, sim->mem0_req_rw,
                    sim->mem0_req_data, sim->mem0_req_ready, sim->mem0_rsp_valid,
                    sim->mem0_rsp_data, sim->mem0_rsp_tag, mem, mem0_reqs);
  service_mem_port(st1, sim->mem1_req_valid, sim->mem1_req_addr, sim->mem1_req_rw,
                    sim->mem1_req_data, sim->mem1_req_ready, sim->mem1_rsp_valid,
                    sim->mem1_rsp_data, sim->mem1_rsp_tag, mem, mem1_reqs);
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

static bool do_write0(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                      uint32_t addr, uint64_t data, uint32_t tag, const char *label, int max_cycles = 40) {
  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 1;
  sim->core0_req_addr   = addr;
  sim->core0_req_data   = data;
  sim->core0_req_byteen = 0xFF;
  sim->core0_req_tag    = tag;
  std::printf("=== %s ===\n", label);
  bool got = wait_write_done([&]{ return (bool)sim->core0_req_ready; }, max_cycles,
                             [&]{ step_both_mem(sim, ticks, st0, st1, mem); });
  sim->core0_req_valid = 0;
  return got;
}

static bool do_read0(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                     uint32_t addr, uint32_t tag, uint64_t &rsp_data, const char *label,
                     int max_cycles = 40, int *mem0_reqs = nullptr, int *mem1_reqs = nullptr) {
  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 0;
  sim->core0_req_addr   = addr;
  sim->core0_req_byteen = 0xFF;
  sim->core0_req_tag    = tag;
  std::printf("=== %s ===\n", label);
  bool got = false;
  for (int i = 0; i < max_cycles && !got; ++i) {
    step_both_mem(sim, ticks, st0, st1, mem, mem0_reqs, mem1_reqs);
    if (sim->core0_rsp_valid) { got = true; rsp_data = sim->core0_rsp_data; }
  }
  sim->core0_req_valid = 0;
  return got;
}

static bool do_read1(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                     uint32_t addr, uint32_t tag, uint64_t &rsp_data, const char *label,
                     int max_cycles = 40) {
  sim->core1_req_valid  = 1;
  sim->core1_req_rw     = 0;
  sim->core1_req_addr   = addr;
  sim->core1_req_byteen = 0xFF;
  sim->core1_req_tag    = tag;
  std::printf("=== %s ===\n", label);
  bool got = false;
  for (int i = 0; i < max_cycles && !got; ++i) {
    step_both_mem(sim, ticks, st0, st1, mem);
    if (sim->core1_rsp_valid) { got = true; rsp_data = sim->core1_rsp_data; }
  }
  sim->core1_req_valid = 0;
  return got;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Sim sim;
  uint64_t ticks = 0;
  ticks = sim.reset(ticks);

  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;

  MemPortState st0, st1;
  MemMap mem;

  int fails = 0;
  auto check = [&](bool cond, const char *what) {
    if (!cond) { std::printf("FAIL: %s\n", what); ++fails; }
    else       { std::printf("ok: %s\n", what); }
  };

  // Direcciones (ver descomposición en el comentario de arriba):
  const uint32_t kAddrA = 0;  // banco0, set0, tag0
  const uint32_t kAddrB = 1;  // banco1, set0, tag0
  const uint32_t kAddrC = 2;  // banco0, set1, tag0
  const uint32_t kAddrD = 3;  // banco1, set1, tag0
  const uint32_t kAddrE = 4;  // banco0, set0, tag1 (2da vía del mismo set que A)
  const uint32_t kAddrF = 8;  // banco0, set0, tag2 (fuerza desalojo en ese set)

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
    step_both_mem(sim, ticks, st0, st1, mem);
    if (!got0) { if (!acc0) { if (!sim->core0_req_ready) acc0 = true; } else if (sim->core0_req_ready) got0 = true; }
    if (!got1) { if (!acc1) { if (!sim->core1_req_ready) acc1 = true; } else if (sim->core1_req_ready) got1 = true; }
  }
  sim->core0_req_valid = 0;
  sim->core1_req_valid = 0;
  check(got0 && got1, "las dos escrituras (bancos distintos) respondieron");

  uint64_t rback;
  bool ok = do_read0(sim, ticks, st0, st1, mem, kAddrA, 10, rback, "read0 addrA");
  check(ok && rback == kDataA, "core0 recupera su propio dato (A)");
  ok = do_read1(sim, ticks, st0, st1, mem, kAddrB, 11, rback, "read1 addrB");
  check(ok && rback == kDataB, "core1 recupera su propio dato (B), sin cruzarse con A");

  // ------------------------------------------------------------------
  // Escenario 2: MISMO banco, mismo ciclo exacto (contención real).
  // ------------------------------------------------------------------
  ticks = sim.reset(ticks);
  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;
  st0 = MemPortState();
  st1 = MemPortState();
  mem.clear();

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
    step_both_mem(sim, ticks, st0, st1, mem);
    if (!got0) { if (!acc0) { if (!sim->core0_req_ready) acc0 = true; } else if (sim->core0_req_ready) got0 = true; }
    if (!got1) { if (!acc1) { if (!sim->core1_req_ready) acc1 = true; } else if (sim->core1_req_ready) got1 = true; }
  }
  sim->core0_req_valid = 0;
  sim->core1_req_valid = 0;
  check(got0 && got1, "las dos escrituras (mismo banco, contencion) respondieron -- sin deadlock");

  ok = do_read0(sim, ticks, st0, st1, mem, kAddrA, 12, rback, "read0 addrA (post-contencion)");
  check(ok && rback == kDataA, "core0 recupera su dato (A) sin corrupcion");
  ok = do_read1(sim, ticks, st0, st1, mem, kAddrC, 13, rback, "read1 addrC (post-contencion)");
  check(ok && rback == kDataC, "core1 recupera su dato (C) sin corrupcion");

  // ------------------------------------------------------------------
  // Escenario 3: read-miss hacia el arbitro global, y confirmar que un
  // hit posterior ya no genera trafico nuevo.
  // ------------------------------------------------------------------
  ticks = sim.reset(ticks);
  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;
  st0 = MemPortState();
  st1 = MemPortState();
  mem.clear();

  const uint64_t kDataD = 0xDDDDDDDDDDDDDDDDull;
  mem[kAddrD] = kDataD;  // precarga: "ya existe" en la memoria de atras, L2 nunca la cacheo

  // Lectura manual (no via do_read1) para poder contar cuántas
  // peticiones acepta mem1 en cada intento -- un miss real dispara
  // exactamente 1; un hit no deberia disparar ninguna.
  auto read1_counting = [&](uint32_t addr, uint32_t tag, int &mem1_count,
                             const char *label) -> uint64_t {
    sim->core1_req_valid  = 1;
    sim->core1_req_rw     = 0;
    sim->core1_req_addr   = addr;
    sim->core1_req_byteen = 0xFF;
    sim->core1_req_tag    = tag;
    std::printf("=== %s ===\n", label);
    uint64_t data = 0;
    bool got = false;
    for (int i = 0; i < 40 && !got; ++i) {
      step_both_mem(sim, ticks, st0, st1, mem, nullptr, &mem1_count);
      if (sim->core1_rsp_valid) { got = true; data = sim->core1_rsp_data; }
    }
    sim->core1_req_valid = 0;
    if (!got) std::printf("  (nunca respondio)\n");
    return data;
  };

  int mem1_count_miss = 0;
  rback = read1_counting(kAddrD, 14, mem1_count_miss, "read1 addrD (miss -> va al arbitro global, banco1)");
  check(rback == kDataD, "el miss trajo el dato correcto del mock de memoria");
  check(mem1_count_miss == 1, "el miss disparo exactamente 1 peticion al arbitro global");

  int mem1_count_hit = 0;
  rback = read1_counting(kAddrD, 15, mem1_count_hit, "read1 addrD otra vez (deberia ser hit)");
  check(rback == kDataD, "el hit sigue trayendo el dato correcto");
  check(mem1_count_hit == 0, "el hit NO genero trafico nuevo hacia el arbitro global");

  // ------------------------------------------------------------------
  // Escenario 4: eviction dentro de un banco -- llenar las 2 vias del
  // set (A, E), despues F fuerza desalojar la victima (via 0 = A).
  // ------------------------------------------------------------------
  ticks = sim.reset(ticks);
  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;
  st0 = MemPortState();
  st1 = MemPortState();
  mem.clear();

  const uint64_t kDataE = 0xEEEEEEEEEEEEEEEEull;
  const uint64_t kDataF = 0xF0F0F0F0F0F0F0F0ull;

  ok = do_write0(sim, ticks, st0, st1, mem, kAddrA, kDataA, 20, "write addrA (llena via 0 del set)");
  check(ok, "write addrA respondio");
  ok = do_write0(sim, ticks, st0, st1, mem, kAddrE, kDataE, 21, "write addrE (llena via 1 del mismo set)");
  check(ok, "write addrE respondio");

  ok = do_write0(sim, ticks, st0, st1, mem, kAddrF, kDataF, 22,
                "write addrF (mismo set, fuerza desalojo de la victima dirty)");
  check(ok, "write addrF (con desalojo) respondio");

  // addrA se desalojo -> releerla es un miss nuevo, pero el write-back
  // debio haber guardado kDataA en el mock de memoria antes de perderse.
  ok = do_read0(sim, ticks, st0, st1, mem, kAddrA, 23, rback, "read addrA (post-desalojo)");
  check(ok && rback == kDataA, "el write-back guardo el dato desalojado -- no se perdio");

  // addrE nunca se tocó -> debe seguir en la otra vía (todavía valida).
  ok = do_read0(sim, ticks, st0, st1, mem, kAddrE, 24, rback, "read addrE (nunca desalojada)");
  check(ok && rback == kDataE, "addrE sigue cacheada, dato correcto");

  if (fails) {
    std::printf("l2_cache isolation test: FAILED (%d fallo(s))\n", fails);
    return 1;
  }
  std::printf("l2_cache isolation test: PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
