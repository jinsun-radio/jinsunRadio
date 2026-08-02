import type { CSSProperties, ReactNode } from 'react';
import type { DesignSystem, Page, SlideMeta, SlideTransition } from '@open-slide/core';
import { useSlidePageNumber } from '@open-slide/core';

import devReal from './assets/dev_real.jpg';
import devInternal from './assets/dev_internal.jpg';
import four from './assets/four.png';
import pElder from './assets/p_elder.png';
import pChild from './assets/p_child.png';
import pWorker from './assets/p_worker.png';
import pVolunteer from './assets/p_volunteer.png';
import appElder from './assets/app_elder.png';
import appFamily from './assets/app_family.png';
import appVolunteer from './assets/app_volunteer.png';
import appWorker from './assets/app_worker.png';
import pdBtn from './assets/pd_btn.png';
import pdBig from './assets/pd_big.png';
import pdLang from './assets/pd_lang.png';
import radio from './assets/radio.png';

/* ══════════════════════════════════════════════════════════════════════
   金孫收音機 · 台灣十年提案
   Ported from deck/index.html (tpl-pitch-deck) onto the 1920×1080 canvas.
   Original CSS pixel values are scaled ~1.35× so the fluid viewport deck
   reads at the same weight inside the fixed canvas.
   ══════════════════════════════════════════════════════════════════ */

export const design: DesignSystem = {
  palette: { bg: '#FFFFFF', text: '#1C1712', accent: '#F96C1A' },
  fonts: {
    display: '"Inter", "PingFang TC", "Noto Sans TC", ui-sans-serif, system-ui, sans-serif',
    body: '"Inter", "PingFang TC", "Noto Sans TC", ui-sans-serif, system-ui, sans-serif',
  },
  typeScale: { hero: 104, body: 21 },
  radius: 27,
};

/* ── colors outside the DesignSystem shape ─────────────────────────── */
const surface = '#FFFFFF';
const surface2 = '#F5F1EC';
const border = 'rgba(40,30,20,.09)';
const borderStrong = 'rgba(40,30,20,.18)';
const text1 = '#1C1712';
const text2 = '#5A5147';
const text3 = '#9A8F82';
const blue = '#0E6EA8';
const orange = '#F96C1A';
const amber = '#FFB14D';
const deepBlue = '#1E88D6';
const purple = '#9A6FA0';
const green = '#2E9E5B';
const red = '#E5484D';
const pain = '#B23B2E';
const mono = '"SF Mono", ui-monospace, SFMono-Regular, Menlo, monospace';

const GRAD = 'linear-gradient(120deg,#FFB14D 0%,#F96C1A 42%,#1E88D6 100%)';
const GRAD_SOFT = 'linear-gradient(135deg,#FFF3E9 0%,#FDEEE2 45%,#E7F3FB 100%)';
const SHADOW = '0 19px 54px rgba(60,40,20,.08), 0 3px 11px rgba(60,40,20,.04)';

const gradText: CSSProperties = {
  background: GRAD,
  WebkitBackgroundClip: 'text',
  backgroundClip: 'text',
  color: 'transparent',
};

/* ── page shells ───────────────────────────────────────────────────── */
const pageBase: CSSProperties = {
  position: 'relative',
  width: '100%',
  height: '100%',
  boxSizing: 'border-box',
  background: 'var(--osd-bg)',
  color: 'var(--osd-text)',
  fontFamily: 'var(--osd-font-body)',
  overflow: 'hidden',
  display: 'flex',
  flexDirection: 'column',
  justifyContent: 'flex-start',
};

/** standard slide: 44/90/74 → ×1.35 */
const padded: CSSProperties = { ...pageBase, padding: '58px 120px 96px' };

/** full-bleed slide (threefull / fourfull / appqfull) */
const bleed: CSSProperties = { ...pageBase, padding: 0 };

/* ── chrome ────────────────────────────────────────────────────────── */
const Footer = ({ label }: { label: string }) => {
  const { current, total } = useSlidePageNumber();
  return (
    <div
      style={{
        position: 'absolute',
        left: 54,
        right: 54,
        bottom: 32,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        fontSize: 17,
        color: text3,
        zIndex: 10,
        pointerEvents: 'none',
      }}
    >
      <span>{label}</span>
      <span>
        {current} / {total}
      </span>
    </div>
  );
};

const BleedNum = () => {
  const { current, total } = useSlidePageNumber();
  return (
    <div
      style={{
        position: 'absolute',
        right: 27,
        bottom: 22,
        zIndex: 6,
        color: 'rgba(255,255,255,.7)',
        fontSize: 19,
        fontWeight: 700,
      }}
    >
      {current} / {total}
    </div>
  );
};

const SectionNum = ({ n }: { n: string }) => (
  <span
    style={{
      position: 'absolute',
      right: 81,
      bottom: 40,
      fontSize: 256,
      fontWeight: 900,
      lineHeight: 0.9,
      letterSpacing: '-.05em',
      color: surface2,
      zIndex: 0,
    }}
  >
    {n}
  </span>
);

const NumTag = ({ children }: { children: ReactNode }) => (
  <p
    style={{
      position: 'relative',
      zIndex: 1,
      margin: 0,
      fontSize: 19,
      fontWeight: 800,
      color: orange,
      letterSpacing: '.14em',
      lineHeight: 1.5,
    }}
  >
    {children}
  </p>
);

const h2Style: CSSProperties = {
  position: 'relative',
  zIndex: 1,
  margin: '10px 0 0',
  fontFamily: 'var(--osd-font-display)',
  fontSize: 60,
  lineHeight: 1.1,
  fontWeight: 800,
  letterSpacing: '-.025em',
};

/* ── inline emphasis (mirrors the original `b` colour rules) ────────── */
const Bb = ({ children }: { children: ReactNode }) => (
  <b style={{ color: blue, fontWeight: 800 }}>{children}</b>
);
const Bo = ({ children }: { children: ReactNode }) => (
  <b style={{ color: orange, fontWeight: 800 }}>{children}</b>
);
const Bl = ({ children }: { children: ReactNode }) => (
  <b style={{ color: '#9FD6FF', fontWeight: 800 }}>{children}</b>
);
const Bd = ({ children }: { children: ReactNode }) => (
  <b style={{ color: text1, fontWeight: 800 }}>{children}</b>
);
const G = ({ children }: { children: ReactNode }) => <span style={gradText}>{children}</span>;

const badgeBase: CSSProperties = {
  display: 'inline-block',
  fontSize: 15.5,
  fontWeight: 800,
  borderRadius: 999,
  padding: '2px 12px',
  marginLeft: 8,
  whiteSpace: 'nowrap',
  verticalAlign: 3,
};

const Wip = ({ dark }: { dark?: boolean }) => (
  <span
    style={{
      ...badgeBase,
      background: dark ? 'rgba(255,177,77,.22)' : '#FFF0DC',
      color: dark ? '#FFD9A8' : '#9A4A08',
      border: `1px solid ${dark ? 'rgba(255,177,77,.6)' : '#F5C089'}`,
    }}
  >
    開發中
  </span>
);

const DoneTag = ({ flush }: { flush?: boolean }) => (
  <span
    style={{
      ...badgeBase,
      marginLeft: flush ? 0 : 8,
      background: '#E4F5EA',
      color: '#1C6B3D',
      border: '1px solid #9AD5B0',
    }}
  >
    已完成
  </span>
);

const NewTag = ({ size = 16 }: { size?: number }) => (
  <span
    style={{
      fontSize: size,
      fontWeight: 800,
      color: '#fff',
      background: orange,
      borderRadius: 999,
      padding: '2px 13px',
    }}
  >
    新角色
  </span>
);

/* ── shared building blocks ────────────────────────────────────────── */
const chartWrap: CSSProperties = {
  background: surface,
  border: `1px solid ${border}`,
  borderRadius: 27,
  padding: '27px 30px',
  boxShadow: SHADOW,
  boxSizing: 'border-box',
};

const ctStyle: CSSProperties = {
  fontSize: 20,
  fontWeight: 800,
  marginBottom: 8,
  lineHeight: 1.4,
};

const figcapStyle: CSSProperties = {
  fontSize: 17.5,
  color: text3,
  marginTop: 12,
  textAlign: 'center',
  lineHeight: 1.4,
};

const demoNote: CSSProperties = {
  marginTop: 22,
  background: surface2,
  border: `1px dashed ${borderStrong}`,
  borderRadius: 19,
  padding: '22px 27px',
  fontSize: 21,
  color: text2,
  lineHeight: 1.5,
  boxSizing: 'border-box',
};

const cardStyle: CSSProperties = {
  background: surface,
  border: `1px solid ${border}`,
  borderRadius: 27,
  padding: '35px 38px',
  boxShadow: SHADOW,
  boxSizing: 'border-box',
};

const Code = ({ children }: { children: ReactNode }) => (
  <code
    style={{
      fontFamily: mono,
      fontSize: 17,
      background: surface2,
      border: `1px solid ${border}`,
      borderRadius: 7,
      padding: '1px 7px',
      color: text1,
    }}
  >
    {children}
  </code>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 1 — 影片（首頁）
   ══════════════════════════════════════════════════════════════════ */

const StatCell = ({ n, children }: { n: string; children: ReactNode }) => (
  <div
    style={{
      background: 'rgba(255,255,255,.78)',
      border: `1px solid ${border}`,
      borderRadius: 19,
      padding: '16px 19px',
      boxShadow: SHADOW,
      boxSizing: 'border-box',
    }}
  >
    <b
      style={{
        ...gradText,
        display: 'block',
        fontSize: 44,
        fontWeight: 900,
        lineHeight: 1.05,
        letterSpacing: '-.02em',
      }}
    >
      {n}
    </b>
    <span style={{ display: 'block', marginTop: 7, fontSize: 17, color: text2, lineHeight: 1.4 }}>
      {children}
    </span>
  </div>
);

const Cover: Page = () => (
  <div style={{ ...padded, justifyContent: 'center' }}>
    {/* cover-bg + blobs */}
    <div style={{ position: 'absolute', inset: 0, background: GRAD_SOFT, zIndex: 0 }} />
    <div
      style={{
        position: 'absolute',
        right: -189,
        top: -189,
        width: 756,
        height: 756,
        borderRadius: '50%',
        background: GRAD,
        filter: 'blur(14px)',
        opacity: 0.3,
        zIndex: 0,
      }}
    />
    <div
      style={{
        position: 'absolute',
        left: -243,
        bottom: -270,
        width: 621,
        height: 621,
        borderRadius: '50%',
        background: GRAD,
        filter: 'blur(14px)',
        opacity: 0.18,
        zIndex: 0,
      }}
    />

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'flex',
        gap: 54,
        alignItems: 'center',
      }}
    >
      {/* ── left ─────────────────────────────────────────────────── */}
      <div style={{ flex: '1.04 1 0', minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 19 }}>
          <svg width="49" height="49" viewBox="0 0 24 24" aria-hidden="true">
            <defs>
              <linearGradient id="jrHeart" x1="0" x2="1" y1="0" y2="1">
                <stop offset="0" stopColor="#F96C1A" />
                <stop offset="1" stopColor="#1E88D6" />
              </linearGradient>
            </defs>
            <path
              d="M12 20.3l-1.3-1.2C6 14.9 3 12.2 3 8.9 3 6.3 5 4.4 7.5 4.4c1.5 0 2.9.7 3.8 1.9.9-1.2 2.3-1.9 3.8-1.9C20.6 4.4 22 6.3 22 8.9c0 3.3-3 6-7.7 10.2L12 20.3z"
              fill="url(#jrHeart)"
            />
          </svg>
          <span style={{ fontSize: 35, fontWeight: 900, letterSpacing: '-.01em', color: text1 }}>
            金孫收音機
          </span>
        </div>

        <p style={{ margin: 0, fontSize: 19, fontWeight: 700, color: blue, letterSpacing: '.06em' }}>
          台灣十年提案 · 智慧照護與居家健康
        </p>

        <h1
          style={{
            margin: '0 0 24px',
            fontFamily: 'var(--osd-font-display)',
            fontSize: 'var(--osd-size-hero)',
            lineHeight: 1.06,
            fontWeight: 900,
            letterSpacing: '-.03em',
          }}
        >
          獨居長輩出事沒人知，
          <br />
          <G>能到場的人卻不夠</G>。
        </h1>

        <p
          style={{
            margin: '24px 0 0',
            fontSize: 29,
            lineHeight: 1.5,
            fontWeight: 300,
            color: text2,
            maxWidth: 830,
          }}
        >
          <b style={{ fontWeight: 700 }}>時間銀行</b>＋<b style={{ fontWeight: 700 }}>國台語都能通</b>
          的金孫收音機——讓長輩的需求只要<b style={{ fontWeight: 700 }}>講一句話</b>
          ，就能像 Uber 點餐一樣被接住。
        </p>

        <div
          style={{
            display: 'grid',
            gridTemplateColumns: 'repeat(3, 1fr)',
            gap: 19,
            marginTop: 28,
          }}
        >
          <StatCell n="20.1%">
            台灣每 5 人就有 1 位 65 歲以上長輩
            <br />
            467 萬人・2025 年底正式進入超高齡社會
          </StatCell>
          <StatCell n="70 萬人">
            獨居、或僅與 65 歲以上伴侶同住的長者
            <br />
            衛福部 2026 年 6 月
          </StatCell>
          <StatCell n="93%">
            台北市 5 萬名獨居長輩中，僅 3,598 人配有緊急求助設備
            <br />
            其餘<Bo>出事只能靠鄰居聞到味道</Bo>
          </StatCell>
        </div>

        <div
          style={{
            display: 'inline-block',
            marginTop: 26,
            background: GRAD,
            color: '#fff',
            fontWeight: 800,
            padding: '15px 30px',
            borderRadius: 999,
            boxShadow: '0 16px 38px rgba(249,108,26,.3)',
            fontSize: 21,
          }}
        >
          ▶ 2 分鐘情境影片・連結待補
        </div>
      </div>

      {/* ── right · videobox ─────────────────────────────────────── */}
      <div style={{ flex: '0.96 1 0', minWidth: 0 }}>
        <div
          style={{
            position: 'relative',
            width: '100%',
            aspectRatio: '16 / 10',
            backgroundImage: `url(${devReal})`,
            backgroundSize: 'cover',
            backgroundPosition: 'center',
            borderRadius: 27,
            boxShadow: '0 32px 80px rgba(60,40,20,.2)',
            overflow: 'hidden',
          }}
        >
          <div
            style={{
              position: 'absolute',
              inset: 0,
              background: 'linear-gradient(to top, rgba(0,0,0,.5), rgba(0,0,0,.05))',
            }}
          />
          <div
            style={{
              position: 'absolute',
              top: '50%',
              left: '50%',
              transform: 'translate(-50%, -50%)',
              width: 105,
              height: 105,
              borderRadius: '50%',
              background: GRAD,
              color: '#fff',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 40,
              zIndex: 2,
              boxShadow: '0 14px 40px rgba(0,0,0,.35)',
            }}
          >
            ▶
          </div>
          <div
            style={{
              position: 'absolute',
              left: 24,
              bottom: 20,
              color: '#fff',
              fontWeight: 800,
              fontSize: 20,
              zIndex: 2,
              textShadow: '0 1px 5px rgba(0,0,0,.5)',
            }}
          >
            Live Demo 影片
          </div>
        </div>
      </div>
    </div>

    <Footer label="2026 AI 創新獎" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 2 — 問題 · 規模
   ══════════════════════════════════════════════════════════════════ */

const CHART_SVG_H = 606;

const Scale: Page = () => (
  <div style={padded}>
    <SectionNum n="01" />
    <NumTag>問題 · 規模</NumTag>
    <h2 style={h2Style}>
      每 5 個台灣人就有 1 位長輩，<G>70 萬人獨居</G>。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: 54,
        alignItems: 'stretch',
        marginTop: 22,
      }}
    >
      {/* ── 老年人口趨勢 ──────────────────────────────────────── */}
      <div style={{ ...chartWrap, display: 'flex', flexDirection: 'column' }}>
        <div style={ctStyle}>65 歲以上人口（萬人）與占總人口比率</div>
        <svg
          viewBox="0 0 500 470"
          preserveAspectRatio="xMidYMid meet"
          style={{ width: '100%', height: CHART_SVG_H, display: 'block' }}
          role="img"
          aria-label="老年人口與占比趨勢"
        >
          <defs>
            <linearGradient id="jrGrowthFill" x1="0" y1="1" x2="0" y2="0">
              <stop offset="0" stopColor="#F96C1A" stopOpacity=".16" />
              <stop offset="1" stopColor="#1E88D6" stopOpacity=".05" />
            </linearGradient>
            <linearGradient id="jrGrowthLine" x1="0" x2="1">
              <stop offset="0" stopColor="#F96C1A" />
              <stop offset="1" stopColor="#1E88D6" />
            </linearGradient>
          </defs>
          <line x1="60" y1="420" x2="470" y2="420" stroke={borderStrong} strokeWidth="2" />
          <polygon points="95,213 290,88 450,111 450,420 95,420" fill="url(#jrGrowthFill)" />
          <polyline
            fill="none"
            stroke="url(#jrGrowthLine)"
            strokeWidth="7"
            strokeLinecap="round"
            strokeLinejoin="round"
            points="95,213 290,88 450,111"
          />
          <g textAnchor="middle">
            <circle cx="95" cy="213" r="8" fill={orange} />
            <text x="95" y="172" fontSize="30" fill={orange} fontWeight="900">
              20.1%
            </text>
            <text x="95" y="197" fontSize="19" fill={text1} fontWeight="800">
              467 萬人
            </text>
            <text x="95" y="452" fontSize="16" fill={text2} fontWeight="700">
              2025 實際
            </text>

            <circle cx="290" cy="88" r="7" fill={purple} />
            <text x="290" y="68" fontSize="16" fill={text2} fontWeight="800">
              老年人口達高峰
            </text>
            <text x="290" y="452" fontSize="16" fill={text2} fontWeight="700">
              2050
            </text>

            <circle cx="450" cy="111" r="8" fill={deepBlue} />
            <text x="450" y="70" fontSize="30" fill={deepBlue} fontWeight="900">
              46.5%
            </text>
            <text x="450" y="95" fontSize="19" fill={text1} fontWeight="800">
              697 萬人
            </text>
            <text x="450" y="452" fontSize="16" fill={text2} fontWeight="700">
              2070 推估
            </text>
          </g>
        </svg>
        <div style={figcapStyle}>
          45 年內老年人口再增 248 萬人；扶老比從 <b>3.6 位青壯年撐 1 位長輩</b> 掉到 <b>1 : 1</b>。
          <br />
          來源：內政部戶政司（2025 年底實際 4,673,155 人 / 20.06%）、國發會《中華民國人口推估
          2024–2070》中推估
        </div>
      </div>

      {/* ── 服務對象漏斗 ──────────────────────────────────────── */}
      <div style={{ ...chartWrap, display: 'flex', flexDirection: 'column' }}>
        <div style={ctStyle}>政府自己算出來的服務對象漏斗 · 全是官方數字</div>
        <svg
          viewBox="0 0 460 470"
          preserveAspectRatio="xMidYMid meet"
          style={{ width: '100%', height: CHART_SVG_H, display: 'block' }}
          role="img"
          aria-label="服務對象人口漏斗"
        >
          <g textAnchor="middle" fontWeight="800">
            <polygon points="30,18 430,18 394,115 66,115" fill={amber} />
            <text x="230" y="58" fontSize="17" fill="#7A4A10">
              65 歲以上（全台 20.1%）
            </text>
            <text x="230" y="88" fontSize="23" fill="#7A4A10">
              467 萬人
            </text>

            <polygon points="66,123 394,123 358,220 102,220" fill={orange} />
            <text x="230" y="163" fontSize="16" fill="#fff">
              ＋ 獨居或僅與 65+ 伴侶同住
            </text>
            <text x="230" y="193" fontSize="21" fill="#fff">
              約 70 萬人
            </text>

            <polygon points="102,228 358,228 322,325 138,325" fill="#5F93C4" />
            <text x="230" y="268" fontSize="15" fill="#fff">
              ＋ 政府訪視後評估「需要支持」
            </text>
            <text x="230" y="298" fontSize="20" fill="#fff">
              約 35 萬人
            </text>

            <polygon points="138,333 322,333 286,430 174,430" fill={deepBlue} />
            <text x="230" y="373" fontSize="14" fill="#fff">
              ＋ 本期已編列補助的救援設備
            </text>
            <text x="230" y="403" fontSize="20" fill="#fff">
              7 萬台
            </text>
          </g>
        </svg>
        <div style={figcapStyle}>
          最底層的 <b>7 萬台</b> 不是我們猜的市場，是<b>政府這兩年已經編列預算要買的量</b>。
          <br />
          來源：衛福部獨居長者支持方案（62.5 億元特別預算，2026–2027 訪視 70 萬人）
        </div>
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 3 — 問題 · 人力
   ══════════════════════════════════════════════════════════════════ */

const HrRow = ({ icon, n, children }: { icon: string; n: string; children: ReactNode }) => (
  <div
    style={{
      display: 'flex',
      gap: 18,
      alignItems: 'flex-start',
      padding: '10px 0',
      borderTop: `1px solid ${border}`,
    }}
  >
    <div style={{ fontSize: 30, lineHeight: 1.1, flex: '0 0 35px' }}>{icon}</div>
    <div style={{ minWidth: 0 }}>
      <div
        style={{
          ...gradText,
          fontSize: 30,
          fontWeight: 900,
          letterSpacing: '-.02em',
          lineHeight: 1.15,
        }}
      >
        {n}
      </div>
      <p style={{ margin: '2px 0 0', fontSize: 19, color: text2, lineHeight: 1.45 }}>{children}</p>
    </div>
  </div>
);

const Src = ({ children }: { children: ReactNode }) => (
  <span style={{ display: 'block', fontSize: 15.5, color: text3, marginTop: 4 }}>{children}</span>
);

const HrCard = ({
  tone,
  head,
  sub,
  children,
}: {
  tone: string;
  head: string;
  sub: string;
  children: ReactNode;
}) => (
  <div
    style={{
      background: surface,
      border: `1px solid ${border}`,
      borderTop: `5px solid ${tone}`,
      borderRadius: 24,
      padding: '22px 27px 19px',
      boxShadow: SHADOW,
      boxSizing: 'border-box',
    }}
  >
    <div style={{ fontSize: 26, fontWeight: 900, marginBottom: 5, lineHeight: 1.3 }}>{head}</div>
    <div style={{ fontSize: 18, color: text3, marginBottom: 13, lineHeight: 1.4 }}>{sub}</div>
    {children}
  </div>
);

const Manpower: Page = () => (
  <div style={padded}>
    <SectionNum n="02" />
    <NumTag>問題 · 人力</NumTag>
    <h2 style={{ ...h2Style, fontSize: 58 }}>
      台灣不缺善意，<G>缺的是把善意派到門口的系統</G>。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: 27,
        marginTop: 20,
      }}
    >
      <HrCard
        tone={green}
        head="✅ 供給 · 民間人力其實很足"
        sub="問題不是沒人願意幫，是沒人知道「現在誰需要什麼」"
      >
        <HrRow icon="🤝" n="110 萬人">
          全國志工人數，其中 <Bb>65 歲以上 34.4 萬人、占 31%</Bb>
          ——長輩自己就是最大的志工族群。
          <Src>依衛福部志願服務統計推算：2022 年 65 歲以上志工 344,019 人，占全體 31.13%</Src>
        </HrRow>
        <HrRow icon="⛏️" n="50 萬人">
          2025 年馬太鞍溪溢流，光復鄉<Bb>一次動員逾 50 萬名「鏟子超人」</Bb>
          ——任務夠清楚，台灣人就會到場。
          <Src>環境部，2026 年 7 月</Src>
        </HrRow>
        <HrRow icon="🏠" n="5,000 處">
          政府正推動社區關懷據點與基層組織做關懷訪視、送餐。<Bb>據點在、人也在，缺的是即時派單。</Bb>
          <Src>衛福部，2026 年 3 月</Src>
        </HrRow>
      </HrCard>

      <HrCard
        tone={red}
        head="⚠️ 需求 · 專業人力補不上來"
        sub="照服員成長停滯、社工瀕臨崩潰，靠「再加人」已經無解"
      >
        <HrRow icon="🧑‍⚕️" n="1 : 67">
          居家服務員僅約 <Bb>7 萬人</Bb>，面對 467 萬長輩。照服員總數 9.7–10 萬人、
          <Bb>近三年停滯</Bb>，2024 年居服員只增加 700 人。
          <Src>衛福部長照 2.0 統計</Src>
        </HrRow>
        <HrRow icon="😵" n="近 80%">
          社工有<Bb>中度以上職業倦怠</Bb>、近半數重度；對制度支持的自評只有 <Bb>28.6 / 100 分</Bb>。
          <Src>台北市社會工作人員職業工會 2026 年調查，n=724</Src>
        </HrRow>
        <HrRow icon="📈" n="50 萬人">
          專家推估的未來照顧人力缺口。85 歲以上將從 47 萬（2025）增至 <Bb>139 萬（2045）</Bb>
          ，這段年紀失能率約 5 成。
          <Src>國發會中推估、衛福部</Src>
        </HrRow>
      </HrCard>
    </div>

    {/* ── 人力比例對照 ────────────────────────────────────────── */}
    <div
      style={{
        position: 'relative',
        zIndex: 1,
        marginTop: 18,
        background: surface,
        border: `1px solid ${border}`,
        borderRadius: 22,
        padding: '19px 27px 16px',
        boxShadow: SHADOW,
        boxSizing: 'border-box',
      }}
    >
      <div style={ctStyle}>同一批長輩，兩種人力比例</div>
      <svg
        viewBox="0 0 900 46"
        style={{ width: '100%', height: 'auto', display: 'block' }}
        role="img"
        aria-label="人力比例對照"
      >
        <rect x="0" y="6" width="440" height="34" rx="8" fill={green} />
        <text x="220" y="30" textAnchor="middle" fontSize="16" fontWeight="800" fill="#fff">
          志工 110 萬 : 需關懷長輩 70 萬 ≈ 1.6 : 1（善意夠）
        </text>
        <rect x="460" y="6" width="440" height="34" rx="8" fill={red} />
        <text x="680" y="30" textAnchor="middle" fontSize="16" fontWeight="800" fill="#fff">
          居服員 7 萬 : 65 歲以上 467 萬 ≈ 1 : 67（專業人力不夠）
        </text>
      </svg>
      <div style={figcapStyle}>
        所以我們不再增加一種專業人力，而是<b>把志工接進派單系統</b>——用時間銀行讓這 110
        萬人的善意可被調度、被記錄、被回饋。
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 4 — 三端困擾（全幅三分割）
   ══════════════════════════════════════════════════════════════════ */

const tfHead: CSSProperties = {
  position: 'absolute',
  top: 27,
  left: '50%',
  transform: 'translateX(-50%)',
  zIndex: 6,
  width: 1458,
  background: 'rgba(255,255,255,.95)',
  borderRadius: 22,
  padding: '19px 35px',
  boxShadow: '0 16px 46px rgba(0,0,0,.3)',
  textAlign: 'center',
  boxSizing: 'border-box',
};

const tfHeadTitle: CSSProperties = { fontSize: 40, fontWeight: 900, color: text1, lineHeight: 1.25 };

const PainItem = ({ children }: { children: ReactNode }) => (
  <li
    style={{
      position: 'relative',
      color: '#fff',
      fontSize: 24,
      fontWeight: 700,
      lineHeight: 1.45,
      marginBottom: 12,
      paddingLeft: 27,
      textShadow: '0 1px 5px rgba(0,0,0,.6)',
    }}
  >
    <span
      style={{
        position: 'absolute',
        left: 0,
        top: 11,
        width: 12,
        height: 12,
        borderRadius: '50%',
        background: '#FF6A52',
      }}
    />
    {children}
  </li>
);

const TfCell = ({
  img,
  title,
  children,
  divider,
}: {
  img: string;
  title: string;
  children: ReactNode;
  divider?: boolean;
}) => (
  <div
    style={{
      position: 'relative',
      backgroundImage: `url(${img})`,
      backgroundSize: 'cover',
      backgroundPosition: 'center 26%',
      overflow: 'hidden',
      boxShadow: divider ? '-1px 0 0 rgba(255,255,255,.14)' : undefined,
    }}
  >
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'flex-end',
        padding: '40px 40px 49px',
        background:
          'linear-gradient(to top, rgba(16,11,7,.93) 0%, rgba(16,11,7,.55) 30%, rgba(16,11,7,0) 60%)',
      }}
    >
      <h4
        style={{
          margin: '0 0 16px',
          color: '#fff',
          fontSize: 38,
          fontWeight: 900,
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          lineHeight: 1.2,
        }}
      >
        {title}
      </h4>
      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>{children}</ul>
    </div>
  </div>
);

const ThreePains: Page = () => (
  <div style={bleed}>
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'grid',
        gridTemplateColumns: '1fr 1fr 1fr',
      }}
    >
      <TfCell img={pElder} title="👵 長輩">
        <PainItem>在家出事沒人知道——台北 5 年 178 起獨居死亡通報</PainItem>
        <PainItem>只會講台語、不識字</PainItem>
        <PainItem>不會用手機、按不了 LINE</PainItem>
      </TfCell>
      <TfCell img={pChild} title="🧑‍💼 兒女" divider>
        <PainItem>不在身邊放不下心</PainItem>
        <PainItem>出事往往最後才知道</PainItem>
      </TfCell>
      <TfCell img={pWorker} title="🧑‍⚕️ 社工" divider>
        <PainItem>案量爆炸、訪視跑不完</PainItem>
        <PainItem>近 80% 中度以上職業倦怠、近半重度</PainItem>
        <PainItem>紀錄申報壓垮、怕漏接</PainItem>
      </TfCell>
    </div>

    <div style={tfHead}>
      <b style={tfHeadTitle}>
        照顧的每一端，<G>都卡在自己的困擾裡</G>
      </b>
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 16,
          marginTop: 11,
          paddingTop: 11,
          borderTop: `1px solid ${border}`,
        }}
      >
        <img src={four} alt="四端關係圖" style={{ width: 108, borderRadius: 11, display: 'block' }} />
        <span style={{ fontSize: 19.5, color: text2, lineHeight: 1.45, textAlign: 'left' }}>
          <Bo>四端關係圖：</Bo>收音機把一個事件同步推到四端，並補進第四端——<Bo>社區志工</Bo>
          ，把「感知」接到真正能到場的人力。
        </span>
      </div>
    </div>

    <BleedNum />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 5 — 四端困擾 → 解決（全幅四分割）
   ══════════════════════════════════════════════════════════════════ */

const Ar = () => <span style={{ color: amber, margin: '0 7px', fontWeight: 900 }}>→</span>;

const FixItem = ({ children }: { children: ReactNode }) => (
  <li
    style={{
      color: '#fff',
      fontSize: 20,
      fontWeight: 600,
      lineHeight: 1.5,
      marginBottom: 13,
      paddingLeft: 3,
      textShadow: '0 1px 5px rgba(0,0,0,.6)',
    }}
  >
    {children}
  </li>
);

const FfCell = ({
  img,
  title,
  badge,
  vol,
  children,
}: {
  img: string;
  title: string;
  badge?: ReactNode;
  vol?: boolean;
  children: ReactNode;
}) => (
  <div
    style={{
      position: 'relative',
      backgroundImage: `url(${img})`,
      backgroundSize: 'cover',
      backgroundPosition: 'center 30%',
      overflow: 'hidden',
      outline: vol ? `7px solid ${orange}` : undefined,
      outlineOffset: vol ? -7 : undefined,
    }}
  >
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'flex-end',
        padding: '32px 43px 35px',
        background:
          'linear-gradient(to top, rgba(16,11,7,.95) 0%, rgba(16,11,7,.82) 46%, rgba(16,11,7,.3) 78%, rgba(16,11,7,0) 100%)',
      }}
    >
      <h4
        style={{
          margin: '0 0 15px',
          color: '#fff',
          fontSize: 35,
          fontWeight: 900,
          display: 'flex',
          alignItems: 'center',
          gap: 12,
          lineHeight: 1.2,
        }}
      >
        {title}
        {badge}
      </h4>
      <ul style={{ listStyle: 'none', margin: 0, padding: 0 }}>{children}</ul>
    </div>
  </div>
);

const FourFixes: Page = () => (
  <div style={bleed}>
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gridTemplateRows: '1fr 1fr',
      }}
    >
      <FfCell img={pElder} title="👵 長輩">
        <FixItem>
          出事沒人知 <Ar /> <Bl>整個手掌就能按的 SOS 大鈕</Bl>
          ，或直接開口說一句話；不必找手機、不必解鎖
        </FixItem>
        <FixItem>
          不會用手機 <Ar /> 免螢幕、免 App，<Bl>按住就說話、放開就送出</Bl>，國語台語都聽得懂
        </FixItem>
        <FixItem>
          倒下了按不到鈕 <Ar /> <Bl>鏡頭在晶片裡判斷跌倒</Bl>
          ，先用語音問「你還好嗎？」，長輩說不用就不通報
          <Wip dark />
        </FixItem>
      </FfCell>

      <FfCell img={pChild} title="🧑‍💼 兒女">
        <FixItem>
          放不下心 <Ar /> 長輩一按 SOS 或發出需求，<Bl>手機立刻收到推播</Bl>
          ，不必再靠每天打電話確認
        </FixItem>
        <FixItem>
          怕漏接 <Ar /> App 看得到<Bl>志工是否接單、預計幾分鐘到（ETA）與到場回報</Bl>
        </FixItem>
      </FfCell>

      <FfCell img={pWorker} title="🧑‍⚕️ 社工">
        <FixItem>
          案量爆炸 <Ar /> 遠端就能掌握全區長輩狀態，事件<Bl>自動分三軌</Bl>
          （自行關懷／派志工／轉緊急）
        </FixItem>
        <FixItem>
          申報壓垮 <Ar /> 每次服務<Bl>自動留下紀錄</Bl>，月底<Bl>一鍵匯出 Excel</Bl> 交政府核銷
        </FixItem>
      </FfCell>

      <FfCell img={pVolunteer} title="🤝 志工" badge={<NewTag />} vol>
        <FixItem>
          想幫忙沒管道 <Ar /> App 收到<Bl>附近的關懷／物資需求單</Bl>，接單後導航到長輩家
        </FixItem>
        <FixItem>
          付出沒被記得 <Ar /> 服務時數存進<Bl>「時間銀行」，日後可換回自己需要的照顧</Bl>
        </FixItem>
      </FfCell>
    </div>

    <div
      style={{
        position: 'absolute',
        top: 32,
        left: '50%',
        transform: 'translateX(-50%)',
        zIndex: 6,
        background: 'rgba(255,255,255,.94)',
        borderRadius: 19,
        padding: '14px 30px',
        boxShadow: '0 14px 40px rgba(0,0,0,.25)',
        textAlign: 'center',
      }}
    >
      <b style={{ fontSize: 32, fontWeight: 900, color: text1 }}>
        一台收音機串起四端，<G>困擾全接住</G>
      </b>
    </div>

    <BleedNum />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 6 — 產品設計 · 長輩端
   ══════════════════════════════════════════════════════════════════ */

const PdCell = ({
  fig,
  figBg,
  title,
  children,
}: {
  fig: ReactNode;
  figBg?: string;
  title: ReactNode;
  children: ReactNode;
}) => (
  <div
    style={{
      border: `1px solid ${border}`,
      borderRadius: 19,
      padding: '15px 18px',
      background: surface,
      boxShadow: SHADOW,
      boxSizing: 'border-box',
    }}
  >
    <div
      style={{
        width: '100%',
        height: 81,
        borderRadius: 12,
        overflow: 'hidden',
        marginBottom: 11,
        border: `1px solid ${border}`,
        background: figBg,
      }}
    >
      {fig}
    </div>
    <h6 style={{ margin: '0 0 4px', fontSize: 21, fontWeight: 800, color: text1, lineHeight: 1.3 }}>
      {title}
    </h6>
    <p style={{ margin: 0, fontSize: 17, color: text2, lineHeight: 1.4 }}>{children}</p>
  </div>
);

const pdImg: CSSProperties = { width: '100%', height: '100%', display: 'block', objectFit: 'cover' };

const ProductDesign: Page = () => (
  <div style={padded}>
    <SectionNum n="03" />
    <NumTag>產品設計 · 長輩端</NumTag>
    <h2 style={h2Style}>
      為長輩重設計：<G>大字、橘紅鍵、整掌就能按</G>。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: '1.15fr .85fr',
        gap: 54,
        alignItems: 'center',
        marginTop: 27,
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'center' }}>
        <img
          src={appElder}
          alt="長輩端介面"
          style={{
            width: 389,
            height: 'auto',
            display: 'block',
            borderRadius: 27,
            boxShadow: '0 32px 80px rgba(60,40,20,.16)',
          }}
        />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 19 }}>
        <PdCell fig={<img src={pdBtn} alt="橘紅按鈕" style={pdImg} />} title="橘紅高辨識">
          對長者辨識度最高，遠遠就看得到。
        </PdCell>

        <PdCell fig={<img src={pdBig} alt="大字介面" style={pdImg} />} title="WCAG · 大字簡潔">
          高對比、超大字，不怕點錯。
        </PdCell>

        <PdCell
          fig={<img src={pdLang} alt="國台語切換" style={pdImg} />}
          title="國台語 ASR・Breeze-ASR-26"
        >
          聯發科國產模型，長輩不用學。
        </PdCell>

        <PdCell
          figBg="#E7F3FB"
          fig={
            <svg
              viewBox="0 0 200 62"
              style={{ width: '100%', height: '100%', display: 'block' }}
              role="img"
              aria-label="藍牙佈網"
            >
              <defs>
                <linearGradient id="jrPfBle" x1="0" x2="1">
                  <stop offset="0" stopColor="#F96C1A" />
                  <stop offset="1" stopColor="#1E88D6" />
                </linearGradient>
              </defs>
              <rect width="200" height="62" fill="#E7F3FB" />
              <rect
                x="20"
                y="13"
                width="28"
                height="38"
                rx="6"
                fill="#fff"
                stroke="#1E88D6"
                strokeWidth="1.5"
              />
              <rect x="25" y="18" width="18" height="24" rx="2" fill="#DCEBF8" />
              <g fill="none" stroke="url(#jrPfBle)" strokeWidth="3" strokeLinecap="round">
                <path d="M60,31 q10,-12 20,0" />
                <path d="M68,31 q6,-8 12,0" />
              </g>
              <text x="90" y="52" fontSize="9" fontWeight="800" fill="#0E6EA8" textAnchor="middle">
                BLE
              </text>
              <rect
                x="120"
                y="11"
                width="60"
                height="42"
                rx="10"
                fill="#EFE7D7"
                stroke="#D8CCB4"
                strokeWidth="1.5"
              />
              <rect x="128" y="18" width="44" height="6" rx="3" fill="#1E88D6" />
              <circle cx="168" cy="41" r="7" fill="#CD2018" />
            </svg>
          }
          title="簡單連 Wi-Fi"
        >
          家屬 App 藍牙一鍵佈建；無網路可選 4G。
        </PdCell>

        <PdCell
          figBg="#FDECEA"
          fig={
            <svg
              viewBox="0 0 200 62"
              style={{ width: '100%', height: '100%', display: 'block' }}
              role="img"
              aria-label="SOS 整掌按"
            >
              <rect width="200" height="62" fill="#FDECEA" />
              <ellipse cx="88" cy="13" rx="20" ry="7" fill="#000" opacity=".08" />
              <circle cx="88" cy="33" r="21" fill="#CD2018" />
              <text x="88" y="39" fontSize="15" fontWeight="900" fill="#fff" textAnchor="middle">
                SOS
              </text>
              <text x="150" y="37" fontSize="12" fontWeight="800" fill="#CD2018">
                整掌按
              </text>
            </svg>
          }
          title="緊急零打字"
        >
          整掌按大鈕或直接語音，手抖也免精細操作。
        </PdCell>
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 7 — 使用者端硬體說明
   ══════════════════════════════════════════════════════════════════ */

const SRow = ({
  icon,
  title,
  first,
  children,
}: {
  icon: string;
  title: ReactNode;
  first?: boolean;
  children: ReactNode;
}) => (
  <div
    style={{
      display: 'flex',
      alignItems: 'center',
      gap: 16,
      padding: '8px 0',
      borderTop: first ? 'none' : `1px solid ${border}`,
    }}
  >
    <div style={{ fontSize: 32, lineHeight: 1, flex: '0 0 36px' }}>{icon}</div>
    <div style={{ minWidth: 0 }}>
      <h5 style={{ margin: '0 0 3px', fontSize: 23, fontWeight: 800, lineHeight: 1.3 }}>{title}</h5>
      <p style={{ margin: 0, fontSize: 19.5, color: text2, lineHeight: 1.45 }}>{children}</p>
    </div>
  </div>
);

const Hardware: Page = () => (
  <div style={padded}>
    <SectionNum n="04" />
    <NumTag>使用者端硬體說明 · 加分項</NumTag>
    <h2 style={h2Style}>
      有鏡頭，但<G>影像永遠留在晶片裡</G>。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: '1.04fr .96fr',
        gap: 54,
        alignItems: 'center',
        marginTop: 27,
      }}
    >
      <div style={{ display: 'flex', gap: 19 }}>
        <img
          src={devReal}
          alt="實體原型"
          style={{
            width: '50%',
            height: 'auto',
            display: 'block',
            borderRadius: 27,
            boxShadow: '0 32px 80px rgba(60,40,20,.16)',
          }}
        />
        <img
          src={devInternal}
          alt="內部結構"
          style={{
            width: '50%',
            height: 'auto',
            display: 'block',
            borderRadius: 27,
            boxShadow: '0 32px 80px rgba(60,40,20,.16)',
          }}
        />
      </div>

      <div>
        <SRow icon="🖨️" title="外殼・3D 列印" first>
          咖啡色圓角機身，快速打樣、依長輩手感微調；<Bb>像收音機、不像醫療器材</Bb>。
        </SRow>
        <SRow icon="🎗️" title="掛繩・隨身攜帶">
          機身頂部掛繩孔，掛脖子或掛牆邊，<Bb>走到哪帶到哪</Bb>，求助不受限在固定位置。
        </SRow>
        <SRow icon="🔘" title="講話鍵・超簡單操作">
          頂部一顆大鍵，<Bb>按住就說話、放開就送出</Bb>；免螢幕、免 App、零學習。
        </SRow>
        <SRow
          icon="🎙️"
          title={
            <>
              收音＋喇叭・ASR 全用國產模型
              <DoneTag />
            </>
          }
        >
          國語、台語一律走<Bb>聯發科 Breeze-ASR-26</Bb>；喇叭播報國台語都通，
          <Bb>語音轉成文字後音檔即刪</Bb>。
        </SRow>
        <SRow icon="🧠" title="晟邦 AI 晶片・RTL8735B">
          相機＋NPU＋Wi-Fi/BLE 八合一，<Bb>視覺推論在晶片本地跑完，原始影像永不離開裝置</Bb>
          ——不錄影、不上傳、雲端看不到長輩家裡。
        </SRow>
        <SRow
          icon="👁️"
          title={
            <>
              跌倒偵測・全程在裝置端
              <Wip />
            </>
          }
        >
          偵測到疑似跌倒，裝置<Bb>先用語音問長輩「需不需要幫忙」</Bb>；確認需要才把<Bb>事件</Bb>
          送上雲派給志工／社工——<Bb>送出去的是一則事件，不是影像</Bb>。
        </SRow>
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 8 — 國產晶片 · 邊緣大腦
   ══════════════════════════════════════════════════════════════════ */

const Cf = ({ children }: { children: ReactNode }) => (
  <span style={{ fontSize: 24, fontWeight: 800, color: text1 }}>{children}</span>
);
const Cfa = () => <span style={{ fontSize: 27, fontWeight: 900, color: orange }}>→</span>;

const ChipCell = ({
  title,
  vis,
  children,
}: {
  title: ReactNode;
  vis?: boolean;
  children: ReactNode;
}) => (
  <div
    style={{
      border: `1px solid ${vis ? 'rgba(249,108,26,.45)' : border}`,
      borderRadius: 22,
      padding: '19px 24px 18px',
      background: vis ? 'linear-gradient(135deg,#FFF6EE,#F7FBFE)' : surface,
      boxShadow: SHADOW,
      boxSizing: 'border-box',
    }}
  >
    <h5
      style={{
        margin: '0 0 8px',
        fontSize: 24,
        fontWeight: 800,
        display: 'flex',
        alignItems: 'center',
        gap: 11,
        flexWrap: 'wrap',
        lineHeight: 1.3,
      }}
    >
      {title}
    </h5>
    <p style={{ margin: 0, fontSize: 19, color: text2, lineHeight: 1.5 }}>{children}</p>
  </div>
);

const EdgeChip: Page = () => (
  <div style={padded}>
    <SectionNum n="05" />
    <NumTag>國產晶片 · 邊緣大腦</NumTag>
    <h2 style={h2Style}>
      一顆晟邦 HUB8735 Ultra，<G>包辦長輩端幾乎所有的活</G>。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'flex',
        alignItems: 'center',
        gap: 14,
        marginTop: 24,
        background: 'linear-gradient(135deg,#FFF3E9,#EAF4FC)',
        border: '1px solid rgba(249,108,26,.22)',
        borderRadius: 22,
        padding: '19px 30px',
        boxSizing: 'border-box',
      }}
    >
      <Cf>感知（視覺跌倒＋收音）</Cf>
      <Cfa />
      <Cf>上報事件</Cf>
      <Cfa />
      <Cf>收下行指令</Cf>
      <Cfa />
      <Cf>發聲</Cf>
      <div
        style={{ marginLeft: 'auto', fontSize: 19, color: text2, textAlign: 'right', lineHeight: 1.4 }}
      >
        AmebaPro2 平台 · <Bd>國產晶片</Bd>
        <br />
        不是架構圖上的一個插槽，是整個長輩端
      </div>
    </div>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: 'repeat(3, 1fr)',
        gap: 19,
        marginTop: 19,
      }}
    >
      <ChipCell title="🧩 主控 MCU">
        跑整個韌體主迴圈與狀態邏輯，並負責 <Bb>SD 卡錄音暫存</Bb>，斷網時不掉資料。
      </ChipCell>

      <ChipCell
        vis
        title={
          <>
            👁️ 視覺 NPU · 跌倒偵測
            <Wip />
          </>
        }
      >
        本地跑 <Bb>YOLO person</Bb>，人形框 <Bb>w/h &gt; 1.3 且持續 3 秒</Bb> 判為疑似跌倒。
        <Bb>影像永不外傳</Bb>——隱私邊界靠這顆在本地算才守得住。
      </ChipCell>

      <ChipCell title="📶 Wi-Fi ＋ BLE 5.1">
        BLE 讓家屬 App 一鍵藍牙配網（<Code>BLEWifiConfig</Code>）；Wi-Fi 上行打{' '}
        <Code>POST /voice</Code>，並常駐 <Bb>MQTT/TLS</Bb> 訂閱下行{' '}
        <Code>{'jinsun/{serial}/cmd'}</Code>。
      </ChipCell>

      <ChipCell title="🎤 板載 PDM 麥克風">
        只錄<Bb>長輩按鈕主動觸發</Bb>的那一段，<Bb>16 kHz mono</Bb> 上雲做 ASR；沒按就不錄、不上傳。
      </ChipCell>

      <ChipCell title="🔊 I2S 音訊輸出">
        驅動 <Bb>MAX98357</Bb> 功放，把雲端 TTS 的 WAV 串流播出來——安撫語、進度播報、台語旗標。
      </ChipCell>

      <ChipCell title="🔘 觸發／SOS 輸入">
        實體大鈕走 <Code>D9</Code>。<Bb>按下才錄音、按下才上雲</Bb>
        ，這是整套「主動觸發」隱私設計的最後一道實體開關。
      </ChipCell>
    </div>

    <div style={{ ...demoNote, position: 'relative', zIndex: 1 }}>
      🇹🇼 <Bd>全國產組合</Bd>：邊緣用<Bd>晟邦 HUB8735 Ultra</Bd> 做感知與本地推論，語音理解用
      <Bd>聯發科 Breeze-ASR-26</Bd> 國產模型——從晶片到模型都留在台灣。
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 9 — 生成式 AI 技術應用
   ══════════════════════════════════════════════════════════════════ */

const AiCard = ({ title, children }: { title: ReactNode; children: ReactNode }) => (
  <div style={cardStyle}>
    <h4 style={{ margin: '0 0 11px', fontSize: 31, fontWeight: 800, lineHeight: 1.3 }}>{title}</h4>
    <p style={{ margin: 0, fontSize: 21, color: text2, lineHeight: 1.6 }}>{children}</p>
  </div>
);

const GenAi: Page = () => (
  <div style={padded}>
    <SectionNum n="06" />
    <NumTag>生成式 AI 技術應用</NumTag>
    <h2 style={h2Style}>
      多 Agent＋記憶＋護欄，<G>把一句話變成正確一單</G>。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: 32,
        marginTop: 43,
      }}
    >
      <AiCard title="🧠 多 Agent 編排（Bedrock）">
        六個 Agent：Intent／Emergency／Needs／Conversation／Device／Memory，結構化工具呼叫，而非單次
        prompt。
      </AiCard>

      <AiCard title="💾 個人記憶 · RAG">
        Bedrock Titan Embeddings ＋ Knowledge
        Bases——「牛奶跟雞蛋」對到他常去的店、病史與家人。
      </AiCard>

      <AiCard
        title={
          <>
            🎙️ ASR · 全用國產模型
            <DoneTag />
          </>
        }
      >
        <Bd>國語、台語一律走聯發科 Breeze-ASR-26</Bd>（聯發創新基地），跑在 SageMaker
        上——不是把台語當華語硬解；播報用 Polly。
      </AiCard>

      <AiCard title="🛡️ 護欄">
        低信心就<Bd>語音再確認</Bd>（「你是說要買牛奶嗎？」），寧可問一句、不亂派一單。跌倒偵測也一樣——
        <Bd>先問長輩要不要幫忙</Bd>，不自作主張報警。
      </AiCard>
    </div>

    <div
      style={{
        ...demoNote,
        position: 'relative',
        zIndex: 1,
        display: 'flex',
        gap: 46,
        flexWrap: 'wrap',
      }}
    >
      <div style={{ flex: '1 1 0', minWidth: 0 }}>
        <DoneTag flush /> 國台語 ASR（聯發科 Breeze-ASR-26）、四端 App 與社工 Web 後台
        <Bd>已部署上線</Bd>
      </div>
      <div style={{ flex: '1 1 0', minWidth: 0 }}>
        <span style={{ marginLeft: -8 }}>
          <Wip />
        </span>{' '}
        裝置端視覺跌倒偵測（影像不上雲，偵測後語音確認再通報）
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 10 — AWS 雲端技術架構
   ══════════════════════════════════════════════════════════════════ */

const Svc = ({ aws, children }: { aws?: boolean; children: ReactNode }) => (
  <span
    style={{
      display: 'inline-flex',
      alignItems: 'center',
      fontSize: 20,
      fontWeight: 700,
      padding: '9px 18px',
      borderRadius: 14,
      background: aws ? 'rgba(249,108,26,.12)' : surface2,
      border: `1px solid ${aws ? 'rgba(249,108,26,.32)' : border}`,
      color: aws ? '#9A4A08' : text1,
      whiteSpace: 'nowrap',
    }}
  >
    {children}
  </span>
);

const ArchRow = ({
  title,
  note,
  mid,
  children,
}: {
  title: string;
  note?: string;
  mid?: boolean;
  children: ReactNode;
}) => (
  <div
    style={{
      border: `1px solid ${mid ? 'rgba(249,108,26,.22)' : border}`,
      borderRadius: 22,
      padding: '20px 32px',
      background: mid ? 'linear-gradient(135deg,#FFF6EE,#EAF4FC)' : surface,
      boxShadow: SHADOW,
      boxSizing: 'border-box',
    }}
  >
    <div style={{ fontSize: 26, fontWeight: 800, marginBottom: 14, lineHeight: 1.3 }}>
      {title}
      {note ? (
        <small style={{ fontWeight: 600, color: text2, fontSize: 19, marginLeft: 11 }}>{note}</small>
      ) : null}
    </div>
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 12 }}>{children}</div>
  </div>
);

const ArchConn = ({ children }: { children: ReactNode }) => (
  <div
    style={{
      textAlign: 'center',
      color: blue,
      fontWeight: 800,
      fontSize: 21,
      letterSpacing: '.02em',
      lineHeight: 1.4,
    }}
  >
    {children}
  </div>
);

const Architecture: Page = () => (
  <div style={padded}>
    <SectionNum n="07" />
    <NumTag>AWS 雲端技術架構</NumTag>
    <h2 style={{ ...h2Style, fontSize: 58 }}>
      影像不出裝置，<G>長輩開口或按鈕才上雲</G>。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'flex',
        flexDirection: 'column',
        gap: 18,
        marginTop: 24,
      }}
    >
      <ArchRow title="邊緣・家中" note="相機影像只在晶片內推論・不儲存、不外傳">
        <Svc>晟邦 HUB8735 Ultra · 相機＋NPU 本地推論</Svc>
        <Svc>
          跌倒偵測
          <Wip />
        </Svc>
        <Svc>SOS 大鈕 · 燈號回饋</Svc>
        <Svc>麥克風／喇叭 · Wi-Fi/BLE</Svc>
      </ArchRow>

      <ArchConn>
        ↕ MQTT / TLS · 只有<Bo>長輩主動按 SOS／開口說話</Bo>，或跌倒後確認要幫忙，才上傳事件與語音——
        <Bo>影像永不上傳</Bo>
      </ArchConn>

      <ArchRow title="雲端・AWS" note="生成式 AI＋事件狀態機" mid>
        <Svc aws>IoT Core</Svc>
        <Svc aws>Step Functions</Svc>
        <Svc aws>Lambda</Svc>
        <Svc aws>Bedrock</Svc>
        <Svc aws>SageMaker · Breeze-ASR-26</Svc>
        <Svc aws>Polly</Svc>
        <Svc aws>DynamoDB</Svc>
        <Svc aws>Cognito</Svc>
        <Svc aws>AppSync</Svc>
      </ArchRow>

      <ArchConn>↕ AppSync / WebSocket · 四端即時同步</ArchConn>

      <ArchRow title="四端・使用者">
        <Svc>長輩 · 語音/燈號</Svc>
        <Svc>家屬 App</Svc>
        <Svc>志工 App</Svc>
        <Svc>社工 Web · Excel</Svc>
      </ArchRow>
    </div>

    <div
      style={{
        ...demoNote,
        position: 'relative',
        zIndex: 1,
        fontSize: 19,
        display: 'grid',
        gridTemplateColumns: '1fr 1fr',
        gap: '12px 35px',
      }}
    >
      <div>
        🧠 <Bd>Bedrock</Bd>：生成式 AI 大腦——多 Agent 意圖分類、對話、RAG 個人記憶與低信心再確認護欄。
      </div>
      <div>
        🏗️ <Bd>SageMaker</Bd>：承載<Bd>聯發科 Breeze-ASR-26</Bd>{' '}
        推論端點（國語台語共用一顆國產模型）；跌倒偵測模型也在此訓練，量化後部署到邊緣 NPU。
      </div>
      <div>
        🗄️ <Bd>DynamoDB＋Cognito</Bd>：事件／服務紀錄／時間銀行帳本＋三端角色權限；社工
        <Bd>一鍵匯出 Excel</Bd> 申報。
      </div>
      <div>
        🛠️ <Bd>Kiro 輔助開發</Bd>：spec-driven 代理式 IDE，產出三端 App、雲端狀態機與韌體，加速迭代。
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 11 — 商業模型 · 客群
   ══════════════════════════════════════════════════════════════════ */

const SegCard = ({
  img,
  cover,
  tag,
  title,
  children,
}: {
  img: string;
  cover?: boolean;
  tag: string;
  title: string;
  children: ReactNode;
}) => (
  <div
    style={{
      border: `1px solid ${border}`,
      borderRadius: 27,
      overflow: 'hidden',
      background: surface,
      boxShadow: SHADOW,
      boxSizing: 'border-box',
    }}
  >
    <div
      style={{
        height: 252,
        background: '#F3EDE3',
        backgroundImage: `url(${img})`,
        backgroundSize: cover ? 'cover' : 'contain',
        backgroundRepeat: 'no-repeat',
        backgroundPosition: 'center',
      }}
    />
    <div style={{ padding: '24px 30px' }}>
      <div style={{ fontSize: 17.5, fontWeight: 800, color: orange, letterSpacing: '.06em' }}>
        {tag}
      </div>
      <h4 style={{ margin: '4px 0 7px', fontSize: 28, fontWeight: 800, lineHeight: 1.3 }}>
        {title}
      </h4>
      <p style={{ margin: 0, fontSize: 21, color: text2, lineHeight: 1.5 }}>{children}</p>
    </div>
  </div>
);

const Segments: Page = () => (
  <div style={padded}>
    <SectionNum n="08" />
    <NumTag>商業模型 · 客群</NumTag>
    <h2 style={h2Style}>
      先接政府已編列的 <G>7 萬台</G>，再往 70 萬人擴張。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: '1.04fr .96fr',
        gap: 54,
        alignItems: 'stretch',
        marginTop: 19,
      }}
    >
      <SegCard
        img={radio}
        cover
        tag="主要客群 · 剛需（第一批 7 萬台）"
        title="不識字／手抖・帕金森／不會用手機"
      >
        政府本期補助的<b>緊急救援設備 7 萬台</b>就是這群人。手無法精細操作——<b>整個手掌就能按</b>
        大鈕，打開、按下、說話。
      </SegCard>

      <SegCard img={appFamily} tag="次要客群 · 擴張" title="會用基礎手機">
        家屬／志工用 <b>App</b> 掌握四端；長輩端仍可只用收音機，家人在遠端補足數位介面。
      </SegCard>
    </div>

    <div style={{ ...chartWrap, position: 'relative', zIndex: 1, marginTop: 19, padding: '19px 27px' }}>
      <div style={ctStyle}>三階段市場（每一階都是政府已公布的數字）</div>
      <svg
        viewBox="0 0 900 54"
        style={{ width: '100%', height: 'auto', display: 'block' }}
        role="img"
        aria-label="三階段市場擴張"
      >
        <rect x="0" y="10" width="900" height="34" rx="8" fill="#EEEEEE" />
        <rect x="0" y="10" width="200" height="34" rx="8" fill={orange} />
        <rect x="200" y="10" width="330" height="34" fill={purple} />
        <rect x="530" y="10" width="370" height="34" fill={deepBlue} />
        <text x="100" y="33" textAnchor="middle" fontSize="15" fontWeight="800" fill="#fff">
          7 萬台・已編列
        </text>
        <text x="365" y="33" textAnchor="middle" fontSize="15" fontWeight="800" fill="#fff">
          35 萬人・評估需支持
        </text>
        <text x="715" y="33" textAnchor="middle" fontSize="15" fontWeight="800" fill="#fff">
          70 萬人・獨居／雙老
        </text>
      </svg>
      <div style={figcapStyle}>
        來源：衛福部獨居長者支持方案（62.5 億元特別預算，2026–2027）
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 12 — 成本預算 · 全配套
   ══════════════════════════════════════════════════════════════════ */

const bomTd: CSSProperties = {
  padding: '9px 8px',
  borderBottom: `1px solid ${border}`,
  color: text2,
  fontSize: 20,
};
const bomTdV: CSSProperties = {
  ...bomTd,
  textAlign: 'right',
  fontWeight: 800,
  color: text1,
  fontVariantNumeric: 'tabular-nums',
};
const bomSumTd: CSSProperties = {
  padding: '9px 8px',
  borderTop: `2px solid ${borderStrong}`,
  borderBottom: 'none',
  color: text1,
  fontWeight: 800,
  fontSize: 22,
};

const BomRow = ({ label, value }: { label: string; value: string }) => (
  <tr>
    <td style={bomTd}>{label}</td>
    <td style={bomTdV}>{value}</td>
  </tr>
);

const Cost: Page = () => (
  <div style={padded}>
    <SectionNum n="09" />
    <NumTag>成本預算 · 全配套</NumTag>
    <h2 style={h2Style}>
      量產後單套約 <G>NT$1,400</G>，不靠硬體賺錢。
    </h2>

    <div
      style={{
        position: 'relative',
        zIndex: 1,
        display: 'grid',
        gridTemplateColumns: '1.04fr .96fr',
        gap: 54,
        alignItems: 'start',
        marginTop: 27,
      }}
    >
      <div style={chartWrap}>
        <div style={ctStyle}>單套配套成本 · 含硬體＋人力＋維護（NT$／台）</div>
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <tbody>
            <BomRow label="硬體（量產 BOM：晟邦模組＋機構＋電池）" value="700" />
            <BomRow label="佈建／安裝人力（一次）" value="200" />
            <BomRow label="雲端服務・OTA（首年／台）" value="250" />
            <BomRow label="維護・客服（首年／台）" value="250" />
            <tr>
              <td style={bomSumTd}>單套配套合計</td>
              <td style={{ ...bomSumTd, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
                ≈ 1,400
              </td>
            </tr>
          </tbody>
        </table>
        <div style={figcapStyle}>
          本頁金額為<b>內部量產估算</b>，非官方統計、未經第三方查核；實際成本依採購量與規格而異。
        </div>
      </div>

      <div>
        <div style={chartWrap}>
          <div style={ctStyle}>晟邦模組成本隨量下降（NT$／顆）· 內部量產估算</div>
          <svg
            viewBox="0 0 420 180"
            style={{ width: '100%', height: 'auto', display: 'block' }}
            role="img"
            aria-label="模組量產成本曲線"
          >
            <defs>
              <linearGradient id="jrVolLine" x1="0" x2="1">
                <stop offset="0" stopColor="#F96C1A" />
                <stop offset="1" stopColor="#1E88D6" />
              </linearGradient>
            </defs>
            <line x1="50" y1="150" x2="400" y2="150" stroke={borderStrong} strokeWidth="2" />
            <polyline
              fill="none"
              stroke="url(#jrVolLine)"
              strokeWidth="5"
              strokeLinecap="round"
              strokeLinejoin="round"
              points="80,44 215,100 360,124"
            />
            <g textAnchor="middle">
              <circle cx="80" cy="44" r="6" fill={orange} />
              <text x="80" y="32" fontSize="13" fill={text1} fontWeight="800">
                900
              </text>
              <text x="80" y="172" fontSize="14" fill={text2} fontWeight="700">
                現況/小量
              </text>

              <circle cx="215" cy="100" r="6" fill={purple} />
              <text x="215" y="88" fontSize="13" fill={text1} fontWeight="800">
                ~500
              </text>
              <text x="215" y="172" fontSize="14" fill={text2} fontWeight="700">
                1 萬台
              </text>

              <circle cx="360" cy="124" r="6" fill={deepBlue} />
              <text x="360" y="112" fontSize="13" fill={text1} fontWeight="800">
                ~400
              </text>
              <text x="360" y="172" fontSize="14" fill={text2} fontWeight="700">
                10 萬台
              </text>
            </g>
          </svg>
        </div>

        <p style={{ margin: '16px 0 0', fontSize: 20, lineHeight: 1.55, color: text2 }}>
          依規模單套 <b>1,000–2,000</b>；硬體靠量產壓低、人力與維護隨規模攤薄。硬體由
          <b>政府長照標案採購</b>、差額補助，公司<b>不靠硬體賺錢</b>，獲利走服務訂閱＋標案。
        </p>
        <p style={{ margin: '11px 0 0', fontSize: 20, lineHeight: 1.55, color: text2 }}>
          對照政府預算：<b>7 萬台 × NT$1,400 ≈ 9.8 億元</b>，在衛福部 <b>62.5 億元</b>{' '}
          獨居長者特別預算之內，<b>不需要新的財源</b>。
        </p>
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 13 — 願景
   ══════════════════════════════════════════════════════════════════ */

const Vision: Page = () => (
  <div style={{ ...padded, justifyContent: 'center' }}>
    <NumTag>願景</NumTag>

    <div
      style={{
        marginTop: 24,
        background: GRAD,
        color: '#fff',
        padding: '70px 81px',
        borderRadius: 38,
        boxShadow: '0 40px 94px rgba(249,108,26,.30)',
        boxSizing: 'border-box',
      }}
    >
      <h2
        style={{
          margin: 0,
          fontFamily: 'var(--osd-font-display)',
          fontSize: 60,
          lineHeight: 1.1,
          fontWeight: 800,
          letterSpacing: '-.025em',
          color: '#fff',
        }}
      >
        四端接成一張網：
        <br />
        長輩安心、兒女放心、社工減壓、志工有為。
      </h2>

      <p
        style={{
          margin: '24px 0 0',
          fontSize: 29,
          lineHeight: 1.5,
          fontWeight: 300,
          color: 'rgba(255,255,255,.92)',
          maxWidth: 1250,
        }}
      >
        十年內，把「一個人在家」變成「附近有人能接手」。感知 → 決策 → 行動 →
        回報，一條會呼吸的社區互助閉環。
      </p>
      <p
        style={{
          margin: '14px 0 0',
          fontSize: 29,
          lineHeight: 1.5,
          fontWeight: 300,
          color: 'rgba(255,255,255,.92)',
          maxWidth: 1250,
        }}
      >
        目標很具體：把獨居長輩的求助覆蓋率，從台北市今天的 <b style={{ fontWeight: 700 }}>7%</b> 拉到{' '}
        <b style={{ fontWeight: 700 }}>全台 70 萬人</b>；讓{' '}
        <b style={{ fontWeight: 700 }}>110 萬名志工</b> 的每一小時，都存進自己的時間銀行。
      </p>

      <div style={{ display: 'flex', gap: 76, alignItems: 'center', marginTop: 43 }}>
        <div>
          <div style={{ fontSize: 43, fontWeight: 900, lineHeight: 1.2 }}>金孫收音機</div>
          <div style={{ fontSize: 21, color: 'rgba(255,255,255,.92)' }}>近端 AI 陪伴與社區互助派遣</div>
        </div>
        <div>
          <div style={{ fontSize: 43, fontWeight: 900, lineHeight: 1.2 }}>2026</div>
          <div style={{ fontSize: 21, color: 'rgba(255,255,255,.92)' }}>AI 創新獎 · 智慧照護</div>
        </div>
      </div>
    </div>

    <Footer label="金孫收音機 · 台灣十年提案" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 14 — 四端畫面 · Live Demo（全幅四分割）
   ══════════════════════════════════════════════════════════════════ */

const appqCell: CSSProperties = {
  position: 'relative',
  overflow: 'hidden',
  backgroundSize: 'cover',
  backgroundPosition: 'center',
  padding: '202px 16px 30px',
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  justifyContent: 'flex-start',
  gap: 11,
  textDecoration: 'none',
  color: 'inherit',
  boxSizing: 'border-box',
};

const AppqInner = ({ shot, alt, cap, sub }: { shot: string; alt: string; cap: string; sub: string }) => (
  <>
    <div
      style={{
        position: 'absolute',
        inset: 0,
        background: 'linear-gradient(to top, rgba(12,9,6,.72), rgba(12,9,6,.25))',
      }}
    />
    <img
      src={shot}
      alt={alt}
      style={{
        position: 'relative',
        zIndex: 2,
        width: '88%',
        height: 'auto',
        display: 'block',
        borderRadius: 14,
        boxShadow: '0 16px 40px rgba(0,0,0,.4)',
        marginBottom: 8,
      }}
    />
    <div
      style={{
        position: 'relative',
        zIndex: 2,
        color: '#fff',
        fontWeight: 800,
        fontSize: 23,
        textShadow: '0 1px 5px rgba(0,0,0,.6)',
      }}
    >
      {cap}
    </div>
    <div
      style={{
        position: 'relative',
        zIndex: 2,
        color: 'rgba(255,255,255,.9)',
        fontSize: 17,
        textShadow: '0 1px 4px rgba(0,0,0,.6)',
      }}
    >
      {sub}
    </div>
  </>
);

const FourScreens: Page = () => (
  <div style={bleed}>
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'grid',
        gridTemplateColumns: 'repeat(4, 1fr)',
      }}
    >
      <div style={{ ...appqCell, backgroundImage: `url(${pElder})` }}>
        <AppqInner shot={appElder} alt="長輩畫面" cap="👵 長輩" sub="收音機・按住說話" />
      </div>

      <a
        href="https://d22h4jxlikk4jo.cloudfront.net/"
        target="_blank"
        rel="noopener"
        style={{
          ...appqCell,
          backgroundImage: `url(${pChild})`,
          boxShadow: '-1px 0 0 rgba(255,255,255,.14)',
        }}
      >
        <AppqInner shot={appFamily} alt="家屬 App" cap="🧑‍💼 兒女" sub="家屬 App · ▶ 點我開啟" />
      </a>

      <a
        href="https://d3inbvxprhol1.cloudfront.net/"
        target="_blank"
        rel="noopener"
        style={{
          ...appqCell,
          backgroundImage: `url(${pVolunteer})`,
          boxShadow: '-1px 0 0 rgba(255,255,255,.14)',
        }}
      >
        <AppqInner shot={appVolunteer} alt="志工 App" cap="🤝 志工" sub="志工 App · ▶ 點我開啟" />
      </a>

      <a
        href="https://d2o5h7ul68enq.cloudfront.net/"
        target="_blank"
        rel="noopener"
        style={{
          ...appqCell,
          backgroundImage: `url(${pWorker})`,
          boxShadow: '-1px 0 0 rgba(255,255,255,.14)',
        }}
      >
        <AppqInner shot={appWorker} alt="社工後台" cap="🧑‍⚕️ 社工" sub="Web 後台・Excel · ▶ 點我開啟" />
      </a>
    </div>

    <div style={tfHead}>
      <b style={tfHeadTitle}>
        同一起事件，<G>四端各自看到為他設計的畫面</G>
      </b>
      <div
        style={{
          marginTop: 10,
          paddingTop: 10,
          borderTop: `1px solid ${border}`,
          fontSize: 19.5,
          color: text2,
          lineHeight: 1.4,
        }}
      >
        <Bo>主要族群</Bo>只用一台<Bo>收音機</Bo>、免看螢幕；<Bo>次要族群</Bo>用 <Bo>App</Bo>{' '}
        掌握四端。網頁後台＋兩端 App <Bo>已部署上線</Bo>，現在就能點開。
      </div>
    </div>

    <BleedNum />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   transition — same motion family as the other decks in this workspace
   ══════════════════════════════════════════════════════════════════ */

const EASE_OUT = 'cubic-bezier(0, 0, 0.2, 1)';
const EASE_IN = 'cubic-bezier(0.4, 0, 1, 1)';

export const transition: SlideTransition = {
  duration: 200,
  exit: {
    duration: 140,
    easing: EASE_IN,
    keyframes: [
      { opacity: 1, transform: 'translateX(0)' },
      { opacity: 0, transform: 'translateX(-8px)' },
    ],
  },
  enter: {
    duration: 200,
    delay: 80,
    easing: EASE_OUT,
    keyframes: [
      { opacity: 0, transform: 'translateX(10px)' },
      { opacity: 1, transform: 'translateX(0)' },
    ],
  },
};

export const meta: SlideMeta = {
  title: '金孫收音機 · 台灣十年提案',
  createdAt: '2026-08-02T00:46:21.572Z',
};

export default [
  Cover,
  Scale,
  Manpower,
  ThreePains,
  FourFixes,
  ProductDesign,
  Hardware,
  EdgeChip,
  GenAi,
  Architecture,
  Segments,
  Cost,
  Vision,
  FourScreens,
] satisfies Page[];
