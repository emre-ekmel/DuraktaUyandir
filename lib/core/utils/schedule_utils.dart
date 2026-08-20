/// Pure schedule-window and mute-lifecycle logic shared by the background
/// service isolate and the UI layer. No Flutter imports — fully unit-testable.
library;

import 'dart:convert';

import 'package:durakta_uyandir/core/utils/location_utils.dart';
import 'package:durakta_uyandir/domain/entities/destination_alarm.dart';

/// Parses an "HH:mm" string into minutes-since-midnight, or null on bad input.
/// Accepts zero-padded and non-padded hours ("7:05" == "07:05").
int? parseHHmm(String? time) {
  if (time == null) return null;
  final parts = time.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}

/// Formats hour/minute as zero-padded "HH:mm".
String formatHHmm(int hour, int minute) {
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Whether a schedule configuration is storable.
/// A non-scheduled alarm needs no config; when scheduled we require at least
/// one day and a valid forward window (start strictly before end).
bool isScheduleConfigValid({
  required Set<int> scheduledDays,
  String? startTime,
  String? endTime,
}) {
  if (scheduledDays.isEmpty) return false;
  final start = parseHHmm(startTime);
  final end = parseHHmm(endTime);
  if (start == null || end == null) return false;
  return start < end;
}

/// Returns true when the alarm is allowed to fire/track at [now]:
///  • not scheduled → always true (identical to pre-scheduling behavior);
///  • scheduled → now's weekday is selected AND now's time-of-day is inside
///    the window [startTime, endTime) — start inclusive, end exclusive.
///
/// KNOWN LIMITATION (v1): overnight wraparound is intentionally unsupported.
/// Windows where startTime >= endTime (e.g. 22:00 → 06:00) always return
/// false; the UI validates start < end at save time. Supporting cross-midnight
/// windows requires day-of-week rollover semantics which v1 does not model.
///
/// Defensive rule: a scheduled alarm with missing/invalid fields (null times,
/// empty day set, corrupted strings) is treated as OUTSIDE its window —
/// fail-silent (the alarm simply doesn't fire) rather than fail-loud.
bool isWithinScheduleWindow({
  required bool isScheduled,
  required Set<int> scheduledDays,
  String? startTime,
  String? endTime,
  required DateTime now,
}) {
  if (!isScheduled) return true;

  if (scheduledDays.isEmpty || !scheduledDays.contains(now.weekday)) {
    return false;
  }

  final start = parseHHmm(startTime);
  final end = parseHHmm(endTime);
  if (start == null || end == null || start >= end) return false;

  final nowMinutes = now.hour * 60 + now.minute;
  return nowMinutes >= start && nowMinutes < end;
}

/// Map-payload variant used inside the background service isolate, where
/// alarms travel as plain maps over the isolate channel.
/// Missing keys fall back to the same defaults as old Hive records
/// (isScheduled: false), so un-upgraded payloads always pass through.
bool isAlarmWithinSchedule(Map<String, dynamic> alarm, DateTime now) {
  final isScheduled = alarm['isScheduled'] as bool? ?? false;

  final rawDays = alarm['scheduledDays'];
  final scheduledDays = rawDays is List
      ? rawDays.map((e) => (e as num).toInt()).toSet()
      : const <int>{};

  return isWithinScheduleWindow(
    isScheduled: isScheduled,
    scheduledDays: scheduledDays,
    startTime: alarm['startTime'] as String?,
    endTime: alarm['endTime'] as String?,
    now: now,
  );
}

// ---------------------------------------------------------------------------
// MUTED ("SUSTUR") lifecycle — pure, injectable, unit-testable.
// ---------------------------------------------------------------------------

/// Extra meters beyond an alarm's trigger radius that must be exceeded before
/// a MUTED alarm re-arms. Sized like the tier engine's hysteresis buffers
/// (100–200 m) but a SEPARATE per-alarm concept — deliberately not reusing
/// the tier thresholds.
const double kMuteExitBufferMeters = 200.0;

/// The single re-arm rule for muted alarms: strictly outside
/// radius + [kMuteExitBufferMeters]. Hitting the boundary exactly does NOT
/// re-arm — same buffer-between-thresholds hysteresis idea as the tier engine.
bool isOutsideMuteExitBoundary({
  required double distance,
  required double radiusMeters,
}) {
  return distance > radiusMeters + kMuteExitBufferMeters;
}

/// Engine eligibility used for BOTH triggering and tier/tracking decisions:
/// an alarm counts only when it is ON (isActive), NOT muted, and inside its
/// schedule window. Muted alarms never trigger (regardless of any trigger
/// cooldown) and never contribute to the tier-selection min-distance —
/// that exclusion is the battery fix, not a side effect.
bool isEngineEligible(
  Map<String, dynamic> alarm, {
  required DateTime now,
  Set<String> mutedIds = const {},
}) {
  if (alarm['isActive'] != true) return false;
  final id = alarm['id'];
  if (id is String && mutedIds.contains(id)) return false;
  return isAlarmWithinSchedule(alarm, now);
}

/// All currently engine-eligible alarms (see [isEngineEligible]).
List<Map<String, dynamic>> engineEligibleAlarms(
  List<Map<String, dynamic>> alarms, {
  DateTime? now,
  Set<String> mutedIds = const {},
}) {
  final effectiveNow = now ?? DateTime.now();
  return alarms
      .where((a) => isEngineEligible(a, now: effectiveNow, mutedIds: mutedIds))
      .toList();
}

/// Muted alarm ids whose distance from ([lat], [lng]) exceeds their personal
/// exit boundary (radius + [kMuteExitBufferMeters]) and must re-arm.
/// Malformed/inactive entries are ignored (left muted until pruned elsewhere).
Set<String> mutedAlarmsOutsideExitBoundary(
  List<Map<String, dynamic>> alarms,
  Set<String> mutedIds,
  double lat,
  double lng,
) {
  if (mutedIds.isEmpty) return const {};
  final cleared = <String>{};
  for (final alarm in alarms) {
    final id = alarm['id'];
    if (id is! String || !mutedIds.contains(id)) continue;
    if (alarm['isActive'] != true) continue;
    final targetLat = (alarm['targetLat'] as num?)?.toDouble();
    final targetLng = (alarm['targetLng'] as num?)?.toDouble();
    if (targetLat == null || targetLng == null) continue;
    final radius = (alarm['triggerRadiusInMeters'] as num?)?.toDouble() ?? 500.0;
    final distance = LocationUtils.calculateDistance(lat, lng, targetLat, targetLng);
    if (isOutsideMuteExitBoundary(distance: distance, radiusMeters: radius)) {
      cleared.add(id);
    }
  }
  return cleared;
}

/// Muted ids of SCHEDULED alarms whose window is currently closed — the next
/// window must start fresh (unmuted) regardless of whether the user left the
/// area. Unscheduled muted alarms are never cleared here (distance-only re-arm).
Set<String> mutedAlarmsWithClosedWindow(
  List<Map<String, dynamic>> alarms,
  Set<String> mutedIds,
  DateTime now,
) {
  if (mutedIds.isEmpty) return const {};
  final cleared = <String>{};
  for (final alarm in alarms) {
    final id = alarm['id'];
    if (id is! String || !mutedIds.contains(id)) continue;
    final isScheduled = alarm['isScheduled'] as bool? ?? false;
    if (isScheduled && !isAlarmWithinSchedule(alarm, now)) {
      cleared.add(id);
    }
  }
  return cleared;
}

/// Notification payloads are small JSON maps ({"id": ...}) so the cold
/// dispatcher isolate can act without live isolate state. Notifications
/// posted by older builds carry a bare id string — tolerate both.
String? parseAlarmIdFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  if (payload.startsWith('{')) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map && decoded['id'] is String) {
        return decoded['id'] as String;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
  return payload; // legacy bare id
}

/// Entity → service-isolate payload map (the wire shape shared by
/// [BackgroundLocationService.updateAlarms] and the service isolate's own
/// cold-start hydration). Any new engine-relevant field must be mirrored here
/// OR boot/respawn-hydrated state will silently diverge from UI-pushed state.
Map<String, dynamic> destinationAlarmToServicePayload(DestinationAlarm a) {
  return {
    'id': a.id,
    'name': a.name,
    'targetLat': a.targetLat,
    'targetLng': a.targetLng,
    'triggerRadiusInMeters': a.triggerRadiusInMeters,
    'isActive': a.isActive,
    'isScheduled': a.isScheduled,
    'scheduledDays': a.scheduledDays.toList(),
    'startTime': a.startTime,
    'endTime': a.endTime,
  };
}

/// Earliest FUTURE schedule-window opening across all active scheduled alarms
/// (service-payload maps). `null` when no scheduled alarm has any future
/// boundary within the next 8 days — i.e. the engine need not wake for
/// window-open at all. Unscheduled alarms contribute nothing (they are
/// permanently "inside" their window by definition).
///
/// Drives the self-heal scheduler's precise window-open tick: the engine may
/// sleep through closed windows (battery) yet still come alive exactly when a
/// window opens.
DateTime? nextScheduleWindowOpen(List<Map<String, dynamic>> alarms, {DateTime? now}) {
  final n = now ?? DateTime.now();
  DateTime? best;
  for (final alarm in alarms) {
    if (alarm['isActive'] != true) continue;
    final isScheduled = alarm['isScheduled'] as bool? ?? false;
    if (!isScheduled) continue;

    final rawDays = alarm['scheduledDays'];
    if (rawDays is! List || rawDays.isEmpty) continue;
    final daySet = rawDays.map((e) => (e as num).toInt()).toSet();

    final start = parseHHmm(alarm['startTime'] as String?);
    final end = parseHHmm(alarm['endTime'] as String?);
    if (start == null || end == null || start >= end) continue;

    final startHour = start ~/ 60;
    final startMinute = start % 60;
    for (var offset = 0; offset < 8; offset++) {
      final day = DateTime(n.year, n.month, n.day + offset);
      if (!daySet.contains(day.weekday)) continue;
      final boundary = DateTime(day.year, day.month, day.day, startHour, startMinute);
      if (boundary.isAfter(n) && (best == null || boundary.isBefore(best))) {
        best = boundary;
      }
    }
  }
  return best;
}
