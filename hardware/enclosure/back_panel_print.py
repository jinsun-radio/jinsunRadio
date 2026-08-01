"""Printable magnetic back panel of the HUB8735 smart speaker (single part).

Recommended print orientation: outer face down on the bed (lips up).
Glue 6x D8x3 magnets proud by 0.8 mm; match polarity against the shell set.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import speaker_design as d  # noqa: E402


def gen_step():
    return d.make_back_panel()
