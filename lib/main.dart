import 'dart:io';

import 'package:flutter/material.dart';

import 'core/native.dart';
import 'core/node.dart';
import 'theme.dart';
import 'ui/desktop.dart';
import 'ui/mobile.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Native.init();
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
