/// An audio container, identified from the bytes rather than from a name.
enum AudioFormat {
  /// RIFF/WAVE, including RF64 and BW64 (EBU Tech 3306, ITU-R BS.2088).
  wav('wav', 'audio/wav', {'wav', 'wave', 'bwf', 'rf64', 'bw64'}),

  /// Native FLAC (`fLaC`), with or without a leading ID3v2 tag.
  flac('flac', 'audio/flac', {'flac'}),

  /// MPEG-1, MPEG-2 or MPEG-2.5 Audio Layer III.
  mp3('mp3', 'audio/mpeg', {'mp3'}),

  /// Uncompressed AIFF (`FORM` ... `AIFF`).
  aiff('aiff', 'audio/aiff', {'aiff', 'aif', 'aifc'}),

  /// AIFF-C (`FORM` ... `AIFC`), compressed or not.
  aifc('aifc', 'audio/aiff', {'aifc', 'aif', 'aiff'}),

  /// The ISO base media file format family: M4A, M4B, MP4, MOV, 3GP.
  ///
  /// Every name in this family is opened by the same demuxer, so an `.mp4`
  /// holding AAC or ALAC is not a lie. A file with a video track is reported
  /// here too.
  m4a('m4a', 'audio/mp4',
      {'m4a', 'm4b', 'm4p', 'm4r', 'mp4', 'mov', '3gp', '3g2'}),

  /// The bytes match none of the formats above.
  unknown('', 'application/octet-stream', {});

  const AudioFormat(this.extension, this.mimeType, this.extensions);

  /// The extension this format should carry, without a dot. Empty for
  /// [unknown].
  final String extension;

  /// The media type to label these bytes with.
  final String mimeType;

  /// Every lowercase extension a player maps to the right demuxer for this
  /// format. A name carrying any of them tells the truth.
  final Set<String> extensions;
}

/// How far a [AudioProbe.duration] can be trusted.
enum DurationAccuracy {
  /// Computed from counts the file's own header declares: WAV sample frames,
  /// FLAC total samples, an MP3 Xing/Info/VBRI frame count, AIFF frames or
  /// the MP4 movie header.
  ///
  /// Exact to what the header counts, which for MP3 (and for an AAC M4A
  /// whose movie header includes its priming samples) still includes the
  /// encoder's delay and padding: a few tens of milliseconds more than the
  /// audio itself.
  exact,

  /// Derived from a byte rate: a constant-bit-rate MP3 without a VBR header,
  /// or a compressed WAV without a `fact` chunk. Wrong if the stream is
  /// variable bit rate.
  estimated,
}

/// Something worth knowing about how a file was read.
enum ProbeNote {
  /// One or more ID3v2 tags precede the audio.
  id3v2Tag,

  /// RF64/BW64 file whose 64-bit sizes came from the `ds64` chunk.
  rf64,

  /// `WAVE_FORMAT_EXTENSIBLE` resolved through its SubFormat GUID.
  extensibleFormat,

  /// The writer skipped the pad byte after an odd-sized RIFF/IFF chunk.
  missingPadByte,

  /// The header did not record the audio size (a streamed or interrupted
  /// write); the size was taken from the file length instead.
  unknownDataSize,

  /// The header declares more audio than the file holds; the duration covers
  /// only the audio actually present.
  truncated,

  /// A fragmented MP4 whose duration came from the `mehd` box.
  fragmented,
}

/// The lowercase extension of [nameOrPath] without the dot, or null when it
/// has none.
///
/// Directory segments (`/` and `\`) are ignored, so a dot in a folder name is
/// never mistaken for an extension, and a leading dot (`.wav`) names a hidden
/// file rather than an extension. A URL with a scheme is reduced to its path,
/// so a query string such as `?token=...` is ignored.
String? extensionOf(String nameOrPath) {
  var name = nameOrPath;
  if (name.contains('://')) {
    final uri = Uri.tryParse(name);
    if (uri != null) name = uri.path;
  }
  final slash = name.lastIndexOf(RegExp(r'[\\/]'));
  if (slash >= 0) name = name.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// What a file's bytes say it is.
///
/// Produced by `sniffBytes`, `sniffStream`, `sniffReader` and the file
/// helpers. A probe never throws: input it cannot understand produces
/// [AudioFormat.unknown].
final class AudioProbe {
  /// Creates a probe result. Normally produced by the sniffing functions.
  const AudioProbe({
    required this.format,
    this.duration,
    this.durationAccuracy,
    this.sampleRate,
    this.channels,
    this.bitsPerSample,
    this.codec,
    this.audioOffset,
    this.notes = const {},
  });

  /// The result for bytes that match no supported format.
  static const AudioProbe unknown = AudioProbe(format: AudioFormat.unknown);

  /// The container the bytes are.
  final AudioFormat format;

  /// Playing time read from the header, or null when the header cannot say
  /// for certain. Never a guess dressed up as a fact: see [durationAccuracy].
  final Duration? duration;

  /// How [duration] was obtained; null exactly when [duration] is null.
  final DurationAccuracy? durationAccuracy;

  /// Samples per second, when the header states it.
  final int? sampleRate;

  /// Channel count, when the header states it.
  final int? channels;

  /// Bits per sample, when meaningful for the codec.
  final int? bitsPerSample;

  /// A short codec name: `flac` or `mp3`; for WAV, `pcm`, `float`, `alaw`,
  /// `mulaw`, `adpcm-ms`, `adpcm-ima`, `mpeg` or `mp3`, and any other format
  /// tag in hex (such as `0x0161`); for AIFF, `pcm` or the AIFF-C
  /// compression type (such as `sowt`); for M4A, the sample entry type
  /// (such as `mp4a` or `alac`).
  final String? codec;

  /// Byte offset where the audio payload starts, when known.
  final int? audioOffset;

  /// Facts about how the file was read.
  final Set<ProbeNote> notes;

  /// Whether the bytes matched a supported format.
  bool get isKnown => format != AudioFormat.unknown;

  /// Whether [duration] is an exact header value.
  bool get isDurationExact => durationAccuracy == DurationAccuracy.exact;

  /// True when [nameOrPath] carries an extension and that extension disagrees
  /// with the bytes: a WAV named `.mp3`.
  ///
  /// False when the bytes are unknown (there is nothing to contradict) or the
  /// name has no extension (it claims nothing). For "will a player that picks
  /// its demuxer from the name get this right?", use [extensionMatches].
  bool extensionLies(String nameOrPath) {
    if (!isKnown) return false;
    final ext = extensionOf(nameOrPath);
    return ext != null && !format.extensions.contains(ext);
  }

  /// True when [nameOrPath] ends in an extension that leads a player to the
  /// right demuxer for these bytes.
  ///
  /// Wider than `!extensionLies(...)`: a name with no extension does not lie,
  /// but it does not match either, and a player choosing by extension handles
  /// it just as badly.
  bool extensionMatches(String nameOrPath) {
    final ext = extensionOf(nameOrPath);
    return ext != null && format.extensions.contains(ext);
  }

  @override
  String toString() {
    final parts = <String>['format: ${format.name}'];
    if (duration != null) {
      parts.add('duration: $duration (${durationAccuracy!.name})');
    }
    if (codec != null) parts.add('codec: $codec');
    if (sampleRate != null) parts.add('sampleRate: $sampleRate');
    if (channels != null) parts.add('channels: $channels');
    if (bitsPerSample != null) parts.add('bitsPerSample: $bitsPerSample');
    if (notes.isNotEmpty) {
      parts.add('notes: ${notes.map((n) => n.name).join(', ')}');
    }
    return 'AudioProbe(${parts.join(', ')})';
  }
}
