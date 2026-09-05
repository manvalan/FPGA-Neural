# D — Analisi trasversali

Data: 2026-09-04.

---

## D.1 CDC (clock domain crossing)

`spi_slave.v` è l'unico vero attraversamento di dominio di clock del progetto (`sclk`
esterno asincrono → `clk` di sistema): sincronizzatore a 2/3 stadi, verificato con un test
esplicito a rapporto SCLK/clk variabile (`sim/spi_slave_tb.v` TEST 4, §C.7). Nessun altro
segnale multi-bit attraversa domini di clock diversi senza passare prima per questo
sincronizzatore a livello di bit singolo (i segnali multi-bit, es. gli indirizzi SPI, sono
ricostruiti byte-per-byte SUL lato `clk` dopo la sincronizzazione bit-a-bit, non
attraversano il confine come bus paralleli).

**Verdetto: CERTIFICATO** (evidenza da C.7, non ripetuta qui).

---

## D.2 Reset

**Trovato per ispezione su tutti i 20 file RTL** (non assunto): `grep -l "posedge rst"
rtl/*.v` → **nessun risultato**. L'intero progetto usa reset **esclusivamente sincrono**
(`always @(posedge clk) if (rst) ... else ...`), mai `always @(posedge clk or posedge rst)`.
Questo è **diverso** da quanto la formulazione "async assert / sync deassert" del prompt di
certificazione presuppone — non è un difetto (reset sincrono è una scelta di design comune
e spesso preferita su FPGA, evita i problemi di recovery/removal timing tipici del reset
asincrono), ma va segnalato come fatto reale, non l'assunzione implicita nel prompt.

Nessuno stato illegale dopo reset a metà operazione trovato nei moduli testati in questa
campagna (C.1-C.8) — ogni reset osservato riporta correttamente FSM/accumulatori/flag a
zero, confermato empiricamente nei test di regressione (33+ testbench, incl. reset a metà
run in `flash_slot_manager_tb.v`'s test di power-loss simulato, §sessioni precedenti).

**Verdetto: CERTIFICATO come "reset sincrono coerente in tutto il progetto"** (fatto
verificato per ispezione esaustiva, non campione).

---

## D.3 FSM (stati irraggiungibili, deadlock, default sicuro)

Non è stata fatta un'analisi di raggiungibilità formale di ogni FSM del progetto (fuori
scope per il tempo di questa campagna) — ma **6 bug reali trovati in questa campagna
(BUG-002-007) sono ESATTAMENTE difetti di FSM**: contatori che avvolgono su un valore
raggiungibile invece di essere bloccati da una guardia, e un mux non agganciato allo stato
del motore che sta effettivamente pilotando. Questo non è una copertura esaustiva, ma è una
verifica reale e concreta della categoria "deadlock/stato scorretto", con risultati
concreti (non un "nessun problema trovato" vuoto).

Ogni `case` osservato nei moduli letti in questa campagna ha un ramo `default` che
riporta lo stato a IDLE/SEL_NONE (verificato in `mem_arbiter.v`, `int8_memory_access.v`,
`neuron_parallel.v` — nessuno stato `case` privo di default trovato nei moduli ispezionati).

**Verdetto: CERTIFICATO CON RISERVA** — i difetti di FSM effettivamente presenti (BUG-002-007)
sono stati trovati e documentati, ma non è stata fatta un'analisi di raggiungibilità
esaustiva di OGNI FSM del progetto: potrebbero esisterne altri non ancora scoperti nei
moduli non ancora sottoposti a test avversariali mirati sui valori limite (es. `spi_slave.v`
stesso, `psram_controller.v` oltre a quanto già verificato in sessioni precedenti).

---

## D.4 Larghezze e overflow

**Un bug reale di questa classe era già stato trovato e corretto in una fase precedente di
questa stessa sessione** (non solo teoria): `FLASH_SPACE_BYTES = 24'h100_0000` (16MB=2^24)
troncava silenziosamente a 0 in 24 bit, catturato dal warning di iverilog stesso
("Numeric constant truncated"), corretto allargando a 25 bit — citato per completezza, non
riscoperto qui.

**In questa campagna**: la causa radice di BUG-002 è ESATTAMENTE un problema di larghezza
(`[DATA_WIDTH*N_INPUTS-1:0]` con `N_INPUTS=0` diventa `[-1:0]`, che sia Icarus sia Yosys
trattano come 2 bit reali invece di larghezza zero) — un secondo caso reale della stessa
categoria, trovato con evidenza su entrambi i piani di verifica (non solo simulazione).

**Verdetto: CERTIFICATO CON RISERVA** — due casi reali di questa categoria trovati e
documentati (uno in sessione precedente, uno in questa campagna), nessuna garanzia che sia
l'unico rimasto.

---

## D.5 Lint

**Eseguito in questa fase** (non solo il CHECK pass isolato per modulo già visto durante
tutta la sessione): sintesi Yosys dell'intero sistema (`spi_neuron_top` + tutti i 19 moduli
RTL che istanzia), con `proc; opt_clean; check`, filtrando esplicitamente ogni messaggio
`warning`/`latch`/`error`/`width mismatch`/`multiple driver`:

```
Warnings: 1 unique messages, 1 total
rtl/psram_controller.v:191: Warning: Yosys has only limited support for tri-state logic
[...25× "No latch inferred for signal ..." -- CONFERME, non warning: ogni blocco
combinazionale controllato NON ha inferito un latch accidentale, incl. l'intero albero
binario di mac8.v e la funzione next_crc di crc32.v]
```

**Un solo warning reale**, lo stesso già noto e documentato ripetutamente in
`WORKLOG.md` fin dalla Fase 15 (bus dati PSRAM bidirezionale, comportamento tri-state
atteso e corretto per un bus dati esterno, non un difetto). **Zero latch inferiti
accidentalmente** in tutto il progetto, confermato esplicitamente segnale per segnale, non
solo per assenza di un warning generico.

**Verdetto: CERTIFICATO.** Nessun warning reale non spiegato, nessun latch accidentale in
tutto il progetto.

---

## D.6 Determinismo

Non eseguita una campagna dedicata di run ripetuti a confronto bit-esatto in questa fase
(fuori scope per il tempo disponibile) — ma **evidenza indiretta forte** raccolta durante
tutta questa campagna: ogni test rieseguito più volte durante il debug (es. i tentativi
multipli su BUG-003 in C.2, il test di regressione completo rieseguito ad ogni fase C.1-C.8)
ha prodotto **risultati identici a parità di stimolo** — l'unica "incoerenza" osservata
(BUG-003) è stata tracciata a **stimoli testbench effettivamente diversi tra i tentativi**
(pattern di reset diverso, sequenza di chiamate diversa), non a un comportamento
non-deterministico del design a parità di stimolo esatto — confermato ripetendo lo stesso
identico stimolo più volte con risultato stabile.

**Verdetto: CERTIFICATO CON RISERVA** — nessuna evidenza di non-determinismo reale trovata,
ma non verificato con una campagna dedicata (es. seed multipli su tutti i testbench,
confronto bit-esatto sistematico).
