import 'package:durakta_uyandir/core/utils/schedule_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Fixed anchor: 2024-01-01 is a Monday (weekday == 1).
  final monday = DateTime(2024, 1, 1);

  Map<String, dynamic> scheduledAlarm({
    List<int>? days,
    String? start = '08:00',
    String? end = '18:00',
  }) {
    return {
      'isScheduled': true,
      'scheduledDays': days ?? [1],
      'startTime': start,
      'endTime': end,
    };
  }

  group('parseHHmm', () {
    test('parses padded and non-padded times', () {
      expect(parseHHmm('08:30'), 8 * 60 + 30);
      expect(parseHHmm('7:05'), 7 * 60 + 5);
      expect(parseHHmm('00:00'), 0);
      expect(parseHHmm('23:59'), 23 * 60 + 59);
    });    test('rejects malformed and out-of-range input', () {
      expect(parseHHmm(null), isNull);
      expect(parseHHmm(''), isNull);
      expect(parseHHmm('8.30'), isNull);
      expect(parseHHmm('24:00'), isNull);
      expect(parseHHmm('12:60'), isNull);
      expect(parseHHmm('a:b'), isNull);
      expect(parseHHmm('08:00:00'), isNull);
    });
  });

  group('isWithinScheduleWindow — unscheduled passthrough', () {
    test('unscheduled alarms are always within the window', () {
      expect(
        isWithinScheduleWindow(
          isScheduled: false,
          scheduledDays: const {},
          startTime: null,
          endTime: null,
          now: monday,
        ),
        isTrue,
      );
    });

    test('map payload with missing keys (old Hive records) passes through', () {
      expect(isAlarmWithinSchedule(const {}, monday), isTrue);
      expect(isAlarmWithinSchedule(const {'isActive': true}, monday), isTrue);
    });
  });

  group('isWithinScheduleWindow — day matching', () {
    test('a day not in scheduledDays returns false even if the time matches', () {
      expect(
        isWithinScheduleWindow(
          isScheduled: true,
          scheduledDays: const {1}, // Monday only
          startTime: '08:00',
          endTime: '18:00',
          now: DateTime(2024, 1, 2, 12, 0), // Tuesday noon
        ),
        isFalse,
      );
    });

    test('every day of the week matches when selected', () {
      for (var day = 1; day <= 7; day++) {
        final date = monday.add(Duration(days: day - 1));
        expect(date.weekday, day);
        expect(
          isWithinScheduleWindow(
            isScheduled: true,
            scheduledDays: {day},
            startTime: '08:00',
            endTime: '18:00',
            now: DateTime(date.year, date.month, date.day, 12, 0),
          ),
          isTrue,
          reason: 'weekday $day should match',
        );
      }
    });
  });

  group('isWithinScheduleWindow — same-day window boundaries', () {
    bool at(int hour, int minute) => isWithinScheduleWindow(
          isScheduled: true,
          scheduledDays: const {1},
          startTime: '08:00',
          endTime: '18:00',
          now: DateTime(2024, 1, 1, hour, minute),
        );

    test('start edge is INCLUSIVE (08:00 inside, 07:59 outside)', () {
      expect(at(7, 59), isFalse);
      expect(at(8, 0), isTrue);
      expect(at(8, 1), isTrue);
    });

    test('end edge is EXCLUSIVE (17:59 inside, 18:00 outside)', () {
      expect(at(17, 59), isTrue);
      expect(at(18, 0), isFalse);
      expect(at(18, 1), isFalse);
    });
  });

  group('isWithinScheduleWindow — overnight wraparound NOT supported (v1)', () {
    // v1 deliberately rejects/ignores cross-midnight windows (e.g. 22:00–06:00).
    // The UI validates start < end at save time; these tests pin the engine's
    // fail-silent behavior so wraparound is a documented limitation, never a
    // silent bug.
    bool overnightAt(DateTime when) => isWithinScheduleWindow(
          isScheduled: true,
          scheduledDays: const {1, 2},
          startTime: '22:00',
          endTime: '06:00', // end <= start → invalid window in v1
          now: when,
        );

    test('late night on a selected day is OUTSIDE (22:00–06:00 not honored)', () {
      expect(overnightAt(DateTime(2024, 1, 1, 23, 0)), isFalse); // Mon 23:00
    });

    test('early morning on the rollover day is OUTSIDE', () {
      expect(overnightAt(DateTime(2024, 1, 2, 5, 0)), isFalse); // Tue 05:00
    });

    test('an inverted window never matches at any time', () {
      for (var hour = 0; hour < 24; hour++) {
        expect(overnightAt(DateTime(2024, 1, 1, hour, 0)), isFalse, reason: 'hour $hour');
      }
    });
  });

  group('isWithinScheduleWindow — defensive handling of bad config', () {
    test('scheduled with empty day set is outside', () {
      expect(
        isWithinScheduleWindow(
          isScheduled: true,
          scheduledDays: const {},
          startTime: '08:00',
          endTime: '18:00',
          now: DateTime(2024, 1, 1, 12, 0),
        ),
        isFalse,
      );
    });

    test('scheduled with null or malformed times is outside', () {
      for (final times in [
        (null, '18:00'),
        ('08:00', null),
        ('garbage', '18:00'),
        ('08:00', '25:99'),
      ]) {
        expect(
          isWithinScheduleWindow(
            isScheduled: true,
            scheduledDays: const {1},
            startTime: times.$1,
            endTime: times.$2,
            now: DateTime(2024, 1, 1, 12, 0),
          ),
          isFalse,
          reason: 'times ${times.$1}–${times.$2}',
        );
      }
    });
  });

  group('isAlarmWithinSchedule (map payload variant)', () {
    test('reads map payloads like the isolate channel produces', () {
      final alarm = scheduledAlarm(days: [1, 3, 5], start: '09:00', end: '10:00');
      expect(isAlarmWithinSchedule(alarm, DateTime(2024, 1, 1, 9, 30)), isTrue); // Mon
      expect(isAlarmWithinSchedule(alarm, DateTime(2024, 1, 2, 9, 30)), isFalse); // Tue
      expect(isAlarmWithinSchedule(alarm, DateTime(2024, 1, 1, 10, 0)), isFalse); // end excl.
    });

    test('scheduled payload with missing day list behaves as fail-silent', () {
      expect(
        isAlarmWithinSchedule(
          {'isScheduled': true, 'startTime': '08:00', 'endTime': '18:00'},
          DateTime(2024, 1, 1, 12, 0),
        ),
        isFalse,
      );
    });
  });

  group('isScheduleConfigValid (UI save gate)', () {
    test('requires at least one selected day', () {
      expect(
        isScheduleConfigValid(scheduledDays: const {}, startTime: '08:00', endTime: '18:00'),
        isFalse,
      );
    });

    test('requires start strictly before end (no overnight in v1)', () {
      expect(
        isScheduleConfigValid(scheduledDays: const {1}, startTime: '18:00', endTime: '08:00'),
        isFalse,
      );
      expect(
        isScheduleConfigValid(scheduledDays: const {1}, startTime: '08:00', endTime: '08:00'),
        isFalse,
      );
      expect(
        isScheduleConfigValid(scheduledDays: const {1}, startTime: '08:00', endTime: '18:00'),
        isTrue,
      );
    });

    test('rejects missing/malformed times', () {
      expect(isScheduleConfigValid(scheduledDays: const {1}, startTime: null, endTime: '18:00'), isFalse);
      expect(isScheduleConfigValid(scheduledDays: const {1}, startTime: '08:00', endTime: null), isFalse);
    });
  });

  group('nextScheduleWindowOpen', () {
    // Anchor: 2024-01-01 is a Monday (weekday == 1).
    Map<String, dynamic> activeScheduled({
      List<int> days = const [1],
      String start = '08:00',
      String end = '18:00',
      bool isActive = true,
    }) {
      return {
        'isActive': isActive,
        'isScheduled': true,
        'scheduledDays': days,
        'startTime': start,
        'endTime': end,
      };
    }

    test('same-day boundary when window opens later today', () {
      final now = DateTime(2024, 1, 1, 7, 30); // Monday 07:30
      final next = nextScheduleWindowOpen([activeScheduled()], now: now);
      expect(next, DateTime(2024, 1, 1, 8, 0));
    });

    test('next weekday boundary when today is not a scheduled day', () {
      final now = DateTime(2024, 1, 3, 9, 0); // Wednesday 09:00
      final next = nextScheduleWindowOpen([activeScheduled()], now: now);
      expect(next, DateTime(2024, 1, 8, 8, 0)); // next Monday
    });

    test('skips to the NEXT week when today is scheduled but the window already ended', () {
      final now = DateTime(2024, 1, 1, 18, 30); // Monday 18:30 (after end)
      final next = nextScheduleWindowOpen([activeScheduled()], now: now);
      expect(next, DateTime(2024, 1, 8, 8, 0));
    });

    test('unscheduled, inactive, and malformed alarms contribute nothing', () {
      final now = DateTime(2024, 1, 1, 7, 0);
      final alarms = [
        {'isActive': true, 'isScheduled': false}, // always-inside
        activeScheduled(isActive: false), // switched off
        {
          'isActive': true,
          'isScheduled': true,
          'scheduledDays': <int>[],
          'startTime': '08:00',
          'endTime': '18:00',
        }, // no days
        {
          'isActive': true,
          'isScheduled': true,
          'scheduledDays': const [1],
          'startTime': '18:00',
          'endTime': '08:00',
        }, // wraparound invalid
        {
          'isActive': true,
          'isScheduled': true,
          'scheduledDays': const [1],
          'startTime': 'garbage',
          'endTime': '18:00',
        }, // malformed time
      ];
      expect(nextScheduleWindowOpen(alarms, now: now), isNull);
    });

    test('earliest boundary wins across multiple scheduled alarms', () {
      final now = DateTime(2024, 1, 1, 7, 0); // Monday 07:00
      final alarms = [
        activeScheduled(days: const [2], start: '09:00', end: '10:00'), // Tue 09:00
        activeScheduled(days: const [1], start: '08:30', end: '18:00'), // Mon 08:30 (constrain)
        activeScheduled(days: const [1], start: '07:45', end: '18:00'), // Mon 07:45 (minimum)
      ];
      expect(nextScheduleWindowOpen(alarms, now: now), DateTime(2024, 1, 1, 7, 45));
    });

    test('boundary exactly equal to now is NOT a future opening', () {
      final now = DateTime(2024, 1, 1, 8, 0); // window starts NOW
      final next = nextScheduleWindowOpen([activeScheduled()], now: now);
      expect(next, DateTime(2024, 1, 8, 8, 0)); // engine is already live; next opening is next Monday
    });
  });
}
