import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n.dart';
import '../core/models.dart';
import '../core/node.dart';
import '../core/notifier.dart';
import '../theme.dart';
import '../updater.dart';
import 'extras.dart';
import 'widgets.dart';

/// Bilgisayar ana penceresi (taslaktaki "Bilgisayar — ana pencere").
class DesktopHome extends StatefulWidget {
  DesktopHome({super.key});

  @override
  State<DesktopHome> createState() => _DesktopHomeState();
}

class _DesktopHomeState extends State<DesktopHome> {
  final k = Kopru.i;
  StreamSubscription<KopruEvent>? _sub;
  bool _dragging = false;
  UpdateInfo? get _update => updateAvailable.value;
  double? _updateProgress;
  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    _sub = k.events.listen(_onEvent);
    updateAvailable.addListener(_onUpdate);
    Updater.check();
    // Uygulama günlerce açık kalabilir: 6 saatte bir yeni sürüme bak
    _updateTimer = Timer.periodic(Duration(hours: 6), (_) => Updater.check());
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    updateAvailable.removeListener(_onUpdate);
    _updateTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  void _onEvent(KopruEvent e) {
    if (!mounted) return;
    switch (e.type) {
      case 'paired':
        showSnack(context, L('{0} eşleşti', [e.peer?.name ?? L('Cihaz')]));
      case 'text':
        showSnack(context, L('{0}: yeni {1}', [e.peer?.name ?? L('Telefon'), looksLikeLink(e.text ?? '') ? L('bağlantı') : L('metin')]));
      case 'clipCopied':
        showSnack(context, L('Telefonun panosu kopyalandı, yapıştırabilirsin'));
      case 'received':
        showSnack(context, L('{0} geldi · İndirilenler\\Pusula Köprü', [e.text]));
      case 'unpaired':
        showSnack(context, L('{0} eşleşmeyi kaldırdı', [e.peer?.name ?? L('Cihaz')]));
      case 'error':
        showSnack(context, e.text ?? L('Bir sorun oldu'));
      case 'nearOffer':
        if (e.offer != null) {
          Notifier.showWindow?.call();
          showOfferDialog(context, e.offer!);
        }
    }
  }

  Future<void> _pickFiles() async {
    final p = k.selected;
    if (p == null) return;
    final r = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = r?.files.map((f) => f.path).whereType<String>().toList() ?? <String>[];
    if (paths.isNotEmpty) k.sendFiles(p, paths);
  }

  void _dropped(List<String> paths) {
    final p = k.selected;
    if (p == null) {
      showSnack(context, L('Önce bir telefon eşleştir'));
      return;
    }
    if (paths.isNotEmpty) k.sendFiles(p, paths);
  }

  Future<void> _pickFolder() async {
    final p = k.selected;
    if (p == null) return;
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: L('Gönderilecek klasör'));
    if (dir != null) k.sendFiles(p, [dir]);
  }

  Future<void> _sendText() async {
    final p = k.selected;
    if (p == null) return;
    final text = await showDialog<String>(context: context, builder: (_) => const _SendTextDialog());
    if (text == null || text.trim().isEmpty) return;
    final ok = await k.sendText(p, text);
    if (mounted) {
      showSnack(context, ok ? (p.online ? L('Gönderildi') : L('Gönderildi; {0} bağlanınca iletilecek', [p.name])) : L('{0} bağlı değil', [p.name]));
    }
  }

  Future<void> _ring(Peer p) async {
    final ok = await k.ring(p);
    if (!mounted) return;
    if (!ok) {
      showSnack(context, L('Telefona ulaşılamadı. Pusula Köprü telefonda açık mı?'));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L('Telefon çalıyor'), style: oaDisplay(22)),
        content: Text(L('{0} sessizdeyse bile 30 saniye çalar.', [p.name]), style: oaBody(15, color: OA.text2)),
        actions: [
          FilledButton(
            onPressed: () {
              k.stopRemoteRing(p);
              Navigator.pop(ctx);
            },
            child: Text(L('Durdur')),
          ),
        ],
      ),
    );
  }

  Future<void> _nearbyDialog() => showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(L('Yakındakiler'), style: oaDisplay(24)),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(L('Eşleştirmeden, aynı Wi-Fi\'deki birine tek seferlik dosya gönder ya da al. ')
                    L('Karşı taraf her gönderimi onaylar; dosyalar şifreli gider.'),
                    style: oaBody(15, color: OA.text2, height: 1.5)),
                SizedBox(height: 16),
                NearbyPanel(),
              ]),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(L('Kapat')))],
        ),
      );

  Future<void> _pair() async {
    await showDialog(context: context, barrierDismissible: false, builder: (_) => PairDialog());
  }

  Future<void> _install() async {
    final u = _update;
    if (u == null) return;
    setState(() => _updateProgress = 0);
    final ok = await downloadAndInstall(u, (v) {
      if (mounted) setState(() => _updateProgress = v);
    });
    if (!mounted) return;
    if (ok) {
      exit(0);
    } else {
      setState(() => _updateProgress = null);
      showSnack(context, L('Güncelleme indirilemedi'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: k,
        builder: (context, _) {
          final sel = k.selected;
          return Column(children: [
            _header(sel),
            if (k.startError != null)
              Container(
                width: double.infinity,
                color: OA.surface2,
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                child: Text(k.startError!, style: oaBody(14, color: OA.danger)),
              ),
            Expanded(
              child: k.peers.isEmpty
                  ? _empty()
                  : LayoutBuilder(builder: (context, c) {
                      final narrow = c.maxWidth < 860;
                      final side = _sidebar(sel);
                      final main = _main(sel!);
                      return SingleChildScrollView(
                        padding: EdgeInsets.all(24),
                        child: narrow
                            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [side, SizedBox(height: 24), main])
                            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                SizedBox(width: 320, child: side),
                                SizedBox(width: 24),
                                Expanded(child: main),
                              ]),
                      );
                    }),
            ),
          ]);
        },
      ),
    );
  }

  Widget _header(Peer? sel) {
    final online = sel?.online == true;
    return Container(
      height: 64,
      padding: EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: OA.line))),
      child: Row(children: [
        OALogo(),
        Spacer(),
        if (_update != null) ...[
          _updateProgress == null
              ? FilledButton(onPressed: _install, child: Text(L('Güncelle: {0}', [_update!.version])))
              : SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(value: _updateProgress, minHeight: 6, borderRadius: BorderRadius.circular(9))),
          SizedBox(width: 12),
        ],
        if (sel != null)
          OAChip(
            label: online
                ? (k.viaRelay(sel) ? L('İnternet üzerinden · şifreli') : L('Aynı Wi-Fi · doğrudan bağlantı'))
                : L('{0} bağlı değil', [sel.name]),
            dot: online ? OA.green : OA.faint,
          ),
        SizedBox(width: 12),
        _RoundIconButton(
          icon: Icons.settings_outlined,
          tooltip: L('Ayarlar'),
          onPressed: () => showDialog(context: context, builder: (_) => SettingsDialog()),
        ),
      ]),
    );
  }

  Widget _empty() {
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconBox(Icons.smartphone_outlined, size: 72, radius: 22),
            SizedBox(height: 20),
            Text(L('Telefonunu bağla'), textAlign: TextAlign.center, style: oaDisplay(34)),
            SizedBox(height: 12),
            Text(
              L('Telefona Pusula Köprü\'yü kur, aynı Wi-Fi\'ye bağlan ve bilgisayardaki QR kodu okut. ')
              L('Sonra dosyalar, bağlantılar ve pano iki cihaz arasında doğrudan ve şifreli gider.'),
              textAlign: TextAlign.center,
              style: oaBody(17, color: OA.text2, height: 1.6),
            ),
            SizedBox(height: 28),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: Size(0, 54), padding: EdgeInsets.symmetric(horizontal: 28)),
              onPressed: _pair,
              icon: Icon(Icons.qr_code_2),
              label: Text(L('QR kodu göster'), style: oaBody(17, color: OA.amberInk, weight: FontWeight.w600)),
            ),
            SizedBox(height: 12),
            TextButton.icon(
              onPressed: _nearbyDialog,
              icon: Icon(Icons.wifi_tethering),
              label: Text(L('Eşleştirmeden yakındakine gönder ya da al')),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _sidebar(Peer? sel) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(L('Cihazlarım'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
      SizedBox(height: 12),
      for (final p in k.peers) ...[
        p.id == sel?.id ? _selectedCard(p) : _peerRow(p),
        SizedBox(height: 12),
      ],
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: Size(0, 54), foregroundColor: OA.text2),
        onPressed: _pair,
        icon: Icon(Icons.add, size: 20),
        label: Text(L('Yeni cihaz eşleştir')),
      ),
      SizedBox(height: 10),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: Size(0, 50), foregroundColor: k.isVisible ? OA.amber : OA.text2),
        onPressed: _nearbyDialog,
        icon: Icon(Icons.wifi_tethering, size: 20),
        label: Text(k.isVisible ? L('Yakındakilere görünürsün') : L('Yakındakiler')),
      ),
    ]);
  }

  Widget _peerMenu(Peer p) => PopupMenuButton<String>(
        tooltip: L('Seçenekler'),
        icon: Icon(Icons.more_horiz, color: OA.muted),
        color: OA.surface2,
        onSelected: (v) async {
          if (v == 'remove') {
            final yes = await confirmUnpair(context, p);
            if (yes) await k.unpair(p);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'remove', child: Text(L('Eşleşmeyi kaldır'), style: oaBody(15, color: OA.danger))),
        ],
      );

  Widget _selectedCard(Peer p) {
    return OACard(
      highlight: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          IconBox(peerIcon(p)),
          SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: oaDisplay(18)),
              SizedBox(height: 2),
              Text(peerStatus(p),
                  style: oaBody(13, color: p.online ? OA.green : OA.muted, weight: FontWeight.w600)),
            ]),
          ),
          _peerMenu(p),
        ]),
        SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (p.battery != null)
            OAChip(
              icon: p.charging ? Icons.battery_charging_full : Icons.battery_std_outlined,
              label: L('Pil %{0}{1}', [p.battery, p.charging ? L(' · şarjda') : '']),
            ),
          OAChip(label: p.isPhone ? 'Android' : 'Windows'),
        ]),
        if (p.isPhone) ...[
          SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _ring(p),
            icon: Icon(Icons.notifications_active_outlined, size: 18),
            label: Text(L('Telefonu çaldır')),
          ),
          SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => showDialog(context: context, builder: (_) => PhoneFilesDialog(peer: p)),
            icon: Icon(Icons.photo_library_outlined, size: 18),
            label: Text(L('Telefonun dosyaları')),
          ),
          if ((k.backupReceived[p.id] ?? 0) > 0) ...[
            SizedBox(height: 10),
            InkWell(
              onTap: () => openFolder(k.backupFolder(p)),
              child: Row(children: [
                Icon(Icons.backup_outlined, size: 16, color: OA.green),
                SizedBox(width: 8),
                Expanded(
                  child: Text(L('Fotoğraf yedeği: {0} öğe · klasörü aç', [k.backupReceived[p.id]]),
                      style: oaBody(13, color: OA.text2)),
                ),
              ]),
            ),
          ],
        ],
      ]),
    );
  }

  Widget _peerRow(Peer p) {
    return OACard(
      padding: EdgeInsets.fromLTRB(20, 12, 8, 12),
      onTap: () => k.selectedPeer = p,
      child: Row(children: [
        IconBox(peerIcon(p), color: OA.muted),
        SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: oaBody(15, weight: FontWeight.w600)),
            Text(peerStatus(p), style: oaBody(13, color: p.online ? OA.green : OA.muted)),
          ]),
        ),
        _peerMenu(p),
      ]),
    );
  }

  Widget _main(Peer sel) {
    final transfers = k.active.toList().reversed.take(6).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          _dropped(d.files.map((f) => f.path).toList());
        },
        child: AnimatedContainer(
          duration: Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          decoration: BoxDecoration(
            color: _dragging ? OA.surface2 : OA.bg2,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _dragging ? OA.amber : OA.border2, width: 2),
          ),
          child: Column(children: [
            IconBox(Icons.upload_outlined, size: 64, radius: 20),
            SizedBox(height: 16),
            Text(sel.isPhone ? L('Telefona göndermek için buraya bırak') : L('{0} cihazına göndermek için buraya bırak', [sel.name]),
                textAlign: TextAlign.center, style: oaDisplay(30)),
            SizedBox(height: 10),
            Text(
                k.viaRelay(sel)
                    ? L('Farklı ağdasınız: internet üzerinden, uçtan uca şifreli gider (dosya başına en fazla 100 MB).')
                    : L('Dosya, fotoğraf ya da klasör. Aynı Wi-Fi\'deyken doğrudan ve şifreli gider.'),
                textAlign: TextAlign.center, style: oaBody(17, color: OA.text2)),
            SizedBox(height: 20),
            Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 12, children: [
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: Size(0, 54), padding: EdgeInsets.symmetric(horizontal: 28)),
                onPressed: _pickFiles,
                child: Text(L('Dosya seç'), style: oaBody(17, color: OA.amberInk, weight: FontWeight.w600)),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: Size(0, 54), padding: EdgeInsets.symmetric(horizontal: 24)),
                onPressed: _pickFolder,
                child: Text(L('Klasör seç'), style: oaBody(17, weight: FontWeight.w600)),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: Size(0, 54), padding: EdgeInsets.symmetric(horizontal: 24)),
                onPressed: _sendText,
                child: Text(L('Metin ya da bağlantı gönder'), style: oaBody(17, weight: FontWeight.w600)),
              ),
            ]),
          ]),
        ),
      ),
      if (transfers.isNotEmpty) ...[
        SizedBox(height: 20),
        OACard(
          padding: EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(L('Aktarımlar'), style: oaDisplay(20)),
            SizedBox(height: 8),
            for (final t in transfers) TransferRow(t),
          ]),
        ),
      ],
      SizedBox(height: 20),
      LayoutBuilder(builder: (context, c) {
        final two = c.maxWidth >= 560;
        final a = _clipCard();
        final b = _incomingCard();
        return two
            ? IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: a),
                  SizedBox(width: 20),
                  Expanded(child: b),
                ]),
              )
            : Column(children: [a, SizedBox(height: 20), b]);
      }),
      if (sel.isPhone && k.phoneNotifs.any((n) => n.peerId == sel.id)) ...[
        SizedBox(height: 20),
        _notifCard(sel),
      ],
      SizedBox(height: 20),
      OACard(
        padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionHeader(L('Son aktarımlar'),
              action: k.history.isEmpty ? null : L('Tümü'),
              onAction: () => showDialog(context: context, builder: (_) => HistoryDialog())),
          if (k.history.isEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: 16, top: 4),
              child: Text(L('Henüz bir şey gönderilmedi.'), style: oaBody(15, color: OA.muted)),
            ),
          for (final h in k.history.take(5)) ...[
            Divider(),
            HistoryTile(h),
          ],
        ]),
      ),
    ]);
  }

  Widget _notifCard(Peer sel) {
    final list = k.phoneNotifs.where((n) => n.peerId == sel.id).take(6).toList();
    return OACard(
      padding: EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionHeader(L('Telefon bildirimleri'),
            action: list.isEmpty ? null : L('Temizle'),
            onAction: () {
              for (final n in list) {
                k.dismissNotif(n);
              }
            }),
        if (list.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              L('Telefona gelen WhatsApp, SMS ve diğer bildirimler burada görünür; yanıt verilebilenlere buradan yanıt yazabilirsin. ')
              L('Açmak için telefonda Pusula Köprü → Ayarlar → "Bildirimleri bilgisayara ilet".'),
              style: oaBody(15, color: OA.muted, height: 1.5),
            ),
          ),
        for (final n in list) ...[
          Divider(),
          NotifTile(n),
        ],
      ]),
    );
  }

  Widget _clipCard() {
    return OACard(
      padding: EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(L('Ortak pano'), style: oaDisplay(20))),
          Text(k.clipShare ? L('Açık') : L('Kapalı'), style: oaBody(13, color: OA.text2, weight: FontWeight.w600)),
          SizedBox(width: 6),
          Switch(value: k.clipShare, onChanged: (v) => k.setClipShare(v)),
        ]),
        SizedBox(height: 6),
        Text(
          k.clipShare
              ? L('Burada kopyaladığın, telefonda yapıştırılmaya hazır.')
              : L('Kapalıyken bilgisayarda kopyaladıkların telefona gitmez.'),
          style: oaBody(15, color: OA.muted),
        ),
        SizedBox(height: 14),
        if (k.clipHistory.isEmpty)
          Text(L('Bir şey kopyaladığında burada görünür.'), style: oaBody(14, color: OA.faint))
        else ...[
          Text(L('Geçmiş · tıkla, yeniden kopyala'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
          ClipHistoryList(max: 5),
        ],
      ]),
    );
  }

  Widget _incomingCard() {
    final inc = k.lastIncoming;
    return OACard(
      padding: EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(L('Telefondan gelen'), style: oaDisplay(20)),
        SizedBox(height: 14),
        if (inc == null)
          Text(L('Telefondan gönderilen metin ve bağlantılar burada görünür. "Panoyu gönder" ile gelenler doğrudan panoya kopyalanır.'),
              style: oaBody(15, color: OA.muted, height: 1.5))
        else ...[
          TextPreview(
            label: '${inc.isLink ? L('Bağlantı') : (inc.fromClipboard ? L('Pano · kopyalandı') : L('Metin'))} · ${timeAgo(inc.at)}',
            text: inc.text,
          ),
          SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (inc.isLink) FilledButton(onPressed: () => openLink(inc.text), child: Text(L('Aç'))),
            if (inc.isLink)
              OutlinedButton(onPressed: () => copyText(context, inc.text), child: Text(L('Kopyala')))
            else
              FilledButton(onPressed: () => copyText(context, inc.text), child: Text(L('Kopyala'))),
            OutlinedButton(onPressed: k.dismissIncoming, child: Text(L('Kapat'))),
          ]),
        ],
      ]),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onPressed, required this.tooltip});
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: Size(44, 44),
            maximumSize: Size(44, 44),
            padding: EdgeInsets.zero,
            shape: CircleBorder(),
          ),
          onPressed: onPressed,
          child: Icon(icon, size: 20),
        ),
      );
}

/// Süren bir aktarımın satırı.
class TransferRow extends StatelessWidget {
  TransferRow(this.t, {super.key});
  final ActiveTransfer t;

  @override
  Widget build(BuildContext context) {
    final state = switch (t.state) {
      'done' => t.incoming ? L('Geldi') : L('Gitti'),
      'failed' => L('Olmadı'),
      'cancelled' => L('İptal'),
      'waiting' => L('Sırada'),
      _ => '%${(t.fraction * 100).round()}',
    };
    final color = switch (t.state) {
      'done' => OA.green,
      'failed' || 'cancelled' => OA.danger,
      _ => OA.amber,
    };
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        IconBox(fileIcon(t.name), size: 44, color: OA.text2),
        SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(t.incoming ? Icons.south : Icons.north, size: 14, color: OA.muted),
              SizedBox(width: 4),
              Expanded(child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: oaBody(15, weight: FontWeight.w600))),
              SizedBox(width: 8),
              Text(state, style: oaBody(13, color: t.state == 'running' ? OA.muted : color, weight: FontWeight.w600)),
            ]),
            SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: t.state == 'waiting' ? 0 : t.fraction,
                minHeight: 6,
                color: color,
                backgroundColor: OA.surface2,
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _SendTextDialog extends StatefulWidget {
  const _SendTextDialog();

  @override
  State<_SendTextDialog> createState() => _SendTextDialogState();
}

class _SendTextDialogState extends State<_SendTextDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(L('Metin ya da bağlantı gönder'), style: oaDisplay(22)),
      content: SizedBox(
        width: 460,
        child: TextField(
          controller: _c,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          style: oaBody(15),
          decoration: InputDecoration(hintText: L('Yaz ya da yapıştır')),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(L('Vazgeç'))),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: Text(L('Gönder'))),
      ],
    );
  }
}

/// QR ve 6 haneli kod; telefon okutunca kendiliğinden kapanır.
class PairDialog extends StatefulWidget {
  PairDialog({super.key});

  @override
  State<PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<PairDialog> {
  final k = Kopru.i;
  String? _qr;
  StreamSubscription<KopruEvent>? _sub;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    k.openPairing().then((q) {
      if (mounted) setState(() => _qr = q);
    });
    _sub = k.events.listen((e) {
      if (e.type == 'paired' && mounted) Navigator.pop(context);
    });
    _tick = Timer.periodic(Duration(seconds: 1), (_) {
      if (!mounted) return;
      final s = k.pairSession;
      if (s == null || s.expired) {
        k.openPairing().then((q) {
          if (mounted) setState(() => _qr = q);
        });
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    k.closePairing();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = k.pairSession;
    final code = s?.code ?? '';
    final left = s == null ? 0 : s.expires.difference(DateTime.now()).inSeconds.clamp(0, 300);
    return AlertDialog(
      contentPadding: EdgeInsets.fromLTRB(28, 24, 28, 8),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(L('Telefonla eşleştir'), style: oaDisplay(28)),
          SizedBox(height: 8),
          Text(L('Telefonda Pusula Köprü\'yü aç ve bu kodu okut. İki cihaz aynı Wi-Fi\'de olmalı.'),
              style: oaBody(15, color: OA.text2, height: 1.5)),
          SizedBox(height: 20),
          Center(
            child: Container(
              padding: EdgeInsets.all(14),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
              child: _qr == null
                  ? SizedBox(width: 240, height: 240, child: Center(child: CircularProgressIndicator()))
                  : QrImageView(data: _qr!, size: 240, backgroundColor: Colors.white, padding: EdgeInsets.zero),
            ),
          ),
          SizedBox(height: 20),
          Text(L('Kamera yoksa telefonda "Kodla eşleştir"e bas ve şunu gir:'), style: oaBody(14, color: OA.muted)),
          SizedBox(height: 8),
          Row(children: [
            Text(code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code,
                style: oaDisplay(34).copyWith(letterSpacing: 2)),
            Spacer(),
            Text('${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: oaBody(13, color: OA.faint)),
          ]),
          SizedBox(height: 8),
          Text(L('Windows "erişime izin ver" diye sorarsa izin ver; yoksa telefon bilgisayarı göremez.'),
              style: oaBody(13, color: OA.faint, height: 1.4)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(L('Kapat')))],
    );
  }
}

Future<bool> confirmUnpair(BuildContext context, Peer p) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(L('Eşleşme kaldırılsın mı?'), style: oaDisplay(22)),
      content: Text(L('{0} ile artık dosya ve pano paylaşılmaz. Yeniden bağlamak için tekrar eşleştirmen gerekir.', [p.name]),
          style: oaBody(15, color: OA.text2, height: 1.5)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(L('Vazgeç'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: OA.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(L('Kaldır')),
        ),
      ],
    ),
  );
  return r == true;
}

class HistoryDialog extends StatelessWidget {
  HistoryDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text(L('Bütün aktarımlar'), style: oaDisplay(22))),
        TextButton(
          onPressed: () async {
            await Kopru.i.clearHistory();
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(L('Geçmişi temizle')),
        ),
      ]),
      content: SizedBox(
        width: 620,
        height: 480,
        child: ListenableBuilder(
          listenable: Kopru.i,
          builder: (_, __) => ListView.separated(
            itemCount: Kopru.i.history.length,
            separatorBuilder: (_, __) => Divider(),
            itemBuilder: (_, i) => HistoryTile(Kopru.i.history[i]),
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(L('Kapat')))],
    );
  }
}

class SettingsDialog extends StatefulWidget {
  SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final k = Kopru.i;
  late final _name = TextEditingController(text: k.myName);
  String? _folder;
  String? _updateText;

  @override
  void initState() {
    super.initState();
    k.downloadsFolder().then((f) {
      if (mounted) setState(() => _folder = f);
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(L('Ayarlar'), style: oaDisplay(24)),
      content: SizedBox(
        width: 460,
        child: ListenableBuilder(
          listenable: k,
          builder: (_, __) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const LanguagePicker(),
            const SizedBox(height: 12),
            Text(L('Bu bilgisayarın adı'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
            SizedBox(height: 8),
            TextField(
              controller: _name,
              style: oaBody(15),
              onSubmitted: k.setMyName,
              decoration: InputDecoration(hintText: L('Örn. Ev bilgisayarı')),
            ),
            SizedBox(height: 20),
            Row(children: [
              Expanded(child: Text(L('Panoyu telefonla paylaş'), style: oaBody(15, weight: FontWeight.w600))),
              Switch(value: k.clipShare, onChanged: k.setClipShare),
            ]),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(L('Farklı ağdayken de bağlan'), style: oaBody(15, weight: FontWeight.w600)),
                  Text(L('Telefon başka bir ağdayken (mobil veri, iş yeri) OA sunucusu üzerinden, uçtan uca şifreli.'),
                      style: oaBody(13, color: OA.muted)),
                ]),
              ),
              Switch(value: k.relayOn, onChanged: k.setRelay),
            ]),
            SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(L('Windows açılınca başlat'), style: oaBody(15, weight: FontWeight.w600)),
                  Text(L('Pencereyi kapatınca saat yanındaki simgeye iner, gelenleri almaya devam eder.'),
                      style: oaBody(13, color: OA.muted)),
                ]),
              ),
              Switch(value: k.autostart, onChanged: k.setAutostart),
            ]),
            SizedBox(height: 16),
            Text(L('Gelen dosyalar'), style: oaBody(13, color: OA.muted, weight: FontWeight.w600)),
            SizedBox(height: 6),
            Row(children: [
              Expanded(child: Text(_folder ?? '', style: oaBody(14, color: OA.text2))),
              TextButton(
                onPressed: _folder == null ? null : () => Process.run('explorer.exe', [_folder!]),
                child: Text(L('Klasörü aç')),
              ),
            ]),
            SizedBox(height: 16),
            Row(children: [
              Expanded(child: Text(L('Sürüm {0}', [appVersion == '0.0.0' ? L('geliştirme') : appVersion]), style: oaBody(14, color: OA.muted))),
              TextButton(
                onPressed: () async {
                  setState(() => _updateText = 'Denetleniyor…');
                  final u = await Updater.check();
                  if (!mounted) return;
                  if (u == null) {
                    setState(() => _updateText = L('Güncel'));
                  } else {
                    showSnack(context, L('Yeni sürüm {0} hazır: üst çubuktaki "Güncelle"ye bas', [u.version]));
                    Navigator.pop(context); // üst çubukta "Güncelle" düğmesi belirdi
                  }
                },
                child: Text(_updateText ?? L('Güncellemeleri denetle')),
              ),
            ]),
          ]),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () async {
            if (_name.text.trim() != k.myName) await k.setMyName(_name.text);
            if (context.mounted) Navigator.pop(context);
          },
          child: Text(L('Tamam')),
        ),
      ],
    );
  }
}


/// Telefondan gelen bir bildirim; yanıt verilebiliyorsa yanıt kutusu.
class NotifTile extends StatefulWidget {
  NotifTile(this.n, {super.key});
  final PhoneNotif n;

  @override
  State<NotifTile> createState() => _NotifTileState();
}

class _NotifTileState extends State<NotifTile> {
  final _c = TextEditingController();
  bool _open = false;
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _c.text.trim();
    if (t.isEmpty) return;
    setState(() => _busy = true);
    final ok = await Kopru.i.replyNotif(widget.n, t);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _open = false;
        _c.clear();
      }
    });
    showSnack(context, ok ? L('Yanıt gönderildi') : L('Yanıt gönderilemedi'));
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.n;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconBox(Icons.notifications_none, size: 40, color: OA.text2, radius: 12),
          SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${n.app} · ${timeAgo(n.at)}', style: oaBody(13, color: OA.muted)),
              if (n.title.isNotEmpty) Text(n.title, style: oaBody(15, weight: FontWeight.w600)),
              if (n.text.isNotEmpty)
                Text(n.text, maxLines: 4, overflow: TextOverflow.ellipsis, style: oaBody(15, color: OA.text2, height: 1.4)),
              if (n.replied != null) ...[
                SizedBox(height: 4),
                Text(L('Yanıtın: {0}', [n.replied]), style: oaBody(13, color: OA.green)),
              ],
            ]),
          ),
          if (n.canReply && !_open)
            TextButton(onPressed: () => setState(() => _open = true), child: Text(L('Yanıtla'))),
          IconButton(
            tooltip: L('Kaldır'),
            onPressed: () => Kopru.i.dismissNotif(n),
            icon: Icon(Icons.close, size: 18, color: OA.muted),
          ),
        ]),
        if (_open) ...[
          SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _c,
                autofocus: true,
                style: oaBody(15),
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(hintText: L('Yanıt yaz')),
              ),
            ),
            SizedBox(width: 8),
            FilledButton(onPressed: _busy ? null : _send, child: Text(L('Gönder'))),
          ]),
        ],
      ]),
    );
  }
}
