import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';
import 'package:test/test.dart';

import 'support/build.dart';

void main() {
  group('AIFF / AIFF-C', () {
    test('frames over an 80-bit extended sample rate', () {
      for (final rate in [8000, 22050, 44100, 48000, 96000, 192000]) {
        final p = sniffBytes(aiffFile([
          ifChunk('COMM',
              commBody(channels: 1, frames: rate * 3, bits: 8, rate: rate)),
          ifChunk('SSND', ssndBody(rate * 3)),
        ]));
        expect(p.format, AudioFormat.aiff);
        expect(p.duration, const Duration(seconds: 3), reason: '$rate Hz');
        expect(p.sampleRate, rate);
        expect(p.codec, 'pcm');
      }
    });

    test('AIFF-C reports its compression type', () {
      final p = sniffBytes(aiffFile([
        ifChunk('COMM',
            commBody(frames: 4410, compression: 'sowt', compressionName: 'x')),
        ifChunk('SSND', ssndBody(4410 * 4)),
      ], aifc: true));
      expect(p.format, AudioFormat.aifc);
      expect(p.codec, 'sowt');
      expect(p.duration, const Duration(milliseconds: 100));
      expect(p.durationAccuracy, DurationAccuracy.exact);
    });

    test('SSND offset is honoured and truncation detected', () {
      final p = sniffBytes(aiffFile([
        ifChunk(
            'COMM', commBody(channels: 1, frames: 1000, bits: 16, rate: 1000)),
        ifChunk('SSND', ssndBody(800, offset: 8)),
      ]));
      expect(p.duration, const Duration(milliseconds: 400));
      expect(p.notes, contains(ProbeNote.truncated));
      expect(p.audioOffset, 12 + 26 + 8 + 8 + 8);
    });

    test('SSND before COMM', () {
      final p = sniffBytes(aiffFile([
        ifChunk('SSND', ssndBody(2000)),
        ifChunk(
            'COMM', commBody(channels: 1, frames: 1000, bits: 16, rate: 1000)),
      ]));
      expect(p.duration, const Duration(seconds: 1));
    });

    test('a broken sample rate gives no duration', () {
      final comm = commBody(rate: 44100);
      comm[8] = 0x7F; // exponent 0x7FFF: infinity / NaN
      comm[9] = 0xFF;
      final p = sniffBytes(
          aiffFile([ifChunk('COMM', comm), ifChunk('SSND', ssndBody(4))]));
      expect(p.format, AudioFormat.aiff);
      expect(p.duration, isNull);
    });

    test('no COMM, no duration', () {
      final p = sniffBytes(aiffFile([ifChunk('SSND', ssndBody(4))]));
      expect(p.format, AudioFormat.aiff);
      expect(p.duration, isNull);
    });
  });

  group('M4A / MP4', () {
    test('mvhd version 0 and the sound sample entry', () {
      final p = sniffBytes(concat([
        ftyp('M4A '),
        box('moov', [
          mvhd(timescale: 44100, duration: 44100 * 5 + 22050),
          soundTrak(rate: 48000, channels: 1)
        ]),
      ]));
      expect(p.format, AudioFormat.m4a);
      expect(p.duration, const Duration(milliseconds: 5500));
      expect(p.codec, 'mp4a');
      expect(p.sampleRate, 48000);
      expect(p.channels, 1);
    });

    test('mvhd version 1 with a 64-bit duration', () {
      const scale = 90000;
      const seconds = 60 * 60 * 24 * 30; // 30 days
      final p = sniffBytes(concat([
        ftyp('mp42'),
        box('moov',
            [mvhd(timescale: scale, duration: scale * seconds, version: 1)]),
      ]));
      expect(p.duration, const Duration(seconds: seconds));
    });

    test('an unknown duration (all ones) is no duration', () {
      final p = sniffBytes(concat([
        ftyp('M4A '),
        box('moov', [mvhd(timescale: 1000, duration: 0xFFFFFFFF)]),
      ]));
      expect(p.format, AudioFormat.m4a);
      expect(p.duration, isNull);
    });

    test('64-bit box sizes', () {
      final mdat = concat([
        (Bytes()
              ..u32be(1)
              ..ascii('mdat')
              ..u64be(16 + 100))
            .bytes,
        noise(100),
      ]);
      final p = sniffBytes(concat([
        ftyp('M4A '),
        mdat,
        box('moov', [mvhd(timescale: 10, duration: 25)]),
      ]));
      expect(p.duration, const Duration(milliseconds: 2500));
    });

    test('moov far from the start, read through a partial buffer', () {
      final file = concat([
        ftyp('M4A '),
        box('mdat', [noise(300000)]),
        box('moov', [mvhd(timescale: 1000, duration: 1234)]),
      ]);
      // Only the start in memory: the format is known, the duration is not.
      final head = sniffBytes(file.sublist(0, 4096), fileLength: file.length);
      expect(head.format, AudioFormat.m4a);
      expect(head.duration, isNull);
      // Random access finds it.
      final p = sniffReaderSync(
        (o, n) => file.sublist(
            o.clamp(0, file.length), (o + n).clamp(0, file.length)),
        length: file.length,
      );
      expect(p.duration, const Duration(milliseconds: 1234));
    });

    test('size 0 means "to the end of the file"', () {
      final p = sniffBytes(concat([
        ftyp('M4A '),
        box('moov', [mvhd(timescale: 1000, duration: 500)]),
        (Bytes()
              ..u32be(0)
              ..ascii('mdat'))
            .bytes,
        noise(64),
      ]));
      expect(p.duration, const Duration(milliseconds: 500));
    });

    test('ftyp with no moov is M4A without a duration', () {
      final p = sniffBytes(concat([
        ftyp('M4A '),
        box('mdat', [Uint8List(64)])
      ]));
      expect(p.format, AudioFormat.m4a);
      expect(p.duration, isNull);
    });

    test('a box smaller than its header stops the walk', () {
      final p = sniffBytes(concat([
        ftyp('M4A '),
        (Bytes()
              ..u32be(3)
              ..ascii('free'))
            .bytes,
        box('moov', [mvhd(timescale: 1000, duration: 500)]),
      ]));
      expect(p.format, AudioFormat.m4a);
      expect(p.duration, isNull);
    });
  });
}
