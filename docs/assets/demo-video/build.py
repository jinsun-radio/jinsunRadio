#!/usr/bin/env python3
"""組裝 3 分鐘 demo 粗剪：實拍素材 + 待補素材字卡 → 1920x1080 / 30fps / 180s。"""
import os
import subprocess
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
CARDS = os.path.join(HERE, "cards")
SEG = os.path.join(HERE, "segments")
CAP = os.path.join(HERE, "captions")
DL = os.path.expanduser("~/Downloads")
os.makedirs(SEG, exist_ok=True)
os.makedirs(CAP, exist_ok=True)

W, H, FPS = 1920, 1080, 30
HEITI_M = "/System/Library/Fonts/STHeiti Medium.ttc"
HEITI_L = "/System/Library/Fonts/STHeiti Light.ttc"

SRC = {
    "hw_out": os.path.join(DL, "收音機實體demo.mp4"),
    "hw_in": os.path.join(DL, "收音機內部.mp4"),
    "rec1": os.path.join(DL, "Screen_Recording_20260726_231034.mp4"),
    "rec2": os.path.join(DL, "Screen_Recording_20260726_231242_Photos.mp4"),
}

# 手機錄屏需遮蔽的區域（原始 1080x2316 座標）
MASK_WIDGET = (940, 280, 140, 230)      # 右上角浮動相片小工具（私人照片＋未讀徽章）
MASK_BANNER = (250, 240, 680, 190)      # 通話畫面上方的私人訊息通知橫幅


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("FFMPEG FAIL:", " ".join(cmd[:12]), "...")
        print(r.stderr[-2500:])
        raise SystemExit(1)


def caption_png(text, name):
    """底部說明條（RGBA 透明）。"""
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    fm = ImageFont.truetype(HEITI_M, 38, index=0)
    fl = ImageFont.truetype(HEITI_L, 30, index=0)
    d.rectangle([0, H - 150, W, H], fill=(10, 12, 16, 215))
    d.rectangle([0, H - 150, W, H - 146], fill=(251, 146, 60, 255))
    d.text((90, H - 112), text, font=fm, fill=(245, 245, 244, 255))
    d.text((W - 300, H - 104), "實拍畫面", font=fl, fill=(251, 146, 60, 255))
    p = os.path.join(CAP, name + ".png")
    im.save(p)
    return p


def card_seg(png, dur, out, fade_in=True, fade_out=True):
    vf = [f"scale={W}:{H}", f"fps={FPS}", "format=yuv420p"]
    if fade_in:
        vf.append("fade=t=in:st=0:d=0.3")
    if fade_out:
        vf.append(f"fade=t=out:st={dur - 0.3:.2f}:d=0.3")
    run(["ffmpeg", "-v", "error", "-loop", "1", "-i", png, "-t", str(dur),
         "-vf", ",".join(vf), "-r", str(FPS), "-c:v", "libx264",
         "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-y", out])


def countdown_seg(dur, out):
    seq = os.path.join(CARDS, "countdown", "cd_%04d.png")
    run(["ffmpeg", "-v", "error", "-framerate", "6", "-i", seq,
         "-vf", f"scale={W}:{H},fps={FPS},format=yuv420p,fade=t=in:st=0:d=0.3,"
                f"fade=t=out:st={dur - 0.3:.2f}:d=0.3",
         "-t", str(dur), "-r", str(FPS), "-c:v", "libx264", "-preset", "veryfast",
         "-crf", "20", "-pix_fmt", "yuv420p", "-y", out])


def footage_seg(src, tin, tlen, slot, out, caption=None, masks=(),
                fade_in=True, fade_out=True):
    speed = min(2.0, slot / tlen)
    hold = max(0.0, slot - tlen * speed) + 0.6

    parts, cur = [], "0:v"
    for i, (mx, my, mw, mh) in enumerate(masks):
        a, b, o = f"a{i}", f"b{i}", f"m{i}"
        parts.append(f"[{cur}]split=2[{a}][{b}]")
        parts.append(f"[{b}]crop={mw}:{mh}:{mx}:{my},boxblur=26:4[{o}]")
        parts.append(f"[{a}][{o}]overlay={mx}:{my}[p{i}]")
        cur = f"p{i}"

    parts.append(f"[{cur}]setpts=PTS*{speed:.4f},fps={FPS},"
                 f"tpad=stop_mode=clone:stop_duration={hold:.2f}[m]")
    parts.append("[m]split=2[bg0][fg0]")
    parts.append(f"[bg0]scale={W}:-1,boxblur=42:5,crop={W}:{H},"
                 f"eq=brightness=-0.30:saturation=0.55[bg]")
    parts.append("[fg0]scale=-2:1000[fg]")
    parts.append("[bg][fg]overlay=(W-w)/2:(H-h)/2[base]")

    inputs = ["-ss", str(tin), "-t", str(tlen), "-i", src]
    last = "base"
    if caption:
        inputs += ["-i", caption]
        parts.append(f"[{last}][1:v]overlay=0:0[cap]")
        last = "cap"

    fades = []
    if fade_in:
        fades.append("fade=t=in:st=0:d=0.3")
    if fade_out:
        fades.append(f"fade=t=out:st={slot - 0.3:.2f}:d=0.3")
    tail = ",".join(fades + ["format=yuv420p"])
    parts.append(f"[{last}]{tail}[v]")

    run(["ffmpeg", "-v", "error"] + inputs +
        ["-filter_complex", ";".join(parts), "-map", "[v]", "-t", str(slot),
         "-r", str(FPS), "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
         "-pix_fmt", "yuv420p", "-y", out])


# ---------------- EDL ----------------
PHONE_MASKS = (MASK_WIDGET,)
CALL_MASKS = (MASK_WIDGET, MASK_BANNER)

EDL = [
    ("01_hook",     "card", dict(png="01_hook", dur=6)),
    ("02_S1",       "card", dict(png="02_ph_S1", dur=10)),
    ("03_pain1",    "card", dict(png="03_pain1", dur=8)),
    ("04_pain2",    "card", dict(png="04_pain2", dur=8)),
    ("05_pain3",    "card", dict(png="05_pain3", dur=9)),
    ("06_product",  "card", dict(png="06_product", dur=7)),
    ("07_hw_out",   "shot", dict(src="hw_out", tin=2.0, tlen=12.0, slot=12,
                                 cap="實機　·　蜂巢喇叭孔／相機鏡頭／狀態燈號",
                                 masks=(), fade_out=False)),
    ("08_hw_in",    "shot", dict(src="hw_in", tin=0.0, tlen=5.6, slot=6,
                                 cap="機殼、電路、韌體　全部自己做",
                                 masks=(), fade_in=False)),
    ("09_S3",       "card", dict(png="09_ph_S3", dur=5)),
    ("10_S4",       "card", dict(png="10_ph_S4", dur=9)),
    ("11_countdown", "cd",  dict(dur=12)),
    ("12_family_alert", "shot", dict(src="rec2", tin=4.2, tlen=1.7, slot=4,
                                     cap="家屬 App　·　偵測到緊急狀況，即時推播",
                                     masks=PHONE_MASKS)),
    ("13_family_timeline", "shot", dict(src="rec2", tin=0.2, tlen=3.4, slot=7,
                                        cap="家屬 App　·　派遣進度與即時紀錄同步",
                                        masks=PHONE_MASKS)),
    ("14_volunteer_task", "shot", dict(src="rec1", tin=7.3, tlen=3.9, slot=6,
                                       cap="志工 App　·　派遣單、距離與預計到場時間",
                                       masks=PHONE_MASKS)),
    ("15_S5",       "card", dict(png="15_ph_S5", dur=7)),
    ("16_S6",       "card", dict(png="16_ph_S6", dur=8)),
    ("17_contact",  "shot", dict(src="rec1", tin=11.5, tlen=1.4, slot=4,
                                 cap="志工 App　·　聯絡家屬，號碼雙向遮蔽",
                                 masks=PHONE_MASKS)),
    ("18_incoming", "shot", dict(src="rec2", tin=6.2, tlen=3.6, slot=6,
                                 cap="家屬端　·　號碼已遮蔽，透過金孫收音機安全轉接",
                                 masks=CALL_MASKS)),
    ("19_incall",   "shot", dict(src="rec1", tin=22.5, tlen=4.0, slot=6,
                                 cap="通話接通　·　雙方都拿不到對方的電話號碼",
                                 masks=CALL_MASKS)),
    ("20_family_arrived", "shot", dict(src="rec2", tin=66.2, tlen=4.1, slot=6,
                                       cap="家屬 App　·　志工已到場，狀態即時更新",
                                       masks=PHONE_MASKS)),
    ("21_S7",       "card", dict(png="21_ph_S7", dur=7)),
    ("22_arch",     "card", dict(png="22a_arch", dur=8)),
    ("23_privacy",  "card", dict(png="22b_privacy", dur=7)),
    ("24_end",      "card", dict(png="23_end", dur=12)),
]

files, total = [], 0
for name, kind, a in EDL:
    out = os.path.join(SEG, name + ".mp4")
    if kind == "card":
        card_seg(os.path.join(CARDS, a["png"] + ".png"), a["dur"], out)
        total += a["dur"]
    elif kind == "cd":
        countdown_seg(a["dur"], out)
        total += a["dur"]
    else:
        cap = caption_png(a["cap"], name) if a.get("cap") else None
        footage_seg(SRC[a["src"]], a["tin"], a["tlen"], a["slot"], out,
                    caption=cap, masks=a.get("masks", ()),
                    fade_in=a.get("fade_in", True), fade_out=a.get("fade_out", True))
        total += a["slot"]
    files.append(out)
    print(f"  ✓ {name:22s} → 累計 {total:3d}s")

lst = os.path.join(SEG, "concat.txt")
with open(lst, "w") as fh:
    for p in files:
        fh.write(f"file '{p}'\n")

FINAL = os.path.join(DL, "jinsun-demo-3min-roughcut.mp4")
run(["ffmpeg", "-v", "error", "-f", "concat", "-safe", "0", "-i", lst,
     "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
     "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
     "-r", str(FPS), "-c:a", "aac", "-b:a", "128k", "-shortest",
     "-movflags", "+faststart", "-y", FINAL])
print("\n完成：", FINAL, f"（設計長度 {total}s）")
