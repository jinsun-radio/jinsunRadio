"""Printable fold-out stand flap / back clip.

Print flat (outer face down). Snap the two D3 studs into the back panel's
hinge lug sockets. PETG recommended for clip springiness.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import speaker_design as d  # noqa: E402


def gen_step():
    return d.make_stand_flap()
