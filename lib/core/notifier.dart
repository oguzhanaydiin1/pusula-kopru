import 'dart:io';

import 'package:local_notifier/local_notifier.dart';

import 'native.dart';

/// Sistem bildirimi: Android'de bildirim çubuğu, Windows'ta sağ alttaki bildirim.
class Notifier {
  Notifier._();
  static bool _ready = false;

  /// Windows: bildirime tıklanınca pencereyi öne getir (masaüstü kabuğu ayarlar).
  static void Function()? showWindow;

  /// Windows: pencere şu an önde ve görünür mü (öyleyse bildirim gösterilmez).
  static Future<bool> Function()? windowFocused;

  static Future<void> init() async {
    if (!Platform.isWindows || _ready) return;
    try {
      await localNotifier.setup(appName: 'Pusula Köprü', shortcutPolicy: ShortcutPolicy.requireCreate);
      _ready = true;
    } catch (_) {}
  }

  /// [uri]/[path]: dokununca açılacak dosya; [url]: açılacak bağlantı; [onClick]: Windows'ta ek iş.
  static Future<void> show(String title, String body,
      {String? uri, String? mime, String? url, void Function()? onClick, bool always = false}) async {
    if (Platform.isAndroid) {
      if (!always && await Native.isForeground()) return;
      await Native.notify(title, body, uri: uri, mime: mime, url: url);
      return;
    }
    if (!Platform.isWindows || !_ready) return;
    if (!always && windowFocused != null && await windowFocused!()) return;
    try {
      final n = LocalNotification(title: title, body: body);
      n.onClick = () {
        if (onClick != null) {
          onClick();
        } else {
          showWindow?.call();
        }
      };
      await n.show();
    } catch (_) {}
  }
}
