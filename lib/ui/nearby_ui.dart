import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/models.dart';
import '../core/node.dart';
import '../l10n.dart';
import '../theme.dart';
import 'extras.dart';
import 'widgets.dart';

// ============================================================ radar

class RadarBlip {
  RadarBlip({required this.id, required this.label, required this.sub, required this.bearing, required this.range, required this.onTap});
  final String id;
  final String label;
  final String sub;
  final double bearing; // derece, kuzeyden saat yönünde
  final double range; // 0..1
  final VoidCallback onTap;
}

/// Gemi radarı gibi dönen tarama. Işın bir cihazın üzerinden geçince cihaz parlar, sonra yavaşça söner.
class RadarView extends StatefulWidget {
  const RadarView({super.key, required this.blips, this.size = 320, this.scanning = true});
  final List<RadarBlip> blips;
  final double size;
  final bool scanning;

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView> with SingleTickerProviderStateMixin {
  static const period = Duration(seconds: 4);
  late final AnimationController _c = AnimationController(vsync: this, duration: period);

  @override
  void initState() {
    super.initState();
    if (widget.scanning) _c.repeat();
  }

  @override
  void didUpdateWidget(RadarView old) {
    super.didUpdateWidget(old);
    if (widget.scanning && !_c.isAnimating) _c.repeat();
    if (!widget.scanning && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Işın bu kerterizden ne kadar önce geçti (0 = şimdi, 1 = bir tur önce)
  double _age(double bearing, double sweep) {
    final d = (sweep - bearing) % 360;
    return (d < 0 ? d + 360 : d) / 360;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final r = s / 2 - 6;
    final reduce = MediaQuery.of(context).disableAnimations;
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final sweep = _c.value * 360;
          return Stack(clipBehavior: Clip.none, children: [
            Positioned.fill(child: CustomPaint(painter: _RadarPainter(sweep: reduce ? null : sweep))),
            for (final b in widget.blips) _blip(b, s, r, reduce ? 0.0 : _age(b.bearing, sweep)),
            Center(
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: OA.amber, borderRadius: BorderRadius.circular(10)),
                child: Text(L('SEN'), style: oaDisplay(11).copyWith(color: OA.amberInk)),
              ),
            ),
          ]);
        },
      ),
    );
  }

  Widget _blip(RadarBlip b, double s, double r, double age) {
    final a = b.bearing * math.pi / 180;
    final x = s / 2 + r * b.range * math.sin(a);
    final y = s / 2 - r * b.range * math.cos(a);
    // Işın geçince parlak, sonra %25'e kadar söner
    final glow = age < 0.08 ? 1.0 : math.max(0.25, 1 - (age - 0.08) * 1.1);
    final ping = age < 0.3 ? age / 0.3 : 1.0;
    final labelRight = x < s / 2 + 30;
    return Positioned(
      left: x - 22,
      top: y - 22,
      child: Semantics(
        button: true,
        label: L('{0}, {1}. Göndermek için dokun', [b.label, b.sub]),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: b.onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(clipBehavior: Clip.none, children: [
              if (ping < 1)
                Center(
                  child: Opacity(
                    opacity: (1 - ping) * 0.9,
                    child: Container(
                      width: 16 + 26 * ping,
                      height: 16 + 26 * ping,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: OA.amber, width: 1.5)),
                    ),
                  ),
                ),
              Center(
                child: Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: OA.amber.withValues(alpha: glow),
                    boxShadow: [BoxShadow(color: OA.amber.withValues(alpha: glow * 0.8), blurRadius: 14)],
                  ),
                ),
              ),
              Positioned(
                top: 32,
                left: labelRight ? 14 : null,
                right: labelRight ? null : 14,
                child: Opacity(
                  opacity: math.max(0.6, glow),
                  child: Column(
                    crossAxisAlignment: labelRight ? CrossAxisAlignment.start : CrossAxisAlignment.end,
                    children: [
                      Text(b.label, maxLines: 1, style: oaBody(12, weight: FontWeight.w600, color: const Color(0xFFF7D9A8))),
                      Text(b.sub, maxLines: 1, style: oaBody(11, color: const Color(0xFFC79A58))),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({required this.sweep});
  final double? sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 6;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF0B0E0F));
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = OA.amber.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    for (final f in [0.25, 0.5, 0.75]) {
      canvas.drawCircle(c, r * f, ring);
    }
    final cross = Paint()
      ..color = OA.amber.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), cross);
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), cross);
    // Kerteriz çentikleri ve dereceler
    for (var d = 0; d < 360; d += 5) {
      final a = d * math.pi / 180;
      final major = d % 30 == 0;
      final l = major ? 10.0 : 5.0;
      final p1 = Offset(c.dx + r * math.sin(a), c.dy - r * math.cos(a));
      final p2 = Offset(c.dx + (r - l) * math.sin(a), c.dy - (r - l) * math.cos(a));
      canvas.drawLine(
          p1,
          p2,
          Paint()
            ..color = OA.amber.withValues(alpha: major ? 0.7 : 0.35)
            ..strokeWidth = 1.2);
      if (major) {
        final tp = TextPainter(
          text: TextSpan(text: d.toString().padLeft(3, '0'), style: TextStyle(fontSize: 9, color: OA.amber.withValues(alpha: 0.55))),
          textDirection: TextDirection.ltr,
        )..layout();
        final rr = r - 22;
        tp.paint(canvas, Offset(c.dx + rr * math.sin(a) - tp.width / 2, c.dy - rr * math.cos(a) - tp.height / 2));
      }
    }
    // Dönen ışın ve arkasındaki iz
    final sw = sweep;
    if (sw != null) {
      final rect = Rect.fromCircle(center: c, radius: r);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.rotate((sw - 90) * math.pi / 180);
      canvas.translate(-c.dx, -c.dy);
      final grad = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi,
        colors: [
          OA.amber.withValues(alpha: 0),
          OA.amber.withValues(alpha: 0),
          OA.amber.withValues(alpha: 0.05),
          OA.amber.withValues(alpha: 0.38),
        ],
        stops: const [0, 0.79, 0.84, 1],
      );
      canvas.drawCircle(c, r, Paint()..shader = grad.createShader(rect));
      canvas.restore();
      final a = sw * math.pi / 180;
      canvas.drawLine(
          c,
          Offset(c.dx + r * math.sin(a), c.dy - r * math.cos(a)),
          Paint()
            ..color = OA.amber.withValues(alpha: 0.85)
            ..strokeWidth = 2);
    }
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = OA.amber.withValues(alpha: 0.5)
          ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.sweep != sweep;
}

// ============================================================ telefon: Gönder (Yakındakiler | Kodla)

class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key, this.initialTab = 0});
  final int initialTab;

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  final k = Kopru.i;
  late int _tab = widget.initialTab;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(k.bt.scan(true));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(k.bt.scan(false));
    super.dispose();
  }

  static double _hashBearing(String id) {
    var h = 7;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return (h % 360).toDouble();
  }

  Future<List<String>> _pick() async {
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    return r?.files.map((f) => f.path).whereType<String>().toList() ?? <String>[];
  }

  Future<void> _sendLan(NearbyDevice d) async {
    final paths = await _pick();
    if (paths.isEmpty || !mounted) return;
    await sendNearbyFlow(context, d, paths);
  }

  Future<void> _sendBt(BtDevice d) async {
    final paths = await _pick();
    if (paths.isEmpty || !mounted) return;
    await sendBtFlow(context, d, paths);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L('Gönder'), style: oaDisplay(22))),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: k,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              _tabs(),
              const SizedBox(height: 16),
              if (_tab == 0) ..._nearby() else ..._code(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabs() {
    Widget tab(int i, String label) => Expanded(
          child: Semantics(
            selected: _tab == i,
            button: true,
            child: TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 44),
                backgroundColor: _tab == i ? OA.amber : Colors.transparent,
                foregroundColor: _tab == i ? OA.amberInk : OA.text2,
                shape: const StadiumBorder(),
              ),
              onPressed: () => setState(() => _tab = i),
              child: Text(label, style: oaBody(15, weight: FontWeight.w600, color: _tab == i ? OA.amberInk : OA.text2)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: OA.surface, borderRadius: BorderRadius.circular(999), border: Border.all(color: OA.border)),
      child: Row(children: [tab(0, L('Yakındakiler')), const SizedBox(width: 4), tab(1, L('Kodla'))]),
    );
  }

  List<Widget> _nearby() {
    final lan = k.visible.values.where((d) => k.peerById(d.id) == null).toList();
    final bt = k.bt.devices.values.toList();
    final blips = <RadarBlip>[
      for (final d in lan)
        RadarBlip(id: d.id, label: d.name, sub: L('Aynı Wi-Fi'), bearing: _hashBearing(d.id), range: 0.45, onTap: () => _sendLan(d)),
      for (final d in bt)
        RadarBlip(id: d.id, label: d.name, sub: L('Bluetooth'), bearing: d.bearing, range: 0.68, onTap: () => _sendBt(d)),
    ];
    final n = blips.length;
    final left = k.visibleUntil?.difference(DateTime.now()).inSeconds ?? 0;
    final width = math.min(MediaQuery.of(context).size.width - 32, 360.0);
    return [
      Center(child: RadarView(blips: blips, size: width)),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: Text(n == 0 ? L('Yakındaki cihazlar aranıyor') : L('{0} cihaz bulundu', [n]), style: oaDisplay(20))),
        Text(L('Taranıyor…'), style: oaBody(13, color: OA.muted)),
      ]),
      const SizedBox(height: 4),
      Text(
        k.bt.supported
            ? L('Birine dokun, dosyalar gitsin. Wi-Fi ya da internet gerekmez; karşı tarafta "Görünür ol" açık olmalı.')
            : L('Bu telefonda Google Play hizmetleri olmadığı için yalnız aynı Wi-Fi\'deki cihazlar görünür.'),
        style: oaBody(13, color: OA.muted, height: 1.4),
      ),
      if (k.bt.supported && !k.bt.permission) ...[
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            if (await k.bt.ensurePermission()) await k.bt.scan(true);
          },
          icon: const Icon(Icons.bluetooth_searching, size: 18),
          label: Text(L('Yakındaki cihazlar iznini ver')),
        ),
      ],
      if (n > 0) ...[
        const SizedBox(height: 10),
        OACard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (final d in lan)
              ListTile(
                leading: IconBox(d.platform == 'android' ? Icons.smartphone_outlined : Icons.computer_outlined),
                title: Text(d.name, style: oaBody(15, weight: FontWeight.w600)),
                subtitle: Text(L('Aynı Wi-Fi'), style: oaBody(13, color: OA.muted)),
                trailing: const Icon(Icons.chevron_right, color: OA.muted),
                onTap: () => _sendLan(d),
              ),
            for (final d in bt)
              ListTile(
                leading: IconBox(Icons.smartphone_outlined),
                title: Text(d.name, style: oaBody(15, weight: FontWeight.w600)),
                subtitle: Text(L('Bluetooth · internetsiz'), style: oaBody(13, color: OA.muted)),
                trailing: const Icon(Icons.chevron_right, color: OA.muted),
                onTap: () => _sendBt(d),
              ),
          ]),
        ),
      ],
      const SizedBox(height: 14),
      OACard(
        highlight: k.isVisible,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(L('Görünür ol'), style: oaBody(15, weight: FontWeight.w600)),
              Text(
                k.isVisible
                    ? L('Yakındakiler seni "{0}" olarak görüyor · {1}:{2}', [k.myName, left ~/ 60, (left % 60).toString().padLeft(2, '0')])
                    : L('Sen de bulunabilirsin · 10 dk. Her gönderimi sen onaylarsın.'),
                style: oaBody(13, color: k.isVisible ? OA.green : OA.muted),
              ),
            ]),
          ),
          Switch(value: k.isVisible, onChanged: k.setVisible),
        ]),
      ),
    ];
  }

  List<Widget> _code() => [
        Text(L('İnternet üzerinden, eşleştirmeden gönder. Karşı taraf kodu yazar ya da QR\'ı okutur; dosyalar uçtan uca şifreli gider.'),
            style: oaBody(15, color: OA.text2, height: 1.5)),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 54)),
          onPressed: () async {
            final paths = await _pick();
            if (paths.isEmpty || !mounted) return;
            final s = k.sendWithCode(paths);
            if (!mounted) return;
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CodeSendScreen(session: s)));
          },
          icon: const Icon(Icons.upload_outlined),
          label: Text(L('Kodla gönder')),
        ),
        const SizedBox(height: 24),
        Text(L('Kodla al'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
        const SizedBox(height: 8),
        const CodeEntry(),
      ];
}

// ============================================================ kodla al: giriş

class CodeEntry extends StatefulWidget {
  const CodeEntry({super.key, this.inDialog = false});
  final bool inDialog;

  @override
  State<CodeEntry> createState() => _CodeEntryState();
}

class _CodeEntryState extends State<CodeEntry> {
  final _c = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _go([String? raw]) {
    final code = (raw ?? _c.text).replaceFirst(RegExp(r'^pusulakopru://kod/'), '');
    final r = Kopru.i.receiveWithCode(code);
    if (r == null) {
      setState(() => _err = L('Kod "7-ayva-kalem" gibi olmalı: sayı ve iki kelime.'));
      return;
    }
    setState(() => _err = null);
    if (widget.inDialog) {
      Navigator.pop(context);
      showDialog(context: context, barrierDismissible: false, builder: (_) => Dialog(child: SizedBox(width: 480, child: CodeReceiveView(session: r))));
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(), body: SafeArea(child: CodeReceiveView(session: r)))));
    }
  }

  Future<void> _scan() async {
    final v = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _CodeScanScreen()));
    if (v != null && mounted) {
      _c.text = v.replaceFirst('pusulakopru://kod/', '');
      _go(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      TextField(
        controller: _c,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _go(),
        style: oaDisplay(22),
        decoration: InputDecoration(
          labelText: L('Gönderenin ekranındaki kod'),
          hintText: '7-ayva-kalem',
          errorText: _err,
        ),
      ),
      const SizedBox(height: 10),
      Row(children: [
        if (Platform.isAndroid) ...[
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _scan,
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: Text(L('QR kodu okut')),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _go,
            child: Text(L('Bağlan')),
          ),
        ),
      ]),
    ]);
  }
}

class _CodeScanScreen extends StatefulWidget {
  const _CodeScanScreen();

  @override
  State<_CodeScanScreen> createState() => _CodeScanScreenState();
}

class _CodeScanScreenState extends State<_CodeScanScreen> {
  final _controller = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L('QR kodu okut'), style: oaDisplay(20))),
      body: MobileScanner(
        controller: _controller,
        onDetect: (c) {
          if (_done) return;
          final v = c.barcodes.map((b) => b.rawValue).whereType<String>().where((s) => s.startsWith('pusulakopru://kod/')).firstOrNull;
          if (v == null) return;
          _done = true;
          HapticFeedback.mediumImpact();
          Navigator.pop(context, v);
        },
      ),
    );
  }
}

// ============================================================ kodla gönder: ekran

class CodeSendScreen extends StatelessWidget {
  const CodeSendScreen({super.key, required this.session});
  final CodeSend session;

  @override
  Widget build(BuildContext context) => PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop && session.state == 'bekliyor') session.close();
        },
        child: Scaffold(appBar: AppBar(title: Text(L('Kodla gönder'), style: oaDisplay(20))), body: SafeArea(child: CodeSendView(session: session))),
      );
}

Future<void> showCodeSendDialog(BuildContext context, CodeSend s) => showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(child: SizedBox(width: 460, child: CodeSendView(session: s, inDialog: true))),
    );

class CodeSendView extends StatefulWidget {
  const CodeSendView({super.key, required this.session, this.inDialog = false});
  final CodeSend session;
  final bool inDialog;

  @override
  State<CodeSendView> createState() => _CodeSendViewState();
}

class _CodeSendViewState extends State<CodeSendView> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return ListenableBuilder(
      listenable: Listenable.merge([s, Kopru.i]),
      builder: (context, _) {
        final items = s.batch == null ? <ActiveTransfer>[] : Kopru.i.active.where((t) => t.batch == s.batch).toList();
        final total = items.fold<int>(0, (a, t) => a + t.size);
        final done = items.fold<int>(0, (a, t) => a + (t.state == 'done' ? t.size : t.done));
        final left = s.expires.difference(DateTime.now());
        final close = widget.inDialog
            ? TextButton(onPressed: () => Navigator.pop(context), child: Text(s.finished || s.state == 'gidiyor' ? L('Kapat') : L('İptal et')))
            : null;
        return ListView(shrinkWrap: true, padding: const EdgeInsets.all(20), children: [
          if (s.state == 'hazirlaniyor') ...[
            const SizedBox(height: 40),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Center(child: Text(L('Kod hazırlanıyor…'), style: oaBody(15, color: OA.text2))),
          ],
          if (s.state == 'bekliyor' || s.state == 'onay') ...[
            OACard(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Text(L('Alacak kişi bu kodu yazsın'), style: oaBody(14, color: OA.text2, weight: FontWeight.w600)),
                const SizedBox(height: 8),
                SelectableText(s.code, textAlign: TextAlign.center, style: oaDisplay(36).copyWith(color: OA.amber)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                  child: QrImageView(data: 'pusulakopru://kod/${s.code}', size: 170, backgroundColor: Colors.white),
                ),
                const SizedBox(height: 10),
                Text(
                  L('ya da Pusula Köprü\'deki "Kodla al" ile okutsun · {0}:{1}',
                      [left.inMinutes.clamp(0, 99), (left.inSeconds % 60).clamp(0, 59).toString().padLeft(2, '0')]),
                  textAlign: TextAlign.center,
                  style: oaBody(13, color: OA.muted),
                ),
              ]),
            ),
            const SizedBox(height: 14),
            OACard(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Expanded(child: Text(L('{0} dosya · {1}', [s.files.length, formatSize(s.total)]), style: oaBody(15, weight: FontWeight.w600))),
                if (s.state == 'bekliyor') ...[
                  const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(L('Alıcı bekleniyor…'), style: oaBody(14, color: OA.text2)),
                ] else
                  Text(L('Alıcı onaylıyor…'), style: oaBody(14, color: OA.green)),
              ]),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: s.code));
                if (context.mounted) showSnack(context, L('Kod kopyalandı'));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(L('Kodu kopyala')),
            ),
          ],
          if (s.state == 'gidiyor' || s.state == 'bitti') ...[
            Text(s.state == 'bitti' ? L('Gönderildi') : L('{0} cihazına gönderiliyor', [s.peerName ?? L('Alıcı')]), style: oaDisplay(26)),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: total == 0 ? null : done / total, minHeight: 6, borderRadius: BorderRadius.circular(9)),
            const SizedBox(height: 10),
            Text(L('{0} / {1} dosya · {2} / {3}', [items.where((t) => t.state == 'done').length, items.length, formatSize(done), formatSize(total)]),
                style: oaBody(14, color: OA.text2)),
          ],
          if (s.state == 'hata') ...[
            Text(L('Gönderilemedi'), style: oaDisplay(26)),
            const SizedBox(height: 10),
            Text(s.error ?? '', style: oaBody(15, color: OA.danger, height: 1.5)),
          ],
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            OAChip(icon: Icons.public, label: L('İnternet üzerinden')),
            OAChip(icon: Icons.lock_outline, label: L('Uçtan uca şifreli')),
          ]),
          if (close != null) ...[const SizedBox(height: 10), Align(alignment: Alignment.centerRight, child: close)],
        ]);
      },
    );
  }

  @override
  void deactivate() {
    if (widget.inDialog && widget.session.state == 'bekliyor') widget.session.close();
    super.deactivate();
  }
}

// ============================================================ kodla al: ekran

class CodeReceiveView extends StatelessWidget {
  const CodeReceiveView({super.key, required this.session});
  final CodeReceive session;

  @override
  Widget build(BuildContext context) {
    final r = session;
    return ListenableBuilder(
      listenable: Listenable.merge([r, Kopru.i]),
      builder: (context, _) {
        final items = Kopru.i.active.where((t) => r.ids.contains(t.id)).toList();
        final done = items.fold<int>(0, (a, t) => a + (t.state == 'done' ? t.size : t.done));
        return ListView(shrinkWrap: true, padding: const EdgeInsets.all(20), children: [
          if (r.state == 'baglaniyor') ...[
            const SizedBox(height: 30),
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Center(child: Text(L('Gönderene bağlanıyor…'), style: oaBody(15, color: OA.text2))),
          ],
          if (r.state == 'teklif') ...[
            Text(r.senderName, style: oaDisplay(24)),
            const SizedBox(height: 4),
            Text(L('{0} dosya gönderiyor · {1}', [r.files.length, formatSize(r.total)]), style: oaBody(15, color: OA.text2)),
            const SizedBox(height: 14),
            OACard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(children: [
                for (final f in r.files.take(6))
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.insert_drive_file_outlined, color: OA.text2),
                    title: Text(f.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: oaBody(14, weight: FontWeight.w600)),
                    trailing: Text(formatSize(f.$2), style: oaBody(13, color: OA.muted)),
                  ),
                if (r.files.length > 6)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(L('ve {0} dosya daha', [r.files.length - 6]), style: oaBody(13, color: OA.muted)),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            Text(Platform.isWindows ? L('Gelenler İndirilenler\\Pusula Köprü klasörüne kaydedilir') : L('Gelenler İndirilenler / Pusula Köprü klasörüne kaydedilir'),
                style: oaBody(13, color: OA.muted)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                  onPressed: () {
                    r.reject();
                    Navigator.maybePop(context);
                  },
                  child: Text(L('Reddet')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                  onPressed: r.accept,
                  child: Text(L('Al')),
                ),
              ),
            ]),
          ],
          if (r.state == 'gidiyor' || r.state == 'bitti') ...[
            Text(r.state == 'bitti' ? L('Alındı') : L('{0} cihazından alınıyor', [r.senderName]), style: oaDisplay(26)),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: r.total == 0 ? null : (done / r.total).clamp(0, 1), minHeight: 6, borderRadius: BorderRadius.circular(9)),
            const SizedBox(height: 10),
            Text(L('{0} / {1} dosya · {2} / {3}', [r.got, r.files.length, formatSize(done), formatSize(r.total)]), style: oaBody(14, color: OA.text2)),
            if (r.failed > 0) ...[
              const SizedBox(height: 6),
              Text(L('{0} dosya alınamadı', [r.failed]), style: oaBody(14, color: OA.danger)),
            ],
          ],
          if (r.state == 'hata') ...[
            Text(L('Alınamadı'), style: oaDisplay(26)),
            const SizedBox(height: 10),
            Text(r.error ?? '', style: oaBody(15, color: OA.danger, height: 1.5)),
          ],
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            OAChip(icon: Icons.public, label: L('İnternet üzerinden')),
            OAChip(icon: Icons.lock_outline, label: L('Uçtan uca şifreli')),
          ]),
          if (r.state != 'teklif') ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () {
                  if (r.state == 'baglaniyor') r.close();
                  Navigator.maybePop(context);
                },
                child: Text(r.finished ? L('Kapat') : (r.state == 'gidiyor' ? L('Arka planda devam et') : L('İptal et'))),
              ),
            ),
          ],
        ]);
      },
    );
  }
}

// ============================================================ Bluetooth ile gönderim (gönderen)

Future<void> sendBtFlow(BuildContext context, BtDevice d, List<String> paths) async {
  final s = Kopru.i.bt.send(d, paths);
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([s, Kopru.i]),
      builder: (ctx, _) {
        final items = s.transfers.values.toList();
        final total = items.fold<int>(0, (a, t) => a + t.size);
        final done = items.fold<int>(0, (a, t) => a + (t.state == 'done' ? t.size : t.done));
        final speed = items.where((t) => !t.finished).fold<double>(0, (a, t) => a + t.speed);
        return AlertDialog(
          title: Text(
            switch (s.state) {
              'baglaniyor' => L('{0} ile bağlanıyor', [d.name]),
              'onay' => L('{0} onaylasın', [d.name]),
              'gidiyor' => L('{0} cihazına gönderiliyor', [d.name]),
              'bitti' => L('Gönderildi'),
              _ => L('Gönderilemedi'),
            },
            style: oaDisplay(22),
          ),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (s.state == 'baglaniyor') const LinearProgressIndicator(),
              if (s.state == 'onay') ...[
                Text(L('Karşı ekranda "Kabul et"e basılmasını bekliyoruz. Bu kod iki ekranda da aynı olmalı:'),
                    style: oaBody(15, color: OA.text2, height: 1.5)),
                const SizedBox(height: 12),
                Center(child: Text((s.digits ?? '····').split('').join(' '), style: oaDisplay(36).copyWith(color: OA.amber, letterSpacing: 4))),
              ],
              if (s.state == 'gidiyor' || s.state == 'bitti') ...[
                LinearProgressIndicator(value: total == 0 ? null : done / total, minHeight: 6, borderRadius: BorderRadius.circular(9)),
                const SizedBox(height: 10),
                Text(
                    L('{0} / {1} dosya · {2} / {3}', [items.where((t) => t.state == 'done').length, items.length, formatSize(done), formatSize(total)]) +
                        (speed > 0 && s.state == 'gidiyor' ? ' · ${formatSize(speed.round())}/sn' : ''),
                    style: oaBody(14, color: OA.text2)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OAChip(icon: Icons.wifi_tethering, label: L('Doğrudan Wi-Fi · internetsiz')),
                  OAChip(icon: Icons.lock_outline, label: L('Şifreli')),
                ]),
                const SizedBox(height: 8),
                Text(L('Mobil veri harcamaz. Telefonları yakın tut.'), style: oaBody(13, color: OA.muted)),
              ],
              if (s.state == 'hata') Text(s.error ?? '', style: oaBody(15, color: OA.danger)),
            ]),
          ),
          actions: [
            if (!s.finished) TextButton(onPressed: s.cancel, child: Text(L('İptal et'))),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s.finished ? L('Tamam') : L('Arka planda devam et')),
            ),
          ],
        );
      },
    ),
  );
}
