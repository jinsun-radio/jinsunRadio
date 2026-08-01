// 角色授權 —— 取代 Supabase RLS 的那一層。
//
// 為什麼要重寫：Supabase 的 policy 全部靠 `auth.uid()`，Aurora 沒有這個函式，
// 而且原本的 policy 是 demo 全開（`for select using (true)`），本來就不能照搬。
// 這裡把「家屬只看得到綁定的長輩、志工只看得到自己的單或已開放搶單的單、社工全看」
// 落實成 **SQL 述詞**（讀）與 **op 白名單＋擁有權檢查**（寫）。
//
// 這個檔刻意寫成純函式、不碰資料庫：授權規則是最容易寫錯又最不容易被發現寫錯的地方，
// 要能單獨測。所有值一律走具名參數，述詞裡不做任何字串拼接使用者輸入。

/**
 * 家屬綁定的長輩子查詢（其餘述詞都建立在它上面）。
 * `::uuid` 不可省：Data API 的參數一律是 text，Postgres 不會隱式轉 uuid（見 db.js）。
 */
const BOUND_ELDERS = '(select elder_id from family_bindings where family_id = :uid::uuid)';

/**
 * 志工「看得到」的單：自己的單，或已經開放搶的單。
 *
 * - 緊急單只要還是 pending 就全體看得見（現行行為：指派給最近的人，但其他人可接單補位，
 *   看門狗改派時的通知就是這樣寫的）。
 * - 物資單有 3 分鐘寬限期，`offered_until` 到期前只有被 offer 的督導志工看得到。
 * - 追蹤單（follow_up）是給督導本人的待辦，永不進搶單池。
 */
const VOLUNTEER_TASK = `(
  t.assignee_name = :vname
  or (t.status = 'pending' and t.kind <> 'follow_up'
      and (t.kind = 'emergency' or t.offered_until is null or t.offered_until < now()))
)`;

export const ROLES = ['family', 'volunteer', 'worker'];

/**
 * 從 API Gateway JWT authorizer 的 claims 取出身分。
 * 角色以 Cognito Group 為準（`cognito:groups`）——group 只有管理者能改，
 * 自訂屬性使用者自己就能改，不能拿來當授權依據。
 */
export function principalFrom(event) {
  const claims = event?.requestContext?.authorizer?.jwt?.claims || {};
  const raw = claims['cognito:groups'];
  // claims 裡的 groups 可能是陣列，也可能是 "[family]" 這種字串（HTTP API 會攤平）
  const groups = Array.isArray(raw)
    ? raw
    : String(raw || '').replace(/[[\]]/g, '').split(/[\s,]+/).filter(Boolean);
  const role = ROLES.find((r) => groups.includes(r)) || null;
  return {
    sub: claims.sub || null,
    role,
    name: claims.name || '',
    phone: claims.phone_number || '',
    groups,
  };
}

/**
 * 讀取用的 SQL 述詞。每個 key 對應 snapshot 裡的一張表，值是可直接塞進 where 的片段。
 * 別名固定：elders=e、radio_events=ev、dispatch_tasks=t、volunteers=v、
 * task_messages=m、call_signals=c。
 */
export function readScope(principal) {
  const { role } = principal;
  if (role === 'worker') {
    return {
      elders: 'true',
      events: 'true',
      tasks: 'true',
      volunteers: 'true',
      workers: 'true',
      messages: 'true',
      calls: 'true',
    };
  }
  if (role === 'family') {
    return {
      elders: `e.id in ${BOUND_ELDERS}`,
      events: `ev.elder_id in ${BOUND_ELDERS}`,
      tasks: `t.elder_id in ${BOUND_ELDERS}`,
      // 家屬只看得到「與自己長輩有關」的志工：接了單的人，或長期關懷的督導志工。
      // 志工名冊不是家屬該看的東西（有電話、位置）。
      volunteers: `v.name in (
        select assignee_name from dispatch_tasks
          where elder_id in ${BOUND_ELDERS} and assignee_name is not null
        union
        select supervisor_volunteer_name from elders
          where id in ${BOUND_ELDERS} and supervisor_volunteer_name is not null
      )`,
      workers: 'false',
      messages: `m.task_id in (select id from dispatch_tasks where elder_id in ${BOUND_ELDERS})`,
      calls: `c.task_id in (select id::text from dispatch_tasks where elder_id in ${BOUND_ELDERS})`,
    };
  }
  if (role === 'volunteer') {
    const visibleTasks = `(select t.id from dispatch_tasks t where ${VOLUNTEER_TASK})`;
    return {
      // 只看得到「手上有單／可接單」那幾位長輩，不是全體名冊
      elders: `e.id in (select t.elder_id from dispatch_tasks t where ${VOLUNTEER_TASK})`,
      events: `ev.elder_id in (select t.elder_id from dispatch_tasks t where ${VOLUNTEER_TASK})`,
      tasks: VOLUNTEER_TASK,
      // 志工彼此看得到（App 要從名冊找出自己、後台指派時也要比較負載）
      volunteers: 'true',
      workers: 'false',
      messages: `m.task_id in ${visibleTasks}`,
      calls: `c.task_id in (select id::text from dispatch_tasks t where ${VOLUNTEER_TASK})`,
    };
  }
  // 沒有角色＝什麼都看不到（不是「全看」——預設拒絕）
  return {
    elders: 'false', events: 'false', tasks: 'false', volunteers: 'false',
    workers: 'false', messages: 'false', calls: 'false',
  };
}

/**
 * 寫入白名單：op → 允許的角色。
 * `own` 代表除了角色之外還要通過擁有權檢查（見 ownershipCheck）。
 */
export const WRITE_RULES = {
  acceptTask: { roles: ['volunteer', 'worker'], own: 'taskVisible' },
  markArrived: { roles: ['volunteer', 'worker', 'family'], own: 'taskVisible' },
  resolveTask: { roles: ['volunteer', 'worker', 'family'], own: 'taskVisible' },
  updateTaskEta: { roles: ['volunteer', 'worker'], own: 'taskAssignee' },
  assignVolunteer: { roles: ['worker'] },
  reassignTask: { roles: ['worker', 'family', 'volunteer'], own: 'taskVisible' },
  cancelSupplyTask: { roles: ['family', 'worker'], own: 'taskVisible' },
  sendTaskMessage: { roles: ['family', 'volunteer', 'worker'], own: 'taskVisible' },
  startCall: { roles: ['family', 'volunteer', 'worker'], own: 'taskVisible' },
  setCallStatus: { roles: ['family', 'volunteer', 'worker'] },
  proofUploadUrl: { roles: ['volunteer', 'worker'], own: 'taskVisible' },

  setElderLang: { roles: ['family', 'worker'], own: 'elderVisible' },
  // 狀況注記是社工的個管紀錄，家屬不能改
  setElderNote: { roles: ['worker'] },
  // 基本資料相反——家屬才知道長輩的住址與電話，社工可代填
  updateElderProfile: { roles: ['family', 'worker'], own: 'elderVisible' },

  setVolunteerLocation: { roles: ['volunteer'], own: 'self' },
  setVolunteerOnline: { roles: ['volunteer'], own: 'self' },
  submitCertificate: { roles: ['volunteer'], own: 'self' },
  redeemTimeBank: { roles: ['volunteer'], own: 'self' },

  bindFamily: { roles: ['family'] },
  setAppSetting: { roles: ['worker'] },
  registerDeviceToken: { roles: ['family', 'volunteer', 'worker'] },
  unregisterDeviceToken: { roles: ['family', 'volunteer', 'worker'] },
};

/** 角色層檢查。回傳 null＝放行，字串＝拒絕原因。 */
export function checkRole(op, principal) {
  const rule = WRITE_RULES[op];
  if (!rule) return `未知的操作：${op}`;
  if (!principal.role) return '未帶角色（Cognito group 未設定）';
  if (!rule.roles.includes(principal.role)) {
    return `${principal.role} 不能執行 ${op}`;
  }
  return null;
}

/**
 * 擁有權檢查需要查資料庫，所以由呼叫端提供 lookup。
 * @param {object} deps
 * @param {(taskId:string)=>Promise<object|null>} deps.getTask
 * @param {(elderId:string)=>Promise<boolean>} deps.elderVisible
 * @param {(taskId:string)=>Promise<boolean>} deps.taskVisible
 */
export async function checkOwnership(op, principal, args, deps) {
  const rule = WRITE_RULES[op];
  if (!rule?.own) return null;
  if (principal.role === 'worker') return null; // 社工是派遣中心，天生看得到全部

  switch (rule.own) {
    case 'taskVisible': {
      const id = args?.taskId;
      if (!id) return '缺少 taskId';
      return (await deps.taskVisible(id)) ? null : '這張單不在您的權限範圍';
    }
    case 'taskAssignee': {
      const t = await deps.getTask(args?.taskId);
      if (!t) return '找不到這張單';
      return t.assignee_name === principal.name ? null : '只有接單的志工能更新 ETA';
    }
    case 'elderVisible': {
      const id = args?.elderId;
      if (!id) return '缺少 elderId';
      return (await deps.elderVisible(id)) ? null : '這位長輩不在您的權限範圍';
    }
    case 'self': {
      // 志工資料以「顯示名」對應（現行資料模型就是用 name 串起來的，見 setVolunteerLocation）
      const target = args?.volunteerName;
      if (!target) return '缺少 volunteerName';
      return target === principal.name ? null : '只能修改自己的資料';
    }
    default:
      return `未知的擁有權規則：${rule.own}`;
  }
}
