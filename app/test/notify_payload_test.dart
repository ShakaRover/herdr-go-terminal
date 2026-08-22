/// 通知 payload 编解码 + 前台心跳节流。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/notify/blocked_watch.dart';
import 'package:herdrgo/notify/foreground_heartbeat.dart';
import 'package:herdrgo/notify/notify_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('encode/decode round-trip', () {
    test('uuid bridgeId + 普通 paneId', () {
      const bridgeId = '3f6b8b8e-2a1c-4d5e-9f0a-1b2c3d4e5f6a';
      const paneId = 'w0';
      final payload = encodeNotifyPayload(bridgeId, paneId);
      expect(payload, '$bridgeId\n$paneId');
      expect(decodeNotifyPayload(payload), (bridgeId, paneId));
    });

    test('paneId 带冒号也安全（分隔符是首个换行）', () {
      final payload = encodeNotifyPayload('b1', 'w1:t2');
      expect(decodeNotifyPayload(payload), ('b1', 'w1:t2'));
    });
  });

  group('旧 payload 兼容', () {
    test('无换行的旧 payload 视为 paneId，bridgeId 回退空串', () {
      expect(decodeNotifyPayload('w0'), ('', 'w0'));
    });
  });

  group('ForegroundHeartbeat 节流', () {
    test('首次必写；间隔内复写被节流；过期间隔后再写', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final hb = ForegroundHeartbeat();

      hb.stamp(prefs);
      final first = prefs.getInt(foregroundHeartbeatKey);
      expect(first, isNotNull);

      // 紧跟着 stamp：节流，值不变。
      hb.stamp(prefs);
      expect(prefs.getInt(foregroundHeartbeatKey), first);

      // 新的实例（模拟下一次轮询回路）立即再写。
      ForegroundHeartbeat().stamp(prefs);
      expect(prefs.getInt(foregroundHeartbeatKey), greaterThanOrEqualTo(first!));
    });
  });
}
