import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../file_io/file_type_detector.dart';
import '../models/extracted_file_content.dart';
import '../models/file_metadata.dart';
import '../models/parsing_result.dart';
import '../models/pdf_content.dart';
import 'parser.dart';

const int _pdfPageObjectText = 1;
const int _pdfPageObjectImage = 3;
const int _pdfPageObjectForm = 5;

final class _FsMatrix extends Struct {
  @Float()
  external double a;

  @Float()
  external double b;

  @Float()
  external double c;

  @Float()
  external double d;

  @Float()
  external double e;

  @Float()
  external double f;
}

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

typedef _LoadDocumentNative = Pointer<Void> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
);
typedef _LoadDocumentDart = Pointer<Void> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
);

typedef _PointerVoidNative = Void Function(Pointer<Void>);
typedef _PointerVoidDart = void Function(Pointer<Void>);

typedef _PointerToIntNative = Int32 Function(Pointer<Void>);
typedef _PointerToIntDart = int Function(Pointer<Void>);

typedef _LoadPageNative = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _LoadPageDart = Pointer<Void> Function(Pointer<Void>, int);

typedef _GetPageDimensionNative = Float Function(Pointer<Void>);
typedef _GetPageDimensionDart = double Function(Pointer<Void>);

typedef _GetPageObjectNative = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _GetPageObjectDart = Pointer<Void> Function(Pointer<Void>, int);

typedef _GetObjectBoundsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Float>,
  Pointer<Float>,
  Pointer<Float>,
  Pointer<Float>,
);
typedef _GetObjectBoundsDart = int Function(
  Pointer<Void>,
  Pointer<Float>,
  Pointer<Float>,
  Pointer<Float>,
  Pointer<Float>,
);

typedef _TextLoadPageNative = Pointer<Void> Function(Pointer<Void>);
typedef _TextLoadPageDart = Pointer<Void> Function(Pointer<Void>);

typedef _TextObjectGetTextNative = Uint32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint16>,
  Uint32,
);
typedef _TextObjectGetTextDart = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint16>,
  int,
);

typedef _GetRenderedBitmapNative = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _GetRenderedBitmapDart = Pointer<Void> Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);

typedef _BitmapGetBufferNative = Pointer<Void> Function(Pointer<Void>);
typedef _BitmapGetBufferDart = Pointer<Void> Function(Pointer<Void>);

typedef _FormGetObjectNative = Pointer<Void> Function(Pointer<Void>, Uint32);
typedef _FormGetObjectDart = Pointer<Void> Function(Pointer<Void>, int);

typedef _GetMatrixNative = Int32 Function(Pointer<Void>, Pointer<_FsMatrix>);
typedef _GetMatrixDart = int Function(Pointer<Void>, Pointer<_FsMatrix>);

class _PdfiumApi {
  final DynamicLibrary library;

  late final _VoidDart initLibrary;
  late final _VoidDart destroyLibrary;

  late final _LoadDocumentDart loadDocument;
  late final _PointerVoidDart closeDocument;

  late final _PointerToIntDart getPageCount;
  late final _LoadPageDart loadPage;
  late final _PointerVoidDart closePage;

  late final _GetPageDimensionDart getPageWidth;
  late final _GetPageDimensionDart getPageHeight;

  late final _PointerToIntDart pageCountObjects;
  late final _GetPageObjectDart pageGetObject;
  late final _PointerToIntDart pageObjectGetType;
  late final _GetObjectBoundsDart pageObjectGetBounds;
  late final _GetMatrixDart pageObjectGetMatrix;

  late final _TextLoadPageDart textLoadPage;
  late final _PointerVoidDart textClosePage;
  late final _TextObjectGetTextDart textObjectGetText;

  late final _GetRenderedBitmapDart imageGetRenderedBitmap;

  late final _BitmapGetBufferDart bitmapGetBuffer;
  late final _PointerToIntDart bitmapGetWidth;
  late final _PointerToIntDart bitmapGetHeight;
  late final _PointerToIntDart bitmapGetStride;
  late final _PointerToIntDart bitmapGetFormat;
  late final _PointerVoidDart bitmapDestroy;

  late final _PointerToIntDart formCountObjects;
  late final _FormGetObjectDart formGetObject;

  _PdfiumApi(this.library) {
    initLibrary = library.lookupFunction<_VoidNative, _VoidDart>(
      'FPDF_InitLibrary',
    );

    destroyLibrary = library.lookupFunction<_VoidNative, _VoidDart>(
      'FPDF_DestroyLibrary',
    );

    loadDocument = library
        .lookupFunction<_LoadDocumentNative, _LoadDocumentDart>(
          'FPDF_LoadDocument',
        );

    closeDocument = library
        .lookupFunction<_PointerVoidNative, _PointerVoidDart>(
          'FPDF_CloseDocument',
        );

    getPageCount = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDF_GetPageCount',
        );

    loadPage = library.lookupFunction<_LoadPageNative, _LoadPageDart>(
      'FPDF_LoadPage',
    );

    closePage = library.lookupFunction<_PointerVoidNative, _PointerVoidDart>(
      'FPDF_ClosePage',
    );

    getPageWidth = library
        .lookupFunction<_GetPageDimensionNative, _GetPageDimensionDart>(
          'FPDF_GetPageWidthF',
        );

    getPageHeight = library
        .lookupFunction<_GetPageDimensionNative, _GetPageDimensionDart>(
          'FPDF_GetPageHeightF',
        );

    pageCountObjects = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDFPage_CountObjects',
        );

    pageGetObject = library
        .lookupFunction<_GetPageObjectNative, _GetPageObjectDart>(
          'FPDFPage_GetObject',
        );

    pageObjectGetType = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDFPageObj_GetType',
        );

    pageObjectGetBounds = library
        .lookupFunction<_GetObjectBoundsNative, _GetObjectBoundsDart>(
          'FPDFPageObj_GetBounds',
        );

    pageObjectGetMatrix = library
        .lookupFunction<_GetMatrixNative, _GetMatrixDart>(
          'FPDFPageObj_GetMatrix',
        );

    textLoadPage = library
        .lookupFunction<_TextLoadPageNative, _TextLoadPageDart>(
          'FPDFText_LoadPage',
        );

    textClosePage = library
        .lookupFunction<_PointerVoidNative, _PointerVoidDart>(
          'FPDFText_ClosePage',
        );

    textObjectGetText = library
        .lookupFunction<_TextObjectGetTextNative, _TextObjectGetTextDart>(
          'FPDFTextObj_GetText',
        );

    imageGetRenderedBitmap = library
        .lookupFunction<_GetRenderedBitmapNative, _GetRenderedBitmapDart>(
          'FPDFImageObj_GetRenderedBitmap',
        );

    bitmapGetBuffer = library
        .lookupFunction<_BitmapGetBufferNative, _BitmapGetBufferDart>(
          'FPDFBitmap_GetBuffer',
        );

    bitmapGetWidth = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDFBitmap_GetWidth',
        );

    bitmapGetHeight = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDFBitmap_GetHeight',
        );

    bitmapGetStride = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDFBitmap_GetStride',
        );

    bitmapGetFormat = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDFBitmap_GetFormat',
        );

    bitmapDestroy = library
        .lookupFunction<_PointerVoidNative, _PointerVoidDart>(
          'FPDFBitmap_Destroy',
        );

    formCountObjects = library
        .lookupFunction<_PointerToIntNative, _PointerToIntDart>(
          'FPDFFormObj_CountObjects',
        );

    formGetObject = library
        .lookupFunction<_FormGetObjectNative, _FormGetObjectDart>(
          'FPDFFormObj_GetObject',
        );
  }
}

class _Point {
  final double x;
  final double y;

  const _Point(this.x, this.y);
}

class _Bounds {
  final double left;
  final double bottom;
  final double right;
  final double top;

  const _Bounds({
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });
}

class _Matrix2D {
  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  const _Matrix2D({
    required this.a,
    required this.b,
    required this.c,
    required this.d,
    required this.e,
    required this.f,
  });

  static const identity = _Matrix2D(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0);

  _Point transform(double x, double y) {
    return _Point(a * x + c * y + e, b * x + d * y + f);
  }

  _Matrix2D multiply(_Matrix2D other) {
    return _Matrix2D(
      a: a * other.a + c * other.b,
      b: b * other.a + d * other.b,
      c: a * other.c + c * other.d,
      d: b * other.c + d * other.d,
      e: a * other.e + c * other.f + e,
      f: b * other.e + d * other.f + f,
    );
  }
}

class PdfParser implements Parser {
  final String libraryPath;

  PdfParser({String? libraryPath})
    : libraryPath = libraryPath ?? _platformLibraryPath();

  static String _platformLibraryPath() => switch (Platform.operatingSystem) {
    'windows' => 'windows/third_party/pdfium/x64/pdfium.dll',
    'linux' => 'linux/third_party/pdfium/x64/libpdfium.so',
    'macos' => 'macos/third_party/pdfium/lib/libpdfium.dylib',
    _ => throw UnsupportedError(
      'No PDFium runtime layout is defined for ${Platform.operatingSystem}.',
    ),
  };

  @override
  Future<ParsingResult> parse(
    String filePath, {
    FileProcessingObserver? observer,
  }) async {
    await reportFileProcessing(observer, FileProcessingStage.reading);
    final file = File(filePath);

    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    await reportFileProcessing(observer, FileProcessingStage.typeDetection);
    final detectedFileType = await FileTypeDetector.detect(filePath);

    if (detectedFileType != 'PDF') {
      throw FormatException('The file content is not a valid PDF.');
    }

    final runtime = File(libraryPath);

    if (!await runtime.exists()) {
      throw FileSystemException('PDFium runtime not found', runtime.path);
    }

    final runtimeDirectory = runtime.parent;

    if (Platform.isWindows) {
      final dependencyNames = [
        'libc++.dll',
        'third_party_abseil-cpp_absl.dll',
        'icuuc.dll',
        'base_allocator_partition_allocator_src_partition_alloc_allocator_base.dll',
        'base_allocator_partition_allocator_src_partition_alloc_allocator_core.dll',
        'third_party_zlib.dll',
        'third_party_harfbuzz.dll',
      ];

      for (final dependencyName in dependencyNames) {
        final dependency = File('${runtimeDirectory.path}/$dependencyName');

        if (!await dependency.exists()) {
          throw FileSystemException(
            'PDFium dependency not found',
            dependency.path,
          );
        }

        DynamicLibrary.open(dependency.absolute.path);
      }
    }

    final api = _PdfiumApi(DynamicLibrary.open(runtime.absolute.path));

    api.initLibrary();

    Pointer<Void> document = nullptr;

    try {
      final nativePath = file.absolute.path.toNativeUtf8();

      try {
        document = api.loadDocument(nativePath, nullptr);
      } finally {
        calloc.free(nativePath);
      }

      if (document == nullptr) {
        throw FormatException('PDFium failed to load the PDF document.');
      }

      final pages = <PdfPageContent>[];
      final pageCount = api.getPageCount(document);

      for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.structureParsing,
          completedUnits: pageIndex,
          totalUnits: pageCount,
        );
        final page = api.loadPage(document, pageIndex);

        if (page == nullptr) {
          continue;
        }

        try {
          final pageContent = _parsePage(
            api: api,
            document: document,
            page: page,
            pageIndex: pageIndex,
          );

          pages.add(pageContent);
        } finally {
          api.closePage(page);
        }
      }
      await reportFileProcessing(
        observer,
        FileProcessingStage.structureParsing,
        completedUnits: pageCount,
        totalUnits: pageCount,
      );

      final stat = await file.stat();
      final content = _buildExtractedContent(filePath, pages);
      if (content.textInformation.isNotEmpty) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.textExtraction,
          completedUnits: content.textInformation.length,
          totalUnits: content.textInformation.length,
        );
      }
      if (content.imageInformation.isNotEmpty) {
        await reportFileProcessing(
          observer,
          FileProcessingStage.imageDecoding,
          completedUnits: content.imageInformation.length,
          totalUnits: content.imageInformation.length,
        );
      }

      return ParsingResult(
        metadata: FileMetadata(
          filePath: filePath,
          detectedFileType: detectedFileType,
          fileSize: stat.size,
          modifiedTime: stat.modified,
        ),
        content: content,
      );
    } finally {
      if (document != nullptr) {
        api.closeDocument(document);
      }

      api.destroyLibrary();
    }
  }

  ExtractedFileContent _buildExtractedContent(
    String filePath,
    List<PdfPageContent> pages,
  ) {
    final textInformation = <TextInformation>[];
    final imageInformation = <ImageInformation>[];

    for (final page in pages) {
      final orderedBlocks = List<PdfBlock>.from(page.blocks)
        ..sort((a, b) => a.layoutOrder.compareTo(b.layoutOrder));

      for (final block in orderedBlocks) {
        final region = ContentRegion(
          pageIndex: page.pageIndex,
          sourceOrder: block.sourceOrder,
          layoutOrder: block.layoutOrder,
          left: block.left,
          top: block.top,
          right: block.right,
          bottom: block.bottom,
        );

        if (block is PdfTextBlock && block.text.trim().isNotEmpty) {
          textInformation.add(
            TextInformation(
              text: block.text,
              extractionMethod: TextExtractionMethod.direct,
              sourcePath: filePath,
              regions: [region],
            ),
          );
        } else if (block is PdfImageBlock) {
          imageInformation.add(
            ImageInformation(
              sourcePath: filePath,
              format: 'PDFIUM_BITMAP_${block.bitmapFormat}',
              pixelWidth: block.pixelWidth,
              pixelHeight: block.pixelHeight,
              frameCount: 1,
              colorMode: 'PDFIUM_BITMAP_${block.bitmapFormat}',
              hasAlpha: false,
              bytes: block.pixelData,
              region: region,
              semanticVector: const [],
            ),
          );
        }
      }
    }

    return ExtractedFileContent(
      textInformation: textInformation,
      imageInformation: imageInformation,
      audioInformation: const [],
      videoInformation: const [],
      issues: const [],
      status: ExtractionStatus.completed,
    );
  }

  PdfPageContent _parsePage({
    required _PdfiumApi api,
    required Pointer<Void> document,
    required Pointer<Void> page,
    required int pageIndex,
  }) {
    final blocks = <PdfBlock>[];

    final textPage = api.textLoadPage(page);

    var sourceOrder = 0;

    try {
      void visitObject(Pointer<Void> object, _Matrix2D parentTransform) {
        if (object == nullptr) {
          return;
        }

        final objectType = api.pageObjectGetType(object);

        if (objectType == _pdfPageObjectForm) {
          final formMatrix = _readObjectMatrix(api, object);

          final childTransform = parentTransform.multiply(formMatrix);

          final childCount = api.formCountObjects(object);

          for (var index = 0; index < childCount; index++) {
            final child = api.formGetObject(object, index);

            visitObject(child, childTransform);
          }

          return;
        }

        if (objectType != _pdfPageObjectText &&
            objectType != _pdfPageObjectImage) {
          return;
        }

        final bounds = _readBounds(api, object, parentTransform);

        if (bounds == null) {
          return;
        }

        final currentSourceOrder = sourceOrder++;

        if (objectType == _pdfPageObjectText) {
          final text = textPage == nullptr
              ? ''
              : _readTextObject(api, object, textPage);

          blocks.add(
            PdfTextBlock(
              text: text,
              sourceOrder: currentSourceOrder,
              layoutOrder: -1,
              left: bounds.left,
              bottom: bounds.bottom,
              right: bounds.right,
              top: bounds.top,
            ),
          );

          return;
        }

        final image = _readImageObject(
          api: api,
          document: document,
          page: page,
          object: object,
          sourceOrder: currentSourceOrder,
          bounds: bounds,
        );

        blocks.add(image);
      }

      final objectCount = api.pageCountObjects(page);

      for (var index = 0; index < objectCount; index++) {
        visitObject(api.pageGetObject(page, index), _Matrix2D.identity);
      }
    } finally {
      if (textPage != nullptr) {
        api.textClosePage(textPage);
      }
    }

    _assignLayoutOrder(blocks);

    return PdfPageContent(
      pageIndex: pageIndex,
      width: api.getPageWidth(page),
      height: api.getPageHeight(page),
      blocks: blocks,
    );
  }

  _Matrix2D _readObjectMatrix(_PdfiumApi api, Pointer<Void> object) {
    final matrix = calloc<_FsMatrix>();

    try {
      final success = api.pageObjectGetMatrix(object, matrix);

      if (success == 0) {
        return _Matrix2D.identity;
      }

      return _Matrix2D(
        a: matrix.ref.a,
        b: matrix.ref.b,
        c: matrix.ref.c,
        d: matrix.ref.d,
        e: matrix.ref.e,
        f: matrix.ref.f,
      );
    } finally {
      calloc.free(matrix);
    }
  }

  _Bounds? _readBounds(
    _PdfiumApi api,
    Pointer<Void> object,
    _Matrix2D parentTransform,
  ) {
    final left = calloc<Float>();
    final bottom = calloc<Float>();
    final right = calloc<Float>();
    final top = calloc<Float>();

    try {
      final success = api.pageObjectGetBounds(object, left, bottom, right, top);

      if (success == 0) {
        return null;
      }

      final points = [
        parentTransform.transform(left.value, bottom.value),
        parentTransform.transform(left.value, top.value),
        parentTransform.transform(right.value, bottom.value),
        parentTransform.transform(right.value, top.value),
      ];

      final xs = points.map((point) => point.x);

      final ys = points.map((point) => point.y);

      return _Bounds(
        left: xs.reduce(math.min),
        bottom: ys.reduce(math.min),
        right: xs.reduce(math.max),
        top: ys.reduce(math.max),
      );
    } finally {
      calloc.free(left);
      calloc.free(bottom);
      calloc.free(right);
      calloc.free(top);
    }
  }

  String _readTextObject(
    _PdfiumApi api,
    Pointer<Void> object,
    Pointer<Void> textPage,
  ) {
    final byteLength = api.textObjectGetText(
      object,
      textPage,
      nullptr.cast<Uint16>(),
      0,
    );

    if (byteLength <= 2) {
      return '';
    }

    final codeUnitCapacity = (byteLength / 2).ceil();

    final buffer = calloc<Uint16>(codeUnitCapacity);

    try {
      final writtenBytes = api.textObjectGetText(
        object,
        textPage,
        buffer,
        byteLength,
      );

      if (writtenBytes <= 2) {
        return '';
      }

      final codeUnitLength = (writtenBytes ~/ 2) - 1;

      return buffer.cast<Utf16>().toDartString(length: codeUnitLength);
    } finally {
      calloc.free(buffer);
    }
  }

  PdfImageBlock _readImageObject({
    required _PdfiumApi api,
    required Pointer<Void> document,
    required Pointer<Void> page,
    required Pointer<Void> object,
    required int sourceOrder,
    required _Bounds bounds,
  }) {
    final bitmap = api.imageGetRenderedBitmap(document, page, object);

    if (bitmap == nullptr) {
      return PdfImageBlock(
        pixelData: Uint8List(0),
        pixelWidth: 0,
        pixelHeight: 0,
        stride: 0,
        bitmapFormat: 0,
        sourceOrder: sourceOrder,
        layoutOrder: -1,
        left: bounds.left,
        bottom: bounds.bottom,
        right: bounds.right,
        top: bounds.top,
      );
    }

    try {
      final width = api.bitmapGetWidth(bitmap);
      final height = api.bitmapGetHeight(bitmap);
      final stride = api.bitmapGetStride(bitmap);
      final format = api.bitmapGetFormat(bitmap);

      final byteCount = stride * height;
      final buffer = api.bitmapGetBuffer(bitmap);

      final pixelData = buffer == nullptr || byteCount <= 0
          ? Uint8List(0)
          : Uint8List.fromList(buffer.cast<Uint8>().asTypedList(byteCount));

      return PdfImageBlock(
        pixelData: pixelData,
        pixelWidth: width,
        pixelHeight: height,
        stride: stride,
        bitmapFormat: format,
        sourceOrder: sourceOrder,
        layoutOrder: -1,
        left: bounds.left,
        bottom: bounds.bottom,
        right: bounds.right,
        top: bounds.top,
      );
    } finally {
      api.bitmapDestroy(bitmap);
    }
  }

  void _assignLayoutOrder(List<PdfBlock> blocks) {
    final ordered = List<PdfBlock>.from(blocks);

    ordered.sort((a, b) {
      final verticalTolerance = math.max(
        2.0,
        math.min(a.height, b.height) * 0.5,
      );

      if ((a.top - b.top).abs() > verticalTolerance) {
        return b.top.compareTo(a.top);
      }

      final leftComparison = a.left.compareTo(b.left);

      if (leftComparison != 0) {
        return leftComparison;
      }

      return a.sourceOrder.compareTo(b.sourceOrder);
    });

    for (var index = 0; index < ordered.length; index++) {
      ordered[index].layoutOrder = index;
    }
  }
}
