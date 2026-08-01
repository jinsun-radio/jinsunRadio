// jinsun-data 的授權規則測試。
//
// 放在 cloud/prototype/test/ 是為了讓 `npm test` 一個指令就跑得到——授權是這次遷移裡
// 最容易寫錯又最不容易被發現寫錯的地方（原環境的 RLS 根本是 demo 全開），
// 不能讓它躺在一個沒人會跑的目錄。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  principalFrom, readScope, checkRole, checkOwnership, WRITE_RULES,
} from '../../aws/lambda/data/authz.mjs';
import { timeBankMinutes } from '../../aws/lambda/data/ops.mjs';

const evt = (claims) => ({ requestContext: { authorizer: { jwt: { claims } } } });

test('principalFrom：角色只認 Cognito group，不認自訂屬性', () => {
  const p = principalFrom(evt({
    sub: 'u-1', name: '阿明', 'cognito:groups': ['volunteer'], 'custom:role': 'worker',
  }));
  assert.equal(p.role, 'volunteer', 'custom:role 使用者自己就能改，不可當授權依據');
});

test('principalFrom：groups 被攤平成 "[family]" 字串時也要解得出來', () => {
  const p = principalFrom(evt({ sub: 'u-2', 'cognito:groups': '[family]' }));
  assert.equal(p.role, 'family');
});

test('principalFrom：沒有 group＝沒有角色（不是預設 family）', () => {
  const p = principalFrom(evt({ sub: 'u-3' }));
  assert.equal(p.role, null);
});

test('readScope：無角色一律 false（預設拒絕，不是預設全開）', () => {
  const s = readScope({ role: null });
  for (const [k, v] of Object.entries(s)) {
    assert.equal(v, 'false', `${k} 應為 false`);
  }
});

test('readScope：社工全看、家屬綁定過濾、志工不看志工名冊以外的東西', () => {
  const worker = readScope({ role: 'worker' });
  assert.equal(worker.elders, 'true');
  assert.equal(worker.workers, 'true');

  const family = readScope({ role: 'family' });
  assert.match(family.elders, /family_bindings/);
  assert.match(family.tasks, /family_bindings/);
  assert.equal(family.workers, 'false', '家屬不該看到社工名單');
  assert.match(family.volunteers, /assignee_name/, '家屬只看得到接自己單的志工');

  const vol = readScope({ role: 'volunteer' });
  assert.match(vol.tasks, /assignee_name = :vname/);
  assert.equal(vol.workers, 'false');
  assert.match(vol.elders, /dispatch_tasks/, '志工只看得到有單的長輩，不是全體名冊');
});

test('readScope（志工）：追蹤單不進搶單池、物資單寬限期內不外流', () => {
  const vol = readScope({ role: 'volunteer' });
  assert.match(vol.tasks, /kind <> 'follow_up'/);
  assert.match(vol.tasks, /offered_until is null or t\.offered_until < now\(\)/);
});

test('readScope：述詞裡不含任何被拼接的使用者輸入（一律具名參數）', () => {
  for (const role of ['family', 'volunteer', 'worker', null]) {
    const s = readScope({ role, name: "'; drop table elders; --" });
    for (const frag of Object.values(s)) {
      assert.doesNotMatch(frag, /drop table/i);
    }
  }
});

test('checkRole：社工專屬操作擋掉家屬與志工', () => {
  for (const op of ['assignVolunteer', 'setElderNote', 'setAppSetting']) {
    assert.equal(checkRole(op, { role: 'worker', name: 'w' }), null);
    assert.ok(checkRole(op, { role: 'family', name: 'f' }));
    assert.ok(checkRole(op, { role: 'volunteer', name: 'v' }));
  }
});

test('checkRole：未知 op 一律拒絕（白名單，不是黑名單）', () => {
  assert.ok(checkRole('deleteEverything', { role: 'worker', name: 'w' }));
});

test('checkRole：沒有角色的帳號什麼都不能寫', () => {
  for (const op of Object.keys(WRITE_RULES)) {
    assert.ok(checkRole(op, { role: null, name: '' }), `${op} 應被拒絕`);
  }
});

test('checkOwnership：志工不能改別人的資料', async () => {
  const p = { role: 'volunteer', name: '阿明', sub: 'u-1' };
  const deps = { getTask: async () => null, taskVisible: async () => true, elderVisible: async () => true };
  assert.equal(await checkOwnership('setVolunteerLocation', p, { volunteerName: '阿明' }, deps), null);
  assert.ok(await checkOwnership('setVolunteerLocation', p, { volunteerName: '阿華' }, deps));
  assert.ok(await checkOwnership('redeemTimeBank', p, { volunteerName: '阿華' }, deps),
    '兌換別人的時數必須擋掉');
});

test('checkOwnership：看不到的單不能結案', async () => {
  const p = { role: 'volunteer', name: '阿明', sub: 'u-1' };
  const deps = {
    getTask: async () => ({ assignee_name: '阿華' }),
    taskVisible: async () => false,
    elderVisible: async () => false,
  };
  assert.ok(await checkOwnership('resolveTask', p, { taskId: 't-9' }, deps));
  assert.ok(await checkOwnership('setElderLang', p, { elderId: 'elder-9' }, deps));
});

test('checkOwnership：只有接單的志工能改 ETA', async () => {
  const deps = {
    getTask: async () => ({ assignee_name: '阿明' }),
    taskVisible: async () => true,
    elderVisible: async () => true,
  };
  assert.equal(
    await checkOwnership('updateTaskEta', { role: 'volunteer', name: '阿明' }, { taskId: 't-1' }, deps),
    null,
  );
  assert.ok(
    await checkOwnership('updateTaskEta', { role: 'volunteer', name: '阿華' }, { taskId: 't-1' }, deps),
  );
});

test('checkOwnership：社工是派遣中心，跳過擁有權檢查', async () => {
  const deps = { getTask: async () => null, taskVisible: async () => false, elderVisible: async () => false };
  assert.equal(await checkOwnership('resolveTask', { role: 'worker', name: 'w' }, { taskId: 't-1' }, deps), null);
});

test('timeBankMinutes 與 Dart models.dart 的算法一致', () => {
  // serviceMinutes = eta + 6；緊急 ×1.5（四捨五入）；follow_up 不計
  assert.equal(timeBankMinutes('emergency', 8), 21); // (8+6)*1.5 = 21
  assert.equal(timeBankMinutes('supply', 8), 14);
  assert.equal(timeBankMinutes('follow_up', 8), 0);
  assert.equal(timeBankMinutes('supply', null), 16); // eta 缺值時退回 10
});
