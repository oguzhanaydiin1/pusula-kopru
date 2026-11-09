import 'dart:io';

import 'package:flutter/services.dart';

/// Android'deki "kopru/native" kanalı (MainActivity.kt). Windows'ta çağrılar boş döner.
class Native {
  Native._();
  static const _ch = MethodChannel('kopru/native');

  static void Function(Map<String, dynamic>)? onShared;

  static void init() {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shared' && call.arguments is Map) {
        onShared?.call(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
  }

  static Future<T?> _call<T>(String m, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _ch.invokeMethod<T>(m, args);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> initialShare() async {
    final v = await _call<Map>('initialShare');
    return v == null ? null : Map<String, dynamic>.from(v);
  }

  static Future<String?> deviceName() => _call<String>('deviceName');

  static Future<(int, bool)?> battery() async {
    final v = await _call<Map>('battery');
    if (v == null) return null;
    return ((v['level'] as num?)?.toInt() ?? -1, v['charging'] == true);
  }

  static Future<void> multicast() => _call('multicast');
  static Future<void> ring() => _call('ring');
  static Future<void> stopRing() => _call('stopRing');

  /// Dosyayı İndirilenler/Pusula Köprü'ye taşır; açmak için adresini döndürür.
  static Future<String?> saveToDownloads(String path, String name, String mime) async {
    if (!Platform.isAndroid) return null;
    return _ch.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name, 'mime': mime});
  }

  static Future<bool> openUri(String uri, String? mime) async =>
      await _call<bool>('openUri', {'uri': uri, 'mime': mime}) ?? false;

  static Future<bool> openDownloads() async => await _call<bool>('openDownloads') ?? false;

  static Future<bool> openInPusula(String url) async => await _call<bool>('openInPusula', {'url': url}) ?? false;
}
