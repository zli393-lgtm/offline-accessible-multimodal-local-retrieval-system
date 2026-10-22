import 'package:flutter/material.dart';

class BaseRectButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final double? width;
  final double height;
  final double minimumWidth;
  final double minimumAccessibleTargetSize;
  final double radius;
  final double borderWidth;
  final double horizontalPadding;
  final double verticalPadding;
  final double fontSize;
  final FontWeight fontWeight;
  final String fontFamily;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color pressedBackgroundColor;
  final Color pressedForegroundColor;
  final Color disabledBackgroundColor;
  final Color disabledForegroundColor;
  final Color borderColor;
  final Color shadowColor;
  final double shadowBlur;
  final double elevation;
  final double visibleShadowThreshold;
  final Offset shadowOffset;
  final String? semanticLabel;
  final String? semanticHint;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;
  final Duration interactionDuration;

  const BaseRectButton({
    super.key,
    required this.child,
    required this.onPressed,
    required this.height,
    required this.minimumWidth,
    required this.minimumAccessibleTargetSize,
    required this.radius,
    required this.borderWidth,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.fontSize,
    required this.fontWeight,
    required this.fontFamily,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.pressedBackgroundColor,
    required this.pressedForegroundColor,
    required this.disabledBackgroundColor,
    required this.disabledForegroundColor,
    required this.borderColor,
    required this.shadowColor,
    required this.shadowBlur,
    required this.elevation,
    required this.visibleShadowThreshold,
    required this.shadowOffset,
    this.width,
    this.semanticLabel,
    this.semanticHint,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    required this.interactionDuration,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveHeight = height < minimumAccessibleTargetSize
        ? minimumAccessibleTargetSize
        : height;
    Widget button = ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: minimumWidth,
        minHeight: effectiveHeight,
      ),
      child: SizedBox(
        width: width,
        child: FilledButton(
          onPressed: onPressed,
          focusNode: focusNode,
          autofocus: autofocus,
          style: ButtonStyle(
            animationDuration: interactionDuration,
            tapTargetSize: MaterialTapTargetSize.padded,
            minimumSize: WidgetStatePropertyAll(
              Size(minimumWidth, effectiveHeight),
            ),
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
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? disabledBackgroundColor
                  : states.contains(WidgetState.pressed)
                  ? pressedBackgroundColor
                  : backgroundColor,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? disabledForegroundColor
                  : states.contains(WidgetState.pressed)
                  ? pressedForegroundColor
                  : foregroundColor,
            ),
            side: WidgetStatePropertyAll(
              BorderSide(color: borderColor, width: borderWidth),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
              ),
            ),
            elevation: WidgetStatePropertyAll(elevation),
            shadowColor: WidgetStatePropertyAll(shadowColor),
          ),
          child: child,
        ),
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: shadowBlur <= visibleShadowThreshold
              ? const []
              : [
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: shadowBlur,
                    offset: shadowOffset,
                  ),
                ],
        ),
        child: button,
      ),
    );
  }
}
