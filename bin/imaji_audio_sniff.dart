import 'dart:io';

import 'package:imaji_audio_sniff/imaji_audio_sniff_io.dart';

/// Prints what each file's bytes say it is.
///
/// Exit code 0 when every name tells the truth, 1 when any extension lies,
/// 2 on a usage or I/O error.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    stdout.writeln('usage: imaji_audio_sniff <file> [<file> ...]');
    exitCode = args.isEmpty ? 2 : 0;
    return;
  }
  var lies = false;
  var failed = false;
  for (final path in args) {
    try {
      final probe = await sniffFile(path);
      final lie = probe.extensionLies(path);
      lies |= lie;
      final duration = probe.duration == null
          ? 'unknown'
          : '${probe.duration} (${probe.durationAccuracy!.name})';
      stdout.writeln('$path\n'
          '  format:   ${probe.format.name}${probe.codec == null ? '' : ' / ${probe.codec}'}\n'
          '  duration: $duration\n'
          '${lie ? '  WARNING:  the extension lies; this is a .${probe.format.extension} file\n' : ''}'
          '${probe.notes.isEmpty ? '' : '  notes:    ${probe.notes.map((n) => n.name).join(', ')}\n'}');
    } on FileSystemException catch (e) {
      failed = true;
      stderr.writeln('$path: ${e.message}');
    }
  }
  exitCode = failed ? 2 : (lies ? 1 : 0);
}
