#!/usr/bin/env python3
"""Generate vectors for tb_core_pe_chain — multi-block chained dot products.

For each test case:
  - Pick N_BLOCKS (1, 2, or 4)
  - Each block: 4 (a, b) FP16 pairs
  - Reference: chain-reduce using tree-reduce per block + sequential block accumulation
    expected = block_sum[0]
              + block_sum[1] + block_sum[2] + ... + block_sum[N-1]
    using the bit-exact fp32_add_ref order:
      tile_acc = block_sum[0]
      for n in 1..N-1: tile_acc = fp32_add(tile_acc, block_sum[n])
"""

import sys, random
sys.path.insert(0, '.')
sys.path.insert(0, '../m4_work')
from fp32_adder_ref import fp32_add_ref
from pe_vector_gen import (
    fp16_multiply, float_to_fp16, pe_tree_reduce
)


def chained_reduce(blocks_ab):
    """blocks_ab: list of [(a0,b0),...,(a3,b3)] per block. Returns FP32 bits."""
    block_sums = []
    for ab in blocks_ab:
        prods = [fp16_multiply(a, b) for (a, b) in ab]
        block_sums.append(pe_tree_reduce(prods))
    tile_acc = block_sums[0]
    for s in block_sums[1:]:
        tile_acc = fp32_add_ref(tile_acc, s)
    return tile_acc


def make_block(rng, scale=1.0):
    return [(float_to_fp16(rng.uniform(-scale, scale)),
             float_to_fp16(rng.uniform(-scale, scale))) for _ in range(4)]


def main():
    cases = []

    # Directed: single block (N=1) — same as v1 PE behavior
    cases.append({
        'nb': 1,
        'blocks': [[(float_to_fp16(1.0), float_to_fp16(1.0))]*4],
        'label': 'nb1_all_ones'
    })

    # Directed: N=2, simple
    cases.append({
        'nb': 2,
        'blocks': [
            [(float_to_fp16(1.0), float_to_fp16(1.0))]*4,
            [(float_to_fp16(1.0), float_to_fp16(1.0))]*4,
        ],
        'label': 'nb2_all_ones'
    })

    # Directed: N=4, all-ones
    cases.append({
        'nb': 4,
        'blocks': [[(float_to_fp16(1.0), float_to_fp16(1.0))]*4 for _ in range(4)],
        'label': 'nb4_all_ones'
    })

    # Directed: N=4, alternating sign so blocks cancel
    cases.append({
        'nb': 4,
        'blocks': [
            [(float_to_fp16(1.0),  float_to_fp16(1.0))]*4,
            [(float_to_fp16(1.0),  float_to_fp16(-1.0))]*4,
            [(float_to_fp16(1.0),  float_to_fp16(1.0))]*4,
            [(float_to_fp16(1.0),  float_to_fp16(-1.0))]*4,
        ],
        'label': 'nb4_cancel'
    })

    # Random — half nb=2, half nb=4
    rng = random.Random(42)
    for i in range(40):
        nb = 4
        blocks = [make_block(rng, scale=1.5) for _ in range(nb)]
        cases.append({'nb': nb, 'blocks': blocks, 'label': f'rand_nb4_{i}'})
    for i in range(20):
        nb = 2
        blocks = [make_block(rng, scale=1.5) for _ in range(nb)]
        cases.append({'nb': nb, 'blocks': blocks, 'label': f'rand_nb2_{i}'})
    for i in range(10):
        nb = 1
        blocks = [make_block(rng, scale=1.5) for _ in range(nb)]
        cases.append({'nb': nb, 'blocks': blocks, 'label': f'rand_nb1_{i}'})

    # Write vectors
    with open('pe_chain_vectors.mem', 'w') as f:
        for c in cases:
            nb = c['nb']
            expected = chained_reduce(c['blocks'])
            row = [str(nb)]
            for blk in c['blocks']:
                for (a, b) in blk:
                    row.append(f"{a:04x}")
                    row.append(f"{b:04x}")
            row.append(f"{expected:08x}")
            row.append(f"// {c['label']}")
            f.write(' '.join(row) + '\n')
    print(f"Wrote {len(cases)} chained PE test cases to pe_chain_vectors.mem")


if __name__ == '__main__':
    main()
