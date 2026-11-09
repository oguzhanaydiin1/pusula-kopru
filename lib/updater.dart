import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Derlenirken verilen sürüm (CI: --dart-define=APP_VERSION=0.1.0).
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');

class UpdateInfo {
  const UpdateInfo(this.version, this.assetUrl, this.assetName, this.pageUrl);
  final String version;
  final String assetUrl;
  final String assetName;
  final String pageUrl;
}

/// GitHub'daki pusula-kopru sürümlerine bakar.
class Updater {
  Updater._();
  static const _api = 'https://api.github.com/repos/oguzhanaydiin1/pusula-kopru/releases?per_page=5';

  static List<int> _parts(String v) =>
      v.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.+-]')).take(3).map((p) => int.tryParse(p) ?? 0).toList();

  static bool isNewer(String remote, String local) {
    final a = _parts(remote), b = _parts(local);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static Future<UpdateInfo?> check({bool force = false}) async {
    if (appVersion == '0.0.0' && !force) return null; // geliştirme derlemesi
    try {
      final r = await http.get(Uri.parse(_api), headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'PusulaKopru/$appVersion',
      }).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
      final wanted = Platform.isAndroid ? 'Pusula-Kopru-Android.apk' : 'Pusula-Kopru-Kurulum.exe';
      for (final rel in list.whereType<Map>()) {
        if (rel['draft'] == true) continue;
        final tag = rel['tag_name']?.toString() ?? '';
        if (!isNewer(tag, appVersion)) return null;
        for (final a in (rel['assets'] as List? ?? const []).whereType<Map>()) {
          if (a['name'] == wanted) {
            return UpdateInfo(tag.replaceFirst(RegExp(r'^v'), ''), a['browser_download_url'].toString(), wanted,
                rel['html_url']?.toString() ?? '');
          }
        }
      }
    } catch (_) {}
    return null;
  }
}

/// Windows: kurulum dosyasını indirir ve sessizce kurar (uygulama kapanıp yenisi açılır).
Future<bool> downloadAndInstall(UpdateInfo u, void Function(double) onProgress) async {
  final client = http.Client();
  try {
    final res = await client.send(http.Request('GET', Uri.parse(u.assetUrl))..headers['User-Agent'] = 'PusulaKopru/$appVersion');
    if (res.statusCode != 200) return false;
    final f = File('${Directory.systemTemp.path}${Platform.pathSeparator}Pusula-Kopru-Kurulum-${u.version}.exe');
    final sink = f.openWrite();
    final total = res.contentLength ?? 0;
    var got = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress(got / total);
    }
    await sink.close();
    if (total > 0 && got != total) return false;
    await Process.start(f.path, ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS', '/NOCANCEL'],
        mode: ProcessStartMode.detached);
    return true;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}
