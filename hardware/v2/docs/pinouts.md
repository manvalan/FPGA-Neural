Perfetto, il CSV è quello giusto: FPGA-SC-02034-3-0-ECP5U-45-Pinout.csv, rev. 3.0. L'ho letto e possiamo finalmente fare il pinout esatto per il LFE5U-45F caBGA381, senza deduzioni.

Ho anche verificato la documentazione Lattice aggiornata: per LFE5U VCC = 1,1 V ±5%, VCCAUX = 2,5 V ±5%, VCCIO da 1,2 a 3,3 V e VCCIO8 è il banco associato alla configurazione.

Pinout essenziale BG381
Ball	Funzione	Alimentazione / collegamento
H13	VCC	1.1 V
J13	VCC	1.1 V
K13	VCC	1.1 V
L13	VCC	1.1 V
M13	VCC	1.1 V
N13	VCC	1.1 V
H12	VCC	1.1 V
N12	VCC	1.1 V
H11	VCC	1.1 V
N11	VCC	1.1 V
H10	VCC	1.1 V
N10	VCC	1.1 V
H9	VCC	1.1 V
N9	VCC	1.1 V
H8	VCC	1.1 V
J8	VCC	1.1 V
K8	VCC	1.1 V
L8	VCC	1.1 V
M8	VCC	1.1 V
N8	VCC	1.1 V
F6	VCCAUX	2.5 V
P6	VCCAUX	2.5 V
F15	VCCAUX	2.5 V
P15	VCCAUX	2.5 V
F9, F10	VCCIO0	Bank 0
F11, F12	VCCIO1	Bank 1
H14, H15, J15	VCCIO2	Bank 2
L14, L15, M15	VCCIO3	Bank 3
L6, L7, M6	VCCIO6	Bank 6
H6, H7, J6	VCCIO7	Bank 7
P9, P10	VCCIO8	Bank 8 / configuration

Nota: il CSV elenca anche i pin VSS/VSSIO; vanno tutti collegati correttamente al piano GND, senza lasciarne nessuno scollegato.

JTAG / programmazione

Questi sono particolarmente importanti perché sono ball esatti del BG381:

Ball	Pin	Bank	Collegamento
R5	TDI	40	JTAG TDI
T5	TCK	40	JTAG TCK
U5	TMS	40	JTAG TMS
V4	TDO	40	JTAG TDO
W3	PROGRAMN	8	controllo configurazione
V3	INITN	8	stato configurazione
Y3	DONE	8	configurazione completata

Il bank 8 è quello associato all'interfaccia di configurazione; Lattice indica esplicitamente VCCIO8 come alimentazione da dimensionare in funzione dell'interfaccia di configurazione utilizzata.

CCLK

Dal CSV:

Ball	Pin	Bank
U3	CCLK	8

Attenzione però: CCLK non è automaticamente il clock di sistema della nostra rete neurale. È il clock associato alla configurazione; il clock operativo della FPGA va identificato separatamente nel percorso dell'oscillatore/PLL.

CFG[2:0] (selezione modalità di boot)

Dal CSV, tutti banco 8:

Ball	Pin	Note
U4	CFG_0	CFGMDN0
T4	CFG_1	CFGMDN1
R4	CFG_2	CFGMDN2

Per boot automatico da flash #2 (MSPI): CFG[2:0]=[0,1,0] (letto CFG2,CFG1,CFG0) → CFG_2 a GND, CFG_1 a pull-up 1–10kΩ verso VCCIO8, CFG_0 a GND (dato reale, Lattice FPGA-TN-02039-2.3 §6.1.1, Tabella 6.3). Pin resi modificabili via jumper/resistori 0Ω, non hardwired fissi.

Pin dual-function MSPI verso flash #2 (boot)

Dal CSV, ball dual-function del banco 8, NON pin JTAG/dedicati separati — sono ball PIO ordinari con funzione secondaria sysCONFIG:

Ball	Pin CSV	Funzione MSPI
R2	PB15A: HOLDN/DI/BUSY/CSSPIN/CEN	CSSPIN (chip select verso flash #2), + 4.7kΩ pull-up a VCCIO8
W2	PB11B: D0/MOSI/IO0	D0/MOSI verso flash #2
V2	PB11A: D1/MISO/IO1	D1/MISO verso flash #2
U3	CCLK (vedi sopra)	MCLK verso flash #2, pull-up debole interna

Questi 4 ball (insieme a PROGRAMN/INITN/DONE sopra) collegano l'FPGA esclusivamente alla flash di boot — unico chip flash presente nel design attuale.

**Aggiornamento 2026-09-07 — Flash #1 (dati rete neurale) rimossa**: era stata realmente integrata (RTL V1 `flash_copy_engine.v`/`flash_slot_manager.v` istanziato, adapter nuovo, opcode SPI dedicato, testbench dedicato, verificata bit-exact) sui ball B2/E2/F2/F3 (banco 7). **Rimossa di nuovo** su scelta esplicita dell'utente: degradava il timing reale di N_SLOTS=4 (8/8→3/8 PASS a 64MHz) e la frequenza di clock è stata giudicata più importante della persistenza locale dei pesi — l'ESP32 può ricaricarli ad ogni sessione via il protocollo SPI applicativo. Revert pulito (`git revert`, commit `59901a4`, recuperabile in futuro). I ball B2/E2/F2/F3 sono di nuovo liberi (nessuna funzione riservata). Vedi `decisions.log` DEC-0041 (design originale) e DEC-0042 (rimozione + recupero del timing).

Decoupling

Qui preferisco essere molto preciso: non voglio inventare una quantità di condensatori per “ogni VCC”.

La Hardware Checklist ufficiale Lattice richiede esplicitamente:

VCC 1,1 V con PCB plane e adeguato decoupling;
VCCAUX 2,5 V;
VCCIO 1,2–3,3 V;
VCCIO8 coerente con l'interfaccia di configurazione.

Per la nostra scheda farei quindi una rete di decoupling distribuita, non un condensatore unico per ogni ball:

                 LFE5U-45F
              ┌──────────────┐
1V1_CORE ─────┤ VCC          │
              │              │
2V5_AUX ──────┤ VCCAUX       │
              │              │
3V3/2V5/etc ──┤ VCCIOx       │
              │              │
GND ──────────┤ VSS          │
              └──────────────┘

con i condensatori fisicamente distribuiti attorno al BGA, con quelli ad alta frequenza il più vicino possibile alle rispettive vie/pad di alimentazione.

Una cosa importante

Adesso che abbiamo il CSV ufficiale, posso fare un lavoro ancora più utile: estrarre tutti i 381 ball del BG381 e generarti una tabella Markdown completa divisa in:

VCC
VCCAUX
VCCIO0–8
VSS/VSSIO
JTAG
PROGRAMN/INITN/DONE
clock
GPIO utilizzabili
pin da NON utilizzare
BOM decoupling consigliata
header JTAG completo

Quella diventerebbe praticamente la nostra scheda di riferimento hardware per il PCB V2.