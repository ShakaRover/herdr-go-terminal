import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/main.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('terminal auto-resize option reflects and persists its switch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      appLocalePreferenceKey: AppLocalePreference.english.name,
      terminalAutoResizePreferenceKey: false,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const HerdrApp(),
      ),
    );
    await tester.pumpAndSettle();

    final tileFinder = find.widgetWithText(
      SwitchListTile,
      'Fit terminal output to phone',
    );
    expect(tileFinder, findsOneWidget);
    expect(tester.widget<SwitchListTile>(tileFinder).value, isFalse);

    await tester.tap(tileFinder);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(tileFinder).value, isTrue);
    expect(prefs.getBool(terminalAutoResizePreferenceKey), isTrue);
  });

  testWidgets('language selection updates the app and persists', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      appLocalePreferenceKey: AppLocalePreference.english.name,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const HerdrApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Connection settings'), findsOneWidget);
    expect(find.text('No bridge is paired yet.'), findsNothing);
    expect(find.textContaining('No bridge is paired yet.'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文').last);
    await tester.pumpAndSettle();

    expect(find.text('连接设置'), findsOneWidget);
    expect(
      prefs.getString(appLocalePreferenceKey),
      AppLocalePreference.simplifiedChinese.name,
    );
  });

  test('invalid persisted locale falls back to system', () async {
    SharedPreferences.setMockInitialValues({appLocalePreferenceKey: 'invalid'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    expect(container.read(appLocaleProvider), AppLocalePreference.system);
  });
}
