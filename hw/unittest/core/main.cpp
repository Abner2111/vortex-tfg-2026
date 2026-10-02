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
// TFG: A-9, un VX_core real (sin cache stock) con l1_cache.sv empalmada
// en el camino de datos (ver VX_core_top.sv). Arranca un kernel mínimo
// de 1 CTA / 1 warp / 1 thread (mismo mecanismo que
// hw/unittest/kmu/main.cpp: programar VX_DCR_KMU_* y pulsar `start`) que
// corre un puñado de instrucciones RV32I hechas a mano:
//
//   lui  x1, 1          # x1 = 0x1000            (dirección fuente)
//   lw   x2, 0(x1)      # x2 = mem[0x1000]
//   lui  x3, 2          # x3 = 0x2000            (dirección destino)
//   addi x2, x2, 1      # x2 += 1
//   sw   x2, 0(x3)      # mem[0x2000] = x2       (a través de la L1)
//   .insn r 0x0b,0,0,x0,x0,x0   # TMC x0 -- termina el warp
//
// Codificaciones verificadas con el ensamblador real del toolchain
// (riscv32-unknown-elf-as + objdump), no solo a mano.
//
// STATUS (A-9, pausado -- ver docs/proposals/tfg_core_integration_progress.md):
// confirmado con los debug taps de VX_core_top.sv (dbg_active_warps,
// dbg_lsu_*): el fetch, el LOAD y el despacho del STORE desde el LSU
// funcionan -- el STORE incluso dispara correctamente el write-allocate
// read de l1_cache.sv. Pero la corrida completa termina golpeando una
// aserción real DENTRO de VX_mem_coalescer/VX_allocator (código de
// Vortex, no del TFG) -- "releasing invalid addr 0". No se investigó la
// causa raíz todavía (¿bug latente de Vortex bajo esta config reducida,
// o timing de respuesta de este mock distinto al de la caché real?).
// Este test por ahora NO PASA de punta a punta -- se deja documentado y
// buildable para retomar.
//
// build: make CONFIGS="-DVX_CFG_NUM_THREADS=2 -DVX_CFG_NUM_WARPS=2"
// (DCACHE_NUM_REQS tiene que dar 1 para esta config -- ver el chequeo de
// elaboración g_check_num_reqs en VX_core_top.sv).

#include "vl_simulator.h"
#include "VVX_core_top.h"
#include "VX_config.h"
#include "VX_types.h"
#include <array>
#include <cstdio>
#include <cstdint>
#include <unordered_map>

using Sim = vl_simulator<VVX_core_top>;

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

// ---- programa (ver comentario de arriba) ----
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

// ---- icache: sirve una instrucción de 4 bytes por pedido ----
static void service_icache(Sim &sim) {
  sim->icache_req_ready = 1;
  if (sim->icache_req_valid) {
    uint32_t addr_bytes = sim->icache_req_addr << 2;  // ICACHE_WORD_SIZE=4, addr es de palabra
    uint32_t word = 0;
    if (addr_bytes >= kProgramBase) {
      size_t idx = (addr_bytes - kProgramBase) / 4;
      if (idx < sizeof(kProgram) / sizeof(kProgram[0]))
        word = kProgram[idx];
    }
    sim->icache_rsp_valid = 1;
    sim->icache_rsp_data  = word;
    sim->icache_rsp_tag   = sim->icache_req_tag;
  } else {
    sim->icache_rsp_valid = 0;
  }
}

// ---- "memoria" detrás de la L1: TFG_L1_LINE_SIZE=16 bytes (128 bits) ----
// más ancho que un escalar de 64 bits -- Verilator expone el puerto como
// un array de palabras de 32 bits (WData/VlWide), así que la línea se
// maneja acá como 4 uint32_t, no como un entero simple.
using Line = std::array<uint32_t, 4>;
static constexpr uint32_t kLineSize = 16;  // bytes, debe calzar con TFG_L1_LINE_SIZE

enum { MEM_WAIT_REQ, MEM_DELAY, MEM_RESPONDING };

template <typename T>
static void service_dcache_mem(vl_simulator<T> &sim, std::unordered_map<uint32_t, Line> &mem,
                                int &phase, uint32_t &cap_addr, Line &cap_wdata, bool &cap_rw) {
  switch (phase) {
    case MEM_WAIT_REQ:
      sim->dcache_req_ready = 1;
      if (sim->dcache_req_valid) {
        cap_addr = sim->dcache_req_addr;
        cap_rw   = sim->dcache_req_rw;
        for (int w = 0; w < 4; ++w) cap_wdata[w] = sim->dcache_req_data[w];
        phase = MEM_DELAY;
      }
      break;
    case MEM_DELAY: {
      sim->dcache_req_ready = 0;
      if (cap_rw) mem[cap_addr] = cap_wdata;
      auto it = mem.find(cap_addr);
      Line rdata = (it != mem.end()) ? it->second : Line{0, 0, 0, 0};
      sim->dcache_rsp_valid = 1;
      for (int w = 0; w < 4; ++w) sim->dcache_rsp_data[w] = rdata[w];
      sim->dcache_rsp_tag = 0;
      phase = MEM_RESPONDING;
      break;
    }
    case MEM_RESPONDING:
      sim->dcache_rsp_valid = 0;
      phase = MEM_WAIT_REQ;
      break;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Sim sim;
  uint64_t tick = 0;

  // Memoria "detrás" de la L1: precarga la línea que contiene kSrcAddr.
  // kSrcAddr=0x1000 ya está alineado a kLineSize (16), así que la palabra
  // fuente cae en el offset 0 de esa línea.
  std::unordered_map<uint32_t, Line> mem;
  mem[kSrcAddr / kLineSize] = Line{kSrcValue, 0, 0, 0};

  int mem_phase = MEM_WAIT_REQ;
  uint32_t mem_cap_addr = 0;
  Line mem_cap_wdata{};
  bool mem_cap_rw = false;

  tick = sim.reset(tick);
  sim->start           = 0;
  sim->dcr_req_valid   = 0;
  sim->dcr_req_rw      = 0;
  sim->gbar_req_ready  = 1;
  sim->gbar_rsp_valid  = 0;

  // Kernel mínimo: 1 CTA, 1 warp, 1 thread -- ver comentario de arriba.
  write_dcr(sim, tick, VX_DCR_KMU_STARTUP_ADDR0, kProgramBase);
  write_dcr(sim, tick, VX_DCR_KMU_STARTUP_ARG0,  0);
  write_dcr(sim, tick, VX_DCR_KMU_GRID_DIM_X,    1);
  write_dcr(sim, tick, VX_DCR_KMU_GRID_DIM_Y,    1);
  write_dcr(sim, tick, VX_DCR_KMU_GRID_DIM_Z,    1);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_DIM_X,   1);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_DIM_Y,   1);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_DIM_Z,   1);
  write_dcr(sim, tick, VX_DCR_KMU_BLOCK_SIZE,    1);
  write_dcr(sim, tick, VX_DCR_KMU_WARP_STEP_X,   VX_CFG_NUM_THREADS);

  sim->start = 1;
  tick = sim.step(tick, 2);
  sim->start = 0;

  bool finished = false;
  const int kMaxCycles = 2000;
  // "busy" baja apenas el front-end/scheduler no tiene mas trabajo que
  // emitir -- un store ya despachado por el LSU (fire-and-forget, sin
  // writeback) puede seguir drenando hacia dcache_bus_if unos ciclos MAS
  // ALLA de eso (confirmado con dbg_lsu_mem_req_valid). Seguir sirviendo
  // el mock un rato extra despues de ver busy=0, en vez de cortar de
  // inmediato -- si no, el store nunca llega a completarse del lado del
  // mock aunque el core ya lo haya despachado.
  const int kDrainCycles = 100;
  int drain_until = -1;
  for (int i = 0; i < kMaxCycles; ++i) {
    service_icache(sim);
    service_dcache_mem(sim, mem, mem_phase, mem_cap_addr, mem_cap_wdata, mem_cap_rw);
    tick = sim.step(tick, 2);
    if (!sim->busy) finished = true;
    if (finished && drain_until < 0) drain_until = i + kDrainCycles;
    if (finished && i >= drain_until) break;
  }

  if (!finished) {
    std::printf("FAIL: el core nunca bajo busy (colgado) despues de %d ciclos\n", kMaxCycles);
    return 1;
  }

  auto it = mem.find(kDstAddr / kLineSize);
  if (it == mem.end()) {
    std::printf("FAIL: nunca se escribio la linea destino (mem[0x%x])\n", kDstAddr);
    return 1;
  }
  uint32_t got = it->second[0];  // kDstAddr tambien cae en offset 0 de su linea
  uint32_t expected = kSrcValue + 1;
  if (got != expected) {
    std::printf("FAIL: mem[0x%x] = 0x%x, esperado 0x%x\n", kDstAddr, got, expected);
    return 1;
  }

  std::printf("core+l1 end-to-end test: PASSED (mem[0x%x] = 0x%x, %lu ticks)\n",
              kDstAddr, got, (unsigned long)tick);
  return 0;
}
