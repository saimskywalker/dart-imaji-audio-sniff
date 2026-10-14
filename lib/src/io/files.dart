import 'dart:io';
import 'dart:typed_data';

import '../bytes.dart';
import '../sniff.dart';
import '../types.dart';

/// Identifies the audio file at [path], reading only the bytes the parsers
/// need (usually a few KiB, never more than a few MiB however the file is
/// built).
///
/// Throws a [FileSystemException] when the file cannot be opened: a missing
/// file is an I/O problem, not an unknown format. Once open, the bytes can
/// never cause an exception; unreadable regions are treated as the end of
/// the file.
Future<AudioProbe> sniffFile(String path) async {
  final file = await File(path).open();
  try {
    final length = await file.length();
    return await probeAsync((offset, count) async {
      try {
        await file.setPosition(offset);
        final data = await file.read(count);
        return (bytes: data, atEnd: data.length < count);
      } on FileSystemException {
        return (bytes: Uint8List(0), atEnd: true);
      }
    }, length);
  } finally {
    await file.close();
  }
}

/// Synchronous [sniffFile].
///
/// Prefer this inside Flutter widget tests: they run on a fake clock, and
/// asynchronous file I/O may never complete there.
AudioProbe sniffFileSync(String path) {
  final file = File(path).openSync();
  try {
    final length = file.lengthSync();
    return probeWith(ByteReader((offset, count) {
      try {
        file.setPositionSync(offset);
        return file.readSync(count);
      } on FileSystemException {
        return Uint8List(0);
      }
    }, length));
  } finally {
    file.closeSync();
  }
}
