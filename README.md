# audio_sniff

> Status: **pre-alpha, not published.** Progress is tracked in the issues.

A file's extension is a claim; its bytes are the truth.

`audio_sniff` reads the bytes to tell WAV, FLAC and MP3 apart, and returns
exact durations straight from WAV and FLAC headers — no decoder, no plugin,
no platform channel. Pure Dart, zero dependencies.

## Why

Players pick their demuxer from the file extension. A WAV renamed `.mp3`
gets the MP3 extractor, which false-syncs on raw PCM, reports
`size / bitrate` as the duration and decodes silence: a six-minute song shown
as 46:26. `audio_sniff` catches that before the player meets the file.

## Planned API

```dart
final probe = AudioSniff.probeBytes(headerBytes, fileLength: length);

probe.container;        // AudioContainer.wav / flac / mp3 / unknown
probe.duration;         // exact for WAV and FLAC, from the header
probe.extensionLies('take_03.mp3'); // true when the name disagrees with the bytes
```

## Survives real-world files

- `bext` / `JUNK` / `LIST` chunks before `fmt `.
- RF64 / BW64 masters over 4 GiB (`ds64`).
- Writers that skip the RIFF pad byte after an odd-length chunk.
- `WAVE_FORMAT_EXTENSIBLE`.
- FLAC behind an ID3v2 tag.
- MPEG frame-sync checks strict enough to reject PCM that happens to
  contain `0xFFE`.

## License

MIT. See [LICENSE](LICENSE).
