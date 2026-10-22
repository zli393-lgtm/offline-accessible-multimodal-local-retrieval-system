import 'dart:typed_data';

class PdfContent {
  final List<PdfPageContent> pages;

  const PdfContent({required this.pages});
}

class PdfPageContent {
  final int pageIndex;
  final double width;
  final double height;
  final List<PdfBlock> blocks;

  const PdfPageContent({
    required this.pageIndex,
    required this.width,
    required this.height,
    required this.blocks,
  });
}

abstract class PdfBlock {
  final int sourceOrder;
  int layoutOrder;

  final double left;
  final double bottom;
  final double right;
  final double top;

  PdfBlock({
    required this.sourceOrder,
    required this.layoutOrder,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  double get width => right - left;

  double get height => top - bottom;
}

class PdfTextBlock extends PdfBlock {
  final String text;

  PdfTextBlock({
    required this.text,
    required super.sourceOrder,
    required super.layoutOrder,
    required super.left,
    required super.bottom,
    required super.right,
    required super.top,
  });
}

class PdfImageBlock extends PdfBlock {
  final Uint8List pixelData;
  final int pixelWidth;
  final int pixelHeight;
  final int stride;
  final int bitmapFormat;

  PdfImageBlock({
    required this.pixelData,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.stride,
    required this.bitmapFormat,
    required super.sourceOrder,
    required super.layoutOrder,
    required super.left,
    required super.bottom,
    required super.right,
    required super.top,
  });
}
