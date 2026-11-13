import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Hmac, SecretKey, Sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../updater.dart' show appVersion;
import '../l10n.dart';
import 'crypto.dart';
import 'models.dart';
import 'native.dart';
import 'notifier.dart';
import 'relay.dart';
import 'spake2.dart';
import 'win_input.dart';
import 'words.dart';

part 'bt_send.dart';
part 'code_send.dart';

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
  NearbyDevice(this.id, this.name, this.platform, this.address, this.port, this.seen, {this.pub});
  final String id;
  final String name;
  final String platform;
  String address;
  int port;
  DateTime seen;
  Uint8List? pub; // "Yakındakilerden al" açıkken tek seferlik açık anahtar
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
  bool relayOn = true; // farklı ağdayken sunucu üzerinden bağlan
  final _relays = <String, RelayLink>{};
  final _pendingReplies = <String, Completer<Map<String, dynamic>?>>{};

  // Pano geçmişi (yalnız bellekte; şifre gibi görünenler yazılmaz)
  final clipHistory = <ClipItem>[];

  // Fotoğraf yedekleme (telefon)
  bool backupOn = false;
  String? backupPeerId;
  int backupSince = 0; // saniye
  int backupCount = 0;
  DateTime? backupLast;
  bool backupRunning = false;
  Timer? _backupTimer;
  // Bilgisayar: telefonlardan gelen yedek sayısı
  final backupReceived = <String, int>{};
  bool browseAllowed = true; // bilgisayar bu telefonun fotoğraflarına göz atabilsin

  // Sağ tık menüsünden gelen dosyalar (Windows, "--send")
  List<String> pendingSend = const [];

  // Telefonu bul
  bool locateAllowed = false; // telefon: bilgisayar konumu görebilsin

  // Otomatik eylemler
  bool autoLock = false; // bilgisayar: telefon uzaklaşınca kilitle
  bool autoWake = false; // telefon: eve gelince bilgisayarı uyandır
  bool batteryAlerts = true; // bilgisayar: telefonun pili azaldı / doldu
  final _wasNear = <String, DateTime>{};
  final _lockedFor = <String>{};
  final _lastBatteryAlert = <String, String>{};
  DateTime? _lastWake;
  Timer? _autoTimer;

  // Eşleştirmeden gönderme
  final visible = <String, NearbyDevice>{}; // "Yakındakilerden al" açık olan cihazlar
  DateTime? visibleUntil; // bu cihaz görünür mü
  dynamic _nearKeyPair; // SimpleKeyPair
  Uint8List? _nearPub;
  final _offers = <String, NearOffer>{};
  bool get isVisible => visibleUntil != null && DateTime.now().isBefore(visibleUntil!);
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

  /// İnternetsiz gönderme (Android, Bluetooth + doğrudan Wi-Fi)
  late final BtHub bt = BtHub._(this);
  Stream<KopruEvent> get events => _events.stream;
  void _emit(KopruEvent e) => _events.add(e);

  void _touch() => notifyListeners();

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
    relayOn = _prefs.getBool('relay') ?? true;
    backupOn = _prefs.getBool('backupOn') ?? false;
    backupPeerId = _prefs.getString('backupPeer');
    backupSince = _prefs.getInt('backupSince') ?? 0;
    backupCount = _prefs.getInt('backupCount') ?? 0;
    final bl = _prefs.getInt('backupLast');
    if (bl != null) backupLast = DateTime.fromMillisecondsSinceEpoch(bl);
    browseAllowed = _prefs.getBool('browseAllowed') ?? true;
    locateAllowed = _prefs.getBool('locateAllowed') ?? false;
    autoLock = _prefs.getBool('autoLock') ?? false;
    autoWake = _prefs.getBool('autoWake') ?? false;
    batteryAlerts = _prefs.getBool('batteryAlerts') ?? true;
    try {
      final r = jsonDecode(_prefs.getString('backupReceived') ?? '{}') as Map;
      r.forEach((k, v) => backupReceived[k.toString()] = (v as num).toInt());
    } catch (_) {}
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
      unawaited(bt.init());
      Native.onNotification = _mirrorOut;
      Native.onNotificationRemoved = (key) {
        if (!mirror) return;
        for (final p in peers.where((p) => p.online && p.isComputer)) {
          _send(p, {'t': 'notifGone', 'key': key});
        }
      };
      if (peers.isNotEmpty && background) Native.setBackground(true);
    }
    if (Platform.isWindows) {
      _applyAutostart(autostart);
      _loadMacs();
    }
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
    _ensureRelays();
    _autoTimer = Timer.periodic(const Duration(seconds: 15), (_) => _automations());
    if (Platform.isWindows) {
      _registerContextMenu();
      if (pendingSend.isNotEmpty) {
        final paths = pendingSend;
        pendingSend = const [];
        Future.delayed(const Duration(seconds: 3), () => _sendFromShell(paths));
      }
    }
    if (isPhone) {
      _backupTimer = Timer.periodic(const Duration(minutes: 10), (_) => runBackup());
      Future.delayed(const Duration(seconds: 20), runBackup);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- sunucu üzerinden

  Future<void> setRelay(bool v) async {
    relayOn = v;
    await _prefs.setBool('relay', v);
    if (v) {
      _ensureRelays();
    } else {
      for (final l in _relays.values) {
        await l.close();
      }
      _relays.clear();
    }
    notifyListeners();
  }

  Future<void> _ensureRelays() async {
    if (!relayOn) return;
    for (final p in peers) {
      if (_relays.containsKey(p.id)) continue;
      final box = await relayBox(p.key);
      if (_relays.containsKey(p.id) || !peers.contains(p)) continue;
      final link = RelayLink(
        peer: p,
        box: box,
        myId: myId,
        onMessage: (sealed) => _onRelayed(p, sealed),
        onChange: notifyListeners,
      );
      _relays[p.id] = link;
      link.start();
    }
  }

  Future<void> _dropRelay(String id) async {
    await _relays.remove(id)?.close();
  }

  Future<void> _onRelayed(Peer p, Uint8List sealed) async {
    try {
      final m = await p.key.openJson(sealed);
      if (!_fresh(m)) return;
      p.relayOnline = true;
      final t = m['t']?.toString();
      if (t == 'rfile') {
        _receiveRelayed(p, m);
        return;
      }
      if (t == 'reply') {
        final c = _pendingReplies.remove(m['rid']?.toString());
        final d = m['data'];
        c?.complete(d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{'ok': true});
        return;
      }
      final out = await _onMessage(p, m);
      final rid = m['rid']?.toString();
      if (rid != null) {
        // Sunucu üzerinden gelen soruya yanıt (ör. telefondaki fotoğraf listesi)
        _relays[p.id]?.send(await p.key.sealJson(_stamp({'t': 'reply', 'rid': rid, 'data': out ?? {'ok': true}})));
      }
    } catch (_) {}
  }

  /// Yanıt gerektiren iletiler: sunucu üzerinden de yanıt beklenir.
  static const _needsReply = {'mlist', 'mthumb', 'mpull', 'notifReply', 'ping', 'locate'};

  /// Bağlantı yolu: arayüzde "Aynı Wi-Fi · doğrudan" ya da "İnternet üzerinden · şifreli"
  bool viaRelay(Peer p) => !p.lanOnline && p.relayOnline;

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

  /// Gezgin'deki sağ tık menüsü: "Pusula Köprü ile telefona gönder" (HKCU, yönetici izni gerekmez).
  Future<void> _registerContextMenu() async {
    final exe = Platform.resolvedExecutable;
    final label = L('Pusula Köprü ile telefona gönder');
    for (final root in [r'HKCU\Software\Classes\*\shell\PusulaKopru', r'HKCU\Software\Classes\Directory\shell\PusulaKopru']) {
      try {
        await Process.run('reg', ['add', root, '/ve', '/t', 'REG_SZ', '/d', label, '/f']);
        await Process.run('reg', ['add', root, '/v', 'Icon', '/t', 'REG_SZ', '/d', exe, '/f']);
        await Process.run('reg', ['add', '$root\\command', '/ve', '/t', 'REG_SZ', '/d', '"$exe" --send "%1"', '/f']);
      } catch (_) {}
    }
  }

  /// Sağ tık menüsünden gelen dosyaları seçili (ya da ilk) telefona gönderir. Arka arkaya gelenler birleşir.
  final _shellQueue = <String>[];
  Timer? _shellTimer;
  Future<bool> _sendFromShell(List<String> paths) async {
    final target = (selected?.isPhone == true ? selected : null) ??
        peers.where((p) => p.isPhone && p.online).firstOrNull ??
        peers.where((p) => p.isPhone).firstOrNull;
    if (target == null) {
      Notifier.showWindow?.call();
      await Notifier.show(L('Gönderilemedi'), L('Önce bir telefon eşleştir'), always: true);
      return false;
    }
    _shellQueue.addAll(paths.where((e) => e.isNotEmpty));
    _shellTimer?.cancel();
    _shellTimer = Timer(const Duration(milliseconds: 700), () {
      final list = _shellQueue.toSet().toList();
      _shellQueue.clear();
      if (list.isEmpty) return;
      sendFiles(target, list);
      Notifier.show(L('{0} cihazına gönderiliyor', [target.name]),
          list.length == 1 ? list.first.split(RegExp(r'[\\/]')).last : L('{0} öğe', [list.length]),
          always: true);
    });
    return true;
  }

  /// Windows: aynı bilgisayarda Pusula Köprü zaten açıksa onu öne getirir.
  Future<bool> _otherInstance() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:$kPort/v1/hello')).timeout(const Duration(milliseconds: 800));
      if (r.statusCode != 200) return false;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is! Map || j['id'] != myId) return false;
      if (pendingSend.isNotEmpty) {
        await http
            .post(Uri.parse('http://127.0.0.1:$kPort/v1/local/files'),
                headers: {'content-type': 'application/json'}, body: jsonEncode({'paths': pendingSend}))
            .timeout(const Duration(seconds: 5));
      } else {
        await http.get(Uri.parse('http://127.0.0.1:$kPort/v1/local/show')).timeout(const Duration(seconds: 2));
      }
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

  void _addClip(String text, String from) {
    final t = text.trim();
    if (t.isEmpty || looksSecret(t)) return;
    clipHistory.removeWhere((c) => c.text == t);
    clipHistory.insert(0, ClipItem(t.length > 5000 ? t.substring(0, 5000) : t, from, DateTime.now()));
    if (clipHistory.length > 20) clipHistory.removeRange(20, clipHistory.length);
  }

  void clearClipHistory() {
    clipHistory.clear();
    notifyListeners();
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
      startError = L('Bağlantı noktası açılamadı. Pusula Köprü başka bir pencerede açık olabilir.');
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
      if (req.method == 'POST' && path == '/v1/near/offer') return await _handleOffer(req);
      if (req.method == 'POST' && path == '/v1/near/file') return await _handleNearFile(req);

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
    if (path == '/v1/local/files' && req.method == 'POST') {
      final j = jsonDecode(utf8.decode(await _readAll(req, 1 << 20)));
      final paths = j is Map ? ((j['paths'] as List?) ?? const []).map((e) => e.toString()).toList() : <String>[];
      final ok = await _sendFromShell(paths);
      return await _replyJson(req, {'ok': ok});
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

  Map<String, dynamic> _statusFields() => {'name': myName, 'platform': platform, if (_macs.isNotEmpty) 'macs': _macs};

  // Windows: ağ kartlarının MAC adresleri (telefon "eve gelince uyandır" için kullanır)
  Map<String, String> _macs = {};
  Future<void> _loadMacs() async {
    if (!Platform.isWindows) return;
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $a = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue; if ($a) { "$($_.IPAddress) $($a.MacAddress)" } }',
      ]);
      final out = <String, String>{};
      for (final line in r.stdout.toString().split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length == 2 && RegExp(r'^([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}$').hasMatch(parts[1])) {
          out[parts[0]] = parts[1].replaceAll('-', ':').toUpperCase();
        }
      }
      _macs = out;
    } catch (_) {}
  }

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
        _batteryAlert(peer);
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
            await Notifier.show(L('{0}: bağlantı', [peer.name]), L('Dokun, Pusula\'da aç · {0}', [text]), url: linkUrl(text), always: true);
          }
        } else {
          await Notifier.show(link ? L('{0}: bağlantı', [peer.name]) : L('{0}: metin', [peer.name]), text,
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
          _addClip(text, peer.name);
          peer.clipAt = DateTime.now();
          notifyListeners();
        } else {
          // Telefondan "Panoyu gönder": doğrudan bilgisayarın panosuna
          _lastClipSeen = text;
          _addClip(text, peer.name);
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
        if (Platform.isWindows && !WinInput.key(m['key']?.toString() ?? '', times: (m['key'] == 'volup' || m['key'] == 'voldown') ? 2 : 1)) {
          await _mediaKey(m['key']?.toString() ?? '');
        }
        return null;
      case 'locate':
        if (!isPhone) return {'error': 'yok'};
        if (!locateAllowed) return {'error': 'kapali'};
        final loc = await Native.locate();
        if (loc == null) return {'error': 'yok'};
        if (loc['permission'] == false) return {'error': 'izin'};
        return {'loc': loc};
      case 'input':
        if (Platform.isWindows) await _input(m);
        return null;
      case 'power':
        if (Platform.isWindows) await _power(m['a']?.toString() ?? '');
        return null;
      case 'mlist':
        if (!isPhone) return {'error': 'yok'};
        if (!browseAllowed) return {'error': 'kapali'};
        final items = await Native.listMedia(m['kind']?.toString() ?? 'img', (m['offset'] as num?)?.toInt() ?? 0,
            ((m['limit'] as num?)?.toInt() ?? 60).clamp(1, 120));
        if (items == null) {
          await Notifier.show(L('{0} fotoğraflarına bakmak istiyor', [peer.name]),
              L('Pusula Köprü\'yü açıp fotoğraflara erişim izni ver.'), always: true);
          return {'error': 'izin'};
        }
        return {'items': items};
      case 'mthumb':
        if (!isPhone || !browseAllowed) return {'error': 'kapali'};
        final b = await Native.thumb(m['id']?.toString() ?? '', ((m['px'] as num?)?.toInt() ?? 200).clamp(64, 400));
        return b == null ? {'error': 'yok'} : {'data': base64Encode(b)};
      case 'mpull':
        if (!isPhone || !browseAllowed) return {'error': 'kapali'};
        final wanted = ((m['items'] as List?) ?? const []).whereType<Map>().take(200).toList();
        () async {
          final paths = <String>[];
          for (final it in wanted) {
            final path = await Native.copyMedia(it['id'].toString(), it['name']?.toString() ?? 'dosya');
            if (path != null) paths.add(path);
          }
          if (paths.isNotEmpty) sendFiles(peer, paths, deleteAfter: true);
        }();
        return {'ok': true, 'n': wanted.length};
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
        _dropRelay(peer.id);
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
      final open = j['open']?.toString();
      if (open != null && open.isNotEmpty) {
        final v = visible[id];
        final pub = unb64u(open);
        if (v == null || !sameBytes(v.pub ?? Uint8List(0), pub)) {
          visible[id] = NearbyDevice(id, j['n']?.toString() ?? 'Cihaz', j['p']?.toString() ?? '', d.address.address, port,
              DateTime.now(), pub: pub);
          notifyListeners();
        } else {
          v
            ..address = d.address.address
            ..port = port
            ..seen = DateTime.now();
        }
      } else if (visible.remove(id) != null) {
        notifyListeners();
      }
      final peer = peerById(id);
      if (peer != null) {
        final wasOnline = peer.lanOnline;
        _seen(peer, d.address.address, port);
        if (!wasOnline && isPhone) {
          sendStatus(only: peer);
          if (peer.id == backupPeerId || backupPeerId == null) Future.delayed(const Duration(seconds: 5), runBackup);
        }
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
      if (isVisible && _nearPub != null) 'open': b64u(_nearPub!),
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
    final vb = visible.length;
    visible.removeWhere((_, n) => now.difference(n.seen) > const Duration(seconds: 12));
    if (visibleUntil != null && !isVisible) {
      visibleUntil = null;
      _offers.clear();
      unawaited(bt.advertise(false));
      notifyListeners();
    }
    if (nearby.length != before || visible.length != vb) notifyListeners();
  }

  /// Yayın ulaşmayan ağlarda (misafir Wi-Fi, güvenlik duvarı) bilinen adresleri doğrudan dener.
  Future<void> _probeOffline() async {
    for (final p in peers) {
      if (p.lanOnline) continue;
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
    if (p.lanOnline && p.addrs.isNotEmpty) return p.addrs.first;
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
    await _dropRelay(id);
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
    _ensureRelays();
    notifyListeners();
  }

  /// Telefon: bilgisayardaki QR'ı okuttuktan sonra.
  Future<Peer> pairWithQr(String qr) async {
    final u = Uri.parse(qr.trim());
    if (u.scheme != 'pusulakopru' || u.host != 'pair') {
      throw KopruError(L('Bu bir Pusula Köprü kodu değil.'));
    }
    final q = u.queryParameters;
    final addrs = (q['a'] ?? '').split(',').where((e) => e.isNotEmpty).toList();
    final port = int.tryParse(q['port'] ?? '') ?? kPort;
    final pub = unb64u(q['k'] ?? '');
    final token = unb64u(q['t'] ?? '');
    if (pub.length != 32 || token.length < 16 || addrs.isEmpty) throw KopruError(L('Kod eksik okundu, tekrar dene.'));
    final addr = await _firstReachable(addrs, port, const Duration(seconds: 4), expectId: q['id']);
    if (addr == null) {
      throw KopruError(L('Bilgisayara ulaşılamadı. İki cihaz da aynı Wi-Fi\'de mi? Windows güvenlik duvarı sorduysa "İzin ver" de.'));
    }
    return _pairWith(addr, port, pub, token, 'qr');
  }

  /// Telefon: yakındaki bilgisayarı seçip 6 haneli kodu girince.
  Future<Peer> pairWithCode(NearbyDevice d, String code) async {
    final c = code.replaceAll(RegExp(r'\D'), '');
    if (c.length != 6) throw KopruError(L('Kod 6 haneli olmalı.'));
    final http.Response r;
    try {
      r = await http.get(Uri.http('${d.address}:${d.port}', '/v1/pair/info')).timeout(const Duration(seconds: 4));
    } catch (_) {
      throw KopruError(L('Bilgisayara ulaşılamadı.'));
    }
    if (r.statusCode != 200) throw KopruError(L('Bilgisayarda eşleştirme penceresi kapanmış.'));
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
      throw KopruError(L('Bilgisayara ulaşılamadı.'));
    }
    if (r.statusCode == 403) {
      throw KopruError(mode == 'code' ? L('Kod yanlış. Bilgisayardaki kodu tekrar gir.') : L('Kod geçersiz, bilgisayarda yeni kod aç.'));
    }
    if (r.statusCode == 404) throw KopruError(L('Bilgisayarda eşleştirme penceresi kapanmış.'));
    if (r.statusCode != 200) throw KopruError(L('Eşleştirme başarısız oldu.'));
    final j = Map<String, dynamic>.from(jsonDecode(utf8.decode(r.bodyBytes)) as Map);
    final expected = await PairCrypto.proof(auth, 'kopru-pair-2', serverPub, pub);
    if (!sameBytes(expected, unb64u(j['proof'] as String))) {
      throw KopruError(L('Bilgisayar doğrulanamadı; eşleştirme durduruldu.'));
    }
    final key = await PairCrypto.derive(kp, serverPub, auth);
    final id = j['id'].toString();
    await _dropRelay(id);
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
    _ensureRelays();
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
    await _dropRelay(p.id);
    await _savePeers();
    if (peers.isEmpty) Native.setBackground(false);
    notifyListeners();
  }

  // ---------------------------------------------------------------- iletiler

  Future<Map<String, dynamic>?> _send(Peer p, Map<String, dynamic> m, {Duration replyTimeout = const Duration(seconds: 15)}) async {
    final wantsReply = _needsReply.contains(m['t']);
    final rid = wantsReply ? b64u(randomBytes(9)) : null;
    if (rid != null) m = {...m, 'rid': rid};
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

    final link = _relays[p.id];
    final relayReady = relayOn && link != null && link.connected;
    if (p.lanOnline && p.addrs.isNotEmpty) {
      // Aynı ağda görülüyor: doğrudan
      final r = await tryAddr(p.addrs.first);
      if (r != null) return r;
    }
    if (!(relayReady && p.relayOnline)) {
      // Sunucuda görünmüyor: bilinen yerel adresleri hızlıca (aynı anda) dene
      final a = await _firstReachable(p.addrs.where((x) => !tried.contains(x)).toList(), p.port,
          const Duration(milliseconds: 1500), expectId: p.id);
      if (a != null) {
        final r = await tryAddr(a);
        if (r != null) return r;
      }
    }
    // Aynı ağda değil: sunucu üzerinden (şifreli). Metin gibi kalıcı şeyler karşı taraf çevrim dışıysa
    // sunucuda bekler; çaldırma, kumanda gibi anlık işler beklemez.
    if (relayReady) {
      final keepable = const {'text', 'unpair'}.contains(m['t']);
      if (!p.relayOnline && !keepable) return null;
      if (rid != null) {
        final c = Completer<Map<String, dynamic>?>();
        _pendingReplies[rid] = c;
        if (!link.send(body)) {
          _pendingReplies.remove(rid);
          return null;
        }
        try {
          return await c.future.timeout(replyTimeout);
        } catch (_) {
          _pendingReplies.remove(rid);
          return null;
        }
      }
      if (link.send(body, keep: keepable)) {
        return {'ok': true, 'relay': true, if (!p.relayOnline) 'queued': true};
      }
    }
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
      _addClip(t, L('Bu telefon'));
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

  /// Windows: telefondan dokunmatik yüzey ve klavye.
  Future<void> _input(Map<String, dynamic> m) async {
    int n(String k) => (m[k] as num?)?.round() ?? 0;
    switch (m['k']) {
      case 'move':
        WinInput.move(n('dx'), n('dy'));
      case 'click':
        WinInput.click(right: m['right'] == true, double: m['double'] == true);
      case 'drag':
        WinInput.leftButton(m['down'] == true);
      case 'scroll':
        WinInput.scroll(n('dx'), n('dy'));
      case 'key':
        WinInput.key(m['name']?.toString() ?? '', times: n('times').clamp(1, 20));
      case 'type':
        // Yazı: panoya koy, Ctrl+V, eski panoyu geri yükle
        final text = m['text']?.toString() ?? '';
        if (text.isEmpty) return;
        String? old;
        try {
          old = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
        } catch (_) {}
        _lastClipSeen = text;
        await Clipboard.setData(ClipboardData(text: text));
        await Future.delayed(const Duration(milliseconds: 60));
        WinInput.key('paste');
        await Future.delayed(const Duration(milliseconds: 250));
        if (old != null) {
          _lastClipSeen = old;
          await Clipboard.setData(ClipboardData(text: old));
        }
    }
  }

  Future<void> _power(String a) async {
    try {
      switch (a) {
        case 'lock':
          await Process.run('rundll32.exe', ['user32.dll,LockWorkStation']);
        case 'sleep':
          await Process.run('rundll32.exe', ['powrprof.dll,SetSuspendState', '0,1,0']);
        case 'restart':
          await Process.run('shutdown', ['/r', '/t', '5', '/c', 'Pusula Köprü: telefondan yeniden başlatıldı']);
        case 'shutdown':
          await Process.run('shutdown', ['/s', '/t', '5', '/c', 'Pusula Köprü: telefondan kapatıldı']);
      }
    } catch (_) {}
  }

  // Telefon tarafı: kumanda iletileri (hareketler toplanıp ~30 ms'de bir gönderilir)
  double _mx = 0, _my = 0;
  Timer? _moveTimer;
  void mouseMove(Peer p, double dx, double dy) {
    _mx += dx;
    _my += dy;
    _moveTimer ??= Timer(const Duration(milliseconds: 30), () {
      _moveTimer = null;
      final x = _mx.round(), y = _my.round();
      _mx -= x;
      _my -= y;
      if (x != 0 || y != 0) _send(p, {'t': 'input', 'k': 'move', 'dx': x, 'dy': y});
    });
  }

  double _sx = 0, _sy = 0;
  Timer? _scrollTimer;
  void mouseScroll(Peer p, double dx, double dy) {
    _sx += dx;
    _sy += dy;
    _scrollTimer ??= Timer(const Duration(milliseconds: 50), () {
      _scrollTimer = null;
      final x = _sx.round(), y = _sy.round();
      _sx -= x;
      _sy -= y;
      if (x != 0 || y != 0) _send(p, {'t': 'input', 'k': 'scroll', 'dx': x, 'dy': y});
    });
  }

  Future<bool> input(Peer p, Map<String, dynamic> m) async => await _send(p, {'t': 'input', ...m}) != null;
  Future<bool> power(Peer p, String a) async => await _send(p, {'t': 'power', 'a': a}) != null;

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
    if (r == null) return (null, L('Ekran görüntüsü okunamadı'));
    if (r['permission'] == true) return (null, L('Fotoğraflara erişim izni ver, sonra tekrar dene'));
    final path = r['path']?.toString();
    if (path == null) return (null, L('Ekran görüntüsü bulunamadı'));
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
        final macs = r['macs'];
        if (macs is Map && macs.isNotEmpty) {
          final mac = macs[p.addrs.isNotEmpty ? p.addrs.first : ''] ?? macs.values.first;
          if (mac != null) _prefs.setString('mac:${p.id}', mac.toString());
        }
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
    _addClip(t, L('Bu bilgisayar'));
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
  String sendFiles(Peer p, List<String> paths, {bool deleteAfter = false, bool print = false}) {
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
        print: print,
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
        if (deleteAfter) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
      _cleanupLater();
    }();
    return batch;
  }

  // ---------------------------------------------------------------- otomatik eylemler

  Future<void> setAutoLock(bool v) async {
    autoLock = v;
    await _prefs.setBool('autoLock', v);
    notifyListeners();
  }

  Future<void> setAutoWake(bool v) async {
    autoWake = v;
    await _prefs.setBool('autoWake', v);
    notifyListeners();
  }

  Future<void> setBatteryAlerts(bool v) async {
    batteryAlerts = v;
    await _prefs.setBool('batteryAlerts', v);
    notifyListeners();
  }

  Future<void> _automations() async {
    final now = DateTime.now();
    if (Platform.isWindows && autoLock) {
      // Telefon (aynı Wi-Fi'de görülmüşken) 2 dakika görünmezse bilgisayarı kilitle
      for (final p in peers.where((p) => p.isPhone)) {
        if (p.lanOnline) {
          _wasNear[p.id] = now;
          _lockedFor.remove(p.id);
        } else {
          final last = _wasNear[p.id];
          if (last != null && now.difference(last) > const Duration(minutes: 2) && !_lockedFor.contains(p.id)) {
            _lockedFor.add(p.id);
            await Process.run('rundll32.exe', ['user32.dll,LockWorkStation']);
          }
        }
      }
    }
    if (isPhone && autoWake) {
      // Bilgisayarla aynı ağa gelince (ve bilgisayar görünmüyorsa) Wake-on-LAN
      for (final p in peers.where((p) => p.isComputer && !p.lanOnline && p.addrs.isNotEmpty)) {
        final mac = _prefs.getString('mac:${p.id}');
        if (mac == null) continue;
        if (_lastWake != null && now.difference(_lastWake!) < const Duration(minutes: 10)) continue;
        final mine = await localAddresses();
        String net(String a) => a.split('.').take(3).join('.');
        if (!mine.any((a) => net(a) == net(p.addrs.first))) continue;
        _lastWake = now;
        await wake(p);
      }
    }
  }

  /// Wake-on-LAN "sihirli paket" (bilgisayarın ağ kartında açık olmalı).
  Future<bool> wake(Peer p) async {
    final mac = _prefs.getString('mac:${p.id}');
    if (mac == null) return false;
    final bytes = mac.split(':').map((h) => int.parse(h, radix: 16)).toList();
    if (bytes.length != 6) return false;
    final packet = Uint8List.fromList([...List.filled(6, 0xFF), for (var i = 0; i < 16; i++) ...bytes]);
    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      final targets = {'255.255.255.255', if (p.addrs.isNotEmpty) '${p.addrs.first.split('.').take(3).join('.')}.255'};
      for (final t in targets) {
        for (final port in [9, 7]) {
          sock.send(packet, InternetAddress(t), port);
        }
      }
      sock.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  bool canWake(Peer p) => _prefs.getString('mac:${p.id}') != null;

  void _batteryAlert(Peer p) {
    if (!Platform.isWindows || !batteryAlerts || p.battery == null) return;
    final b = p.battery!;
    String? kind;
    if (!p.charging && b <= 15) kind = 'low';
    if (p.charging && b >= 100) kind = 'full';
    if (kind == null) {
      if (b > 20 && b < 95) _lastBatteryAlert.remove(p.id); // sonraki uyarıya hazır
      return;
    }
    if (_lastBatteryAlert[p.id] == kind) return;
    _lastBatteryAlert[p.id] = kind;
    Notifier.show(
      kind == 'low' ? L('{0}: pil azaldı (%{1})', [p.name, b]) : L('{0}: pil doldu', [p.name]),
      kind == 'low' ? L('Telefonu şarja tak.') : L('Şarj aletinden çıkarabilirsin.'),
      always: true,
    );
  }

  // ---------------------------------------------------------------- telefonu bul

  Future<void> setLocateAllowed(bool v) async {
    locateAllowed = v;
    await _prefs.setBool('locateAllowed', v);
    notifyListeners();
  }

  /// Bilgisayar: telefonun konumu. (konum, hata) hata: izin | kapali | yok | baglanti
  Future<(Map<String, dynamic>?, String?)> locatePhone(Peer p) async {
    final r = await _send(p, {'t': 'locate'}, replyTimeout: const Duration(seconds: 25));
    if (r == null) return (null, 'baglanti');
    if (r['error'] != null) return (null, r['error'].toString());
    final loc = r['loc'];
    return loc is Map ? (Map<String, dynamic>.from(loc), null) : (null, 'yok');
  }

  // ---------------------------------------------------------------- yazdırma

  /// Telefon: dosyaları bilgisayarda varsayılan yazıcıdan yazdır.
  String printOnComputer(Peer p, List<String> paths) => sendFiles(p, paths, print: true);

  // ---------------------------------------------------------------- eşleştirmeden gönderme

  /// "Yakındakilerden al": 10 dakika boyunca aynı Wi-Fi'deki Pusula Köprü'ler bu cihazı görür.
  Future<void> setVisible(bool on) async {
    if (on) {
      _nearKeyPair = await PairCrypto.newKeyPair();
      _nearPub = await PairCrypto.publicBytes(_nearKeyPair);
      visibleUntil = DateTime.now().add(const Duration(minutes: 10));
      unawaited(bt.advertise(true));
    } else {
      unawaited(bt.advertise(false));
      visibleUntil = null;
      _nearKeyPair = null;
      _nearPub = null;
      _offers.clear();
    }
    _announce();
    notifyListeners();
  }

  static Future<String> _sas(PairKey key) async {
    final mac = await Hmac.sha256().calculateMac(utf8.encode('kopru-yakin-kod'), secretKey: SecretKey(List<int>.from(key.bytes)));
    final v = ((mac.bytes[0] << 16) | (mac.bytes[1] << 8) | mac.bytes[2]) % 1000000;
    final c = v.toString().padLeft(6, '0');
    return '${c.substring(0, 3)} ${c.substring(3)}';
  }

  Future<void> _handleOffer(HttpRequest req) async {
    final body = await _readAll(req, 256 * 1024);
    if (!isVisible || _nearKeyPair == null) return await _reply(req, 403);
    final j = jsonDecode(utf8.decode(body));
    if (j is! Map) return await _reply(req, 400);
    if (_offers.length > 20) return await _reply(req, 429);
    final senderPub = unb64u(j['pub']?.toString() ?? '');
    if (senderPub.length != 32) return await _reply(req, 400);
    final key = PairKey(await PairCrypto.derive(_nearKeyPair, senderPub, utf8.encode('kopru-yakin')));
    final offer = NearOffer(
      id: b64u(randomBytes(9)),
      name: _short((j['n']?.toString() ?? 'Cihaz').trim(), 40),
      platform: j['p']?.toString() ?? '',
      files: ((j['files'] as List?) ?? const []).map((e) => e.toString()).take(500).toList(),
      total: (j['total'] as num?)?.toInt() ?? 0,
      sas: await _sas(key),
      key: key,
      expires: DateTime.now().add(const Duration(minutes: 10)),
    );
    _offers[offer.id] = offer;
    final answer = Completer<bool>();
    _offerAnswers[offer.id] = answer;
    _emit(KopruEvent('nearOffer', offer: offer));
    await Notifier.show(L('{0} dosya göndermek istiyor', [offer.name]),
        L('{0} öğe · {1}. Kabul etmek için Pusula Köprü\'yü aç.', [offer.files.length, formatSize(offer.total)]),
        always: true);
    bool ok;
    try {
      ok = await answer.future.timeout(const Duration(seconds: 90));
    } catch (_) {
      ok = false;
    }
    _offerAnswers.remove(offer.id);
    if (!ok) _offers.remove(offer.id);
    offer.accepted = ok;
    return await _replyJson(req, {'ok': ok, if (ok) 'offer': offer.id});
  }

  final _offerAnswers = <String, Completer<bool>>{};

  static String _short(String s, int n) => s.length <= n ? s : s.substring(0, n);

  void answerOffer(NearOffer o, bool accept) {
    if (o.btId != null) return bt.answer(o, accept);
    _offerAnswers[o.id]?.complete(accept);
  }

  Future<void> _handleNearFile(HttpRequest req) async {
    final o = _offers[req.headers.value('x-k-offer') ?? ''];
    if (o == null || o.key == null || !o.accepted || DateTime.now().isAfter(o.expires)) {
      await _readAll(req, 1 << 16).catchError((_) => Uint8List(0));
      return await _reply(req, 403);
    }
    final temp = Peer(id: 'yakin:${o.id}', name: o.name, platform: o.platform, key: o.key!, addrs: const [], port: 0);
    final Map<String, dynamic> meta;
    try {
      meta = await o.key!.openJson(unb64u(req.headers.value('x-k-meta') ?? ''));
    } catch (_) {
      return await _reply(req, 403);
    }
    if (!_fresh(meta)) return await _reply(req, 409);
    final ok = await _receiveStream(req, temp, meta);
    await _reply(req, ok ? 200 : 400);
  }

  /// Eşleşmemiş yakındaki cihaza gönder. [onSas]: doğrulama kodu (karşı ekranla karşılaştırmak için).
  /// Dönüş: null başarılı (gönderim başladı, toplu kimlik [batch]'te), aksi hâlde hata iletisi.
  Future<String?> sendNearby(NearbyDevice d, List<String> paths,
      {void Function(String sas)? onSas, void Function(String batch)? onStart}) async {
    final pub = d.pub;
    if (pub == null) return L('Cihaz artık görünür değil');
    final files = <File>[];
    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.file) files.add(File(path));
    }
    if (files.isEmpty) return L('Gönderilecek dosya yok');
    final kp = await PairCrypto.newKeyPair();
    final myPub = await PairCrypto.publicBytes(kp);
    final key = PairKey(await PairCrypto.derive(kp, pub, utf8.encode('kopru-yakin')));
    onSas?.call(await _sas(key));
    final total = files.fold<int>(0, (a, f) => a + f.lengthSync());
    final http.Response r;
    try {
      r = await http
          .post(Uri.http('${d.address}:${d.port}', '/v1/near/offer'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'n': myName,
                'p': platform,
                'pub': b64u(myPub),
                'files': files.map((f) => f.path.split(RegExp(r'[\\/]')).last).toList(),
                'total': total,
              }))
          .timeout(const Duration(seconds: 100));
    } catch (_) {
      return L('{0} yanıt vermedi', [d.name]);
    }
    if (r.statusCode != 200) return L('{0} şu an almıyor', [d.name]);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map || j['ok'] != true) return L('{0} reddetti', [d.name]);
    final offer = j['offer'].toString();
    final temp = Peer(id: 'yakin:${d.id}', name: d.name, platform: d.platform, key: key, addrs: [d.address], port: d.port);
    final batch = b64u(randomBytes(6));
    final items = <(ActiveTransfer, File)>[];
    for (final f in files) {
      final t = ActiveTransfer(
          id: b64u(randomBytes(9)), name: f.path.split(RegExp(r'[\\/]')).last, size: f.lengthSync(), incoming: false, peerId: temp.id, batch: batch);
      active.add(t);
      items.add((t, f));
    }
    onStart?.call(batch);
    notifyListeners();
    for (final (t, f) in items) {
      if (t.cancelRequested) {
        t.state = 'cancelled';
        continue;
      }
      t.state = 'running';
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      try {
        final req = await client.post(d.address, d.port, '/v1/near/file');
        t.abort = () {
          try {
            req.abort();
          } catch (_) {}
        };
        req.headers.set('x-k-offer', offer);
        req.headers.set('x-k-meta', b64u(await key.sealJson(await _fileMeta(t))));
        req.headers.contentType = ContentType.binary;
        req.bufferOutput = false;
        await _writeFrames(req, f, t, temp);
        final res = await req.close().timeout(const Duration(minutes: 2));
        await res.drain<void>();
        t.state = res.statusCode == 200 ? 'done' : 'failed';
      } catch (_) {
        t.state = t.cancelRequested ? 'cancelled' : 'failed';
      } finally {
        client.close(force: true);
        t.abort = null;
        notifyListeners();
      }
      await _addHistory(HistoryItem(
          kind: 'file', name: t.name, incoming: false, peerName: d.name, at: DateTime.now(), size: t.size, location: f.path, mime: mimeFor(t.name), ok: t.state == 'done'));
    }
    _cleanupLater();
    return null;
  }

  // ---------------------------------------------------------------- fotoğraf yedekleme (telefon)

  Future<void> setBackup(bool on, {String? peerId, bool all = false}) async {
    backupOn = on;
    if (peerId != null) backupPeerId = peerId;
    if (on && (all || backupSince == 0)) {
      backupSince = all ? 0 : DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }
    await _prefs.setBool('backupOn', on);
    await _prefs.setInt('backupSince', backupSince);
    if (backupPeerId != null) await _prefs.setString('backupPeer', backupPeerId!);
    notifyListeners();
    if (on) runBackup();
  }

  /// Yeni fotoğraf ve videoları, bilgisayar aynı Wi-Fi'deyken sırayla gönderir (mobil veri harcamaz).
  Future<void> runBackup() async {
    if (!isPhone || !backupOn || backupRunning) return;
    final p = peerById(backupPeerId) ?? peers.where((x) => x.isComputer).firstOrNull;
    if (p == null || !p.lanOnline) return;
    if (!await Native.mediaPermission()) return;
    backupRunning = true;
    notifyListeners();
    try {
      for (var round = 0; round < 40; round++) {
        final items = await Native.newMedia(backupSince, 20);
        if (items == null || items.isEmpty) break;
        for (final it in items) {
          if (!backupOn || !p.lanOnline) return;
          final name = it['name']?.toString() ?? 'dosya';
          final date = DateTime.fromMillisecondsSinceEpoch((it['date'] as num?)?.toInt() ?? 0);
          final path = await Native.copyMedia(it['id'].toString(), name);
          var ok = path == null; // okunamayan öğeyi atla
          if (path != null) {
            final f = File(path);
            final t = ActiveTransfer(
              id: b64u(randomBytes(9)),
              name: name,
              size: f.lengthSync(),
              incoming: false,
              peerId: p.id,
              batch: 'backup',
              dir: '${date.year}-${date.month.toString().padLeft(2, '0')}',
              backup: true,
            );
            active.add(t);
            await _sendFile(p, f, t);
            ok = t.state == 'done';
            try {
              f.deleteSync();
            } catch (_) {}
            active.remove(t);
          }
          if (!ok) return; // bağlantı koptu: sonra devam
          backupSince = date.millisecondsSinceEpoch ~/ 1000;
          if (path != null) backupCount++;
          backupLast = DateTime.now();
          await _prefs.setInt('backupSince', backupSince);
          await _prefs.setInt('backupCount', backupCount);
          await _prefs.setInt('backupLast', backupLast!.millisecondsSinceEpoch);
          notifyListeners();
        }
      }
    } finally {
      backupRunning = false;
      notifyListeners();
    }
  }

  Future<void> setBrowseAllowed(bool v) async {
    browseAllowed = v;
    await _prefs.setBool('browseAllowed', v);
    notifyListeners();
  }

  /// Bilgisayar: yedeklerin klasörü (Resimler\Pusula Köprü\<telefon>).
  String backupFolder(Peer p) {
    final home = Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return '$home\\Pictures\\Pusula Köprü\\${_safeName(p.name)}';
  }

  // ---------------------------------------------------------------- telefonun dosyalarına göz atma (bilgisayar)

  /// (öğeler, hata): hata 'izin' | 'kapali' | 'baglanti'
  Future<(List<MediaItem>, String?)> phoneMedia(Peer p, String kind, int offset, {int limit = 60}) async {
    final r = await _send(p, {'t': 'mlist', 'kind': kind, 'offset': offset, 'limit': limit});
    if (r == null) return (<MediaItem>[], 'baglanti');
    if (r['error'] != null) return (<MediaItem>[], r['error'].toString());
    final items = ((r['items'] as List?) ?? const []).whereType<Map>().map((e) => MediaItem.fromJson(Map<String, dynamic>.from(e))).toList();
    return (items, null);
  }

  final _thumbs = <String, Uint8List>{};
  final _thumbWait = <String, Future<Uint8List?>>{};
  Uint8List? cachedThumb(Peer p, String id) => _thumbs['${p.id}/$id'];
  Future<Uint8List?> phoneThumb(Peer p, String id) {
    final key = '${p.id}/$id';
    final c = _thumbs[key];
    if (c != null) return Future.value(c);
    return _thumbWait[key] ??= () async {
      final r = await _send(p, {'t': 'mthumb', 'id': id, 'px': 220});
      _thumbWait.remove(key);
      final d = r?['data'];
      if (d is! String) return null;
      final b = base64Decode(d);
      if (_thumbs.length > 600) _thumbs.clear();
      _thumbs[key] = b;
      return b;
    }();
  }

  Future<bool> pullFromPhone(Peer p, List<MediaItem> items) async {
    final r = await _send(p, {
      't': 'mpull',
      'items': [for (final i in items) {'id': i.id, 'name': i.name}],
    });
    return r?['ok'] == true;
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

  /// Şifreli dosyanın tam boyutu (sunucu üzerinden gönderirken önceden bildirilir).
  static int sealedFileSize(int size) {
    final n = size == 0 ? 1 : (size + kChunk - 1) ~/ kChunk;
    return size + n * (5 + 12 + 16);
  }

  Future<Map<String, dynamic>> _fileMeta(ActiveTransfer t) async =>
      _stamp({'name': t.name, 'size': t.size, 'id': t.id, if (t.dir.isNotEmpty) 'dir': t.dir, if (t.backup) 'backup': true, if (t.print) 'print': true});

  Future<void> _sendFile(Peer p, File f, ActiveTransfer t) async {
    t.state = 'running';
    notifyListeners();
    final addr = await _reachable(p);
    if (addr == null && t.backup) {
      t.state = 'failed'; // yedek yalnız aynı Wi-Fi'de (mobil veri harcamasın)
      return;
    }
    if (addr == null) {
      // Aynı ağda değil: sunucu üzerinden (şifreli)
      final link = _relays[p.id];
      if (relayOn && link != null && link.connected) {
        await _sendFileRelay(p, f, t, link);
      } else {
        t.state = 'failed';
      }
      notifyListeners();
      return;
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.post(addr, p.port, '/v1/file');
      t.abort = () {
        try {
          req.abort();
        } catch (_) {}
      };
      req.headers.set('x-k-from', myId);
      req.headers.set('x-k-port', '$port');
      req.headers.set('x-k-meta', b64u(await p.key.sealJson(await _fileMeta(t))));
      req.headers.contentType = ContentType.binary;
      req.bufferOutput = false;
      await _writeFrames(req, f, t, p);
      final res = await req.close().timeout(const Duration(minutes: 2));
      await res.drain<void>();
      t.state = res.statusCode == 200 ? 'done' : 'failed';
    } catch (_) {
      t.state = t.cancelRequested ? 'cancelled' : 'failed';
    } finally {
      client.close(force: true);
      t.abort = null;
      notifyListeners();
    }
  }

  Future<void> _sendFileRelay(Peer p, File f, ActiveTransfer t, RelayLink link) async {
    if (t.size > kRelayMax) {
      t.state = 'failed';
      _emit(KopruEvent('error', peer: p, text: L('İnternet üzerinden en fazla 100 MB gönderilebilir. {0} ile aynı Wi-Fi\'ye bağlan.', [p.name])));
      return;
    }
    t.viaRelay = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.putUrl(Uri.parse('$kRelayBase/v1/kopru/file/${link.box}/${t.id}'));
      t.abort = () {
        try {
          req.abort();
        } catch (_) {}
      };
      req.headers.contentType = ContentType.binary;
      req.contentLength = sealedFileSize(t.size);
      req.bufferOutput = false;
      await _writeFrames(req, f, t, p);
      final res = await req.close().timeout(const Duration(minutes: 5));
      await res.drain<void>();
      if (res.statusCode != 200) {
        t.state = 'failed';
        return;
      }
      final meta = b64u(await p.key.sealJson(await _fileMeta(t)));
      final ok = link.send(await p.key.sealJson(_stamp({'t': 'rfile', 'id': t.id, 'meta': meta})), keep: true);
      t.state = ok ? 'done' : 'failed';
    } catch (_) {
      t.state = t.cancelRequested ? 'cancelled' : 'failed';
    } finally {
      client.close(force: true);
      t.abort = null;
    }
  }

  /// Dosyayı 256 KB'lık şifreli parçalar hâlinde yazar: [uzunluk(4)][bayrak(1)][şifreli parça]
  Future<void> _writeFrames(IOSink out, File f, ActiveTransfer t, Peer p) async {
    final raf = await f.open();
    try {
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
        out.add(header.buffer.asUint8List());
        out.add(sealed);
        await out.flush();
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
    } finally {
      await raf.close();
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
    final ok = await _receiveStream(req, peer, meta);
    await _reply(req, ok ? 200 : 400);
  }

  /// Sunucu üzerinden gelen dosya: indir, aç, sunucudan sil.
  Future<void> _receiveRelayed(Peer peer, Map<String, dynamic> m) async {
    final link = _relays[peer.id];
    final id = m['id']?.toString() ?? '';
    if (link == null || id.isEmpty) return;
    final Map<String, dynamic> meta;
    try {
      meta = await peer.key.openJson(unb64u(m['meta']?.toString() ?? ''));
    } catch (_) {
      return;
    }
    if (meta['id']?.toString() != id) return;
    final url = Uri.parse('$kRelayBase/v1/kopru/file/${link.box}/$id');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(url);
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        return;
      }
      final ok = await _receiveStream(res, peer, meta, relay: true);
      if (ok) {
        final del = await client.deleteUrl(url);
        await (await del.close()).drain<void>();
      }
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _receiveStream(Stream<List<int>> stream, Peer peer, Map<String, dynamic> meta, {bool relay = false}) async {
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
    final t = ActiveTransfer(id: id, name: name, size: size, incoming: true, peerId: peer.id, batch: id)
      ..state = 'running'
      ..viaRelay = relay;
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
      await for (final d in stream) {
        if (gotLast) continue;
        final data = d is Uint8List ? d : Uint8List.fromList(d);
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
      return false;
    }

    final backup = meta['backup'] == true && Platform.isWindows;
    if (backup) {
      // Fotoğraf yedeği: Resimler\Pusula Köprü\<telefon>\<yıl-ay>; aynısı varsa yenisini atla
      String? loc;
      try {
        final target = Directory('${backupFolder(peer)}${sub.isEmpty ? '' : '\\$sub'}');
        if (!target.existsSync()) target.createSync(recursive: true);
        final same = File('${target.path}\\$name');
        if (same.existsSync() && same.lengthSync() == size) {
          part.deleteSync();
          loc = same.path;
        } else {
          final dest = _unique(target, name);
          await part.rename(dest.path);
          loc = dest.path;
          backupReceived[peer.id] = (backupReceived[peer.id] ?? 0) + 1;
          await _prefs.setString('backupReceived', jsonEncode(backupReceived));
        }
      } catch (_) {}
      t.state = loc != null ? 'done' : 'failed';
      t.done = size;
      active.remove(t);
      notifyListeners();
      return loc != null;
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
    if (location != null && meta['print'] == true && Platform.isWindows) {
      // Telefondan "Bilgisayarda yazdır": varsayılan uygulamanın yazdır komutu
      final ok = await _printFile(location);
      await Notifier.show(ok ? L('Yazdırılıyor') : L('Yazdırılamadı'), name, always: true);
    } else if (location != null) {
      _emit(KopruEvent('received', peer: peer, text: name));
      _notifyReceived(peer, sub.isEmpty ? name : '${sub.split('/').first}/', location, name);
    }
    notifyListeners();
    _cleanupLater();
    return location != null;
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
      final title = n == 1 ? L('{0} gönderdi', [peer.name]) : L('{0}: {1} öğe geldi', [peer.name, n]);
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

  Future<bool> _printFile(String path) async {
    try {
      final esc = path.replaceAll("'", "''");
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Start-Process -FilePath '$esc' -Verb Print",
      ]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
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
