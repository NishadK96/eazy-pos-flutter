import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

class WindowsRawThermalPrinter {
  static bool get supported => false;

  static Future<bool> printPdf(
    Printer printer,
    Uint8List pdf, {
    required PdfPageFormat format,
    required String name,
  }) async => false;
}
