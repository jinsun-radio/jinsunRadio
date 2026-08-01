"""Printable speaker clamp ring (presses the 36 mm speaker flange).

Fastened with 3x M2x5 COUNTERSUNK (flat-head) self-tapping screws into the
shell bosses; the screw holes carry 90 deg countersinks so the heads sit flush.
Print flat on the bed. If the speaker flange is on the thin side of its
tolerance, add a thin foam gasket ring under the flange (also seals audio).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import speaker_design as d  # noqa: E402


def gen_step():
    return d.make_speaker_clamp()
