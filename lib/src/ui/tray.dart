import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../sync/sync_controller.dart';
import 'sync_dialog.dart' show syncSummary;

/// GPad's icon in the system tray. With it on, closing the window hides
/// it instead of quitting, and sync goes on picking up changes from the
/// other computers until Quit in the icon's menu.
///
/// The runner draws the icon: through libayatana-appindicator on Linux,
/// where the desktop shows such icons, and the notification area on
/// Windows.
class Tray extends ChangeNotifier {
  Tray(this.sync, [this._channel = const MethodChannel(channelName)]) {
    _channel.setMethodCallHandler(_fromIcon);
    sync.addListener(_update);
  }

  static const channelName = 'gpad/tray';
  static const _settingKey = 'tray';

  final SyncController sync;
  final MethodChannel _channel;

  /// Quits GPad, when Quit is chosen in the icon's menu.
  Future<void> Function()? onQuit;

  bool? _available;

  /// Whether GPad asked for the icon, and whether the runner said it is
  /// there, as it may not be: Windows refuses while Explorer is down.
  bool _wanted = false;
  bool _shown = false;
  String? _status;
  bool _disposed = false;

  /// Asking the runner for the icon, while it answers.
  Future<void>? _showing;

  /// Whether this desktop has a tray GPad can put its icon in; null until
  /// [start] has asked.
  bool? get available => _available;

  /// Whether the person turned the tray on.
  bool get enabled => sync.notepad.store.setting(_settingKey) == 'on';

  /// Whether closing the window keeps GPad running in the tray now: it is
  /// turned on, sync is set up, and the icon is there to come back by.
  bool get keepsRunning => _wantsIcon && _wanted && _shown;

  bool get _wantsIcon =>
      enabled && _available == true && sync.config != null && !_disposed;

  /// Whether closing the window should keep GPad running in the tray,
  /// trying once more to put the icon there if it isn't yet.
  Future<bool> readyToKeepRunning() async {
    if (!keepsRunning && _wantsIcon) await _update();
    return keepsRunning;
  }

  /// Asks the runner whether there is a tray, and shows the icon if it is
  /// turned on.
  Future<void> start() async {
    _available = await _call<bool>('available') ?? false;
    await _update();
    if (!_disposed) notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    if (on) {
      sync.notepad.store.setSetting(_settingKey, 'on');
    } else {
      sync.notepad.store.deleteSetting(_settingKey);
    }
    await _update();
    if (!_disposed) notifyListeners();
  }

  /// Hides the window, as when it is closed with the tray on.
  Future<void> hideWindow() => _call<void>('hideWindow');

  /// Shows the window again, in front.
  Future<void> showWindow() => _call<void>('showWindow');

  /// Lets another GPad bring its window to the front, which Windows allows
  /// only a program the person is using to do.
  static Future<void> allowOthersToFront({
    MethodChannel channel = const MethodChannel(channelName),
  }) => _invoke<void>(channel, 'allowForeground');

  Future<void> _update() async {
    if (!_wantsIcon) {
      await remove();
      return;
    }
    final status = 'GPad: ${syncSummary(sync).label}';
    if (_shown) {
      if (status == _status) return;
      _status = status;
      await _call<void>('status', {'status': status});
      return;
    }
    if (_showing case final showing?) return showing;
    final showing = _showing = _show(status);
    try {
      await showing;
    } finally {
      if (_showing == showing) _showing = null;
    }
  }

  /// Until the runner says the icon is there, closing quits; the next
  /// change, or closing, asks again.
  Future<void> _show(String status) async {
    _wanted = true;
    final shown = await _call<bool>('show', {'status': status}) == true;
    // Taken away meanwhile.
    if (!_wanted) return;
    _shown = shown;
    _status = shown ? status : null;
  }

  /// Takes the icon away, as GPad quits.
  Future<void> remove() async {
    if (!_wanted) return;
    _wanted = false;
    _shown = false;
    _status = null;
    await _call<void>('remove');
  }

  Future<Object?> _fromIcon(MethodCall call) async {
    switch (call.method) {
      case 'syncNow':
        await sync.syncNow();
      case 'quit':
        await onQuit?.call();
    }
    return null;
  }

  Future<T?> _call<T>(String method, [Object? arguments]) =>
      _invoke<T>(_channel, method, arguments);

  /// Calls the runner, and takes no tray, as in tests or on macOS, as
  /// having none.
  static Future<T?> _invoke<T>(
    MethodChannel channel,
    String method, [
    Object? arguments,
  ]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    sync.removeListener(_update);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
