import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:jinsun_core/jinsun_core.dart';
import 'package:jinsun_ui_kit/jinsun_ui_kit.dart';

import '../app_local.dart';

/// 家屬填寫／編輯長輩基本資料。
///
/// 這是「社工後台的長輩狀態卡」與「志工派遣單上的長輩資訊、導航地址」的唯一真實來源——
/// 家屬在這裡填了，下游三端才有真資料可看；不填就只有空白。
/// 送出時會對地址做一次地理編碼（OpenStreetMap Nominatim），把地圖釘與志工路線一起校正到正確位置。
class ElderProfilePage extends StatefulWidget {
  const ElderProfilePage({super.key, required this.local, required this.elder});

  final AppLocal local;
  final Elder elder;

  @override
  State<ElderProfilePage> createState() => _ElderProfilePageState();
}

class _ElderProfilePageState extends State<ElderProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _age;
  late final TextEditingController _address;
  late final TextEditingController _phone;
  late final TextEditingController _note;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.elder;
    _name = TextEditingController(text: e.name);
    _age = TextEditingController(text: e.age > 0 ? '${e.age}' : '');
    _address = TextEditingController(text: e.address);
    _phone = TextEditingController(text: e.phone ?? '');
    _note = TextEditingController(text: e.note ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _address.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 對地址做地理編碼；成功回 (lat, lng)，失敗（查無／逾時／離線）回 null，
  /// 讓後端保留原本座標，不會把地圖釘拉到錯的地方。
  Future<(double, double)?> _geocode(String address) async {
    if (address.trim().isEmpty) return null;
    try {
      final url = Uri.parse(
          'https://nominatim.openstreetmap.org/search'
          '?q=${Uri.encodeQueryComponent(address.trim())}'
          '&format=json&limit=1&countrycodes=tw');
      final res = await http.get(url, headers: {
        // Nominatim 使用政策要求帶可辨識的 User-Agent。
        'User-Agent': 'jinsun-radio-family/1.0',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final list = jsonDecode(res.body) as List;
      if (list.isEmpty) return null;
      final first = list.first as Map<String, dynamic>;
      final lat = double.tryParse('${first['lat']}');
      final lng = double.tryParse('${first['lon']}');
      if (lat == null || lng == null) return null;
      return (lat, lng);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final address = _address.text.trim();
    // 地址有變才重新地理編碼（避免每次存檔都打 Nominatim）。
    (double, double)? coord;
    if (address != widget.elder.address.trim()) {
      coord = await _geocode(address);
    }
    try {
      await widget.local.backend.updateElderProfile(
        widget.elder.id,
        name: _name.text.trim(),
        age: int.tryParse(_age.text.trim()) ?? widget.elder.age,
        address: address,
        phone: _phone.text.trim(),
        note: _note.text.trim(),
        lat: coord?.$1,
        lng: coord?.$2,
      );
      if (!mounted) return;
      final located = coord != null;
      final geocodeChanged = address != widget.elder.address.trim();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(geocodeChanged && !located
            ? '已儲存長輩資料（地址無法定位，地圖位置沿用先前設定）'
            : '已儲存長輩資料，社工與志工都會看到最新資訊'),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('儲存失敗，請稍後再試（$e）')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('長輩資料')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: JinsunColors.orangeBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 20, color: JinsunColors.orangeDeep),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '這裡填的資料，就是社工後台與志工派遣單上看到的長輩資訊。'
                      '地址請填完整，志工會照著它導航到府。',
                      style: TextStyle(
                          color: JinsunColors.orangeDeep, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _field(
              controller: _name,
              label: '長輩姓名',
              icon: Icons.badge_outlined,
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '請填寫長輩姓名' : null,
            ),
            const SizedBox(height: 16),
            _field(
              controller: _age,
              label: '年齡',
              icon: Icons.cake_outlined,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              textInputAction: TextInputAction.next,
              validator: (v) {
                final n = int.tryParse((v ?? '').trim());
                if (n == null || n <= 0) return '請填寫有效年齡';
                return null;
              },
            ),
            const SizedBox(height: 16),
            _field(
              controller: _address,
              label: '居住地址',
              icon: Icons.location_on_outlined,
              helperText: '志工到府導航用，請填完整（含縣市、路名、門牌）',
              textInputAction: TextInputAction.next,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '請填寫居住地址' : null,
            ),
            const SizedBox(height: 16),
            _field(
              controller: _phone,
              label: '家中電話（選填）',
              icon: Icons.phone_outlined,
              keyboardType: TextInputType.phone,
              helperText: '家屬／志工緊急時可直撥；不填則停用撥號鈕',
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16),
            _field(
              controller: _note,
              label: '狀況注記（選填）',
              icon: Icons.medical_information_outlined,
              helperText: '獨居、慢性病、行動狀況、用藥提醒等，志工出勤前會先看到',
              maxLines: 3,
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.check),
                label: Text(_saving ? '儲存中…' : '儲存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? helperText,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    TextInputAction? textInputAction,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      maxLines: maxLines,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperMaxLines: 2,
        prefixIcon: Icon(icon),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
