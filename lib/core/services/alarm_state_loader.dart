import 'package:durakta_uyandir/core/utils/schedule_utils.dart';
import 'package:durakta_uyandir/core/utils/stopped_alarms_queue.dart';
import 'package:durakta_uyandir/data/datasources/alarm_local_data_source.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Shared durable-state loader, callable from ANY isolate (background service,
/// android_alarm_manager callback dispatcher, WorkManager worker, UI).
///
/// Reads the encrypted Hive box (tolerant per-record decode so one torn record
/// cannot zero the result) and reconciles the durable StoppedAlarmsQueue, so
/// every cold-start path sees the SAME state the UI would push. Returns
/// service-payload maps ([destinationAlarmToServicePayload] shape).
Future<List<Map<String, dynamic>>> loadAlarmsFromHive() async {
  await Hive.initFlutter();
  final dataSource = AlarmLocalDataSourceImpl();
  await dataSource.init();
  final models = await dataSource.getAlarmsTolerant();
  final payloads = models.map(destinationAlarmToServicePayload).toList();

  try {
    final stoppedAlarms = await StoppedAlarmsQueue.peek();
    if (stoppedAlarms.isNotEmpty) {
      for (final alarm in payloads) {
        if (stoppedAlarms.contains(alarm['id'])) {
          alarm['isActive'] = false;
        }
      }
    }
  } catch (e) {
    debugPrint('[AlarmStateLoader] reconcile error: $e');
  }
  return payloads;
}
