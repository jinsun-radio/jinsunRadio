"""Printable main shell of the HUB8735 smart speaker (single part).

Recommended print orientation: front face down on the bed (rotate -90 deg
about X before slicing) so every internal feature grows vertically.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import speaker_design as d  # noqa: E402


def gen_step():
    return d.make_shell()
