# Changelog

## 0.1.1

Documentation only; no change in behaviour.

- README: pub.dev version and pub points badges, and the `^0.1.0`
  constraint `dart pub add` writes.
- README: compressed AIFF-C (`ima4`) is no longer listed as handled. It is
  detected, but its duration is 64 times too short because `COMM` counts
  packets for it ([#22](https://github.com/saimskywalker/dart-imaji-audio-sniff/issues/22)).
- README and API docs: an MP3 or AAC duration marked `exact` still includes
  the encoder's delay and padding; `estimated` covers any MP3 without a
  Xing/Info/VBRI header; `sniffFile` and `sniffFileSync` throw
  `FileSystemException` when the file cannot be opened; an ID3v2 tag alone
  identifies an MP3 only when nothing after it can be read; `audioOffset` is
  not reported for M4A; the CLI exits with 2 on an unreadable file.
- README: the "not supported yet" list now also names AMR, WebM/Matroska and
  Ogg Speex.
- API docs: `AudioProbe.codec` lists the names it really returns (a WAV
  format tag 0x0055 is `mp3`, not `0x0055`; M4A gives `mp4a` or `alac`).

## 0.1.0

First release.

- Container detection from bytes: WAV (RIFF, RF64, BW64), FLAC (including
  behind ID3v2 tags), MP3 (MPEG-1/2/2.5 Layer III with a strict frame sync
  that rejects raw PCM), AIFF, AIFF-C and the MP4 family (M4A, M4B, MP4, MOV,
  3GP).
- Exact durations from headers:
  - WAV: walks the chunk list (metadata before `fmt `, `data` before
    `fmt `, odd-sized chunks with and without the pad byte, `ds64` 64-bit
    sizes, `WAVE_FORMAT_EXTENSIBLE`, `fact` for compressed audio, streamed
    and truncated files).
  - FLAC: STREAMINFO total samples and sample rate; a total of 0 is
    reported as unknown, never as zero.
  - MP3: Xing/Info and VBRI frame counts; a constant-bit-rate estimate,
    flagged as `DurationAccuracy.estimated`, only when neither exists.
  - AIFF/AIFF-C: `COMM` frames over the 80-bit extended sample rate.
  - M4A/MP4: `mvhd`, with `mvex/mehd` for fragmented files.
- `AudioProbe.extensionLies` and `extensionMatches`, plus `extensionOf`.
- Synchronous (`sniffBytes`, `sniffReaderSync`), asynchronous random-access
  (`sniffReader`) and streamed (`sniffStream`) APIs, all with bounded reads.
- `dart:io` helpers: `sniffFile`, `sniffFileSync` and `PlaybackAliases`, which
  gives a mislabelled file a correctly named copy for players that choose a
  demuxer by extension.
- A command-line tool: `dart pub global activate imaji_audio_sniff`, then
  `imaji_audio_sniff <file>...`.
