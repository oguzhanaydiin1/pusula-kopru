import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto.dart';
import 'models.dart';

const kRelayBase = 'https://api.oalabs.dev';
const kRelayMax = 100 * 1024 * 1024;

/// Eşleşmiş iki cihazın sunucudaki ortak posta kutusunun adı. Ortak anahtardan türetilir;
/// başka kimse bilemez. Sunucu içeriği göremez, yalnız şifreli baytları taşır.
Future<String> relayBox(PairKey key) async {
  final mac = await Hmac.sha256().calculateMac(utf8.encode('kopru-relay-v1'), secretKey: SecretKey(List<int>.from(key.bytes)));
  return b64u(mac.bytes).substring(0, 32);
}

/// Bir cihazla sunucu üzerinden bağlantı (aynı ağda değilken). Kopunca kendiliğinden yeniden bağlanır.
class RelayLink {
  RelayLink({required this.peer, required this.box, required this.myId, required this.onMessage, required this.onChange});

  final Peer peer;
  final String box;
  final String myId;
  final void Function(Uint8List sealed) onMessage;
  final void Function() onChange;

  WebSocket? _ws;
  Timer? _ping, _retry;
  int _backoff = 2;
  bool _closed = false;
  bool _connecting = false;

  bool get connected => _ws != null;

  void start() {
    _closed = false;
    _connect();
  }

  Future<void> _connect() async {
    if (_closed || _connecting || _ws != null) return;
    _connecting = true;
    try {
      final ws = await WebSocket.connect('${kRelayBase.replaceFirst('https', 'wss')}/v1/kopru/ws/$box?d=$myId')
          .timeout(const Duration(seconds: 12));
      if (_closed) {
        await ws.close();
        return;
      }
      _ws = ws;
      _backoff = 2;
      ws.listen(_onData, onDone: _lost, onError: (_) => _lost(), cancelOnError: true);
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 30), (_) {
        try {
          _ws?.add('ping');
        } catch (_) {}
      });
      onChange();
    } catch (_) {
      _schedule();
    } finally {
      _connecting = false;
    }
  }

  void _lost() {
    _ws = null;
    _ping?.cancel();
    if (peer.relayOnline) {
      peer.relayOnline = false;
    }
    onChange();
    _schedule();
  }

  void _schedule() {
    if (_closed) return;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = (_backoff * 2).clamp(2, 120);
  }

  /// Ağ değişince (Wi-Fi'ye bağlanma gibi) hemen yeniden dene.
  void kick() {
    if (_ws == null && !_closed) {
      _retry?.cancel();
      _backoff = 2;
      _connect();
    }
  }

  void _onData(dynamic d) {
    if (d is! String || d == 'pong') return;
    try {
      final m = jsonDecode(d);
      if (m is! Map) return;
      switch (m['t']) {
        case 'hello':
          peer.relayOnline = ((m['online'] as List?) ?? const []).contains(peer.id);
          onChange();
        case 'presence':
          if (m['d'] == peer.id) {
            peer.relayOnline = m['on'] == true;
            onChange();
          }
        case 'msg':
          if (m['from'] != peer.id) return;
          onMessage(base64Decode(m['data'] as String));
      }
    } catch (_) {}
  }

  /// [keep]: karşı taraf çevrim dışıysa sunucu saklasın (en fazla 3 gün).
  bool send(Uint8List sealed, {bool keep = false}) {
    final ws = _ws;
    if (ws == null) return false;
    try {
      ws.add(jsonEncode({'t': 'msg', 'to': peer.id, 'data': base64Encode(sealed), 'keep': keep}));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _ping?.cancel();
    final ws = _ws;
    _ws = null;
    peer.relayOnline = false;
    try {
      await ws?.close();
    } catch (_) {}
  }
}
