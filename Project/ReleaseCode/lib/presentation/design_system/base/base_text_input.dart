import 'package:flutter/material.dart';

class BaseTextInput extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final String? helper;
  final int? minLines;
  final int maxLines;
  final bool enabled;
  final bool autofocus;
  final bool readOnly;
  final double minimumHeight;
  final double minimumAccessibleTargetSize;
  final double radius;
  final double borderWidth;
  final double horizontalPadding;
  final double verticalPadding;
  final Color borderColor;
  final Color focusedBorderColor;
  final Color fillColor;
  final TextStyle textStyle;
  final TextStyle labelStyle;
  final TextStyle helperStyle;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;

  const BaseTextInput({
    super.key,
    required this.controller,
    required this.maxLines,
    required this.enabled,
    required this.autofocus,
    this.readOnly = false,
    required this.minimumHeight,
    required this.minimumAccessibleTargetSize,
    required this.radius,
    required this.borderWidth,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.borderColor,
    required this.focusedBorderColor,
    required this.fillColor,
    required this.textStyle,
    required this.labelStyle,
    required this.helperStyle,
    this.label,
    this.hint,
    this.helper,
    this.minLines,
    this.onSubmitted,
    this.onChanged,
    this.focusNode,
    this.textInputAction,
  }) : assert(
         label != null || hint != null,
         'Accessible text input requires a visible label or hint.',
       );

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      minHeight: minimumHeight < minimumAccessibleTargetSize
          ? minimumAccessibleTargetSize
          : minimumHeight,
    ),
    child: TextField(
      controller: controller,
      focusNode: focusNode,
      textInputAction: textInputAction,
      enabled: enabled,
      autofocus: autofocus,
      readOnly: readOnly,
      minLines: minLines,
      maxLines: maxLines,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      style: textStyle,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        labelStyle: labelStyle,
        helperStyle: helperStyle,
        hintStyle: textStyle,
        filled: true,
        fillColor: fillColor,
        contentPadding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: borderColor, width: borderWidth),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: focusedBorderColor, width: borderWidth),
        ),
      ),
    ),
  );
}
