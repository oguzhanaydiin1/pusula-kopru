# Pusula Köprü

OA Labs'in bilgisayar ↔ telefon köprüsü. Windows ve Android'de çalışır (Flutter).
Aynı Wi-Fi'deki iki cihaz arasında dosya, fotoğraf, metin, bağlantı ve pano doğrudan ve uçtan uca şifreli gider.

> Durum: ilk deneme sürümü (0.1.0).

## İndir

Her `main` gönderiminde GitHub Actions derler ve **Releases** sayfasına `pubspec.yaml`daki sürümle ekler:

- **Pusula-Kopru-Kurulum.exe**: Windows kurulum programı (yönetici izni istemez). İlk açılışta Windows güvenlik duvarı
  sorarsa **İzin ver**; yoksa telefon bilgisayarı göremez.
- **Pusula-Kopru-Windows.zip**: kurmadan denemek için.
- **Pusula-Kopru-Android.apk**: telefona kur ("Bilinmeyen kaynaklardan yükleme" izni ister).

## Özellikler (0.1)

- QR kodla eşleştirme; kamera yoksa 6 haneli kodla
- Dosya ve fotoğraf gönderme, iki yönde (bilgisayarda sürükle-bırak, telefonda paylaş menüsü)
- Metin ve bağlantı gönderme; bağlantılar telefonda Pusula'da açılır
- Ortak pano: bilgisayarda kopyalanan telefonda hazır; telefondan "Panoyu gönder" doğrudan bilgisayarın panosuna
- Telefonu çaldır (sessizde bile, 30 saniye), telefondan bilgisayarı kilitle, telefonun pili bilgisayarda
- Gelen dosyalar: Windows'ta `İndirilenler\Pusula Köprü`, Android'de `İndirilenler/Pusula Köprü`
- Kendini güncelleme (GitHub sürümlerinden)

## Nasıl çalışır

- Her cihaz yerel ağda bir HTTP sunucusu (47821) açar ve UDP yayınıyla (47822) varlığını duyurur.
- Eşleştirme: bilgisayar QR'da tek kullanımlık bir sır ve X25519 açık anahtarı gösterir. Telefon kendi anahtarını
  gönderir; iki taraf da sırrı bildiğini HMAC ile kanıtlar ve ortak anahtar HKDF ile türetilir.
- Sonraki her ileti ve 256 KB'lık her dosya parçası bu anahtarla ChaCha20-Poly1305 ile şifrelenir. Parça sırası ve
  son parça işareti doğrulanır; tekrar gönderilen iletiler reddedilir.
- Anahtarlar cihazın güvenli deposunda (Windows DPAPI, Android Keystore) tutulur.

## Kod

- `lib/core/node.dart`: sunucu, cihaz bulma, eşleştirme, ileti ve dosya aktarımı
- `lib/core/crypto.dart`: şifreleme ve eşleştirme adımları
- `lib/ui/desktop.dart`, `lib/ui/mobile.dart`: ekranlar (OA Labs tasarım sistemi, koyu tema)
- `platform/android/.../MainActivity.kt`: paylaş menüsü, İndirilenler'e kaydetme, çaldırma, pil
- `scripts/platform_hazirla.sh`, `scripts/android_ayarla.py`: platform klasörleri derlemede üretilir
- `installer/pusula_kopru.iss`: Windows kurulum programı (Inno Setup)

## Sonraki adımlar

- Farklı ağdayken OA sunucusu üzerinden (uçtan uca şifreli) aktarım
- Android'de arka planda çalışan hizmet (uygulama kapalıyken de dosya alma)
- Bildirim aynası, medya kumandası
- Pusula'da "Telefona gönder" düğmesi
