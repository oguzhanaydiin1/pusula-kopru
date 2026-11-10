import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Android'deki "kopru/native" kanalı (NativeBridge.kt). Windows'ta çağrılar boş döner.
class Native {
  Native._();
  static const _ch = MethodChannel('kopru/native');

  static void Function(Map<String, dynamic>)? onShared;
  static void Function()? onRingStopped;
  static void Function(Map<String, dynamic>)? onNotification; // bildirim aynası (0.3)
  static void Function(String key)? onNotificationRemoved;
  static void Function(String dir)? onVolumeKey;

  static void init() {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'shared':
          if (call.arguments is Map) onShared?.call(Map<String, dynamic>.from(call.arguments as Map));
        case 'ringStopped':
          onRingStopped?.call();
        case 'notification':
          if (call.arguments is Map) onNotification?.call(Map<String, dynamic>.from(call.arguments as Map));
        case 'volumeKey':
          onVolumeKey?.call(call.arguments?.toString() ?? '');
        case 'notificationRemoved':
          onNotificationRemoved?.call(call.arguments?.toString() ?? '');
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
  static Future<void> ring(String from) => _call('ring', {'from': from});
  static Future<void> stopRing() => _call('stopRing');

  /// Dosyayı İndirilenler/Pusula Köprü(/alt klasör)'e taşır; açmak için adresini döndürür.
  static Future<String?> saveToDownloads(String path, String name, String mime, {String sub = ''}) async {
    if (!Platform.isAndroid) return null;
    return _ch.invokeMethod<String>('saveToDownloads', {'path': path, 'name': name, 'mime': mime, 'sub': sub});
  }

  static Future<bool> openUri(String uri, String? mime) async =>
      await _call<bool>('openUri', {'uri': uri, 'mime': mime}) ?? false;

  static Future<bool> openDownloads() async => await _call<bool>('openDownloads') ?? false;

  static Future<bool> openInPusula(String url) async => await _call<bool>('openInPusula', {'url': url}) ?? false;

  /// Arka plan hizmeti (bildirim çubuğunda "Pusula Köprü açık").
  static Future<void> setBackground(bool on) => _call('setBackground', {'on': on});

  static Future<void> requestNotifications() => _call('requestNotifications');

  static Future<void> notify(String title, String text, {String? uri, String? mime, String? url}) =>
      _call('notify', {'title': title, 'text': text, 'uri': uri, 'mime': mime, 'url': url});

  /// Ekran açık ve uygulama önde mi?
  static Future<bool> isForeground() async => await _call<bool>('isForeground') ?? false;

  /// Son ekran görüntüsü: {path} | {none: true} | {permission: true} (izin istendi)
  static Future<Map<String, dynamic>?> latestScreenshot() async {
    final v = await _call<Map>('latestScreenshot');
    return v == null ? null : Map<String, dynamic>.from(v);
  }

  // Medya: göz atma ve yedekleme
  static Future<bool> mediaPermission() async => await _call<bool>('mediaPermission') ?? false;
  static Future<bool> requestMedia() async => await _call<bool>('requestMedia') ?? false;

  static List<Map<String, dynamic>>? _list(Object? v) =>
      v is List ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList() : null;

  /// kind: img | vid | dl. İzin yoksa null.
  static Future<List<Map<String, dynamic>>?> listMedia(String kind, int offset, int limit) async =>
      _list(await _call<Object>('listMedia', {'kind': kind, 'offset': offset, 'limit': limit}));

  static Future<List<Map<String, dynamic>>?> newMedia(int sinceSeconds, int limit) async =>
      _list(await _call<Object>('newMedia', {'since': sinceSeconds, 'limit': limit}));

  static Future<Uint8List?> thumb(String id, int px) => _call<Uint8List>('thumb', {'id': id, 'px': px});

  static Future<String?> copyMedia(String id, String name) => _call<String>('copyMedia', {'id': id, 'name': name});

  static Future<void> setLang(String lang) => _call('setLang', {'lang': lang});

  static Future<void> captureVolume(bool on) => _call('captureVolume', {'on': on});

  // Bildirim aynası (0.3)
  /// Bu APK'da bildirim aynası var mı (standart APK'da yok; bkz. android_ayarla.py)
  static Future<bool> mirrorAvailable() async => await _call<bool>('mirrorAvailable') ?? false;
  static Future<bool> notificationAccess() async => await _call<bool>('notificationAccess') ?? false;
  static Future<void> openNotificationAccess() => _call('openNotificationAccess');
  static Future<bool> replyNotification(String key, String text) async =>
      await _call<bool>('replyNotification', {'key': key, 'text': text}) ?? false;
  static Future<void> setMirror(bool on) => _call('setMirror', {'on': on});
}
