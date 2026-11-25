"""Workloads: MoE layers built from recorded routing."""
import base64
import json
import os
from dataclasses import dataclass

import numpy as np


@dataclass
class LayerRouting:
    """Routing of one MoE layer for M tokens: ids[t, j] is the j-th expert of token t."""
    ids: np.ndarray            # int, shape [M, k]
    experts: int

    @property
    def tokens(self):
        return self.ids.shape[0]

    def lists(self):
        """{expert: array of token indices}, only for experts that received a token."""
        m, k = self.ids.shape
        flat = self.ids.ravel()
        tok = np.repeat(np.arange(m), k)
        order = np.argsort(flat, kind='stable')
        flat, tok = flat[order], tok[order]
        cut = np.flatnonzero(np.diff(flat)) + 1
        return {int(e[0]): t for e, t in zip(np.split(flat, cut), np.split(tok, cut))}


class Trace:
    """A routing trace in the layout of HANDOVER_qwen36_traces.md: experts.npy [T, L, k] plus req_index.npy [T]."""

    def __init__(self, directory, experts):
        self.ex = np.load(directory + '/experts.npy', allow_pickle=False, mmap_mode='r')
        ri = np.load(directory + '/req_index.npy', allow_pickle=False)
        b = np.flatnonzero(np.diff(ri)) + 1
        self.requests = list(zip(np.r_[0, b].tolist(), np.r_[b, len(ri)].tolist()))
        self.experts = experts
        self.req_index = ri
        self.phase = np.load(directory + '/phase.npy', allow_pickle=False) if os.path.exists(directory + '/phase.npy') else None

    def window(self, start, tokens, layers=None, shared=0):
        """`tokens` consecutive tokens from position `start` of the trace: [LayerRouting per layer]. With `shared`,
        every token also goes to that many extra experts (ids after the routed ones)."""
        w = np.asarray(self.ex[start:start + tokens]).astype(np.int64)
        return self._layers(w, layers, shared)

    def rows(self, positions, layers=None, shared=0):
        """One batch from arbitrary token positions (for example one token from each of several requests)."""
        w = np.stack([np.asarray(self.ex[p]) for p in positions]).astype(np.int64)
        return self._layers(w, layers, shared)

    def _layers(self, w, layers, shared):
        out = []
        for l in (range(w.shape[1]) if layers is None else layers):
            ids = w[:, l, :]
            if shared:
                extra = np.tile(np.arange(self.experts, self.experts + shared), (ids.shape[0], 1))
                ids = np.concatenate([ids, extra], axis=1)
            out.append(LayerRouting(ids, self.experts + shared))
        return out

    def starts(self, tokens, n, seed=1, phase=0):
        """`n` window starts, each inside one request and one phase (0 prompt, 1 response), spread over requests."""
        rng = np.random.RandomState(seed)
        ok = []
        for a, z in self.requests:
            if self.phase is not None:
                idx = np.flatnonzero(self.phase[a:z] == phase)
                if len(idx) == 0:
                    continue
                a, z = a + int(idx[0]), a + int(idx[-1]) + 1
            if z - a >= tokens:
                ok.append((a, z))
        if not ok:
            raise ValueError('no request has %d tokens of phase %d' % (tokens, phase))
        pick = rng.permutation(len(ok))
        out = []
        for i in range(n):
            a, z = ok[pick[i % len(ok)]]
            out.append(int(a + rng.randint(z - a - tokens + 1)))
        return out

    def windows(self, tokens, layers, limit=10):
        """First `tokens` tokens of each request that is long enough: a list of [LayerRouting per layer]."""
        out = []
        for a, z in self.requests:
            if z - a < tokens:
                continue
            w = np.asarray(self.ex[a:a + tokens])
            out.append([LayerRouting(w[:, l, :].astype(np.int64), self.experts) for l in layers])
            if len(out) >= limit:
                break
        return out


def embedded_sample(path, tokens, offset=0, experts=512, k=10, full=1024):
    """The 1024-token, two-layer sample the artifact page embeds (model/overlap_embed.json)."""
    e = json.load(open(path))
    a = np.frombuffer(base64.b64decode(e['b64']), dtype='<i2').reshape(-1, full, k)
    return [LayerRouting(a[l, offset:offset + tokens].astype(np.int64), experts) for l in range(a.shape[0])]
