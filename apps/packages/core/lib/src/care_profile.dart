import 'package:flutter/material.dart';

/// 長輩照護檢核範本（十大類）——三端共用的**唯讀資料**。
///
/// 志工「到場後」查看；社工後台「點進長輩」也看得到同一份（志工端所見即後台所見）。
/// 目前為通用照護檢核範本＋長輩實際注記；日後可改成每位長輩的結構化照護檔案
/// （後台社工填、志工端唯讀）。放在 core 讓 volunteer_app 與 admin 共用，避免複製貼上。
class CareCategory {
  const CareCategory(this.icon, this.title, this.items);
  final IconData icon;
  final String title;
  final List<String> items;
}

const careCategories = <CareCategory>[
  CareCategory(Icons.favorite_border, '一、健康狀況', [
    '藥物過敏（例：青黴素、阿斯匹靈）',
    '食物過敏（例：花生、海鮮、牛奶）',
    '慢性病：高血壓／糖尿病／心臟病／腎臟病／肝病',
    '氣喘・慢性阻塞性肺病（COPD）',
    '癲癇・骨質疏鬆・曾中風',
    '巴金森氏症・失智症・癌症病史',
    '最近住院或手術紀錄',
  ]),
  CareCategory(Icons.medication_outlined, '二、用藥資訊', [
    '固定服用藥物、用藥時間',
    '是否需提醒服藥',
    '是否自行管理藥物',
    '緊急用藥（如硝化甘油、吸入劑）',
  ]),
  CareCategory(Icons.accessible_outlined, '三、行動能力', [
    '可自行行走／使用拐杖／助行器／輪椅',
    '上下樓梯需協助',
    '容易跌倒、平衡感較差',
    '行動速度慢',
  ]),
  CareCategory(Icons.visibility_outlined, '四、感官功能', [
    '視力不佳／配戴眼鏡／白內障・青光眼',
    '聽力不好／配戴助聽器',
    '說話困難、吞嚥困難',
  ]),
  CareCategory(Icons.restaurant_outlined, '五、飲食需求', [
    '糖尿病飲食／低鹽／低油',
    '軟質／流質飲食',
    '素食、忌口食物',
    '容易噎到',
  ]),
  CareCategory(Icons.volunteer_activism_outlined, '六、生活照顧需求', [
    '如廁需協助／使用尿布／尿失禁・便失禁',
    '洗澡需協助、穿衣需協助',
    '需要攙扶、需陪同外出',
  ]),
  CareCategory(Icons.psychology_outlined, '七、認知與心理狀況', [
    '記憶力退化、容易迷路',
    '情緒起伏大／焦慮／憂鬱傾向／容易激動',
    '睡眠問題',
    '溝通需耐心',
  ]),
  CareCategory(Icons.warning_amber_outlined, '八、安全注意事項', [
    '容易跌倒、容易低血糖',
    '血壓容易過高／過低、容易喘、容易抽筋',
    '有壓瘡（褥瘡）／有傷口需避免碰撞',
    '不可單獨外出',
  ]),
  CareCategory(Icons.contact_phone_outlined, '九、緊急聯絡資訊', [
    '主要聯絡人、關係（子女、配偶等）、聯絡電話',
    '家庭醫師、常就診醫院',
    '緊急送醫偏好醫院',
  ]),
  CareCategory(Icons.info_outline, '十、服務注意事項', [
    '喜歡的稱呼、慣用語言（國語／台語／客語）',
    '個性（健談、害羞、固執等）、宗教信仰',
    '特殊生活習慣、不喜歡的話題或行為',
    '需要陪伴聊天',
    '需要定期量血壓／血糖',
    '接送需求、是否有寵物、特殊交代事項',
  ]),
];
