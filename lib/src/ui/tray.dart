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
  bool _shown = false;
  String? _status;
  bool _disposed = false;

  /// Whether this desktop has a tray GPad can put its icon in; null until
  /// [start] has asked.
  bool? get available => _available;

  /// Whether the person turned the tray on.
  bool get enabled => sync.notepad.store.setting(_settingKey) == 'on';

  /// Whether closing the window keeps GPad running in the tray now: it is
  /// turned on, this desktop has a tray, and sync is set up.
  bool get keepsRunning => enabled && _available == true && sync.config != null;

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

  /// Takes the icon away, as GPad quits.
  Future<void> remove() async {
    if (!_shown) return;
    _shown = false;
    _status = null;
    await _call<void>('remove');
  }

  Future<void> _update() async {
    if (_disposed || _available != true) return;
    if (!keepsRunning) {
      await remove();
      return;
    }
    final status = 'GPad: ${syncSummary(sync).label}';
    if (_shown && status == _status) return;
    final first = !_shown;
    _shown = true;
    _status = status;
    await _call<bool>(first ? 'show' : 'status', {'status': status});
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
