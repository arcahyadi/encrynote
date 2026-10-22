import 'package:flutter_test/flutter_test.dart';
import 'package:hello_flutter/lock/idle_lock.dart';
import 'package:hello_flutter/vault/vault_types.dart';

/// Clock-controlled rules for inactivity locking.
///
/// The wall clock and the monotonic process timer are advanced together by the
/// test, so a passing case means the lock used its injected inputs rather than
/// a real timer.
void main() {
  late DateTime now;
  late Duration elapsed;
  late int lockCalls;
  late IdleLock lock;

  setUp(() {
    now = DateTime.utc(2026, 10, 22, 12);
    elapsed = Duration.zero;
    lockCalls = 0;
    lock = IdleLock(
      now: () => now,
      elapsed: () => elapsed,
      onLock: () async => lockCalls++,
    );
    addTearDown(lock.dispose);
  });

  void advance(Duration duration) {
    now = now.add(duration);
    elapsed += duration;
  }

  test('one minute locks exactly at the boundary, not before', () async {
    lock.setMode(AutoLockMode.oneMinute);
    lock.activity();
    advance(const Duration(seconds: 59));
    await lock.checkDeadline();
    expect(lockCalls, 0);

    advance(const Duration(seconds: 1));
    await lock.checkDeadline();
    expect(lockCalls, 1);
  });

  for (final (mode, duration) in [
    (AutoLockMode.fiveMinutes, const Duration(minutes: 5)),
    (AutoLockMode.tenMinutes, const Duration(minutes: 10)),
  ]) {
    test('${mode.name} locks at its exact boundary', () async {
      lock.setMode(mode);
      lock.activity();
      advance(duration - const Duration(seconds: 1));
      await lock.checkDeadline();
      expect(lockCalls, 0);

      advance(const Duration(seconds: 1));
      await lock.checkDeadline();
      expect(lockCalls, 1);
    });
  }

  test('activity restarts the deadline', () async {
    lock.setMode(AutoLockMode.oneMinute);
    lock.activity();
    advance(const Duration(seconds: 40));
    lock.activity();
    advance(const Duration(seconds: 40));
    await lock.checkDeadline();
    expect(lockCalls, 0);

    advance(const Duration(seconds: 20));
    await lock.checkDeadline();
    expect(lockCalls, 1);
  });

  test('background time counts even without activity', () async {
    lock.setMode(AutoLockMode.oneMinute);
    lock.activity();
    advance(const Duration(minutes: 3));
    await lock.checkDeadline();
    expect(lockCalls, 1);
  });

  test('immediately ignores elapsed time and locks on focus loss', () async {
    lock.setMode(AutoLockMode.immediately);
    lock.activity();
    advance(const Duration(hours: 1));
    await lock.checkDeadline();
    expect(lockCalls, 0, reason: 'Immediately is about leaving the app');

    await lock.focusChanged(false);
    expect(lockCalls, 1);
    expect(lock.deadline, isNull);
  });

  test('focus gain before the deadline does not reset it', () async {
    lock.setMode(AutoLockMode.oneMinute);
    lock.activity();
    advance(const Duration(seconds: 30));
    await lock.focusChanged(false);
    advance(const Duration(seconds: 20));
    await lock.focusChanged(true);
    expect(lockCalls, 0);

    advance(const Duration(seconds: 10));
    await lock.checkDeadline();
    expect(lockCalls, 1);
  });

  test('resume past the deadline locks before activity can reset it', () async {
    lock.setMode(AutoLockMode.oneMinute);
    lock.activity();
    await lock.focusChanged(false);
    advance(const Duration(minutes: 2));

    await lock.focusChanged(true);
    expect(lockCalls, 1);

    lock.activity();
    await lock.checkDeadline();
    expect(lockCalls, 1, reason: 'a fired lock cannot be revived by input');
  });

  test('a wall-clock jump past the deadline locks without a timer', () async {
    lock.setMode(AutoLockMode.oneMinute);
    lock.activity();
    // Deep sleep: the wall clock moves, the process timer does not.
    now = now.add(const Duration(minutes: 2));
    await lock.checkDeadline();
    expect(lockCalls, 1);
  });

  test(
    'a backwards clock jump locks instead of extending the session',
    () async {
      lock.setMode(AutoLockMode.tenMinutes);
      lock.activity();
      now = now.subtract(const Duration(hours: 1));
      await lock.checkDeadline();
      expect(lockCalls, 1);
    },
  );

  test('the deadline is the last activity plus the mode duration', () async {
    lock.setMode(AutoLockMode.fiveMinutes);
    lock.activity();
    expect(lock.deadline, now.add(const Duration(minutes: 5)));

    advance(const Duration(seconds: 30));
    lock.activity();
    expect(lock.deadline, now.add(const Duration(minutes: 5)));
  });

  test('a deadline fires once and a disposed lock ignores input', () async {
    lock.setMode(AutoLockMode.oneMinute);
    lock.activity();
    advance(const Duration(minutes: 2));
    await lock.checkDeadline();
    await lock.checkDeadline();
    await lock.focusChanged(false);
    expect(lockCalls, 1);

    lock.dispose();
    lock.activity();
    advance(const Duration(minutes: 2));
    await lock.checkDeadline();
    expect(lockCalls, 1);
  });
}
