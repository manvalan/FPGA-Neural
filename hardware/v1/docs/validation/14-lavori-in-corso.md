# C.14 — Lavori in corso (page-mode PSRAM, sottosistema flash)

Data: 2026-09-04.

## Stato reale, non dichiarato

Entrambi gli elementi che il prompt di certificazione elenca come "lavori in corso" sono in
realtà **completi**, verificato per lo stato reale della repo (non per quanto dichiarato):

- **Page-mode PSRAM**: `sim/psram_page_mode_tb.v` esiste, copre `ACCESS_CYCLES`, `PAGE_CYCLES`,
  `tCEM` (idle timeout e budget mid-burst), con `psram_model.v` che fa `$fatal` su
  violazione di timing reale. Rieseguito PASS in Fase 0 (§C.3).
- **Sottosistema flash**: `rtl/spi_flash_master.v`, `flash_copy_engine.v`,
  `flash_slot_manager.v` esistono, 8 opcode SPI (0x40-0x47) integrati in
  `spi_neuron_top.v`, bus SPI reso indipendente in Fase F7. 33 testbench del progetto
  includono 9 dedicati al sottosistema flash, tutti PASS in Fase 0.

**Nessun residuo "in corso" trovato**: non ci sono moduli RTL a metà, TODO irrisolti nel
codice, o funzionalità dichiarate ma non implementate per questi due elementi.

## Verdetto

**CERTIFICATO come COMPLETO**, non "in corso" — il prompt di certificazione descriveva
questi elementi come potenzialmente incompleti, ma lo stato reale della repo (verificato,
non assunto) li mostra completi e testati, coerentemente con quanto già stabilito nella
documentazione. Nessuno scostamento trovato qui.
