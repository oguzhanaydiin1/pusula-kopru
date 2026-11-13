import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';

import 'crypto.dart';

/// SPAKE2 (RFC 9382), P-256 üzerinde. "7-ayva-kalem" gibi kısa bir kodu bilen iki cihaz, araya giren
/// sunucu kodu bilmeden (ve çevrim dışı deneme yapamadan) güçlü bir ortak anahtar kurar.
/// Yanlış kodla deneyen tek bir tahmin hakkı kazanır; onay adımında yakalanır.
///
/// M ve N, "bir şey saklamıyoruz" yöntemiyle üretildi: SHA-256("Pusula Kopru SPAKE2 P-256 M")
/// (ve N) ile başlayıp eğri üzerinde ilk geçerli x'e kadar SHA-256 tekrarlanarak. Kimse bunların
/// G'ye göre ayrık logaritmasını bilmez.
class Spake2 {
  Spake2._(this.isA, this._w, this._x, this.message, this._idA, this._idB);

  static final _d = ECCurve_secp256r1();
  static final ECPoint _m = _d.curve.decodePoint(_hex('03a00be09fb9f4970bcdc7a1de3d176e24684fa7f54eda0d1ee743ed0accbe6a14'))!;
  static final ECPoint _n = _d.curve.decodePoint(_hex('02469a28640b8dbffd4b5efd92ac399e61d888dd9dcbf911600849aa86abd938d9'))!;

  final bool isA;
  final BigInt _w;
  final BigInt _x;
  final Uint8List message; // karşıya gidecek nokta (sıkıştırılmamış, 65 bayt)
  final List<int> _idA, _idB;

  /// [isA]: kodu oluşturan taraf (gönderen). [password]: kodun gizli kısmı (iki kelime).
  static Future<Spake2> start({required bool isA, required String password, String idA = 'kopru-gonderen', String idB = 'kopru-alan'}) async {
    final wh = await Sha512().hash(utf8.encode('kopru-kod-v1|${password.trim().toLowerCase()}'));
    final w = _int(wh.bytes) % _d.n;
    final x = (_int(randomBytes(48)) % (_d.n - BigInt.one)) + BigInt.one;
    final xP = (_d.G * x)!;
    final wM = ((isA ? _m : _n) * w)!;
    final p = (xP + wM)!;
    return Spake2._(isA, w, x, p.getEncoded(false), utf8.encode(idA), utf8.encode(idB));
  }

  /// Karşının iletisini işler. Dönüş: ortak 32 baytlık anahtar ve iki onay kodu.
  /// Kod yanlışsa anahtarlar farklı çıkar; bu ancak onay kodları karşılaştırılınca anlaşılır.
  Future<Spake2Result> finish(List<int> other) async {
    if (other.length != 65 || other[0] != 4) throw const FormatException('Geçersiz nokta');
    final q = _d.curve.decodePoint(other);
    if (q == null || q.isInfinity) throw const FormatException('Geçersiz nokta');
    // Eğri üzerinde mi (decodePoint denetlemeyebilir)
    final qx = q.x!.toBigInteger()!, qy = q.y!.toBigInteger()!;
    final p = _pField;
    final rhs = (qx * qx * qx - BigInt.from(3) * qx + _bCoef) % p;
    if ((qy * qy) % p != rhs) throw const FormatException('Eğri dışı nokta');
    final otherBase = isA ? _n : _m;
    final minusW = (otherBase * ((_d.n - _w) % _d.n));
    final shifted = minusW == null || minusW.isInfinity ? q : (q + minusW)!;
    final k = (shifted * _x)!;
    if (k.isInfinity) throw const FormatException('Geçersiz anahtar');
    final pA = isA ? message : Uint8List.fromList(other);
    final pB = isA ? Uint8List.fromList(other) : message;
    final tt = BytesBuilder()
      ..add(_lp(_idA))
      ..add(_lp(_idB))
      ..add(_lp(_m.getEncoded(false)))
      ..add(_lp(_n.getEncoded(false)))
      ..add(_lp(pA))
      ..add(_lp(pB))
      ..add(_lp(k.getEncoded(false)))
      ..add(_lp(_bytes32(_w)));
    final transcript = tt.toBytes();
    final h = (await Sha256().hash(transcript)).bytes;
    Future<List<int>> kdf(String info) async {
      final out = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
          .deriveKey(secretKey: SecretKey(h), nonce: const <int>[], info: utf8.encode(info));
      return out.extractBytes();
    }

    final key = await kdf('kopru-kod-anahtar');
    final ca = await kdf('kopru-kod-onay-A');
    final cb = await kdf('kopru-kod-onay-B');
    final macA = (await Hmac.sha256().calculateMac(transcript, secretKey: SecretKey(ca))).bytes;
    final macB = (await Hmac.sha256().calculateMac(transcript, secretKey: SecretKey(cb))).bytes;
    return Spake2Result(Uint8List.fromList(key), isA ? macA : macB, isA ? macB : macA);
  }

  static final _pField = BigInt.parse('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff', radix: 16);
  static final _bCoef = BigInt.parse('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', radix: 16);

  static Uint8List _hex(String s) =>
      Uint8List.fromList(List<int>.generate(s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16)));

  static BigInt _int(List<int> b) {
    var r = BigInt.zero;
    for (final x in b) {
      r = (r << 8) | BigInt.from(x);
    }
    return r;
  }

  static Uint8List _bytes32(BigInt v) {
    final out = Uint8List(32);
    var t = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (t & BigInt.from(0xff)).toInt();
      t = t >> 8;
    }
    return out;
  }

  /// RFC 9382: 8 baytlık küçük-sonlu uzunluk + veri
  static Uint8List _lp(List<int> b) {
    final out = Uint8List(8 + b.length);
    var n = b.length;
    for (var i = 0; i < 8; i++) {
      out[i] = n & 0xff;
      n >>= 8;
    }
    out.setRange(8, out.length, b);
    return out;
  }
}

class Spake2Result {
  Spake2Result(this.key, this.myConfirm, this.expectedConfirm);
  final Uint8List key;
  final List<int> myConfirm; // karşıya gönderilir
  final List<int> expectedConfirm; // karşıdan bu gelmeli

  bool verify(List<int> got) => sameBytes(got, expectedConfirm);
}
