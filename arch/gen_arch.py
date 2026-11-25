#!/usr/bin/env python3
"""Generate the draw.io architecture figure of the CPU + cluster design.

usage: python3 -I gen_arch.py teranoc_ooo_arch.drawio
       drawio -x -f png -e -o teranoc_ooo_arch.drawio.png teranoc_ooo_arch.drawio      (optional preview)

Style follows the reference figures in tmp/arch_ref: Helvetica, black outlines, the TeraNoC / MergeCast palette
(blue SPM, green crossbars and routers, teal routing, red PEs, orange for what is new), and the Zen 6 block diagram
(large tinted regions, entry counts in every block, labelled flow arrows).
"""
import sys
from xml.sax.saxutils import escape

DOMAIN = 'scheduling domain'        # the logical unit served by one CPU task port (earlier called "FU group")
FONT, INK = 'Helvetica', '#111111'
C = dict(spm='#1169B0', xbar='#009900', route='#009797', pe='#A8322C', pe2='#C86460', new='#F29545', new_bg='#FFF1DF', new_dk='#BA5D0D',
         grp='#E6E6E6', tile='#FEFFF9', zoom='#7754A3', zoom_bg='#F1EBF8', l2='#910569', flow='#9A9AE5', gray='#CFCFCF',
         fe='#FFF6D5', ee='#DFF5E4', mem='#E9DDF8', cl='#EEF1F5', white='#FFFFFF', cream='#FEFFF9')
cells, _n = [], [0]


def _id(tag):
    _n[0] += 1
    return '%03d-%s' % (_n[0], tag)


def box(x, y, w, h, text='', fill='#FFFFFF', stroke=INK, sw=1.25, fs=13, bold=False, italic=False, fc=INK, arc=4, align='center',
        valign='middle', dashed=None, tag='box', rot=0, pad=3):
    st = ('rounded=%d;arcSize=%s;absoluteArcSize=1;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;strokeWidth=%s;fontFamily=%s;fontSize=%s;'
          'fontColor=%s;fontStyle=%d;align=%s;verticalAlign=%s;spacing=0;spacingLeft=%d;spacingRight=%d;shadow=0;' % (
              1 if arc else 0, arc, fill, stroke, sw, FONT, fs, fc, (1 if bold else 0) + (2 if italic else 0), align, valign, pad, pad))
    if dashed:
        st += 'dashed=1;dashPattern=%s;' % dashed
    if rot:
        st += 'rotation=%d;' % rot
    cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1"><mxGeometry x="%s" y="%s" width="%s" height="%s" as="geometry"/></mxCell>' % (
        _id(tag), escape(text, {'"': '&quot;'}), st, x, y, w, h))


def text(x, y, w, h, s, fs=13, bold=False, italic=False, align='left', fc=INK, valign='middle', tag='label'):
    box(x, y, w, h, s, fill='none', stroke='none', fs=fs, bold=bold, italic=italic, fc=fc, arc=0, align=align, valign=valign, tag=tag, pad=2)


def vbox(x, y, w, h, s, **kw):
    """A tall box whose text reads top to bottom."""
    box(x + w / 2.0 - h / 2.0, y + h / 2.0 - w / 2.0, h, w, s, rot=90, **kw)


def rtext(cx, cy, length, s, fs=12, fc=INK, bold=False, rot=-90, tag='label'):
    """A text label rotated about its centre (reads bottom to top for -90)."""
    box(cx - length / 2.0, cy - 10, length, 20, s, fill='none', stroke='none', fs=fs, fc=fc, bold=bold, arc=0, rot=rot, tag=tag, pad=0)


def ellipse(x, y, d, s='', fill='#FFFFFF', stroke=INK, fs=10, fc=INK, sw=1.0, tag='dot'):
    st = ('ellipse;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;strokeWidth=%s;fontFamily=%s;fontSize=%s;fontColor=%s;fontStyle=1;'
          'align=center;verticalAlign=middle;spacing=0;' % (fill, stroke, sw, FONT, fs, fc))
    cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1"><mxGeometry x="%s" y="%s" width="%s" height="%s" as="geometry"/></mxCell>' % (
        _id(tag), escape(s), st, x, y, d, d))


def edge(pts, color=INK, sw=1.4, end='block', start='none', dashed=None, size=None, tag='path', jump=False):
    if size is None:
        size = 5 if sw < 3 else 2.2
    st = 'html=1;rounded=0;strokeColor=%s;strokeWidth=%s;endArrow=%s;endFill=1;startArrow=%s;startFill=1;endSize=%s;startSize=%s;' % (color, sw, end, start, size, size)
    if dashed:
        st += 'dashed=1;dashPattern=%s;' % dashed
    if jump:
        st += 'jumpStyle=arc;jumpSize=10;'
    mid = ''.join('<mxPoint x="%s" y="%s"/>' % p for p in pts[1:-1])
    cells.append('<mxCell id="%s" style="%s" edge="1" parent="1"><mxGeometry relative="1" as="geometry"><mxPoint x="%s" y="%s" as="sourcePoint"/>'
                 '<mxPoint x="%s" y="%s" as="targetPoint"/>%s</mxGeometry></mxCell>' % (
                     _id(tag), st, pts[0][0], pts[0][1], pts[-1][0], pts[-1][1], ('<Array as="points">%s</Array>' % mid) if mid else ''))


def line(pts, color=INK, sw=1.0, dashed=None, tag='line'):
    edge(pts, color=color, sw=sw, end='none', dashed=dashed, tag=tag)


def flow(pts, **kw):
    edge(pts, color=kw.pop('color', C['flow']), sw=kw.pop('sw', 5), **kw)


def cpu(x, y, w, h, s, **kw):          # an existing block of the host CPU
    box(x, y, w, h, s, fill=C['white'], **kw)


def new(x, y, w, h, s, **kw):          # a block that is new in this design
    box(x, y, w, h, s, fill=C['new'], sw=kw.pop('sw', 1.6), **kw)


def fu(x, y, w, h, s):                 # a functional unit of the host CPU
    box(x, y, w, h, s, fill=C['pe2'], fc='#FFFFFF', fs=12, sw=1.0, arc=3)


W, H = 2400, 1500
box(0, 0, W, H, fill='#FFFFFF', stroke='none', arc=0, tag='white-canvas')

# ------------------------------------------------------------------ header and legend
text(20, 8, 1440, 44, 'TeraNoC-OoO · an out-of-order host CPU schedules a shared-L1 compute cluster', fs=26, bold=True, tag='title')
box(1480, 12, 26, 18, fill=C['white'])
text(1512, 8, 190, 26, 'Host CPU, C910-class')
box(1710, 12, 26, 18, fill=C['grp'])
text(1742, 8, 420, 26, 'Compute cluster: TeraNoC, MergeCast, TeraMonster')
box(1480, 38, 26, 18, fill=C['new'], sw=1.6)
text(1512, 34, 190, 26, 'New in this design')
text(1710, 34, 680, 26, 'Orange blocks carry the sizes of RTL version 1 · italic numbers come from the system model', italic=True)

# ------------------------------------------------------------------ regions
box(20, 66, 990, 470, fill=C['fe'], stroke='none', arc=0, tag='region-front-end')
box(20, 546, 990, 620, fill=C['ee'], stroke='none', arc=0, tag='region-execution')
box(1090, 66, 1290, 1100, fill=C['cl'], stroke='none', arc=0, tag='region-cluster')
box(20, 1176, 2360, 304, fill=C['mem'], stroke='none', arc=0, tag='region-memory')
text(36, 486, 330, 40, 'Front End', fs=24, bold=True)
text(36, 1112, 330, 40, 'Execution Engine', fs=24, bold=True)
text(2050, 70, 320, 36, 'Compute Cluster', fs=24, bold=True, align='right')
text(36, 1430, 360, 40, 'Memory Subsystem', fs=24, bold=True)

# ------------------------------------------------------------------ front end (C910-class; sizes from the reference figure)
box(40, 86, 200, 262, fill=C['cream'], tag='bp')
text(40, 88, 200, 26, 'Branch Predictor', bold=True, align='center')
for i, s in enumerate(('L0 BTB · 16 entry', 'BHT · 32K entry', 'L1 BTB · 4K entry', 'Indirect BTB · 256 entry', 'RAS · 12 entry')):
    cpu(52, 118 + i * 44, 176, 36, s)
cpu(40, 366, 200, 40, 'PC Gen')
cpu(290, 86, 330, 48, 'L1 Instruction Cache · 64 KB 2-way')
cpu(630, 86, 150, 48, 'ITLB · 32 entry')
cpu(790, 86, 200, 48, 'L2 TLB · 256 entry 4-way · PTW')
cpu(290, 172, 150, 40, 'Pre-decode')
cpu(460, 172, 170, 40, 'Inst Buffer · 32 entry')
cpu(650, 172, 170, 40, 'Loop Buffer · 16 entry')
box(290, 250, 470, 82, fill=C['cream'], tag='decode')
text(290, 252, 470, 26, '3-Way Decode', bold=True, align='center')
for i in range(3):
    cpu(302 + i * 150, 284, 146, 36, 'Decoder %d' % i)
new(780, 250, 210, 82, '<b>Task Decode</b><br>TLoad · TRun · TJoin · TFree')
box(290, 372, 700, 84, fill=C['cream'], tag='rename')
text(290, 374, 700, 26, 'Rename / Dispatch', bold=True, align='center')
cpu(302, 406, 160, 40, 'Int Reg Rename')
cpu(472, 406, 160, 40, 'FP Reg Rename')
new(642, 402, 172, 48, '<b>Handle Rename</b><br><font style="font-size:11px">32 names → 256 handles</font>')
cpu(824, 406, 154, 40, 'Dispatch')
flow([(140, 348), (140, 366)])
flow([(240, 386), (265, 386), (265, 110), (290, 110)])
flow([(365, 134), (365, 172)])
text(374, 138, 150, 30, '128-bit line', fs=12)
flow([(440, 192), (460, 192)])
flow([(545, 212), (545, 250)])
text(554, 216, 80, 30, '3 inst', fs=12)
flow([(735, 212), (735, 250)])
flow([(525, 332), (525, 372)])
text(534, 336, 80, 30, '3 inst', fs=12)
flow([(885, 332), (885, 372)], color=C['new_dk'])
text(894, 336, 110, 30, '1 task instr.', fs=12)
flow([(525, 456), (525, 580)])
text(534, 496, 90, 30, '4 µop', fs=12)
flow([(727, 450), (727, 520), (845, 520), (845, 580)], color=C['new_dk'])
text(854, 496, 150, 40, 'physical<br>handles', fs=12)

# ------------------------------------------------------------------ execution engine
cpu(40, 580, 640, 46, 'Reorder Buffer · 64 entry')
new(690, 580, 305, 46, '<b>Task Window</b> · 256 entry · program order<br><font style="font-size:11px">a TJoin completes when it is the oldest task</font>')
iq = [('AIQ0', 'int'), ('AIQ1', 'int'), ('BIQ', 'branch'), ('LSIQ', 'load / store'), ('SDIQ', 'store data'), ('FIQ0', 'FP / vector'), ('FIQ1', 'FP / vector')]
for i, (a, b) in enumerate(iq):
    x = 40 + i * 100
    cpu(x, 668, 92, 46, '%s<br><font style="font-size:11px">%s</font>' % (a, b))
    flow([(x + 46, 626), (x + 46, 668)], sw=4)
    flow([(x + 46, 714), (x + 46, 756)], sw=4)
SMALL = '<br><font style="font-size:11px">%s</font>'
new(750, 668, 245, 50, '<b>Run Issue Queue</b> · 32 entry' + SMALL % 'ready: data placed · order handle done · credit<br>oldest ready task first, one per cycle')
flow([(872, 626), (872, 668)], sw=4, color=C['new_dk'])
cpu(40, 756, 492, 46, 'Integer Register File · 96 entry')
cpu(540, 756, 192, 46, 'FP / Vector Register File · 64 entry')
new(750, 726, 245, 50, '<b>Load Queue</b> · 16 entry · program order' + SMALL % 'placement: the domain with the least work<br>that has idle DMA engines and a free slot')
new(750, 784, 245, 54, '<b>Handle File</b> · 256 entry' + SMALL % 'placed · done · domain · slot · user count<br>frees handle and slot at the last user')
fus = [['ALU0', 'DIV'], ['ALU1', 'MUL'], ['Branch'], ['Load AGU'], ['Store AGU', 'Store Data'], ['FALU0', 'FDSU', 'FMAU0'], ['FALU1', 'FMAU1']]
for i, col in enumerate(fus):
    x = 40 + i * 100
    flow([(x + 46, 802), (x + 46, 844)], sw=4)
    for j, s in enumerate(col):
        fu(x, 844 + j * 32, 92, 28, s)
new(750, 846, 245, 58, '<b>Resource Counters</b>' + SMALL % 'per domain: 4 task credits, free slots,<br>DMA busy · cluster: 32 lanes, 4 per load')
new(750, 912, 245, 38, '<b>Completion Arbiter</b>' + SMALL % '16 domains and TJoin · one per cycle')
box(750, 958, 245, 32, '<b>16 task ports</b> · one per domain', fill=C['new_dk'], fc='#FFFFFF', sw=1.0)
new(556, 950, 184, 94, '<b>Balancer</b>' + SMALL % 'moves single blocks from a domain with waiting blocks to a domain with idle PEs, at most 2 steps apart; one move per cycle')
edge([(740, 974), (750, 974)], color=C['new_dk'], sw=2.2, size=3)
box(750, 998, 245, 32, '<b>16 load ports</b> · one per domain', fill=C['new_dk'], fc='#FFFFFF', sw=1.0)
box(40, 960, 500, 92, fill=C['cream'], tag='lsu')
text(40, 962, 500, 26, 'Load Store Unit', bold=True, align='center')
cpu(52, 994, 236, 46, 'Load Queue · 16 entry')
cpu(296, 994, 232, 46, 'Store Queue · 12 entry')
box(560, 1054, 435, 106, fill=C['new_bg'], stroke=C['new_dk'], sw=1.6, arc=6, tag='task-isa')
text(572, 1056, 420, 22, 'Task instructions · decoded form; the encoding is open', bold=True, fs=12.5)
text(572, 1078, 420, 20, '<b>TLoad</b> hd, len, addr · copy a tile from L2 into a free L1 slot', fs=12)
text(572, 1097, 420, 20, '<b>TRun</b> hd, hs1, hs2, cls, nblk, kern · blocks on data hs1, after hs2', fs=12)
text(572, 1116, 420, 20, '<b>TJoin</b> hd · done when every older task is done', fs=12)
text(572, 1135, 420, 20, '<b>TFree</b> hs1 · release the data and its slot', fs=12)
flow([(386, 872), (386, 960)], sw=4)
flow([(486, 904), (486, 960)], sw=4)
flow([(290, 1052), (290, 1210)], sw=5, start='block')

# ------------------------------------------------------------------ CPU <-> cluster
edge([(1108, 300), (1022, 300), (1022, 931), (995, 931)], color=C['new_dk'], sw=2.2, dashed='6 4')
rtext(1009, 610, 330, 'done · a task, a load or a moved block · one per cycle', fs=12, tag='label-done')
flow([(995, 974), (1050, 974), (1050, 360), (1108, 360)], color=C['new_dk'], sw=6)
rtext(1037, 670, 470, 'TRun · kernel, blocks, slot · and the balancer: give commands, moved blocks', fs=12, tag='label-task')
flow([(995, 1014), (1082, 1014), (1082, 440), (1108, 440)], color=C['new_dk'], sw=6)
rtext(1069, 730, 470, 'TLoad · L2 address, length, L1 slot · four DMA engines copy one tile', fs=12, tag='label-load')

# ------------------------------------------------------------------ (a) cluster overview
text(1110, 74, 620, 30, '(a) Compute cluster · 8 × 8 groups · 16 %ss' % DOMAIN, fs=18, bold=True)
text(1110, 102, 500, 44, 'A domain: one task port, one load port, one domain scheduler.<br>No links between domains: work moves through the CPU. Any PE reads any domain.', fs=12.5, valign='top')
GX, GY, P, G = 1152, 180, 54, 36
box(1108, 174, 20, 426, fill=C['new_dk'], stroke=C['new_dk'], arc=3, tag='task-port-bus')
rtext(1118, 387, 420, '16 task ports and 16 load ports · one pair per domain scheduler', fs=11.5, fc='#FFFFFF', bold=True)
for j in range(8):
    line([(GX, GY + j * P + G / 2.0), (GX + 7 * P + G, GY + j * P + G / 2.0)], color=C['xbar'], sw=2.4, tag='mesh')
    line([(GX + j * P + G / 2.0, GY), (GX + j * P + G / 2.0, GY + 7 * P + G)], color=C['xbar'], sw=2.4, tag='mesh')
for b in range(4):
    for a in range(4):
        hi = (a, b) == (3, 0)
        box(GX + 2 * a * P - 7, GY + 2 * b * P - 7, P + G + 14, P + G + 14, fill=C['zoom_bg'] if hi else 'none', stroke=C['zoom'] if hi else C['new_dk'],
            sw=2.5 if hi else 1.6, arc=6, dashed=None if hi else '4 3', tag='domain-%d-%d' % (a, b))
for j in range(8):
    for i in range(8):
        hi = (i, j) == (0, 7)
        box(GX + i * P, GY + j * P, G, G, fill='#FFE2C4' if hi else C['grp'], stroke=C['new_dk'] if hi else INK, sw=2.2 if hi else 1.1, arc=3, tag='group-%d-%d' % (i, j))
for b in range(4):
    for a in range(4):
        ellipse(GX + 2 * a * P + P / 2.0 + G / 2.0 - 9, GY + 2 * b * P + P / 2.0 + G / 2.0 - 9, 18, 'S', fill=C['new'], fs=10, tag='ds-%d-%d' % (a, b))
ly = 622
box(1230, ly + 3, 16, 16, fill=C['grp'], sw=1.0, arc=3)
text(1252, ly - 2, 60, 26, 'group', fs=12)
line([(1306, ly + 11), (1334, ly + 11)], color=C['xbar'], sw=2.4)
text(1340, ly - 2, 70, 26, 'mesh NoC', fs=12)
box(1414, ly + 3, 16, 16, fill='none', stroke=C['new_dk'], sw=1.6, arc=3, dashed='4 3')
text(1436, ly - 2, 60, 26, 'domain', fs=12)
ellipse(1490, ly + 2, 18, 'S', fill=C['new'], fs=10)
text(1514, ly - 2, 110, 26, 'domain scheduler', fs=12)

# ------------------------------------------------------------------ (b) one scheduling domain
BX, BY, BW, BH = 1622, 116, 738, 500
line([(GX + 7 * P + G + 7, GY - 7), (BX, BY)], color=C['zoom'], sw=1.4, dashed='3 3', tag='zoom')
line([(GX + 7 * P + G + 7, GY + P + G + 7), (BX, BY + BH)], color=C['zoom'], sw=1.4, dashed='3 3', tag='zoom')
box(BX, BY, BW, BH, fill=C['zoom_bg'], stroke=C['zoom'], sw=2.5, arc=8, tag='domain-zoom')
text(BX + 12, BY + 6, 700, 30, '(b) One %s · 2 × 2 groups and a domain scheduler' % DOMAIN, fs=18, bold=True)
box(BX + 14, BY + 44, 432, 442, fill=C['new_bg'], stroke=C['new_dk'], sw=1.8, arc=6, tag='domain-scheduler')
text(BX + 14, BY + 46, 432, 28, 'Domain Scheduler', bold=True, fs=15, align='center')
rows = [(36, '<b>Task table</b> · 4 tasks · kernel, blocks, PE types, slot'),
        (46, '<b>Load unit</b> · one tile at a time · starts the 4 DMA engines' + SMALL % '8 chunks per engine · progress = chunks all four have finished'),
        (46, '<b>Block counters</b> per task · handed out, eligible, running' + SMALL % 'a task that follows a stream gets blocks as its tile arrives'),
        (46, '<b>Block decision</b> · one block per cycle · oldest task first' + SMALL % '1. give command &nbsp;2. received block &nbsp;3. idle PE &nbsp;4. next block'),
        (36, '<b>Block read</b> · second stage: the fields of the block'),
        (46, '<b>Give and take</b> · on command of the cluster level' + SMALL % 'reports idle PEs and spare blocks · gives one block per command'),
        (36, '<b>Done</b> → completion of a task or a load to the cluster level')]
ry = BY + 80
ry_disp = ry_lend = 0
for k, (h, s) in enumerate(rows):
    box(BX + 26, ry, 408, h, s, fill=C['cream'])
    if k == 4:
        ry_disp = ry + h / 2.0
    if k == 5:
        ry_lend = ry + h / 2.0
    if k < len(rows) - 1:
        edge([(BX + 230, ry + h), (BX + 230, ry + h + 10)], sw=1.4, size=3.5)
    ry += h + 10
text(BX + 26, ry - 4, 408, 40, 'Decision and block read are two register stages. A block received from another domain runs before own blocks; its PE reads the weights from that domain.', fs=11.5, valign='top')
QX, QY, QS, QG = BX + 478, BY + 60, 112, 16
for j in range(2):
    line([(QX - 14, QY + j * (QS + QG) + QS / 2.0), (QX + 2 * QS + QG + 14, QY + j * (QS + QG) + QS / 2.0)], color=C['xbar'], sw=3)
    line([(QX + j * (QS + QG) + QS / 2.0, QY - 12), (QX + j * (QS + QG) + QS / 2.0, QY + 2 * QS + QG + 14)], color=C['xbar'], sw=3)
for j in range(2):
    for i in range(2):
        x, y = QX + i * (QS + QG), QY + j * (QS + QG)
        box(x, y, QS, QS, fill=C['grp'], sw=1.4, arc=4, tag='zoom-group')
        text(x + 4, y + 2, 70, 18, 'Group', fs=11, bold=True)
        for t in range(4):
            box(x + 8 + t * 25, y + 22, 21, 21, fill=C['pe'], sw=0.7, arc=2)
        for t in range(12):
            box(x + 8 + (t % 6) * 16.5, y + 48 + (t // 6) * 13, 13, 10, fill=C['pe2'], sw=0.6, arc=1)
        box(x + 8, y + 78, 96, 12, fill=C['spm'], sw=0.7, arc=1)
        box(x + 8, y + 94, 46, 12, fill=C['new'], sw=0.9, arc=1)
        box(x + 58, y + 94, 46, 12, fill=C['route'], sw=0.7, arc=1)
gy2 = QY + 2 * QS + QG + 22
box(QX, gy2 + 4, 16, 16, fill=C['pe'], sw=0.7, arc=2)
text(QX + 22, gy2 - 1, 220, 26, 'tensor engine · 16 per domain', fs=12)
box(QX, gy2 + 28, 16, 12, fill=C['pe2'], sw=0.6, arc=1)
text(QX + 22, gy2 + 21, 220, 26, 'vector unit · 48 per domain', fs=12)
box(QX, gy2 + 50, 16, 12, fill=C['spm'], sw=0.7, arc=1)
text(QX + 22, gy2 + 43, 220, 26, 'L1 SPM banks · 4 MiB per domain', fs=12)
box(QX, gy2 + 72, 16, 12, fill=C['route'], sw=0.7, arc=1)
text(QX + 22, gy2 + 65, 220, 26, 'DMA engine · 1 per group', fs=12)
box(QX, gy2 + 94, 16, 12, fill=C['new'], sw=0.9, arc=1)
text(QX + 22, gy2 + 87, 240, 26, 'group dispatcher · starts the PEs', fs=12)
text(QX - 6, gy2 + 114, 262, 56, 'L1 is fully shared: the mesh continues across the domain border and any PE reads any L1 slot, further away is slower.', fs=11.5, valign='top')
edge([(BX + 434, ry_disp), (QX - 24, ry_disp), (QX - 24, QY + QS + QG + 100), (QX + 8, QY + QS + QG + 100)], color=C['new_dk'], sw=3, size=3)

# ------------------------------------------------------------------ (c) one group
CX, CY, CW, CH = 1104, 660, 640, 492
line([(GX, GY + 7 * P + G), (CX + 8, CY)], color=C['new_dk'], sw=1.4, dashed='3 3', tag='zoom')
line([(GX + G, GY + 7 * P + G), (CX + 120, CY)], color=C['new_dk'], sw=1.4, dashed='3 3', tag='zoom')
box(CX, CY, CW, CH, fill='#FFF8EE', stroke=C['new_dk'], sw=2.5, arc=8, tag='group-zoom')
text(CX + 12, CY + 6, 600, 30, '(c) One group · 4 tiles · per tile 1 core with the tensor engine, 3 cores with a vector unit', fs=18, bold=True)
TW, TH = 252, 148
for t in range(4):
    x, y = CX + 14 + (t % 2) * (TW + 10), CY + 44 + (t // 2) * (TH + 44)
    box(x, y, TW, TH, fill=C['tile'], sw=1.8, arc=6, tag='tile')
    text(x + 8, y + 2, 100, 22, 'Tile %d' % t, bold=True)
    box(x + 8, y + 26, 104, 56, '<b>Tensor engine</b><br><font style="font-size:11px">8 × 32 array<br>256 MAC/cycle</font>', fill=C['pe'], fc='#FFFFFF', sw=1.0, fs=12.5, arc=3)
    for v in range(3):
        box(x + 118, y + 26 + v * 19.5, 126, 17, 'Vector unit · 8 MAC/cycle', fill=C['pe2'], fc='#FFFFFF', sw=0.8, fs=10, arc=2, pad=0)
    box(x + 8, y + 90, 236, 24, 'L1 SPM banks · 16 × 32-bit', fill=C['spm'], fc='#FFFFFF', sw=1.0, fs=12, arc=2)
    box(x + 8, y + 119, 236, 22, 'Intra-tile crossbar', fill=C['xbar'], fc='#FFFFFF', sw=1.0, fs=12, arc=3, italic=True, bold=True)
box(CX + 14, CY + 44 + TH + 8, 2 * TW + 10, 28, 'Intra-Group Crossbar', fill=C['xbar'], fc='#FFFFFF', sw=2.0, fs=14, bold=True, italic=True, arc=6)
vbox(CX + 538, CY + 44, 40, 2 * TH + 44, 'Router-to-tile crossbar', fill=C['route'], fc='#FFFFFF', sw=1.6, fs=13, bold=True, arc=6)
vbox(CX + 586, CY + 44, 40, 2 * TH + 44, 'Mesh routers · burst plane 512-bit · word plane 32-bit', fill=C['xbar'], fc='#FFFFFF', sw=1.6, fs=12, bold=True, arc=6)
by = CY + 44 + 2 * TH + 44 + 12
new(CX + 14, by, 300, 52, '<b>Group Dispatcher</b><br><font style="font-size:11px">one next-block register per PE type · wakes the core of the first idle PE</font>')
box(CX + 324, by, 150, 52, '<b>DMA engine</b><br><font style="font-size:11px">1 stream lane, 64 B/cycle</font>', fill=C['route'], fc='#FFFFFF', sw=1.2, arc=4)
box(CX + 484, by, 142, 52, '1 MiB of the shared L1 SPM', fill=C['spm'], fc='#FFFFFF', sw=1.2, arc=4, fs=12.5)

# ------------------------------------------------------------------ (d) life of a task
DX, DY, DW, DH = 1760, 660, 600, 492
box(DX, DY, DW, DH, fill='#FAFAFA', sw=1.8, arc=8, tag='life')
text(DX + 12, DY + 6, 590, 30, '(d) Life of a task · who decides, and how fast', fs=18, bold=True)
stages = [('Decode', 'cpu', 'TLoad, TRun, TJoin and TFree are recognised (host CPU, not in RTL yet)', '3-wide'),
          ('Rename', 'new', 'handle name → physical handle; map stage, then dispatch stage', '1 per cycle'),
          ('Window', 'new', 'entry in program order; a TJoin completes at the head', '256 entry'),
          ('Issue', 'new', 'load: the domain with the least work; run: the domain of its data', '1 load + 1 run'),
          ('Hand-over', 'new', 'registered link to the domain scheduler; credits, no ready wire', '2 stages'),
          ('Cut', 'dom', 'task → blocks by counters; follows the tile as it arrives', '≤ 1,023 blocks'),
          ('Dispatch', 'dom', 'one block per cycle to a group; an idle PE starts in the next cycle', '2 stages'),
          ('Run', 'pe', 'a PE is a core: it reads the block from a register of its tile, runs the kernel, writes done', '<i>10³–10⁵ cycles</i>'),
          ('Done', 'new', 'one completion per cycle; the slot is freed at its last user', '')]
fillc = dict(cpu=C['white'], new=C['new'], dom=C['new_bg'], pe=C['pe2'])
for k, (name, kind, what, rate) in enumerate(stages):
    y = DY + 46 + k * 44
    box(DX + 14, y, 112, 34, '<b>%s</b>' % name, fill=fillc[kind], fc='#FFFFFF' if kind == 'pe' else INK, sw=1.6 if kind in ('new', 'dom') else 1.25,
        stroke=C['new_dk'] if kind == 'dom' else INK)
    text(DX + 134, y - 2, 334, 38, what, fs=12.5)
    text(DX + 468, y - 2, 122, 38, rate, fs=12.5, align='right')
    if k < len(stages) - 1:
        edge([(DX + 70, y + 34), (DX + 70, y + 44)], sw=1.4, size=3.5)
ky = DY + 46 + len(stages) * 44 + 2
box(DX + 14, ky + 8, 16, 14, fill=C['white'])
text(DX + 34, ky + 2, 70, 26, 'host CPU', fs=11.5)
box(DX + 112, ky + 8, 16, 14, fill=C['new'], sw=1.6)
text(DX + 132, ky + 2, 110, 26, 'CPU, new logic', fs=11.5)
box(DX + 246, ky + 8, 16, 14, fill=C['new_bg'], stroke=C['new_dk'], sw=1.6)
text(DX + 266, ky + 2, 130, 26, 'domain scheduler', fs=11.5)
box(DX + 400, ky + 8, 16, 14, fill=C['pe2'])
text(DX + 420, ky + 2, 60, 26, 'PE', fs=11.5)

# ------------------------------------------------------------------ memory subsystem
cpu(40, 1210, 330, 60, 'L1 Data Cache · 64 KB 2-way')
cpu(380, 1210, 160, 60, 'DTLB · 17 entry')
cpu(40, 1300, 500, 60, 'L2 Cache (host) · program, kernels’ descriptors, routing tables')
flow([(290, 1270), (290, 1300)], sw=5, start='block')
box(1104, 1210, 1256, 60, '<b>Shared L1 SPM</b> · 64 MiB · every PE reads every word · activations spread over all groups · a weight tile in an L1 slot, spread over one domain', fill=C['spm'], fc='#FFFFFF', sw=1.6, fs=15, arc=6)
flow([(1424, 1152), (1424, 1210)], color=C['spm'], sw=6, start='block')
text(1436, 1164, 420, 40, 'the SPM banks of all 64 groups', fs=12.5)
box(1104, 1330, 400, 52, '<b>DMA engines</b> · 64 · one per group<br><font style="font-size:12px">started by the load unit of their domain scheduler</font>', fill=C['route'], fc='#FFFFFF', sw=1.4, fs=14, arc=6)
box(1560, 1330, 400, 52, '<b>32 stream lanes</b> · 64 B/cycle each (512-bit) · 2 KiB/cycle', fill=C['l2'], fc='#FFFFFF', sw=1.4, fs=14, arc=6)
box(2010, 1296, 350, 120, '<b>L2 Memory</b> · model weights and matrices<br><font style="font-size:12px">Qwen3.6-35B-A3B: 40 layers × 257 experts,<br>6 MiB per expert in FP16, 1.5 MiB in 4-bit</font>', fill=C['zoom_bg'], stroke=C['zoom'], sw=2.0, fs=15, arc=6)
flow([(2010, 1356), (1960, 1356)], color=C['l2'], sw=6)
flow([(1560, 1356), (1504, 1356)], color=C['l2'], sw=6)
flow([(1304, 1330), (1304, 1270)], color=C['l2'], sw=6)
text(1316, 1280, 330, 40, 'weights arrive; blocks become eligible as the tile fills', fs=12.5)
text(1104, 1396, 880, 70, 'Per layer step, FP16: one decode token streams 116 MiB and uses each weight for 1.1 multiply-adds; a 64-token midfill 770 MiB and 10; '
     'a 2,048-token prefill 1,474 MiB and 174. With few tokens the PEs wait for the lanes.', fs=12.5, italic=True, valign='top')

xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<mxfile host="app.diagrams.net">\n  <diagram name="TeraNoC-OoO architecture" id="teranoc-ooo-arch">\n'
       '    <mxGraphModel grid="1" page="0" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" pageScale="1" pageWidth="%d" pageHeight="%d" '
       'background="#FFFFFF" math="0" shadow="0">\n      <root>\n        <mxCell id="0"/>\n        <mxCell id="1" parent="0"/>\n%s\n      </root>\n    </mxGraphModel>\n  </diagram>\n</mxfile>\n'
       % (W, H, '\n'.join('        ' + c for c in cells if c)))
open(sys.argv[1], 'w').write(xml)
print(len(cells), 'cells')
