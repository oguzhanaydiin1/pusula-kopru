import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Şifreleme: eşleşen iki cihazın ortak 32 baytlık anahtarıyla ChaCha20-Poly1305.
/// Eşleştirmede anahtar X25519 ile kurulur; QR'daki tek kullanımlık sır (ya da 6 haneli kod)
/// karşı tarafın gerçekten o cihaz olduğunu doğrular.

final _aead = Chacha20.poly1305Aead();
final _rnd = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => _rnd.nextInt(256)));

String b64u(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List unb64u(String s) {
  var t = s.trim();
  while (t.length % 4 != 0) {
    t += '=';
  }
  return base64Url.decode(t);
}

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

class PairKey {
  PairKey(List<int> bytes)
      : bytes = Uint8List.fromList(bytes),
        _key = SecretKey(List<int>.from(bytes));

  final Uint8List bytes;
  final SecretKey _key;

  /// nonce(12) | şifreli metin | mac(16)
  Future<Uint8List> seal(List<int> plain, {List<int> aad = const <int>[]}) async {
    final nonce = randomBytes(12);
    final box = await _aead.encrypt(plain, secretKey: _key, nonce: nonce, aad: aad);
    final out = BytesBuilder(copy: false)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Doğrulanamazsa hata fırlatır.
  Future<Uint8List> open(List<int> data, {List<int> aad = const <int>[]}) async {
    if (data.length < 28) throw const FormatException('Eksik veri');
    final box = SecretBox(
      data.sublist(12, data.length - 16),
      nonce: data.sublist(0, 12),
      mac: Mac(data.sublist(data.length - 16)),
    );
    final clear = await _aead.decrypt(box, secretKey: _key, aad: aad);
    return clear is Uint8List ? clear : Uint8List.fromList(clear);
  }

  Future<Uint8List> sealJson(Map<String, dynamic> m) => seal(utf8.encode(jsonEncode(m)));

  Future<Map<String, dynamic>> openJson(List<int> data) async {
    final v = jsonDecode(utf8.decode(await open(data)));
    if (v is! Map) throw const FormatException('Beklenmeyen ileti');
    return Map<String, dynamic>.from(v);
  }
}

/// Eşleştirme adımları.
class PairCrypto {
  PairCrypto._();
  static final _x = X25519();
  static final _hmac = Hmac.sha256();

  static Future<SimpleKeyPair> newKeyPair() => _x.newKeyPair();

  static Future<Uint8List> publicBytes(SimpleKeyPair kp) async =>
      Uint8List.fromList((await kp.extractPublicKey()).bytes);

  /// Ortak anahtar: HKDF(X25519(benim, onun), tuz = doğrulama sırrı).
  static Future<Uint8List> derive(SimpleKeyPair mine, List<int> theirPub, List<int> auth) async {
    final shared = await _x.sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(theirPub, type: KeyPairType.x25519),
    );
    final key = await Hkdf(hmac: _hmac, outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: auth,
      info: utf8.encode('pusula-kopru v1'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Sırrı bildiğini, açık anahtarları da ele vererek kanıtlar.
  static Future<Uint8List> proof(List<int> auth, String label, List<int> a, List<int> b) async {
    final mac = await _hmac.calculateMac(
      <int>[...utf8.encode(label), ...a, ...b],
      secretKey: SecretKey(List<int>.from(auth)),
    );
    return Uint8List.fromList(mac.bytes);
  }
}
