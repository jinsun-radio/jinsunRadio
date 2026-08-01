import type { CSSProperties } from 'react';
import type { DesignSystem, Page, SlideMeta, SlideTransition } from '@open-slide/core';

export const design: DesignSystem = {
  palette: { bg: '#0B1220', text: '#E9EFF8', accent: '#FF9900' },
  fonts: {
    display: 'ui-sans-serif, system-ui, "PingFang TC", "Noto Sans TC", sans-serif',
    body: 'ui-sans-serif, system-ui, "PingFang TC", "Noto Sans TC", sans-serif',
  },
  typeScale: { hero: 64, body: 32 },
  radius: 12,
};

/* ── colors outside the DesignSystem shape ─────────────────────────── */
const panel = '#101B2D';
const panelSoft = '#0D1729';
const stroke = '#1F2E47';
const muted = '#8298B4';
const green = '#34D399';
const cyan = '#22D3EE';
const purple = '#A78BFA';
const blue = '#60A5FA';
const rose = '#FB7185';
const amber = '#FF9900';
const mono = 'ui-monospace, SFMono-Regular, Menlo, monospace';

const fill = {
  position: 'relative',
  width: '100%',
  height: '100%',
  background:
    'radial-gradient(1200px 700px at 78% -10%, #16233A 0%, rgba(11,18,32,0) 70%), var(--osd-bg)',
  color: 'var(--osd-text)',
  fontFamily: 'var(--osd-font-body)',
  overflow: 'hidden',
} as const;

/* ── shared keyframes ──────────────────────────────────────────────── */
const CSS = `
@keyframes jsPulse {
  0%   { box-shadow: 0 0 0 0 var(--js-glow); border-color: var(--js-edge); }
  16%  { box-shadow: 0 0 0 12px transparent; border-color: var(--js-edge); }
  40%  { box-shadow: 0 0 0 0 transparent; border-color: rgba(255,255,255,0.09); }
  100% { box-shadow: 0 0 0 0 transparent; border-color: rgba(255,255,255,0.09); }
}
@keyframes jsRun {
  0%   { transform: translateX(0);      opacity: 0; }
  6%   { opacity: 1; }
  94%  { opacity: 1; }
  100% { transform: translateX(1450px); opacity: 0; }
}
@keyframes jsBoundary {
  0%, 100% { opacity: 0.35; }
  50%      { opacity: 0.9; }
}
@keyframes jsBreathe {
  0%, 100% { opacity: 0.55; }
  50%      { opacity: 1; }
}
`;

const Styles = () => <style>{CSS}</style>;

/* ══════════════════════════════════════════════════════════════════════
   PAGE 1 — deployment topology
   ══════════════════════════════════════════════════════════════════ */

const Chip = ({
  x,
  y,
  w,
  h,
  title,
  sub,
  line3,
  tone,
  dashed,
}: {
  x: number;
  y: number;
  w: number;
  h: number;
  title: string;
  sub: string;
  line3?: string;
  tone: string;
  dashed?: boolean;
}) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      width: w,
      height: h,
      boxSizing: 'border-box',
      background: panel,
      border: `1.5px ${dashed ? 'dashed' : 'solid'} ${dashed ? stroke : 'rgba(255,255,255,0.09)'}`,
      borderLeft: `4px solid ${tone}`,
      borderRadius: 'var(--osd-radius)',
      padding: '0 16px',
      display: 'flex',
      flexDirection: 'column',
      justifyContent: 'center',
      gap: 5,
      opacity: dashed ? 0.62 : 1,
    }}
  >
    <div style={{ fontSize: 24, fontWeight: 700, letterSpacing: '-0.01em', lineHeight: 1.1 }}>
      {title}
    </div>
    <div style={{ fontSize: 16, color: muted, lineHeight: 1.25 }}>{sub}</div>
    {line3 ? (
      <div style={{ fontSize: 15, color: tone, fontFamily: mono, lineHeight: 1.2 }}>{line3}</div>
    ) : null}
  </div>
);

const GroupBox = ({
  x,
  y,
  w,
  h,
  label,
  tone,
  dashed,
}: {
  x: number;
  y: number;
  w: number;
  h: number;
  label: string;
  tone: string;
  dashed?: boolean;
}) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      width: w,
      height: h,
      boxSizing: 'border-box',
      border: `1.5px ${dashed ? 'dashed' : 'solid'} ${tone}`,
      borderRadius: 18,
      background: 'rgba(255,255,255,0.015)',
    }}
  >
    <div
      style={{
        position: 'absolute',
        left: 20,
        top: 14,
        fontSize: 17,
        letterSpacing: '0.16em',
        color: tone,
        fontFamily: mono,
      }}
    >
      {label}
    </div>
  </div>
);

const ColLabel = ({ x, y, text }: { x: number; y: number; text: string }) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      fontSize: 17,
      letterSpacing: '0.14em',
      color: muted,
      fontFamily: mono,
    }}
  >
    {text}
  </div>
);

const NoteCard = ({
  x,
  y,
  w,
  h,
  text,
  tone,
}: {
  x: number;
  y: number;
  w: number;
  h: number;
  text: string;
  tone: string;
}) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      width: w,
      height: h,
      boxSizing: 'border-box',
      background: panelSoft,
      border: `1px dashed ${stroke}`,
      borderRadius: 'var(--osd-radius)',
      padding: '16px 18px',
      fontSize: 17,
      lineHeight: 1.55,
      color: muted,
      borderTop: `2px solid ${tone}`,
    }}
  >
    {text}
  </div>
);

const EdgeLabel = ({
  x,
  y,
  text,
  tone,
}: {
  x: number;
  y: number;
  text: string;
  tone: string;
}) => (
  <div
    style={{
      position: 'absolute',
      left: x,
      top: y,
      fontSize: 15,
      color: tone,
      fontFamily: mono,
      letterSpacing: '0.02em',
      whiteSpace: 'nowrap',
    }}
  >
    {text}
  </div>
);

const LegendDot = ({ color, text }: { color: string; text: string }) => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
    <span
      style={{
        width: 10,
        height: 10,
        borderRadius: 5,
        background: color,
        boxShadow: `0 0 10px ${color}`,
      }}
    />
    <span style={{ fontSize: 16, color: muted }}>{text}</span>
  </div>
);

const Packet = ({
  path,
  color,
  dur,
  begin,
  r,
}: {
  path: string;
  color: string;
  dur: string;
  begin: string;
  r?: number;
}) => (
  <circle r={r ?? 6} fill={color} style={{ filter: `drop-shadow(0 0 7px ${color})` }}>
    <animateMotion path={path} dur={dur} begin={begin} repeatCount="indefinite" />
  </circle>
);

const Topology: Page = () => (
  <div style={fill}>
    <Styles />

    {/* header */}
    <div
      style={{
        position: 'absolute',
        left: 48,
        top: 40,
        fontSize: 17,
        letterSpacing: '0.24em',
        color: amber,
        fontFamily: mono,
      }}
    >
      AWS · us-west-2 · ACCOUNT 012804034919
    </div>
    <h1
      style={{
        position: 'absolute',
        left: 46,
        top: 66,
        margin: 0,
        fontFamily: 'var(--osd-font-display)',
        fontSize: 'var(--osd-size-hero)',
        fontWeight: 800,
        letterSpacing: '-0.02em',
      }}
    >
      金孫收音機 · AWS 部署全景
    </h1>
    <div
      style={{
        position: 'absolute',
        right: 48,
        top: 46,
        display: 'flex',
        gap: 26,
        alignItems: 'center',
      }}
    >
      <LegendDot color={amber} text="上行 HTTPS" />
      <LegendDot color={green} text="下行 MQTT" />
      <LegendDot color={rose} text="緊急升級" />
      <LegendDot color={purple} text="AI 推論" />
      <LegendDot color={blue} text="資料讀寫" />
      <LegendDot color={cyan} text="前端輪詢" />
    </div>
    <div
      style={{
        position: 'absolute',
        right: 48,
        top: 84,
        fontSize: 16,
        color: muted,
        fontFamily: mono,
      }}
    >
      虛線 ＝ 尚未接線 · 2026-08-01 逐項 aws CLI 實查
    </div>

    {/* ── 家中近端 ─────────────────────────────────────────────── */}
    <GroupBox x={48} y={150} w={290} h={350} label="家中近端" tone="#3E5878" />
    <Chip
      x={72}
      y={206}
      w={242}
      h={96}
      title="Himax WiseEye2"
      sub="跌倒視覺推論 · 未實作"
      tone={muted}
      dashed
    />
    <Chip
      x={72}
      y={336}
      w={242}
      h={130}
      title="HUB8735 Ultra"
      sub="錄音 · TTS · SOS 鍵"
      line3="BACKEND_AWS = 1"
      tone={amber}
    />

    {/* ── 外部服務 ─────────────────────────────────────────────── */}
    <GroupBox x={48} y={620} w={290} h={236} label="外部服務 · 非 AWS" tone="#3E5878" dashed />
    <Chip
      x={72}
      y={674}
      w={242}
      h={86}
      title="XCC Gateway"
      sub="faster-whisper Breeze-ASR"
      tone="#6F86A6"
    />
    <Chip x={72} y={774} w={242} h={62} title="TTS Gateway" sub="kws.oaselab.org" tone="#6F86A6" />
    <div
      style={{
        position: 'absolute',
        left: 52,
        top: 878,
        width: 286,
        fontSize: 16,
        lineHeight: 1.5,
        color: muted,
      }}
    >
      ASR / TTS 仍走外部服務：Transcribe 與 Polly 都沒有台語，而這是長輩唯一的輸入方式。
    </div>

    {/* ── 隱私邊界 ─────────────────────────────────────────────── */}
    <div
      style={{
        position: 'absolute',
        left: 361,
        top: 150,
        width: 2,
        height: 890,
        background: `repeating-linear-gradient(to bottom, ${amber} 0 10px, transparent 10px 22px)`,
        animation: 'jsBoundary 3.2s ease-in-out infinite',
      }}
    />
    <div
      style={{
        position: 'absolute',
        left: 366,
        top: 690,
        width: 20,
        writingMode: 'vertical-rl',
        fontSize: 15,
        letterSpacing: '0.18em',
        color: amber,
        fontFamily: mono,
      }}
    >
      隱私邊界 · 影像永不跨線
    </div>

    {/* ── AWS 邊界 ─────────────────────────────────────────────── */}
    <GroupBox x={386} y={150} w={1194} h={890} label="AWS CLOUD · US-WEST-2" tone="#2C4A6E" />

    <ColLabel x={410} y={206} text="入口層" />
    <Chip
      x={410}
      y={244}
      w={244}
      h={128}
      title="API Gateway"
      sub="HTTP API · yr0ep335el"
      line3="/voice /asr /data/*"
      tone={amber}
    />
    <Chip
      x={410}
      y={396}
      w={244}
      h={128}
      title="IoT Core"
      sub="X.509 雙向 TLS · QoS 1"
      line3="jinsun/{serial}/cmd"
      tone={green}
    />
    <Chip
      x={410}
      y={548}
      w={244}
      h={118}
      title="Cognito"
      sub="3 groups · JWT authorizer"
      tone={cyan}
    />
    <NoteCard
      x={410}
      y={700}
      w={244}
      h={172}
      tone={amber}
      text="唯一的 HTTPS 入口。/asr 刻意不掛 JWT——長輩端是裝置身分，不該為了轉一句逐字稿去換 token。"
    />

    <ColLabel x={710} y={206} text="運算層 · LAMBDA ×5" />
    <Chip x={710} y={244} w={244} h={74} title="jinsun-voice" sub="六個 Agent · 意圖分流" tone={amber} />
    <Chip x={710} y={332} w={244} h={74} title="jinsun-data" sub="三端 API ＋ 角色授權" tone={blue} />
    <Chip x={710} y={420} w={244} h={74} title="jinsun-progress" sub="進度播報去重" tone={green} />
    <Chip x={710} y={508} w={244} h={74} title="jinsun-speak" sub="publish 一句話到 IoT" tone={green} />
    <Chip x={710} y={596} w={244} h={74} title="jinsun-auth" sub="Cognito 觸發器" tone={cyan} />

    <ColLabel x={710} y={706} text="編排層 · STEP FUNCTIONS" />
    <Chip
      x={710}
      y={744}
      w={244}
      h={96}
      title="EmergencyLadder"
      sub="絕對時間戳 8s → 20s"
      tone={rose}
    />
    <Chip
      x={710}
      y={854}
      w={244}
      h={96}
      title="EnrouteBroadcast"
      sub="路上每 10 分鐘"
      tone={rose}
    />

    <ColLabel x={1010} y={206} text="AI 層" />
    <Chip
      x={1010}
      y={244}
      w={244}
      h={108}
      title="Bedrock"
      sub="Sonnet 4.6 · Haiku 4.5"
      line3="us. 前綴才叫得動"
      tone={purple}
    />
    <Chip
      x={1010}
      y={366}
      w={244}
      h={108}
      title="SageMaker"
      sub="breeze-asr-26 · 台語 ASR"
      line3="InService · 未接線"
      tone={purple}
      dashed
    />

    <ColLabel x={1010} y={510} text="資料層" />
    <Chip
      x={1010}
      y={548}
      w={244}
      h={108}
      title="Aurora"
      sub="Serverless v2 · Data API"
      line3="PG 16.14 · 0.5–4 ACU"
      tone={blue}
    />
    <Chip x={1010} y={670} w={244} h={96} title="DynamoDB ×3" sub="三張表皆有 TTL" tone={blue} />
    <Chip x={1010} y={780} w={244} h={82} title="S3 · proofs" sub="結案照片 presigned PUT" tone={blue} />
    <Chip x={1010} y={876} w={244} h={82} title="Secrets Manager" sub="Aurora 主密碼託管" tone={blue} />

    <ColLabel x={1310} y={206} text="前端託管" />
    <Chip x={1310} y={244} w={244} h={108} title="S3 ×4" sub="四端 Flutter Web 靜態站" tone={cyan} />
    <Chip
      x={1310}
      y={366}
      w={244}
      h={108}
      title="CloudFront ×4"
      sub="HTTPS · 麥克風與定位必需"
      tone={cyan}
    />

    <ColLabel x={1310} y={510} text="可觀測性 · 安全" />
    <Chip x={1310} y={548} w={244} h={96} title="CloudWatch Logs" sub="/aws/lambda/jinsun-*" tone="#6F86A6" />
    <Chip x={1310} y={658} w={244} h={82} title="IAM ×6 role" sub="每支 Lambda 最小權限" tone="#6F86A6" />
    <NoteCard
      x={1310}
      y={790}
      w={244}
      h={170}
      tone={cyan}
      text="與正式環境 Supabase 完全斷開的平行環境。四端靠 BACKEND=aws 單一切換點。"
    />

    {/* ── 四端 ─────────────────────────────────────────────────── */}
    <ColLabel x={1604} y={206} text="四端 · FLUTTER WEB" />
    <Chip x={1604} y={244} w={268} h={104} title="家屬 App" sub="安心日報 · 緊急通知" tone={cyan} />
    <Chip x={1604} y={362} w={268} h={104} title="志工 App" sub="派遣接單 · 到場回報" tone={cyan} />
    <Chip x={1604} y={480} w={268} h={104} title="社工後台" sub="dashboard · Excel 匯出" tone={cyan} />
    <Chip
      x={1604}
      y={598}
      w={268}
      h={118}
      title="長輩端收音機"
      sub="網頁版 · 無 UI"
      line3="裝置帳號自動登入"
      tone={amber}
    />
    <NoteCard
      x={1604}
      y={750}
      w={268}
      h={190}
      tone={cyan}
      text="沒有 WebSocket：每 3 秒 GET /data/version 比對六張表的 md5 指紋，變了才抓 snapshot。黃金窗是 20 秒，3 秒偵測延遲綽綽有餘。"
    />

    {/* ── 連線與封包 ────────────────────────────────────────────── */}
    <svg
      width={1920}
      height={1080}
      viewBox="0 0 1920 1080"
      style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}
    >
      <defs>
        <marker id="mA" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
          <path d="M0,0 L9,4.5 L0,9 z" fill={amber} />
        </marker>
        <marker id="mG" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
          <path d="M0,0 L9,4.5 L0,9 z" fill={green} />
        </marker>
        <marker id="mB" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
          <path d="M0,0 L9,4.5 L0,9 z" fill={blue} />
        </marker>
        <marker id="mP" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
          <path d="M0,0 L9,4.5 L0,9 z" fill={purple} />
        </marker>
        <marker id="mR" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
          <path d="M0,0 L9,4.5 L0,9 z" fill={rose} />
        </marker>
        <marker id="mC" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
          <path d="M0,0 L9,4.5 L0,9 z" fill={cyan} />
        </marker>
        <marker id="mM" markerWidth="9" markerHeight="9" refX="7" refY="4.5" orient="auto">
          <path d="M0,0 L9,4.5 L0,9 z" fill="#6F86A6" />
        </marker>
      </defs>

      {/* 家中：相機 → 主控 */}
      <path d="M 193 302 V 336" stroke="#3E5878" strokeWidth="1.6" fill="none" markerEnd="url(#mM)" />

      {/* 主控 ↔ 外部 ASR / TTS */}
      <path d="M 176 466 V 674" stroke="#6F86A6" strokeWidth="1.6" fill="none" strokeDasharray="6 6" markerEnd="url(#mM)" />
      <path d="M 210 674 V 466" stroke="#6F86A6" strokeWidth="1.6" fill="none" strokeDasharray="6 6" markerEnd="url(#mM)" />

      {/* ① 上行 HTTPS */}
      <path d="M 314 380 H 372 V 300 H 410" stroke={amber} strokeWidth="2" fill="none" markerEnd="url(#mA)" />
      {/* ② 下行 MQTT */}
      <path d="M 410 450 H 372 V 430 H 314" stroke={green} strokeWidth="2" fill="none" markerEnd="url(#mG)" />

      {/* API GW → Lambda */}
      <path d="M 654 292 H 682 V 274 H 710" stroke={amber} strokeWidth="2" fill="none" markerEnd="url(#mA)" />
      <path d="M 654 330 H 682 V 362 H 710" stroke={blue} strokeWidth="2" fill="none" markerEnd="url(#mB)" />

      {/* voice → Bedrock ; data → Aurora ; progress → DynamoDB */}
      <path d="M 954 274 H 982 V 292 H 1010" stroke={purple} strokeWidth="2" fill="none" markerEnd="url(#mP)" />
      <path d="M 954 362 H 990 V 596 H 1010" stroke={blue} strokeWidth="2" fill="none" markerEnd="url(#mB)" />
      <path d="M 954 452 H 972 V 712 H 1010" stroke={blue} strokeWidth="1.6" fill="none" strokeDasharray="5 5" markerEnd="url(#mB)" />

      {/* Lambda → Step Functions */}
      <path d="M 832 676 V 738" stroke={rose} strokeWidth="2" fill="none" markerEnd="url(#mR)" />
      {/* Step Functions → jinsun-speak */}
      <path d="M 710 780 H 678 V 530 H 710" stroke={rose} strokeWidth="2" fill="none" markerEnd="url(#mR)" />
      {/* jinsun-speak → IoT Core */}
      <path d="M 710 560 H 692 V 470 H 656" stroke={green} strokeWidth="2" fill="none" markerEnd="url(#mG)" />

      {/* Cognito ↔ API Gateway */}
      <path d="M 654 590 H 672 V 344 H 656" stroke={cyan} strokeWidth="1.6" fill="none" strokeDasharray="5 5" markerEnd="url(#mC)" />

      {/* CloudFront → 四端 */}
      <path d="M 1554 420 H 1580" stroke={cyan} strokeWidth="2" fill="none" />
      <path d="M 1580 296 V 657" stroke={cyan} strokeWidth="2" fill="none" />
      <path d="M 1580 296 H 1604" stroke={cyan} strokeWidth="2" fill="none" markerEnd="url(#mC)" />
      <path d="M 1580 414 H 1604" stroke={cyan} strokeWidth="2" fill="none" markerEnd="url(#mC)" />
      <path d="M 1580 532 H 1604" stroke={cyan} strokeWidth="2" fill="none" markerEnd="url(#mC)" />
      <path d="M 1580 657 H 1604" stroke={cyan} strokeWidth="2" fill="none" markerEnd="url(#mC)" />

      {/* 四端 → API Gateway 輪詢 */}
      <path
        d="M 1738 944 V 1004 H 402 V 386 H 532 V 374"
        stroke={cyan}
        strokeWidth="1.8"
        fill="none"
        strokeDasharray="7 6"
        markerEnd="url(#mC)"
      />

      {/* 封包 */}
      <Packet path="M 314 380 H 372 V 300 H 410" color={amber} dur="2.6s" begin="0s" />
      <Packet path="M 654 292 H 682 V 274 H 710" color={amber} dur="1.6s" begin="2.6s" />
      <Packet path="M 954 274 H 982 V 292 H 1010" color={purple} dur="1.6s" begin="4.2s" />
      <Packet path="M 832 676 V 738" color={rose} dur="1.4s" begin="0.9s" />
      <Packet path="M 710 780 H 678 V 530 H 710" color={rose} dur="2.6s" begin="2.3s" />
      <Packet path="M 710 560 H 692 V 470 H 656" color={green} dur="1.6s" begin="4.9s" />
      <Packet path="M 410 450 H 372 V 430 H 314" color={green} dur="2.2s" begin="6.5s" />
      <Packet path="M 654 330 H 682 V 362 H 710" color={blue} dur="1.8s" begin="1.4s" />
      <Packet path="M 954 362 H 990 V 596 H 1010" color={blue} dur="2.4s" begin="3.2s" />
      <Packet path="M 176 466 V 674" color="#6F86A6" dur="2.4s" begin="0.4s" r={5} />
      <Packet path="M 210 674 V 466" color="#6F86A6" dur="2.4s" begin="3.4s" r={5} />
      <Packet path="M 1738 944 V 1004 H 402 V 386 H 532 V 374" color={cyan} dur="6s" begin="0s" r={5} />
      <Packet path="M 1580 296 V 657" color={cyan} dur="2.8s" begin="1.2s" r={5} />
    </svg>

    {/* 連線標籤（畫在 svg 之上，避免被線壓住） */}
    <EdgeLabel x={252} y={504} text="① 錄音上行" tone="#6F86A6" />
    <EdgeLabel x={222} y={560} text="逐字稿" tone="#6F86A6" />
    <EdgeLabel x={252} y={344} text="POST /voice" tone={amber} />
    <EdgeLabel x={252} y={396} text="speak / ask" tone={green} />
    <EdgeLabel x={846} y={700} text="StartExecution" tone={rose} />
    <EdgeLabel x={1050} y={968} text="每 3 秒 GET /data/version（無 WebSocket）" tone={cyan} />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════
   PAGE 2 — animated data flows
   ══════════════════════════════════════════════════════════════════ */

const TRACK_X = 410;
const NODE_W = 220;
const NODE_STEP = 246;
const nodeX = (k: number) => TRACK_X + k * NODE_STEP;

const FlowNode = ({
  top,
  k,
  title,
  sub,
  tone,
  delay,
  time,
}: {
  top: number;
  k: number;
  title: string;
  sub: string;
  tone: string;
  delay: string;
  time?: string;
}) => (
  <>
    <div
      style={
        {
          position: 'absolute',
          left: nodeX(k),
          top: top + 52,
          width: NODE_W,
          height: 96,
          boxSizing: 'border-box',
          background: panel,
          border: '1.5px solid rgba(255,255,255,0.09)',
          borderRadius: 'var(--osd-radius)',
          padding: '0 16px',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'center',
          gap: 6,
          animation: 'jsPulse 6s linear infinite',
          animationDelay: delay,
          '--js-glow': `${tone}80`,
          '--js-edge': tone,
        } as CSSProperties
      }
    >
      <div style={{ fontSize: 22, fontWeight: 700, lineHeight: 1.1, letterSpacing: '-0.01em' }}>
        {title}
      </div>
      <div style={{ fontSize: 15, color: muted, lineHeight: 1.25 }}>{sub}</div>
    </div>
    <div
      style={{
        position: 'absolute',
        left: nodeX(k),
        top: top + 46,
        width: 4,
        height: 108,
        borderRadius: 2,
        background: tone,
        opacity: 0.9,
      }}
    />
    {time ? (
      <div
        style={{
          position: 'absolute',
          left: nodeX(k),
          top: top + 156,
          width: NODE_W,
          textAlign: 'center',
          fontSize: 16,
          fontFamily: mono,
          color: tone,
        }}
      >
        {time}
      </div>
    ) : null}
  </>
);

const LaneChrome = ({
  top,
  badge,
  title,
  sub,
  tone,
  packetDelay,
}: {
  top: number;
  badge: string;
  title: string;
  sub: string;
  tone: string;
  packetDelay: string;
}) => (
  <>
    <div
      style={{
        position: 'absolute',
        left: 48,
        top,
        width: 1824,
        height: 200,
        boxSizing: 'border-box',
        background: 'rgba(255,255,255,0.014)',
        border: '1px solid rgba(255,255,255,0.05)',
        borderRadius: 16,
      }}
    />
    <div
      style={{
        position: 'absolute',
        left: 72,
        top: top + 70,
        width: 60,
        height: 60,
        borderRadius: 14,
        background: tone,
        color: '#0B1220',
        fontSize: 32,
        fontWeight: 800,
        fontFamily: mono,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      {badge}
    </div>
    <div
      style={{
        position: 'absolute',
        left: 148,
        top: top + 58,
        width: 250,
        fontSize: 28,
        fontWeight: 800,
        letterSpacing: '-0.01em',
        lineHeight: 1.2,
      }}
    >
      {title}
    </div>
    <div
      style={{
        position: 'absolute',
        left: 148,
        top: top + 98,
        width: 254,
        fontSize: 17,
        lineHeight: 1.45,
        color: muted,
      }}
    >
      {sub}
    </div>
    {/* track */}
    <div
      style={{
        position: 'absolute',
        left: TRACK_X,
        top: top + 99,
        width: 1450,
        height: 2,
        background: 'rgba(255,255,255,0.10)',
      }}
    />
    {/* packet */}
    <div
      style={{
        position: 'absolute',
        left: 403,
        top: top + 93,
        width: 14,
        height: 14,
        borderRadius: 7,
        background: tone,
        boxShadow: `0 0 18px 4px ${tone}`,
        animation: 'jsRun 6s linear infinite',
        animationDelay: packetDelay,
      }}
    />
  </>
);

const GoldenBracket = ({ top }: { top: number }) => (
  <>
    <div
      style={{
        position: 'absolute',
        left: nodeX(2),
        top: top + 32,
        width: nodeX(4) + NODE_W - nodeX(2),
        height: 2,
        background: rose,
        opacity: 0.7,
      }}
    />
    <div
      style={{
        position: 'absolute',
        left: nodeX(2),
        top: top + 32,
        width: 2,
        height: 12,
        background: rose,
        opacity: 0.7,
      }}
    />
    <div
      style={{
        position: 'absolute',
        left: nodeX(4) + NODE_W - 2,
        top: top + 32,
        width: 2,
        height: 12,
        background: rose,
        opacity: 0.7,
      }}
    />
    <div
      style={{
        position: 'absolute',
        left: nodeX(2),
        top: top + 4,
        width: nodeX(4) + NODE_W - nodeX(2),
        textAlign: 'center',
        fontSize: 18,
        fontFamily: mono,
        color: rose,
        letterSpacing: '0.08em',
        animation: 'jsBreathe 2.4s ease-in-out infinite',
      }}
    >
      黃金窗 20 秒 · 計時器活在 Step Functions，不在任何行程裡
    </div>
  </>
);

const LANE_A = 176;
const LANE_B = 392;
const LANE_C = 608;
const LANE_D = 824;

const Flows: Page = () => (
  <div style={fill}>
    <Styles />

    <div
      style={{
        position: 'absolute',
        left: 48,
        top: 40,
        fontSize: 17,
        letterSpacing: '0.24em',
        color: amber,
        fontFamily: mono,
      }}
    >
      DATA FLOW · 四條主鏈路
    </div>
    <h1
      style={{
        position: 'absolute',
        left: 46,
        top: 66,
        margin: 0,
        fontFamily: 'var(--osd-font-display)',
        fontSize: 'var(--osd-size-hero)',
        fontWeight: 800,
        letterSpacing: '-0.02em',
      }}
    >
      一次事件，服務之間依序發生什麼
    </h1>
    <div
      style={{
        position: 'absolute',
        right: 48,
        top: 74,
        fontSize: 18,
        color: muted,
        textAlign: 'right',
        lineHeight: 1.5,
      }}
    >
      沒出現在這四條裡的連線，就是還沒接線的
    </div>

    {/* ── A ─────────────────────────────────────────────────────── */}
    <LaneChrome
      top={LANE_A}
      badge="A"
      title="長輩主動求助"
      sub="唯一會上雲的那段語音"
      tone={amber}
      packetDelay="0s"
    />
    <FlowNode top={LANE_A} k={0} title="長輩端" sub="按住大按鈕錄音" tone={amber} delay="-5.52s" />
    <FlowNode top={LANE_A} k={1} title="API Gateway" sub="POST /asr → /voice" tone={amber} delay="-4.50s" />
    <FlowNode top={LANE_A} k={2} title="jinsun-voice" sub="六個 Agent 分流" tone={amber} delay="-3.48s" />
    <FlowNode top={LANE_A} k={3} title="Bedrock" sub="Haiku 分類 → Sonnet 對話" tone={purple} delay="-2.46s" />
    <FlowNode top={LANE_A} k={4} title="Aurora" sub="開物資單 · 查偏好語言" tone={blue} delay="-1.44s" />
    <FlowNode top={LANE_A} k={5} title="長輩聽到回覆" sub="TTS 播報 · 國語／台語" tone={amber} delay="-0.43s" />

    {/* ── B ─────────────────────────────────────────────────────── */}
    <LaneChrome
      top={LANE_B}
      badge="B"
      title="20 秒黃金升級"
      sub="疑似跌倒 / SOS — 本系統最重要的一條"
      tone={rose}
      packetDelay="-1.2s"
    />
    <GoldenBracket top={LANE_B} />
    <FlowNode top={LANE_B} k={0} title="fall_suspected" sub="裝置本地推論後上行" tone={rose} delay="-6.72s" time="T0" />
    <FlowNode top={LANE_B} k={1} title="jinsun-voice" sub="同步回「您還好嗎」" tone={rose} delay="-5.70s" time="T0 · 同步回覆" />
    <FlowNode top={LANE_B} k={2} title="Step Functions" sub="Wait → step1At" tone={rose} delay="-4.68s" time="絕對時間戳" />
    <FlowNode top={LANE_B} k={3} title="jinsun-speak" sub="IoT publish · 再問一次" tone={green} delay="-3.66s" time="T0+8.0s" />
    <FlowNode top={LANE_B} k={4} title="Escalate" sub="寫 Aurora · 開緊急派遣單" tone={rose} delay="-2.64s" time="T0+20.0s ✓" />
    <FlowNode top={LANE_B} k={5} title="三端亮燈" sub="家屬 · 志工 · 社工" tone={cyan} delay="-1.63s" time="≤ 3s 內看到" />

    {/* ── C ─────────────────────────────────────────────────────── */}
    <LaneChrome
      top={LANE_C}
      badge="C"
      title="志工接單到結案"
      sub="Aurora 沒有 Realtime，改由 data 直接非同步 invoke"
      tone={green}
      packetDelay="-2.4s"
    />
    <FlowNode top={LANE_C} k={0} title="志工 App" sub="POST /data/mutate" tone={cyan} delay="-7.92s" />
    <FlowNode top={LANE_C} k={1} title="jinsun-data" sub="JWT ＋ 擁有權檢查" tone={blue} delay="-6.90s" />
    <FlowNode top={LANE_C} k={2} title="Aurora" sub="更新單 · 搶單衝突回 409" tone={blue} delay="-5.88s" />
    <FlowNode top={LANE_C} k={3} title="非同步 invoke" sub="__direct: accepted" tone={green} delay="-4.86s" />
    <FlowNode top={LANE_C} k={4} title="jinsun-progress" sub="DynamoDB 去重後 publish" tone={green} delay="-3.84s" />
    <FlowNode top={LANE_C} k={5} title="長輩聽到" sub="「大約 8 分鐘到」" tone={amber} delay="-2.83s" />

    {/* ── D ─────────────────────────────────────────────────────── */}
    <LaneChrome
      top={LANE_D}
      badge="D"
      title="四端即時同步"
      sub="變更指紋輪詢，不是 AppSync 訂閱"
      tone={cyan}
      packetDelay="-3.6s"
    />
    <FlowNode top={LANE_D} k={0} title="四端 App" sub="每 3 秒一次" tone={cyan} delay="-9.12s" />
    <FlowNode top={LANE_D} k={1} title="Cognito" sub="IdToken · cognito:groups" tone={cyan} delay="-8.10s" />
    <FlowNode top={LANE_D} k={2} title="/data/version" sub="六張表的 md5 指紋" tone={cyan} delay="-7.08s" />
    <FlowNode top={LANE_D} k={3} title="指紋沒變" sub="什麼都不做（絕大多數）" tone={muted} delay="-6.06s" />
    <FlowNode top={LANE_D} k={4} title="/data/snapshot" sub="單次 Data API 往返" tone={blue} delay="-5.04s" />
    <FlowNode top={LANE_D} k={5} title="依角色過濾" sub="家屬／志工／社工不同視野" tone={cyan} delay="-4.03s" />
  </div>
);

/* ══════════════════════════════════════════════════════════════════════ */

const EASE_OUT = 'cubic-bezier(0, 0, 0.2, 1)';
const EASE_IN = 'cubic-bezier(0.4, 0, 1, 1)';

export const transition: SlideTransition = {
  duration: 200,
  exit: {
    duration: 140,
    easing: EASE_IN,
    keyframes: [
      { opacity: 1, transform: 'translateY(0)' },
      { opacity: 0, transform: 'translateY(-4px)' },
    ],
  },
  enter: {
    duration: 200,
    delay: 80,
    easing: EASE_OUT,
    keyframes: [
      { opacity: 0, transform: 'translateY(6px)' },
      { opacity: 1, transform: 'translateY(0)' },
    ],
  },
};

export const meta: SlideMeta = {
  title: '金孫收音機 · AWS 部署與資料流',
  createdAt: '2026-08-01T11:55:26.324Z',
};

export default [Topology, Flows] satisfies Page[];
