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
// TFG: A-7, snoop_bus.sv con DOS l1_cache reales conectados. A diferencia
// de hw/unittest/l1_cache (un L1 aislado, snoop_bus_if atado a mano),
// acá el snoop entre L1s pasa por la interconexión real -- este test
// verifica arbitraje, propagación de invalidaciones/upgrades, la señal de
// hit remoto, y que los datos de un flush lleguen correctos al otro lado,
// todo de punta a punta.
//
// mem0/mem1 comparten el MISMO modelo de "memoria" (unordered_map): un
// write-back o flush de un L1 tiene que ser visible como lectura para el
// otro, igual que compartirían la L2 real.

#include "vl_simulator.h"
#include "VVX_snoop_bus_top.h"
#include <cstdio>
#include <cstdlib>
#include <unordered_map>

using Sim = vl_simulator<VVX_snoop_bus_top>;
using MemMap = std::unordered_map<uint32_t, uint64_t>;

enum MemPhase { WAIT_REQ, DELAY, RESPONDING };

struct MemPortState {
  MemPhase phase = WAIT_REQ;
  uint32_t cap_addr = 0;
  uint64_t cap_wdata = 0;  // LINE_SIZE*8 = 64 bits (QData del lado Verilator)
  bool cap_rw = false;
};

// Sirve una transacción de mem_bus_if contra `mem` (memoria compartida).
// Mismo criterio de "decidir antes de step()" que hw/unittest/l1_cache:
// se llama con los valores de req_valid/addr/rw/data tal como están ANTES
// del próximo flanco.
static void service_mem_port(MemPortState &st, uint8_t req_valid, uint32_t req_addr,
                              uint8_t req_rw, uint64_t req_data, uint8_t &req_ready,
                              uint8_t &rsp_valid, uint64_t &rsp_data, uint8_t &rsp_tag,
                              MemMap &mem) {
  switch (st.phase) {
    case WAIT_REQ:
      req_ready = 1;
      if (req_valid) {
        st.cap_addr  = req_addr;
        st.cap_rw    = req_rw;
        st.cap_wdata = req_data;
        st.phase     = DELAY;
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

// Un ciclo completo: sirve mem0 y mem1 (siempre, sin importar cuál L1 es
// el "foco" del escenario -- un snoop remoto puede disparar un flush en
// el mem_bus_if del otro L1 en cualquier momento) y avanza el reloj.
static void step_both_mem(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem) {
  service_mem_port(st0, sim->mem0_req_valid, sim->mem0_req_addr, sim->mem0_req_rw,
                    sim->mem0_req_data, sim->mem0_req_ready, sim->mem0_rsp_valid,
                    sim->mem0_rsp_data, sim->mem0_rsp_tag, mem);
  service_mem_port(st1, sim->mem1_req_valid, sim->mem1_req_addr, sim->mem1_req_rw,
                    sim->mem1_req_data, sim->mem1_req_ready, sim->mem1_rsp_valid,
                    sim->mem1_rsp_data, sim->mem1_rsp_tag, mem);
  ticks = sim.step(ticks, 2);
}

// ---- L1 #0: escritura/lectura en primer plano ----
static bool do_write0(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                       uint32_t addr, uint32_t data, uint32_t tag, const char *label, int max_cycles = 40) {
  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 1;
  sim->core0_req_addr   = addr;
  sim->core0_req_data   = data;
  sim->core0_req_byteen = 0xF;
  sim->core0_req_tag    = tag;
  std::printf("=== %s ===\n", label);
  bool got = false;
  for (int i = 0; i < max_cycles && !got; ++i) {
    step_both_mem(sim, ticks, st0, st1, mem);
    if (sim->core0_rsp_valid) got = true;
  }
  sim->core0_req_valid = 0;
  return got;
}

static bool do_read0(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                      uint32_t addr, uint32_t tag, uint32_t &rsp_data, const char *label, int max_cycles = 40) {
  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 0;
  sim->core0_req_addr   = addr;
  sim->core0_req_byteen = 0xF;
  sim->core0_req_tag    = tag;
  std::printf("=== %s ===\n", label);
  bool got = false;
  for (int i = 0; i < max_cycles && !got; ++i) {
    step_both_mem(sim, ticks, st0, st1, mem);
    if (sim->core0_rsp_valid) { got = true; rsp_data = sim->core0_rsp_data; }
  }
  sim->core0_req_valid = 0;
  return got;
}

// ---- L1 #1: mismo patrón ----
static bool do_write1(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                       uint32_t addr, uint32_t data, uint32_t tag, const char *label, int max_cycles = 40) {
  sim->core1_req_valid  = 1;
  sim->core1_req_rw     = 1;
  sim->core1_req_addr   = addr;
  sim->core1_req_data   = data;
  sim->core1_req_byteen = 0xF;
  sim->core1_req_tag    = tag;
  std::printf("=== %s ===\n", label);
  bool got = false;
  for (int i = 0; i < max_cycles && !got; ++i) {
    step_both_mem(sim, ticks, st0, st1, mem);
    if (sim->core1_rsp_valid) got = true;
  }
  sim->core1_req_valid = 0;
  return got;
}

static bool do_read1(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                      uint32_t addr, uint32_t tag, uint32_t &rsp_data, const char *label, int max_cycles = 40) {
  sim->core1_req_valid  = 1;
  sim->core1_req_rw     = 0;
  sim->core1_req_addr   = addr;
  sim->core1_req_byteen = 0xF;
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

enum { MESI_I = 0, MESI_S = 1, MESI_E = 2, MESI_M = 3 };

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
  auto occupied = [](uint8_t v0, uint8_t m0, uint8_t v1, uint8_t m1, bool &valid, uint32_t &mesi) {
    if (v0)      { valid = true;  mesi = m0; }
    else if (v1) { valid = true;  mesi = m1; }
    else         { valid = false; mesi = 0;  }
  };

  // kAddr0 (word 0, tag=0/set=0), misma dirección que hw/unittest/l1_cache
  // usa para sus escenarios MESI -- reutilizamos el mismo mapeo mental.
  const uint32_t kAddr0 = 0;

  // ------------------------------------------------------------------
  // Escenario 1: L1-0 hace miss de lectura sobre addr0. Nadie más la
  // tiene todavía -> la consulta al bus vuelve con hit=0 -> I->E.
  // ------------------------------------------------------------------
  uint32_t rdata;
  if (do_read0(sim, ticks, st0, st1, mem, kAddr0, 1, rdata, "L1-0 read addr0 (I->E)")) {
    bool v; uint32_t m;
    occupied(sim->dbg0_valid_way0, sim->dbg0_mesi_way0, sim->dbg0_valid_way1, sim->dbg0_mesi_way1, v, m);
    check(v && m == MESI_E, "L1-0 queda en E tras el miss (nadie más la tenia)");
  } else {
    check(false, "L1-0 read addr0 respondio");
  }

  // ------------------------------------------------------------------
  // Escenario 2: L1-1 hace miss de lectura sobre addr0. L1-0 SI la
  // tiene (en E) -> el bus reporta hit=1 -> L1-1 llena como S, y L1-0
  // se entera por su lado snooper y baja de E a S (mismo mecanismo ya
  // probado en aislamiento en A-6, ahora disparado por el bus real).
  // ------------------------------------------------------------------
  if (do_read1(sim, ticks, st0, st1, mem, kAddr0, 2, rdata, "L1-1 read addr0 (I->S, remoto en E)")) {
    bool v1; uint32_t m1;
    occupied(sim->dbg1_valid_way0, sim->dbg1_mesi_way0, sim->dbg1_valid_way1, sim->dbg1_mesi_way1, v1, m1);
    check(v1 && m1 == MESI_S, "L1-1 queda en S (el bus reporto hit remoto)");
    bool v0; uint32_t m0;
    occupied(sim->dbg0_valid_way0, sim->dbg0_mesi_way0, sim->dbg0_valid_way1, sim->dbg0_mesi_way1, v0, m0);
    check(v0 && m0 == MESI_S, "L1-0 bajo de E a S via el snoop bus real");
  } else {
    check(false, "L1-1 read addr0 respondio");
  }

  // ------------------------------------------------------------------
  // Escenario 3: L1-0 escribe addr0 (la tiene en S) -> upgrade: hace
  // falta invalidar a L1-1 antes de subir a M.
  // ------------------------------------------------------------------
  const uint32_t kDataUpg = 0x12345678;
  if (do_write0(sim, ticks, st0, st1, mem, kAddr0, kDataUpg, 3, "L1-0 write addr0 (upgrade S->M)")) {
    bool v0; uint32_t m0;
    occupied(sim->dbg0_valid_way0, sim->dbg0_mesi_way0, sim->dbg0_valid_way1, sim->dbg0_mesi_way1, v0, m0);
    check(v0 && m0 == MESI_M, "L1-0 sube a M tras el upgrade");
    bool v1; uint32_t m1;
    occupied(sim->dbg1_valid_way0, sim->dbg1_mesi_way0, sim->dbg1_valid_way1, sim->dbg1_mesi_way1, v1, m1);
    check(!v1, "L1-1 quedo invalidada por el upgrade");
  } else {
    check(false, "L1-0 write addr0 (upgrade) respondio");
  }

  // ------------------------------------------------------------------
  // Escenario 4: L1-1 vuelve a leer addr0 (ahora es un miss, se invalido
  // en el paso anterior). L1-0 la tiene en M -> flush (vuelca kDataUpg a
  // la memoria compartida) + share -> L1-0 termina en S, L1-1 llena en S
  // con el dato YA actualizado por el flush -- confirma que los datos
  // realmente viajan por mem_bus_if de punta a punta a través del bus.
  // ------------------------------------------------------------------
  if (do_read1(sim, ticks, st0, st1, mem, kAddr0, 4, rdata, "L1-1 read addr0 (I->S, remoto en M: flush)")) {
    check(rdata == kDataUpg, "L1-1 leyo el dato flusheado por L1-0, no basura vieja");
    bool v1; uint32_t m1;
    occupied(sim->dbg1_valid_way0, sim->dbg1_mesi_way0, sim->dbg1_valid_way1, sim->dbg1_mesi_way1, v1, m1);
    check(v1 && m1 == MESI_S, "L1-1 queda en S");
    bool v0; uint32_t m0;
    occupied(sim->dbg0_valid_way0, sim->dbg0_mesi_way0, sim->dbg0_valid_way1, sim->dbg0_mesi_way1, v0, m0);
    check(v0 && m0 == MESI_S, "L1-0 bajo de M a S tras el flush+share");
  } else {
    check(false, "L1-1 read addr0 (flush) respondio");
  }

  // ------------------------------------------------------------------
  // Escenario 5 (arbitraje bajo contencion): reset limpio, L1-0 arranca
  // un miss de escritura, y unos ciclos despues (con L1-0 ya arbitrado y
  // en camino, no en el mismo ciclo) L1-1 pide otro miss de escritura
  // sobre una direccion distinta. El arbitro tiene que atender la
  // segunda consulta aunque la primera siga en curso, sin cruzar las
  // respuestas. (El caso de pedirlos EXACTAMENTE al mismo ciclo -- que
  // antes de A-8 quedaba bloqueado -- se prueba aparte en el escenario 6.)
  // ------------------------------------------------------------------
  ticks = sim.reset(ticks);
  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;
  st0 = MemPortState();
  st1 = MemPortState();
  mem.clear();

  const uint32_t kAddrA = 4;  // tag=1, set=0
  const uint32_t kAddrB = 2;  // tag=0, set=1 (set distinto de kAddrA)
  const uint32_t kDataA = 0xAAAA1111;
  const uint32_t kDataB = 0xBBBB2222;

  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 1;
  sim->core0_req_addr   = kAddrA;
  sim->core0_req_data   = kDataA;
  sim->core0_req_byteen = 0xF;
  sim->core0_req_tag    = 5;

  std::printf("=== L1-0 y L1-1 piden en paralelo, desfasados (arbitraje bajo contencion) ===\n");
  bool got0 = false, got1 = false;
  bool l1_started = false;
  for (int i = 0; i < 200 && !(got0 && got1); ++i) {
    if (i == 3 && !l1_started) {
      // L1-0 ya salio de S_IDLE (aceptó su propia petición) -- recién
      // ahora arranca L1-1, para no competir por ser master el mismo ciclo.
      sim->core1_req_valid  = 1;
      sim->core1_req_rw     = 1;
      sim->core1_req_addr   = kAddrB;
      sim->core1_req_data   = kDataB;
      sim->core1_req_byteen = 0xF;
      sim->core1_req_tag    = 6;
      l1_started = true;
    }
    step_both_mem(sim, ticks, st0, st1, mem);
    if (sim->core0_rsp_valid) got0 = true;
    if (sim->core1_rsp_valid) got1 = true;
  }
  sim->core0_req_valid = 0;
  sim->core1_req_valid = 0;
  check(got0 && got1, "ambas escrituras (desfasadas) respondieron");

  uint32_t back0 = 0, back1 = 0;
  bool ok0 = do_read0(sim, ticks, st0, st1, mem, kAddrA, 7, back0, "L1-0 relee addr A");
  bool ok1 = do_read1(sim, ticks, st0, st1, mem, kAddrB, 8, back1, "L1-1 relee addr B");
  check(ok0 && back0 == kDataA, "L1-0 recupera su propio dato (A), sin cruzarse con B");
  check(ok1 && back1 == kDataB, "L1-1 recupera su propio dato (B), sin cruzarse con A");

  // ------------------------------------------------------------------
  // Escenario 6 (A-8): invalidacion concurrente con miss propio -- el
  // caso que antes de separar las FSM (l1_cache.sv: `state` vs
  // `snp_state`) quedaba bloqueado. Los dos L1 piden un miss de escritura
  // sobre direcciones DISTINTAS exactamente en el mismo ciclo: cada uno
  // entra a su propia consulta (S_SNOOP_QUERY) a la vez, así que cada uno
  // tiene que poder responderle al otro mientras espera su propio turno
  // del arbitro. Antes de A-8 esto colgaba (nunca respondia, ni con 200
  // ciclos de margen) porque atender un snoop remoto solo corria en
  // S_IDLE -- ninguno de los dos volvia a S_IDLE hasta terminar su propia
  // consulta, y ninguno podia terminar su propia consulta sin que el otro
  // respondiera. Con `snp_state` independiente, cada L1 puede responder
  // el snoop remoto (via snp_state) al mismo tiempo que espera el suyo
  // propio (via state) -- ver l1_cache.sv.
  // ------------------------------------------------------------------
  ticks = sim.reset(ticks);
  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;
  st0 = MemPortState();
  st1 = MemPortState();
  mem.clear();

  const uint32_t kAddrC = 6;  // tag=1, set=1 (distinto de A y B)
  const uint32_t kAddrD = 8;  // tag=2, set=0
  const uint32_t kDataC = 0xCCCC3333;
  const uint32_t kDataD = 0xDDDD4444;

  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 1;
  sim->core0_req_addr   = kAddrC;
  sim->core0_req_data   = kDataC;
  sim->core0_req_byteen = 0xF;
  sim->core0_req_tag    = 9;

  sim->core1_req_valid  = 1;
  sim->core1_req_rw     = 1;
  sim->core1_req_addr   = kAddrD;
  sim->core1_req_data   = kDataD;
  sim->core1_req_byteen = 0xF;
  sim->core1_req_tag    = 10;

  std::printf("=== L1-0 y L1-1 piden EXACTAMENTE el mismo ciclo (A-8: ex-deadlock) ===\n");
  bool got0c = false, got1c = false;
  for (int i = 0; i < 60 && !(got0c && got1c); ++i) {
    step_both_mem(sim, ticks, st0, st1, mem);
    if (sim->core0_rsp_valid) got0c = true;
    if (sim->core1_rsp_valid) got1c = true;
  }
  sim->core0_req_valid = 0;
  sim->core1_req_valid = 0;
  check(got0c && got1c, "ambas escrituras SIMULTANEAS respondieron (ya no hay deadlock cruzado)");

  uint32_t back0c = 0, back1c = 0;
  bool ok0c = do_read0(sim, ticks, st0, st1, mem, kAddrC, 11, back0c, "L1-0 relee addr C");
  bool ok1c = do_read1(sim, ticks, st0, st1, mem, kAddrD, 12, back1c, "L1-1 relee addr D");
  check(ok0c && back0c == kDataC, "L1-0 recupera su propio dato (C), sin cruzarse con D");
  check(ok1c && back1c == kDataD, "L1-1 recupera su propio dato (D), sin cruzarse con C");

  if (fails) {
    std::printf("snoop_bus arbitration test: FAILED (%d fallo(s))\n", fails);
    return 1;
  }
  std::printf("snoop_bus arbitration test: PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
