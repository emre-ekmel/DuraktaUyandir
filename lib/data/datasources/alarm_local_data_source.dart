import 'dart:convert';

import 'package:durakta_uyandir/data/models/destination_alarm_model.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

abstract class AlarmLocalDataSource {
  Future<void> init();
  Future<void> cacheAlarm(DestinationAlarmModel alarm);
  Future<void> deleteAlarm(String id);
  Future<List<DestinationAlarmModel>> getAlarms();
  Future<void> updateAlarmStatus(String id, bool isActive);
}

class AlarmLocalDataSourceImpl implements AlarmLocalDataSource {
  static const String _boxName = 'alarms_box';
  static const String _keyName = 'hive_encryption_key';

  Box<String>? _box;
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  @override
  Future<void> init() async {
    String? encryptionKeyStr = await _secureStorage.read(key: _keyName);
    if (encryptionKeyStr == null) {
      final key = Hive.generateSecureKey();
      await _secureStorage.write(key: _keyName, value: base64UrlEncode(key));
      encryptionKeyStr = base64UrlEncode(key);
    }

    final encryptionKeyUint8List = base64Url.decode(encryptionKeyStr);

    _box = await Hive.openBox<String>(
      _boxName,
      encryptionCipher: HiveAesCipher(encryptionKeyUint8List),
    );
  }

  Box<String> get box {
    if (_box == null) {
      throw Exception("AlarmLocalDataSource not initialized. Call init() first.");
    }
    return _box!;
  }

  @override
  Future<void> cacheAlarm(DestinationAlarmModel alarm) async {
    if (alarm.targetLat < -90 ||
        alarm.targetLat > 90 ||
        alarm.targetLng < -180 ||
        alarm.targetLng > 180) {
      throw Exception("Invalid coordinates");
    }

    await box.put(alarm.id, jsonEncode(alarm.toJson()));
  }

  @override
  Future<void> deleteAlarm(String id) async {
    await box.delete(id);
  }

  @override
  Future<List<DestinationAlarmModel>> getAlarms() async {
    return box.values.map((e) => DestinationAlarmModel.fromJson(jsonDecode(e))).toList();
  }

  /// Tolerant read: skips records that fail to decode instead of failing the
  /// whole list. Exists for the background-service cold-start hydration path
  /// (boot/respawn), where one torn record must not leave the engine with
  /// zero alarms. The strict [getAlarms] contract is deliberately unchanged.
  Future<List<DestinationAlarmModel>> getAlarmsTolerant() async {
    final alarms = <DestinationAlarmModel>[];
    for (final raw in box.values) {
      try {
        alarms.add(DestinationAlarmModel.fromJson(jsonDecode(raw)));
      } catch (_) {
        // Corrupt/torn record (e.g. process death mid-write): skip it; the
        // remaining valid alarms must still drive tracking.
      }
    }
    return alarms;
  }

  @override
  Future<void> updateAlarmStatus(String id, bool isActive) async {
    final alarmJson = box.get(id);
    if (alarmJson != null) {
      final alarmMap = jsonDecode(alarmJson) as Map<String, dynamic>;
      alarmMap['isActive'] = isActive;
      await box.put(id, jsonEncode(alarmMap));
    }
  }
}
