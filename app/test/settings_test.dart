import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/state/settings.dart';

void main() {
  group('BridgeSettings profileId', () {
    test('旧数据缺 profileId 字段时默认为空串', () {
      final s = BridgeSettings.fromJson({
        'baseUrl': 'https://a.ts.net',
        'headerName': 'X-Device-Id',
        'headerValue': 'v',
      });
      expect(s.profileId, '');
      expect(s.baseUrl, 'https://a.ts.net');
    });

    test('toJson/fromJson 往返保留 profileId', () {
      const s = BridgeSettings(
        baseUrl: 'https://a.ts.net',
        profileId: 'abc-123',
      );
      final restored = BridgeSettings.fromJson(s.toJson());
      expect(restored.profileId, 'abc-123');
      expect(restored.baseUrl, 'https://a.ts.net');
    });

    test('copyWith 可单独更新 profileId，其余字段不动', () {
      const s = BridgeSettings(baseUrl: 'https://a.ts.net');
      final updated = s.copyWith(profileId: 'p1');
      expect(updated.profileId, 'p1');
      expect(updated.baseUrl, s.baseUrl);
    });
  });
}
