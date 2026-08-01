"""HUB8735 Ultra smart-speaker — full labeled assembly.

Static parameterized layout: every component is authored in its closed/world
position by speaker_design.py parameters. Named rigid datums document the key
interfaces (back rim plane, button axis, lens axis, speaker axis).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build123d import Color, Location  # noqa: E402
from cadpy.assembly import AssemblyHelper  # noqa: E402

import speaker_design as d  # noqa: E402


def gen_step():
    asm = AssemblyHelper("hub8735_smart_speaker")

    shell = asm.add(d.make_shell(), "shell", color=Color(0.82, 0.84, 0.88, 0.5))
    panel = asm.add(d.make_back_panel(), "back_panel_magnetic", color=Color(0.45, 0.48, 0.55, 0.85))

    asm.add(d.make_hub8735(), "hub8735_ultra_board", color=Color(0.13, 0.45, 0.22))
    asm.add(d.make_speaker(), "speaker_36mm_3w_4ohm", color=Color(0.25, 0.25, 0.28))
    asm.add(d.make_speaker_clamp(), "speaker_clamp_ring", color=Color(0.9, 0.65, 0.2))
    asm.add(d.make_mic_module(), "inmp441_mic_module", color=Color(0.35, 0.2, 0.5))
    asm.add(d.make_amp_module(), "max98357a_amp_module", color=Color(0.6, 0.1, 0.15))
    asm.add(d.make_powerbank(), "powerbank_md_bp075qi", color=Color(0.2, 0.3, 0.4))
    asm.add(d.make_button(), "pushbutton_16mm_r13", color=Color(0.85, 0.15, 0.1))
    asm.add(d.make_button_nut(), "pushbutton_nut_m16", color=Color(0.6, 0.6, 0.62))

    asm.add(d.make_stand_flap(), "stand_flap_folded", color=Color(0.75, 0.7, 0.62))

    for i, mz in enumerate(d.MAG_ZS):
        for j, sx in enumerate((1, -1)):
            side = "right" if sx == 1 else "left"
            asm.add(d.make_shell_magnet(sx, mz), f"magnet_shell_{side}_{i}", color=Color(0.75, 0.75, 0.78))
            asm.add(d.make_panel_magnet(sx, mz), f"magnet_panel_{side}_{i}", color=Color(0.85, 0.85, 0.88))

    # documentation datums
    asm.rigid_frame(shell, "back_rim_plane", Location((0, d.Y_B, d.OUT_H / 2), (-90, 0, 0)))
    asm.rigid_frame(shell, "button_axis", Location((d.BTN_CX, d.BTN_CY, d.Z_CEIL)))
    asm.rigid_frame(
        shell,
        "camera_axis",
        Location((d.BOARD_CX + d.LENS_DX, d.Y_OUT_F, d.BOARD_CZ + d.LENS_DZ), (90, 0, 0)),
    )
    asm.rigid_frame(shell, "speaker_axis", Location((d.SPK_CX, d.Y_OUT_F, d.SPK_CZ), (90, 0, 0)))
    asm.rigid_frame(panel, "panel_mating_face", Location((0, d.Y_B, d.OUT_H / 2), (90, 0, 0)))

    return asm.build()
