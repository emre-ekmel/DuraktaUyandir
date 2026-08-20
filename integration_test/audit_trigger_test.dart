import 'package:durakta_uyandir/data/datasources/alarm_local_data_source.dart';
import 'package:durakta_uyandir/data/models/destination_alarm_model.dart';
import 'package:durakta_uyandir/main.dart' as app;
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:permission_handler/permission_handler.dart';

/// AUDIT HARNESS (production-readiness audit, Section 11 manual matrix) —
/// NOT part of V1/V2 App Check rollout. Release after use if desired.
///
/// Goal: end-to-end proof on a real device (target Android 16 / API 36) that
/// the full trigger chain actually fires:
///   seeded ACTIVE alarm at the device's CURRENT position
///   -> AlarmBloc sync -> flutter_background_service FGS + tiered GPS stream
///   -> _checkAlarms -> _triggerAlarm -> flutter_local_notifications.show()
///   -> a REAL posted OS notification on `alarm_channel`.
///
/// This is the path that must never regress silently: FGS type correctness on
/// API 34+, FLN v17 behavior on API 36, POST_NOTIFICATIONS enforcement, and
/// the geolocator stream all sit on it.
///
/// Design notes (mirroring the V2 harness's verified gotchas):
///  - `flutter test` reinstalls the app per run and wipes app data, so runtime
///    permissions CANNOT be pre-granted. The harness prints
///    AWAITING_PERMISSION_GRANT and polls; the HOST must then run
///    `adb shell pm grant com.durakta.uyandir android.permission.ACCESS_FINE_LOCATION`
///    (+ ACCESS_COARSE_LOCATION, POST_NOTIFICATIONS).
///  - The seeded settings pre-disable sound & vibration so the trigger does
///    not make audible noise on the test phone; notification stays ON (it is
///    the assertion target).
///  - Assertion is OS-level truth (NotificationManager active notifications),
///    not a log claim.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'AUDIT: seeded here-alarm triggers a real posted alarm notification (API 36)',
    (tester) async {
      // --- Seed: settings (silent trigger) BEFORE booting the app ----------
      await Hive.initFlutter();
      final settingsBox = await Hive.openBox('settings_box');
      await settingsBox.put('sound_enabled', false);
      await settingsBox.put('vibration_enabled', false);
      await settingsBox.put('notification_enabled', true);
      await settingsBox.put('analytics_enabled', false);

      // --- Permissions: external grant window (same pattern as V2) ---------
      debugPrint('[AUDIT-EVIDENCE] AWAITING_PERMISSION_GRANT');
      var granted = await Permission.location.isGranted;
      for (var i = 0; i < 120 && !granted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        granted = await Permission.location.isGranted;
      }
      debugPrint('[AUDIT-EVIDENCE] permission.location.isGranted=$granted');
      if (!granted) {
        fail('External permission grant never arrived (host must run '
            'adb shell pm grant after the harness installs the app).');
      }

      // --- Seed: one ACTIVE alarm at the device's CURRENT position ---------
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 15),
        ),
      );
      debugPrint(
        '[AUDIT-EVIDENCE] device fix: ${position.latitude}, ${position.longitude} '
        '(accuracy: ${position.accuracy}m)',
      );

      final dataSource = AlarmLocalDataSourceImpl();
      await dataSource.init();
      const seedId = 'audit-here-alarm';
      await dataSource.cacheAlarm(
        DestinationAlarmModel(
          id: seedId,
          name: 'AUDIT here-alarm',
          targetLat: position.latitude,
          targetLng: position.longitude,
          isActive: true,
          triggerRadiusInMeters: 500,
        ),
      );
      debugPrint('[AUDIT-EVIDENCE] seeded active here-alarm ($seedId)');

      // --- Boot the real app --------------------------------------------------
      // Under the live test binding the app renders frames ONLY when the test
      // pumps them: BlocProvider(create:) is lazy, so HomePage's BlocBuilder
      // (and with it AlarmBloc -> LoadAlarms -> startService) never fires
      // until at least a few frames run. But pumpAndSettle must ALSO be
      // avoided: continuously animating widgets (progress/pulse rings) mean
      // "settled" never happens, and each pump interval of the live binding
      // burns real wall-clock time (run B burned its whole budget this way).
      // Compromise: a bounded pump burst drives initial builds + event
      // processing, then real-time waits proceed with no pumping (the native
      // FGS + background isolate run independently of UI frames afterwards).
      app.main();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      // --- Observe: poll the OS for the posted alarm notification (<= 90 s) ---
      final androidPlugin = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      var alarmNotificationSeen = false;
      var lastSeenDescription = 'none';
      for (var i = 0; i < 45 && !alarmNotificationSeen; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final active = await androidPlugin?.getActiveNotifications() ?? [];
        final hit = active.where((n) => n.channelId == 'alarm_channel').toList();
        if (active.isNotEmpty) {
          lastSeenDescription = active
              .map((n) => 'id=${n.id} channel=${n.channelId} title=${n.title}')
              .join(' | ');
        }
        if (hit.isNotEmpty) {
          alarmNotificationSeen = true;
          for (final n in hit) {
            debugPrint(
              '[AUDIT-EVIDENCE] alarm notification POSTED: id=${n.id} '
              'channel=${n.channelId} title=${n.title} body=${n.body}',
            );
          }
        }
      }

      debugPrint(
        '[AUDIT-EVIDENCE] trigger result: posted=$alarmNotificationSeen '
        '(last active set: $lastSeenDescription)',
      );

      // --- Layer-by-layer autopsy (turns a flaky harness run into signal) ----
      // L1: does the app's own read path see the seeded alarm?
      try {
        final readback = await dataSource.getAlarms();
        debugPrint(
          '[AUDIT-EVIDENCE] L1 hive readback: count=${readback.length} '
          'ids=${readback.map((a) => '${a.id}(active=${a.isActive})').toList()}',
        );
      } catch (e) {
        debugPrint('[AUDIT-EVIDENCE] L1 hive readback FAILED: $e');
      }
      // L2: does the native plugin report the foreground service running?
      final running = await FlutterBackgroundService().isRunning();
      debugPrint('[AUDIT-EVIDENCE] L2 serviceRunning=$running');
      // L3: what notifications does the OS currently hold for this app?
      final finalActive = await androidPlugin?.getActiveNotifications() ?? [];
      debugPrint(
        '[AUDIT-EVIDENCE] L3 final active notifications: '
        '${finalActive.map((n) => 'id=${n.id}/ch=${n.channelId}').toList()}',
      );

      // --- Cleanup: remove the seed so a later full app launch is clean -------
      await dataSource.deleteAlarm(seedId);

      expect(
        alarmNotificationSeen,
        isTrue,
        reason: 'The full alarm trigger chain (FGS -> GPS tier engine -> '
            '_checkAlarms -> _triggerAlarm -> notification post) did not '
            'produce an OS-visible alarm notification within 90 s on this device.',
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
