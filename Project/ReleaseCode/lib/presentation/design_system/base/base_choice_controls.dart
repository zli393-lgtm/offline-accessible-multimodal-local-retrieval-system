import 'package:flutter/material.dart';

class BaseSelectOption<T> {
  final T value;
  final String label;
  final bool enabled;
  const BaseSelectOption(this.value, this.label, {this.enabled = true});
}

class BaseSelectField<T> extends StatelessWidget {
  final T? value;
  final String label;
  final String? helper;
  final List<BaseSelectOption<T>> options;
  final ValueChanged<T?>? onChanged;
  final double minimumHeight;
  final double minimumAccessibleTargetSize;
  final double horizontalPadding;
  final double verticalPadding;
  final double radius;
  final double borderWidth;
  final Color borderColor;
  final Color focusedBorderColor;
  final TextStyle textStyle;
  final TextStyle labelStyle;
  final TextStyle helperStyle;

  const BaseSelectField({
    super.key,
    required this.value,
    required this.label,
    this.helper,
    required this.options,
    required this.onChanged,
    required this.minimumHeight,
    required this.minimumAccessibleTargetSize,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.radius,
    required this.borderWidth,
    required this.borderColor,
    required this.focusedBorderColor,
    required this.textStyle,
    required this.labelStyle,
    required this.helperStyle,
  });

  @override
  Widget build(BuildContext context) {
    final selectedLabel = options
        .where((option) => option.value == value)
        .map((option) => option.label)
        .firstOrNull;
    final effectiveHeight = minimumHeight < minimumAccessibleTargetSize
        ? minimumAccessibleTargetSize
        : minimumHeight;
    return Semantics(
      container: true,
      label: label,
      hint: helper,
      value: selectedLabel,
      enabled: onChanged != null,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: effectiveHeight),
        child: DropdownButtonFormField<T>(
          key: ValueKey<T?>(value),
          initialValue: value,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            labelStyle: labelStyle,
            helperStyle: helperStyle,
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
              borderSide: BorderSide(
                color: focusedBorderColor,
                width: borderWidth,
              ),
            ),
          ),
          items: options
              .map(
                (option) => DropdownMenuItem<T>(
                  value: option.value,
                  enabled: option.enabled,
                  child: Text(option.label, style: textStyle),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class BaseCheckOption extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool? value;
  final bool toggle;
  final bool tristate;
  final ValueChanged<bool?>? onChanged;
  final double horizontalPadding;
  final double verticalPadding;
  final double minimumVerticalPadding;
  final double minimumAccessibleTargetSize;
  final double horizontalDensity;
  final double verticalDensity;
  final TextStyle titleStyle;
  final TextStyle subtitleStyle;

  const BaseCheckOption({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.toggle = false,
    this.tristate = false,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.minimumVerticalPadding,
    required this.minimumAccessibleTargetSize,
    required this.horizontalDensity,
    required this.verticalDensity,
    required this.titleStyle,
    required this.subtitleStyle,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: title,
    hint: subtitle,
    enabled: onChanged != null,
    checked: toggle ? null : value,
    mixed: toggle ? null : value == null,
    toggled: toggle ? value : null,
    onTap: onChanged == null ? null : () => onChanged!(value != true),
    excludeSemantics: true,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minimumAccessibleTargetSize),
      child: toggle
          ? SwitchListTile(
              contentPadding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              minVerticalPadding: minimumVerticalPadding,
              visualDensity: VisualDensity(
                horizontal: horizontalDensity,
                vertical: verticalDensity,
              ),
              title: Text(title, style: titleStyle),
              subtitle: subtitle == null
                  ? null
                  : Text(subtitle!, style: subtitleStyle),
              value: value ?? false,
              onChanged: onChanged == null
                  ? null
                  : (nextValue) => onChanged!(nextValue),
            )
          : CheckboxListTile(
              contentPadding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              minVerticalPadding: minimumVerticalPadding,
              visualDensity: VisualDensity(
                horizontal: horizontalDensity,
                vertical: verticalDensity,
              ),
              title: Text(title, style: titleStyle),
              subtitle: subtitle == null
                  ? null
                  : Text(subtitle!, style: subtitleStyle),
              value: value,
              tristate: tristate,
              onChanged: onChanged,
            ),
    ),
  );
}

class BaseSegmentOption<T> {
  final T value;
  final String label;
  final IconData? icon;
  const BaseSegmentOption(this.value, this.label, {this.icon});
}

class BaseSegmentedSelector<T> extends StatelessWidget {
  final T value;
  final List<BaseSegmentOption<T>> options;
  final ValueChanged<T>? onChanged;
  final double minimumHeight;
  final double minimumAccessibleTargetSize;
  final double horizontalPadding;
  final double verticalPadding;
  final double radius;
  final double borderWidth;
  final double iconSize;
  final double fontSize;
  final FontWeight fontWeight;
  final String semanticLabel;
  final String fontFamily;

  const BaseSegmentedSelector({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.minimumHeight,
    required this.minimumAccessibleTargetSize,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.radius,
    required this.borderWidth,
    required this.iconSize,
    required this.fontSize,
    required this.fontWeight,
    required this.semanticLabel,
    required this.fontFamily,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveHeight = minimumHeight < minimumAccessibleTargetSize
        ? minimumAccessibleTargetSize
        : minimumHeight;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      enabled: onChanged != null,
      child: SegmentedButton<T>(
        showSelectedIcon: false,
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size.fromHeight(effectiveHeight)),
          tapTargetSize: MaterialTapTargetSize.padded,
          padding: WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
          ),
          textStyle: WidgetStatePropertyAll(
            TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize,
              fontWeight: fontWeight,
            ),
          ),
          iconSize: WidgetStatePropertyAll(iconSize),
          side: WidgetStatePropertyAll(BorderSide(width: borderWidth)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
          ),
        ),
        segments: options
            .map(
              (option) => ButtonSegment<T>(
                value: option.value,
                label: Text(option.label),
                icon: option.icon == null ? null : Icon(option.icon),
              ),
            )
            .toList(),
        selected: {value},
        onSelectionChanged: onChanged == null
            ? null
            : (values) => onChanged!(values.single),
      ),
    );
  }
}
