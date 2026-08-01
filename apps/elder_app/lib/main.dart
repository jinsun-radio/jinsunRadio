import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';
import 'package:record/record.dart';

/// 語音 server（Render 正式站）；部署時可用 --dart-define=SIM_BASE=... 覆蓋。
const _serverBase = String.fromEnvironment(
  'SIM_BASE',
  defaultValue: 'https://jinsun-voice-server-mg1f.onrender.com',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JinsunSupabase.ensureInitialized();
  runApp(const ElderApp());
}

class ElderApp extends StatelessWidget {
  const ElderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '金孫收音機',
      debugShowCheckedModeBanner: false,
      theme: jinsunTheme(JinsunColors.orange),
      home: const ElderRadioPage(),
    );
  }
}

enum _Phase { idle, recording, thinking }

class ElderRadioPage extends StatefulWidget {
  const ElderRadioPage({super.key});

  @override
  State<ElderRadioPage> createState() => _ElderRadioPageState();
}

class _ElderRadioPageState extends State<ElderRadioPage> {
  final BackendClient _backend = SupabaseBackend();
  final AudioRecorder _rec = AudioRecorder();
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();
  final http.Client _http = http.Client();

  int _speakSeq = 0; // 語音序號：只讓「最新一次」發聲，避免兩個聲音一起講

  StreamSubscription<List<Elder>>? _elderSub;
  StreamSubscription<List<DispatchTask>>? _taskSub;

  List<Elder> _elders = const [];
  String? _elderId; // 目前這台收音機對應的長輩
  _Phase _phase = _Phase.idle;
  String _bubble = '有事就按住下面的大按鈕，跟我說一聲。';
  DispatchTask? _activeTask; // 進行中派遣（志工前往中／已到場）
  bool _tasksSeeded = false;
  String? _lastSpokenTaskKey;

  @override
  void initState() {
    super.initState();
    _initTts();
    // 網址帶 ?elder=elder-1 或 ?serial=JS-0001 指定這台是誰的；否則載入後預設第一位。
    final q = Uri.base.queryParameters;
    _elderId = q['elder'];
    _elderSub = _backend.elders.listen((list) {
      if (!mounted) return;
      setState(() {
        _elders = list;
        if (_elderId == null || !list.any((e) => e.id == _elderId)) {
          final bySerial = q['serial'];
          Elder? match;
          for (final e in list) {
            if (bySerial != null && e.deviceSerial == bySerial) match = e;
          }
          _elderId = match?.id ?? (list.isNotEmpty ? list.first.id : null);
        }
      });
    });
    _taskSub = _backend.tasks.listen(_onTasks);
  }

  Future<void> _initTts() async {
    try {
      await _tts.setSpeechRate(0.46); // 放慢，長輩聽得清楚
      await _tts.setVolume(1.0);
    } catch (_) {}
  }

  @override
  void dispose() {
    _elderSub?.cancel();
    _taskSub?.cancel();
    _rec.dispose();
    _tts.stop();
    _player.dispose();
    _http.close();
    _backend.dispose();
    super.dispose();
  }

  /// 目前這台的語言（跟家屬 App 設的走）：mandarin / taigi。
  ElderLang get _lang => _elder?.preferredLang ?? ElderLang.mandarin;

  Elder? get _elder {
    for (final e in _elders) {
      if (e.id == _elderId) return e;
    }
    return null;
  }

  /// 念一句話：先停掉正在講的（不管是雲端 WAV 還是瀏覽器語音），確保同時只有一個聲音。
  /// 優先用「雲端 ATEN TTS」（跟硬體同一套、依語言選國語／台語），打不通才退回瀏覽器語音。
  Future<void> _speak(String text) async {
    if (text.trim().isEmpty) return;
    final seq = ++_speakSeq;
    // 先全部靜音，避免兩個聲音疊在一起。
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _tts.stop();
    } catch (_) {}
    if (seq != _speakSeq) return; // 有更新的一句要講，這句放棄

    final url = await _cloudTtsUrl(text, _lang.wire);
    if (seq != _speakSeq) return;
    if (url != null) {
      try {
        await _player.play(UrlSource(url));
        return;
      } catch (_) {/* 播不出來就退回瀏覽器語音 */}
    }
    // 退回瀏覽器語音（國語；台語瀏覽器多半沒有語音，僅備援）。
    try {
      await _tts.setLanguage('zh-TW');
      if (seq != _speakSeq) return;
      await _tts.speak(text);
    } catch (_) {}
  }

  /// 打 server 的 /tts 代理（代打 ATEN），拿回可跨源播放的 WAV url；失敗回 null。
  Future<String?> _cloudTtsUrl(String text, String langWire) async {
    try {
      final res = await _http
          .post(Uri.parse('$_serverBase/tts'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({'text': text, 'lang': langWire}))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      if (j is Map && j['url'] is String) return j['url'] as String;
    } catch (_) {}
    return null;
  }

  Future<void> _setLang(ElderLang lang) async {
    final id = _elderId;
    if (id == null) return;
    try {
      await _backend.setElderLang(id, lang);
    } catch (_) {}
  }

  // 進行中派遣的即時通知：志工接單＝正在過來、到場＝到了，各念一次並在螢幕放大字。
  void _onTasks(List<DispatchTask> list) {
    DispatchTask? active;
    for (final t in list) {
      if (t.elderId != _elderId) continue;
      if (t.status == DispatchStatus.accepted ||
          t.status == DispatchStatus.arrived) {
        active = t; // 取最後一筆進行中
      }
    }
    if (mounted) setState(() => _activeTask = active);

    if (active != null && _tasksSeeded) {
      final key = '${active.id}:${active.status}';
      if (key != _lastSpokenTaskKey) {
        _lastSpokenTaskKey = key;
        final who =
            active.assigneeName == null ? '志工' : '志工${active.assigneeName}';
        if (active.status == DispatchStatus.arrived) {
          _speak('$who到您家門口了，馬上就進來看您，您安心坐著休息就好。');
        } else {
          final eta = active.etaMinutes;
          _speak(eta != null
              ? '$who正在過來，大約$eta分鐘到，您在家裡等他就好。'
              : '$who正在過來，您在家裡等他就好。');
        }
      }
    }
    _tasksSeeded = true;
  }

  // ---- 大錄音按鈕：按住說話 → 放開送雲端 ASR → POST /voice → 念出回覆 ----
  Future<void> _startRecording() async {
    if (_phase != _Phase.idle) return;
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _bubble = '請允許使用麥克風，才能聽到您說話。');
        return;
      }
      // 錄成 WAV 16k 單聲道：faster-whisper Breeze 對乾淨 WAV 辨識率明顯比 webm/opus 好
      // （與 XCC Gateway 實測成功的請求同格式）。
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: 'jinsun-elder', // web 走 Web Audio，path 不會實際寫檔
      );
      setState(() {
        _phase = _Phase.recording;
        _bubble = '我在聽，您說…';
      });
    } catch (e) {
      setState(() {
        _phase = _Phase.idle;
        _bubble = '麥克風打不開，請確認瀏覽器允許錄音。';
      });
    }
  }

  Future<void> _stopAndSend() async {
    if (_phase != _Phase.recording) return;
    setState(() => _phase = _Phase.thinking);
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    if (path == null || path.isEmpty) {
      setState(() {
        _phase = _Phase.idle;
        _bubble = '沒有錄到聲音，再按住大按鈕跟我說一次。';
      });
      return;
    }
    try {
      final bytes = await _readBytes(path);
      // 1) 雲端 ASR（Supabase Whisper Edge Function）
      final said = await _backend.transcribeAudio(
        bytes,
        filename: 'audio.wav',
        mimeType: 'audio/wav',
        // 給 ASR 一點情境詞，長輩常說的字比較不會被聽錯。
        prompt: '長輩日常求助與代辦：買牛奶、雞蛋、麵包、藥、衛生紙；'
            '救命、好痛、頭暈、跌倒、我沒事、幫我叫人。',
      );
      if (said.trim().isEmpty) {
        setState(() {
          _phase = _Phase.idle;
          _bubble = '我沒有聽清楚，再說一次好嗎？';
        });
        return;
      }
      setState(() => _bubble = '您說：$said');
      // 2) 送語音 server（多 Agent 決定要買東西／求助／閒聊），拿回要念的話
      final reply = await _postVoice(said);
      final toSay = reply ?? '好，我聽到了，我來幫您處理。';
      setState(() {
        _phase = _Phase.idle;
        _bubble = toSay;
      });
      await _speak(toSay);
    } catch (e) {
      setState(() {
        _phase = _Phase.idle;
        _bubble = '網路好像不太順，請再試一次。';
      });
    }
  }

  /// web 錄音 stop() 回傳的是 blob: URL，用 http 取回位元組。
  Future<Uint8List> _readBytes(String url) async {
    final r = await _http.get(Uri.parse(url));
    return r.bodyBytes;
  }

  /// POST /voice：把 ASR 文字送上雲端，回傳要念給長輩的 reply（失敗回 null）。
  Future<String?> _postVoice(String text) async {
    final elder = _elder;
    final body = {
      if (elder?.deviceSerial != null) 'device_serial': elder!.deviceSerial,
      'elder_id': _elderId,
      'text': text,
    };
    final res = await _http
        .post(Uri.parse('$_serverBase/voice'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    final j = jsonDecode(res.body);
    if (j is Map && j['reply'] is String) return j['reply'] as String;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final elder = _elder;
    return Scaffold(
      backgroundColor: JinsunColors.orangeBg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(
            children: [
              _header(elder),
              const SizedBox(height: 12),
              Expanded(child: _center(elder)),
              const SizedBox(height: 12),
              _bigButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(Elder? elder) {
    return Row(
      children: [
        const JinsunLogo(size: 40),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('金孫收音機',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              Text(elder == null ? '載入中…' : '${elder.name} 的收音機',
                  style: const TextStyle(
                      fontSize: 13, color: JinsunColors.orangeDeep)),
            ],
          ),
        ),
        // 國語／台語切換（跟家屬 App 同一個 preferred_lang，改了兩邊都生效）。
        if (elder != null)
          _LangToggle(
            value: elder.preferredLang,
            onChanged: (l) => _setLang(l),
          ),
        const SizedBox(width: 8),
        // demo 用：切換這台是哪位長輩的收音機。
        if (_elders.isNotEmpty)
          DropdownButton<String>(
            value: _elderId,
            underline: const SizedBox.shrink(),
            icon: const Icon(Icons.expand_more),
            items: [
              for (final e in _elders)
                DropdownMenuItem(value: e.id, child: Text(e.name)),
            ],
            onChanged: (v) => setState(() {
              _elderId = v;
              _activeTask = null;
              _lastSpokenTaskKey = null;
            }),
          ),
      ],
    );
  }

  Widget _center(Elder? elder) {
    // 進行中派遣 → 放最大的通知（志工正在過來／已到）。
    if (_activeTask != null) {
      final arrived = _activeTask!.status == DispatchStatus.arrived;
      final who = _activeTask!.assigneeName == null
          ? '志工'
          : '志工 ${_activeTask!.assigneeName}';
      final eta = _activeTask!.etaMinutes;
      return _bigCard(
        bg: arrived ? JinsunColors.okBg : JinsunColors.blueBg,
        fg: arrived ? JinsunColors.okText : JinsunColors.blueDeep,
        icon: arrived ? Icons.meeting_room : Icons.directions_run,
        title: arrived ? '$who 到了' : '$who 正在過來',
        subtitle: arrived
            ? '他馬上就進來看您，有需要就跟他說。'
            : (eta != null ? '大約 $eta 分鐘到，您在家裡等他就好。' : '您在家裡等他就好。'),
      );
    }
    // 平常：安心提示 + 目前的對話泡泡。
    return _bigCard(
      bg: Colors.white,
      fg: JinsunColors.ink,
      icon: _phase == _Phase.recording
          ? Icons.mic
          : (_phase == _Phase.thinking ? Icons.hourglass_top : Icons.favorite),
      title: elder == null ? '您好' : '${elder.name}，您好',
      subtitle: _bubble,
    );
  }

  Widget _bigCard({
    required Color bg,
    required Color fg,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: fg.withValues(alpha: 0.20), width: 1.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: fg),
          const SizedBox(height: 18),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 30, fontWeight: FontWeight.w900, color: fg)),
          const SizedBox(height: 12),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 20,
                  height: 1.5,
                  color: fg.withValues(alpha: 0.85))),
        ],
      ),
    );
  }

  Widget _bigButton() {
    final recording = _phase == _Phase.recording;
    final thinking = _phase == _Phase.thinking;
    final label = recording ? '放開就送出' : (thinking ? '處理中…' : '按住說話');
    return GestureDetector(
      onTapDown: (_) => _startRecording(),
      onTapUp: (_) => _stopAndSend(),
      onTapCancel: () => _stopAndSend(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 168,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: recording
                ? const [Color(0xFFD64545), Color(0xFFB4322E)]
                : const [Color(0xFFF97316), Color(0xFFB85708)],
          ),
          boxShadow: [
            BoxShadow(
              color: (recording
                      ? const Color(0xFFB4322E)
                      : const Color(0xFFB85708))
                  .withValues(alpha: 0.45),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(recording ? Icons.mic : Icons.mic_none,
                size: 64, color: Colors.white),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// 國語／台語切換小藥丸。改的是長輩偏好語言（與家屬 App 共用 preferred_lang）。
class _LangToggle extends StatelessWidget {
  const _LangToggle({required this.value, required this.onChanged});

  final ElderLang value;
  final ValueChanged<ElderLang> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: JinsunColors.line),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final l in ElderLang.values)
            GestureDetector(
              onTap: () => onChanged(l),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: value == l ? JinsunColors.orange : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  l.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: value == l ? Colors.white : JinsunColors.muted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
