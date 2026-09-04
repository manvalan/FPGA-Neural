# Registro bug — campagna di ri-certificazione FPGA-Neural

Formato per ogni voce: severità, sintomo, causa radice, evidenza (file:riga / comando/log
citabile), stato, test di regressione che lo blocca (se risolto) o che lo riprodurrebbe (se
aperto). Aggiornato incrementalmente man mano che avanzano gli aspetti C.1–C.14.

Severità: **CRITICA** (corrompe dati/hang in scenari raggiungibili), **MEDIA** (comportamento
scorretto in casi limite plausibili ma rari), **BASSA** (difetto reale ma senza impatto
funzionale pratico), **INFO** (non un bug: gap di copertura, ambiguità documentale/naming).

---

## Aperti

(nessuno — tutti i bug della campagna sono stati corretti e verificati, vedi "Risolti" sotto)

---

## Risolti

### BUG-001 (INFO) — `sim/top.v` non compila contro l'RTL corrente

- **Sintomo**: `iverilog` fallisce con `parameter FRAC_BITS not found in top.dut`.
- **Causa radice**: `sim/top.v` è un residuo della versione Q8.8 a virgola fissa del
  progetto, mai aggiornato dopo la conversione a INT8 puro (Fase 6, vedi
  `docs/validation/00-inventario.md` §0.2).
- **Evidenza**: `iverilog -g2012 -o /tmp/topcheck.out rtl/neuron_parallel.v rtl/mac8.v rtl/mac_unit.v sim/top.v` → 2 errori di elaborazione.
- **Impatto**: nessuno sulla regressione (il file non è referenziato da alcun testbench o
  tool) — era dead code, non un difetto funzionale del design.
- **Fix applicato**: file rimosso (`git rm sim/top.v`) — confermato non referenziato da alcun
  testbench o tool (`tools/run_regression.py` lo esclude esplicitamente dal proprio elenco
  sorgenti anche prima della rimozione).
- **Stato**: **RISOLTO** — file eliminato, nessun test di regressione necessario (non c'era
  comportamento da preservare).

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
- **Fix applicato** (`rtl/neuron_parallel.v`, guard di elaborazione): esteso a
  `if (N_INPUTS == 0 || N_INPUTS % PARALLEL != 0)` — `N_INPUTS=0` ora fa fallire
  l'elaborazione con lo stesso errore `Unknown module type:
  neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL` dei due test negativi già
  esistenti, invece di elaborare con successo e produrre `start` silenziosamente ignorato.
- **Test di regressione**: `sim/neuron_parallel_bug002_n_inputs_zero_tb.v`, riscritto per
  asserire il fallimento di compilazione (stesso pattern di
  `neuron_parallel_guard_negative_*_tb.v`), aggiunto a `EXPECTED_COMPILE_FAIL` in
  `tools/run_regression.py`. Verificato: `iverilog -g2012 -o /tmp/out rtl/neuron_parallel.v sim/neuron_parallel_bug002_n_inputs_zero_tb.v` → errore di elaborazione atteso, exit code 3.
- **Stato**: **RISOLTO, verificato.**

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
- **Fix applicato** (`rtl/neuron_parallel.v`, dentro `if (start && !busy)`):
  `finishing <= (n_inputs_real == 16'h0);` (era `finishing <= 0;`) — riusa il percorso di
  completamento "finishing" già corretto ed esistente nel modulo invece di introdurre nuova
  logica per il caso degenere, stessa convenzione già usata altrove nel progetto. Per zero
  input reali il risultato matematico è `y = activation(bias)`: con `bias=0` e ACT_RELU nel
  test di regressione, `expect_y=0`.
- **Nota onestà**: il meccanismo esatto per cui il comportamento pre-fix variava tra
  ripetizioni (hang vs. risultato sbagliato silenzioso) **non è stato isolato bit-per-bit**
  neppure in fase di correzione — il fix è un early-out esplicito che bypassa
  l'intero percorso ambiguo, verificato corretto e deterministico sul nuovo comportamento,
  non una spiegazione a posteriori del vecchio meccanismo.
- **Test di regressione**: `sim/neuron_parallel_bug003_n_inputs_real_zero_tb.v` TEST 4,
  riscritto da osservazione ad asserzione hard (done entro 8 cicli, `y===0`). Verificato:
  `n_inputs_real=0` completa in **1 ciclo**, `y=0` — TUTTI I TEST PASSED (incluse le TEST
  1-3 di non-regressione sulla regione "poison").
- **Stato**: **RISOLTO, verificato** (il meccanismo esatto del comportamento PRE-fix resta
  non isolato per intero, per trasparenza, ma non è più rilevante: il nuovo percorso è
  deterministico e verificato indipendentemente).

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
- **Fix applicato** (`rtl/neuron_memory.v`, tre punti coordinati, non uno solo): il pattern
  vulnerabile esisteva in TRE punti distinti, non uno — scoperto durante la correzione stessa
  (un primo tentativo di guard solo al dispatch `STATE_IDLE`→`STATE_READ_X` è stato
  riconosciuto insufficiente perché copriva un solo dei tre punti d'ingresso nello stato
  vulnerabile `STATE_READ_W`, che viene rientrato indipendentemente una volta per neurone nel
  loop). Fix corretto (single-point-of-truth sulle CONDIZIONI di terminazione, non sui punti
  di dispatch): `STATE_READ_X` e `STATE_READ_W` guadagnano entrambe un prefisso
  `n_inputs_real == 16'h0 ||`/`n_neurons_real == 16'h0 ||` sulla propria condizione di
  terminazione, e il punto di transizione X→W guadagna un ramo esplicito
  `if (n_neurons_real == 16'h0) begin busy<=0; done<=1; state<=STATE_IDLE; end`.
- **Test di regressione**: `sim/neuron_memory_bug004_n_neurons_real_zero_tb.v` TEST 4,
  riscritto per asserire `done` entro il baseline a piena larghezza (`cyc_full`, stabilito
  dinamicamente da TEST 3). Verificato: `n_neurons_real=0` completa in **32 cicli** contro
  **155** per il build completo a 3 neuroni (X viene ancora letto una volta, condiviso tra
  neuroni, ma nessun calcolo per-neurone viene eseguito) — TUTTI I TEST PASSED.
- **Stato**: **RISOLTO, verificato** (stessa nota di onestà di BUG-003: il meccanismo esatto
  del comportamento PRE-fix — 114 vs 196 cicli a seconda di `N_NEURONS` — non è stato isolato
  bit-per-bit, ma il nuovo percorso è deterministico e verificato indipendentemente).

### BUG-005 (CRITICA, CONFERMATO) — `RUN_NETWORK(0)` esegue 256 layer fasulli leggendo dati arbitrari come descrittori

- **Sintomo**: `rtl/layer_sequencer.v` documenta `run_num_layers` come "1..N_LAYERS" ma
  **non esiste alcun guard**, né a tempo di elaborazione né a runtime, che lo imponga.
  `layer_idx` (riga 121) è un registro a 8 bit PIENO (non ristretto come il
  `group_index` a 1 bit di BUG-002) — per `run_num_layers=0`, la condizione di
  terminazione `layer_idx == num_layers_reg-1` (riga 303) avvolge a `layer_idx==255`, un
  valore che il contatore RAGGIUNGE naturalmente contando da 0. Risultato confermato
  empiricamente: **`RUN_NETWORK(0)` non si blocca — esegue tutti e 256 gli indici di
  layer possibili** (21761 cicli in simulazione) prima di terminare, ciascuno leggendo 11
  byte di "descrittore" da `table_base + layer_idx×11` — ben oltre la vera tabella
  descrittori (dimensionata per il build reale, tipicamente poche decine di byte) — e
  interpretando dati PSRAM arbitrari (pesi, altri dati di rete, o memoria non
  inizializzata) come indirizzi/parametri di layer validi, eseguendo run reali di
  `neuron_memory` con quei parametri e **scrivendo i risultati nei buffer ping-pong a
  indirizzi derivati da quei dati arbitrari**.
- **Causa radice**: nessun guard su `run_num_layers`, né a tempo di elaborazione (come
  invece esiste per `N_INPUTS%PARALLEL` in `neuron_parallel.v`) né a runtime (come invece
  esiste, sia pure incompleto, per `n_inputs_real`/`n_neurons_real`, BUG-003/004).
- **Evidenza**: `sim/layer_sequencer_bug005_zero_layers_tb.v` — `iverilog -g2012 -o /tmp/ls0.out rtl/layer_sequencer.v sim/layer_sequencer_bug005_zero_layers_tb.v && vvp /tmp/ls0.out` →
  `dut.layer_idx` termina a 255, non a 0.
- **Impatto pratico**: **più severo di BUG-002/003/004** — raggiungibile con un singolo
  opcode SPI documentato (`RUN_NETWORK`, `num_layers=0`) senza bisogno di ricompilare il
  bitstream né di impostare un valore "runtime" degenere in un percorso secondario; il
  rischio non è solo un risultato sbagliato o un hang, ma **scritture reali in PSRAM a
  indirizzi non controllati**, derivati da dati che non erano mai stati pensati per essere
  interpretati come indirizzi.
- **Fix applicato** (`rtl/layer_sequencer.v`, `ST_IDLE`): `run_num_layers==0` è ora un
  no-op esplicito e immediato — `seq_done` pulsa senza mai entrare in `ST_READ_DESC`,
  stessa convenzione già usata da `spi_engine.v` per `WRITE_RAM`/`READ_RAM` con `len==0`
  (accetta il comando, non fa nulla, nessun errore riportato).
- **Test di regressione**: `sim/layer_sequencer_bug005_zero_layers_tb.v`, riscritto da
  osservazione ad asserzione hard (seq_done entro 5 cicli, `layer_idx===0`). Verificato:
  `run_num_layers=0` completa in **1 ciclo** con `layer_idx` rimasto a 0 (era 21761 cicli,
  `layer_idx` terminato a 255, prima del fix) — PASS.
- **Stato**: **RISOLTO, verificato.**

### BUG-006 (BASSA, stessa causa radice di BUG-005, protezione incidentale) — `num_neurons_graph=0` in `graph_engine.v`

- **Sintomo/causa radice**: identica struttura a BUG-005 — `neuron_idx`
  (`rtl/graph_engine.v:159`) è un registro a 16 bit pieni, `num_neurons_graph=0` fa
  avvolgere la condizione di terminazione a un valore (65535) che il contatore raggiunge
  naturalmente. Nessun guard esplicito su `num_neurons_graph`.
- **Differenza da BUG-005**: `graph_engine` ha già un guard runtime per-edge
  (`src_id>=out_id`/`out_id>=N_TOTAL` → `err`) che, **come effetto collaterale non
  progettato per questo scopo**, cattura la maggior parte dei pattern di dati spazzatura
  molto rapidamente — verificato con un pattern non banale: `err` a 58 cicli, non 65536.
  `layer_sequencer.v` non ha alcuna protezione equivalente.
- **Evidenza**: `sim/graph_engine_bug006_zero_neurons_probe_tb.v` — finestra di 5000 cicli,
  non fatto girare a completamento (limite dichiarato, vedi
  `docs/validation/06-graph-engine.md` §6.2).
- **Impatto pratico**: basso ma non nullo — la protezione PRE-fix era incidentale, non
  garantita per ogni possibile contenuto PSRAM. Il buco strutturale era reale.
- **Fix applicato** (`rtl/graph_engine.v`, `ST_COPY_IN_WAIT`, alla transizione di fine copia
  input): `num_neurons_graph==0` è ora un no-op esplicito e immediato — `done` pulsa subito
  dopo il completamento della copia input, senza mai entrare in `ST_DESC_RD`/il loop
  descrittori, stessa convenzione del fix BUG-005.
- **Test di regressione**: `sim/graph_engine_bug006_zero_neurons_probe_tb.v`, riscritto da
  osservazione a asserzione hard (`done` entro 30 cicli, nessun `err`, `neuron_idx===0`).
  Verificato: `num_neurons_graph=0` completa in **13 cicli** senza `err`, `neuron_idx` rimasto
  a 0 (era 58 cicli tramite l'intercettazione incidentale del guard src_id/out_id, prima del
  fix) — PASS.
- **Stato**: **RISOLTO, verificato.**

### BUG-007 (CRITICA, CONFERMATO end-to-end via SPI reale) — `SET_NET_TYPE` durante un `RUN_NETWORK` in corso blocca permanentemente il motore in esecuzione

- **Sintomo**: `rtl/spi_engine.v`, stato `ST_SET_NET_TYPE`, accetta
  `net_type <= rx_byte` **incondizionatamente** su qualunque `rx_valid`, senza alcun
  controllo su `graph_busy`/`seq_busy`. `rtl/spi_neuron_top.v` (righe 394-397) instrada la
  Porta C dell'arbitro tra `graph_engine` e `layer_sequencer` in modo **puramente
  combinazionale** sul valore CORRENTE di `net_type` — non agganciato a quale motore ha
  effettivamente avviato il run in corso. Il commento alla riga 390 dichiara i due motori
  "mutually exclusive by construction", ma quella costruzione impedisce solo che **entrambi
  vengano avviati insieme** — non dice nulla su una scrittura di `net_type` che arriva a
  metà di un run già avviato.
- **Confermato end-to-end su SPI reale** (non solo per ispezione): avviato un
  `RUN_NETWORK` in modalità grafo (lo stesso grafo valido già certificato in
  `spi_neuron_top_graph_tb.v`), poi immediatamente — prima che completi — inviato
  `SET_NET_TYPE(dense)` via SPI. Risultato: **`STATUS.busy` resta bloccato a 1 per 400+
  letture consecutive, ~2.35ms di tempo simulato** (contro i ~12-25µs normali per quel
  grafo) — un hang permanente, non un rallentamento. Le transazioni SPI stesse (incl. il
  `SET_NET_TYPE` avversariale) completano regolarmente; è specificamente il motore grafo
  a restare bloccato in attesa di un `ram_ready` che non arriverà mai più tramite il
  percorso ormai scollegato dal mux.
- **Evidenza**: `sim/spi_neuron_top_bug007_mid_run_net_type_tb.v` — riproduce l'hang in
  modo deterministico e ripetibile su SPI reale (non solo un accesso interno).
- **Impatto pratico**: **il più severo finora insieme a BUG-005** — raggiungibile con due
  soli opcode SPI documentati emessi in sequenza ravvicinata (`RUN_NETWORK` seguito da
  `SET_NET_TYPE` prima del completamento), uno scenario host plausibile (es. un host che
  prepara la configurazione per il prossimo run senza attendere la fine del precedente,
  o una race a livello applicativo tra due richieste). Blocca l'inferenza in corso finché
  l'host non se ne accorge (nessun timeout hardware, nessun errore riportato — solo
  `STATUS.busy` che non si abbassa mai).
- **Recupero verificato**: un `RESET` inviato durante l'hang **riporta il sistema a uno
  stato pienamente funzionante** — verificato con una successiva operazione dense legittima
  completata normalmente (2 cicli di polling, esito corretto). **Non è un blocco
  permanente**, ma un host che si limita a fare polling di `STATUS` senza un timeout e un
  `RESET` di ripiego resterebbe bloccato indefinitamente comunque, dato che l'hardware non
  segnala mai da solo che qualcosa è andato storto.
- **Fix applicato** (`rtl/spi_engine.v`, `ST_SET_NET_TYPE`): `net_type <= rx_byte` ora
  condizionato a `if (!graph_busy && !seq_busy)` — la scrittura viene silenziosamente
  rifiutata (comando accettato via SPI come prima, ma senza effetto) mentre un run è in
  corso, invece di rimappare il mux dell'arbitro a metà esecuzione.
- **Test di regressione**: `sim/spi_neuron_top_bug007_mid_run_net_type_tb.v`, riscritto per
  asserire end-to-end su SPI reale sia (a) che il run in corso completi normalmente
  nonostante lo `SET_NET_TYPE` avversariale a metà esecuzione, sia (b) che la scrittura sia
  stata VERAMENTE rifiutata e non parzialmente applicata (una successiva `RUN_NETWORK` senza
  re-inviare `SET_NET_TYPE(graph)` completa comunque correttamente). Verificato: il run grafo
  completa con `out_base[0]=126` dopo 1 solo polling nonostante lo `SET_NET_TYPE(dense)`
  avversariale; `net_type` confermato ancora `GRAPH` internamente — PASS su entrambi i
  controlli.
- **Stato**: **RISOLTO, verificato end-to-end su SPI reale.**

---

## Verifica post-fix su entrambi i piani (§A.4)

Dopo l'applicazione di tutti e 7 i fix (RTL: `rtl/neuron_parallel.v`, `rtl/neuron_memory.v`,
`rtl/layer_sequencer.v`, `rtl/graph_engine.v`, `rtl/spi_engine.v`; rimozione:
`sim/top.v`):

- **Regressione Icarus completa** (`python3 tools/run_regression.py`): 44 testbench, **43
  PASS**, 0 FAIL/ERROR, 1 BENCHMARK (nessun verdetto per progetto, invariato). Nessuna
  regressione sui 37 test già certificati pre-fix.
- **Sintesi reale** (`yosys synth_ecp5`, sistema completo `spi_neuron_top` con sottosistema
  flash, PARALLEL=8, stessi file/comando già validati in Fase 15/F7 di WORKLOG.md): **0
  problemi CHECK**, 1 warning atteso/preesistente (tri-state limitato in
  `psram_controller.v`, invariato). TRELLIS_FF: 4900 (era 4855 — +45, coerente con la nuova
  logica di guard/controllo introdotta dai fix, nessuna crescita anomala).
- **Place&route reale** (`nextpnr-ecp5 --45k --package CABGA381 --speed 8 --freq 80
  --lpf synth/ecp5/spi_neuron_top.lpf`): **0 errori di vincolo, 0 pin non vincolati,
  "Program finished normally"**. Fmax: **68.65 MHz** (era 67.91 MHz — leggermente meglio,
  entro il rumore di piazzamento già documentato in Fase 7/WORKLOG.md, non una regressione).
  Percorso critico verificato esplicitamente **strutturalmente identico** a prima del fix:
  `u_neuron_memory.u_neuron.group_index` → `u_mac8` → catena di riporto CCU2C
  dell'accumulatore (`rtl/mac8.v`) — nessun modulo toccato dai fix (che sono tutti
  aggiunte al percorso di controllo, non al datapath MAC/accumulatore) compare nel
  percorso critico. Margine sull'oscillatore reale 16MHz: 4.29× (invariato).
  Log: `synth/ecp5/post_fix_verify/yosys.log`, `synth/ecp5/post_fix_verify/nextpnr.log`.

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
- **C.1 (falso "hang" iniziale, `neuron_parallel` config nota-buona)**: controllo tardivo e
  singolo di `done` (impulso di un solo ciclo) in uno script bespoke — non un problema
  dell'RTL. Vedi `docs/validation/01-datapath.md` §1.4.
- **C.2 (falso "hang" per `n_inputs_real=17`)**: stesso tipo di errore in un secondo script
  bespoke diverso da quello già provato — corretto riusando lo schema affidabile. Vedi
  `docs/validation/02-runtime-width.md` §2.2.
- **C.3 (falsi mismatch su 2048 controlli + un falso fallimento di round-trip)**: nel nuovo
  `sim/int8_memory_access_bytelane_tb.v`, un controllo dei segnali nello stesso passo di
  simulazione del loro aggiornamento non-bloccante (leggeva il valore dell'iterazione
  precedente), e uno stub di memoria comportamentale che ignorava le byte-lane
  `mem_lb_n`/`mem_ub_n` durante la scrittura. Entrambi difetti della testbench, non
  dell'RTL — vedi `docs/validation/03-memoria.md` §3.1.
- **C.4 (`mem_arbiter` mai concedeva nulla nella mia prima testbench)**: assegnazioni
  bloccanti per ritirare le richieste dei "perdenti" nello stesso fronte di clock che
  doveva concedere la richiesta — race reale con il blocco sincrono del DUT. Diagnosticato
  con `dut.owner` mai uscito da `SEL_NONE`. Corretto passando ad assegnazioni non bloccanti.
  Vedi `docs/validation/04-arbiter.md` §4.1.
