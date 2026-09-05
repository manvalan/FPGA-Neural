# FPGA-Neural V2 — stato roadmap

Fonte del mandato: `docs/v2-description.md` (root del repository). Baseline
funzionale/numerica/bit-exact: `hardware/v1/` (frozen, sola lettura — vedi
`hardware/v1/README.md`).

Legenda: `[ ]` non iniziato · `[~]` in corso · `[x]` completo (sim+synth+timing
reali, non solo scritto).

- [x] **M1 — Neural Processor** (`hardware/v2/rtl/neural_processor.v`, P8).
      Bit-exact vs V1 (7/7 test, Verilator), pipeline a 8 stadi
      funzionante, throughput reale (1 tile/ciclo). Sintesi reale: 0
      problemi CHECK, Fmax 183.12 MHz (ACC_WIDTH=32) — vedi
      `logs/experiments.log` EXP-0001/EXP-0002, `logs/errors.log` per 3
      bug reali trovati e risolti (2 del toolchain Icarus, 1 RTL).
- [x] **M2 — Processor Array** (`neural_processor_array.v`). 1/2/4/8
      processor testati (sim concorrenza reale + sintesi/P&R reali).
      Fmax sempre PASS a 80MHz (159.11→134.70 MHz). Scoperta: il DSP
      (MULT18X18D), non LUT/FF, satura per primo (88% a N=8) — vedi
      `logs/decisions.log` DEC-0005.
- [x] **M3 — Buffers** (`activation_buffer.v`, `weight_buffer.v`,
      `result_buffer.v`). Tutti inferiscono DP16KD reale (10/10 test,
      6/6 config sintetizzate 0 problemi). Scoperta: il costo BRAM di
      weight_buffer e' guidato da P_IN (larghezza), non da DEPTH.
- [x] **M4 — Memory Manager** (`memory_manager.v`, `prefetch_engine.v`),
      backend PSRAM V1 riusato SENZA MODIFICHE. End-to-end reale (3/3
      job PASS) con vero neural_processor + vera catena PSRAM V1.
      3 bug RTL trovati/risolti (`logs/errors.log` ERR-0006). Fmax
      165.86 MHz.
- [x] **M5 — Neural Director** (`neural_director.v`), scheduling
      first-free. 4/4 test PASS (dispatch + coda + backpressure reale
      su N_SLOTS=2). FSM ridotta a 4 stati, dependency rimandata a M6
      (`logs/decisions.log` DEC-0007). Fmax 250.50 MHz.
- [x] **M6 — Dependency Manager** (`dependency_manager.v`), ready/waiting
      queue, dependency counters, wake-up, producer tracking. 4/4 test
      PASS (dipendenze multiple + produttore condiviso/piu' consumer).
      Fmax 155.30 MHz. Forwarding di valori e riuso slot rimandati
      (`logs/decisions.log` DEC-0008).
- [x] **M7 — Dataflow Core** (`dataflow_core.v`), prima integrazione
      completa: Dependency Manager (M6) -> Neural Director (M5) ->
      N_SLOTS x (Memory Manager (M4) + Neural Processor (M1)), loop di
      wake-up chiuso end-to-end. 4/4 test PASS su un DAG a 3 nodi (node2
      dipende da entrambi node0+node1, dispatch confermato solo dopo che
      ENTRAMBI completano davvero). Sintesi reale 0 problemi a
      N_SLOTS=2 e N_SLOTS=4. Fmax reale (harness): 165.15 MHz
      (N_SLOTS=2), 133.19 MHz (N_SLOTS=4). Buffer M3 e arbitraggio PSRAM
      condiviso rimandati esplicitamente a M8 (`logs/decisions.log`
      DEC-0009).
- [x] **M8 — PSRAM integration** (`neural_multiprocessor.v`,
      `slot_mem_arbiter.v`), controller V1 riusato SENZA MODIFICHE,
      condiviso tra N_SLOTS memory_manager concorrenti reali. Trovato e
      risolto un bug RTL reale: il primo arbitro perdeva silenziosamente
      una richiesta arrivata durante la contesa (protocollo byte-level
      "fire-and-forget", mai esposto da M4 che collega un solo master
      direttamente) — vedi `logs/errors.log` ERR-0008. Dopo il fix: 4/4
      test PASS (2 slot in vera contesa concorrente sulla stessa PSRAM
      reale). Sintesi reale 0 problemi (nessun harness necessario — pin
      reali PSRAM tengono il top-level a 157 pin). Fmax reale 142.45
      MHz. Politica di arbitraggio a priorità fissa, non ancora fair
      (`logs/decisions.log` DEC-0010).
- [x] **M9 — Full benchmark**, tabella V1 vs V2 (§32 del mandato) —
      confronto full-system, stesso PARALLEL/P_IN=8, stesso backend
      PSRAM reale V1 in entrambi. Fmax POST-P&R: V2 142.45 MHz (PASS
      @80MHz) vs V1 68.65 MHz (FAIL @80MHz). Cicli/neurone SIMULATED
      (1 neurone, 8 input, PSRAM reale): V2 166 vs V1 209 (2.6x
      speedup wall-clock reale). MAC/cycle di picco: V2 16 (N_SLOTS=2 x
      P_IN=8, concorrenza reale) vs V1 8 (core sequenziale singolo).
      LUT/FF: V2 4191/3659 vs V1 8907/4900. 9/12 righe con dati reali
      misurati; stall %/memory utilization/processor utilization
      esplicitamente NON misurati questo milestone (`logs/decisions.log`
      DEC-0011), rimandati a M10. Tabella completa in
      `logs/benchmark.log`.
- [x] **M10 — Optimization**, solo sulla base dei dati raccolti in
      M1-M9. N_SLOTS=8 sintetizzato e P&R reale (92.63 MHz, PASS
      @80MHz, DSP 64/72=88.9%) — tetto pratico raccomandato per P_IN=8
      su LFE5U-45F (`logs/decisions.log` DEC-0012). Sweep reale a 6
      seed ACC_WIDTH 24 vs 32 (riusando i netlist gia' sintetizzati):
      ACC_WIDTH=24 vince sia in Fmax medio (+6.2%, 180.71 vs 170.12
      MHz) che in varianza (~3.4x piu' stretta) — risolve
      l'inconcludenza a singolo seed di EXP-0002, nuovo default
      raccomandato (DEC-0013). Strumentazione di conteggio cicli
      (solo testbench, nessun RTL toccato) chiude la lacuna
      stall%/utilization di DEC-0011 con dati reali: porta PSRAM
      condivisa all'81.7% di utilizzo, slot0 95.2%, slot1 65.2%.

## Roadmap completa (§33)

Tutte e 10 le milestone del mandato (`docs/v2-description.md` §33) sono
complete: simulazione reale (Verilator), sintesi reale (Yosys), place &
route reale (nextpnr-ecp5) per ognuna, con log completi in
`hardware/v2/logs/` (EXP-0001..EXP-0013, DEC-0001..DEC-0013,
ERR-0001..ERR-0008). Elementi esplicitamente rimandati (non
dimenticanze, ognuno con la propria motivazione in `decisions.log`):
riuso slot in dependency_manager (DEC-0008), fairness dell'arbitro PSRAM
sotto contesa piu' estesa (DEC-0010), sweep P_IN<8 per N_SLOTS ancora
piu' alto (DEC-0012), riuso dei buffer M3 come cache condivisa
(DEC-0009), strumentazione stall%/utilization completa anche lato V1
(DEC-0011).

## Final Benchmark Campaign (post-roadmap, richiesta utente)

Dopo il completamento di M1-M10, una campagna di benchmark finale
completa e reale (`hardware/v2/sim/tb_benchmark_suite.v`, EXP-0014) ha
caratterizzato V2 end-to-end su 6 workload realistici (16-256 neuroni
indipendenti, un layer multilivello con forwarding reale via PSRAM, un
DAG a 6 nodi con risveglio a 2 hop) su N_SLOTS=1/2/4/8. 24/24 PASS
bit-exact dopo aver trovato e risolto 3 problemi reali (1 bug RTL in
`neural_director.v` mai testato a N_SLOTS=1, 2 bug nel testbench --
`logs/errors.log` ERR-0009). Scoperta principale: lo scaling parallelo
reale e' sostanzialmente PIATTO oltre N_SLOTS=2 (la vera porta PSRAM
condivisa satura al 91%, non il numero di processori) -- N_SLOTS=4 e'
misurabilmente PIU' LENTO in wall-clock reale di N_SLOTS=1 per il
workload Stress una volta considerato il vero Fmax POST-P&R.
**N_SLOTS=2 raccomandato come default** (`logs/decisions.log`
DEC-0014). Report completo (21 sezioni, THEORETICAL/SIMULATED/
POST-P&R/DERIVED classificati): `hardware/v2/docs/benchmarks/
final-benchmark.md`.

### Ottimizzazioni post-campagna (su richiesta utente)

Implementate entrambe le raccomandazioni #1/#2 del report:
1. **Burst a livello di parola** (`prefetch_engine.v`/`memory_manager.v`
   parlano direttamente il protocollo a 16 bit di `memory_interface.v`,
   bypassando `int8_memory_access.v` -- ancora congelato, semplicemente
   non piu' istanziato in questo percorso). Reale: -49/-56% cicli sui
   job singoli, 2.24-2.37x speedup wall-clock reale sull'intera
   campagna. `logs/decisions.log` DEC-0015.
2. **Cache condivisa on-chip per il vettore di attivazione** (nuovo
   `activation_cache.v`, evita che neuroni con lo stesso `x_base`
   rileggano X da PSRAM). Reale: ulteriore -1.66/-2.00x cicli. MA costo
   Fmax reale molto piu' ripido del previsto: N_SLOTS=4 ora FALLISCE il
   target 80MHz (65.01 MHz, prima passava). N_SLOTS=2 (default
   raccomandato) resta valido con margine piu' sottile (87.72 MHz).
   Speedup wall-clock reale combinato (#1+#2) vs baseline originale:
   N=1 3.86x, N=2 2.45x. `logs/decisions.log` DEC-0016.

Trovati e risolti 3 bug RTL reali durante l'implementazione
(`logs/errors.log` ERR-0009, ERR-0010). 24/24 combinazioni
workload/config ancora bit-exact dopo entrambe le ottimizzazioni.

## Log

Vedi `hardware/v2/logs/` (`development.log` per la cronologia di sessione,
`decisions.log` per le decisioni architetturali con motivazione,
`experiments.log` per ogni EXP-XXXX end-to-end).

## Regole non negoziabili attive (§34 del mandato, per riferimento rapido)

1. V1 (`hardware/v1/`) rimane intatta — mai modificata.
2. V2 vive esclusivamente sotto `hardware/v2/`.
3. Nessun risultato inventato: THEORETICAL vs SIMULATED vs SYNTHESIZED vs
   POST-P&R sempre etichettati esplicitamente.
4. Ogni modifica/esperimento/decisione registrata nei log, mai persa.
5. Ogni esperimento ha un ID univoco, mai riutilizzato — anche i FAIL restano.
