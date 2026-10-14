import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';
import 'package:test/test.dart';

import 'support/build.dart';

Duration frames(int n, int spf, int rate) =>
    Duration(microseconds: (n * spf * 1000000 / rate).round());

void main() {
  group('FLAC', () {
    test('duration, rate, channels and bits from STREAMINFO', () {
      final p = sniffBytes(flacFile(
          rate: 48000, totalSamples: 48000 * 61, channels: 1, bits: 24));
      expect(p.format, AudioFormat.flac);
      expect(p.duration, const Duration(seconds: 61));
      expect(p.sampleRate, 48000);
      expect(p.channels, 1);
      expect(p.bitsPerSample, 24);
      expect(p.audioOffset, 42);
    });

    test('total samples of zero means unknown, not zero', () {
      final p = sniffBytes(flacFile(totalSamples: 0));
      expect(p.format, AudioFormat.flac);
      expect(p.duration, isNull);
      expect(p.durationAccuracy, isNull);
      expect(p.sampleRate, 44100);
    });

    test('the full 36-bit sample count', () {
      const total = 0xFFFFFFFFF; // 2^36 - 1
      final p = sniffBytes(flacFile(rate: 655350, totalSamples: total));
      expect(p.duration,
          Duration(microseconds: (total / 655350 * 1000000).round()));
    });

    test('a sample rate of zero is invalid', () {
      final p = sniffBytes(flacFile(rate: 0));
      expect(p.format, AudioFormat.flac);
      expect(p.duration, isNull);
      expect(p.sampleRate, isNull);
    });

    test('a first block that is not STREAMINFO gives no duration', () {
      final b = flacFile();
      b[4] = 0x04;
      final p = sniffBytes(b);
      expect(p.format, AudioFormat.flac);
      expect(p.duration, isNull);
    });

    test('truncated STREAMINFO gives no duration', () {
      final p = sniffBytes(flacFile().sublist(0, 30));
      expect(p.format, AudioFormat.flac);
      expect(p.duration, isNull);
    });

    test('behind an ID3v2 tag', () {
      final p = sniffBytes(
          concat([id3v2(bodySize: 300), flacFile(totalSamples: 88200)]));
      expect(p.format, AudioFormat.flac);
      expect(p.duration, const Duration(seconds: 2));
      expect(p.notes, contains(ProbeNote.id3v2Tag));
      expect(p.extensionLies('song.mp3'), isTrue);
    });

    test('audio offset follows the metadata chain', () {
      final p = sniffBytes(flacFile(
          blocks: [flacBlock(1, Uint8List(100)), flacBlock(1, Uint8List(10))]));
      expect(p.audioOffset, 42 + 104 + 14);
    });
  });

  group('MP3', () {
    test('Xing frame count is exact', () {
      final p = sniffBytes(
          concat([mp3Frame(tag: 'Xing', tagFrames: 1000), mp3Frames(5)]));
      expect(p.duration, frames(1000, 1152, 44100));
      expect(p.isDurationExact, isTrue);
    });

    test('Xing in a mono MPEG-1 frame', () {
      final p = sniffBytes(concat([
        mp3Frame(mono: true, tag: 'Xing', tagFrames: 10),
        mp3Frames(2, mono: true)
      ]));
      expect(p.duration, frames(10, 1152, 44100));
      expect(p.channels, 1);
    });

    test('Xing in MPEG-2 stereo and mono frames', () {
      for (final mono in [false, true]) {
        final p = sniffBytes(concat([
          mp3Frame(
              version: 2,
              kbps: 64,
              rate: 24000,
              mono: mono,
              tag: 'Xing',
              tagFrames: 77),
          mp3Frames(2, version: 2, kbps: 64, rate: 24000, mono: mono),
        ]));
        expect(p.duration, frames(77, 576, 24000), reason: 'mono $mono');
      }
    });

    test('Xing after a CRC', () {
      final p = sniffBytes(concat(
          [mp3Frame(crc: true, tag: 'Xing', tagFrames: 9), mp3Frames(2)]));
      expect(p.duration, frames(9, 1152, 44100));
    });

    test('Xing without the frames flag falls back to the estimate', () {
      final audio = concat(
          [mp3Frame(tag: 'Xing', tagFrames: 9, xingFlags: 0x06), mp3Frames(9)]);
      final p = sniffBytes(audio);
      expect(p.durationAccuracy, DurationAccuracy.estimated);
      expect(
          p.duration,
          Duration(
              microseconds: (audio.length * 8 * 1000000 / 128000).round()));
    });

    test('VBRI frame count is exact', () {
      final p = sniffBytes(
          concat([mp3Frame(tag: 'VBRI', tagFrames: 321), mp3Frames(2)]));
      expect(p.duration, frames(321, 1152, 44100));
      expect(p.isDurationExact, isTrue);
    });

    test('CBR estimate excludes ID3v2, ID3v1 and APEv2', () {
      final audio = mp3Frames(20);
      Uint8List apeBlock(int flags) => (Bytes()
            ..ascii('APETAGEX')
            ..u32le(2000)
            ..u32le(28 + 32)
            ..u32le(1)
            ..u32le(flags)
            ..zeros(8))
          .bytes;
      final file = concat([
        id3v2(),
        audio,
        apeBlock(0xA0000000), // header
        noise(28), // items
        apeBlock(0x80000000), // footer
        id3v1(),
      ]);
      final p = sniffBytes(file);
      expect(p.durationAccuracy, DurationAccuracy.estimated);
      expect(
        p.duration,
        Duration(microseconds: (audio.length * 8 * 1000000 / 128000).round()),
      );
    });

    test('no length, no estimate', () async {
      final p = await sniffStream(Stream.value(mp3Frames(5)), maxBytes: 1000);
      expect(p.format, AudioFormat.mp3);
      expect(p.duration, isNull);
    });

    test('sample rate and channels come from the first frame', () {
      final p = sniffBytes(
          mp3Frames(3, version: 2, kbps: 32, rate: 16000, mono: true));
      expect(p.sampleRate, 16000);
      expect(p.channels, 1);
      expect(p.codec, 'mp3');
    });
  });
}
