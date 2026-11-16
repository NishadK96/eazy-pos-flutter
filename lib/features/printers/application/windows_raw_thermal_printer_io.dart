import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:win32/win32.dart';

import 'android_bluetooth_printer.dart';

/// Sends thermal receipts to a Windows queue as native ESC/POS raster data.
///
/// The normal Windows PDF path renders the already-rasterized receipt again in
/// the vendor driver. That second scaling pass softens small Arabic glyphs and
/// thin rules. A RAW spool job preserves the exact 203-DPI black dots prepared
/// by the app. If the queue cannot accept RAW data, an exception is raised so
/// callers can report the printer/driver incompatibility instead of silently
/// claiming that a degraded print succeeded.
class WindowsRawThermalPrinter {
  static bool get supported => Platform.isWindows;

  static Future<bool> printPdf(
    Printer printer,
    Uint8List pdf, {
    required PdfPageFormat format,
    required String name,
  }) async {
    if (!supported) return false;

    final width = format.width < 70 * PdfPageFormat.mm ? 384 : 576;
    final output = BytesBuilder(copy: false)..add([0x1b, 0x40]);
    var pages = 0;
    await for (final page in Printing.raster(pdf, dpi: 203)) {
      final decoded = img.decodePng(await page.toPng());
      if (decoded == null) {
        throw StateError('Could not render the thermal receipt.');
      }
      final cropped = AndroidBluetoothPrinter.trimTrailingWhitespace(decoded);
      final sized = cropped.width == width
          ? cropped
          : img.copyResize(
              cropped,
              width: width,
              interpolation: img.Interpolation.linear,
            );
      final bitmap = AndroidBluetoothPrinter.strengthenThermalBitmap(sized);
      output.add(AndroidBluetoothPrinter.rasterCommands(bitmap));
      pages++;
    }
    if (pages == 0) throw StateError('The receipt has no printable pages.');
    output.add([0x0a, 0x0a, 0x0a, 0x1d, 0x56, 0x00]);

    _writeRaw(printer.url, name, output.takeBytes());
    return true;
  }

  static void _writeRaw(
    String printerName,
    String documentName,
    Uint8List bytes,
  ) {
    final namePointer = printerName.toNativeUtf16();
    final handlePointer = calloc<IntPtr>();
    try {
      if (OpenPrinter(namePointer, handlePointer, nullptr) == 0) {
        throw StateError('Could not open Windows printer "$printerName".');
      }
      final handle = handlePointer.value;
      final document = calloc<DOC_INFO_1>();
      final titlePointer = documentName.toNativeUtf16();
      final datatypePointer = 'RAW'.toNativeUtf16();
      try {
        document.ref
          ..pDocName = titlePointer
          ..pOutputFile = nullptr
          ..pDatatype = datatypePointer;
        if (StartDocPrinter(handle, 1, document) == 0) {
          throw StateError('The Windows print spooler rejected the RAW job.');
        }
        var pageStarted = false;
        try {
          if (StartPagePrinter(handle) == 0) {
            throw StateError(
              'The Windows print spooler could not start the receipt.',
            );
          }
          pageStarted = true;
          final data = calloc<Uint8>(bytes.length);
          final written = calloc<Uint32>();
          try {
            data.asTypedList(bytes.length).setAll(0, bytes);
            if (WritePrinter(handle, data, bytes.length, written) == 0 ||
                written.value != bytes.length) {
              throw StateError(
                'The thermal printer did not accept the complete receipt.',
              );
            }
          } finally {
            calloc.free(written);
            calloc.free(data);
          }
        } finally {
          if (pageStarted) EndPagePrinter(handle);
          EndDocPrinter(handle);
        }
      } finally {
        calloc.free(datatypePointer);
        calloc.free(titlePointer);
        calloc.free(document);
        ClosePrinter(handle);
      }
    } finally {
      calloc.free(handlePointer);
      calloc.free(namePointer);
    }
  }
}
