"""
cocotb testbench STUB for core_pe.sv — cf04 COPT Part B #2.

This is intentionally a harness, not a full verification suite. M2 will add:
  - randomized stimulus across the parameter range
  - co-simulation against a reference Python model
  - directed coverage points (en gating, input forwarding skew, sign edges)

Compatible with cocotb 2.0+.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


SETTLE = (1, "ns")


async def reset_dut(dut):
    """Synchronous active-high reset, deasserted before the next rising edge."""
    dut.rst.value = 1
    dut.en.value = 0
    dut.a_in.value = 0
    dut.b_in.value = 0
    await RisingEdge(dut.clk)   # samples rst=1 -> all regs <= 0
    await Timer(*SETTLE)
    dut.rst.value = 0


@cocotb.test()
async def test_pe_smoke(dut):
    """Smoke test: reset, one accumulation, confirm acc_out updated."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    # After reset, all registered outputs should be 0
    assert dut.acc_out.value.to_signed() == 0, "acc_out should be 0 after reset"
    assert dut.a_out.value.to_signed() == 0, "a_out should be 0 after reset"
    assert dut.b_out.value.to_signed() == 0, "b_out should be 0 after reset"
    dut._log.info("smoke: post-reset state OK (acc_out=0, a_out=0, b_out=0)")

    # One representative input: a=5, b=7, en=1
    # Expected after 1 cycle: acc_out = 5*7 = 35, a_out=5, b_out=7
    dut.a_in.value = 5
    dut.b_in.value = 7
    dut.en.value = 1
    await RisingEdge(dut.clk)
    await Timer(*SETTLE)

    acc = dut.acc_out.value.to_signed()
    a_fwd = dut.a_out.value.to_signed()
    b_fwd = dut.b_out.value.to_signed()
    dut._log.info(
        f"smoke: applied a=5 b=7 en=1 -> acc_out={acc}, a_out={a_fwd}, b_out={b_fwd}"
    )

    # Light assertion: the module is wired correctly enough that the values
    # propagate. Per the handout, complex correctness checking is M2's job.
    assert acc == 35, f"acc_out expected 35, got {acc}"
    assert a_fwd == 5, f"a_out expected 5 (forwarded), got {a_fwd}"
    assert b_fwd == 7, f"b_out expected 7 (forwarded), got {b_fwd}"
    dut._log.info("smoke: harness OK — module instantiated, reset works, "
                  "one input applied and observed at outputs")
