import 'bytes.dart';
import 'types.dart';

/// `ftyp` major brands of still-image formats that share the ISO base media
/// file format with audio and video (HEIF, AVIF, JPEG 2000, CR3).
const Set<String> _imageBrands = {
  'heic', 'heix', 'heim', 'heis', 'hevc', 'hevx', 'mif1', 'msf1', 'avif', //
  'avis', 'jp2 ', 'jpx ', 'jpm ', 'crx ',
};

/// Whether [b] starts like an ISO BMFF file this package treats as M4A:
/// an `ftyp` box whose major brand is not an image brand, or a QuickTime
/// file that opens straight with `moov`.
bool looksLikeMp4(List<int> b) {
  if (b.length < 12) return false;
  final type = String.fromCharCodes(b.sublist(4, 8));
  if (type == 'ftyp') {
    return !_imageBrands.contains(String.fromCharCodes(b.sublist(8, 12)));
  }
  return type == 'moov';
}

/// A box header: type, where it starts, header length and total size.
typedef _Box = ({String type, int start, int header, int size});

/// Reads the box header at [pos], bounded by [end] (exclusive, may be null
/// for "unknown").
_Box? _boxAt(ByteReader r, int pos, int? end) {
  final h = r.read(pos, 16);
  if (h.length < 8) return null;
  final type = fourCC(h, 4);
  if (type == null) return null;
  var size = u32be(h, 0);
  var header = 8;
  if (size == 1) {
    if (h.length < 16) return null;
    size = u64be(h, 8);
    header = 16;
  } else if (size == 0) {
    if (end == null) return null;
    size = end - pos;
  }
  if (size < header) return null;
  return (type: type, start: pos, header: header, size: size);
}

/// The first child of type [type] in the byte range [from, to).
_Box? _child(ByteReader r, int from, int to, String type) {
  var pos = from;
  for (var i = 0; i < 256 && pos + 8 <= to; i++) {
    final box = _boxAt(r, pos, to);
    if (box == null) return null;
    if (box.type == type) return box;
    pos += box.size;
  }
  return null;
}

/// Reads the movie duration of an MP4/M4A/MOV file from `moov/mvhd`
/// (ISO/IEC 14496-12, section 8.2.2), falling back to `moov/mvex/mehd` for
/// a fragmented file. `moov` may sit at the end of the file.
AudioProbe parseMp4(ByteReader r) {
  final length = r.length;
  _Box? moov;
  var pos = 0;
  for (var i = 0; i < 1024; i++) {
    final box = _boxAt(r, pos, length);
    if (box == null) break;
    if (box.type == 'moov') {
      moov = box;
      break;
    }
    pos += box.size;
    if (pos > maxPlausibleValue) break;
  }
  final head = r.read(0, 12);
  final hasFtyp = hasTag(head, 4, 'ftyp');
  if (moov == null) {
    return hasFtyp
        ? const AudioProbe(format: AudioFormat.m4a)
        : AudioProbe.unknown;
  }
  final body = moov.start + moov.header;
  final end = moov.start + moov.size;
  final notes = <ProbeNote>{};

  Duration? duration;
  final mvhd = _child(r, body, end, 'mvhd');
  var timescale = 0;
  if (mvhd != null) {
    final b = r.read(mvhd.start + mvhd.header, 32);
    if (b.length >= 20 && b[0] == 0) {
      timescale = u32be(b, 12);
      final d = u32be(b, 16);
      if (d != 0xFFFFFFFF && d > 0) duration = framesToDuration(d, timescale);
    } else if (b.length >= 32 && b[0] == 1) {
      timescale = u32be(b, 20);
      final d = u64be(b, 24);
      if (d > 0) duration = framesToDuration(d, timescale);
    }
  }
  if (duration == null && timescale > 0) {
    final mvex = _child(r, body, end, 'mvex');
    final mehd = mvex == null
        ? null
        : _child(r, mvex.start + mvex.header, mvex.start + mvex.size, 'mehd');
    if (mehd != null) {
      final b = r.read(mehd.start + mehd.header, 12);
      final d = (b.length >= 8 && b[0] == 0)
          ? u32be(b, 4)
          : (b.length >= 12 && b[0] == 1)
              ? u64be(b, 4)
              : 0;
      if (d > 0) {
        duration = framesToDuration(d, timescale);
        if (duration != null) notes.add(ProbeNote.fragmented);
      }
    }
  }

  final audio = _audioTrack(r, body, end);
  return AudioProbe(
    format: AudioFormat.m4a,
    duration: duration,
    durationAccuracy: duration == null ? null : DurationAccuracy.exact,
    codec: audio?.codec,
    sampleRate: audio?.sampleRate,
    channels: audio?.channels,
    bitsPerSample: audio?.bits,
    notes: notes,
  );
}

/// The sample entry of the first sound track: codec four-character code,
/// rate, channels and sample size.
({String codec, int? sampleRate, int? channels, int? bits})? _audioTrack(
    ByteReader r, int from, int to) {
  var pos = from;
  for (var i = 0; i < 64 && pos + 8 <= to; i++) {
    final trak = _boxAt(r, pos, to);
    if (trak == null) return null;
    pos += trak.size;
    if (trak.type != 'trak') continue;
    final mdia = _inside(r, trak, 'mdia');
    if (mdia == null) continue;
    final hdlr = _inside(r, mdia, 'hdlr');
    if (hdlr == null) continue;
    final hb = r.read(hdlr.start + hdlr.header, 12);
    if (!hasTag(hb, 8, 'soun')) continue;
    final stbl = _inside(r, _inside(r, mdia, 'minf'), 'stbl');
    final stsd = _inside(r, stbl, 'stsd');
    if (stsd == null) return null;
    // stsd: version/flags (4), entry count (4), then the first sample entry.
    final e = r.read(stsd.start + stsd.header + 8, 36);
    final codec = fourCC(e, 4);
    if (codec == null) return null;
    if (e.length < 36) {
      return (
        codec: codec.trim(),
        sampleRate: null,
        channels: null,
        bits: null
      );
    }
    // AudioSampleEntry: 8 header, 6 reserved, 2 index, 8 reserved/version,
    // then channelcount (2), samplesize (2), 4 reserved, samplerate 16.16.
    final channels = u16be(e, 24);
    final bits = u16be(e, 26);
    final rate = u32be(e, 32) ~/ 0x10000;
    return (
      codec: codec.trim(),
      sampleRate: rate > 0 ? rate : null,
      channels: channels > 0 ? channels : null,
      bits: bits > 0 ? bits : null,
    );
  }
  return null;
}

_Box? _inside(ByteReader r, _Box? parent, String type) => parent == null
    ? null
    : _child(r, parent.start + parent.header, parent.start + parent.size, type);
