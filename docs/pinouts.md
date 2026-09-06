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