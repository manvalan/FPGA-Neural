# Registro bug — campagna di ri-certificazione FPGA-Neural

Formato per ogni voce: severità, sintomo, causa radice, evidenza (file:riga / comando/log
citabile), stato, test di regressione che lo blocca (se risolto) o che lo riprodurrebbe (se
aperto). Aggiornato incrementalmente man mano che avanzano gli aspetti C.1–C.14.

Severità: **CRITICA** (corrompe dati/hang in scenari raggiungibili), **MEDIA** (comportamento
scorretto in casi limite plausibili ma rari), **BASSA** (difetto reale ma senza impatto
funzionale pratico), **INFO** (non un bug: gap di copertura, ambiguità documentale/naming).

---

## Aperti

### BUG-001 (INFO, non ancora classificato) — `sim/top.v` non compila contro l'RTL corrente

- **Sintomo**: `iverilog` fallisce con `parameter FRAC_BITS not found in top.dut`.
- **Causa radice**: `sim/top.v` è un residuo della versione Q8.8 a virgola fissa del
  progetto, mai aggiornato dopo la conversione a INT8 puro (Fase 6, vedi
  `docs/validation/00-inventario.md` §0.2).
- **Evidenza**: `iverilog -g2012 -o /tmp/topcheck.out rtl/neuron_parallel.v rtl/mac8.v rtl/mac_unit.v sim/top.v` → 2 errori di elaborazione.
- **Impatto**: nessuno sulla regressione (il file non è referenziato da alcun testbench o
  tool) — è dead code, non un difetto funzionale del design.
- **Stato**: aperto, non corretto per policy §E (analisi separata dalla correzione). Azione
  proposta: rimuovere il file o aggiornarlo, decisione da confermare con l'utente.

### BUG-002 (MEDIA, CONFERMATO su sim + sintesi reale) — `N_INPUTS=0` bypassa il guard, `start` viene silenziosamente ignorato

- **Sintomo confermato** (non più un'ipotesi — vedi `docs/validation/01-datapath.md` §1.4 per
  la narrativa completa, incl. un falso positivo iniziale nella mia stessa metodologia di
  test, corretto e ridocumentato per trasparenza): con
  `neuron_parallel #(.N_INPUTS(0), .PARALLEL(P))`, il guard elaboration-time
  (`rtl/neuron_parallel.v:71`, `if (N_INPUTS % PARALLEL != 0)`) **non scatta** (`0 % P == 0`
  per ogni `P`), il modulo **elabora con successo** (sia in simulazione Icarus sia in sintesi
  reale Yosys, 0 problemi CHECK). A runtime: `start` viene accettato ma **`busy` non si alza
  mai e `done` non pulsa mai** — non l'hang "busy resta alto per sempre" descritto nel
  commento originale del guard (righe 55-58), un sintomo diverso, osservato per la prima
  volta in questa campagna.
- **Causa radice, confermata (non più ipotesi)**: `x_bus`/`w_bus` sono dichiarati
  `[DATA_WIDTH*N_INPUTS-1:0]`, che per `N_INPUTS=0` diventa `[-1:0]` — un range che **non
  collassa a larghezza zero**: sia Icarus sia Yosys lo trattano come un vettore reale a
  **2 bit** (larghezza = |MSB-LSB|+1 = 2), lasciato non pilotato. Confermato dai warning di
  Yosys: `Wire ...x_bus[1] is used but has no driver` (×2, per x_bus e w_bus).
- **Evidenza**:
  - `iverilog -g2012 -o /tmp/n0proper.out rtl/neuron_parallel.v rtl/mac8.v rtl/mac_unit.v sim/neuron_parallel_bug002_n_inputs_zero_tb.v && vvp /tmp/n0proper.out` → conferma il sintomo, ogni volta.
  - `yosys -p "synth_ecp5 -json /tmp/n0.json -top n0_synth_wrap" rtl/neuron_parallel.v rtl/mac8.v rtl/mac_unit.v <wrapper>` → **0 problemi CHECK**, 4 warning "no driver" su x_bus/w_bus[1:0].
  - Test di regressione permanente: `sim/neuron_parallel_bug002_n_inputs_zero_tb.v`.
- **Impatto pratico**: `N_INPUTS` è un parametro Verilog fissato in fase di sintesi (non un
  registro configurabile via SPI a runtime) — per essere raggiunto, qualcuno deve
  deliberatamente istanziare il modulo con `N_INPUTS=0`, cosa che non ha senso semantico per
  un layer reale. Rischio quindi basso in pratica (nessun percorso runtime/host-controllato
  può innescarlo), ma è un buco reale e confermato nella protezione, non solo teorico.
- **Fix proposto** (non applicato — analisi separata dalla correzione, §E del prompt di
  certificazione): estendere il guard a `if (N_INPUTS == 0 || N_INPUTS % PARALLEL != 0)`.
- **Stato**: **APERTO, confermato, non corretto.**

### BUG-003 (MEDIA, CONFERMATO ma NON pienamente caratterizzato) — `n_inputs_real=0` a runtime, comportamento incoerente tra ripetizioni

- **Sintomo**: con `N_INPUTS=32, PARALLEL=8` validi a compile-time (nessun problema di
  larghezza `[-1:0]`, a differenza di BUG-002), impostando `n_inputs_real=0` a runtime (lo
  stesso percorso raggiungibile dall'host via `SET_BASE sel=7`) il comportamento osservato
  **varia tra ripetizioni quasi identiche dello stesso test**: a volte `start` viene
  accettato ma `busy`/`done` non si muovono mai più (hang), a volte l'operazione completa
  normalmente ma processa l'INTERA larghezza di build invece di zero elementi (limite
  ignorato silenziosamente, stessa classe di BUG-004). Vedi `docs/validation/
  02-runtime-width.md` §2.3 per la registrazione completa di ogni singola ripetizione e dei
  suoi risultati, riportati senza scartare quelli "scomodi".
- **Causa radice**: **non isolata con certezza** entro il tempo ragionevole per questa
  campagna. Analisi aritmetica plausibile (non confermata come spiegazione completa): per
  questa build `GROUP_INDEX_WIDTH=2` bit, quindi `groups_real[1:0]-1` per `groups_real=0`
  avvolge al valore 3 (raggiungibile da un contatore a 2 bit, a differenza del contatore a
  1 bit di BUG-002) — spiegherebbe l'esito "limite ignorato" come esito aritmeticamente
  atteso, ma non spiega perché in alcune ripetizioni compaia invece un hang vero. Esclusi
  esplicitamente: propagazione di X in simulazione (verificato inizializzando ogni registro
  prima di qualunque reset, il comportamento non cambia), e una dipendenza semplice
  dall'ordine delle chiamate (una sequenza valida→zero non blocca; una sequenza
  zero→zero→zero blocca dalla seconda chiamata in poi, non dalla prima — non un pattern
  semplice "prima volta sicura, poi no").
- **Impatto pratico**: come BUG-002, `n_inputs_real=0` non ha senso semantico per una rete
  reale, ma a differenza di BUG-002 questo valore **è raggiungibile a runtime da un host via
  SPI** senza bisogno di una nuova sintesi — un host con un bug che calcola erroneamente
  `n_inputs_real=0` per un caso limite (es. un layer con zero neuroni in una topologia
  degenere) potrebbe innescarlo, con un esito imprevedibile tra hang e risultato
  silenziosamente sbagliato.
- **Stato**: **APERTO, confermato come comportamento scorretto in ogni caso osservato, ma
  meccanismo esatto NON isolato** — dichiarato esplicitamente come limite di questa verifica
  (§A.5), non presentato come pienamente compreso. Richiederebbe un'indagine dedicata
  (probabilmente a livello gate/timing reale, non solo comportamentale) per chiudere con
  certezza il meccanismo, non solo il sintomo.

### BUG-004 (MEDIA, CONFERMATO scorretto, NON pienamente caratterizzato) — `n_neurons_real=0` non blocca, ma non fa nemmeno quello che ci si aspetterebbe in modo coerente

- **Sintomo**: a `rtl/neuron_memory.v`, con `n_neurons_real=0`, l'operazione **completa
  sempre normalmente** (mai un hang, a differenza di BUG-002/003) — ma il numero di cicli
  impiegato **non è coerente tra build diverse**: per `N_NEURONS=2` (`NEURON_INDEX_WIDTH=1`
  bit) impiega **esattamente** lo stesso numero di cicli di `n_neurons_real=2` (114=114,
  suggerendo che il limite venga ignorato e processi tutto), mentre per `N_NEURONS=3`
  (`NEURON_INDEX_WIDTH=2` bit) impiega **196 cicli — più della build completa a 3 neuroni
  (155)**, un terzo valore che non corrisponde né a "zero neuroni" né a "tutti i neuroni".
  In ogni caso testato: nessun errore, nessun timeout — un host che chiede zero neuroni
  riceve sempre un completamento dall'aspetto normale ma su un conteggio/dato diverso da
  quanto richiesto, e il conteggio esatto varia con `N_NEURONS`.
- **Causa radice**: non isolata bit-per-bit (a differenza di BUG-002). Ipotesi coerente con
  BUG-003: l'aritmetica di avvolgimento (`neuron_index == n_neurons_real[W-1:0]-1`) per
  `n_neurons_real=0` produce un valore di terminazione che, per coincidenza di larghezza,
  corrisponde al conteggio pieno invece che a "termina subito".
  Vedi `docs/validation/02-runtime-width.md` §2.5.
- **Impatto pratico**: come BUG-002/003, richiede che l'host imposti deliberatamente (o per
  bug proprio) `n_neurons_real=0` — non raggiungibile da un input esterno arbitrario, ma
  raggiungibile da un bug nel software host senza bisogno di ricompilare il bitstream.
- **Stato**: **APERTO, confermato, causa esatta non isolata** (stesso limite dichiarato di
  BUG-003).

---

## Risolti

(nessuno ancora in questa campagna — la Fase 0 è analisi/inventario, non correzione)

---

## Non-bug (falsi positivi trovati e chiusi durante l'analisi)

Voci che sono sembrate anomalie a un primo controllo automatico ma si sono rivelate corrette
per progetto una volta letto il codice/intento — riportate per trasparenza sul processo, non
perché siano difetti.

- **`neuron_parallel_guard_negative_{degenerate,nonmultiple}_tb.v` "falliscono a compilare"**:
  comportamento corretto e intenzionale (test negativi, la mancata compilazione è il PASS).
  Vedi `docs/validation/00-inventario.md` §0.5.
- **`graph_engine_bandwidth_tb.v` "nessun verdetto PASS/FAIL"**: è un benchmark per
  progetto, non un test di correttezza. Vedi §0.3/§0.5 dell'inventario.
