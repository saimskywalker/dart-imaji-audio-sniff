import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';
import 'package:test/test.dart';

import 'support/build.dart';

Uint8List dataHeader(int declared) => (Bytes()
      ..ascii('data')
      ..u32le(declared))
    .bytes;

void main() {
  test('canonical 44-byte header', () {
    final p = sniffBytes(simpleWav(frames: 44100 * 2));
    expect(p.duration, const Duration(seconds: 2));
    expect(p.codec, 'pcm');
    expect(p.sampleRate, 44100);
    expect(p.channels, 2);
    expect(p.bitsPerSample, 16);
    expect(p.audioOffset, 44);
  });

  test('fmt after kilobytes of metadata', () {
    final p = sniffBytes(wavFile([
      chunk('JUNK', Uint8List(4096)),
      chunk('bext', Uint8List(602)),
      chunk('iXML', Uint8List(3001)),
      chunk('fmt ', fmtBody(rate: 48000, bits: 24)),
      chunk('data', noise(48000 * 6)),
    ]));
    expect(p.duration, const Duration(seconds: 1));
    expect(p.notes, isNot(contains(ProbeNote.missingPadByte)));
  });

  group('odd-sized chunks', () {
    for (final pad in [true, false]) {
      test(pad ? 'with the pad byte' : 'without the pad byte', () {
        final p = sniffBytes(wavFile([
          chunk('LIST', Uint8List(17)..setAll(0, 'INFO'.codeUnits), pad: pad),
          chunk('fmt ', fmtBody(channels: 1, rate: 8000, bits: 8)),
          chunk('note', Uint8List(5)..setAll(0, 'hello'.codeUnits), pad: pad),
          chunk('data', noise(8000)),
        ]));
        expect(p.duration, const Duration(seconds: 1));
        expect(p.notes.contains(ProbeNote.missingPadByte), !pad);
      });
    }

    test('an odd final chunk with no pad at the end of the file', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(channels: 1, rate: 8000, bits: 8)),
        chunk('data', noise(8001), pad: false),
      ]));
      expect(p.duration, const Duration(microseconds: 1000125));
    });
  });

  test('data before fmt', () {
    final p = sniffBytes(wavFile([
      chunk('data', noise(16000 * 2)),
      chunk('fmt ', fmtBody(channels: 1, rate: 16000)),
    ]));
    expect(p.duration, const Duration(seconds: 1));
  });

  test('data before fmt with an unknown size has no duration', () {
    final p = sniffBytes(wavFile([
      concat([dataHeader(0xFFFFFFFF), noise(1000)]),
      chunk('fmt ', fmtBody()),
    ]));
    expect(p.format, AudioFormat.wav);
    expect(p.duration, isNull);
  });

  group('data size', () {
    test('0 with audio behind it is a streamed write', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(channels: 1, rate: 1000, bits: 8)),
        concat([dataHeader(0), noise(500)]),
      ], riffSize: 0));
      expect(p.duration, const Duration(milliseconds: 500));
      expect(p.notes, contains(ProbeNote.unknownDataSize));
    });

    test('0 at the end of the file is an empty recording', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(channels: 1, rate: 1000, bits: 8)),
        dataHeader(0),
      ]));
      expect(p.duration, Duration.zero);
      expect(p.notes, isNot(contains(ProbeNote.unknownDataSize)));
    });

    test('0 followed by another chunk is an empty recording', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(channels: 1, rate: 1000, bits: 8)),
        dataHeader(0),
        chunk('LIST', 'INFO'.codeUnits),
      ]));
      expect(p.duration, Duration.zero);
    });

    test('larger than the file is a truncated copy', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(channels: 1, rate: 1000, bits: 8)),
        concat([dataHeader(100000), noise(250)]),
      ]));
      expect(p.duration, const Duration(milliseconds: 250));
      expect(p.notes, contains(ProbeNote.truncated));
    });

    test('a partial buffer plus the real length trusts the header', () {
      final whole = simpleWav(frames: 44100 * 10);
      final p = sniffBytes(whole.sublist(0, 1024), fileLength: whole.length);
      expect(p.duration, const Duration(seconds: 10));
      expect(p.notes, isEmpty);
    });
  });

  group('formats', () {
    test('block align of zero is derived from channels and bits', () {
      final p = sniffBytes(wavFile([
        chunk(
            'fmt ', fmtBody(channels: 2, rate: 1000, bits: 16, blockAlign: 0)),
        chunk('data', noise(4000)),
      ]));
      expect(p.duration, const Duration(seconds: 1));
    });

    test('a wrong byte rate is outvoted by the frame arithmetic', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ',
            fmtBody(channels: 2, rate: 1000, bits: 16, byteRate: 12345)),
        chunk('data', noise(4000)),
      ]));
      expect(p.duration, const Duration(seconds: 1));
    });

    test('A-law, mu-law and float are constant-frame', () {
      for (final (tag, name) in [(6, 'alaw'), (7, 'mulaw'), (3, 'float')]) {
        final bits = tag == 3 ? 32 : 8;
        final p = sniffBytes(wavFile([
          chunk('fmt ', fmtBody(tag: tag, channels: 1, rate: 8000, bits: bits)),
          chunk('data', noise(8000 * bits ~/ 8)),
        ]));
        expect(p.codec, name);
        expect(p.duration, const Duration(seconds: 1));
      }
    });

    test('WAVE_FORMAT_EXTENSIBLE resolves the SubFormat GUID', () {
      final p = sniffBytes(wavFile([
        chunk(
            'fmt ',
            fmtBody(
                extensible: true,
                subFormat: 3,
                channels: 6,
                rate: 48000,
                bits: 32)),
        chunk('data', noise(48000 * 24 ~/ 2)),
      ]));
      expect(p.codec, 'float');
      expect(p.channels, 6);
      expect(p.duration, const Duration(milliseconds: 500));
      expect(p.notes, contains(ProbeNote.extensibleFormat));
    });

    test('extensible 24-in-32 reports the valid bits', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(extensible: true, bits: 32, validBits: 24)),
        chunk('data', noise(44100 * 8)),
      ]));
      expect(p.bitsPerSample, 24);
      expect(p.duration, const Duration(seconds: 1));
    });

    test('a truncated extensible fmt is a WAV without a duration', () {
      final fmt = fmtBody(extensible: true).sublist(0, 20);
      final p =
          sniffBytes(wavFile([chunk('fmt ', fmt), chunk('data', noise(100))]));
      expect(p.format, AudioFormat.wav);
      expect(p.duration, isNull);
    });

    test('compressed audio uses fact', () {
      final p = sniffBytes(wavFile([
        chunk(
            'fmt ',
            fmtBody(
                tag: 0x11,
                channels: 1,
                rate: 8000,
                bits: 4,
                blockAlign: 256,
                byteRate: 4055)),
        chunk('fact', (Bytes()..u32le(16000)).bytes),
        chunk('data', noise(8110)),
      ]));
      expect(p.codec, 'adpcm-ima');
      expect(p.duration, const Duration(seconds: 2));
      expect(p.isDurationExact, isTrue);
      expect(p.bitsPerSample, isNull);
    });

    test('compressed audio without fact is an estimate from the byte rate', () {
      final p = sniffBytes(wavFile([
        chunk(
            'fmt ',
            fmtBody(
                tag: 0x55,
                channels: 2,
                rate: 44100,
                byteRate: 16000,
                blockAlign: 1)),
        chunk('data', noise(24000)),
      ]));
      expect(p.codec, 'mp3');
      expect(p.duration, const Duration(milliseconds: 1500));
      expect(p.durationAccuracy, DurationAccuracy.estimated);
    });

    test('fact after data is still found', () {
      final p = sniffBytes(wavFile([
        chunk(
            'fmt ',
            fmtBody(
                tag: 2,
                channels: 1,
                rate: 8000,
                bits: 4,
                blockAlign: 256,
                byteRate: 4096)),
        chunk('data', noise(4096)),
        chunk('fact', (Bytes()..u32le(4000)).bytes),
      ]));
      expect(p.duration, const Duration(milliseconds: 500));
    });

    test('zero sample rate gives a WAV without a duration', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(rate: 0)),
        chunk('data', noise(100)),
      ]));
      expect(p.format, AudioFormat.wav);
      expect(p.duration, isNull);
    });
  });

  group('RF64', () {
    test('a data size beyond 4 GiB comes from ds64', () {
      const frames = 48000 * 60 * 60 * 7; // seven hours, 24-bit stereo
      const dataSize = frames * 6;
      expect(dataSize, greaterThan(0xFFFFFFFF));
      final head = wavFile([
        chunk(
            'ds64',
            ds64Body(
                riffSize: dataSize + 100,
                dataSize: dataSize,
                sampleCount: frames)),
        chunk('fmt ', fmtBody(rate: 48000, bits: 24)),
        concat([dataHeader(0xFFFFFFFF), noise(512)]),
      ], magic: 'RF64', riffSize: 0xFFFFFFFF);
      final p = sniffBytes(head, fileLength: head.length - 512 + dataSize);
      expect(p.duration, const Duration(hours: 7));
      expect(p.notes, contains(ProbeNote.rf64));
    });

    test('a table entry resolves another chunk', () {
      final p = sniffBytes(wavFile([
        chunk(
            'ds64', ds64Body(riffSize: 0, dataSize: 2000, table: {'LIST': 4})),
        chunk('LIST', 'INFO'.codeUnits, declared: 0xFFFFFFFF),
        chunk('fmt ', fmtBody(channels: 1, rate: 1000, bits: 16)),
        concat([dataHeader(0xFFFFFFFF), noise(2000)]),
      ], magic: 'BW64', riffSize: 0xFFFFFFFF));
      expect(p.duration, const Duration(seconds: 1));
    });

    test('without ds64 the data size is unknown and counted from the file', () {
      final p = sniffBytes(wavFile([
        chunk('fmt ', fmtBody(channels: 1, rate: 1000, bits: 8)),
        concat([dataHeader(0xFFFFFFFF), noise(300)]),
      ], magic: 'RF64'));
      expect(p.duration, const Duration(milliseconds: 300));
      expect(p.notes, contains(ProbeNote.unknownDataSize));
    });

    test('compressed RF64 takes the sample count from ds64', () {
      final p = sniffBytes(wavFile([
        chunk(
            'ds64', ds64Body(riffSize: 0, dataSize: 1000, sampleCount: 24000)),
        chunk(
            'fmt ',
            fmtBody(
                tag: 0x55,
                channels: 1,
                rate: 24000,
                byteRate: 1000,
                blockAlign: 1)),
        chunk('fact', (Bytes()..u32le(0xFFFFFFFF)).bytes),
        concat([dataHeader(0xFFFFFFFF), noise(1000)]),
      ], magic: 'RF64'));
      expect(p.duration, const Duration(seconds: 1));
      expect(p.isDurationExact, isTrue);
    });
  });

  test('a corrupt chunk id ends the walk without a duration', () {
    final p = sniffBytes(wavFile([
      [0x01, 0x02, 0x03, 0x04, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      chunk('fmt ', fmtBody()),
      chunk('data', noise(100)),
    ]));
    expect(p.format, AudioFormat.wav);
    expect(p.duration, isNull);
  });

  test('a chunk size near 2^32 ends the walk instead of overflowing', () {
    final p = sniffBytes(wavFile([
      chunk('JUNK', Uint8List(4), declared: 0xFFFFFFFE),
      chunk('fmt ', fmtBody()),
      chunk('data', noise(100)),
    ]));
    expect(p.format, AudioFormat.wav);
    expect(p.duration, isNull);
  });
}
