# FPGA-Neural V1 — Golden Reference (FROZEN)

Questo albero è una copia bit-esatta del codice V1 così come esisteva al commit
`07a48e4` (fix: close 7 zero-value/mid-run guard gaps found in re-certification
campaign) del repository principale. Verificato byte-per-byte al momento della
creazione (`diff -rq` contro `rtl/` e `sim/*.v` dell'albero principale, 0
differenze).

## Regola non negoziabile

**Questo albero non deve mai essere modificato.** È il riferimento funzionale,
numerico, prestazionale e bit-exact per ogni sviluppo V2 (`hardware/v2/`), per
policy esplicita di `docs/v2-description.md` §1 e §34 ("V1 rimane intatta").

Se un bug o miglioramento V1 viene scoperto durante lo sviluppo V2, **non
correggerlo qui**: documentarlo in `hardware/v2/logs/decisions.log` o
`errors.log` e, se necessario, applicarlo separatamente al V1 "vivo"
nell'albero principale del repository (`rtl/`, `sim/`, ecc.), mai in questa
copia.

## Contenuto

- `rtl/` — i 20 moduli RTL V1 (copia di `rtl/*.v` dell'albero principale).
- `sim/` — le 47 testbench V1 (copia di `sim/*.v`, esclusi i `.vcd` generati:
  rieseguibili in loco con `iverilog`/`vvp`, non servono duplicati).
- `tools/` — copia di `tools/` (harness di regressione, netasm, generatore
  `.lpf`, oracoli di validazione).
- `constraints/` — i vincoli `.lpf` per ECP5 (`spi_neuron_top.lpf`,
  `spi_neuron_top_flash.lpf`).
- `synthesis/` — sottoinsieme rappresentativo dei risultati di sintesi reale
  già misurati sul V1 (non l'intera storia sperimentale, che resta
  nell'albero principale sotto `synth/ecp5/`):
  - `post_fix_verify/` — sistema completo (`spi_neuron_top` con sottosistema
    flash, PARALLEL=8), stato più recente e autorevole: 0 errori di vincolo,
    **Fmax 68.65 MHz**.
  - `p2/`, `p4/`, `p8/` — sweep isolato di `neuron_parallel` a PARALLEL
    variabile (N_INPUTS=256), stessa fonte dei numeri citati in
    `docs/v2-description.md` §3 per P8/P4/P2. Il dato P16 (52.13 MHz) citato
    nella stessa sezione proviene da `docs/FPGA-Neural-Datapatch-Benchmark.md`
    (copiato in `docs/`), non da un artefatto di sintesi grezzo separato.
- `docs/` — copia dei documenti di riferimento: `WORKLOG.md`, i capitoli di
  `docs/validation/` (campagna di certificazione + registro bug), il datasheet
  markdown (`FPGA-NeuralNetwork-Engine.md`), il report benchmark
  (`FPGA-Neural-Datapatch-Benchmark.md`) e il documento hardware
  (`FPGA-Neural-Hardware-Design.md`).

## Dati baseline citati da V2 (`docs/v2-description.md` §3)

| Config | Fmax (isolato, N_INPUTS=256) | Fonte |
|---|---|---|
| PARALLEL=16 | 52.13 MHz (FAIL @80MHz) | `docs/FPGA-Neural-Datapatch-Benchmark.md` |
| PARALLEL=8  | 61.71 MHz (FAIL @80MHz) | `synthesis/p8/` |
| PARALLEL=4  | 75.01 MHz (FAIL @80MHz) | `synthesis/p4/` |
| PARALLEL=2  | 87.88 MHz (PASS @80MHz) | `synthesis/p2/` |

Sistema integrato (`spi_neuron_top`, PARALLEL=8, sottosistema flash incluso):
**68.65 MHz** (`synthesis/post_fix_verify/`, più recente della cifra 65.13 MHz
citata in `docs/v2-description.md` §3, che si riferiva a uno stato pre-fix
precedente — vedi `docs/WORKLOG.md` per la cronologia completa).

Percorso critico osservato in ogni misura: logica di `neuron_parallel.v`
(catena di riporto CCU2C del comparatore/accumulatore) e la sua
interconnessione — mai il controller PSRAM.
