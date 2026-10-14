import 'bytes.dart';

/// One chunk of a RIFF (little-endian) or IFF (big-endian) file.
final class Chunk {
  /// Creates a chunk record.
  const Chunk(this.id, this.headerOffset, this.size);

  /// The four-character identifier, e.g. `fmt `.
  final String id;

  /// Offset of the 8-byte chunk header.
  final int headerOffset;

  /// Body size in bytes, or -1 when the file does not say.
  final int size;

  /// Offset of the chunk body.
  int get bodyOffset => headerOffset + 8;
}

/// Identifiers real writers put in WAV and AIFF files. Used only to break a
/// tie when an odd-sized chunk leaves two candidate positions for the next
/// header.
const Set<String> _commonIds = {
  'fmt ', 'data', 'fact', 'ds64', 'LIST', 'JUNK', 'junk', 'PAD ', 'FLLR', //
  'bext', 'iXML', 'axml', 'cue ', 'smpl', 'inst', 'acid', 'id3 ', 'ID3 ', //
  'PEAK', 'minf', 'elm1', 'regn', 'umid', 'plst', 'labl', 'note', 'ltxt', //
  'DISP', 'cart', 'levl', 'chna', 'r64m', 'COMM', 'SSND', 'FVER', 'MARK', //
  'INST', 'COMT', 'NAME', 'AUTH', '(c) ', 'ANNO', 'APPL', 'CHAN', 'MIDI', //
  'AESD', 'basc', 'trns', 'cate',
};

/// Walks a chain of chunks, one 8-byte header at a time.
///
/// RIFF and IFF pad an odd-sized chunk with one byte so the next header is
/// even-aligned. Some writers forget. After an odd chunk the walker scores
/// both candidate positions and takes the more plausible one, preferring the
/// padded (specified) layout on a tie; [missingPad] records when it had to
/// take the unpadded one.
final class ChunkWalker {
  /// Starts at [start]. [resolveSize] maps a declared size of 0xFFFFFFFF to
  /// a real one (RF64), returning -1 when it cannot.
  ChunkWalker(
    this._reader,
    int start, {
    required this.bigEndian,
    this.resolveSize,
  }) : _pos = start;

  final ByteReader _reader;

  /// Whether sizes are big-endian (IFF) rather than little-endian (RIFF).
  final bool bigEndian;

  /// Optional size resolver for 0xFFFFFFFF placeholders.
  final int Function(String id)? resolveSize;

  int? _pos;
  int _count = 0;

  /// Whether any chunk was found without its pad byte.
  bool missingPad = false;

  static const int _maxChunks = 512;

  int _size(List<int> h) => bigEndian
      ? h[4] * 0x1000000 + ((h[5] << 16) | (h[6] << 8) | h[7])
      : (h[4] | (h[5] << 8) | (h[6] << 16)) + h[7] * 0x1000000;

  /// The next chunk, or null at the end of the chain or at the first byte
  /// that is not a chunk header.
  Chunk? next() {
    final pos = _pos;
    if (pos == null || _count >= _maxChunks) return null;
    _count++;
    final head = _reader.read(pos, 8);
    if (head.length < 8) return _stop();
    final id = fourCC(head, 0);
    if (id == null) return _stop();
    var size = _size(head);
    if (size == 0xFFFFFFFF && resolveSize != null) size = resolveSize!(id);
    final chunk = Chunk(id, pos, size);
    _advancePast(chunk);
    return chunk;
  }

  /// Stops the walk; the next call to [next] returns null.
  void stop() => _pos = null;

  Chunk? _stop() {
    _pos = null;
    return null;
  }

  void _advancePast(Chunk chunk) {
    if (chunk.size < 0) {
      _pos = null;
      return;
    }
    final end = chunk.bodyOffset + chunk.size;
    if (end > maxPlausibleValue) {
      _pos = null;
      return;
    }
    if (chunk.size.isEven) {
      _pos = end;
      return;
    }
    final padded = score(end + 1);
    final unpadded = score(end);
    if (unpadded > padded) {
      _pos = end;
      missingPad = true;
    } else {
      _pos = end + 1;
    }
  }

  /// How plausible it is that a chunk header starts at [pos]:
  /// 0 = not a header, 1 = printable id, 2 = printable id whose size fits in
  /// the file (or a clean end of file), 3 = common id, 4 = common id that fits.
  int score(int pos) {
    final head = _reader.read(pos, 8);
    final length = _reader.length;
    if (head.length < 8) return (length != null && pos == length) ? 2 : 0;
    final id = fourCC(head, 0);
    if (id == null) return 0;
    final size = _size(head);
    final fits = length == null || pos + 8 + size <= length;
    return (_commonIds.contains(id) ? 2 : 0) + (fits ? 2 : 1);
  }
}
