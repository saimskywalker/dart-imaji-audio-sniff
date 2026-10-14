/// File helpers for `dart:io` platforms (Flutter on Android, iOS, macOS,
/// Windows and Linux; Dart servers and CLIs).
///
/// * [sniffFile] and [sniffFileSync] identify a file on disk, reading only
///   the bytes the parsers need.
/// * [PlaybackAliases] gives a mislabelled file a correctly named copy for
///   players that choose a demuxer from the extension.
///
/// Everything in `package:imaji_audio_sniff/imaji_audio_sniff.dart` is
/// re-exported, so one import is enough.
library;

import 'src/io/aliases.dart';
import 'src/io/files.dart';

export 'imaji_audio_sniff.dart';
export 'src/io/aliases.dart' show AliasOutcome, PlaybackAliases, PlaybackFile;
export 'src/io/files.dart' show sniffFile, sniffFileSync;
