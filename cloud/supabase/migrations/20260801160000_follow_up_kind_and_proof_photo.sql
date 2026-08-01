-- 補兩個「程式碼一直在用、schema 卻沒有」的東西。冪等，對有資料的正式 DB 安全。
--
-- ① dispatch_kind_t 缺 'follow_up'
--    supabase_backend.dart 的 _recordFallTrend 會在長輩 7 天內累積 3 次
--    「疑似跌倒但自行回應無恙」時，為督導開一張追蹤訪視待辦（kind='follow_up'）。
--    models.dart 也有對應的 DispatchKind.followUp。但 enum 只有 emergency / supply
--    → 那個 insert 一定失敗（22P02 invalid input value for enum）。
--    已在正式環境確認缺這個值：查 kind=eq.follow_up 直接回 22P02。
--    也就是說「注意軌 → 督導追蹤」這條線目前在正式環境是壞的。
--
--    注意：alter type add value 不能與「同一交易內使用該新值」並存，
--    所以這句要單獨執行（Supabase SQL Editor 一次貼一段即可）。
alter type dispatch_kind_t add value if not exists 'follow_up';

-- ② dispatch_tasks.proof_photo_url 沒有被 schema.sql 宣告過
--    三端一直在讀寫它（models.dart 的 proofPhotoUrl、志工端 history_page、resolveTask）。
--    正式環境已用其它方式補過這一欄（實測讀得到），但 schema.sql 裡沒有 —— 於是
--    由它產生的 Aurora 版就沒有，AWS 那側「附照片結案」直接炸 42703。
--    這句在正式環境是 no-op，只是讓兩邊定義收斂。
alter table dispatch_tasks add column if not exists proof_photo_url text;
