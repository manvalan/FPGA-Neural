# C.9 — Pinout / `.lpf`

Data: 2026-09-04. Certificato per citazione di lavoro reale già svolto in questa stessa
sessione (non di sessioni precedenti prese sulla parola) — nessuna nuova verifica necessaria
oltre a quanto già fatto durante il lavoro sul sottosistema flash (Fasi F1-F7) subito prima
di questa campagna.

## Evidenza

- **`.lpf` reale, non pianificato**: `synth/ecp5/spi_neuron_top.lpf`, generato da
  `tools/pinout/gen_lpf.py` contro `iodb.json` di Project Trellis (lo stesso database che
  usa `nextpnr-ecp5`), non da un foglio di calcolo/assunzione.
- **Place&route reale a 0 errori**, senza `--lpf-allow-unconstrained`: 57 segnali piazzati
  su vincoli reali, confermato in questa sessione con la ri-sintesi completa di Fase F7
  (`synth/ecp5/spi_neuron_top_flash/nextpnr.log`).
- **Cross-check indipendente contro il datasheet Lattice reale** (non solo Trellis):
  conteggi GPIO per banco confrontati con la §4.3.2 del datasheet ufficiale
  `FPGA-DS-02012-3-4-ECP5-ECP5G-Family-Data-Sheet.pdf` fornito dall'utente — coincidenza
  esatta su 6 banchi su 7.
- **`USRMCLK` verificato contro il blackbox reale di yosys** (`cells_bb.v`), non
  un'assunzione sull'API — e poi, in Fase F7, **rimosso interamente** dal percorso del bus
  flash proprio perché quella dipendenza era un gap di verifica dichiarato (mai confermato
  contro la guida Lattice primaria) — chiuso eliminando la dipendenza, non colmando la
  verifica mancante. Confermato dalla stessa sintesi: `USRMCLK` 0/1 (0%) nel build corrente.
- **Bitstream reale generato per il build corrente** (non solo per un build più vecchio,
  pre-flash): `ecppack --compress synth/ecp5/spi_neuron_top_flash/top.config
  /tmp/current_full_system.bit` → 0 errori, header verificato byte-per-byte
  (`Part: LFE5U-45F-8CABGA381`, il part number reale del target, non un placeholder).

## Verdetto

**CERTIFICATO.** Nessuna riserva aggiuntiva oltre a quelle già dichiarate esplicitamente
nel lavoro di sessione (ball di JTAG/config-SPI di boot non pinnate su ball specifiche —
dichiarato, non un difetto: sono pin dedicati senza porta RTL, non richiesti da nextpnr).
