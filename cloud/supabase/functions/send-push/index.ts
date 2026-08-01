// 金孫收音機 — 推播發送 Edge Function（FCM HTTP v1 代理）
//
// 用途：長輩事件與派遣單一有變化，就把「事件通知」推給對應的家屬／志工手機。
// 由 Supabase Database Webhook 觸發（radio_events、dispatch_tasks 的 INSERT/UPDATE）。
//
// 隱私邊界：推播只承載事件文字（跌倒/SOS/派遣單狀態），永遠不含原始影音，
// 與裝置端本地推論的約束一致（見 docs/architecture.md）。
//
// 資料流：
//   webhook(record) → 依規則產生通知文案＋收件者 → 查 device_tokens
//                   → 用 FCM v1 (OAuth2 service account) 逐一發送
//
// 需要的 secret（supabase secrets set ...）：
//   FCM_PROJECT_ID       Firebase 專案 ID
//   FCM_CLIENT_EMAIL     service account client_email
//   FCM_PRIVATE_KEY      service account private_key（含 -----BEGIN...，\n 可保留）
//   PUSH_WEBHOOK_SECRET  自訂密鑰，與 Database Webhook 的 header 比對
//   （SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 由平台自動注入）
//
// 部署：
//   supabase functions deploy send-push --project-ref <ref>
//   supabase secrets set FCM_PROJECT_ID=... FCM_CLIENT_EMAIL=... \
//       FCM_PRIVATE_KEY="$(cat sa.json | jq -r .private_key)" \
//       PUSH_WEBHOOK_SECRET=... --project-ref <ref>
// 詳細（含 Database Webhook 設定）見 docs/requirements/push-notifications.md。

import { createClient } from 'jsr:@supabase/supabase-js@2';

const FCM_PROJECT_ID = Deno.env.get('FCM_PROJECT_ID')!;
const FCM_CLIENT_EMAIL = Deno.env.get('FCM_CLIENT_EMAIL')!;
const FCM_PRIVATE_KEY = (Deno.env.get('FCM_PRIVATE_KEY') ?? '').replace(/\\n/g, '\n');
const PUSH_WEBHOOK_SECRET = Deno.env.get('PUSH_WEBHOOK_SECRET');

const sb = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
);

// ---- 收件者與通知文案 ----

type Audience = { role?: string; elderId?: string };
interface PushMsg {
  title: string;
  body: string;
  audience: Audience;
  data: Record<string, string>;
}

// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;

interface WebhookPayload {
  type: 'INSERT' | 'UPDATE' | 'DELETE';
  table: string;
  record: Row | null;
  old_record: Row | null;
}

async function elderName(elderId: string | null | undefined): Promise<string> {
  if (!elderId) return '長輩';
  const { data } = await sb.from('elders').select('name').eq('id', elderId).maybeSingle();
  return (data?.name as string) ?? '長輩';
}

async function elderInfo(
  elderId: string | null | undefined,
): Promise<{ name: string; address: string }> {
  if (!elderId) return { name: '長輩', address: '' };
  const { data } = await sb.from('elders').select('name,address').eq('id', elderId)
    .maybeSingle();
  return {
    name: (data?.name as string) ?? '長輩',
    address: (data?.address as string) ?? '',
  };
}

/// 依 webhook 變化決定要發哪些通知（沿用三端 App 內的通知文案語氣）。
async function buildMessages(p: WebhookPayload): Promise<PushMsg[]> {
  const r = p.record;
  if (!r) return [];
  const out: PushMsg[] = [];

  if (p.table === 'radio_events') {
    const name = await elderName(r.elder_id);
    const data = { kind: 'event', eventId: String(r.id ?? ''), elderId: String(r.elder_id ?? '') };
    const prevStatus = p.old_record?.status;

    if (p.type === 'INSERT' && r.type === 'sos') {
      out.push({ title: '🆘 緊急求助', body: `${name} 按下 SOS，已派遣志工前往`,
        audience: { elderId: r.elder_id }, data });
      out.push({ title: '🆘 緊急派遣', body: `${name} 按下 SOS，請盡快支援`,
        audience: { role: 'volunteer' }, data });
    } else if (p.type === 'INSERT' && r.type === 'fall_suspected' && r.status === 'open') {
      out.push({ title: '⚠️ 疑似跌倒', body: `${name} 疑似跌倒，收音機確認中…`,
        audience: { elderId: r.elder_id }, data });
    } else if (p.type === 'UPDATE' && r.status === 'escalated' && prevStatus !== 'escalated') {
      out.push({ title: '🚨 跌倒無回應', body: `${name} 疑似跌倒且無回應，已派遣`,
        audience: { elderId: r.elder_id }, data });
      out.push({ title: '🚨 緊急派遣', body: `${name} 疑似跌倒無回應，請盡快支援`,
        audience: { role: 'volunteer' }, data });
    } else if (p.type === 'UPDATE' && r.status === 'confirmed_ok' && prevStatus !== 'confirmed_ok') {
      out.push({ title: '✅ 事件解除', body: `${name} 回應「我沒事」，事件已解除`,
        audience: { elderId: r.elder_id }, data });
    }
  }

  if (p.table === 'dispatch_tasks') {
    const info = await elderInfo(r.elder_id);
    const name = info.name;
    const data = {
      kind: 'dispatch',
      taskId: String(r.id ?? ''),
      elderId: String(r.elder_id ?? ''),
      dispatchKind: String(r.kind ?? ''),
      address: info.address,
    };
    const prevStatus = p.old_record?.status;

    if (p.type === 'INSERT') {
      // 物資單不跳推播（只在 App 內列表呈現）；只有緊急單推給志工。
      if (r.kind === 'emergency') {
        out.push({
          title: '🚨 緊急派遣・請支援',
          body: `${name}，位置在 ${info.address}`,
          audience: { role: 'volunteer' },
          data: { ...data, offer: '1' },
        });
      }
    } else if (p.type === 'UPDATE') {
      const who = r.assignee_name ?? '志工';
      // 卡單改派：緊急單仍 pending 但指派對象變了 → 廣播「請支援」給全體志工補位。
      if (
        r.kind === 'emergency' && r.status === 'pending' &&
        prevStatus === 'pending' && r.assignee_name !== p.old_record?.assignee_name
      ) {
        out.push({
          title: '🚨 請支援',
          body: `${name}，位置在 ${info.address}（原志工逾時未動身，其他志工也可接單）`,
          audience: { role: 'volunteer' },
          data: { ...data, offer: '1' },
        });
      } else if (r.status !== prevStatus) {
        if (r.status === 'accepted') {
          const eta = r.eta_minutes ? `預計 ${r.eta_minutes} 分鐘到` : '前往';
          out.push({ title: '🚗 志工已接單', body: `${who} 已接單，${eta} ${name} 家`,
            audience: { elderId: r.elder_id }, data });
        } else if (r.status === 'arrived') {
          out.push({ title: '📍 志工已抵達', body: `${who} 已抵達 ${name} 家`,
            audience: { elderId: r.elder_id }, data });
        } else if (r.status === 'resolved') {
          out.push({ title: '✅ 已確認平安', body: `${name} 已確認平安，事件結束`,
            audience: { elderId: r.elder_id }, data });
        }
      }
    }
  }

  // 來電（限時遮罩通話）：背景／被系統凍結的 App 收不到 realtime 號誌，
  // 靠這則推播叫醒；App 端點擊後由 CallListener 開來電畫面再接聽。
  if (p.table === 'call_signals' && p.type === 'INSERT' && r.status === 'ringing') {
    const fromName = (r.from_name as string) ??
      (r.from_role === 'volunteer' ? '志工' : '家屬');
    out.push({
      title: '📞 來電',
      body: `${fromName} 來電中（號碼已遮蔽・安全轉接）`,
      audience: { role: r.to_role },
      data: {
        kind: 'call',
        signalId: String(r.id ?? ''),
        taskId: String(r.task_id ?? ''),
        room: String(r.room ?? ''),
        fromRole: String(r.from_role ?? ''),
        toRole: String(r.to_role ?? ''),
        fromName: String(r.from_name ?? ''),
      },
    });
  }

  return out;
}

async function tokensFor(a: Audience): Promise<string[]> {
  let q = sb.from('device_tokens').select('token');
  if (a.elderId) q = q.contains('elder_ids', [a.elderId]);
  else if (a.role) q = q.eq('role', a.role);
  else return [];
  const { data, error } = await q;
  if (error) { console.error('[send-push] 查 token 失敗', error); return []; }
  return (data ?? []).map((r) => r.token as string);
}

// ---- FCM HTTP v1（OAuth2 service account）----

let _cachedToken: { token: string; exp: number } | null = null;

function pemToBuf(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '').replace(/\s+/g, '');
  const raw = atob(b64);
  const buf = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i);
  return buf.buffer;
}

function b64url(bytes: Uint8Array | string): string {
  const str = typeof bytes === 'string' ? bytes
    : String.fromCharCode(...bytes);
  return btoa(str).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function getAccessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (_cachedToken && _cachedToken.exp - 60 > now) return _cachedToken.token;

  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = b64url(JSON.stringify({
    iss: FCM_CLIENT_EMAIL,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));
  const key = await crypto.subtle.importKey(
    'pkcs8', pemToBuf(FCM_PRIVATE_KEY),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign'],
  );
  const sig = new Uint8Array(await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claim}`),
  ));
  const jwt = `${header}.${claim}.${b64url(sig)}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`OAuth 失敗：${JSON.stringify(body)}`);
  _cachedToken = { token: body.access_token, exp: now + (body.expires_in ?? 3600) };
  return _cachedToken.token;
}

async function sendToToken(accessToken: string, m: PushMsg, token: string): Promise<boolean> {
  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FCM_PROJECT_ID}/messages:send`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: m.title, body: m.body },
          data: m.data,
          android: { priority: 'high', notification: { channel_id: 'jinsun_alerts' } },
          apns: { payload: { aps: { sound: 'default' } } },
        },
      }),
    },
  );
  if (res.ok) return true;
  const err = await res.text();
  // token 失效（UNREGISTERED / INVALID_ARGUMENT）→ 清掉，避免累積死 token。
  if (res.status === 404 || res.status === 400) {
    await sb.from('device_tokens').delete().eq('token', token);
  }
  console.error(`[send-push] FCM ${res.status}: ${err}`);
  return false;
}

// ---- HTTP entry ----

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  // 驗證 webhook 來源（Database Webhook 設定自訂 header：x-webhook-secret）
  if (PUSH_WEBHOOK_SECRET &&
      req.headers.get('x-webhook-secret') !== PUSH_WEBHOOK_SECRET) {
    return new Response('unauthorized', { status: 401 });
  }

  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return new Response('bad request', { status: 400 });
  }

  const messages = await buildMessages(payload);
  if (messages.length === 0) return Response.json({ sent: 0, skipped: true });

  const accessToken = await getAccessToken();
  let sent = 0;
  for (const m of messages) {
    const tokens = await tokensFor(m.audience);
    for (const t of tokens) {
      if (await sendToToken(accessToken, m, t)) sent++;
    }
  }
  return Response.json({ sent });
});
