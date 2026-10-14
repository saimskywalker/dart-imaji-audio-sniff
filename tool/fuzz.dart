// Long-running fuzz campaign over every parser.
//
//   dart run tool/fuzz.dart [--iterations N] [--seed S]
//
// Exits non-zero and prints the first failures (with their bytes) when any
// input throws, reads an unbounded amount, or makes the sync, random-access
// and async APIs disagree.

import 'dart:io';

import '../test/support/fuzz.dart';

Future<void> main(List<String> args) async {
  var iterations = 100000;
  var seed = DateTime.now().millisecondsSinceEpoch;
  for (var i = 0; i + 1 < args.length; i += 2) {
    switch (args[i]) {
      case '--iterations':
        iterations = int.parse(args[i + 1]);
      case '--seed':
        seed = int.parse(args[i + 1]);
    }
  }
  stdout.writeln('fuzzing $iterations inputs, seed $seed');
  final watch = Stopwatch()..start();
  final failures = await fuzz(iterations: iterations, seed: seed);
  stdout.writeln('done in ${watch.elapsed}, ${failures.length} failures');
  for (final f in failures.take(5)) {
    stdout.writeln('\n$f');
  }
  exitCode = failures.isEmpty ? 0 : 1;
}
