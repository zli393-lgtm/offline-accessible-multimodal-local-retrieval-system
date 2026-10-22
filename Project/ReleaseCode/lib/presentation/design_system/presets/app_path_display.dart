import 'package:flutter/material.dart';

import '../../../configuration/presentation/controls/path_display_values.dart';

/// A non-editable path presentation that always exposes the complete value.
class AppPathDisplay extends StatelessWidget {
  final String label;
  final String path;
  final String? emptyText;
  final String? helper;
  final Key? pathKey;

  const AppPathDisplay({
    super.key,
    required this.label,
    required this.path,
    this.emptyText,
    this.helper,
    this.pathKey,
  });

  @override
  Widget build(BuildContext context) {
    final displayed = path.trim().isEmpty ? (emptyText ?? '') : path;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '$label：$displayed',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(PathDisplayValues.padding),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          border: Border.all(
            color: colors.outline,
            width: PathDisplayValues.borderWidth,
          ),
          borderRadius: BorderRadius.circular(PathDisplayValues.radius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: PathDisplayValues.labelToPathGap),
            SelectableText(
              displayed,
              key: pathKey,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (helper != null) ...[
              const SizedBox(height: PathDisplayValues.helperTopGap),
              Text(helper!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}
