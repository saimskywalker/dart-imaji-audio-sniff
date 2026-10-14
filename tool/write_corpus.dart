// Writes the synthetic fixture corpus to a directory, for trying real
// players against it (for example: rename a WAV to .mp3 and play it).
//
//   dart run tool/write_corpus.dart [out_dir]

import 'dart:io';

import '../test/support/writers.dart';

void main(List<String> args) {
  final out = Directory(args.isEmpty ? 'build/corpus' : args.first)
    ..createSync(recursive: true);
  for (final f in corpus()) {
    File('${out.path}/${f.name}').writeAsBytesSync(f.bytes);
    stdout.writeln(
        '${f.name.padRight(36)} ${f.bytes.length.toString().padLeft(8)} bytes'
        '  ${f.format.name}  ${f.duration ?? 'no duration'}');
  }
}
