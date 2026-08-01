// jinsun-auth —— Cognito 的兩個觸發器（同一支 Lambda，靠 triggerSource 分流）。
//
//   PreSignUp        自動確認帳號。原環境（Supabase）註冊完就直接有 session，
//                    三端 App 沒有「輸入驗證碼」這個畫面；要保住同樣的流程，
//                    就得在這裡自動確認，否則 UI 得整個改。
//   PostConfirmation 把使用者加進對應的 Cognito Group，並寫一筆 profiles 到 Aurora
//                    （原本由 auth.users 的 trg_new_user 觸發器做，Aurora 沒有那張表）。
//
// ⚠️ 角色不是完全自助的：`worker`（社工）只能由管理者事後 admin-add-user-to-group，
// 自助註冊一律只給 family / volunteer。理由很直接——社工角色在 authz.mjs 裡是「全看、
// 全改」，如果註冊表單上自己選就能當社工，那整套授權等於沒做。

import {
  CognitoIdentityProviderClient,
  AdminAddUserToGroupCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { createAuroraSql } from './src/db.js';

const idp = new CognitoIdentityProviderClient({});

/** 允許自助註冊的角色。worker 不在其中（見檔頭說明）。 */
const SELF_SERVICE_ROLES = new Set(['family', 'volunteer']);

export const handler = async (event) => {
  const source = event.triggerSource || '';

  if (source.startsWith('PreSignUp')) {
    // 自動確認：註冊完立刻可登入，維持與原環境相同的 UX。
    event.response.autoConfirmUser = true;
    if (event.request.userAttributes?.email) event.response.autoVerifyEmail = true;
    if (event.request.userAttributes?.phone_number) event.response.autoVerifyPhone = true;
    return event;
  }

  if (source.startsWith('PostConfirmation')) {
    const attrs = event.request.userAttributes || {};
    const wanted = (attrs['custom:role'] || 'family').toLowerCase();
    const role = SELF_SERVICE_ROLES.has(wanted) ? wanted : 'family';
    if (wanted !== role) {
      console.warn(`[auth] 拒絕自助指派角色 ${wanted}，退回 family（sub=${attrs.sub}）`);
    }

    try {
      await idp.send(new AdminAddUserToGroupCommand({
        UserPoolId: event.userPoolId,
        Username: event.userName,
        GroupName: role,
      }));
    } catch (e) {
      // 加不進 group 就等於沒有角色，authz 會一律拒絕——要吵得夠大聲才找得到原因。
      console.error('[auth] AdminAddUserToGroup 失敗：', e?.message || e);
      throw e;
    }

    // profiles 寫失敗不擋登入：帳號已經建立了，這裡再擋只會讓使用者卡在註冊完成畫面。
    try {
      const db = await createAuroraSql();
      if (db) {
        await db.query(
          `insert into profiles (id, role, name, phone)
           values (:id::uuid, :role::user_role, :name, :phone)
           on conflict (id) do update
              set role = excluded.role, name = excluded.name, phone = excluded.phone`,
          {
            id: attrs.sub,
            role,
            name: attrs.name || '',
            phone: attrs.phone_number || attrs['custom:phone'] || null,
          },
        );
      } else {
        console.warn('[auth] Aurora 未設定，跳過 profiles 寫入');
      }
    } catch (e) {
      console.error('[auth] 寫 profiles 失敗（不擋登入）：', e?.message || e);
    }
    return event;
  }

  return event;
};
