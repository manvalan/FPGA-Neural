# FPGA-Neural — Datasheet

Datasheet tecnico multicapitolo dell'engine FPGA-Neural, in italiano e inglese.
Ricostruito a partire dal codice RTL, dalla documentazione e dai benchmark presenti
nella repository (revisione A1, settembre 2026).

## Struttura

```
docs/datasheet/
├── FPGA-Neural-Datasheet.pdf        ← PDF italiano (36 pagine)
├── FPGA-Neural-Datasheet.tex        ← sorgente principale (IT)
├── preamble.tex                     ← stili, palette, box, TikZ
├── chapters/                        ← 14 capitoli (IT)
└── en/
    ├── FPGA-Neural-Datasheet-EN.pdf ← PDF inglese (36 pagine)
    ├── FPGA-Neural-Datasheet-EN.tex ← sorgente principale (EN)
    ├── preamble.tex                 ← stili (EN)
    └── chapters/                    ← 14 capitoli (EN)
```

## Compilazione

Serve una distribuzione LaTeX con `pgfplots`, `tikz-timing`, `tcolorbox`,
`ltablex`, `listings`, `babel`.

```sh
# Italiano
cd docs/datasheet
pdflatex FPGA-Neural-Datasheet.tex
pdflatex FPGA-Neural-Datasheet.tex   # 2ª passata per indice e riferimenti

# Inglese
cd docs/datasheet/en
pdflatex FPGA-Neural-Datasheet-EN.tex
pdflatex FPGA-Neural-Datasheet-EN.tex
```

## Nota sul pinout

Il capitolo *Progetto hardware e mappa dei segnali* riporta l'analisi completa
segnale-per-segnale del top-level `spi_neuron_top`, con la colonna **Ball**
compilata con assegnazioni CABGA381 reali (53 segnali, `.lpf` reale in
`synth/`) e verificata da un place\&route reale (`nextpnr-ecp5`, 0 errori di
vincolo, `Program finished normally`) — non più auto-piazzate.
