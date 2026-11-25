// usage: node fluid_ref.js <moe_study/model dir> <out.json>
// Reference values from the fluid layer-overlap model on the embedded 1024-token sample, for regress_fluid.py.
const path = require('path'), fs = require('fs');
const dir = path.resolve(process.argv[2]), { simLayers } = require(path.join(dir, 'overlap_model.js')), e = require(path.join(dir, 'overlap_embed.json'));
const b = Buffer.from(e.b64, 'base64'), a = new Int16Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.length));
const out = [];
for (const [cluster, u] of [['mergecast', 38400], ['teramonster', 4800]])
  for (const M of [1, 16, 64, 256, 1024]) {
    const W = { M, k: 10, E: 512, layers: [0, 1].map(l => a.subarray(l * 10240, l * 10240 + M * 10)) };
    const slots = Math.floor((64 - M * 15 / 1024) / 9.375);
    for (const order of ['hot', 'mix']) for (const overlap of [false, true]) for (const gap of [100, 1000]) {
      const r = simLayers(W, { G: 64, u, tx: 4800, gap, slots, rho: 0.9, phi: 0.6, win: 5, wout: 3, dt: 50, overlap, order, passMin: Math.max(1, Math.round(M / 4)) });
      out.push({ cluster, M, order, overlap, gap, per_layer: r.perLayer, bound: r.bound, stream_util: r.streamUtil, compute_util: r.compUtil, fetches: r.fetches, passes: r.passes });
    }
  }
fs.writeFileSync(process.argv[3], JSON.stringify(out));
console.log('wrote', out.length, 'reference points');
