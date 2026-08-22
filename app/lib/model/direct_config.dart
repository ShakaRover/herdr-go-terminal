/// 直填 bridge 连接配置（label 缺省取 baseUrl 的 host）。
class DirectConfig {
  const DirectConfig({
    required this.id, // 本地 uuid
    required this.label, // 展示名
    required this.baseUrl, // 不带尾斜杠（api 层再归一化）
    this.headerName = '',
    this.headerValue = '',
    this.enabled = true,
  });

  final String id;
  final String label;
  final String baseUrl;
  final String headerName;
  final String headerValue;
  final bool enabled;

  Map<String, String> get headers =>
      headerName.trim().isEmpty ? const {} : {headerName.trim(): headerValue};

  DirectConfig copyWith({
    String? label,
    String? baseUrl,
    String? headerName,
    String? headerValue,
    bool? enabled,
  }) =>
      DirectConfig(
        id: id,
        label: label ?? this.label,
        baseUrl: baseUrl ?? this.baseUrl,
        headerName: headerName ?? this.headerName,
        headerValue: headerValue ?? this.headerValue,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'baseUrl': baseUrl,
        'headerName': headerName,
        'headerValue': headerValue,
        'enabled': enabled,
      };

  factory DirectConfig.fromJson(Map<String, dynamic> j) => DirectConfig(
        id: j['id'] is String ? j['id'] as String : '',
        label: j['label'] is String ? j['label'] as String : '',
        baseUrl: j['baseUrl'] is String ? j['baseUrl'] as String : '',
        headerName: j['headerName'] is String ? j['headerName'] as String : '',
        headerValue:
            j['headerValue'] is String ? j['headerValue'] as String : '',
        enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      );
}
