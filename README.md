# Advanced-CPU-Optimization

This is an on going CPU architecture design group project that primarily focus on implementing modern state of the art optimization methods to speedup a simple baseline CPU architecture.
We will be implementing the below optimizations:
- Branch prediction
- Register Renaming
- Out of Order execution
- Hardware prefetching

# Baseline

We are starting with a standard 5-stage pipelined baseline CPU with a basic static branch predictor.
![image](https://github.com/user-attachments/assets/92958813-c3e5-4a26-98b2-04022365c847)
Features

    Pipeline Stages: Implements a classical five-stage pipeline with hazard handling.
    Instruction & Data Caches: Includes I-Cache and D-Cache modules for efficient memory access.
    Hazard Handling:
        Data hazards: Managed via a forwarding unit.
        Control hazards: Mitigated with a branch predictor and a branch controller.
    AXI Memory Arbiter: Provides memory access management for the pipeline.
    Modular Design: The architecture is built using SystemVerilog, allowing flexibility in modifications and extensions.

Code Structure

    fetch_unit.sv - Fetch stage logic
    decoder.sv - Instruction decoding
    reg_file.sv - Register file implementation
    alu.sv - Arithmetic and logical operations
    forward_unit.sv - Data hazard forwarding
    hazard_controller.sv - Overall hazard management
    branch_controller.sv - Branch control logic
    glue_circuits.sv - Pipeline stage interconnections
    memory_arbiter.sv - AXI memory management



# Simulation

1.) oss-cad-suite https://github.com/YosysHQ/oss-cad-suite-build open-source binary release.
This package includes verilator and gtkwave which will be our simulator and waveviewer respectively.
Follow the installation in https://github.com/YosysHQ/oss-cad-suite-build#installation

# Synthesis

We use the Following Packages
1) FreePDK45 from NCSU
2) OpenRAM - Use the Binaries directly
3) OpenSTA - Need to build. Follow instructions in the repo
4) sv2v - Need to build. Follow instructions in the repo. (some binaries already available)
5) Python3.6+

The synthesis compiles system verilog design code into C code to make synthesis and execute.


# Branch Predictor

We have decided to make a neural network based perceptron branch predictor. Link to the paper reference: [perceptron](https://www.cs.utexas.edu/~lin/papers/hpca01.pdf).
We will combine our GShare predictor with our perceptron branch predictor for the best accuracy.

![image](https://github.com/user-attachments/assets/a88fff39-ef96-4a6d-b27d-6a73976f5192)

![image](https://github.com/user-attachments/assets/949eee24-9657-49f6-9703-cefa054b7aa6)

The Perceptron and the Gshare are both finished. Here is a screenshot of their accuracy:

![image](https://github.com/user-attachments/assets/af39a6a9-ef4d-49f6-bfc3-80da6c37e6da)







# Register Renaming

The register renaming optimization is a setup for Out of Order Execution. Each writes its own physical register; and you turn all false dependencies into just true RAW dependencies, enabling wide, speculation-driven out-of-order pipelines.

We implemented a very similar module as described in the MIPS R10000 Paper.

![image](https://github.com/user-attachments/assets/08b2c3e7-3301-4921-99dd-292728afd216)

![image](https://github.com/user-attachments/assets/ebead8e1-23b0-4016-b5b0-e7a66c4efb3f)


The register renaming will have its own pipeline stage on top of the baseline 5-stage pipeline.

It features an active list, a register map table, a free list, and a busy bit table.

# Out of Order Execution

The out-of-order execution is enabled by register renaming and will explore instruction-level parallelism to provide speedup to the CPU in executing instructions.

Our out-of-order execution features an instruction window of size 64, a register renaming module, a load and store queue, modifications to write back into the map table, as well as a recovery branch stack in case of false branch prediction rollback.

# Hardware Prefetching

We implemented a next-line Hardware Prefetcher along with a Stream Buffer.
![image](https://github.com/user-attachments/assets/d619eeec-c238-4fb5-b9d0-15bc34627fa6)

We changed the associativity of the instruction cache and saw a nearly 6 times performance increase on Nqueens.
![image](https://github.com/user-attachments/assets/bf1977cb-399c-4fc7-a8e2-8c8aa9d450e8)

We saw a performance improvement of 35%-45% with our next-line prefetcher due to its decently high hit chance.

