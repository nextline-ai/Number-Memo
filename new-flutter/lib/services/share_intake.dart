import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's share sheet can start a fresh activity or reuse the running one.
/// Intake only opens the editable save dialog; it never silently saves a link.
class ShareIntake {
  ShareIntake(this.onText);
  final void Function(String) onText;
  static const _channel = MethodChannel('work.nextline.number_memo/share');
  bool _disposed = false;

  Future<void> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler((call) async {
      if (!_disposed &&
          call.method == 'sharedText' &&
          call.arguments is String) {
        _deliver(call.arguments as String);
      }
    });
    try {
      final text = await _channel.invokeMethod<String>('initialText');
      if (text != null && !_disposed) _deliver(text);
    } on MissingPluginException {
      // Tests and non-Android embedding hosts do not have this channel.
    }
  }

  void _deliver(String text) {
    if (text.trim().isNotEmpty) onText(text.trim());
  }

  void dispose() {
    _disposed = true;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _channel.setMethodCallHandler(null);
    }
  }
}
