import 'package:flutter/material.dart';

import '../application/application_controller.dart';
import '../indexing/index_file_state.dart';
import '../indexing/index_job.dart';
import 'design_system/presets/app_choice_controls.dart';
import 'design_system/presets/app_form_dialog.dart';
import 'app_localizations.dart';
import 'ui_components.dart';
import '../configuration/presentation/pages/index_result_dialog_values.dart';

Future<void> showIndexResultDialog(
  BuildContext context,
  ApplicationController controller,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => _IndexResultDialog(controller: controller),
);

/// The single presentation-level index workflow. Every user entry point must
/// use this function so invoking indexing from another feature cannot omit the
/// normal result dialog or weaken the existing indexing behavior.
Future<bool> runCompleteIndexFlow(
  BuildContext context,
  ApplicationController controller,
) async {
  late final bool completed;
  try {
    await controller.runIndex();
    completed = controller.indexState?.status == IndexJobStatus.completed;
  } catch (_) {
    if (context.mounted) await showIndexResultDialog(context, controller);
    rethrow;
  }
  if (context.mounted) await showIndexResultDialog(context, controller);
  return completed;
}

class _IndexResultDialog extends StatefulWidget {
  final ApplicationController controller;
  const _IndexResultDialog({required this.controller});

  @override
  State<_IndexResultDialog> createState() => _IndexResultDialogState();
}

class _IndexResultDialogState extends State<_IndexResultDialog> {
  bool _advanced = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.indexState;
    final files = widget.controller.indexFileStates.values.toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    final successful = files
        .where(
          (item) =>
              item.status == IndexFileStatus.indexed ||
              item.status == IndexFileStatus.removed,
        )
        .toList();
    final unchanged = files
        .where((item) => item.status == IndexFileStatus.unchanged)
        .toList();
    final failed = files
        .where(
          (item) =>
              item.status == IndexFileStatus.failed ||
              item.status == IndexFileStatus.cancelled,
        )
        .toList();
    return AppFormDialog(
      title: context.tr('索引建立结果', 'Indexing results'),
      cancelLabel: context.tr('确定', 'OK'),
      onCancel: () => Navigator.pop(context),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_summary(state)),
          const SizedBox(height: IndexResultDialogValues.summaryToAdvancedGap),
          AppCheckOption(
            value: _advanced,
            toggle: true,
            onChanged: (value) => setState(() => _advanced = value ?? false),
            title: context.tr('高级信息', 'Advanced details'),
            subtitle: context.tr(
              '查看处理数量以及成功和失败的文件',
              'View processing totals and the files that succeeded or failed',
            ),
          ),
          if (_advanced && state != null) ...[
            const SizedBox(
              height: IndexResultDialogValues.advancedToMetricsGap,
            ),
            Wrap(
              spacing: IndexResultDialogValues.metricsHorizontalGap,
              runSpacing: IndexResultDialogValues.metricsRunGap,
              children: [
                MetricTile(
                  label: context.tr('已发现', 'Discovered'),
                  value: '${state.discovered}',
                ),
                MetricTile(
                  label: context.tr('成功', 'Succeeded'),
                  value: '${state.succeeded}',
                ),
                MetricTile(
                  label: context.tr('未变化', 'Unchanged'),
                  value: '${state.skipped}',
                ),
                MetricTile(
                  label: context.tr('失败', 'Failed'),
                  value: '${state.failed}',
                ),
              ],
            ),
            const SizedBox(height: IndexResultDialogValues.listTopGap),
            Text(
              context.tr(
                '建立成功（${successful.length}）',
                'Indexed (${successful.length})',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ...successful.map(
              (item) => Padding(
                padding: const EdgeInsets.only(
                  bottom: IndexResultDialogValues.rowBottomGap,
                ),
                child: SelectableText(item.path),
              ),
            ),
            const SizedBox(height: IndexResultDialogValues.listTopGap),
            Text(
              context.tr(
                '已有索引且无需更新（${unchanged.length}）',
                'Already indexed and unchanged (${unchanged.length})',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ...unchanged.map(
              (item) => Padding(
                padding: const EdgeInsets.only(
                  bottom: IndexResultDialogValues.rowBottomGap,
                ),
                child: SelectableText(item.path),
              ),
            ),
            const SizedBox(height: IndexResultDialogValues.listTopGap),
            Text(
              context.tr('建立失败（${failed.length}）', 'Failed (${failed.length})'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            ...failed.map(
              (item) => Padding(
                padding: const EdgeInsets.only(
                  bottom: IndexResultDialogValues.rowBottomGap,
                ),
                child: SelectableText(
                  '${item.path}${item.message == null ? '' : ': ${item.message}'}',
                ),
              ),
            ),
            if (state.fileStateLogPath != null) ...[
              const SizedBox(height: IndexResultDialogValues.listTopGap),
              Text(
                context.tr('本次任务日志', 'Log for this run'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SelectableText(state.fileStateLogPath!),
            ],
          ],
        ],
      ),
    );
  }

  String _summary(IndexJobState? state) {
    if (state == null) {
      return context.tr('没有可显示的索引结果。', 'No indexing results are available.');
    }
    return switch (state.status) {
      IndexJobStatus.completed => context.tr(
        '索引建立成功。',
        'Indexing completed successfully.',
      ),
      IndexJobStatus.partial => context.tr(
        '索引部分完成，部分文件建立失败。',
        'Indexing completed with some failed files.',
      ),
      IndexJobStatus.cancelled => context.tr(
        '索引建立已取消。',
        'Indexing was cancelled.',
      ),
      IndexJobStatus.failed => context.tr('索引建立失败。', 'Indexing failed.'),
      _ => context.tr('索引任务尚未结束。', 'The indexing task has not finished.'),
    };
  }
}
