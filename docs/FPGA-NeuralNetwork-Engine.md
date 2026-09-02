# FPGA Neural Network Engine

Hardware Neural Network Engine based on FPGA + dedicated RAM.

The project implements a **parametric hardware accelerator for neural networks**, designed to be reusable across different embedded systems and applications.

The fundamental design principle is that the neural-network computation is performed entirely inside the FPGA, while the host system communicates with the engine through a simple hardware-independent interface such as SPI.

---

## 1. Project Goal

The goal of this project is to develop a reusable **Neural Network Engine implemented in FPGA hardware**.

The engine is composed of:

- FPGA;
- dedicated RAM connected to the FPGA;
- host interface, initially SPI and potentially Dual SPI.

The host system is not part of the neural-network computational datapath.

Possible host systems include:

- Linux SoCs;
- Raspberry-Pi-like systems;
- ESP32;
- microcontrollers;
- other embedded processors;
- development PCs.

The same Neural Network Engine architecture should therefore be usable in completely different systems.

```text
                    HOST SYSTEM
             ┌─────────────────────────┐
             │                         │
             │ Linux / ESP32 / MCU     │
             │                         │
             │ Configuration           │
             │ Training                │
             │ Control                 │
             └────────────┬────────────┘
                          │
                       SPI / Dual SPI
                          │
                          ▼
             ┌─────────────────────────┐
             │          FPGA           │
             │                         │
             │ Neural Network Engine   │
             │                         │
             │ Compute / Control       │
             │                         │
             └────────────┬────────────┘
                          │
                          │
                    Dedicated RAM
```

---

# 2. Architectural Principle

The FPGA is the actual neural-network accelerator.

The RAM required by the neural network is physically associated with the FPGA and is **not part of the host system memory**.

The host only provides:

- configuration;
- network parameters;
- input data;
- control;
- result retrieval.

The neural-network calculations themselves are executed by the FPGA.

This separation is a fundamental architectural requirement.

---

# 3. Hardware Configuration vs Network Configuration

An important distinction is made between the **hardware architecture of the accelerator** and the **parameters of the neural network**.

## 3.1 FPGA hardware configuration

The physical architecture of the Neural Network Engine is defined when the FPGA design is synthesized and implemented.

Typical hardware parameters include:

```text
N_INPUTS
N_NEURONS
N_LAYERS
PARALLEL
DATA_WIDTH
ACCUMULATOR_WIDTH
```

These parameters can therefore be Verilog/SystemVerilog parameters or equivalent synthesis-time configuration values.

For example:

```text
N_INPUTS  = 32
N_NEURONS = 4
PARALLEL  = 8
```

defines a specific hardware implementation optimized for that architecture.

The resulting FPGA bitstream contains the corresponding datapath.

---

## 3.2 Neural-network configuration

Once the FPGA has been configured and initialized, the actual neural-network parameters can be loaded through the host interface.

These parameters may include:

- weights;
- biases;
- activation parameters;
- quantization parameters;
- network-specific constants.

These values are stored in the RAM associated with the FPGA.

Therefore:

```text
FPGA BITSTREAM
        │
        │ defines hardware architecture
        ▼
┌─────────────────────┐
│ Neural Network      │
│ Hardware Engine     │
└──────────┬──────────┘
           │
           │ loads
           ▼
┌─────────────────────┐
│ Dedicated RAM       │
│                     │
│ weights             │
│ biases              │
│ parameters          │
│ buffers             │
└─────────────────────┘
```

This provides an important separation between **hardware specialization** and **network data**.

---

# 4. Application-Specific Neural Networks

The Neural Network Engine is not intended to implement one fixed neural network.

Instead, each application can define its own network.

For example:

```text
Application A
    16 inputs
    8 neurons
    1 output

Application B
    32 inputs
    16 neurons
    4 outputs

Application C
    64 inputs
    multiple layers
    custom parallelism
```

The FPGA hardware can then be generated specifically for the required architecture.

This allows the design to exploit the FPGA resources efficiently rather than implementing a completely generic and potentially inefficient neural-network processor.

---

# 5. Parametric Compute Engine

The current implementation contains a parametric neural-network layer.

A validated configuration is:

```text
N_INPUTS  = 32
N_NEURONS = 4
PARALLEL  = 8
```

The datapath processes the inputs in parallel groups.

Conceptually:

```text
32 inputs
    │
    ├── 8 parallel MACs
    │
    ├── 8 parallel MACs
    │
    ├── 8 parallel MACs
    │
    └── 8 parallel MACs
             │
             ▼
        Accumulation
             │
             ▼
           Bias
             │
             ▼
        Activation
             │
             ▼
          Output
```

The architecture is intended to scale by changing the synthesis parameters.

---

# 6. Current Functional Validation

The `32 × 4 / PARALLEL = 8` configuration has been successfully simulated.

Test output:

```text
========================================
PARAMETRIC LAYER TEST
N_INPUTS  = 32
N_NEURONS = 4
PARALLEL  = 8
========================================

PASS N0: 8192
PASS N1: 4096
PASS N2: 0 (ReLU)
PASS N3: 16384

========================================
PARAMETRIC TEST PASSED
========================================
```

Validated functionality:

- multiple inputs;
- multiple neurons;
- parallel MAC processing;
- accumulation across multiple input groups;
- bias handling;
- independent neuron outputs;
- ReLU activation;
- parametric layer architecture.

The corresponding test has been committed to the repository.

Commit:

```text
test: validate parametric 32x4 layer with parallelism 8
```

---

# 7. FPGA Boot and Initialization

The FPGA is configured during system initialization using its normal FPGA configuration mechanism.

The FPGA bitstream defines the hardware architecture of the Neural Network Engine.

Conceptually:

```text
Power-on
   │
   ▼
FPGA configuration
   │
   │ bitstream
   ▼
Neural Network Engine available
   │
   ▼
Host initialization
   │
   │ SPI
   ▼
Load network parameters
   │
   ▼
Load weights / biases
   │
   ▼
Engine ready
```

This means that the host does **not dynamically construct the FPGA datapath** during normal operation.

The datapath already exists in hardware.

The host configures the network data that the datapath operates on.

---

# 8. Host Interface

The primary external interface is intended to be:

```text
SPI
```

with possible future support for:

```text
Dual SPI
```

The interface must remain independent of the host operating system.

The same hardware protocol should therefore be usable from:

```text
Linux
ESP32
MCU
PC
```

The host interface should provide access to:

- control registers;
- status;
- network configuration;
- RAM;
- input data;
- output data;
- start/stop control;
- completion status.

A conceptual command sequence is:

```text
RESET
  │
  ▼
CONFIGURE
  │
  ▼
LOAD NETWORK PARAMETERS
  │
  ▼
LOAD WEIGHTS
  │
  ▼
LOAD BIASES
  │
  ▼
LOAD INPUT
  │
  ▼
START
  │
  ▼
WAIT FOR DONE
  │
  ▼
READ OUTPUT
```

---

# 9. Dedicated FPGA RAM

The RAM is considered part of the Neural Network Engine.

It is not intended to be supplied by the host system.

Depending on the final architecture, RAM may contain:

```text
Weights
Biases
Input buffers
Intermediate layer buffers
Output buffers
Network parameters
```

The memory architecture must be designed according to:

- number of parallel MAC units;
- data width;
- required bandwidth;
- number of layers;
- buffering requirements;
- FPGA block-RAM resources;
- possible external RAM requirements.

The preferred architecture is that the FPGA directly controls this memory.

---

# 10. Training

Training and inference are conceptually separated.

The first implementation does not require the FPGA to perform the complete training process.

Training can be performed externally:

```text
PC / Linux / other host
        │
        │ training
        ▼
Network weights
        │
        │ SPI
        ▼
FPGA RAM
```

The FPGA then performs inference using the resulting parameters.

This approach greatly reduces the complexity of the initial hardware implementation.

However, the architecture should not prevent future implementation of hardware-assisted or fully hardware-based training.

---

# 11. Inference

During inference, the host only supplies input data and retrieves the result.

```text
              HOST
                │
             Input
                │
                │ SPI
                ▼
        ┌───────────────┐
        │      FPGA     │
        │               │
        │ Neural Network│
        │    Engine     │
        │               │
        └───────┬───────┘
                │
             Output
                │
                │ SPI
                ▼
              HOST
```

The host is not involved in the individual MAC operations.

This provides:

- deterministic computation;
- reduced host workload;
- hardware parallelism;
- predictable latency;
- independence from the host CPU architecture.

---

# 12. Multi-Layer Architecture

The current implementation starts from a single parametrized layer.

The intended architecture is eventually:

```text
Input
  │
  ▼
┌──────────────┐
│   Layer 0    │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   Layer 1    │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   Layer 2    │
└──────┬───────┘
       │
       ▼
    Output
```

Intermediate data will be stored in FPGA-controlled memory buffers.

The number and size of layers should ultimately be part of the hardware generation process.

---

# 13. Reusability

The main purpose of the architecture is reuse.

A future project should be able to use the same general Neural Network Engine architecture with a different hardware configuration.

For example:

```text
Project A
    N_INPUTS  = 32
    N_NEURONS = 8
    PARALLEL  = 8

Project B
    N_INPUTS  = 64
    N_NEURONS = 16
    PARALLEL  = 16

Project C
    N_INPUTS  = 128
    N_NEURONS = 32
    PARALLEL  = 32
```

The HDL architecture remains conceptually the same while synthesis parameters generate an implementation appropriate for the target application.

---

# 14. Design Philosophy

The project should be considered a:

> **Reusable FPGA Neural Network Accelerator Platform**

rather than a single neural-network implementation.

The application determines:

```text
Input size
Network topology
Number of layers
Number of neurons
Parallelism
Numerical precision
Activation functions
Memory requirements
Performance requirements
```

The hardware generator then produces the corresponding FPGA implementation.

---

# 15. Development Roadmap

## Phase 1 — Parametric Layer

- [x] Parametric inputs
- [x] Parametric neurons
- [x] Parametric parallelism
- [x] Accumulation
- [x] Bias
- [x] ReLU
- [x] 32×4 / P=8 functional test

## Phase 2 — Parameter Sweep

Validate multiple combinations of:

```text
N_INPUTS
N_NEURONS
PARALLEL
```

including configurations where the number of inputs is not an exact multiple of the parallelism.

- [x] Exact-multiple sanity configs (32×8, 64×32)
- [x] Non-exact-multiple configs (30×8, 20×16)
- [x] Degenerate config, PARALLEL > N_INPUTS (4×8)
- [x] Sweep testbench: `sim/parameter_sweep_tb.v`

**Findings — FIXED (2026-09-02):**

- `neuron_parallel.v` computed `GROUPS = N_INPUTS / PARALLEL` with
  integer division. When `N_INPUTS` was **not** an exact multiple of
  `PARALLEL`, only the first `GROUPS * PARALLEL` inputs were ever
  read by the accumulator — the remainder was silently dropped (no
  error, no warning). Confirmed for 30×8 → only 24 of 30 inputs
  summed, and 20×16 → only 16 of 20 inputs summed.
- If `PARALLEL > N_INPUTS`, `GROUPS = 0` and the controller's
  `group_index == GROUPS-1` terminal condition was never satisfied:
  the neuron entered `busy` and never asserted `done` (confirmed
  hang, 500-cycle watchdog in the sweep bench).
- Both share the same root cause (`N_INPUTS % PARALLEL != 0`,
  degenerate `PARALLEL > N_INPUTS` included) and both are now
  rejected at **elaboration time**, in simulation and synthesis
  alike, by a `generate` guard added to `neuron_parallel.v`
  (instantiates a deliberately undefined module when the parameter
  combination is invalid — zero cost, zero behavior change for any
  valid configuration). The validated datapath itself
  (mac8/mac_unit/accumulation/ReLU/saturation) was **not** modified.
  See `sim/neuron_parallel_guard_negative_nonmultiple_tb.v` and
  `sim/neuron_parallel_guard_negative_degenerate_tb.v` for the
  negative-test proof, and `sim/parameter_sweep_tb.v` for the
  updated positive sweep (now valid-configs-only, including
  `PARALLEL=2` and `PARALLEL=4`, the two best-performing values from
  `docs/FPGA-Neural-Datapatch-Benchmark.md`).

## Phase 3 — Memory Architecture

Define:

- weight memory;
- bias memory;
- input buffers;
- output buffers;
- intermediate buffers;
- memory addressing;
- bandwidth requirements.

- [x] `neuron_memory.v`: single-neuron memory integration (N_NEURONS=1)
- [x] `neuron_memory.v`: multi-neuron memory integration (N_NEURONS>1)
- [ ] Intermediate/multi-layer buffers (deferred to Phase 5)
- [ ] Bandwidth analysis against PSRAM timing (deferred to Phase 7)

**Multi-neuron design (2026-09-02):** `neuron_memory.v` now takes an
`N_NEURONS` parameter and loops over neurons in memory: `X` is read
once (shared input vector), and for each neuron in turn `W` and
`bias` are re-read from PSRAM and fed to a single, reused
`neuron_parallel` instance — memory-bound by design, one neuron
computed at a time, no change to the validated compute datapath.
Addressing follows the same neuron-major convention as `layer.v`:
neuron `n`'s weights live at `w_base + n*N_INPUTS` bytes, its bias at
`bias_addr + n`. Output is now `y_bus` (packed, `DATA_WIDTH*N_NEURONS`
bits, neuron-major), replacing the old single-neuron `y` port.
Validated end to end through the full memory stack
(`memory_interface` + `psram_controller` + `psram_model`) in
`sim/neuron_memory_multi_tb.v` (N_NEURONS=3: scale, larger value,
ReLU). `sim/neuron_memory_tb.v` (N_NEURONS=1) still passes unchanged,
confirming backward compatibility.

## Phase 4 — SPI Interface

Implement:

- SPI controller;
- register map;
- RAM access;
- configuration protocol;
- input/output protocol;
- status and control.

## Phase 5 — Multi-Layer Network

Implement:

- multiple layers;
- intermediate buffers;
- layer sequencing;
- configurable activation functions.

## Phase 6 — Host Software

Develop host-side drivers for:

- Linux;
- ESP32.

The same FPGA protocol should be usable by both.

## Phase 7 — Optimization

Evaluate:

- pipeline depth;
- MAC parallelism;
- memory bandwidth;
- numerical precision;
- FPGA resource utilization;
- latency;
- throughput.

## Phase 8 — Optional Hardware Training

Investigate:

- backpropagation;
- gradient calculation;
- weight updates;
- hardware-assisted training.

---

# 16. Long-Term Vision

The final objective is to create a reusable hardware block that can be integrated into different future MIKILAB projects.

```text
                         APPLICATION
                              │
                ┌─────────────┴─────────────┐
                │                           │
             Linux                       ESP32
                │                           │
                └─────────────┬─────────────┘
                              │
                         SPI / Dual SPI
                              │
                              ▼
                 ┌────────────────────────┐
                 │          FPGA          │
                 │                        │
                 │ Neural Network Engine  │
                 │                        │
                 │ ┌────────────────────┐ │
                 │ │ Control            │ │
                 │ ├────────────────────┤ │
                 │ │ Input Interface    │ │
                 │ ├────────────────────┤ │
                 │ │ NN Compute Core    │ │
                 │ ├────────────────────┤ │
                 │ │ Activation         │ │
                 │ ├────────────────────┤ │
                 │ │ Output Interface   │ │
                 │ └────────────────────┘ │
                 │                        │
                 │ Dedicated RAM          │
                 │                        │
                 └────────────────────────┘
```

The host platform can change without changing the fundamental Neural Network Engine architecture.

The FPGA becomes a dedicated neural-computation peripheral, analogous to other hardware accelerators, but optimized specifically for the neural-network topology required by each application.

---

# 17. Current Status

| Component | Status |
|---|---|
| Parametric neuron layer | OK Working |
| Parametric input count |  OK |
| Parametric neuron count | OK |
| Parametric parallelism | OK |
| Accumulation | OK |
| Bias | OK |
| ReLU | OK |
| 32×4 / P=8 validation | OK |
| Dedicated RAM architecture | - Design |
| SPI interface | Planned |
| Dual SPI | Future |
| Multi-layer engine | Planned |
| Linux host driver | Planned |
| ESP32 host driver | Planned |
| Hardware training | Future |

---

## Core architectural principle

**The FPGA implements the neural-network machine.  
The FPGA owns its RAM.  
The host configures and uses the machine.  
The network topology is specialized at FPGA build time, while its trained parameters are loaded into FPGA-local memory at initialization.**

This separation is the foundation of the project.