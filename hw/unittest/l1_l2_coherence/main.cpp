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
// TFG: A-17, coherencia L1->L2 de punta a punta. Dos L1 reales +
// snoop_bus.sv real (coherencia L1<->L1, A-7/A-8, sin cambios) + l2_cache.sv
// REAL en el lugar donde hw/unittest/snoop_bus usaba un mock de "memoria"
// plano -- la pregunta que A-11/A-14 no probaban todavía: cuando una
// línea sucia de un L1 se vuelca (por snoop o por desalojo local), ¿llega
// bien a la L2 compartida? Y cuando el OTRO núcleo la relee, ¿la trae de
// L2 con el dato más reciente?
//
// Escenario A (el que pide A-17 literal): write-miss en core0 (I->M),
// read-miss en core1 dispara snoop sobre core0 (lo encuentra en M) ->
// core0 flushea (SNP_WB) a L2 real -> M->S -> core1 trae la línea YA
// con el dato fresco. Se verifica que el dato es el más reciente tanto
// para core1 (quien lo trajo de L2) como para core0 (quien lo sigue
// teniendo localmente en S).
//
// Escenario B (caso límite -- writeback SIN snoop): core0 fuerza su
// propio desalojo local (llena las 2 vías del set, dirty) -- un
// writeback derecho a L2 sin que el snoop bus intervenga. core1 lee esa
// misma línea después (su propio miss, nadie más la tiene) y la trae de
// L2. Prueba que L2 maneja bien las DOS vías de writeback (flush por
// snoop vs. desalojo local), no solo la que menciona A-17 textualmente.

#include "vl_simulator.h"
#include "VVX_l1_l2_top.h"
#include <cstdio>
#include <unordered_map>

using Sim = vl_simulator<VVX_l1_l2_top>;
// Lo que hay debajo de L2 mueve LINEAS completas (LINE_SIZE=8 bytes =
// 64 bits), no palabras de 32 -- distinto del lado core0/core1 (L1<->
// pipeline, WORD_SIZE=4). Verilator expone un puerto de 64 bits como
// QData (uint64_t).
using MemMap = std::unordered_map<uint32_t, uint64_t>;

enum MemPhase { WAIT_REQ, DELAY, RESPONDING };

struct MemPortState {
  MemPhase phase = WAIT_REQ;
  uint32_t cap_addr = 0;
  uint64_t cap_wdata = 0;
  bool cap_rw = false;
};

// Mismo criterio de "decidir antes de step()" que el resto del TFG. Esto
// mockea lo que hay DEBAJO de L2 (los dos bancos) -- no la memoria de
// cada L1 (eso ahora es la L2 real).
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

static void step_both_mem(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem) {
  service_mem_port(st0, sim->mem0_req_valid, sim->mem0_req_addr, sim->mem0_req_rw,
                    sim->mem0_req_data, sim->mem0_req_ready, sim->mem0_rsp_valid,
                    sim->mem0_rsp_data, sim->mem0_rsp_tag, mem);
  service_mem_port(st1, sim->mem1_req_valid, sim->mem1_req_addr, sim->mem1_req_rw,
                    sim->mem1_req_data, sim->mem1_req_ready, sim->mem1_rsp_valid,
                    sim->mem1_rsp_data, sim->mem1_rsp_tag, mem);
  ticks = sim.step(ticks, 2);
}

static bool do_write0(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                       uint32_t addr, uint32_t data, uint32_t tag, const char *label, int max_cycles = 60) {
  sim->core0_req_valid  = 1;
  sim->core0_req_rw     = 1;
  sim->core0_req_addr   = addr;
  sim->core0_req_data   = data;
  sim->core0_req_byteen = 0xF;
  sim->core0_req_tag    = tag;
  std::printf("=== %s ===\n", label);
  bool accepted = false, got = false;
  for (int i = 0; i < max_cycles && !got; ++i) {
    step_both_mem(sim, ticks, st0, st1, mem);
    if (!accepted) { if (!sim->core0_req_ready) accepted = true; }
    else if (sim->core0_req_ready) got = true;
  }
  sim->core0_req_valid = 0;
  return got;
}

static bool do_read0(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                      uint32_t addr, uint32_t tag, uint32_t &rsp_data, const char *label, int max_cycles = 60) {
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

static bool do_read1(Sim &sim, uint64_t &ticks, MemPortState &st0, MemPortState &st1, MemMap &mem,
                      uint32_t addr, uint32_t tag, uint32_t &rsp_data, const char *label, int max_cycles = 60) {
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

  // Direcciones (word): WORD_SIZE=4, LINE_SIZE=8 -> OFFSET_BITS=1;
  // CACHE_SIZE=32, NUM_WAYS=2 -> NUM_SETS=2 -> SET_BITS=1.
  // addr[0]=offset, addr[1]=set, addr[2:]=tag.
  const uint32_t kAddrX  = 0;   // set0, tag0
  const uint32_t kAddrY  = 4;   // set0, tag1 (2da vía del mismo set que X)
  const uint32_t kAddrY2 = 16;  // set0, tag4 (fuerza desalojo de Y en escenario B)

  // ------------------------------------------------------------------
  // Escenario A: write-miss en core0 (I->M), read-miss en core1 ->
  // dispara snoop -> core0 flushea a L2 (M->S) -> core1 trae de L2.
  // ------------------------------------------------------------------
  const uint32_t kDataX = 0xAAAA1111;

  bool ok = do_write0(sim, ticks, st0, st1, mem, kAddrX, kDataX, 1, "core0 write addrX (I->M, local)");
  check(ok, "core0 write addrX respondio");

  uint32_t rback = 0;
  ok = do_read1(sim, ticks, st0, st1, mem, kAddrX, 2, rback,
                "core1 read addrX (dispara snoop sobre core0 en M -> flush a L2 -> core1 trae de L2)",
                200);
  check(ok && rback == kDataX, "core1 trajo de L2 el dato mas reciente (el que escribio core0)");

  ok = do_read0(sim, ticks, st0, st1, mem, kAddrX, 3, rback,
                "core0 relee addrX (sigue en S localmente, no tuvo que ir a L2 de nuevo)");
  check(ok && rback == kDataX, "core0 ve el mismo dato mas reciente localmente (en S)");

  // ------------------------------------------------------------------
  // Escenario B (caso limite): writeback SIN snoop -- desalojo local.
  // ------------------------------------------------------------------
  ticks = sim.reset(ticks);
  sim->core0_rsp_ready = 1;
  sim->core1_rsp_ready = 1;
  st0 = MemPortState();
  st1 = MemPortState();
  mem.clear();

  const uint32_t kDataY  = 0xBBBB2222;
  const uint32_t kDataY2 = 0xCCCC3333;

  ok = do_write0(sim, ticks, st0, st1, mem, kAddrY, kDataY, 4, "core0 write addrY (llena via 0 del set)");
  check(ok, "core0 write addrY respondio");

  ok = do_write0(sim, ticks, st0, st1, mem, kAddrY2, kDataY2, 5,
                 "core0 write addrY2 (misma set, fuerza desalojo local de addrY -- writeback SIN snoop)");
  check(ok, "core0 write addrY2 (con desalojo local) respondio");

  ok = do_read1(sim, ticks, st0, st1, mem, kAddrY, 6, rback,
                "core1 read addrY (nadie mas la tiene -- miss puro, trae de L2 lo que el desalojo local volco)");
  check(ok && rback == kDataY, "core1 trajo de L2 el dato volcado por el desalojo local (writeback sin snoop)");

  if (fails) {
    std::printf("l1_l2_coherence test: FAILED (%d fallo(s))\n", fails);
    return 1;
  }
  std::printf("l1_l2_coherence test: PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
