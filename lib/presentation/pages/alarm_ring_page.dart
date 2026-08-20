import 'dart:convert';

import 'package:durakta_uyandir/core/services/background_service.dart';
import 'package:durakta_uyandir/core/utils/schedule_utils.dart';
import 'package:durakta_uyandir/data/datasources/alarm_local_data_source.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Full-screen ringing surface shown when the alarm's full-screen intent
/// delivers to MainActivity (locked/over-lockscreen path) or when the user
/// taps the ringing notification body with the app already running.
///
/// Both buttons funnel through the SAME convergent handler the notification
/// actions use ([notificationTapBackground]) with fabricated action
/// responses, so the UI's KAPAT/SUSTUR semantics can never drift from the
/// notification's — including the durable-stops-first ordering and the
/// process-death-safe queue write.
class AlarmRingPage extends StatelessWidget {
  final String alarmId;
  final String? alarmName;

  const AlarmRingPage({super.key, required this.alarmId, this.alarmName});

  /// Alarm name is not part of the notification payload — resolve it from
  /// the durable store so the lone-survivor case (process-dead ring) still
  /// shows the stop's name.
  Future<String?> _resolveAlarmName() async {
    try {
      await Hive.initFlutter();
      final dataSource = AlarmLocalDataSourceImpl();
      await dataSource.init();
      final alarms = await dataSource.getAlarmsTolerant();
      for (final alarm in alarms) {
        if (alarm.id == alarmId) return alarm.name;
      }
    } catch (_) {}
    return null;
  }

  static NotificationResponse _fabricated(String actionId, String alarmId) {
    return NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      id: 0,
      actionId: actionId,
      payload: jsonEncode({'id': alarmId}),
    );
  }

  Future<void> _stop(BuildContext context) async {
    await notificationTapBackground(_fabricated('stop_alarm_action', alarmId));
    if (context.mounted) Navigator.of(context).maybePop();
  }

  Future<void> _mute(BuildContext context) async {
    await notificationTapBackground(_fabricated('mute_alarm_action', alarmId));
    if (context.mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A0E2E),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.alarm, color: Color(0xFFFFB300), size: 96),
                const SizedBox(height: 32),
                Text(
                  'ring.title'.tr(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                FutureBuilder<String?>(
                  future: _resolveAlarmName(),
                  builder: (context, snapshot) {
                    final name = snapshot.data ?? alarmName ?? '';
                    return Text(
                      'ring.arrived'.tr(args: [name]),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 20),
                    );
                  },
                ),
                const SizedBox(height: 64),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton(
                    onPressed: () => _stop(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    child: Text('ring.stop'.tr()),
                  ),
                ),
                const SizedBox(height: 48),
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: OutlinedButton(
                    onPressed: () => _mute(context),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white54, width: 2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      foregroundColor: Colors.white,
                      textStyle: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    child: Text('ring.mute'.tr()),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'ring.mute_hint'.tr(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Navigation hook shared by the cold-start (getNotificationAppLaunchDetails)
/// and warm (onDidReceiveNotificationResponse with SELECT_NOTIFICATION)
/// paths. Guards against double navigation when both fire for one ring.
class AlarmRingNavigator {
  AlarmRingNavigator._();

  static String? _openedFor;

  /// Current mounted navigator context supplier, registered by MainPage.
  static BuildContext? Function()? contextProvider;

  static void maybeOpenForPayload(String? payload, String? alarmName) {
    final alarmId = parseAlarmIdFromPayload(payload);
    if (alarmId == null) return;
    if (_openedFor == alarmId) return;
    final ctx = contextProvider?.call();
    if (ctx == null) return;
    _openedFor = alarmId;
    Navigator.of(ctx).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AlarmRingPage(alarmId: alarmId, alarmName: alarmName),
      ),
    ).whenComplete(() {
      if (_openedFor == alarmId) _openedFor = null;
    });
  }

  static void reset() {
    _openedFor = null;
  }
}
