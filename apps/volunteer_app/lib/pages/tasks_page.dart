import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../data/care_profile.dart';

/// 任務頁：待接單與進行中的派遣單
class TasksPage extends StatefulWidget {
  const TasksPage(
      {super.key, required this.backend, this.volunteerName = '志工'});

  final BackendClient backend;
  final String volunteerName;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  BackendClient get backend => widget.backend;
  String get volunteerName => widget.volunteerName;

  // 物資單寬限期是時間相關（inOfferWindow 用 now），Realtime 不會在「到期那一刻」
  // 推事件，因此用一個輕量 ticker 週期重繪，讓到期後的單自動出現在「接任務」給全體。
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(
        const Duration(seconds: 15), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Row(
            children: [
              const JinsunLogo(size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('你好，$volunteerName',
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                    const Text('感謝你守望社區的長輩',
                        style: TextStyle(
                            fontSize: 12.5, color: JinsunColors.muted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 工作狀態切換：工作中＝可被派單／休息中＝暫停接收新派單（已接任務不受影響）
              _DutyToggle(backend: backend, volunteerName: volunteerName),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _TodaySummary(backend: backend, volunteerName: volunteerName),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: StreamBuilder<List<DispatchTask>>(
            stream: backend.tasks,
            initialData: backend.currentTasks,
            builder: (context, snapshot) {
              // 督導追蹤（followUp）是個管／居督的後台待辦，不是志工可接的派遣單，
              // 志工 App 一律過濾掉（只在社工後台呈現）。
              final all = (snapshot.data ?? [])
                  .where((t) => t.kind != DispatchKind.followUp)
                  .toList();
              // 目前任務：我接的、進行中（前往中／已到場）
              final mine = all
                  .where((t) =>
                      t.assigneeName == volunteerName &&
                      (t.status == DispatchStatus.accepted ||
                          t.status == DispatchStatus.arrived))
                  .toList()
                  .reversed
                  .toList();
              // 「派單」判定：這張單目前是否定向指派給某位志工。
              // 緊急單＝就近派單給某人，但「其他人也能接單補位」（見下方 open）；
              // 物資單＝只在 3 分鐘寬限期內定向給督導志工，逾期才開放全體。
              bool directed(DispatchTask t) =>
                  t.status == DispatchStatus.pending &&
                  t.assigneeName != null &&
                  (t.kind == DispatchKind.emergency || t.inOfferWindow);
              // 派給你的單：定向指派給我這位志工。
              final invited = all
                  .where((t) => directed(t) && t.assigneeName == volunteerName)
                  .toList()
                  .reversed
                  .toList();
              final invitedEmergency =
                  invited.any((t) => t.kind == DispatchKind.emergency);
              // 接任務（可補位池）：待接單且「非定向給我」。包含：
              //   ①非定向單（無指派對象／物資單已過寬限）；
              //   ②緊急單即使已就近派給別人，也開放其他志工接單補位（避免卡單漏接）。
              final open = all
                  .where((t) =>
                      t.status == DispatchStatus.pending &&
                      t.assigneeName != volunteerName &&
                      (!directed(t) || t.kind == DispatchKind.emergency))
                  .toList()
                  .reversed
                  .toList();
              return ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 90),
                children: [
                  _sectionHeader('目前任務', mine.length),
                  if (mine.isEmpty)
                    _emptyHint('目前沒有進行中的任務')
                  else
                    for (final t in mine)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TaskCard(
                            backend: backend,
                            task: t,
                            volunteerName: volunteerName),
                      ),
                  if (invited.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _sectionHeader(
                        invitedEmergency
                            ? '🚨 就近派單給你（系統指派・請盡快前往）'
                            : '邀請你接單（你是督導志工）',
                        invited.length),
                    for (final t in invited)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TaskCard(
                            backend: backend,
                            task: t,
                            volunteerName: volunteerName,
                            invited: true),
                      ),
                  ],
                  const SizedBox(height: 10),
                  _sectionHeader('接任務', open.length),
                  if (open.isEmpty)
                    _emptyHint('目前沒有待接的任務，感謝你的守望 🙏')
                  else
                    for (final t in open)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: TaskCard(
                            backend: backend,
                            task: t,
                            volunteerName: volunteerName),
                      ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
        child: Row(
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            if (count > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                decoration: BoxDecoration(
                    color: JinsunColors.blueBg,
                    borderRadius: BorderRadius.circular(10)),
                child: Text('$count',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: JinsunColors.blueDeep)),
              ),
          ],
        ),
      );

  Widget _emptyHint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(text,
            style: const TextStyle(fontSize: 14, color: JinsunColors.muted)),
      );
}

/// 今日概況（外送員 App 風格：今日完成、服務時數、上線時長）
class _TodaySummary extends StatelessWidget {
  const _TodaySummary({required this.backend, required this.volunteerName});

  final BackendClient backend;
  final String volunteerName;

  bool get _online {
    for (final v in backend.currentVolunteers) {
      if (v.name == volunteerName) return v.online;
    }
    return true; // 查無資料時預設視為上線
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DispatchTask>>(
      stream: backend.tasks,
      initialData: backend.currentTasks,
      builder: (context, snap) {
        final now = DateTime.now();
        bool isToday(DateTime t) =>
            t.year == now.year && t.month == now.month && t.day == now.day;
        // 只算「這位登入志工」自己真實接、今日結案的單（不用任何假資料）。
        final liveToday = snap.data!
            .where((t) =>
                t.status == DispatchStatus.resolved &&
                t.assigneeName == volunteerName &&
                isToday(t.resolvedAt ?? t.createdAt))
            .toList();
        final orders = liveToday.length;
        final minutes = liveToday.fold<int>(0, (s, t) => s + t.timeBankMinutes);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: JinsunColors.line),
          ),
          child: Row(
            children: [
              _cell('$orders', '今日完成'),
              _sep(),
              _cell(formatServiceMinutes(minutes), '今日時數'),
              _sep(),
              Expanded(
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: _online
                                    ? JinsunColors.okText
                                    : JinsunColors.muted,
                                shape: BoxShape.circle)),
                        const SizedBox(width: 5),
                        Text(_online ? '上線中' : '未上線',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: _online
                                    ? JinsunColors.okText
                                    : JinsunColors.muted)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    const Text('接單狀態',
                        style: TextStyle(
                            fontSize: 12.5, color: JinsunColors.muted)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _cell(String value, String label) => Expanded(
        child: Column(
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label,
                style:
                    const TextStyle(fontSize: 12.5, color: JinsunColors.muted)),
          ],
        ),
      );

  Widget _sep() =>
      Container(width: 1, height: 32, color: JinsunColors.line);
}

/// 志工工作狀態切換：工作中（online）／休息中（offline）。
/// 休息中時派單不會挑到我、來單受理也不彈出；已接的任務不受影響。即時寫回後端，後台看得到。
class _DutyToggle extends StatelessWidget {
  const _DutyToggle({required this.backend, required this.volunteerName});

  final BackendClient backend;
  final String volunteerName;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Volunteer>>(
      stream: backend.volunteers,
      initialData: backend.currentVolunteers,
      builder: (context, snap) {
        final list = snap.data ?? const <Volunteer>[];
        final me = list.where((v) => v.name == volunteerName);
        final online = me.isEmpty ? true : me.first.online;
        return InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: () async {
            await backend.setVolunteerOnline(volunteerName, !online);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(!online ? '已上工，開始接收派單' : '休息中，暫停接收新派單'),
                duration: const Duration(seconds: 2),
              ));
            }
          },
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
            decoration: BoxDecoration(
              color: online ? JinsunColors.okBg : const Color(0xFFEDEDEA),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                  color: online ? JinsunColors.okText : JinsunColors.line),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color:
                          online ? JinsunColors.okText : JinsunColors.muted),
                ),
                const SizedBox(width: 6),
                Text(online ? '工作中' : '休息中',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color:
                            online ? JinsunColors.okText : JinsunColors.muted)),
                const SizedBox(width: 2),
                Icon(online ? Icons.toggle_on : Icons.toggle_off,
                    size: 24,
                    color: online ? JinsunColors.okText : JinsunColors.muted),
              ],
            ),
          ),
        );
      },
    );
  }
}

class TaskCard extends StatelessWidget {
  const TaskCard(
      {super.key,
      required this.backend,
      required this.task,
      this.volunteerName = '志工',
      this.invited = false,
      this.detail = false});

  final BackendClient backend;
  final DispatchTask task;
  final String volunteerName;
  final bool invited; // 督導志工受邀（寬限期）→ 多一顆「婉拒（改由全體支援）」
  final bool detail; // true＝詳情頁完整內容；false＝外層列表摘要卡

  Elder get elder => backend.currentElders.firstWhere(
        (e) => e.id == task.elderId,
        orElse: () => Elder(
          id: task.elderId,
          name: '長輩',
          age: 0,
          address: '',
          severity: Severity.normal,
          lastActivityAt: DateTime.now(),
        ),
      );

  // 依志工目前位置 → 長輩家 實算距離與時間（LocationPublisher 即時回報位置）
  double get _km => roadDistanceKm(_myPos.$1, _myPos.$2, elder.lat, elder.lng);
  int get _walkMin => _autoEta;

  // 開單時間顯示：MM/dd HH:mm（zh-TW）
  String _formatCreatedAt(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  /// 這張派遣單對應的事件（用來寫「具體怎麼了」）。查無回 null。
  RadioEvent? get _event {
    for (final e in backend.currentEvents) {
      if (e.id == task.eventId) return e;
    }
    return null;
  }

  /// 卡片標題＝「具體發生什麼事」：跌倒／SOS／物資帶出品項，而非籠統「緊急派遣」。
  String get _concreteTitle {
    if (task.kind == DispatchKind.supply) {
      return task.items.isNotEmpty ? '物資：${task.items.join('、')}' : '物資代購';
    }
    return switch (_event?.type) {
      RadioEventType.sos => 'SOS 緊急求救',
      RadioEventType.fallSuspected => '疑似跌倒',
      _ => '緊急求助',
    };
  }

  @override
  Widget build(BuildContext context) {
    // detail=true：詳情頁的完整內容（時間軸／導航／回報結案／照護資訊／聯絡家屬）。
    if (detail) return _detailCard(context);

    final emergency = task.kind == DispatchKind.emergency;
    final inProgress = task.status == DispatchStatus.accepted ||
        task.status == DispatchStatus.arrived;

    // 外層列表卡：只放摘要（分級／長輩／地址／開單時間）。
    // 待接單 → 直接給接單鈕（列表就要能快速接）；進行中 → 整張卡點進詳情頁回報，
    // 細節不在外層重複顯示。
    final card = Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
            color: emergency && task.status == DispatchStatus.pending
                ? const Color(0xFFEBB4A6)
                : JinsunColors.line),
      ),
      color: emergency && task.status == DispatchStatus.pending
          ? const Color(0xFFFFF3EF)
          : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summaryHeader(),
            if (task.status == DispatchStatus.pending) ...[
              const SizedBox(height: 6),
              _distanceRow(),
              const SizedBox(height: 12),
              _actionRow(context),
            ] else if (inProgress) ...[
              const SizedBox(height: 12),
              // 進行中：一排三顆＝導航｜聯絡家屬｜結單（狀態已在右上藥丸，不重複顯示）。
              _inProgressActions(context),
            ],
          ],
        ),
      ),
    );

    if (!inProgress) return card;
    // 進行中：整張卡可點 → 進詳情頁（時間軸、導航、回報結案、照護資訊、聯絡都在裡面）。
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => TaskDetailScreen(
          backend: backend,
          taskId: task.id,
          volunteerName: volunteerName,
        ),
      )),
      child: card,
    );
  }

  /// 卡片摘要標頭：分級圖示＋標籤＋狀態，長輩姓名年齡、地址、開單時間。列表與詳情共用。
  Widget _summaryHeader() {
    final emergency = task.kind == DispatchKind.emergency;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(emergency ? Icons.emergency : Icons.shopping_basket,
                size: 20,
                color:
                    emergency ? JinsunColors.dangerText : JinsunColors.okText),
            const SizedBox(width: 8),
            // 具體怎麼了（跌倒／SOS／物資品項），一行帶不下就省略。
            Expanded(
              child: Text(_concreteTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            _statusPill(),
          ],
        ),
        const SizedBox(height: 6),
        // 長輩｜地址｜開單時間 收成一行，降低卡片高度。
        Text('${elder.name}（${elder.age}）· ${elder.address}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: JinsunColors.muted)),
        Text('開單 ${_formatCreatedAt(task.createdAt)}',
            style: const TextStyle(fontSize: 12, color: JinsunColors.muted)),
      ],
    );
  }

  /// 距離／ETA 一行（未到場才有意義）。
  Widget _distanceRow() {
    return Row(
      children: [
        const Icon(Icons.route, size: 15, color: JinsunColors.blueDeep),
        const SizedBox(width: 4),
        Text('約 ${_km.toStringAsFixed(1)} km',
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: JinsunColors.blueDeep)),
        const SizedBox(width: 12),
        const Icon(Icons.two_wheeler, size: 15, color: JinsunColors.muted),
        const SizedBox(width: 4),
        Text('約 $_walkMin 分鐘到',
            style: const TextStyle(fontSize: 13, color: JinsunColors.muted)),
      ],
    );
  }

  /// 詳情頁完整內容：摘要＋（未到場才給）距離＋時間軸＋導航/回報結案＋照護資訊＋聯絡家屬。
  Widget _detailCard(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: JinsunColors.line)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _summaryHeader(),
            if (task.status != DispatchStatus.arrived) ...[
              const SizedBox(height: 6),
              _distanceRow(),
            ],
            const SizedBox(height: 12),
            _taskTimeline(task),
            const SizedBox(height: 12),
            _actionRow(context),
            const SizedBox(height: 14),
            CareSheet(elder: elder),
            const SizedBox(height: 8),
            ContactButton(
              label: '聯絡家屬',
              backend: backend,
              taskId: task.id,
              accent: JinsunColors.blue,
              callSelfRole: CallRole.volunteer,
              callSelfName: volunteerName,
              callPeerName: '家屬',
              callPeerLabel: '${elder.name}的家人',
              chatMyRole: ChatFromRole.volunteer,
              chatTitle: '與 ${elder.name} 家屬的訊息',
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusPill() {
    // 紅色＝緊急語意，只保留給 emergency 待接單；物資單待接單用中性藍，避免視覺混淆分級。
    final (label, fg, bg) = switch (task.status) {
      DispatchStatus.pending => task.kind == DispatchKind.emergency
          ? ('待接單', JinsunColors.dangerText, JinsunColors.dangerBg)
          : ('待接單', JinsunColors.blueDeep, JinsunColors.blueBg),
      DispatchStatus.accepted => (
          '前往中',
          JinsunColors.warnText,
          JinsunColors.warnBg
        ),
      DispatchStatus.arrived => (
          '已到場',
          JinsunColors.warnText,
          JinsunColors.warnBg
        ),
      DispatchStatus.resolved => ('已完成', JinsunColors.okText, JinsunColors.okBg),
    };
    return StatusPill(label: label, fg: fg, bg: bg);
  }

  Widget _actionRow(BuildContext context) {
    if (task.status == DispatchStatus.resolved) return const SizedBox.shrink();
    // 接單前：只給接單主按鈕。督導受邀單多一顆「婉拒 → 改由全體支援」。
    if (task.status == DispatchStatus.pending) {
      // 定向派單（invited）用「確認前往」＝接受指派；搶單池用「接單」。
      final accept = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: () => _accept(context),
        icon: Icon(invited ? Icons.directions_run : Icons.pan_tool_alt,
            size: 18),
        label: Text(invited
            ? '確認前往（約 $_autoEta 分鐘到）'
            : '接單（約 $_autoEta 分鐘到）'),
      );
      if (!invited) return accept;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          accept,
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                foregroundColor: JinsunColors.muted),
            onPressed: () => backend.requestSupport(task.id),
            icon: const Icon(Icons.groups, size: 18),
            label: const Text('我無法前往，改派他人'),
          ),
        ],
      );
    }
    final resolve = FilledButton.icon(
      style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          backgroundColor: JinsunColors.okText),
      onPressed: () => _resolveWithPhoto(context),
      icon: const Icon(Icons.photo_camera, size: 18),
      label: const Text('拍照結單'),
    );
    // 已到場：人已在現場，不再顯示導航，只留「拍照結單」。
    if (task.status == DispatchStatus.arrived) {
      return SizedBox(width: double.infinity, child: resolve);
    }
    // 前往中：導航＋拍照結單並排。到場時間本可由 GPS 接近自動判定，但志工常沒開定位
    // （林國男這種「嫌麻煩」的），這時長輩端就收不到「志工到門口了」那句安撫、家屬地圖
    // 也不會顯示已到場。所以補一顆明顯的「我到了」手動回報 markArrived，把安撫鏈路救回來。
    final nav = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          padding: const EdgeInsets.symmetric(horizontal: 16)),
      onPressed: () => _openNavigation(context),
      icon: const Icon(Icons.navigation, size: 18),
      label: const Text('導航'),
    );
    final arrived = OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          foregroundColor: JinsunColors.okText,
          side: const BorderSide(color: JinsunColors.okText)),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        await backend.markArrived(task.id);
        messenger.showSnackBar(const SnackBar(
            content: Text('已回報到場，長輩會聽到「志工到了」的安撫語')));
      },
      icon: const Icon(Icons.doorbell_outlined, size: 18),
      label: const Text('我到了（到門口按這裡）'),
    );
    return Column(
      children: [
        SizedBox(width: double.infinity, child: arrived),
        const SizedBox(height: 8),
        Row(
          children: [
            nav,
            const SizedBox(width: 10),
            Expanded(child: resolve),
          ],
        ),
      ],
    );
  }

  /// 進行中的一排動作：（未到場才有）導航｜聯絡家屬｜結單。等寬，卡片高度只多一行。
  /// 已到場後人已在現場，不再顯示導航，只留 聯絡｜結單。
  Widget _inProgressActions(BuildContext context) {
    final arrived = task.status == DispatchStatus.arrived;
    return Row(
      children: [
        if (!arrived) ...[
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  padding: EdgeInsets.zero),
              onPressed: () => _openNavigation(context),
              icon: const Icon(Icons.navigation, size: 17),
              label: const Text('導航'),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: ContactButton(
            label: '聯絡',
            backend: backend,
            taskId: task.id,
            accent: JinsunColors.blue,
            callSelfRole: CallRole.volunteer,
            callSelfName: volunteerName,
            callPeerName: '家屬',
            callPeerLabel: '${elder.name}的家人',
            chatMyRole: ChatFromRole.volunteer,
            chatTitle: '與 ${elder.name} 家屬的訊息',
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: JinsunColors.okText,
                padding: EdgeInsets.zero),
            onPressed: () => _resolveWithPhoto(context),
            icon: const Icon(Icons.check_circle, size: 17),
            label: const Text('結單'),
          ),
        ),
      ],
    );
  }

  /// 開啟 Google Maps 導航前往長輩家（有座標用座標，否則用地址）。
  Future<void> _openNavigation(BuildContext context) async {
    final hasCoord = elder.lat != 0 || elder.lng != 0;
    final dest = hasCoord
        ? '${elder.lat},${elder.lng}'
        : Uri.encodeComponent(elder.address);
    final url = Uri.parse(
        'https://www.google.com/maps/dir/?api=1&destination=$dest&travelmode=driving');
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('無法開啟地圖，請確認已安裝 Google Maps 或瀏覽器')),
      );
    }
  }

  /// 任務時間軸：開單→出發→到場→回報，各步驟顯示實際時間（未到的步驟灰、無時間顯示「—」）。
  Widget _taskTimeline(DispatchTask t) {
    String hm(DateTime? d) => d == null
        ? '—'
        : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final rows = <(IconData, String, DateTime?)>[
      (Icons.assignment_outlined, '開單', t.createdAt),
      (Icons.two_wheeler, '出發', t.acceptedAt),
      (Icons.where_to_vote_outlined, '到場', t.arrivedAt),
      (Icons.verified_outlined, t.outcome ?? '回報', t.resolvedAt),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F8FB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: JinsunColors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < rows.length; i++)
            _timelineRow(rows[i].$1, rows[i].$2, hm(rows[i].$3),
                done: rows[i].$3 != null, last: i == rows.length - 1),
        ],
      ),
    );
  }

  Widget _timelineRow(IconData icon, String label, String time,
      {required bool done, required bool last}) {
    final color = done ? JinsunColors.blueDeep : JinsunColors.muted;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                    color: done ? JinsunColors.blue : const Color(0xFFDDE1E8),
                    shape: BoxShape.circle),
                child: Icon(icon, size: 12, color: Colors.white),
              ),
              if (!last)
                Expanded(
                    child: Container(
                        width: 2, color: const Color(0xFFDDE1E8))),
            ],
          ),
          const SizedBox(width: 10),
          Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 10, top: 1),
            child: Row(
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: done ? JinsunColors.ink : JinsunColors.muted)),
                const SizedBox(width: 8),
                Text(time,
                    style: TextStyle(
                        fontSize: 13,
                        color: color,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 回報結案並輸入現場備註（會傳給家屬看到）
  /// Uber 式拍照結單：先彈窗請志工附上到場照片 → 拍照 → 選處置＋補充 → 上傳照片＋關單。
  /// 沒拍照就不關單；上傳／關單失敗會跳錯誤，不會靜默卡住。
  Future<void> _resolveWithPhoto(BuildContext context) async {
    final emergency = task.kind == DispatchKind.emergency;
    // 0) 先彈窗說明：完成前要附上到場照片當證明，不直接跳相機。
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.photo_camera, color: JinsunColors.blue),
        title: const Text('完成前，請附上到場照片'),
        content: Text(emergency
            ? '拍一張現場照片當作到場證明，會一併傳給家屬看到，才能完成這張單。'
            : '拍一張送達照片當作證明，會一併傳給家屬看到，才能完成這張單。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.photo_camera, size: 18),
            label: const Text('附上照片'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (proceed != true) return; // 志工按取消＝不關單

    final picker = ImagePicker();
    // 1) 開相機拍照。桌機瀏覽器沒相機時退回相簿選圖，避免完全卡死。
    XFile? shot;
    try {
      shot = await picker.pickImage(
          source: ImageSource.camera, imageQuality: 55, maxWidth: 1280);
    } catch (_) {
      shot = await picker.pickImage(
          source: ImageSource.gallery, imageQuality: 55, maxWidth: 1280);
    }
    if (shot == null) return; // 取消拍照＝不關單
    var photoBytes = await shot.readAsBytes();
    var photoType = shot.mimeType ??
        (shot.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');

    final controller = TextEditingController();
    final outcomes = emergency
        ? const ['確認沒事', '已扶起休息', '已通知家屬', '送往醫院', '陪同就醫', '其他']
        : const ['已送達', '長輩已收到', '其他'];
    var selected = outcomes.first;

    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(emergency ? '拍照結單・回報處置' : '拍照結單・回報送達',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text('現場照＋處置都會傳給家屬看到，當作到場證明。',
                    style: TextStyle(fontSize: 13, color: JinsunColors.muted)),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: AspectRatio(
                    aspectRatio: 16 / 10,
                    child: Image.memory(photoBytes, fit: BoxFit.cover),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.photo_camera, size: 18),
                    label: const Text('重拍'),
                    onPressed: () async {
                      final r = await picker.pickImage(
                          source: ImageSource.camera,
                          imageQuality: 55,
                          maxWidth: 1280);
                      if (r == null) return;
                      final b = await r.readAsBytes();
                      setSheet(() {
                        photoBytes = b;
                        photoType = r.mimeType ?? photoType;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in outcomes)
                      ChoiceChip(
                        label: Text(o),
                        selected: selected == o,
                        onSelected: (_) => setSheet(() => selected = o),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: '補充說明（可留白）',
                    hintText: emergency
                        ? '例：長輩只是坐著喘，已扶回沙發，狀況穩定'
                        : '例：放在廚房桌上，長輩收到了',
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.verified, size: 18),
                  label: const Text('上傳照片並關單'),
                  onPressed: () =>
                      Navigator.pop(ctx, (selected, controller.text)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    if (result == null) return;
    final (outcome, note) = result;
    final mins = task.timeBankMinutes;

    // 上傳＋關單期間先擋一層 loading，避免重複按、也讓志工知道在處理。
    if (context.mounted) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }
    try {
      // 沒有「已到場」中間步驟時，關單就補上到場時間，時間軸的「到場」不會空著。
      if (task.arrivedAt == null) {
        await backend.markArrived(task.id);
      }
      final url = await backend.uploadProofPhoto(task.id, photoBytes,
          contentType: photoType);
      await backend.resolveTask(task.id,
          note: note, outcome: outcome, photoUrl: url);
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop(); // 收掉 loading
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('關單失敗，請再試一次：$e'),
            duration: const Duration(seconds: 5)));
      }
      return;
    }
    if (context.mounted) Navigator.of(context).pop(); // 收掉 loading
    await HapticFeedback.heavyImpact();
    // 關單後：打勾動畫＋「辛苦了」＋時間銀行入帳分鐘
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierColor: Colors.black54,
        builder: (_) => _CompletionCard(minutes: mins),
      );
    }
    // 若在詳情頁結案，回到列表（該任務已結案、移出「目前任務」）。
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// 志工目前座標（來自 volunteers 表，LocationPublisher 即時回報）
  (double, double) get _myPos {
    for (final v in backend.currentVolunteers) {
      if (v.name == volunteerName) return (v.lat, v.lng);
    }
    return (0, 0);
  }

  /// 依「志工位置 → 長輩家」自動估算抵達分鐘數（不再手動勾選）
  int get _autoEta {
    final (vlat, vlng) = _myPos;
    return estimateEtaMinutes(vlat, vlng, elder.lat, elder.lng);
  }

  /// 緊急派遣的接單資格：良民證＋志工意外險須為有效（兌現證件頁的規則承諾）。
  bool get _canTakeEmergency {
    for (final v in backend.currentVolunteers) {
      if (v.name != volunteerName) continue;
      bool valid(CertKind k) => v.certificates
          .any((c) => c.kind == k && c.status == CertStatus.valid);
      return valid(CertKind.goodCitizen) && valid(CertKind.insurance);
    }
    return true; // 查無志工資料時不擋（避免誤鎖）
  }

  Future<void> _accept(BuildContext context) async {
    // 緊急單需完成證件（良民證＋意外險）才能接，與 certificates_page 的規則一致
    if (task.kind == DispatchKind.emergency && !_canTakeEmergency) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('接緊急派遣需先完成良民證與志工意外險，請至「我的 → 證件」補齊'),
        duration: Duration(seconds: 5),
      ));
      return;
    }
    // 依地點自動算 ETA；接單後 LocationPublisher 會隨志工移動即時更新。
    // 接單失敗（網路／權限）要讓志工看得到，不要靜默吞掉。
    try {
      await backend.acceptTask(task.id,
          etaMinutes: _autoEta, assigneeName: volunteerName);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已接單，開始前往'), duration: Duration(seconds: 2)));
      }
    } on StateError {
      // 兩人同搶：後接者匹配 0 列 → 明確告知已被接走，不靜默。
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('這張單已被其他志工接走'),
            duration: Duration(seconds: 3)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('接單失敗，請再試一次：$e'),
            duration: const Duration(seconds: 4)));
      }
    }
  }
}

/// 任務詳情頁：從列表卡片點進來才看得到的完整內容（時間軸／導航／回報結案／照護資訊／聯絡家屬）。
/// 綁定即時串流：任務被結案或改派而離開「我的進行中」時自動退回列表，志工不會停在死頁面。
class TaskDetailScreen extends StatelessWidget {
  const TaskDetailScreen({
    super.key,
    required this.backend,
    required this.taskId,
    required this.volunteerName,
  });

  final BackendClient backend;
  final String taskId;
  final String volunteerName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('任務詳情')),
      body: StreamBuilder<List<DispatchTask>>(
        stream: backend.tasks,
        initialData: backend.currentTasks,
        builder: (context, snapshot) {
          final all = snapshot.data ?? const <DispatchTask>[];
          DispatchTask? task;
          for (final t in all) {
            if (t.id == taskId) {
              task = t;
              break;
            }
          }
          // 任務已結案／改派給別人 → 自動退回列表。
          final stillMine = task != null &&
              task.assigneeName == volunteerName &&
              (task.status == DispatchStatus.accepted ||
                  task.status == DispatchStatus.arrived);
          if (!stillMine) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            });
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            children: [
              TaskCard(
                backend: backend,
                task: task,
                volunteerName: volunteerName,
                detail: true,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 關單後的完成回饋：綠圈彈入＋打勾＋「辛苦了！」＋時間銀行入帳分鐘。
/// 2.4 秒後自動關閉，或點背景關閉。
class _CompletionCard extends StatefulWidget {
  const _CompletionCard({required this.minutes});
  final int minutes;

  @override
  State<_CompletionCard> createState() => _CompletionCardState();
}

class _CompletionCardState extends State<_CompletionCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  Timer? _auto;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..forward();
    _auto = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final circle = CurvedAnimation(
        parent: _c, curve: const Interval(0.0, 0.6, curve: Curves.elasticOut));
    final check = CurvedAnimation(
        parent: _c, curve: const Interval(0.25, 0.72, curve: Curves.easeOutBack));
    final text = CurvedAnimation(
        parent: _c, curve: const Interval(0.5, 1.0, curve: Curves.easeOut));
    return Center(
      child: Material(
        color: Colors.transparent,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => Container(
            width: 288,
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.scale(
                  scale: circle.value.clamp(0.0, 1.2),
                  child: Container(
                    width: 92,
                    height: 92,
                    decoration: const BoxDecoration(
                        color: JinsunColors.okBg, shape: BoxShape.circle),
                    child: Center(
                      child: Transform.scale(
                        scale: check.value.clamp(0.0, 1.0),
                        child: const Icon(Icons.check_rounded,
                            size: 56, color: JinsunColors.okText),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Opacity(
                  opacity: text.value.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, 14 * (1 - text.value)),
                    child: Column(
                      children: [
                        const Text('辛苦了！',
                            style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w900,
                                color: JinsunColors.ink)),
                        const SizedBox(height: 4),
                        const Text('這趟服務已完成回報，謝謝你守望社區 🙏',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13, color: JinsunColors.muted)),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 9),
                          decoration: BoxDecoration(
                              color: JinsunColors.yellowBg,
                              borderRadius: BorderRadius.circular(999)),
                          child: Text('時間銀行 ＋${widget.minutes} 分鐘',
                              style: const TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w800,
                                  color: JinsunColors.yellowText)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
