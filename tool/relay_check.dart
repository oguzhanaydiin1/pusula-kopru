// Köprü'nün sunucu bağlantı kodunu (lib/core/relay.dart) canlı sunucuyla dener: iki sahte cihaz.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pusula_kopru/core/crypto.dart';
import 'package:pusula_kopru/core/models.dart';
import 'package:pusula_kopru/core/relay.dart';

Future<void> main() async {
  final key = PairKey(randomBytes(32));
  final idA = b64u(randomBytes(12)), idB = b64u(randomBytes(12));
  final peerB = Peer(id: idB, name: 'B', platform: 'android', key: key, addrs: [], port: 1);
  final peerA = Peer(id: idA, name: 'A', platform: 'windows', key: key, addrs: [], port: 1);
  final box = await relayBox(key);
  print('kutu: $box');
  final gotA = <String>[], gotB = <String>[];
  final a = RelayLink(peer: peerB, box: box, myId: idA, onMessage: (b) => gotA.add(utf8.decode(b)), onChange: () {});
  final b = RelayLink(peer: peerA, box: box, myId: idB, onMessage: (x) => gotB.add(utf8.decode(x)), onChange: () {});
  var fail = 0;
  void ok(bool c, String m) {
    print('${c ? 'GEÇTİ' : 'KALDI'} $m');
    if (!c) fail++;
  }

  a.start();
  await Future.delayed(const Duration(seconds: 4));
  ok(a.connected, 'A bağlandı');
  b.start();
  await Future.delayed(const Duration(seconds: 4));
  ok(b.connected, 'B bağlandı');
  ok(peerB.relayOnline, 'A, B\'yi çevrimiçi görüyor');
  ok(peerA.relayOnline, 'B, A\'yı çevrimiçi görüyor');
  ok(a.send(Uint8List.fromList(utf8.encode('merhaba'))), 'A gönderdi');
  await Future.delayed(const Duration(seconds: 3));
  ok(gotB.contains('merhaba'), 'B iletiyi aldı');
  await a.close();
  await b.close();
  exit(fail == 0 ? 0 : 1);
}
