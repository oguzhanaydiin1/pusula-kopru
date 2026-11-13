part of 'node.dart';

// ============================================================ kodla gönder (internet üzerinden)
//
// Gönderen "7-ayva-kalem" gibi bir kod alır. Sayı sunucudaki geçici kutunun adıdır (gizli değil);
// iki kelime ise şifredir ve sunucuya hiç gitmez. İki taraf SPAKE2 ile bu kelimelerden ortak bir
// anahtar kurar; dosyalar o anahtarla şifrelenip mevcut sunucu kutusundan geçer.
//
// İletiler (kutu içinde):
//   B→A  {t: pake, p}          A→B {t: pake, p}
//   B→A  {t: conf, m}          (A doğrular; yanlışsa oturumu kapatır: tek tahmin hakkı)
//   A→B  mühürlü {t: offer, n, p, files, total}
//   B→A  mühürlü {t: accept} | {t: reject}
//   A→B  mühürlü {t: rfile, id, meta} … {t: end}

const kCodeLife = Duration(minutes: 10);

Future<String> _codeBox(int slot) async {
  final h = await Sha256().hash(utf8.encode('kopru-kod-kutu-v1:$slot'));
  return b64u(h.bytes).substring(0, 32);
}

/// Kod biçimi: "<sayı>-<kelime>-<kelime>". Geçersizse null.
(int, String)? parseCode(String raw) {
  final s = normalizeCode(raw);
  final m = RegExp(r'^(\d{1,4})-([a-z]+)-([a-z]+)$').firstMatch(s);
  if (m == null) return null;
  final words = kKodWords.map(normalizeCode).toSet();
  if (!words.contains(m[2]) || !words.contains(m[3])) return null;
  return (int.parse(m[1]!), '${m[2]}-${m[3]}');
}

/// Sunucu kutusuna basit bağlantı (yalnız bu oturum için).
class _CodeLink {
  _CodeLink(this.box, this.myId);
  final String box;
  final String myId;
  WebSocket? _ws;
  Timer? _ping;
  void Function(List<String> online)? onHello;
  void Function(String d, bool on)? onPresence;
  void Function(String from, Uint8List data)? onMsg;
  void Function()? onLost;

  Future<bool> open() async {
    try {
      final ws = await WebSocket.connect('${kRelayBase.replaceFirst('https', 'wss')}/v1/kopru/ws/$box?d=$myId')
          .timeout(const Duration(seconds: 12));
      _ws = ws;
      ws.listen((d) {
        if (d is! String || d == 'pong') return;
        try {
          final m = jsonDecode(d);
          if (m is! Map) return;
          switch (m['t']) {
            case 'hello':
              onHello?.call(((m['online'] as List?) ?? const []).map((e) => e.toString()).where((e) => e != myId).toList());
            case 'presence':
              if (m['d'] != myId) onPresence?.call(m['d'].toString(), m['on'] == true);
            case 'msg':
              onMsg?.call(m['from'].toString(), base64Decode(m['data'] as String));
          }
        } catch (_) {}
      }, onDone: () {
        _ws = null;
        onLost?.call();
      }, onError: (_) {}, cancelOnError: true);
      _ping = Timer.periodic(const Duration(seconds: 25), (_) {
        try {
          _ws?.add('ping');
        } catch (_) {}
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  bool send(String to, List<int> data, {bool keep = true}) {
    final ws = _ws;
    if (ws == null) return false;
    try {
      ws.add(jsonEncode({'t': 'msg', 'to': to, 'data': base64Encode(data), 'keep': keep}));
      return true;
    } catch (_) {
      return false;
    }
  }

  void sendJson(String to, Map<String, dynamic> m, {bool keep = true}) => send(to, utf8.encode(jsonEncode(m)), keep: keep);

  Future<void> close() async {
    _ping?.cancel();
    final ws = _ws;
    _ws = null;
    onLost = null;
    try {
      await ws?.close();
    } catch (_) {}
  }
}

Map<String, dynamic>? _plainJson(Uint8List d) {
  try {
    final v = jsonDecode(utf8.decode(d));
    return v is Map ? Map<String, dynamic>.from(v) : null;
  } catch (_) {
    return null;
  }
}

/// Gönderen taraf. [state]: hazirlaniyor | bekliyor | onay | gidiyor | bitti | hata
class CodeSend extends ChangeNotifier {
  CodeSend._(this._k, this.files);
  final Kopru _k;
  final List<File> files;
  String code = '';
  String state = 'hazirlaniyor';
  String? error;
  String? peerName;
  String? batch;
  DateTime expires = DateTime.now().add(kCodeLife);
  _CodeLink? _link;
  Spake2? _pake;
  Spake2Result? _res;
  String? _partner;
  PairKey? _key;
  Peer? _temp;
  Timer? _timer;

  int get total => files.fold<int>(0, (a, f) => a + f.lengthSync());
  bool get finished => state == 'bitti' || state == 'hata';

  void _set(String s, {String? err}) {
    state = s;
    if (err != null) error = err;
    notifyListeners();
    _k._touch();
  }

  Future<void> _start() async {
    final rnd = Random.secure();
    for (var attempt = 0; attempt < 6; attempt++) {
      final slot = attempt < 3 ? 2 + rnd.nextInt(98) : 100 + rnd.nextInt(900);
      final w1 = kKodWords[rnd.nextInt(kKodWords.length)];
      var w2 = kKodWords[rnd.nextInt(kKodWords.length)];
      while (w2 == w1) {
        w2 = kKodWords[rnd.nextInt(kKodWords.length)];
      }
      final link = _CodeLink(await _codeBox(slot), 'a${b64u(randomBytes(9))}');
      final hello = Completer<List<String>>();
      link.onHello = (o) {
        if (!hello.isCompleted) hello.complete(o);
      };
      if (!await link.open()) {
        _set('hata', err: L('Sunucuya bağlanılamadı. İnternet bağlantını denetle.'));
        return;
      }
      final online = await hello.future.timeout(const Duration(seconds: 8), onTimeout: () => const <String>[]);
      if (online.any((d) => d.startsWith('a'))) {
        await link.close(); // bu numara başka bir gönderimde kullanılıyor
        continue;
      }
      _link = link;
      code = '$slot-$w1-$w2';
      _pake = await Spake2.start(isA: true, password: normalizeCode('$w1-$w2'));
      link.onMsg = _onMsg;
      link.onLost = () {
        if (!finished) _set('hata', err: L('Sunucu bağlantısı koptu'));
      };
      expires = DateTime.now().add(kCodeLife);
      _timer = Timer(kCodeLife, () {
        if (state == 'bekliyor') {
          _set('hata', err: L('Kodun süresi doldu. Yeniden gönder.'));
          close();
        }
      });
      _set('bekliyor');
      return;
    }
    _set('hata', err: L('Şu an kod alınamadı, biraz sonra yeniden dene.'));
  }

  Future<void> _onMsg(String from, Uint8List data) async {
    if (_partner != null && from != _partner) return; // tek alıcı
    if (_key == null) {
      final m = _plainJson(data);
      if (m == null) return;
      if (m['t'] == 'pake' && _res == null) {
        try {
          _res = await _pake!.finish(unb64u(m['p'].toString()));
        } catch (_) {
          return;
        }
        _partner = from;
        _link!.sendJson(from, {'t': 'pake', 'p': b64u(_pake!.message)});
        _set('onay');
      } else if (m['t'] == 'conf' && _res != null) {
        if (!_res!.verify(unb64u(m['m'].toString()))) {
          // Yanlış kod denendi: bu kodu kapat (tahmin denemelerine izin verme)
          _set('hata', err: L('Biri yanlış kodla bağlanmaya çalıştı. Güvenlik için bu kod kapatıldı; yeniden gönder.'));
          await close();
          return;
        }
        _key = PairKey(_res!.key);
        _temp = Peer(id: 'kod:$from', name: L('Kodla alan'), platform: '', key: _key!, addrs: const [], port: 0);
        await _sendSealed({
          't': 'offer',
          'n': _k.myName,
          'p': _k.platform,
          'files': files.map((f) => {'name': f.path.split(RegExp(r'[\\/]')).last, 'size': f.lengthSync()}).toList(),
          'total': total,
        });
      }
      return;
    }
    Map<String, dynamic> m;
    try {
      m = await _key!.openJson(data);
    } catch (_) {
      return;
    }
    if (m['t'] == 'accept' && state == 'onay') {
      peerName = _short(m['n']?.toString() ?? '', 40);
      if (peerName!.isEmpty) peerName = null;
      unawaited(_upload());
    } else if (m['t'] == 'reject') {
      _set('hata', err: L('Alıcı reddetti'));
      await close();
    }
  }

  static String _short(String s, int n) => s.length <= n ? s : s.substring(0, n);

  Future<void> _sendSealed(Map<String, dynamic> m) async {
    _link?.send(_partner!, await _key!.sealJson(_k._stamp(m)));
  }

  Future<void> _upload() async {
    _timer?.cancel();
    final box = await relayBox(_key!);
    batch = b64u(randomBytes(6));
    final items = <(ActiveTransfer, File)>[];
    for (final f in files) {
      final t = ActiveTransfer(
          id: b64u(randomBytes(9)), name: f.path.split(RegExp(r'[\\/]')).last, size: f.lengthSync(), incoming: false, peerId: _temp!.id, batch: batch!)
        ..viaRelay = true;
      _k.active.add(t);
      items.add((t, f));
    }
    _set('gidiyor');
    for (final (t, f) in items) {
      if (t.cancelRequested || _link == null) {
        t.state = 'cancelled';
        continue;
      }
      if (t.size > kRelayMax) {
        t.state = 'failed';
        continue;
      }
      t.state = 'running';
      _k._touch();
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.putUrl(Uri.parse('$kRelayBase/v1/kopru/file/$box/${t.id}'));
        t.abort = () {
          try {
            req.abort();
          } catch (_) {}
        };
        req.headers.contentType = ContentType.binary;
        req.contentLength = Kopru.sealedFileSize(t.size);
        req.bufferOutput = false;
        await _k._writeFrames(req, f, t, _temp!);
        final res = await req.close().timeout(const Duration(minutes: 5));
        await res.drain<void>();
        if (res.statusCode == 200) {
          final meta = b64u(await _key!.sealJson(await _k._fileMeta(t)));
          await _sendSealed({'t': 'rfile', 'id': t.id, 'meta': meta});
          t.state = 'done';
        } else {
          t.state = 'failed';
        }
      } catch (_) {
        t.state = t.cancelRequested ? 'cancelled' : 'failed';
      } finally {
        client.close(force: true);
        t.abort = null;
        _k._touch();
      }
      await _k._addHistory(HistoryItem(
          kind: 'file',
          name: t.name,
          incoming: false,
          peerName: peerName ?? L('Kodla'),
          at: DateTime.now(),
          size: t.size,
          location: f.path,
          mime: mimeFor(t.name),
          ok: t.state == 'done'));
    }
    await _sendSealed({'t': 'end'});
    final failed = items.where((e) => e.$1.state != 'done').length;
    if (failed == items.length) {
      _set('hata', err: L('Gönderilemedi'));
    } else {
      _set('bitti');
    }
    _k._cleanupLater();
    Future.delayed(const Duration(seconds: 5), close);
  }

  Future<void> close() async {
    _timer?.cancel();
    if (batch != null && !finished) _k.cancelBatch(batch!);
    final l = _link;
    _link = null;
    await l?.close();
    if (!finished) _set('hata', err: L('İptal edildi'));
  }
}

/// Alan taraf. [state]: baglaniyor | teklif | gidiyor | bitti | hata
class CodeReceive extends ChangeNotifier {
  CodeReceive._(this._k);
  final Kopru _k;
  String state = 'baglaniyor';
  String? error;
  String senderName = '';
  String senderPlatform = '';
  List<(String, int)> files = const [];
  int total = 0;
  int got = 0;
  int failed = 0;
  final ids = <String>[];
  _CodeLink? _link;
  String? _partner;
  String _box = '';
  Spake2? _pake;
  PairKey? _key;
  Peer? _temp;
  bool _ended = false;
  int _pending = 0;

  bool get finished => state == 'bitti' || state == 'hata';

  void _set(String s, {String? err}) {
    state = s;
    if (err != null) error = err;
    notifyListeners();
    _k._touch();
  }

  Future<void> _start(int slot, String password) async {
    _pake = await Spake2.start(isA: false, password: password);
    final link = _CodeLink(await _codeBox(slot), 'b${b64u(randomBytes(9))}');
    final found = Completer<String?>();
    link.onHello = (o) {
      final a = o.where((d) => d.startsWith('a')).firstOrNull;
      if (a != null && !found.isCompleted) found.complete(a);
    };
    link.onPresence = (d, on) {
      if (on && d.startsWith('a') && !found.isCompleted) found.complete(d);
    };
    link.onMsg = _onMsg;
    if (!await link.open()) {
      _set('hata', err: L('Sunucuya bağlanılamadı. İnternet bağlantını denetle.'));
      return;
    }
    _link = link;
    link.onLost = () {
      if (!finished) _set('hata', err: L('Sunucu bağlantısı koptu'));
    };
    final a = await found.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (a == null) {
      _set('hata', err: L('Bu kodla gönderen bulunamadı. Kodu denetle; gönderenin ekranı açık olmalı.'));
      await close();
      return;
    }
    _partner = a;
    link.sendJson(a, {'t': 'pake', 'p': b64u(_pake!.message)}, keep: false);
    Future.delayed(const Duration(seconds: 20), () {
      if (state == 'baglaniyor') {
        _set('hata', err: L('Gönderen yanıt vermedi'));
        close();
      }
    });
  }

  Spake2Result? _res;

  Future<void> _onMsg(String from, Uint8List data) async {
    if (from != _partner) return;
    if (_key == null) {
      final m = _plainJson(data);
      if (m == null || m['t'] != 'pake' || _res != null) return;
      try {
        _res = await _pake!.finish(unb64u(m['p'].toString()));
      } catch (_) {
        _set('hata', err: L('Bağlantı kurulamadı'));
        return;
      }
      _key = PairKey(_res!.key);
      _box = await relayBox(_key!);
      _link!.sendJson(from, {'t': 'conf', 'm': b64u(_res!.myConfirm)});
      // Kod yanlışsa teklif hiç gelmez (gönderen kapatır) ya da açılamaz.
      Future.delayed(const Duration(seconds: 12), () {
        if (state == 'baglaniyor') {
          _set('hata', err: L('Kod yanlış. Gönderenin ekranındaki kodu yeniden yaz.'));
          close();
        }
      });
      return;
    }
    Map<String, dynamic> m;
    try {
      m = await _key!.openJson(data);
    } catch (_) {
      return;
    }
    if (!_k._fresh(m)) return;
    switch (m['t']) {
      case 'offer':
        if (state != 'baglaniyor') return;
        senderName = CodeSend._short(m['n']?.toString() ?? L('Cihaz'), 40);
        senderPlatform = m['p']?.toString() ?? '';
        files = ((m['files'] as List?) ?? const [])
            .whereType<Map>()
            .take(500)
            .map((e) => (e['name']?.toString() ?? 'dosya', (e['size'] as num?)?.toInt() ?? 0))
            .toList();
        total = (m['total'] as num?)?.toInt() ?? files.fold<int>(0, (a, e) => a + e.$2);
        _temp = Peer(id: 'kod:$from', name: senderName, platform: senderPlatform, key: _key!, addrs: const [], port: 0);
        _set('teklif');
      case 'rfile':
        _pending++;
        unawaited(_download(m).whenComplete(() {
          _pending--;
          _checkEnd();
        }));
      case 'end':
        _ended = true;
        _checkEnd();
    }
  }

  void _checkEnd() {
    if (!_ended || _pending > 0 || finished) return;
    if (got == 0 && failed > 0) {
      _set('hata', err: L('Dosyalar alınamadı'));
    } else {
      _set('bitti');
    }
    close();
  }

  Future<void> _download(Map<String, dynamic> m) async {
    final id = m['id']?.toString() ?? '';
    final Map<String, dynamic> meta;
    try {
      meta = await _key!.openJson(unb64u(m['meta']?.toString() ?? ''));
    } catch (_) {
      failed++;
      return;
    }
    if (meta['id']?.toString() != id) return;
    ids.add(id);
    final url = Uri.parse('$kRelayBase/v1/kopru/file/$_box/$id');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final res = await (await client.getUrl(url)).close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        failed++;
        return;
      }
      final ok = await _k._receiveStream(res, _temp!, meta, relay: true);
      if (ok) {
        got++;
        await (await client.deleteUrl(url).then((r) => r.close())).drain<void>();
      } else {
        failed++;
      }
    } catch (_) {
      failed++;
    } finally {
      client.close(force: true);
      notifyListeners();
    }
  }

  Future<void> accept() async {
    if (state != 'teklif') return;
    _set('gidiyor');
    _link?.send(_partner!, await _key!.sealJson(_k._stamp({'t': 'accept', 'n': _k.myName})));
  }

  Future<void> reject() async {
    if (_key != null && _partner != null) {
      _link?.send(_partner!, await _key!.sealJson(_k._stamp({'t': 'reject'})));
    }
    _set('hata', err: L('Reddettin'));
    await Future.delayed(const Duration(milliseconds: 300));
    await close();
  }

  Future<void> close() async {
    final l = _link;
    _link = null;
    await l?.close();
    if (!finished) _set('hata', err: L('İptal edildi'));
  }
}

extension KopruCode on Kopru {
  /// Dosyaları kodla gönder. Oturum [CodeSend.code] hazır olunca 'bekliyor' durumuna geçer.
  CodeSend sendWithCode(List<String> paths) {
    final files = <File>[
      for (final p in paths)
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.file) File(p)
    ];
    final s = CodeSend._(this, files);
    if (files.isEmpty) {
      s.state = 'hata';
      s.error = L('Gönderilecek dosya yok');
    } else if (files.any((f) => f.lengthSync() > kRelayMax)) {
      s.state = 'hata';
      s.error = L('Kodla gönderirken dosya başına en fazla 100 MB. Daha büyükler için aynı Wi-Fi\'yi ya da yakındakileri kullan.');
    } else {
      unawaited(s._start());
    }
    return s;
  }

  /// Koddan al. Kod geçersizse null.
  CodeReceive? receiveWithCode(String code) {
    final c = parseCode(code);
    if (c == null) return null;
    final r = CodeReceive._(this);
    unawaited(r._start(c.$1, c.$2));
    return r;
  }
}
