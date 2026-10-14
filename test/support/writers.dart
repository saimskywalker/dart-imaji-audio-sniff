// Synthetic fixtures modelled on the layouts common audio writers produce.
//
// Each fixture reproduces the STRUCTURE (chunk order, metadata chunks,
// padding, size fields) that a family of tools is known to write, with
// generated noise in place of audio. Nothing here is a recording, and the
// sample payloads are kept short so the whole corpus builds in milliseconds.

import 'dart:typed_data';

import 'package:imaji_audio_sniff/imaji_audio_sniff.dart';

import 'build.dart';

/// A fixture plus what a correct probe must report.
class Fixture {
  Fixture(
    this.name,
    this.bytes, {
    required this.format,
    this.duration,
    this.accuracy = DurationAccuracy.exact,
    this.notes = const {},
    this.sampleRate,
    this.channels,
  });

  final String name;
  final Uint8List bytes;
  final AudioFormat format;
  final Duration? duration;
  final DurationAccuracy accuracy;
  final Set<ProbeNote> notes;
  final int? sampleRate;
  final int? channels;
}

Duration ms(int v) => Duration(milliseconds: v);

/// A Broadcast WAV the way a DAW records it: `bext` with an odd-length
/// coding history, an odd-length `iXML`, then vendor chunks, and only then
/// `fmt ` and `data`.
Fixture dawBroadcastWav() {
  const frames = 48000 ~/ 4; // 250 ms at 48 kHz
  final bext = Uint8List(602 + 37)..setAll(0, 'Synthetic take'.codeUnits);
  final ixml = Uint8List.fromList(
      '<?xml version="1.0"?><BWFXML><PROJECT>p</PROJECT></BWFXML>'.codeUnits);
  return Fixture(
    'daw-bwf-24bit.wav',
    wavFile([
      chunk('bext', bext),
      chunk('iXML', ixml),
      chunk('minf', Uint8List(16)),
      chunk('elm1', Uint8List(214)),
      chunk('umid', Uint8List(24)),
      chunk('fmt ', fmtBody(channels: 2, rate: 48000, bits: 24)),
      chunk('regn', Uint8List(92)),
      chunk('data', noise(frames * 6)),
    ]),
    format: AudioFormat.wav,
    duration: ms(250),
    sampleRate: 48000,
    channels: 2,
  );
}

/// A large `JUNK` reservation (room to upgrade to RF64 later) ahead of
/// `fmt `, and a filler chunk that aligns `data` to 4 KiB.
Fixture junkAlignedWav() {
  const frames = 44100 ~/ 2;
  final pre = concat([
    chunk('JUNK', Uint8List(28)),
    chunk('fmt ', fmtBody(channels: 2, rate: 44100, bits: 16)),
  ]);
  final fill = 4096 - (12 + pre.length + 8 + 8);
  return Fixture(
    'junk-fllr-aligned.wav',
    wavFile([
      pre,
      chunk('FLLR', Uint8List(fill)),
      chunk('data', noise(frames * 4))
    ]),
    format: AudioFormat.wav,
    duration: ms(500),
    sampleRate: 44100,
    channels: 2,
  );
}

/// 32-bit float in an 18-byte `fmt ` with `fact` and `PEAK`, followed by
/// `LIST`/INFO and an `id3 ` chunk after the audio.
Fixture floatWithTrailingTags() {
  const frames = 22050; // 500 ms at 44.1 kHz
  final info =
      concat(['INFO'.codeUnits, chunk('ISFT', 'Synthetic 1.0\x00'.codeUnits)]);
  return Fixture(
    'float32-fact-peak-list-id3.wav',
    wavFile([
      chunk('fmt ',
          fmtBody(tag: 3, channels: 1, rate: 44100, bits: 32, cbSize: 0)),
      chunk('fact', (Bytes()..u32le(frames)).bytes),
      chunk('PEAK', Uint8List(16)),
      chunk('data', noise(frames * 4)),
      chunk('LIST', info),
      chunk('id3 ', id3v2(bodySize: 63)),
    ]),
    format: AudioFormat.wav,
    duration: ms(500),
    sampleRate: 44100,
    channels: 1,
  );
}

/// The layout of a transcoder writing to a file: `fmt `, an odd-sized
/// `LIST`/INFO software tag (padded), then `data`.
Fixture transcoderWav() {
  final info =
      concat(['INFO'.codeUnits, chunk('ISFT', 'Lavf61.7.100\x00'.codeUnits)]);
  return Fixture(
    'transcoder-list-info.wav',
    wavFile([
      chunk('fmt ', fmtBody(channels: 2, rate: 44100, bits: 16)),
      chunk('LIST', info),
      chunk('data', noise(44100 * 4 ~/ 10)),
    ]),
    format: AudioFormat.wav,
    duration: ms(100),
  );
}

/// A transcoder writing to a pipe: it cannot seek back, so the RIFF and
/// `data` sizes stay 0xFFFFFFFF.
Fixture streamedWav() => Fixture(
      'streamed-unknown-size.wav',
      wavFile([
        chunk('fmt ', fmtBody(channels: 1, rate: 8000, bits: 16)),
        concat([
          (Bytes()
                ..ascii('data')
                ..u32le(0xFFFFFFFF))
              .bytes,
          noise(8000 * 2 * 3 ~/ 4),
        ]),
      ], riffSize: 0xFFFFFFFF),
      format: AudioFormat.wav,
      duration: ms(750),
      notes: {ProbeNote.unknownDataSize},
    );

/// RF64 with `ds64` first and every 32-bit size set to 0xFFFFFFFF.
Fixture rf64Wav({String magic = 'RF64'}) {
  const frames = 4800; // 100 ms at 48 kHz
  final data = noise(frames * 4);
  return Fixture(
    '${magic.toLowerCase()}-ds64.wav',
    wavFile([
      chunk('ds64',
          ds64Body(riffSize: 0, dataSize: data.length, sampleCount: frames)),
      chunk('fmt ', fmtBody(channels: 2, rate: 48000, bits: 16)),
      concat([
        (Bytes()
              ..ascii('data')
              ..u32le(0xFFFFFFFF))
            .bytes,
        data,
      ]),
    ], magic: magic, riffSize: 0xFFFFFFFF),
    format: AudioFormat.wav,
    duration: ms(100),
    notes: {ProbeNote.rf64},
  );
}

/// 24-bit stereo written as WAVE_FORMAT_EXTENSIBLE, the way command-line
/// converters write anything above 16 bits or two channels.
Fixture extensible24Wav() => Fixture(
      'extensible-24bit.wav',
      wavFile([
        chunk('fmt ',
            fmtBody(channels: 2, rate: 96000, bits: 24, extensible: true)),
        chunk('data', noise(96000 * 6 ~/ 5)),
      ]),
      format: AudioFormat.wav,
      duration: ms(200),
      notes: {ProbeNote.extensibleFormat},
      sampleRate: 96000,
      channels: 2,
    );

/// An odd-sized `LIST` chunk written WITHOUT its pad byte.
Fixture unpaddedWav() {
  final info = concat([
    'INFO'.codeUnits,
    chunk('INAM', 'Odd\x00'.codeUnits),
    [0x41]
  ]);
  return Fixture(
    'odd-chunk-no-pad.wav',
    wavFile([
      chunk('fmt ', fmtBody(channels: 1, rate: 16000, bits: 16)),
      chunk('LIST', info, pad: false),
      chunk('data', noise(16000 * 2 ~/ 4)),
    ]),
    format: AudioFormat.wav,
    duration: ms(250),
    notes: {ProbeNote.missingPadByte},
  );
}

/// A reference-encoder FLAC: STREAMINFO, a VORBIS_COMMENT, and a large
/// PADDING block.
Fixture encoderFlac() => Fixture(
      'encoder-padding.flac',
      flacFile(
        rate: 44100,
        totalSamples: 44100 * 3 + 22050,
        blocks: [
          flacBlock(
              4,
              concat([
                (Bytes()..u32le(11)).bytes,
                'synthetic 1'.codeUnits,
                [0, 0, 0, 0],
              ])),
          flacBlock(1, Uint8List(8192)),
        ],
      ),
      format: AudioFormat.flac,
      duration: ms(3500),
      sampleRate: 44100,
      channels: 2,
    );

/// A FLAC behind an ID3v2 tag, as some taggers leave it.
Fixture id3Flac() => Fixture(
      'id3-prefixed.flac',
      concat([
        id3v2(bodySize: 2048),
        flacFile(rate: 96000, totalSamples: 96000 * 2, bits: 24)
      ]),
      format: AudioFormat.flac,
      duration: ms(2000),
      notes: {ProbeNote.id3v2Tag},
      sampleRate: 96000,
    );

/// A VBR MP3: ID3v2, a Xing frame with a LAME tag, then audio frames.
Fixture lameVbrMp3() {
  const frames = 38; // ~992.65 ms at 44.1 kHz
  return Fixture(
    'lame-vbr-xing.mp3',
    concat([
      id3v2(bodySize: 4096, major: 4),
      mp3Frame(tag: 'Xing', tagFrames: frames),
      mp3Frames(frames),
    ]),
    format: AudioFormat.mp3,
    duration: Duration(microseconds: (frames * 1152 * 1000000 / 44100).round()),
    notes: {ProbeNote.id3v2Tag},
    sampleRate: 44100,
    channels: 2,
  );
}

/// A CBR MP3 from the same encoder: an `Info` frame instead of `Xing`.
Fixture lameCbrMp3() => Fixture(
      'lame-cbr-info.mp3',
      concat([mp3Frame(tag: 'Info', tagFrames: 100), mp3Frames(100)]),
      format: AudioFormat.mp3,
      duration: Duration(microseconds: (100 * 1152 * 1000000 / 44100).round()),
    );

/// An MPEG-2 MP3 with a Fraunhofer `VBRI` header.
Fixture vbriMp3() => Fixture(
      'vbri-mpeg2.mp3',
      concat([
        mp3Frame(version: 2, kbps: 64, rate: 22050, tag: 'VBRI', tagFrames: 50),
        mp3Frames(50, version: 2, kbps: 64, rate: 22050),
      ]),
      format: AudioFormat.mp3,
      duration: Duration(microseconds: (50 * 576 * 1000000 / 22050).round()),
      sampleRate: 22050,
    );

/// A bare CBR MP3 without any VBR header, with an ID3v1 tag at the end.
Fixture bareCbrMp3() {
  final audio = mp3Frames(80, kbps: 128);
  return Fixture(
    'bare-cbr-id3v1.mp3',
    concat([audio, id3v1()]),
    format: AudioFormat.mp3,
    duration: Duration(
      microseconds: (audio.length * 8 * 1000000 / 128000).round(),
    ),
    accuracy: DurationAccuracy.estimated,
  );
}

/// An uncompressed AIFF as a DAW bounces it: COMM, a MARK chunk, SSND.
Fixture dawAiff() => Fixture(
      'daw-bounce.aiff',
      aiffFile([
        ifChunk('COMM',
            commBody(channels: 2, frames: 48000, bits: 24, rate: 48000)),
        ifChunk('MARK', [0, 0]),
        ifChunk('SSND', ssndBody(48000 * 6)),
      ]),
      format: AudioFormat.aiff,
      duration: ms(1000),
      sampleRate: 48000,
      channels: 2,
    );

/// An AIFF-C with little-endian `sowt` samples and an FVER chunk, the
/// layout of the platform audio APIs on Apple systems.
Fixture sowtAifc() => Fixture(
      'sowt.aifc',
      aiffFile([
        ifChunk('FVER', (Bytes()..u32be(0xA2805140)).bytes),
        ifChunk(
            'COMM',
            commBody(
                frames: 11025,
                rate: 44100,
                compression: 'sowt',
                compressionName: 'Not compressed')),
        ifChunk('SSND', ssndBody(11025 * 4)),
      ], aifc: true),
      format: AudioFormat.aifc,
      duration: ms(250),
    );

/// An M4A with `moov` before `mdat` ("fast start").
Fixture fastStartM4a() => Fixture(
      'faststart-aac.m4a',
      concat([
        ftyp('M4A ', ['M4A ', 'mp42', 'isom']),
        box('moov', [
          mvhd(timescale: 1000, duration: 4321),
          soundTrak(frames: 44100 * 4321 ~/ 1000),
        ]),
        box('mdat', [noise(2048)]),
      ]),
      format: AudioFormat.m4a,
      duration: ms(4321),
      sampleRate: 44100,
      channels: 2,
    );

/// An M4A with `moov` after a large `mdat`, as a non-streaming muxer writes
/// it, plus a version-1 `mvhd` and an ALAC track.
Fixture moovAtEndAlac() => Fixture(
      'moov-at-end-alac.m4a',
      concat([
        ftyp('M4A '),
        box('free', [Uint8List(8)]),
        box('mdat', [noise(200 * 1024)]),
        box('moov', [
          mvhd(timescale: 44100, duration: 44100 * 7, version: 1),
          soundTrak(codec: 'alac', bits: 24, frames: 44100 * 7),
        ]),
      ]),
      format: AudioFormat.m4a,
      duration: ms(7000),
    );

/// A fragmented MP4: `mvhd` duration 0, the real one in `mvex/mehd`.
Fixture fragmentedMp4() => Fixture(
      'fragmented.mp4',
      concat([
        ftyp('iso6', ['iso6', 'dash']),
        box('moov', [
          mvhd(timescale: 48000, duration: 0),
          box('mvex', [
            box('mehd', [
              [0, 0, 0, 0],
              (Bytes()..u32be(48000 * 3)).bytes,
            ]),
          ]),
          soundTrak(rate: 48000, frames: 48000 * 3),
        ]),
        box('moof', [Uint8List(16)]),
        box('mdat', [noise(512)]),
      ]),
      format: AudioFormat.m4a,
      duration: ms(3000),
      notes: {ProbeNote.fragmented},
    );

/// Every fixture above.
List<Fixture> corpus() => [
      dawBroadcastWav(),
      junkAlignedWav(),
      floatWithTrailingTags(),
      transcoderWav(),
      streamedWav(),
      rf64Wav(),
      rf64Wav(magic: 'BW64'),
      extensible24Wav(),
      unpaddedWav(),
      encoderFlac(),
      id3Flac(),
      lameVbrMp3(),
      lameCbrMp3(),
      vbriMp3(),
      bareCbrMp3(),
      dawAiff(),
      sowtAifc(),
      fastStartM4a(),
      moovAtEndAlac(),
      fragmentedMp4(),
    ];
