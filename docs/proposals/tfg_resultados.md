# 4. Resultados obtenidos hasta ahora

Compilación de todos los resultados cuantitativos/cualitativos
producidos por este TFG hasta la fecha, con referencia al documento de
detalle de cada uno. Las secciones marcadas `[PENDIENTE]` son
resultados que el plan de trabajo contempla pero que todavía no existen
— se deja el placeholder con la forma exacta que va a tener el dato
para no reestructurar el documento cuando lleguen.

## 4.1. Descripción del proceso de solución

El trabajo se dividió en fases secuenciales, cada una cerrada y
verificada (pruebas unitarias + punta a punta) antes de empezar la
siguiente.

1. **Diseño del protocolo MESI (A-6/A-7/A-8).** Tabla de transiciones
   completa, interconexión `VX_snoop_bus_if`, y las dos FSM
   independientes (lado dueño/lado snooper) que necesita `l1_cache.sv`
   para poder atender su propio núcleo y responder a snoops de otros
   núcleos a la vez (`tfg_mesi_coherence_design.md §1-§9`). Esta fase
   encontró y cerró, en el momento, dos bugs de timing propios del
   diseño de la FSM (no de integración): uno en el lado snooper
   (`tfg_mesi_coherence_design.md §7`) y uno en el camino de
   `snoop_bus.sv` donde un snoop sin match local se quedaba sin
   contestar (`§8.2`).

2. **Fase A — reemplazo de `VX_cluster.sv`.** Se construyó
   `tfg_cluster.sv` con el mismo contrato externo que `VX_cluster.sv`
   (mismas interfaces DCR/KMU/mem), wireando `l1_cache.sv` (x`NUM_CORES`)
   + `snoop_bus.sv` + `l2_cache.sv` detrás de un macro opt-in
   (`` `TFG_USE_CUSTOM_CLUSTER ``), de forma que el resto de Vortex
   queda sin cambios de comportamiento sin el flag
   (`tfg_fase_a_tfg_cluster.md`).

3. **Fase B — empalme en `Vortex.sv`.** Integración real en el loop de
   clusters de Vortex. El primer intento de correr de punta a punta
   colgaba por dos bugs reales (una FSM del TFG esperando un ack que
   nunca llegaba, en dos límites distintos de `core_bus_if`/`mem_bus_if`),
   y faltaba por completo el mecanismo de flush de dos niveles al
   terminar el kernel. Cerrado con `diverge -n16` pasando con 0 errores
   (`tfg_fase_b_integration_blocker.md`).

4. **Pruebas unitarias por capa (A-10, A-14, A-16, A-17).** `l1_cache`,
   `l2_cache`, `compute_unit` (4 núcleos reales + L2 compartida) y la
   integración L1→L2 (`l1_l2_coherence`), cada una con su propio
   testbench aislado. A-17 encontró un bug real de coherencia en la
   integración que A-10/A-16 por separado no podían exponer
   (`tfg_l1_l2_coherence_a17.md §3`) — confirmando que la verificación
   por capa aislada no sustituye la de integración.

5. **Baseline round-robin para medir qué aporta/cuesta la jerarquía.**
   Se construyó `tfg_cluster_baseline.sv`, mismo contrato externo que
   `tfg_cluster.sv` pero sin ningún nivel de caché ni coherencia —
   permite aislar el costo/beneficio de la jerarquía MESI corriendo el
   mismo kernel con los dos clusters. Al correrlo con `sgemm` (kernel
   con reuso real entre núcleos, a diferencia de `diverge`) la
   jerarquía real expuso **70/256 resultados en poison** — investigado
   con trazas hasta la causa raíz: dos condiciones de carrera reales
   que `diverge` nunca ejercitaba lo bastante para volverlas visibles.
   Cerradas con `line_lock.sv` (miss concurrente entre núcleos sobre la
   misma línea, `tfg_mesi_coherence_design.md §9.6`) y
   `local_snoop_conflict` (write-hit local vs. snoop en vuelo en el
   mismo ciclo, `§9.4`). Verificado después: `sgemm`/`diverge` con 0
   errores y las 6 suites unitarias sin regresión
   (`tfg_cluster_baseline_comparison.md §6`).

6. **Fase C — síntesis fuera de contexto (`hw/syn/xilinx/dut`).**
   Síntesis real del DUT aislado (sin el shell de la plataforma) contra
   la parte del Alveo U55C, misma config de núcleo que la Fase B/A-14,
   comparando PPA de la jerarquía MESI contra el baseline round-robin.
   Expuso que la jerarquía MESI no cierra timing a 300 MHz; el análisis
   de los dos caminos críticos (`report_timing -nworst 100`) identificó
   la causa exacta: decisiones de coherencia completas calculadas
   combinacionalmente en un solo ciclo con entradas cruzando
   módulo/núcleo (`tfg_hierarchy_spec.md §5-6`).

7. **Integración de bitstream completo contra la plataforma Vitis/XRT.**
   A diferencia de la Fase C (DUT aislado), este flujo integra
   `tfg_cluster.sv` dentro del AFU completo contra el shell DFX real del
   U55C, para poder correr workloads en hardware. En el proceso se
   encontraron y corrigieron, en orden: (a) el entorno Xilinx no se
   hereda en una sesión nueva de `tmux`; (b) un stub de IP de FPU
   (`xil_fma`) que el *gate* de elaboración necesita y que
   `generate_target all` no producía de forma confiable en todos los
   hosts — corregido en la causa raíz agregando `synth_ip [get_ips]`
   explícito en `hw/scripts/xilinx_ip_gen.tcl` (commit `ddd8f7c37`); y
   (c) un conflicto de ruteo post-route en el límite de SLR (registros
   Laguna, `axi_regslice_slr0`, contra nets de la plataforma,
   `axi_data_sc`) — primera vez que place & route terminan
   exitosamente de punta a punta, todavía sin resolver. Detalle
   completo de cada intento: §4.2.4.

## 4.2. Análisis de los resultados obtenidos

### 4.2.1. Funcionalidad — jerarquía L1+L2 MESI (`tfg_cluster.sv`)

**Estado: CERRADO y verificado end-to-end.**

| Hito | Resultado | Detalle |
|---|---|---|
| Fase A — reemplazo de `VX_cluster.sv` | CERRADO | `tfg_cluster_baseline_comparison.md`, `tfg_fase_a_tfg_cluster.md` |
| Fase B — empalme en `Vortex.sv`, hang original | CERRADO, 0 errores (`diverge -n16`) | `tfg_fase_b_integration_blocker.md` |
| A-15 — soporte de prefetch hacia L2 | DESCARTADO (fuera de alcance) | `tfg_prefetch_design.md` |

Pruebas unitarias:

| Test | Resultado |
|---|---|
| `l1_cache` (A-10) | PASSED (224 ticks) |
| `l2_cache` (A-16) | PASSED (86 ticks) |
| `l1_l2_coherence` (A-17) | PASSED (124 ticks) |
| `compute_unit` (A-14) | PASSED (402 ticks) |
| `snoop_bus` | PASSED |
| `line_lock` | PASSED |

Las 6 suites pasan sin regresión tras cada fix aplicado durante el TFG
(`tfg_mesi_coherence_design.md §9.7`). Las dos carreras de coherencia
reales (§4.1, punto 5) fueron expuestas por un patrón de acceso con
reuso real entre núcleos, no por los kernels write-mostly de fases
tempranas — la lectura es que la cobertura funcional lograda es
correcta para el alcance ejercitado, no una prueba de ausencia general
de carreras fuera de ese alcance.

### 4.2.2. Rendimiento funcional — jerarquía MESI vs. baseline round-robin

**Estado: CERRADO.** Fuente: `tfg_cluster_baseline_comparison.md`.
Misma config de núcleo en las dos corridas (`NUM_CORES=4, NUM_WARPS=4,
NUM_THREADS=2, SOCKET_SIZE=4, PLATFORM_MEMORY_NUM_BANKS=1`), driver
`rtlsim`.

| Kernel | Patrón de acceso | Jerarquía MESI | Baseline round-robin | Ganador |
|---|---|---:|---:|---|
| `diverge -n16` | write-mostly, sin reuso | 10,648,427 ciclos / IPC 0.182 | 6,393,602 ciclos / IPC 0.304 | Baseline (~40% más rápido) |
| `sgemm -n16` | reuso real cross-core | 15,582 ciclos / IPC 0.982 | 73,880 ciclos / IPC 0.207 | Jerarquía (~4.7x más rápida) |

(La fila de `sgemm` del baseline usa la corrida real con
`TFG_USE_BASELINE_CLUSTER` — una versión anterior de esta tabla repetía
por error el número de `diverge`, que corresponde a otro kernel. Ver
`tfg_cluster_baseline_comparison.md §6` para el comando exacto.)

Lectura: la jerarquía de coherencia paga dividendos solo cuando el
kernel tiene reuso real entre núcleos; en un patrón write-once paga el
costo fijo de consulta-antes-de-miss y de flush de cola sin
recuperarlo en hits.

**Desglose de ciclos por fuente (snoop vs. flush vs. tráfico normal)**
`[PENDIENTE]` — instrumentación `` `TRACE `` ya existe en el código
(`tfg_cluster_baseline_comparison.md §5`); falta correrla y tabular.

| Kernel | % ciclos en consulta de snoop | % ciclos en flush de cola | % ciclos en tráfico normal L1↔L2 |
|---|---:|---:|---:|
| `diverge -n16` | `[PENDIENTE]` | `[PENDIENTE]` | `[PENDIENTE]` |
| `sgemm -n16` | `[PENDIENTE]` | `[PENDIENTE]` | `[PENDIENTE]` |

**Roofline (`ci/roofline.py`)** `[PENDIENTE]` — no corrido todavía para
esta jerarquía. Falta: FLOP/ciclo medido, `--peak-flops` usado, imagen
del plot.

| Kernel | FLOPs | Ciclos | FLOP/ciclo medido | Techo de cómputo usado |
|---|---:|---:|---:|---:|
| `sgemm` | `[PENDIENTE]` | `[PENDIENTE]` | `[PENDIENTE]` | `[PENDIENTE]` |

### 4.2.3. PPA — síntesis fuera de contexto (Fase C, `hw/syn/xilinx/dut`)

**Estado: CERRADO.** Fuente: `tfg_hierarchy_spec.md §5-6`. Config:
`NUM_CORES=4, NUM_WARPS=4, NUM_THREADS=2, SOCKET_SIZE=4,
PLATFORM_MEMORY_NUM_BANKS=1`, `DEVICE=xcu55c-fsvh2892-2L-e`,
`OPT_LEVEL=3`, reloj objetivo 300 MHz (3.333 ns).

| Métrica | Jerarquía MESI (TFG) | Baseline round-robin |
|---|---:|---:|
| Fmax | 178.6 MHz | 304.1 MHz |
| WNS | −2.266 ns (timing no cumplido) | +0.045 ns (timing cumplido) |
| LUT | 198,857 | 81,827 |
| FF | 133,333 | 78,308 |
| BRAM | 42 | 42 |
| DSP | 48 | 48 |
| Tiempo de build | 2h 17m | 41m |

Los dos caminos críticos de la jerarquía MESI (slack −2.266 ns ambos)
están dominados por ruteo cruzando módulos (73–82% del delay):
`snoop_set_r`→árbitro L2→`state_reg` combinacional, y
`snoop_bus.addr_r`→`tag_array[...].mesi.CE` combinacional. El análisis
descarta que sea un artefacto de colocación: es una propiedad del
diseño actual de la FSM MESI (decisión de coherencia completa en un
solo ciclo, sin registro de por medio, con entradas cruzando
módulo/núcleo). Las dos mitigaciones de pipeline propuestas
(`tfg_hierarchy_spec.md §6`) no están aplicadas todavía — requieren
actualización equivalente de `model_parity` en SimX.

**Impacto de registrar los dos caminos críticos propuestos**
`[PENDIENTE]` — depende de implementar las dos mitigaciones de
`tfg_hierarchy_spec.md §6` y su actualización equivalente de SimX.

| Métrica | Antes (actual) | Después `[PENDIENTE]` |
|---|---:|---:|
| Fmax | 178.6 MHz | `[PENDIENTE]` |
| WNS | −2.266 ns | `[PENDIENTE]` |
| Ciclos añadidos por resolución de snoop | 0 extra | `[PENDIENTE]` |

### 4.2.4. Bitstream completo e integración en plataforma Vitis/XRT (U55C)

**Estado: EN PROGRESO, bloqueado.** A diferencia de la síntesis fuera
de contexto de la §4.2.3 (DUT aislado, sin el shell de la plataforma),
este flujo (`hw/syn/xilinx/xrt`) integra `tfg_cluster.sv` dentro del
AFU completo contra el shell DFX real del Alveo U55C
(`xilinx_u55c_gen3x16_xdma_3_202210_1`), para poder correr workloads
reales en hardware (`ci/blackbox.sh --driver=xrt`).

Intentos de build y resultado de cada uno:

| # | Host | `IMPL_STRATEGY` | `KERNEL_FREQ` | Resultado | Tiempo hasta la falla |
|---|---|---|---:|---|---:|
| 1 | `hacc-u55c-11` | `Congestion_SSI_SpreadLogic_high` | 300 (default) | Terminado — expiró la ventana de acceso (~5h), nunca llegó a `route_design` | ~5h |
| 2 | `hacc-u55c-11` | default | 300 (default) | Terminado durante síntesis a nivel de bloque (150/153 jobs), con `MAX_JOBS=32` | — |
| 3 | `hacc-build-01` | — | — | `xil_fma` no encontrado (bug de stub de IP, ver §4.1 punto 7) — corregido | minutos (gate de elaboración, antes de implementación) |
| 4 | `hacc-build-01` | `Congestion_SSI_SpreadLogic_high` | 200 | **Place & route completos por primera vez** — falla en verificación post-route: `ERROR: [VPL 18-1000] Routing results verification failed due to partially-conflicted nets` (registros Laguna de cruce de SLR, `axi_regslice_slr0`, en conflicto con nets de la plataforma, `axi_data_sc`) | 8h 07m |
| 5 | `hacc-build-02` (`PREFIX=tfg2`) | default (sin override) | 200 | Falla con el mismo error que el intento 4: `ERROR: [VPL 18-1000] Routing results verification failed due to partially-conflicted nets` (ahora en `axi_regslice_slr0`/`axi_data_sc`, mismo patrón de cruce de SLR vía registros Laguna). Descarta `KERNEL_FREQ=200` como causa — el conflicto persiste con `IMPL_STRATEGY` default, así que la causa raíz es la estrategia de ruteo bajo congestión en el límite de SLR, no la frecuencia | ~9h 56m |
| 6 | `hacc-build-02` (`PREFIX=tfg3`) | default (sin override) | 200 | Diagnóstico: mismo build que el intento 5 pero con `NUM_CORES=2` en vez de 4. Falla con el **mismo error, en los mismos nets** (`axi_data_sc/m00_exit_pipeline/m00_exit`, `axi_regslice_slr0`) — **descarta la hipótesis de capacidad/tamaño de cluster**: el conflicto no escala con la densidad lógica de `tfg_cluster.sv`, aparece igual con la mitad del cluster. Reorienta la causa raíz hacia el crossbar AXI generado por la plataforma (fan-out a 32 canales HBM) como problemático en sí mismo con este shell/versión de Vitis, independiente del diseño del kernel | ~10h 55m |

**Hipótesis de capacidad del cluster — descartada por el intento 6**
(mismo error, mismos nets, con `NUM_CORES=2` que con 4): el conflicto
no escala con la densidad lógica de `tfg_cluster.sv`.

**Causa raíz corroborada — fan-out a 32 canales HBM sin floorplanning
SLR-aware:** `--connectivity.sp vortex_afu_1.m_axi_mem_0:HBM[0:31]`
(`platforms.mk:25`, vía `PLATFORM_MERGED_MEMORY_INTERFACE`) es la
config estándar de Vortex upstream (idéntica en `u50`/`u280`), por lo
que no es un error de configuración — pero reportes de la comunidad de
AMD confirman que es un trade-off conocido específicamente en el U55C:
usar muchos canales HBM en un diseño que cruza las 3 SLR sin pblocks
explícitos produce exactamente este tipo de conflicto de ruteo
(foro AMD, `owoiho420`/`guenselmann`, 2025 — diseño con 30 canales HBM
cruzando 3 SLR sin floorplanning, forzado a bajar a 150 MHz para
cumplir timing; la misma lógica confinada a una sola SLR corrió casi
al doble de frecuencia con los mismos canales). La guía oficial AMD es
`ug949-vivado-design-methodology` §"Designing with SSI Devices". Esto
no es un bug: es el costo conocido de usar ancho de banda HBM completo
en U55C sin floorplanning SLR-aware, documentado por AMD y confirmado
empíricamente por terceros con el mismo síntoma.

**`vortex_afu.xclbin`** `[PENDIENTE]` — no generado todavía. Ningún
intento llegó más allá de la verificación de ruteo post-route.

**Resultados de PPA del AFU completo (shell + `tfg_cluster.sv`)**
`[PENDIENTE]` — requiere un build exitoso. A diferencia de la tabla de
la §4.2.3 (DUT aislado), estos números incluyen el overhead real del
shell DFX de la plataforma.

| Métrica | Valor |
|---|---:|
| Fmax alcanzado | `[PENDIENTE]` |
| WNS | `[PENDIENTE]` |
| LUT / FF / BRAM / DSP (AFU completo) | `[PENDIENTE]` |
| Tiempo total de build | `[PENDIENTE]` |

### 4.2.5. Ejecución en hardware real (Alveo U55C)

**Estado: NO INICIADO** — bloqueado por §4.2.4. Requiere `scp` del
`.xclbin` de `hacc-build-01` de vuelta a `hacc-u55c-11` (única máquina
con la tarjeta física) y habilitar host-memory
(`xrt-smi configure --host-mem -d <BDF> --size 1G enable`), por
`docs/fpga_setup.md`.

| Kernel | Driver | Resultado | Ciclos/tiempo real medido |
|---|---|---|---:|
| `sgemm -n128` | `xrt` | `[PENDIENTE]` | `[PENDIENTE]` |
| `diverge -n16` | `xrt` | `[PENDIENTE]` | `[PENDIENTE]` |

**Comparación simx/rtlsim vs. hardware real** `[PENDIENTE]` — una vez
corrido en hardware, comparar contra los ciclos de simx/rtlsim de la
§4.2.2 para medir qué tan ajustado está el modelo de timing de SimX al
comportamiento real (más allá del gate `model_parity`, que solo
compara simx contra rtlsim, no contra hardware).
