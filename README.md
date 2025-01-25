# Advanced-CPU-Optimization

This is an on going CPU architecture design group project that primarily focus on implementing modern state of the art optimization methods to speedup a simple baseline CPU architecture.
We will be implementing the below optimizations:
- Branch prediction
- Out-of-order execution
- Register Renaming
- Hardware prefetching

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

# Register Renaming

# Out of Order Execution

# Hardware Prefetching



