# Diseño de la máquina de estados MESI por línea (A-6) + interconexión (A-7) + integración del snooping (A-8)

**Status: A-6, A-7 y A-8 implementados y probados end-to-end.** Este
documento cubre tres actividades del anteproyecto:
- **A-6**: diseñar la FSM MESI, modelar las 5 transiciones pedidas, y
  documentar la tabla completa para validarla contra A-11. Las 5
  transiciones (I→E, I→S, E→S, S→I, M→E) están implementadas en
  `l1_cache.sv` — lado snooper (§4, §7) y lado master (§4, §8).
- **A-7**: `snoop_bus.sv`, la interconexión entre L1 — arbitraje,
  propagación de invalidaciones/upgrades, señal de hit remoto, probado con
  2 `l1_cache` reales conectados. Ver §8.
- **A-8**: conectar `snoop_bus.sv` a la FSM MESI de forma que un L1 pueda
  atender un snoop remoto *mientras* tiene su propio miss/upgrade en
  vuelo — resuelve el deadlock cruzado que A-7 había dejado documentado
  como límite conocido. Ver §9.

Todo está probado: `hw/unittest/l1_cache` (un L1 aislado, snoop_bus_if
atado a mano) y `hw/unittest/snoop_bus` (2 L1 reales + el bus real,
incluyendo el escenario que antes colgaba). Queda una condición de carrera
residual mucho más angosta (colisión exacta de dirección entre un snoop
remoto y una operación local, no solo de timing) documentada en §9.4 — no
resuelta a propósito en esta pasada, ver por qué.

**Rama:** `l1_cache/a8-snoop-integration`, sobre `l1_cache/mesi_fsm`.

---

## 1. Decisiones de protocolo (para revisar con el asesor)

Antes de la tabla de transiciones, tres decisiones de diseño que
`VX_snoop_bus_if.sv` había dejado explícitamente pendientes:

**1. Los datos siempre viajan por `mem_bus_if`, nunca cache-a-cache.**
Cuando un snoop remoto encuentra la línea sucia (M) en este L1, este L1
hace su propio write-back a memoria (reutilizando el mecanismo de `S_WB`
que ya existe) — no le manda los datos directamente al L1 que preguntó por
`snoop_data`. El L1 que preguntó, después, trae la línea (ya limpia) de
memoria por su camino normal de miss. Es una simplificación deliberada:
más lento que una transferencia directa cache-a-cache, pero reutiliza el
camino de escritura que ya está probado, y no hay que arbitrar un segundo
camino de datos entre L1s.
`ponytail:` cache-a-cache directo si el TFG termina midiendo latencia de
coherencia y esto resulta ser el cuello de botella.

**2. El arbitraje entre varios L1 pidiendo snoop a la vez es responsabilidad
de `snoop_bus.sv` (A-7), no de `l1_cache.sv`.** Cada L1 expone un puerto
`master` (para publicar su propia petición) y un puerto `snooper` (para
responder a las de los demás) — es el bus el que decide a quién le toca
publicar cuando hay contención, no cada L1 individualmente.

**3. `M→E` no es un evento aislado — es la primera mitad de un remote-read
sobre una línea M.** En MESI de libro, un read remoto sobre M hace
flush + downgrade directo a S (M→S). Acá se parte esa transición en dos
pasos explícitos, que son justo los dos que pide A-6: `M→E` (el flush
completa, la línea queda limpia, todavía exclusiva por un instante) seguido
inmediatamente de `E→S` (se comparte con quien preguntó) — la misma lógica
de downgrade que ya hace falta para el caso de un read remoto sobre una
línea que ya estaba en E. Un remoto **write** sobre M sigue siendo
flush + invalidar directo (M→I, ver tabla) — no pasa por E, porque nadie va
a compartir la línea.

## 2. Tabla de transiciones completa

| Estado actual | Evento | Estado siguiente | Disparador | ¿Pedido explícitamente en A-6? |
|---|---|---|---|---|
| I | Miss de lectura local, snoop no encuentra la línea en nadie más | **E** | local (miss) + consulta al bus (S_SNOOP_QUERY) | ✅ I→E |
| I | Miss de lectura local, snoop encuentra la línea en otro L1 | **S** | local (miss) + consulta al bus | ✅ I→S |
| I | Miss de escritura local (write-allocate) | M | local (miss) + consulta al bus (invalidación) | — (ya existía el fill; la invalidación se agregó en A-7) |
| E | Write-hit local | M | local | — (upgrade silencioso, sin tráfico de bus) |
| E | Snoop remoto de lectura | **S** | remoto | — (mismo mecanismo que cierra M→E, ver más abajo) |
| E | Snoop remoto de escritura/upgrade | I | remoto | — (invalidar, sin flush, línea ya limpia) |
| S | Write-hit local | **M** | local + consulta al bus (invalidación, S_SNOOP_QUERY con is_upgrade_r) | — (implementado en A-7 junto con el puerto master) |
| S | Snoop remoto de escritura/upgrade | **I** | remoto | ✅ S→I |
| M | Snoop remoto de lectura — **paso 1: flush completa** | **E** | remoto | ✅ M→E |
| E (viniendo de M, mismo evento) | Snoop remoto de lectura — **paso 2: se comparte** | **S** | remoto | (cierra el M→S de libro, usando E→S) |
| M | Snoop remoto de escritura/upgrade | I | remoto | — (flush + invalidar directo, no pasa por E) |

Las filas marcadas ✅ son las 5 que A-6 pide modelar explícitamente — las
5 están implementadas y probadas. Las demás están documentadas porque el
protocolo no es consistente sin ellas (algunas, como el upgrade silencioso
E→M, ya existían desde A-5; la invalidación en un write-miss y el upgrade
S→M se completaron en A-7, ver §8).

### Diagrama

```
                    ┌─────────────────────────────────────────┐
                    │                                          │
        local RD miss, nadie tiene la línea                    │
                    │                                          │
                    ▼                                          │
        ┌───────┐  local RD miss, alguien la tiene   ┌───────┐ │
        │   I   │────────────────────────────────────▶   S   │ │
        └───┬───┘                                    └───┬───┘ │
            │  local WR miss                  snoop RD    │     │
            │  (write-allocate)                remoto      │ snoop WR
            ▼                                  (comparte)  │ remoto
        ┌───────┐                                          │ (invalida)
        │   M   │◀─── local WR-hit sobre S (upgrade) ───────┘
        └───┬───┘
            │  snoop RD remoto: paso 1, flush completa
            ▼
        ┌───────┐   local WR-hit          snoop RD remoto (comparte)
        │   E   │◀────────────── M   ────────────────────────▶  S
        └───┬───┘   (silencioso)         (mismo mecanismo E→S)
            │
            │  snoop WR remoto (invalida, sin flush)
            ▼
        ┌───────┐
        │   I   │
        └───────┘

  M --(snoop WR remoto: flush + invalidar, directo, no pasa por E)--> I
```

## 3. Formato de los campos de `VX_snoop_bus_if`

Sin cambios de ancho respecto al draft de A-4 — la decisión del §1.1
(siempre por memoria) significa que `snoop_data` queda definido en la
interfaz pero **sin uso real** en esta implementación (el snoopeado nunca
lo llena con datos válidos; solo usa `snoop_hit`/`snoop_state`/`snoop_dirty`
para que el requester sepa qué pasó). Se deja documentado así en vez de
sacar el campo, para no romper el contrato de la interfaz si A-7 o una
extensión futura decide sí usarlo.

## 4. Qué cambia en `l1_cache.sv`

Implementar la tabla de arriba en RTL necesita dos piezas nuevas, en lados
opuestos del módulo:

1. **Lado snooper (responder a los demás)** — hoy son ceros fijos
   (`snoop_bus_if.snoop_ready = 1'b0`, etc. al final del archivo). Hay que
   reemplazarlos por lógica real: al llegar `snoop_valid`, buscar la
   dirección en el tag array local, y según `snoop_rw` y el estado actual
   de esa línea, aplicar la transición que corresponda de la tabla —
   incluyendo, si está en M, hacer un flush real por `mem_bus_if` antes de
   contestar `snoop_ready`.

2. **Lado master (pedir snoop a los demás)** — hoy `l1_cache.sv` ni
   siquiera tiene un puerto para esto (solo tiene `snoop_bus_if.snooper`).
   Para que un miss local decida I→E vs. I→S hace falta agregar un puerto
   `VX_snoop_bus_if.master`, y meter un paso nuevo en la FSM de hit/miss
   (`S_IDLE` → nuevo estado de consulta de snoop → recién ahí
   `S_MISS_WAIT`), que hoy no existe.

**Implementado**: las dos piezas.
- **Lado snooper** — cubre M→E, E→S, S→I y las transiciones de soporte
  E→I, M→I, más el caso de un snoop que no encuentra la línea local
  (necesario para que el árbitro de A-7 no se quede esperando para
  siempre — ver §8). Probado en aislamiento con un testbench que emula
  "el otro L1" pidiendo snoops (ver §7 para el bug de timing que apareció
  al probarlo y cómo se resolvió).
- **Lado master** — puerto `VX_snoop_bus_if.master snoop_mst_if` y un
  estado nuevo, `S_SNOOP_QUERY`, que se mete antes de `S_MISS_WAIT` en
  todo miss local (decide I→E/I→S/I→M-con-invalidación según lo que
  responda el bus) y antes de `S_HIT` cuando un write-hit encuentra la
  línea en S (upgrade S→M, necesita invalidar a los demás primero). Ver
  §8 para el diseño de `snoop_bus.sv` contra el que se probó, y el test
  con 2 L1 reales (`hw/unittest/snoop_bus`) que lo verifica.

## 5. Relación con los objetivos del anteproyecto

| Este trabajo | Actividad |
|---|---|
| §1-2 (protocolo, tabla completa) | **A-6**: diseño de la FSM + tabla de transiciones para validar contra A-11. |
| Lado snooper implementado y probado (M→E, E→S, S→I + soporte) | **A-6**: modela las 5 transiciones pedidas en RTL real. |
| Lado master implementado y probado (I→E, I→S, I→M-invalidación, S→M-upgrade) | **A-6/A-7**: cierra I→E/I→S y el resto de la tabla del §2. |
| `snoop_bus.sv` (arbitraje, invalidación, upgrade, hit remoto) + test con 2 L1 reales | **A-7 completa**, ver §8. |
| §1.1 (decisión de no hacer cache-a-cache) | Confirmado en el diseño de `snoop_bus.sv` (§8): nunca transporta `snoop_data`. |

## 6. Pendientes

- Revisar esta tabla con el asesor antes de que A-11 la use como
  referencia para las pruebas de coherencia.
- Deadlock cruzado bajo contención simultánea (§8, "riesgo conocido") —
  evaluar si hace falta resolverlo (separar la FSM en dos: pedidos
  propios vs. responder snoops) antes de A-11, o si alcanza con
  documentarlo como límite del diseño actual.
- `snoop_bus.sv` sirve un solo broadcast a la vez (sin pipelining) —
  suficiente para probar coherencia funcional; si el TFG mide contención
  real del bus, revisar si hace falta un diseño con más solapamiento.
- Integrar `l1_cache.sv` + `snoop_bus.sv` en un core/cluster real de
  Vortex (A-9, fuera del alcance de A-6/A-7).

## 7. Bug de timing encontrado al probar el lado snooper (y su fix)

Al escribir el testbench (`hw/unittest/l1_cache/main.cpp`, `do_snoop()`) con
escenarios reales de remote-read/remote-write, apareció un bug real de RTL
(no del testbench) que vale la pena dejar documentado porque es el mismo
tipo de trampa que ya había aparecido con `data_rd_data`/write-back en A-5:
una carrera entre una escritura registrada y una lectura combinacional del
mismo dato en el mismo ciclo.

**El bug**: la primera versión resolvía un snoop sin flush (E/S) en el
mismo ciclo `S_IDLE` — `snoop_ready`/`snoop_hit`/`snoop_state`/
`snoop_dirty` se armaban con un `assign` que releía `tag_array` en vivo,
mientras que, en paralelo, otro `always_ff` escribía la transición (E→S,
E→I, S→I) sobre esa misma entrada. Dos problemas relacionados:

1. Cuando el snoop llegaba justo en el ciclo en que la FSM local recién
   volvía a `S_IDLE` desde otro estado (p. ej. `S_FILL`), la condición
   `state == S_IDLE` de la escritura usaba el valor de `state` *antes* del
   flanco (todavía no era `S_IDLE`), mientras que `snoop_ready` — un
   `assign` puramente combinacional — ya leía el valor *después* del
   flanco (ya `S_IDLE`). Resultado: `ready` se reportaba un ciclo antes de
   que la escritura realmente aplicara.
2. En régimen estable (sin ese desfase), la escritura sí aplicaba en el
   mismo ciclo — pero como el `assign` de la respuesta releía
   `tag_array[snoop_set][snoop_hit_way]` ya mutado (Verilator resuelve la
   lógica combinacional después de aplicar los NBA del mismo paso), a
   veces se reportaba el estado *posterior* a la transición en vez del que
   tenía la línea cuando llegó el snoop (por ejemplo, un remote-write que
   invalida la línea podía hacer que `snoop_hit` leyera 0, porque para
   cuando se releía `tag_array` la entrada ya estaba invalidada).

**El fix**: igual que `S_HIT` ya resuelve un hit local en un ciclo de
"reporte" separado (no combinacional en el mismo ciclo que decide el hit),
se agregaron dos estados equivalentes del lado snooper:
- `S_SNOOP_HIT`: para E/S sin flush. En `S_IDLE`, al decidir ir a
  `S_SNOOP_HIT`, se capturan `snoop_resp_mesi_r`/`snoop_resp_dirty_r` con
  el valor *de antes* de la transición (mismo ciclo, mismo `always_ff` que
  la transición, sin releer nada mutado). La respuesta en `S_SNOOP_HIT` usa
  esos registros, nunca `tag_array` en vivo.
- `S_SNOOP_DONE`: después de `S_SNOOP_POST_WB` (que aplica la escritura
  final E→S/E→I tras el flush). La respuesta ahí es un valor fijo (M,
  dirty=1 — lo que el que preguntó necesita saber), así que no hay carrera
  de lectura, pero igual hacía falta el ciclo extra para que `ready` no se
  adelantara a la escritura por el mismo motivo del punto 1.

Verificado con los 3 escenarios de `main.cpp` (I→E→S→I, M→E→S,
M→E→I) — ver la tabla del §2, todos con acceso directo a `tag_array` desde
el testbench (`dbg_mesi_way*`/`dbg_valid_way*` en `VX_l1_cache_top.sv`)
para confirmar el estado final sin depender de inferirlo por temporización.

## 8. Lado master + `snoop_bus.sv` (A-7)

### 8.1 Puerto master y `S_SNOOP_QUERY`

`l1_cache.sv` gana un segundo puerto, `VX_snoop_bus_if.master snoop_mst_if`
(el `snoop_bus_if` original queda como está, respondiendo a los demás).
Un estado nuevo, `S_SNOOP_QUERY`, se mete en dos puntos de la FSM
existente:

- **Antes de `S_MISS_WAIT`** (`S_IDLE` → `S_WB`* → `S_SNOOP_QUERY` →
  `S_MISS_WAIT`, *solo si la vía víctima estaba dirty): todo miss local
  consulta primero al bus con `snoop_mst_if.snoop_rw = req_rw_r`. Si el
  miss es de lectura, la respuesta (`snoop_hit`) decide I→E (nadie la
  tenía) vs. I→S (alguien la tenía — y, gracias al lado snooper ya
  probado en A-6, ese alguien ya se auto-degradó a S o hizo su propio
  flush antes de contestar, así que los datos que se van a leer de
  memoria en `S_MISS_WAIT` ya están al día). Si el miss es de escritura,
  la consulta funciona como invalidación (nadie necesita compartir una
  línea que se va a M) — el resultado de `hit` no importa, siempre I→M.
- **Antes de `S_HIT`, solo si hay upgrade**: un write-hit sobre una línea
  en S no puede subir a M en el mismo ciclo (otros L1 todavía la tienen
  compartida) — se desvía a `S_SNOOP_QUERY` (con `is_upgrade_r=1`,
  `snoop_mst_if.snoop_rw=1`) y recién cuando el bus confirma que invalidó
  a los demás se marca `dirty<=1, mesi<=M` y se sigue a `S_HIT` a servir
  la palabra. Un write-hit sobre E o M sigue siendo instantáneo (upgrade
  silencioso, sin tráfico de bus) — nadie más puede tener la línea.

`snoop_mst_if.snoop_valid` se mantiene en alto (nunca se relee después de
`step()`, mismo criterio que todo el archivo) hasta ver `snoop_ready` del
árbitro.

### 8.2 Bug encontrado en el camino: un snoop que no encuentra nada local se quedaba sin contestar

Al escribir el test de 2 L1 (§8.4) apareció que una consulta sobre una
dirección que este L1 NO tiene (`snoop_valid && !snoop_tag_hit`) nunca
hacía `snoop_ready=1` — la lógica de A-6 solo respondía cuando había un
**hit** local (`S_SNOOP_HIT`/`S_SNOOP_DONE`); un miss simplemente no
tocaba ninguno de esos estados. En el testbench aislado de A-6 esto nunca
se notó porque `main.cpp` siempre apuntaba a una dirección que el L1 sí
tenía cacheada. Con dos L1 reales, la primera consulta real (nadie tiene
la línea todavía) expone el problema: el árbitro espera `ready` para
siempre. Fix: un caso combinacional nuevo, sin estado extra —
`snoop_miss_resolve = (state==S_IDLE) && snoop_valid && !snoop_tag_hit`
responde `ready=1, hit=0` en el mismo ciclo (no hay nada que
transicionar, así que no hay riesgo de la carrera del §7).

### 8.3 `snoop_bus.sv`: diseño

Un árbitro simple, un solo broadcast en vuelo a la vez (`ponytail:`
documentado en el propio archivo — upgrade a un diseño con más
solapamiento si el TFG termina midiendo contención real del bus):

1. **BUS_IDLE**: prioridad fija entre los `NUM_L1` puertos `req_if` (la
   consulta propia de cada L1) — gana el índice más bajo con
   `snoop_valid`.
2. **BUS_BROADCAST**: le manda la consulta del ganador a **todos los
   demás** L1 (`rsp_if[j]` para `j != grant`) y espera a que **todos**
   respondan `ready`, acumulando el OR de sus `hit`. Cada `j` puede tardar
   un número distinto de ciclos (un miss local responde ya, un hit en M
   necesita el flush completo) — el árbitro simplemente espera al más
   lento.
3. **BUS_DONE**: le contesta al que preguntó (`req_if[grant]`):
   `ready=1, hit=OR acumulado`.

Nota de implementación: un array de interfaces (`VX_snoop_bus_if ... [N]`)
no se puede indexar con una variable en tiempo de ejecución en Verilator,
solo con `genvar` — el árbitro necesita indexar con `grant_idx` (una señal,
no una constante), así que los campos que hace falta leer así se
"aplanan" primero a arrays de señales planas (`req_valid_flat`,
`req_addr_flat`, etc.) con un `for (genvar ...)`, y esos sí se indexan con
la variable.

### 8.4 Riesgo conocido: deadlock cruzado bajo contención simultánea

Mientras un L1 está en `S_SNOOP_QUERY` (esperando que el árbitro le dé su
turno), **no puede** atender un snoop remoto — esa lógica solo corre en
`S_IDLE` (ver el `case` de la FSM). Si dos L1 entran a `S_SNOOP_QUERY` en
el mismo ciclo (cada uno queriendo consultar por su cuenta), cada uno
queda esperando que el árbitro lo atienda — pero el árbitro, al atender al
primero, necesita que el segundo (que está ocupado esperando su propio
turno) le conteste el broadcast. Ninguno avanza: deadlock cruzado.

Esto se **encontró en la práctica**: el primer diseño del test de
arbitraje (§8.5) hacía que los dos L1 pidieran al mismo tiempo direcciones
sin relación entre sí — y se colgaba (ni con 200 ciclos de margen
resolvía). No depende de que las direcciones coincidan; es puramente un
problema de *timing* (ambos queriendo ser master a la vez).

**No se resolvió en esta pasada** — resolverlo en general requiere
separar la FSM en dos (una para pedidos propios, otra para responder
snoops, cada una con su propio registro `state`) y, como consecuencia,
arbitrar `mem_bus_if` entre ambas (un snoop entrante en M necesita hacer
su propio flush por `mem_bus_if` incluso si la FSM "local" está ocupada
con su propio miss) — un cambio de arquitectura más grande que ameritaba
su propio análisis, no algo para meter de apuro junto con A-7. Queda
documentado acá y en `l1_cache.sv` (comentario de `S_SNOOP_QUERY`) como
límite conocido del diseño actual — a evaluar antes de A-11 si las
pruebas de coherencia necesitan contención real simultánea.

### 8.5 Test: `hw/unittest/snoop_bus` (2 `l1_cache` reales + `snoop_bus.sv`)

`VX_snoop_bus_top.sv` instancia 2 `l1_cache` (mismos parámetros chicos que
`hw/unittest/l1_cache`) conectados a un `snoop_bus` real, con `core0_*`/
`mem0_*` y `core1_*`/`mem1_*` expuestos como puertos planos. `mem0`/`mem1`
comparten el mismo modelo de memoria en `main.cpp` (un `unordered_map`),
como compartirían la L2 real. 5 escenarios, todos contra el bus real (no
mockeado):

1. L1-0 lee addr0 (miss, nadie más la tiene) → I→E.
2. L1-1 lee addr0 (L1-0 la tiene en E) → el bus reporta hit remoto → L1-1
   llena en S, y **L1-0 se entera por el bus real** y baja de E a S (el
   mismo mecanismo E→S de A-6, ahora disparado de punta a punta).
3. L1-0 escribe addr0 (la tiene en S) → upgrade: invalida a L1-1 antes de
   subir a M.
4. L1-1 vuelve a leer addr0 (ahora es miss, se invalidó en el paso 3) →
   L1-0 la tiene en M → flush (vuelca el dato a la memoria compartida) +
   share → L1-1 lee el dato **recién flusheado** (no basura vieja),
   ambos terminan en S.
5. Arbitraje bajo contención: L1-0 arranca un miss de escritura, y unos
   ciclos después (con L1-0 ya arbitrado, no en el mismo ciclo — ver
   §8.4) L1-1 pide otro miss de escritura sobre una dirección sin
   relación. Ambos deben resolver correctamente, sin que el árbitro cruce
   las respuestas — verificado releyendo desde cada L1 su propio dato.

`PASSED (96 ticks)`. Confirma, con hardware real de los dos lados (no un
mock), las transiciones E→S y M→E→S ya probadas en aislamiento en A-6, y
además el upgrade S→M, la invalidación en un write-miss, y el arbitraje
del §8.3 — todo de punta a punta.

## 9. Integrar el controlador de snooping en la FSM MESI (A-8)

### 9.1 El problema: una sola FSM no puede hacer las dos cosas a la vez

Hasta A-7, `l1_cache.sv` tenía **un solo registro `state`** manejando todo:
el camino local (pipeline ↔ L1 ↔ L2) y el camino de responder a snoops
remotos compartían la misma máquina de estados. Eso significaba que
mientras `state` estaba en `S_SNOOP_WB`/`S_SNOOP_POST_WB`/`S_SNOOP_HIT`/
`S_SNOOP_DONE` (respondiendo un snoop) o en `S_SNOOP_QUERY` (esperando el
turno del árbitro para SU PROPIA consulta), el L1 **no podía** hacer la
otra cosa — literal, el `case (state)` solo puede estar en un estado a la
vez.

El síntoma ya estaba documentado desde A-7 (§8.4, ahora obsoleto, ver
abajo): si dos L1 entraban a `S_SNOOP_QUERY` en el mismo ciclo (cada uno
queriendo consultar por su cuenta), cada uno quedaba esperando que el
árbitro lo atendiera — pero ninguno podía atender el snoop del otro
porque esa lógica solo corría en `S_IDLE`, y ninguno volvía a `S_IDLE`
hasta que el árbitro lo atendiera. Deadlock cruzado.

### 9.2 La solución: dos FSM independientes

`l1_cache.sv` ahora tiene dos registros de estado separados:

- **`state`** (`S_IDLE, S_HIT, S_WB, S_SNOOP_QUERY, S_MISS_WAIT, S_FILL`):
  el camino local, sin cambios de comportamiento respecto a A-7 salvo que
  ya no tiene los 4 estados de snoop mezclados adentro.
- **`snp_state`** (`SNP_IDLE, SNP_WB, SNP_POST_WB, SNP_HIT, SNP_DONE`):
  el camino de responder snoops remotos — es literalmente el mismo código
  que antes vivía dentro de `S_IDLE`/`S_SNOOP_WB`/etc., movido a su propio
  `always_ff`, corriendo en paralelo.

Las dos corren **todos los ciclos, simultáneamente**, cada una en su
propio `case`. Esto es lo que resuelve el deadlock: mientras `state` está
en `S_SNOOP_QUERY` esperando su propio turno del árbitro, `snp_state`
sigue libre para atender cualquier snoop remoto que llegue — incluyendo,
justamente, el snoop del L1 con el que se estaba bloqueado antes.

`core_bus_if.req_ready` se simplificó de `(state==S_IDLE) &&
!snoop_any_hit` a simplemente `(state==S_IDLE)` — aceptar una petición
local nueva ya no tiene por qué esperar a que se resuelva un snoop
remoto, porque ya no comparten registro de estado.

### 9.3 Lo que las dos FSM siguen necesitando compartir

Separar los *estados* fue la parte fácil. Dos recursos físicos seguían
siendo compartidos, y ahí es donde apareció el verdadero trabajo de
"integración":

**mem_bus_if** (un solo puerto hacia la L2). Antes, con una sola FSM,
nunca había dos peticiones a mem_bus_if compitiendo al mismo tiempo — era
literalmente imposible. Con las FSM separadas, el camino local (`S_WB`/
`S_MISS_WAIT`) y el de snoop (`SNP_WB`, cuando toca flushear una línea M
por un snoop remoto) sí pueden necesitarlo al mismo tiempo. Se agregó un
arbitrito interno chico, `mem_owner_r` (`MEM_NONE`/`MEM_CORE`/
`MEM_SNOOP`), que concede el puerto a uno de los dos y no lo suelta hasta
que esa transacción completa (mismo patrón que `snoop_bus.sv` usa para
sus sesiones de broadcast). Prioridad fija a favor del snoop — un remoto
ya está esperando la respuesta (y probablemente bloqueando a otros via el
árbitro de A-7), mientras que el peor caso para el camino local es una
espera un poco más larga. `ponytail:` prioridad fija en vez de
round-robin — si esto genera starvation medible del camino local, revisar.

**El puerto de lectura del data array.** Este fue el hallazgo no obvio de
esta actividad: al separar las FSM, `array_set_addr` (la dirección que se
le da al data array cada ciclo) pasó a tener DOS dueños potenciales
compitiendo por el mismo puerto único de lectura — si uno le "robaba" el
puerto al otro por un solo ciclo mientras el otro tenía un `S_WB`/`SNP_WB`
en curso, `data_rd_data`/lo que se lee quedaba corrompido exactamente
igual que describe el bug de A-5 (`data_rd_data` corriéndose un ciclo). En
vez de arbitrar un recurso compartido más (y arriesgar otra carrera sutil
de timing, que es exactamente el tipo de bug que este proyecto ya pisó
varias veces), se le dio al lado snoop **su propio puerto de lectura**
independiente (`snoop_rd_data`, indexado por `snoop_array_set_addr`). Es
una BRAM de 2 puertos de lectura (o 1R+1W) — un primitivo estándar y
barato en FPGA/ASIC (Xilinx, Yosys lo soportan nativamente), no un truco
inventado para esquivar el problema. Esto eliminó la clase entera de bugs
de "quién tiene el puerto este ciclo" en vez de intentar arbitrarla.

**tag_array** sigue en un solo `always_ff` (obligatorio: dos bloques
separados escribiendo la misma variable no es válido en SV), con las
condiciones de cada lado ahora usando `state==...` o `snp_state==...`
según corresponda — ver §9.4 para la carrera residual que esto deja
abierta.

### 9.4 Condición de carrera residual (documentada, no resuelta)

Si un snoop remoto y una operación local coinciden **en la línea exacta**
(mismo set y vía) en el mismo ciclo, las dos escrituras a `tag_array`
(una desde el bloque gateado por `state`, otra desde el gateado por
`snp_state`) compiten dentro del mismo `always_ff` — la que está más
abajo en el código gana (last-write-wins de SystemVerilog). No es el
deadlock que A-8 pedía resolver (que era puramente de *timing*, sin
importar la dirección) — esta es una colisión de *dirección exacta*,
mucho más angosta y menos probable en la práctica.

Arreglarla bien necesita algo al estilo MSHR (miss status holding
register): un candado por línea que, cuando el camino local elige una vía
víctima o el camino de snoop decide flushear una, bloquee al otro lado de
tocar esa misma entrada hasta que la transacción en curso termine
(diferir el snoop unos ciclos en vez de dejarlo competir). Es un cambio de
otro tamaño — no se metió en esta pasada porque exactamente ese tipo de
apuro ("meter un fix chico encima de un problema grande sin poder
probarlo bien") es lo que ya causó los bugs de timing documentados en §7 y
en `tfg_l1_cache_implementation.md`. Queda como candidato a revisar antes
de A-11 si las pruebas de coherencia necesitan garantizar esto.

### 9.5 Test: el escenario que antes colgaba, ahora resuelve

Se agregó un escenario nuevo a `hw/unittest/snoop_bus/main.cpp`
("Escenario 6"): los dos L1 piden un miss de escritura sobre direcciones
**sin relación entre sí**, en el **mismo ciclo exacto** — reproduciendo
literalmente la condición que antes de A-8 hacía que el test de
arbitraje colgara (ni con 200 ciclos de margen resolvía; por eso el
escenario de arbitraje de A-7 tuvo que desfasar a propósito las dos
peticiones, ver §8.5). Con las FSM separadas, el mismo escenario ahora
resuelve limpio y cada L1 recupera su propio dato sin cruzarse con el del
otro. `PASSED (134 ticks)` para la suite completa (antes 96, con este
escenario nuevo sumado).
