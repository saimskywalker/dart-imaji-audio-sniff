import 'dart:typed_data';

import 'bytes.dart';
import 'types.dart';

/// Layer III bitrates in kbit/s by bitrate index (ISO/IEC 11172-3 and
/// 13818-3). Index 0 ("free format") and 15 (forbidden) are rejected.
const List<int> _kbpsV1 = [
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0, //
];
const List<int> _kbpsV2 = [
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0, //
];

/// One MPEG audio Layer III frame header.
final class FrameHeader {
  FrameHeader._(this.version, this.bitrateKbps, this.sampleRate, this.padding,
      this.mono, this.crc, this._rateIndex);

  /// Parses the four bytes at [at], or returns null unless every field holds
  /// a legal value. The sync word alone is not enough: raw PCM is full of
  /// 0xFF bytes, and only the reserved-value checks reject it.
  static FrameHeader? parse(Uint8List b, int at) {
    if (b.length < at + 4) return null;
    final b1 = b[at + 1], b2 = b[at + 2], b3 = b[at + 3];
    if (b[at] != 0xFF || (b1 & 0xE0) != 0xE0) return null;
    final versionBits = (b1 >> 3) & 0x03; // 00 = 2.5, 01 reserved, 10, 11
    if (versionBits == 0x01) return null;
    if (((b1 >> 1) & 0x03) != 0x01) return null; // Layer III only
    final bitrateIndex = b2 >> 4;
    final rateIndex = (b2 >> 2) & 0x03;
    if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;
    if ((b3 & 0x03) == 0x02) return null; // reserved emphasis
    final version = switch (versionBits) { 3 => 1, 2 => 2, _ => 25 };
    final kbps = (version == 1 ? _kbpsV1 : _kbpsV2)[bitrateIndex];
    const rates = [44100, 48000, 32000];
    final rate = rates[rateIndex] ~/
        (version == 1
            ? 1
            : version == 2
                ? 2
                : 4);
    return FrameHeader._(version, kbps, rate, (b2 >> 1) & 0x01,
        (b3 >> 6) == 0x03, (b1 & 0x01) == 0, rateIndex);
  }

  /// 1 for MPEG-1, 2 for MPEG-2, 25 for MPEG-2.5.
  final int version;

  /// Bitrate of this frame.
  final int bitrateKbps;

  /// Sample rate in Hz.
  final int sampleRate;

  /// 1 when the frame carries a padding slot.
  final int padding;

  /// Whether the channel mode is single channel.
  final bool mono;

  /// Whether a 16-bit CRC follows the header.
  final bool crc;

  final int _rateIndex;

  /// PCM samples per channel in one frame.
  int get samplesPerFrame => version == 1 ? 1152 : 576;

  /// Frame length in bytes, header included.
  int get length =>
      (version == 1 ? 144 : 72) * bitrateKbps * 1000 ~/ sampleRate + padding;

  /// Offset of the Xing/Info tag from the frame start: the header plus the
  /// side information.
  int get sideInfoEnd =>
      4 + (version == 1 ? (mono ? 17 : 32) : (mono ? 9 : 17));

  /// Whether [other] can belong to the same stream.
  bool sameStream(FrameHeader other) =>
      other.version == version && other._rateIndex == _rateIndex;
}

/// Looks for a Layer III stream at [start] and reads its duration, or
/// returns null when there is none.
///
/// Leading zero bytes are skipped. The first header must be followed by a
/// second, consistent one exactly one frame later, unless the bytes end
/// first. When [tagged] (an ID3v2 tag came first) and nothing sits right
/// after the tag, a bounded window is searched for a chain of three
/// consistent frames instead.
AudioProbe? parseMpeg(ByteReader r, int start, Set<ProbeNote> notes,
    {required bool tagged}) {
  final pos = _skipZeros(r, start);
  if (pos == null) return null;
  var found = -1;
  final first = r.read(pos, 4);
  final header = FrameHeader.parse(first, 0);
  if (header != null && _confirm(r, pos, header, 1, allowEnd: true)) {
    found = pos;
  } else if (tagged) {
    found = _search(r, pos);
  }
  if (found < 0) return null;
  return _describe(r, found, notes);
}

int? _skipZeros(ByteReader r, int start) {
  var pos = start;
  for (var round = 0; round < 4; round++) {
    final b = r.read(pos, 4096);
    if (b.isEmpty) return null;
    for (var i = 0; i < b.length; i++) {
      if (b[i] != 0) return pos + i;
    }
    pos += b.length;
  }
  return pos;
}

bool _confirm(ByteReader r, int pos, FrameHeader header, int more,
    {required bool allowEnd}) {
  var at = pos;
  var h = header;
  for (var i = 0; i < more; i++) {
    at += h.length;
    final b = r.read(at, 4);
    if (b.length < 4) return allowEnd;
    final next = FrameHeader.parse(b, 0);
    if (next == null || !h.sameStream(next)) return false;
    h = next;
  }
  return true;
}

int _search(ByteReader r, int start) {
  const window = 64 * 1024;
  final b = r.read(start, window);
  var candidates = 0;
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] != 0xFF) continue;
    final h = FrameHeader.parse(b, i);
    if (h == null) continue;
    if (++candidates > 256) return -1;
    if (_confirm(r, start + i, h, 2, allowEnd: false)) return start + i;
  }
  return -1;
}

AudioProbe _describe(ByteReader r, int pos, Set<ProbeNote> notes) {
  final b = r.read(pos, 64);
  final h = FrameHeader.parse(b, 0)!;
  final spf = h.samplesPerFrame;

  Duration? duration;
  var accuracy = DurationAccuracy.exact;

  // Xing / Info: right after the side information (and after the CRC when
  // the frame is protected).
  for (final off in [h.sideInfoEnd, if (h.crc) h.sideInfoEnd + 2]) {
    if (hasTag(b, off, 'Xing') || hasTag(b, off, 'Info')) {
      if (b.length >= off + 12 && (u32be(b, off + 4) & 0x01) != 0) {
        final frames = u32be(b, off + 8);
        if (frames > 0) duration = framesToDuration(frames * spf, h.sampleRate);
      }
      break;
    }
  }
  // VBRI (Fraunhofer): 32 bytes after the header, whatever the mode.
  if (duration == null && hasTag(b, 36, 'VBRI') && b.length >= 54) {
    final frames = u32be(b, 50);
    if (frames > 0) duration = framesToDuration(frames * spf, h.sampleRate);
  }
  if (duration == null) {
    final end = _audioEnd(r);
    if (end != null && end > pos) {
      duration = framesToDuration((end - pos) * 8, h.bitrateKbps * 1000);
      accuracy = DurationAccuracy.estimated;
    }
  }
  return AudioProbe(
    format: AudioFormat.mp3,
    codec: 'mp3',
    duration: duration,
    durationAccuracy: duration == null ? null : accuracy,
    sampleRate: h.sampleRate,
    channels: h.mono ? 1 : 2,
    audioOffset: pos,
    notes: notes,
  );
}

/// End of the audio: the file length minus a trailing ID3v1 tag and an
/// APEv2 tag, or null when the length is unknown.
int? _audioEnd(ByteReader r) {
  final length = r.length;
  if (length == null) return null;
  var end = length;
  if (end >= 128 && hasTag(r.read(end - 128, 3), 0, 'TAG')) end -= 128;
  if (end >= 32) {
    final footer = r.read(end - 32, 32);
    if (hasTag(footer, 0, 'APETAGEX') && footer.length == 32) {
      final size = u32le(footer, 12);
      final hasHeader = (footer[23] & 0x80) != 0;
      final total = size + (hasHeader ? 32 : 0);
      if (total <= end) end -= total;
    }
  }
  return end;
}
