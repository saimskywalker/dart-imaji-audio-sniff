import 'dart:async';
import 'dart:typed_data';

import 'bytes.dart';
import 'flac.dart';
import 'mp3.dart';
import 'types.dart';
import 'wav.dart';

/// Reads up to `length` bytes at `offset`, synchronously. May return fewer
/// bytes, or none, at the end of the data. Must not throw for an offset past
/// the end.
typedef ReadAtSync = List<int> Function(int offset, int length);

/// Reads up to `length` bytes at `offset`, asynchronously: a seek in a file,
/// an HTTP range request, a blob slice. May complete with fewer bytes, or
/// none, at the end of the data.
typedef ReadAt = Future<List<int>> Function(int offset, int length);

/// Identifies the audio in [bytes] and reads its duration from the header.
///
/// [bytes] may be the whole file or only its beginning. When it is only the
/// beginning, pass the real size as [fileLength]: the WAV data size, the MP3
/// bitrate estimate and the M4A `moov` search all depend on it. A few KiB is
/// enough to identify any supported format; reading the duration of a WAV
/// with large metadata chunks, or of an M4A whose `moov` box is at the end,
/// needs the bytes where those structures live, which [sniffReader] and the
/// file helpers in `package:imaji_audio_sniff/imaji_audio_sniff_io.dart`
/// fetch on demand.
///
/// Never throws: bytes it cannot understand give [AudioProbe.unknown].
AudioProbe sniffBytes(List<int> bytes, {int? fileLength}) {
  final data = asBytes(bytes);
  final length = (fileLength == null || fileLength < data.length)
      ? data.length
      : fileLength;
  return probeWith(ByteReader(memorySource(data), length));
}

/// Like [sniffBytes], but reads through [readAt] so only the bytes each
/// parser needs are touched. [length] is the total size, or null when it is
/// unknown.
AudioProbe sniffReaderSync(ReadAtSync readAt, {required int? length}) {
  return probeWith(ByteReader((offset, count) {
    try {
      return asBytes(readAt(offset, count));
    } on Object {
      return Uint8List(0);
    }
  }, length));
}

/// Like [sniffReaderSync], for an asynchronous source such as a file opened
/// for random access or a server that honours HTTP range requests.
///
/// Reads are issued one at a time, in blocks of a few KiB, and the total is
/// bounded no matter what the file claims. Errors thrown by [readAt] are
/// treated as the end of the data.
Future<AudioProbe> sniffReader(ReadAt readAt, {int? length}) {
  return probeAsync(
    (offset, count) async {
      try {
        final data = asBytes(await readAt(offset, count));
        return (bytes: data, atEnd: data.length < count);
      } on Object {
        return (bytes: Uint8List(0), atEnd: true);
      }
    },
    length,
  );
}

/// Identifies the audio at the start of [stream], reading at most
/// [maxBytes], then cancels the subscription.
///
/// A stream cannot seek, so pass [length] (for example an HTTP
/// `Content-Length`) when it is known. Without it, sizes declared in the
/// header are trusted as written, the MP3 bitrate estimate is unavailable,
/// and an M4A whose `moov` box comes after [maxBytes] has no duration.
Future<AudioProbe> sniffStream(
  Stream<List<int>> stream, {
  int? length,
  int maxBytes = 1024 * 1024,
}) async {
  final source = _StreamSource(stream, maxBytes);
  try {
    return await probeAsync(source.fetch, length);
  } finally {
    await source.cancel();
  }
}

/// Runs the parsers over [r]. Never throws, except [NeedBytes], which only an
/// async block cache produces and only its driver catches.
AudioProbe probeWith(ByteReader r) {
  try {
    return _dispatch(r);
  } on NeedBytes {
    rethrow;
  } on Object {
    // Every parser bounds-checks its input; this is a last line of defence
    // so that hostile bytes can never become an exception for the caller.
    return AudioProbe.unknown;
  }
}

AudioProbe _dispatch(ByteReader r) {
  final head = r.read(0, 16);
  if (head.length < 4) return AudioProbe.unknown;
  final isRiff = hasTag(head, 0, 'RIFF') ||
      hasTag(head, 0, 'RF64') ||
      hasTag(head, 0, 'BW64');
  if (isRiff && hasTag(head, 8, 'WAVE')) return parseWav(r);
  if (hasTag(head, 0, 'fLaC')) return parseFlac(r, 0, const {});

  // ID3v2 tags (there may be more than one) in front of MP3 audio, or in
  // front of a FLAC stream by some taggers' choice.
  var pos = 0;
  var tagged = false;
  for (var i = 0; i < 8; i++) {
    final size = id3v2Size(r.read(pos, 10), 0);
    if (size == null) break;
    tagged = true;
    pos += size;
  }
  final notes = tagged ? const {ProbeNote.id3v2Tag} : const <ProbeNote>{};
  if (tagged) {
    final after = r.read(pos, 4);
    if (hasTag(after, 0, 'fLaC')) return parseFlac(r, pos, notes);
    if (after.isEmpty) {
      // The tag runs past the bytes available. ID3v2 almost always fronts
      // MP3, but nothing behind it could be checked, so no duration.
      return AudioProbe(format: AudioFormat.mp3, codec: 'mp3', notes: notes);
    }
  }
  return parseMpeg(r, pos, notes, tagged: tagged) ?? AudioProbe.unknown;
}

/// One asynchronous fetch: the bytes, and whether they reach the real end
/// of the data.
typedef Fetched = ({Uint8List bytes, bool atEnd});

/// An asynchronous fetch of `count` bytes at `offset`.
typedef Fetch = Future<Fetched> Function(int offset, int count);

/// Runs the synchronous parsers over an asynchronous source.
///
/// The parsers read from a block cache. A read that misses throws
/// [NeedBytes]; the driver fetches the missing blocks and runs the parse
/// again from the top. Parsing a header is microseconds, so re-running is
/// cheaper than writing every parser twice, and the rounds are bounded.
Future<AudioProbe> probeAsync(Fetch fetch, int? length) async {
  final cache = _BlockCache(fetch, length);
  for (var round = 0; round < 96; round++) {
    try {
      return probeWith(ByteReader(cache.read, cache.length));
    } on NeedBytes catch (need) {
      await cache.fill(need);
    }
  }
  cache.exhausted = true;
  return probeWith(ByteReader(cache.read, cache.length));
}

final class _BlockCache {
  _BlockCache(this._fetch, this.length);

  static const int block = 4096;
  static const int maxFetched = 4 * 1024 * 1024;

  final Fetch _fetch;
  final Map<int, Uint8List> _blocks = {};

  /// Total size: as given, or learned when a fetch reached the real end.
  int? length;

  /// No further fetching: missing bytes read as absent.
  bool exhausted = false;

  int _fetched = 0;

  Uint8List read(int offset, int count) {
    var end = offset + count;
    final total = length;
    if (total != null && end > total) end = total;
    if (end <= offset) return Uint8List(0);
    final first = offset ~/ block;
    final last = (end - 1) ~/ block;
    for (var b = first; b <= last; b++) {
      if (_blocks.containsKey(b) || exhausted) continue;
      var missingEnd = b;
      while (missingEnd < last && !_blocks.containsKey(missingEnd + 1)) {
        missingEnd++;
      }
      throw NeedBytes(b * block, (missingEnd - b + 1) * block);
    }
    final out = Uint8List(end - offset);
    var filled = 0;
    for (var b = first; b <= last; b++) {
      final data = _blocks[b];
      if (data == null) break;
      final blockStart = b * block;
      final from = offset > blockStart ? offset - blockStart : 0;
      final to =
          end - blockStart < data.length ? end - blockStart : data.length;
      if (to <= from) break;
      out.setRange(filled, filled + to - from, data, from);
      filled += to - from;
      if (data.length < block) break;
    }
    return filled == out.length ? out : Uint8List.sublistView(out, 0, filled);
  }

  Future<void> fill(NeedBytes need) async {
    if (_fetched >= maxFetched) {
      exhausted = true;
      return;
    }
    final got = await _fetch(need.offset, need.count);
    final data = got.bytes;
    _fetched += need.count;
    for (var at = 0; at < need.count; at += block) {
      final index = (need.offset + at) ~/ block;
      if (at >= data.length) {
        _blocks[index] = Uint8List(0);
        continue;
      }
      final to = at + block < data.length ? at + block : data.length;
      _blocks[index] = Uint8List.sublistView(data, at, to);
    }
    if (data.length < need.count) {
      if (got.atEnd) {
        // Learn the size only when the caller did not state one: a stated
        // size is trusted exactly as the synchronous readers trust it.
        length ??= need.offset + data.length;
      } else {
        // Not the end, but nothing more can be had (a capped stream).
        exhausted = true;
      }
    }
  }
}

/// Serves fetches from a stream that can only be read forwards, keeping at
/// most `maxBytes` of it.
final class _StreamSource {
  _StreamSource(Stream<List<int>> stream, this._max)
      : _it = StreamIterator(stream);

  final StreamIterator<List<int>> _it;
  final int _max;
  Uint8List _buffer = Uint8List(16 * 1024);
  int _filled = 0;
  bool _done = false;

  Future<Fetched> fetch(int offset, int count) async {
    final want = offset + count;
    while (_filled < want && _filled < _max && !_done) {
      if (!await _it.moveNext()) {
        _done = true;
        break;
      }
      _append(_it.current);
    }
    final end = want < _filled ? want : _filled;
    final bytes = offset >= end
        ? Uint8List(0)
        : Uint8List.fromList(Uint8List.sublistView(_buffer, offset, end));
    return (bytes: bytes, atEnd: _done && end < want);
  }

  void _append(List<int> chunk) {
    var take = chunk.length;
    if (_filled + take > _max) take = _max - _filled;
    if (take <= 0) return;
    if (_filled + take > _buffer.length) {
      var size = _buffer.length * 2;
      while (size < _filled + take) {
        size *= 2;
      }
      _buffer = Uint8List(size)..setRange(0, _filled, _buffer);
    }
    _buffer.setRange(_filled, _filled + take, chunk);
    _filled += take;
  }

  Future<void> cancel() => _it.cancel();
}
