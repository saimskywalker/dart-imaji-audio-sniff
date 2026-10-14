# imaji_audio_sniff — real audio format and duration from the bytes, for Dart & Flutter

[![CI](https://github.com/saimskywalker/dart-imaji-audio-sniff/actions/workflows/ci.yml/badge.svg)](https://github.com/saimskywalker/dart-imaji-audio-sniff/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**The extension is a claim; the bytes are the truth.**

Pure Dart, zero dependencies, works in Flutter (Android, iOS, macOS, Windows,
Linux, web), on Dart servers and in CLIs.

## The symptom

Your Flutter app plays a local audio file and:

- the **duration is wildly wrong** (a six-minute song shows as 46:26), and
- it **plays silence**, or fails with a decoder error,

while the same file plays fine on a desktop. The file is usually a **WAV,
FLAC or M4A wearing an `.mp3` name** (or no extension at all): renamed by a
user, a chat app, a download manager or a content provider.

Why: [`just_audio`](https://pub.dev/packages/just_audio), ExoPlayer/Media3
on Android and AVPlayer on iOS/macOS **pick the demuxer from the file
extension**. A WAV named `.mp3` goes to the MP3 extractor, which "finds"
frame syncs inside raw PCM, estimates `size ÷ bitrate` as the duration, and
decodes nothing. `ffmpeg` and most servers sniff the bytes instead, so the
bug only shows up on the device.

`imaji_audio_sniff` reads a few KiB of the file, tells you what it really
is, gives you the exact duration from the header, and can hand the player a
correctly named copy.

## Quick start (30 seconds)

```sh
dart pub add imaji_audio_sniff     # or: flutter pub add imaji_audio_sniff
```

```dart
import 'package:imaji_audio_sniff/imaji_audio_sniff_io.dart';

final probe = await sniffFile('/path/to/take_03.mp3');

probe.format;                       // AudioFormat.wav
probe.duration;                     // 0:06:00.000000, from the header
probe.isDurationExact;              // true
probe.extensionLies('take_03.mp3'); // true: it is really a .wav
```

Bytes you already hold (works on the web too):

```dart
import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';

final probe = sniffBytes(firstBytes, fileLength: totalSize);
```

### Fix playback in Flutter with just_audio

```dart
import 'package:imaji_audio_sniff/imaji_audio_sniff_io.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

final aliases = PlaybackAliases(
  '${(await getTemporaryDirectory()).path}/imaji_audio_sniff',
);
await aliases.clear(); // once at startup: removes copies a crash left behind

final playable = await aliases.prepare(pickedPath, name: pickedDisplayName);
await player.setFilePath(playable.path);
// Prefer the header's duration; fall back to the player's.
final duration = playable.probe.duration ?? player.duration;
// ...when done with this track:
await aliases.release(playable);
```

`prepare` copies only when the name would mislead the player (wrong or
missing extension), never touches the original, refuses to delete anything
outside its own directory, and caps the copy size (512 MiB by default).

## API

Two libraries:

| Import | Use it for |
|---|---|
| `package:imaji_audio_sniff/imaji_audio_sniff.dart` | Pure Dart, every platform including the web. |
| `package:imaji_audio_sniff/imaji_audio_sniff_io.dart` | Adds file helpers; re-exports everything above. |

**Sniffing.** Every function returns an `AudioProbe` and never throws on bad
input (unknown bytes give `AudioFormat.unknown`):

| Function | Source |
|---|---|
| `sniffBytes(bytes, {fileLength})` | Bytes in memory: the whole file, or its start plus its real size. |
| `sniffReaderSync(readAt, {length})` | Your own synchronous random access. |
| `sniffReader(readAt, {length})` | Asynchronous random access, e.g. HTTP range requests. |
| `sniffStream(stream, {length, maxBytes})` | A forward-only stream; stops after `maxBytes` (1 MiB) and cancels it. |
| `sniffFile(path)` / `sniffFileSync(path)` | A file on disk (`dart:io`). Use the sync one in widget tests. |

Reads are bounded: a probe reads a few KiB for most files and never more than
a few MiB, whatever the file claims about itself.

**`AudioProbe`**

| Member | Meaning |
|---|---|
| `format` | `AudioFormat.wav`, `flac`, `mp3`, `aiff`, `aifc`, `m4a` or `unknown`. |
| `duration` | From the header, or `null` when the header cannot say. |
| `durationAccuracy` | `exact` (header counts) or `estimated` (CBR MP3 bitrate, compressed WAV byte rate). |
| `sampleRate`, `channels`, `bitsPerSample`, `codec` | When the header states them. |
| `audioOffset` | Where the audio payload starts. |
| `notes` | `ProbeNote`s: `id3v2Tag`, `rf64`, `extensibleFormat`, `missingPadByte`, `unknownDataSize`, `truncated`, `fragmented`. |
| `extensionLies(name)` | The name has an extension and it contradicts the bytes. |
| `extensionMatches(name)` | The name's extension leads a player to the right demuxer (false when there is none). |

**`AudioFormat`** carries `extension` (`'wav'`), `mimeType` (`'audio/wav'`)
and `extensions`: every name a player maps to the same demuxer, so an `.mp4`
holding AAC is not a lie.

**`extensionOf(nameOrPath)`** returns the lowercase extension, ignoring
folders, dotfiles and URL query strings.

**`PlaybackAliases`** offers `prepare`, `release`, `releasePath`, `owns` and
`clear`; `prepare` reports an `AliasOutcome` (`notNeeded`, `created`,
`unrecognised`, `tooLarge`, `failed`).

There is also a command-line tool:

```sh
dart pub global activate imaji_audio_sniff
imaji_audio_sniff ~/Downloads/*.mp3     # exit code 1 if any extension lies
```

## Supported formats and edge cases

| Format | Detected by | Duration from | Edge cases handled |
|---|---|---|---|
| WAV | `RIFF`/`RF64`/`BW64` + `WAVE` | `data` size ÷ block align ÷ rate (`fact` for compressed audio) | `bext`, `iXML`, `JUNK`, `LIST`, `FLLR` … before `fmt `; `data` before `fmt `; odd-sized chunks **with and without** the pad byte; RF64/BW64 `ds64` sizes beyond 4 GiB; `WAVE_FORMAT_EXTENSIBLE`; PCM, float, A-law, µ-law; size 0 / 0xFFFFFFFF from streamed writers; truncated copies; wrong byte-rate fields |
| FLAC | `fLaC` | STREAMINFO total samples ÷ rate | ID3v2 tag(s) in front; total samples 0 = unknown (never zero); full 36-bit sample counts |
| MP3 | ID3v2 and/or a Layer III frame header confirmed by the next frame | Xing/Info or VBRI frame count | Strict sync rejects PCM and 0xFF runs; MPEG-1/2/2.5; CRC-protected frames; padding after the tag; CBR estimate (flagged) that excludes ID3v1 and APEv2 tags |
| AIFF / AIFF-C | `FORM` + `AIFF`/`AIFC` | `COMM` frames ÷ 80-bit extended rate | `sowt`, `fl32`, `ima4` …; `SSND` offset; truncated sound data |
| M4A / MP4 / MOV | `ftyp` (image brands excluded) or a leading `moov` | `mvhd` duration ÷ timescale | `moov` at the end; 64-bit box sizes; size-0 boxes; fragmented files via `mehd`; AAC/ALAC codec, rate and channels from the sample entry |

Not supported yet (reported as `unknown`): Ogg (Vorbis, Opus, Ogg FLAC), raw
AAC (ADTS), WMA, CAF, MP1/MP2. Pull requests welcome.

## FAQ

**Does it decode audio?** No. It reads headers only: no decoder, no plugin,
no platform channel. That is why it is fast and works everywhere.

**How many bytes does it read?** For most files a few KiB. A WAV with large
metadata chunks or an M4A with `moov` at the end needs a few seeks. Reads are
capped per probe no matter what the file claims.

**Why `null` instead of a duration?** When the header cannot say for certain
(FLAC with total samples 0, a WAV whose `data` size was never written and no
file length is known), any number would be a guess. Fall back to the
player's figure.

**Is an MP3 duration exact?** With a Xing/Info or VBRI header, yes (frame
count × samples per frame). Without one it is a bitrate estimate and
`durationAccuracy` says `estimated`; that estimate is wrong for VBR files
that lack a header, which is exactly why it is flagged.

**Should I rename the user's file?** Usually not. Use `PlaybackAliases` to
give the player a correctly named copy and keep the original intact. When
uploading, label the bytes with `probe.format.mimeType` instead of trusting
the name.

**Flutter widget tests hang on `sniffFile`.** Widget tests run on a fake
clock where real asynchronous I/O may never complete. Use `sniffFileSync`
there.

**Does it work on the web?** The core library does; its 64-bit arithmetic is
written to be exact in JavaScript, and CI runs the tests in Chrome. The file
helpers need `dart:io`; on the web, call `sniffBytes` or `sniffStream` on the
picked file's bytes.

## How it compares

Tag-reading packages (for example `audio_metadata_reader`, `metadata_god`,
`flutter_media_metadata`) are about **tags**: title, album, performer, cover
art. Some need a native plugin, and none of them is meant to answer "is this
`.mp3` really an MP3?". Player plugins (`just_audio`, `audioplayers`) report
a duration only after loading, from whichever demuxer the extension picked,
which is exactly the number that is wrong here. MIME-sniffing packages map
magic numbers to a type; they do not read durations, and a check of the
MPEG sync word alone is easy to fool with PCM, which is full of `0xFF` bytes.

`imaji_audio_sniff` does one thing: **format and duration from the bytes**,
in pure Dart, with no plugin and no decoding. Use it alongside any of the
above.

## Support

If this saved you a debugging session, a ⭐ on
[GitHub](https://github.com/saimskywalker/dart-imaji-audio-sniff) helps other
Dart & Flutter developers find it.

## License

MIT © saimskywalker. See [LICENSE](LICENSE).
