import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/native.dart';
import 'core/node.dart';
import 'core/notifier.dart';
import 'desktop_host.dart';
import 'l10n.dart';
import 'theme.dart';
import 'ui/desktop.dart';
import 'ui/mobile.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Lang.apply((await SharedPreferences.getInstance()).getString('lang') ?? 'auto');
  Native.init();
  Native.setLang(Lang.en ? 'en' : 'tr');
  await Notifier.init();
  await DesktopHost.i.init(args);
  // Gezgin sağ tık menüsü: pusula_kopru.exe --send "dosya"
  final si = args.indexOf('--send');
  if (si >= 0) Kopru.i.pendingSend = args.sublist(si + 1);
  await Kopru.i.start();
  runApp(const KopruApp());
}

class KopruApp extends StatefulWidget {
  const KopruApp({super.key});

  /// Dil değişince bütün arayüzü yeniden çiz.
  static void setLang(BuildContext context, String v) async {
    Lang.apply(v);
    (await SharedPreferences.getInstance()).setString('lang', v);
    Native.setLang(Lang.en ? 'en' : 'tr');
    if (context.mounted) context.findAncestorStateOfType<_KopruAppState>()?.rebuild();
  }

  @override
  State<KopruApp> createState() => _KopruAppState();
}

class _KopruAppState extends State<KopruApp> {
  int _gen = 0;
  void rebuild() => setState(() => _gen++);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      key: ValueKey(_gen),
      title: 'Pusula Köprü',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: Platform.isAndroid ? MobileShell() : DesktopHome(),
    );
  }
}
