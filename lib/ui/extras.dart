import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../core/node.dart';
import '../theme.dart';
import 'widgets.dart';

// ============================================================ dokunmatik yüzey (telefon)

class TouchpadScreen extends StatefulWidget {
  TouchpadScreen({super.key, required this.peer});
  final Peer peer;

  @override
  State<TouchpadScreen> createState() => _TouchpadScreenState();
}

class _TouchpadScreenState extends State<TouchpadScreen> {
  final k = Kopru.i;
  double _speed = 1.6;
  int _pointers = 0;
  bool _dragging = false;
  final _text = TextEditingController();
  bool _keyboard = false;

  Peer get p => widget.peer;

  @override
  void dispose() {
    if (_dragging) k.input(p, {'k': 'drag', 'down': false});
    _text.dispose();
    super.dispose();
  }

  void _key(String name) {
    HapticFeedback.selectionClick();
    k.input(p, {'k': 'key', 'name': name});
  }

  Future<void> _sendText() async {
    final t = _text.text;
    if (t.isEmpty) return;
    _text.clear();
    final ok = await k.input(p, {'k': 'type', 'text': t});
    if (!ok && mounted) showSnack(context, L('{0} bağlı değil', [p.name]));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L('Dokunmatik yüzey'), style: oaDisplay(20)),
        actions: [
          IconButton(
            tooltip: _keyboard ? L('Klavyeyi gizle') : L('Klavye'),
            onPressed: () => setState(() => _keyboard = !_keyboard),
            icon: Icon(_keyboard ? Icons.keyboard_hide_outlined : Icons.keyboard_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (_keyboard) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    autofocus: true,
                    style: oaBody(15),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendText(),
                    decoration: InputDecoration(hintText: L('Yaz, bilgisayarda belirsin')),
                  ),
                ),
                SizedBox(width: 8),
                FilledButton(onPressed: _sendText, child: Text(L('Yaz'))),
              ]),
            ),
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  for (final b in [
                    ('enter', 'Enter'),
                    ('backspace', '⌫'),
                    ('tab', 'Tab'),
                    ('esc', 'Esc'),
                    ('left', '←'),
                    ('up', '↑'),
                    ('down', '↓'),
                    ('right', '→'),
                    ('copy', L('Kopyala')),
                    ('paste', L('Yapıştır')),
                    ('undo', L('Geri al')),
                    ('alttab', 'Alt+Tab'),
                    ('desktop', L('Masaüstü')),
                  ])
                    Padding(
                      padding: EdgeInsets.only(right: 6),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(minimumSize: Size(44, 36), padding: EdgeInsets.symmetric(horizontal: 12)),
                        onPressed: () => _key(b.$1),
                        child: Text(b.$2),
                      ),
                    ),
                ],
              ),
            ),
          ],
          Expanded(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Listener(
                onPointerDown: (_) => _pointers++,
                onPointerUp: (_) => _pointers = (_pointers - 1).clamp(0, 10),
                onPointerCancel: (_) => _pointers = (_pointers - 1).clamp(0, 10),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => k.input(p, {'k': 'click'}),
                  onDoubleTap: () => k.input(p, {'k': 'click', 'double': true}),
                  onLongPress: () {
                    HapticFeedback.mediumImpact();
                    k.input(p, {'k': 'click', 'right': true});
                  },
                  onScaleUpdate: (d) {
                    final dx = d.focalPointDelta.dx, dy = d.focalPointDelta.dy;
                    if (_pointers >= 2 || d.pointerCount >= 2) {
                      k.mouseScroll(p, -dx * 4, dy * 4);
                    } else {
                      k.mouseMove(p, dx * _speed, dy * _speed);
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: OA.surface,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: _dragging ? OA.amber : OA.border),
                    ),
                    alignment: Alignment.center,
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        L('Parmağını kaydır: fare\nDokun: tıkla · Uzun bas: sağ tık\nİki parmak: kaydır'),
                        textAlign: TextAlign.center,
                        style: oaBody(15, color: OA.faint, height: 1.6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: Size(0, 52)),
                  onPressed: () => k.input(p, {'k': 'click'}),
                  child: Text(L('Sol tık')),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size(0, 52),
                    backgroundColor: _dragging ? OA.amber.withValues(alpha: 0.16) : null,
                  ),
                  onPressed: () {
                    setState(() => _dragging = !_dragging);
                    k.input(p, {'k': 'drag', 'down': _dragging});
                  },
                  child: Text(_dragging ? L('Bırak') : L('Sürükle')),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: Size(0, 52)),
                  onPressed: () => k.input(p, {'k': 'click', 'right': true}),
                  child: Text(L('Sağ tık')),
                ),
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(children: [
              Text(L('Hız'), style: oaBody(13, color: OA.muted)),
              Expanded(
                child: Slider(value: _speed, min: 0.6, max: 3.5, onChanged: (v) => setState(() => _speed = v)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ============================================================ sunum kumandası (telefon)

class PresentationScreen extends StatefulWidget {
  PresentationScreen({super.key, required this.peer});
  final Peer peer;

  @override
  State<PresentationScreen> createState() => _PresentationScreenState();
}

class _PresentationScreenState extends State<PresentationScreen> {
  final k = Kopru.i;
  final _sw = Stopwatch();
  Timer? _tick;
  int _slide = 1;

  @override
  void initState() {
    super.initState();
    Native.captureVolume(true);
    Native.onVolumeKey = (d) => d == 'down' ? _next() : _prev();
    _tick = Timer.periodic(Duration(seconds: 1), (_) {
      if (mounted && _sw.isRunning) setState(() {});
    });
  }

  @override
  void dispose() {
    Native.captureVolume(false);
    Native.onVolumeKey = null;
    _tick?.cancel();
    super.dispose();
  }

  void _key(String name) {
    HapticFeedback.mediumImpact();
    k.input(widget.peer, {'k': 'key', 'name': name});
  }

  void _next() {
    _key('right');
    setState(() => _slide++);
  }

  void _prev() {
    _key('left');
    setState(() => _slide = (_slide - 1).clamp(1, 9999));
  }

  @override
  Widget build(BuildContext context) {
    final e = _sw.elapsed;
    final time = '${e.inMinutes.toString().padLeft(2, '0')}:${(e.inSeconds % 60).toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(title: Text(L('Sunum kumandası'), style: oaDisplay(20))),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              OAChip(label: L('Slayt {0}', [_slide])),
              SizedBox(width: 8),
              OAChip(label: time, icon: Icons.timer_outlined),
              Spacer(),
              TextButton(
                onPressed: () => setState(() => _sw.isRunning ? _sw.stop() : _sw.start()),
                child: Text(_sw.isRunning ? L('Duraklat') : L('Süreyi başlat')),
              ),
            ]),
            SizedBox(height: 16),
            Expanded(
              flex: 3,
              child: FilledButton(
                style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))),
                onPressed: _next,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.arrow_forward, size: 56, color: OA.amberInk),
                  SizedBox(height: 8),
                  Text(L('İleri'), style: oaDisplay(28, color: OA.amberInk)),
                ]),
              ),
            ),
            SizedBox(height: 12),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
                onPressed: _prev,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.arrow_back),
                  SizedBox(width: 8),
                  Text(L('Geri'), style: oaDisplay(22)),
                ]),
              ),
            ),
            SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _key('f5'), child: Text(L('Baştan başlat')))),
              SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: () => _key('shiftf5'), child: Text(L('Buradan başlat')))),
            ]),
            SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _key('black'), child: Text(L('Siyah ekran')))),
              SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: () => _key('esc'), child: Text(L('Bitir')))),
            ]),
            SizedBox(height: 10),
            Text(L('Telefonun ses tuşlarıyla da geçebilirsin: kıs = ileri, aç = geri.'),
                textAlign: TextAlign.center, style: oaBody(13, color: OA.muted)),
          ]),
        ),
      ),
    );
  }
}

// ============================================================ güç menüsü (telefon)

Future<void> showPowerSheet(BuildContext context, Peer p) async {
  final k = Kopru.i;
  Future<void> run(String a, String done, {String? confirm}) async {
    Navigator.pop(context);
    if (confirm != null) {
      final yes = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(confirm, style: oaDisplay(22)),
          content: Text(L('Açık belgeler kaydedilmediyse kaybolabilir. 5 saniye içinde başlar.'), style: oaBody(15, color: OA.text2)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L('Vazgeç'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(L('Evet'))),
          ],
        ),
      );
      if (yes != true) return;
    }
    final ok = await k.power(p, a);
    if (context.mounted) showSnack(context, ok ? done : L('{0} bağlı değil', [p.name]));
  }

  await showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 16, 8, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(p.name, style: oaDisplay(20)),
          SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.lock_outline, color: OA.amber),
            title: Text(L('Kilitle')),
            onTap: () => run('lock', L('Bilgisayar kilitlendi')),
          ),
          if (k.canWake(p) && !p.lanOnline)
            ListTile(
              leading: Icon(Icons.wb_sunny_outlined, color: OA.amber),
              title: Text(L('Uyandır (Wake-on-LAN)')),
              onTap: () async {
                Navigator.pop(context);
                final ok = await k.wake(p);
                if (context.mounted) showSnack(context, ok ? L('Uyandırma sinyali gönderildi') : L('Gönderilemedi'));
              },
            ),
          ListTile(
            leading: Icon(Icons.bedtime_outlined, color: OA.amber),
            title: Text(L('Uyut')),
            onTap: () => run('sleep', L('Bilgisayar uyutuluyor')),
          ),
          ListTile(
            leading: Icon(Icons.restart_alt, color: OA.amber),
            title: Text(L('Yeniden başlat')),
            onTap: () => run('restart', L('Bilgisayar yeniden başlıyor'), confirm: L('Yeniden başlatılsın mı?')),
          ),
          ListTile(
            leading: Icon(Icons.power_settings_new, color: OA.danger),
            title: Text(L('Kapat'), style: oaBody(16, color: OA.danger)),
            onTap: () => run('shutdown', L('Bilgisayar kapanıyor'), confirm: L('Bilgisayar kapatılsın mı?')),
          ),
        ]),
      ),
    ),
  );
}

// ============================================================ pano geçmişi (iki cihaz)

class ClipHistoryList extends StatelessWidget {
  ClipHistoryList({super.key, this.max = 20});
  final int max;

  @override
  Widget build(BuildContext context) {
    final k = Kopru.i;
    final items = k.clipHistory.take(max).toList();
    if (items.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(L('Kopyaladıkların ve gelen panolar burada listelenir. Şifre gibi görünenler saklanmaz.'),
            style: oaBody(14, color: OA.muted, height: 1.4)),
      );
    }
    return Column(children: [
      for (final c in items)
        InkWell(
          onTap: () => copyText(context, c.text),
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              Icon(looksLikeLink(c.text) ? Icons.link : Icons.notes_outlined, size: 18, color: OA.muted),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.text.replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: oaBody(15)),
                  Text('${c.from} · ${timeAgo(c.at)}', style: oaBody(12, color: OA.faint)),
                ]),
              ),
              Icon(Icons.copy, size: 16, color: OA.faint),
            ]),
          ),
        ),
    ]);
  }
}

class ClipHistoryScreen extends StatelessWidget {
  ClipHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L('Pano geçmişi'), style: oaDisplay(20)),
        actions: [TextButton(onPressed: Kopru.i.clearClipHistory, child: Text(L('Temizle')))],
      ),
      body: ListenableBuilder(
        listenable: Kopru.i,
        builder: (context, _) => ListView(padding: EdgeInsets.all(16), children: [ClipHistoryList()]),
      ),
    );
  }
}

// ============================================================ eşleştirmeden gönderme (iki cihaz)

/// Yakındakiler: görünür ol (al) ya da görünür bir cihaza gönder.
class NearbyPanel extends StatefulWidget {
  NearbyPanel({super.key});

  @override
  State<NearbyPanel> createState() => _NearbyPanelState();
}

class _NearbyPanelState extends State<NearbyPanel> {
  final k = Kopru.i;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _send(NearbyDevice d) async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = r?.files.map((f) => f.path).whereType<String>().toList() ?? <String>[];
    if (paths.isEmpty || !mounted) return;
    await sendNearbyFlow(context, d, paths);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: k,
      builder: (context, _) {
        final list = k.visible.values.where((d) => k.peerById(d.id) == null).toList();
        final left = k.visibleUntil?.difference(DateTime.now()).inSeconds ?? 0;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          OACard(
            highlight: k.isVisible,
            padding: EdgeInsets.all(16),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(L('Yakındakilerden al'), style: oaBody(15, weight: FontWeight.w600)),
                  SizedBox(height: 2),
                  Text(
                    k.isVisible
                        ? L('Aynı Wi-Fi\'dekiler seni "{0}" olarak görüyor · {1}:{2}', [k.myName, left ~/ 60, (left % 60).toString().padLeft(2, '0')])
                        : L('Açınca 10 dakika boyunca, eşleşmemiş cihazlar sana dosya gönderebilir. Her gönderimi sen onaylarsın.'),
                    style: oaBody(13, color: k.isVisible ? OA.green : OA.muted, height: 1.4),
                  ),
                ]),
              ),
              Switch(value: k.isVisible, onChanged: k.setVisible),
            ]),
          ),
          SizedBox(height: 16),
          Text(L('Gönder'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
          SizedBox(height: 6),
          if (list.isEmpty)
            Row(children: [
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Expanded(
                child: Text(L('Aynı Wi-Fi\'de "Yakındakilerden al"ı açan cihazlar burada görünür.'),
                    style: oaBody(14, color: OA.muted, height: 1.4)),
              ),
            ]),
          for (final d in list)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: IconBox(d.platform == 'android' ? Icons.smartphone_outlined : Icons.computer_outlined),
              title: Text(d.name, style: oaBody(15, weight: FontWeight.w600)),
              subtitle: Text(L('Eşleşmemiş · aynı Wi-Fi'), style: oaBody(13, color: OA.muted)),
              trailing: FilledButton(onPressed: () => _send(d), child: Text(L('Dosya gönder'))),
            ),
        ]);
      },
    );
  }
}

/// Gönderim: doğrulama kodunu göster, karşı taraf kabul edince ilerlemeyi göster.
Future<void> sendNearbyFlow(BuildContext context, NearbyDevice d, List<String> paths) async {
  final sas = ValueNotifier<String?>(null);
  final state = ValueNotifier<String>('bekliyor'); // bekliyor | gidiyor | bitti | hata
  final err = ValueNotifier<String?>(null);
  String? batch;
  unawaited(Kopru.i.sendNearby(d, paths, onSas: (c) => sas.value = c, onStart: (b) {
    batch = b;
    state.value = 'gidiyor';
  }).then((e) {
    if (e != null) {
      err.value = e;
      state.value = 'hata';
    } else {
      state.value = 'bitti';
    }
  }));
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([sas, state, err, Kopru.i]),
      builder: (ctx, _) {
        final items = batch == null ? <ActiveTransfer>[] : Kopru.i.active.where((t) => t.batch == batch).toList();
        final total = items.fold<int>(0, (a, t) => a + t.size);
        final done = items.fold<int>(0, (a, t) => a + (t.state == 'done' ? t.size : t.done));
        final failed = items.where((t) => t.state == 'failed').length;
        return AlertDialog(
          title: Text(
            switch (state.value) {
              'bekliyor' => L('{0} onaylasın', [d.name]),
              'gidiyor' => L('Gönderiliyor'),
              'bitti' => failed > 0 ? L('{0} dosya gönderilemedi', [failed]) : L('Gönderildi'),
              _ => L('Gönderilemedi'),
            },
            style: oaDisplay(22),
          ),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (state.value == 'bekliyor') ...[
                Text(L('Karşı ekranda "Kabul et"e basılmasını bekliyoruz. Bu kod iki ekranda da aynı olmalı:'),
                    style: oaBody(15, color: OA.text2, height: 1.5)),
                SizedBox(height: 12),
                Center(child: Text(sas.value ?? '··· ···', style: oaDisplay(34).copyWith(letterSpacing: 2))),
              ],
              if (state.value == 'gidiyor' || state.value == 'bitti') ...[
                LinearProgressIndicator(value: total == 0 ? null : done / total, minHeight: 6, borderRadius: BorderRadius.circular(9)),
                SizedBox(height: 10),
                Text(L('{0} / {1} dosya · {2} / {3}', [items.where((t) => t.state == 'done').length, items.length, formatSize(done), formatSize(total)]),
                    style: oaBody(14, color: OA.text2)),
              ],
              if (state.value == 'hata') Text(err.value ?? '', style: oaBody(15, color: OA.danger)),
            ]),
          ),
          actions: [
            if (state.value == 'gidiyor' && batch != null)
              TextButton(onPressed: () => Kopru.i.cancelBatch(batch!), child: Text(L('İptal et'))),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(state.value == 'bitti' || state.value == 'hata' ? L('Tamam') : L('Arka planda devam et')),
            ),
          ],
        );
      },
    ),
  );
}

/// Alan taraf: gelen teklif.
Future<void> showOfferDialog(BuildContext context, NearOffer o) async {
  final r = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(L('{0} dosya göndermek istiyor', [o.name]), style: oaDisplay(22)),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(L('{0} öğe · {1}', [o.files.length, formatSize(o.total)]), style: oaBody(15, weight: FontWeight.w600)),
          SizedBox(height: 6),
          if (o.files.any((f) => f.isNotEmpty))
            Text(o.files.take(4).join(', ') + (o.files.length > 4 ? '…' : ''),
                maxLines: 3, overflow: TextOverflow.ellipsis, style: oaBody(14, color: OA.text2)),
          if (o.btId != null) ...[
            SizedBox(height: 8),
            OAChip(icon: Icons.bluetooth, label: L('Bluetooth ile bulundu · internetsiz')),
          ],
          SizedBox(height: 16),
          Text(L('Gönderenin ekranındaki kod bununla aynı mı?'), style: oaBody(14, color: OA.muted)),
          SizedBox(height: 6),
          Text(o.btId != null ? o.sas.split('').join(' ') : o.sas, style: oaDisplay(32).copyWith(letterSpacing: 2, color: o.btId != null ? OA.amber : null)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L('Reddet'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(L('Kabul et'))),
      ],
    ),
  );
  Kopru.i.answerOffer(o, r == true);
}

// ============================================================ telefonun dosyaları (bilgisayar)

class PhoneFilesDialog extends StatefulWidget {
  PhoneFilesDialog({super.key, required this.peer});
  final Peer peer;

  @override
  State<PhoneFilesDialog> createState() => _PhoneFilesDialogState();
}

class _PhoneFilesDialogState extends State<PhoneFilesDialog> {
  final k = Kopru.i;
  String _kind = 'img';
  final _items = <MediaItem>[];
  final _selected = <String>{};
  bool _loading = false;
  bool _end = false;
  String? _error;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) _load();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      _items.clear();
      _selected.clear();
      _end = false;
      _error = null;
    }
    if (_loading || _end) return;
    setState(() => _loading = true);
    final (items, err) = await k.phoneMedia(widget.peer, _kind, _items.length);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = err;
      _items.addAll(items);
      if (items.length < 60 || err != null) _end = true;
    });
  }

  Future<void> _pull() async {
    final list = _items.where((i) => _selected.contains(i.id)).toList();
    if (list.isEmpty) return;
    final ok = await k.pullFromPhone(widget.peer, list);
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      showSnack(context, L('{0} öğe geliyor · İndirilenler\\Pusula Köprü', [list.length]));
    } else {
      showSnack(context, L('{0} yanıt vermedi', [widget.peer.name]));
    }
  }

  String? get _errorText => switch (_error) {
        null => null,
        'izin' => L('Telefonda Pusula Köprü\'ye fotoğraf ve video erişim izni verilmemiş. Telefona bildirim gönderdik: uygulamayı açıp izin ver.'),
        'kapali' => L('Telefonda "Bilgisayar fotoğraflarıma göz atabilsin" kapalı (Pusula Köprü → Ayarlar).'),
        'yok' => L('Bu cihazda göz atılacak bir şey yok.'),
        _ => L('{0} yanıt vermedi. Bağlı mı?', [widget.peer.name]),
      };

  @override
  Widget build(BuildContext context) {
    final total = _items.where((i) => _selected.contains(i.id)).fold<int>(0, (a, i) => a + i.size);
    return AlertDialog(
      titlePadding: EdgeInsets.fromLTRB(24, 20, 16, 0),
      title: Row(children: [
        Expanded(child: Text(L('{0}: dosyalar', [widget.peer.name]), style: oaDisplay(22))),
        IconButton(onPressed: () => Navigator.pop(context), icon: Icon(Icons.close)),
      ]),
      content: SizedBox(
        width: 860,
        height: 560,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'img', label: Text(L('Fotoğraflar')), icon: Icon(Icons.image_outlined)),
              ButtonSegment(value: 'vid', label: Text(L('Videolar')), icon: Icon(Icons.movie_outlined)),
              ButtonSegment(value: 'dl', label: Text(L('İndirilenler')), icon: Icon(Icons.download_outlined)),
            ],
            selected: {_kind},
            onSelectionChanged: (v) {
              setState(() => _kind = v.first);
              _load(reset: true);
            },
          ),
          SizedBox(height: 12),
          if (_errorText != null && _items.isEmpty)
            Expanded(child: Center(child: Text(_errorText!, textAlign: TextAlign.center, style: oaBody(15, color: OA.text2, height: 1.5))))
          else if (_items.isEmpty && _loading)
            Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_items.isEmpty)
            Expanded(child: Center(child: Text(L('Burada bir şey yok.'), style: oaBody(15, color: OA.muted))))
          else
            Expanded(
              child: _kind == 'dl'
                  ? ListView.builder(
                      controller: _scroll,
                      itemCount: _items.length,
                      itemBuilder: (_, i) {
                        final it = _items[i];
                        final on = _selected.contains(it.id);
                        return CheckboxListTile(
                          value: on,
                          onChanged: (_) => setState(() => on ? _selected.remove(it.id) : _selected.add(it.id)),
                          secondary: Icon(fileIcon(it.name), color: OA.text2),
                          title: Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${formatSize(it.size)} · ${timeAgo(it.date)}', style: oaBody(13, color: OA.muted)),
                        );
                      },
                    )
                  : GridView.builder(
                      controller: _scroll,
                      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 140, mainAxisSpacing: 6, crossAxisSpacing: 6),
                      itemCount: _items.length,
                      itemBuilder: (_, i) {
                        final it = _items[i];
                        final on = _selected.contains(it.id);
                        return InkWell(
                          onTap: () => setState(() => on ? _selected.remove(it.id) : _selected.add(it.id)),
                          child: Stack(fit: StackFit.expand, children: [
                            ClipRRect(borderRadius: BorderRadius.circular(10), child: _Thumb(peer: widget.peer, item: it)),
                            if (_kind == 'vid')
                              Positioned(left: 6, bottom: 6, child: Icon(Icons.play_circle_fill, color: Colors.white, size: 22)),
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: on ? OA.amber : Colors.black38,
                                  border: Border.all(color: Colors.white, width: 1.5),
                                ),
                                child: on ? Icon(Icons.check, size: 16, color: OA.amberInk) : null,
                              ),
                            ),
                          ]),
                        );
                      },
                    ),
            ),
        ]),
      ),
      actions: [
        Text(_selected.isEmpty ? L('Seçmek için dokun') : L('{0} seçili · {1}', [_selected.length, formatSize(total)]),
            style: oaBody(14, color: OA.muted)),
        SizedBox(width: 12),
        FilledButton(onPressed: _selected.isEmpty ? null : _pull, child: Text(L('Bilgisayara al'))),
      ],
    );
  }
}

class _Thumb extends StatefulWidget {
  const _Thumb({required this.peer, required this.item});
  final Peer peer;
  final MediaItem item;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _b;

  @override
  void initState() {
    super.initState();
    _b = Kopru.i.cachedThumb(widget.peer, widget.item.id);
    if (_b == null) {
      Kopru.i.phoneThumb(widget.peer, widget.item.id).then((b) {
        if (mounted) setState(() => _b = b);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _b;
    if (b == null) return Container(color: OA.surface2);
    return Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

/// Bilgisayar: yedek klasörünü aç.
Future<void> openFolder(String path) async {
  if (!Platform.isWindows) return;
  final d = Directory(path);
  if (!d.existsSync()) d.createSync(recursive: true);
  await Process.run('explorer.exe', [path]);
}


// ============================================================ telefonu bul (bilgisayar)

Future<void> showLocateDialog(BuildContext context, Peer p) async {
  final future = Kopru.i.locatePhone(p);
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(L('Telefonu bul'), style: oaDisplay(22)),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<(Map<String, dynamic>?, String?)>(
          future: future,
          builder: (ctx, snap) {
            if (!snap.hasData) {
              return Row(children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 14),
                Expanded(child: Text(L('{0} konumunu buluyor…', [p.name]), style: oaBody(15, color: OA.text2))),
              ]);
            }
            final (loc, err) = snap.data!;
            if (loc == null) {
              return Text(
                switch (err) {
                  'izin' => L('Telefonda konum izni verilmemiş. Telefonda Pusula Köprü → Ayarlar → "Telefonu bul" ayarını aç ve izin ver.'),
                  'kapali' => L('Telefonda "Telefonu bul: bilgisayar konumumu görebilsin" kapalı (Pusula Köprü → Ayarlar).'),
                  'yok' => L('Konum alınamadı. Telefonda konum (GPS) kapalı olabilir.'),
                  _ => L('{0} yanıt vermedi. Bağlı mı?', [p.name]),
                },
                style: oaBody(15, color: OA.text2, height: 1.5),
              );
            }
            final lat = (loc['lat'] as num).toDouble(), lon = (loc['lon'] as num).toDouble();
            final acc = (loc['acc'] as num?)?.round();
            final at = DateTime.fromMillisecondsSinceEpoch((loc['time'] as num?)?.toInt() ?? 0);
            final url = 'https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=17/$lat/$lon';
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}', style: oaDisplay(22)),
              const SizedBox(height: 6),
              Text(
                [if (acc != null) L('±{0} m', [acc]), timeAgo(at), if (loc['fresh'] != true) L('son bilinen konum')].join(' · '),
                style: oaBody(14, color: OA.muted),
              ),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  onPressed: () => openLink(url),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(L('Haritada aç')),
                ),
                OutlinedButton.icon(
                  onPressed: () => Kopru.i.ring(p),
                  icon: const Icon(Icons.notifications_active_outlined, size: 18),
                  label: Text(L('Telefonu çaldır')),
                ),
              ]),
            ]);
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L('Kapat')))],
    ),
  );
}
