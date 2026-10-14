import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';
import 'package:test/test.dart';

import 'support/build.dart';

void main() {
  group('the extension is a claim; the bytes are the truth', () {
    test('a six-minute WAV named .mp3 is a WAV, six minutes long', () {
      // 6:00 of 44.1 kHz 16-bit stereo, only the header and a little audio
      // in memory, the real size passed separately.
      const frames = 44100 * 360;
      final header = wavFile([
        chunk('fmt ', fmtBody()),
        concat([
          (Bytes()
                ..ascii('data')
                ..u32le(frames * 4))
              .bytes,
          noise(4096),
        ]),
      ]);
      final p = sniffBytes(header, fileLength: 44 + frames * 4);
      expect(p.format, AudioFormat.wav);
      expect(p.duration, const Duration(minutes: 6));
      expect(p.isDurationExact, isTrue);
      expect(p.extensionLies('take_03.mp3'), isTrue);
      expect(p.extensionMatches('take_03.mp3'), isFalse);
      expect(p.format.extension, 'wav');
      expect(p.format.mimeType, 'audio/wav');
    });

    test('a WAV whose samples begin with an MPEG sync word is still a WAV', () {
      final data = concat([mp3Frames(3), noise(1000)]);
      final p =
          sniffBytes(wavFile([chunk('fmt ', fmtBody()), chunk('data', data)]));
      expect(p.format, AudioFormat.wav);
    });
  });

  group('strict MPEG frame sync', () {
    test('rejects 0xFF runs', () {
      expect(sniffBytes(List.filled(4096, 0xFF)).format, AudioFormat.unknown);
    });

    test('rejects headerless PCM noise', () {
      for (var seed = 1; seed < 200; seed++) {
        expect(sniffBytes(noise(8192, seed: seed)).format, AudioFormat.unknown,
            reason: 'seed $seed');
      }
    });

    test('rejects reserved version, layer, bitrate, rate and emphasis', () {
      final good = frameHeader();
      Uint8List withByte(int index, int value) {
        final h = Uint8List.fromList(good);
        h[index] = value;
        return concat([h, Uint8List(600)]);
      }

      expect(sniffBytes(withByte(1, (good[1] & ~0x18) | 0x08)).isKnown, isFalse,
          reason: 'version 01');
      expect(sniffBytes(withByte(1, good[1] & ~0x06)).isKnown, isFalse,
          reason: 'layer 00');
      expect(sniffBytes(withByte(1, (good[1] & ~0x06) | 0x04)).isKnown, isFalse,
          reason: 'Layer II is not MP3');
      expect(sniffBytes(withByte(2, good[2] & 0x0F)).isKnown, isFalse,
          reason: 'free bitrate');
      expect(sniffBytes(withByte(2, good[2] | 0xF0)).isKnown, isFalse,
          reason: 'bad bitrate');
      expect(sniffBytes(withByte(2, good[2] | 0x0C)).isKnown, isFalse,
          reason: 'rate 11');
      expect(sniffBytes(withByte(3, good[3] | 0x02)).isKnown, isFalse,
          reason: 'emphasis 10');
    });

    test('needs a consistent second frame when one should follow', () {
      final frame = mp3Frame();
      final bad = concat([frame, Uint8List(600)]);
      expect(sniffBytes(bad).isKnown, isFalse);
      final good = concat([frame, mp3Frame()]);
      expect(sniffBytes(good).format, AudioFormat.mp3);
    });

    test('accepts a lone frame when the bytes end first', () {
      final frame = mp3Frame();
      expect(sniffBytes(frame.sublist(0, 200)).format, AudioFormat.mp3);
    });

    test('accepts MPEG-2 and MPEG-2.5', () {
      expect(sniffBytes(mp3Frames(3, version: 2, kbps: 64, rate: 22050)).format,
          AudioFormat.mp3);
      expect(sniffBytes(mp3Frames(3, version: 25, kbps: 32, rate: 8000)).format,
          AudioFormat.mp3);
    });
  });

  group('ID3v2', () {
    test('skips one or more tags to reach MPEG audio', () {
      final p =
          sniffBytes(concat([id3v2(), id3v2(bodySize: 10), mp3Frames(4)]));
      expect(p.format, AudioFormat.mp3);
      expect(p.notes, contains(ProbeNote.id3v2Tag));
      expect(p.audioOffset, 1034 + 20);
    });

    test('honours the v2.4 footer flag', () {
      final p =
          sniffBytes(concat([id3v2(major: 4, footer: true), mp3Frames(3)]));
      expect(p.format, AudioFormat.mp3);
      expect(p.audioOffset, 1044);
    });

    test('skips zero padding after the tag', () {
      final p = sniffBytes(concat([id3v2(), Uint8List(700), mp3Frames(3)]));
      expect(p.format, AudioFormat.mp3);
      expect(p.audioOffset, 1034 + 700);
    });

    test('searches past junk after the tag for a chain of frames', () {
      final junk = Uint8List.fromList(List.generate(333, (i) => 1 + i % 200));
      final p = sniffBytes(concat([id3v2(), junk, mp3Frames(4)]));
      expect(p.format, AudioFormat.mp3);
      expect(p.audioOffset, 1034 + 333);
    });

    test('in front of something that is not audio is unknown', () {
      final p = sniffBytes(concat([id3v2(), noise(4096)]));
      expect(p.format, AudioFormat.unknown);
    });

    test('a tag running past the given bytes reads as MP3 with no duration',
        () {
      final p = sniffBytes(id3v2(bodySize: 100000).sublist(0, 512));
      expect(p.format, AudioFormat.mp3);
      expect(p.duration, isNull);
    });

    test('a malformed size byte is not a tag', () {
      final tag = id3v2();
      tag[6] = 0x80;
      expect(
          sniffBytes(concat([tag, mp3Frames(3)])).format, AudioFormat.unknown);
    });
  });

  group('magic numbers', () {
    test('RIFF without WAVE is not WAV', () {
      final b = Bytes()
        ..ascii('RIFF')
        ..u32le(100)
        ..ascii('AVI ')
        ..zeros(100);
      expect(sniffBytes(b.bytes).format, AudioFormat.unknown);
    });

    test('image brands in ftyp are not audio', () {
      for (final brand in ['heic', 'avif', 'mif1', 'crx ']) {
        expect(
            sniffBytes(concat([
              ftyp(brand),
              box('mdat', [Uint8List(8)])
            ])).format,
            AudioFormat.unknown);
      }
    });

    test('a QuickTime file that opens with moov is M4A', () {
      final p = sniffBytes(box('moov', [mvhd(timescale: 600, duration: 1200)]));
      expect(p.format, AudioFormat.m4a);
      expect(p.duration, const Duration(seconds: 2));
    });

    test('empty and tiny inputs are unknown', () {
      expect(sniffBytes(const []).format, AudioFormat.unknown);
      expect(sniffBytes(const [0x52]).format, AudioFormat.unknown);
      expect(sniffBytes('RIFF'.codeUnits).format, AudioFormat.unknown);
      expect(AudioProbe.unknown.extensionLies('a.mp3'), isFalse);
    });
  });

  group('extensionOf', () {
    test('reads the last extension, lowercased', () {
      expect(extensionOf('Song.MP3'), 'mp3');
      expect(extensionOf('a.tar.gz'), 'gz');
      expect(extensionOf('/music/take.wav'), 'wav');
      expect(extensionOf(r'C:\Music\take.FLAC'), 'flac');
    });

    test('has no extension for these', () {
      expect(extensionOf('song'), isNull);
      expect(extensionOf('.wav'), isNull);
      expect(extensionOf('song.'), isNull);
      expect(extensionOf('/Music v1.2/song'), isNull);
      expect(extensionOf(''), isNull);
    });

    test('ignores the query of a URL', () {
      expect(extensionOf('https://cdn.example.com/a/b.m4a?sig=x.mp3'), 'm4a');
    });
  });

  group('extension sets follow the demuxer, not the name', () {
    test('an MP4 holding audio is not a lie', () {
      const p = AudioProbe(format: AudioFormat.m4a);
      expect(p.extensionLies('a.mp4'), isFalse);
      expect(p.extensionLies('a.m4b'), isFalse);
      expect(p.extensionLies('a.aac'), isTrue);
    });

    test('.aif covers both AIFF and AIFF-C', () {
      expect(const AudioProbe(format: AudioFormat.aiff).extensionLies('a.aif'),
          isFalse);
      expect(const AudioProbe(format: AudioFormat.aifc).extensionLies('a.aif'),
          isFalse);
    });

    test('a missing extension does not lie, but does not match', () {
      const p = AudioProbe(format: AudioFormat.wav);
      expect(p.extensionLies('recording'), isFalse);
      expect(p.extensionMatches('recording'), isFalse);
    });
  });

  test('toString names the format and duration', () {
    final p = sniffBytes(simpleWav());
    expect(p.toString(), contains('format: wav'));
    expect(p.toString(), contains('0:00:01.000000 (exact)'));
  });
}
