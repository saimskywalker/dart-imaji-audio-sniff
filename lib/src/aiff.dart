import 'dart:math' as math;
import 'dart:typed_data';

import 'bytes.dart';
import 'chunks.dart';
import 'types.dart';

/// AIFF-C compression types whose frames all have the same size, so the
/// sound data can be cross-checked against the declared frame count.
const Set<String> _uncompressed = {
  'NONE', 'twos', 'sowt', 'raw ', 'in24', 'in32', '42ni', '23ni', //
  'fl32', 'FL32', 'fl64', 'FL64',
};

/// Reads an AIFF or AIFF-C file. The caller has checked the magic.
///
/// The duration is `numSampleFrames / sampleRate` from the `COMM` chunk,
/// whose sample rate is an 80-bit IEEE 754 extended float.
AudioProbe parseAiff(ByteReader r) {
  final isAifc = hasTag(r.read(8, 4), 0, 'AIFC');
  final format = isAifc ? AudioFormat.aifc : AudioFormat.aiff;
  final notes = <ProbeNote>{};

  Uint8List? comm;
  Chunk? ssnd;
  final walker = ChunkWalker(r, 12, bigEndian: true);
  for (var c = walker.next(); c != null; c = walker.next()) {
    if (c.id == 'COMM') comm = r.read(c.bodyOffset, c.size < 22 ? c.size : 22);
    if (c.id == 'SSND') ssnd = c;
    if (comm != null && ssnd != null) break;
  }
  if (walker.missingPad) notes.add(ProbeNote.missingPadByte);
  if (comm == null || comm.length < 18) {
    return AudioProbe(format: format, notes: notes);
  }

  final channels = u16be(comm, 0);
  var frames = u32be(comm, 2);
  final bits = u16be(comm, 6);
  final rate = _extended(comm, 8);
  final compression = (isAifc && comm.length >= 22) ? fourCC(comm, 18) : null;
  final codec = switch (compression) {
    null || 'NONE' => 'pcm',
    final c => c.trim(),
  };

  int? audioOffset;
  final sound = ssnd;
  if (sound != null && sound.size >= 8) {
    final head = r.read(sound.bodyOffset, 8);
    if (head.length == 8) {
      audioOffset = sound.bodyOffset + 8 + u32be(head, 0);
      final frameBytes = channels * ((bits + 7) ~/ 8);
      final constant =
          compression == null || _uncompressed.contains(compression);
      if (constant && frameBytes > 0) {
        var present = sound.bodyOffset + sound.size;
        final length = r.length;
        if (length != null && length < present) present = length;
        final available = present - audioOffset;
        final framesPresent = available <= 0 ? 0 : available ~/ frameBytes;
        if (framesPresent < frames) {
          frames = framesPresent;
          notes.add(ProbeNote.truncated);
        }
      }
    }
  }

  final duration = rate == null ? null : framesToDurationAtRate(frames, rate);
  return AudioProbe(
    format: format,
    codec: codec,
    duration: duration,
    durationAccuracy: duration == null ? null : DurationAccuracy.exact,
    sampleRate: rate?.round(),
    channels: channels > 0 ? channels : null,
    bitsPerSample: bits > 0 ? bits : null,
    audioOffset: audioOffset,
    notes: notes,
  );
}

/// An 80-bit IEEE 754 extended-precision float, or null when it is not a
/// positive finite number below 10 MHz (no audio sample rate is).
double? _extended(Uint8List b, int at) {
  if (b.length < at + 10) return null;
  if (b[at] & 0x80 != 0) return null; // negative
  final exponent = ((b[at] & 0x7F) << 8) | b[at + 1];
  if (exponent == 0x7FFF) return null;
  final mantissa = u32be(b, at + 2) * 4294967296.0 + u32be(b, at + 6);
  if (mantissa == 0) return null;
  final value = mantissa * math.pow(2, exponent - 16383 - 63);
  if (!value.isFinite || value <= 0 || value >= 10000000) return null;
  return value.toDouble();
}
