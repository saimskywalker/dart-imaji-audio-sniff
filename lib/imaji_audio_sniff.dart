/// The extension is a claim; the bytes are the truth.
///
/// Detects the real audio container (WAV, RF64/BW64, FLAC, MP3, AIFF,
/// AIFF-C, M4A/MP4) from a file's bytes and reads its exact duration from
/// the header, so a Dart or Flutter app can catch a file whose extension
/// lies before a player picks the wrong demuxer for it.
///
/// Pure Dart with no dependencies, safe on every platform including the web.
/// File helpers and the playback alias helper live in
/// `package:imaji_audio_sniff/imaji_audio_sniff_io.dart`.
///
/// ```dart
/// final probe = sniffBytes(bytes);
/// if (probe.extensionLies('take_03.mp3')) {
///   print('Really a ${probe.format.extension}, ${probe.duration} long');
/// }
/// ```
library;

export 'src/sniff.dart'
    show
        ReadAt,
        ReadAtSync,
        sniffBytes,
        sniffReader,
        sniffReaderSync,
        sniffStream;
export 'src/types.dart'
    show AudioFormat, AudioProbe, DurationAccuracy, ProbeNote, extensionOf;
