import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/ui/content_pane.dart';

void main() {
  testWidgets('wide layouts cap single-column content at 720 points', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1194, 834);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ContentPane(child: SizedBox.expand(key: Key('content'))),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const Key('content'))).width, 720);
  });

  testWidgets('compact layouts use all available width', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(375, 667);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ContentPane(child: SizedBox.expand(key: Key('content'))),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const Key('content'))).width, 375);
  });

  testWidgets('bounded height follows content instead of expanding', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: ContentPane(
              key: Key('pane'),
              child: SizedBox(width: double.infinity, height: 100),
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byKey(const Key('pane'))).height, 100);
  });
}
