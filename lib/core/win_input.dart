import 'dart:ffi';
import 'dart:io';

/// Windows'ta fare ve klavye (telefondan dokunmatik yüzey, klavye, sunum ve medya kumandası).
/// user32.dll'in mouse_event / keybd_event işlevleri; ek paket gerektirmez.
class WinInput {
  WinInput._();

  static DynamicLibrary? _lib;
  static void Function(int, int, int, int, int)? _mouse;
  static void Function(int, int, int, int)? _key;

  static bool _load() {
    if (!Platform.isWindows) return false;
    if (_lib != null) return true;
    try {
      final l = DynamicLibrary.open('user32.dll');
      _mouse = l
          .lookupFunction<Void Function(Uint32, Int32, Int32, Int32, IntPtr), void Function(int, int, int, int, int)>(
              'mouse_event');
      _key = l.lookupFunction<Void Function(Uint8, Uint8, Uint32, IntPtr), void Function(int, int, int, int)>(
          'keybd_event');
      _lib = l;
      return true;
    } catch (_) {
      return false;
    }
  }

  static const _move = 0x0001, _leftDown = 0x0002, _leftUp = 0x0004, _rightDown = 0x0008, _rightUp = 0x0010;
  static const _wheel = 0x0800, _hwheel = 0x01000;
  static const _keyUp = 0x0002, _extended = 0x0001;

  /// Göreli fare hareketi (piksel).
  static void move(int dx, int dy) {
    if (!_load() || (dx == 0 && dy == 0)) return;
    _mouse!(_move, dx, dy, 0, 0);
  }

  static void click({bool right = false, bool double = false}) {
    if (!_load()) return;
    final times = double ? 2 : 1;
    for (var i = 0; i < times; i++) {
      _mouse!(right ? _rightDown : _leftDown, 0, 0, 0, 0);
      _mouse!(right ? _rightUp : _leftUp, 0, 0, 0, 0);
    }
  }

  /// Sürükleme için sol tuşu basılı tut / bırak.
  static void leftButton(bool down) {
    if (!_load()) return;
    _mouse!(down ? _leftDown : _leftUp, 0, 0, 0, 0);
  }

  /// Kaydırma: dy > 0 aşağı. 120 = bir tık.
  static void scroll(int dx, int dy) {
    if (!_load()) return;
    if (dy != 0) _mouse!(_wheel, 0, 0, -dy, 0);
    if (dx != 0) _mouse!(_hwheel, 0, 0, dx, 0);
  }

  static const _extendedKeys = {0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E, 0x5B};

  static void _press(int vk, bool up) {
    var flags = up ? _keyUp : 0;
    if (_extendedKeys.contains(vk)) flags |= _extended;
    _key!(vk, 0, flags, 0);
  }

  /// Tek tuş ya da kısayol (ör. [0x11, 0x56] = Ctrl+V).
  static void keys(List<int> vks) {
    if (!_load() || vks.isEmpty) return;
    for (final k in vks) {
      _press(k, false);
    }
    for (final k in vks.reversed) {
      _press(k, true);
    }
  }

  /// Telefondan gelen tuş adları → sanal tuş kodları
  static const named = <String, List<int>>{
    'enter': [0x0D],
    'backspace': [0x08],
    'tab': [0x09],
    'esc': [0x1B],
    'space': [0x20],
    'left': [0x25],
    'up': [0x26],
    'right': [0x27],
    'down': [0x28],
    'pageup': [0x21],
    'pagedown': [0x22],
    'home': [0x24],
    'end': [0x23],
    'delete': [0x2E],
    'f5': [0x74],
    'shiftf5': [0x10, 0x74],
    'win': [0x5B],
    'alttab': [0x12, 0x09],
    'copy': [0x11, 0x43],
    'paste': [0x11, 0x56],
    'undo': [0x11, 0x5A],
    'selectall': [0x11, 0x41],
    'desktop': [0x5B, 0x44],
    // medya
    'playpause': [0xB3],
    'next': [0xB0],
    'prev': [0xB1],
    'volup': [0xAF],
    'voldown': [0xAE],
    'mute': [0xAD],
    // sunum: siyah ekran (PowerPoint "B")
    'black': [0x42],
  };

  static bool key(String name, {int times = 1}) {
    final k = named[name];
    if (k == null || !_load()) return false;
    for (var i = 0; i < times; i++) {
      keys(k);
    }
    return true;
  }
}
