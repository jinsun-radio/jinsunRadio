// 三端 App 的具名寫入操作 —— 一個 op 對應 BackendClient 的一個方法。
//
// 為什麼是「具名 op」而不是「傳一包 patch 進來 update」：後者等於把整張表的寫入權
// 開給前端，志工可以把自己的 points 改成一百萬、把別人的單改成自己的。這裡每個 op
// 的可寫欄位都是寫死的，客戶端送什麼多餘欄位都不會進 SQL。
//
// 時間戳一律用資料庫的 now()，不收客戶端時鐘——手機時間錯了會讓時間軸倒著長。

const PROGRESS_FN = process.env.PROGRESS_FN || 'jinsun-progress';
let _lambda = null;

/**
 * 觸發收音機的進度播報（jinsun-progress）。
 *
 * 為什麼要從這裡主動打：Aurora 沒有 Realtime，原本 Supabase 那套是
 * 「worker 訂閱 dispatch_tasks 變化」。純 AWS 環境若不在寫入點主動觸發，
 * 「志工接單 → 收音機說『志工○○大約○分鐘到』」就完全不會發生
 * ——而且是**靜默**不發生，三端畫面一切正常，只有長輩那端沒聲音。
 *
 * 用非同步 invoke（InvocationType: Event）＋吞掉錯誤：播報是附加價值，
 * 它掛掉不該讓志工的「接單」整個失敗。但一定要 log，否則就變成
 * aws-handoff.md §4 講的那種「只 log 不中斷」的難查症狀。
 */
async function notifyProgress(kind, record) {
  if (!record) return;
  try {
    if (!_lambda) {
      const { LambdaClient } = await import('@aws-sdk/client-lambda');
      _lambda = new LambdaClient({});
    }
    const { InvokeCommand } = await import('@aws-sdk/client-lambda');
    await _lambda.send(new InvokeCommand({
      FunctionName: PROGRESS_FN,
      InvocationType: 'Event',
      Payload: Buffer.from(JSON.stringify({ __direct: kind, record })),
    }));
  } catch (e) {
    console.error(`[ops] 觸發進度播報失敗（${kind}）：`, e?.message || e);
  }
}

/** 結單存入時間銀行的分鐘數。與 Dart models.dart 的 timeBankMinutes 同一套算法。 */
export function timeBankMinutes(kind, etaMinutes) {
  const serviceMinutes = (etaMinutes ?? 10) + 6;
  if (kind === 'emergency') return Math.round(serviceMinutes * 1.5);
  if (kind === 'supply') return serviceMinutes;
  return 0; // follow_up：督導專業工時，不計入志工時間銀行
}

/**
 * @param {{query:Function, queryOne:Function}} db
 * @param {object} principal 見 authz.principalFrom
 */
export function createOps(db, principal) {
  const { query, queryOne } = db;

  const task = (id) =>
    queryOne('select * from dispatch_tasks where id = :id::uuid', { id });

  return {
    // ── 派遣流程 ──────────────────────────────────────────────
    async acceptTask({ taskId, etaMinutes, assigneeName, assigneeId }) {
      // 只在單仍 pending 時才接得下。兩人同時搶接：後接者匹配 0 列 → 回 409，
      // 不會靜默覆蓋前接者、讓輸家的單無聲消失。
      const rows = await query(
        `update dispatch_tasks
            set status = 'accepted',
                assignee_name = :name,
                assignee_id = :assigneeId::uuid,
                eta_minutes = :eta::int,
                accepted_at = now()
          where id = :id::uuid and status = 'pending'
        returning *`,
        {
          id: taskId,
          name: assigneeName || principal.name || '志工',
          assigneeId: assigneeId ?? principal.sub ?? null,
          eta: etaMinutes ?? null,
        },
      );
      if (!rows.length) {
        const err = new Error('這張單已被其他志工接走');
        err.statusCode = 409;
        throw err;
      }
      // ① 出發播報 ＋ 啟動「路上每 10 分鐘」的 Step Functions 迴圈
      await notifyProgress('task', rows[0]);
      return { ok: true };
    },

    async markArrived({ taskId }) {
      const rows = await query(
        `update dispatch_tasks set status = 'arrived', arrived_at = now()
          where id = :id::uuid
        returning *`,
        { id: taskId },
      );
      // ③ 開門播報（若 GPS 已在 250m 內預告過，progress 那側會去重擋掉）
      await notifyProgress('task', rows[0]);
      return { ok: true };
    },

    async updateTaskEta({ taskId, etaMinutes }) {
      await query(
        'update dispatch_tasks set eta_minutes = :eta::int where id = :id::uuid',
        { id: taskId, eta: etaMinutes ?? null },
      );
      return { ok: true };
    },

    async assignVolunteer({ taskId, volunteerName, volunteerId, etaMinutes }) {
      await query(
        `update dispatch_tasks
            set assignee_name = :name,
                assignee_id = coalesce(:vid::uuid, assignee_id),
                eta_minutes = coalesce(:eta::int, eta_minutes)
          where id = :id::uuid`,
        { id: taskId, name: volunteerName, vid: volunteerId ?? null, eta: etaMinutes ?? null },
      );
      return { ok: true };
    },

    /** 改派下一位就近志工（看門狗與「請求支援」共用）。volunteerName 傳 null＝交回社工指派。 */
    async reassignTask({ taskId, volunteerName, windowMinutes }) {
      await query(
        `update dispatch_tasks
            set assignee_name = :name,
                offered_until = now() + (:mins::int || ' minutes')::interval
          where id = :id::uuid`,
        { id: taskId, name: volunteerName ?? null, mins: windowMinutes ?? 3 },
      );
      return { ok: true };
    },

    async cancelSupplyTask({ taskId, note }) {
      const t = await task(taskId);
      await query(
        `update dispatch_tasks
            set status = 'resolved', resolved_at = now(), note = :note
          where id = :id::uuid`,
        { id: taskId, note: note || '家屬自行處理，未派工' },
      );
      if (t?.event_id) {
        await query(
          "update radio_events set status = 'closed' where id = :id::uuid",
          { id: t.event_id },
        );
      }
      return { ok: true };
    },

    async resolveTask({ taskId, note, outcome, photoUrl }) {
      const t = await task(taskId);
      if (!t) {
        const err = new Error('找不到這張單');
        err.statusCode = 404;
        throw err;
      }
      await query(
        `update dispatch_tasks
            set status = 'resolved',
                resolved_at = now(),
                note = coalesce(nullif(:note, ''), note),
                outcome = coalesce(nullif(:outcome, ''), outcome),
                proof_photo_url = coalesce(nullif(:photo, ''), proof_photo_url)
          where id = :id::uuid`,
        { id: taskId, note: note ?? '', outcome: outcome ?? '', photo: photoUrl ?? '' },
      );
      if (t.event_id) {
        await query("update radio_events set status = 'closed' where id = :id::uuid",
          { id: t.event_id });
      }
      if (t.elder_id) {
        await query("update elders set severity = 'normal' where id = :id", { id: t.elder_id });
      }
      // 點數由伺服器依 kind＋eta 算，不收客戶端傳來的數字（否則志工可自行灌點）。
      const points = timeBankMinutes(t.kind, t.eta_minutes);
      if (t.assignee_name) {
        await query(
          `insert into time_bank_ledger (volunteer_name, task_id, points, reason)
           values (:name, :taskId::uuid, :points::int, :reason)`,
          {
            name: t.assignee_name,
            taskId,
            points,
            reason: t.kind === 'emergency' ? '緊急派遣完成（分鐘）' : '物資代購完成（分鐘）',
          },
        );
      }
      return { ok: true, points };
    },

    // ── 長輩 ──────────────────────────────────────────────────
    async setElderLang({ elderId, lang }) {
      const v = lang === 'taigi' ? 'taigi' : 'mandarin';
      await query('update elders set preferred_lang = :lang::lang_t where id = :id',
        { id: elderId, lang: v });
      return { ok: true };
    },

    async setElderNote({ elderId, note }) {
      const clean = (note ?? '').trim();
      await query('update elders set note = nullif(:note, \'\') where id = :id',
        { id: elderId, note: clean });
      return { ok: true };
    },

    // 家屬填的長輩基本資料——社工後台與志工派遣單上「長輩資訊」的唯一來源。
    async updateElderProfile({ elderId, name, age, address, phone, note, lat, lng }) {
      await query(
        `update elders
            set name = :name,
                age = :age::int,
                address = :address,
                phone = nullif(:phone, ''),
                note = nullif(:note, '')
          where id = :id`,
        {
          id: elderId,
          name: (name ?? '').trim(),
          age: Number(age) || 0,
          address: (address ?? '').trim(),
          phone: (phone ?? '').trim(),
          note: (note ?? '').trim(),
        },
      );
      // 座標分開更新：呼叫端沒帶＝地理編碼失敗，保留原本的地圖釘而不是覆蓋成 0,0。
      if (lat != null && lng != null) {
        await query(
          `update elders
              set lat = :lat::double precision,
                  lng = :lng::double precision
            where id = :id`,
          { id: elderId, lat, lng },
        );
      }
      return { ok: true };
    },

    // ── 志工自己的資料 ────────────────────────────────────────
    async setVolunteerLocation({ volunteerName, lat, lng }) {
      await query(
        `update volunteers
            set lat = :lat::double precision,
                lng = :lng::double precision,
                location_updated_at = now()
          where name = :name`,
        { name: volunteerName, lat, lng },
      );
      // ② 走進長輩家 250m 內就先預告開門（同一張單只預告一次）
      await notifyProgress('volunteer', { name: volunteerName, lat, lng });
      return { ok: true };
    },

    async setVolunteerOnline({ volunteerName, online }) {
      await query('update volunteers set online = :online::boolean where name = :name',
        { name: volunteerName, online: Boolean(online) });
      return { ok: true };
    },

    /**
     * 送出／更新一張證件。狀態一律寫 pending——志工不能自行核可
     * （良民證這種背景審查不可自助通過），要社工端核可後才 valid。
     */
    async submitCertificate({ volunteerName, kind, issuedAt, expiresAt, note }) {
      const v = await queryOne('select id from volunteers where name = :name',
        { name: volunteerName });
      if (!v) {
        const err = new Error('找不到這位志工');
        err.statusCode = 404;
        throw err;
      }
      await query(
        `insert into volunteer_certificates (volunteer_id, kind, status, issued_at, expires_at, note)
         values (:vid, :kind, 'pending', :issued::date, :expires::date, :note)
         on conflict (volunteer_id, kind) do update
            set status = 'pending',
                issued_at = excluded.issued_at,
                expires_at = excluded.expires_at,
                note = excluded.note`,
        {
          vid: v.id, kind,
          issued: issuedAt ?? null,
          expires: expiresAt ?? null,
          note: note || '已送出，等待社工審核',
        },
      );
      return { ok: true };
    },

    async redeemTimeBank({ volunteerName, minutes, reason }) {
      const cur = await queryOne(
        'select coalesce(sum(points), 0)::int as total from time_bank_ledger where volunteer_name = :name',
        { name: volunteerName },
      );
      const total = cur?.total ?? 0;
      if (minutes > total) {
        const err = new Error('時數不足');
        err.statusCode = 400;
        throw err;
      }
      await query(
        `insert into time_bank_ledger (volunteer_name, points, reason)
         values (:name, :points::int, :reason)`,
        { name: volunteerName, points: -Math.abs(minutes), reason: `兌換：${reason}` },
      );
      return { ok: true, remaining: total - Math.abs(minutes) };
    },

    // ── 聊天與通話 ────────────────────────────────────────────
    async sendTaskMessage({ taskId, fromRole, text }) {
      const t = (text || '').trim();
      if (!t) return { ok: true, skipped: true };
      const rows = await query(
        `insert into task_messages (task_id, from_role, sender_id, text)
         values (:taskId::uuid, :role::chat_from_t, :sender::uuid, :text)
         returning *`,
        { taskId, role: fromRole, sender: principal.sub ?? null, text: t },
      );
      return { ok: true, row: rows[0] };
    },

    async startCall({ taskId, room, fromRole, toRole, fromName }) {
      const rows = await query(
        `insert into call_signals (task_id, room, from_role, to_role, status, from_name)
         values (:taskId, :room, :from, :to, 'ringing', :fromName)
         returning *`,
        {
          taskId, room, from: fromRole, to: toRole,
          fromName: fromName ?? principal.name ?? null,
        },
      );
      return { ok: true, row: rows[0] };
    },

    async setCallStatus({ signalId, status }) {
      const rows = await query(
        'update call_signals set status = :status where id = :id::uuid returning *',
        { id: signalId, status },
      );
      return { ok: true, row: rows[0] ?? null };
    },

    // ── 綁定／設定／推播 token ────────────────────────────────
    async bindFamily({ elderId }) {
      // 一律綁到「呼叫者自己」，不收客戶端傳來的 family_id（否則可綁到別人身上偷看）
      await query(
        `insert into family_bindings (family_id, elder_id) values (:uid::uuid, :elderId)
         on conflict (family_id, elder_id) do nothing`,
        { uid: principal.sub, elderId },
      );
      return { ok: true };
    },

    async setAppSetting({ key, value }) {
      await query(
        `insert into app_settings (key, value, updated_at) values (:k, :v, now())
         on conflict (key) do update set value = excluded.value, updated_at = now()`,
        { k: key, v: value },
      );
      return { ok: true };
    },

    async registerDeviceToken({ token, platform, elderIds }) {
      await query(
        `insert into device_tokens (token, user_id, role, platform, elder_ids, updated_at)
         values (:token, :uid::uuid, :role, :platform, :elderIds::text[], now())
         on conflict (token) do update
            set user_id = excluded.user_id, role = excluded.role,
                platform = excluded.platform, elder_ids = excluded.elder_ids,
                updated_at = now()`,
        {
          token, uid: principal.sub, role: principal.role,
          platform: platform ?? null, elderIds: elderIds ?? [],
        },
      );
      return { ok: true };
    },

    async unregisterDeviceToken({ token }) {
      // 只能刪自己的 token
      await query('delete from device_tokens where token = :token and user_id = :uid::uuid',
        { token, uid: principal.sub });
      return { ok: true };
    },
  };
}
