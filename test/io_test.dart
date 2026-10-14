@TestOn('vm')
library;

import 'dart:io';

import 'package:imaji_audio_sniff/imaji_audio_sniff_io.dart';
import 'package:test/test.dart';

import 'support/build.dart';
import 'support/writers.dart';

void main() {
  late Directory tmp;
  late PlaybackAliases aliases;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('imaji_audio_sniff_test_');
    aliases = PlaybackAliases('${tmp.path}/aliases');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final f = File('${tmp.path}/$name')..writeAsBytesSync(bytes);
    return f.path;
  }

  group('sniffFile / sniffFileSync', () {
    for (final f in corpus()) {
      test(f.name, () async {
        final path = write(f.name, f.bytes);
        final a = await sniffFile(path);
        final s = sniffFileSync(path);
        expect(a.format, f.format);
        expect(a.duration, f.duration);
        expect(s.format, f.format);
        expect(s.duration, f.duration);
      });
    }

    test('a missing file throws FileSystemException', () {
      expect(() => sniffFile('${tmp.path}/nope.wav'),
          throwsA(isA<FileSystemException>()));
      expect(() => sniffFileSync('${tmp.path}/nope.wav'),
          throwsA(isA<FileSystemException>()));
    });

    test('an empty file is unknown', () async {
      final path = write('empty.mp3', const []);
      expect((await sniffFile(path)).format, AudioFormat.unknown);
      expect(sniffFileSync(path).format, AudioFormat.unknown);
    });
  });

  group('PlaybackAliases', () {
    test('a WAV named .mp3 gets a .wav copy', () async {
      final bytes = simpleWav();
      final path = write('take_03.mp3', bytes);
      final play = await aliases.prepare(path);
      expect(play.outcome, AliasOutcome.created);
      expect(play.isAlias, isTrue);
      expect(play.path, endsWith('.wav'));
      expect(play.path, startsWith(aliases.directoryPath));
      expect(File(play.path).readAsBytesSync(), bytes);
      expect(play.probe.format, AudioFormat.wav);

      expect(await aliases.release(play), isTrue);
      expect(File(play.path).existsSync(), isFalse);
      expect(File(path).existsSync(), isTrue,
          reason: 'the original is never touched');
      expect(await aliases.release(play), isFalse, reason: 'idempotent');
    });

    test('a file with no extension gets one', () async {
      final path = write('download', flacFile());
      final play = await aliases.prepare(path);
      expect(play.outcome, AliasOutcome.created);
      expect(play.path, endsWith('.flac'));
    });

    test('a display name is judged instead of the path', () async {
      final path = write('cache_1234', simpleWav());
      final play = await aliases.prepare(path, name: 'Song.wav');
      expect(play.outcome, AliasOutcome.notNeeded);
      expect(play.path, path);
    });

    test('a correctly named file is played as is', () async {
      final path = write('song.wav', simpleWav());
      final play = await aliases.prepare(path);
      expect(play.outcome, AliasOutcome.notNeeded);
      expect(play.path, path);
      expect(await aliases.release(play), isFalse);
      expect(File(path).existsSync(), isTrue);
    });

    test('unknown bytes are played as is', () async {
      final path = write('mystery.mp3', noise(2048));
      final play = await aliases.prepare(path);
      expect(play.outcome, AliasOutcome.unrecognised);
      expect(play.path, path);
    });

    test('a file over the ceiling is not copied', () async {
      final small = PlaybackAliases('${tmp.path}/small', maxBytes: 100);
      final path = write('big.mp3', simpleWav());
      final play = await small.prepare(path);
      expect(play.outcome, AliasOutcome.tooLarge);
      expect(Directory('${tmp.path}/small').existsSync(), isFalse);
    });

    test('a copy failure falls back to the original and leaves nothing',
        () async {
      final blocker = File('${tmp.path}/blocked')
        ..writeAsStringSync('not a dir');
      final broken = PlaybackAliases('${blocker.path}/aliases');
      final path = write('take.mp3', simpleWav());
      final play = await broken.prepare(path);
      expect(play.outcome, AliasOutcome.failed);
      expect(play.error, isNotNull);
      expect(play.path, path);
    });

    test('every alias name is fresh', () async {
      final path = write('take.mp3', simpleWav());
      final a = await aliases.prepare(path);
      final b = await aliases.prepare(path);
      expect(a.path, isNot(b.path));
    });

    group('refuses to delete anything it does not own', () {
      test('the original', () async {
        final path = write('take.mp3', simpleWav());
        expect(await aliases.releasePath(path), isFalse);
        expect(File(path).existsSync(), isTrue);
      });

      test('a look-alike name outside the directory', () async {
        final path = write('imaji-abc-0.wav', simpleWav());
        expect(aliases.owns(path), isFalse);
        expect(await aliases.releasePath(path), isFalse);
        expect(File(path).existsSync(), isTrue);
      });

      test('a user file inside the directory', () async {
        Directory(aliases.directoryPath).createSync(recursive: true);
        final user = File('${aliases.directoryPath}/song.wav')
          ..writeAsStringSync('x');
        expect(await aliases.releasePath(user.path), isFalse);
        expect(await aliases.clear(), 0);
        expect(user.existsSync(), isTrue);
      });

      test('a sub-directory of the alias directory', () async {
        final nested = Directory('${aliases.directoryPath}/album')
          ..createSync(recursive: true);
        final f = File('${nested.path}/imaji-abc-0.wav')
          ..writeAsStringSync('x');
        expect(await aliases.releasePath(f.path), isFalse);
        expect(f.existsSync(), isTrue);
      });

      test('a path that climbs out with ..', () async {
        final outside = write('imaji-abc-1.wav', simpleWav());
        final sneaky = '${aliases.directoryPath}/../imaji-abc-1.wav';
        expect(await aliases.releasePath(sneaky), isFalse);
        expect(File(outside).existsSync(), isTrue);
      });

      test('a symbolic link with an alias name', () async {
        Directory(aliases.directoryPath).createSync(recursive: true);
        final target = write('precious.wav', simpleWav());
        final link = Link('${aliases.directoryPath}/imaji-abc-2.wav')
          ..createSync(target);
        expect(await aliases.releasePath(link.path), isFalse);
        expect(File(target).existsSync(), isTrue);
      });
    });

    test('clear removes every alias, including a previous run\'s', () async {
      final path = write('take.mp3', simpleWav());
      await aliases.prepare(path);
      await aliases.prepare(path);
      final later = PlaybackAliases(aliases.directoryPath);
      expect(await later.clear(), 2);
      expect(Directory(aliases.directoryPath).listSync(), isEmpty);
      expect(await later.clear(), 0);
    });

    test('inSystemTemp uses a folder under the system temp directory', () {
      final a = PlaybackAliases.inSystemTemp(folderName: 'imaji_audio_sniff_x');
      expect(a.directoryPath, endsWith('imaji_audio_sniff_x'));
      expect(a.maxBytes, PlaybackAliases.defaultMaxBytes);
    });
  });
}
