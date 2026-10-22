import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../lock/idle_lock.dart';
import '../session/note_session.dart';
import '../vault/vault_types.dart';
import 'native_bridge.dart';

/// Owns the inactivity window and the native privacy shield for the whole app.
///
/// Activity is counted only from real input (pointer, scroll, keys) on the root
/// listener. Lifecycle and focus events are never activity: leaving the app
/// shields at once, and returning checks the deadline before the shield may be
/// removed. The shield stays up until a Flutter frame has been rendered after
/// those checks, so a stale note frame is never revealed on resume.
class PrivacyLifecycle extends StatefulWidget {
  const PrivacyLifecycle({
    super.key,
    required this.session,
    required this.native,
    required this.child,
  });

  final NoteSession session;
  final NativeBridge native;
  final Widget child;

  @override
  State<PrivacyLifecycle> createState() => _PrivacyLifecycleState();
}

class _PrivacyLifecycleState extends State<PrivacyLifecycle>
    with WidgetsBindingObserver {
  final Stopwatch _clock = Stopwatch()..start();

  IdleLock? _idle;
  StreamSubscription<bool>? _focusEvents;
  bool _focused = true;
  bool _foreground = true;
  bool _resuming = false;
  int _shieldEpoch = 0;
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
    HardwareKeyboard.instance.addHandler(_onKey);
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
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _session.removeListener(_onSessionChanged);
    unawaited(_focusEvents?.cancel());
    _idle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          now: DateTime.now,
          elapsed: () => _clock.elapsed,
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
    // The one policy source: Immediately locks here, and a timed window keeps
    // counting. A session with nothing to hide has no [IdleLock] at all.
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
        // Only after the checks has a safe frame been built and painted.
        await _nextFrame();
        if (!mounted || !_focused || !_foreground) return;
        if (epoch != _shieldEpoch) continue;
        _unshield();
        return;
      }
    } finally {
      _resuming = false;
    }
  }

  /// Waits for one painted frame, scheduling it explicitly: [endOfFrame] alone
  /// does not request a frame when it is called from inside a frame callback.
  Future<void> _nextFrame() {
    final binding = WidgetsBinding.instance;
    binding.scheduleFrame();
    return binding.endOfFrame;
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
      }
    });
    _shieldTail = next;
    return next;
  }
}
