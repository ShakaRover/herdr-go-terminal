import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../model/remote_profile.dart';

/// 全屏扫码页：识别 bridge 打印的 EasyTier 配对二维码。
/// 扫到合法的配对载荷后 pop 并返回解析好的 [RemoteProfile]，否则 pop null。
class ScanPairingScreen extends StatefulWidget {
  const ScanPairingScreen({super.key});

  @override
  State<ScanPairingScreen> createState() => _ScanPairingScreenState();
}

class _ScanPairingScreenState extends State<ScanPairingScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );

  /// 防止一次扫描连续触发多次回调。
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      RemoteProfile profile;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('not a json object');
        }
        profile = RemoteProfile.fromPairingJson(decoded);
      } on FormatException {
        continue;
      }
      _handled = true;
      Navigator.of(context).pop(profile);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描配对二维码'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          )),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('对准 bridge 启动时打印的二维码（herdr-bridge --show-qr）。'),
          ),
        ],
      ),
    );
  }
}
