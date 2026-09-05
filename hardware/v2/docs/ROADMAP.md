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
- [ ] **M4 — Memory Manager** (`memory_manager.v`, `prefetch_engine.v`),
      backend PSRAM V1 riusato senza modifiche.
- [ ] **M5 — Neural Director** (`neural_director.v`), scheduling first-free.
- [ ] **M6 — Dependency Manager** (`dependency_manager.v`), ready/waiting
      queue, dependency counters, wake-up, producer tracking.
- [ ] **M7 — Dataflow Core** (`dataflow_core.v`), integrazione completa.
- [ ] **M8 — PSRAM integration**, controller V1 non modificato, misura reale.
- [ ] **M9 — Full benchmark**, tabella V1 vs V2 (§32 del mandato).
- [ ] **M10 — Optimization**, solo sulla base dei dati raccolti in M1-M9.

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
