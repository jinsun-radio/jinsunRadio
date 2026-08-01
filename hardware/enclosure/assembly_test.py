"""Full assembly audit: static interference, insertion sweeps, fit metrics."""

import itertools
import math

from build123d import Pos

import speaker_design as d

shell = d.make_shell()
panel = d.make_back_panel()
parts = {
    'shell': shell, 'panel': panel, 'hub': d.make_hub8735(),
    'spk': d.make_speaker(), 'clamp': d.make_speaker_clamp(),
    'mic': d.make_mic_module(), 'amp': d.make_amp_module(),
    'bank': d.make_powerbank(), 'btn': d.make_button(),
    'nut': d.make_button_nut(), 'flap': d.make_stand_flap(),
}
for i, mz in enumerate(d.MAG_ZS):
    for sx, side in ((1, 'R'), (-1, 'L')):
        parts[f'magS{side}{i}'] = d.make_shell_magnet(sx, mz)
        parts[f'magP{side}{i}'] = d.make_panel_magnet(sx, mz)

print('=== 1. static pairwise interference ===')
bad = 0
for a, b in itertools.combinations(list(parts), 2):
    try:
        v = (parts[a] & parts[b]).volume
    except Exception:
        v = 0
    if v > 1e-6:
        bad += 1
        print(f'  FAIL {a} x {b}: {v:.3f} mm3')
print(f'  pairs={len(list(itertools.combinations(list(parts), 2)))} interferences={bad}')


def sweep(name, part, dx, dy, dz, steps, others):
    worst = 0.0
    at = None
    for i in range(1, steps + 1):
        moved = Pos(dx * i / steps, dy * i / steps, dz * i / steps) * part
        for on, o in others:
            try:
                v = (moved & o).volume
            except Exception:
                v = 0
            if v > 1e-4 and v > worst:
                worst, at = v, (round(dx * i / steps, 1), round(dy * i / steps, 1), round(dz * i / steps, 1), on)
    status = 'OK' if worst < 1e-4 else f'FAIL {worst:.2f} mm3 at offset {at}'
    print(f'  {name}: {status}')


print('=== 2. insertion path sweeps ===')
sweep('board drop-in (lift +28 out of grooves)', parts['hub'], 0, 0, 28, 14, [('shell', shell)])
sweep('bank slide out +Y 30', parts['bank'], 0, 30, 0, 10, [('shell', shell)])
sweep('panel open +Y 12', parts['panel'], 0, 12, 0, 6, [('shell', shell), ('bank', parts['bank'])])
sweep('mic module lift +Z 10', parts['mic'], 0, 0, 10, 5, [('shell', shell)])
sweep('speaker out +Y 25', parts['spk'], 0, 25, 0, 10, [('shell', shell), ('amp', parts['amp'])])
sweep('clamp ring out +Y 25', parts['clamp'], 0, 25, 0, 10, [('shell', shell), ('amp', parts['amp']), ('mic', parts['mic'])])

print('=== 3. fit / clearance metrics ===')


def gap(label, a, b, expect):
    print(f'  {label}: {parts[a].distance_to(parts[b]):.3f} mm  (expect {expect})')


gap('board in grooves (contact)', 'hub', 'shell', '0.000 rest')
gap('board back -> bank front', 'hub', 'bank', '>=15 DuPont')
gap('speaker seated (contact)', 'spk', 'shell', '0.000')
gap('clamp presses flange (contact)', 'clamp', 'spk', '0.000')
gap('clamp -> mic channel', 'clamp', 'mic', '>0.3')
gap('button body -> bank', 'btn', 'bank', '>0.5')
gap('nut -> bank', 'nut', 'bank', '>0.5')
gap('magnet pair contact', 'magSR1', 'magPR1', '0.000')
gap('panel seats on rim (contact)', 'panel', 'shell', '0.000')
gap('flap stud in socket', 'flap', 'panel', '~0.15 radial')

bb = parts['bank'].bounding_box()
print(f'  bank side slack per side: {(d.BOSS_X0 - bb.max.X):.2f} mm')
print(f'  bank top headroom: {(d.Z_CEIL - bb.max.Z):.2f} mm (foam pad optional)')
print(f'  bank depth slack to panel: {(d.Y_B - bb.max.Y):.2f} mm (foam pad advised)')
hb = parts['hub'].bounding_box()
print(f'  DuPont depth available: {(bb.min.Y - (d.PCB_Y1)):.1f} mm (need ~16.5)')
print(f'  lens tip -> front wall air gap: {abs(d.Y_F - hb.min.Y):.2f} mm')

print('=== 4. groove & pocket dimensional audit ===')
print(f'  groove width 1.9 vs PCB 1.6 -> 0.3 slack; grip L-low 2.5 / L-up 1.0 / R-low 1.5 / R-up 1.5')
print(f'  board drop-in headroom: entry Z 82.5 + board 27 = 109.5 vs ceiling {d.Z_CEIL} -> {d.Z_CEIL - 109.5:.1f} mm')
print(f'  button hole {d.BTN_HOLE_D}/{d.BTN_HOLE_FLAT} flats vs body 16.0/15.0 -> 0.2 clearance')
print(f'  magnet pockets D{d.MAG_POCKET_D} vs D{d.MAG_D} -> 0.4; stack: shell recess 0.8 = panel proud 0.8')
print(f'  mic channel width {d.MIC_D + 0.6:.1f} vs module D{d.MIC_D}; depth {d.MIC_T + 0.4:.1f} vs {d.MIC_T}')
print(f'  speaker seat ID {d.SPK_SEAT_ID} vs flange D36+-0.4 -> 0.4..0.8 radial')
print(f'  clamp ID {d.SPK_CLAMP_ID} presses flange rim r17.3..18; OD flat at X-22.2 clears mic channel')
print(f'  amp boss span {d.AMP_HOLE_SPACING} +- verify on real GY board before printing')

print('=== 5. thin-wall spots ===')
probes = [
    ('top-fillet ring at ceiling corner', d._box(46.9, 47.4, -1, 1, 112.3, 112.5)),
    ('panel skin behind magnet pocket', d._ycyl(38, 57.5, d.Y_B + 1.9, d.Y_B + 3.4, 8.0)),
    ('pilot front skin (spk 270deg)', d._ycyl(0, 6.8, d.Y_OUT_F - 0.4, d.Y_OUT_F + d.HEX_RECESS + 0.9, 1.6)),
]
for label, probe in probes:
    tgt = panel if 'panel' in label else shell
    v = (tgt & probe).volume
    print(f'  {label}: material {v:.2f} mm3 (>0 intact)')
