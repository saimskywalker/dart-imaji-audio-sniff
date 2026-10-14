@TestOn('vm')
library;

import 'package:imaji_audio_sniff/imaji_audio_sniff_io.dart';
import 'package:test/test.dart';

void main() {
  // test/fixtures/ima4_stereo_8k.aifc (8,380 bytes) was written by Apple's
  // own encoder on macOS:
  //
  //   ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=8000:duration=0.5" \
  //     -ac 2 -c:a pcm_s16le src.wav
  //   afconvert -f AIFC -d ima4 src.wav ima4_stereo_8k.aifc
  //
  // `afinfo ima4_stereo_8k.aifc`:
  //
  //   Data format:     2 ch,   8000 Hz, ima4 (0x00000000) 0 bits/channel,
  //                    68 bytes/packet, 64 frames/packet, 0 bytes/frame
  //   Channel layout: Stereo (L R)
  //   estimated duration: 0.504000 sec
  //   audio bytes: 4284
  //   audio packets: 63
  //   audio data file offset: 4096
  //
  // `ffprobe` agrees: adpcm_ima_qt, duration_ts=4032, duration=0.504000.
  // Its COMM chunk holds numSampleFrames = 0x3F = 63, the packet count, so
  // the duration is 63 x 64 / 8000 = 0.504 s (0.5 s of input plus the
  // padding of the last packet). Read as frames it would be 7.875 ms.
  test('a real ima4 AIFF-C from afconvert', () {
    final p = sniffFileSync('test/fixtures/ima4_stereo_8k.aifc');
    expect(p.format, AudioFormat.aifc);
    expect(p.codec, 'ima4');
    expect(p.channels, 2);
    expect(p.sampleRate, 8000);
    expect(p.duration, const Duration(milliseconds: 504));
    expect(p.durationAccuracy, DurationAccuracy.exact);
    expect(p.audioOffset, 4096);
    expect(p.notes, isEmpty);
  });
}
