import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/ansi/ansi.dart';
import 'package:herdrgo/ui/agent/ansi_span.dart';

void main() {
  test('uses a concrete monospace font on iOS', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final style = segmentStyle(const AnsiSegment(text: '0'));

    expect(style.fontFamily, 'Menlo');
  });

  test('keeps Android native monospace family', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    final style = segmentStyle(const AnsiSegment(text: '0'));

    expect(style.fontFamily, 'monospace');
  });
}
