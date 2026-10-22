import 'package:flutter/material.dart';

class BaseEllipseButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final double longAxis;
  final double shortAxis;
  final double minimumAccessibleTargetSize;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color pressedBackgroundColor;
  final Color pressedForegroundColor;
  final Color borderColor;
  final double borderWidth;
  final double contentPadding;
  final String? semanticLabel;
  final String? semanticHint;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;
  final Duration interactionDuration;

  const BaseEllipseButton({
    super.key,
    required this.child,
    required this.onPressed,
    required this.longAxis,
    required this.shortAxis,
    required this.minimumAccessibleTargetSize,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.pressedBackgroundColor,
    required this.pressedForegroundColor,
    required this.borderColor,
    required this.borderWidth,
    required this.contentPadding,
    this.semanticLabel,
    this.semanticHint,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    required this.interactionDuration,
  });

  @override
  Widget build(BuildContext context) {
    final width = longAxis < minimumAccessibleTargetSize
        ? minimumAccessibleTargetSize
        : longAxis;
    final height = shortAxis < minimumAccessibleTargetSize
        ? minimumAccessibleTargetSize
        : shortAxis;
    Widget button = SizedBox(
      width: width,
      height: height,
      child: FilledButton(
        onPressed: onPressed,
        focusNode: focusNode,
        autofocus: autofocus,
        style: ButtonStyle(
          animationDuration: interactionDuration,
          tapTargetSize: MaterialTapTargetSize.padded,
          minimumSize: WidgetStatePropertyAll(Size(width, height)),
          padding: WidgetStatePropertyAll(EdgeInsets.all(contentPadding)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? pressedBackgroundColor
                : backgroundColor,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.pressed)
                ? pressedForegroundColor
                : foregroundColor,
          ),
          side: WidgetStatePropertyAll(
            BorderSide(color: borderColor, width: borderWidth),
          ),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
        ),
        child: child,
      ),
    );
    if (tooltip != null && tooltip!.trim().isNotEmpty) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: semanticLabel,
      hint: semanticHint,
      onTap: onPressed,
      excludeSemantics: semanticLabel != null,
      child: button,
    );
  }
}
