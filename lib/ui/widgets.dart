import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import '../main.dart' show KopruApp;
import '../core/models.dart';
import '../core/native.dart';
import '../core/node.dart';
import '../theme.dart';

/// OA işareti + "Köprü" yazısı.
class OALogo extends StatelessWidget {
  OALogo({super.key, this.size = 20, this.showText = true});
  final double size;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: OA.text, borderRadius: BorderRadius.circular(9)),
        child: Text('OA', style: oaDisplay(13, color: OA.bg).copyWith(letterSpacing: -0.5)),
      ),
      if (showText) ...[
        SizedBox(width: 10),
        Text('Köprü', style: oaDisplay(size)),
      ],
    ]);
  }
}

class OACard extends StatelessWidget {
  OACard({super.key, required this.child, this.padding = const EdgeInsets.all(20), this.highlight = false, this.onTap});
  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool highlight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: OA.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: highlight ? OA.amber : OA.border),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap, child: box),
    );
  }
}

class IconBox extends StatelessWidget {
  IconBox(this.icon, {super.key, this.size = 44, this.color = OA.amber, this.radius = 14});
  final IconData icon;
  final double size;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: OA.surface2, borderRadius: BorderRadius.circular(radius)),
        child: Icon(icon, size: size * 0.5, color: color),
      );
}

class OAChip extends StatelessWidget {
  OAChip({super.key, required this.label, this.dot, this.icon});
  final String label;
  final Color? dot;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        height: 30,
        padding: EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: OA.surface2,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: OA.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot != null) ...[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
            SizedBox(width: 8),
          ],
          if (icon != null) ...[Icon(icon, size: 15, color: OA.text2), SizedBox(width: 6)],
          Text(label, style: oaBody(13, color: OA.text2, weight: FontWeight.w600)),
        ]),
      );
}

IconData peerIcon(Peer p) => p.isPhone ? Icons.smartphone_outlined : Icons.computer_outlined;

String peerStatus(Peer p) {
  if (p.online) return L('Bağlı');
  final s = p.lastSeen;
  return s == null ? L('Bağlı değil') : L('Son görülme: {0}', [timeAgo(s)]);
}

IconData fileIcon(String name) {
  if (isImageName(name)) return Icons.image_outlined;
  if (isVideoName(name)) return Icons.movie_outlined;
  final m = mimeFor(name);
  if (m.startsWith('audio/')) return Icons.music_note_outlined;
  if (m == 'application/pdf') return Icons.picture_as_pdf_outlined;
  return Icons.insert_drive_file_outlined;
}

/// Geçmişteki bir satır.
class HistoryTile extends StatelessWidget {
  HistoryTile(this.h, {super.key, this.compact = false});
  final HistoryItem h;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final icon = switch (h.kind) {
      'link' => Icons.link,
      'text' => Icons.notes_outlined,
      _ => fileIcon(h.name),
    };
    final direction = Kopru.i.isPhone
        ? (h.incoming ? L('Bilgisayardan') : L('Bilgisayara'))
        : (h.incoming ? L('Telefondan') : L('Telefona'));
    final what = switch (h.kind) {
      'link' => L('Bağlantı'),
      'text' => L('Metin'),
      _ => formatSize(h.size),
    };
    final meta = Kopru.i.isPhone
        ? '${direction} · ${what} · ${timeAgo(h.at)}${h.ok ? '' : L(' · gönderilemedi')}'
        : '${what} · ${timeAgo(h.at)}${h.ok ? '' : L(' · gönderilemedi')}';
    final canOpen = h.kind == 'file' && h.incoming && h.location != null;
    return InkWell(
      onTap: () async {
        if (canOpen) {
          await Kopru.i.openHistoryItem(h);
        } else if (h.kind == 'link') {
          await openLink(h.name);
        } else if (h.kind == 'text') {
          await copyText(context, h.name);
        }
      },
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 12 : 14),
        child: Row(children: [
          _thumb(h) ?? IconBox(icon, size: 40, color: h.ok ? OA.text2 : OA.danger, radius: 12),
          SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(h.kind == 'file' ? h.name : h.name.replaceAll('\n', ' '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: oaBody(15, weight: FontWeight.w600)),
              SizedBox(height: 2),
              Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: oaBody(13, color: OA.muted)),
            ]),
          ),
          if (!Kopru.i.isPhone) ...[
            SizedBox(width: 12),
            Text(direction, style: oaBody(13, color: OA.text2, weight: FontWeight.w600)),
          ],
        ]),
      ),
    );
  }
}

/// Fotoğraflar için küçük resim (dosya bu cihazdaysa).
Widget? _thumb(HistoryItem h) {
  final loc = h.location;
  if (h.kind != 'file' || loc == null || !isImageName(h.name) || loc.startsWith('content://')) return null;
  final f = File(loc);
  if (!f.existsSync()) return null;
  return ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Image.file(f, width: 40, height: 40, fit: BoxFit.cover, cacheWidth: 96, errorBuilder: (_, __, ___) => IconBox(Icons.image_outlined, size: 40, color: OA.text2, radius: 12)),
  );
}

Future<void> copyText(BuildContext context, String text) async {
  await ClipboardHelper.set(text);
  showSnack(context, L('Kopyalandı'));
}

class ClipboardHelper {
  static Future<void> set(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}

Future<void> openLink(String text, {bool pusula = false}) async {
  final url = linkUrl(text);
  if (pusula && await Native.openInPusula(url)) return;
  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

void showSnack(BuildContext context, String text) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(text), duration: Duration(seconds: 3)));
}

/// Başlık + sağda isteğe bağlı bağlantı.
class SectionHeader extends StatelessWidget {
  SectionHeader(this.title, {super.key, this.action, this.onAction, this.size = 20});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final double size;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: Text(title, style: oaDisplay(size))),
        if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
      ]);
}

/// Koyu kutuda metin önizlemesi.
class TextPreview extends StatelessWidget {
  TextPreview({super.key, required this.label, required this.text, this.maxLines = 3});
  final String label;
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: OA.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: OA.border2),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: oaBody(13, color: OA.muted)),
          SizedBox(height: 6),
          SelectableText(text, maxLines: maxLines, style: oaBody(15)),
        ]),
      );
}


/// Dil seçimi (Ayarlar): Sistem / Türkçe / English
class LanguagePicker extends StatelessWidget {
  const LanguagePicker({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: Text(Lang.en ? 'Language' : 'Dil', style: oaBody(15, weight: FontWeight.w600))),
      DropdownButton<String>(
        value: Lang.setting,
        dropdownColor: OA.surface2,
        underline: const SizedBox.shrink(),
        items: [
          DropdownMenuItem(value: 'auto', child: Text(Lang.en ? 'System language' : 'Sistem dili')),
          const DropdownMenuItem(value: 'tr', child: Text('Türkçe')),
          const DropdownMenuItem(value: 'en', child: Text('English')),
        ],
        onChanged: (v) {
          if (v != null) KopruApp.setLang(context, v);
        },
      ),
    ]);
  }
}
