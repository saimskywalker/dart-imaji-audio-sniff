import 'dart:async';
import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';
import 'package:test/test.dart';

import 'support/writers.dart';

void expectFixture(AudioProbe p, Fixture f) {
  expect(p.format, f.format, reason: f.name);
  expect(p.duration, f.duration, reason: f.name);
  if (f.duration != null) {
    expect(p.durationAccuracy, f.accuracy, reason: f.name);
  }
  for (final note in f.notes) {
    expect(p.notes, contains(note), reason: '${f.name}: $p');
  }
  if (f.sampleRate != null) expect(p.sampleRate, f.sampleRate, reason: f.name);
  if (f.channels != null) expect(p.channels, f.channels, reason: f.name);
}

void main() {
  for (final f in corpus()) {
    group(f.name, () {
      test('sniffBytes', () => expectFixture(sniffBytes(f.bytes), f));

      test('sniffReaderSync reads a bounded amount', () {
        var read = 0;
        final p = sniffReaderSync((offset, length) {
          final end = (offset + length).clamp(0, f.bytes.length);
          final out =
              offset >= end ? Uint8List(0) : f.bytes.sublist(offset, end);
          read += out.length;
          return out;
        }, length: f.bytes.length);
        expectFixture(p, f);
        expect(read, lessThan(256 * 1024));
      });

      test('sniffReader (async random access)', () async {
        final p = await sniffReader((offset, length) async {
          if (offset >= f.bytes.length) return const <int>[];
          final end = (offset + length).clamp(0, f.bytes.length);
          return f.bytes.sublist(offset, end);
        }, length: f.bytes.length);
        expectFixture(p, f);
      });

      test('sniffStream in small chunks', () async {
        Stream<List<int>> chunks() async* {
          for (var i = 0; i < f.bytes.length; i += 1000) {
            yield f.bytes.sublist(i, (i + 1000).clamp(0, f.bytes.length));
          }
        }

        final p = await sniffStream(chunks(), length: f.bytes.length);
        expectFixture(p, f);
      });

      test('the extension check agrees with the format', () {
        final p = sniffBytes(f.bytes);
        expect(p.extensionLies(f.name), isFalse);
        expect(p.extensionMatches(f.name), isTrue);
        final lie = f.format == AudioFormat.mp3 ? 'x.wav' : 'x.mp3';
        expect(p.extensionLies(lie), isTrue);
      });
    });
  }

  test('a stream without a length still identifies every fixture', () async {
    for (final f in corpus()) {
      final p = await sniffStream(Stream.value(f.bytes));
      expect(p.format, f.format, reason: f.name);
    }
  });

  test('sniffStream stops reading at maxBytes and cancels', () async {
    var cancelled = false;
    var emitted = 0;
    final controller =
        StreamController<List<int>>(onCancel: () => cancelled = true);
    controller.onListen = () async {
      final big = dawBroadcastWav().bytes;
      for (var i = 0; i < 1000 && !cancelled; i++) {
        emitted++;
        controller.add(i == 0 ? big : Uint8List(4096));
        await Future<void>.delayed(Duration.zero);
      }
      await controller.close();
    };
    final p = await sniffStream(controller.stream, maxBytes: 64 * 1024);
    expect(p.format, AudioFormat.wav);
    expect(cancelled, isTrue);
    expect(emitted, lessThan(1000));
  });
}
