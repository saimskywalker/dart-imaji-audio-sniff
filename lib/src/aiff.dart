import 'dart:math' as math;
import 'dart:typed_data';

import 'bytes.dart';
import 'chunks.dart';
import 'types.dart';

/// AIFF-C compression types whose frames all have the same size, given by
/// the `COMM` sample size, so the sound data can be cross-checked against the
/// declared frame count.
const Set<String> _uncompressed = {
  'NONE', 'twos', 'sowt', 'raw ', 'in24', 'in32', '42ni', '23ni', //
  'fl32', 'FL32', 'fl64', 'FL64',
};

/// Compressed AIFF-C types whose `COMM` count is understood, as (sample
/// frames per counted unit, bytes per unit per channel).
///
/// Apple's AIFF-C spec calls `numSampleFrames` "the number of sample frames",
/// but for compressed sound Apple's writers store the number of packets. The
/// Sound Manager keeps compressed sound as "interleaved packet frames"
/// (Inside Macintosh: Sound, 1994, "Compressed Sound Header", `numFrames`),
/// and Core Audio's `afconvert -f AIFC -d ima4` writes into `COMM` the number
/// `afinfo` reports as "audio packets". FFmpeg reads it the same way
/// (libavformat/aiffdec.c: `st->duration = st->nb_frames *
/// aiff->block_duration`, the block duration being
/// `av_get_audio_frame_duration2` of the codec's `block_align`) and writes it
/// the same way (aiffenc.c: sound data size / `block_align`).
///
/// - `ima4`, Apple IMA 4:1 ADPCM: "Apple's IMA compressed files have a fixed
///   packet size of 64 samples per packet", each packet led by two predictor
///   bytes (Apple Technical Note TN1081), so 2 + 64 / 2 = 34 bytes per
///   channel. afinfo on a mono file: "34 bytes/packet, 64 frames/packet".
///   The last packet is padded, so the duration includes up to 63 frames of
///   padding, as afinfo's and ffprobe's do.
/// - `MAC3`, `MAC6`: MACE packets are 16 and 8 bits per channel (Inside
///   Macintosh: Sound, `threeToOnePacketSize`, `sixToOnePacketSize`) of 8-bit
///   audio compressed 3:1 and 6:1, so 6 frames each. Checked on FFmpeg's MACE
///   samples (samples.ffmpeg.org/A-codecs/MACE), whose `COMM` count times 6 is
///   within one packet of the uncompressed original's frame count.
/// - `ulaw`, `alaw`: one byte per sample and one frame per count, whatever
///   the `COMM` sample size (the size before compression). afinfo: "1
///   bytes/packet, 1 frames/packet"; FFmpeg: a block duration of 1.
///
/// Any other compression type (`GSM `, `ilbc`, `Qclp`, `QDM2`, `QDMC`,
/// `G722` ...) gets no duration: for those, the factor between the `COMM`
/// count and sample frames has not been confirmed against a real file, and
/// reading the count as frames is wrong by that factor (160 for `ilbc`).
const Map<String, ({int frames, int bytesPerChannel})> _packed = {
  'ima4': (frames: 64, bytesPerChannel: 34),
  'MAC3': (frames: 6, bytesPerChannel: 2),
  'MAC6': (frames: 6, bytesPerChannel: 1),
  'ulaw': (frames: 1, bytesPerChannel: 1),
  'alaw': (frames: 1, bytesPerChannel: 1),
};

/// Reads an AIFF or AIFF-C file. The caller has checked the magic.
///
/// The duration is the sample frames the `COMM` chunk declares over its
/// sample rate, an 80-bit IEEE 754 extended float. For compressed AIFF-C the
/// `COMM` count is converted to frames as [_packed] describes, and there is
/// no duration for a compression type not listed there.
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
  var count = u32be(comm, 2);
  final bits = u16be(comm, 6);
  final rate = _extended(comm, 8);
  final compression = (isAifc && comm.length >= 22) ? fourCC(comm, 18) : null;
  final codec = switch (compression) {
    null || 'NONE' => 'pcm',
    final c => c.trim(),
  };

  // Sample frames per COMM count, and bytes per count, when known.
  int? framesPerUnit;
  var unitBytes = 0;
  if (compression == null || _uncompressed.contains(compression)) {
    framesPerUnit = 1;
    unitBytes = channels * ((bits + 7) ~/ 8);
  } else if (_packed[compression] case final packing?) {
    framesPerUnit = packing.frames;
    unitBytes = channels * packing.bytesPerChannel;
  }

  int? audioOffset;
  final sound = ssnd;
  if (sound != null && sound.size >= 8) {
    final head = r.read(sound.bodyOffset, 8);
    if (head.length == 8) {
      audioOffset = sound.bodyOffset + 8 + u32be(head, 0);
      if (framesPerUnit != null && unitBytes > 0) {
        var present = sound.bodyOffset + sound.size;
        final length = r.length;
        if (length != null && length < present) present = length;
        final available = present - audioOffset;
        final unitsPresent = available <= 0 ? 0 : available ~/ unitBytes;
        if (unitsPresent < count) {
          count = unitsPresent;
          notes.add(ProbeNote.truncated);
        }
      }
    }
  }

  final duration = (rate == null || framesPerUnit == null)
      ? null
      : framesToDurationAtRate(count * framesPerUnit, rate);
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
