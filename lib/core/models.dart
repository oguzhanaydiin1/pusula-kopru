import 'crypto.dart';

/// Eşleşmiş bir cihaz.
class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.platform,
    required this.key,
    required this.addrs,
    required this.port,
  });

  final String id;
  String name;
  String platform; // windows | android
  final PairKey key;
  List<String> addrs; // son çalışan önde
  int port;

  // Çalışırken
  DateTime? lastSeen;
  int? battery;
  bool charging = false;
  String? clip; // bu cihazın panosundan gelen son metin
  DateTime? clipAt;

  bool get isPhone => platform == 'android';
  bool get isComputer => platform == 'windows';

  bool get online => lastSeen != null && DateTime.now().difference(lastSeen!) < const Duration(seconds: 20);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'platform': platform,
        'key': b64u(key.bytes),
        'addrs': addrs,
        'port': port,
        if (lastSeen != null) 'seen': lastSeen!.millisecondsSinceEpoch,
      };

  static Peer fromJson(Map<String, dynamic> j) {
    final p = Peer(
      id: j['id'] as String,
      name: (j['name'] ?? 'Cihaz') as String,
      platform: (j['platform'] ?? '') as String,
      key: PairKey(unb64u(j['key'] as String)),
      addrs: ((j['addrs'] as List?) ?? const []).map((e) => e.toString()).toList(),
      port: (j['port'] as num?)?.toInt() ?? 47821,
    );
    final seen = (j['seen'] as num?)?.toInt();
    if (seen != null) p.lastSeen = DateTime.fromMillisecondsSinceEpoch(seen);
    return p;
  }

  /// Bağlı değilken "Son görülme" yazısı için.
  DateTime? get lastSeenStored => lastSeen;
}

/// Geçmişteki bir aktarım.
class HistoryItem {
  HistoryItem({
    required this.kind,
    required this.name,
    required this.incoming,
    required this.peerName,
    required this.at,
    this.size = 0,
    this.location,
    this.mime,
    this.ok = true,
  });

  final String kind; // file | text | link
  final String name; // dosya adı ya da metin
  final bool incoming;
  final String peerName;
  final DateTime at;
  final int size;
  final String? location; // Windows: dosya yolu, Android: content:// adresi
  final String? mime;
  final bool ok;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'name': name,
        'in': incoming,
        'peer': peerName,
        'at': at.millisecondsSinceEpoch,
        'size': size,
        if (location != null) 'loc': location,
        if (mime != null) 'mime': mime,
        'ok': ok,
      };

  static HistoryItem fromJson(Map<String, dynamic> j) => HistoryItem(
        kind: (j['kind'] ?? 'file') as String,
        name: (j['name'] ?? '') as String,
        incoming: j['in'] == true,
        peerName: (j['peer'] ?? '') as String,
        at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
        size: (j['size'] as num?)?.toInt() ?? 0,
        location: j['loc'] as String?,
        mime: j['mime'] as String?,
        ok: j['ok'] != false,
      );
}

/// Süren bir dosya aktarımı.
class ActiveTransfer {
  ActiveTransfer({
    required this.id,
    required this.name,
    required this.size,
    required this.incoming,
    required this.peerId,
    required this.batch,
  });

  final String id;
  final String name;
  final int size;
  final bool incoming;
  final String peerId;
  final String batch; // aynı anda gönderilen dosyalar
  int done = 0;
  String state = 'waiting'; // waiting | running | done | failed | cancelled
  double speed = 0; // bayt/sn
  void Function()? abort;
  bool cancelRequested = false;

  double get fraction => size <= 0 ? (state == 'done' ? 1 : 0) : (done / size).clamp(0, 1).toDouble();
  bool get finished => state == 'done' || state == 'failed' || state == 'cancelled';
}

/// Başka cihazdan gelen son metin ya da bağlantı.
class IncomingText {
  IncomingText(this.peerName, this.text, this.at, {this.fromClipboard = false});
  final String peerName;
  final String text;
  final DateTime at;
  final bool fromClipboard;
  bool get isLink => looksLikeLink(text);
}

bool looksLikeLink(String s) {
  final t = s.trim();
  if (t.contains(RegExp(r'\s'))) return false;
  return RegExp(r'^(https?://|www\.)[^\s]+$', caseSensitive: false).hasMatch(t);
}

String linkUrl(String s) {
  final t = s.trim();
  return t.toLowerCase().startsWith('www.') ? 'https://$t' : t;
}

/// Ekrandaki olaylar (arayüz bunlara bakıp bilgi gösterir).
class KopruEvent {
  KopruEvent(this.type, {this.peer, this.text});
  final String type; // paired | ring | ringStop | received | text | clipCopied | unpaired | error
  final Peer? peer;
  final String? text;
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${s.replaceAll('.', ',')} ${units[i]}';
}

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'az önce';
  if (d.inMinutes < 60) return '${d.inMinutes < 1 ? 1 : d.inMinutes} dk önce';
  if (d.inHours < 24) return '${d.inHours} sa önce';
  if (d.inDays == 1) return 'dün';
  if (d.inDays < 7) return '${d.inDays} gün önce';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}';
}

String mimeFor(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const m = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'heic': 'image/heic',
    'mp4': 'video/mp4',
    'mov': 'video/quicktime',
    'mkv': 'video/x-matroska',
    'mp3': 'audio/mpeg',
    'm4a': 'audio/mp4',
    'wav': 'audio/wav',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'zip': 'application/zip',
    'rar': 'application/vnd.rar',
    '7z': 'application/x-7z-compressed',
    'apk': 'application/vnd.android.package-archive',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  };
  return m[ext] ?? 'application/octet-stream';
}

bool isImageName(String name) => mimeFor(name).startsWith('image/');
bool isVideoName(String name) => mimeFor(name).startsWith('video/');
