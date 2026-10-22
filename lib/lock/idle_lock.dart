import 'dart:async';

import '../vault/vault_types.dart';

/// Pure inactivity rules with an injected wall clock and process timer.
///
/// The monotonic [elapsed] reading is the authority: it keeps counting while the
/// OS delays timers in the background, and it cannot be moved by changing the
/// system clock. The wall clock supplies [deadline], covers a sleep that froze
/// the process timer, and detects a backwards jump, which locks instead of
/// granting a longer session.
class IdleLock {
  IdleLock({
    required DateTime Function() now,
    required Duration Function() elapsed,
    required Future<void> Function() onLock,
  }) : _now = now, // ignore: prefer_initializing_formals
       _elapsed = elapsed, // ignore: prefer_initializing_formals
       _onLock = onLock; // ignore: prefer_initializing_formals

  final DateTime Function() _now;
  final Duration Function() _elapsed;
  final Future<void> Function() _onLock;

  AutoLockMode _mode = AutoLockMode.oneMinute;
  DateTime? _lastActivityAt;
  Duration? _lastActivityElapsed;
  Timer? _timer;
  bool _locked = false;
  bool _disposed = false;

  AutoLockMode get mode => _mode;

  /// End of the current window, or `null` for [AutoLockMode.immediately] and
  /// before the first activity of a session.
  DateTime? get deadline {
    final at = _lastActivityAt;
    if (at == null || _mode == AutoLockMode.immediately) return null;
    return at.add(_duration);
  }

  Duration get _duration => switch (_mode) {
    AutoLockMode.immediately => Duration.zero,
    AutoLockMode.oneMinute => const Duration(minutes: 1),
    AutoLockMode.fiveMinutes => const Duration(minutes: 5),
    AutoLockMode.tenMinutes => const Duration(minutes: 10),
  };

  /// Applies [mode] and starts a fresh window, as when a session becomes
  /// lockable again after an unlock or a successful recovery.
  void setMode(AutoLockMode mode) {
    if (_disposed) return;
    _mode = mode;
    _locked = false;
    _lastActivityAt = _now();
    _lastActivityElapsed = _elapsed();
    _timer?.cancel();
    _timer = null;
    if (mode != AutoLockMode.immediately) _arm();
  }

  /// Real user input only: typing, tap, drag or scroll. Background work, a
  /// rebuild or a lifecycle event must never call this.
  void activity() {
    if (_disposed || _locked) return;
    _lastActivityAt = _now();
    _lastActivityElapsed = _elapsed();
    _timer?.cancel();
    _timer = null;
    if (_mode != AutoLockMode.immediately) _arm();
  }

  /// Leaving the app locks at once for [AutoLockMode.immediately]; the timed
  /// modes keep counting and are rechecked on return. Returning is not
  /// activity, so a deadline that passed while away still fires first.
  Future<void> focusChanged(bool focused) async {
    if (_disposed) return;
    if (!focused) {
      if (_mode == AutoLockMode.immediately) await _fire();
      return;
    }
    await checkDeadline();
  }

  Future<void> checkDeadline() async {
    if (_disposed || _locked || _mode == AutoLockMode.immediately) return;
    final lastAt = _lastActivityAt;
    final lastElapsed = _lastActivityElapsed;
    if (lastAt == null || lastElapsed == null) return;
    final wall = _now();
    // A clock that moved backwards could otherwise extend the window forever.
    final anomaly = wall.isBefore(lastAt);
    // The process timer can stop during deep sleep, so the wall clock also has
    // to agree that the window is still open.
    final overdue =
        _elapsed() - lastElapsed >= _duration ||
        wall.difference(lastAt) >= _duration;
    if (anomaly || overdue) {
      await _fire();
      return;
    }
    _arm();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    _timer?.cancel();
    final lastElapsed = _lastActivityElapsed;
    final lastAt = _lastActivityAt;
    if (lastElapsed == null || lastAt == null) return;
    final monotonic = _duration - (_elapsed() - lastElapsed);
    final wall = _duration - _now().difference(lastAt);
    final remaining = monotonic < wall ? monotonic : wall;
    _timer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _timer = null;
      unawaited(checkDeadline().catchError((Object _) {}));
    });
  }

  Future<void> _fire() async {
    if (_locked) return;
    _locked = true;
    _timer?.cancel();
    _timer = null;
    await _onLock();
  }
}
