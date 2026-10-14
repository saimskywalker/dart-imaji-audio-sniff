# Changelog

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
