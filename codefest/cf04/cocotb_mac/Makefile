# cocotb Makefile for mac_correct.v — cf04 COPT Part A
#
# Usage:
#   make            run simulation, produce sim_build/mac.fst
#   make dump.vcd   convert FST to VCD (handout asks for dump.vcd)
#   make wave       open dump.vcd in GTKWave
#   make clean      remove build artifacts

SIM            = icarus
TOPLEVEL_LANG  = verilog
VERILOG_SOURCES = $(PWD)/mac_correct.v
TOPLEVEL       = mac
MODULE         = test_mac

# SystemVerilog-2012; matches PSU's VCS flow when invoked with `-sverilog`.
COMPILE_ARGS  += -g2012

# Generate FST waveform automatically (cocotb-icarus default when WAVES=1).
WAVES         ?= 1

include $(shell cocotb-config --makefiles)/Makefile.sim

# Convert the FST cocotb produces into a VCD named `dump.vcd` per the handout.
dump.vcd: sim_build/mac.fst
	fst2vcd sim_build/mac.fst -o dump.vcd

sim_build/mac.fst: sim

wave: dump.vcd
	gtkwave dump.vcd
