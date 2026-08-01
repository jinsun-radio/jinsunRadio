#!/usr/bin/env python3
"""生成 3 分鐘 demo 影片的所有字卡 PNG（1920x1080）。"""
import os
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cards")
os.makedirs(OUT, exist_ok=True)

W, H = 1920, 1080
BG = (14, 17, 22)
FG = (245, 245, 244)
MUTED = (156, 163, 175)
ORANGE = (251, 146, 60)
BLUE = (59, 130, 246)
DIM = (75, 85, 99)

HEITI_M = "/System/Library/Fonts/STHeiti Medium.ttc"
HEITI_L = "/System/Library/Fonts/STHeiti Light.ttc"


def f(size, light=False):
    return ImageFont.truetype(HEITI_L if light else HEITI_M, size, index=0)


def new(bg=BG):
    im = Image.new("RGB", (W, H), bg)
    return im, ImageDraw.Draw(im)


def center(d, y, text, font, fill=FG, spacing=18):
    bbox = d.textbbox((0, 0), text, font=font)
    d.text(((W - (bbox[2] - bbox[0])) / 2 - bbox[0], y), text, font=font, fill=fill)
    return bbox[3] - bbox[1]


def block(d, y, lines, font, fill=FG, gap=26):
    """置中多行，回傳結束 y。"""
    for ln in lines:
        h = center(d, y, ln, font, fill)
        y += h + gap
    return y


def save(im, name):
    p = os.path.join(OUT, name + ".png")
    im.save(p)
    print("card:", name)
    return p


def dashed_rect(d, box, color, dash=22, gap=14, width=3):
    x0, y0, x1, y1 = box
    for x in range(x0, x1, dash + gap):
        d.line([(x, y0), (min(x + dash, x1), y0)], fill=color, width=width)
        d.line([(x, y1), (min(x + dash, x1), y1)], fill=color, width=width)
    for y in range(y0, y1, dash + gap):
        d.line([(x0, y), (x0, min(y + dash, y1))], fill=color, width=width)
        d.line([(x1, y), (x1, min(y + dash, y1))], fill=color, width=width)


# ---------- A 段 ----------
im, d = new()
center(d, 470, "他知道自己要什麼。", f(78))
save(im, "01_hook")


# ---------- B 段：三個斷點 ----------
def pain(idx, label, headline, subs, name):
    im, d = new()
    d.line([(210, 300), (210, 780)], fill=ORANGE, width=6)
    x = 280
    d.text((x, 300), label, font=f(34), fill=ORANGE)
    d.text((x, 372), headline, font=f(84))
    y = 520
    for s in subs:
        d.text((x, y), s, font=f(40, light=True), fill=MUTED)
        y += 68
    d.text((W - 260, 300), idx, font=f(140), fill=(32, 37, 46))
    save(im, name)


pain("01", "斷點一", "入口失效",
     ["看不懂字、按不準、手機根本拿不到", "穿戴裝置在充電座上，洗澡時取下"], "03_pain1")
pain("02", "斷點二", "沒人知道",
     ["跌倒了、久臥了，家人都在上班", "裝監視器？長輩不想被看，家屬也沒空看"], "04_pain2")
pain("03", "斷點三", "通知了，然後呢",
     ["子女在外縣市，短時間趕不回來", "叫救護車不一定符合需求", "真正需要的是有人先到現場"], "05_pain3")


# ---------- C 段：產品標題 ----------
im, d = new()
center(d, 380, "金孫收音機", f(112))
center(d, 540, "一鍵語音求助與社區照護派遣系統", f(42, light=True), MUTED)
d.line([(760, 660), (1160, 660)], fill=ORANGE, width=4)
center(d, 700, "我們沒有要長輩學會新的東西", f(38, light=True), MUTED)
save(im, "06_product")


# ---------- D 段：20 秒倒數（動態）----------
os.makedirs(os.path.join(OUT, "countdown"), exist_ok=True)
FPS_CD = 6
DUR_CD = 12
for i in range(FPS_CD * DUR_CD):
    t = i / FPS_CD
    n = max(0, 20 - int(t / DUR_CD * 20))
    im, d = new()
    center(d, 210, "系統已語音詢問　·　等待長輩回應", f(38, light=True), MUTED)
    col = ORANGE if n > 6 else (239, 68, 68)
    center(d, 330, f"{n:02d}", f(300), col)
    center(d, 700, "秒", f(44, light=True), MUTED)
    # 進度條
    bw, bx, by = 900, (W - 900) // 2, 830
    d.rounded_rectangle([bx, by, bx + bw, by + 14], 7, fill=(38, 43, 52))
    prog = int(bw * (1 - n / 20))
    if prog > 0:
        d.rounded_rectangle([bx, by, bx + prog, by + 14], 7, fill=col)
    if n == 0:
        center(d, 900, "無回應　→　自動升級為緊急事件", f(44), (239, 68, 68))
    im.save(os.path.join(OUT, "countdown", f"cd_{i:04d}.png"))
print("card: countdown (%d frames)" % (FPS_CD * DUR_CD))


# ---------- E 段：架構 ----------
im, d = new()
center(d, 130, "感知　→　決策　→　行動　→　回報", f(64))
center(d, 240, "四層構成完整閉環", f(36, light=True), MUTED)
rows = [
    ("感知", "大按鈕　·　麥克風　·　近端視覺", BLUE),
    ("決策", "意圖分類　·　三級風險分級　·　20 秒升級", BLUE),
    ("行動", "裝置語音回應　·　就近派單　·　家屬通知", ORANGE),
    ("回報", "到場確認　·　結案處置　·　社工後台留痕", ORANGE),
]
y = 360
for name, desc, col in rows:
    d.rounded_rectangle([300, y, 1620, y + 120], 14, outline=col, width=3)
    d.text((360, y + 34), name, font=f(52), fill=col)
    d.text((560, y + 44), desc, font=f(36, light=True), fill=FG)
    y += 148
save(im, "22a_arch")

im, d = new()
center(d, 150, "隱私邊界", f(88))
d.rounded_rectangle([260, 340, 920, 800], 18, outline=BLUE, width=4)
d.text((320, 390), "長輩家中", font=f(40), fill=BLUE)
for i, s in enumerate(["原始影像", "原始聲音", "跌倒推論"]):
    d.text((320, 480 + i * 78), "●  " + s, font=f(42, light=True), fill=FG)
d.text((320, 726), "永遠不離開這個框", font=f(34), fill=BLUE)
d.line([(940, 570), (1180, 570)], fill=ORANGE, width=4)
d.polygon([(1180, 555), (1210, 570), (1180, 585)], fill=ORANGE)
d.text((940, 490), "僅主動求助的那段語音", font=f(32, light=True), fill=ORANGE)
d.rounded_rectangle([1240, 460, 1660, 680], 18, outline=DIM, width=3)
d.text((1300, 510), "雲端", font=f(40), fill=MUTED)
d.text((1300, 590), "意圖理解　·　派遣", font=f(32, light=True), fill=MUTED)
center(d, 900, "這條線，我們從第一天就畫死了", f(40), FG)
save(im, "22b_privacy")


# ---------- F 段：收尾 ----------
im, d = new()
center(d, 350, "讓不會用手機的長輩", f(66))
center(d, 450, "只按一個按鈕", f(66))
center(d, 550, "就能得到家人和整個社區的幫助", f(66), ORANGE)
d.line([(810, 700), (1110, 700)], fill=DIM, width=3)
center(d, 760, "金孫收音機", f(52))
center(d, 840, "一鍵語音求助與社區照護派遣系統", f(32, light=True), MUTED)
save(im, "23_end")


# ---------- 待補素材卡 ----------
def placeholder(code, title, desc, dur, narration, name):
    im, d = new((18, 15, 12))
    dashed_rect(d, (140, 120, W - 140, H - 120), ORANGE)
    # chip
    d.rounded_rectangle([200, 190, 200 + 250, 190 + 62], 31, fill=ORANGE)
    d.text((236, 202), "待補素材", font=f(38), fill=(18, 15, 12))
    d.text((490, 200), code, font=f(44), fill=ORANGE)
    d.text((200, 320), title, font=f(76))
    y = 460
    for ln in desc:
        d.text((200, y), "·  " + ln, font=f(40, light=True), fill=(226, 226, 224))
        y += 66
    d.text((200, 790), f"建議長度　{dur}", font=f(36), fill=ORANGE)
    if narration:
        d.line([(200, 862), (W - 200, 862)], fill=(70, 58, 44), width=2)
        d.text((200, 892), "旁白／裝置語音：" + narration, font=f(32, light=True), fill=MUTED)
    save(im, name)


placeholder("S1", "長者打不開手機",
            ["特寫老人的手在螢幕上反覆滑動、解鎖失敗", "不露臉，只拍手部與手機", "自然光，手抖的細節要留住"],
            "10 秒", "他意識清楚，他能說話，他知道自己需要什麼。但他的手，打不開手機。",
            "02_ph_S1")

placeholder("S3", "跌倒情境",
            ["客廳，人倒地後畫面外", "只拍到腳與地板，不要戲劇化", "悶響之後留三秒安靜"],
            "5 秒", "（無旁白，環境音）", "09_ph_S3")

placeholder("S4", "收音機主動語音詢問",
            ["收音機喇叭孔特寫，LED 由綠轉紅", "務必收裝置的原始音軌，不要事後配音",
             "這是全片最有說服力的一個聲音"],
            "9 秒", "裝置：我看到您好像跌倒了，您還好嗎？需要幫忙嗎？", "10_ph_S4")

placeholder("S5", "收音機播報志工 ETA",
            ["接續 S4 的收音機特寫", "可帶家屬 App 地圖上志工圖示開始移動", "插 1～2 秒志工騎車外景"],
            "7 秒", "裝置：志工阿明大約六分鐘就到，您再稍等一下，我會一直陪著您喔。", "15_ph_S5")

placeholder("S6", "★ 接近預告（差異化重點）",
            ["家屬 App 地圖上浮出距離數字 250 m 並閃動", "切收音機特寫，LED 由紅轉橘",
             "結尾帶一聲敲門聲", "這段不要趕，是全片最關鍵的差異化"],
            "8 秒",
            "裝置：志工阿明快到您家門口了，等一下會敲門，您不用緊張，是我們請來幫您的人。",
            "16_ph_S6")

placeholder("S7", "社工後台與 Excel 匯出",
            ["桌機瀏覽器錄屏（橫式，本段可滿版）", "dashboard 三色狀態 → 派遣監控 → 點「匯出 Excel」",
             "快閃 Excel 三張工作表：事件紀錄／派遣紀錄／長輩名冊"],
            "7 秒", "社工後台留下完整紀錄，一鍵匯出，直接用於政府申報。", "21_ph_S7")
