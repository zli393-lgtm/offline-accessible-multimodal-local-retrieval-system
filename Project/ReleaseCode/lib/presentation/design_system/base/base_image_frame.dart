import 'package:flutter/material.dart';

class BaseImageFrame extends StatelessWidget {
  final ImageProvider image;
  final double width;
  final double height;
  final double opacity;
  final double minimumOpacity;
  final double maximumOpacity;
  final double radius;
  final double borderWidth;
  final Color borderColor;
  final Color backgroundColor;
  final BoxFit fit;
  final Alignment alignment;
  final String semanticLabel;

  const BaseImageFrame({
    super.key,
    required this.image,
    required this.width,
    required this.height,
    required this.opacity,
    required this.minimumOpacity,
    required this.maximumOpacity,
    required this.radius,
    required this.borderWidth,
    required this.borderColor,
    required this.backgroundColor,
    required this.fit,
    required this.alignment,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: semanticLabel,
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border.all(color: borderColor, width: borderWidth),
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: opacity.clamp(minimumOpacity, maximumOpacity),
        child: Image(
          image: image,
          fit: fit,
          alignment: alignment,
          excludeFromSemantics: true,
        ),
      ),
    ),
  );
}
