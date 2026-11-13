#!/usr/bin/env python3
"""flutter create'in ürettiği Android klasörüne Pusula Köprü ayarlarını uygular.

- İzinler: internet, Wi-Fi (yerel ağda cihaz bulma), kamera (QR), titreşim, eski Android'de depolama.
- Paylaş menüsü: her türden dosya ve metin Pusula Köprü'ye gönderilebilir.
- Yerel ağdaki bilgisayarla şifreli ama düz HTTP üzerinden konuşulur: usesCleartextTraffic.
- MainActivity platform/android/ klasöründen gelir (çaldırma, İndirilenler'e kaydetme, pil, paylaşım).
- OA_KEYSTORE_PATH ve OA_KEYSTORE_PASSWORD varsa yayın sürümü sabit anahtarla imzalanır.

Kullanım (proje kökünde): python3 scripts/android_ayarla.py
"""
import os
import re
import shutil
import sys

MANIFEST = 'android/app/src/main/AndroidManifest.xml'

PERMS = [
    'android.permission.INTERNET',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.ACCESS_WIFI_STATE',
    'android.permission.CHANGE_WIFI_MULTICAST_STATE',
    'android.permission.CAMERA',
    'android.permission.VIBRATE',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE',
    'android.permission.RECEIVE_BOOT_COMPLETED',
    'android.permission.READ_MEDIA_IMAGES',
    'android.permission.READ_MEDIA_VIDEO',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_BACKGROUND_LOCATION',
    # İnternetsiz gönderme (Nearby Connections: Bluetooth ile bulma, doğrudan Wi-Fi ile aktarım)
    'android.permission.CHANGE_WIFI_STATE',
    'android.permission.BLUETOOTH_SCAN',
    'android.permission.BLUETOOTH_ADVERTISE',
    'android.permission.BLUETOOTH_CONNECT',
    'android.permission.NEARBY_WIFI_DEVICES',
]

# Arka plan hizmeti, açılışta başlatma ve (0.3) bildirim aynası
# Bildirim aynası (NotificationListenerService). Google Play Protect, Play dışından kurulan ve
# bildirim erişimi isteyen uygulamaları engelliyor; bu yüzden yalnız KOPRU_MIRROR=1 ile eklenir.
MIRROR = '''
        <service
            android:name=".NotifListener"
            android:label="Pusula Köprü"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE"
            android:exported="true">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService"/>
            </intent-filter>
        </service>
'''

COMPONENTS = '''
        <service
            android:name=".KopruService"
            android:exported="false"
            android:foregroundServiceType="connectedDevice"/>
        <receiver android:name=".BootReceiver" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
            </intent-filter>
        </receiver>
'''

SHARE_FILTERS = '''
            <!-- Paylaş menüsü: dosya, fotoğraf, metin, bağlantı -->
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
'''


def manifest():
    s = open(MANIFEST, encoding='utf-8').read()
    for p in PERMS:
        if p + '"' not in s:
            s = s.replace('<application', '<uses-permission android:name="%s"/>\n    <application' % p, 1)
    if 'READ_EXTERNAL_STORAGE' not in s:
        s = s.replace('<application', '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>\n    <application', 1)
    if '.KopruService' not in s:
        comp = COMPONENTS + (MIRROR if os.environ.get('KOPRU_MIRROR') == '1' else '')
        i = s.rfind('</application>')
        s = s[:i] + comp.strip('\n') + '\n    ' + s[i:]
    for old in ('BLUETOOTH', 'BLUETOOTH_ADMIN'):
        if 'android.permission.%s"' % old not in s:
            s = s.replace('<application', '<uses-permission android:name="android.permission.%s" android:maxSdkVersion="30"/>\n    <application' % old, 1)
    if 'WRITE_EXTERNAL_STORAGE' not in s:
        s = s.replace('<application', '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>\n    <application', 1)
    if 'android.hardware.camera' not in s:
        s = s.replace('<application', '<uses-feature android:name="android.hardware.camera" android:required="false"/>\n    <application', 1)
    s = s.replace('android:label="pusula_kopru"', 'android:label="Pusula Köprü"')
    if 'usesCleartextTraffic' not in s:
        s = s.replace('android:label="Pusula Köprü"', 'android:label="Pusula Köprü"\n        android:usesCleartextTraffic="true"', 1)
    if 'android.intent.action.SEND_MULTIPLE' not in s:
        i = s.find('</activity>')
        if i < 0:
            sys.exit('AndroidManifest.xml içinde </activity> bulunamadı')
        s = s[:i] + SHARE_FILTERS.strip('\n') + '\n        ' + s[i:]
    open(MANIFEST, 'w', encoding='utf-8').write(s)
    print('Manifest: izinler, paylaş menüsü ve ad ayarlandı')


def native():
    for root, _, files in os.walk('android/app/src/main'):
        for f in files:
            if f in ('MainActivity.kt', 'MainActivity.java'):
                os.remove(os.path.join(root, f))
    shutil.copytree('platform/android/app/src/main', 'android/app/src/main', dirs_exist_ok=True)
    # Yayın sürümünde R8, QR okumanın kullandığı ML Kit sınıflarını silmesin
    with open('android/app/proguard-rules.pro', 'w', encoding='utf-8') as f:
        f.write('-keep class com.google.mlkit.** { *; }\n'
                '-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }\n'
                '-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }\n'
                '-dontwarn com.google.mlkit.**\n')
    print('Android: MainActivity ve ProGuard kuralları kopyalandı')


NEARBY_DEP = 'com.google.android.gms:play-services-nearby:19.5.1'


def deps():
    kts = 'android/app/build.gradle.kts'
    groovy = 'android/app/build.gradle'
    if os.path.exists(kts):
        s = open(kts, encoding='utf-8').read()
        if NEARBY_DEP not in s:
            s += '\ndependencies {\n    implementation("%s")\n}\n' % NEARBY_DEP
            open(kts, 'w', encoding='utf-8').write(s)
    elif os.path.exists(groovy):
        s = open(groovy, encoding='utf-8').read()
        if NEARBY_DEP not in s:
            s += "\ndependencies {\n    implementation '%s'\n}\n" % NEARBY_DEP
            open(groovy, 'w', encoding='utf-8').write(s)
    else:
        sys.exit('android/app/build.gradle(.kts) bulunamadı')
    print('Bağımlılık: Nearby Connections eklendi')


def signing():
    path = os.environ.get('OA_KEYSTORE_PATH')
    if not path or not os.environ.get('OA_KEYSTORE_PASSWORD'):
        print('::warning title=imza::Sabit imza anahtarı yok (ANDROID_KEYSTORE_BASE64 secret). '
              'APK test anahtarıyla imzalanıyor; Android güncellemeyi eski sürümün üzerine kurmaz.')
        return
    kts = 'android/app/build.gradle.kts'
    groovy = 'android/app/build.gradle'
    if os.path.exists(kts):
        s = open(kts, encoding='utf-8').read()
        block = '''    signingConfigs {
        create("oa") {
            storeFile = file(System.getenv("OA_KEYSTORE_PATH"))
            storePassword = System.getenv("OA_KEYSTORE_PASSWORD")
            keyAlias = "oa"
            keyPassword = System.getenv("OA_KEYSTORE_PASSWORD")
        }
    }
'''
        if 'create("oa")' not in s:
            s = re.sub(r'(^android\s*\{\s*\n)', lambda m: m.group(1) + block, s, count=1, flags=re.M)
        s = s.replace('signingConfig = signingConfigs.getByName("debug")',
                      'signingConfig = signingConfigs.getByName("oa")')
        open(kts, 'w', encoding='utf-8').write(s)
    elif os.path.exists(groovy):
        s = open(groovy, encoding='utf-8').read()
        block = '''    signingConfigs {
        oa {
            storeFile file(System.getenv("OA_KEYSTORE_PATH"))
            storePassword System.getenv("OA_KEYSTORE_PASSWORD")
            keyAlias "oa"
            keyPassword System.getenv("OA_KEYSTORE_PASSWORD")
        }
    }
'''
        if 'signingConfigs {' not in s:
            s = re.sub(r'(^android\s*\{\s*\n)', lambda m: m.group(1) + block, s, count=1, flags=re.M)
        s = s.replace('signingConfig signingConfigs.debug', 'signingConfig signingConfigs.oa')
        open(groovy, 'w', encoding='utf-8').write(s)
    else:
        sys.exit('android/app/build.gradle(.kts) bulunamadı')
    print('İmza: yayın sürümü sabit OA anahtarıyla imzalanacak')


if __name__ == '__main__':
    manifest()
    native()
    deps()
    signing()
