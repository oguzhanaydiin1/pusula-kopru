import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../updater.dart' show appVersion;
import 'crypto.dart';
import 'models.dart';
import 'native.dart';
import 'notifier.dart';

/// Pusula Köprü'nün çekirdeği.
///
/// Her cihaz yerel ağda küçük bir HTTP sunucusu açar ([kPort]) ve UDP yayınıyla ([kDiscoveryPort])
/// varlığını duyurur. Eşleşmiş iki cihaz arasındaki her ileti ve dosya parçası ortak anahtarla
/// şifrelenir (ChaCha20-Poly1305); ağdaki biri ne gönderildiğini göremez, araya bir şey ekleyemez.
const kPort = 47821;
const kDiscoveryPort = 47822;
const kChunk = 256 * 1024;
const _kMagic = 'pusula-kopru';

class PairSession {
  PairSession(this.keyPair, this.pub, this.token, this.code, this.expires);
  final dynamic keyPair; // SimpleKeyPair
  final Uint8List pub;
  final Uint8List token;
  String code;
  final DateTime expires;
  int attempts = 0;
  bool get expired => DateTime.now().isAfter(expires);
}

/// Yakındaki, eşleşmeye açık bir cihaz (bilgisayarda "Yeni cihaz eşleştir" penceresi açıkken).
class NearbyDevice {
  NearbyDevice(this.id, this.name, this.platform, this.address, this.port, this.seen);
  final String id;
  final String name;
  final String platform;
  String address;
  int port;
  DateTime seen;
}

class Kopru extends ChangeNotifier {
  Kopru._();
  static final Kopru i = Kopru._();

  final _secure = const FlutterSecureStorage();
  late SharedPreferences _prefs;

  String myId = '';
  String myName = '';
  String get platform => Platform.isAndroid ? 'android' : (Platform.isWindows ? 'windows' : Platform.operatingSystem);
  bool get isPhone => Platform.isAndroid;

  final peers = <Peer>[];
  String? _selectedId;
  final history = <HistoryItem>[];
  final active = <ActiveTransfer>[];
  final nearby = <String, NearbyDevice>{};
  IncomingText? lastIncoming;
  PairSession? pairSession;

  bool clipShare = true;
  bool background = true; // Android: arka planda çalış
  bool autostart = true; // Windows: Windows açılınca başla
  bool mirror = false; // Android: bildirimleri bilgisayara ilet
  final phoneNotifs = <PhoneNotif>[]; // Windows: telefondan gelen bildirimler
  String? myClip; // bilgisayarda son kopyalanan
  DateTime? myClipAt;
  String? _lastClipSeen;
  bool _clipPrimed = false;

  HttpServer? _server;
  int port = kPort;
  RawDatagramSocket? _udp;
  Timer? _announceTimer, _statusTimer, _clipTimer, _probeTimer;
  final _recentNonces = <String>{};
  final _nonceOrder = <String>[];
  bool started = false;
  String? startError;

  final _events = StreamController<KopruEvent>.broadcast();
  Stream<KopruEvent> get events => _events.stream;
  void _emit(KopruEvent e) => _events.add(e);

  Peer? get selected {
    if (peers.isEmpty) return null;
    return peers.firstWhere((p) => p.id == _selectedId, orElse: () => peers.first);
  }

  set selectedPeer(Peer? p) {
    _selectedId = p?.id;
    _prefs.setString('selected', p?.id ?? '');
    notifyListeners();
  }

  Peer? peerById(String? id) {
    if (id == null) return null;
    for (final p in peers) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ---------------------------------------------------------------- başlangıç

  Future<void> start() async {
    if (started) return;
    started = true;
    _prefs = await SharedPreferences.getInstance();
    myId = _prefs.getString('id') ?? '';
    if (myId.isEmpty) {
      myId = b64u(randomBytes(12));
      await _prefs.setString('id', myId);
    }
    clipShare = _prefs.getBool('clipShare') ?? true;
    background = _prefs.getBool('background') ?? true;
    autostart = _prefs.getBool('autostart') ?? true;
    mirror = _prefs.getBool('mirror') ?? false;
    _selectedId = _prefs.getString('selected');
    myName = _prefs.getString('name') ?? '';
    if (myName.isEmpty) myName = await _defaultName();

    try {
      final raw = await _secure.read(key: 'peers');
      if (raw != null && raw.isNotEmpty) {
        for (final j in (jsonDecode(raw) as List)) {
          try {
            final p = Peer.fromJson(Map<String, dynamic>.from(j as Map));
            p.lastSeen = null; // açılışta bağlı sayma
            peers.add(p);
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      final raw = _prefs.getString('history');
      if (raw != null) {
        for (final j in (jsonDecode(raw) as List)) {
          history.add(HistoryItem.fromJson(Map<String, dynamic>.from(j as Map)));
        }
      }
    } catch (_) {}

    if (Platform.isWindows && await _otherInstance()) {
      // Pusula Köprü zaten açık: onun penceresi öne geldi, bu kopya kapanır.
      exit(0);
    }
    if (Platform.isAndroid) {
      await Native.multicast();
      Native.onNotification = _mirrorOut;
      Native.onNotificationRemoved = (key) {
        if (!mirror) return;
        for (final p in peers.where((p) => p.online && p.isComputer)) {
          _send(p, {'t': 'notifGone', 'key': key});
        }
      };
      if (peers.isNotEmpty && background) Native.setBackground(true);
    }
    if (Platform.isWindows) _applyAutostart(autostart);
    await _startServer();
    await _startDiscovery();

    _announceTimer = Timer.periodic(const Duration(seconds: 4), (_) => _announce());
    _probeTimer = Timer.periodic(const Duration(seconds: 10), (_) => _probeOffline());
    if (isPhone) {
      _statusTimer = Timer.periodic(const Duration(seconds: 60), (_) => sendStatus());
      Future.delayed(const Duration(seconds: 2), sendStatus);
    } else {
      _clipTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => _pollClipboard());
    }
    _announce();
    Future.delayed(const Duration(milliseconds: 600), _probeOffline);
    notifyListeners();
  }

  Future<String> _defaultName() async {
    if (Platform.isAndroid) return await Native.deviceName() ?? 'Android telefon';
    final h = Platform.localHostname;
    return h.isEmpty ? 'Bilgisayar' : h;
  }

  Future<void> setMyName(String name) async {
    final n = name.trim();
    myName = n.isEmpty ? await _defaultName() : n;
    await _prefs.setString('name', n);
    notifyListeners();
    _announce();
    for (final p in peers.where((p) => p.online)) {
      _send(p, {'t': 'status', ..._statusFields()});
    }
  }

  Future<void> setBackground(bool v) async {
    background = v;
    await _prefs.setBool('background', v);
    await Native.setBackground(v && peers.isNotEmpty);
    notifyListeners();
  }

  Future<void> setAutostart(bool v) async {
    autostart = v;
    await _prefs.setBool('autostart', v);
    await _applyAutostart(v);
    notifyListeners();
  }

  Future<void> setMirror(bool v) async {
    mirror = v;
    await _prefs.setBool('mirror', v);
    await Native.setMirror(v);
    notifyListeners();
  }

  Future<void> _applyAutostart(bool on) async {
    if (!Platform.isWindows) return;
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    try {
      if (on) {
        await Process.run('reg', ['add', key, '/v', 'PusulaKopru', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --hidden', '/f']);
      } else {
        await Process.run('reg', ['delete', key, '/v', 'PusulaKopru', '/f']);
      }
    } catch (_) {}
  }

  /// Windows: aynı bilgisayarda Pusula Köprü zaten açıksa onu öne getirir.
  Future<bool> _otherInstance() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:$kPort/v1/hello')).timeout(const Duration(milliseconds: 800));
      if (r.statusCode != 200) return false;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map || j['id'] != myId) return false;
      await http.get(Uri.parse('http://127.0.0.1:$kPort/v1/local/show')).timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setClipShare(bool v) async {
    clipShare = v;
    await _prefs.setBool('clipShare', v);
    notifyListeners();
  }

  Future<void> _savePeers() async {
    await _secure.write(key: 'peers', value: jsonEncode(peers.map((p) => p.toJson()).toList()));
  }

  Future<void> _addHistory(HistoryItem h) async {
    history.insert(0, h);
    if (history.length > 200) history.removeRange(200, history.length);
    await _prefs.setString('history', jsonEncode(history.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  Future<void> clearHistory() async {
    history.clear();
    await _prefs.remove('history');
    notifyListeners();
  }

  // ---------------------------------------------------------------- sunucu

  Future<void> _startServer() async {
    for (var p = kPort; p < kPort + 8; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        port = p;
        break;
      } catch (_) {}
    }
    final s = _server;
    if (s == null) {
      startError = 'Bağlantı noktası açılamadı. Pusula Köprü başka bir pencerede açık olabilir.';
      return;
    }
    s.idleTimeout = const Duration(seconds: 30);
    s.listen((req) => _handle(req), onError: (_) {});
  }

  Future<void> _reply(HttpRequest req, int code, [List<int>? body, String type = 'application/octet-stream']) async {
    try {
      req.response.statusCode = code;
      req.response.headers.set('content-type', type);
      if (body != null) req.response.add(body);
      await req.response.close();
    } catch (_) {}
  }

  Future<void> _replyJson(HttpRequest req, Map<String, dynamic> m, [int code = 200]) =>
      _reply(req, code, utf8.encode(jsonEncode(m)), 'application/json');

  Future<Uint8List> _readAll(HttpRequest req, int max) async {
    final b = BytesBuilder(copy: false);
    await for (final d in req) {
      b.add(d);
      if (b.length > max) throw const FormatException('Çok büyük');
    }
    return b.takeBytes();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/v1/hello') {
        return await _replyJson(req, {'k': _kMagic, 'id': myId, 'n': myName, 'p': platform, 'v': appVersion});
      }
      if (req.method == 'GET' && path == '/v1/pair/info') {
        final s = pairSession;
        if (s == null || s.expired) return await _reply(req, 404);
        return await _replyJson(req, {'id': myId, 'n': myName, 'p': platform, 'pub': b64u(s.pub)});
      }
      if (req.method == 'POST' && path == '/v1/pair') return await _handlePair(req);
      if (path.startsWith('/v1/local/')) return await _handleLocal(req, path);

      final peer = peerById(req.headers.value('x-k-from'));
      if (peer == null) {
        await _readAll(req, 1 << 20).catchError((_) => Uint8List(0));
        return await _reply(req, 403);
      }
      if (req.method == 'POST' && path == '/v1/msg') {
        final body = await _readAll(req, 4 << 20);
        final Map<String, dynamic> m;
        try {
          m = await peer.key.openJson(body);
        } catch (_) {
          return await _reply(req, 403);
        }
        if (!_fresh(m)) return await _reply(req, 409);
        _seen(peer, req.connectionInfo?.remoteAddress.address, int.tryParse(req.headers.value('x-k-port') ?? ''));
        final out = await _onMessage(peer, m) ?? <String, dynamic>{'ok': true};
        return await _reply(req, 200, await peer.key.sealJson(out));
      }
      if (req.method == 'POST' && path == '/v1/file') return await _receiveFile(req, peer);
      return await _reply(req, 404);
    } catch (_) {
      return await _reply(req, 400);
    }
  }

  /// Bu bilgisayardaki uygulamalar için (ör. Pusula Browser'ın "Telefona gönder" düğmesi).
  /// Yalnız aynı bilgisayardan (127.0.0.1) gelen istekler kabul edilir.
  Future<void> _handleLocal(HttpRequest req, String path) async {
    final from = req.connectionInfo?.remoteAddress;
    if (from == null || !from.isLoopback) {
      await _readAll(req, 1 << 16).catchError((_) => Uint8List(0));
      return await _reply(req, 403);
    }
    if (path == '/v1/local/show') {
      Notifier.showWindow?.call();
      return await _replyJson(req, {'ok': true});
    }
    if (path == '/v1/local/status') {
      return await _replyJson(req, {
        'ok': true,
        'name': myName,
        'peers': [
          for (final p in peers) {'id': p.id, 'name': p.name, 'platform': p.platform, 'online': p.online},
        ],
      });
    }
    if (path == '/v1/local/send' && req.method == 'POST') {
      final j = jsonDecode(utf8.decode(await _readAll(req, 1 << 20)));
      if (j is! Map) return await _reply(req, 400);
      final text = j['text']?.toString() ?? '';
      final target = peerById(j['peer']?.toString()) ??
          (selected?.isPhone == true ? selected : null) ??
          peers.where((p) => p.isPhone && p.online).firstOrNull ??
          peers.where((p) => p.isPhone).firstOrNull;
      if (target == null) return await _replyJson(req, {'ok': false, 'error': 'eslesme'});
      final ok = await sendText(target, text, open: j['open'] == true);
      return await _replyJson(req, {'ok': ok, 'peer': target.name, if (!ok) 'error': 'ulasilamadi'});
    }
    return await _reply(req, 404);
  }

  /// Aynı ileti ikinci kez (araya giren biri tarafından) gönderilemesin.
  bool _fresh(Map<String, dynamic> m) {
    final ts = (m['ts'] as num?)?.toInt() ?? 0;
    final n = m['n']?.toString() ?? '';
    if (n.isEmpty) return false;
    if ((DateTime.now().millisecondsSinceEpoch - ts).abs() > 15 * 60 * 1000) return false;
    if (_recentNonces.contains(n)) return false;
    _recentNonces.add(n);
    _nonceOrder.add(n);
    if (_nonceOrder.length > 2000) _recentNonces.remove(_nonceOrder.removeAt(0));
    return true;
  }

  Map<String, dynamic> _stamp(Map<String, dynamic> m) =>
      {...m, 'ts': DateTime.now().millisecondsSinceEpoch, 'n': b64u(randomBytes(12))};

  void _seen(Peer p, String? addr, int? port) {
    p.lastSeen = DateTime.now();
    if (port != null && port > 0) p.port = port;
    if (addr != null && addr.isNotEmpty && !addr.startsWith('127.')) {
      if (p.addrs.isEmpty || p.addrs.first != addr) {
        p.addrs.remove(addr);
        p.addrs.insert(0, addr);
        if (p.addrs.length > 6) p.addrs = p.addrs.sublist(0, 6);
        _savePeers();
      }
    }
    notifyListeners();
  }

  Map<String, dynamic> _statusFields() => {'name': myName, 'platform': platform};

  Future<Map<String, dynamic>?> _onMessage(Peer peer, Map<String, dynamic> m) async {
    final t = m['t']?.toString();
    switch (t) {
      case 'ping':
        return {'ok': true, ..._statusFields()};
      case 'status':
        final name = m['name']?.toString();
        if (name != null && name.isNotEmpty && name != peer.name) {
          peer.name = name;
          _savePeers();
        }
        if (m['battery'] is num) peer.battery = (m['battery'] as num).toInt();
        peer.charging = m['charging'] == true;
        notifyListeners();
        return {'ok': true, ..._statusFields()};
      case 'text':
        final text = m['text']?.toString() ?? '';
        if (text.isEmpty) return null;
        lastIncoming = IncomingText(peer.name, text, DateTime.now());
        await _addHistory(HistoryItem(
          kind: looksLikeLink(text) ? 'link' : 'text',
          name: text,
          incoming: true,
          peerName: peer.name,
          at: DateTime.now(),
        ));
        final link = looksLikeLink(text);
        if (m['open'] == true && link) {
          // "Telefona/Bilgisayara gönder": bağlantı hemen açılsın
          if (Platform.isWindows) {
            await launchUrl(Uri.parse(linkUrl(text)), mode: LaunchMode.externalApplication);
          } else if (await Native.isForeground()) {
            await Native.openInPusula(linkUrl(text));
          } else {
            await Notifier.show('${peer.name}: bağlantı', 'Dokun, Pusula\'da aç · $text', url: linkUrl(text), always: true);
          }
        } else {
          await Notifier.show(link ? '${peer.name}: bağlantı' : '${peer.name}: metin', text,
              url: link ? linkUrl(text) : null);
        }
        _emit(KopruEvent('text', peer: peer, text: text));
        return null;
      case 'clip':
        final text = m['text']?.toString() ?? '';
        if (text.isEmpty) return null;
        if (isPhone) {
          // Bilgisayarın panosu: telefonda "Kopyala" ile alınır
          peer.clip = text;
          peer.clipAt = DateTime.now();
          notifyListeners();
        } else {
          // Telefondan "Panoyu gönder": doğrudan bilgisayarın panosuna
          _lastClipSeen = text;
          await Clipboard.setData(ClipboardData(text: text));
          myClip = text;
          myClipAt = DateTime.now();
          lastIncoming = IncomingText(peer.name, text, DateTime.now(), fromClipboard: true);
          await _addHistory(HistoryItem(
            kind: looksLikeLink(text) ? 'link' : 'text',
            name: text,
            incoming: true,
            peerName: peer.name,
            at: DateTime.now(),
          ));
          _emit(KopruEvent('clipCopied', peer: peer, text: text));
        }
        return null;
      case 'ring':
        if (isPhone) {
          await Native.ring(peer.name);
          _emit(KopruEvent('ring', peer: peer));
        }
        return null;
      case 'ringStop':
        if (isPhone) {
          await Native.stopRing();
          _emit(KopruEvent('ringStop', peer: peer));
        }
        return null;
      case 'media':
        if (Platform.isWindows) await _mediaKey(m['key']?.toString() ?? '');
        return null;
      case 'notif':
        if (!Platform.isWindows) return null;
        final n = PhoneNotif.fromMsg(m, peer.id);
        if (n.key.isEmpty) return null;
        phoneNotifs.removeWhere((x) => x.key == n.key);
        phoneNotifs.insert(0, n);
        if (phoneNotifs.length > 50) phoneNotifs.removeRange(50, phoneNotifs.length);
        notifyListeners();
        await Notifier.show(n.title.isEmpty ? n.app : '${n.app} · ${n.title}', n.text);
        return null;
      case 'notifGone':
        phoneNotifs.removeWhere((x) => x.key == m['key']);
        notifyListeners();
        return null;
      case 'notifReply':
        if (!Platform.isAndroid) return {'ok': false};
        return {'ok': await Native.replyNotification(m['key']?.toString() ?? '', m['text']?.toString() ?? '')};
      case 'lock':
        if (Platform.isWindows) {
          await Process.run('rundll32.exe', ['user32.dll,LockWorkStation']);
        }
        return null;
      case 'unpair':
        peers.removeWhere((p) => p.id == peer.id);
        await _savePeers();
        _emit(KopruEvent('unpaired', peer: peer));
        notifyListeners();
        return null;
    }
    return null;
  }

  // ---------------------------------------------------------------- cihaz bulma

  Future<void> _startDiscovery() async {
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kDiscoveryPort, reuseAddress: true);
      s.broadcastEnabled = true;
      s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = s.receive()) != null) {
          _onDatagram(d!);
        }
      });
      _udp = s;
    } catch (_) {
      // Başka bir kopya açıksa UDP kapalı kalır; bilinen adresler yine denenir.
      try {
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        s.broadcastEnabled = true;
        _udp = s;
      } catch (_) {}
    }
  }

  void _onDatagram(Datagram d) {
    try {
      final j = jsonDecode(utf8.decode(d.data));
      if (j is! Map || j['k'] != _kMagic) return;
      final id = j['id']?.toString() ?? '';
      if (id.isEmpty || id == myId) return;
      final port = (j['port'] as num?)?.toInt() ?? kPort;
      final peer = peerById(id);
      if (peer != null) {
        final wasOnline = peer.online;
        _seen(peer, d.address.address, port);
        if (!wasOnline && isPhone) sendStatus(only: peer);
        return;
      }
      if (j['pair'] == true) {
        final n = nearby[id];
        if (n == null) {
          nearby[id] = NearbyDevice(id, j['n']?.toString() ?? 'Cihaz', j['p']?.toString() ?? '', d.address.address, port,
              DateTime.now());
        } else {
          n
            ..address = d.address.address
            ..port = port
            ..seen = DateTime.now();
        }
        notifyListeners();
      } else if (nearby.remove(id) != null) {
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<List<String>> localAddresses() async {
    final out = <String>[];
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifs) {
        final name = i.name.toLowerCase();
        final virtual = name.contains('vethernet') || name.contains('virtual') || name.contains('vmware') ||
            name.contains('vbox') || name.contains('docker') || name.contains('wsl');
        for (final a in i.addresses) {
          final s = a.address;
          if (s.startsWith('169.254.') || s.startsWith('127.')) continue;
          if (virtual) {
            out.add(s); // sona
          } else {
            out.insert(0, s);
          }
        }
      }
    } catch (_) {}
    // Özel ağ adresleri öne
    int rank(String s) => s.startsWith('192.168.') ? 0 : (s.startsWith('10.') ? 1 : (s.startsWith('172.') ? 2 : 3));
    final sorted = [...out]..sort((a, b) => rank(a).compareTo(rank(b)));
    return sorted;
  }

  Future<void> _announce() async {
    final s = _udp;
    if (s == null) return;
    final pairing = pairSession != null && !pairSession!.expired;
    final data = utf8.encode(jsonEncode({
      'k': _kMagic,
      'v': 1,
      'id': myId,
      'n': myName,
      'p': platform,
      'port': port,
      if (pairing) 'pair': true,
    }));
    final targets = <String>{'255.255.255.255'};
    for (final a in await localAddresses()) {
      final parts = a.split('.');
      if (parts.length == 4) targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
    }
    for (final t in targets) {
      try {
        s.send(data, InternetAddress(t), kDiscoveryPort);
      } catch (_) {}
    }
    // Eski yakın cihazlar
    final now = DateTime.now();
    final before = nearby.length;
    nearby.removeWhere((_, n) => now.difference(n.seen) > const Duration(seconds: 15));
    if (nearby.length != before) notifyListeners();
  }

  /// Yayın ulaşmayan ağlarda (misafir Wi-Fi, güvenlik duvarı) bilinen adresleri doğrudan dener.
  Future<void> _probeOffline() async {
    for (final p in peers) {
      if (p.online) continue;
      final addr = await _reachable(p, timeout: const Duration(milliseconds: 1500));
      if (addr != null) {
        _seen(p, addr, null);
        if (isPhone) sendStatus(only: p);
      }
    }
    notifyListeners(); // "Bağlı" yazısı süre dolunca da güncellensin
  }

  Future<String?> _hello(String addr, int port, Duration timeout, {String? expectId}) async {
    try {
      final r = await http.get(Uri.http('$addr:$port', '/v1/hello')).timeout(timeout);
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map || j['k'] != _kMagic) return null;
      if (expectId != null && j['id'] != expectId) return null;
      return addr;
    } catch (_) {
      return null;
    }
  }

  /// Adreslerin hepsini aynı anda dener, ilk yanıt vereni döndürür.
  Future<String?> _firstReachable(List<String> addrs, int port, Duration timeout, {String? expectId}) async {
    if (addrs.isEmpty) return null;
    final c = Completer<String?>();
    var pending = addrs.length;
    for (final a in addrs) {
      _hello(a, port, timeout, expectId: expectId).then((r) {
        pending--;
        if (r != null && !c.isCompleted) c.complete(r);
        if (pending == 0 && !c.isCompleted) c.complete(null);
      });
    }
    return c.future;
  }

  Future<String?> _reachable(Peer p, {Duration timeout = const Duration(seconds: 3)}) async {
    if (p.online && p.addrs.isNotEmpty) return p.addrs.first;
    return _firstReachable(p.addrs, p.port, timeout, expectId: p.id);
  }

  // ---------------------------------------------------------------- eşleştirme

  /// Bilgisayar: QR ve 6 haneli kod üretir; 5 dakika açık kalır.
  Future<String> openPairing() async {
    final kp = await PairCrypto.newKeyPair();
    final pub = await PairCrypto.publicBytes(kp);
    pairSession = PairSession(kp, pub, randomBytes(16), _newCode(), DateTime.now().add(const Duration(minutes: 5)));
    _announce();
    notifyListeners();
    return pairingQr();
  }

  String _newCode() {
    final b = randomBytes(4);
    final v = ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) & 0x7fffffff;
    return (v % 1000000).toString().padLeft(6, '0');
  }

  Future<String> pairingQr() async {
    final s = pairSession!;
    final addrs = await localAddresses();
    return Uri(scheme: 'pusulakopru', host: 'pair', queryParameters: {
      'v': '1',
      'id': myId,
      'n': myName,
      'p': platform,
      'a': addrs.take(5).join(','),
      'port': '$port',
      'k': b64u(s.pub),
      't': b64u(s.token),
    }).toString();
  }

  void closePairing() {
    pairSession = null;
    _announce();
    notifyListeners();
  }

  Future<void> _handlePair(HttpRequest req) async {
    final s = pairSession;
    final body = await _readAll(req, 64 * 1024);
    if (s == null || s.expired) return _reply(req, 404);
    final j = Map<String, dynamic>.from(jsonDecode(utf8.decode(body)) as Map);
    final mode = j['mode']?.toString() ?? 'qr';
    final clientPub = unb64u(j['pub'] as String);
    final proof = unb64u(j['proof'] as String);
    final auth = mode == 'code' ? Uint8List.fromList(utf8.encode(s.code)) : s.token;
    final expected = await PairCrypto.proof(auth, 'kopru-pair-1', clientPub, s.pub);
    if (!sameBytes(expected, proof)) {
      s.attempts++;
      if (mode == 'code' && s.attempts >= 3) {
        s.code = _newCode(); // tahmin etmeyi zorlaştır
        s.attempts = 0;
        notifyListeners();
      }
      return _replyJson(req, {'error': 'code'}, 403);
    }
    final key = await PairCrypto.derive(s.keyPair, clientPub, auth);
    final id = j['id'].toString();
    peers.removeWhere((p) => p.id == id);
    final peer = Peer(
      id: id,
      name: j['n']?.toString() ?? 'Cihaz',
      platform: j['p']?.toString() ?? '',
      key: PairKey(key),
      addrs: [if (req.connectionInfo != null) req.connectionInfo!.remoteAddress.address],
      port: (j['port'] as num?)?.toInt() ?? kPort,
    )..lastSeen = DateTime.now();
    peers.add(peer);
    _selectedId = peer.id;
    await _prefs.setString('selected', peer.id);
    await _savePeers();
    pairSession = null;
    final reply = await PairCrypto.proof(auth, 'kopru-pair-2', s.pub, clientPub);
    await _replyJson(req, {'id': myId, 'n': myName, 'p': platform, 'port': port, 'proof': b64u(reply)});
    _announce();
    _emit(KopruEvent('paired', peer: peer));
    notifyListeners();
  }

  /// Telefon: bilgisayardaki QR'ı okuttuktan sonra.
  Future<Peer> pairWithQr(String qr) async {
    final u = Uri.parse(qr.trim());
    if (u.scheme != 'pusulakopru' || u.host != 'pair') {
      throw const KopruError('Bu bir Pusula Köprü kodu değil.');
    }
    final q = u.queryParameters;
    final addrs = (q['a'] ?? '').split(',').where((e) => e.isNotEmpty).toList();
    final port = int.tryParse(q['port'] ?? '') ?? kPort;
    final pub = unb64u(q['k'] ?? '');
    final token = unb64u(q['t'] ?? '');
    if (pub.length != 32 || token.length < 16 || addrs.isEmpty) throw const KopruError('Kod eksik okundu, tekrar dene.');
    final addr = await _firstReachable(addrs, port, const Duration(seconds: 4), expectId: q['id']);
    if (addr == null) {
      throw const KopruError('Bilgisayara ulaşılamadı. İki cihaz da aynı Wi-Fi\'de mi? '
          'Bilgisayarda Windows güvenlik duvarı sorduysa "İzin ver" de.');
    }
    return _pairWith(addr, port, pub, token, 'qr');
  }

  /// Telefon: yakındaki bilgisayarı seçip 6 haneli kodu girince.
  Future<Peer> pairWithCode(NearbyDevice d, String code) async {
    final c = code.replaceAll(RegExp(r'\D'), '');
    if (c.length != 6) throw const KopruError('Kod 6 haneli olmalı.');
    final http.Response r;
    try {
      r = await http.get(Uri.http('${d.address}:${d.port}', '/v1/pair/info')).timeout(const Duration(seconds: 4));
    } catch (_) {
      throw const KopruError('Bilgisayara ulaşılamadı.');
    }
    if (r.statusCode != 200) throw const KopruError('Bilgisayarda eşleştirme penceresi kapanmış.');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    return _pairWith(d.address, d.port, unb64u(j['pub'] as String), Uint8List.fromList(utf8.encode(c)), 'code');
  }

  Future<Peer> _pairWith(String addr, int port, Uint8List serverPub, Uint8List auth, String mode) async {
    final kp = await PairCrypto.newKeyPair();
    final pub = await PairCrypto.publicBytes(kp);
    final proof = await PairCrypto.proof(auth, 'kopru-pair-1', pub, serverPub);
    final http.Response r;
    try {
      r = await http
          .post(Uri.http('$addr:$port', '/v1/pair'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'mode': mode,
                'id': myId,
                'n': myName,
                'p': platform,
                'port': this.port,
                'pub': b64u(pub),
                'proof': b64u(proof),
              }))
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      throw const KopruError('Bilgisayara ulaşılamadı.');
    }
    if (r.statusCode == 403) {
      throw KopruError(mode == 'code' ? 'Kod yanlış. Bilgisayardaki kodu tekrar gir.' : 'Kod geçersiz, bilgisayarda yeni kod aç.');
    }
    if (r.statusCode == 404) throw const KopruError('Bilgisayarda eşleştirme penceresi kapanmış.');
    if (r.statusCode != 200) throw const KopruError('Eşleştirme başarısız oldu.');
    final j = Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
    final expected = await PairCrypto.proof(auth, 'kopru-pair-2', serverPub, pub);
    if (!sameBytes(expected, unb64u(j['proof'] as String))) {
      throw const KopruError('Bilgisayar doğrulanamadı; eşleştirme durduruldu.');
    }
    final key = await PairCrypto.derive(kp, serverPub, auth);
    final id = j['id'].toString();
    peers.removeWhere((p) => p.id == id);
    final peer = Peer(
      id: id,
      name: j['n']?.toString() ?? 'Bilgisayar',
      platform: j['p']?.toString() ?? '',
      key: PairKey(key),
      addrs: [addr],
      port: (j['port'] as num?)?.toInt() ?? port,
    )..lastSeen = DateTime.now();
    peers.add(peer);
    _selectedId = peer.id;
    await _prefs.setString('selected', peer.id);
    await _savePeers();
    nearby.remove(id);
    _emit(KopruEvent('paired', peer: peer));
    notifyListeners();
    if (isPhone) {
      sendStatus(only: peer);
      Native.requestNotifications();
      if (background) Native.setBackground(true);
    }
    return peer;
  }

  Future<void> unpair(Peer p) async {
    await _send(p, {'t': 'unpair'});
    peers.removeWhere((x) => x.id == p.id);
    phoneNotifs.removeWhere((n) => n.peerId == p.id);
    await _savePeers();
    if (peers.isEmpty) Native.setBackground(false);
    notifyListeners();
  }

  // ---------------------------------------------------------------- iletiler

  Future<Map<String, dynamic>?> _send(Peer p, Map<String, dynamic> m) async {
    final body = await p.key.sealJson(_stamp(m));
    final tried = <String>{};
    Future<Map<String, dynamic>?> tryAddr(String a) async {
      tried.add(a);
      try {
        final r = await http
            .post(Uri.http('$a:${p.port}', '/v1/msg'),
                headers: {'x-k-from': myId, 'x-k-port': '$port', 'content-type': 'application/octet-stream'},
                body: body)
            .timeout(const Duration(seconds: 6));
        if (r.statusCode != 200) return null;
        _seen(p, a, null);
        return await p.key.openJson(r.bodyBytes);
      } catch (_) {
        return null;
      }
    }

    for (final a in List<String>.from(p.addrs)) {
      final r = await tryAddr(a);
      if (r != null) return r;
      if (p.online) break; // biliniyor ama yanıt vermedi
    }
    final a = await _reachable(p);
    if (a != null && !tried.contains(a)) return tryAddr(a);
    return null;
  }

  Future<bool> sendText(Peer p, String text, {bool open = false}) async {
    final t = text.trim();
    if (t.isEmpty) return false;
    final ok = await _send(p, {'t': 'text', 'text': t, if (open) 'open': true}) != null;
    if (ok) {
      await _addHistory(HistoryItem(
          kind: looksLikeLink(t) ? 'link' : 'text', name: t, incoming: false, peerName: p.name, at: DateTime.now()));
    }
    return ok;
  }

  /// Bu cihazın panosunu karşıya gönderir.
  Future<bool?> sendClipboard(Peer p) async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim() ?? '';
    if (t.isEmpty) return null;
    final ok = await _send(p, {'t': 'clip', 'text': t.length > 100000 ? t.substring(0, 100000) : t}) != null;
    if (ok) {
      await _addHistory(HistoryItem(
          kind: looksLikeLink(t) ? 'link' : 'text', name: t, incoming: false, peerName: p.name, at: DateTime.now()));
    }
    return ok;
  }

  Future<bool> ring(Peer p) async => await _send(p, {'t': 'ring'}) != null;
  Future<bool> stopRemoteRing(Peer p) async => await _send(p, {'t': 'ringStop'}) != null;
  Future<bool> lockComputer(Peer p) async => await _send(p, {'t': 'lock'}) != null;
  Future<bool> media(Peer p, String key) async => await _send(p, {'t': 'media', 'key': key}) != null;

  /// Bilgisayar: telefondaki bir bildirime yanıt.
  Future<bool> replyNotif(PhoneNotif n, String text) async {
    final p = peerById(n.peerId);
    if (p == null) return false;
    final r = await _send(p, {'t': 'notifReply', 'key': n.key, 'text': text});
    final ok = r?['ok'] == true;
    if (ok) {
      n.replied = text;
      notifyListeners();
    }
    return ok;
  }

  void dismissNotif(PhoneNotif n) {
    phoneNotifs.remove(n);
    notifyListeners();
  }

  /// Telefon: bildirimi bilgisayar(lar)a ilet.
  void _mirrorOut(Map<String, dynamic> m) {
    if (!mirror) return;
    for (final p in peers.where((p) => p.online && p.isComputer)) {
      _send(p, {'t': 'notif', ...m});
    }
  }

  /// Windows: medya ve ses tuşları (telefondan kumanda).
  Future<void> _mediaKey(String key) async {
    const codes = {'playpause': 179, 'next': 176, 'prev': 177, 'volup': 175, 'voldown': 174, 'mute': 173};
    final c = codes[key];
    if (c == null) return;
    final times = (key == 'volup' || key == 'voldown') ? 3 : 1;
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        '\$w = New-Object -ComObject WScript.Shell; 1..$times | ForEach-Object { \$w.SendKeys([char]$c) }',
      ]);
    } catch (_) {}
  }

  /// Telefon: son ekran görüntüsünü gönderir. null: gönderildi (toplu kimlik döner)
  Future<(String?, String?)> sendLatestScreenshot(Peer p) async {
    final r = await Native.latestScreenshot();
    if (r == null) return (null, 'Ekran görüntüsü okunamadı');
    if (r['permission'] == true) return (null, 'Fotoğraflara erişim izni ver, sonra tekrar dene');
    final path = r['path']?.toString();
    if (path == null) return (null, 'Ekran görüntüsü bulunamadı');
    return (sendFiles(p, [path]), null);
  }

  Future<void> sendStatus({Peer? only}) async {
    final b = await Native.battery();
    final m = {
      't': 'status',
      ..._statusFields(),
      if (b != null && b.$1 >= 0) 'battery': b.$1,
      if (b != null) 'charging': b.$2,
    };
    for (final p in only != null ? [only] : peers.where((p) => p.online).toList()) {
      final r = await _send(p, m);
      if (r != null) {
        final n = r['name']?.toString();
        if (n != null && n.isNotEmpty && n != p.name) {
          p.name = n;
          _savePeers();
          notifyListeners();
        }
      }
    }
  }

  void dismissIncoming() {
    lastIncoming = null;
    notifyListeners();
  }

  Future<void> _pollClipboard() async {
    if (!Platform.isWindows) return;
    String? t;
    try {
      t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return;
    }
    if (t == null || t.trim().isEmpty || t == _lastClipSeen) return;
    _lastClipSeen = t;
    if (!_clipPrimed) {
      // Açılıştaki pano gönderilmez; yalnız bundan sonra kopyalananlar
      _clipPrimed = true;
      return;
    }
    myClip = t;
    myClipAt = DateTime.now();
    notifyListeners();
    if (!clipShare) return;
    final text = t.length > 100000 ? t.substring(0, 100000) : t;
    for (final p in peers.where((p) => p.online && p.isPhone)) {
      _send(p, {'t': 'clip', 'text': text});
    }
  }

  // ---------------------------------------------------------------- dosyalar

  /// Dosyaları sırayla gönderir. Toplu gönderimin kimliğini döndürür (gönderim ekranı için).
  /// Klasörler içindeki dosyalarla birlikte gönderilir; karşıda aynı klasör yapısı kurulur.
  String sendFiles(Peer p, List<String> paths) {
    final batch = b64u(randomBytes(6));
    final items = <(ActiveTransfer, File)>[];
    void add(File f, String dir) {
      final t = ActiveTransfer(
        id: b64u(randomBytes(9)),
        name: f.path.split(RegExp(r'[\\/]')).last,
        size: f.lengthSync(),
        incoming: false,
        peerId: p.id,
        batch: batch,
        dir: dir,
      );
      active.add(t);
      items.add((t, f));
    }

    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.file) {
        add(File(path), '');
      } else if (type == FileSystemEntityType.directory) {
        final root = Directory(path);
        final base = root.path.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty).last;
        try {
          for (final e in root.listSync(recursive: true, followLinks: false)) {
            if (e is! File) continue;
            final rel = e.parent.path.substring(root.path.length).replaceAll('\\', '/');
            add(e, '$base$rel'.replaceAll(RegExp(r'/+$'), ''));
            if (items.length >= 2000) break;
          }
        } catch (_) {}
      }
    }
    notifyListeners();
    () async {
      for (final (t, f) in items) {
        if (t.cancelRequested) {
          t.state = 'cancelled';
          continue;
        }
        await _sendFile(p, f, t);
        await _addHistory(HistoryItem(
          kind: 'file',
          name: t.name,
          incoming: false,
          peerName: p.name,
          at: DateTime.now(),
          size: t.size,
          location: f.path,
          mime: mimeFor(t.name),
          ok: t.state == 'done',
        ));
      }
      _cleanupLater();
    }();
    return batch;
  }

  void cancelBatch(String batch) {
    for (final t in active.where((t) => t.batch == batch && !t.finished)) {
      t.cancelRequested = true;
      t.abort?.call();
    }
    notifyListeners();
  }

  void _cleanupLater() {
    Future.delayed(const Duration(minutes: 2), () {
      active.removeWhere((t) => t.finished);
      notifyListeners();
    });
  }

  static List<int> _aad(String id, int index, int flags) => <int>[
        ...utf8.encode(id),
        (index >> 24) & 0xff,
        (index >> 16) & 0xff,
        (index >> 8) & 0xff,
        index & 0xff,
        flags,
      ];

  Future<void> _sendFile(Peer p, File f, ActiveTransfer t) async {
    t.state = 'running';
    notifyListeners();
    final addr = await _reachable(p);
    if (addr == null) {
      t.state = 'failed';
      notifyListeners();
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    RandomAccessFile? raf;
    try {
      final req = await client.post(addr, p.port, '/v1/file');
      t.abort = () {
        try {
          req.abort();
        } catch (_) {}
      };
      req.headers.set('x-k-from', myId);
      req.headers.set('x-k-port', '$port');
      final meta = await p.key.sealJson(_stamp({'name': t.name, 'size': t.size, 'id': t.id, if (t.dir.isNotEmpty) 'dir': t.dir}));
      req.headers.set('x-k-meta', b64u(meta));
      req.headers.contentType = ContentType.binary;
      req.bufferOutput = false;
      raf = await f.open();
      var index = 0;
      var sent = 0;
      final sw = Stopwatch()..start();
      var lastTick = 0;
      var lastBytes = 0;
      while (true) {
        if (t.cancelRequested) throw const KopruError('İptal edildi');
        final chunk = await raf.read(kChunk);
        final last = sent + chunk.length >= t.size || chunk.isEmpty;
        final flags = last ? 1 : 0;
        final sealed = await p.key.seal(chunk, aad: _aad(t.id, index, flags));
        final header = ByteData(5)
          ..setUint32(0, sealed.length)
          ..setUint8(4, flags);
        req.add(header.buffer.asUint8List());
        req.add(sealed);
        await req.flush();
        sent += chunk.length;
        index++;
        t.done = sent;
        final ms = sw.elapsedMilliseconds;
        if (ms - lastTick >= 250 || last) {
          final dt = (ms - lastTick) / 1000;
          if (dt > 0) {
            final inst = (sent - lastBytes) / dt;
            t.speed = t.speed == 0 ? inst : t.speed * 0.7 + inst * 0.3;
          }
          lastTick = ms;
          lastBytes = sent;
          notifyListeners();
        }
        if (last) break;
      }
      final res = await req.close().timeout(const Duration(minutes: 2));
      await res.drain<void>();
      t.state = res.statusCode == 200 ? 'done' : 'failed';
    } catch (_) {
      t.state = t.cancelRequested ? 'cancelled' : 'failed';
    } finally {
      await raf?.close();
      client.close(force: true);
      t.abort = null;
      notifyListeners();
    }
  }

  Future<Directory> _incomingDir() async {
    if (Platform.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
      final d = Directory('$home\\Downloads\\Pusula Köprü');
      if (!d.existsSync()) d.createSync(recursive: true);
      return d;
    }
    final d = Directory('${(await getTemporaryDirectory()).path}/gelen');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// Windows'ta gelen dosyaların klasörü.
  Future<String> downloadsFolder() async => (await _incomingDir()).path;

  String _safeName(String n) {
    var s = n.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (s.isEmpty || s == '.' || s == '..') s = 'dosya';
    if (s.length > 150) {
      final dot = s.lastIndexOf('.');
      s = dot > 0 && s.length - dot < 12 ? s.substring(0, 140) + s.substring(dot) : s.substring(0, 150);
    }
    return s;
  }

  File _unique(Directory dir, String name) {
    var f = File('${dir.path}${Platform.pathSeparator}$name');
    var n = 1;
    while (f.existsSync()) {
      final dot = name.lastIndexOf('.');
      final alt = dot > 0 ? '${name.substring(0, dot)} ($n)${name.substring(dot)}' : '$name ($n)';
      f = File('${dir.path}${Platform.pathSeparator}$alt');
      n++;
    }
    return f;
  }

  Future<void> _receiveFile(HttpRequest req, Peer peer) async {
    final Map<String, dynamic> meta;
    try {
      meta = await peer.key.openJson(unb64u(req.headers.value('x-k-meta') ?? ''));
    } catch (_) {
      return _reply(req, 403);
    }
    if (!_fresh(meta)) return _reply(req, 409);
    _seen(peer, req.connectionInfo?.remoteAddress.address, int.tryParse(req.headers.value('x-k-port') ?? ''));
    final id = meta['id'].toString();
    final name = _safeName(meta['name']?.toString() ?? 'dosya');
    // Klasör gönderimi: alt klasörler (güvenli adlarla, en fazla 8 düzey)
    final sub = (meta['dir']?.toString() ?? '')
        .split(RegExp(r'[\\/]'))
        .map((e) => _safeName(e))
        .where((e) => e.isNotEmpty && e != 'dosya' && !e.startsWith('.'))
        .take(8)
        .join('/');
    final size = (meta['size'] as num?)?.toInt() ?? 0;
    final t = ActiveTransfer(id: id, name: name, size: size, incoming: true, peerId: peer.id, batch: id)..state = 'running';
    active.add(t);
    notifyListeners();

    final dir = await _incomingDir();
    final part = File('${dir.path}${Platform.pathSeparator}.$id.part');
    final sink = part.openWrite();
    var buf = Uint8List(0);
    var index = 0;
    var received = 0;
    var gotLast = false;
    var ok = false;
    final sw = Stopwatch()..start();
    var lastTick = 0;
    var lastBytes = 0;
    try {
      await for (final data in req) {
        if (gotLast) continue;
        if (buf.isEmpty) {
          buf = data;
        } else {
          final b = BytesBuilder(copy: false)
            ..add(buf)
            ..add(data);
          buf = b.takeBytes();
        }
        var off = 0;
        while (buf.length - off >= 5) {
          final bd = ByteData.sublistView(buf, off, off + 5);
          final len = bd.getUint32(0);
          final flags = bd.getUint8(4);
          if (len > kChunk + 64) throw const FormatException('Bozuk parça');
          if (buf.length - off - 5 < len) break;
          final sealed = Uint8List.sublistView(buf, off + 5, off + 5 + len);
          final plain = await peer.key.open(sealed, aad: _aad(id, index, flags));
          sink.add(plain);
          received += plain.length;
          index++;
          off += 5 + len;
          if (flags & 1 == 1) {
            gotLast = true;
            break;
          }
        }
        buf = off == 0 ? buf : Uint8List.fromList(Uint8List.sublistView(buf, off));
        t.done = received;
        final ms = sw.elapsedMilliseconds;
        if (ms - lastTick >= 250) {
          final dt = (ms - lastTick) / 1000;
          final inst = (received - lastBytes) / dt;
          t.speed = t.speed == 0 ? inst : t.speed * 0.7 + inst * 0.3;
          lastTick = ms;
          lastBytes = received;
          notifyListeners();
        }
      }
      await sink.close();
      ok = gotLast && received == size;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      ok = false;
    }

    if (!ok) {
      try {
        part.deleteSync();
      } catch (_) {}
      t.state = 'failed';
      notifyListeners();
      _cleanupLater();
      return _reply(req, 400);
    }

    String? location;
    try {
      if (Platform.isAndroid) {
        location = await Native.saveToDownloads(part.path, name, mimeFor(name), sub: sub);
      } else {
        final target = sub.isEmpty ? dir : Directory('${dir.path}\\${sub.replaceAll('/', '\\')}');
        if (!target.existsSync()) target.createSync(recursive: true);
        final dest = _unique(target, name);
        await part.rename(dest.path);
        location = dest.path;
      }
    } catch (_) {
      location = null;
    }
    t.state = location != null ? 'done' : 'failed';
    t.done = size;
    await _reply(req, location != null ? 200 : 500);
    await _addHistory(HistoryItem(
      kind: 'file',
      name: name,
      incoming: true,
      peerName: peer.name,
      at: DateTime.now(),
      size: size,
      location: location,
      mime: mimeFor(name),
      ok: location != null,
    ));
    if (location != null) {
      _emit(KopruEvent('received', peer: peer, text: name));
      _notifyReceived(peer, sub.isEmpty ? name : '${sub.split('/').first}/', location, name);
    }
    notifyListeners();
    _cleanupLater();
  }

  // Arka arkaya gelen dosyalar için tek bildirim
  Timer? _recvTimer;
  final _recvNames = <String>[];
  String? _recvLoc;
  String? _recvMime;
  void _notifyReceived(Peer peer, String label, String location, String name) {
    if (!_recvNames.contains(label)) _recvNames.add(label);
    _recvLoc = location;
    _recvMime = mimeFor(name);
    _recvTimer?.cancel();
    _recvTimer = Timer(const Duration(milliseconds: 1500), () {
      final n = _recvNames.length;
      final title = n == 1 ? '${peer.name} gönderdi' : '${peer.name}: $n öğe geldi';
      final body = n == 1 ? _recvNames.first : _recvNames.take(3).join(', ') + (n > 3 ? '…' : '');
      final loc = _recvLoc;
      final single = n == 1 && !_recvNames.first.endsWith('/');
      Notifier.show(title, body,
          uri: Platform.isAndroid && single ? loc : null,
          mime: _recvMime,
          onClick: Platform.isWindows && loc != null ? () => Process.run('explorer.exe', ['/select,', loc]) : null);
      _recvNames.clear();
    });
  }

  Future<void> openHistoryItem(HistoryItem h) async {
    final loc = h.location;
    if (loc == null) return;
    if (Platform.isAndroid) {
      if (loc.startsWith('content://')) {
        await Native.openUri(loc, h.mime);
      } else {
        await Native.openDownloads();
      }
    } else if (Platform.isWindows) {
      if (File(loc).existsSync()) {
        await Process.run('explorer.exe', ['/select,', loc]);
      }
    }
  }

  @override
  void dispose() {
    _announceTimer?.cancel();
    _statusTimer?.cancel();
    _clipTimer?.cancel();
    _probeTimer?.cancel();
    _server?.close(force: true);
    _udp?.close();
    super.dispose();
  }
}

class KopruError implements Exception {
  const KopruError(this.message);
  final String message;
  @override
  String toString() => message;
}
