import 'package:flutter/material.dart';

import '../base/base_image_frame.dart';
import '../../../configuration/presentation/controls/image_frame_values.dart';

class AppImageFrame extends StatelessWidget {
  final ImageProvider image;
  final String semanticLabel;
  final double opacity;

  const AppImageFrame({
    super.key,
    required this.image,
    required this.semanticLabel,
    this.opacity = ImageFrameValues.opacity,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BaseImageFrame(
      image: image,
      width: ImageFrameValues.width,
      height: ImageFrameValues.height,
      opacity: opacity,
      minimumOpacity: ImageFrameValues.minimumOpacity,
      maximumOpacity: ImageFrameValues.maximumOpacity,
      radius: ImageFrameValues.radius,
      borderWidth: ImageFrameValues.borderWidth,
      borderColor: scheme.outlineVariant,
      backgroundColor: scheme.surfaceContainerLow,
      fit: BoxFit.contain,
      alignment: Alignment.center,
      semanticLabel: semanticLabel,
    );
  }
}
