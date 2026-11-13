import 'package:flutter_test/flutter_test.dart';
import 'package:pusula_kopru/core/crypto.dart';
import 'package:pusula_kopru/core/spake2.dart';
import 'package:pusula_kopru/core/words.dart';

void main() {
  test('aynı kodla iki taraf aynı anahtarı bulur ve onaylar', () async {
    final a = await Spake2.start(isA: true, password: 'ayva-kalem');
    final b = await Spake2.start(isA: false, password: 'ayva-kalem');
    final ra = await a.finish(b.message);
    final rb = await b.finish(a.message);
    expect(sameBytes(ra.key, rb.key), isTrue);
    expect(ra.verify(rb.myConfirm), isTrue);
    expect(rb.verify(ra.myConfirm), isTrue);
    expect(a.message.length, 65);
  });

  test('yanlış kod: anahtarlar ve onaylar tutmaz', () async {
    final a = await Spake2.start(isA: true, password: 'ayva-kalem');
    final b = await Spake2.start(isA: false, password: 'ayva-kitap');
    final ra = await a.finish(b.message);
    final rb = await b.finish(a.message);
    expect(sameBytes(ra.key, rb.key), isFalse);
    expect(ra.verify(rb.myConfirm), isFalse);
    expect(rb.verify(ra.myConfirm), isFalse);
  });

  test('bozuk nokta reddedilir', () async {
    final a = await Spake2.start(isA: true, password: 'x-y');
    final bad = List<int>.from(a.message)..[40] ^= 1;
    expect(() => a.finish(bad), throwsA(anything));
  });

  test('kod sadeleştirme ve kelime listesi', () {
    expect(kKodWords.length, 256);
    expect(kKodWords.toSet().length, 256);
    expect(normalizeCode(' 7 Şapka  YOĞURT '), '7-sapka-yogurt');
    expect(normalizeCode('12.IRMAK.kale'), '12-irmak-kale');
  });
}
