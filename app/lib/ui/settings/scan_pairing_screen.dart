import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:image_picker/image_picker.dart';

import '../../l10n/l10n.dart';
import '../../model/remote_profile.dart';
import '../content_pane.dart';

/// 全屏扫码页：识别 bridge 打印的 EasyTier 配对二维码。
///
/// 相机扫描使用 ZXing（flutter_zxing，无 ML Kit）；右上角可从相册/文件夹
/// 选择图片解码。扫到合法载荷后 pop 并返回 [RemoteProfile]，否则 pop null。
class ScanPairingScreen extends StatefulWidget {
  const ScanPairingScreen({super.key});

  @override
  State<ScanPairingScreen> createState() => _ScanPairingScreenState();
}

class _ScanPairingScreenState extends State<ScanPairingScreen> {
  /// 防止一次扫描连续触发多次回调。
  bool _handled = false;
  bool _picking = false;

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

  Future<void> _pickImage() async {
    if (_picking || _handled) return;
    setState(() => _picking = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 4096,
      );
      if (file == null || !mounted) return;
      final code = await zx.readBarcodeImagePathString(
        file.path,
        DecodeParams(format: Format.qrCode, tryHarder: true),
      );
      if (!mounted) return;
      if (code.isValid && _handleRaw(code.text, fromImage: true)) return;
      if (!_handled) _toast(context.l10n.scanImageNoCode);
    } catch (error) {
      if (mounted) _toast(context.l10n.scanImageFailed('$error'));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.scanPairingTitle),
        actions: [
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
              child: ReaderWidget(
                codeFormat: Format.qrCode,
                tryHarder: true,
                showGallery: false,
                onScan: (code) => _handleRaw(code.text),
                onControllerCreated: (controller, error) {
                  if (error != null && mounted) {
                    _toast(context.l10n.cameraUnavailable('$error'));
                  }
                },
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
