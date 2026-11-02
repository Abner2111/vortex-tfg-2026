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
// TFG: A-14, 4 VX_core reales (cada uno con su propia l1_cache.sv, mismo
// splice que A-9) compartiendo UNA l2_cache.sv, coordinando coherencia
// entre sí vía snoop_bus.sv, y la L2 saliendo por el árbitro global real
// de Vortex (VX_mem_bus_arb) antes de llegar a "memoria" (mockeada acá).
//
// Mismo kernel mínimo y mismo programa de A-9 (1 CTA/1 warp/1 thread,
// RV32I hecho a mano) -- con las 4 L1 y la L2 recién creadas, el LOAD y
// el write-allocate del STORE faltan en L1 Y en L2 necesariamente (primer
// toque), así que el camino se ejercita completo sin direcciones
// especiales: núcleo -> L1 (miss) -> L2 (miss) -> VX_mem_bus_arb -> mock
// de "memoria" -> de vuelta.
//
// El reparto de CTAs es round-robin (VX_kmu_bus_arb) -- no se sabe de
// antemano qué núcleo ejecuta el único CTA del test, así que el chequeo
// final escanea los 4 (dbg_dst_found).
//
// El mock de "memoria" tiene que ECOAR el tag que recibe tal cual (no
// hardcodear 0): el árbitro global ensancha el tag en vuelo para poder
// enrutar la respuesta al banco correcto -- si el mock lo pisa, la
// respuesta se enruta mal.
//
// build: make CONFIGS="-DVX_CFG_NUM_THREADS=2 -DVX_CFG_NUM_WARPS=2"
// (DCACHE_NUM_REQS tiene que dar 1, igual que A-9).

#include "vl_simulator.h"
#include "VVX_compute_unit_top.h"
#include "VX_config.h"
#include "VX_types.h"
#include <array>
#include <cstdio>
#include <cstdint>
#include <unordered_map>

using Sim = vl_simulator<VVX_compute_unit_top>;

bool sim_trace_enabled() { return false; }

// ---- DCR ----
template <typename T>
static void write_dcr(vl_simulator<T> &sim, uint64_t &tick, int addr, int value) {
  sim->dcr_req_valid = 1;
  sim->dcr_req_rw    = 1;
  sim->dcr_req_addr  = addr;
  sim->dcr_req_data  = value;
  tick = sim.step(tick, 2);
  sim->dcr_req_valid = 0;
  sim->dcr_req_rw    = 0;
}

// ---- programa (idéntico a A-9, ver hw/unittest/core/main.cpp) ----
static const uint32_t kProgram[] = {
    0x000010b7,  // lui  x1, 1
    0x0000a103,  // lw   x2, 0(x1)
    0x000021b7,  // lui  x3, 2
    0x00110113,  // addi x2, x2, 1
    0x0021a023,  // sw   x2, 0(x3)
    0x0000000b,  // .insn r 0x0b,0,0,x0,x0,x0  (TMC x0)
};
static const uint32_t kProgramBase = 0x80;  // PC=0 es un centinela invalido en VX_fetch.sv
static const uint32_t kSrcAddr     = 0x1000;
static const uint32_t kDstAddr     = 0x2000;
static const uint32_t kSrcValue    = 0x41;  // -> mem[kDstAddr] esperado: 0x42

// ---- icache: sirve una instrucción de 4 bytes por pedido -- mismo
// contenido en las 4 (programa idéntico, solo lectura). ----
static void service_icache(uint8_t req_valid, uint32_t req_addr, uint32_t req_tag,
                            uint8_t &rsp_valid, uint32_t &rsp_data, uint32_t &rsp_tag) {
  if (req_valid) {
    uint32_t addr_bytes = req_addr << 2;  // ICACHE_WORD_SIZE=4, addr es de palabra
    uint32_t word = 0;
    if (addr_bytes >= kProgramBase) {
      size_t idx = (addr_bytes - kProgramBase) / 4;
      if (idx < sizeof(kProgram) / sizeof(kProgram[0]))
        word = kProgram[idx];
    }
    rsp_valid = 1;
    rsp_data  = word;
    rsp_tag   = req_tag;
  } else {
    rsp_valid = 0;
  }
}

// ---- "memoria" detrás del árbitro global: TFG_L1_LINE_SIZE=16 bytes
// (128 bits) -- más ancho que un escalar de 64 bits, Verilator expone el
// puerto como VlWide (array de palabras de 32 bits), igual que A-9. ----
using Line = std::array<uint32_t, 4>;
static constexpr uint32_t kLineSize = 16;  // bytes, debe calzar con TFG_L1_LINE_SIZE

enum { MEM_WAIT_REQ, MEM_DELAY, MEM_RESPONDING };

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Sim sim;
  uint64_t tick = 0;

  std::unordered_map<uint32_t, Line> mem;
  mem[kSrcAddr / kLineSize] = Line{kSrcValue, 0, 0, 0};

  int mem_phase = MEM_WAIT_REQ;
  uint32_t mem_cap_addr = 0;
  uint32_t mem_cap_tag  = 0;
  Line mem_cap_wdata{};
  bool mem_cap_rw = false;

  // Mismo motivo que A-9: vl_simulator::reset() solo sostiene 1 ciclo; el
  // driver real sostiene VX_CFG_RESET_DELAY ciclos y bombea otros tantos
  // despues de que reset baja.
  sim->reset = 1;
  for (int i = 0; i < VX_CFG_RESET_DELAY; ++i) tick = sim.step(tick, 2);
  sim->reset = 0;
  for (int i = 0; i < VX_CFG_RESET_DELAY; ++i) tick = sim.step(tick, 2);
  sim->start         = 0;
  sim->dcr_req_valid = 0;
  sim->dcr_req_rw    = 0;

  // Kernel mínimo: 1 CTA, 1 warp, 1 thread -- igual que A-9. El reparto a
  // cuál de los 4 núcleos le toca es responsabilidad de VX_kmu_bus_arb
  // (round-robin); no se fija nada especial acá.
  write_dcr(sim, tick, VX_DCR_KMU_STARTUP_ADDR0, kProgramBase);
  write_dcr(sim, tick, VX_DCR_KMU_KERNEL_ENTRY0, kProgramBase);
  write_dcr(sim, tick, VX_DCR_KMU_STARTUP_ARG0,  0);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_DIM_X,   1);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_DIM_Y,   1);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_DIM_Z,   1);
  write_dcr(sim, tick, VX_DCR_KMU_GRID_DIM_X,    1);
  write_dcr(sim, tick, VX_DCR_KMU_GRID_DIM_Y,    1);
  write_dcr(sim, tick, VX_DCR_KMU_GRID_DIM_Z,    1);
  write_dcr(sim, tick, VX_DCR_KMU_LMEM_SIZE,     0);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_SIZE,    1);
  write_dcr(sim, tick, VX_DCR_KMU_WARP_STEP_X,   VX_CFG_NUM_THREADS);
  write_dcr(sim, tick, VX_DCR_KMU_WARP_STEP_Y,   1);
  write_dcr(sim, tick, VX_DCR_KMU_WARP_STEP_Z,   1);
  write_dcr(sim, tick, VX_DCR_KMU_CLUSTER_DIM_X, 1);
  write_dcr(sim, tick, VX_DCR_KMU_CLUSTER_DIM_Y, 1);
  write_dcr(sim, tick, VX_DCR_KMU_CLUSTER_DIM_Z, 1);

  sim->start = 1;
  tick = sim.step(tick, 2);
  sim->start = 0;

  bool finished = false;
  const int kMaxCycles = 2000;
  const int kDrainCycles = 100;  // mismo motivo que A-9: drenar el store fire-and-forget
  int drain_until = -1;
  for (int i = 0; i < kMaxCycles; ++i) {
    uint8_t rv; uint32_t rd, rt;

    service_icache(sim->icache0_req_valid, sim->icache0_req_addr, sim->icache0_req_tag, rv, rd, rt);
    sim->icache0_req_ready = 1;
    sim->icache0_rsp_valid = rv; sim->icache0_rsp_data = rd; sim->icache0_rsp_tag = rt;

    service_icache(sim->icache1_req_valid, sim->icache1_req_addr, sim->icache1_req_tag, rv, rd, rt);
    sim->icache1_req_ready = 1;
    sim->icache1_rsp_valid = rv; sim->icache1_rsp_data = rd; sim->icache1_rsp_tag = rt;

    service_icache(sim->icache2_req_valid, sim->icache2_req_addr, sim->icache2_req_tag, rv, rd, rt);
    sim->icache2_req_ready = 1;
    sim->icache2_rsp_valid = rv; sim->icache2_rsp_data = rd; sim->icache2_rsp_tag = rt;

    service_icache(sim->icache3_req_valid, sim->icache3_req_addr, sim->icache3_req_tag, rv, rd, rt);
    sim->icache3_req_ready = 1;
    sim->icache3_rsp_valid = rv; sim->icache3_rsp_data = rd; sim->icache3_rsp_tag = rt;

    // mem_bus_if (post-arbitro global): mismo criterio de "decidir antes
    // de step()" que el resto del TFG.
    switch (mem_phase) {
      case MEM_WAIT_REQ:
        sim->mem_req_ready = 1;
        if (sim->mem_req_valid) {
          mem_cap_addr = sim->mem_req_addr;
          mem_cap_rw   = sim->mem_req_rw;
          mem_cap_tag  = sim->mem_req_tag;
          for (int w = 0; w < 4; ++w) mem_cap_wdata[w] = sim->mem_req_data[w];
          mem_phase = MEM_DELAY;
        }
        break;
      case MEM_DELAY: {
        sim->mem_req_ready = 0;
        if (mem_cap_rw) mem[mem_cap_addr] = mem_cap_wdata;
        auto it = mem.find(mem_cap_addr);
        Line rdata = (it != mem.end()) ? it->second : Line{0, 0, 0, 0};
        sim->mem_rsp_valid = 1;
        for (int w = 0; w < 4; ++w) sim->mem_rsp_data[w] = rdata[w];
        // Ecoar el tag tal cual -- el arbitro global lo ensancho para
        // poder enrutar esta respuesta al banco correcto; pisarlo (p.ej.
        // con 0) la enrutaria mal.
        sim->mem_rsp_tag = mem_cap_tag;
        mem_phase = MEM_RESPONDING;
        break;
      }
      case MEM_RESPONDING:
        sim->mem_rsp_valid = 0;
        mem_phase = MEM_WAIT_REQ;
        break;
    }

    tick = sim.step(tick, 2);

    if (!sim->busy) finished = true;
    if (finished && drain_until < 0) drain_until = i + kDrainCycles;
    if (finished && i >= drain_until) break;
  }

  if (!finished) {
    std::printf("FAIL: ningun nucleo bajo busy (colgado) despues de %d ciclos\n", kMaxCycles);
    return 1;
  }

  // Reparto round-robin: no se sabe de antemano cuál de los 4 nucleos
  // ejecuto el unico CTA -- escanear dbg_dst_found.
  int core_hit = -1;
  for (int c = 0; c < 4; ++c) {
    if ((sim->dbg_dst_found >> c) & 1) { core_hit = c; break; }
  }
  if (core_hit < 0) {
    std::printf("FAIL: ningun nucleo cacheo la linea destino (set=0 tag=2 para mem[0x%x])\n", kDstAddr);
    return 1;
  }
  if (!((sim->dbg_dst_dirty >> core_hit) & 1)) {
    std::printf("FAIL: nucleo%d tiene la linea destino pero no esta dirty (store no se aplico)\n", core_hit);
    return 1;
  }
  uint32_t got = (uint32_t)sim->dbg_dst_word0[core_hit];
  uint32_t expected = kSrcValue + 1;
  if (got != expected) {
    std::printf("FAIL: nucleo%d linea destino = 0x%x, esperado 0x%x\n", core_hit, got, expected);
    return 1;
  }

  std::printf("compute_unit end-to-end test: PASSED (nucleo%d dirty, mem[0x%x] = 0x%x, %lu ticks)\n",
              core_hit, kDstAddr, got, (unsigned long)tick);
  return 0;
}
