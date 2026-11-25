"""Step 2: geometry of the group mesh and the two laws that turn "where the data is" and "how many tokens share a
weight" into the speed of a block.

Distance
  Groups sit on a k x k mesh. A piece of weights is interleaved over a *region*: an aligned square of 1, 4, 16 or
  all groups (the multiscale virtual clusters of the TeraMonster paper). The distance of a block is the mean
  Manhattan distance from the engine's group to the groups of the region that holds its weights.

Speed
  slow_factor(cls, system, n, h) = duration of a block / (its FLOP / nominal engine rate), for n tokens at h hops.
"""
import math


class Mesh:
    def __init__(self, side, region_groups):
        self.k = k = side
        self.G = G = k * k
        s = int(round(region_groups ** 0.5))
        if s * s != region_groups or k % s:
            raise ValueError('region_groups must be a square that tiles the %dx%d mesh' % (k, k))
        self.s, self.per_region = s, region_groups
        self.R = R = (k // s) ** 2
        xy = [(g % k, g // k) for g in range(G)]
        self.region_of = [(y // s) * (k // s) + (x // s) for x, y in xy]
        self.members = [[g for g in range(G) if self.region_of[g] == r] for r in range(R)]
        # mean hop distance from a group to the groups of a region
        self.hop = [[sum(abs(xy[g][0] - xy[m][0]) + abs(xy[g][1] - xy[m][1]) for m in self.members[r]) / region_groups
                     for r in range(R)] for g in range(G)]
        self.regions_near = [sorted(range(R), key=lambda r: (self.hop[g][r], r)) for g in range(G)]
        self.groups_near = [sorted(range(G), key=lambda g: (self.hop[g][r], g)) for r in range(R)]
        self.hop_inside = sum(self.hop[g][self.region_of[g]] for g in range(G)) / G


def slow_factor(cls, system, n, h):
    """How much longer a block takes than FLOP / nominal rate, on an engine of class `cls`, when `n` tokens share
    each weight and the operands are `h` hops away on average."""
    if cls.plane == 'ideal' and not cls.row_fill:
        return 1.0
    if cls.row_fill:
        # Systolic array: `rows` rows of multipliers all receive the same weight element. A block with fewer tokens
        # leaves rows empty; more tokens take several passes. The array pulls operands at a fixed rate, so the
        # interconnect is a plain utilisation factor.
        fill = n / float(cls.rows * math.ceil(n / float(cls.rows)))
        if cls.plane == 'ideal':
            return 1.0 / fill
        w = system.wide
        util = min(w.u_max, w.tensor_window_cycles / (w.lat0 + w.lat_hop * h))
        return 1.0 / (fill * util)
    # Vector unit: `mac` multiply-adds per cycle; in one pass over the weights it serves up to `rows` tokens.
    # Per weight element a pass needs max(tokens / mac, element bytes / delivered bytes per cycle) cycles.
    mac = cls.flop_per_cycle / 2.0
    share = 1
    if cls.plane == 'wide':
        w = system.wide
        delivered = w.window_bytes / (w.lat0 + w.lat_hop * h)
    else:
        w = system.word
        delivered = w.port_bytes if h * w.port_bytes <= w.reach else w.reach / h
        # with several full passes, up to `merge` cores of a group work on the same weights and share one read
        share = min(w.merge, max(1, n // cls.rows))
    wait = 2.0 * (1.0 + cls.need_overhead) / delivered
    q, r = divmod(n, cls.rows)
    t = q * max(cls.rows / mac, wait / share) + (max(r / mac, wait) if r else 0.0)
    return t / (n / mac)
