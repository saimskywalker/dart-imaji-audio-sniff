import 'bytes.dart';
import 'types.dart';

/// Reads a native FLAC stream whose `fLaC` marker sits at [start].
///
/// STREAMINFO must be the first metadata block (FLAC format specification,
/// section "METADATA_BLOCK_STREAMINFO"). A total-samples field of zero means
/// "unknown", so it produces no duration rather than a zero one.
AudioProbe parseFlac(ByteReader r, int start, Set<ProbeNote> notes) {
  final b = r.read(start, 42);
  if (b.length < 42 || (b[4] & 0x7F) != 0 || u24be(b, 5) < 34) {
    return AudioProbe(format: AudioFormat.flac, codec: 'flac', notes: notes);
  }
  const s = 8; // STREAMINFO body
  final sampleRate = (b[s + 10] << 12) | (b[s + 11] << 4) | (b[s + 12] >> 4);
  final channels = ((b[s + 12] >> 1) & 0x07) + 1;
  final bits = (((b[s + 12] & 0x01) << 4) | (b[s + 13] >> 4)) + 1;
  final totalSamples = (b[s + 13] & 0x0F) * 0x100000000 + u32be(b, s + 14);

  final duration = (sampleRate > 0 && totalSamples > 0)
      ? framesToDuration(totalSamples, sampleRate)
      : null;
  return AudioProbe(
    format: AudioFormat.flac,
    codec: 'flac',
    duration: duration,
    durationAccuracy: duration == null ? null : DurationAccuracy.exact,
    sampleRate: sampleRate > 0 ? sampleRate : null,
    channels: channels,
    bitsPerSample: bits,
    audioOffset: _firstFrameOffset(r, start),
    notes: notes,
  );
}

/// Offset just past the last metadata block, where the first audio frame
/// starts; null when the block chain cannot be followed.
int? _firstFrameOffset(ByteReader r, int start) {
  var pos = start + 4;
  for (var i = 0; i < 256; i++) {
    final h = r.read(pos, 4);
    if (h.length < 4) return null;
    pos += 4 + u24be(h, 1);
    if (h[0] & 0x80 != 0) return pos;
  }
  return null;
}

/// The total size of the ID3v2 tag at [at] in [b], or null when there is no
/// well-formed tag there (ID3v2.4 section 3.1; v2.2 and v2.3 share the
/// header layout).
int? id3v2Size(List<int> b, int at) {
  if (b.length < at + 10) return null;
  if (b[at] != 0x49 || b[at + 1] != 0x44 || b[at + 2] != 0x33) return null;
  final major = b[at + 3];
  if (major < 2 || major > 4 || b[at + 4] == 0xFF) return null;
  for (var i = at + 6; i < at + 10; i++) {
    if (b[i] & 0x80 != 0) return null;
  }
  final body =
      (b[at + 6] << 21) | (b[at + 7] << 14) | (b[at + 8] << 7) | b[at + 9];
  final footer = (major == 4 && (b[at + 5] & 0x10) != 0) ? 10 : 0;
  return 10 + body + footer;
}
