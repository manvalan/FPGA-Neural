# WORKLOG

## Fase: Setup sessione debug neuron_memory (2026-09-02)

- 2026-09-02T00:00 — [FASE 0] — Avviata sessione di debug su `neuron_memory`. Contesto fornito dall'utente: core di calcolo (neuron_parallel, mac8, mac_unit) considerato corretto e non da toccare; neuron_memory gestisce solo N_NEURONS=1; bug noto in sim/neuron_memory_tb.v su preload_vector/preload_weights (usavano `base + (k>>1)` invece di `(base>>1) + (k>>1)`).
- 2026-09-02T00:01 — [FASE 0] — `git status`: modifiche non committate su sim/neuron_memory.vcd, sim/neuron_memory_sim, sim/neuron_memory_tb.v (working tree su main).
- 2026-09-02T00:02 — [FASE 0] — `git diff sim/neuron_memory_tb.v`: confermato che il fix `(base >> 1) + (k >> 1)` è già presente nel working tree (non committato) sia in preload_vector che preload_weights. Aggiunto anche un nuovo task `preload_x_pattern` e un nuovo TEST 0 "PATTERN X=1..32" (somma 1..32 = 528, atteso saturato a 127).
- 2026-09-02T00:03 — [FASE 0] — Creato branch `fix/neuron-memory-debug` da main (non si lavora su main).
- 2026-09-02T00:04 — [FASE 0] — Letto rtl/neuron_memory.v per intero: FSM IDLE->READ_X->READ_W->READ_BIAS->START_N->WAIT_N. Nota: `access_mem_rdata` ricostruisce una parola a 16 bit da un singolo byte (`mem_rdata` esterno a 8 bit) usando `access_addr[0]` come selettore, per poi essere ri-decodificata dentro int8_memory_access con `addr_reg[0]` catturato alla request. Da verificare se il timing di `access_addr` (che avanza al prossimo indice nello stesso colpo di clock in cui `access_ready` viene consumato) possa disallinearsi da `addr_reg[0]` interno a int8_memory_access.
- 2026-09-02T00:05 — [FASE 0] — Letto rtl/int8_memory_access.v per intero: FSM IDLE/WAIT, converte addr byte->word (`addr>>1`), seleziona lb_n/ub_n in base a addr[0], estrae byte da mem_rdata in base a addr_reg[0] (registrato alla request, non al momento della ready) — quindi il rischio di disallineamento sopra ipotizzato non sussiste per l'estrazione interna a int8_memory_access, ma resta da verificare `access_mem_rdata` lato neuron_memory che usa `access_addr[0]` corrente (non registrato) nello stesso ciclo in cui int8_memory_access è ancora in STATE_WAIT.
- 2026-09-02T00:06 — [FASE 0] — Letto sim/neuron_memory_tb.v per intero: testbench end-to-end con memory_interface + psram_controller + psram_model reali (non mock), mux a singolo master (TB preload vs neuron_memory), 5 test (PATTERN, SUM, SATURATION, RELU, BIAS=10).
- 2026-09-02T00:10 — [FASE 1] — Compilato: `iverilog -g2012 -o sim/neuron_memory_sim rtl/*.v sim/psram_model.v sim/neuron_memory_tb.v`. Nessun errore/warning.
- 2026-09-02T00:11 — [FASE 1] — Eseguito: `vvp sim/neuron_memory_sim`. Risultato: TUTTI I 5 TEST PASSANO (PATTERN X=1..32 -> y=127 saturato correttamente; SUM=32 -> y=32; SATURATION -> y=127; RELU -> y=0; BIAS=10 -> y=42). Conferma che il fix `(base>>1)+(k>>1)` già presente nel working tree risolve correttamente l'indirizzamento byte->word nel preload e che neuron_memory.v (non modificato in questa sessione) è funzionalmente corretto per N_NEURONS=1 con questo pattern di test.
- 2026-09-02T00:12 — [FASE 1] — Analisi manuale del timing dell'handshake req/ready tra neuron_memory.v e int8_memory_access.v (in particolare `access_mem_rdata` che ricostruisce la word a 16 bit usando `access_addr[0]` corrente, non registrato): il redirect avviene un ciclo dopo che `access_req` diventa 1 quando `access_ready` è ancora alto, quindi `access_addr` non è stato ancora aggiornato al nuovo indice nel ciclo in cui `access_mem_rdata` viene consumato da int8_memory_access — nessuna race identificata. Confermato empiricamente anche dal test PATTERN X=1..32 che esercita 32 letture byte consecutive con parità alternata (indirizzi pari/dispari) e produce la somma corretta (528, satura a 127).
- 2026-09-02T00:15 — [FASE 2] — Eseguita regressione sugli altri testbench del repo per verificare che non ci fossero altri "test già eseguiti" rilevanti da esaminare:
  - int8_memory_access_tb: PASS (tutti i sotto-test)
  - memory_interface_tb: PASS
  - psram_controller_tb: PASS (2048 transazioni stress + byte enable)
  - int8_psram_integration_tb: PASS (incl. 2048 stress)
  - parametric_tb (256x4, PARALLEL=32): PASS (N0..N3, incl. ReLU e saturazione)
  - layer_tb: FALLISCE in elaborazione — `parameter FRAC_BITS not found in tb.dut`. Il testbench referenzia un parametro `FRAC_BITS` non più presente in rtl/layer.v (probabile debito tecnico da refactor precedente, indipendente da neuron_memory).
  - neuron_parallel_tb: FALLISCE in elaborazione — stesso errore, `parameter FRAC_BITS not found in tb.dut`, riferito a rtl/neuron_parallel.v.
  - NOTA: questi due fallimenti sono preesistenti e non toccano i file modificati in questa sessione (sim/neuron_memory_tb.v). Non risolti in questa sessione perché fuori scope dichiarato (debug neuron_memory); da segnalare all'utente.
- 2026-09-02T00:20 — [FASE 3] — CONCLUSIONE: il bug indirizzamento byte/word nei task preload_vector/preload_weights di sim/neuron_memory_tb.v era l'unico difetto riscontrato nel percorso neuron_memory; risulta già corretto nel working tree e validato con successo da tutti e 5 i test (incl. il nuovo test PATTERN aggiunto). Nessun bug residuo individuato in rtl/neuron_memory.v o rtl/int8_memory_access.v per il caso N_NEURONS=1. Procedo al commit del fix sul branch `fix/neuron-memory-debug`.
- 2026-09-02T00:21 — [FASE 4] — Committato (896f56c) il fix di sim/neuron_memory_tb.v + artefatti sim/neuron_memory_sim, sim/neuron_memory.vcd + WORKLOG.md sul branch fix/neuron-memory-debug. Ripristinati con `git checkout --` i .vcd di altri testbench (int8_memory_access, int8_psram_integration, memory_interface, parametric, psram_controller) rigenerati per errore durante la regressione, per non introdurre diff non pertinenti.
- 2026-09-02T00:25 — [FASE 5] — Contesto hardware fornito dall'utente durante la sessione (per riferimento futuro, non ancora usato in RTL/sim): FPGA target = Lattice ECP5 LFE5U-45F-8BG381C; PSRAM = ISSI IS66WVE4M16EBLL-70BLI; il controller esterno pilota il sistema FPGA+RAM via SPI, e accede alla RAM solo tramite la FPGA (mai in accesso diretto).
- 2026-09-02T00:26 — [FASE 6] — Richiesta utente: "sistema i due test e così chiudiamo" — riferito a sim/layer_tb.v e sim/neuron_parallel_tb.v, che fallivano in elaborazione con `parameter FRAC_BITS not found in tb.dut`.
- 2026-09-02T00:27 — [FASE 6] — Letto rtl/neuron_parallel.v per intero: DATA_WIDTH default 8, nessun parametro FRAC_BITS, ReLU (final_acc<=0 -> y=0) e saturazione positiva HARDCODED a `8'sd127` indipendentemente da DATA_WIDTH (nessuna saturazione negativa esplicita, solo ReLU). Confermato che il modulo non supporta più (e non ha mai realmente supportato in questa versione) il formato fixed-point Q8.8 a 16 bit assunto dai due testbench.
- 2026-09-02T00:28 — [FASE 6] — Letto rtl/layer.v per intero: parametrico, instanzia N_NEURONS x neuron_parallel con layout pesi neuron-major; nessun riferimento a FRAC_BITS.
- 2026-09-02T00:29 — [FASE 6] — Letto per intero sim/neuron_parallel_tb.v e sim/layer_tb.v (versioni obsolete, DATA_WIDTH=16, FRAC_BITS=8, valori Q8.8 via funzione q8_8(), saturazione attesa a ±32767): confermato che sono residui di una precedente architettura fixed-point a 16 bit, incompatibile con neuron_parallel.v attuale (core validato, da NON modificare).
- 2026-09-02T00:30 — [FASE 6] — Letto sim/parametric_tb.v (test già passante) come riferimento di stile/parametri corretti per l'architettura INT8 attuale (DATA_WIDTH=8, valori interi, saturazione a 127).
- 2026-09-02T00:35 — [FASE 6] — Riscritto interamente sim/neuron_parallel_tb.v: rimosso FRAC_BITS e funzione q8_8; parametri allineati ai default di rtl/neuron_parallel.v (DATA_WIDTH=8, N_INPUTS=32, PARALLEL=8, ACC_WIDTH=32); 4 test ridisegnati con valori interi INT8 mantenendo lo stesso intento dei test originali:
  - TEST 1 DIVERSE VECTOR: x0=3,w0=2 / x1=4,w1=-1 / x2=2,w2=1 / bias=1 -> atteso 5.
  - TEST 2 RELU: tutti i prodotti negativi (x=1,w=-1 su 32 input) -> atteso 0.
  - TEST 3 POSITIVE SATURATION: x=100,w=2 su 32 input -> somma 6400, satura a 127.
  - TEST 4 MIXED + NEGATIVE BIAS: 16 input pari (x=2,w=1) + 16 dispari (x=-1,w=1), bias=-16 -> somma esattamente 0 -> ReLU -> atteso 0.
- 2026-09-02T00:40 — [FASE 6] — Riscritto interamente sim/layer_tb.v: rimosso FRAC_BITS; parametri DATA_WIDTH=8, N_INPUTS=32, N_NEURONS=8, PARALLEL=8, ACC_WIDTH=32; input vettore tutti =1; 8 neuroni con scenari distinti (pattern ispirato a parametric_tb.v):
  - N0 w=1,bias=0 -> 32
  - N1 w=3,bias=0 -> 96
  - N2 w=-1 -> ReLU -> 0
  - N3 w=8 -> somma 256 -> satura 127
  - N4 w=0,bias=+5 -> 5
  - N5 w=0,bias=-5 -> ReLU -> 0
  - N6 w=1,bias=-10 -> 32-10=22
  - N7 primi 16 pesi=1 resto 0, bias=+5 -> 16+5=21 (verifica pattern di pesi sparso su più gruppi, PARALLEL=8 -> GROUPS=4)
- 2026-09-02T00:42 — [FASE 6] — Compilato ed eseguito `sim/neuron_parallel_tb.v`: `iverilog -g2012 -o <tmp> rtl/*.v sim/neuron_parallel_tb.v` + `vvp`. Risultato: TUTTI I 4 TEST PASSANO (TEST1=5, TEST2=0, TEST3=127, TEST4=0).
- 2026-09-02T00:43 — [FASE 6] — Compilato ed eseguito `sim/layer_tb.v`: `iverilog -g2012 -o <tmp> rtl/*.v sim/layer_tb.v` + `vvp`. Risultato: TUTTI GLI 8 NEURONI PASSANO (32,96,0,127,5,0,22,21), busy=0, done=1 a fine test.
- 2026-09-02T00:44 — [FASE 6] — Rigenerati gli artefatti tracciati in git `sim/neuron_sim` (da neuron_parallel_tb.v) e `sim/layer_sim` (da layer_tb.v) con i relativi `.vcd`, per coerenza con la convenzione del repo di committare i binari di simulazione insieme alle sorgenti.
- 2026-09-02T00:45 — [FASE 7] — Nessuna modifica a rtl/ in questa fase: root cause dei due fallimenti era esclusivamente nei testbench (riferimento a un parametro FRAC_BITS rimosso da tempo dall'RTL), non nel core di calcolo. Sessione di debug neuron_memory + fix dei due test residui considerata chiusa.

## Fase: Roadmap Fase 2 — Parameter Sweep (2026-09-02)

- 2026-09-02T01:00 — [FASE 8] — Utente: "passiamo a fase 1 (o successiva)". Chiarito (dopo scambio) che il riferimento è al roadmap ufficiale in docs/FPGA-NeuralNetwork-Engine.md (sezione 15, "Development Roadmap"), da seguire come percorso vincolante. Letta la roadmap: Fase 1 (Parametric Layer) risulta già completamente spuntata; Fase 2 (Parameter Sweep) non ancora affrontata: "Validate multiple combinations of N_INPUTS/N_NEURONS/PARALLEL, including configurations where the number of inputs is not an exact multiple of the parallelism."
- 2026-09-02T01:02 — [FASE 8] — Letto rtl/mac8.v per intero: PARALLEL deve essere potenza di 2 (adder tree binario con $clog2(PARALLEL) livelli). Nessun vincolo esplicito che N_INPUTS sia multiplo di PARALLEL.
- 2026-09-02T01:03 — [FASE 8] — Ri-analizzato rtl/neuron_parallel.v: `localparam GROUPS = N_INPUTS / PARALLEL;` è divisione INTERA. Ipotesi: se N_INPUTS non è multiplo esatto di PARALLEL, gli input residui (N_INPUTS - GROUPS*PARALLEL) non vengono mai letti dall'accumulatore (nessun errore/warning a compile o runtime). Ipotesi aggiuntiva: se PARALLEL > N_INPUTS, GROUPS=0 e la condizione di terminazione del controller (`group_index == GROUPS-1`) non è mai soddisfatta -> hang permanente (busy=1, done mai asserito).
- 2026-09-02T01:10 — [FASE 8] — Creato sim/parameter_sweep_tb.v: 5 istanze di neuron_parallel con configurazioni diverse (CONFIG A..E), watchdog a ciclo (max 500 cicli, nessun `wait` bloccante) per evitare hang reale della simulazione anche nel caso patologico:
  - A: N_INPUTS=32 PARALLEL=8 (esatto, sanity check, atteso y=32)
  - B: N_INPUTS=30 PARALLEL=8 (non esatto, GROUPS=3, atteso y=24 per troncamento RTL vs somma piena=30)
  - C: N_INPUTS=20 PARALLEL=16 (non esatto, GROUPS=1, atteso y=16 per troncamento RTL vs somma piena=20)
  - D: N_INPUTS=64 PARALLEL=32 (esatto, sanity check, atteso y=64)
  - E: N_INPUTS=4 PARALLEL=8 (degenere, GROUPS=0, atteso TIMEOUT/hang)
- 2026-09-02T01:12 — [FASE 8] — Compilato: `iverilog -g2012 -o <tmp> rtl/*.v sim/parameter_sweep_tb.v`. Nessun errore (anche il part-select fuori range in CONFIG E, dovuto a x_bus/w_bus da 32 bit letti come blocchi da 64 bit dentro neuron_parallel, non causa errore di elaborazione in Icarus).
- 2026-09-02T01:13 — [FASE 8] — Eseguito `vvp`. RISULTATI (tutti confermano le ipotesi):
  - CONFIG A: PASS, y=32.
  - CONFIG B: y=24 (non 30) -> confermato troncamento silenzioso, 6 input su 30 ignorati.
  - CONFIG C: y=16 (non 20) -> confermato troncamento silenzioso, 4 input su 20 ignorati.
  - CONFIG D: PASS, y=64.
  - CONFIG E: TIMEOUT confermato -> done mai asserito entro 500 cicli, hang reale per PARALLEL > N_INPUTS (GROUPS=0).
  - Sweep complessivo: errors=0 (nessun comportamento imprevisto rispetto alle ipotesi), findings=3 (troncamento non-multiplo x2, hang degenerato x1).
- 2026-09-02T01:15 — [FASE 8] — Rigenerato artefatto tracciato sim/parameter_sweep_sim + sim/parameter_sweep.vcd per coerenza con la convenzione del repo.
- 2026-09-02T01:16 — [FASE 8] — Nessuna modifica a rtl/neuron_parallel.v in questa fase (core di calcolo non toccato, come da policy di progetto). I due limiti trovati (troncamento su non-multiplo, hang su PARALLEL>N_INPUTS) sono documentati come "Findings" nella Fase 2 della roadmap (docs/FPGA-NeuralNetwork-Engine.md) e proposti come azione futura per Fase 3/7, non risolti ora.
- 2026-09-02T01:18 — [FASE 8] — Aggiornato docs/FPGA-NeuralNetwork-Engine.md, sezione "## Phase 2 — Parameter Sweep": aggiunta checklist di completamento e sezione "Findings" con i due limiti documentati sopra.

## Fase: Fix dei findings di Fase 2 (guardia elaboration-time) (2026-09-02)

- 2026-09-02T02:00 — [FASE 9] — Utente chiede se i due finding di Fase 2 (troncamento su N_INPUTS non multiplo di PARALLEL; hang su PARALLEL>N_INPUTS) siano errori da correggere o si possano lasciare, segnalando che dai benchmark PARALLEL=2 dà i risultati migliori (PARALLEL=4 leggermente meno) — vedi docs/FPGA-Neural-Datapatch-Benchmark.md.
- 2026-09-02T02:02 — [FASE 9] — Letto docs/FPGA-Neural-Datapatch-Benchmark.md, tabella comparativa (§13, N_INPUTS=256, N_NEURONS=4): PARALLEL=16 FAIL (52.13 MHz), PARALLEL=8 FAIL (61.71 MHz), PARALLEL=4 FAIL (75.01 MHz), PARALLEL=2 PASS (87.88 MHz, unico sopra 80 MHz). Confermato che N_INPUTS e PARALLEL sono parametri Verilog fissati in fase di sintesi (non registri configurabili via SPI a runtime): il rischio dei due finding è quindi "errore di chi istanzia il modulo per un certo layer", non un rischio da campo/runtime.
- 2026-09-02T02:05 — [FASE 9] — Analisi di rischio comunicata all'utente: Finding 2 (hang, PARALLEL>N_INPUTS) trascurabile con PARALLEL reale=2/4 (richiederebbe un layer con 1-3 input, non realistico). Finding 1 (troncamento silenzioso) più concreto: con PARALLEL=2 basta un N_INPUTS dispari per perdere silenziosamente l'ultimo input, senza segnalazione — proposta una guardia a elaboration-time (nessuna modifica al datapath validato).
- 2026-09-02T02:10 — [FASE 9] — Proposta dettagliata verificata isolatamente PRIMA di toccare l'RTL: creato in scratchpad un modulo di test con blocco `generate` che istanzia un modulo indefinito `neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL` quando `N_INPUTS % PARALLEL != 0`. Compilato con Icarus (`iverilog -g2012`) sia con parametri validi (32/8, exit=0, nessun errore) sia invalidi (30/8, exit=1, errore "Unknown module type: neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL"). Idioma confermato portabile (standard Verilog generate + elaborazione modulo, non system task da simulazione tipo $error/$fatal che i tool di sintesi spesso ignorano).
- 2026-09-02T02:15 — [FASE 9] — Presentata la proposta all'utente (unica modifica prevista: blocco `generate` in rtl/neuron_parallel.v, nessun'altra riga toccata) e chiesta conferma esplicita prima di modificare il core "validato/non riscrivere" secondo la policy di progetto stabilita a inizio sessione.
- 2026-09-02T02:20 — [FASE 9] — Utente autorizza ESPLICITAMENTE e SOLO per questa modifica a toccare ciò che era dichiarato fisso ("core is correct, don't touch/rewrite"), con richiesta di annotazione dettagliata nel log (questa sezione).
- 2026-09-02T02:22 — [FASE 9] — MODIFICA A rtl/neuron_parallel.v: inserito blocco `generate` subito prima di `localparam GROUPS = N_INPUTS / PARALLEL;`:
  ```verilog
  generate
      if (N_INPUTS % PARALLEL != 0) begin : PARAMETER_ERROR_N_INPUTS_NOT_MULTIPLE_OF_PARALLEL
          neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL invalid_parameter_combination();
      end
  endgenerate
  ```
  Nessun'altra riga del file toccata. Il datapath di calcolo (mac8, accumulo, bias, ReLU, saturazione) è invariato. Per configurazioni valide (N_INPUTS%PARALLEL==0) il ramo generate non viene mai elaborato: zero impatto.
- 2026-09-02T02:25 — [FASE 9] — REGRESSIONE COMPLETA post-modifica, per verificare che nessuna configurazione valida esistente sia stata rotta. Compilato ed eseguito con `iverilog -g2012 -o <tmp> rtl/*.v [sim/psram_model.v] sim/<tb>.v` + `vvp`:
  - int8_memory_access_tb: PASS (non usa neuron_parallel, invariato)
  - layer_tb: PASS - ALL 8 NEURONS (N_INPUTS=32 PARALLEL=8, esatto)
  - memory_interface_tb: PASS (non usa neuron_parallel, invariato)
  - neuron_parallel_tb: PASS - ALL TESTS PASSED (N_INPUTS=32 PARALLEL=8, esatto)
  - parametric_tb: PASS (N_INPUTS=256 PARALLEL=32, esatto)
  - psram_controller_tb: PASS (non usa neuron_parallel, invariato)
  - int8_psram_integration_tb: PASS (non usa neuron_parallel, invariato)
  - neuron_memory_tb: PASS, tutti e 5 i test (N_INPUTS=32 PARALLEL=8, esatto)
  Nessuna regressione: tutte le configurazioni preesistenti erano già multipli esatti, quindi il ramo `generate` della guardia non si attiva mai per esse.
- 2026-09-02T02:30 — [FASE 9] — Creati due test NEGATIVI dedicati (devono FALLIRE la compilazione per definizione, quello è il test):
  - sim/neuron_parallel_guard_negative_nonmultiple_tb.v: istanzia neuron_parallel con N_INPUTS=30, PARALLEL=8 (il caso di troncamento del Finding 1).
  - sim/neuron_parallel_guard_negative_degenerate_tb.v: istanzia neuron_parallel con N_INPUTS=4, PARALLEL=8 (il caso di hang/Finding 2).
  Ogni file contiene nell'header il comando esatto di verifica e l'errore atteso, per poter essere ri-eseguito manualmente in futuro come regressione "negativa" (nessun binario/vcd generabile per questi, dato che l'elaborazione fallisce sempre by design).
- 2026-09-02T02:32 — [FASE 9] — Eseguita verifica di entrambi i test negativi: `iverilog -g2012 -o <tmp> rtl/*.v sim/neuron_parallel_guard_negative_nonmultiple_tb.v` -> exit=1, errore "Unknown module type: neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL" a rtl/neuron_parallel.v:45. Stesso esito identico per la variante degenerate_tb.v. Confermato: la guardia scatta per ENTRAMBI i finding con lo stesso, unico controllo (`N_INPUTS % PARALLEL != 0` intercetta sia il troncamento sia il caso degenere PARALLEL>N_INPUTS, perché quest'ultimo implica resto non nullo salvo N_INPUTS=0).
- 2026-09-02T02:40 — [FASE 9] — Riscritto sim/parameter_sweep_tb.v: rimosse le CONFIG B, C, E (non più compilabili per design, la loro copertura "negativa" è ora nei due file dedicati sopra). Aggiunte due nuove config valide allineate ai risultati reali del benchmark ECP5:
  - CONFIG F: N_INPUTS=32 PARALLEL=2 (GROUPS=16) — configurazione a timing migliore (87.88 MHz, unica PASS a 80MHz nel benchmark).
  - CONFIG G: N_INPUTS=32 PARALLEL=4 (GROUPS=8) — seconda scelta per timing.
  Mantenute CONFIG A (32/8) e D (64/32) come sanity check di regressione. Rimosso il watchdog a ciclo (non più necessario: la guardia elimina la possibilità di hang per qualunque config che compili).
- 2026-09-02T02:42 — [FASE 9] — Compilato ed eseguito sim/parameter_sweep_tb.v aggiornato: TUTTE E 4 LE CONFIG PASSANO (A: y=32, D: y=64, F: y=32 con PARALLEL=2, G: y=32 con PARALLEL=4). Rigenerati gli artefatti tracciati sim/parameter_sweep_sim e sim/parameter_sweep.vcd.
- 2026-09-02T02:45 — [FASE 9] — Aggiornato docs/FPGA-NeuralNetwork-Engine.md, sezione "## Phase 2 — Parameter Sweep": la sezione "Findings" è stata aggiornata da "non ancora risolti" a "FIXED (2026-09-02)", con descrizione della guardia, riferimento ai due test negativi e al nuovo sweep positivo con PARALLEL=2/4.
- 2026-09-02T02:46 — [FASE 9] — CONCLUSIONE: entrambi i finding di Fase 2 sono ora chiusi tramite un'unica guardia a elaboration-time in rtl/neuron_parallel.v, verificata sia in positivo (nessuna regressione sulle config valide esistenti + nuove config F/G con PARALLEL=2/4) sia in negativo (entrambi i casi patologici falliscono ora la compilazione con un errore esplicito invece di produrre un risultato silenziosamente errato o un hang). Modifica autorizzata esplicitamente dall'utente in deroga alla policy "core non toccare", limitata a questo unico blocco generate.

## Fase: Merge/push in main + cleanup branch (2026-09-02)

- 2026-09-02T03:00 — [FASE 10] — Utente: "poi visto che questo è validato allinea il main." Eseguito `git checkout main` + `git merge --ff-only fix/neuron-memory-debug`: fast-forward pulito (16769ea..1a6f0ba), nessun conflitto, nessuna modifica al working tree oltre al merge. Riepilogati i 4 commit portati su main.
- 2026-09-02T03:05 — [FASE 10] — Utente: "fai pure" (autorizzazione a pushare). Eseguito `git push origin main`: push riuscito, origin/main allineato a 1a6f0ba.
- 2026-09-02T03:10 — [FASE 10] — Utente: "in locale elimina pure il branch neuron-memory-debug". Eseguito `git branch -d fix/neuron-memory-debug` (delete sicuro, branch già interamente mergiato in main, nessuna perdita di lavoro). Rimane solo `main` in locale.

## Fase: Fase 3 roadmap — neuron_memory multi-neurone (2026-09-02)

- 2026-09-02T03:20 — [FASE 11] — Utente: "poi prossimo punto". Consultato docs/FPGA-NeuralNetwork-Engine.md sezione 15: Fase 1 e Fase 2 chiuse/spuntate. Fase 3 (Memory Architecture) è il prossimo punto del roadmap, e coincide con il limite esplicitamente segnalato nel contesto iniziale della sessione: "neuron_memory è l'integrazione memoria→neurone. Attualmente gestisce solo N_NEURONS=1." Deciso di procedere con l'estensione multi-neurone di neuron_memory.v come primo task concreto di Fase 3.
- 2026-09-02T03:21 — [FASE 11] — Utente interviene a promemoria: "ricorda quanto ti ho incollato nelle istruzioni precise" — riconfermati i vincoli originali della sessione: NON toccare neuron_parallel/mac8/mac_unit (core validato — a parte la guardia già autorizzata in Fase 9, non riaperta qui), rispettare la convenzione indirizzi BYTE con conversione mem_addr<=addr>>1, rispettare il layout pesi NEURON-MAJOR di layer.v (weights_bus[n*N_INPUTS*DATA_WIDTH +: N_INPUTS*DATA_WIDTH], bias contigue per neurone), e mantenere il log dettagliato per ogni fase. neuron_memory.v stesso NON è nella lista dei moduli "non toccare" — è esplicitamente il modulo da estendere.
- 2026-09-02T03:25 — [FASE 11] — Letto integralmente rtl/neuron_memory.v (stato pre-modifica, invariato dall'inizio sessione): FSM STATE_IDLE->READ_X->READ_W->READ_BIAS->START_N->WAIT_N, un solo neuron_parallel instanziato, output singolo `y` a 8 bit, nessun parametro N_NEURONS.
- 2026-09-02T03:30 — [FASE 11] — DECISIONE DI PROGETTO: implementazione memory-bound (non compute-parallel). Un solo neuron_parallel viene riusato in sequenza per ciascun neurone: X viene letto UNA VOLTA (condiviso, è l'input del layer), mentre W e bias vengono ri-letti da PSRAM per ciascun neurone in turno, seguendo il layout neuron-major già usato da layer.v (pesi neurone n a w_base+n*N_INPUTS byte, bias neurone n a bias_addr+n byte). Motivazione: Fase 3 del roadmap è esplicitamente "Memory Architecture", quindi la sequenza memory-bound è la scelta naturale (throughput/parallelismo di calcolo sono oggetto della Fase 7 - Optimization); istanziare N_NEURONS neuron_parallel in parallelo (come fa layer.v) avrebbe richiesto anche N_NEURONS canali di memoria/prefetch, fuori scope per questo step.
- 2026-09-02T03:35 — [FASE 11] — MODIFICHE A rtl/neuron_memory.v (uniche modifiche di questa fase, nessun'altra riga toccata in nessun altro modulo core):
  1. Aggiunto parametro `N_NEURONS = 1` (default 1 per retrocompatibilità totale).
  2. Porta di output `output reg signed [7:0] y` sostituita con `output wire signed [DATA_WIDTH*N_NEURONS-1:0] y_bus` (packed, neuron-major, stessa convenzione di layer.v).
  3. Aggiunti registri: `neuron_index` (larghezza $clog2(N_NEURONS), stesso pattern di GROUP_INDEX_WIDTH in neuron_parallel.v), `w_group_base` e `bias_group_addr` (ADDR_WIDTH bit, tracciano l'indirizzo base del neurone corrente), array `y_reg[0:N_NEURONS-1]` per l'output per-neurone.
  4. Aggiunto blocco `generate` che assembla y_bus da y_reg[] (stesso pattern già usato per x_bus/w_bus da x_mem/w_mem).
  5. STATE_IDLE: su `start`, inizializza neuron_index<=0, w_group_base<=w_base, bias_group_addr<=bias_addr (oltre alla logica preesistente di avvio lettura X).
  6. STATE_READ_X: a fine lettura (index==N_INPUTS-1), l'indirizzo per iniziare READ_W ora usa `w_group_base` invece di `w_base` diretto (equivalenti per il neurone 0, ma necessario per generalizzare).
  7. STATE_READ_W: indirizzi calcolati da `w_group_base` invece di `w_base`; a fine lettura pesi, transizione a READ_BIAS con indirizzo `bias_group_addr` invece di `bias_addr` diretto.
  8. STATE_WAIT_N: riscritta. Al completamento del neurone corrente (`neuron_done`), salva `y_reg[neuron_index] <= neuron_y`. Se `neuron_index == N_NEURONS-1` (ultimo neurone del layer): busy<=0, done<=1, torna a IDLE (comportamento identico al precedente per N_NEURONS=1). Altrimenti: incrementa neuron_index, avanza w_group_base di N_INPUTS byte e bias_group_addr di 1 byte, azzera index, avvia una nuova richiesta di lettura pesi (access_addr<=w_group_base+N_INPUTS, cioè il nuovo base) e torna a STATE_READ_W per il neurone successivo — X in x_mem NON viene ricaricato (condiviso).
  9. Reset: aggiunto reset esplicito di neuron_index, w_group_base, bias_group_addr, e di tutto l'array y_reg[] (tramite un `integer rst_i` e un for-loop, dato che y_reg è un array e non può essere azzerato con un singolo `<= 0`).
- 2026-09-02T03:40 — [FASE 11] — Verifica di correttezza degli indirizzi a mente prima della compilazione: per N_NEURONS=1 (default), neuron_index resta sempre 0, w_group_base=w_base e bias_group_addr=bias_addr per l'intera esecuzione -> comportamento bit-identico alla versione precedente. Per N_NEURONS>1, w_group_base/bias_group_addr vengono aggiornati SOLO nella transizione WAIT_N->READ_W (una volta per neurone, non per byte), quindi restano stabili per tutta la durata della lettura di quel neurone.
- 2026-09-02T03:42 — [FASE 11] — Compilazione di verifica: `iverilog -g2012 -o <tmp> rtl/*.v sim/psram_model.v sim/neuron_memory_tb.v` (tb esistente, non ancora aggiornato) -> ERRORE atteso: "port `y` is not a port of u_neuron" (il tb referenziava ancora la vecchia porta `y`).
- 2026-09-02T03:44 — [FASE 11] — Aggiornato sim/neuron_memory_tb.v: aggiunta esplicita `.N_NEURONS(1)` all'istanziazione (documenta l'intento, comportamento invariato essendo il default), e connessione porta cambiata da `.y(y)` a `.y_bus(y)` (il segnale interno del tb resta chiamato `y`, larghezza 8 bit compatibile con N_NEURONS=1). Nessun'altra riga del tb toccata.
- 2026-09-02T03:46 — [FASE 11] — Ricompilato ed eseguito sim/neuron_memory_tb.v: TUTTI E 5 I TEST PASSANO INVARIATI (PATTERN X=1..32=127, SUM=32, SATURATION=127, RELU=0, BIAS=10=42) — confermata retrocompatibilità totale per N_NEURONS=1.
- 2026-09-02T03:50 — [FASE 11] — Creato sim/neuron_memory_multi_tb.v: nuovo testbench dedicato, copia della struttura end-to-end di neuron_memory_tb.v (memory_interface + psram_controller + psram_model reali, mux a singolo master), che instanzia neuron_memory con N_NEURONS=3, N_INPUTS=32. Nuovi task: preload_x (X condiviso), preload_weights_n(base, n, value) (scrive i pesi del neurone n a w_base+n*32 byte), preload_bias_3(base, b0, b1, b2) (scrive le 3 bias contigue, impacchettando b0/b1 in una word e b2 nella successiva). Test case:
  - X condiviso = 1 (32 elementi)
  - Neurone 0: W=1, bias=0 -> atteso 32
  - Neurone 1: W=2, bias=0 -> atteso 64
  - Neurone 2: W=-1, bias=0 -> somma -32 -> ReLU -> atteso 0
  Scelto per coprire: valore normale, valore più grande ma senza saturazione, e ReLU — validando in particolare che l'indirizzamento per-neurone (w_base+n*32, bias_addr+n) sia corretto e che `done` scatti una sola volta alla fine dell'intera sequenza (non per singolo neurone).
- 2026-09-02T03:55 — [FASE 11] — Compilato ed eseguito sim/neuron_memory_multi_tb.v: PASS AL PRIMO TENTATIVO. Neurone0=32 (atteso 32), Neurone1=64 (atteso 64), Neurone2=0 (atteso 0), busy=0 dopo done. Nessun bug di indirizzamento o di sequenza riscontrato.
- 2026-09-02T04:00 — [FASE 11] — REGRESSIONE COMPLETA finale: ricompilati ed eseguiti TUTTI i testbench del repo (int8_memory_access_tb, layer_tb, memory_interface_tb, neuron_parallel_tb, parametric_tb, psram_controller_tb, int8_psram_integration_tb, neuron_memory_tb, parameter_sweep_tb, neuron_memory_multi_tb) — TUTTI PASS. Ri-verificati anche i due test negativi della guardia Fase 9 (neuron_parallel_guard_negative_*): entrambi falliscono l'elaborazione come atteso, invariati (neuron_parallel.v non è stato toccato in questa fase).
- 2026-09-02T04:05 — [FASE 11] — Rigenerati gli artefatti tracciati sim/neuron_memory_sim + sim/neuron_memory.vcd (contenuto aggiornato dal nuovo N_NEURONS(1) esplicito) e creati i nuovi sim/neuron_memory_multi_sim + sim/neuron_memory_multi.vcd. Ripristinati con `git checkout --` i .vcd di testbench non pertinenti (int8_memory_access, int8_psram_integration, layer, memory_interface, neuron_parallel, parameter_sweep, parametric, psram_controller) rigenerati per effetto collaterale della regressione, per non introdurre diff non pertinenti.
- 2026-09-02T04:10 — [FASE 11] — Aggiornato docs/FPGA-NeuralNetwork-Engine.md, sezione "## Phase 3 — Memory Architecture": aggiunta checklist (single-neuron e multi-neuron chiusi; buffer intermedi multi-layer e analisi di banda esplicitamente rimandati rispettivamente a Fase 5 e Fase 7) e paragrafo descrittivo del design memory-bound scelto, con riferimento ai file di test.
- 2026-09-02T04:11 — [FASE 11] — CONCLUSIONE: neuron_memory.v supporta ora N_NEURONS>=1 in modo generico, validato end-to-end sia per il caso singolo-neurone (retrocompatibile, 5/5 test) sia multi-neurone (nuovo test dedicato, 3/3 neuroni corretti). Nessuna modifica al core di calcolo validato (neuron_parallel/mac8/mac_unit). Prossimo punto naturale di Fase 3 seguendo il roadmap: buffer di input/output e requisiti di banda, oppure passaggio a Fase 4 (interfaccia SPI) — da concordare con l'utente.
- 2026-09-02T04:15 — [FASE 11] — Merge/push: `git checkout main` + `git merge --ff-only feat/neuron-memory-multi-neuron` (fast-forward pulito 1a6f0ba..661363f) + `git push origin main` + `git branch -d feat/neuron-memory-multi-neuron`. main allineato e pushato, branch locale ripulito.

## Fase: Definizione protocollo SPI (Fase 4 roadmap, solo design) (2026-09-02)

- 2026-09-02T04:20 — [FASE 12] — Utente: "per interfaccia SPI occorre però che definiamo bene i protocolli e i comandi" — richiesta esplicita di FASE DI DESIGN prima di qualunque RTL per la Fase 4. Nessuna modifica a codice in questa fase.
- 2026-09-02T04:22 — [FASE 12] — Letto docs/FPGA-NeuralNetwork-Engine.md sezione "# 8. Host Interface" (già esistente): conteneva solo uno schema concettuale ad alto livello (RESET->CONFIGURE->LOAD PARAMS->LOAD WEIGHTS->LOAD BIASES->LOAD INPUT->START->WAIT DONE->READ OUTPUT) senza opcode, framing o register map concreti. Letta anche sezione "# 9. Dedicated FPGA RAM" per contesto su cosa la RAM deve contenere (pesi, bias, buffer input/output/intermedi, parametri rete).
- 2026-09-02T04:25 — [FASE 12] — Proposta iniziale (bozza v1) presentata all'utente: framing SPI byte-oriented con opcode da 1 byte, tabella comandi (NOP, WRITE_RAM, READ_RAM, SET_BASE, START, STATUS, READ_OUTPUT, READ_CONFIG) ancorata alle porte reali di rtl/neuron_memory.v (x_base/w_base/bias_addr come indirizzi BYTE a 22 bit, y_bus N_NEURONS*8 bit, N_INPUTS/N_NEURONS/PARALLEL fissati a sintesi).
- 2026-09-02T04:27 — [FASE 12] — Poste 2 domande di decisione architetturale via AskUserQuestion (non derivabili dal codice esistente, impattano la complessità del controller SPI e il firmware host):
  1. WRITE_RAM/READ_RAM: lunghezza esplicita nel comando vs streaming fino a rilascio di CS -> utente ha scelto LUNGHEZZA ESPLICITA (campo len a 2 byte, il controller SPI usa un contatore invece di rilevare il fronte di CS a metà trasferimento).
  2. Serve READ_CONFIG per esporre N_INPUTS/N_NEURONS/PARALLEL/ADDR_WIDTH a runtime, o il firmware host li assume fissi per bitstream -> utente ha scelto SÌ, READ_CONFIG (stesso firmware riusabile su bitstream diversi, coerente con l'obiettivo dichiarato nel doc di un protocollo indipendente dall'host).
- 2026-09-02T04:30 — [FASE 12] — Utente ha incollato la tabella comandi (identica a quella proposta) e chiesto esplicitamente: "terrei separato NOP con RESET" — richiesta di un opcode RESET dedicato, distinto da NOP (nella bozza iniziale RESET non era stato assegnato come opcode separato). Aggiunto opcode 0x0F = RESET: impulso di reset sincrono verso il motore di calcolo (neuron_memory) + pulizia del bit STATUS.done latched; NON cancella il contenuto della PSRAM (chiarito esplicitamente nello spec per evitare ambiguità).
- 2026-09-02T04:32 — [FASE 12] — Utente ha poi precisato: "questi sono esempi" — la tabella/i valori di opcode incollati sono da intendersi come ESEMPIO/bozza, non definitivi. Aggiornata la sezione nel doc da "defined/agreed" a "draft", specificando esplicitamente quali parti sono da considerarsi solide (framing MSB-first, lunghezza esplicita, STATUS.done sticky/clear-on-read, presenza di READ_CONFIG) vs quali sono ancora aperte a revisione (valori esatti degli opcode, set di comandi).
- 2026-09-02T04:35 — [FASE 12] — NOTA TECNICA IMPORTANTE identificata e documentata nello spec: in rtl/neuron_memory.v il segnale `done` è un impulso di UN SOLO CICLO di clock (asserito solo nello stato STATE_WAIT_N terminale, poi resettato al ciclo successivo dalla logica di default-pulse). Un host che fa polling via SPI (ordini di grandezza più lento del clock FPGA) lo perderebbe quasi certamente se il registro STATUS lo campionasse "al volo". Documentato che il register-bank SPI DEVE catturare `done` in un bit STICKY (latched sul fronte dell'impulso, azzerato alla lettura di STATUS o su RESET), non campionare il segnale raw — requisito di design per la futura implementazione RTL della Fase 4, non ancora implementato.
- 2026-09-02T04:40 — [FASE 12] — Scritta la spec completa in docs/FPGA-NeuralNetwork-Engine.md, nuova sezione "## 8.1 SPI Protocol v1 (draft, 2026-09-02)": fisico (SPI mode 0, MSB-first, single SPI, un comando per ciclo di CS), convenzione campi multi-byte big-endian, indirizzi a 3 byte (ADDR_WIDTH=22 bit + 2 bit riservati), tabella opcode completa (NOP 0x00, WRITE_RAM 0x01, READ_RAM 0x02, RESET 0x0F, SET_BASE 0x10, START 0x20, STATUS 0x21, READ_OUTPUT 0x22, READ_CONFIG 0x30), layout payload di READ_CONFIG (8 byte: ADDR_WIDTH, N_INPUTS, N_NEURONS, PARALLEL, DATA_WIDTH, versione protocollo), sessione di esempio end-to-end, elenco esplicito di ciò che resta fuori scope per v1 (Dual SPI, CRC/checksum, comandi di sequenziamento multi-layer -> rimandati a Fase 5).
- 2026-09-02T04:45 — [FASE 12] — Aggiornata la checklist della "## Phase 4 — SPI Interface" nel roadmap: spuntato "Protocol/opcode set drafted" con riferimento a §8.1; aggiunti come non ancora fatti: SPI controller RTL, register bank RTL, RAM access passthrough RTL, testbench dedicato (stile SPI master BFM + stack completo, sulla falsariga di neuron_memory_tb.v).
- 2026-09-02T04:46 — [FASE 12] — CONCLUSIONE: nessuna modifica a codice RTL/testbench in questa fase, solo documentazione di design (docs/FPGA-NeuralNetwork-Engine.md). Nessuna compilazione/simulazione necessaria. Prossimo step naturale: implementazione RTL del controller SPI/register-bank secondo questa spec, quando l'utente conferma che il draft è sufficientemente maturo (gli opcode restano volutamente aperti a revisione).

## Fase: Implementazione RTL SPI - livello fisico (Fase 4 RTL) (2026-09-02)

- 2026-09-02T05:00 — [FASE 13] — Utente conferma priorità: matrice di sequenziamento layer-to-layer (Fase 5) rimandata; procedere ORA con l'implementazione RTL vera dell'SPI (Fase 4), "fatta bene". Successivamente chiarito con "#4" = implementazione hardware COMPLETA di SPI, testata in tutte le sue sfaccettature (non solo happy path).
- 2026-09-02T05:02 — [FASE 13] — Piano comunicato: (1) spi_slave.v livello fisico + tb dedicato, (2) spi_engine.v FSM opcode + register bank, (3) arbitro bus condiviso spi_engine/neuron_memory, (4) top-level integrazione, (5) tb end-to-end con master SPI simulato che esegue l'intera sessione della spec. Iniziato dal punto più a rischio (CDC tra SCLK del master e clock di sistema).
- 2026-09-02T05:05 — [FASE 13] — Creato rtl/spi_slave.v: livello fisico SPI Mode 0 (CPOL=0,CPHA=0), MSB-first. Sincronizzatori a doppio flip-flop (3 stadi) per SCLK/MOSI/CS_N in ingresso dal dominio di clock del master (asincrono). Edge-detect su segnali sincronizzati. Shift register a 8 bit per rx (campiona MOSI su fronte di salita SCLK sincronizzato) e tx (aggiorna MISO su fronte di discesa SCLK sincronizzato). Segnali cs_start/cs_end (impulsi) e cs_active (livello) per delimitare le transazioni. Rimossa durante la scrittura una riga placeholder/dead-code lasciata per errore (wire sclk_rising ridondante).
- 2026-09-02T05:10 — [FASE 13] — Creato sim/spi_slave_tb.v: master SPI simulato bit-banged (Mode 0, MSB-first) con 4 test: TEST1 singolo byte (rx_byte/rx_valid + readback MISO), TEST2 multi-byte in una sola sessione CS, TEST3 transazioni back-to-back separate, TEST4 SCLK più lento (verifica indipendenza dal rapporto SCLK/clk).
- 2026-09-02T05:12 — [FASE 13] — Prima esecuzione: TEST1 e TEST3 PASS, TEST2 e TEST4 FAIL su mismatch MISO (sequenza byte ricevuta dal master shiftata, es. atteso "de ad be ef" ottenuto "ad be ef 00").
- 2026-09-02T05:15 — [FASE 13] — Prima ipotesi (poi rivelatasi solo parzialmente corretta): margine di temporizzazione insufficiente nel BFM del testbench, basato su ritardi `#ns` non allineati al clock di sistema. Riscritto il BFM per usare conteggi di cicli di `clk` (task `clk_wait`) invece di `#ns` assoluti, con margini generosi (8 e 20 cicli per mezzo-bit, ben oltre la latenza di sincronizzazione CDC di ~4 cicli). Stesso esito di fallimento anche dopo questa riscrittura -> la causa non era (solo) di margine.
- 2026-09-02T05:20 — [FASE 13] — Aggiunta strumentazione di debug temporanea (blocco `always @(posedge clk)` con `$display`/poi `$strobe` che traccia tx_byte_req, sclk_rise/fall, cs_fell, rx_valid, bit_count, tx_shift, miso, tx_byte, tx_queue_idx). Individuata la causa reale: `tx_queue_idx` (nel testbench) veniva avanzato su OGNI impulso `tx_byte_req`, ma il DUT genera legittimamente un impulso "phantom" extra dopo l'ultimo bit di ogni transazione (non può sapere in anticipo se il master continuerà a inviare altri byte prima di rilasciare CS, quindi pre-carica comunque il prossimo byte per garantire la validità di MISO). Questo consumava un elemento di troppo dalla coda del testbench ad ogni transazione.
- 2026-09-02T05:25 — [FASE 13] — FIX 1 (contratto tx_byte_req): documentato esplicitamente in rtl/spi_slave.v (commento sul segnale `tx_byte_req`) che è un hint di prefetch, NON un evento "byte consumato" — un consumer non deve usarlo per avanzare un puntatore stateful (es. indirizzo di lettura RAM), pena un avanzamento di un byte in eccesso ad ogni transazione. Il segnale corretto per avanzare un puntatore è `rx_valid`, che scatta esattamente una volta per ogni byte REALMENTE trasferito (mai un impulso extra, essendo guidato dal conteggio di fronti SCLK realmente avvenuti). Aggiornato sim/spi_slave_tb.v: `tx_queue_idx` ora avanza su `rx_valid` invece che su `tx_byte_req`.
- 2026-09-02T05:28 — [FASE 13] — Rieseguito dopo il fix 1: STESSO fallimento identico (miso ancora shiftato). Approfondito ulteriormente con debug tracing esteso dall'inizio simulazione: scoperto che `tx_queue_idx` non veniva MAI azzerato dai reset intermedi tra un test e l'altro (`rst=1'b1; @(posedge clk); rst=1'b0; @(posedge clk);`), nonostante la logica `if(rst) tx_queue_idx<=0;` fosse corretta.
- 2026-09-02T05:32 — [FASE 13] — CAUSA REALE identificata: race classica a "ritardo zero" sul fronte di clock. L'assegnazione blocking `rst=1'b1;` nel testbench avveniva, per la cadenza temporale usata (nessun `#delay` tra istruzioni, solo `@(posedge clk)`), esattamente nello stesso istante di simulazione di un fronte di salita del clock — rendendo non deterministico se i vari blocchi `always @(posedge clk)` (nel testbench e nel DUT) vedessero il vecchio o il nuovo valore di `rst` per quel fronte. Risultato osservato: il reset "non prendeva mai" per l'indice della coda, che restava sporco da un test al successivo.
- 2026-09-02T05:35 — [FASE 13] — FIX 2 (eliminazione della race): sostituiti i 3 reset rapidi inter-test da `rst=1'b1; @(posedge clk); rst=1'b0; @(posedge clk);` a `@(negedge clk); rst=1'b1; @(negedge clk); rst=1'b0; @(posedge clk);` — assegnando rst sul FRONTE DI DISCESA del clock, garantendo per costruzione che sia già stabile e senza ambiguità al successivo fronte di salita.
- 2026-09-02T05:38 — [FASE 13] — Rieseguito dopo il fix 2: TUTTI E 4 I TEST PASSANO (TEST1 PASS, TEST2 miso=de ad be ef come atteso, TEST3 PASS, TEST4 rx=0x96/miso=0x5a come atteso). Rimossa tutta la strumentazione di debug temporanea (blocco always/$strobe, reg debug_on e relativi toggle) per lasciare il testbench pulito.
- 2026-09-02T05:40 — [FASE 13] — Ricompilato ed eseguito sim/spi_slave_tb.v pulito (senza debug): confermato TUTTI E 4 I TEST PASSANO, esito identico.
- 2026-09-02T05:42 — [FASE 13] — LEZIONE APPRESA (rilevante per ogni futuro testbench in questo repo che usa sequenziamento `@(posedge clk)` senza `#delay` espliciti): assegnare segnali di controllo come `rst` con blocking assignment immediatamente prima di un `@(posedge clk)` rischia una race a delta-zero se il tempo di simulazione corrente coincide esattamente con un fronte di clock. Pattern sicuro: assegnare su `@(negedge clk)` quando si vuole garantire che il valore sia stabile e non ambiguo al successivo fronte di salita.
- 2026-09-02T05:45 — [FASE 13] — VERIFICA CON TOOLCHAIN FPGA REALE (richiesta esplicita dell'utente: "hai verificato con il simulatore della FPGA specifica?"): fino a questo punto la verifica era stata fatta solo con Icarus Verilog (simulatore RTL generico, verifica solo correttezza logica/funzionale, non timing né sintetizzabilità specifica del vendor). Individuato il toolchain reale già presente in ambiente (stesso usato per i benchmark in docs/FPGA-Neural-Datapatch-Benchmark.md, Appendice A): Yosys 0.68+post (/opt/homebrew/bin/yosys), nextpnr-ecp5 0.11.1 (/tmp/nextpnr/build/nextpnr-ecp5), ecppack/Project Trellis (/opt/homebrew/bin/ecppack).
- 2026-09-02T05:48 — [FASE 13] — Eseguita sintesi reale: `yosys -p "synth_ecp5 -json spi_slave.json -top spi_slave" rtl/spi_slave.v`. Risultato: 0 problemi rilevati dal CHECK pass, nessun latch inferito, 41 TRELLIS_FF, 55 LUT4, 21 PFUMX, 10 L6MUX21 — footprint coerente con un semplice shift register SPI.
- 2026-09-02T05:50 — [FASE 13] — Eseguito place&route reale: `nextpnr-ecp5 --45k --package CABGA381 --speed 8 --json spi_slave.json --lpf-allow-unconstrained --freq 80 --textcfg spi_slave.config` (stessi parametri usati nei benchmark esistenti, target LFE5U-45F-8BG381C). Risultato: **Max frequency 403.23 MHz, PASS al target 80 MHz** (ampio margine, atteso per un modulo così piccolo). Nessun errore di routing, "Program finished normally".
- 2026-09-02T05:52 — [FASE 13] — Generato bitstream reale: `ecppack spi_slave.config spi_slave.bit` -> completato senza errori (file da ~1 MB, dimensione plausibile per ECP5-45F). Confermata l'intera catena di implementazione (Verilog -> sintesi -> place&route -> bitstream) funzionante per questo modulo, non solo la simulazione comportamentale.
- 2026-09-02T05:53 — [FASE 13] — CONCLUSIONE: rtl/spi_slave.v verificato sia funzionalmente (Icarus, 4/4 test) sia a livello di implementazione reale sul target FPGA dichiarato nel progetto (Yosys+nextpnr-ecp5+ecppack, PASS a 80MHz con margine ampio). Il bug trovato durante il debug era interamente nel testbench (due bug distinti: contratto tx_byte_req mal interpretato + race di reset a delta-zero), NON nel DUT stesso — rtl/spi_slave.v non ha richiesto modifiche funzionali, solo l'aggiunta del commento di contratto su tx_byte_req. Prossimo step: rtl/spi_engine.v (FSM opcode + register bank).
- 2026-09-02T06:00 — [FASE 13] — Domanda utente (mentre si scriveva spi_engine.v): "quale è il numero massimo consigliato di neuroni per la FPGA?" Risposta basata sui dati reali del benchmark (docs/FPGA-Neural-Datapatch-Benchmark.md): LFE5U-45F ha 72 DSP MULT18X18D, 1 DSP per MAC, budget DSP di un layer = N_NEURONS × PARALLEL. Con PARALLEL=2 (config a miglior timing, 87.88MHz, unica PASS a 80MHz nel benchmark), 2 DSP/neurone fisico. Raccomandato ~50% di utilizzo DSP come margine (SPI/memoria non usano DSP, solo LUT/FF) -> circa 16-18 neuroni fisici paralleli come tetto pratico. Segnalata esplicitamente la cautela: il benchmark ha validato con place&route reale solo fino a 4 istanze fisiche, oltre serve riverifica nextpnr (il degrado di Fmax osservato nel benchmark dipende anche da routing/congestione LUT, non solo da %DSP).
- 2026-09-02T06:02 — [FASE 13] — Utente: "vorrei che questi fossero poi divisibili dall'utente tra i vari layer... e la matrice di configurazione si occupa di questo" — conferma/estende la visione già discussa per la Fase 5 (sequenziamento layer-to-layer, opzione scelta in precedenza): un numero FISICO limitato di neuroni (vincolato da DSP/routing) va riusato nel tempo per servire un numero LOGICO più grande di neuroni/layer. Fatto notare che l'architettura di neuron_memory.v (Fase 3, appena estesa) già implementa esattamente questo pattern per il caso "più neuroni in un layer" (1 neuron_parallel fisico riusato in sequenza per N_NEURONS logici via memoria) — la futura "matrice di configurazione" di Fase 5 estenderebbe lo stesso pattern al caso "più layer", riconfigurando x_base/w_base/bias_addr (e N_INPUTS/N_NEURONS per quel layer) tra un layer logico e il successivo. Nessuna azione di codice in questa nota, solo allineamento di visione per il design futuro di Fase 5; ripreso subito dopo il lavoro su rtl/spi_engine.v.

## Fase: Implementazione RTL SPI - motore opcode/register bank (2026-09-02)

- 2026-09-02T06:10 — [FASE 14] — Creato rtl/spi_engine.v: FSM opcode + register bank sopra l'interfaccia byte-level di spi_slave.v, secondo la spec docs §8.1. Implementati tutti gli 8 opcode: NOP, WRITE_RAM, READ_RAM, RESET, SET_BASE, START, STATUS, READ_OUTPUT, READ_CONFIG. Porta RAM master byte-level con la stessa convenzione del porto esterno "mem_*" di neuron_memory.v (indirizzo byte, dato byte, handshake req/ready), per poter condividere in futuro un arbitro + int8_memory_access + memory_interface con neuron_memory. `tx_byte` guidato interamente in modo COMBINATORIO dallo stato corrente (non reattivo a tx_byte_req), applicando la lezione del contratto tx_byte_req/rx_valid già documentata in spi_slave.v. Sticky STATUS.done latch: settato da nm_done (impulso), azzerato da nm_soft_rst o dalla lettura effettiva del byte STATUS (rx_valid mentre in ST_RESP con opcode STATUS).
- 2026-09-02T06:15 — [FASE 14] — Compilazione di verifica sintassi/elaborazione standalone (piccolo modulo tb con tutte le porte cablate a segnali dummy): pulita al primo tentativo dopo una piccola pulizia (rimossa un'assegnazione ridondante `opcode<={opcode[7:0]}` in ST_SETBASE_SEL, no-op lasciata per errore).
- 2026-09-02T06:20 — [FASE 14] — Creato sim/spi_engine_tb.v: testbench dedicato che instanzia spi_slave+spi_engine insieme, con un modello di RAM sintetico (latenza fissa a 2 cicli, isola la FSM degli opcode dalla complessità/temporizzazione dello stack PSRAM reale, che sarà verificato nel test end-to-end finale) e un mock manuale di neuron_memory (nm_busy/nm_done/y_bus pilotati dal test, x_base/w_base/bias_addr/nm_start/nm_soft_rst osservati). 10 test, uno per ciascun opcode più casi limite di protocollo: A) WRITE_RAM poi READ_RAM di verifica, B) SET_BASE per X/W/BIAS, C) START accettato da idle / ignorato da busy, D) STATUS (bit busy live, bit done sticky/clear-on-read), E) RESET (impulso nm_soft_rst + pulizia sticky done), F) READ_OUTPUT (N_NEURONS=3, neuron-major), G) READ_CONFIG (payload 8 byte), H) NOP (nessun effetto collaterale), I) WRITE_RAM con più byte MOSI del previsto (i byte in eccesso devono essere ignorati), J) transazioni back-to-back (stato si resetta correttamente su cs_end).
- 2026-09-02T06:25 — [FASE 14] — Prima esecuzione: 8/10 test PASS, 2 FAIL: TEST D (bit done non sticky dopo l'impulso nm_done) e TEST I (ram[0x302] sovrascritto, atteso ignorato).
- 2026-09-02T06:27 — [FASE 14] — TEST D: applicata preventivamente la stessa lezione già imparata nel debug di spi_slave_tb.v (Fase 13): il pattern `nm_done=1'b1; @(posedge clk); nm_done=1'b0;` rischia la stessa race a ritardo-zero sul fronte di clock. Sostituito con `@(negedge clk); nm_done=1'b1; @(negedge clk); nm_done=1'b0;` in entrambi i punti dove appariva (TEST D e TEST E). Rieseguito: TEST D ora PASS — confermata la stessa causa.
- 2026-09-02T06:30 — [FASE 14] — TEST I: bug diverso, individuato per ispezione (non serviva tracing esteso questa volta): il test inizializzava sentinel 0xFF solo su ram_mem[0x300] e ram_mem[0x301] (gli indirizzi che DEVONO essere scritti), ma MAI su ram_mem[0x302] (l'indirizzo che NON deve essere toccato) — il controllo `if (ram_mem[0x302] !== 8'hFF)` falliva quindi SEMPRE, confrontando il valore iniziale non scritto (0x00, da inizializzazione globale della RAM sintetica a inizio simulazione) contro un sentinel 0xFF mai effettivamente impostato. Bug nel TESTBENCH, non nell'RTL. Aggiunta `ram_mem[16'h0302] = 8'hFF;` prima della transazione. Anche corretta la larghezza del campo `label` (input reg) nei task `report`/`miso_check` da 128 a 512 bit, per evitare troncamento dei nomi dei test più lunghi nell'output (bug cosmetico separato, notato durante il debug).
- 2026-09-02T06:32 — [FASE 14] — Rieseguito dopo entrambi i fix: TUTTI E 10 I TEST PASSANO. Nessuna modifica a rtl/spi_engine.v richiesta in questa fase di bring-up: entrambi i bug erano nel testbench (stessa classe di race già vista in Fase 13, più un errore di inizializzazione del sentinel).
- 2026-09-02T06:35 — [FASE 14] — Verifica con toolchain ECP5 reale (stessa procedura di Fase 13): `yosys -p "synth_ecp5 -json spi_engine.json -top spi_engine" rtl/spi_engine.v` -> 0 problemi, nessun latch, 208 TRELLIS_FF, 240 LUT4 + 19 CCU2C (catene di riporto per gli incrementi/decrementi di addr/len), 0 DSP utilizzati (atteso, logica di controllo pura).
- 2026-09-02T06:37 — [FASE 14] — `nextpnr-ecp5 --45k --package CABGA381 --speed 8 --json spi_engine.json --lpf-allow-unconstrained --freq 80 --textcfg spi_engine.config`: **PASS, Fmax 191.31 MHz** (target 80MHz ampiamente superato). `ecppack spi_engine.config spi_engine.bit` -> bitstream generato senza errori.
- 2026-09-02T06:38 — [FASE 14] — CONCLUSIONE: rtl/spi_engine.v implementa tutti gli 8 opcode della spec draft, verificato funzionalmente (Icarus, 10/10 test su ogni opcode + edge case) e sul toolchain FPGA reale (Yosys+nextpnr-ecp5+ecppack, PASS a 80MHz con ampio margine, nessun DSP consumato). Prossimo step: arbitro bus condiviso tra spi_engine e neuron_memory verso int8_memory_access/memory_interface, poi top-level di integrazione, poi testbench end-to-end con la sessione SPI completa della spec.

## Fase: Integrazione end-to-end SPI + RAM reale + neuron_memory (2026-09-02)

- 2026-09-02T06:45 — [FASE 15] — Domanda utente: "hai verificato con la ram reale?" Risposta onesta: no, spi_engine.v era stato verificato solo contro un modello di RAM sintetico a 2 cicli di latenza fissa. Deciso di procedere subito con l'integrazione completa (arbitro + top-level) e il test end-to-end con lo stack PSRAM reale (memory_interface + psram_controller + psram_model), lo stesso già usato in neuron_memory_tb.v.
- 2026-09-02T06:47 — [FASE 15] — Utente, mentre si scriveva il top-level: "la ram non sta nella disponibilità di altri, solo della FPGA (giusto per essere precisi)" — confermato che il design rispetta già questo vincolo: l'host esterno non ha mai un collegamento elettrico diretto alla RAM, solo tramite SPI+FPGA; i pin psram_a/psram_dq/ce_n/... sono cablati esclusivamente tra psram_controller e il chip PSRAM dentro spi_neuron_top, mai esposti all'esterno.
- 2026-09-02T06:50 — [FASE 15] — Creato rtl/mem_arbiter.v: arbitro a priorità fissa (neuron_memory > spi_engine quando entrambi richiedono nello stesso ciclo idle) tra le due porte byte-level master (spi_engine per WRITE_RAM/READ_RAM, neuron_memory per le proprie letture X/W/bias durante un run), verso un'unica porta master condivisa. Design "grant-and-forward": nessuna coda/pipeline necessaria dato che entrambi i master emettono già `req` come impulso pulito di un ciclo (stesso contratto di int8_memory_access.v).
- 2026-09-02T06:55 — [FASE 15] — Creato rtl/spi_neuron_top.v: top-level di integrazione completo. spi_slave -> spi_engine -> mem_arbiter (porta A) / neuron_memory (porta B, con rst = global_rst OR nm_soft_rst da opcode RESET) -> arbitro -> UNA istanza condivisa di int8_memory_access (bridge byte<->word) -> memory_interface -> psram_controller -> pin fisici PSRAM esterni.
- 2026-09-02T07:00 — [FASE 15] — Creato sim/spi_neuron_top_tb.v: testbench end-to-end che pilota l'INTERO stack SOLO via SPI simulato (nessuna iniezione diretta nelle porte di neuron_memory), con psram_model.v reale (non un mock). Sessione: RESET -> READ_CONFIG (verifica) -> WRITE_RAM(X=1 x32, W=1 x32, bias=0) nella PSRAM reale -> READ_RAM di verifica (conferma che la scrittura sia realmente arrivata in RAM, non solo accettata) -> SET_BASE x3 -> START -> poll STATUS -> READ_OUTPUT, ripetuto per 3 scenari (SUM=32, SATURATION=127 dopo un secondo WRITE_RAM che ricarica i pesi a 4, RELU=0 dopo un terzo WRITE_RAM con pesi a -1). Margini di clock SPI differenziati: HB_RAM=40 cicli/mezzo-bit per i comandi che toccano la RAM (margine ampio rispetto alla latenza reale di psram_controller, ACCESS_CYCLES=ceil(70ns*80MHz)=6 cicli, più overhead della catena completa), HB_REG=8 cicli per i comandi di solo registro (SET_BASE/START/STATUS/READ_OUTPUT/READ_CONFIG/RESET, che non toccano mai l'arbitro/RAM).
- 2026-09-02T07:05 — [FASE 15] — Compilato: `iverilog -g2012 -o <tmp> rtl/*.v sim/psram_model.v sim/spi_neuron_top_tb.v`. Pulito al primo tentativo. Eseguito: TUTTO PASSA AL PRIMO TENTATIVO — READ_CONFIG PASS, READ_RAM verify PASS (X[0]=0x01 confermato scritto realmente in PSRAM), TEST 1 (SUM=32) PASS, TEST 2 (SATURATION=127) PASS, TEST 3 (RELU=0) PASS. Nessun bug trovato in questa integrazione: sia l'arbitro sia il ponte byte<->word condiviso funzionano correttamente al primo colpo con lo stack PSRAM reale.
- 2026-09-02T07:10 — [FASE 15] — Verifica con toolchain ECP5 reale del top-level completo (prima volta che il percorso PSRAM entra nella sintesi reale in questa sessione): `yosys -p "synth_ecp5 -json ... -top spi_neuron_top" rtl/spi_neuron_top.v rtl/spi_slave.v rtl/spi_engine.v rtl/mem_arbiter.v rtl/neuron_memory.v rtl/neuron_parallel.v rtl/mac8.v rtl/mac_unit.v rtl/int8_memory_access.v rtl/memory_interface.v rtl/psram_controller.v` (N_NEURONS=1, PARALLEL=8, N_INPUTS=32, come in neuron_memory_tb.v). Risultato: 0 problemi dal CHECK pass, 8 MULT18X18D (=N_NEURONS×PARALLEL, corretto), 16 $_TBUF_ (buffer tri-state per psram_dq bidirezionale, corretto), 1 warning noto/atteso ("Yosys has only limited support for tri-state logic") proveniente da psram_controller.v preesistente, non dal codice nuovo.
- 2026-09-02T07:15 — [FASE 15] — `nextpnr-ecp5 --45k --package CABGA381 --speed 8 --freq 80 --lpf-allow-unconstrained`: **FAIL, Fmax ~52.58 MHz** (target 80MHz). FINDING IMPORTANTE, verificato con attenzione prima di riportarlo: il percorso critico (19.02ns) è interamente contenuto dentro u_neuron_memory.u_neuron (rtl/neuron_parallel.v, in particolare la catena di riporto CCU2C del comparatore di saturazione ">127" a riga 127) — ZERO contributo da spi_slave, spi_engine, mem_arbiter o dallo stack PSRAM. Coerente con il benchmark preesistente (docs/FPGA-Neural-Datapatch-Benchmark.md): PARALLEL=8 era già noto FAIL a 80MHz (61.71MHz nel benchmark isolato).
- 2026-09-02T07:18 — [FASE 15] — Verificata l'ipotesi: risintetizzato con `chparam -set PARALLEL 2 spi_neuron_top` (confermato applicato: 2 MULT18X18D invece di 8) — la configurazione che nel benchmark isolato raggiungeva 87.88MHz PASS. Risultato nel design INTEGRATO completo: **ANCORA FAIL, Fmax ~55.85 MHz**. Il percorso critico resta identico in natura (stesso comparatore di saturazione in neuron_parallel.v, stesso genere di catena CCU2C), ma la sua temporizzazione peggiora sensibilmente rispetto al benchmark isolato (11.38ns isolato -> 17.91ns nel design integrato, +57% circa) per congestione di piazzamento/routing dovuta alla logica SPI/arbitro/PSRAM circostante che compete per le stesse risorse FPGA — non per esaurimento di risorse (utilizzo DSP solo 2%, LUT/FF anch'essi bassi rispetto alla capacità totale del dispositivo; `--lpf-allow-unconstrained` non aiuta il posizionamento).
- 2026-09-02T07:20 — [FASE 15] — VALUTAZIONE: questo NON è un bug introdotto dal lavoro SPI di questa sessione (la logica SPI/arbitro stessa sintetizza pulita e velocissima isolatamente: spi_slave 403MHz, spi_engine 191MHz). È un problema di temporizzazione a livello SISTEMA (placement/routing quando tutti i blocchi coesistono nello stesso design), che richiede tipicamente vincoli di floorplanning (region constraint LPF) o pipeline aggiuntive nel comparatore di saturazione di neuron_parallel.v per essere risolto — esplicitamente nello scope della Fase 7 (Optimization: "pipeline depth", "FPGA resource utilization") del roadmap, non di questa fase. NESSUNA modifica al core di calcolo tentata per questo motivo, coerentemente con la policy di progetto.
- 2026-09-02T07:22 — [FASE 15] — CONCLUSIONE: l'integrazione SPI+RAM reale+neuron_memory è funzionalmente CORRETTA e verificata end-to-end (simulazione Icarus con PSRAM reale, 3/3 scenari PASS) e la logica SPI stessa è velocissima in sintesi isolata. Il target di temporizzazione a 80MHz per il SISTEMA COMPLETO non è ancora raggiunto con l'attuale floorplanning automatico — finding onesto, documentato in dettaglio, da affrontare in una fase di ottimizzazione futura (Fase 7) e non bloccante per la correttezza funzionale della Fase 4 SPI appena completata.

## Fase: Type #2 (grafo sparso) — G1..G7 (2026-09-03)

Avviato il lavoro di specifica per il supporto a reti a grafo arbitrario (Tipo #2, edge-list sparsa) accanto alla rete densa esistente (Tipo #1, invariata). Vincolo invalicabile confermato: mac_unit/mac8/neuron_parallel non si toccano (a parte il guard elaboration-time già presente da una sessione precedente); tutto il lavoro nuovo è a livello di orchestrazione/memoria, seguendo lo stesso pattern di neuron_memory.v/layer_sequencer.v. Piano completo (formati dati, opcode SPI, FSM, guardie, assemblatore host) ricevuto dall'utente come specifica dettagliata; si procede fase per fase (G1..G7) con simulazione verde ad ogni passo, come richiesto.

- 2026-09-03T00:00 — [G1] — Creato `rtl/act_buffer.v`: buffer di attivazione globale, dual-port, N_TOTAL=4096 slot INT8 (id 0..4095), indirizzo derivato con `localparam ADDR_WIDTH = $clog2(N_TOTAL)`. Porta A: scrittura sincrona (`wr_en`/`wr_addr`/`wr_data`). Porta B: lettura sincrona REGISTRATA (`rd_addr` -> `rd_data` un ciclo dopo), nessun `rst` (idioma standard per inferenza block-RAM: un reset sincrono su un array indicizzato forzerebbe Yosys verso LUT-RAM invece di DP16KD).
- 2026-09-03T00:05 — [G1] — Creato `sim/act_buffer_tb.v`, 6 test: TEST1 scrittura/lettura id basso (0), TEST2 id alto (N_TOTAL-1=4095), TEST3 round-trip valore negativo con segno, TEST4 verifica esplicita che la lettura sia REGISTRATA (cambiando `rd_addr` il `rd_data` non cambia nello stesso ciclo, solo un ciclo dopo — il rischio concreto che il gather di graph_engine dovrà rispettare), TEST5 scrittura e lettura simultanee su indirizzi diversi (porte indipendenti, nessuna interferenza), TEST6 burst di 16 scritture seguito da letture in ordine INVERSO (modella il pattern di gather fuori ordine di graph_engine). Compilato con `iverilog -g2012 -o <tmp> rtl/act_buffer.v sim/act_buffer_tb.v` + `vvp`: **ALL TESTS PASSED** (tutti e 6 i test, incl. i due sub-check di TEST4).
- 2026-09-03T00:10 — [G1] — Verifica inferenza block-RAM con Yosys (nextpnr-ecp5 non disponibile in questo ambiente, solo `yosys` — usato per il solo check di mappatura, non per il timing): primo tentativo con `memory; opt` espliciti prima di `synth_ecp5` ha prodotto 0 DP16KD e ~71K celle (32776 TRELLIS_FF + LUT) — la `memory` pass generica mappa già a logica/FF prima che `synth_ecp5` possa applicare la sua `memory_bram`. Corretto lasciando che `synth_ecp5 -top act_buffer` gestisca da solo il proprio passo memoria (nessun `memory`/`proc`/`flatten` manuale prima): risultato **2× DP16KD, 0 celle di memoria residue** (86 celle totali, di cui solo 30 TRELLIS_FF/37 LUT4 per la piccola logica di indirizzamento/muxing attorno alle due primitive). Script e log salvati in `synth/ecp5/act_buffer/` (synth.ys, yosys.log, top.json) per riferimento. Conferma il requisito del piano (act_buffer deve essere DP16KD, non LUT-RAM).
- 2026-09-03T00:12 — [G1] — CONCLUSIONE G1: buffer di attivazione pronto, comportamento verificato in simulazione (incl. il caso critico della latenza di lettura registrata) e mappatura block-RAM confermata in sintesi. Nessuna modifica a file esistenti in questa fase. Procedo a G2 (formato descrittore graph + edge, loader via PSRAM).
- 2026-09-03T01:00 — [G2] — Creato `sim/graph_format_tb.v`: nessun nuovo modulo RTL in questa fase (per esplicita indicazione del piano, G2 riguarda il FORMATO, non nuovo hardware). Riusa lo stesso harness a stack di memoria reale di `sim/int8_psram_integration_tb.v` (int8_memory_access + memory_interface + psram_controller + psram_model). Grafo di riferimento: l'esempio del §3 (4 ingressi id0-3, n4 connesso a 0/1, n5 connesso a n4(id4)/2, uscita=n5 id5). Scrive la tabella descrittori (2 voci da 11 byte, §4.2) e i blocchi edge (4 byte/edge, §4.3) via task dedicate (`write_graph_desc`, `write_edge`) e rilegge OGNI singolo byte confrontandolo col valore atteso (byte-exact, non solo il valore logico ricomposto) — incl. un check di non-interferenza (riscrittura del bias di n4 non deve toccare il descrittore di n5 né gli edge di n4).
- 2026-09-03T01:05 — [G2] — Compilato con `iverilog -g2012 -o <tmp> rtl/int8_memory_access.v rtl/memory_interface.v rtl/psram_controller.v sim/psram_model.v sim/graph_format_tb.v` + `vvp`: **GRAPH FORMAT TEST PASSED (0 errors)**, tutti i 42 confronti byte-exact passano (tabella + edge + check di non-interferenza). Conferma che il formato dati Tipo #2 è rappresentabile e ricostruibile byte-per-byte attraverso lo stack di memoria reale così com'è, senza bisogno di modifiche a int8_memory_access/memory_interface/psram_controller.
- 2026-09-03T01:10 — [G2] — CONCLUSIONE G2: formato dati (§4.2/§4.3) validato byte-exact end-to-end sulla memoria reale. Procedo a G3 (graph_engine core: gather -> neuron_parallel -> scrittura act_buf, con padding PARALLEL).
- 2026-09-03T02:00 — [G3] — Creato `rtl/graph_engine.v`: FSM che orchestra il Tipo #2 riusando `neuron_parallel` (istanza privata, MAX_CONN come suo N_INPUTS di build) e `act_buffer` (istanza privata, dedicata, non condivisa col Tipo #1) senza toccare nessuno dei due moduli validati. Decisioni di design NON esplicitate parola-per-parola nella spec, documentate nell'header del file e qui per traccia:
  - **Riuso di registri esistenti** invece di nuovi selettori SET_BASE (oltre a sel9/sel10 già previsti): `x_base` = base ingressi grafo, `table_base` = base tabella descrittori grafo, `buf_a_base` = `out_base` (destinazione copia uscite), `n_inputs_real` = N_in (numero ingressi grafo). Motivazione: Tipo #1 e Tipo #2 sono mutuamente esclusivi a runtime (stesso principio già usato dalla spec per condividere la porta C dell'arbitro), quindi questi registri non servono mai contemporaneamente per i due scopi.
  - **WRITE_OUTPUTS fuso nel loop principale** invece di un secondo passaggio finale separato: dato che la spec stessa garantisce che le uscite sono ESATTAMENTE le ultime n_out voci della tabella descrittori (ordine out_id crescente), la copia verso `out_base` avviene subito dopo aver scritto act_buf[out_id], per i soli neuroni con `neuron_idx >= num_neurons_graph - n_out` — evita un secondo attraversamento di act_buf o una tabella di lookup id separata.
  - **Padding PARALLEL interamente lato host/assembler**: l'RTL si limita a calcolare `n_conn_padded = ceil(n_conn/PARALLEL)*PARALLEL` e a leggere fisicamente quel numero di edge dal blocco PSRAM (che l'assemblatore avrà già esteso con edge a peso zero) — nessun caso speciale hardware per il padding stesso.
  - **Guardie aggiuntive oltre al testo letterale del §7**: oltre a `src_id < out_id` e `src_id < N_TOTAL`, aggiunto anche `out_id < N_TOTAL` (altrimenti scrittura fuori range silenziosa in act_buf) e `n_conn_padded == 0` trattato come errore di caricamento (altrimenti forwardato a neuron_parallel come n_inputs_real=0, che va in hang per il motivo già documentato in una sessione precedente — GROUPS=0). Entrambe le estensioni sono nello spirito esplicito del §7 ("fermare l'esecuzione invece di produrre risultati silenziosamente errati"), documentate nell'header del modulo per chi confronta con la spec originale.
  - **Timing del gather su act_buffer**: `rd_addr` di act_buffer è cablato COMBINAZIONALMENTE a `src_id_acc` (niente registro di staging aggiuntivo); il consumo di `rd_data` avviene uno STATO intero dopo che src_id è noto (dopo aver letto anche peso e byte riservato dello stesso edge, cioè almeno 2 ulteriori round-trip PSRAM), quindi ben oltre il singolo ciclo di latenza che act_buffer richiede — nessuno stato di attesa dedicato necessario, verificato empiricamente (vedi test G3 sotto).
  - Bug corretto durante la stesura: la prima versione dell'espressione di indirizzo edge (`conn_ptr_acc + (conn_i<<2) + edge_byte_idx` costruita con concatenazioni manuali di zeri) è stata sostituita con la normale aritmetica Verilog (`conn_ptr_acc[ADDR_WIDTH-1:0] + (conn_i*4) + edge_byte_idx`), coerente con lo stile del resto della codebase (vedi `neuron_memory.v`/`layer_sequencer.v`) ed elaborata senza errori.
  - Bug corretto durante la stesura: `act_buffer` istanziato con `rd_addr(src_id_acc[...])` PRIMA che `src_id_acc` fosse dichiarato più in basso nel file (errore di elaborazione Icarus "Unable to bind wire/reg") — risolto spostando l'intero blocco di dichiarazione registri/localparam degli stati FSM PRIMA delle istanze dei sottomoduli.
- 2026-09-03T02:15 — [G3] — Verifica elaboration-only (`iverilog -g2012 -s graph_engine -o <tmp> rtl/act_buffer.v rtl/mac_unit.v rtl/mac8.v rtl/neuron_parallel.v rtl/graph_engine.v`): 0 errori dopo i due fix sopra.
- 2026-09-03T02:20 — [G3] — Creato `sim/graph_engine_tb.v`: stesso grafo minuscolo del §3 usato in G2 (4 ingressi, n4, n5=uscita), ma questa volta calcolato attraverso l'hardware reale end-to-end (graph_engine + int8_memory_access + memory_interface + psram_controller + psram_model), con PARALLEL=4/MAX_CONN=8 scelto APPOSTA per esercitare il padding (n_conn reale=2 per neurone, n_conn_padded=4, quindi 2 edge di padding a peso zero inseriti "a mano" nel test come farebbe l'assemblatore) invece del caso banale PARALLEL=2 (dove n_conn=2 sarebbe già multiplo, senza padding). Calcolo atteso a mano: n4 = relu(10*5 + 1*(-3) + 2) = 49; n5 = 49*2 + 4*7 + 0 = 126 (ACT_NONE, nessuna saturazione). Verifica tramite riferimenti gerarchici (stile già usato nel repo, es. `psram_ctrl.state` in `int8_psram_integration_tb.v`) sia sul contenuto di `dut.u_act_buffer.mem[]` sia sulla PSRAM model (`psram.mem[]`) per il byte copiato in `out_base`.
- 2026-09-03T02:25 — [G3] — Compilato ed eseguito: `iverilog -g2012 -o <tmp> rtl/act_buffer.v rtl/mac_unit.v rtl/mac8.v rtl/neuron_parallel.v rtl/graph_engine.v rtl/int8_memory_access.v rtl/memory_interface.v rtl/psram_controller.v sim/psram_model.v sim/graph_engine_tb.v` + `vvp`. Risultato: **GRAPH_ENGINE CORE TEST PASSED (0 errors)** al primo tentativo dopo i due fix di elaborazione — done dopo 784 cicli, err=0, act_buf[0..3]=input attesi, act_buf[4]=49, act_buf[5]=126, out_base[0]=126. Conferma end-to-end: gather fuori ordine da act_buf, riuso di neuron_parallel senza modifiche, padding PARALLEL letto correttamente dalla PSRAM, ReLU su n4 e passthrough ACT_NONE su n5, copia dell'unica uscita su out_base tutti corretti al primo run.
- 2026-09-03T02:30 — [G3] — CONCLUSIONE G3: core del graph_engine funzionalmente corretto e verificato end-to-end su hardware simulato reale (non solo unit test isolato). Procedo a G4 (guardia load-time src_id<out_id / N_TOTAL, testbench con grafo deliberatamente non valido).
- 2026-09-03T02:35 — [G3] — Sintesi Yosys standalone di `graph_engine.v` (con `act_buffer`, `neuron_parallel`, `mac8`, `mac_unit`, parametri di default PARALLEL=8/MAX_CONN=32): 0 problemi dal CHECK pass, **2× DP16KD** (act_buffer mappato correttamente su block RAM anche annidato dentro graph_engine, non solo isolato come in G1), 8× MULT18X18D (= PARALLEL, corretto), nessun warning di tri-state (nessun segnale bidirezionale in questo modulo). Script/log salvati in `synth/ecp5/graph_engine/`.
- 2026-09-03T03:00 — [G4] — Creato `sim/graph_engine_guard_tb.v`: 4 scenari sullo stesso harness a stack di memoria reale di G3 — TEST A (src_id >= out_id, auto-riferimento), TEST B (out_id >= N_TOTAL), TEST C (n_conn_padded==0, l'estensione di guardia aggiunta oltre al testo letterale del §7), TEST D (recupero: un nuovo run_start su un grafo VALIDO subito dopo un errore, SENZA rst di mezzo, deve pulire `err` e completare normalmente — verifica esplicita del comportamento "ST_IDLE, ST_ERROR" nello stesso case branch dell'RTL).
- 2026-09-03T03:10 — [G4] — **BUG DI TESTBENCH TROVATO E RISOLTO (non un bug RTL)**: prima esecuzione, tutti e 4 i test fallivano con TIMEOUT (né `done` né `err` mai assertiti), nonostante lo stesso identico grafo "self-reference" testato manualmente in isolamento (script di debug ad-hoc, non nel repo) innescasse correttamente la guardia in ~240 cicli. Investigazione approfondita (bisection sistematica: rimozione delle task annidate `write_graph_desc`/`write_edge`, poi delle task `do_reset`/`run_and_wait` stesse, sostituendo ogni volta con codice inline nell'`initial` block) ha isolato la causa: il pulse `run_start = 1'b1; @(posedge clk); run_start = 1'b0;` in `run_and_wait` usava ASSEGNAZIONE BLOCCANTE (`=`). Questo è un classico race condition di simulazione (IEEE 1364): l'assegnazione bloccante del testbench che azzera `run_start` sullo STESSO fronte di clock che il blocco `always @(posedge clk)` di `graph_engine` usa per campionare `run_start` compete in un ordine di scheduling non garantito dallo standard — con la struttura testbench di G3 (nessuna task, nessun blocco `always` di debug aggiuntivo) l'ordine "vincente" risultava casualmente favorevole; con la struttura di G4 (task annidate) l'ordine si è invertito, facendo perdere silenziosamente il pulse. Riprodotto e isolato con un testbench minimale standalone (`graph_engine` nudo, nessuno stack di memoria) che mostrava lo stesso sintomo in modo deterministico. Il resto della codebase (es. i task `ld_write` esistenti, `int8_psram_integration_tb.v`) già usa correttamente l'assegnazione NON bloccante (`<=`) per i segnali sincroni pilotati dal testbench — questa era un'incongruenza introdotta SOLO nei due nuovi testbench di questa sessione (`graph_engine_tb.v` e `graph_engine_guard_tb.v`).
  - **FIX**: cambiate tutte le assegnazioni a `run_start` da bloccanti a non bloccanti in `sim/graph_engine_tb.v` e `sim/graph_engine_guard_tb.v` (G3 "funzionava" solo per fortuna di scheduling, quindi corretto anche lì per robustezza, non solo in G4 dove falliva apertamente).
- 2026-09-03T03:15 — [G4] — **SECONDO BUG DI TESTBENCH TROVATO E RISOLTO** (dopo il fix sopra, TEST A/B/C passavano ma TEST D falliva ancora): la condizione del loop `while (!done && !err && timeout<5000)` in `run_and_wait` veniva valutata NELLO STESSO delta-cycle del fronte di clock che pulisce `err` (via assegnazione non bloccante nell'RTL, ramo `ST_IDLE, ST_ERROR` con `run_start` attivo) — la valutazione bloccante nel testbench vede il valore di `err` ANTECEDENTE all'aggiornamento NBA di quello stesso fronte, quindi ancora 1 (stantio da TEST C), facendo uscire il loop immediatamente con `timeout=0`. **FIX**: aggiunto un `@(posedge clk)` extra dopo aver azzerato `run_start` e PRIMA di valutare la condizione iniziale del while, per lasciare che gli aggiornamenti non bloccanti del fronte precedente si stabilizzino.
- 2026-09-03T03:20 — [G4] — **TERZO BUG DI TESTBENCH** (non un race, un errore logico): dopo i due fix sopra, TEST D falliva ancora — `done` è un impulso di UN SOLO CICLO nell'RTL (`done<=1` poi `done<=0` il ciclo successivo come parte dei "default pulses"), ma `run_and_wait` faceva un `@(posedge clk)` FINALE ("let busy/err settle") DOPO l'uscita dal loop, avanzando oltre l'impulso — cosicché il controllo `if (!done || err)` in TEST D leggeva `done` già ritornato a 0. Innocuo per `expect_guard_violation` (che controlla solo `err`, sticky), fatale per il controllo esplicito di `done` in TEST D. **FIX**: aggiunto un registro `done_latched` che cattura `done` esattamente al momento dell'uscita dal loop (prima del ciclo di settle finale); tutti i controlli che leggono `done` ora usano `done_latched`.
- 2026-09-03T03:25 — [G4] — Dopo i tre fix: `iverilog -g2012 -o <tmp> rtl/act_buffer.v rtl/mac_unit.v rtl/mac8.v rtl/neuron_parallel.v rtl/graph_engine.v rtl/int8_memory_access.v rtl/memory_interface.v rtl/psram_controller.v sim/psram_model.v sim/graph_engine_guard_tb.v` + `vvp`: **GRAPH_ENGINE GUARD TEST PASSED (0 errors)** — TEST A (208 cicli), TEST B (208 cicli), TEST C (157 cicli), TEST D/recupero (386 cicli) tutti PASS.
- 2026-09-03T03:30 — [G4] — REGRESSIONE COMPLETA su tutti i testbench esistenti del repo (Tipo #1 + stack memoria, invariati in questa fase): `neuron_parallel_tb`, `layer_tb`, `neuron_memory_tb`, `neuron_memory_multi_tb`, `layer_sequencer_tb`, `spi_engine_tb`, `spi_neuron_top_tb`, `spi_neuron_top_runnetwork_tb`, `int8_memory_access_tb`, `memory_interface_tb`, `psram_controller_tb`, `int8_psram_integration_tb`, `parametric_tb`, `parameter_sweep_tb` — **TUTTI PASS**, zero regressioni. Ririeseguiti anche `graph_engine_tb.v` (G3) e `act_buffer_tb.v`/`graph_format_tb.v` (G1/G2): tutti PASS dopo i fix di questa fase.
- 2026-09-03T03:35 — [G4] — CONCLUSIONE G4: guardia load-time verificata su 3 scenari di violazione distinti + 1 scenario di recupero, nessuna modifica ulteriore a `rtl/graph_engine.v` necessaria (l'RTL era già corretto; tutti i bug trovati in questa fase erano nei NUOVI testbench, non nell'hardware). Lezione da portare avanti nelle fasi successive (G5 in particolare, che avrà testbench SPI ancora più complessi): usare SEMPRE assegnazione non bloccante per segnali di stimolo sincroni pilotati dal testbench verso il DUT, e non fidarsi di un singolo "funziona" senza capire se dipende da un ordine di scheduling fortunato. Procedo a G5 (integrazione SPI/top: SET_NET_TYPE, SET_BASE sel 9/10, dispatch RUN_NETWORK, mux nel top-level).

- 2026-09-03T04:00 — [G5] — Modificato `rtl/spi_engine.v`: aggiunto opcode `OP_SET_NET_TYPE` (0x11, 1 byte payload -> registro `net_type`, default `NET_TYPE_DENSE`=0x01 dopo `rst` E dopo l'opcode RESET, come richiesto dalla spec §5); nuovi selettori SET_BASE `SEL_NUM_NEURONS_GRAPH`=0x09 e `SEL_N_OUT`=0x0A (stesso pattern BE a 2 byte di SEL_N_INPUTS/SEL_N_NEURONS esistenti) che scrivono i nuovi registri `num_neurons_graph`/`n_out`; nuovo registro `graph_mode` (analogo a `net_mode` esistente ma per il ramo grafo) che gestisce `busy_all`/`done_event` insieme ai due esistenti (`busy_all = nm_busy|seq_busy|graph_busy`; `done_event = graph_mode ? graph_done : (net_mode ? seq_done : nm_done)`); dispatch di RUN_NETWORK: se `net_type==NET_TYPE_GRAPH` setta `graph_mode` invece di `net_mode` (il payload byte, `num_layers`, resta ricevuto ma ignorato in modalità grafo, framing byte-identico ai due net_type come richiesto); STATUS.bit2 = `graph_err`, congelato nello stesso `status_snapshot` già esistente per `busy`/`done` (nessuna nuova logica di clear-on-read necessaria: `graph_err` è già sticky-fino-a-reset lato `graph_engine`); READ_CONFIG esteso da 8 a 11 byte (byte 8-9 = `N_TOTAL` a 16 bit, byte 10 = flag di capacità con bit0=`GRAPH_SUPPORTED`=1 fisso). Nuovo parametro `N_TOTAL` (default 4096) aggiunto a `spi_engine` solo per esporlo via READ_CONFIG.
- 2026-09-03T04:10 — [G5] — Modificato `rtl/spi_neuron_top.v`: istanziato `graph_engine` (nuovi parametri di top-level `GRAPH_MAX_CONN`=32, `GRAPH_N_TOTAL`=4096) riusando gli stessi registri di `x_base`/`table_base`/`buf_a_base`(come `out_base`)/`n_inputs_real`(come N_in) già esposti da spi_engine per il Tipo #1 — nessun nuovo filo di config necessario oltre a `num_neurons_graph`/`n_out`. Routing del singolo impulso `run_start` di spi_engine verso `layer_sequencer` o `graph_engine` in base al registro `net_type` (`seq_run_start`/`graph_run_start`, mutua esclusione garantita a monte da spi_engine che accetta un nuovo RUN_NETWORK solo con `!busy_all`). Porta C dell'arbitro condivisa fra `layer_sequencer` e `graph_engine` con un mux statico su `net_type` (non su busy, dato che i due motori non sono mai contemporaneamente in esecuzione per costruzione) — evitata una quarta porta come indicato dalla spec. `graph_engine.rst` = `rst | nm_soft_rst` (stessa convenzione di `nm_rst` per neuron_memory: l'opcode RESET pulisce anche un `err` bloccato senza reset fisico).
- 2026-09-03T04:15 — [G5] — Verifica elaboration-only dell'intera gerarchia: `iverilog -g2012 -s spi_neuron_top -o <tmp> rtl/*.v` — 0 errori.
- 2026-09-03T04:20 — [G5] — REGRESSIONE IMMEDIATA su `spi_engine_tb.v` (unico testbench che istanzia `spi_engine` in isolamento, non attraverso `spi_neuron_top`): FALLITA con 7 errori a cascata (TEST L RUN_NETWORK e successivi) subito dopo l'estensione dei port di spi_engine. Causa: i 3 nuovi input (`graph_busy`/`graph_done`/`graph_err`) erano lasciati non connessi nel testbench esistente (scritto per l'interfaccia a 9 porte precedente) — un input non connesso è `x` in simulazione, e `busy_all = nm_busy|seq_busy|graph_busy` con un operando `x` produce `x`, contaminando ogni successiva decisione `if(!busy_all)`. **FIX**: aggiunte `reg graph_busy=0; reg graph_done=0; reg graph_err=0;` (stesso pattern già usato lì per `seq_busy`/`seq_done`, con commento esplicativo) e collegate le 3 nuove uscite (`net_type`/`num_neurons_graph`/`n_out`) come non connesse (stesso trattamento delle altre uscite SET_BASE-driven già non connesse in quel file). Nessuna modifica all'intento dei test esistenti. Rieseguito: **SPI_ENGINE TEST PASSED**.
- 2026-09-03T04:25 — [G5] — REGRESSIONE COMPLETA (14 testbench Tipo #1 + stack memoria, tutti quelli della sessione precedente): tutti **PASS**, zero regressioni, incl. `spi_neuron_top_tb.v` e `spi_neuron_top_runnetwork_tb.v` (il percorso RUN_NETWORK denso resta bit-identico: nessuno di questi test emette mai `SET_NET_TYPE`, confermando che il default `net_type=dense` dopo RESET funziona esattamente come richiesto dalla spec).
- 2026-09-03T04:30 — [G5] — Creato `sim/spi_neuron_top_graph_tb.v`: stesso stile/BFM SPI bit-banged di `spi_neuron_top_runnetwork_tb.v`, stesso grafo minuscolo delle fasi precedenti (4 ingressi, n4, n5=uscita), ma questa volta guidato INTERAMENTE via SPI simulato (nessun accesso diretto ai registri RTL): RESET -> WRITE_RAM(input/tabella/edge) -> SET_NET_TYPE(0x02) -> SET_BASE(x/table/out_base/n_inputs/num_neurons_graph/n_out, sel 0/3/4/7/9/10) -> RUN_NETWORK -> poll STATUS -> READ_RAM(out_base). 5 sotto-test: (1) grafo valido end-to-end, risultato 126 come atteso; (2) contenuto di out_base via READ_RAM; (3) READ_CONFIG espone N_TOTAL e il bit di capacità grafo; (4) un grafo deliberatamente non valido (self-reference) fa emergere STATUS.bit2=err VIA SPI REALE (non solo a livello RTL come in G4); (5) dopo un altro RESET, il percorso Tipo #1 legacy (SET_BASE X/W/BIAS + START) funziona identico a prima, a riprova che RESET riporta `net_type` a dense e che l'uso del grafo non lascia residui.
- 2026-09-03T04:35 — [G5] — **BUG DI TESTBENCH TROVATO E RISOLTO** (non RTL) durante la prima esecuzione di `spi_neuron_top_graph_tb.v`: il sotto-test 5 (Tipo #1 legacy dopo RESET) falliva con uscite `x` nonostante STATUS riportasse `done=1`. Debug approfondito (tracciamento ciclo-per-ciclo dello stato interno di `neuron_memory` con riferimenti gerarchici) ha mostrato che il calcolo procedeva realmente attraverso più neuroni (non un falso "done" spurio), ma con dati sbagliati. Causa: il sotto-test 4 (guardia) aveva impostato `SET_BASE sel 7` (`n_inputs_real`, riusato come N_in per il grafo) a 1 per costruire deliberatamente un grafo a un solo ingresso; l'opcode RESET pulisce solo lo stato interno dei motori di calcolo (`nm_soft_rst`), NON i registri di configurazione di `spi_engine` stesso (by design, così l'host può recuperare un motore bloccato senza dover riconfigurare tutto) — quindi `n_inputs_real=1` restava impostato anche nel sotto-test 5, facendo leggere a `neuron_memory` un solo byte di X invece di 4. **FIX**: aggiunto un `set_base(8'h07, 24'h000004)` esplicito prima del setup Tipo #1 del sotto-test 5, per ripristinare `n_inputs_real=4` come farebbe un host reale. Rieseguito: **SPI_NEURON_TOP GRAPH END-TO-END TEST PASSED**, tutti e 5 i sotto-test.
- 2026-09-03T04:40 — [G5] — Sintesi Yosys dell'intero `spi_neuron_top` con Tipo #2 abilitato (PARALLEL=2, come nella sintesi di riferimento del Tipo #1 puro): 0 problemi dal CHECK pass, **2× DP16KD** (act_buffer), 4× MULT18X18D (2 per `neuron_memory` + 2 per `graph_engine`, entrambi a PARALLEL=2, corretto), 16× `$_TBUF_` (bus PSRAM bidirezionale, invariato), 1 solo warning — lo stesso, già noto e atteso, "Yosys has only limited support for tri-state logic" da `psram_controller.v` (preesistente, non originato da questa fase). Script/log salvati in `synth/ecp5/spi_neuron_top_graph/`.
- 2026-09-03T04:45 — [G5] — REGRESSIONE FINALE su tutti i 20 testbench del repo (14 Tipo #1/memoria + `act_buffer_tb`/`graph_format_tb`/`graph_engine_tb`/`graph_engine_guard_tb`/`spi_neuron_top_graph_tb`): **TUTTI PASS**, zero regressioni.
- 2026-09-03T04:50 — [G5] — CONCLUSIONE G5: integrazione SPI/top-level completa e verificata sia a livello RTL isolato (G3/G4) sia end-to-end via SPI simulato reale (questa fase), con sintesi ECP5 pulita del sistema completo. Tutti i bug incontrati in G5 erano nei testbench (una connessione di porta mancante dopo l'estensione dell'interfaccia, e un registro di configurazione non ripristinato tra sotto-test), non nell'RTL. Procedo a G6 (regressione completa — già in gran parte coperta incrementalmente in questa fase, ma da ripetere come checkpoint esplicito prima di dichiarare il lavoro concluso).

- 2026-09-03T05:00 — [G6] — CHECKPOINT DI REGRESSIONE ESPLICITO: enumerati ed eseguiti TUTTI i 22 testbench presenti in `sim/`. 20/20 testbench "positivi" **PASS** (14 preesistenti Tipo #1/stack memoria invariati + `act_buffer_tb`, `graph_format_tb`, `graph_engine_tb`, `graph_engine_guard_tb`, `spi_neuron_top_graph_tb` di questa sessione). I restanti 2 (`neuron_parallel_guard_negative_degenerate_tb`, `neuron_parallel_guard_negative_nonmultiple_tb`, da una sessione precedente) sono test "negativi" il cui successo È il fallimento di elaborazione — confermato invariato: `rtl/neuron_parallel.v:72: Unknown module type: neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL`, esattamente come atteso, a riprova che il guard elaboration-time preesistente non è stato toccato da questa sessione. Sintesi ECP5 di sistema completo con Tipo #2 abilitato già verificata in G5 (`synth/ecp5/spi_neuron_top_graph/`). CONCLUSIONE G6: zero regressioni confermate su tutta la suite di test del repository. Il piano G1-G6 dello Type #2 è completo; G7 (page-mode PSRAM) resta esplicitamente opzionale per questa sessione. Procedo al deliverable §9/§11 ancora mancante: l'assemblatore host `tools/netasm/`.

- 2026-09-03T05:15 — [§9] — Creato `tools/netasm/` (Python, puro host-side, nessuna dipendenza esterna): `parser.py` (grammatica pseudo-assembly -> AST `DenseNet`/`GraphNet`, riga per riga, `;` commento a fine riga), `frames.py` (codifica esatta delle transazioni SPI: opcode + payload per ogni comando del §5, incl. i nuovi `SET_NET_TYPE`/sel 9/sel 10 di G5), `assembler.py` (AST -> layout indirizzi + byte esatti + sequenza comandi), `cli.py` (entry point), `README.md`, `examples/` (uno per tipo), `tests/test_netasm.py` (20 test unittest, nessuna dipendenza da pytest).
  - **Assegnazione id per il grafo**: input a 0..N_in-1; neuroni non-OUTPUT nell'ordine di dichiarazione, poi neuroni OUTPUT nell'ordine delle direttive OUTPUT — dato che la grammatica impone "usa solo nomi già dichiarati" nei CONN, l'ordine di dichiarazione è già un ordine topologico valido, quindi separare gli OUTPUT in coda (senza reordinare i non-output) basta a garantire "gli id di uscita sono i più alti" richiesto dal §4.4, SENZA bisogno di un vero algoritmo di sort topologico.
  - **Vincolo verificato**: un neurone usato come sorgente da un altro (CONN che lo referenzia per nome) non può comparire nella lista OUTPUT — controllato a tempo di assemblaggio (§4.4), con messaggio d'errore dedicato.
  - **Padding PARALLEL**: `n_conn_padded = max(PARALLEL, ceil(max(n_conn,1)/PARALLEL)*PARALLEL)` — il `max(n_conn,1)` garantisce che un neurone con ZERO connessioni reali venga comunque riempito con un intero gruppo di edge a peso zero (src=0, sempre valido perché id0 esiste sempre e src_id<out_id vale banalmente per qualunque neurone con id>0), evitando l'errore di caricamento "n_conn_padded==0" già implementato come guardia in `rtl/graph_engine.v` (G4).
  - **Formato dense**: la grammatica (§9) dichiara solo DIMENSIONI/attivazioni dei layer, non i VALORI dei pesi (assenti anche nell'esempio della spec) — l'assemblatore per il Tipo #1 quindi si limita a: validare che l'input reale di ogni layer sia multiplo di PARALLEL (stesso vincolo runtime di `neuron_parallel.v`/`neuron_memory.v`), allocare gli indirizzi di w_base/bias_addr per ogni layer, emettere la tabella descrittori + i comandi SET_BASE/RUN_NETWORK. I pesi/bias REALI restano da scrivere separatamente dall'host (via WRITE_RAM esistente) — documentato esplicitamente nel dump di debug e nel README, non un'omissione silenziosa.
  - **Bug d'ambiente incontrato e aggirato (non un bug del tool)**: l'ambiente di sviluppo ha `PYTHONPATH` che include `/tmp/prjtrellis/tools` (da un setup Yosys/Trellis preesistente), che crea un "namespace package" `tools` in conflitto con `tools/` di questo repo — `import tools.netasm` e `python3 -m tools.netasm.cli` falliscono con `ModuleNotFoundError` in QUESTO ambiente specifico (non un problema del codice). Risolto con: (1) nei test, caricamento del pacchetto `tools/netasm` per PERCORSO DI FILE esplicito via `importlib.util.spec_from_file_location`, che bypassa completamente la risoluzione di `sys.path`/`PYTHONPATH`; (2) in `cli.py`/`assembler.py`, un fallback `try: from . import X / except ImportError: import X` che permette anche l'esecuzione diretta come script (`python3 tools/netasm/cli.py ...`), utile di per sé indipendentemente dal problema d'ambiente.
  - Verificato manualmente end-to-end: `python3 tools/netasm/cli.py tools/netasm/examples/graph_example.netasm -o /tmp/graph_out --parallel 4 --max-conn 8` produce una tabella descrittori/edge byte-per-byte IDENTICA a quella verificata a mano in `sim/graph_format_tb.v`/`sim/graph_engine_tb.v`/`sim/spi_neuron_top_graph_tb.v` (stesso grafo di riferimento del §3), confermando che tool e RTL concordano sul formato dati indipendentemente l'uno dall'altro.
- 2026-09-03T05:20 — [§9] — `python3 tools/netasm/tests/test_netasm.py -v`: **20/20 PASS**. Copertura: parsing (grafo/denso, commenti, errori sintattici), assemblaggio grafo byte-esatto SENZA padding (PARALLEL=2, confrontato byte-per-byte contro l'esempio del §3), assemblaggio grafo CON padding (PARALLEL=4), neurone a zero connessioni, sequenza comandi SPI attesa, e un test per ciascuna delle guardie a tempo di compilazione (self-reference, forward-reference, output-usato-come-sorgente, overflow di MAX_CONN, overflow di N_TOTAL, OUTPUT non dichiarato) + layout/validazione PARALLEL per il denso.
- 2026-09-03T05:25 — [§9] — CONCLUSIONE: tutti i deliverable esplicitamente richiesti in §11 sono ora presenti: `rtl/act_buffer.v`, `rtl/graph_engine.v`, modifiche a `spi_engine.v`/`spi_neuron_top.v`, `tools/netasm/` con grammatica/esempi/test, testbench per ogni fase (G1-G5) + regressione completa verde (G6), report di sintesi ECP5 col Tipo #2 abilitato (`synth/ecp5/act_buffer/`, `synth/ecp5/graph_engine/`, `synth/ecp5/spi_neuron_top_graph/`), WORKLOG aggiornato fase per fase. G7 (page-mode PSRAM) resta apertamente non affrontato in questa sessione, come esplicitamente consentito dal piano ("opzionale").

## Nota finale — Tipo #2 (grafo sparso), sessione 2026-09-03

**Risultati.** Il Tipo #2 (rete a grafo arbitrario, edge-list sparsa) è implementato e verificato end-to-end senza toccare il datapath validato (`mac_unit`/`mac8`/`neuron_parallel`, invariati byte-per-byte). Il Tipo #1 (denso) resta bit-identico: tutti i 14 testbench preesistenti passano invariati, e nessuno emette mai `SET_NET_TYPE` (il default `net_type=dense` dopo RESET funziona esattamente come richiesto). Nuovi moduli: `rtl/act_buffer.v` (buffer di attivazione, DP16KD confermato in sintesi), `rtl/graph_engine.v` (FSM di orchestrazione, riusa `neuron_parallel` e `act_buffer` come istanze private). Modifiche mirate a `rtl/spi_engine.v` (opcode `SET_NET_TYPE`, selettori SET_BASE 9/10, dispatch di RUN_NETWORK, STATUS.bit2, READ_CONFIG esteso) e `rtl/spi_neuron_top.v` (istanza di `graph_engine`, mux di `run_start` e della porta C dell'arbitro su `net_type`). Tool host `tools/netasm/` completo con parser, assemblatore, validazioni a tempo di compilazione, e 20 test.

**Occupazione (sintesi Yosys, non piazzamento/routing).** `graph_engine` standalone (PARALLEL=8, MAX_CONN=32): 2× DP16KD, 8× MULT18X18D, 187 CCU2C, 1180 LUT4, 826 TRELLIS_FF. Sistema completo `spi_neuron_top` con Tipo #2 abilitato (PARALLEL=2): 2× DP16KD, 4× MULT18X18D (2 per `neuron_memory` + 2 per `graph_engine`), 391 CCU2C, 2367 LUT4, 2406 TRELLIS_FF, 16× `$_TBUF_` (bus PSRAM). Zero problemi dal CHECK pass di Yosys in ogni sintesi eseguita; un solo warning, preesistente e già documentato in una sessione precedente ("Yosys has only limited support for tri-state logic"), da `psram_controller.v`, non originato da questo lavoro.

**Fmax — MISURATO (aggiornamento post-sessione, con `nextpnr-ecp5` reale).** La dichiarazione iniziale di questa nota ("non misurato, `nextpnr-ecp5` non disponibile") era basata su `command -v nextpnr-ecp5` che fallisce con l'attuale `PATH` — ma un binario compilato esiste comunque su questa macchina (`/private/tmp/nextpnr/build/nextpnr-ecp5`, versione nextpnr-0.11.1-19-g8dbcee5c), trovato e usato dopo che l'utente ha chiesto esplicitamente la frequenza massima. Eseguito su `synth/ecp5/spi_neuron_top_graph/top.json` (sistema completo, Tipo #2 abilitato, PARALLEL=2): `nextpnr-ecp5 --45k --package CABGA381 --speed 8 --freq 80 --lpf-allow-unconstrained`.
  - **Risultato: Fmax = 55.59 MHz, FAIL al target di 80 MHz** (log completo in `synth/ecp5/spi_neuron_top_graph/nextpnr.log`).
  - **Percorso critico**: identico per natura a quello già trovato in una sessione precedente per il solo Tipo #1 — parte da `u_neuron_memory.u_neuron` (la catena di riporto CCU2C del comparatore di saturazione/ReLU in `neuron_parallel.v`, attraverso `mac8.v`), NON da `graph_engine` o da alcun modulo nuovo di questa sessione. Confermato leggendo per intero il report "Critical path report for clock ... (posedge -> posedge)" nel log: nessun elemento di `act_buffer`/`graph_engine` compare nel percorso più lento.
  - **Confronto con la sessione precedente**: Tipo #1 da solo, stesso PARALLEL=2, aveva dato ~55.85 MHz — praticamente lo stesso numero. L'aggiunta del Tipo #2 non ha quindi peggiorato (né migliorato) il collo di bottiglia esistente: il floorplanning automatico soffre dello stesso problema di temporizzazione a livello sistema già documentato, indipendente da questa sessione.
  - **Occupazione da place&route reale** (non solo conteggio Yosys): 2/108 DP16KD, 4/72 MULT18X18D, 2406/43848 DFF (5%), 3149/43848 LUT4 totali (7%, di cui 782 carry LUT) — tutto ben lontano dalla saturazione del dispositivo; il problema è di temporizzazione/floorplanning, non di spazio.
  - **Conclusione pratica**: 80 MHz non è raggiunto né con Tipo #1 né con Tipo #2 abilitato, con l'attuale RTL di `neuron_parallel.v` e il floorplanning puramente automatico (nessun vincolo di area, `--lpf-allow-unconstrained`). Restare esplicitamente FUORI dallo scope di questa sessione (che ha come vincolo invalicabile "non toccare `neuron_parallel.v`" tranne il guard già esistente) — la richiesta esplicita del piano di NON modificare il datapath validato impedisce di intervenire sulla catena di saturazione per risolverlo qui. Vera Fase 7 (ottimizzazione: pipeline del comparatore, vincoli di floorplanning LPF) resta il percorso corretto per affrontarlo.

**Cosa resta aperto:**
- **G7 (page-mode PSRAM, opzionale)**: non affrontato. Il gather casuale del grafo (un byte alla volta, `int8_memory_access` per ogni singolo edge) resta il collo di bottiglia di banda più ovvio per grafi grandi/densi — ogni edge costa un round-trip PSRAM completo (byte singolo, non pagina). Non misurato in questa sessione quanto pesi in pratica.
- **Banda PSRAM del gather**: non misurata quantitativamente (né in cicli/edge né in throughput). La spec la elenca esplicitamente come nota finale da riportare; richiederebbe un benchmark dedicato (stile `docs/FPGA-Neural-Datapatch-Benchmark.md`) su grafi di dimensione realistica, non fatto qui.
- **Innalzamento di N_TOTAL** (oltre 4096, fino al limite teorico di 65536 con id a 16 bit): nessun ostacolo strutturale noto — `act_buffer`'s `ADDR_WIDTH` è già derivato da `$clog2(N_TOTAL)` parametrico, e `graph_engine`/`spi_engine` propagano `N_TOTAL` come parametro — ma non testato a valori più alti di 4096 in questa sessione, e l'impatto sull'occupazione DP16KD (block RAM più grandi/più numerose) non misurato.
- **Fmax reale del sistema con Tipo #2** (vedi sopra): richiede `nextpnr-ecp5`, non disponibile in questo ambiente.
- **Pesi/bias reali per il Tipo #1** tramite `netasm`: il tool genera solo il layout/tabella per il denso, non i comandi WRITE_RAM dei valori reali (spec non li fornisce nella grammatica) — un'estensione naturale futura sarebbe accettare i pesi come dati numerici nel sorgente `.netasm` stesso o da un file separato (es. numpy/CSV) ed emettere anche quei WRITE_RAM.

## Pinout fisico reale (2026-09-03, su richiesta esplicita dell'utente)

L'utente ha chiesto "un pinout sensato" e perché non esistesse già un `.lpf`. Risposta: la spec originale lo escludeva esplicitamente ("altro task", vedi appendice); tutte le sintesi finora (comprese sessioni precedenti) usavano `--lpf-allow-unconstrained`. Eseguito ora come task a parte:

- **Fonte dati**: la spreadsheet citata in memoria (`../basic-ecp5-pcb/docs/ECP5Upinouts.ods`) non esiste più su questa macchina (cercata ovunque, assente). Usata invece **Project Trellis stesso** (`prjtrellis`'s `database/ECP5/LFE5U-45F/iodb.json`) — la stessa base dati che `nextpnr-ecp5` usa realmente — unendo `packages['CABGA381']` (ball -> col/row/pio) con `pio_metadata` (col/row/pio -> banco/funzione) per ottenere banco e funzione reali di ogni ball. Nessun numero inventato.
- **Geometria fisica** ricavata da `globals.json` di Trellis (quadranti/die coordinate): banchi 2 (col=90, row 11-32) e 3 (col=90, row 35-68) sono contigui sul lato DESTRO del die — usati insieme per l'intero bus PSRAM (44+1 segnali: 22 indirizzi + 16 dati + 6 controllo + 1 bit sempre-zero). Banco 7 (col=0, row 11-32, lato SINISTRO, fisicamente opposto) per SPI applicativo + clock/reset, deliberatamente sul lato opposto per non incrociare i due bus. `clk` fissato su `H5` (`GR_PCLK7_0`, pad di clock globale dedicato nel banco 7).
- **Script riproducibile**: `tools/pinout/gen_lpf.py` (richiede `prjtrellis`), genera `synth/ecp5/spi_neuron_top.lpf` (51 segnali vincolati, `LOCATE`+`IOBUF LVCMOS33`).
- **Verificato con place&route REALE** (non solo generato a tavolino): `nextpnr-ecp5 --45k --package CABGA381 --speed 8 --freq 80 --json synth/ecp5/spi_neuron_top_graph/top.json --lpf synth/ecp5/spi_neuron_top.lpf` — **0 errori di vincolo, routing completo, "Program finished normally"** (incl. il ball dual-function `VREF1_2` usato come GPIO semplice, funziona senza problemi). Log: `synth/ecp5/spi_neuron_top_graph/nextpnr_constrained.log`.
- **Fmax con pinout reale fisso: 54.58 MHz** (FAIL a 80MHz) — quasi identico ai 55.59 MHz auto-piazzati di prima: vincolare i pin non ha spostato di molto il numero, confermando che il collo di bottiglia è strutturale (catena di saturazione in `neuron_parallel.v`), non di piazzamento. TRELLIS_IO: 51/245 (20%), conferma la stima di margine del documento hardware.
- **Documentazione aggiornata**: `docs/FPGA-Neural-Hardware-Design.md` §2 (nota sulla fonte dati non più disponibile) e §7 (riscritto con la tabella pin reale, raggruppata per funzione, con note sui ball dual-function) e §9 (checklist: `.lpf` segnato fatto per SPI+PSRAM; config-SPI e JTAG restano aperti — sono ball a funzione fissa non presenti nel database di I/O programmabile di Trellis, servirebbe la vera tabella datasheet Lattice, non disponibile in questo ambiente).
- **Ancora mancante**: ball di config-SPI (verso la flash) e JTAG (debug) — sono pin a funzione dedicata/fissa dal package, non enumerati nel database PIO generico di Trellis (che copre solo I/O programmabile). Richiedono la vera tabella datasheet Lattice per il CABGA381, non disponibile in questo ambiente — task ancora aperto.

## Timing closure di `neuron_parallel` (2026-09-03, su prompt dedicato dell'utente)

Deroga esplicita concessa dall'utente al vincolo "datapath intoccabile" per un task **separato e deliberato** di timing closure, con un solo vincolo: equivalenza bit-esatta su tutta la regressione. Diagnosi di partenza (già fornita dall'utente, confermata rileggendo `mac8.v`/`mac_unit.v`): nessun comparatore lì, solo aritmetica pura — tutta la logica di saturazione/ReLU è in `neuron_parallel.v`.

### Passo 1 — saturazione/ReLU come bit-test

Riscritti i confronti `> 127` / `< -128` / `<= 0` su `final_acc` (ACC_WIDTH=32 bit) come riduzioni AND/OR sui bit `[ACC_WIDTH-1:DATA_WIDTH-1]` (in-range sse tutti uguali fra loro), parametrico su `DATA_WIDTH`/`ACC_WIDTH`, non hardcoded a 8 bit. Verificato a mano su tutti i casi limite (126,127,128,129,-128,-129,-1,0) per entrambe le attivazioni prima di scrivere il test.

- Nuovo `sim/neuron_parallel_saturation_bounds_tb.v`: 16 casi (8 valori limite × 2 attivazioni), N_INPUTS=PARALLEL=1 per centrare `final_acc` esattamente sul valore bersaglio via `(x,w,bias)` scelti a mano. **Tutti PASS**.
- Regressione completa (21 testbench, incl. tutti quelli Tipo #1/#2 di questa sessione): **tutti PASS, zero differenze di valore**.
- **Sintesi/place&route — finding non banale**: contando gli hop CCU2C nel SOLO percorso critico riportato da `nextpnr-ecp5` (non l'intero design), il Passo 1 riduce genuinamente sia il conteggio (P2: 70→64, P8: 60→56) sia il delay di sola logica (P2: 7.97→7.74ns, P8: 8.47→7.58ns) — **ma** Yosys/abc9 mappa la riduzione AND/OR larga su celle CCU2C (carry chain) anch'essa, non su un albero LUT piatto come ci si aspetterebbe: la promessa "niente più carry chain" non si realizza alla lettera. Il guadagno di logica reale (~0.2-0.9ns) risulta **sommerso dal rumore di piazzamento**: sweep di 4 seed extra oltre al default mostra P2 prima/dopo che si sovrappongono ampiamente (before 43-50MHz a P8, after 45-48MHz; before ~55.6MHz singolo seed a P2, after 52-56MHz su 5 seed) — nessun verdetto netto attribuibile al solo Passo 1. Tenuto comunque: è una semplificazione corretta e verificata bit-esatta, il guadagno di logica è reale anche se non decisivo da solo.

### Passo 2 — pipeline stage (accumulo/bias+attivazione separati)

Dato che il Passo 1 da solo non chiude nulla in modo affidabile (rumore di piazzamento domina), e che il percorso critico dopo il Passo 1 è confermato essere l'albero adder di `mac8`/somma del bias (aritmetica genuina, non la saturazione), applicato il Passo 2: nuovo registro `finishing` (1 bit) in `neuron_parallel.v` che separa in DUE cicli quello che prima era un solo ciclo:
- ciclo N (ultimo gruppo MAC): `acc <= acc_next;` (somma completa, bias non ancora sommato) — identico a un ciclo di accumulo normale, poi `finishing <= 1`.
- ciclo N+1 (`finishing`): `final_acc = acc + bias_ext` (ora dal registro `acc`, non da `acc_next` combinatorio nello stesso ciclo), saturazione bit-test, scrittura di `y`, `done <= 1`.

`busy` resta alto per tutto il ciclo extra — **trasparente** per `neuron_memory.v`/`layer_sequencer.v`/`graph_engine.v`: nessuna interfaccia toccata, +1 ciclo di latenza per neurone assorbito dall'handshake `start`/`busy`/`done` esistente. Nessun testbench ha dovuto essere aggiornato (nessuno conta cicli esatti, tutti pollano `done` con timeout generosi).

- Regressione completa (21 testbench + boundary test): **tutti PASS, zero differenze di valore** (solo la latenza cambia, mai il risultato).
- Guard negativi (`neuron_parallel_guard_negative_*_tb.v`): confermato ancora falliscono in elaborazione come previsto, invariati.

### Tabella Fmax prima/dopo (place&route reale, `nextpnr-ecp5`, stesso JSON/toolchain di questa sessione)

| Config | Prima (originale) | Dopo Passo 1 (bit-test) | Dopo Passo 2 (+pipeline) | Δ Passo1→Passo2 |
|---|---|---|---|---|
| PARALLEL=2, LPF reale, seed default | 54.58 MHz | 52.90 MHz | **75.30 MHz** | +42% |
| PARALLEL=2, unconstrained, seed default | 55.59 MHz | 52.78 MHz | — | — |
| PARALLEL=2, LPF reale, sweep 5 seed | 55.59 MHz (1 seed) | 52.00–55.85 MHz | **73.38–75.55 MHz** | robusto |
| PARALLEL=8, unconstrained, seed default | 45.47 MHz | 48.72 MHz | **60.26 MHz** | +24% |
| PARALLEL=8, unconstrained, sweep 5 seed | 43.15–50.48 MHz | 44.90–48.72 MHz | **60.26–68.87 MHz** | robusto, non sovrapposto al "prima" |

Il Passo 2 è l'unico che dà un salto **strutturale e riproducibile su ogni seed** (non sovrapposto al range "prima", a differenza del Passo 1) — coerente con l'aspettativa: tagliare la catena con un registro garantisce il risultato indipendentemente dall'euristica di piazzamento, mentre accorciare la sola logica no. Percorso critico dopo il Passo 2 (verificato rileggendo il report): interamente dentro `u_neuron.acc_next` — l'albero adder di `mac8.v` + uscita `MULT18X18D`, aritmetica genuina del MAC, non più saturazione/attivazione. Occupazione invariata (2 DP16KD, 4 MULT18X18D, stesso conteggio di prima — solo qualche FF in più per `finishing`).

### Conclusione e stop

**80 MHz non raggiunto** (75.30 MHz a PARALLEL=2, 94% del target; 60-69 MHz a PARALLEL=8) ma **guadagno enorme e reale** rispetto al punto di partenza (+35% e +33% rispettivamente). Mi fermo qui, per i criteri di stop indicati dall'utente stesso: il prossimo passo naturale (registro di uscita del `MULT18X18D`, che toccherebbe `mac_unit.v`) attaccherebbe la stessa aritmetica del MAC ora al collo di bottiglia, ma 80MHz è dichiarato "headroom in vista del `.lpf` reale, non un requisito operativo" (l'oscillatore previsto è 16MHz — anche il numero PEGGIORE misurato in questa sessione, 44.90MHz a P8/seed3, ha 2.8× di margine). Non proseguo oltre senza indicazione esplicita, per non aggiungere un'altra latenza/complessità (un ulteriore ciclo di pipeline nel DSP) per un guadagno incerto.

**Verifica finale (§8 del prompt)**: `CLK_FREQ_MHZ` di default nell'RTL resta 80 (non toccato, come richiesto) — coerente con l'ipotesi di lavoro di questa sessione (sintesi mirata a 80MHz), ma **incoerente con l'oscillatore reale raccomandato (16MHz)** in `docs/FPGA-Neural-Hardware-Design.md` §4: quel documento segnala già esplicitamente che `CLK_FREQ_MHZ` va impostato a 16 quando si sintetizza per l'hardware reale, altrimenti i tempi di accesso PSRAM (`ceil(70ns × CLK_FREQ_MHZ / 1000)`) risultano sottostimati di 5×. Non modificato qui (è responsabilità di chi istanzia il modulo per il target reale, non un default RTL da cambiare in questo task).

**Cosa resta** (invariato dal piano originale): pinout config-SPI/JTAG (vedi sezione pinout sopra), page-mode PSRAM (banda edge-list del Tipo #2), eventuale ulteriore pipeline nel DSP se in futuro servisse chiudere gli ultimi ~5-20MHz a 80MHz reali.

## Datasheet Lattice reale fornito dall'utente (2026-09-03)

L'utente ha fornito il PDF ufficiale (`FPGA-DS-02012-3-4-ECP5-ECP5G-Family-Data-Sheet.pdf`). Letto per intero (115 pagine, `pdftotext` + verifica visiva delle pagine 96-99, sezione 4 "Pinout Information" completa).

- **Validazione incrociata positiva**: la tabella §4.3.2 "LFE5U" del datasheet dà, per LFE5U-45/381caBGA, i conteggi I/O per banco 27/33/32/32/–/33/32/13 (banchi 0/1/2/3/4/6/7/8) — combaciano ESATTAMENTE con quelli derivati da Project Trellis usati in §7 su 6 banchi su 7 (differenza di 1 solo ball sul banco 3, ininfluente: nessuno dei 51 segnali assegnati usava quel ball conteso). Conferma indipendente che usare il database di Trellis al posto della spreadsheet non più disponibile era la scelta giusta, non una scorciatoia che ha introdotto errori.
- **Confermato (non per la prima volta, ma ora con fonte ufficiale)**: il datasheet NON contiene una tabella ball-per-ball. La sezione 4 ha solo §4.1 (descrizioni funzionali, nessun numero di ball) e §4.3 (solo conteggi di riepilogo: TAP=4 per JTAG, "Miscellaneous Dedicated Pins"=7 per il config-SPI/PROGRAMN/INITN/DONE/CCLK/CFG). L'assegnazione ball-per-ball resta una risorsa Lattice separata (spreadsheet o database Diamond/Radiant), non in questo PDF.
- **Correzione importante**: i ball di JTAG/config-SPI NON bloccano nulla del lavoro RTL/sintesi di questa repo — sono pin dedicati a funzione fissa, senza alcuna porta corrispondente in `rtl/spi_neuron_top.v` (nessun TCK/TMS/TDI/TDO/PROGRAMN/ecc nel netlist utente), quindi `nextpnr-ecp5` non li richiede mai e nessuna riga di `.lpf` è possibile o necessaria per loro — confermato dai run a 0 errori già eseguiti. Contano solo per la SCHEMATIC CAPTURE del PCB (header JTAG + flash di config), che è lavoro KiCad separato dell'utente (cartella non tracciata `FPGA-Neural/`), non un deliverable di sintesi di questo repo. Corretto di conseguenza in `docs/FPGA-Neural-Hardware-Design.md` §7/§9 (il checklist item non è più "bloccante", solo "non ancora fatto, e non necessario per l'RTL").
- Aggiornato anche il numero di Fmax riportato in §7 (era rimasto a 54.58MHz, il valore pre-timing-closure) con il nuovo 75.30MHz post-pipeline.

## Bitstream reale + banda del gather (2026-09-03, su richiesta esplicita "#6 e #2 se veramente utile")

### #6 — Generazione bitstream reale (`ecppack`)

Mai fatto finora in questa sessione (solo `nextpnr` fino al `.config`). Trovato `ecppack` su `PATH` (`/opt/homebrew/bin/ecppack`, Project Trellis 1.4). Eseguito sul risultato del timing closure (Passo 2, `synth/ecp5/timing_closure/step2/top_p2.config` e `top_p8.config`):

```
ecppack --compress synth/ecp5/timing_closure/step2/top_p2.config synth/ecp5/timing_closure/step2/top_p2.bit
ecppack --compress synth/ecp5/timing_closure/step2/top_p8.config synth/ecp5/timing_closure/step2/top_p8.bit
```

**Risultato: 0 errori, bitstream generato per entrambi** (226KB/234KB compressi, ~1MB non compresso — dimensione plausibile per questo dispositivo). Header del bitstream verificato byte-per-byte: `Part: LFE5U-45F-8CABGA381` — **il part number REALE del target hardware confermato**, non un placeholder. Questo chiude end-to-end l'intera toolchain aperta (RTL → Yosys → nextpnr-ecp5 → ecppack) con 0 errori ad ogni stadio, per la prima volta in questa sessione. Non testato su hardware reale (nessuna scheda fisica disponibile in questo ambiente) — la generazione del bitstream è verificata, la programmazione no.

### #2 — Banda del gather (misurata quantitativamente per la prima volta)

Nuovo `sim/graph_engine_bandwidth_tb.v`: isola il costo MARGINALE per edge confrontando due grafi identici per struttura (una catena di N=16 neuroni, tutti che referenziano id0 con peso 0 — il contenuto non conta, solo il conteggio edge) con K1=4 e K2=8 edge/neurone (multipli di PARALLEL=4, zero padding a confondere la misura):

```
K1=4 edge/neurone (64 edge totali): 5787 cicli
K2=8 edge/neurone (128 edge totali): 9195 cicli
cycles_per_edge = (9195-5787) / (16*(8-4)) = 53.25 cicli/edge
```

Il metodo per differenza cancella ogni costo fisso per-neurone (lettura descrittore, calcolo `neuron_parallel`, `WRITE_ACT`), isolando solo il costo del gather per edge. **Coerente con l'analisi teorica**: ogni edge sono 4 byte (src_id 2B + peso 1B + riservato 1B), ogni byte via PSRAM asincrona costa ~13 cicli (letture precedenti di debug in questa sessione mostravano 12-14 cicli/byte) → 4×13≈52, molto vicino ai 53.25 misurati.

- A 80MHz (clock di sintesi di default): **~1.50M edge/s, banda edge-stream effettiva ~6.0 MB/s**.
- A 16MHz (oscillatore reale raccomandato, `docs/FPGA-Neural-Hardware-Design.md` §4): **~300k edge/s, ~1.2 MB/s**.

Per contesto: un grafo con qualche migliaio di edge (dimensione realistica per una piccola rete) costerebbe quindi qualche decina di migliaia di cicli SOLO per il gather — questo è esattamente il collo di bottiglia che G7 (page-mode read PSRAM, mai affrontato in questa sessione, esplicitamente opzionale) punterebbe a ridurre: ogni edge oggi costa un round-trip PSRAM completo (byte singolo), non una lettura in burst di pagina.

### Conclusione

Entrambi i task extra erano "veramente utili": #6 dà la prova end-to-end che l'intera toolchain produce un bitstream valido per il part reale (nessun gap di processo nascosto), #2 dà per la prima volta un numero concreto (53.25 cicli/edge) al posto di "non misurato", trasformando l'apertura G7 da vaga a quantificata: **sapere che 53 cicli/edge è il costo attuale rende ora possibile stimare in anticipo se G7 vale lo sforzo per una rete di dimensione data**, invece di scoprirlo dopo averlo implementato.

## Pin fisici IRQ_N / DATA_READY_N (2026-09-03, richiesta esplicita dell'utente)

Richiesti due nuovi pin fisici attivi bassi: `IRQ_N` (avvisa il processore host che è richiesta attenzione) e `DATA_READY_N` (avvisa che un input è stato elaborato). Decisione di design (non specificata dall'utente, presa e documentata): i due pin NON sono ridondanti — coprono due eventi diversi già esistenti nel protocollo SPI, semplicemente esposti anche come segnale fisico oltre che come bit di STATUS:

- **`DATA_READY_N`** = `~status_done_sticky` (STATUS.bit1) — il "lieto fine": un run (denso o grafo) è terminato con successo, il risultato è pronto da leggere. Stessa esatta bascula di STATUS.bit1: si azzera (torna alto) quando l'host legge STATUS con quel bit attivo, o su RESET — **nessuna nuova logica di clear**, è letteralmente lo stesso flip-flop cablato anche su un pin.
- **`IRQ_N`** = `~graph_err` (STATUS.bit2) — il caso "serve intervento": la guardia load-time del grafo (§7 della spec Tipo #2) ha rilevato una violazione. Diversamente da `DATA_READY_N`, NON si azzera con una semplice lettura di STATUS (coerente con `graph_engine.err`, che è sticky fino a RESET o a un nuovo `run_start` su grafo) — un IRQ deve restare visibile finché l'host non lo gestisce attivamente, non sparire alla prima lettura di stato di routine.

Entrambi derivati direttamente da bit già registrati (`status_done_sticky` in `spi_engine.v`, `err` in `graph_engine.v`) — un'inversione combinazionale sul pin, nessun registro/pipeline aggiuntivo necessario, nessun rischio di glitch.

- **`rtl/spi_engine.v`**: nuova porta `output wire data_ready`, `assign data_ready = status_done_sticky;` vicino alla dichiarazione del registro.
- **`rtl/spi_neuron_top.v`**: nuove porte fisiche `irq_n`, `data_ready_n`; `assign data_ready_n = ~data_ready; assign irq_n = ~graph_err;`.
- **Nuovo `sim/spi_neuron_top_irq_tb.v`**: 4 test — (1) entrambi i pin alti dopo reset, (2) run grafo valido: `data_ready_n` si abbassa, `irq_n` resta alto per tutta la durata, `data_ready_n` torna alto dopo lettura STATUS; (3) run grafo non valido: `irq_n` si abbassa, `data_ready_n` resta alto (nessun risultato pronto), `irq_n` resta basso anche dopo una lettura STATUS non correlata (non è clear-on-read); (4) RESET riporta `irq_n` alto. **Tutti PASS**.
- Regressione completa (22 testbench, incl. tutti quelli di questa sessione): **tutti PASS**, nessuna interfaccia esistente toccata (le porte nuove sono aggiuntive, non sostitutive).
- **Pinout aggiornato**: `tools/pinout/gen_lpf.py` esteso per assegnare 2 ball reali in più nel banco 7 (stesso banco di `sclk/mosi/miso/cs_n/rst/clk`, coerente con la logica "lontano dal bus PSRAM" già usata) — verificato che i 5 segnali SPI esistenti mantengono ESATTAMENTE gli stessi ball di prima (solo aggiunta, nessuna riassegnazione). `data_ready_n`→ball C3, `irq_n`→ball C4. Ri-verificato con place&route reale: **0 errori di vincolo**, `Program finished normally`, 53/245 TRELLIS_IO (21%). Fmax 73.88MHz — dentro la stessa banda di rumore già caratterizzata nello sweep di seed del timing closure (non una regressione).
- Documentazione aggiornata: `docs/FPGA-Neural-Hardware-Design.md` §2 (budget pin) e §7 (tabella pinout + nota sulla verifica).

## PSRAM page mode (2026-09-03, richiesta esplicita dell'utente: "controlla se è implementato il trasferimento page della RAM")

Chiuso esattamente il gap che l'entry precedente ("Bitstream reale + banda del gather") aveva lasciato esplicitamente aperto e quantificato come G7: `rtl/psram_controller.v` faceva SOLO accesso asincrono a parola singola, ogni transazione pagava sempre i 70ns pieni (`ACCESS_CYCLES`), nessun uso del page mode che il chip target (ISSI IS66WVE4M16EBLL-70BLI, "asynchronous/**page mode**") supporta realmente. Confermato leggendo il datasheet reale della famiglia (scaricato ed estratto pagina per pagina, non assunto): pagina di 16 word (`A[3:0]`), `tAPA`/`tPC` = 20ns per accessi successivi nella stessa pagina invece di `tAA` = 70ns, page mode **disabilitato di default all'accensione** (bit 7 del registro di configurazione, CR = `0x0070` di default) — quindi non bastava solo velocizzare i cicli, serviva anche abilitare esplicitamente il chip.

**Implementazione (`rtl/psram_controller.v`)** — interamente interna al controller, interfaccia `mem_*` verso `memory_interface.v` invariata (nessuna modifica a nessun altro modulo RTL):
- **Abilitazione page mode all'avvio**: nuovo stato `STATE_CR_INIT` tra `STATE_INIT` e `STATE_IDLE`, esegue la "software-access sequence" del datasheet (Fig. 6): 2 letture dummy + 2 scritture (0x0000 di sblocco, poi CR reale = `0x00F0` = default + bit Page) all'indirizzo massimo del chip, ognuna un impulso CE# separato — riusa esattamente la stessa logica `STATE_READ`/`STATE_WRITE` già esistente, quindi passa dagli stessi controlli di timing di ogni altra transazione.
- **Burst di pagina**: dopo una READ, il controller non chiude più CE#/OE# — resta in un nuovo stato `STATE_PAGE_OPEN`. Una READ successiva nella stessa pagina (bit sopra `A[3]` invariati) cambia solo il bus indirizzi e aspetta `PAGE_CYCLES` (tAPA) invece di `ACCESS_CYCLES` (tAA); una READ che attraversa pagina resta comunque senza toggle di CE# ma paga un tAA pieno per quella parola (esattamente la regola del datasheet: "any change in addresses A[4] or higher initiates a new tAA access time"). Un contatore `hold_cycles` chiude la pagina prima del limite `tCEM` (8µs, refresh) con margine di sicurezza (6µs). Solo una WRITE forza la chiusura (nuovi stati `STATE_PAGE_CLOSE`/`STATE_PAGE_REOPEN`, un ciclo di gap per rispettare `tHZ` prima che il controller inizi a pilotare il bus dati).
- **Bug trovato e corretto PRIMA di considerarlo finito** (verificato quantitativamente, non solo per intuito): la prima versione trattava anche un cambio di `lb_n`/`ub_n` come condizione di chiusura pagina, per prudenza. Misurando la banda reale del gather di `graph_engine` (stesso benchmark dell'entry precedente, `sim/graph_engine_bandwidth_tb.v`) con quella policy: **53.25 → 61.25 cicli/edge, PEGGIORE non migliore**. Causa: `int8_memory_access.v` alterna `LB#`/`UB#` a quasi ogni accesso (accesso byte-granulare su bus a 16 bit — è così che l'INT8 arriva/riparte dalla PSRAM ovunque nel progetto), quindi quella policy chiudeva la pagina quasi ad ogni parola, pagando il costo extra di chiusura/riapertura senza mai raggiungere il percorso veloce. Il datasheet non richiede affatto che `LB#`/`UB#` restino fissi durante un burst di pagina (Fig. 4 li mostra fissi ma la temporizzazione è definita solo su indirizzi/CE#/OE#) — rimossa la condizione, tenuta solo WRITE (+ timeout `tCEM`) come chiusura. Misurato di nuovo: **53.25 → 37.53 cicli/edge, banda gather 6.01→8.53 MB/s a 80MHz (+42%), 1.20→1.71 MB/s a 16MHz (oscillatore reale target)** — numeri prima/dopo ottenuti con `git stash` mirato ai soli due file toccati (`rtl/psram_controller.v`, `sim/psram_model.v`), per isolare l'effetto senza toccare il resto del lavoro in corso non commesso.
- **`sim/psram_model.v`** (il modello PSRAM comportamentale con controlli di timing rigorosi/`$fatal`, condiviso da 13 testbench) esteso con un check indipendente `tAPA`/`tAA` per i cambi di indirizzo mentre CE#/OE# restano bassi — altrimenti il modello non avrebbe mai verificato la nuova modalità (i suoi controlli esistenti erano tutti agganciati a `negedge`/`posedge ce_n`, eventi che un burst di pagina per costruzione non genera più tra una parola e l'altra). **Bug di modellazione trovato e corretto durante lo sviluppo del test**: il primo check confrontava l'intervallo SBAGLIATO (tempo tra l'indirizzo che arriva e quello precedente, con soglia scelta guardando la parola in arrivo) — la regola del datasheet riguarda invece quanto a lungo la parola *in corso* va tenuta prima che il controller possa muoversi, cosa nota solo confrontando quella parola con la PRECEDENTE, non con la prossima (non ancora arrivata). Corretto rendendo il vincolo differito di una parola (`pending_min_t`, calcolato quando la parola arriva, verificato al cambio successivo). Il primo tentativo (sbagliato) è stato scoperto perché ha fatto scattare `$fatal` durante il test di attraversamento pagina, non ignorato.
- **Nuovo `sim/psram_page_mode_tb.v`**: burst di 16 word nella stessa pagina (verifica sia i dati sia il tempo, il primo paga tAA, i successivi tAPA), attraversamento pagina con CE# che resta basso, WRITE che chiude la pagina (verificato contando i fronti di salita di CE#, non per intuito — inclusa la scoperta che una WRITE dentro una sessione READ aperta costa **2** impulsi CE# non 1: uno per chiudere la sessione READ, uno per la WRITE stessa), cambi di byte-enable che restano sul percorso veloce (il caso reale, vedi bug sopra), stress con 64 pagine sparse miste READ/WRITE. **Tutti PASS**.
- **Regressione completa**: tutti i 26 testbench esistenti (compreso il nuovo) ricompilati ed eseguiti da zero due volte (prima e dopo il fix del bug byte-enable) — **0 `$fatal` in entrambi i giri**, nessuna interfaccia esterna toccata.
- **Impatto risorse ECP5** (Yosys `synth_ecp5`, `psram_controller.v` isolato): 63→290 LUT4, 83→141 TRELLIS_FF, 7→12 CCU2C, 8→57 PFUMX — atteso, la FSM è passata da 5 a 9 stati con due comparatori aggiuntivi (page-hit, timeout). Sul sistema completo (`spi_neuron_top` con Tipo #2, stessa configurazione `synth/ecp5/spi_neuron_top_graph/`, PARALLEL=2): 2367→2619 LUT4, 2406→2467 TRELLIS_FF — su un dispositivo da ~43.8k LUT4 equivalenti resta sotto il 6% di utilizzo, nessun impatto pratico. Fmax reale ri-misurato con `nextpnr-ecp5` sullo stesso comando/vincoli già validati: **75.73 MHz** (era 55.59 MHz prima di questa sessione) — ancora FAIL all'obiettivo 80MHz ma **migliore**, non peggiore; coerente con quanto già stabilito nello sweep di seed del Fase 7 (il collo di bottiglia resta il comparatore di saturazione in `neuron_parallel.v`, non lo stack PSRAM — il rumore di piazzamento su questo design domina di più della differenza di logica).
- Documentazione aggiornata: `docs/FPGA-Neural-Hardware-Design.md` §3 (PSRAM subsystem), `docs/FPGA-NeuralNetwork-Engine.md` §17 (Current Status), `docs/FPGA-Neural-Datapatch-Benchmark.md` Appendice C (stato) + nuova Appendice D (numeri di banda/risorse/Fmax).

## PSRAM page mode — giro di rigore aggiuntivo (2026-09-03, richiesta esplicita dell'utente)

L'utente ha fornito una nota tecnica dettagliata con requisiti di verifica specifici per il lavoro sopra (page-mode PSRAM). Confronto punto per punto: la maggior parte era già soddisfatta (nessun tocco a `mac_unit`/`mac8`/`neuron_parallel`/`act_buffer`, fast path solo in lettura, interfaccia `psram_controller` invariata, confine di pagina rilevato dalla FSM con dati letti dal datasheet reale, banda prima/dopo a 16MHz e 80MHz già in tabella). Tre richieste NON erano ancora coperte, e nel colmarle sono emersi **due bug reali**, non solo lavoro amministrativo:

- **`sim/psram_model.v` non applicava mai un limite `tCEM` esplicito.** L'utente lo ha segnalato esplicitamente ("non ignorare tCEM perché in simulazione funziona: il modello potrebbe non modellarlo") — ed era vero: il modello aveva i check `tAPA`/`tAA` aggiunti in precedenza ma nessun controllo indipendente sul tempo massimo di CE# basso (8µs reali, confermato dal datasheet, non i ~4µs ipotizzati nella nota). Aggiunto: `TCEM_NS = 8000.0` più due check (`posedge ce_n` per la lunghezza totale della sessione, `always @(a)` per rilevare un overrun a metà burst, non solo a chiusura).
- **Bug scoperto introducendo quel check**: il nuovo controllo su `always @(a)` scattava un falso `$fatal` proprio alla PRIMA parola di ogni sessione (es. durante la sequenza CR all'avvio). Causa: race Verilog reale, non ipotetica — `a` e `ce_n` cambiano nello stesso istante di simulazione (stesso assegnamento non bloccante nel controller), ma `always @(negedge ce_n)` e `always @(a)` sono due processi indipendenti e l'ordine con cui girano nello stesso istante **non è definito dallo standard**: se `always @(a)` gira per primo, legge `ce_low_time` non ancora aggiornato dall'altro processo. La guardia `$realtime > ce_low_time` che doveva escludere la prima parola si basava implicitamente su un ordine di esecuzione che nessuno garantiva — funzionava solo per fortuna dell'ordine di scheduling di Icarus nei test già scritti. Corretto con la tecnica standard Verilog per questo esatto problema: un `#0` in testa al blocco `always @(a)`, che rinvia la valutazione a dopo che tutti i processi a ritardo zero triggerati nello stesso istante (incluso l'handler `negedge ce_n`) hanno finito. Rieseguita tutta la regressione page-mode dopo il fix: pulita.
- **Nuovo test dedicato**: un burst di centinaia di letture consecutive nella stessa pagina, mai idle, per dimostrare che la spaccatura del burst avviene anche quando il contatore si esaurisce **durante** un burst attivo (non solo nel caso idle già coperto) — con margine reale sotto il limite `tCEM` del modello (8µs), non per coincidenza. Risultato: split confermato (8 chiusure di CE# durante il loop), nessun `$fatal` dal modello. Regressione completa (26 testbench) ripetuta con il modello aggiornato: **0 `$fatal`**.
- **Fmax a P8** (mancava, avevo solo P2): sintetizzato e piazzato/instradato `spi_neuron_top` (Tipo #2, `PARALLEL=8`) con lo stesso comando/vincoli validati: **65.13 MHz**, FAIL a 80MHz come P2, coerente. **Natura del percorso critico verificata esplicitamente** (non assunta) leggendo il report di `nextpnr-ecp5` per entrambi P2 e P8: in entrambi i casi la sorgente è `u_graph_engine.u_neuron.group_index` → `mac8`/`neuron_parallel` (stessa catena CCU2C dell'accumulatore già nota dalla Fase 7) — **`psram_controller` non compare mai nel percorso critico**, nonostante la crescita di risorse del page mode.
- **Ri-esecuzione del benchmark P2/P4/P8 isolato** (`tools/fpga_benchmark.py`, richiesta esplicita di rieseguire "anche quelli sulla parallelizzazione"): tentata, ma il sotto-processo Yosys per P8 è andato in una patologia di `abc -g simple` sul netlist srotolato (256×4×32 MAC), consumando >144 minuti di CPU senza terminare — **verificato non essere un effetto del lavoro di questa sessione** (lo script sintetizza solo `mac_unit`/`mac8`/`neuron_parallel`/`layer.v`, mai toccati; stesso script, stesso RTL di input di prima). Processo terminato (kill). I numeri storici (P16 52.13, P8 61.71, P4 75.01, P2 87.88 MHz) restano validi perché deterministici su input invariati; non riprodotti in questa sessione per il blocco del toolchain. La verifica realmente rilevante per il lavoro di oggi — Fmax del **sistema integrato con PSRAM** a P2 e P8 — è stata comunque fatta con successo sopra, tramite sintesi diretta (non lo script).

## Sottosistema FLASH — F1: SPI master + modello comportamentale (2026-09-04)

Avvio del piano a fasi richiesto dall'utente per dare alla FPGA accesso esclusivo alla
flash di boot/persistenza (Winbond W25Q128JV, SPI NOR 16MB). §A del prompt utente (standard
di verifica: oracolo indipendente, due piani — sim + sintesi reale, test avversari, tracciabilità)
è vincolante per ogni fase; questa entry documenta F1 secondo quello standard.

**Fonti usate (nessun numero a memoria, tutti citati)**:
- Datasheet locale `~/Development/HubAudio/datasheets/W25Q128JVS.pdf` — la prima pagina lo
  identifica come **"W25Q128JV-DTR"** (variante Double Transfer Rate), non il part number
  liscio "W25Q128JV" che `docs/FPGA-Neural-Hardware-Design.md` §6/§7 e
  `docs/FPGA-Neural-Datapatch-Benchmark.md` specificano come componente reale montato in
  BOM. **Discrepanza dichiarata esplicitamente** (non ignorata): il set di istruzioni SPI
  standard (§8.1.2 Tabella 1, p.26 — WREN 06h, READ 03h, PP 02h, SE 20h, RDSR-1 05h) e i
  tempi in §9.6 AC Electrical Characteristics (p.90) sono condivisi da tutta la famiglia
  W25Q128JV (DTR aggiunge solo istruzioni/modalità extra sopra, non cambia questi), quindi
  usabili senza riserve. Il **JEDEC ID** invece NON coincide: questo PDF (§8.1.1, p.24) dà
  `EF7018h` (memory type 70h, variante DTR); il part liscio W25Q128JV pubblicamente
  documentato è `EF4018h` (memory type 40h). `sim/flash_model.v` usa **EF4018h**, coerente
  col part realmente specificato nei documenti hardware del progetto, con la discrepanza
  commentata inline nel sorgente — **il bring-up su hardware reale deve confermare l'RDID
  effettivo del chip montato prima di fidarsi oltre di questa costante**.
- ECP5: Lattice `FPGA-DS-02012-3.4` "ECP5 and ECP5-5G Family Data Sheet" (locale,
  `~/Downloads/`), §2.18 "Device Configuration" (p.48): CCLK è uno degli **11 pin dedicati**
  (non un pin dual-function bank-8 "rilasciabile" come MOSI/MISO/CS_N, §2.14.1 p.42) — da qui
  la necessità della primitiva `USRMCLK` per pilotarlo da fabric dopo la configurazione. Il
  documento che descrive `USRMCLK` in dettaglio (Lattice "ECP5 and ECP5-5G sysCONFIG Usage
  Guide", FPGA-TN-02039, citato ripetutamente dal datasheet stesso) **non è presente nel set
  documentale locale** — limite dichiarato (§A.6): la polarità di `USRMCLKTS` (qui legata a
  0) segue la convenzione comune dei progetti open-source ECP5, non verificata contro il TN
  primario. Il port-list della primitiva stessa (`USRMCLKI`, `USRMCLKTS`) è invece confermato
  da una fonte indipendente e non indovinata: `/opt/homebrew/Cellar/yosys/*/share/yosys/ecp5/cells_bb.v`,
  `module USRMCLK(USRMCLKI, USRMCLKTS)` — la stessa blackbox che yosys/nextpnr-ecp5 usano
  davvero per il piazzamento.

**RTL creato**:
- `rtl/spi_flash_master.v` — master SPI generico verso la flash (mode 0, MSB-first),
  interfaccia a comando singolo (`opcode`/`has_addr`/`addr`/`dir`/`n_data`) con handshake
  byte-a-byte (`wdata_req`/`wdata_valid`, `rdata_valid`/`rdata_ack`) nello stesso stile
  req/ready già usato da `mem_arbiter.v`/`spi_slave.v`. `SCLK_DIV=2` di default a
  `CLK_FREQ_MHZ=80` → sclk=20MHz, scelto per stare sotto il limite **fR=50MHz** che il
  datasheet impone specificamente all'istruzione READ (03h) (§9.6 p.90 — le altre istruzioni
  permettono fino a 104-133MHz, ma un solo generatore di clock fisso deve rispettare il più
  stretto). Sotto `` `ifdef SIMULATION `` espone `sclk_sim` come porta normale (per
  `sim/flash_model.v`, che non può simulare la blackbox `USRMCLK`); altrimenti istanzia
  `USRMCLK` internamente, nessun vincolo LPF necessario (non è un pin I/O normale).
  **Bug trovato e corretto PRIMA della prima simulazione** (derivazione manuale bit-per-bit
  della logica di shift, non per tentativi): l'aggiornamento di MOSI sul fronte di discesa
  usava un indice `bit_idx+1` invece di `bit_idx`, saltando un bit e disallineando l'intero
  byte — corretto in entrambi i punti (header opcode+addr, byte dati) prima di compilare.
- `sim/flash_model.v` (SOLO simulazione) — modella le regole del datasheet: erase→0xFF
  (§8.2.18 p.56), program **solo AND** mai OR (§8.2.16/Tabella1 p.29/53), WIP/BUSY =
  RDSR-1 bit0, WEL = bit1 (ordine da §7.1.1/7.1.2 p.15 + convenzione universale Winbond,
  non c'è un'unica tabella-bit consolidata in questo PDF — dichiarato). Timing tPP/tSE usa i
  valori **MAX** (peggiore caso, non tipico) del datasheet, scalati da `TIME_SCALE` per non
  bruciare tempo reale di simulazione — scelta deliberata: un design che funziona solo col
  caso tipico non è corretto. `DEPTH` ridotto (128KB, non i 16MB reali) per velocità di
  simulazione, stesso precedente già stabilito da `sim/psram_model.v`. Limiti dichiarati nel
  header: nessuna istruzione Fast/Dual/Quad/QPI/DTR, nessuna gestione dei bit di protezione
  (fuori scope: la flash è esclusiva della FPGA), nessun timing analogico, e il power-loss
  simulato può rappresentare solo "operazione mai committata" non "committata a metà" (limite
  del modello, non del design).
- `sim/spi_flash_master_tb.v` — 5 test:
  - **TEST1 (RDID)**: oracolo = valore del datasheet scritto indipendentemente nel testbench
    (non letto dalla costante di `flash_model.v`) → **PASS** (EF/40/18h).
  - **TEST2 (READ, oracolo indipendente vero)**: pattern piantato per riferimento
    gerarchico DIRETTAMENTE nell'array `mem[]` di `flash_model` (mai passato attraverso
    l'RTL sotto test), poi letto via `spi_flash_master` e confrontato byte-esatto → **PASS**,
    16/16 byte.
  - **TEST3/3b (WREN+PP+poll RDSR+READ round-trip, AND-only)**: TEST3 programma un pattern
    su una regione erasa e lo rilegge (round-trip, non indipendente dall'RTL — dichiarato
    esplicitamente come tale nel commento del tb); TEST3b riprogramma la STESSA regione con
    `0xFF` e verifica che il valore letto **non cambi** (la regola AND-only non è
    distinguibile da un "program sovrascrive" ingenuo col solo TEST3) → **PASS** entrambi.
  - **TEST4 (WREN+SE+poll RDSR+READ)**: la regione lasciata deliberatamente non-FF da
    TEST3/3b viene cancellata e riletta, tutta a `0xFF` → **PASS** (non può passare per
    coincidenza, la regione non era già bianca).
  - **TEST5 (avversario §A.3, opcode illegale)**: emesso `0xAB` (istruzione reale W25Q128JV
    ma non implementata né dal master né dal modello) — requisito: `done` deve comunque
    arrivare entro il watchdog del testbench (il master shifta un numero fisso di bit
    indipendentemente dalla semantica dell'opcode) → **PASS**, nessun hang.
  - Compilato: `iverilog -g2012 -DSIMULATION -o <tmp> rtl/spi_flash_master.v sim/flash_model.v sim/spi_flash_master_tb.v`.
    Nessun errore/warning. Eseguito (`vvp`): **ALL TESTS PASSED**.
- **Sintesi reale** (secondo piano indipendente, §A.2): `yosys synth_ecp5` pulito (0
  problemi da CHECK, 1 cella `USRMCLK` come atteso) + **`nextpnr-ecp5` reale** (binario
  trovato in `/private/tmp/nextpnr/build/nextpnr-ecp5`, versione 0.11.1-19-g8dbcee5c — NON
  installato via Homebrew su questa macchina, percorso assoluto necessario finché non viene
  reinstallato in un posto stabile) sul modulo isolato (`--45k --package CABGA381 --speed 8
  --freq 80 --lpf-allow-unconstrained`): **Program finished normally**, Fmax **181.72 MHz**
  (PASS a 80MHz — numero di solo modulo, non riflette il collo di bottiglia noto di
  `neuron_parallel.v` che dominerà il sistema integrato, da rimisurare in F6), `USRMCLK 1/1
  100%` piazzata correttamente, `TRELLIS_IO 79/245 32%` (porte non ancora integrate in un top
  reale — atteso a questo stadio).

**Cosa NON è coperto da F1 (dichiarato, §A.6)**: nessun test di power-loss vero (arriva in
F4 col catalogo/CRC), nessun timeout RDSR (il master non ne impone uno — responsabilità del
copy engine in F3), nessuna integrazione in `spi_neuron_top`/`mem_arbiter` (F5), nessuna
verifica elettrica/analogica reale (rise/fall, setup/hold) — solo comportamentale.

**Prossimo passo**: F2, copy engine flash→PSRAM (load) sopra questo master, integrato come
nuovo master a bassa priorità su `mem_arbiter`.

## Sottosistema FLASH — F2: copy engine flash→PSRAM (load) + DUE BUG REALI trovati e corretti (2026-09-04)

Costruito `rtl/flash_copy_engine.v` sopra il master F1: comando singolo (`op_start`,
`flash_addr`, `psram_addr`, `len`), streaming byte-a-byte flash→PSRAM tramite un nuovo
**Port D a priorità più bassa** su `mem_arbiter.v` (priorità finale: B>C>A>D, come richiesto
dal piano — le operazioni flash sono ms-scale e non devono mai competere con l'inferenza).
`spi_flash_master` è istanziato INTERNAMENTE (il copy engine possiede il bus fisico verso la
flash); verso l'alto espone solo il comando + le porte fisiche flash + Port D.

Il READ (03h) non ha vincoli di pagina (solo PP/SE li hanno, §8 intro p.24 del datasheet),
quindi F2 non ha bisogno del loop erase+page-program — quello arriva in F3 per la direzione
PSRAM→flash. `len` è però a 24 bit (come da bozza opcode §5) mentre `n_data` del master F1 è
a 16 bit: il copy engine spezza automaticamente in chunk da max 65535 byte, chiudendo un
potenziale bug latente prima ancora di scriverne il test.

**Bounds checking (§A.3, "len fuori range")**: `flash_addr+len` oltre i 16MB modellati o
`psram_addr+len` oltre 8MB → `err` + `done` immediato, NESSUNA transazione flash o PSRAM
tentata. `len==0` è anch'esso un errore esplicito (non un no-op silenzioso — un host che
manda una lunghezza sbagliata deve vederlo, non essere coperto).

### I due bug (nessuno dei due nel design del giorno prima — trovati DURANTE il bring-up di F2)

Il test F2 (TEST1, round-trip byte-esatto con dato piantato indipendentemente in
`flash_model.mem[]`) falliva alla primissima esecuzione: lettura 0x00 invece di 0x50. Invece
di aggiustare il test per farlo passare (vietato da §A.1), ho isolato la causa con tracce
mirate fino al segnale, non fermandomi al primo sospetto plausibile:

**BUG #1 — `rtl/psram_controller.v`, PRE-ESISTENTE, non del subsystem flash.** Riprodotto con
un testbench minimale che usa SOLO la Porta A esistente (`/tmp/portA_repro_tb.v`, nessun
codice flash coinvolto) — confermato non essere un problema mio. Meccanismo:
1. `STATE_INIT` (power-up, 150µs @ 80MHz) non controlla affatto `mem_req`: una richiesta
   esterna che arriva in questa finestra è persa per sempre (`mem_req` è un impulso di un
   solo ciclo da `int8_memory_access.v`, senza retry).
2. `STATE_CR_INIT` (sequenza software-access del datasheet PSRAM, 2 read + 2 write interne)
   riusa gli stessi stati `STATE_READ`/`STATE_WRITE` del percorso ESTERNO, e la loro
   condizione di completamento pulsava `mem_ready` **incondizionatamente** — nessuna guardia
   per distinguere "questo è un passo interno di CR_INIT" da "questa è la transazione reale
   del chiamante". Un chiamante in attesa durante quella finestra vedeva uno di quegli
   impulsi spuri, credeva che la SUA richiesta (mai davvero eseguita) fosse completata, e
   proseguiva con dati sbagliati/mai scritti.
   Nel caso di F2 (accesso quasi immediato dopo reset, ben dentro la finestra vulnerabile —
   a differenza dei test esistenti che iniziano il primo accesso reale più tardi, incidentalmente
   fuori dalla finestra), l'effetto era esattamente questo: `wb(0x100, 0x50)` sembrava
   riuscire (handshake completato) ma la scrittura reale non avveniva mai.
   **Corretto** con: (a) un latch "early request" (`req_pending` + registri ombra) che cattura
   una richiesta arrivata durante `STATE_INIT`/`STATE_CR_INIT` invece di perderla, consumata
   non appena `STATE_IDLE` viene raggiunto per davvero; (b) `mem_ready <= 1'b1` ora guardato
   con `if (!cr_init_active)` in ENTRAMBI i punti di completamento (`STATE_READ` e
   `STATE_WRITE_WAIT`), così i passi interni di CR_INIT non trapelano mai verso l'esterno.
   **Rischio reale, non accademico**: lo scenario "boot standalone" del piano (§6 del prompt
   di fase) è ESATTAMENTE un caricamento da flash a PSRAM molto presto dopo il power-on — il
   caso che questo bug avrebbe colpito su silicio vero.

Verificato con lo stesso repro minimale (Port A pura, nessun codice flash coinvolto): scrittura
   singola e doppia scrittura adiacente (stesso word PSRAM, byte basso poi alto) ora byte-
   esatte. Rieseguita l'INTERA regressione esistente (elencata sotto): tutti i numeri
   (banda gather, cicli, Fmax) restano IDENTICI a prima del fix — conferma che il bug
   colpiva solo la finestra di avvio, non il comportamento a regime già misurato.

**BUG #2 — `rtl/flash_copy_engine.v`, nel MIO nuovo codice, introdotto mentre correggevo il
Bug #1 e poi ricontrollato con lo stesso rigore.** La richiesta Port D (`d_req`) era
originariamente un impulso di un solo ciclo (stesso stile degli altri master). Ma
`mem_arbiter` campiona `req` di un richiedente SOLO mentre `owner==SEL_NONE` — se l'impulso
di un solo ciclo cade esattamente sullo stesso ciclo in cui la Porta A (priorità più alta)
richiede anch'essa, l'arbitro concede alla Porta A e l'impulso di Port D è perso per sempre
(deadlock: il motore resta in attesa di un `d_ready` che non arriverà mai). Riprodotto
esplicitamente con TEST5 (contesa attiva di Port A durante un LOAD).
**Corretto** rendendo `d_req` un segnale di LIVELLO (`assign d_req = (state==ST_PSRAM_WAIT) &&
!d_ready`), tenuto alto finché non viene davvero servito — non serve toccare
`mem_arbiter.v` (che serve gli altri tre master già validati). **Sotto-bug scoperto nel fix
stesso**: la prima versione (`d_req = state==ST_PSRAM_WAIT`, senza `&& !d_ready`) lasciava
`d_req` combinazionalmente alto per un ciclo in più esatto in cui l'arbitro tornava a
`SEL_NONE` dopo il completamento — causando una RI-concessione spuria con indirizzo/dato
ormai stantii. Trovato ripetendo la stessa tecnica di tracciamento ciclo-per-ciclo usata per
il Bug #1, non per tentativi.

### Verifica F2 (secondo §A)

- `sim/flash_copy_engine_load_tb.v`, 5 test — **ALL TESTS PASSED**:
  - TEST1: LOAD byte-esatto, dato piantato indipendentemente in `flash_model.mem[]` (oracolo
    indipendente vero, non passato per l'RTL sotto test).
  - TEST2: due LOAD separati back-to-back (rientranza IDLE-dopo-DONE).
  - TEST3 (avversario §A.3): `flash_addr+len` oltre 16MB → `err`, sentinella PSRAM
    intatta, nessuna transazione flash tentata.
  - TEST4 (avversario §A.3): `len==0` → `err` esplicito, non un no-op silenzioso.
  - TEST5: contesa reale con un "nibbler" Port A in background durante un intero LOAD da 64
    byte — Port A vince sempre l'arbitraggio (priorità), il LOAD comunque completa
    byte-esatto (dimostra "Port D allungato, mai perso", l'intento di design dichiarato in
    `mem_arbiter.v`).
- **Regressione completa** ripetuta dopo ENTRAMBI i fix (non solo alla fine): tutti i
  testbench che toccano `psram_controller.v`/`mem_arbiter.v` (`psram_controller_tb`,
  `psram_page_mode_tb`, `int8_psram_integration_tb`, `neuron_memory_tb`,
  `neuron_memory_multi_tb`, `spi_neuron_top_tb`, `spi_neuron_top_graph_tb`,
  `spi_neuron_top_runnetwork_tb`, `spi_neuron_top_irq_tb`, `graph_engine_tb`,
  `graph_engine_guard_tb`, `graph_engine_bandwidth_tb`, `graph_format_tb`) più i test guardia
  negativi (`neuron_parallel_guard_negative_*`, ancora falliscono in elaborazione **come
  previsto**) — **tutti PASS**, nessuna regressione, numeri di banda/ciclo identici a prima
  (37.53 cicli/edge, 8.53MB/s@80MHz, 1.71MB/s@16MHz — invariati, confermando che il fix non
  tocca il comportamento a regime). I testbench che non toccano né `psram_controller.v` né
  `mem_arbiter.v` (verificato via `grep`) sono stati lasciati fuori da questa ri-esecuzione
  mirata perché il fix non può averli toccati.
- **Sintesi reale** (yosys `synth_ecp5` + `nextpnr-ecp5` reale, `--lpf-allow-unconstrained`,
  a livello di modulo isolato):
  - `psram_controller.v` (con fix): 0 problemi CHECK, Fmax **244.74 MHz** (PASS a 80MHz).
  - `flash_copy_engine.v`: 0 problemi CHECK, `USRMCLK 1/1 100%`, Fmax **172.98 MHz** (PASS a
    80MHz) — numeri di solo modulo, l'integrazione reale nel sistema arriva in F5/F6.

**Cosa NON è coperto da F2 (dichiarato, §A.6)**: nessun blocco >65535 byte testato a piena
dimensione (chunking implementato e ragionato ma non esercitato oltre un singolo chunk, per
tempo di simulazione — dichiarato come gap di copertura, non nascosto); nessuna direzione
SAVE (arriva in F3); nessuna integrazione col catalogo (F4) né con gli opcode SPI (F5).

**Lezione per le fasi successive**: il Bug #1 dimostra che "il codice esistente è già
validato" non è una garanzia assoluta quando cambia il PATTERN di accesso (qui: accesso
molto presto dopo reset, mai esercitato prima). F3 (SAVE, con erase+program+poll WIP) e F4
(catalogo, letto al boot) andranno verificati con la STESSA attenzione alla tempistica di
avvio, non solo alla logica a regime.

**Prossimo passo**: F3, direzione PSRAM→flash (erase settore + loop page-program ≤256B +
poll WIP), estendendo lo stesso `flash_copy_engine.v`.

## Sottosistema FLASH — F3: copy engine PSRAM→flash (save), erase+program+poll WIP (2026-09-04)

Estesa `rtl/flash_copy_engine.v` (stesso file di F2, path LOAD invariato — nessuna riga del
percorso F2 toccata) con la direzione `DIR_SAVE`: erase settore + loop Page Program ≤256B +
poll RDSR-1 (WIP), tutto orchestrato dalla FPGA come richiesto dal piano (§2.2 — "Il loop lo
fa la FPGA: è il valore rispetto a 'host un registro alla volta'").

**Decisione di design dichiarata (§2.1 del piano chiede esplicitamente di sceglierne una e
motivarla)**: `flash_addr` per una SAVE **deve** essere allineato a settore (4KB, bit bassi
a zero) — rifiutato come errore altrimenti, invece di un read-modify-erase-write del settore
parziale. Motivo: il progetto non ha un buffer di scratch abbastanza grande da tenere un
intero settore da 4KB di dati circostanti non correlati mentre lo si cancella/riprogramma, e
il design del sottosistema flash stesso (slot di catalogo a dimensione fissa, §4 del piano)
implica che ogni vera `SAVE_SLOT` (F5) scriverà già slot interi e allineati a settore — quindi
l'allineamento non è una restrizione reale, solo un caso patologico respinto esplicitamente.

**Struttura della macchina a stati (interamente additiva rispetto a F2)**:
- Fase erase: per ogni settore da 4KB che si sovrappone a `[flash_addr, flash_addr+len)` →
  WREN + SE + poll RDSR-1 fino a WIP libero, prima di iniziare qualunque programmazione. Una
  `len` non multipla di 4096 cancella comunque l'INTERO ultimo settore parziale (l'erase non
  ha granularità più fine, Tabella 1 p.26) — la coda non scritta resta a 0xFF, corretto per
  design (il flag valido+CRC del catalogo, F4, marcherà la lunghezza significativa, non "tutto
  il settore è significativo").
- Fase program: loop di Page Program (02h) da max 256B ciascuno, ognuno con il proprio WREN e
  poll RDSR-1 fino a completamento prima del successivo (mai un'unica PP che attraversi una
  pagina — garantito dall'allineamento a settore/pagina di `flash_addr` più il tetto di 256B
  per chunk). I byte di ogni pagina sono letti UNO ALLA VOLTA dalla PSRAM (Port D) e passati
  direttamente all'handshake `wdata_req`/`wdata_valid` di `spi_flash_master` (F1) — nessun
  buffer locale, stesso stile "streaming" del percorso LOAD.
- Poll RDSR-1 (WIP) condiviso tra erase e program (stessi 3 stati, un registro `save_phase`
  decide cosa fare quando WIP si libera) — **nessun timeout sul numero di poll**: dichiarato
  esplicitamente nel modulo e qui, perché il datasheet non impone un limite superiore reale
  oltre tSE/tPP MAX, e un timeout applicato qui (piuttosto che a livello host/STATUS, F5)
  rischierebbe di abortire un'operazione ancora legittimamente in corso su silicio più lento
  del previsto — TEST 5 sotto dimostra che il poll NON si arrende mai da solo.
- `d_req` verso l'arbitro: la stessa lezione di F2 (segnale di livello, non impulso) si
  applica anche alla nuova lettura PSRAM sorgente della fase program — l'espressione
  `assign d_req` è stata estesa per coprire anche questo nuovo stato di attesa, stessa
  motivazione, nessuna sorpresa in più.

### Verifica F3 (secondo §A)

`sim/flash_copy_engine_save_tb.v`, 5 test — **ALL TESTS PASSED** (primo tentativo pulito,
grazie alle lezioni di tempistica/arbitraggio già imparate in F2):
- **TEST1/1b**: round-trip byte-esatto (SAVE poi LOAD, riusando il percorso F2 già verificato
  come metà dell'oracolo) **più** un oracolo indipendente vero (TEST1b: lettura diretta di
  `flash_model.mem[]` via riferimento gerarchico, mai passata per l'RTL sotto test) — 40 byte,
  entrambi PASS.
- **TEST2 (avversario §A.3, attraversamento pagina)**: SAVE di 300 byte (attraversa il
  confine 256B dentro lo stesso settore) — verificato byte-esatto su tutti i 300 byte,
  dimostrando che il loop interno emette WREN+PP+poll separati per ciascuna pagina invece di
  un singolo PP che tronchi/corrompa al confine.
- **TEST3 (avversario §A.3, blocco non allineato al settore)**: `flash_addr=0x5100` (non
  multiplo di 0x1000) → `err`, nessun SE tentato (confermato indirettamente: il guardiano
  `$fatal` di `flash_model.v` su un SE non allineato non scatta mai).
- **TEST4 (avversario §A.3, verifica erase reale)**: settore avvelenato con `0x55` (non
  0xFF), SAVE di soli 20 byte, poi verificato che il PREFISSO programmato sia esatto E che
  la CODA non scritta del settore (byte 20..4095) sia tutta 0xFF — prova che è avvenuto un
  vero erase, non solo un program in-place sopra il vecchio contenuto avvelenato (che
  avrebbe lasciato la coda com'era).
- **TEST5 (avversario §A.3, WIP prolungato)**: MISO forzato a riportare BUSY per una finestra
  di 300µs (simulata) durante il primo poll dopo l'erase, poi rilasciato — il motore continua
  a fare polling (nessun timeout, nessun abbandono) e completa correttamente non appena BUSY
  si libera davvero. Nessun bit/byte corrotto nel resto del comando durante la finestra
  forzata (verificato: MISO forzato non altera MOSI né le fasi non-lettura di WREN/SE/PP, che
  non campionano MISO affatto).
- **Regressione**: F1 + F2 rieseguiti insieme a F3 (**tutti ALL TESTS PASSED**), più
  `spi_neuron_top_tb`, `spi_neuron_top_graph_tb`, `graph_engine_bandwidth_tb`,
  `psram_controller_tb` (nessuna riga toccata da F3 in questi percorsi, ri-verificati per
  completezza) — numeri invariati, nessuna regressione.
- **Sintesi reale**: `yosys synth_ecp5` pulito (0 problemi CHECK) + `nextpnr-ecp5` reale
  (`--lpf-allow-unconstrained`, modulo isolato): **Program finished normally**, Fmax
  **158.28–158.55 MHz** (PASS a 80MHz, numero di solo modulo), `USRMCLK 1/1 100%`. Risorse
  cresciute rispetto a F2 (306→582 LUT4, 259→407 TRELLIS_FF, 80→143 CCU2C) — atteso, la FSM è
  quasi raddoppiata in stati per la logica erase/program/poll.

**Cosa NON è coperto da F3 (dichiarato, §A.6)**: nessun test di power-loss vero a metà
erase/program (arriva in F4, dove il meccanismo valido_flag+CRC del catalogo lo rende
osservabile) — qui il timing del modello resta quello dichiarato nel header di
`sim/flash_model.v` (commit tutto-o-niente, non parziale, limite di fedeltà già dichiarato in
F1); nessuna integrazione col catalogo (F4) né con gli opcode SPI (F5); nessuna verifica che
due SAVE consecutive su settori ADIACENTI non si disturbino a vicenda (non richiesto dal
piano per F3, ma da tenere presente quando il catalogo scriverà slot vicini in F4).

**Prossimo passo**: F4, catalogo a slot fissi + CRC (calcolata anche in Python come oracolo
indipendente, §A.1) — read/write del catalogo, `LOAD_SLOT`/`SAVE_SLOT`, test di slot con CRC
corrotta e power-loss simulato.

## Sottosistema FLASH — F4: catalogo a slot fissi + CRC32 (2026-09-04)

**Layout del catalogo** (documentato anche in `tools/flash_catalog/oracle.py`, la fonte di
verità per la codifica byte — l'RTL e lo script sono tenuti sincronizzati a mano, verificati
confrontando i byte reali prodotti dall'hardware, non fidandosi della prosa dell'uno o
dell'altro): 16 slot × 16 byte = 256 byte, dentro il settore 0 (riservato, mai usato per dati
di slot). Ogni voce: `offset[24b] | length[24b] | type[8b] | valid[8b] (0x01=valido) |
crc32[32b] | riservato[32b]`. Un settore appena cancellato è tutto 0xFF, quindi ogni slot non
scritto decodifica automaticamente come non valido (0xFF≠0x01) — nessun passo di formattazione
necessario, coerente col comportamento reale di erase Winbond già citato in F1.

**Oracolo indipendente (§A.1)**: `tools/flash_catalog/oracle.py`, CRC32 = `zlib.crc32` di
Python (libreria standard, implementazione completamente separata da `rtl/crc32.v`, non
derivata dalla stessa comprensione di design). `rtl/crc32.v` implementa il classico CRC32
riflesso (polinomio 0xEDB88320, IEEE 802.3/zlib) — verificato con `sim/crc32_tb.v` contro
**tre fonti indipendenti**: (1) l'identità matematica del messaggio vuoto (init XOR final =
0), (2) il valore di controllo testuale standard "123456789" → `0xCBF43926` (pubblicato in
ogni tabella di riferimento CRC32, non calcolato da nessuno dei due lati), (3) l'output dello
script Python per un payload di 32 byte. **Tutti e tre PASS**, incluso al primo tentativo
(algoritmo da manuale, rischio di errore basso ma comunque verificato, non assunto).

**Architettura** (`rtl/flash_slot_manager.v`, nuovo modulo sopra `flash_copy_engine.v` di
F2/F3, riusato **senza modifiche** — zero rischio di regressione sui percorsi LOAD/SAVE già
verificati):
- Il catalogo viene "messo in scena" in una piccola regione PSRAM riservata
  (`CATALOG_PSRAM_ADDR`) usando `flash_copy_engine` COSÌ COM'È (nessuna terza direzione
  aggiunta): `CAT_READ` = un `DIR_LOAD` del settore 0 nella regione di staging, poi lettura
  byte-a-byte in registri on-chip; la persistenza di una voce aggiornata = serializzazione
  byte-a-byte nella regione di staging, poi un `DIR_SAVE` del settore 0 (riusa l'intero
  erase+loop-page-program+poll-WIP di F3, invariato).
- La Port D verso l'arbitro PSRAM è condivisa tra l'uso interno di `flash_copy_engine` e
  l'uso diretto di `flash_slot_manager` per la propria regione di staging, tramite un mux
  statico su `fce_busy` — sicuro perché i due usi sono temporalmente disgiunti per
  costruzione (nessuna nuova porta sull'arbitro necessaria).
- Il CRC32 viene calcolato **osservando** (tap) il traffico Port D che `flash_copy_engine`
  già genera durante un `LOAD_SLOT`/`SAVE_SLOT` (il byte scritto in PSRAM per un LOAD, il
  byte letto da PSRAM per un SAVE) — di nuovo zero modifiche a `flash_copy_engine.v`.
- **Bug trovato e corretto PRIMA della prima simulazione** (revisione attenta del codice
  appena scritto, non per tentativi): la condizione di aggiornamento del CRC controllava
  `fce_d_req && d_ready`, ma `d_req` di `flash_copy_engine` è definito (in F2) come
  `(stato_attesa) && !d_ready` — quindi quella condizione era una contraddizione, sempre
  falsa, il CRC non si sarebbe MAI aggiornato. Corretta in `fce_busy && d_ready` (lo stesso
  ragionamento di tempistica "un ciclo di ritardo" già documentato in `flash_copy_engine.v`).
  Anche il decode di una voce di catalogo dalla CAT_READ era incompleto nella prima stesura
  (solo l'offset, mancavano length/type/valid/crc) — completato prima di compilare.

**Semantica `CAT_WRITE_SLOT`/`SAVE_SLOT`/`LOAD_SLOT`** (nessun campo CRC nell'opcode
`CAT_WRITE_SLOT` per bozza §5 del piano → decisione di design): `CAT_WRITE_SLOT` registra
offset/length/type ma marca lo slot **non valido** (nessun dato verificato ancora dietro);
`SAVE_SLOT` (che non riceve un offset, solo `slot_id`+`psram_addr`+`length`) risolve
l'offset già registrato dal catalogo, scrive i dati, calcola il CRC dal vero stream, e SOLO
al termine marca lo slot valido + persiste; `LOAD_SLOT` (che non riceve una length, solo
`slot_id`+`psram_addr`) rifiuta immediatamente (nessuna transazione flash/PSRAM tentata) se
lo slot non è valido, altrimenti carica e verifica il CRC dal vero stream contro quello
salvato — se non combacia, segnala errore (i dati restano comunque in PSRAM, stesso stile
"flag di errore non rollback transazionale" già usato altrove nel progetto, es. STATUS.bit2).

### Verifica F4 (secondo §A)

`sim/flash_slot_manager_tb.v`, 6 test — **ALL TESTS PASSED** (primo tentativo pulito dopo i
due bug corretti in revisione):
- **TEST1**: `CAT_WRITE_SLOT` + persistenza + `CAT_READ` round-trip — i byte REALI persistiti
  in `flash_model.mem[]` confrontati byte-a-byte con `oracle.py.pack_entry(...)` (oracolo
  indipendente, non il decode dell'RTL stesso); poi una `CAT_READ` fresca (simula un reboot)
  ricostruisce la stessa voce on-chip.
- **TEST2/3**: `SAVE_SLOT` con pattern noto — voce di catalogo persistita (CRC incluso)
  confrontata byte-a-byte con l'oracolo Python; `LOAD_SLOT` byte-esatto con CRC accettato.
- **TEST4 (avversario §A.3, CRC corrotto → invalido)**: un bit del dato flash dello slot
  salvato viene capovolto direttamente (`flash_model.mem[]`, indipendente dall'RTL sotto
  test) → `LOAD_SLOT` successivo segnala errore.
- **TEST5 (avversario §A.3, slot mai salvato → invalido)**: `CAT_WRITE_SLOT` senza mai una
  `SAVE_SLOT` → `LOAD_SLOT` rifiuta immediatamente, sentinella PSRAM intatta (nessuna
  transazione tentata).
- **TEST6 (avversario §A.3, power-loss simulato)**: il Sector Erase di una `SAVE_SLOT` viene
  abortito a metà usando l'hook di power-loss già documentato in `sim/flash_model.v`
  (`pending_se`+`busy` forzati bassi via riferimento gerarchico), con il settore target
  pre-avvelenato con un pattern DIVERSO da quello atteso. Il poll WIP di `flash_copy_engine`,
  ingannato dal `busy` forzato, fa apparentemente "completare con successo" l'intera
  `SAVE_SLOT` (nessun `err` sulla SAVE stessa — corretto, dal punto di vista del motore
  l'operazione È completata secondo RDSR) — ma il CRC persistito è quello dei dati
  INTENZIONATI, che non combacia più con i byte REALI (avvelenati, mai davvero cancellati).
  Una `LOAD_SLOT` successiva rileva correttamente l'incoerenza → errore. Dimostra esattamente
  il meccanismo per cui "regione invalida rilevata" funziona anche quando un'operazione
  sottostante non ha fatto silenziosamente quel che dichiarava: il CRC verifica i byte
  realmente committed, non si fida di un segnale di completamento.
- **Regressione**: `crc32_tb.v` + F1 + F2 + F3 rieseguiti insieme a F4 (**tutti ALL TESTS
  PASSED**), più `spi_neuron_top_tb`/`psram_controller_tb` (nessuna riga toccata da F4 in
  questi percorsi) — nessuna regressione.
- **Sintesi reale**: `yosys synth_ecp5` pulito (0 problemi CHECK) per `flash_slot_manager.v`
  completo. **`nextpnr-ecp5` reale a livello di modulo isolato NON eseguibile per questo
  modulo specifico** — dichiarato onestamente, non nascosto: la lista di porte a livello di
  modulo (253 bit — ogni campo del comando/ispezione catalogo diventa un "pin" quando il
  modulo è trattato come top fittizio) supera i 245 pin TRELLIS_IO fisici del package,
  `nextpnr-ecp5` fallisce con "no BELs remaining to implement TRELLIS_IO" — artefatto del
  testare un modulo INTERNO come se fosse il top reale (F1/F2/F3 erano abbastanza piccoli da
  non avere questo limite), non un problema del design. La verifica reale di piazzamento
  arriva in F5, quando il modulo è integrato in `spi_neuron_top` e la maggior parte di queste
  porte diventa segnale interno, non pin fisico.

**Cosa NON è coperto da F4 (dichiarato, §A.6)**: nessun test di due slot che si sovrappongano
in flash (l'host è responsabile di offset/length coerenti via `CAT_WRITE_SLOT`, come da
modello "nessun filesystem" del piano); `CATALOG_PSRAM_ADDR` è una convenzione non applicata
altrove — nulla impedisce ad un altro master di scrivere quella regione PSRAM durante
un'operazione di catalogo (dichiarato, non un problema nello scope attuale poiché nessun
altro master è integrato prima di F5); nessuna integrazione con gli opcode SPI (F5) —
`flash_slot_manager` è verificato come modulo standalone col proprio testbench diretto, non
ancora pilotato da `spi_engine`.

**Prossimo passo**: F5, opcode SPI (§5 del piano) + integrazione in `spi_neuron_top` —
`FLASH_READ_BLOCK`/`FLASH_WRITE_BLOCK`/`FLASH_ERASE`/`CAT_READ`/`CAT_WRITE_SLOT`/
`LOAD_SLOT`/`SAVE_SLOT`, `data_ready_n` a fine operazione, test end-to-end
`netasm → SAVE_SLOT → LOAD_SLOT → RUN_NETWORK`; anche la vera sintesi/place&route a livello
di sistema (Fmax, occupazione) per `flash_slot_manager.v` arriva qui.

## Sottosistema FLASH — F5: opcode SPI + integrazione in spi_neuron_top (2026-09-04)

Ultima fase di integrazione: gli 8 opcode SPI (7 dal piano §5 + 1 aggiunto, motivato sotto),
`rtl/spi_engine.v` esteso per decodificarli, `rtl/spi_neuron_top.v` esteso per istanziare
`flash_slot_manager.v` e portare i pin fisici della flash (`flash_mosi`/`flash_miso`/
`flash_cs_n`, distinti dai pin SPI host esistenti — stesso principio di
`docs/FPGA-Neural-Hardware-Design.md` §6: mai condividere i pin della config-flash), pinout
reale aggiornato.

**Opcode aggiunti** (`rtl/spi_engine.v`, range 0x40-0x47):
```
0x40 FLASH_READ_BLOCK   flash_addr(3) psram_addr(3) len(3)
0x41 FLASH_WRITE_BLOCK  psram_addr(3) flash_addr(3) len(3)
0x42 FLASH_ERASE        sector_addr(3)
0x43 CAT_READ           (nessun payload — ricarica il catalogo on-chip da flash)
0x44 CAT_WRITE_SLOT     slot_id(1) offset(3) length(3) type(1)
0x45 LOAD_SLOT          slot_id(1) psram_addr(3)
0x46 SAVE_SLOT          slot_id(1) psram_addr(3) length(3)
0x47 CAT_INSPECT        slot_id(1) → risposta sincrona 16 byte (voce di catalogo)
```
`CAT_INSPECT` **non è nella bozza originale del piano** — aggiunto e motivato esplicitamente
(commento nel sorgente): `CAT_READ` non porta byte di risposta nella bozza (coerente col
resto del protocollo, "fire-and-forget poi polla STATUS/data_ready_n", mai "tieni CS basso
per millisecondi"), quindi serviva un meccanismo SEPARATO per il "-> host" che il piano
stesso menziona — `CAT_INSPECT` è quel meccanismo, nello stesso stile sincrono già usato da
STATUS/READ_OUTPUT/READ_CONFIG.

**Decodifica del payload**: un unico accumulatore a scorrimento condiviso da tutti gli
opcode flash (stesso pattern "shift ogni byte, decodifica sull'ultimo con slice a bit fissi"
già usato per il decode delle voci di catalogo in `flash_slot_manager.v`), non uno stato
dedicato per opcode — payload da 0 a 9 byte a seconda dell'opcode.
**Bug trovato e corretto PRIMA di compilare** (derivazione a mano bit-per-bit, stesso
metodo già validato in F1): l'estrazione di `slot_id` per `CAT_WRITE_SLOT` prendeva il
nibble ALTO del suo byte invece del nibble BASSO (convenzione usata coerentemente da
`LOAD_SLOT`/`SAVE_SLOT`/`CAT_INSPECT`) — corretto confrontando ogni singolo campo con una
derivazione indipendente dei bit del registro di accumulo, non solo quello sbagliato.

**Bug trovato e corretto DALLA REGRESSIONE, non dalla progettazione** (la ragione per cui la
regressione va sempre rieseguita, non solo assunta): `done_event` in `spi_engine.v` era
un multiplexer a priorità (`graph_mode ? graph_done : (net_mode ? seq_done : nm_done)`) che
NON sceglie semplicemente "una fonte tra varie mutuamente esclusive" — MASCHERA
deliberatamente gli `nm_done` intermedi (uno per layer) durante una `RUN_NETWORK` multi-layer,
altrimenti STATUS.bit1 si alzerebbe troppo presto. La prima versione del supporto flash
sostituiva questo con un semplice OR di tutte e quattro le sorgenti (`nm_done|seq_done|
graph_done|flash_done`) — sbagliato: **`sim/spi_engine_tb.v` (test esistente, invariato)
ha fallito immediatamente** ("done bit set by an intermediate nm_done during RUN_NETWORK").
Corretto separando: la maschera esistente resta `inference_done_event` **invariata**, e
`flash_done` viene aggiunto in OR **fuori** da quella maschera (i due domini sono ora
genuinamente indipendenti — le operazioni flash sull'arbitro a bassa priorità possono
sovrapporsi a un'inferenza per design, F2). Rieseguito subito dopo: PASS pulito.

**STATUS byte esteso** (bit3=`flash_err_sticky`, sticky-fino-a-lettura come `status_done_sticky`
— scelta motivata nel sorgente: `graph_err` NON viene riusato perché confonderebbe due domini
di errore non correlati; bit4=`flash_busy`, livello non sticky) — `resp_index`/`resp_len`
allargati da 4 a 5 bit per accomodare la risposta a 16 byte di `CAT_INSPECT` (le esigenze
degli opcode esistenti, tutte ≤11 byte, restano immutate).

**Bug (gap) trovato in revisione e corretto in `flash_slot_manager.v` durante F5, non un
bug di F5 stesso**: `ST_SLOT_FCE_WAIT` per `SAVE_SLOT` aggiornava e persisteva il catalogo
come "valido" incondizionatamente al completamento di `flash_copy_engine`, **senza mai
controllare `fce_err`** — una `SAVE_SLOT` il cui `flash_copy_engine` sottostante fosse stato
rifiutato internamente (es. lunghezza fuori range) sarebbe stata comunque marcata valida nel
catalogo. Trovato rileggendo il codice mentre si aggiungevano gli opcode raw (che DOVEVANO
propagare `fce_err`, il che ha fatto notare l'assenza dello stesso controllo nel ramo
`SAVE_SLOT` già esistente). Corretto: `SAVE_SLOT` ora salta l'aggiornamento/persistenza del
catalogo se `fce_err` è alto.

### Una scoperta reale, non specifica alla flash (§A.5 — tracciabilità di un rischio)

Durante il debug del test end-to-end (sotto) è emerso un problema REALE e generale, non un
bug di questa sessione: **`WRITE_RAM`/`READ_RAM` non hanno alcun backpressure verso il master
SPI** — limite già dichiarato nell'header di `spi_engine.v` ("v1 LIMITATION... reasonable
constraint... not a real-time path") ma la cui conseguenza pratica non era mai stata esposta
prima. Riprodotto con un test minimo, SENZA alcun opcode flash coinvolto: un primo `WRITE_RAM`
emesso troppo presto dopo il reset (prima che `psram_controller` esca dal suo power-up,
~150µs) fa sì che l'host, non essendo rallentato da alcun handshake, continui a scorrere byte
SPI mentre `spi_engine` è ancora bloccato ad aspettare il PRIMO `ram_ready` — i byte ricevuti
in quella finestra vengono scartati silenziosamente, **senza errore, senza hang**: solo dati
sbagliati. **Perché è emerso solo ora**: prima del fix del Bug #1 di F2
(`psram_controller.v`), una richiesta che arrivava durante il power-up veniva soddisfatta
"per sbaglio, ma presto" da un impulso `mem_ready` spurio della sequenza CR_INIT — un
comportamento SBAGLIATO che però, per coincidenza, dava all'host abbastanza poco tempo da non
disallinearsi. Il fix CORRETTO (F2) fa aspettare la richiesta per l'intera, vera durata del
power-up — tempo sufficiente perché l'host si disallinei davvero. **Non è una regressione**:
è un rischio pre-esistente, mascherato da un bug pre-esistente diverso, ora scoperto per la
prima volta. **Mitigazione applicata qui**: ogni testbench che tocca la PSRAM aspetta
esplicitamente `psram_ctrl.state == STATE_IDLE` prima del primo accesso (pattern già usato da
`sim/spi_neuron_top_graph_tb.v` e simili, solo non ancora copiato nei nuovi testbench di
questa sessione). **Non risolto nell'RTL** (fuori scope per il sottosistema flash — servirebbe
un vero backpressure su `WRITE_RAM`/`READ_RAM`, una modifica di protocollo più ampia):
dichiarato esplicitamente come rischio aperto per qualunque host reale, non solo per i test.

### Verifica F5 (secondo §A)

`sim/spi_neuron_top_flash_tb.v`, 4 test sopra lo stack REALE completo (spi_slave+spi_engine+
flash_slot_manager+flash_copy_engine+spi_flash_master+mem_arbiter+int8_memory_access+
memory_interface+psram_controller+psram_model+flash_model), pilotato via SPI bit-banged
realistico — **ALL TESTS PASSED**:
- TEST1: `FLASH_ERASE`+`FLASH_WRITE_BLOCK`+`FLASH_READ_BLOCK` via SPI reale (la correttezza
  profonda di questi primitivi è già coperta a livello di modulo da F2/F3/F5-raw — questo
  prova che la DECODIFICA SPI in `spi_engine.v` li invoca correttamente, cosa che i test di
  modulo non possono provare).
- TEST2: `CAT_WRITE_SLOT`+`CAT_READ`+`CAT_INSPECT` via SPI reale.
- TEST3 (avversario §A.3): `LOAD_SLOT` su uno slot mai salvato → `STATUS.bit3` osservato via
  SPI reale.
- **TEST4 — il requisito esplicito §6 del piano**: `netasm → WRITE_RAM → SAVE_SLOT →
  (sovrascrittura PSRAM con garbage) → LOAD_SLOT → RUN_NETWORK → READ_RAM` = **126**, lo
  stesso valore atteso indipendente già usato in `sim/graph_engine_tb.v`/
  `sim/spi_neuron_top_graph_tb.v` (esempio da manuale §3, x=[10,1,4,0]), non ri-derivato qui.

**Tre intoppi reali nella COSTRUZIONE del TEST4** (nessuno un bug RTL — tutti dichiarati per
esteso nei commenti del testbench, perché sono esattamente il tipo di errore un utente reale
di questo sistema potrebbe fare):
1. Il blob di rete (tabella descrittore + edge) piazzato a PSRAM 0x000000 collide col
   `CATALOG_PSRAM_ADDR` di `flash_slot_manager` (default, anch'esso 0x000000) — la
   serializzazione del catalogo durante il passo di persistenza di `SAVE_SLOT` sovrascriveva
   silenziosamente il blob. Esattamente il limite già dichiarato nell'header di
   `flash_slot_manager.v` ("nothing else in this design may use that PSRAM range").
2. Prima generazione con `netasm` usava `--parallel` di default (8), ma questo testbench usa
   `PARALLEL=2` (come `spi_neuron_top_graph_tb.v`) — il padding delle connessioni non
   corrispondeva a `GRAPH_MAX_CONN`/`PARALLEL` reali dell'hardware sotto test.
3. **La scoperta più insidiosa**: `netasm` incorpora nella tabella descrittore l'indirizzo
   ASSOLUTO di ogni blocco edge, calcolato a tempo di compilazione da `--table-base`/
   `--edges-base` — NON un offset relativo a `table_base`. Spostare il blob compilato a un
   indirizzo PSRAM diverso da quello dato a `netasm` lascia questi puntatori incorporati
   "stantii", puntando silenziosamente a byte non correlati (qui, tutti zero) invece dei
   veri edge. **Nessun errore, nessun hang**: `graph_engine` legge edge azzerati e calcola un
   risultato sbagliato (0 invece di 126) con STATUS che riporta un completamento
   perfettamente pulito — motivo per cui è documentato per esteso nel commento del test:
   argomenti di indirizzo base sbagliati a un generatore di codice possono produrre un
   risultato "riuscito" ma completamente sbagliato, senza alcun sintomo visibile
   dall'hardware. Risolto rigenerando con `--table-base`/`--edges-base` che corrispondono
   davvero a dove il blob viene piazzato.
- **Regressione completa**: tutti i testbench del sottosistema flash (crc32, F1, F2, F3,
  erase, F4, F5-raw, F5-top) più i testbench esistenti del progetto
  (`spi_neuron_top_tb`, `spi_neuron_top_graph_tb`, `spi_neuron_top_runnetwork_tb`,
  `spi_neuron_top_irq_tb`, `spi_engine_tb`, `spi_slave_tb`, `psram_controller_tb`) —
  **tutti PASS**, nessuna regressione.
- **Sintesi reale, livello di SISTEMA COMPLETO** (prima volta per il sottosistema flash
  integrato): `yosys synth_ecp5` pulito (0 problemi CHECK) su `spi_neuron_top` intero.
  Pinout reale rigenerato (`tools/pinout/gen_lpf.py` esteso con `flash_mosi`/`flash_miso`/
  `flash_cs_n`, stesso banco 7, nessun pin `flash_sclk` — quel clock resta interno via
  `USRMCLK`) — **0 errori di vincolo**, 56/56 celle piazzate secondo vincoli.
  `nextpnr-ecp5` reale: **Program finished normally**, Fmax **66.68 MHz** (FAIL a 80MHz,
  atteso). **Percorso critico verificato esplicitamente identico a quello già noto** (non
  assunto): `u_graph_engine.u_neuron.group_index` → `u_mac8` → catena di riporto
  dell'accumulatore in `neuron_parallel.v` — la STESSA catena documentata fin dalla Fase 7,
  **nessun modulo del sottosistema flash compare nel percorso critico**. Il calo rispetto ai
  73.88MHz precedenti è rumore di piazzamento (floorplanning automatico, banda già
  caratterizzata nello sweep di seed), non una regressione di design — confermato dal
  percorso critico invariato. Occupazione: `TRELLIS_IO` 56/245 (22%), `TRELLIS_FF` 4855/43848
  (11%), `TRELLIS_COMB` 9060/43848 (20%), `USRMCLK` 1/1 (100%, piazzata correttamente) —
  nessuna pressione sulle risorse del dispositivo.

**Cosa NON è coperto da F5 (dichiarato, §A.6)**: nessun backpressure reale su
`WRITE_RAM`/`READ_RAM` (limite pre-esistente, rischio dichiarato sopra, non risolto — fuori
scope); nessuna verifica timing reale a 16MHz/80MHz delle latenze di load/save/erase con
metodologia di misura dedicata (arriva in F6); nessun documento di verifica consolidato
per-modulo (arriva in F6); `CATALOG_PSRAM_ADDR` resta una convenzione non imposta altrove
(dichiarato già in F4, confermato qui come causa reale di un intoppo — non un bug, ma un
rischio noto per l'host).

**Prossimo passo**: F6 — regressione completa finale, report di sintesi consolidato (Fmax,
occupazione), documento di verifica per modulo (cosa è coperto, come, contro quale oracolo),
misura reale delle latenze di load/save/erase a 16MHz e 80MHz con metodologia dichiarata.

## Sottosistema FLASH — F6: regressione finale, documento di verifica, latenze reali (2026-09-04)

Ultima fase: nessun RTL nuovo, solo verifica consolidata e misure — i deliverable finali di
§9 del piano.

**Regressione completa finale**: tutti i **33 testbench** del progetto (elenco completo via
`find sim -name "*_tb.v"`), ognuno compilato ed eseguito da zero (`iverilog -g2012
-DSIMULATION -o <tmp> rtl/*.v sim/psram_model.v sim/flash_model.v <tb>.v` + `vvp`) — **32
PASS + 2 fallimenti di elaborazione ATTESI** (`neuron_parallel_guard_negative_*`, il cui
"fallire a compilare" È il test, per costruzione — comportamento invariato dalla Fase 9,
mai toccato da questa sessione). **Zero regressioni** su un progetto che ora comprende 8
nuovi file RTL (`spi_flash_master.v`, `crc32.v`, `flash_copy_engine.v`,
`flash_slot_manager.v` + le modifiche a `mem_arbiter.v`, `psram_controller.v`,
`spi_engine.v`, `spi_neuron_top.v`) e 9 nuovi testbench, oltre a un file Python
(`tools/flash_catalog/oracle.py`) e uno di benchmark timing
(`sim/flash_latency_bench.v`).

**Misure reali di latenza a 16MHz e 80MHz** — metodologia dichiarata per esteso in
`docs/FPGA-Neural-Flash-Subsystem-Verification.md` (sintesi qui): simulare l'attesa WIP
INTERA a scala temporale reale con il vero loop di poll RDSR è stato **tentato e
abbandonato** — a timing reale, coprire un'attesa di 400ms (tSE MAX) con poll SPI reali
richiede ~100.000+ transazioni, decine di milioni di eventi Icarus, oltre il limite pratico
di tempo macchina (limite del simulatore, dichiarato esplicitamente come tale — non un
limite dell'hardware reale, dove il poll non costa nulla). Sostituito con: fase di "issue"
(WREN+SE/PP) misurata direttamente in simulazione (accurata indipendentemente dalla scala
temporale del modello flash, che scala solo l'attesa POST-issue) + durata dell'attesa WIP
presa dal valore MAX del datasheet (già citato in F1/F2, §9.6 p.90) sommata analiticamente —
lo stesso numero totale che un host reale vedrebbe, scomposto in una parte misurata e una
citata invece di forzare un singolo numero simulato che costerebbe più di quanto vale
ottenere onestamente.

| Operazione | @16MHz | @80MHz |
|---|---|---|
| ERASE (un settore 4KB) | 400.014 ms | 400.003 ms |
| SAVE (256B, incl. proprio erase) | 403.019 ms | 403.004 ms |
| LOAD (4096B) | 8.713 ms (0.470 MB/s) | 1.743 ms (2.351 MB/s) |

ERASE/SAVE dominati quasi interamente dal timing FISICO interno della flash (indipendente
dalla frequenza host, come atteso — tSE/tPP sono proprietà del chip, non dell'interfaccia);
LOAD invece puramente limitato dal clock SPI (READ non ha attesa WIP, §8 intro p.24) — la
banda scala linearmente con la frequenza, confermando che il modello di temporizzazione è
internamente coerente (nessuna sorpresa, il numero atteso fisicamente è quello misurato).

**Documento di verifica consolidato**: `docs/FPGA-Neural-Flash-Subsystem-Verification.md` —
per ogni modulo (`spi_flash_master.v`, `flash_model.v`, `flash_copy_engine.v`, `crc32.v`,
`flash_slot_manager.v`, le estensioni di `spi_engine.v`/`spi_neuron_top.v`): cosa è
coperto, come, contro quale oracolo indipendente, cosa NON è coperto (§A.6), più le due
scoperte trasversali di questa sessione (il bug di `psram_controller.v` e il limite di
backpressure di `WRITE_RAM`/`READ_RAM`) e le latenze reali sopra.

### Riepilogo del sottosistema flash (F1→F6)

- **RTL nuovo**: `rtl/spi_flash_master.v`, `rtl/crc32.v`, `rtl/flash_copy_engine.v`,
  `rtl/flash_slot_manager.v` (4 file, ~1100 righe totali).
- **RTL esteso, additivamente**: `rtl/mem_arbiter.v` (+ Port D), `rtl/psram_controller.v`
  (fix di un bug pre-esistente reale, non un'estensione funzionale), `rtl/spi_engine.v`
  (+ 8 opcode), `rtl/spi_neuron_top.v` (+ istanza `flash_slot_manager` + pin fisici).
  **Nessuna interfaccia esistente ha cambiato comportamento** (verificato dalla regressione
  completa ripetuta ad ogni fase, non solo alla fine).
  **Un secondo bug pre-esistente e non-flash trovato e documentato ma NON risolto nell'RTL**
  (fuori scope, richiederebbe un vero protocollo di backpressure): il limite di
  `WRITE_RAM`/`READ_RAM` — dichiarato apertamente, non nascosto.
- **Oracoli indipendenti usati**: datasheet W25Q128JV(-DTR) (citato riga per riga in
  `flash_model.v`), datasheet ECP5 (per USRMCLK), cell library reale di yosys (per la
  primitiva `USRMCLK`, non indovinata), `tools/flash_catalog/oracle.py` (Python `zlib.crc32`
  + layout catalogo, indipendente dall'RTL), valore di controllo testuale standard CRC32
  ("123456789"), il valore atteso 126 già stabilito indipendentemente da
  `sim/graph_engine_tb.v`.
- **9 nuovi testbench**, tutti con test avversari oltre al caso positivo (lunghezza fuori
  range, blocco non allineato, attraversamento pagina 256B, CRC corrotto, slot mai salvato,
  power-loss simulato, contesa reale dell'arbitro, opcode illegale).
- **Sintesi reale** (Yosys + nextpnr-ecp5, non solo simulazione) ad ogni fase; sintesi di
  SISTEMA COMPLETO in F5: 0 errori di vincolo, Fmax 66.68MHz (percorso critico verificato
  identico a quello pre-esistente dalla Fase 7, nessun modulo flash coinvolto), nessuna
  pressione sulle risorse.
- **Limiti dichiarati esplicitamente** (§A.6, mai nascosti): blocco >65535B non esercitato a
  piena scala; due slot/SAVE adiacenti non testati; `CATALOG_PSRAM_ADDR` è una convenzione
  non imposta a livello di sistema; nessuna verifica elettrica/analogica reale (fuori portata
  di una simulazione comportamentale); il limite di backpressure di WRITE_RAM/READ_RAM
  resta un rischio aperto per qualunque host.

Il sottosistema flash come richiesto dal piano originale (§0-§9) è completo: SPI master (F1),
copy engine bidirezionale flash↔PSRAM con erase-before-write e loop page-program (F2/F3),
catalogo a slot fissi con CRC32 e rilevamento power-loss (F4), opcode SPI completi e
integrazione nel top level (F5), verifica consolidata e misure reali (F6).

## Fase F7 — Bus SPI flash reso davvero indipendente, rimosso USRMCLK/CCLK (2026-09-04)

- 2026-09-04T00:00 — [FASE F7] — Richiesta esplicita dell'utente: il bus SPI verso la flash
  deve essere **esclusivo** anche a livello elettrico, non solo di controllo software. Il
  design F1-F6 riusava il pad `CCLK` di boot (via primitiva ECP5 `USRMCLK`) per il segnale
  SCLK del sottosistema flash, per risparmiare un pin — soluzione corretta ma fuorviante
  rispetto al requisito "bus esclusivo": elettricamente quel SCLK dipendeva dallo stesso pad
  del motore di configurazione, e portava con sé un gap di verifica reale mai chiuso (timing
  di pad-enable di `USRMCLKTS` non verificato contro la guida Lattice primaria
  `FPGA-TN-02039`, assente dal set di documenti locali — dichiarato come limite fin
  dall'header di `rtl/spi_flash_master.v`).
- **Fix**: rimossa `USRMCLK` da `rtl/spi_flash_master.v`; `sclk` diventa una porta GPIO
  ordinaria sempre presente (`output wire sclk`, non più dietro `` `ifdef SIMULATION ``),
  esattamente come `mosi`/`miso`/`cs_n`. Propagato attraverso tutta la catena di possesso
  (`flash_copy_engine.v` → `flash_slot_manager.v` → `spi_neuron_top.v`, porta top-level
  `flash_sclk`, prima `flash_sclk_sim` condizionale). Aggiornate tutte le 8 testbench che
  referenziavano il vecchio nome di porta (`spi_flash_master_tb`, `flash_copy_engine_{load,
  save,erase}_tb`, `flash_slot_manager_{tb,raw_tb}`, `flash_latency_bench`,
  `spi_neuron_top_flash_tb`).
- **Pinout**: `tools/pinout/gen_lpf.py` esteso con `flash_sclk` **in coda** alla lista dei
  segnali flash (non inserito in mezzo) proprio per non far slittare le ball già assegnate a
  `flash_mosi`/`flash_miso`/`flash_cs_n` — rigenerato `synth/ecp5/spi_neuron_top.lpf`,
  confermato via `git diff` **puramente additivo**: 3 righe in più, `flash_sclk`→E3 (banco 7),
  nessuna ball esistente riassegnata. Totale segnali reali: 56→**57**.
- **Regressione completa**: tutti i 33 testbench del progetto ricompilati ed eseguiti da zero
  dopo il fix — **tutti PASS**, incluso il test end-to-end mandatorio
  (`spi_neuron_top_flash_tb` TEST4: `netasm`→`SAVE_SLOT`→`LOAD_SLOT`→`RUN_NETWORK`,
  output=126 confermato invariato) e il benchmark di latenza (numeri identici:
  ERASE≈400.003ms, SAVE≈403.004ms, LOAD=1.743ms — la rinomina della porta non tocca la
  temporizzazione, solo il nome del segnale).
- **Sintesi reale ri-eseguita da capo** sul sistema completo (`yosys synth_ecp5` +
  `nextpnr-ecp5`, stessi comandi già validati, PARALLEL=8 default — stesso conteggio
  TRELLIS_FF=4855 del build precedente, confermando che è la stessa configurazione già
  misurata, non una diversa): **0 problemi CHECK**, **0 errori di vincolo**, "Program
  finished normally". Risultati chiave (`synth/ecp5/spi_neuron_top_flash/nextpnr.log`):
  - `TRELLIS_IO`: 57/245 (23%, +1 rispetto a prima).
  - **`USRMCLK`: 0/1 (0%)** — conferma diretta che la primitiva non è più usata affatto:
    il bus flash è ora GPIO ordinario al 100%, nessuna dipendenza dal motore di
    configurazione.
  - Fmax: **67.91 MHz** (FAIL a 80MHz atteso, invariato) — leggermente meglio dei 66.68MHz
    precedenti (rumore di piazzamento, un pin in più non peggiora nulla), non una
    regressione.
  - Percorso critico verificato esplicitamente identico a prima (`u_graph_engine.u_neuron.
    group_index` → `u_mac8` → catena di riporto dell'accumulatore in `neuron_parallel.v`):
    nessun modulo del sottosistema flash, né il nuovo pin, compare nel percorso critico.
  - Margine sull'oscillatore reale 16MHz: 4.24×, sostanzialmente invariato.
- **Conclusione**: il sottosistema flash ha ora un bus SPI a 4 fili (sclk/mosi/miso/cs_n)
  genuinamente indipendente lato FPGA/RTL — zero segnali condivisi con il percorso di boot a
  livello di logica/vincoli. Resta, per costruzione (stesso chip fisico W25Q128JV usato sia
  per il boot sia per la persistenza), un doppio collegamento a livello di **scheda**: i pin
  DI/DO/CS/CLK della flash vanno cablati sia ai pin dedicati di config sia a questi 4 pin
  GPIO ordinari — non ancora catturato in uno schematico (nessuno schematico esiste ancora
  per questa combinazione dispositivo/package), dichiarato come voce aperta.
