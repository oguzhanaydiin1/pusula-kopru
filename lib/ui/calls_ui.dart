// GEÇİCİ: telefonun arama kayıtlarını bilgisayardan görme ve silme. İş bitince bu dosya ve
// CallLogAccess.kt kaldırılacak.
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/node.dart';
import '../l10n.dart';
import '../theme.dart';
import 'widgets.dart';

Future<void> showCallsDialog(BuildContext context, Peer p) =>
    showDialog(context: context, builder: (_) => Dialog(child: SizedBox(width: 760, height: 640, child: _CallsView(peer: p))));

class _CallsView extends StatefulWidget {
  const _CallsView({required this.peer});
  final Peer peer;

  @override
  State<_CallsView> createState() => _CallsViewState();
}

class _CallsViewState extends State<_CallsView> {
  List<Map<String, dynamic>>? _items;
  String? _err;
  bool _busy = false;
  String _q = '';
  final _sel = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final (items, err) = await Kopru.i.phoneCalls(widget.peer);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _items = items;
      _err = err;
      _sel.removeWhere((id) => !(items ?? const []).any((e) => e['id'] == id));
    });
  }

  String _errText(String e) => switch (e) {
        'izin' => L('Telefonda arama kayıtları izni verilmemiş. Telefona bak: izin penceresi açıldıysa "İzin ver" de, sonra "Yenile"ye bas. Pencere açılmadıysa telefonda Pusula Köprü\'yü açık tut ve yeniden dene.'),
        'yok' => L('Bu telefondaki Pusula Köprü arama kayıtlarını desteklemiyor. Arama kayıtları için hazırlanan özel APK kurulu olmalı.'),
        'baglanti' => L('{0} yanıt vermedi. Bağlı mı?', [widget.peer.name]),
        _ => L('Arama kayıtları okunamadı.'),
      };

  List<Map<String, dynamic>> get _shown {
    final all = _items ?? const <Map<String, dynamic>>[];
    if (_q.isEmpty) return all;
    final q = _q.toLowerCase();
    return all.where((e) => '${e['name']} ${e['n']}'.toLowerCase().contains(q)).toList();
  }

  static (IconData, Color, String) _type(int t) => switch (t) {
        1 => (Icons.call_received, OA.green, L('Gelen')),
        2 => (Icons.call_made, OA.blue, L('Giden')),
        3 => (Icons.call_missed, OA.danger, L('Cevapsız')),
        5 => (Icons.call_end, OA.muted, L('Reddedilen')),
        6 => (Icons.block, OA.muted, L('Engellenen')),
        _ => (Icons.call, OA.muted, L('Arama')),
      };

  static String _dur(int s) => s <= 0 ? '' : (s < 60 ? '${s}sn' : '${s ~/ 60}dk ${s % 60}sn');

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title, style: oaDisplay(22)),
          content: SizedBox(width: 420, child: Text(body, style: oaBody(15, color: OA.text2, height: 1.5))),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L('Vazgeç'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: OA.danger, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(c, true),
              child: Text(L('Sil')),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _delete({required bool all}) async {
    final n = all ? (_items?.length ?? 0) : _sel.length;
    if (n == 0) return;
    final ok = await _confirm(
      all ? L('Bütün arama kayıtları silinsin mi?') : L('{0} arama kaydı silinsin mi?', [n]),
      L('Kayıtlar telefondaki arama geçmişinden kalıcı olarak silinir; geri alınamaz.'),
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    final (deleted, err) = await Kopru.i.deletePhoneCalls(widget.peer, ids: all ? const [] : _sel.toList(), all: all);
    if (!mounted) return;
    if (err != null) {
      setState(() => _busy = false);
      showSnack(context, err == 'izin' ? L('Telefonda izin verilmemiş') : L('Silinemedi'));
      return;
    }
    _sel.clear();
    showSnack(context, L('{0} kayıt silindi', [deleted]));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final allShownSelected = shown.isNotEmpty && shown.every((e) => _sel.contains(e['id']));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(L('{0} · arama kayıtları', [widget.peer.name]), style: oaDisplay(24))),
          IconButton(tooltip: L('Yenile'), onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh)),
          IconButton(tooltip: L('Kapat'), onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ]),
        const SizedBox(height: 12),
        if (_err != null)
          Expanded(child: Center(child: Text(_errText(_err!), textAlign: TextAlign.center, style: oaBody(15, color: OA.text2, height: 1.5))))
        else if (_items == null)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else ...[
          Row(children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: L('Ad ya da numara ara')),
              ),
            ),
            const SizedBox(width: 12),
            Text(L('{0} kayıt', [_items!.length]), style: oaBody(14, color: OA.muted)),
          ]),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: allShownSelected,
            onChanged: shown.isEmpty
                ? null
                : (v) => setState(() {
                      for (final e in shown) {
                        v == true ? _sel.add(e['id'] as int) : _sel.remove(e['id'] as int);
                      }
                    }),
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(_q.isEmpty ? L('Hepsini seç') : L('Bulunanların hepsini seç'), style: oaBody(14, weight: FontWeight.w600)),
            dense: true,
          ),
          Divider(height: 1, color: OA.line),
          Expanded(
            child: shown.isEmpty
                ? Center(child: Text(L('Kayıt yok'), style: oaBody(15, color: OA.muted)))
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (c, i) {
                      final e = shown[i];
                      final id = e['id'] as int;
                      final (icon, color, label) = _type((e['type'] as num?)?.toInt() ?? 0);
                      final name = (e['name'] ?? '').toString();
                      final number = (e['n'] ?? '').toString();
                      return CheckboxListTile(
                        value: _sel.contains(id),
                        onChanged: (v) => setState(() => v == true ? _sel.add(id) : _sel.remove(id)),
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        secondary: Icon(icon, color: color, size: 20, semanticLabel: label),
                        title: Text(name.isNotEmpty ? name : (number.isNotEmpty ? number : L('Gizli numara')),
                            style: oaBody(14, weight: FontWeight.w600)),
                        subtitle: Text(
                          [if (name.isNotEmpty && number.isNotEmpty) number, label, _date((e['d'] as num?)?.toInt() ?? 0), _dur((e['dur'] as num?)?.toInt() ?? 0)]
                              .where((x) => x.isNotEmpty)
                              .join(' · '),
                          style: oaBody(13, color: OA.muted),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            OutlinedButton.icon(
              onPressed: _busy || _items!.isEmpty ? null : () => _delete(all: true),
              style: OutlinedButton.styleFrom(foregroundColor: OA.danger),
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(L('Hepsini sil')),
            ),
            const Spacer(),
            if (_busy) const Padding(padding: EdgeInsets.only(right: 12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            FilledButton.icon(
              onPressed: _busy || _sel.isEmpty ? null : () => _delete(all: false),
              style: FilledButton.styleFrom(backgroundColor: OA.danger, foregroundColor: Colors.white),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: Text(L('Seçilenleri sil ({0})', [_sel.length])),
            ),
          ]),
        ],
      ]),
    );
  }
}
