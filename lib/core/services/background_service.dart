import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:audio_session/audio_session.dart' hide AndroidAudioFocus, AVAudioSessionCategory;
import 'package:audioplayers/audioplayers.dart';
import 'package:durakta_uyandir/core/services/alarm_state_loader.dart';
import 'package:durakta_uyandir/core/services/self_heal_service.dart';
import 'package:durakta_uyandir/core/utils/location_utils.dart';
import 'package:durakta_uyandir/core/utils/schedule_utils.dart';
import 'package:durakta_uyandir/core/utils/stopped_alarms_queue.dart';
import 'package:durakta_uyandir/domain/entities/destination_alarm.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

bool _isSoundEnabled = true;
bool _isVibrationEnabled = true;
bool _isNotificationEnabled = true;

bool _isHeadphoneOnlyModeEnabled = false;

final AudioPlayer _audioPlayer = AudioPlayer();

/// Ring-loop state (single ring at a time; notification slot is fixed to 0).
/// Drives: play → onPlayerComplete → wait [_kRingReplayGap] → replay, until
/// the ceiling elapses or cleanupRing() tears everything down.
StreamSubscription<void>? _playerCompleteSubscription;
Timer? _ringReplayTimer;

/// Silence gap between alarm-sound repetitions inside one ring cycle.
const Duration _kRingReplayGap = Duration(seconds: 5);

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse notificationResponse) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    // Breadcrumb for on-device dispatch verification: whichever isolate
    // (dispatcher or main) receives the action prints this line first.
    debugPrint(
      '[NotifTap] handler entered: actionId=${notificationResponse.actionId}, '
      'payload=${notificationResponse.payload}',
    );

    final actionId = notificationResponse.actionId;
    final alarmId = parseAlarmIdFromPayload(notificationResponse.payload);

    // A plain body tap (actionId == null) must not cancel or mute anything.
    if (alarmId == null) return;

    switch (actionId) {
      case 'stop_alarm_action':
        // KAPAT → OFF. Durable write FIRST — this handler can run in a cold
        // dispatcher isolate where the service is not running and the invoke
        // below would be silently dropped.
        try {
          await StoppedAlarmsQueue.record(alarmId);
        } catch (e) {
          debugPrint('notificationTapBackground prefs error: $e');
        }

        // Dismiss the notification locally as well: if the service is dead
        // (e.g. force-stopped process), nobody else will remove it.
        try {
          await FlutterLocalNotificationsPlugin().cancel(0);
        } catch (e) {
          debugPrint('notificationTapBackground cancel error: $e');
        }

        // Best-effort live delivery for immediate in-service effect
        // (stop sound/vibration, disable in memory).
        FlutterBackgroundService().invoke('stop_alarm_from_notification', {'id': alarmId});

      case 'mute_alarm_action':
        // SUSTUR → MUTED. In-memory only per design — NO durable write needed;
        // a lost mute costs at most one re-ring. If the service is dead the
        // invoke is dropped and the alarm stays ACTIVE: acceptable.
        try {
          await FlutterLocalNotificationsPlugin().cancel(0);
        } catch (e) {
          debugPrint('notificationTapBackground cancel error: $e');
        }
        FlutterBackgroundService().invoke('mute_alarm_from_notification', {'id': alarmId});

      default:
        return;
    }
  } catch (e) {
    debugPrint('notificationTapBackground Error: $e');
  }
}

final Map<String, DateTime> _lastTriggerTimes = {};

/// In-memory MUTED set ("SUSTUR" for the current visit). Deliberately NOT
/// persisted: losing a mute on process restart costs at most one re-ring
/// (annoying, self-correcting) — unlike the OFF path, which must be durable
/// because losing a stop is a silent permanent failure.
final Set<String> _mutedAlarmIds = {};

/// Max duration of one ring cycle before it auto-transitions to MUTED.
/// (Introduced with the mute lifecycle: previously an ignored notification
/// left the alarm ACTIVE and it could re-ring after the cooldown.)
const Duration _kRingCeilingDuration = Duration(minutes: 2);

Timer? _ringCeilingTimer;
String? _ringCeilingAlarmId;

/// Hook assigned in onStart() so top-level trigger code can route ceiling
/// expiries into the isolate-local mute logic.
void Function(String alarmId)? onRingCeilingElapsed;

/// The single eligibility filter for the whole isolate: an alarm can drive
/// GPS tracking / tier min-distance and can trigger only when it is enabled
/// (isActive), NOT muted, AND currently inside its schedule window.
/// Consolidated here so tier selection, triggering, and stream gating can
/// never disagree about what "active" means.
List<Map<String, dynamic>> _scheduleEligibleAlarms(List<Map<String, dynamic>> alarms) {
  return engineEligibleAlarms(alarms, now: DateTime.now(), mutedIds: _mutedAlarmIds);
}

// ---------------------------------------------------------------------------
// Phase 1 — Tiered distance-aware location tracking (battery optimisation)
// ---------------------------------------------------------------------------

/// The three location-accuracy tiers, ordered from least to most expensive.
enum _LocationTier { far, medium, near }

// --- Tier enter thresholds: transition DOWN when distance drops below --------
const double _kFarToMediumEnter  = 3000.0; // metres — FAR  → MEDIUM
const double _kMediumToNearEnter =  500.0; //         MEDIUM → NEAR

// --- Tier exit thresholds: transition UP when distance rises above -----------
// The buffers over the enter values prevent flapping near boundaries.
const double _kMediumToFarExit  = 3200.0; // 200 m buffer — MEDIUM → FAR
const double _kNearToMediumExit =  600.0; // 100 m buffer — NEAR   → MEDIUM

/// Minimum interval between [setForegroundNotificationInfo] text refreshes.
const Duration _kNotificationThrottle = Duration(seconds: 15);

/// Muted presence check runs on every Nth engine-timer tick (tick = 60 s).
/// 5 ticks ≈ 5 minutes. Widen this single value toward the "few hours"
/// range if field data shows muted re-arm latency is acceptable that way.
const int _kMutePresenceCheckEveryTicks = 5;

/// Current active tier; reset to [_LocationTier.far] when the stream is stopped.
_LocationTier _currentTier = _LocationTier.far;

/// Timestamp of the last foreground-notification text update.
DateTime? _lastNotificationUpdate;

/// True while a tier-change stream restart is in progress.
/// Prevents a residual event from the old subscription triggering a second
/// restart before [_currentTier] has been updated.
bool _isTransitioning = false;

/// Used to serialize async stream restarts to prevent overlapping/leaking streams.
Completer<void>? _transitionCompleter;

/// Returns [AndroidSettings] for [tier] using the exact values from the
/// battery-optimisation brief (accuracy / distanceFilter / intervalDuration).
AndroidSettings _settingsForTier(_LocationTier tier) {
  switch (tier) {
    case _LocationTier.far:
      return AndroidSettings(
        accuracy: LocationAccuracy.low,
        distanceFilter: 300,
        intervalDuration: const Duration(minutes: 3),
      );
    case _LocationTier.medium:
      return AndroidSettings(
        accuracy: LocationAccuracy.medium,
        distanceFilter: 50,
        intervalDuration: const Duration(seconds: 30),
      );
    case _LocationTier.near:
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        intervalDuration: const Duration(seconds: 5),
      );
  }
}

/// Applies hysteresis to decide whether a tier change is warranted.
/// Call this on ongoing stream ticks where gradual transitions are desirable.
/// Use [_computeTierDirect] instead when starting from a cold/unknown position.
_LocationTier _computeTier(double distanceMetres, _LocationTier current) {
  switch (current) {
    case _LocationTier.far:
      return distanceMetres < _kFarToMediumEnter
          ? _LocationTier.medium
          : _LocationTier.far;
    case _LocationTier.medium:
      if (distanceMetres < _kMediumToNearEnter) return _LocationTier.near;
      if (distanceMetres > _kMediumToFarExit)   return _LocationTier.far;
      return _LocationTier.medium;
    case _LocationTier.near:
      return distanceMetres > _kNearToMediumExit
          ? _LocationTier.medium
          : _LocationTier.near;
  }
}

/// Determines the correct starting tier from a cold position with no hysteresis.
/// Used on first alarm activation and on every [updateAlarms] event.
_LocationTier _computeTierDirect(double distanceMetres) {
  if (distanceMetres < _kMediumToNearEnter) return _LocationTier.near;
  if (distanceMetres < _kFarToMediumEnter)  return _LocationTier.medium;
  return _LocationTier.far;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();

    // APP-CHECK INVARIANT — do not remove without reading.
    // This background isolate makes NO Firebase SDK calls by design
    // (persistence here is SharedPreferences via StoppedAlarmsQueue +
    // flutter_local_notifications; Firestore/Auth writes live in the UI
    // isolate via FeedbackService). That is why this isolate calls neither
    // Firebase.initializeApp() nor FirebaseAppCheck.instance.activate().
    //
    // If you EVER add a Firestore / Storage / Auth / FCM call here (or to
    // notificationTapBackground, which also runs on a cold dispatcher
    // isolate), you MUST first add, inside this isolate:
    //   await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    //   await FirebaseAppCheck.instance.activate(<same providers as main.dart>);
    // Otherwise, the moment App Check is set to Enforce for that product,
    // the background call starts silently failing with permission-denied —
    // a correctness-critical regression on the alarm path.
    //
    // Related performance rule: the tier/tick loops below must never call
    // FirebaseAppCheck.instance.getToken(forceRefresh: true); the SDK's
    // default token caching/TTL is sufficient (see main.dart).
    debugPrint("[BG Service] onStart() CALLED");

    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });

      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: "Durakta Uyandır",
        content: "Servis Başlatıldı...",
      );
    }

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    List<Map<String, dynamic>> monitoredAlarms = [];
    StreamSubscription<Position>? streamSubscription;

    /// Broadcasts the latest fix to the UI isolate so screens can show live
    /// distances/ETA without opening a second GPS stream of their own.
    void emitPositionUpdate(Position position) {
      service.invoke('position_update', {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'speed': position.speed,
        'timestamp': position.timestamp.toIso8601String(),
      });
    }

    Future<void> _stopStream(String reason) async {
      while (_transitionCompleter != null) {
        await _transitionCompleter!.future;
      }
      _transitionCompleter = Completer<void>();
      _isTransitioning = true;
      try {
        await streamSubscription?.cancel();
        streamSubscription = null;
        _currentTier = _LocationTier.far;
        debugPrint('[BG Service][TIER] Stream stopped ($reason).');
      } finally {
        _isTransitioning = false;
        _transitionCompleter?.complete();
        _transitionCompleter = null;
      }
    }

    /// True when at least one alarm is eligible RIGHT NOW (enabled and inside
    /// its schedule window). This — not plain isActive — decides whether the
    /// GPS stream should run. The service's own lifecycle stays keyed on
    /// plain isActive and is driven from the UI side, unchanged.
    bool hasScheduleEligibleAlarm() => _scheduleEligibleAlarms(monitoredAlarms).isNotEmpty;

    /// Min distance from [position] over currently eligible alarms
    /// (infinity when none).
    double minDistanceToEligibleAlarms(Position position) {
      double minDistance = double.infinity;
      for (var alarm in _scheduleEligibleAlarms(monitoredAlarms)) {
        final dist = LocationUtils.calculateDistance(
          position.latitude,
          position.longitude,
          (alarm['targetLat'] as num).toDouble(),
          (alarm['targetLng'] as num).toDouble(),
        );
        if (dist < minDistance) minDistance = dist;
      }
      return minDistance;
    }

    /// Keeps the UI isolate in sync with the in-memory mute set (re-emitted
    /// on every updateAlarms too, so a freshly-started UI catches up).
    void emitMutedAlarmsChanged() {
      service.invoke('muted_alarms_changed', {'ids': _mutedAlarmIds.toList()});
    }

    /// Shared ring teardown for KAPAT, SUSTUR, and ceiling expiry: cancels
    /// the ceiling timer, the replay gap timer, and the completion listener;
    /// dismisses the alarm notification; stops sound and the continuous
    /// vibration. Does NOT touch alarm state — callers decide OFF vs MUTED.
    Future<void> cleanupRing(String reason) async {
      // Timers/listeners first so nothing can schedule work after stop().
      _ringCeilingTimer?.cancel();
      _ringCeilingTimer = null;
      _ringCeilingAlarmId = null;
      _ringReplayTimer?.cancel();
      _ringReplayTimer = null;
      await _playerCompleteSubscription?.cancel();
      _playerCompleteSubscription = null;
      try {
        await flutterLocalNotificationsPlugin.cancel(0);
      } catch (e) {
        debugPrint("[BG Service] Ring cleanup: notification cancel error ($reason): $e");
      }
      try {
        await _audioPlayer.stop();
      } catch (e) {
        debugPrint("[BG Service] Ring cleanup: audio stop error ($reason): $e");
      }
      try {
        Vibration.cancel();
      } catch (e) {
        debugPrint("[BG Service] Ring cleanup: vibration cancel error ($reason): $e");
      }
    }

    /// ACTIVE → MUTED. In-memory only (see [_mutedAlarmIds] rationale).
    /// Key battery effect: a muted alarm no longer forces the expensive tiers,
    /// so if it was the only eligible alarm the GPS stream stops immediately.
    Future<void> applyMuteAlarm(String id, String reason) async {
      final exists = monitoredAlarms.any((a) => a['id'] == id);
      if (!exists) {
        debugPrint("[BG Service][MUTE] Ignoring mute for unknown alarm $id ($reason).");
        return;
      }
      if (_mutedAlarmIds.contains(id)) return; // idempotent

      _mutedAlarmIds.add(id);
      // Cooldown state is irrelevant for muted alarms (they are skipped
      // structurally); drop it so a later re-arm starts with a clean slate.
      _lastTriggerTimes.remove(id);
      debugPrint("[BG Service][MUTE] Alarm $id MUTED ($reason).");
      emitMutedAlarmsChanged();

      if (!hasScheduleEligibleAlarm() && streamSubscription != null) {
        await _stopStream('last eligible alarm muted');
      }
    }

    /// Unmutes every muted alarm whose distance now exceeds its personal exit
    /// boundary (radius + kMuteExitBuffer). Called on every stream tick AND
    /// from the periodic presence check when no stream is running.
    void evaluateMutedExitsWithFix(Position position) {
      if (_mutedAlarmIds.isEmpty) return;
      final cleared = mutedAlarmsOutsideExitBoundary(
        monitoredAlarms,
        _mutedAlarmIds,
        position.latitude,
        position.longitude,
      );
      if (cleared.isEmpty) return;
      for (final id in cleared) {
        _mutedAlarmIds.remove(id);
        _lastTriggerTimes.remove(id); // re-arm with a fresh cooldown slate
        debugPrint("[BG Service][MUTE] Alarm $id re-armed (left exit boundary).");
      }
      emitMutedAlarmsChanged();
    }

    // Ring-ceiling hook: top-level trigger code → isolate-local mute logic.
    onRingCeilingElapsed = (alarmId) async {
      debugPrint("[BG Service][MUTE] Ring ceiling elapsed for $alarmId.");
      await applyMuteAlarm(alarmId, 'ring ceiling');
      await cleanupRing('ring ceiling');
    };

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        final actionId = response.actionId;
        final alarmId = parseAlarmIdFromPayload(response.payload);
        if (alarmId == null) return;

        switch (actionId) {
          case 'stop_alarm_action':
            // KAPAT → OFF (durable). Ring cleanup first, state change after.
            await cleanupRing('KAPAT (active notification)');
            await StoppedAlarmsQueue.record(alarmId);
            _lastTriggerTimes.remove(alarmId);
            _mutedAlarmIds.remove(alarmId);

            try {
              if (service is AndroidServiceInstance) {
                service.invoke('disableAlarmInDb', {'id': alarmId});
              }
            } catch (e) {
              debugPrint("[BG Service] disableAlarmInDb invoke error: $e");
            }

            for (var alarm in monitoredAlarms) {
              if (alarm['id'] == alarmId) {
                alarm['isActive'] = false;
                debugPrint("[BG Service] Alarm $alarmId disabled in memory (from active notification).");
                break;
              }
            }

            final bool hasScheduleEligibleAlarmNow = hasScheduleEligibleAlarm();
            if (!hasScheduleEligibleAlarmNow) {
              await _stopStream('stopped from active notification');
            }

          case 'mute_alarm_action':
            // SUSTUR → MUTED (in-memory). Same ring cleanup, no durable path.
            await cleanupRing('SUSTUR (active notification)');
            await applyMuteAlarm(alarmId, 'notification action');
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );



    service.on('stop_alarm_from_notification').listen((event) async {
      await cleanupRing('stop_alarm_from_notification');

      final id = parseAlarmIdFromPayload(event?['id'] as String?);
      if (id != null) {
        for (var alarm in monitoredAlarms) {
          if (alarm['id'] == id) {
            alarm['isActive'] = false;
            _lastTriggerTimes.remove(id);
            _mutedAlarmIds.remove(id);
            debugPrint("[BG Service] Alarm $id disabled in memory.");

            try {
              await StoppedAlarmsQueue.record(id);
            } catch (e) {
              debugPrint("[BG Service] BG SharedPreferences Error: $e");
            }

            try {
              if (service is AndroidServiceInstance) {
                service.invoke('disableAlarmInDb', {'id': id});
              }
            } catch (e) {
              debugPrint("[BG Service] disableAlarmInDb invoke error: $e");
            }
            break;
          }
        }
      } else {
        // Stop-ALL: persist every id, not just the in-memory flags, so the
        // disable survives an app restart (previously prefs were skipped here).
        try {
          for (var alarm in monitoredAlarms) {
            final alarmId = alarm['id'];
            if (alarmId is String) {
              await StoppedAlarmsQueue.record(alarmId);
            }
          }
        } catch (e) {
          debugPrint("[BG Service] BG SharedPreferences Error: $e");
        }

        for (var alarm in monitoredAlarms) {
          alarm['isActive'] = false;
          _lastTriggerTimes.remove(alarm['id']);
          try {
            if (service is AndroidServiceInstance) {
              service.invoke('disableAlarmInDb', {'id': alarm['id']});
            }
          } catch (e) {
            debugPrint("[BG Service] disableAlarmInDb invoke error: $e");
          }
        }
        _mutedAlarmIds.clear();
      }
      emitMutedAlarmsChanged();

      final bool hasScheduleEligibleAlarmNow = hasScheduleEligibleAlarm();
      if (!hasScheduleEligibleAlarmNow) {
        await _stopStream('stopped from notification handler');
      }
    });

    // SUSTUR → MUTED: ring cleanup + in-memory mute; NO durable queue write
    // by design (a lost mute costs one re-ring — acceptable per spec).
    service.on('mute_alarm_from_notification').listen((event) async {
      final id = parseAlarmIdFromPayload(event?['id'] as String?);
      if (id == null) return;
      await cleanupRing('mute_alarm_from_notification');
      await applyMuteAlarm(id, 'service event');
    });



    // -----------------------------------------------------------------------
    // startStreamForTier — starts (or restarts) the position stream.
    //
    // Guarantees:
    //   • cancel() is awaited before a new .listen() is attached (no duplicate
    //     ticks or duplicate _checkAlarms() calls during the transition).
    //   • _isTransitioning is true for the entire async gap, so residual events
    //     from the old subscription skip the tier-evaluation block.
    //   • onError is always attached (never silently dropped).
    // -----------------------------------------------------------------------
    Future<void> startStreamForTier(_LocationTier tier) async {
      while (_transitionCompleter != null) {
        await _transitionCompleter!.future;
      }
      _transitionCompleter = Completer<void>();
      _isTransitioning = true;

      try {
        await streamSubscription?.cancel();
        streamSubscription = null;
        _currentTier = tier;

        debugPrint('[BG Service][TIER] Starting stream for tier=${tier.name}');

        streamSubscription = Geolocator.getPositionStream(
          locationSettings: _settingsForTier(tier),
        ).listen(
          (Position? position) {
            if (position == null) return;

            if (kDebugMode) {
              debugPrint('[BG Service] Position: ${position.latitude}, ${position.longitude}');
            }

            // Feed the UI isolate (HomePage) — single shared GPS stream.
            emitPositionUpdate(position);

            // 0. Muted alarms piggyback every tick for their exit boundary
            //    (re-arm when the user leaves radius + exitBuffer).
            evaluateMutedExitsWithFix(position);

            // 1. Compute min distance to the nearest ELIGIBLE alarm (active,
            //    NOT muted, inside window). Shared by _checkAlarms, the
            //    notification display, and the tier-evaluation logic.
            //    Muted alarms are excluded here by construction — this is the
            //    battery fix: a muted nearby alarm cannot force NEAR tier.
            final eligible = _scheduleEligibleAlarms(monitoredAlarms);
            double minDistance = double.infinity;
            String nearestName = '';
            for (var alarm in eligible) {
              final dist = LocationUtils.calculateDistance(
                position.latitude,
                position.longitude,
                (alarm['targetLat'] as num).toDouble(),
                (alarm['targetLng'] as num).toDouble(),
              );
              if (dist < minDistance) {
                minDistance = dist;
                nearestName = alarm['name'] as String;
              }
            }

            // 2. _checkAlarms FIRST — alarm triggering must never be delayed
            //    by tier logic.  A position tick at a tier boundary triggers
            //    the alarm before the stream is restarted.
            _checkAlarms(position, monitoredAlarms, flutterLocalNotificationsPlugin);

            // 3. Throttled foreground-notification text update (max once per 15 s).
            //    This throttle does NOT affect _checkAlarms or _triggerAlarm.
            if (service is AndroidServiceInstance) {
              final now = DateTime.now();
              if (_lastNotificationUpdate == null ||
                  now.difference(_lastNotificationUpdate!) >= _kNotificationThrottle) {
                _lastNotificationUpdate = now;
                final String status = minDistance != double.infinity
                    ? '$nearestName: ${minDistance.toStringAsFixed(0)}m'
                    : 'Konum takibi aktif.';
                service.setForegroundNotificationInfo(
                  title: 'Durakta Uyandır',
                  content: status,
                );
              }
            }

            // 4. Tier evaluation — skipped while a restart is already in flight
            //    or when there are no active alarms (minDistance stays infinity).
            if (_isTransitioning || minDistance == double.infinity) return;

            final targetTier = _computeTier(minDistance, _currentTier);
            if (targetTier != _currentTier) {
              debugPrint(
                '[BG Service][TIER] Tier transition: ${_currentTier.name} → ${targetTier.name} '
                '(distance: ${minDistance.toStringAsFixed(0)}m)',
              );
              // Not awaited intentionally: _isTransitioning is set synchronously
              // at the top of startStreamForTier before any async suspension,
              // so further ticks from this stream skip step 4 until the new
              // subscription is fully in place.
              startStreamForTier(targetTier);
            }
          },
          onError: (e) {
            debugPrint('[BG Service][TIER] Location Stream Error: $e');
          },
        );
      } finally {
        // Mark transition complete only after the new subscription is assigned.
        _isTransitioning = false;
        _transitionCompleter?.complete();
        _transitionCompleter = null;
      }
    }

    // -----------------------------------------------------------------------

    /// Cold-start tracking: immediate fix → tier from actual distance →
    /// alarm check → UI position emit → stream start. Falls back to a fresh
    /// last-known fix, then to the FAR tier. Shared by the updateAlarms
    /// handler and the 60 s schedule-window timer so both take the exact
    /// same path when tracking (re)starts.
    Future<void> startTrackingForEligibleAlarms(String reason) async {
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 10),
          ),
        );
        debugPrint(
          "[BG Service] Immediate position check ($reason): ${position.latitude}, ${position.longitude}",
        );

        final minDistance = minDistanceToEligibleAlarms(position);
        final startTier = minDistance == double.infinity
            ? _LocationTier.far
            : _computeTierDirect(minDistance);

        debugPrint(
          '[BG Service][TIER] Initial tier=${startTier.name} ($reason; '
          'distance: ${minDistance == double.infinity ? "N/A" : "${minDistance.toStringAsFixed(0)}m"})',
        );

        _checkAlarms(position, monitoredAlarms, flutterLocalNotificationsPlugin);
        emitPositionUpdate(position);
        await startStreamForTier(startTier);
      } on TimeoutException {
        debugPrint("[BG Service] Timeout getting immediate position ($reason), attempting last known...");
        final position = await Geolocator.getLastKnownPosition();
        if (position != null) {
          final diff = DateTime.now().difference(position.timestamp);
          if (diff <= const Duration(minutes: 5)) {
            final minDistance = minDistanceToEligibleAlarms(position);
            final startTier = minDistance == double.infinity
                ? _LocationTier.far
                : _computeTierDirect(minDistance);

            _checkAlarms(position, monitoredAlarms, flutterLocalNotificationsPlugin);
            emitPositionUpdate(position);
            await startStreamForTier(startTier);
            return;
          }
          debugPrint("[BG Service] Last known position is too old (${diff.inMinutes} mins). Falling back to FAR.");
        }
        // Fall back to FAR; the first real tick will correct the tier.
        await startStreamForTier(_LocationTier.far);
      } catch (e) {
        debugPrint("[BG Service] Error getting immediate position ($reason): $e");
        await startStreamForTier(_LocationTier.far);
      }
    }

    service.on('stopService').listen((event) {
      debugPrint("[BG Service] Stop requested");
      service.stopSelf();
    });

    service.on('updateSettings').listen((event) {
      debugPrint("[BG Service] 'updateSettings' received: $event");
      if (event != null) {
        if (event.containsKey('sound')) _isSoundEnabled = event['sound'];
        if (event.containsKey('vibration')) _isVibrationEnabled = event['vibration'];
        if (event.containsKey('notification')) _isNotificationEnabled = event['notification'];
        if (event.containsKey('headphoneOnly')) {
          _isHeadphoneOnlyModeEnabled = event['headphoneOnly'];
        }

        debugPrint(
          "[BG Service] Settings updated: Sound=$_isSoundEnabled, Vibe=$_isVibrationEnabled, Note=$_isNotificationEnabled, HeadphoneOnly=$_isHeadphoneOnlyModeEnabled",
        );
      }
    });

    // -----------------------------------------------------------------------
    // Cold-start state hydration (Task B1 fix).
    //
    // Historically the ONLY source of alarm state for this isolate was the UI
    // pushing 'updateAlarms'. That made every cold start (device boot via
    // BootReceiver, process respawn, service restart without the UI) a silent
    // zero-alarm state until a human opened the app.
    //
    // The isolate now hydrates itself from the SAME durable store the UI
    // writes to (via the shared [loadAlarmsFromHive] loader — encrypted Hive,
    // tolerant per-record decode, StoppedAlarmsQueue reconcile) and applies
    // the exact same converge path as a UI push. UI-invoked 'updateAlarms'
    // remains an incremental sync on top, not the initialization path.
    // -----------------------------------------------------------------------

    /// Single convergent path for "new alarm state arrived" — used by BOTH
    /// the UI-pushed 'updateAlarms' event and cold-start self-hydration.
    Future<void> applyAlarmPayload(List<dynamic> rawList, String reason) async {
      monitoredAlarms = List<Map<String, dynamic>>.from(rawList);

      // Reconcile with the durable stop queue: an alarm stopped from a
      // notification must stay disabled even when this payload was built
      // from Hive state that predates the pending disableAlarmInDb write.
      // IDs whose alarm was explicitly re-enabled from the UI have already
      // been purged from the queue by the Bloc, so this cannot fight a
      // fresh user intent.
      try {
        final stoppedAlarms = await StoppedAlarmsQueue.peek();
        if (stoppedAlarms.isNotEmpty) {
          for (final alarm in monitoredAlarms) {
            if (stoppedAlarms.contains(alarm['id'])) {
              alarm['isActive'] = false;
            }
          }
        }
      } catch (e) {
        debugPrint("[BG Service] updateAlarms reconcile error: $e");
      }

      // Muted state is isolate-local (not part of the payload): prune ids
      // whose alarm no longer exists (deleted while muted), keep the rest —
      // a mute survives syncs and dies only with the process.
      _mutedAlarmIds.removeWhere(
        (id) => !monitoredAlarms.any((a) => a['id'] == id),
      );
      emitMutedAlarmsChanged();

      debugPrint("[BG Service] Alarms updated ($reason). Count: ${monitoredAlarms.length}");

      // Keep the self-heal scheduler in sync with engine state (Task B3 fix):
      // precise window-open tick + watchdog chain re-arm. Replace-semantics, so
      // every state change tightens the recovery net to the CURRENT truth — on
      // BOTH branches below (eligible and idle).
      await SelfHealScheduler.syncForAlarms(monitoredAlarms);

      // Eligibility includes the schedule window: a synced schedule takes
      // effect immediately instead of waiting up to 60 s for the timer.
      final bool hasScheduleEligibleAlarmNow = hasScheduleEligibleAlarm();

      if (!hasScheduleEligibleAlarmNow) {
        // No eligible alarms right now (all off, or every active alarm is
        // outside its window) — stop GPS entirely. The cheapest battery
        // state is no stream at all; the schedule timer re-arms tracking
        // when a window opens.
        await _stopStream('no schedule-eligible alarms ($reason)');
        return;
      }

      // At least one eligible alarm: cold-start tier evaluation.
      await startTrackingForEligibleAlarms(reason);
    }

    service.on('updateAlarms').listen((event) async {
      debugPrint("[BG Service] 'updateAlarms' received: $event");
      if (event != null && event['alarms'] != null) {
        try {
          await applyAlarmPayload(event['alarms'] as List<dynamic>, 'updateAlarms');
        } catch (e) {
          debugPrint("[BG Service] updateAlarms handler error: $e");
        }
      }
    });

    // Cold-start self-hydration (boot / respawn / revive without UI). After
    // this point the isolate is self-sufficient; the next UI 'updateAlarms'
    // is only an incremental sync.
    try {
      final hydrated = await loadAlarmsFromHive();
      if (hydrated.isNotEmpty) {
        debugPrint('[BG Service] Hydrated ${hydrated.length} alarms from Hive (cold start).');
        await applyAlarmPayload(hydrated, 'hydration (cold start)');
      } else {
        debugPrint('[BG Service] Hydration found no persisted alarms (cold start).');
      }
    } catch (e) {
      debugPrint('[BG Service] Hydration failed: $e');
    }

    // -----------------------------------------------------------------------
    // Periodic engine timer (60 s). One Timer, two cadences:
    //   EVERY tick (clock-only, free):
    //     • clear MUTED flags of scheduled alarms whose window just closed
    //       (next window starts fresh even if the user never left the area);
    //     • eligible && !streaming → window opened: cold-start tracking;
    //     • !eligible && streaming → last window closed: stop GPS.
    //   EVERY Nth tick (~5 min, ONLY when muted alarms exist and no stream is
    //     running for other reasons): one-shot position fetch to evaluate
    //     muted alarms' exit boundaries. If a stream IS already running (any
    //     other ACTIVE alarm), ticks cover it and no extra GPS is used.
    // Skips while a stream restart is mid-flight; guarded against re-entry.
    // -----------------------------------------------------------------------
    bool scheduleTickRunning = false;
    int engineTickCount = 0;
    Timer.periodic(const Duration(seconds: 60), (_) async {
      if (scheduleTickRunning || _isTransitioning) return;
      scheduleTickRunning = true;
      try {
        engineTickCount++;

        // (a) Window-close mute reset — clock-only.
        final closedWindowMutes = mutedAlarmsWithClosedWindow(
          monitoredAlarms,
          _mutedAlarmIds,
          DateTime.now(),
        );
        if (closedWindowMutes.isNotEmpty) {
          for (final id in closedWindowMutes) {
            _mutedAlarmIds.remove(id);
            _lastTriggerTimes.remove(id);
            debugPrint('[BG Service][MUTE] Alarm $id unmuted (schedule window closed).');
          }
          emitMutedAlarmsChanged();
        }

        // (b) Schedule-window transitions — clock-only.
        final bool nowEligible = hasScheduleEligibleAlarm();
        final bool streaming = streamSubscription != null;

        if (nowEligible && !streaming) {
          debugPrint('[BG Service][SCHEDULE] Window opened — starting tracking.');
          await startTrackingForEligibleAlarms('schedule window opened');
        } else if (!nowEligible && streaming) {
          debugPrint('[BG Service][SCHEDULE] Window closed — stopping tracking.');
          await _stopStream('schedule window closed');
        }

        // (c) Muted presence check — Nth tick, one-shot, only without a stream.
        if (engineTickCount % _kMutePresenceCheckEveryTicks == 0 &&
            _mutedAlarmIds.isNotEmpty &&
            streamSubscription == null &&
            !_isTransitioning) {
          debugPrint('[BG Service][MUTE] Presence check: evaluating muted exits...');
          try {
            final position = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.medium,
                timeLimit: Duration(seconds: 10),
              ),
            );
            evaluateMutedExitsWithFix(position);
            // Re-arm may have just made an alarm eligible: wake tracking.
            if (streamSubscription == null && hasScheduleEligibleAlarm()) {
              await startTrackingForEligibleAlarms('mute exit (presence check)');
            }
          } catch (e) {
            debugPrint('[BG Service][MUTE] Presence check position error: $e');
          }
        }
      } catch (e) {
        debugPrint('[BG Service][SCHEDULE] Tick error: $e');
      } finally {
        scheduleTickRunning = false;
      }
    });

    // Stream is NOT started here unconditionally.
    // It starts when 'updateAlarms' arrives with at least one schedule-eligible
    // alarm, or later when the timer above sees a window open.
  } catch (e, stack) {
    debugPrint("[BG Service] CRITICAL ERROR IN ONSTART: $e");
    debugPrint(stack.toString());
  }
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

Future<void> _checkAlarms(
  Position position,
  List<Map<String, dynamic>> alarms,
  FlutterLocalNotificationsPlugin notificationPlugin,
) async {
  // Only schedule-eligible alarms can trigger (active AND inside window).
  for (var alarm in _scheduleEligibleAlarms(alarms)) {
    final double targetLat = (alarm['targetLat'] as num).toDouble();
    final double targetLng = (alarm['targetLng'] as num).toDouble();
    final double radius = (alarm['triggerRadiusInMeters'] as num?)?.toDouble() ?? 500.0;

    final double distance = LocationUtils.calculateDistance(
      position.latitude,
      position.longitude,
      targetLat,
      targetLng,
    );

    final alarmId = alarm['id'] as String;
    final lastTime = _lastTriggerTimes[alarmId];
    final bool canTrigger = lastTime == null ||
        DateTime.now().difference(lastTime).inMinutes >= 1;

    if (distance <= radius && canTrigger) {
      debugPrint("[BG Service] !!! TRIGGERING ALARM for '${alarm['name']}' !!!");
      _lastTriggerTimes[alarmId] = DateTime.now();

      try {
        await _triggerAlarm(alarm, notificationPlugin);
      } catch (e) {
        debugPrint("[BG Service] TRIGGER FAILED: $e");
      }
    }
  }
}

Future<void> _triggerAlarm(
  Map<String, dynamic> alarm,
  FlutterLocalNotificationsPlugin notificationPlugin,
) async {
  if (_isSoundEnabled) {
    bool playOnMediaChannel = false;

    if (_isHeadphoneOnlyModeEnabled) {
      debugPrint("[BG Service] Headphone Mode ON. Checking devices...");
      try {
        final session = await AudioSession.instance;
        await session.configure(const AudioSessionConfiguration.music());

        final devices = await session.getDevices();

        bool isHeadphonesConnected = false;
        for (var device in devices) {
          if (device.type == AudioDeviceType.wiredHeadset ||
              device.type == AudioDeviceType.bluetoothA2dp ||
              device.type == AudioDeviceType.bluetoothSco) {
            isHeadphonesConnected = true;
            break;
          }
        }

        debugPrint("[BG Service] Headphones Connected: $isHeadphonesConnected");

        if (isHeadphonesConnected) {
          playOnMediaChannel = true;
          debugPrint("[BG Service] Routing to Media Channel.");
        } else {
          debugPrint("[BG Service] Routing to Alarm Channel.");
        }
      } catch (e) {
        debugPrint("[BG Service] Error checking audio devices: $e");
      }
    }

    try {
      // Reset loop state from any previous ring before starting this one.
      _ringReplayTimer?.cancel();
      _ringReplayTimer = null;
      await _playerCompleteSubscription?.cancel();
      _playerCompleteSubscription = null;

      await _audioPlayer.stop();

      await _audioPlayer.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            usageType: playOnMediaChannel ? AndroidUsageType.media : AndroidUsageType.alarm,
            contentType: AndroidContentType.music,
            audioFocus: AndroidAudioFocus.gainTransientExclusive,
          ),
          iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
        ),
      );

      // One-shot release mode on purpose: looping is orchestrated Dart-side
      // (complete → 5 s gap → replay) so the gap itself is cancellable via
      // cleanupRing instead of relying on platform looping.
      await _audioPlayer.setReleaseMode(ReleaseMode.stop);
      await _audioPlayer.play(AssetSource('sounds/alarm.mp3'));

      _playerCompleteSubscription = _audioPlayer.onPlayerComplete.listen((_) {
        debugPrint('[BG Service] Ring loop: playback completed; replay in ${_kRingReplayGap.inSeconds}s.');
        _ringReplayTimer?.cancel();
        _ringReplayTimer = Timer(_kRingReplayGap, () {
          debugPrint('[BG Service] Ring loop: replaying alarm sound.');
          _audioPlayer.play(AssetSource('sounds/alarm.mp3')).catchError((Object e) {
            debugPrint('[BG Service] Ring loop replay error: $e');
          });
        });
      }, onError: (Object e) {
        debugPrint('[BG Service] Ring loop player stream error: $e');
      });
    } catch (e) {
      debugPrint("[BG Service] Error playing sound: $e");
    }
  }

  if (_isVibrationEnabled) {
    try {
      if (await Vibration.hasVibrator()) {
        // repeat: 0 loops the pattern continuously for the whole ring cycle
        // (independent of the sound loop's 5 s gaps) until cleanupRing()'s
        // Vibration.cancel().
        if (await Vibration.hasCustomVibrationsSupport()) {
          Vibration.vibrate(
            pattern: const [500, 1000, 500, 1000],
            intensities: const [0, 255, 0, 255],
            repeat: 0,
          );
        } else {
          Vibration.vibrate(pattern: const [500, 1000, 500, 1000], repeat: 0);
        }
      }
    } catch (e) {
      debugPrint("[BG Service] Error vibrating: $e");
    }
  }

  if (_isNotificationEnabled) {
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'alarm_channel',
      'ALARM CHANNEL',
      channelDescription: 'Channel for alarm notifications',
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: true,
      playSound: false,
      enableVibration: false,
      actions: <AndroidNotificationAction>[
        // SUSTUR: silence this visit (MUTED); re-arms on exit boundary.
        AndroidNotificationAction(
          'mute_alarm_action',
          'SUSTUR',
          cancelNotification: true,
          showsUserInterface: false,
        ),
        // KAPAT: fully disable (OFF); durable via StoppedAlarmsQueue.
        // actionId kept as 'stop_alarm_action' — durable-queue logic keyed
        // on it is intentionally untouched.
        AndroidNotificationAction(
          'stop_alarm_action',
          'KAPAT',
          cancelNotification: true,
          showsUserInterface: false,
        ),
      ],
    );

    const NotificationDetails platformChannelSpecifics = NotificationDetails(
      android: androidPlatformChannelSpecifics,
    );

    await notificationPlugin.show(
      0,
      'Durağa Yaklaştınız!',
      '${alarm['name']} konumuna vardınız.',
      platformChannelSpecifics,
      // Small JSON payload so the cold dispatcher isolate can act on the
      // correct alarm without live isolate state (parseAlarmIdFromPayload
      // also tolerates legacy bare-id payloads).
      payload: jsonEncode({'id': alarm['id']}),
    );
  }

  // Ring-ceiling: if neither KAPAT nor SUSTUR is pressed within the ceiling,
  // the ring auto-transitions this alarm to MUTED (not just "stops ringing").
  _ringCeilingTimer?.cancel();
  _ringCeilingAlarmId = alarm['id'] as String;
  final ceilingId = _ringCeilingAlarmId!;
  _ringCeilingTimer = Timer(_kRingCeilingDuration, () {
    onRingCeilingElapsed?.call(ceilingId);
  });

  debugPrint("[BG Service] Alarm sequence completed for ${alarm['name']}");
}

class BackgroundLocationService {
  static final FlutterBackgroundService _service = FlutterBackgroundService();

  static Future<void> initializeService() async {
    const AndroidNotificationChannel channel = AndroidNotificationChannel(
      'my_foreground',
      'MY FOREGROUND SERVICE',
      description: 'This channel is used for important notifications.',
      importance: Importance.low,
    );

    final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
        FlutterLocalNotificationsPlugin();

    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      // The stop action can be delivered to EITHER the main engine or a
      // background dispatcher engine depending on app state; register the
      // same handler here so no delivery path lands on a null callback.
      // The handler is idempotent (contains-check on the prefs queue),
      // and the service isolate has its own richer handler for the live path.
      onDidReceiveNotificationResponse: notificationTapBackground,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    const AndroidNotificationChannel alarmChannel = AndroidNotificationChannel(
      'alarm_channel',
      'ALARM CHANNEL',
      description: 'Channel for alarm notifications',
      importance: Importance.max,
      playSound: false,
      enableVibration: false,
    );

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(alarmChannel);

    // Self-heal net (Task B3 fix): alarmClock watchdog chain + WorkManager
    // periodic backstop, both funneling into selfHealTick. Re-armed on every
    // app start here; chained after each fire inside the tick itself.
    await SelfHealScheduler.initialize();
    await SelfHealScheduler.scheduleWatchdogTick();

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        // Restarts the foreground service after reboot / package replace via
        // the plugin's BootReceiver (exempted types only: location FGS from
        // BOOT_COMPLETED is legitimate at targetSdk 34+). The isolate now
        // self-hydrates alarms from Hive on cold start, so a boot-revival
        // without the UI is a FULL recovery, not an empty shell.
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: 'my_foreground',
        initialNotificationTitle: 'Durakta Uyandır',
        initialNotificationContent: 'Konum takibi başlatılıyor...',
        foregroundServiceNotificationId: 888,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  static Future<bool> startService() async {
    debugPrint("[BG Service] Requesting startService()...");

    if (!await Permission.location.isGranted) {
      debugPrint("[BG Service] Permission denied. Aborting startService.");
      return false;
    }

    if (await _service.isRunning()) {
      debugPrint("[BG Service] Service already running.");
      return true;
    }

    await _service.startService();

    for (int i = 0; i < 15; i++) {
      if (await _service.isRunning()) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return true;
  }

  static Future<void> stopService() async {
    _service.invoke("stopService");
  }

  static Future<void> updateAlarms(List<DestinationAlarm> alarms) async {
    debugPrint("[BG Service Request] Updating alarms: ${alarms.length}");
    // Shared with the isolate's cold-start hydration — one wire shape.
    final alarmsJson = alarms.map(destinationAlarmToServicePayload).toList();

    _service.invoke("updateAlarms", {'alarms': alarmsJson});
  }

  static Future<void> updateSettings(Map<String, dynamic> settings) async {
    debugPrint("[BG Service Request] Updating settings: $settings");
    _service.invoke("updateSettings", settings);
  }
}

/// The single position-fix contract shared between the background service
/// isolate (publisher) and the UI isolate (consumer). Emitted via the
/// 'position_update' channel so UI surfaces never open their own GPS stream.
class LivePosition extends Equatable {
  final double latitude;
  final double longitude;
  final double speed;
  final DateTime timestamp;

  const LivePosition({
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.timestamp,
  });

  factory LivePosition.fromEvent(Map<String, dynamic> event) {
    return LivePosition(
      latitude: (event['latitude'] as num).toDouble(),
      longitude: (event['longitude'] as num).toDouble(),
      speed: (event['speed'] as num?)?.toDouble() ?? 0.0,
      timestamp: DateTime.tryParse(event['timestamp'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  List<Object?> get props => [latitude, longitude, speed, timestamp];
}
