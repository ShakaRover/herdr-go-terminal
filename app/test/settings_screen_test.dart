import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/main.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/ui/dashboard/dashboard_screen.dart';
import 'package:herdrgo/ui/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _RecordingUrlLauncher extends UrlLauncherPlatform {
  String? launchedUrl;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    return true;
  }
}

void main() {
  testWidgets('empty dashboard opens a poppable device-first settings page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      appLocalePreferenceKey: AppLocalePreference.english.name,
    });
    final prefs = await SharedPreferences.getInstance();
    final previousLauncher = UrlLauncherPlatform.instance;
    final launcher = _RecordingUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = previousLauncher);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const HerdrApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('No computers connected'), findsOneWidget);

    await tester.tap(find.text('Add computer'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Computers')).dy,
      lessThan(tester.getTopLeft(find.text('Add computer')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Add computer')).dy,
      lessThan(
        tester.getTopLeft(find.text('Remote bridges (scan to pair)')).dy,
      ),
    );
    expect(
      tester.getTopLeft(find.text('Set up your computer')).dy,
      lessThan(tester.getTopLeft(find.text('Other settings')).dy),
    );
    expect(
      find.textContaining('herdr plugin install herdr-go/herdr-go'),
      findsOneWidget,
    );

    await tester.tap(find.text('Open the official Plugin installation guide'));
    await tester.pump();
    expect(launcher.launchedUrl, 'https://herdr.dev/docs/marketplace/');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(DashboardScreen), findsOneWidget);
  });
}
