import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/utils/money.dart';
import '../../../core/utils/pdf_fonts.dart';
import '../../../shared/models/entities.dart';
import '../../invoice_layouts/domain/invoice_layout_entities.dart';

abstract final class QuotationPdf {
  static Future<ErpInvoicePdf> build({
    required Sale quotation,
    required BusinessProfile? business,
  }) async {
    final theme = await PdfFonts.arabicTheme();
    final document = pw.Document(theme: theme);
    final number = quotation.invoiceNo.trim().isEmpty
        ? quotation.serverId ?? quotation.localId
        : quotation.invoiceNo.trim();
    final businessName = business?.name.trim().isNotEmpty == true
        ? business!.name.trim()
        : 'Eazy POS';
    final customer = quotation.customer;

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(34),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      PdfFonts.text(
                        businessName,
                        style: pw.TextStyle(
                          fontSize: 19,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#0B6F5F'),
                        ),
                      ),
                      if (business?.taxNumber.trim().isNotEmpty == true)
                        PdfFonts.text(
                          'VAT: ${business!.taxNumber.trim()}',
                          style: const pw.TextStyle(
                            fontSize: 9,
                            color: PdfColors.grey700,
                          ),
                        ),
                    ],
                  ),
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    PdfFonts.text(
                      'QUOTATION',
                      style: pw.TextStyle(
                        fontSize: 22,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    PdfFonts.text(
                      number,
                      style: const pw.TextStyle(
                        fontSize: 11,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 12),
            pw.Divider(color: PdfColor.fromHex('#0B6F5F'), thickness: 1.5),
            pw.SizedBox(height: 12),
          ],
        ),
        footer: (context) => pw.Container(
          alignment: pw.Alignment.center,
          margin: const pw.EdgeInsets.only(top: 14),
          child: PdfFonts.text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ),
        build: (_) => [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: _section('QUOTATION FOR', [
                  customer.name,
                  if (customer.businessName.trim().isNotEmpty)
                    customer.businessName.trim(),
                  if (customer.phone.trim().isNotEmpty) customer.phone.trim(),
                  if (customer.email.trim().isNotEmpty) customer.email.trim(),
                ]),
              ),
              pw.SizedBox(width: 28),
              pw.Expanded(
                child: _section('DETAILS', [
                  'Date: ${_date(quotation.createdAt)}',
                  if (quotation.quotationValidityDate.isNotEmpty)
                    'Valid until: ${_textDate(quotation.quotationValidityDate)}',
                  if (quotation.quotationDeliveryDate.isNotEmpty)
                    'Delivery: ${_textDate(quotation.quotationDeliveryDate)}',
                  if (quotation.vehicleNumber.isNotEmpty)
                    'Vehicle: ${quotation.vehicleNumber}',
                  if (quotation.quotationAttention.isNotEmpty)
                    'Attention: ${quotation.quotationAttention}',
                ]),
              ),
            ],
          ),
          pw.SizedBox(height: 24),
          pw.TableHelper.fromTextArray(
            headers: const ['#', 'Item', 'Qty', 'Unit price', 'VAT', 'Total'],
            data: [
              for (var index = 0; index < quotation.items.length; index++)
                [
                  '${index + 1}',
                  quotation.items[index].product.name,
                  _quantity(quotation.items[index].quantity),
                  money(quotation.items[index].unitPriceIncludingTax),
                  money(quotation.items[index].tax),
                  money(quotation.items[index].total),
                ],
            ],
            headerDecoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#E8F2EF'),
            ),
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#174F46'),
            ),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 7,
              vertical: 8,
            ),
            border: const pw.TableBorder(
              horizontalInside: pw.BorderSide(
                color: PdfColors.grey300,
                width: .5,
              ),
              bottom: pw.BorderSide(color: PdfColors.grey400),
            ),
            columnWidths: const {
              0: pw.FixedColumnWidth(25),
              1: pw.FlexColumnWidth(3),
              2: pw.FlexColumnWidth(1),
              3: pw.FlexColumnWidth(1.4),
              4: pw.FlexColumnWidth(1.2),
              5: pw.FlexColumnWidth(1.4),
            },
          ),
          pw.SizedBox(height: 18),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Container(
              width: 235,
              padding: const pw.EdgeInsets.all(14),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#F2F7F5'),
                borderRadius: pw.BorderRadius.circular(5),
              ),
              child: pw.Column(
                children: [
                  _totalRow('Subtotal', quotation.total - quotation.tax),
                  _totalRow('VAT', quotation.tax),
                  if (quotation.discount > 0)
                    _totalRow('Discount', -quotation.discount),
                  pw.Divider(color: PdfColors.grey400),
                  _totalRow('Total', quotation.total, emphasized: true),
                ],
              ),
            ),
          ),
          if (quotation.quotationTerms.trim().isNotEmpty) ...[
            pw.SizedBox(height: 24),
            PdfFonts.text(
              'TERMS & CONDITIONS',
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: PdfColor.fromHex('#174F46'),
              ),
            ),
            pw.SizedBox(height: 6),
            PdfFonts.text(
              quotation.quotationTerms.trim(),
              style: const pw.TextStyle(fontSize: 9, lineSpacing: 2),
            ),
          ],
          pw.SizedBox(height: 28),
          PdfFonts.text(
            'This is a quotation and not a tax invoice.',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
          ),
        ],
      ),
    );

    final safeNumber = number.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '-');
    return ErpInvoicePdf(
      bytes: await document.save(),
      fileName: 'Quotation $safeNumber.pdf',
    );
  }

  static pw.Widget _section(String title, List<String> lines) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      PdfFonts.text(
        title,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: PdfColor.fromHex('#0B6F5F'),
        ),
      ),
      pw.SizedBox(height: 5),
      ...lines.map(
        (line) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: PdfFonts.text(line, style: const pw.TextStyle(fontSize: 9)),
        ),
      ),
    ],
  );

  static pw.Widget _totalRow(
    String label,
    int value, {
    bool emphasized = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Row(
      children: [
        PdfFonts.text(
          label,
          style: pw.TextStyle(
            fontSize: emphasized ? 11 : 9,
            fontWeight: emphasized ? pw.FontWeight.bold : null,
          ),
        ),
        pw.Spacer(),
        PdfFonts.text(
          money(value),
          style: pw.TextStyle(
            fontSize: emphasized ? 12 : 9,
            fontWeight: emphasized ? pw.FontWeight.bold : null,
          ),
        ),
      ],
    ),
  );

  static String _date(DateTime value) =>
      DateFormat('dd MMM yyyy').format(value);
  static String _textDate(String value) {
    final parsed = DateTime.tryParse(value);
    return parsed == null ? value : _date(parsed);
  }

  static String _quantity(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
}
