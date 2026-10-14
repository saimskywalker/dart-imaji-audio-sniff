import 'package:test/test.dart';

import 'support/fuzz.dart';

/// A bounded fuzz run on every build. For long campaigns run
/// `dart run tool/fuzz.dart --iterations 1000000`.
void main() {
  test('parsers never throw, read a bounded amount, and agree across APIs',
      () async {
    final failures = await fuzz(iterations: 3000);
    expect(failures, isEmpty, reason: failures.take(3).join('\n\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a second seed', () async {
    final failures = await fuzz(iterations: 1000, seed: 7);
    expect(failures, isEmpty, reason: failures.take(3).join('\n\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
