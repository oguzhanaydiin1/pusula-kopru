# Sürüm notları

## 0.7.0
- **Kodla gönder:** Eşleştirmeden, farklı ağdaki birine dosya gönder. Ekranda "7-ayva-kalem" gibi bir kod ve QR çıkar; karşı taraf kodu yazar ya da okutur, önce gelenleri görür, sonra "Al" der. Kodun kelimeleri sunucuya hiç gitmez (SPAKE2); dosyalar uçtan uca şifreli. Telefon ve bilgisayarda; dosya başına en fazla 100 MB, kod 10 dakika geçerli.
- **İnternetsiz gönder (telefondan telefona):** Wi-Fi ağı ya da internet olmadan, yakındaki bir Android telefona. Cihazlar Bluetooth ile bulunur, dosya doğrudan Wi-Fi ile hızlıca gider; mobil veri harcamaz. İki ekranda aynı 4 haneli kod görünür, alan taraf onaylar.
- **Radar:** Yakındakiler ekranı gemi radarı gibi tarıyor; bulunan cihaza dokun, dosyalar gitsin. Gönder ekranında "Yakındakiler | Kodla" sekmeleri.

## 0.6.0
- **Sağ tıkla gönder:** Windows Gezgini'nde dosya ya da klasöre sağ tıkla → "Pusula Köprü ile telefona gönder". Windows 11'de "Diğer seçenekleri göster" altında.
- **Bilgisayarda yazdır:** Telefondan seçtiğin dosyalar bilgisayarın varsayılan yazıcısından çıkar.
- **Telefonu bul:** Bilgisayardan telefonun konumunu haritada gör, çaldır. Telefonda Ayarlar'dan açılır; konum iznine "Her zaman izin ver" denmeli.
- **Otomatik eylemler:** Telefon uzaklaşınca bilgisayarı kilitle; eve gelince uyuyan bilgisayarı uyandır (Wake-on-LAN); telefonun pili azalınca ya da dolunca Windows bildirimi.

## 0.5.0
- **İngilizce arayüz:** Uygulama cihazın diline göre Türkçe ya da İngilizce açılır; Ayarlar → Dil'den değiştirilebilir. Android bildirimleri ve Windows kurulum programı da İngilizce.

## 0.4.0
- **Dokunmatik yüzey ve klavye:** Telefon bilgisayarın faresi olur: kaydır, dokun, uzun bas (sağ tık), iki parmakla kaydır, sürükle. Klavyeyle yazdıkların bilgisayarda belirir; Enter, ok tuşları, kopyala/yapıştır düğmeleri.
- **Sunum kumandası:** Büyük İleri/Geri düğmeleri, sunumu başlat/bitir, siyah ekran, süre. Telefonun ses tuşlarıyla da slayt geçilir.
- **Güç menüsü:** Telefondan bilgisayarı kilitle, uyut, yeniden başlat ya da kapat.
- **Pano geçmişi:** Son 20 kopyalanan iki cihazda da; dokunup yeniden kopyala. Şifre gibi görünenler saklanmaz.
- **Fotoğraf yedekleme:** Telefonda yeni çekilen fotoğraf ve videolar, bilgisayarla aynı Wi-Fi'deyken Resimler\Pusula Köprü klasörüne kendiliğinden kopyalanır. Mobil veri harcamaz; aynısı zaten varsa atlanır.
- **Telefonun dosyaları:** Bilgisayardan telefonun fotoğraf, video ve İndirilenler'ine küçük resimlerle göz at, seçtiklerini al. Uzaktayken de çalışır.
- **Yakındakiler:** Eşleştirmeden, aynı Wi-Fi'deki birine tek seferlik dosya gönder ya da al. Alan taraf onaylar; iki ekranda aynı doğrulama kodu görünür, dosyalar şifreli gider.

## 0.3.3
- "Telefonu çaldır" düzeltildi: telefon artık 30 saniye boyunca sesli çalar ve titrer (önceden hemen susuyordu).
- Farklı ağdayken iletiler beklemeden sunucu üzerinden gider (önceden eski Wi-Fi adreslerini denerken yarım dakikaya kadar bekliyordu).

## 0.3.2
- Android: Google Play Protect'in kurulumu engellemesi düzeltildi. Play Protect, Play Store dışından kurulan ve bildirim erişimi isteyen uygulamaları engellediği için bildirim aynası standart sürümden çıkarıldı; diğer bütün özellikler duruyor.

## 0.3.1
- Bilgisayarda "Güncelle" düğmesi, uygulama uzun süre açık kalsa da yeni sürüm çıkınca belirir (6 saatte bir bakar; Ayarlar'dan denetleyince de hemen çıkar).

## 0.3.0
- **Farklı ağdayken de çalışır:** Telefon mobil verideyken ya da başka bir Wi-Fi'deyken dosya, bağlantı, pano, bildirim ve "Telefonu çaldır" OA sunucusu üzerinden gider. Her şey cihazlarda uçtan uca şifrelenir; sunucu içeriği göremez. Dosya başına en fazla 100 MB.
- Karşı cihaz kapalıyken gönderilen metin ve bağlantılar, açılınca iletilir (3 güne kadar).
- Ekranda bağlantı yolu görünür: "Aynı Wi-Fi · doğrudan" ya da "İnternet üzerinden".
- Ayarlar'da "Farklı ağdayken de bağlan" ile kapatılabilir.

## 0.2.1
- Pusula Browser'daki "Bilgisayara gönder" Köprü ekranını açmadan çalışır.

## 0.2.0
- **Arka planda çalışma (Android):** Uygulama kapalıyken de bilgisayardan gelen dosya, bağlantı ve "Telefonu çaldır" alınır. Telefon yeniden başlayınca kendiliğinden açılır. Ayarlar'dan kapatılabilir.
- **Bildirimler:** Telefona dosya ya da bağlantı gelince bildirim; dokununca açılır. Bilgisayarda Windows bildirimi.
- **Sistem tepsisi (Windows):** Pencereyi kapatınca uygulama saat yanındaki simgeye iner ve çalışmaya devam eder. Windows açılınca gizli başlar (Ayarlar'dan kapatılabilir). İkinci kez açınca mevcut pencere öne gelir.
- **Bildirim aynası:** Telefona gelen bildirimler bilgisayarda görünür; WhatsApp gibi uygulamalara bilgisayardan yanıt verilebilir. Telefonda Ayarlar → "Bildirimleri bilgisayara ilet".
- **Kumanda:** Telefondan bilgisayarın müziğini/videosunu durdur, geç, sesini aç-kıs.
- **Son ekran görüntüsü:** Tek dokunuşla bilgisayara.
- **Klasör gönderme:** Bilgisayardan klasör sürükle ya da "Klasör seç"; telefonda aynı klasör yapısıyla kaydedilir.
- **Küçük resimler:** Geçmişte fotoğrafların küçük resmi.
- **Pusula Browser'dan gönderme:** Pusula "Telefona gönder" dediğinde bağlantı telefonda hemen açılır.

## 0.1.2
- Android sürümü artık sabit OA anahtarıyla imzalı: bundan sonraki güncellemeler eskisinin üzerine kurulur. Bu sürümü kurmadan önce telefondaki eski sürümü bir kez kaldır.

## 0.1.1
- Bağlantı hatalarında sunucunun daha sağlam davranması

## 0.1.0
İlk deneme sürümü.
- QR kodla eşleştirme (telefon bilgisayardaki kodu okutur) ya da 6 haneli kodla eşleştirme
- Aynı Wi-Fi'de doğrudan ve uçtan uca şifreli dosya, fotoğraf, metin ve bağlantı gönderme
- Bilgisayarın panosu telefonda; telefondan bilgisayara "Panoyu gönder"
- Android paylaş menüsünden Pusula Köprü'ye gönderme
- Telefonu çaldır (sessizde bile), telefondan bilgisayarı kilitle, telefonun pili bilgisayarda
- Gelen dosyalar İndirilenler/Pusula Köprü klasörüne kaydedilir
