// A small mutation fuzzer for the parsers. Shared by test/fuzz_test.dart
// (a bounded run on every CI build) and tool/fuzz.dart (long runs).

import 'dart:math';
import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';

import 'build.dart';
import 'writers.dart';

/// Upper bound on what one probe may read, whatever the input claims.
const int maxBytesPerProbe = 2 * 1024 * 1024;

/// What went wrong on one input.
class FuzzFailure {
  FuzzFailure(this.iteration, this.input, this.problem);

  final int iteration;
  final Uint8List input;
  final String problem;

  @override
  String toString() =>
      'iteration $iteration (${input.length} bytes): $problem\n'
      'first bytes: ${input.take(48).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}';
}

/// Seeds: every corpus fixture plus a few bare magic numbers.
List<Uint8List> seeds() => [
      for (final f in corpus()) f.bytes,
      simpleWav(frames: 64),
      flacFile(),
      mp3Frames(3),
      Uint8List.fromList('RIFF\x00\x00\x00\x00WAVE'.codeUnits),
      Uint8List.fromList('FORM\x00\x00\x00\x00AIFC'.codeUnits),
      Uint8List.fromList('ID3\x04\x00\x00\x00\x00\x00\x00'.codeUnits),
    ];

const _interesting = [0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF];

/// One mutated copy of [seed].
Uint8List mutate(Uint8List seed, Random rng) {
  final b = List<int>.of(seed);
  final rounds = 1 + rng.nextInt(8);
  for (var r = 0; r < rounds; r++) {
    if (b.isEmpty) b.add(rng.nextInt(256));
    final at = rng.nextInt(b.length);
    switch (rng.nextInt(8)) {
      case 0: // flip a bit
        b[at] ^= 1 << rng.nextInt(8);
      case 1: // interesting byte
        b[at] = _interesting[rng.nextInt(_interesting.length)];
      case 2: // random 32-bit value (a size field, often)
        for (var i = 0; i < 4 && at + i < b.length; i++) {
          b[at + i] = rng.nextInt(256);
        }
      case 3: // all-ones 32-bit value
        for (var i = 0; i < 4 && at + i < b.length; i++) {
          b[at + i] = 0xFF;
        }
      case 4: // truncate
        b.length = at;
      case 5: // delete a run
        b.removeRange(at, min(b.length, at + 1 + rng.nextInt(16)));
      case 6: // insert a run
        b.insertAll(
            at, List.generate(1 + rng.nextInt(16), (_) => rng.nextInt(256)));
      default: // duplicate a slice
        final len = min(b.length - at, 1 + rng.nextInt(64));
        b.insertAll(rng.nextInt(b.length), b.sublist(at, at + len));
    }
  }
  return Uint8List.fromList(b);
}

/// Runs [iterations] inputs from [seed]; returns every failure found.
Future<List<FuzzFailure>> fuzz(
    {required int iterations, int seed = 20261014}) async {
  final rng = Random(seed);
  final pool = seeds();
  final failures = <FuzzFailure>[];
  for (var i = 0; i < iterations; i++) {
    final input = i % 10 == 9
        ? Uint8List.fromList(
            List.generate(rng.nextInt(2048), (_) => rng.nextInt(256)))
        : mutate(pool[rng.nextInt(pool.length)], rng);
    // Sometimes claim the file is much larger than the bytes we have.
    final claimed = rng.nextInt(4) == 0
        ? input.length + rng.nextInt(1 << 30)
        : input.length;
    try {
      final sync = sniffBytes(input, fileLength: claimed);
      var read = 0;
      var calls = 0;
      final viaReader = sniffReaderSync((offset, length) {
        calls++;
        if (offset >= input.length) return const <int>[];
        final end = min(input.length, offset + length);
        read += end - offset;
        return input.sublist(offset, end);
      }, length: claimed);
      final viaAsync = await sniffReader((offset, length) async {
        if (offset >= input.length) return const <int>[];
        return input.sublist(offset, min(input.length, offset + length));
      }, length: claimed);
      if (read > maxBytesPerProbe || calls > 4096) {
        failures.add(FuzzFailure(
            i, input, 'unbounded reads: $read bytes in $calls calls'));
      }
      if (viaReader.format != sync.format ||
          viaReader.duration != sync.duration) {
        failures.add(
            FuzzFailure(i, input, 'reader disagrees: $viaReader vs $sync'));
      }
      if (viaAsync.format != sync.format ||
          viaAsync.duration != sync.duration) {
        failures
            .add(FuzzFailure(i, input, 'async disagrees: $viaAsync vs $sync'));
      }
      final d = sync.duration;
      if (d != null && (d.isNegative || (sync.durationAccuracy == null))) {
        failures.add(FuzzFailure(i, input, 'bad duration: $sync'));
      }
    } on Object catch (e, st) {
      failures.add(FuzzFailure(i, input, 'threw $e\n$st'));
    }
  }
  return failures;
}
