#!/usr/bin/env python3
"""組裝 3 分鐘 demo 粗剪 v1：改用 2026-08-01 的高解析雙端錄影，取代原本的低解析手機錄影。

與 build.py 的差異：
- 新增 crop 參數：08-01 那兩支是 2924x1476 的桌面錄影，右側 767px 是 Claude 對話視窗，
  **一定要裁掉**（裡面是工作筆記，不能出現在送審影片）。
- 新增 fit='contain'：雙端同框那幾格是橫式（2157x1476），用等比縮到畫布內，
  不再套直式的「模糊底襯＋置中」。
- 07-29 的兩支（CleanShot 16.36.54 / 17.14.23）不採用：左半邊整片是 Claude Code
  視窗，且 app 內容只佔約 407px 寬，放大會糊。
"""
import os
import subprocess
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
CARDS = os.path.join(HERE, "cards")
SEG = os.path.join(HERE, "segments1")
CAP = os.path.join(HERE, "captions1")
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
    # 08-01 桌面錄影：左=家屬端、中=志工端、右=Claude 視窗（裁掉）
    "deskA": os.path.join(DL, "CleanShot 2026-08-01 at 10.36.33.mp4"),
    "deskB": os.path.join(DL, "CleanShot 2026-08-01 at 10.23.58.mp4"),
}

# 桌面錄影的裁切框（原始 2924x1476 座標）
# y 從 118 起跳：最上方 0–108 是 Chrome 的自動化提示列
# 「『Claude』已開始為這個瀏覽器偵錯　取消 ✕」——瀏覽器驅動留下的，不能入鏡。
CROP_BOTH = (2157, 1358, 0, 118)        # 家屬＋志工同框，右側 Claude 視窗已排除
CROP_FAMILY = (1089, 1358, 0, 118)      # 只要家屬端
CROP_VOLUNTEER = (1048, 1358, 1109, 118)  # 只要志工端

# 桌面錄影底部要遮的兩個瀏覽器殘留（座標是「裁切後」的畫面，不是原始畫面）：
#   ① Stop Claude 浮標（壓在志工端的底部導覽列上）
#   ② Chrome 的分頁小標「jinsun-family.vercel.app ✕」
# 不用裁掉是因為它們和 app 的底部導覽列重疊，切掉會連導覽列一起失去。
# ⚠️ 尺寸必須完全落在「裁切後」的畫面內（BOTH=2157x1358、FAMILY=1089x1358、
#    VOLUNTEER=1048x1358），超出一個 pixel ffmpeg 就整段吐不出來。
MASK_STOP_BOTH = (1450, 1220, 340, 90)
MASK_CHIP_BOTH = (680, 1292, 420, 60)
MASK_CHIP_FAMILY = (680, 1292, 400, 60)
MASK_STOP_VOLUNTEER = (350, 1220, 320, 90)

# 手機錄影要遮蔽的私人區域（原始 1080x2316 座標）
MASK_WIDGET = (940, 280, 140, 230)
MASK_BANNER = (250, 240, 680, 190)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("FFMPEG FAIL:", " ".join(cmd[:10]), "...")
        print(r.stderr[-2500:])
        raise SystemExit(1)


def caption_png(text, name):
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


def footage_seg(src, tin, tlen, slot, out, caption=None, masks=(), crop=None,
                fit="height", fade_in=True, fade_out=True):
    speed = min(2.0, slot / tlen)
    hold = max(0.0, slot - tlen * speed) + 0.6

    parts, cur = [], "0:v"
    if crop:
        cw, ch, cx, cy = crop
        parts.append(f"[{cur}]crop={cw}:{ch}:{cx}:{cy}[c]")
        cur = "c"
    for i, (mx, my, mw, mh) in enumerate(masks):
        a, b, o = f"a{i}", f"b{i}", f"m{i}"
        # boxblur 半徑不能超過該平面的一半——yuv420p 的色度平面只有亮度的一半大，
        # 所以要用 mw/2、mh/2 去算，否則像 60px 高的遮罩配半徑 26 會讓整段編不出來。
        r = max(2, min(20, (mw // 2 - 1) // 2, (mh // 2 - 1) // 2))
        parts.append(f"[{cur}]split=2[{a}][{b}]")
        parts.append(f"[{b}]crop={mw}:{mh}:{mx}:{my},boxblur={r}:3[{o}]")
        parts.append(f"[{a}][{o}]overlay={mx}:{my}[p{i}]")
        cur = f"p{i}"

    parts.append(f"[{cur}]setpts=PTS*{speed:.4f},fps={FPS},"
                 f"tpad=stop_mode=clone:stop_duration={hold:.2f}[m]")
    parts.append("[m]split=2[bg0][fg0]")
    parts.append(f"[bg0]scale={W}:-1,boxblur=42:5,crop={W}:{H},"
                 f"eq=brightness=-0.30:saturation=0.55[bg]")
    if fit == "contain":
        # 橫式來源：等比縮到畫布內（留邊），不裁切
        parts.append(f"[fg0]scale={W - 200}:{H - 120}:force_original_aspect_ratio=decrease[fg]")
    else:
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
    parts.append(f"[{last}]{','.join(fades + ['format=yuv420p'])}[v]")

    run(["ffmpeg", "-v", "error"] + inputs +
        ["-filter_complex", ";".join(parts), "-map", "[v]", "-t", str(slot),
         "-r", str(FPS), "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
         "-pix_fmt", "yuv420p", "-y", out])


PHONE_MASKS = (MASK_WIDGET,)
CALL_MASKS = (MASK_WIDGET, MASK_BANNER)

EDL = [
    ("01_hook",      "card", dict(png="01_hook", dur=6)),
    ("02_S1",        "card", dict(png="02_ph_S1", dur=8)),
    ("03_pain1",     "card", dict(png="03_pain1", dur=8)),
    ("04_pain2",     "card", dict(png="04_pain2", dur=8)),
    ("05_pain3",     "card", dict(png="05_pain3", dur=8)),
    ("06_product",   "card", dict(png="06_product", dur=7)),
    ("07_hw_out",    "shot", dict(src="hw_out", tin=2.0, tlen=12.0, slot=12,
                                  cap="實機　·　蜂巢喇叭孔／相機鏡頭／狀態燈號",
                                  fade_out=False)),
    ("08_hw_in",     "shot", dict(src="hw_in", tin=0.0, tlen=5.6, slot=6,
                                  cap="機殼、電路、韌體　全部自己做",
                                  fade_in=False)),
    ("09_S3",        "card", dict(png="09_ph_S3", dur=5)),
    ("10_S4",        "card", dict(png="10_ph_S4", dur=9)),
    ("11_countdown", "cd",   dict(dur=11)),
    # ↓↓↓ 以下四格改用 08-01 高解析雙端錄影 ↓↓↓
    ("12_both_ends", "shot", dict(src="deskB", tin=3.0, tlen=8.0, slot=8,
                                  cap="家屬端與志工端　·　同一筆事件，即時同步",
                                  crop=CROP_BOTH, fit="contain",
                                  masks=(MASK_STOP_BOTH, MASK_CHIP_BOTH))),
    ("13_family_map", "shot", dict(src="deskB", tin=14.0, tlen=8.0, slot=8,
                                   cap="家屬 App　·　派遣進度與志工位置即時更新",
                                   crop=CROP_FAMILY, masks=(MASK_CHIP_FAMILY,))),
    ("14_volunteer",  "shot", dict(src="deskB", tin=24.0, tlen=6.0, slot=6,
                                   cap="志工 App　·　任務卡與到場狀態",
                                   crop=CROP_VOLUNTEER,
                                   masks=(MASK_STOP_VOLUNTEER,))),
    ("15_S5",        "card", dict(png="15_ph_S5", dur=7)),
    ("16_S6",        "card", dict(png="16_ph_S6", dur=8)),
    ("17_ai_advice", "shot", dict(src="deskA", tin=700.0, tlen=6.0, slot=6,
                                  cap="家屬 App　·　AI 照護建議",
                                  crop=CROP_FAMILY, masks=(MASK_CHIP_FAMILY,))),
    ("18_incoming",  "shot", dict(src="rec2", tin=6.2, tlen=3.6, slot=6,
                                  cap="家屬端　·　號碼已遮蔽，透過金孫收音機安全轉接",
                                  masks=CALL_MASKS)),
    ("19_incall",    "shot", dict(src="rec1", tin=22.5, tlen=4.0, slot=6,
                                  cap="通話接通　·　雙方都拿不到對方的電話號碼",
                                  masks=CALL_MASKS)),
    ("20_resolved",  "shot", dict(src="deskB", tin=40.0, tlen=6.0, slot=6,
                                  cap="家屬 App　·　志工已到場，可一鍵確認平安",
                                  crop=CROP_FAMILY, masks=(MASK_CHIP_FAMILY,))),
    ("21_S7",        "card", dict(png="21_ph_S7", dur=7)),
    ("22_arch",      "card", dict(png="22a_arch", dur=8)),
    ("23_privacy",   "card", dict(png="22b_privacy", dur=7)),
    ("24_end",       "card", dict(png="23_end", dur=9)),
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
                    caption=cap, masks=a.get("masks", ()), crop=a.get("crop"),
                    fit=a.get("fit", "height"),
                    fade_in=a.get("fade_in", True), fade_out=a.get("fade_out", True))
        total += a["slot"]
    files.append(out)
    print(f"  ✓ {name:18s} → 累計 {total:3d}s")

lst = os.path.join(SEG, "concat.txt")
with open(lst, "w") as fh:
    for p in files:
        fh.write(f"file '{p}'\n")

FINAL = os.path.join(DL, "jinsun-demo-3min-roughcut1.mp4")
run(["ffmpeg", "-v", "error", "-f", "concat", "-safe", "0", "-i", lst,
     "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
     "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
     "-r", str(FPS), "-c:a", "aac", "-b:a", "128k", "-shortest",
     "-movflags", "+faststart", "-y", FINAL])
print("\n完成：", FINAL, f"（設計長度 {total}s）")
