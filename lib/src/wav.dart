import 'dart:typed_data';

import 'bytes.dart';
import 'chunks.dart';
import 'types.dart';

const int _sizeUnset = 0xFFFFFFFF;

/// Reads a RIFF/WAVE, RF64 or BW64 file. The caller has checked the magic.
AudioProbe parseWav(ByteReader r) {
  final head = r.read(0, 12);
  final isRf64 = !hasTag(head, 0, 'RIFF');
  final notes = <ProbeNote>{};

  _Ds64? ds64;
  _Fmt? fmt;
  int? dataOffset;
  int? dataBytes;
  int? factFrames;
  var stoppedInData = false;

  final walker = ChunkWalker(
    r,
    12,
    bigEndian: false,
    resolveSize: isRf64 ? (id) => ds64?.sizeOf(id) ?? -1 : null,
  );

  for (var chunk = walker.next(); chunk != null; chunk = walker.next()) {
    switch (chunk.id) {
      case 'ds64':
        if (isRf64) {
          ds64 = _Ds64.parse(r, chunk);
          if (ds64 != null) notes.add(ProbeNote.rf64);
        }
      case 'fmt ':
        final size = chunk.size < 0 ? 0 : chunk.size;
        fmt = _Fmt.parse(r.read(chunk.bodyOffset, size < 64 ? size : 64));
        if (fmt == null) return const AudioProbe(format: AudioFormat.wav);
        if (fmt.extensible) notes.add(ProbeNote.extensibleFormat);
      case 'fact':
        final b = r.read(chunk.bodyOffset, 4);
        if (chunk.size >= 4 && b.length == 4) {
          final count = u32le(b, 0);
          factFrames =
              (count == _sizeUnset && isRf64) ? ds64?.sampleCount : count;
        }
      case 'data':
        dataOffset = chunk.bodyOffset;
        final resolved = _dataSize(r, walker, chunk, isRf64, notes);
        dataBytes = resolved.bytes;
        if (!resolved.walkable) {
          stoppedInData = true;
          walker.stop();
        }
    }
    final haveAll = fmt != null &&
        dataOffset != null &&
        (fmt.isConstantFrame || factFrames != null);
    if (haveAll) break;
  }
  if (walker.missingPad) notes.add(ProbeNote.missingPadByte);

  if (fmt == null) {
    return AudioProbe(format: AudioFormat.wav, notes: notes);
  }
  final base = AudioProbe(
    format: AudioFormat.wav,
    codec: fmt.codecName,
    sampleRate: fmt.sampleRate,
    channels: fmt.channels > 0 ? fmt.channels : null,
    bitsPerSample: fmt.isConstantFrame && fmt.bits > 0 ? fmt.bits : null,
    audioOffset: dataOffset,
    notes: notes,
  );
  if (dataOffset == null || dataBytes == null) return base;

  Duration? duration;
  var accuracy = DurationAccuracy.exact;
  if (fmt.isConstantFrame) {
    final align = fmt.blockAlign > 0
        ? fmt.blockAlign
        : fmt.channels * ((fmt.bits + 7) ~/ 8);
    if (align > 0) {
      duration = framesToDuration(dataBytes ~/ align, fmt.sampleRate);
    }
  } else {
    final frames = factFrames;
    final truncated = notes.contains(ProbeNote.truncated) || stoppedInData;
    if (frames != null && frames > 0 && !truncated) {
      duration = framesToDuration(frames, fmt.sampleRate);
    } else if (fmt.byteRate > 0) {
      duration = framesToDuration(dataBytes, fmt.byteRate);
      accuracy = DurationAccuracy.estimated;
    }
  }
  if (duration == null) return base;
  return AudioProbe(
    format: AudioFormat.wav,
    duration: duration,
    durationAccuracy: accuracy,
    codec: base.codec,
    sampleRate: base.sampleRate,
    channels: base.channels,
    bitsPerSample: base.bitsPerSample,
    audioOffset: dataOffset,
    notes: notes,
  );
}

/// The usable size of a `data` chunk, and whether the walk may continue
/// past it.
({int? bytes, bool walkable}) _dataSize(
  ByteReader r,
  ChunkWalker walker,
  Chunk chunk,
  bool isRf64,
  Set<ProbeNote> notes,
) {
  final length = r.length;
  final available = length == null
      ? null
      : (length - chunk.bodyOffset < 0 ? 0 : length - chunk.bodyOffset);
  final declared = chunk.size;

  // A streamed writer leaves the size unset (0 or 0xFFFFFFFF) and never comes
  // back to fill it in. Zero is also a genuinely empty file, which shows as a
  // valid chunk header (or the end of the file) right where the body starts.
  final emptyForReal = declared == 0 && walker.score(chunk.bodyOffset) >= 2;
  final unset = declared < 0 ||
      (!isRf64 && declared == _sizeUnset) ||
      (declared == 0 && !emptyForReal);
  if (unset) {
    notes.add(ProbeNote.unknownDataSize);
    return (bytes: available, walkable: false);
  }
  if (available != null && declared > available) {
    notes.add(ProbeNote.truncated);
    return (bytes: available, walkable: false);
  }
  return (bytes: declared, walkable: true);
}

/// The RF64 `ds64` chunk: 64-bit sizes for chunks whose 32-bit field says
/// 0xFFFFFFFF (EBU Tech 3306).
final class _Ds64 {
  _Ds64(this.dataSize, this.sampleCount, this.table);

  static _Ds64? parse(ByteReader r, Chunk chunk) {
    if (chunk.size < 24) return null;
    final b = r.read(chunk.bodyOffset, 28);
    if (b.length < 24) return null;
    final dataSize = u64le(b, 8);
    final sampleCount = u64le(b, 16);
    final table = <String, int>{};
    if (b.length >= 28) {
      var entries = u32le(b, 24);
      if (entries > 32) entries = 32;
      final t = r.read(chunk.bodyOffset + 28, entries * 12);
      for (var i = 0; i + 12 <= t.length; i += 12) {
        final id = fourCC(t, i);
        final size = u64le(t, i + 4);
        if (id != null && size >= 0) table[id] = size;
      }
    }
    return _Ds64(
      dataSize < 0 ? null : dataSize,
      sampleCount < 0 ? null : sampleCount,
      table,
    );
  }

  final int? dataSize;
  final int? sampleCount;
  final Map<String, int> table;

  int sizeOf(String id) => (id == 'data' ? dataSize : null) ?? table[id] ?? -1;
}

/// The fields of a `fmt ` chunk the duration needs.
final class _Fmt {
  _Fmt({
    required this.tag,
    required this.extensible,
    required this.channels,
    required this.sampleRate,
    required this.byteRate,
    required this.blockAlign,
    required this.bits,
  });

  /// Null when the chunk is shorter than the 16 bytes every `fmt ` carries,
  /// or its sample rate is zero.
  static _Fmt? parse(Uint8List b) {
    if (b.length < 16) return null;
    var tag = u16le(b, 0);
    var extensible = false;
    var bits = u16le(b, 14);
    if (tag == 0xFFFE) {
      // WAVE_FORMAT_EXTENSIBLE: the real format code is the first two bytes
      // of the SubFormat GUID at offset 24.
      if (b.length < 26) return null;
      extensible = true;
      tag = u16le(b, 24);
      final valid = u16le(b, 18);
      if (valid > 0 && valid <= bits) bits = valid;
    }
    final rate = u32le(b, 4);
    if (rate == 0) return null;
    return _Fmt(
      tag: tag,
      extensible: extensible,
      channels: u16le(b, 2),
      sampleRate: rate,
      byteRate: u32le(b, 8),
      blockAlign: u16le(b, 12),
      bits: bits,
    );
  }

  final int tag;
  final bool extensible;
  final int channels;
  final int sampleRate;
  final int byteRate;
  final int blockAlign;
  final int bits;

  /// Every frame the same size: PCM, IEEE float, A-law, mu-law.
  bool get isConstantFrame => tag == 1 || tag == 3 || tag == 6 || tag == 7;

  String get codecName => switch (tag) {
        1 => 'pcm',
        3 => 'float',
        6 => 'alaw',
        7 => 'mulaw',
        2 => 'adpcm-ms',
        0x11 => 'adpcm-ima',
        0x50 => 'mpeg',
        0x55 => 'mp3',
        _ => '0x${tag.toRadixString(16).padLeft(4, '0')}',
      };
}
