import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'core/notifier.dart';

/// Windows: pencere kapatılınca uygulama saat yanındaki simgeye (sistem tepsisi) iner ve
/// arka planda çalışmaya devam eder. "--hidden" ile (Windows açılışında) pencere gösterilmeden başlar.
class DesktopHost with WindowListener, TrayListener {
  DesktopHost._();
  static final DesktopHost i = DesktopHost._();

  Future<void> init(List<String> args) async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(720, 560));
    windowManager.addListener(this);

    try {
      await trayManager.setIcon('assets/icon/tray.ico');
      await trayManager.setToolTip('Pusula Köprü');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Pusula Köprü\'yü aç'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Çıkış'),
      ]));
      trayManager.addListener(this);
    } catch (_) {}

    Notifier.showWindow = show;
    Notifier.windowFocused = () async => await windowManager.isVisible() && await windowManager.isFocused();

    if (args.contains('--hidden')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => windowManager.hide());
    }
  }

  Future<void> show() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> quit() async {
    try {
      await trayManager.destroy();
      await windowManager.setPreventClose(false);
    } catch (_) {}
    exit(0);
  }

  @override
  void onWindowClose() async {
    await windowManager.hide();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('trayHint') != true) {
      await prefs.setBool('trayHint', true);
      await Notifier.show('Pusula Köprü arka planda çalışıyor',
          'Telefonundan gelenleri almaya devam eder. Saat yanındaki köprü simgesinden açabilir ya da kapatabilirsin.',
          always: true);
    }
  }

  @override
  void onTrayIconMouseDown() => show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') show();
    if (menuItem.key == 'exit') quit();
  }
}
