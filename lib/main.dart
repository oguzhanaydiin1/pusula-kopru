import 'dart:io';

import 'package:flutter/material.dart';

import 'core/native.dart';
import 'core/node.dart';
import 'core/notifier.dart';
import 'desktop_host.dart';
import 'theme.dart';
import 'ui/desktop.dart';
import 'ui/mobile.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  Native.init();
  await Notifier.init();
  await DesktopHost.i.init(args);
  await Kopru.i.start();
  runApp(const KopruApp());
}

class KopruApp extends StatelessWidget {
  const KopruApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pusula Köprü',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: Platform.isAndroid ? const MobileShell() : const DesktopHome(),
    );
  }
}
