import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

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
    expect(find.text('Terminal refresh speed'), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('Set up your computer'), findsNothing);
    expect(find.textContaining('herdr plugin install'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Remote bridges (scan to pair)')).dy,
      lessThan(tester.getTopLeft(find.text('Other settings')).dy),
    );

    await tester.scrollUntilVisible(
      find.text('Privacy policy'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Support'), findsOneWidget);
    await tester.tap(find.text('Privacy policy'));
    await tester.pump();
    expect(launcher.launchedUrl, 'https://herdr-go.github.io/privacy/');

    await tester.scrollUntilVisible(
      find.text('Setup help'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Setup help'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Set up your computer'), findsOneWidget);
    expect(
      find.textContaining('herdr plugin install ShakaRover/herdr-go-terminal'),
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

  testWidgets('pairing string dialog rejects invalid input without crashing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpApp(tester, AppLocalePreference.english);
    await tester.tap(find.text('Add computer'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add from string'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'not-json');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid pairing string'), findsOneWidget);
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

    await tester.scrollUntilVisible(
      find.text('技术支持'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('技术支持'));
    await tester.pump();

    expect(launcher.launchedUrl, 'https://herdr-go.github.io/zh/support/');
  });

  testWidgets('iOS settings exposes opt-in diagnostic logging and details', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    tester.view.physicalSize = const Size(1194, 834);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final calls = <MethodCall>[];
    const channel = MethodChannel('dev.herdr/easytier');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    await _pumpApp(tester, AppLocalePreference.english);
    await tester.tap(find.text('Add computer'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('EasyTier diagnostic logs'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('EasyTier diagnostic logs'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Share logs'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Share logs'), findsOneWidget);
    expect(find.text('Clear logs'), findsOneWidget);

    await tester.tap(find.byTooltip('About diagnostic logs'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Documents/Diagnostics'), findsOneWidget);
    expect(
      find.textContaining('download the app container with Xcode'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(calls.last.method, 'configureDiagnosticLogging');
    expect(calls.last.arguments, {'enabled': true});
    debugDefaultTargetPlatformOverride = null;
  });
}
