import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';
import 'package:test/test.dart';

import 'support/build.dart';

/// A `COMM` body copied byte for byte from a real file, with the
/// compression name appended.
Uint8List realComm(List<int> head, String type, String name) => concat([
      head,
      type.codeUnits,
      [name.length],
      name.codeUnits,
      if ((name.length + 1).isOdd) [0],
    ]);

/// Channels 1, then [count] in `numSampleFrames`, sample size 8 and the
/// Macintosh 22 kHz rate as the 80-bit float `400D ADDD 1746 0000 0000`
/// (22254.545... Hz): the `COMM` of the FFmpeg MACE samples below.
List<int> maceHead(int count) => [
      0x00, 0x01, //
      (count >> 24) & 0xFF, (count >> 16) & 0xFF, (count >> 8) & 0xFF,
      count & 0xFF,
      0x00, 0x08,
      0x40, 0x0D, 0xAD, 0xDD, 0x17, 0x46, 0x00, 0x00, 0x00, 0x00,
    ];

AudioProbe aifc(Uint8List comm, int soundBytes) => sniffBytes(aiffFile([
      ifChunk('COMM', comm),
      ifChunk('SSND', ssndBody(soundBytes)),
    ], aifc: true));

void main() {
  group('AIFF-C ima4: COMM counts 64-frame packets (#22)', () {
    test('the stereo 44.1 kHz file from the issue', () {
      // `afconvert -f AIFC -d ima4` of a 3 s stereo 44.1 kHz sine.
      // afinfo: "2 ch, 44100 Hz, ima4, 68 bytes/packet, 64 frames/packet",
      // "audio packets: 2068", "estimated duration: 3.001179 sec";
      // ffprobe: duration=3.001179. COMM numSampleFrames is 0x00000814 =
      // 2068, the packet count. 2068 x 64 / 44100 = 3.0011791 s.
      final p = aifc(
          commBody(
              channels: 2,
              frames: 2068,
              bits: 16,
              rate: 44100,
              compression: 'ima4',
              compressionName: 'IMA 4:1'),
          2068 * 68);
      expect(p.format, AudioFormat.aifc);
      expect(p.codec, 'ima4');
      expect(p.duration, const Duration(microseconds: 3001179));
      expect(p.durationAccuracy, DurationAccuracy.exact);
      expect(p.sampleRate, 44100);
      expect(p.channels, 2);
      expect(p.notes, isNot(contains(ProbeNote.truncated)));
    });

    test('mono: a packet is 34 bytes', () {
      // afconvert, 1 s mono 8 kHz: afinfo "34 bytes/packet, 64 frames/packet,
      // audio packets: 126, estimated duration: 1.008000 sec".
      final p = aifc(
          commBody(
              channels: 1,
              frames: 126,
              bits: 0,
              rate: 8000,
              compression: 'ima4',
              compressionName: 'IMA 4:1'),
          126 * 34);
      expect(p.duration, const Duration(milliseconds: 1008));
      expect(p.durationAccuracy, DurationAccuracy.exact);
      expect(p.notes, isNot(contains(ProbeNote.truncated)));
    });

    test('truncated sound data counts only the whole packets present', () {
      // 100 packets declared, 40 stereo packets (68 bytes each) present.
      final p = aifc(
          commBody(
              channels: 2,
              frames: 100,
              rate: 8000,
              compression: 'ima4',
              compressionName: 'IMA 4:1'),
          40 * 68 + 30);
      expect(p.duration, const Duration(milliseconds: 320)); // 40 x 64 / 8000
      expect(p.notes, contains(ProbeNote.truncated));
    });
  });

  group('AIFF-C MACE: COMM counts 6-frame packets', () {
    // Header values of https://samples.ffmpeg.org/A-codecs/MACE/: Bach1-1.aiff
    // is the uncompressed original (AIFF, 257024 frames); mac3/Bach3-1.aiff
    // and mac6/Bach6-1.aiff are the same sound in MACE 3:1 and 6:1. Their
    // COMM says 42837 and 42838, and their SSND holds 85675 and 42838 bytes:
    // one 2-byte (3:1) or 1-byte (6:1) packet per count, each 6 frames,
    // which is 257022 and 257028 frames (ffprobe duration_ts agrees).
    test('MAC3, 2 bytes per packet', () {
      final p = aifc(realComm(maceHead(42837), 'MAC3', 'MACE 3-to-1'), 85675);
      expect(p.codec, 'MAC3');
      expect(p.sampleRate, 22255);
      // 257022 / 22254.545... Hz
      expect(p.duration, const Duration(microseconds: 11549191));
      expect(p.durationAccuracy, DurationAccuracy.exact);
      expect(p.notes, isNot(contains(ProbeNote.truncated)));
    });

    test('MAC6, 1 byte per packet', () {
      final p = aifc(realComm(maceHead(42838), 'MAC6', 'MACE 6-to-1'), 42838);
      expect(p.codec, 'MAC6');
      // 257028 / 22254.545... Hz
      expect(p.duration, const Duration(microseconds: 11549461));
      expect(p.durationAccuracy, DurationAccuracy.exact);
      expect(p.notes, isNot(contains(ProbeNote.truncated)));
    });

    test('both are within one packet of the uncompressed original', () {
      final original = sniffBytes(aiffFile([
        ifChunk('COMM', maceHead(257024)),
        ifChunk('SSND', ssndBody(257024)),
      ])).duration!;
      for (final p in [
        aifc(realComm(maceHead(42837), 'MAC3', 'MACE 3-to-1'), 85675),
        aifc(realComm(maceHead(42838), 'MAC6', 'MACE 6-to-1'), 42838),
      ]) {
        final diff = (p.duration! - original).abs();
        expect(diff, lessThan(const Duration(microseconds: 270)), // 6 frames
            reason: p.codec);
      }
    });
  });

  group('AIFF-C a-law and mu-law: COMM counts frames', () {
    for (final type in ['ulaw', 'alaw']) {
      test('$type: one byte per sample, one frame per count', () {
        // afconvert -f AIFC -d $type, 1 s mono 8 kHz: afinfo "1 bytes/packet,
        // 1 frames/packet, audio packets: 8000"; COMM says 8000.
        final p = aifc(
            commBody(
                channels: 1,
                frames: 8000,
                bits: 8,
                rate: 8000,
                compression: type,
                compressionName: '$type 2:1'),
            8000);
        expect(p.codec, type);
        expect(p.duration, const Duration(seconds: 1));
        expect(p.durationAccuracy, DurationAccuracy.exact);
        expect(p.notes, isNot(contains(ProbeNote.truncated)));
      });
    }

    test('the sample size before compression does not size the frame', () {
      // A 16-bit original: still one byte per sample in the file.
      final p = aifc(
          commBody(
              channels: 2,
              frames: 8000,
              bits: 16,
              rate: 8000,
              compression: 'ulaw',
              compressionName: 'x'),
          16000);
      expect(p.duration, const Duration(seconds: 1));
      expect(p.notes, isNot(contains(ProbeNote.truncated)));
    });

    test('truncation is detected', () {
      final p = aifc(
          commBody(
              channels: 1,
              frames: 8000,
              bits: 8,
              rate: 8000,
              compression: 'alaw',
              compressionName: 'x'),
          4000);
      expect(p.duration, const Duration(milliseconds: 500));
      expect(p.notes, contains(ProbeNote.truncated));
    });
  });

  group('AIFF-C types with an unconfirmed COMM count give no duration', () {
    test('ilbc: COMM counts 160-frame packets, but the mode varies', () {
      // afconvert -f AIFC -d ilbc, 1 s mono 8 kHz: afinfo "38 bytes/packet,
      // 160 frames/packet, audio packets: 51, estimated duration: 1.020000
      // sec"; COMM says 51. Reading 51 as frames would claim 6.4 ms.
      final p = aifc(
          commBody(
              channels: 1,
              frames: 51,
              bits: 0,
              rate: 8000,
              compression: 'ilbc',
              compressionName: 'iLBC'),
          51 * 38);
      expect(p.format, AudioFormat.aifc);
      expect(p.codec, 'ilbc');
      expect(p.sampleRate, 8000);
      expect(p.channels, 1);
      expect(p.duration, isNull);
      expect(p.durationAccuracy, isNull);
    });

    for (final type in ['GSM ', 'Qclp', 'QDM2', 'QDMC', 'G722', 'zzzz']) {
      test("'$type'", () {
        final p = aifc(
            commBody(
                channels: 1,
                frames: 100,
                rate: 8000,
                compression: type,
                compressionName: 'x'),
            3300);
        expect(p.codec, type.trim());
        expect(p.sampleRate, 8000);
        expect(p.duration, isNull);
        expect(p.durationAccuracy, isNull);
      });
    }
  });
}
