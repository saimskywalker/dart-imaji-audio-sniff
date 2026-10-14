import 'dart:io';
import 'dart:math';

import '../types.dart';
import 'files.dart';

/// What [PlaybackAliases.prepare] did.
enum AliasOutcome {
  /// The name already leads a player to the right demuxer; play the
  /// original.
  notNeeded,

  /// A correctly named copy was made; play [PlaybackFile.path] and release
  /// it afterwards.
  created,

  /// The bytes match no supported format, so there is no better name to
  /// give it; play the original.
  unrecognised,

  /// The file is larger than [PlaybackAliases.maxBytes]; play the original.
  tooLarge,

  /// Copying failed (for example, the disk is full); play the original.
  failed,
}

/// The path to hand a player, and whether it is a copy owned by
/// [PlaybackAliases].
final class PlaybackFile {
  /// Creates a result. Normally produced by [PlaybackAliases.prepare].
  const PlaybackFile({
    required this.path,
    required this.originalPath,
    required this.outcome,
    required this.probe,
    this.error,
  });

  /// The path to load into the player.
  final String path;

  /// The file the caller asked about. Never modified or deleted.
  final String originalPath;

  /// What happened.
  final AliasOutcome outcome;

  /// What the bytes are.
  final AudioProbe probe;

  /// The error behind [AliasOutcome.failed], for logging.
  final Object? error;

  /// Whether [path] is a copy that should be released after playback.
  bool get isAlias => outcome == AliasOutcome.created;
}

/// Correctly named copies of mislabelled audio files, for players that pick
/// a demuxer from the file extension (ExoPlayer and AVPlayer both do, and
/// `just_audio` offers no way to override it for a local file).
///
/// A WAV named `.mp3` handed to such a player is decoded as MP3: a wrong
/// duration and silence. [prepare] copies it into a directory this object
/// owns, under the extension its bytes call for, and returns that path.
///
/// Safety rules:
///
/// * The original file is only ever read.
/// * [release] and [clear] delete only regular files that sit directly in
///   [directoryPath] and carry this helper's own name pattern. Any other
///   path is refused, so a caller bug cannot delete a user's file.
/// * Copies are bounded by [maxBytes], because Dart cannot ask how much free
///   space a device has.
/// * A copy rather than a symbolic link: whether a platform player resolves
///   a link before inferring the type is not something a test can promise.
final class PlaybackAliases {
  /// Uses [directoryPath], which should be dedicated to this helper (for
  /// example a sub-directory of the app's temporary directory). It is
  /// created on first use.
  PlaybackAliases(String directoryPath, {this.maxBytes = defaultMaxBytes})
      : directoryPath = _canonical(directoryPath);

  /// Uses a sub-directory named [folderName] of [Directory.systemTemp]. In a
  /// Flutter app, prefer a folder under `getTemporaryDirectory()` from
  /// `path_provider`.
  factory PlaybackAliases.inSystemTemp({
    String folderName = 'imaji_audio_sniff_playback',
    int maxBytes = defaultMaxBytes,
  }) {
    final sep = Platform.pathSeparator;
    return PlaybackAliases('${Directory.systemTemp.path}$sep$folderName',
        maxBytes: maxBytes);
  }

  /// Default ceiling on the size of a copy: 512 MiB.
  static const int defaultMaxBytes = 512 * 1024 * 1024;

  static final RegExp _ownName = RegExp(r'^imaji-[0-9a-z]+-[0-9]+\.[a-z0-9]+$');

  /// The directory copies are written to, as an absolute normalised path.
  final String directoryPath;

  /// Files larger than this are never copied.
  final int maxBytes;

  final String _run = Random.secure().nextInt(0x7FFFFFFF).toRadixString(36) +
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  int _sequence = 0;

  /// Decides what to play for the file at [path].
  ///
  /// [name] is the name to judge, when it differs from the path (a display
  /// name from a document picker, say); it defaults to [path]. Pass [probe]
  /// if the file was already sniffed.
  ///
  /// Never throws for a file that cannot be copied: every failure returns
  /// the original path with an [AliasOutcome] saying why. A file that cannot
  /// be read at all still throws the [FileSystemException] from sniffing,
  /// unless [probe] was given.
  Future<PlaybackFile> prepare(String path,
      {String? name, AudioProbe? probe}) async {
    final found = probe ?? await sniffFile(path);
    PlaybackFile keep(AliasOutcome outcome, [Object? error]) => PlaybackFile(
          path: path,
          originalPath: path,
          outcome: outcome,
          probe: found,
          error: error,
        );

    if (!found.isKnown) return keep(AliasOutcome.unrecognised);
    if (found.extensionMatches(name ?? path)) {
      return keep(AliasOutcome.notNeeded);
    }
    String? target;
    try {
      if (await File(path).length() > maxBytes) {
        return keep(AliasOutcome.tooLarge);
      }
      await Directory(directoryPath).create(recursive: true);
      target = '$directoryPath${Platform.pathSeparator}'
          'imaji-$_run-${_sequence++}.${found.format.extension}';
      await File(path).copy(target);
      return PlaybackFile(
        path: target,
        originalPath: path,
        outcome: AliasOutcome.created,
        probe: found,
      );
    } on Object catch (error) {
      if (target != null) await releasePath(target);
      return keep(AliasOutcome.failed, error);
    }
  }

  /// Deletes the copy behind [file], if [file] is one. Safe to call twice.
  Future<bool> release(PlaybackFile file) async =>
      file.isAlias && await releasePath(file.path);

  /// Deletes [path] if, and only if, it is a copy this helper could have
  /// made: a regular file directly inside [directoryPath] with this helper's
  /// name pattern. Returns whether a file was deleted.
  Future<bool> releasePath(String path) async {
    if (!owns(path)) return false;
    try {
      await File(path).delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Whether [path] names a file [releasePath] would agree to delete.
  bool owns(String path) {
    final canonical = _canonical(path);
    final cut = canonical.lastIndexOf(Platform.pathSeparator);
    if (cut <= 0) return false;
    if (canonical.substring(0, cut) != directoryPath) return false;
    if (!_ownName.hasMatch(canonical.substring(cut + 1))) return false;
    return FileSystemEntity.typeSync(canonical, followLinks: false) ==
        FileSystemEntityType.file;
  }

  /// Deletes every copy in [directoryPath], including those left by an
  /// earlier run that crashed. Other files in the directory are left alone.
  Future<int> clear() async {
    final dir = Directory(directoryPath);
    var removed = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && await releasePath(entity.path)) removed++;
      }
    } on FileSystemException {
      // Best effort: the operating system reclaims temporary files too.
    }
    return removed;
  }

  static String _canonical(String path) {
    var p = File(path).absolute.uri.normalizePath().toFilePath();
    final sep = Platform.pathSeparator;
    while (p.length > 1 && p.endsWith(sep)) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
