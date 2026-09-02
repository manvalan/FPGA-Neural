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
