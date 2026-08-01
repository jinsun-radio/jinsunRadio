"""HUB8735 Ultra smart-speaker enclosure — parametric design (all mm).

CAD brief
=========
Vertical smart-speaker enclosure, outer ~96 x 115.5 x 47 mm (W x H x D incl.
magnetic back panel), printable in two parts (shell + back panel).

World frame: +X right (viewed from front), +Y toward the back, +Z up.
Origin: X centered, Z=0 at the outer bottom face, front outer face at Y=-23.

Contents / placements
- HUB8735 Ultra (53 x 27 x 1.6 PCB, module 8.8 thick, lens perpendicular to
  PCB): side-mounted (53 mm horizontal), PCB parallel to the front wall,
  lens facing front through a 17 mm window. Board slides top-down into two
  C-groove towers. USB-C edge faces +X with ~28 mm internal plug clearance.
- 36 mm / 3 W / 4 ohm speaker: front wall seat ring, hole-pattern grille,
  clamped by 3x M2 self-tapping screws + washers into pilot holes.
- INMP441 mic module (ROUND D14 x ~3 breakout): C-channel pocket against the
  front wall, 3 mm sound port through the wall (bottom-port MEMS).
- GY-MAX98357A amp module (18 x 20, screw-terminal block on top edge): screwed
  onto two M2 bosses (13 mm spacing), components/terminal facing rearward.
- MD-BP075-Qi power bank (65 x 104 x 19.5, r8 corners, ~200 g): stands
  vertically against the back panel; located by floor rails, 4 front stop
  posts, magnet-boss inner faces and 2 chamfered top nubs. Swappable by
  removing the magnetic back panel. Bottom slot for its charge cable.
- 16 mm pushbutton (M16x1.0, body flats 15.0, cap D13, 24.8 overall,
  ~18.3 below flange): top panel hole D16.2 with 15.2 anti-rotation flats.
- Magnetic back: 6x D8x3 disc magnets in the shell rim bosses (recessed
  0.8) attracting 6x D8x3 magnets in the panel (proud 0.8) -> self-locating.
  Panel also carries 4 alignment lip strips. Glue magnets, mind polarity!

Assumptions (parametric, adjust as needed)
- Lens is at the board center (LENS_DX/LENS_DZ offsets below).
- INMP441 sound port at module center (MIC_PORT_* offsets).
- Module envelopes for mic/amp from common breakout listings.
"""

from build123d import *

# ---------------- master parameters ----------------
WALL = 2.5            # side/bottom/front wall
TOP_WALL = 3.0        # top panel (button panel, max clamp << 13 thread)
PANEL_T = 3.5         # magnetic back panel plate

IN_W = 91.0           # interior width  -> X +-45.5
IN_D = 50.0           # interior depth  -> Y -25 .. +25 (DuPont females on the
                      # board's rear headers need ~17 mm behind the PCB)
IN_H = 110.0          # interior height -> Z 2.5 .. 112.5

X_IN = IN_W / 2                       # 45.5
Y_F = -IN_D / 2                       # inner front wall face
Y_B = IN_D / 2                        # back rim plane (panel seats here)
BODY_CORNER_R = 8.0                   # plan-view corner radius (whole body)
BODY_TOP_R, BODY_BOT_R = 6.0, 5.0     # top/bottom perimeter softening
# top-center strap bridge (single anchor, webbing threads front-to-back)
STRAP_W, STRAP_H = 26.0, 11.1         # bridge footprint / height above top
STRAP_Y0, STRAP_Y1 = 3.0, 11.0        # near the assembly center of gravity
STRAP_SLOT_W, STRAP_SLOT_H = 16.0, 5.0
# fold-out stand flap / back clip, hinged on the back panel (snap-in studs)
HINGE_Z = 70.0                        # hinge axis height
HINGE_Y = IN_D / 2 + PANEL_T + 4.0    # hinge axis, 4 off the panel face
FLAP_HALF_W, FLAP_T = 20.8, 4.0
FLAP_TIP_Z, FLAP_HEEL = 3.0, 4.1      # heel stops the flap at ~35 deg open
LUG_X0, LUG_X1, LUG_Z0, LUG_Z1 = 21.0, 29.0, 65.0, 75.0
Z_FLOOR = WALL                        # 2.5
Z_CEIL = Z_FLOOR + IN_H               # 112.5
OUT_W = IN_W + 2 * WALL               # 96
OUT_H = Z_CEIL + TOP_WALL             # 115.5
Y_OUT_F = Y_F - WALL                  # -23
FRONT_CORNER_R = 4.0

# HUB8735 Ultra board (side-mounted, lens to front)
PCB_L, PCB_W, PCB_T = 53.0, 27.0, 1.6
BOARD_CX, BOARD_CZ = -9.0, 67.5       # board center in world XZ
PCB_Y0 = Y_F + 8.5                    # PCB front face (lens stack fills 7.5)
PCB_Y1 = PCB_Y0 + PCB_T               # PCB back face
GRIP_BACK = PCB_Y1 + 2.05             # rear face of the grip blocks
# lens sits on the camera daughter-module folded over the TOP end of the
# board (measured off the product photo; spec PDF has no lens coordinates):
# ~6.2 mm from the camera-end short edge, ~0.9 mm off the centerline.
LENS_DX, LENS_DZ = -20.3, -0.9        # lens offset from board center
LENS_D, LENS_H = 8.0, 4.0             # lens barrel envelope
CAM_WINDOW_D = 12.0                   # front window (covers +-2 mm estimate error)
CAM_MOD_X0, CAM_MOD_X1 = -25.0, -10.0  # camera module footprint (board-local)
CAM_MOD_Y0, CAM_MOD_Y1 = -10.5, 9.5
CAM_MOD_H = 3.5                        # module stack height above PCB face
FLASH_DX, FLASH_DZ = 12.6, 0.5         # flash LED offset from board center
FLASH_WINDOW_D = 5.0
BOARD_Z0 = BOARD_CZ - PCB_W / 2       # 54  (groove bottom)
BOARD_X0 = BOARD_CX - PCB_L / 2       # -35.5
BOARD_X1 = BOARD_CX + PCB_L / 2       # 17.5

# speaker (D36 +-0.4, overall depth 17 +-0.5, flange 2.7 +-0.3, magnet D18)
SPK_D, SPK_T, SPK_FLANGE_T, SPK_MAG_D = 36.0, 17.0, 2.7, 18.0
SPK_CX, SPK_CZ = 0.0, 28.0
SPK_SEAT_ID, SPK_SEAT_OD = 36.8, 43.4
SPK_SEAT_Y1 = Y_F + 2.0               # shallow ring locates the flange only
# honeycomb front face (styled after the reference speaker-grille.stl):
# pointy-top hexes, through-holes over the speaker cone, 1 mm decorative
# recesses across a squircle field around it
HEX_AF, HEX_RIB = 5.0, 1.2
HEX_FIELD_RX, HEX_FIELD_RZ = 36.0, 18.0   # squircle field half-sizes
HEX_RECESS = 1.0
SPK_PILOT_D, SPK_PILOT_R = 1.8, 21.2  # M2 bosses on the screw circle
SPK_BOSS_D = 5.5
SPK_CLAMP_ID, SPK_CLAMP_OD = 34.6, 47.0   # printed clamp ring presses flange rim
SPK_CLAMP_T = 2.0
SPK_SCREW_ANGLES = (30, 150, 270)

# mic module (INMP441, ROUND breakout D14)
MIC_D, MIC_T = 14.0, 3.0
MIC_CX, MIC_CZ = -31.5, 30.0
MIC_PORT_DX, MIC_PORT_DZ = 0.0, 0.0
MIC_PORT_D = 3.0

# amp module (GY-MAX98357A, 18 x 20, screw-terminal block on top edge,
# 2 mounting holes at the top corners -> M2 self-tap bosses)
AMP_W, AMP_H, AMP_PCB_T = 18.0, 20.0, 1.6
AMP_CX, AMP_CZ = 33.0, 28.0
AMP_HOLE_SPACING = 13.0        # between the two top-corner holes
AMP_HOLE_FROM_TOP = 2.5
AMP_STANDOFF = 4.0             # boss length: lifts PCB off the front wall
AMP_BOSS_D = 5.5
AMP_PILOT_D = 1.8

# power bank MD-BP075-Qi
BANK_W, BANK_H, BANK_T, BANK_R = 65.0, 104.0, 19.5, 8.0
BANK_Y0 = Y_B - BANK_T - 2.0          # front face (against stop posts)
BANK_Z0 = 4.5                         # sits on 2 mm floor rails

# 16 mm pushbutton, top panel
BTN_CX, BTN_CY = 0.0, -9.6
BTN_HOLE_D, BTN_HOLE_FLAT = 16.2, 15.2

# magnets
MAG_D, MAG_T = 8.0, 3.0
MAG_POCKET_D = 8.4
MAG_X = 38.0
MAG_ZS = [10.0, 57.5, 105.0]
BOSS_X0, BOSS_H = 33.2, 11.0          # boss block inner face / height
BOSS_Y0 = Y_B - 5.5                   # boss front face (45 deg chamfer below)
SHELL_MAG_RECESS = 0.8                # shell magnet sits 0.8 below rim plane

# misc
VENT_L, VENT_W = 14.0, 2.5
FOOT_H = 5.0


# ---------------- helpers ----------------
def _box(x0, x1, y0, y1, z0, z1):
    return Pos((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2) * Box(
        abs(x1 - x0), abs(y1 - y0), abs(z1 - z0)
    )


def _zcyl(x, y, z0, z1, d):
    return Pos(x, y, (z0 + z1) / 2) * Cylinder(d / 2, z1 - z0)


def _ycyl(x, z, y0, y1, d):
    return Pos(x, (y0 + y1) / 2, z) * Rot(90, 0, 0) * Cylinder(d / 2, y1 - y0)


def _yz_prism(pts, x0, x1):
    """Extrude a polygon drawn in (y, z) coordinates from x0 to x1."""
    sk = Plane.YZ * Polygon(*pts)
    return Pos(x0, 0, 0) * extrude(sk, x1 - x0, dir=(1, 0, 0))


def _xcyl(y, z, x0, x1, d):
    return Pos((x0 + x1) / 2, y, z) * Rot(0, 90, 0) * Cylinder(d / 2, abs(x1 - x0))


def _yhex(x, z, y0, y1, af):
    """Pointy-top hexagonal prism along Y (across-flats = af)."""
    p = extrude(Rot(0, 0, 30) * RegularPolygon(af / 3**0.5, 6), abs(y1 - y0))
    return Pos(x, max(y0, y1), z) * Rot(90, 0, 0) * p


# ---------------- outer body form (shared by shell + back panel) ----------------
def _outer_form():
    """One soft rounded body; the shell and panel are split from it at Y_B."""
    prism = extrude(
        Pos(0, (Y_OUT_F + Y_B + PANEL_T) / 2, 0)
        * RectangleRounded(OUT_W, WALL + IN_D + PANEL_T, BODY_CORNER_R),
        OUT_H,
    )
    prism = fillet(prism.edges().group_by(Axis.Z)[-1], BODY_TOP_R)
    prism = fillet(prism.edges().group_by(Axis.Z)[0], BODY_BOT_R)
    return prism


# ---------------- shell ----------------
def make_shell():
    outer = _outer_form() & _box(-60, 60, -40, Y_B, -30, 140)

    # interior cavity, open at the back
    cavity = extrude(
        Pos(0, (Y_F + Y_B + 1.0) / 2, Z_FLOOR)
        * RectangleRounded(IN_W, IN_D + 1.0, BODY_CORNER_R - WALL),
        IN_H,
    )
    shell = outer - cavity

    # ---- additions ----
    adds = []

    # speaker seat ring (locates the flange) + 3 clamp-screw bosses
    import math as _m

    ring = _ycyl(SPK_CX, SPK_CZ, Y_F, SPK_SEAT_Y1, SPK_SEAT_OD) - _ycyl(
        SPK_CX, SPK_CZ, Y_F - 1, SPK_SEAT_Y1 + 1, SPK_SEAT_ID
    )
    adds.append(ring)
    for ang_deg in SPK_SCREW_ANGLES:
        a = _m.radians(ang_deg)
        adds.append(_ycyl(SPK_CX + SPK_PILOT_R * _m.cos(a), SPK_CZ + SPK_PILOT_R * _m.sin(a),
                          Y_F, Y_F + SPK_FLANGE_T, SPK_BOSS_D))

    # camera board grip blocks: vertical C-grooves on the SHORT edges, board
    # drops in from the top. Each side is split into two blocks so the
    # mid-edge stays open: right gap = USB-C ports + plug, left gap = microSD.
    # (upper blocks stop at 82.5 so the board can drop in under the ceiling;
    # left-upper inner face pulled to -34.6 to clear the camera module sweep)
    # three-corner grip: a right-upper block would trap the USB-C connectors
    # (Z 56..79 at the board edge) during insertion/removal
    adds.append(_box(-38.5, -32.5, Y_F, GRIP_BACK, 50.0, 56.5))   # left lower
    adds.append(_box(-38.5, -34.6, Y_F, GRIP_BACK, 77.5, 82.5))   # left upper
    adds.append(_box(14.3, 20.3, Y_F, GRIP_BACK, 50.0, 55.5))     # right lower

    # mic / amp C-channel pockets (slide in from the top, 0.3 side clearance)
    def c_channel(cx, cz, w, h, t):
        x_in0, x_in1 = cx - w / 2 - 0.3, cx + w / 2 + 0.3    # channel walls
        x_out0, x_out1 = x_in0 - 1.6, x_in1 + 1.6
        z0, z1 = cz - h / 2 - 1.6, cz + h / 2 + 1.5
        back = Y_F + t + 0.4                                  # channel depth
        parts = [
            _box(x_out0, x_in0, Y_F, back + 1.2, z0, z1),     # side bars
            _box(x_in1, x_out1, Y_F, back + 1.2, z0, z1),
            _box(x_out0, x_out1, Y_F, back + 1.2, z0, cz - h / 2 - 0.3),  # bottom
            _box(x_in0 - 0.1, x_in0 + 3.5, back, back + 1.2, z0, z1),     # tabs
            _box(x_in1 - 3.5, x_in1 + 0.1, back, back + 1.2, z0, z1),
        ]
        return parts

    adds += c_channel(MIC_CX, MIC_CZ, MIC_D, MIC_D, MIC_T)

    # amp mounting bosses (module screws on, components/terminal face rear)
    amp_hole_z = AMP_CZ + AMP_H / 2 - AMP_HOLE_FROM_TOP
    for hx in (AMP_CX - AMP_HOLE_SPACING / 2, AMP_CX + AMP_HOLE_SPACING / 2):
        adds.append(_ycyl(hx, amp_hole_z, Y_F, Y_F + AMP_STANDOFF, AMP_BOSS_D))

    # magnet bosses on the rim (both sides) + 45 deg print chamfer wedges
    for mz in MAG_ZS:
        z0, z1 = mz - BOSS_H / 2, mz + BOSS_H / 2
        for sgn in (1, -1):
            adds.append(_box(min(sgn * BOSS_X0, sgn * X_IN), max(sgn * BOSS_X0, sgn * X_IN), BOSS_Y0, Y_B, z0, z1))
            tri = [(X_IN * 1.0, BOSS_Y0), (BOSS_X0, BOSS_Y0), (X_IN * 1.0, BOSS_Y0 - 11.5)]
            pts = [(sgn * px, py) for px, py in tri]
            wedge = extrude(Pos(0, 0, z0) * Polygon(*[(p[0], p[1]) for p in pts]), z1 - z0, dir=(0, 0, 1))
            adds.append(wedge)

    # power-bank front stops: two bottom posts + right top post (front wall)
    # and a ceiling-hung rib top-left, kept out of the board's removal path
    for sx in (1, -1):
        adds.append(_box(sx * 26, sx * 34, Y_F, BANK_Y0, 6.0, 14.0))
    adds.append(_box(26, 34, Y_F, BANK_Y0, 96.0, 104.0))
    adds.append(_yz_prism(
        [(BANK_Y0, Z_CEIL), (BANK_Y0, 96.0), (BANK_Y0 - 8.0, 104.5), (BANK_Y0 - 8.0, Z_CEIL)],
        -34.0, -26.0,
    ))

    # floor rails under the bank
    for sx in (1, -1):
        adds.append(_box(sx * 20, sx * 32, Y_F, Y_B - 4.0, Z_FLOOR, BANK_Z0))

    # top-center strap bridge: rounded arch, webbing tunnel along Y
    slab = Pos(0, STRAP_Y0, 0) * extrude(
        Plane.XZ * Pos(0, OUT_H + STRAP_H / 2 - 0.1) * RectangleRounded(STRAP_W, STRAP_H, 2.5),
        STRAP_Y1 - STRAP_Y0, dir=(0, 1, 0),
    )
    tunnel = Pos(0, STRAP_Y0 - 2, 0) * extrude(
        Plane.XZ * Pos(0, OUT_H + 4.5) * RectangleRounded(STRAP_SLOT_W, STRAP_SLOT_H, 2.0),
        STRAP_Y1 - STRAP_Y0 + 4, dir=(0, 1, 0),
    )
    adds.append(slab - tunnel)

    # feet (chamfered for front-face-down printing)
    foot_f = [(Y_OUT_F + 5.5, 0.0), (Y_OUT_F + 15.5, 0.0),
              (Y_OUT_F + 15.5, -FOOT_H), (Y_OUT_F + 10.5, -FOOT_H)]
    foot_r = [(Y_B - 13.0, 0.0), (Y_B - 3.0, 0.0),
              (Y_B - 3.0, -FOOT_H), (Y_B - 8.0, -FOOT_H)]
    for x0, x1 in ((30.0, 42.0), (-42.0, -30.0)):
        adds.append(_yz_prism(foot_f, x0, x1))
        adds.append(_yz_prism(foot_r, x0, x1))

    for a in adds:
        shell = shell + a

    # ---- subtractions ----
    cuts = []

    # honeycomb front: through-holes over the speaker cone, shallow recesses
    # across the surrounding squircle field (single fused cut for speed)
    import math

    hex_px = HEX_AF + HEX_RIB
    hex_pz = hex_px * math.sqrt(3) / 2
    hex_r = HEX_AF / math.sqrt(3)
    hex_cuts = None
    for k in range(-4, 5):
        z = SPK_CZ + k * hex_pz
        xoff = (abs(k) % 2) * hex_px / 2
        for j in range(-7, 8):
            x = SPK_CX + j * hex_px + xoff
            d_spk = math.hypot(x - SPK_CX, z - SPK_CZ)
            in_field = ((x - SPK_CX) / HEX_FIELD_RX) ** 4 + ((z - SPK_CZ) / HEX_FIELD_RZ) ** 4 <= 1.0
            if d_spk + hex_r <= 17.6:
                h = _yhex(x, z, Y_OUT_F - 0.5, Y_F + 0.5, HEX_AF)             # through
            elif in_field:
                h = _yhex(x, z, Y_OUT_F - 0.5, Y_OUT_F + HEX_RECESS, HEX_AF)  # recess
            else:
                continue
            hex_cuts = h if hex_cuts is None else hex_cuts + h
    cuts.append(hex_cuts)

    # clamp-screw pilot holes (M2x5; stop 1.0 mm below the hex recess floors)
    for ang_deg in SPK_SCREW_ANGLES:
        ang = math.radians(ang_deg)
        cuts.append(
            _ycyl(SPK_CX + SPK_PILOT_R * math.cos(ang), SPK_CZ + SPK_PILOT_R * math.sin(ang),
                  Y_OUT_F + HEX_RECESS + 1.0, Y_F + SPK_FLANGE_T + 0.1, SPK_PILOT_D)
        )

    # camera window + shallow bezel recess, flash LED window
    lx, lz = BOARD_CX + LENS_DX, BOARD_CZ + LENS_DZ
    cuts.append(_ycyl(lx, lz, Y_OUT_F - 1, Y_F + 0.5, CAM_WINDOW_D))
    cuts.append(_ycyl(lx, lz, Y_OUT_F - 1, Y_OUT_F + 1.0, CAM_WINDOW_D + 3.0))
    cuts.append(_ycyl(BOARD_CX + FLASH_DX, BOARD_CZ + FLASH_DZ, Y_OUT_F - 1, Y_F + 0.5, FLASH_WINDOW_D))

    # mic port (hidden inside the honeycomb field, no countersink)
    mx, mz2 = MIC_CX + MIC_PORT_DX, MIC_CZ + MIC_PORT_DZ
    cuts.append(_ycyl(mx, mz2, Y_OUT_F - 1, Y_F + 0.5, MIC_PORT_D))

    # amp boss pilot holes (M2 self-tapping, from the rear; keep 2 mm front skin)
    for hx in (AMP_CX - AMP_HOLE_SPACING / 2, AMP_CX + AMP_HOLE_SPACING / 2):
        cuts.append(_ycyl(hx, amp_hole_z, Y_F - 0.5, Y_F + AMP_STANDOFF + 0.1, AMP_PILOT_D))

    # vertical board grooves (1.9 wide, open at the top; floor at Z=54)
    cuts.append(_box(-35.7, -32.4, PCB_Y0 - 0.25, PCB_Y1 + 0.05, BOARD_Z0, 87.0))
    cuts.append(_box(14.2, 17.7, PCB_Y0 - 0.25, PCB_Y1 + 0.05, BOARD_Z0, 87.0))

    # pushbutton hole D16.2 with 15.2 anti-rotation flats
    btn = _zcyl(BTN_CX, BTN_CY, Z_CEIL - 1, OUT_H + 1, BTN_HOLE_D) & _box(
        BTN_CX - BTN_HOLE_D / 2 - 1, BTN_CX + BTN_HOLE_D / 2 + 1,
        BTN_CY - BTN_HOLE_FLAT / 2, BTN_CY + BTN_HOLE_FLAT / 2,
        Z_CEIL - 1, OUT_H + 1,
    )
    cuts.append(btn)

    # top vents
    for vx in (27.0, -27.0):
        for vy in (-14.0, -6.5):
            cuts.append(extrude(Pos(vx, vy, Z_CEIL - 1) * SlotOverall(VENT_L, VENT_W), TOP_WALL + 2))

    # bottom cable slot under the bank
    cuts.append(extrude(Pos(0, BANK_Y0 + BANK_T / 2, -1) * SlotOverall(30, 8), WALL + 2))


    # shell-side magnet pockets, cut from the rim plane
    for mz in MAG_ZS:
        for sx in (1, -1):
            cuts.append(_ycyl(sx * MAG_X, mz, Y_B - MAG_T - SHELL_MAG_RECESS, Y_B + 1, MAG_POCKET_D))

    for c in cuts:
        shell = shell - c

    return shell


# ---------------- back panel ----------------
def make_back_panel():
    panel = _outer_form() & _box(-60, 60, Y_B, 40, -30, 140)

    # alignment lip strips: hug the cavity floor/ceiling (clear of the rounded
    # rear corners and of the magnet bosses); they resist shear when worn
    for sx in (1, -1):
        for z0, z1 in ((2.6, 4.2), (110.8, 112.4)):
            lip = _box(sx * 34.0, sx * 39.5, Y_B - 2.0, Y_B + 0.1, z0, z1)
            panel = panel + lip

    # magnet pockets (magnet glued proud by 0.8 -> keys into the shell pocket)
    for mz in MAG_ZS:
        for sx in (1, -1):
            panel = panel - _ycyl(sx * MAG_X, mz, Y_B - 0.1, Y_B + MAG_T - SHELL_MAG_RECESS, MAG_POCKET_D)

    # thumb notch at the bottom edge
    panel = panel - _box(-15, 15, Y_B + 1.8, Y_B + PANEL_T + 0.5, -0.5, 2.0)

    # hinge lugs for the fold-out stand flap (snap-in stud sockets)
    for sx in (1, -1):
        lug = _box(sx * LUG_X0, sx * LUG_X1, Y_B + PANEL_T - 0.1, HINGE_Y + 4.0, LUG_Z0, LUG_Z1)
        panel = panel + lug
        panel = panel - _xcyl(HINGE_Y, HINGE_Z, sx * (LUG_X0 - 0.2), sx * (LUG_X0 + 3.2), 3.3)
    return panel


# ---------------- placeholder components ----------------
def make_hub8735():
    pcb = Pos(0, 0, PCB_T / 2) * Box(PCB_L, PCB_W, PCB_T)
    cam = _box(CAM_MOD_X0, CAM_MOD_X1, CAM_MOD_Y0, CAM_MOD_Y1, PCB_T, PCB_T + CAM_MOD_H)
    lens = Pos(LENS_DX, LENS_DZ, PCB_T + CAM_MOD_H + LENS_H / 2) * Cylinder(LENS_D / 2, LENS_H)
    usb1 = Pos(PCB_L / 2 - 3.75, 7.0, PCB_T + 1.6) * Box(7.5, 9.0, 3.2)
    usb2 = Pos(PCB_L / 2 - 3.75, -7.0, PCB_T + 1.6) * Box(7.5, 9.0, 3.2)
    shield = Pos(-9.0, 0, -1.25) * Box(21.0, 22.0, 2.5)
    board = pcb + cam + lens + usb1 + usb2 + shield
    return Pos(BOARD_CX, PCB_Y1, BOARD_CZ) * Rot(90, 0, 0) * board


def make_speaker():
    flange = Pos(0, 0, SPK_FLANGE_T / 2) * Cylinder(SPK_D / 2, SPK_FLANGE_T)
    basket = Pos(0, 0, SPK_FLANGE_T) * Cone(17.0, 10.0, 11.3, align=(Align.CENTER, Align.CENTER, Align.MIN))
    magnet = Pos(0, 0, SPK_T - 1.5) * Cylinder(SPK_MAG_D / 2, 3.0)
    spk = flange + basket + magnet
    return Pos(SPK_CX, Y_F, SPK_CZ) * Rot(-90, 0, 0) * spk


def make_speaker_clamp():
    import math as _m

    ring = _ycyl(SPK_CX, SPK_CZ, Y_F + SPK_FLANGE_T, Y_F + SPK_FLANGE_T + SPK_CLAMP_T,
                 SPK_CLAMP_OD) - _ycyl(SPK_CX, SPK_CZ, Y_F + SPK_FLANGE_T - 1,
                                       Y_F + SPK_FLANGE_T + SPK_CLAMP_T + 1, SPK_CLAMP_ID)
    y_rear = Y_F + SPK_FLANGE_T + SPK_CLAMP_T          # face the screw heads sit on
    for ang_deg in SPK_SCREW_ANGLES:
        a = _m.radians(ang_deg)
        sx, sz = SPK_CX + SPK_PILOT_R * _m.cos(a), SPK_CZ + SPK_PILOT_R * _m.sin(a)
        ring = ring - _ycyl(sx, sz, Y_F, y_rear + 1, 2.4)
        # 90 deg countersink for flat-head (countersunk) M2 self-tappers
        ring = ring - (Pos(sx, y_rear - 0.45, sz) * Rot(90, 0, 0) * Cone(2.3, 1.2, 1.1))
    # flat on the mic side so the ring clears the mic C-channel
    ring = ring & _box(-22.2, 40.0, Y_F - 2, Y_F + 10, SPK_CZ - 30, SPK_CZ + 30)
    return ring


def make_mic_module():
    disc = Pos(0, 0, 0.6) * Cylinder(MIC_D / 2, 1.2)
    chip = Pos(0, 0, 1.95) * Box(4.0, 3.0, 1.5)
    return Pos(MIC_CX, Y_F, MIC_CZ) * Rot(-90, 0, 0) * (disc + chip)


def make_amp_module():
    y0 = Y_F + AMP_STANDOFF                      # PCB front face on the bosses
    pcb = Pos(AMP_CX, y0 + AMP_PCB_T / 2, AMP_CZ) * Box(AMP_W, AMP_PCB_T, AMP_H)
    term = _box(AMP_CX - 5.0, AMP_CX + 5.0, y0 + AMP_PCB_T, y0 + AMP_PCB_T + 9.0,
                AMP_CZ + AMP_H / 2 - 8.0, AMP_CZ + AMP_H / 2)
    amp = pcb + term
    for hx in (AMP_CX - AMP_HOLE_SPACING / 2, AMP_CX + AMP_HOLE_SPACING / 2):
        amp = amp - _ycyl(hx, AMP_CZ + AMP_H / 2 - AMP_HOLE_FROM_TOP, y0 - 1, y0 + AMP_PCB_T + 1, 2.2)
    return amp


def make_powerbank():
    b = extrude(RectangleRounded(BANK_W, BANK_H, BANK_R), BANK_T)
    return Pos(0, BANK_Y0, BANK_Z0 + BANK_H / 2) * Rot(-90, 0, 0) * b


def make_button():
    flange = _zcyl(BTN_CX, BTN_CY, OUT_H, OUT_H + 2.5, 18.3)
    cap = _zcyl(BTN_CX, BTN_CY, OUT_H + 2.5, OUT_H + 6.5, 13.0)
    body = _zcyl(BTN_CX, BTN_CY, OUT_H - 13.0, OUT_H, 15.8) & _box(
        BTN_CX - 8.5, BTN_CX + 8.5, BTN_CY - 7.5, BTN_CY + 7.5,
        OUT_H - 13.5, OUT_H + 0.5,
    )
    terms = _box(BTN_CX - 4.75, BTN_CX + 4.75, BTN_CY - 1.6, BTN_CY + 1.6,
                 OUT_H - 18.3, OUT_H - 13.0)
    return flange + cap + body + terms


def make_button_nut():
    hexnut = extrude(RegularPolygon(10.5, 6), 2.5)
    nut = Pos(BTN_CX, BTN_CY, Z_CEIL - 2.5) * Rot(0, 0, 30) * hexnut
    return nut - _zcyl(BTN_CX, BTN_CY, Z_CEIL - 3.5, Z_CEIL + 1, 16.0)


def make_stand_flap():
    """Fold-out stand / back clip, modeled in the FOLDED (stowed) position.

    Snap the two D3 studs into the panel lug sockets. Folded, it doubles as
    a clothes/pocket clip (2 mm gap, pinch bump near the tip). Swung open,
    the heel above the hinge hits the panel at ~35 deg and the unit stands
    leaning back ~12 deg on a ~93 mm support span.
    """
    y0 = Y_B + PANEL_T + 2.0                     # inner face, 2 mm clip gap
    flap = _box(-FLAP_HALF_W, FLAP_HALF_W, y0, y0 + FLAP_T, FLAP_TIP_Z, HINGE_Z + FLAP_HEEL)
    for sx in (1, -1):
        flap = flap + _xcyl(HINGE_Y, HINGE_Z, sx * FLAP_HALF_W, sx * (FLAP_HALF_W + 2.7), 3.0)
    flap = flap + _box(-15, 15, y0 - 1.4, y0 + 0.1, 6.0, 9.0)   # clip pinch bump
    return flap


def make_shell_magnet(sx, mz):
    return _ycyl(sx * MAG_X, mz, Y_B - SHELL_MAG_RECESS - MAG_T, Y_B - SHELL_MAG_RECESS, MAG_D)


def make_panel_magnet(sx, mz):
    return _ycyl(sx * MAG_X, mz, Y_B - SHELL_MAG_RECESS, Y_B - SHELL_MAG_RECESS + MAG_T, MAG_D)
