import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../core/node.dart';
import '../core/notifier.dart';
import '../theme.dart';
import '../updater.dart';
import 'desktop.dart' show TransferRow, confirmUnpair;
import 'extras.dart';
import 'widgets.dart';

/// Telefon: alt menülü ana kabuk.
class MobileShell extends StatefulWidget {
  MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> with WidgetsBindingObserver {
  final k = Kopru.i;
  int _tab = 0;
  StreamSubscription<KopruEvent>? _sub;
  bool _ringOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = k.events.listen(_onEvent);
    Native.onShared = _onShared;
    Native.onRingStopped = () {
      if (_ringOpen && mounted) Navigator.of(context, rootNavigator: true).pop();
    };
    Updater.check();
    Native.initialShare().then((s) {
      if (s != null) _onShared(s);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) k.sendStatus();
  }

  void _onEvent(KopruEvent e) {
    if (!mounted) return;
    switch (e.type) {
      case 'ring':
        _showRing(e.peer);
      case 'ringStop':
        if (_ringOpen) Navigator.of(context, rootNavigator: true).pop();
      case 'text':
        showSnack(context, L('{0}: yeni {1}', [e.peer?.name ?? L('Bilgisayar'), looksLikeLink(e.text ?? '') ? L('bağlantı') : L('metin')]));
      case 'received':
        showSnack(context, L('{0} geldi · İndirilenler', [e.text]));
      case 'paired':
        showSnack(context, L('{0} ile eşleşti', [e.peer?.name ?? L('Bilgisayar')]));
      case 'unpaired':
        showSnack(context, L('{0} eşleşmeyi kaldırdı', [e.peer?.name ?? L('Cihaz')]));
      case 'error':
        showSnack(context, e.text ?? L('Bir sorun oldu'));
      case 'nearOffer':
        if (e.offer != null) showOfferDialog(context, e.offer!);
    }
  }

  Future<void> _showRing(Peer? p) async {
    if (_ringOpen) return;
    _ringOpen = true;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(L('Telefonun burada'), style: oaDisplay(24)),
        content: Text(L('{0} seni arıyor.', [p?.name ?? L('Bilgisayar')]), style: oaBody(15, color: OA.text2)),
        actions: [
          FilledButton(
            onPressed: () {
              Native.stopRing();
              Navigator.pop(ctx);
            },
            child: Text(L('Durdur')),
          ),
        ],
      ),
    );
    _ringOpen = false;
  }

  Future<void> _onShared(Map<String, dynamic> s) async {
    if (!mounted) return;
    final p = k.selected;
    if (p == null) {
      showSnack(context, L('Önce bir bilgisayarla eşleş'));
      return;
    }
    final files = (s['files'] as List?)?.map((e) => e.toString()).toList() ?? <String>[];
    if (files.isNotEmpty) {
      final batch = k.sendFiles(p, files);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendingScreen(batch: batch, title: L('Paylaş menüsünden'))));
      return;
    }
    final text = s['text']?.toString() ?? '';
    if (text.isEmpty) return;
    final open = s['open'] == true;
    final ok = await k.sendText(p, text, open: open);
    if (open && !ok) {
      // Pusula'dan gönderildi, Köprü ekranı kapalı: sonucu bildirimle söyle
      await Notifier.show(L('Gönderilemedi'), L('{0} bağlı değil. Aynı Wi-Fi\'de ve Pusula Köprü açık mı?', [p.name]), always: true);
    }
    if (mounted) showSnack(context, ok ? L('{0} cihazına gönderildi', [p.name]) : L('{0} bağlı değil', [p.name]));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const _HomeTab(), const _HistoryTab(), const _SettingsTab()];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: OA.bg2,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        body: SafeArea(bottom: false, child: IndexedStack(index: _tab, children: pages)),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(color: OA.bg2, border: Border(top: BorderSide(color: OA.line))),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 68,
              child: Row(children: [
                _nav(0, Icons.home_outlined, L('Ana sayfa')),
                _nav(1, Icons.schedule, L('Geçmiş')),
                _nav(2, Icons.menu, L('Ayarlar')),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _nav(int i, IconData icon, String label) {
    final on = _tab == i;
    final c = on ? OA.amber : OA.muted;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = i),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: c, size: 22),
          SizedBox(height: 4),
          Text(label, style: oaBody(13, color: c, weight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _HomeTab extends StatelessWidget {
  const _HomeTab();

  Future<void> _pick(BuildContext context, Peer p, FileType type) async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true, type: type);
    final paths = r?.files.map((f) => f.path).whereType<String>().toList() ?? <String>[];
    if (paths.isEmpty || !context.mounted) return;
    final batch = Kopru.i.sendFiles(p, paths);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendingScreen(batch: batch)));
  }

  Future<void> _sendClip(BuildContext context, Peer p) async {
    final r = await Kopru.i.sendClipboard(p);
    if (!context.mounted) return;
    showSnack(context, switch (r) {
      null => L('Pano boş'),
      true => L('Pano gönderildi; bilgisayarda yapıştırabilirsin'),
      false => L('{0} bağlı değil', [p.name]),
    });
  }

  Future<void> _screenshot(BuildContext context, Peer p) async {
    final (batch, err) = await Kopru.i.sendLatestScreenshot(p);
    if (!context.mounted) return;
    if (err != null) {
      showSnack(context, err);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SendingScreen(batch: batch!)));
  }

  Future<void> _media(BuildContext context, Peer p, String key) async {
    HapticFeedback.selectionClick();
    final ok = await Kopru.i.media(p, key);
    if (!ok && context.mounted) showSnack(context, L('{0} bağlı değil', [p.name]));
  }

  Future<void> _lock(BuildContext context, Peer p) async {
    final ok = await Kopru.i.lockComputer(p);
    if (context.mounted) showSnack(context, ok ? L('Bilgisayar kilitlendi') : L('{0} bağlı değil', [p.name]));
  }

  void _choosePeer(BuildContext context) {
    final k = Kopru.i;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(L('Hangi cihaz?'), style: oaDisplay(22)),
            SizedBox(height: 12),
            for (final p in k.peers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: IconBox(peerIcon(p), color: p.id == k.selected?.id ? OA.amber : OA.muted),
                title: Text(p.name, style: oaBody(15, weight: FontWeight.w600)),
                subtitle: Text(peerStatus(p), style: oaBody(13, color: p.online ? OA.green : OA.muted)),
                onTap: () {
                  k.selectedPeer = p;
                  Navigator.pop(ctx);
                },
              ),
            SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => PairScreen()));
              },
              icon: Icon(Icons.add),
              label: Text(L('Yeni cihaz eşleştir')),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = Kopru.i;
    return ListenableBuilder(
      listenable: k,
      builder: (context, _) {
        final p = k.selected;
        return ListView(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 24),
          children: [
            Row(children: [
              OALogo(size: 22),
              Spacer(),
              IconButton(
                tooltip: L('Yakındakiler (eşleştirmeden gönder)'),
                style: IconButton.styleFrom(minimumSize: Size(44, 44), side: BorderSide(color: OA.border2)),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => NearbyScreen())),
                icon: Icon(Icons.wifi_tethering, color: k.isVisible ? OA.amber : OA.text),
              ),
              SizedBox(width: 8),
              IconButton(
                tooltip: L('Yeni cihaz eşleştir'),
                style: IconButton.styleFrom(
                  minimumSize: Size(44, 44),
                  side: BorderSide(color: OA.border2),
                ),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PairScreen())),
                icon: Icon(Icons.add, color: OA.text),
              ),
            ]),
            SizedBox(height: 18),
            if (p == null) ..._empty(context) else ..._content(context, p),
          ],
        );
      },
    );
  }

  List<Widget> _empty(BuildContext context) => [
        SizedBox(height: 40),
        Center(child: IconBox(Icons.computer_outlined, size: 72, radius: 22)),
        SizedBox(height: 20),
        Text(L('Bilgisayarını bağla'), textAlign: TextAlign.center, style: oaDisplay(30)),
        SizedBox(height: 10),
        Text(
          L('Bilgisayarda Pusula Köprü\'yü aç, "QR kodu göster"e bas ve buradan okut. İki cihaz aynı Wi-Fi\'de olmalı.'),
          textAlign: TextAlign.center,
          style: oaBody(17, color: OA.text2, height: 1.5),
        ),
        SizedBox(height: 24),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: Size(0, 54)),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PairScreen())),
          icon: Icon(Icons.qr_code_scanner),
          label: Text(L('QR kodu okut'), style: oaBody(17, color: OA.amberInk, weight: FontWeight.w600)),
        ),
        SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: Size(0, 50)),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => NearbyScreen())),
          icon: Icon(Icons.wifi_tethering),
          label: Text(L('Eşleştirmeden yakındakine gönder')),
        ),
        SizedBox(height: 12),
        Text(L('Bilgisayar sürümü: oalabs.dev'), textAlign: TextAlign.center, style: oaBody(13, color: OA.faint)),
      ];

  List<Widget> _content(BuildContext context, Peer p) {
    final k = Kopru.i;
    final actions = <(String, IconData, VoidCallback)>[
      (L('Dosya gönder'), Icons.insert_drive_file_outlined, () => _pick(context, p, FileType.any)),
      (L('Fotoğraf gönder'), Icons.image_outlined, () => _pick(context, p, FileType.media)),
      (L('Panoyu gönder'), Icons.content_paste_go_outlined, () => _sendClip(context, p)),
      (L('Son ekran görüntüsü'), Icons.screenshot_outlined, () => _screenshot(context, p)),
      if (p.isComputer) (L('Bilgisayarı kilitle'), Icons.lock_outline, () => _lock(context, p)),
    ];
    final running = k.active.toList();
    final inc = k.lastIncoming;
    return [
      OACard(
        padding: EdgeInsets.all(16),
        onTap: () => _choosePeer(context),
        child: Row(children: [
          IconBox(peerIcon(p)),
          SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: oaDisplay(17)),
              SizedBox(height: 2),
              Text(p.online ? (k.viaRelay(p) ? L('Bağlı · internet üzerinden') : L('Bağlı · aynı Wi-Fi')) : peerStatus(p),
                  style: oaBody(13, color: p.online ? OA.green : OA.muted, weight: FontWeight.w600)),
            ]),
          ),
          Icon(Icons.expand_more, color: OA.muted),
        ]),
      ),
      SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.75,
        children: [
          for (final a in actions)
            OACard(
              padding: EdgeInsets.all(16),
              onTap: a.$3,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Icon(a.$2, color: OA.amber, size: 22),
                Text(a.$1, style: oaBody(15, weight: FontWeight.w600)),
              ]),
            ),
        ],
      ),
      if (p.isComputer) ...[
        SizedBox(height: 12),
        OACard(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(L('Kumanda'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
            SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              for (final b in [
                ('prev', Icons.skip_previous, L('Önceki')),
                ('playpause', Icons.play_arrow, L('Oynat / duraklat')),
                ('next', Icons.skip_next, L('Sonraki')),
                ('voldown', Icons.volume_down, L('Sesi kıs')),
                ('volup', Icons.volume_up, L('Sesi aç')),
                ('mute', Icons.volume_off, L('Sessiz')),
              ])
                IconButton(
                  tooltip: b.$3,
                  style: IconButton.styleFrom(
                    minimumSize: Size(46, 46),
                    backgroundColor: b.$1 == 'playpause' ? OA.amber : OA.surface2,
                  ),
                  onPressed: () => _media(context, p, b.$1),
                  icon: Icon(b.$2, color: b.$1 == 'playpause' ? OA.amberInk : OA.text),
                ),
            ]),
            SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TouchpadScreen(peer: p))),
                  icon: Icon(Icons.touch_app_outlined, size: 18),
                  label: Text(L('Fare')),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PresentationScreen(peer: p))),
                  icon: Icon(Icons.slideshow_outlined, size: 18),
                  label: Text(L('Sunum')),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => showPowerSheet(context, p),
                  icon: Icon(Icons.power_settings_new, size: 18),
                  label: Text(L('Güç')),
                ),
              ),
            ]),
          ]),
        ),
      ],
      if (running.isNotEmpty) ...[
        SizedBox(height: 12),
        OACard(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(children: [for (final t in running.reversed.take(4)) TransferRow(t)]),
        ),
      ],
      if (p.clip != null) ...[
        SizedBox(height: 12),
        OACard(
          padding: EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(L('{0} panosu · {1}', [p.isComputer ? L('Bilgisayarın') : p.name, timeAgo(p.clipAt!)]),
                style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
            SizedBox(height: 10),
            Text(p.clip!, maxLines: 3, overflow: TextOverflow.ellipsis, style: oaBody(15)),
            SizedBox(height: 12),
            Row(children: [
              Expanded(child: FilledButton(onPressed: () => copyText(context, p.clip!), child: Text(L('Kopyala')))),
              if (looksLikeLink(p.clip!)) ...[
                SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(onPressed: () => openLink(p.clip!, pusula: true), child: Text(L('Pusula\'da aç'))),
                ),
              ],
            ]),
          ]),
        ),
      ],
      if (k.clipHistory.isNotEmpty) ...[
        SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ClipHistoryScreen())),
            icon: Icon(Icons.history, size: 18),
            label: Text(L('Pano geçmişi ({0})', [k.clipHistory.length])),
          ),
        ),
      ],
      if (inc != null) ...[
        SizedBox(height: 12),
        OACard(
          padding: EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(L('{0} gönderdi · {1}', [inc.peerName, timeAgo(inc.at)]), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
            SizedBox(height: 10),
            SelectableText(inc.text, maxLines: 4, style: oaBody(15)),
            SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: inc.isLink
                    ? FilledButton(onPressed: () => openLink(inc.text, pusula: true), child: Text(L('Pusula\'da aç')))
                    : FilledButton(onPressed: () => copyText(context, inc.text), child: Text(L('Kopyala'))),
              ),
              SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: k.dismissIncoming, child: Text(L('Kapat')))),
            ]),
          ]),
        ),
      ],
      SizedBox(height: 20),
      Text(L('Son aktarımlar'), style: oaDisplay(18)),
      SizedBox(height: 4),
      if (k.history.isEmpty)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(L('Henüz bir şey gönderilmedi.'), style: oaBody(15, color: OA.muted)),
        ),
      for (final h in k.history.take(4)) ...[HistoryTile(h, compact: true), Divider()],
    ];
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab();

  @override
  Widget build(BuildContext context) {
    final k = Kopru.i;
    return ListenableBuilder(
      listenable: k,
      builder: (context, _) => ListView(
        padding: EdgeInsets.fromLTRB(16, 24, 16, 24),
        children: [
          Row(children: [
            Expanded(child: Text(L('Geçmiş'), style: oaDisplay(30))),
            if (k.history.isNotEmpty) TextButton(onPressed: k.clearHistory, child: Text(L('Temizle'))),
          ]),
          SizedBox(height: 8),
          if (k.history.isEmpty) Text(L('Gönderdiğin ve gelen her şey burada listelenir.'), style: oaBody(15, color: OA.muted)),
          for (final h in k.history) ...[HistoryTile(h, compact: true), Divider()],
          if (k.history.isNotEmpty) ...[
            SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: Native.openDownloads,
              icon: Icon(Icons.folder_open_outlined),
              label: Text(L('İndirilenler klasörünü aç')),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab();

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> with WidgetsBindingObserver {
  final k = Kopru.i;
  late final _name = TextEditingController(text: k.myName);
  String? _updateText;
  UpdateInfo? get _update => updateAvailable.value;
  set _update(UpdateInfo? v) => updateAvailable.value = v;
  bool? _access;
  bool _mirrorAvailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccess();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAccess();
  }

  Future<void> _checkAccess() async {
    final a = await Native.notificationAccess();
    final m = await Native.mirrorAvailable();
    if (mounted) {
      setState(() {
        _access = a;
        _mirrorAvailable = m;
      });
    }
  }

  Future<void> _toggleBackup(bool on) async {
    if (!on) {
      await k.setBackup(false);
      return;
    }
    final pcs = k.peers.where((p) => p.isComputer).toList();
    if (pcs.isEmpty) {
      showSnack(context, L('Önce bir bilgisayarla eşleş'));
      return;
    }
    if (!await Native.mediaPermission()) {
      await Native.requestMedia();
      if (mounted) showSnack(context, L('Fotoğraf ve video izni verdikten sonra tekrar aç'));
      return;
    }
    if (!mounted) return;
    final all = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L('Hangi fotoğraflar?'), style: oaDisplay(22)),
        content: Text(
          L('Yedek {0} bilgisayarına, aynı Wi-Fi\'deyken gider. Telefondaki bütün fotoğraf ve videolar mı, ', [pcs.first.name])
          L('yoksa yalnız bundan sonra çektiklerin mi?'),
          style: oaBody(15, color: OA.text2, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L('Bundan sonrakiler'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(L('Hepsi'))),
        ],
      ),
    );
    if (all == null) return;
    await k.setBackup(true, peerId: (k.selected?.isComputer == true ? k.selected! : pcs.first).id, all: all);
  }

  Future<void> _toggleMirror(bool on) async {
    await k.setMirror(on);
    if (on && !(await Native.notificationAccess())) await _explainAccess();
  }

  Future<void> _explainAccess() async {
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L('Bildirim erişimi'), style: oaDisplay(22)),
        content: Text(
          L('Açılan ekranda Pusula Köprü\'yü bul ve izni aç.\n\n')
          L('İzin gri ve açılmıyorsa: Ayarlar → Uygulamalar → Pusula Köprü → sağ üstteki ⋮ → ')
          L('"Kısıtlanmış ayarlara izin ver", sonra tekrar dene. (Android bunu Google Play dışından kurulan uygulamalarda ister.)'),
          style: oaBody(15, color: OA.text2, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L('Vazgeç'))),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Native.openNotificationAccess();
            },
            child: Text(L('Ayarları aç')),
          ),
        ],
      ),
    );
  }

  Widget _switchRow(String title, String text, bool value, ValueChanged<bool> onChanged,
      {bool warn = false, VoidCallback? onTapText}) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: InkWell(
          onTap: onTapText,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: oaBody(15, weight: FontWeight.w600)),
            SizedBox(height: 2),
            Text(text, style: oaBody(13, color: warn ? OA.danger : OA.muted, height: 1.4)),
          ]),
        ),
      ),
      SizedBox(width: 12),
      Switch(value: value, onChanged: onChanged),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: k,
      builder: (context, _) => ListView(
        padding: EdgeInsets.fromLTRB(16, 24, 16, 24),
        children: [
          Text(L('Ayarlar'), style: oaDisplay(30)),
          SizedBox(height: 20),
          const LanguagePicker(),
          const SizedBox(height: 16),
          Text(L('Bu telefonun adı'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
          SizedBox(height: 8),
          TextField(
            controller: _name,
            style: oaBody(15),
            textInputAction: TextInputAction.done,
            onSubmitted: k.setMyName,
            onTapOutside: (_) {
              FocusScope.of(context).unfocus();
              if (_name.text.trim() != k.myName) k.setMyName(_name.text);
            },
          ),
          SizedBox(height: 24),
          _switchRow(
            L('Arka planda çalış'),
            L('Uygulama kapalıyken de bilgisayardan gelen dosyaları alır ve "Telefonu çaldır" çalışır. ')
                L('Bildirim çubuğunda sessiz bir "Pusula Köprü açık" bildirimi durur.'),
            k.background,
            k.setBackground,
          ),
          if (_mirrorAvailable) SizedBox(height: 16),
          if (_mirrorAvailable)
          _switchRow(
            L('Bildirimleri bilgisayara ilet'),
            _access == false && k.mirror
                ? L('Bildirim erişimi kapalı. Açmak için dokun.')
                : L('Telefona gelen bildirimler bilgisayarda görünür; mesajlara bilgisayardan yanıt verebilirsin.'),
            k.mirror,
            _toggleMirror,
            warn: _access == false && k.mirror,
            onTapText: _access == false && k.mirror ? _explainAccess : null,
          ),
          SizedBox(height: 16),
          _switchRow(
            L('Fotoğrafları bilgisayara yedekle'),
            k.backupOn
                ? (k.backupRunning
                    ? 'Yedekleniyor…'
                    : L('{0} · {1} öğe', [k.peerById(k.backupPeerId)?.name ?? L('Bilgisayar'), k.backupCount])
                        L('{0}. Yalnız aynı Wi-Fi\'de, mobil veri harcamaz.', [k.backupLast != null ? L(' · son: {0}', [timeAgo(k.backupLast!)]) : '']))
                : L('Yeni fotoğraf ve videolar, bilgisayarla aynı Wi-Fi\'deyken Resimler\\Pusula Köprü klasörüne kopyalanır.'),
            k.backupOn,
            _toggleBackup,
          ),
          SizedBox(height: 16),
          _switchRow(
            L('Bilgisayar fotoğraflarıma göz atabilsin'),
            L('Eşleşmiş bilgisayardan telefonun fotoğraf, video ve İndirilenler\'ine bakıp seçtiklerini alabilirsin.'),
            k.browseAllowed,
            (v) async {
              await k.setBrowseAllowed(v);
              if (v && !await Native.mediaPermission()) await Native.requestMedia();
            },
          ),
          SizedBox(height: 16),
          _switchRow(
            L('Farklı ağdayken de bağlan'),
            L('Bilgisayarla aynı Wi-Fi\'de değilken (mobil veri, iş yeri) OA sunucusu üzerinden, uçtan uca şifreli. ')
                L('Dosya başına en fazla 100 MB.'),
            k.relayOn,
            k.setRelay,
          ),
          SizedBox(height: 24),
          Text(L('Eşleşmiş cihazlar'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
          SizedBox(height: 4),
          if (k.peers.isEmpty) Text(L('Henüz yok.'), style: oaBody(15, color: OA.muted)),
          for (final p in k.peers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: IconBox(peerIcon(p), color: OA.text2),
              title: Text(p.name, style: oaBody(15, weight: FontWeight.w600)),
              subtitle: Text(peerStatus(p), style: oaBody(13, color: p.online ? OA.green : OA.muted)),
              trailing: TextButton(
                onPressed: () async {
                  if (await confirmUnpair(context, p)) await k.unpair(p);
                },
                child: Text(L('Kaldır'), style: oaBody(15, color: OA.danger, weight: FontWeight.w600)),
              ),
            ),
          SizedBox(height: 20),
          Text(L('Gelen dosyalar'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
          SizedBox(height: 6),
          Text(L('İndirilenler / Pusula Köprü'), style: oaBody(15, color: OA.text2)),
          SizedBox(height: 24),

          Row(children: [
            Expanded(
                child: Text(L('Sürüm {0}', [appVersion == '0.0.0' ? L('geliştirme') : appVersion]), style: oaBody(14, color: OA.muted))),
            if (_update != null)
              FilledButton(
                onPressed: () => launchUrl(Uri.parse(_update!.assetUrl), mode: LaunchMode.externalApplication),
                child: Text(L('{0} indir', [_update!.version])),
              )
            else
              TextButton(
                onPressed: () async {
                  setState(() => _updateText = 'Denetleniyor…');
                  final u = await Updater.check();
                  if (mounted) {
                    setState(() {
                      _update = u;
                      _updateText = u == null ? L('Güncel') : null;
                    });
                  }
                },
                child: Text(_updateText ?? L('Güncellemeleri denetle')),
              ),
          ]),
          SizedBox(height: 8),
          Text(L('OA Labs · oalabs.dev'), style: oaBody(13, color: OA.faint)),
        ],
      ),
    );
  }
}

/// QR ile eşleştirme (taslaktaki "Telefon — QR ile eşleştirme").
class PairScreen extends StatefulWidget {
  PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture c) async {
    if (_busy) return;
    final v = c.barcodes.map((b) => b.rawValue).whereType<String>().where((s) => s.startsWith('pusulakopru://')).firstOrNull;
    if (v == null) return;
    setState(() => _busy = true);
    HapticFeedback.mediumImpact();
    try {
      await Kopru.i.pairWithQr(v);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        showSnack(context, e.toString());
        await Future.delayed(Duration(seconds: 2));
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Widget _corner(Alignment a) {
    const side = BorderSide(color: OA.amber, width: 4);
    final top = a.y < 0, left = a.x < 0;
    return Align(
      alignment: a,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          border: Border(
            top: top ? side : BorderSide.none,
            bottom: top ? BorderSide.none : side,
            left: left ? side : BorderSide.none,
            right: left ? BorderSide.none : side,
          ),
          borderRadius: BorderRadius.only(
            topLeft: top && left ? Radius.circular(18) : Radius.zero,
            topRight: top && !left ? Radius.circular(18) : Radius.zero,
            bottomLeft: !top && left ? Radius.circular(18) : Radius.zero,
            bottomRight: !top && !left ? Radius.circular(18) : Radius.zero,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 24),
          children: [
            Row(children: [
              IconButton(
                tooltip: L('Geri'),
                style: IconButton.styleFrom(minimumSize: Size(44, 44), side: BorderSide(color: OA.border2)),
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.chevron_left, color: OA.text),
              ),
              SizedBox(width: 8),
              Text(L('Yeni cihaz'), style: oaBody(15, color: OA.text2, weight: FontWeight.w600)),
            ]),
            SizedBox(height: 20),
            Text(L('Bilgisayardaki QR kodu okut'), style: oaDisplay(30)),
            SizedBox(height: 8),
            Text(L('Pusula Köprü\'yü bilgisayarında aç, "Yeni cihaz eşleştir"e bas.'),
                style: oaBody(17, color: OA.text2, height: 1.5)),
            SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                height: 340,
                decoration: BoxDecoration(color: OA.bg2, border: Border.all(color: OA.border)),
                child: Stack(fit: StackFit.expand, children: [
                  MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    errorBuilder: (context, error) => Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          error.errorCode == MobileScannerErrorCode.permissionDenied
                              ? L('Kamera izni verilmedi. Ayarlardan izin verebilir ya da kodla eşleştirebilirsin.')
                              : L('Kamera açılamadı. Kodla eşleştirebilirsin.'),
                          textAlign: TextAlign.center,
                          style: oaBody(15, color: OA.text2),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: SizedBox(
                      width: 220,
                      height: 220,
                      child: Stack(children: [
                        _corner(Alignment.topLeft),
                        _corner(Alignment.topRight),
                        _corner(Alignment.bottomLeft),
                        _corner(Alignment.bottomRight),
                      ]),
                    ),
                  ),
                  if (_busy)
                    Container(
                      color: OA.bg.withValues(alpha: 0.75),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text(L('Eşleşiyor…'), style: oaBody(15, weight: FontWeight.w600)),
                      ]),
                    ),
                ]),
              ),
            ),
            SizedBox(height: 20),
            _step('1', L('İki cihaz da aynı Wi-Fi\'de olursa aktarım doğrudan olur.')),
            SizedBox(height: 10),
            _step('2', L('Eşleşince bağlantı şifrelenir; ağdaki başka biri ne gönderdiğini göremez.')),
            SizedBox(height: 24),
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: Size(0, 54)),
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (_) => const _CodePairSheet(),
              ).then((paired) {
                if (paired == true && mounted) Navigator.pop(context);
              }),
              child: Text(L('Kodla eşleştir'), style: oaBody(17, weight: FontWeight.w600)),
            ),
            SizedBox(height: 10),
            Text(L('Kamera yoksa bilgisayardaki 6 haneli kodu gir.'),
                textAlign: TextAlign.center, style: oaBody(13, color: OA.muted)),
          ],
        ),
      ),
    );
  }

  Widget _step(String n, String text) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: OA.surface2, shape: BoxShape.circle),
          child: Text(n, style: oaBody(13, color: OA.amber, weight: FontWeight.w600)),
        ),
        SizedBox(width: 12),
        Expanded(child: Text(text, style: oaBody(15, color: OA.text2, height: 1.4))),
      ]);
}

class _CodePairSheet extends StatefulWidget {
  const _CodePairSheet();

  @override
  State<_CodePairSheet> createState() => _CodePairSheetState();
}

class _CodePairSheetState extends State<_CodePairSheet> {
  final k = Kopru.i;
  final _code = TextEditingController();
  String? _chosen;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final d = k.nearby[_chosen];
    if (d == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await k.pairWithCode(d, _code.text);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: ListenableBuilder(
          listenable: k,
          builder: (context, _) {
            final list = k.nearby.values.toList();
            if (_chosen == null && list.length == 1) _chosen = list.first.id;
            return Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(L('Kodla eşleştir'), style: oaDisplay(24)),
                SizedBox(height: 8),
                Text(L('Bilgisayarda "Yeni cihaz eşleştir" penceresi açıkken burada görünür.'),
                    style: oaBody(15, color: OA.text2, height: 1.4)),
                SizedBox(height: 16),
                if (list.isEmpty)
                  Row(children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 12),
                    Expanded(child: Text(L('Aynı Wi-Fi\'deki bilgisayarlar aranıyor…'), style: oaBody(15, color: OA.muted))),
                  ]),
                for (final d in list)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: d.id,
                    groupValue: _chosen,
                    onChanged: (v) => setState(() => _chosen = v),
                    title: Text(d.name, style: oaBody(15, weight: FontWeight.w600)),
                    subtitle: Text(d.address, style: oaBody(13, color: OA.muted)),
                  ),
                SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 7,
                  style: oaDisplay(26).copyWith(letterSpacing: 4),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(hintText: '000 000', counterText: ''),
                  onSubmitted: (_) => _go(),
                ),
                if (_error != null) ...[
                  SizedBox(height: 8),
                  Text(_error!, style: oaBody(14, color: OA.danger)),
                ],
                SizedBox(height: 16),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: Size(0, 54)),
                  onPressed: _busy || _chosen == null ? null : _go,
                  child: _busy
                      ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: OA.amberInk))
                      : Text(L('Eşleştir'), style: oaBody(17, color: OA.amberInk, weight: FontWeight.w600)),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

/// Gönderim ilerlemesi (taslaktaki "Telefon — gönderiliyor").
class SendingScreen extends StatelessWidget {
  SendingScreen({super.key, required this.batch, this.title});
  final String batch;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final k = Kopru.i;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: k,
          builder: (context, _) {
            final items = k.active.where((t) => t.batch == batch).toList();
            final peer = items.isEmpty ? k.selected : k.peerById(items.first.peerId);
            final total = items.fold<int>(0, (a, t) => a + t.size);
            final done = items.fold<int>(0, (a, t) => a + (t.state == 'done' ? t.size : t.done));
            final finished = items.isNotEmpty && items.every((t) => t.finished);
            final failed = items.where((t) => t.state == 'failed').length;
            final cancelled = items.any((t) => t.state == 'cancelled');
            final pct = total == 0 ? (finished ? 100 : 0) : (done * 100 / total).floor();
            final speed = items.where((t) => t.state == 'running').fold<double>(0, (a, t) => a + t.speed);
            final count = items.where((t) => t.state == 'done').length;
            final heading = finished
                ? (failed > 0
                    ? L('{0} dosya gönderilemedi', [failed])
                    : cancelled
                        ? L('Gönderim iptal edildi')
                        : L('{0} cihazına gönderildi', [peer?.name ?? L('Bilgisayar')]))
                : L('{0} cihazına gönderiliyor', [peer?.name ?? L('Bilgisayar')]);
            return ListView(
              padding: EdgeInsets.fromLTRB(16, 28, 16, 24),
              children: [
                Row(children: [
                  OALogo(showText: false),
                  SizedBox(width: 10),
                  Text(title ?? L('Gönderim'), style: oaBody(15, color: OA.text2, weight: FontWeight.w600)),
                ]),
                SizedBox(height: 20),
                Text(heading, style: oaDisplay(30)),
                SizedBox(height: 20),
                OACard(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(children: [for (final t in items) TransferRow(t)]),
                ),
                SizedBox(height: 16),
                Center(child: Text('%${pct}', style: oaDisplay(44))),
                SizedBox(height: 6),
                Center(
                  child: Text(
                    L('{0} / {1} dosya · {2} / {3}', [count, items.length, formatSize(done), formatSize(total)])
                    '${speed > 0 && !finished ? L(' · {0}/sn', [formatSize(speed.round())]) : ''}',
                    style: oaBody(15, color: OA.text2),
                  ),
                ),
                SizedBox(height: 16),
                Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
                  items.any((t) => t.viaRelay)
                      ? OAChip(label: L('İnternet üzerinden'), dot: OA.blue)
                      : OAChip(label: L('Aynı Wi-Fi · doğrudan'), dot: OA.green),
                  OAChip(label: L('Şifreli'), icon: Icons.lock_outline),
                ]),
                SizedBox(height: 32),
                if (finished)
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: Size(0, 54)),
                    onPressed: () => Navigator.pop(context),
                    child: Text(L('Tamam'), style: oaBody(17, color: OA.amberInk, weight: FontWeight.w600)),
                  )
                else ...[
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: Size(0, 54)),
                    onPressed: () => Navigator.pop(context),
                    child: Text(L('Arka planda devam et'), style: oaBody(17, weight: FontWeight.w600)),
                  ),
                  SizedBox(height: 10),
                  TextButton(
                    onPressed: () => k.cancelBatch(batch),
                    child: Text(L('İptal et'), style: oaBody(15, color: OA.danger, weight: FontWeight.w600)),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}


class NearbyScreen extends StatelessWidget {
  NearbyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L('Yakındakiler'), style: oaDisplay(20))),
      body: ListView(
        padding: EdgeInsets.all(16),
        children: [
          Text(L('Eşleştirmeden, aynı Wi-Fi\'deki birine tek seferlik dosya gönder ya da al. ')
              L('Karşı taraf her gönderimi onaylar; dosyalar şifreli gider.'),
              style: oaBody(15, color: OA.text2, height: 1.5)),
          SizedBox(height: 16),
          NearbyPanel(),
        ],
      ),
    );
  }
}
