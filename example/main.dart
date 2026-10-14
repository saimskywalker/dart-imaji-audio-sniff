// Identify audio files from their bytes and spot names that lie.
//
//   dart run example/main.dart song.mp3 take_03.wav ...
//
// With no arguments it builds a small WAV in memory, names it `.mp3`, and
// shows what a player choosing by extension would get wrong.

import 'dart:io';
import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff_io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _inMemoryDemo();
    return;
  }

  final aliases = PlaybackAliases.inSystemTemp();
  for (final path in args) {
    final probe = await sniffFile(path);
    stdout.writeln('$path: $probe');

    if (probe.extensionLies(path)) {
      stdout.writeln('  the name says .${extensionOf(path)}, '
          'the bytes say .${probe.format.extension}');
    }

    // Hand a player a path whose extension matches the bytes.
    final playable = await aliases.prepare(path, probe: probe);
    stdout.writeln('  play: ${playable.path} (${playable.outcome.name})');
    // ...after playback:
    await aliases.release(playable);
  }
}

void _inMemoryDemo() {
  // 2 seconds of 16-bit mono silence at 8 kHz, as a canonical WAV.
  const rate = 8000, frames = rate * 2;
  final header = ByteData(44)
    ..setUint32(0, 0x52494646) // RIFF
    ..setUint32(4, 36 + frames * 2, Endian.little)
    ..setUint32(8, 0x57415645) // WAVE
    ..setUint32(12, 0x666d7420) // 'fmt '
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461) // data
    ..setUint32(40, frames * 2, Endian.little);
  final bytes = Uint8List(44 + frames * 2)
    ..setAll(0, header.buffer.asUint8List());

  final probe = sniffBytes(bytes);
  stdout
    ..writeln('voice_memo.mp3 -> $probe')
    ..writeln('extension lies: ${probe.extensionLies('voice_memo.mp3')}')
    ..writeln('rename to:      voice_memo.${probe.format.extension}');
}
