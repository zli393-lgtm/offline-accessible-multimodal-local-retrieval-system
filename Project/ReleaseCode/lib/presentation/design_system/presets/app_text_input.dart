import 'package:flutter/material.dart';

import '../base/base_text_input.dart';
import '../../../configuration/presentation/controls/text_input_values.dart';
import '../../../configuration/presentation/theme/theme_values.dart';

class AppTextInput extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final String? helper;
  final int? minLines;
  final int maxLines;
  final bool enabled;
  final bool autofocus;
  final bool readOnly;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;

  const AppTextInput({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.helper,
    this.minLines,
    this.maxLines = TextInputValues.singleLine,
    this.enabled = true,
    this.autofocus = false,
    this.readOnly = false,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
    this.textInputAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BaseTextInput(
      controller: controller,
      label: label,
      hint: hint,
      helper: helper,
      minLines: minLines,
      maxLines: maxLines,
      enabled: enabled,
      autofocus: autofocus,
      readOnly: readOnly,
      minimumHeight: TextInputValues.minimumHeight,
      minimumAccessibleTargetSize: TextInputValues.minimumAccessibleTargetSize,
      radius: TextInputValues.radius,
      borderWidth: TextInputValues.borderWidth,
      horizontalPadding: TextInputValues.horizontalPadding,
      verticalPadding: TextInputValues.verticalPadding,
      borderColor: scheme.outline,
      focusedBorderColor: scheme.primary,
      fillColor: scheme.surface,
      textStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: TextInputValues.textFontSize,
        fontWeight: FontWeight.values[TextInputValues.textFontWeightIndex],
      ),
      labelStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: TextInputValues.labelFontSize,
        fontWeight: FontWeight.values[TextInputValues.labelFontWeightIndex],
      ),
      helperStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: TextInputValues.helperFontSize,
        fontWeight: FontWeight.values[TextInputValues.helperFontWeightIndex],
      ),
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      focusNode: focusNode,
      textInputAction: textInputAction,
    );
  }
}
