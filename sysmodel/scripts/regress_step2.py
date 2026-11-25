"""Step 2 against step 1: with the interconnect, the array rows and the lanes switched off, sim2 must reproduce sim.

usage: python3 -I scripts/regress_step2.py
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from sysmodel import HW, PLAN, STATIC, ModelConfig, embedded_sample, mergecast, simulate, simulate2, teramonster

here = os.path.dirname(os.path.abspath(__file__))
sample = os.path.join(here, '..', '..', 'moe_study', 'model', 'overlap_embed.json')
model = ModelConfig()
worst = 0.0
t0 = time.time()
for system, Ms in ((teramonster().ideal(), (1, 64, 256, 1024)), (mergecast().ideal(), (1, 64))):
    for M in Ms:
        layers = embedded_sample(sample, M)
        for name, sc in (('hw', HW.but(min_block_cycles=1000.0)), ('hw mix', HW.but(order='mix', min_block_cycles=2000.0)),
                         ('plan', PLAN.but(min_block_cycles=5000.0)), ('static', STATIC)):
            a = simulate(system, model, sc, layers).per_layer
            b = simulate2(system, model, sc.but(mixer_spm=False), layers).per_layer
            worst = max(worst, abs(b / a - 1))
            print('%-11s M=%4d %-7s step1 %9.0f  step2 %9.0f  %+5.1f%%' % (system.name, M, name, a, b, 100 * (b / a - 1)))
print('worst deviation %.1f%%   (%.0f s)' % (100 * worst, time.time() - t0))
sys.exit(1 if worst > 0.06 else 0)   # the residual is the set-up delay of the extra mixer pieces (visible at M=1 with software delays)
