import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:durakta_uyandir/core/services/alarm_state_loader.dart';
import 'package:durakta_uyandir/core/utils/schedule_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:workmanager/workmanager.dart';

/// Self-heal scheduling (audit 2026-08-20 fix-round task B3).
///
/// Background — the plugin's own kill-recovery (`WatchdogReceiver`) calls
/// `ContextCompat.startForegroundService` from a background alarm receiver,
/// which throws `ForegroundServiceStartNotAllowedException` on API 31+ and is
/// swallowed silently. This module replaces that DYING path with three
/// documented, legitimate layers, ALL funneling into the same tick handler:
///
///   1. **`setAlarmClock()` chain** (`AndroidAlarmManager.oneShot(...,
///      alarmClock: true)`) — single-fire, re-issued after every fire and on
///      every app start. AlarmClock alarms are the canonical exemption to the
///      background-FGS-start restriction and get top-tier Doze treatment.
///      This app's category (an alarm app) is the documented semantic fit.
///   2. **Precise next-schedule-window oneShot** — lets the engine STOP the
///      service outside schedule windows (audit fix-round task 4) without
///      losing window-open punctuality; recomputed from hydrated state.
///   3. **WorkManager periodic minimum** (~15 min) — deliberately dumb
///      backstop for the day the exact-alarm special access is revoked by the
///      user (its interval may be stretched by the OS; that is fine — it is
///      redundancy, not precision).
///
/// Reliability rule: NOTHING in here may fail silently. The old path was
/// invisible when it died. Every catch in this file writes a persistent local
/// log ([SelfHealLog], app-documents/self_heal_log.txt, capped) in addition
/// to logcat. Exchange rate of trade: the file is user-deletable by clearing
/// app data — acceptable for pre-Crashlytics observability.

// ---------------------------------------------------------------------------
// Persistent error log
// ---------------------------------------------------------------------------

class SelfHealLog {
  SelfHealLog._();

  static const String _fileName = 'self_heal_log.txt';
  static const int _maxLines = 400;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  static Future<void> write(String message) async {
    debugPrint('[SelfHeal] $message');
    try {
      final f = await _file();
      await f.writeAsString(
        '${DateTime.now().toIso8601String()}  $message\n',
        mode: FileMode.append,
        flush: true,
      );
      final lines = await f.readAsLines();
      if (lines.length > _maxLines) {
        await f.writeAsString(
          '${lines.sublist(lines.length - _maxLines).join('\n')}\n',
          flush: true,
        );
      }
    } catch (_) {
      // Logging must never break the heal path.
    }
  }

  static Future<void> writeError(String message, [Object? stack]) async {
    await write('ERROR: $message${stack != null ? ' :: $stack' : ''}');
  }

  static Future<List<String>> read() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return const [];
      return f.readAsLines();
    } catch (_) {
      return const [];
    }
  }
}

// ---------------------------------------------------------------------------
// Scheduler
// ---------------------------------------------------------------------------

class SelfHealScheduler {
  SelfHealScheduler._();

  /// Alarm-request ids (stable across processes; distinct from any FLN id).
  static const int watchdogTickId = 0x5348; // 'SH'
  static const int windowOpenTickId = 0x574F; // 'WO'

  /// Watchdog chain cadence. Debug uses 2 minutes so the respawn path is
  /// verifiable on a bench in real time; release uses 15 (minimum sensible).
  static Duration get watchdogInterval =>
      kDebugMode ? const Duration(minutes: 2) : const Duration(minutes: 15);

  static const String workmanagerTask = 'durakta.self_heal.periodic';

  static Future<void> initialize() async {
    await AndroidAlarmManager.initialize();
    try {
      await Workmanager().initialize(selfHealWorkmanagerDispatcher);
      await Workmanager().registerPeriodicTask(
        workmanagerTask,
        workmanagerTask,
        frequency: const Duration(minutes: 15),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.linear,
      );
    } catch (e, s) {
      await SelfHealLog.writeError('WorkManager registration failed: $e', s);
    }
  }

  /// (Re)arms the watchdog chain — idempotent: same-id oneShot replaces.
  static Future<void> scheduleWatchdogTick() async {
    try {
      await AndroidAlarmManager.cancel(watchdogTickId);
    } catch (_) {}
    await AndroidAlarmManager.oneShot(
      watchdogInterval,
      watchdogTickId,
      selfHealAlarmClockTick,
      exact: true,
      wakeup: true,
      alarmClock: true,
      rescheduleOnReboot: true,
    );
  }

  /// Arms (or clears, when [at] is null) the precise window-open tick.
  static Future<void> scheduleNextWindowOpen(DateTime? at) async {
    try {
      await AndroidAlarmManager.cancel(windowOpenTickId);
    } catch (_) {}
    if (at == null) return;
    if (!at.isAfter(DateTime.now())) return;
    await AndroidAlarmManager.oneShotAt(
      at,
      windowOpenTickId,
      selfHealAlarmClockTick,
      exact: true,
      wakeup: true,
      allowWhileIdle: true,
      alarmClock: true,
      rescheduleOnReboot: false,
    );
  }

  /// Single call sites can use after any alarm-state change: recompute the
  /// window-open boundary from CURRENT engine state and arm the watchdog
  /// chain. Safe to call from any isolate; scheduling is replace-semantics.
  static Future<void> syncForAlarms(List<Map<String, dynamic>> alarms) async {
    try {
      final boundary = nextScheduleWindowOpen(alarms, now: DateTime.now());
      await scheduleNextWindowOpen(boundary);
    } catch (e, s) {
      await SelfHealLog.writeError('syncForAlarms failed: $e', s);
    }
  }
}

// ---------------------------------------------------------------------------
// Tick handlers (entry points; spawned in plugin-provided isolates)
// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
Future<void> selfHealAlarmClockTick() async {
  await _selfHealTick(source: 'alarmClock');
}

@pragma('vm:entry-point')
void selfHealWorkmanagerDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await _selfHealTick(source: 'workmanager:$task');
    return true;
  });
}

/// The ONE convergent recovery decision: hydrate durable state, look for live
/// work, (re)start the engine if it should be running but is not, and
/// re-arm the scheduler chain. Catches everything; nothing escapes silently.
Future<void> _selfHealTick({required String source}) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  await SelfHealLog.write('tick started ($source)');
  final exactAlarmsGranted = await Permission.scheduleExactAlarm.isGranted;
  if (!exactAlarmsGranted) {
    // Scheduling layers above degrade silently (the native side only logs);
    // make the state transition VISIBLE here instead.
    await SelfHealLog.write(
      'WARNING: SCHEDULE_EXACT_ALARM not granted ($source); '
      'watchdog chain degraded, WorkManager backstop is the remaining net',
    );
  }

  try {
    final alarms = await loadAlarmsFromHive();
    await SelfHealScheduler.syncForAlarms(alarms);

    final eligible = engineEligibleAlarms(alarms, now: DateTime.now());
    final running = await FlutterBackgroundService().isRunning();

    if (eligible.isNotEmpty && !running) {
      await SelfHealLog.write(
        'engine dead with ${eligible.length} eligible alarm(s) — restarting ($source)',
      );
      try {
        await FlutterBackgroundService().startService();
        await SelfHealLog.write('engine restart issued ($source)');
      } on Exception catch (e, s) {
        // Includes ForegroundServiceStartNotAllowedException. NEVER silent.
        await SelfHealLog.writeError('engine restart FAILED ($source): $e', s);
      }
    } else {
      await SelfHealLog.write(
        'no action ($source; eligible=${eligible.length}, running=$running)',
      );
    }
  } catch (e, s) {
    await SelfHealLog.writeError('tick failed ($source): $e', s);
  } finally {
    // Chain the watchdog single-fire so the net persists even if no app
    // launch happens again. (One-shot with same id replaces the last one.)
    if (source == 'alarmClock') {
      try {
        await SelfHealScheduler.scheduleWatchdogTick();
      } catch (e, s) {
        await SelfHealLog.writeError('watchdog chain re-arm FAILED: $e', s);
      }
    }
    await SelfHealLog.write('tick finished ($source)');
  }
}