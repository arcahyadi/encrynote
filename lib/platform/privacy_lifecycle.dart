import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../lock/idle_lock.dart';
import '../lock/privacy_signals.dart';
import '../session/note_session.dart';
import '../vault/vault_types.dart';
import 'native_bridge.dart';

/// Owns the inactivity window and the native privacy shield for the whole app.
///
/// Activity is counted only from real input (pointer, scroll, keys) on the root
/// listener. Lifecycle and focus events are never activity: leaving the app
/// shields at once, and returning checks the deadline before the shield may be
/// removed. The shield stays up until the engine reports a frame rasterized
/// after those checks, so a stale note frame is never revealed on resume.
class PrivacyLifecycle extends StatefulWidget {
  const PrivacyLifecycle({
    super.key,
    required this.session,
    required this.native,
    required this.child,
    this.now,
    this.elapsed,
  });

  final NoteSession session;
  final NativeBridge native;
  final Widget child;

  /// How long a resume waits for a rasterized frame before nudging the engine
  /// and waiting again. It is a retry cadence, never a reason to uncover.
  static const Duration frameWait = Duration(milliseconds: 250);

  /// Clock injection for deterministic tests; production uses the wall clock.
  final DateTime Function()? now;

  /// Monotonic process timer injection; production uses a [Stopwatch].
  final Duration Function()? elapsed;

  @override
  State<PrivacyLifecycle> createState() => _PrivacyLifecycleState();
}

class _PrivacyLifecycleState extends State<PrivacyLifecycle>
    with WidgetsBindingObserver {
  final Stopwatch _stopwatch = Stopwatch()..start();
  final PrivacySignal _activitySignal = PrivacySignal();
  final PrivacySignal _leavingSignal = PrivacySignal();

  IdleLock? _idle;
  StreamSubscription<bool>? _focusEvents;
  bool _focused = true;
  bool _foreground = true;
  bool _resuming = false;
  int _shieldEpoch = 0;
  int _rasterBaseline = 0;
  int _lastRasterFrame = 0;
  VoidCallback? _rasterWait;
  VoidCallback? _cancelFrameWait;
  Future<void> _shieldTail = Future<void>.value();

  NoteSession get _session => widget.session;

  /// A session needs a window while it is open, while a recovery key is held,
  /// or while a frozen save error still exposes a draft and its key.
  bool get _needsWindow =>
      _session.phase == SessionPhase.unlocked ||
      _session.phase == SessionPhase.recovering ||
      (_session.phase == SessionPhase.storageError &&
          _session.holdsSensitiveState);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    HardwareKeyboard.instance.addHandler(_onKey);
    _activitySignal.addListener(_onUserEdit);
    _session.addListener(_onSessionChanged);
    _focusEvents = widget.native.focusChanges.listen(
      _onNativeFocus,
      onError: (Object _) {},
    );
    // A hot restart can leave a cover installed by the previous isolate while
    // the app is already in front; nothing would ever remove it.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
      unawaited(_setShield(false));
    }
    _syncWindow();
  }

  @override
  void didUpdateWidget(PrivacyLifecycle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
      _syncWindow();
    }
    if (oldWidget.native != widget.native) {
      unawaited(_focusEvents?.cancel());
      _focusEvents = widget.native.focusChanges.listen(
        _onNativeFocus,
        onError: (Object _) {},
      );
    }
  }

  @override
  void dispose() {
    _cancelFrameWait?.call();
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _activitySignal.removeListener(_onUserEdit);
    _activitySignal.dispose();
    _leavingSignal.dispose();
    _session.removeListener(_onSessionChanged);
    unawaited(_focusEvents?.cancel());
    _idle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PrivacySignals(
      activity: _activitySignal,
      leavings: _leavingSignal,
      child: _listener(),
    );
  }

  Widget _listener() {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _activity(),
      // A drag or touch-scroll is user input; a mouse merely hovering is not.
      onPointerMove: (event) {
        if (event.buttons != 0) _activity();
      },
      onPointerSignal: (_) => _activity(),
      onPointerPanZoomStart: (_) => _activity(),
      child: widget.child,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      _foreground = true;
      _focused = true;
      unawaited(_returned());
    } else {
      _foreground = false;
      unawaited(_left());
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) _activity();
    return false;
  }

  /// A field or the editor reported a real user edit (including IME input).
  void _onUserEdit() => _activity();

  void _activity() {
    // Input while away, or while a resume is still checking the deadline, must
    // not restart the window it is about to be judged by.
    if (!_foreground || !_focused || _resuming) return;
    _idle?.activity();
  }

  void _onNativeFocus(bool focused) {
    _focused = focused;
    if (focused) {
      unawaited(_returned());
    } else {
      unawaited(_left());
    }
  }

  /// Keeps one [IdleLock] alive only while the session has something to hide,
  /// so a locked or setup session never runs a lock pipeline on a timer.
  void _syncWindow() {
    if (_needsWindow) {
      final mode = _session.autoLock;
      final idle = _idle;
      if (idle == null) {
        _idle = IdleLock(
          now: widget.now ?? DateTime.now,
          elapsed: widget.elapsed ?? () => _stopwatch.elapsed,
          onLock: _lockNow,
        )..setMode(mode);
        // A session that becomes lockable while the app is away (an unlock
        // finishing in the background) must not stay open until the user
        // returns; the saved policy applies from the moment it exists.
        if (!_focused || !_foreground) unawaited(_left());
      } else if (idle.mode != mode) {
        idle.setMode(mode);
      }
    } else {
      _idle?.dispose();
      _idle = null;
    }
  }

  void _onSessionChanged() => _syncWindow();

  Future<void> _lockNow() async {
    try {
      await _session.lock();
    } on VaultException {
      // A failed flush already froze the session; it stays hidden.
    }
  }

  Future<void> _left() async {
    _shield();
    // Credential drafts go first and synchronously: the drop must not wait for
    // a slow lock flush, and it must never land after the user has returned and
    // typed again.
    //
    // A form with no key cannot know the encrypted policy, so "unknown" is
    // treated as Immediately. This never shortens an unlocked vault's chosen
    // duration; that path keeps its window and is decided by [IdleLock].
    if (_session.phase == SessionPhase.locked ||
        _session.phase == SessionPhase.needsSetup) {
      _leavingSignal.report();
    }
    // The one policy source for keyed sessions: Immediately locks here, and a
    // timed window keeps counting.
    await _idle?.focusChanged(false);
  }

  /// Runs on every focus gain, including one this widget did not cause: the
  /// native side may have covered the window before Flutter was listening, so
  /// a focused app always asks for the cover to be removed after the checks.
  ///
  /// A blur that lands mid-check starts the loop over, so a resume that arrives
  /// while this is awaiting cannot be dropped and leave the cover up.
  Future<void> _returned() async {
    if (_resuming) return;
    _resuming = true;
    try {
      while (mounted && _focused && _foreground) {
        final epoch = _shieldEpoch;
        // Deadline first: input and focus must never reset an overdue window.
        await _idle?.checkDeadline();
        if (!mounted || !_focused || !_foreground) return;
        if (epoch != _shieldEpoch) continue;
        // Only a frame the engine really rasterized may reveal the window.
        if (!await _awaitRasterized()) return;
        if (!mounted || !_focused || !_foreground) return;
        // A newer leaving arrived while waiting: that shield owns its own
        // deadline and frame confirmation, so start the checks over.
        if (epoch != _shieldEpoch) continue;
        _unshield();
        break;
      }
    } finally {
      _resuming = false;
    }
  }

  /// Waits until a frame newer than the last one is rasterized, retrying for as
  /// long as the window is still front-most and no newer leaving intervened.
  ///
  /// Returns `false` only when the window stopped being front-most or the widget
  /// unmounted; the caller still decides whether a newer shield superseded this
  /// resume. A timeout is not an answer: it re-nudges the engine and waits
  /// again, so a slow first frame is uncovered once it arrives, and a window
  /// that never draws keeps the cover.
  Future<bool> _awaitRasterized() async {
    final binding = WidgetsBinding.instance;
    while (mounted && _focused && _foreground) {
      if (await _nextRasterizedFrame()) return true;
      if (!mounted || !_focused || !_foreground) return false;
      binding.scheduleFrame();
    }
    return false;
  }

  /// One wait for a rasterized frame, bounded so the caller can re-check focus
  /// and the shield epoch. Completion comes from [FrameTiming.rasterFinish],
  /// which the engine reports only after the frame was rasterized; the bound
  /// therefore means "not yet", never "safe".
  Future<bool> _nextRasterizedFrame() {
    final binding = WidgetsBinding.instance;
    // The strongest baseline the platform offers: the frame being built now,
    // and never a frame already reported. A batch still in flight from before
    // the cover went up therefore cannot count as the safe frame.
    final building = binding.platformDispatcher.frameData.frameNumber;
    _rasterBaseline = building > _lastRasterFrame ? building : _lastRasterFrame;
    final done = Completer<bool>();
    Timer? limit;

    void finish(bool rasterized) {
      if (done.isCompleted) return;
      limit?.cancel();
      _rasterWait = null;
      _cancelFrameWait = null;
      done.complete(rasterized);
    }

    _rasterWait = () => finish(true);
    // Dispose must release this wait, or its timer outlives the widget tree.
    _cancelFrameWait = () => finish(false);
    limit = Timer(PrivacyLifecycle.frameWait, () => finish(false));
    if (_lastRasterFrame > _rasterBaseline) {
      finish(true);
    } else {
      binding.scheduleFrame();
    }
    return done.future;
  }

  /// Records the newest frame the engine reported as rasterized. It is the only
  /// evidence that a frame reached the screen; a framework callback alone is
  /// not enough. Comparing frame numbers keeps a batch that was already in
  /// flight before the cover went up from counting as the safe frame.
  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      if (timing.frameNumber > _lastRasterFrame) {
        _lastRasterFrame = timing.frameNumber;
      }
    }
    if (_lastRasterFrame > _rasterBaseline) _rasterWait?.call();
  }

  void _shield() {
    _shieldEpoch++;
    unawaited(_setShield(true));
  }

  void _unshield() => unawaited(_setShield(false));

  /// Shield calls are serialized so the last requested state is the last one
  /// applied; concurrent awaits would otherwise let an older show land after a
  /// newer hide.
  Future<void> _setShield(bool visible) {
    final next = _shieldTail.then((_) async {
      try {
        await widget.native.setPrivacyShield(visible);
      } on VaultException {
        // Without a cover the window could be snapshotted with notes on
        // screen, so an install failure locks instead of trusting the platform.
        if (visible) await _lockNow();
      } on Object {
        // Any other bridge failure must not poison the queue: every later call
        // would otherwise be skipped and the cover would never move again.
        if (visible) await _lockNow();
      }
    });
    _shieldTail = next;
    return next;
  }
}
