# CERTIFICATO FPGA-Neural — Campagna di ri-certificazione 2026-09-04

Metodo per ogni aspetto: analisi statica del codice reale (non di descrizioni), test con
oracolo indipendente (Python, calcolo a mano, o citazione datasheet), verifica su entrambi
i piani (simulazione Icarus + sintesi reale Yosys/nextpnr-ecp5 dove applicabile). Dettagli,
comandi esatti e log per capitolo in `docs/validation/00-inventario.md` e
`docs/validation/01-datapath.md` … `D-trasversali.md`.

---

## Verdetto complessivo

**Il datapath aritmetico di base è solido e certificato esaustivamente dove possibile**
(`mac_unit.v`: 65536/65536 combinazioni INT8 esaustive, 0 mismatch). **Il resto del design
— controllo, sequenziamento, arbitraggio — è funzionalmente corretto sul percorso felice**,
confermato da una regressione di 40 testbench reali tutti PASS, riverificata da zero con un
harness indipendente creato in questa campagna (non esisteva prima).

**Ma questa campagna ha trovato 7 bug reali, concentrati tutti in un unico pattern
sistemico**: valori limite "reale=0" (`N_INPUTS`, `n_inputs_real`, `n_neurons_real`,
`run_num_layers`, `num_neurons_graph`) e una scrittura di configurazione (`SET_NET_TYPE`)
non protetta durante un'operazione in corso. **Due di questi (BUG-005, BUG-007) sono
CRITICI**: raggiungibili con opcode SPI documentati in condizioni plausibili (non richiedono
un bitstream diverso né un attacco elaborato), e comportano rischio di corruzione dati reale
in PSRAM o hang dell'inferenza in corso. **Nessuno di questi 7 bug era documentato prima di
questa campagna** — il datasheet e la documentazione descrivono, al momento in cui scrivo,
un sistema più sicuro di quello che l'RTL realmente implementa in questi casi limite.

**Il progetto NON è quindi certificabile senza riserve nel suo complesso.** È certificabile
con riserve esplicite, elencate qui sotto, con priorità di correzione chiara (BUG-005 e
BUG-007 prima di ogni uso in produzione con un host non completamente fidato).

---

## Tabella per aspetto

| Aspetto | Verdetto | Capitolo |
|---|---|---|
| Fase 0 — Inventario | CERTIFICATO (fotografia reale, non presunta) | `00-inventario.md` |
| C.1 — Datapath aritmetico (`mac_unit`, `mac8`) | CERTIFICATO CON RISERVE (guard `N_INPUTS=0` non certificato — BUG-002) | `01-datapath.md` |
| C.2 — Larghezza runtime | CERTIFICATO CON RISERVE (BUG-003, BUG-004) | `02-runtime-width.md` |
| C.3 — Sottosistema memoria | CERTIFICATO | `03-memoria.md` |
| C.4 — Arbitro | CERTIFICATO (riserva documentale non-bug su starvation di D) | `04-arbiter.md` |
| C.5 — Sequencer dense | CERTIFICATO CON RISERVE (**BUG-005, CRITICO**) | `05-layer-sequencer.md` |
| C.6 — Motore grafo | CERTIFICATO CON RISERVE (BUG-006) | `06-graph-engine.md` |
| C.7 — SPI slave + engine | CERTIFICATO | `07-spi.md` |
| C.8 — Top-level | CERTIFICATO CON RISERVE (**BUG-007, CRITICO**) | `08-top-level.md` |
| C.9 — Pinout / `.lpf` | CERTIFICATO | `09-pinout.md` |
| C.10 — Timing | CERTIFICATO | `10-timing.md` |
| C.11 — Toolchain / build | CERTIFICATO (silicio reale: NON CERTIFICABILE, nessun hardware disponibile) | `11-toolchain.md` |
| C.12 — `netasm` | CERTIFICATO | `12-netasm.md` |
| C.13 — Coerenza datasheet↔RTL | NON CERTIFICATO (i 7 bug di questa campagna non sono ancora documentati) | `13-coerenza-datasheet.md` |
| C.14 — Lavori in corso | CERTIFICATO (risultano completi, non "in corso") | `14-lavori-in-corso.md` |
| D.1 — CDC | CERTIFICATO | `D-trasversali.md` §D.1 |
| D.2 — Reset | CERTIFICATO (fatto: sincrono ovunque, non async) | `D-trasversali.md` §D.2 |
| D.3 — FSM | CERTIFICATO CON RISERVE (nessuna analisi di raggiungibilità esaustiva) | `D-trasversali.md` §D.3 |
| D.4 — Larghezze/overflow | CERTIFICATO CON RISERVE | `D-trasversali.md` §D.4 |
| D.5 — Lint | CERTIFICATO (0 latch accidentali, 1 warning noto/atteso) | `D-trasversali.md` §D.5 |
| D.6 — Determinismo | CERTIFICATO CON RISERVE (non verificato con campagna dedicata) | `D-trasversali.md` §D.6 |

---

## Registro bug — riepilogo (dettagli completi in `bugs.md`)

| ID | Severità | Sintomo | Raggiungibilità | Stato |
|---|---|---|---|---|
| BUG-001 | INFO | `sim/top.v` non compila (dead code, residuo pre-INT8) | N/A (non nella regressione) | Aperto, non corretto |
| BUG-002 | MEDIA | `N_INPUTS=0` bypassa il guard compile-time, `start` ignorato | Richiede una nuova sintesi | Aperto, causa isolata con certezza |
| BUG-003 | MEDIA | `n_inputs_real=0` a runtime, comportamento **incoerente** tra ripetizioni (hang o limite ignorato) | Runtime, via SPI (`SET_BASE` sel 7) | Aperto, causa NON isolata con certezza |
| BUG-004 | BASSA | `n_neurons_real=0`, limite ignorato silenziosamente, conteggio cicli incoerente tra build | Runtime, via SPI (`SET_BASE` sel 8) | Aperto, causa NON isolata con certezza |
| BUG-005 | **CRITICA** | `RUN_NETWORK(0)` esegue 256 layer fasulli, scrive PSRAM a indirizzi arbitrari | Un solo opcode SPI documentato | Aperto, causa isolata con certezza |
| BUG-006 | BASSA | Stessa causa di BUG-005 in `graph_engine`, mitigata incidentalmente da un guard esistente | Un solo opcode SPI, rischio pratico basso osservato | Aperto |
| BUG-007 | **CRITICA** | `SET_NET_TYPE` durante un run blocca il motore in corso | Due opcode SPI documentati in sequenza ravvicinata | Aperto, **recupero via RESET verificato** |

---

## Riserve aperte (onestà sui limiti, §A.5)

Elencate esplicitamente, non nascoste:

1. **BUG-003/004**: il meccanismo esatto che decide tra i due sintomi osservati (hang vs.
   limite ignorato) non è stato isolato con certezza — dichiarato, non finto compreso.
2. **BUG-006**: verificato solo con un pattern di dati non esaustivo (5000 cicli, non le
   65536 iterazioni possibili) — il rischio strutturale resta, anche se quello pratico
   osservato è basso.
3. **C.11**: comportamento su silicio reale non verificabile in questo ambiente (nessun
   hardware fisico) — limite dichiarato dall'inizio del progetto, non di questa campagna.
4. **D.3 (FSM)**: nessuna analisi di raggiungibilità esaustiva di OGNI FSM del progetto —
   i 6 bug di FSM trovati (BUG-002-007) sono stati scoperti seguendo un pattern (valori
   limite "reale=0"), non da un'analisi sistematica di ogni possibile stato. **Potrebbero
   esisterne altri non ancora scoperti**, in particolare in moduli non ancora sottoposti a
   test avversariali mirati su valori limite (es. `psram_controller.v`, `spi_slave.v`).
5. **D.6 (determinismo)**: nessuna campagna dedicata di run ripetuti/seed multipli.
6. **C.13**: i 7 bug di questa campagna non sono ancora riflessi nel datasheet — azione di
   follow-up esplicitamente rimandata, non dimenticata.
7. **Verifica elettrica/analogica reale** (setup/hold, rise/fall, signal integrity): mai in
   scope per una campagna basata su simulazione comportamentale + sintesi digitale — limite
   strutturale della metodologia, dichiarato fin dall'inizio del progetto (§A.5).

---

## Priorità di correzione raccomandata (non applicata in questa campagna — analisi separata dalla correzione, §E)

1. **BUG-005 e BUG-007** (CRITICI): entrambi richiedono solo l'aggiunta di un guard/check
   già usato altrove nel progetto (pattern già presente per altri casi) — fix
   concettualmente semplice, alto impatto sulla robustezza verso un host non
   completamente fidato o buggato.
2. **BUG-002/003/004** (MEDIA/BASSA): stesso pattern di guard mancante, minore
   raggiungibilità pratica.
3. **BUG-006**: già mitigato incidentalmente, priorità più bassa ma non nulla.
4. **BUG-001**: decisione su rimuovere/aggiornare `sim/top.v`, non un rischio funzionale.
5. **Aggiornamento datasheet/documentazione** (C.13) una volta chiuse le voci sopra.
