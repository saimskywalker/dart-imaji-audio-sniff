// Byte-level builders for synthetic test files. Every fixture in this
// package is generated here, byte by byte; no recorded audio is used.

import 'dart:typed_data';

/// An append-only byte buffer with endian-aware writers.
class Bytes {
  final List<int> _b = [];

  int get length => _b.length;

  void ascii(String s) => _b.addAll(s.codeUnits);
  void add(List<int> bytes) => _b.addAll(bytes);
  void byte(int v) => _b.add(v & 0xFF);
  void zeros(int n) => _b.addAll(List.filled(n, 0));

  void u16le(int v) => _b.addAll([v & 0xFF, (v >> 8) & 0xFF]);
  void u32le(int v) => _b.addAll(_le(BigInt.from(v), 4));
  void u64le(int v) => _b.addAll(_le(BigInt.from(v), 8));
  void u16be(int v) => _b.addAll([(v >> 8) & 0xFF, v & 0xFF]);
  void u24be(int v) => _b.addAll([(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  void u32be(int v) => _b.addAll(_le(BigInt.from(v), 4).reversed);
  void u64be(int v) => _b.addAll(_le(BigInt.from(v), 8).reversed);

  /// An 80-bit IEEE 754 extended float holding the integer [v] (AIFF rate).
  void ext80(int v) {
    final n = BigInt.from(v);
    final bits = n.bitLength;
    final mantissa = n << (64 - bits);
    u16be(16383 + bits - 1);
    _b.addAll(_le(mantissa, 8).reversed);
  }

  Uint8List get bytes => Uint8List.fromList(_b);

  static List<int> _le(BigInt v, int width) {
    final mask = BigInt.from(0xFF);
    return [for (var i = 0; i < width; i++) ((v >> (8 * i)) & mask).toInt()];
  }
}

Uint8List concat(List<List<int>> parts) {
  final out = Bytes();
  for (final p in parts) {
    out.add(p);
  }
  return out.bytes;
}

/// Deterministic noise. Deliberately rich in 0xFF so that a sloppy MPEG
/// sync check would fire on it.
Uint8List noise(int n, {int seed = 1}) {
  final out = Uint8List(n);
  var x = seed * 2654435761 % 4294967296;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) % 2147483648;
    final v = (x >> 16) & 0xFF;
    out[i] = (i % 7 == 0) ? 0xFF : v;
  }
  return out;
}

// ---------------------------------------------------------------- RIFF / WAV

/// A RIFF chunk. [declared] overrides the size field; [pad] controls the
/// pad byte after an odd-sized body.
Uint8List chunk(String id, List<int> body, {int? declared, bool pad = true}) {
  final b = Bytes()
    ..ascii(id)
    ..u32le(declared ?? body.length)
    ..add(body);
  if (pad && body.length.isOdd) b.byte(0);
  return b.bytes;
}

/// A `fmt ` body.
Uint8List fmtBody({
  int tag = 1,
  int channels = 2,
  int rate = 44100,
  int bits = 16,
  int? blockAlign,
  int? byteRate,
  bool extensible = false,
  int subFormat = 1,
  int? validBits,
  int? cbSize,
}) {
  final align = blockAlign ?? channels * ((bits + 7) ~/ 8);
  final b = Bytes()
    ..u16le(extensible ? 0xFFFE : tag)
    ..u16le(channels)
    ..u32le(rate)
    ..u32le(byteRate ?? rate * align)
    ..u16le(align)
    ..u16le(bits);
  if (extensible) {
    b
      ..u16le(22)
      ..u16le(validBits ?? bits)
      ..u32le(channels == 2 ? 3 : 0)
      ..u16le(subFormat)
      ..add([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA])
      ..add([0x00, 0x38, 0x9B, 0x71]);
  } else if (cbSize != null) {
    b.u16le(cbSize);
  }
  return b.bytes;
}

/// A whole WAV from [chunks]. [riffSize] overrides the RIFF size field.
Uint8List wavFile(List<List<int>> chunks,
    {String magic = 'RIFF', int? riffSize}) {
  final body = concat(chunks);
  return concat([
    (Bytes()
          ..ascii(magic)
          ..u32le(riffSize ?? body.length + 4)
          ..ascii('WAVE'))
        .bytes,
    body,
  ]);
}

/// A canonical 44-byte-header PCM WAV of [frames] frames.
Uint8List simpleWav({
  int frames = 44100,
  int channels = 2,
  int rate = 44100,
  int bits = 16,
}) {
  final align = channels * ((bits + 7) ~/ 8);
  return wavFile([
    chunk('fmt ', fmtBody(channels: channels, rate: rate, bits: bits)),
    chunk('data', noise(frames * align)),
  ]);
}

/// An RF64 `ds64` body.
Uint8List ds64Body({
  required int riffSize,
  required int dataSize,
  int sampleCount = 0,
  Map<String, int> table = const {},
}) {
  final b = Bytes()
    ..u64le(riffSize)
    ..u64le(dataSize)
    ..u64le(sampleCount)
    ..u32le(table.length);
  table.forEach((id, size) {
    b
      ..ascii(id)
      ..u64le(size);
  });
  return b.bytes;
}

// ---------------------------------------------------------------------- FLAC

/// A FLAC STREAMINFO metadata block (header included).
Uint8List streamInfo({
  int rate = 44100,
  int channels = 2,
  int bits = 16,
  int totalSamples = 44100,
  bool last = false,
}) {
  final b = Bytes()
    ..byte(last ? 0x80 : 0x00)
    ..u24be(34)
    ..u16be(4096)
    ..u16be(4096)
    ..u24be(0)
    ..u24be(0);
  final total = BigInt.from(totalSamples);
  // 20 bits rate, 3 bits channels-1, 5 bits bps-1, 36 bits total samples.
  final packed = (BigInt.from(rate) << 44) |
      (BigInt.from(channels - 1) << 41) |
      (BigInt.from(bits - 1) << 36) |
      total;
  final mask = BigInt.from(0xFF);
  for (var i = 7; i >= 0; i--) {
    b.byte(((packed >> (8 * i)) & mask).toInt());
  }
  b.zeros(16); // MD5
  return b.bytes;
}

/// Another metadata block of [type] with [body].
Uint8List flacBlock(int type, List<int> body, {bool last = false}) => concat([
      [(last ? 0x80 : 0) | type, ...(Bytes()..u24be(body.length)).bytes],
      body,
    ]);

/// A FLAC file: marker, STREAMINFO, optional blocks, then a fake frame.
Uint8List flacFile({
  int rate = 44100,
  int totalSamples = 44100,
  int channels = 2,
  int bits = 16,
  List<Uint8List> blocks = const [],
}) =>
    concat([
      'fLaC'.codeUnits,
      streamInfo(
        rate: rate,
        totalSamples: totalSamples,
        channels: channels,
        bits: bits,
        last: blocks.isEmpty,
      ),
      for (var i = 0; i < blocks.length; i++)
        i == blocks.length - 1
            ? (Uint8List.fromList(blocks[i])..[0] |= 0x80)
            : blocks[i],
      [0xFF, 0xF8, 0x69, 0x08],
      noise(256),
    ]);

// ----------------------------------------------------------------- ID3 / MP3

/// An ID3v2 tag whose body is [bodySize] bytes of padding.
Uint8List id3v2({int bodySize = 1024, int major = 3, bool footer = false}) {
  final b = Bytes()
    ..ascii('ID3')
    ..byte(major)
    ..byte(0)
    ..byte(footer ? 0x10 : 0)
    ..byte((bodySize >> 21) & 0x7F)
    ..byte((bodySize >> 14) & 0x7F)
    ..byte((bodySize >> 7) & 0x7F)
    ..byte(bodySize & 0x7F);
  // One TIT2 frame, then zero padding.
  final frame = Bytes()
    ..ascii('TIT2')
    ..u32be(6)
    ..u16be(0)
    ..byte(0)
    ..ascii('Take');
  final f = frame.bytes;
  b
    ..add(f.length <= bodySize ? f : f.sublist(0, bodySize))
    ..zeros(bodySize > f.length ? bodySize - f.length : 0);
  if (footer) {
    b
      ..ascii('3DI')
      ..add(b.bytes.sublist(3, 10));
  }
  return b.bytes;
}

const _kbpsV1 = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320
];
const _kbpsV2 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];

/// MPEG version: 1, 2 or 25 (2.5).
List<int> frameHeader({
  int version = 1,
  int kbps = 128,
  int rate = 44100,
  bool mono = false,
  bool crc = false,
  int padding = 0,
}) {
  final vbits = switch (version) { 1 => 3, 2 => 2, _ => 0 };
  final table = version == 1 ? _kbpsV1 : _kbpsV2;
  final bi = table.indexOf(kbps);
  final base = switch (version) { 1 => 1, 2 => 2, _ => 4 };
  final ri = [44100, 48000, 32000].indexOf(rate * base);
  if (bi <= 0 || ri < 0) throw ArgumentError('bad frame params');
  return [
    0xFF,
    0xE0 | (vbits << 3) | (1 << 1) | (crc ? 0 : 1),
    (bi << 4) | (ri << 2) | (padding << 1),
    (mono ? 0xC0 : 0x00),
  ];
}

int frameLength(
        {int version = 1, int kbps = 128, int rate = 44100, int padding = 0}) =>
    (version == 1 ? 144 : 72) * kbps * 1000 ~/ rate + padding;

/// A Layer III frame with an optional Xing/Info/VBRI tag in it.
Uint8List mp3Frame({
  int version = 1,
  int kbps = 128,
  int rate = 44100,
  bool mono = false,
  bool crc = false,
  String? tag, // 'Xing', 'Info' or 'VBRI'
  int tagFrames = 0,
  int xingFlags = 0x0F,
}) {
  final len = frameLength(version: version, kbps: kbps, rate: rate);
  final out = Uint8List(len);
  out.setAll(
      0,
      frameHeader(
          version: version, kbps: kbps, rate: rate, mono: mono, crc: crc));
  if (tag == 'Xing' || tag == 'Info') {
    final side = version == 1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    final at = 4 + side + (crc ? 2 : 0);
    final t = Bytes()
      ..ascii(tag!)
      ..u32be(xingFlags)
      ..u32be(tagFrames)
      ..u32be(len * (tagFrames + 1));
    out.setAll(at, t.bytes);
    // A LAME-style encoder string after the tag.
    out.setAll(at + 120, 'LAME3.100'.codeUnits);
  } else if (tag == 'VBRI') {
    final t = Bytes()
      ..ascii('VBRI')
      ..u16be(1)
      ..u16be(1105)
      ..u16be(75)
      ..u32be(len * (tagFrames + 1))
      ..u32be(tagFrames);
    out.setAll(36, t.bytes);
  } else {
    // Audio-ish payload.
    out.setAll(4, noise(len - 4).map((v) => v == 0xFF ? 0x7F : v));
  }
  return out;
}

/// [count] plain frames.
Uint8List mp3Frames(int count,
        {int version = 1,
        int kbps = 128,
        int rate = 44100,
        bool mono = false}) =>
    concat([
      for (var i = 0; i < count; i++)
        mp3Frame(version: version, kbps: kbps, rate: rate, mono: mono),
    ]);

/// A 128-byte ID3v1 tag.
Uint8List id3v1() => concat(['TAG'.codeUnits, List.filled(125, 0x20)]);

// ---------------------------------------------------------------------- AIFF

Uint8List ifChunk(String id, List<int> body, {bool pad = true}) {
  final b = Bytes()
    ..ascii(id)
    ..u32be(body.length)
    ..add(body);
  if (pad && body.length.isOdd) b.byte(0);
  return b.bytes;
}

Uint8List commBody({
  int channels = 2,
  int frames = 44100,
  int bits = 16,
  int rate = 44100,
  String? compression,
  String compressionName = '',
}) {
  final b = Bytes()
    ..u16be(channels)
    ..u32be(frames)
    ..u16be(bits)
    ..ext80(rate);
  if (compression != null) {
    b
      ..ascii(compression)
      ..byte(compressionName.length)
      ..ascii(compressionName);
    if ((compressionName.length + 1).isOdd) b.byte(0);
  }
  return b.bytes;
}

Uint8List ssndBody(int bytes, {int offset = 0}) => concat([
      (Bytes()
            ..u32be(offset)
            ..u32be(0))
          .bytes,
      List.filled(offset, 0),
      noise(bytes),
    ]);

Uint8List aiffFile(List<List<int>> chunks, {bool aifc = false}) {
  final body = concat(chunks);
  return concat([
    (Bytes()
          ..ascii('FORM')
          ..u32be(body.length + 4)
          ..ascii(aifc ? 'AIFC' : 'AIFF'))
        .bytes,
    body,
  ]);
}

// ----------------------------------------------------------------------- MP4

Uint8List box(String type, List<List<int>> children) {
  final body = concat(children);
  return concat([
    (Bytes()
          ..u32be(body.length + 8)
          ..ascii(type))
        .bytes,
    body,
  ]);
}

Uint8List ftyp(String major, [List<String> compatible = const ['isom']]) =>
    box('ftyp', [
      major.codeUnits,
      [0, 0, 2, 0],
      for (final c in compatible) c.codeUnits,
    ]);

Uint8List mvhd(
    {required int timescale, required int duration, int version = 0}) {
  final b = Bytes()
    ..byte(version)
    ..zeros(3);
  if (version == 1) {
    b
      ..u64be(0)
      ..u64be(0)
      ..u32be(timescale)
      ..u64be(duration);
  } else {
    b
      ..u32be(0)
      ..u32be(0)
      ..u32be(timescale)
      ..u32be(duration);
  }
  b
    ..u32be(0x00010000)
    ..u16be(0x0100)
    ..zeros(10)
    ..zeros(36)
    ..zeros(24)
    ..u32be(2);
  return box('mvhd', [b.bytes]);
}

/// A sound `trak` whose media header says [frames] samples at [rate].
Uint8List soundTrak(
    {String codec = 'mp4a',
    int rate = 44100,
    int channels = 2,
    int bits = 16,
    int frames = 0}) {
  final entry = Bytes()
    ..zeros(6)
    ..u16be(1)
    ..zeros(8)
    ..u16be(channels)
    ..u16be(bits)
    ..zeros(4)
    ..u32be(rate * 0x10000);
  final stsd = box('stsd', [
    [0, 0, 0, 0, 0, 0, 0, 1],
    box(codec, [
      entry.bytes,
      if (codec == 'alac')
        _alacCookie(rate: rate, channels: channels, bits: bits),
    ]),
  ]);
  final mdhd = Bytes()
    ..zeros(4)
    ..u32be(0)
    ..u32be(0)
    ..u32be(rate)
    ..u32be(frames)
    ..u16be(0x55C4) // 'und'
    ..u16be(0);
  final hdlr = box('hdlr', [
    [0, 0, 0, 0, 0, 0, 0, 0],
    'soun'.codeUnits,
    List.filled(12, 0),
    'SoundHandler\x00'.codeUnits,
  ]);
  return box('trak', [
    box('tkhd', [List.filled(84, 0)]),
    box('mdia', [
      box('mdhd', [mdhd.bytes]),
      hdlr,
      box('minf', [
        box('smhd', [List.filled(8, 0)]),
        box('stbl', [stsd]),
      ]),
    ]),
  ]);
}

/// The ALAC magic cookie that follows an `alac` sample entry.
Uint8List _alacCookie(
        {required int rate, required int channels, required int bits}) =>
    box('alac', [
      (Bytes()
            ..u32be(0)
            ..u32be(4096)
            ..byte(0)
            ..byte(bits)
            ..byte(40)
            ..byte(10)
            ..byte(14)
            ..byte(channels)
            ..u16be(255)
            ..u32be(0)
            ..u32be(0)
            ..u32be(rate))
          .bytes,
    ]);
