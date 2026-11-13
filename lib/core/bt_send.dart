part of 'node.dart';

// ============================================================ internetsiz gönderme (telefondan telefona)
//
// Android'de Google'ın Nearby Connections altyapısı (NearbyConn.kt): Bluetooth ile bulur, doğrudan
// Wi-Fi ile aktarır. Wi-Fi ağı ya da internet gerekmez. Bağlantı şifrelidir; iki ekranda aynı
// 4 haneli kod görünür ve alan taraf onaylamadan hiçbir şey gelmez.

/// Radarda görünen, Bluetooth ile bulunmuş cihaz.
class BtDevice {
  BtDevice(this.id, this.name) : found = DateTime.now();
  final String id;
  String name;
  final DateTime found;

  /// Radardaki yeri (derece). Bluetooth yön vermez; her cihaz kimliğine göre sabit bir yerde durur.
  double get bearing {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return (h % 360).toDouble();
  }
}

/// Gönderen tarafın bir aktarımı. [state]: baglaniyor | onay | gidiyor | bitti | hata
class BtSend extends ChangeNotifier {
  BtSend._(this.device, this.files);
  final BtDevice device;
  final List<File> files;
  String state = 'baglaniyor';
  String? digits;
  String? error;
  String batch = b64u(randomBytes(6));
  final transfers = <int, ActiveTransfer>{};

  bool get finished => state == 'bitti' || state == 'hata';
  int get total => files.fold<int>(0, (a, f) => a + f.lengthSync());

  void _set(String s, {String? err}) {
    state = s;
    if (err != null) error = err;
    notifyListeners();
    Kopru.i._touch();
  }

  Future<void> cancel() async {
    for (final t in transfers.values) {
      if (!t.finished) {
        t.cancelRequested = true;
        await Native.btCancel(int.parse(t.id.substring(2)));
      }
    }
    await Native.btDisconnect(device.id);
    if (!finished) _set('hata', err: L('İptal edildi'));
  }
}

class BtHub {
  BtHub._(this._k);
  final Kopru _k;

  bool? available; // Google Play hizmetleri var mı (Huawei'de yok)
  bool permission = false;
  bool advertising = false;
  bool scanning = false;
  final devices = <String, BtDevice>{};
  final _sends = <String, BtSend>{};
  final _incoming = <int, ActiveTransfer>{}; // alan taraf: pid → aktarım
  final _offerOf = <String, NearOffer>{}; // uç → gelen teklif

  bool get supported => Platform.isAndroid && available == true;

  Future<void> init() async {
    if (!Platform.isAndroid) return;
    Native.onBt = _onEvent;
    available = await Native.btAvailable();
    permission = await Native.btPermission();
  }

  /// İzin yoksa ister ve verilene kadar (en fazla 30 sn) bekler.
  Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return false;
    available ??= await Native.btAvailable();
    if (available != true) return false;
    permission = await Native.btPermission();
    if (permission) return true;
    if (!await Native.btRequest()) return false;
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      permission = await Native.btPermission();
      if (permission) break;
    }
    _k._touch();
    return permission;
  }

  Future<void> advertise(bool on) async {
    if (!supported) return;
    if (on && !await ensurePermission()) return;
    if (!on && !advertising) return;
    advertising = await Native.btAdvertise(on, _k.myName) && on;
    _k._touch();
  }

  Future<void> scan(bool on) async {
    if (!supported) return;
    if (on && !await ensurePermission()) return;
    scanning = await Native.btDiscover(on) && on;
    if (!on) devices.clear();
    _k._touch();
  }

  BtSend send(BtDevice d, List<String> paths) {
    final files = <File>[
      for (final p in paths)
        if (FileSystemEntity.typeSync(p) == FileSystemEntityType.file) File(p)
    ];
    final s = BtSend._(d, files);
    if (files.isEmpty) {
      s._set('hata', err: L('Gönderilecek dosya yok'));
      return s;
    }
    _sends[d.id] = s;
    final name = _k.myName.replaceAll('|', ' ');
    Native.btConnect(d.id, '${name.length > 40 ? name.substring(0, 40) : name}|${files.length}|${s.total}').then((ok) {
      if (!ok && s.state == 'baglaniyor') s._set('hata', err: L('{0} ile bağlantı kurulamadı', [d.name]));
    });
    return s;
  }

  Peer _tempPeer(String id, String name) =>
      Peer(id: 'bt:$id', name: name, platform: 'android', key: PairKey(Uint8List(32)), addrs: const [], port: 0);

  Future<void> _onEvent(Map<String, dynamic> m) async {
    final id = m['id']?.toString() ?? '';
    switch (m['e']) {
      case 'found':
        devices[id] = BtDevice(id, m['name']?.toString() ?? L('Telefon'));
        _k._touch();
      case 'lost':
        if (devices.remove(id) != null) _k._touch();
      case 'digits':
        final s = _sends[id];
        if (s != null) {
          s.digits = m['digits']?.toString();
          s._set('onay');
        }
      case 'offer':
        final name = Kopru._short(m['name']?.toString() ?? L('Telefon'), 40);
        final count = (m['count'] as num?)?.toInt() ?? 0;
        final o = NearOffer(
          id: 'bt-$id',
          name: name,
          platform: 'android',
          files: List<String>.generate(count, (i) => ''),
          total: (m['total'] as num?)?.toInt() ?? 0,
          sas: m['digits']?.toString() ?? '',
          key: null,
          expires: DateTime.now().add(const Duration(minutes: 10)),
          btId: id,
        );
        _offerOf[id] = o;
        _k._emit(KopruEvent('nearOffer', offer: o));
        await Notifier.show(L('{0} dosya göndermek istiyor', [name]),
            L('{0} öğe · {1}. Kabul etmek için Pusula Köprü\'yü aç.', [count, formatSize(o.total)]),
            always: true);
      case 'connected':
        final s = _sends[id];
        if (s == null) return; // alan taraf: teklif kabul edildi, dosyalar gelecek
        final pids = await Native.btSend(id, [
          for (final f in s.files) {'path': f.path, 'name': f.path.split(RegExp(r'[\\/]')).last}
        ]);
        for (var i = 0; i < pids.length && i < s.files.length; i++) {
          final f = s.files[i];
          final t = ActiveTransfer(
              id: 'bt${pids[i]}', name: f.path.split(RegExp(r'[\\/]')).last, size: f.lengthSync(), incoming: false, peerId: 'bt:$id', batch: s.batch)
            ..state = 'running';
          s.transfers[pids[i]] = t;
          _k.active.add(t);
        }
        if (pids.isEmpty) {
          s._set('hata', err: L('Gönderilemedi'));
        } else {
          s._set('gidiyor');
        }
      case 'rejected':
        _sends.remove(id)?._set('hata', err: L('Reddedildi'));
      case 'disconnected':
        final s = _sends.remove(id);
        if (s != null && !s.finished) {
          for (final t in s.transfers.values) {
            if (!t.finished) t.state = 'failed';
          }
          final ok = s.transfers.values.where((t) => t.state == 'done').length;
          if (s.state == 'baglaniyor' || s.state == 'onay') {
            s._set('hata', err: L('Bağlantı kurulamadı'));
          } else {
            s._set(ok == 0 ? 'hata' : 'bitti', err: ok == 0 ? L('Bağlantı koptu') : null);
          }
          _k._cleanupLater();
        }
        for (final t in _incoming.values.where((t) => t.peerId == 'bt:$id' && !t.finished)) {
          t.state = 'failed';
        }
        _offerOf.remove(id);
        _k._touch();
      case 'meta':
        final pid = (m['pid'] as num).toInt();
        final t = ActiveTransfer(
            id: 'bt$pid', name: _k._safeName(m['name']?.toString() ?? 'dosya'), size: (m['size'] as num?)?.toInt() ?? 0, incoming: true, peerId: 'bt:$id', batch: 'bt:$id')
          ..state = 'running';
        _incoming[pid] = t;
        _k.active.add(t);
        _k._touch();
      case 'progress':
        final pid = (m['pid'] as num).toInt();
        final t = _sends[id]?.transfers[pid] ?? _incoming[pid];
        if (t == null) return;
        final done = (m['done'] as num?)?.toInt() ?? 0;
        _speed(t, done);
        if (m['sent'] == true) {
          t.state = 'done';
          final s = _sends[id];
          final f = s?.files.firstWhere((f) => f.path.endsWith(t.name), orElse: () => File(''));
          await _k._addHistory(HistoryItem(
              kind: 'file', name: t.name, incoming: false, peerName: s?.device.name ?? '', at: DateTime.now(), size: t.size, location: f?.path, mime: mimeFor(t.name), ok: true));
          if (s != null && s.transfers.values.every((t) => t.finished)) {
            s._set('bitti');
            _k._cleanupLater();
          }
        }
        _k._touch();
      case 'failed':
        final pid = (m['pid'] as num).toInt();
        final t = _sends[id]?.transfers[pid] ?? _incoming.remove(pid);
        if (t != null) {
          t.state = t.cancelRequested ? 'cancelled' : 'failed';
          _k._touch();
        }
      case 'file':
        final pid = (m['pid'] as num).toInt();
        final t = _incoming.remove(pid);
        final path = m['path']?.toString() ?? '';
        final name = _k._safeName(m['name']?.toString() ?? 'dosya');
        final peer = _tempPeer(id, _offerOf[id]?.name ?? L('Telefon'));
        String? loc;
        try {
          loc = await Native.saveToDownloads(path, name, mimeFor(name));
        } catch (_) {}
        try {
          File(path).deleteSync();
        } catch (_) {}
        if (t != null) {
          t.state = loc != null ? 'done' : 'failed';
          t.done = t.size;
        }
        await _k._addHistory(HistoryItem(
            kind: 'file', name: name, incoming: true, peerName: peer.name, at: DateTime.now(), size: t?.size ?? 0, location: loc, mime: mimeFor(name), ok: loc != null));
        if (loc != null) {
          _k._emit(KopruEvent('received', peer: peer, text: name));
          _k._notifyReceived(peer, name, loc, name);
        }
        _k._touch();
        _k._cleanupLater();
    }
  }

  final _ticks = <String, (int, int)>{}; // aktarım → (zaman ms, bayt)

  void _speed(ActiveTransfer t, int done) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _ticks[t.id];
    if (last != null && now > last.$1) {
      final inst = (done - last.$2) * 1000 / (now - last.$1);
      t.speed = t.speed == 0 ? inst : t.speed * 0.7 + inst * 0.3;
    }
    _ticks[t.id] = (now, done);
    t.done = done;
  }

  void answer(NearOffer o, bool accept) {
    final id = o.btId;
    if (id == null) return;
    o.accepted = accept;
    Native.btAnswer(id, accept);
    if (!accept) _offerOf.remove(id);
  }

  Future<void> stopAll() async {
    if (!Platform.isAndroid) return;
    await Native.btStop();
    advertising = false;
    scanning = false;
    devices.clear();
    _k._touch();
  }
}
