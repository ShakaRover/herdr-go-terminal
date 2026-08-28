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

Future<_RecordingUrlLauncher> _pumpApp(
  WidgetTester tester,
  AppLocalePreference locale,
) async {
  SharedPreferences.setMockInitialValues({appLocalePreferenceKey: locale.name});
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
  return launcher;
}

void main() {
  testWidgets('empty dashboard opens a poppable device-first settings page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final launcher = await _pumpApp(tester, AppLocalePreference.english);

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
    expect(find.text('Setup help'), findsOneWidget);
    expect(find.text('Set up your computer'), findsNothing);
    expect(find.textContaining('herdr plugin install'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Remote bridges (scan to pair)')).dy,
      lessThan(tester.getTopLeft(find.text('Other settings')).dy),
    );

    await tester.tap(find.text('Setup help'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Set up your computer'), findsOneWidget);
    expect(
      find.textContaining('herdr plugin install herdr-go/herdr-go'),
      findsOneWidget,
    );

    await tester.tap(find.text('View the full website guide'));
    await tester.pump();
    expect(launcher.launchedUrl, 'https://herdr-go.github.io/#install');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(DashboardScreen), findsOneWidget);
  });

  testWidgets('Chinese setup help opens the localized website guide', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final launcher = await _pumpApp(
      tester,
      AppLocalePreference.simplifiedChinese,
    );

    await tester.tap(find.text('添加设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('部署帮助'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看完整官网说明'));
    await tester.pump();

    expect(launcher.launchedUrl, 'https://herdr-go.github.io/zh/#install');
  });
}
