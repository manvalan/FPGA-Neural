# C.11 — Toolchain / build (Yosys → nextpnr-ecp5 → `ecppack` → `.bit` reale)

Data: 2026-09-04.

## Evidenza

- **Flusso completo eseguito end-to-end sul build corrente**, non solo in passato su build
  più vecchi:
  ```
  yosys -p "synth_ecp5 -json top.json -top spi_neuron_top" <20 file RTL>
    → 0 problemi CHECK
  nextpnr-ecp5 --45k --package CABGA381 --speed 8 --json top.json --lpf spi_neuron_top.lpf
    → 0 errori di vincolo, "Program finished normally", Fmax 67.91 MHz
  ecppack --compress top.config /tmp/current_full_system.bit
    → 0 errori, 319747 byte, header "Part: LFE5U-45F-8CABGA381" verificato
  ```
  Rieseguito in questa fase (non solo citato da build precedenti in `WORKLOG.md`).
- **Non testato**: programmazione su hardware fisico reale (nessuna scheda disponibile in
  questo ambiente) — dichiarato esplicitamente come limite fin dalle prime fasi del
  progetto, non nascosto.

## Verdetto

**CERTIFICATO** per la parte verificabile in questo ambiente (RTL→bitstream, 0 errori ad
ogni stadio, sul build corrente). **NON CERTIFICABILE in questa campagna**: comportamento
su silicio reale (nessun hardware fisico disponibile) — limite dichiarato esplicitamente
per §A.5, non una lacuna nascosta.
