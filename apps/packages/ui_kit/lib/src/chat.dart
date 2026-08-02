import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:jinsun_core/jinsun_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'theme.dart';

/// 派遣單文字聊天（家屬↔志工）。即時（Realtime），**送出無法收回**。
/// 與遮罩通話並存：任務進行中才有入口，結案後入口消失。
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.backend,
    required this.taskId,
    required this.myRole,
    required this.title,
    required this.accent,
    this.myId,
    this.peerName,
    this.onCall,
    this.readOnly = false,
  });

  final BackendClient backend;
  final String taskId;
  final ChatFromRole myRole; // 我是家屬還是志工
  final String? myId;
  final String title; // AppBar 標題，如「與家屬的訊息」
  final Color accent;
  final String? peerName; // 對方顯示名（放在底部通話鈕，如「林阿春」「志工」）
  // 底部兩顆玻璃擬態按鈕固定是「🎤 語音輸入（ASR）」＋「📞 通話（Jitsi）」。
  // 語音輸入永遠可用；通話僅在提供 [onCall] 時顯示。
  final VoidCallback? onCall; // 📞 通話（App 內 Jitsi 遮罩 VoIP）
  final bool readOnly; // 歷史查看模式：隱藏輸入列與底部鈕，只讀訊息

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  // ---- 語音輸入（按住說話 → Whisper 轉文字 → 填回輸入框）----
  final _recorder = AudioRecorder();
  bool _recording = false; // 錄音中
  bool _transcribing = false; // 上傳辨識中
  Timer? _tick;
  int _elapsed = 0; // 錄音秒數
  // 實際錄出的格式（依瀏覽器/平台而定），上傳時要與 OpenAI 對得上，否則報 Invalid file format
  String _recFilename = 'audio.m4a';
  String _recMime = 'audio/mp4';

  @override
  void dispose() {
    _tick?.cancel();
    _recorder.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startRecord() async {
    if (_recording || _transcribing) return;
    if (!await _recorder.hasPermission()) {
      _toast('請允許使用麥克風才能語音輸入');
      return;
    }
    // 依「這個瀏覽器/平台實際支援的編碼器」挑格式，並記下對應的副檔名/mime。
    // Chrome/Firefox：opus→webm；Safari/iOS：不支援 opus，退回 aac→m4a/mp4。
    // 原生 Android/iOS：aac→m4a。三者 Whisper 都吃，但檔名/mime 必須與內容相符。
    AudioEncoder encoder = AudioEncoder.aacLc;
    _recFilename = 'audio.m4a';
    _recMime = 'audio/mp4';
    if (kIsWeb) {
      if (await _recorder.isEncoderSupported(AudioEncoder.opus)) {
        encoder = AudioEncoder.opus;
        _recFilename = 'audio.webm';
        _recMime = 'audio/webm';
      } else if (await _recorder.isEncoderSupported(AudioEncoder.aacLc)) {
        encoder = AudioEncoder.aacLc;
        _recFilename = 'audio.m4a';
        _recMime = 'audio/mp4';
      }
    }
    final config = RecordConfig(encoder: encoder);
    var path = '';
    if (!kIsWeb) {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/jinsun_voice_${DateTime.now().millisecondsSinceEpoch}'
          '.m4a';
    }
    try {
      await _recorder.start(config, path: path);
    } catch (e) {
      _toast('無法開始錄音：$e');
      return;
    }
    _elapsed = 0;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    setState(() => _recording = true);
  }

  Future<void> _cancelRecord() async {
    _tick?.cancel();
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    if (mounted) setState(() => _recording = false);
  }

  Future<void> _stopAndTranscribe() async {
    if (!_recording) return;
    _tick?.cancel();
    final tooShort = _elapsed < 1;
    setState(() => _recording = false);
    final path = await _recorder.stop();
    if (path == null || path.isEmpty || tooShort) {
      if (tooShort) _toast('說話時間太短，請再試一次');
      return;
    }
    setState(() => _transcribing = true);
    try {
      final bytes = await XFile(path).readAsBytes();
      final text = await widget.backend.transcribeAudio(
        bytes,
        filename: _recFilename,
        mimeType: _recMime,
      );
      if (!mounted) return;
      if (text.isEmpty) {
        _toast('沒有聽清楚，請再說一次');
      } else {
        // 轉出的文字填回輸入框，讓使用者確認／修改後再送出。
        final base = _input.text;
        _input.text = base.isEmpty ? text : '$base $text';
        _input.selection =
            TextSelection.collapsed(offset: _input.text.length);
      }
    } catch (e) {
      if (mounted) _toast('語音辨識失敗，請改用打字：$e');
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.backend.sendTaskMessage(widget.taskId,
          from: widget.myRole, senderId: widget.myId, text: text);
      // 只在「送出成功」後才清空輸入框——失敗時保留文字，讓使用者直接重送。
      _input.clear();
      // 送出後捲到底
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
        }
      });
    } catch (e) {
      // 沒有這層 try/catch 的話：送出一失敗，_sending 會永遠卡在 true，
      // 之後按送出鍵完全沒反應（尤其語音輸入完想送卻送不出去），而且錯誤悄無聲息。
      _toast('訊息送不出去，請檢查網路後再試一次');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: widget.accent,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<TaskMessage>>(
              stream: widget.backend.messages,
              initialData: widget.backend.currentMessages,
              builder: (context, snap) {
                final msgs = (snap.data ?? [])
                    .where((m) => m.taskId == widget.taskId)
                    .toList()
                  ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text('還沒有訊息，傳第一則吧',
                        style: TextStyle(color: JinsunColors.muted)),
                  );
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(14),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _bubble(msgs[i]),
                );
              },
            ),
          ),
          if (widget.readOnly)
            const SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Text('這是已結案的歷史對話，僅供查看',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12.5, color: JinsunColors.muted)),
              ),
            )
          else ...[
            _actionBar(),
            _composer(),
          ],
        ],
      ),
    );
  }

  /// 底部玻璃擬態兩顆鈕：🎤 語音輸入（ASR，錄音轉文字填回輸入框）／📞 通話（Jitsi 遮罩 VoIP）。
  /// 語音輸入永遠顯示；通話僅在提供 [onCall] 時顯示。
  Widget _actionBar() {
    final busy = _recording || _transcribing;
    return Container(
      // 底層淡色漸層，讓上方的毛玻璃有東西可模糊、玻璃感才明顯。
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.accent.withValues(alpha: 0.16),
            widget.accent.withValues(alpha: 0.05),
          ],
        ),
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: _GlassCallButton(
                    icon: Icons.mic,
                    label: '語音輸入',
                    sub: _recording
                        ? '錄音中…'
                        : (_transcribing ? '辨識中…' : '說話轉文字'),
                    accent: widget.accent,
                    // 錄音／辨識中不重複觸發；錄音的停止／取消在下方輸入列。
                    onTap: busy ? null : _startRecord,
                  ),
                ),
                if (widget.onCall != null) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: _GlassCallButton(
                      icon: Icons.call,
                      label: '通話',
                      sub: widget.peerName == null
                          ? '安全轉接'
                          : '撥給${widget.peerName}',
                      accent: widget.accent,
                      onTap: widget.onCall!,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubble(TaskMessage m) {
    if (m.fromRole == ChatFromRole.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(m.text,
              style: const TextStyle(fontSize: 12, color: JinsunColors.muted)),
        ),
      );
    }
    final mine = m.fromRole == widget.myRole;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? widget.accent : const Color(0xFFEDEDED),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(m.text,
                style: TextStyle(
                    fontSize: 15,
                    color: mine ? Colors.white : Colors.black87)),
            const SizedBox(height: 2),
            Text(
              '${m.createdAt.hour.toString().padLeft(2, '0')}:${m.createdAt.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                  fontSize: 10,
                  color: mine ? Colors.white70 : JinsunColors.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: JinsunColors.line)),
        ),
        child: _recording ? _recordingBar() : _inputRow(),
      ),
    );
  }

  Widget _inputRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _input,
            enabled: !_transcribing,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              // 語音輸入已移到上方玻璃鈕；這裡只留打字與送出。
              hintText: _transcribing ? '辨識中…' : '輸入訊息，或用上方語音輸入…',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          style: IconButton.styleFrom(backgroundColor: widget.accent),
          onPressed: (_transcribing || _sending) ? null : _send,
          icon: _sending
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send, size: 20),
        ),
      ],
    );
  }

  Widget _recordingBar() {
    final mm = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final ss = (_elapsed % 60).toString().padLeft(2, '0');
    return Row(
      children: [
        TextButton(
          onPressed: _cancelRecord,
          child: const Text('取消', style: TextStyle(color: JinsunColors.muted)),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _PulsingDot(),
              const SizedBox(width: 8),
              Text('錄音中 $mm:$ss',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: widget.accent),
          onPressed: _stopAndTranscribe,
          icon: const Icon(Icons.check, size: 18),
          label: const Text('完成'),
        ),
      ],
    );
  }
}

/// 錄音中的閃爍紅點。
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();
  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.3, end: 1).animate(_c),
      child: Container(
        width: 12,
        height: 12,
        decoration: const BoxDecoration(
          color: Color(0xFFE53935),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 大型玻璃擬態（Glassmorphism）通話鈕：半透明白玻璃＋高光邊框＋圖示＋文案。
class _GlassCallButton extends StatelessWidget {
  const _GlassCallButton({
    required this.icon,
    required this.label,
    required this.sub,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String sub;
  final Color accent;
  final VoidCallback? onTap; // null＝停用（如語音輸入正在錄音／辨識中）

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
      color: Colors.white.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.75)),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.14),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                child: Icon(icon, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: JinsunColors.ink)),
                  Text(sub,
                      style: const TextStyle(
                          fontSize: 11.5, color: JinsunColors.muted)),
                ],
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// 派遣進行中的「傳訊息」入口（放在派遣卡／任務卡，與遮罩通話並存）。
class ChatMessageButton extends StatelessWidget {
  const ChatMessageButton({
    super.key,
    required this.backend,
    required this.taskId,
    required this.myRole,
    required this.title,
    required this.accent,
    this.label = '傳訊息',
    this.myId,
  });

  final BackendClient backend;
  final String taskId;
  final ChatFromRole myRole;
  final String? myId;
  final String title;
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          foregroundColor: accent,
          side: BorderSide(color: accent.withValues(alpha: 0.5)),
        ),
        icon: const Icon(Icons.chat_bubble_outline, size: 17),
        label: Text(label),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatScreen(
            backend: backend,
            taskId: taskId,
            myRole: myRole,
            myId: myId,
            title: title,
            accent: accent,
          ),
        )),
      ),
    );
  }
}
