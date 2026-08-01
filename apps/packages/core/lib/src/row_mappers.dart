import 'models.dart';

/// 資料庫列 → 資料模型。
///
/// 兩套後端（Supabase PostgREST 與 AWS 的 jinsun-data）回的是**同一份 schema 的同一批
/// 欄位名**，所以解析只能有一份。之前這些函式散在 SupabaseBackend 裡，複製一份到
/// AwsBackend 的話，日後加欄位就會出現「一邊看得到、另一邊看不到」這種最難查的 bug。
///
/// 時間一律 `toLocal()`：兩邊都存 UTC，直接顯示會差 8 小時。

Severity severityFromWire(String? s) => switch (s) {
      'emergency' => Severity.emergency,
      'attention' => Severity.attention,
      _ => Severity.normal,
    };

Elder elderFromRow(Map<String, dynamic> r) => Elder(
      id: r['id'] as String,
      name: r['name'] as String,
      age: ((r['age'] ?? 0) as num).toInt(),
      address: (r['address'] ?? '') as String,
      phone: r['phone'] as String?,
      lat: ((r['lat'] ?? 0) as num).toDouble(),
      lng: ((r['lng'] ?? 0) as num).toDouble(),
      severity: severityFromWire(r['severity'] as String?),
      preferredLang:
          (r['preferred_lang'] == 'taigi') ? ElderLang.taigi : ElderLang.mandarin,
      deviceSerial: r['device_serial'] as String?,
      lastActivityAt:
          DateTime.tryParse((r['last_activity_at'] ?? '') as String) ??
              DateTime.now(),
      note: r['note'] as String?,
      supervisorWorkerName: r['supervisor_worker_name'] as String?,
      supervisorVolunteerName: r['supervisor_volunteer_name'] as String?,
    );

RadioEvent eventFromRow(Map<String, dynamic> r) => RadioEvent(
      id: r['id'].toString(),
      elderId: (r['elder_id'] ?? '') as String,
      type: switch (r['type'] as String) {
        'sos' => RadioEventType.sos,
        'supply_request' => RadioEventType.supplyRequest,
        _ => RadioEventType.fallSuspected,
      },
      status: switch (r['status'] as String) {
        'confirmed_ok' => RadioEventStatus.confirmedOk,
        'escalated' => RadioEventStatus.escalated,
        'closed' => RadioEventStatus.closed,
        _ => RadioEventStatus.open,
      },
      severity: severityFromWire(r['severity'] as String?),
      occurredAt: DateTime.parse(r['occurred_at'] as String).toLocal(),
      transcript: r['transcript'] as String?,
    );

DispatchTask taskFromRow(Map<String, dynamic> r) => DispatchTask(
      id: r['id'].toString(),
      elderId: (r['elder_id'] ?? '') as String,
      eventId: (r['event_id'] ?? '').toString(),
      kind: switch (r['kind'] as String) {
        'supply' => DispatchKind.supply,
        'follow_up' => DispatchKind.followUp,
        _ => DispatchKind.emergency,
      },
      status: switch (r['status'] as String) {
        'accepted' => DispatchStatus.accepted,
        'arrived' => DispatchStatus.arrived,
        'resolved' => DispatchStatus.resolved,
        _ => DispatchStatus.pending,
      },
      assigneeName: r['assignee_name'] as String?,
      workerName: r['worker_name'] as String?,
      etaMinutes: (r['eta_minutes'] as num?)?.toInt(),
      items: ((r['items'] ?? const []) as List).cast<String>(),
      note: r['note'] as String?,
      outcome: r['outcome'] as String?,
      proofPhotoUrl: r['proof_photo_url'] as String?,
      createdAt: DateTime.parse(r['created_at'] as String).toLocal(),
      acceptedAt: DateTime.tryParse((r['accepted_at'] ?? '') as String)?.toLocal(),
      arrivedAt: DateTime.tryParse((r['arrived_at'] ?? '') as String)?.toLocal(),
      resolvedAt: DateTime.tryParse((r['resolved_at'] ?? '') as String)?.toLocal(),
      offeredUntil:
          DateTime.tryParse((r['offered_until'] ?? '') as String)?.toLocal(),
    );

TaskMessage messageFromRow(Map<String, dynamic> r) => TaskMessage(
      id: r['id'].toString(),
      taskId: (r['task_id'] ?? '').toString(),
      fromRole: switch (r['from_role'] as String) {
        'family' => ChatFromRole.family,
        'volunteer' => ChatFromRole.volunteer,
        _ => ChatFromRole.system,
      },
      senderId: r['sender_id'] as String?,
      text: (r['text'] ?? '') as String,
      createdAt: DateTime.parse(r['created_at'] as String),
    );

CallSignal callFromRow(Map<String, dynamic> r) => CallSignal(
      id: r['id'].toString(),
      taskId: (r['task_id'] ?? '').toString(),
      room: (r['room'] ?? '') as String,
      from: CallRoleWire.parse((r['from_role'] ?? 'family') as String),
      to: CallRoleWire.parse((r['to_role'] ?? 'volunteer') as String),
      status: CallStatusWire.parse((r['status'] ?? 'ended') as String),
      fromName: r['from_name'] as String?,
      createdAt:
          DateTime.tryParse((r['created_at'] ?? '') as String) ?? DateTime.now(),
    );

SocialWorker workerFromRow(Map<String, dynamic> r) => SocialWorker(
      id: r['id'] as String,
      name: r['name'] as String,
      phone: (r['phone'] ?? '') as String,
      shiftStartHour: (r['shift_start_hour'] as num).toInt(),
      shiftEndHour: (r['shift_end_hour'] as num).toInt(),
    );

VolunteerCertificate certificateFromRow(Map<String, dynamic> c) =>
    VolunteerCertificate(
      kind: CertKindLabel.fromWire((c['kind'] ?? '') as String),
      status: CertStatusLabel.fromWire(c['status'] as String?),
      issuedAt: DateTime.tryParse((c['issued_at'] ?? '') as String),
      expiresAt: DateTime.tryParse((c['expires_at'] ?? '') as String),
      note: c['note'] as String?,
    );

List<ServiceHourSlot> serviceHoursFromRow(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((m) => ServiceHourSlot.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

Volunteer volunteerFromRow(Map<String, dynamic> r,
        {List<VolunteerCertificate> certificates = const []}) =>
    Volunteer(
      id: r['id'] as String,
      name: r['name'] as String,
      phone: (r['phone'] ?? '') as String,
      lat: ((r['lat'] ?? 0) as num).toDouble(),
      lng: ((r['lng'] ?? 0) as num).toDouble(),
      online: (r['online'] ?? true) as bool,
      points: ((r['points'] ?? 0) as num).toInt(),
      intro: (r['intro'] ?? '') as String,
      serviceHours: serviceHoursFromRow(r['service_hours']),
      certificates: certificates,
      locationUpdatedAt:
          DateTime.tryParse((r['location_updated_at'] ?? '') as String),
    );
