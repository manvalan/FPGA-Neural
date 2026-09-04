# C.7 — SPI slave + engine (`spi_slave.v`, `spi_engine.v`)

Data: 2026-09-04.

---

## 7.1 CDC, framing, opcode dispatch — CERTIFICATO (copertura pre-esistente estesa, riverificata)

Questo modulo ha già ricevuto lavoro di verifica sostanziale **in questa stessa sessione**
(non solo dichiarato in sessioni precedenti):
- **Una race reale trovata e corretta** nel meccanismo sticky di `STATUS` (Fase 4/9 di
  sessioni precedenti, ma il fix e la sua verifica sono tracciabili e riverificati).
- **CDC a 2/3 stadi per `sclk`/`mosi`/`cs_n`**: `sim/spi_slave_tb.v` include un test
  esplicito con rapporto SCLK/clk diverso (TEST 4, "slower SPI clock... confirms no hidden
  dependency on a specific SCLK/clk ratio") — non solo un singolo rapporto a piacere.
- **`sim/spi_engine_tb.v`**: 10 test (A-J) coprono WRITE_RAM/READ_RAM round-trip, SET_BASE,
  START idle/busy, STATUS live/sticky/clear-on-read, RESET, READ_OUTPUT (neuron-major),
  READ_CONFIG, NOP (nessun side-effect), byte MOSI in eccesso ignorati, transazioni
  back-to-back.
- **Opcode sconosciuti**: `default: begin // OP_NOP and unknown opcodes` (riga 724) —
  trattati esplicitamente come NOP, nessun rischio di hang per costruzione, coerente col
  pattern già verificato per `spi_flash_master.v` (opcode illegale, Fase F1).
- Rieseguito in Fase 0 di questa campagna (non solo citato): `spi_slave_tb.v` e
  `spi_engine_tb.v` **PASS**, confermato dall'harness di regressione indipendente.

**Verdetto: CERTIFICATO**, con la stessa evidenza di prima (riverificata, non solo citata).

---

## 7.2 `len=0` per WRITE_RAM/READ_RAM — CERTIFICATO (guard esplicito trovato per ispezione)

Dato il pattern ricorrente in questa campagna (guard mancante su valori "reali=0" in più
moduli, BUG-002/003/004/005/006), ho controllato se lo stesso buco esistesse anche qui.
**Non esiste**: `rtl/spi_engine.v:817` ha un guard esplicito —

```verilog
if ({len_acc[7:0], rx_byte} == 16'h0) begin
    state <= ST_IGNORE;
end else if (opcode == OP_WRITE_RAM) begin
    state <= ST_WRITE_DATA;
...
```

`len=0` transita correttamente a `ST_IGNORE` (no-op sicuro) invece di entrare nel loop di
trasferimento — a differenza di `layer_sequencer.v`/`graph_engine.v`, qui il caso limite è
gestito esplicitamente. Non serviva un nuovo test dedicato: il guard è verificabile per
ispezione diretta, inequivocabile.

**Verdetto: CERTIFICATO.** Nota positiva per il registro: questo modulo dimostra che il
progetto **non manca sistematicamente** di guardie sui valori limite — il buco è
specifico ai moduli già segnalati (BUG-002 - BUG-006), non universale.

---

## 7.3 Verdetto complessivo C.7

| Sotto-aspetto | Verdetto |
|---|---|
| CDC, framing, dispatch opcode, opcode sconosciuti | **CERTIFICATO** (copertura estesa pre-esistente, riverificata) |
| `len=0` WRITE_RAM/READ_RAM | **CERTIFICATO** (guard esplicito confermato per ispezione) |

Nessun nuovo bug trovato in questo aspetto.
