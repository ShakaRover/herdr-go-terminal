import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';
import 'package:zxing2/qrcode.dart';

import '../../l10n/l10n.dart';
import '../../model/remote_profile.dart';
import '../content_pane.dart';

/// 全屏扫码页：识别 bridge 打印的 EasyTier 配对二维码。
///
/// 相机扫描使用 qr_code_scanner_plus（Android ZXing / iOS AVFoundation，
/// 无 ML Kit）；右上角可从相册/文件夹选择图片，用纯 Dart zxing2 解码。
/// 扫到合法载荷后 pop 并返回 [RemoteProfile]，否则 pop null。
class ScanPairingScreen extends StatefulWidget {
  const ScanPairingScreen({super.key});

  @override
  State<ScanPairingScreen> createState() => _ScanPairingScreenState();
}

class _ScanPairingScreenState extends State<ScanPairingScreen> {
  final GlobalKey _qrKey = GlobalKey(debugLabel: 'qr');
  QRViewController? _controller;
  StreamSubscription<Barcode>? _scanSubscription;

  /// 防止一次扫描连续触发多次回调。
  bool _handled = false;
  bool _picking = false;

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 解析并返回 true 表示已处理（合法载荷已 pop 或重复回调）。
  bool _handleRaw(String? raw, {bool fromImage = false}) {
    if (_handled) return true;
    final text = raw?.trim();
    if (text == null || text.isEmpty) return false;
    RemoteProfile profile;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a json object');
      }
      profile = RemoteProfile.fromPairingJson(decoded);
    } on FormatException {
      if (fromImage) _toast(context.l10n.scanImageInvalid);
      return false;
    }
    _handled = true;
    Navigator.of(context).pop(profile);
    return true;
  }

  void _onQRViewCreated(QRViewController controller) {
    _controller = controller;
    _scanSubscription = controller.scannedDataStream.listen((barcode) {
      _handleRaw(barcode.code);
    });
  }

  Future<void> _pickImage() async {
    if (_picking || _handled) return;
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 4096,
      );
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) {
        if (mounted) _toast(context.l10n.scanImageNoCode);
        return;
      }
      final result = _decodeQr(image);
      if (!mounted) return;
      if (result != null && _handleRaw(result, fromImage: true)) return;
      if (!_handled) _toast(context.l10n.scanImageNoCode);
    } catch (error) {
      if (mounted) _toast(context.l10n.scanImageFailed('$error'));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 纯 Dart ZXing 解码，避免为图片导入引入 ML Kit。
  String? _decodeQr(img.Image image) {
    final pixels = Int32List(image.width * image.height);
    var index = 0;
    for (final pixel in image) {
      pixels[index++] =
          (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt();
    }
    final source = RGBLuminanceSource(image.width, image.height, pixels);
    final bitmap = BinaryBitmap(HybridBinarizer(source));
    try {
      return QRCodeReader().decode(bitmap).text;
    } on ReaderException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.scanPairingTitle),
        actions: [
          IconButton(
            tooltip: context.l10n.toggleFlashTooltip,
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller?.toggleFlash(),
          ),
          IconButton(
            tooltip: context.l10n.switchCameraTooltip,
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _controller?.flipCamera(),
          ),
          IconButton(
            tooltip: context.l10n.scanFromImageTooltip,
            icon: _picking
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open),
            onPressed: _picking ? null : _pickImage,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ContentPane(
              child: QRView(
                key: _qrKey,
                onQRViewCreated: _onQRViewCreated,
                overlay: QrScannerOverlayShape(
                  borderColor: Colors.white,
                  borderRadius: 12,
                  borderLength: 24,
                  borderWidth: 6,
                  cutOutSize: 260,
                ),
              ),
            ),
          ),
          ContentPane(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(context.l10n.scanPairingHelp),
            ),
          ),
        ],
      ),
    );
  }
}
