import 'dart:typed_data';

/// Largest single read any parser asks for.
const int maxSingleRead = 64 * 1024;

/// Total bytes one probe may read before every further read answers "end of
/// file". Large enough for every header this package understands, small
/// enough that a hostile file cannot make a probe read megabytes.
const int readBudgetBytes = 2 * 1024 * 1024;

/// Total read calls one probe may make before reads answer "end of file".
const int readBudgetCalls = 2048;

/// 2^50: any size or count above this is treated as corrupt. It also keeps
/// every intermediate value inside the 2^53 range that JavaScript numbers
/// represent exactly, so results are identical on the VM and on the web.
const int maxPlausibleValue = 0x4000000000000;

/// One billion seconds (about 31 years): a longer duration is corrupt.
const int maxPlausibleSeconds = 1000000000;

final Uint8List _empty = Uint8List(0);

/// Signals that bytes must be fetched asynchronously before a parse can
/// continue. Thrown only by the async block cache, caught only by its driver.
final class NeedBytes implements Exception {
  /// Creates a request for [count] bytes at [offset].
  const NeedBytes(this.offset, this.count);

  /// Where the missing bytes start.
  final int offset;

  /// How many bytes are wanted.
  final int count;
}

/// Bounded, bounds-checked random access used by every parser.
///
/// Reads never throw for out-of-range requests: they return fewer bytes, or
/// none. Once the budget is spent every read returns nothing, which every
/// parser already treats as a truncated file.
final class ByteReader {
  /// Wraps a source function. [length] is the total size when known.
  ByteReader(this._source, this.length);

  final Uint8List Function(int offset, int count) _source;

  /// Total size of the underlying file, or null when unknown (a stream).
  final int? length;

  /// Bytes handed out so far.
  int bytesRead = 0;

  /// Read calls made so far.
  int calls = 0;

  /// Up to [count] bytes at [offset].
  Uint8List read(int offset, int count) {
    if (offset < 0 || count <= 0 || offset > maxPlausibleValue) return _empty;
    final total = length;
    var want = count > maxSingleRead ? maxSingleRead : count;
    if (total != null) {
      if (offset >= total) return _empty;
      if (want > total - offset) want = total - offset;
    }
    if (calls >= readBudgetCalls || bytesRead + want > readBudgetBytes) {
      return _empty;
    }
    calls++;
    var got = _source(offset, want);
    if (got.length > want) got = Uint8List.sublistView(got, 0, want);
    bytesRead += got.length;
    return got;
  }
}

/// Converts any `List<int>` into a [Uint8List] without copying when possible.
Uint8List asBytes(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);

/// A [ByteReader] source over bytes already in memory.
Uint8List Function(int, int) memorySource(Uint8List bytes) => (offset, count) {
      if (offset >= bytes.length) return _empty;
      final end = count > bytes.length - offset ? bytes.length : offset + count;
      return Uint8List.sublistView(bytes, offset, end);
    };

/// Whether [b] holds the ASCII [tag] at [at].
bool hasTag(Uint8List b, int at, String tag) {
  if (at < 0 || b.length < at + tag.length) return false;
  for (var i = 0; i < tag.length; i++) {
    if (b[at + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

/// The four bytes at [at] as text when every byte is printable ASCII.
String? fourCC(Uint8List b, int at) {
  if (b.length < at + 4) return null;
  for (var i = at; i < at + 4; i++) {
    if (b[i] < 0x20 || b[i] > 0x7E) return null;
  }
  return String.fromCharCodes(b, at, at + 4);
}

// Every multi-byte read below multiplies rather than shifts into bit 24 and
// above: on the web `<<` works on 32-bit signed values, and a byte >= 0x80
// shifted into the top position would come out negative.

/// Little-endian unsigned 16-bit.
int u16le(Uint8List b, int at) => b[at] | (b[at + 1] << 8);

/// Little-endian unsigned 32-bit.
int u32le(Uint8List b, int at) =>
    (b[at] | (b[at + 1] << 8) | (b[at + 2] << 16)) + b[at + 3] * 0x1000000;

/// Little-endian unsigned 64-bit, or -1 when it exceeds [maxPlausibleValue].
int u64le(Uint8List b, int at) {
  final high = u32le(b, at + 4);
  if (high >= 0x40000) return -1;
  return high * 0x100000000 + u32le(b, at);
}

/// Big-endian unsigned 16-bit.
int u16be(Uint8List b, int at) => (b[at] << 8) | b[at + 1];

/// Big-endian unsigned 24-bit.
int u24be(Uint8List b, int at) => (b[at] << 16) | (b[at + 1] << 8) | b[at + 2];

/// Big-endian unsigned 32-bit.
int u32be(Uint8List b, int at) => b[at] * 0x1000000 + u24be(b, at + 1);

/// Big-endian unsigned 64-bit, or -1 when it exceeds [maxPlausibleValue].
int u64be(Uint8List b, int at) {
  final high = u32be(b, at);
  if (high >= 0x40000) return -1;
  return high * 0x100000000 + u32be(b, at + 4);
}

/// `frames / rate` seconds as a [Duration] rounded to the microsecond, or
/// null when either input is not a usable number.
Duration? framesToDuration(int frames, int rate) {
  if (frames < 0 || rate <= 0 || frames > maxPlausibleValue) return null;
  final whole = frames ~/ rate;
  if (whole > maxPlausibleSeconds) return null;
  final rest = frames - whole * rate;
  // rest < rate <= 2^32, so rest * 10^6 stays below 2^53.
  if (rate > 0xFFFFFFFF) return null;
  return Duration(
    microseconds: whole * 1000000 + (rest * 1000000 + rate ~/ 2) ~/ rate,
  );
}

/// `frames / rate` seconds for a fractional [rate], or null when unusable.
Duration? framesToDurationAtRate(int frames, double rate) {
  if (frames < 0 || !rate.isFinite || rate <= 0) return null;
  final seconds = frames / rate;
  if (!seconds.isFinite || seconds > maxPlausibleSeconds) return null;
  return Duration(microseconds: (seconds * 1000000).round());
}
