import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// Shared user-facing runtime status text.
abstract final class StatusMessages {
  static String serviceNotStarted(BuildContext context) => context.tr(
    '索引与查询服务未启动。请先到“设置”保存配置并启动。',
    'The indexing and search service is not running. Open Settings, save the configuration, and start it.',
  );

  static String serviceStarted(BuildContext context) =>
      context.tr('索引与查询服务已启动', 'The indexing and search service is running');
}
