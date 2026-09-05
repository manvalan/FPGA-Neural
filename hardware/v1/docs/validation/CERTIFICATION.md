# CERTIFICATO FPGA-Neural — Campagna di ri-certificazione 2026-09-04 (aggiornato post-fix)

Metodo per ogni aspetto: analisi statica del codice reale (non di descrizioni), test con
oracolo indipendente (Python, calcolo a mano, o citazione datasheet), verifica su entrambi
i piani (simulazione Icarus + sintesi reale Yosys/nextpnr-ecp5 dove applicabile). Dettagli,
comandi esatti e log per capitolo in `docs/validation/00-inventario.md` e
`docs/validation/01-datapath.md` … `D-trasversali.md`. Dettagli dei fix e delle relative
verifiche in `docs/validation/bugs.md`.

Questo documento è la revisione POST-FIX del verdetto iniziale (commit `77e74db`, fase di
sola analisi). Il verdetto iniziale resta leggibile nella storia git per trasparenza sul
processo — questo documento lo sostituisce come stato corrente del progetto.

---

## Verdetto complessivo

**Il datapath aritmetico di base è solido e certificato esaustivamente dove possibile**
(`mac_unit.v`: 65536/65536 combinazioni INT8 esaustive, 0 mismatch). **Il resto del design
— controllo, sequenziamento, arbitraggio — è funzionalmente corretto sul percorso felice**,
confermato da una regressione di 43 testbench reali tutti PASS (harness indipendente creato
in questa campagna).

**La campagna aveva trovato 7 bug reali, concentrati tutti in un unico pattern sistemico**:
valori limite "reale=0" (`N_INPUTS`, `n_inputs_real`, `n_neurons_real`, `run_num_layers`,
`num_neurons_graph`) e una scrittura di configurazione (`SET_NET_TYPE`) non protetta durante
un'operazione in corso. Due di questi (BUG-005, BUG-007) erano CRITICI: raggiungibili con
opcode SPI documentati in condizioni plausibili, con rischio di corruzione dati reale in
PSRAM o hang dell'inferenza in corso.

**Tutti e 7 i bug sono ora stati corretti in RTL e verificati indipendentemente**, ciascuno
con il proprio testbench di regressione riscritto per ASSERIRE (non solo osservare) il
comportamento corretto — dettagli completi, evidenza per-bug ed esiti dei test in
`docs/validation/bugs.md`. Il fix è stato applicato come commit separato dall'analisi
originale, per policy della campagna (§E del mandato). La regressione completa (43/43 test
reali PASS) e una nuova sintesi/place&route reale (Yosys + nextpnr-ecp5, 0 errori, Fmax
invariato entro il rumore di piazzamento) confermano che nessuno dei fix ha introdotto
regressioni sul percorso felice né sul timing.

**Il progetto è ora certificabile con riserve residue minori** (elencate sotto — nessuna di
severità CRITICA o MEDIA rimane aperta), a differenza del verdetto iniziale che richiedeva
riserve esplicite bloccanti su BUG-005/007 prima di un uso in produzione con host non
completamente fidato.

---

## Tabella per aspetto (aggiornata post-fix)

| Aspetto | Verdetto | Capitolo |
|---|---|---|
| Fase 0 — Inventario | CERTIFICATO (fotografia reale, non presunta) | `00-inventario.md` |
| C.1 — Datapath aritmetico (`mac_unit`, `mac8`) | CERTIFICATO (guard `N_INPUTS=0` corretto e verificato — BUG-002 risolto) | `01-datapath.md`, `bugs.md` |
| C.2 — Larghezza runtime | CERTIFICATO (BUG-003, BUG-004 risolti e verificati) | `02-runtime-width.md`, `bugs.md` |
| C.3 — Sottosistema memoria | CERTIFICATO | `03-memoria.md` |
| C.4 — Arbitro | CERTIFICATO (riserva documentale non-bug su starvation di D) | `04-arbiter.md` |
| C.5 — Sequencer dense | CERTIFICATO (BUG-005, ex-CRITICO, risolto e verificato) | `05-layer-sequencer.md`, `bugs.md` |
| C.6 — Motore grafo | CERTIFICATO (BUG-006 risolto e verificato) | `06-graph-engine.md`, `bugs.md` |
| C.7 — SPI slave + engine | CERTIFICATO | `07-spi.md` |
| C.8 — Top-level | CERTIFICATO (BUG-007, ex-CRITICO, risolto e verificato end-to-end su SPI reale) | `08-top-level.md`, `bugs.md` |
| C.9 — Pinout / `.lpf` | CERTIFICATO | `09-pinout.md` |
| C.10 — Timing | CERTIFICATO (Fmax post-fix 68.65 MHz, invariato entro rumore di piazzamento rispetto a 67.91 MHz pre-fix) | `10-timing.md`, `bugs.md` |
| C.11 — Toolchain / build | CERTIFICATO (silicio reale: NON CERTIFICABILE, nessun hardware disponibile) | `11-toolchain.md` |
| C.12 — `netasm` | CERTIFICATO | `12-netasm.md` |
| C.13 — Coerenza datasheet↔RTL | AGGIORNATO POST-FIX (i 7 bug e i relativi fix sono ora riflessi nel datasheet) | `13-coerenza-datasheet.md` |
| C.14 — Lavori in corso | CERTIFICATO (risultano completi, non "in corso") | `14-lavori-in-corso.md` |
| D.1 — CDC | CERTIFICATO | `D-trasversali.md` §D.1 |
| D.2 — Reset | CERTIFICATO (fatto: sincrono ovunque, non async) | `D-trasversali.md` §D.2 |
| D.3 — FSM | CERTIFICATO CON RISERVE (nessuna analisi di raggiungibilità esaustiva oltre il pattern "reale=0" già trovato e corretto) | `D-trasversali.md` §D.3 |
| D.4 — Larghezze/overflow | CERTIFICATO CON RISERVE | `D-trasversali.md` §D.4 |
| D.5 — Lint | CERTIFICATO (0 latch accidentali, 1 warning noto/atteso, invariato post-fix) | `D-trasversali.md` §D.5 |
| D.6 — Determinismo | CERTIFICATO CON RISERVE (non verificato con campagna dedicata) | `D-trasversali.md` §D.6 |

---

## Registro bug — riepilogo (dettagli completi in `bugs.md`)

| ID | Severità | Sintomo | Raggiungibilità | Stato |
|---|---|---|---|---|
| BUG-001 | INFO | `sim/top.v` non compilava (dead code, residuo pre-INT8) | N/A (non nella regressione) | **RISOLTO** — file rimosso |
| BUG-002 | MEDIA | `N_INPUTS=0` bypassava il guard compile-time, `start` ignorato | Richiede una nuova sintesi | **RISOLTO** — guard esteso, verificato (fallimento di compilazione atteso) |
| BUG-003 | MEDIA | `n_inputs_real=0` a runtime, comportamento incoerente tra ripetizioni (hang o limite ignorato) | Runtime, via SPI (`SET_BASE` sel 7) | **RISOLTO** — early-out esplicito, verificato (1 ciclo, y=0) |
| BUG-004 | BASSA | `n_neurons_real=0`, limite ignorato silenziosamente, conteggio cicli incoerente tra build | Runtime, via SPI (`SET_BASE` sel 8) | **RISOLTO** — guard su 3 punti d'ingresso, verificato (32 vs 155 cicli) |
| BUG-005 | **CRITICA** | `RUN_NETWORK(0)` eseguiva 256 layer fasulli, scriveva PSRAM a indirizzi arbitrari | Un solo opcode SPI documentato | **RISOLTO** — no-op immediato, verificato (1 ciclo, layer_idx=0) |
| BUG-006 | BASSA | Stessa causa di BUG-005 in `graph_engine`, mitigata incidentalmente da un guard esistente | Un solo opcode SPI, rischio pratico basso osservato | **RISOLTO** — no-op immediato, verificato (13 cicli, no err) |
| BUG-007 | **CRITICA** | `SET_NET_TYPE` durante un run bloccava il motore in corso | Due opcode SPI documentati in sequenza ravvicinata | **RISOLTO** — scrittura rifiutata mentre busy, verificato end-to-end su SPI reale |

Tutti i fix e le rispettive verifiche sono in un commit separato dall'analisi originale
(policy §E). Regressione completa post-fix: 44 testbench, 43 PASS, 0 FAIL/ERROR, 1
BENCHMARK (nessun verdetto per progetto, invariato).

---

## Riserve aperte residue (onestà sui limiti, §A.5)

Nessuna riserva CRITICA o MEDIA rimane aperta. Riserve residue, tutte già dichiarate nel
verdetto iniziale e non toccate dalla campagna di fix (fuori scope, o limiti strutturali
della metodologia):

1. **BUG-003/004 (nota storica)**: il meccanismo esatto del comportamento PRE-fix (perché
   variava tra hang e limite ignorato) non è stato isolato bit-per-bit nemmeno durante la
   correzione — il fix bypassa l'intero percorso ambiguo con un early-out esplicito,
   verificato deterministico sul NUOVO comportamento. Non rilevante per la sicurezza
   dell'RTL corrente, ma dichiarato per trasparenza sul processo.
2. **C.11**: comportamento su silicio reale non verificabile in questo ambiente (nessun
   hardware fisico) — limite dichiarato dall'inizio del progetto, non di questa campagna.
3. **D.3 (FSM)**: nessuna analisi di raggiungibilità esaustiva di OGNI FSM del progetto — i
   6 bug di FSM trovati (BUG-002-007) sono stati scoperti e corretti seguendo un pattern
   (valori limite "reale=0"), non da un'analisi sistematica di ogni possibile stato.
   **Potrebbero esisterne altri non ancora scoperti**, in particolare in moduli non ancora
   sottoposti a test avversariali mirati su valori limite (es. `psram_controller.v`,
   `spi_slave.v`).
4. **D.6 (determinismo)**: nessuna campagna dedicata di run ripetuti/seed multipli.
5. **Verifica elettrica/analogica reale** (setup/hold, rise/fall, signal integrity): mai in
   scope per una campagna basata su simulazione comportamentale + sintesi digitale — limite
   strutturale della metodologia, dichiarato fin dall'inizio del progetto (§A.5).

---

## Verifica dei fix (dual-plane, §A.4)

- **Simulazione**: ciascuno dei 6 bug RTL (BUG-002 – BUG-007) ha un testbench di
  regressione dedicato, riscritto dopo il fix per ASSERIRE il comportamento corretto
  (non solo osservarlo, come durante la fase di scoperta) — vedi `docs/validation/bugs.md`
  per il dettaglio di ogni asserzione e il relativo esito.
- **Sintesi reale**: `yosys synth_ecp5` sul sistema completo (`spi_neuron_top` con
  sottosistema flash, PARALLEL=8) — 0 problemi CHECK, 1 warning atteso/preesistente
  (invariato). `nextpnr-ecp5` reale — 0 errori di vincolo, 0 pin non vincolati, Fmax 68.65
  MHz (invariato entro il rumore di piazzamento rispetto ai 67.91 MHz pre-fix), percorso
  critico strutturalmente identico (accumulatore MAC in `neuron_parallel.v`/`mac8.v`, non
  toccato dai fix). Log: `synth/ecp5/post_fix_verify/`.
- **Regressione**: `python3 tools/run_regression.py` — 44 testbench, 43 PASS, 0
  FAIL/ERROR, 1 BENCHMARK (per progetto, invariato).

---

## Stato lavori residui

1. ~~BUG-005 e BUG-007 (CRITICI)~~ — **RISOLTI**.
2. ~~BUG-002/003/004 (MEDIA/BASSA)~~ — **RISOLTI**.
3. ~~BUG-006~~ — **RISOLTO**.
4. ~~BUG-001~~ — **RISOLTO** (file rimosso).
5. ~~Aggiornamento datasheet/documentazione (C.13)~~ — completato in questo stesso ciclo di
   lavoro (markdown + LaTeX IT/EN).
