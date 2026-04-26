"""
cocotb testbench for `mac_correct.v` — cf04 COPT Part A.

Tests:
  test_mac_basic    — handout-specified stimulus (a=3,b=4 for 3 cycles, reset)
  test_mac_overflow — drives the accumulator past 2**31 - 1 and documents
                      whether the design saturates or wraps.

Compatible with cocotb 2.0+.

Note on edge timing
-------------------
mac_correct.v has a synchronous reset and no `initial` block, so `out` is X
at time 0 and only becomes 0 after the first rising edge with rst=1. After
each rising edge we insert a 1-ns Timer so the post-edge value of `out` has
fully propagated before the test code samples it.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


SETTLE = (1, "ns")  # post-edge settle so registered outputs are observable


async def reset_dut(dut):
    """Apply synchronous active-high reset for one cycle, leaving rst=0
    set BEFORE the next rising edge so the next edge samples rst=0."""
    dut.rst.value = 1
    dut.a.value = 0
    dut.b.value = 0
    await RisingEdge(dut.clk)   # samples rst=1 -> out <= 0
    await Timer(*SETTLE)
    dut.rst.value = 0           # deassert before the next edge


@cocotb.test()
async def test_mac_basic(dut):
    """Handout stimulus: a=3, b=4 for 3 cycles, then assert rst.

    Expects accumulator to reach 12, 24, 36 on successive edges, and 0 after rst.
    """
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    await reset_dut(dut)

    # Drive a=3, b=4 and check accumulation across 3 edges
    dut.a.value = 3
    dut.b.value = 4
    for expected in [12, 24, 36]:
        await RisingEdge(dut.clk)
        await Timer(*SETTLE)
        observed = dut.out.value.to_signed()
        assert observed == expected, (
            f"basic: expected out={expected}, got {observed} "
            f"(a={int(dut.a.value)}, b={int(dut.b.value)})"
        )
        dut._log.info(f"basic: a=3 b=4 -> out={observed}  (expected {expected}) OK")

    # Assert rst and confirm out clears to 0
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await Timer(*SETTLE)
    observed = dut.out.value.to_signed()
    assert observed == 0, f"basic: after rst, expected out=0, got {observed}"
    dut._log.info(f"basic: rst -> out={observed} OK")


@cocotb.test()
async def test_mac_overflow(dut):
    """Drive the accumulator past 2**31 - 1 and document the behavior.

    Strategy
    --------
    Max signed product per cycle is 127 * 127 = 16129. To reach the 32-bit
    signed max (2**31 - 1 = 2,147,483,647) takes ~133K accumulations.

    First we accumulate `(127, 127)` for as many cycles as fit cleanly below
    MAX_INT32, sanity-check the pre-overflow value, then drive one more
    cycle to push the result past the boundary and observe what happens.

    Expected outcome for mac_correct.v
    -----------------------------------
    The design uses plain `+` with no saturation logic, so it WRAPS in
    two's complement (becomes a large negative number).
    """
    MAX_INT32 = (1 << 31) - 1
    PROD = 127 * 127  # 16129, the max positive product per cycle

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    # Number of cycles of PROD to land just below MAX_INT32
    n_cycles = MAX_INT32 // PROD
    boundary_value = n_cycles * PROD

    dut._log.info(
        f"overflow: driving a=127 b=127 (product={PROD}) for "
        f"{n_cycles} cycles to approach MAX_INT32={MAX_INT32}"
    )

    dut.a.value = 127
    dut.b.value = 127
    for _ in range(n_cycles):
        await RisingEdge(dut.clk)
    await Timer(*SETTLE)

    observed_pre = dut.out.value.to_signed()
    dut._log.info(
        f"overflow: pre-overflow out={observed_pre} "
        f"(expected {boundary_value}, gap to MAX_INT32 = {MAX_INT32 - observed_pre})"
    )
    assert observed_pre == boundary_value, (
        f"overflow: pre-overflow check failed: "
        f"observed {observed_pre}, expected {boundary_value}"
    )

    # One more cycle: this addition crosses MAX_INT32. Two possible outcomes:
    #   - WRAP (two's complement): result = boundary + PROD - 2**32
    #   - SATURATE: result = MAX_INT32
    await RisingEdge(dut.clk)
    await Timer(*SETTLE)
    observed_post = dut.out.value.to_signed()

    wrapped_value = boundary_value + PROD - (1 << 32)
    saturated_value = MAX_INT32

    dut._log.info(
        f"overflow: pushed past boundary; out={observed_post} "
        f"(wrap would give {wrapped_value}, saturate would give {saturated_value})"
    )

    if observed_post == wrapped_value:
        behavior = "WRAP (two's complement)"
    elif observed_post == saturated_value:
        behavior = "SATURATE"
    else:
        raise AssertionError(
            f"overflow: out={observed_post} matches neither wrap "
            f"({wrapped_value}) nor saturate ({saturated_value})"
        )

    dut._log.info(f"overflow: documented behavior = {behavior}")

    # mac_correct.v has no saturation logic; expect WRAP.
    assert observed_post == wrapped_value, (
        f"overflow: expected wrap behavior (mac_correct.v has no saturation), "
        f"got post={observed_post} which doesn't match wrap={wrapped_value}"
    )
