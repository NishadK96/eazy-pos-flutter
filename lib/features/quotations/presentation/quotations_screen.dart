import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:printing/printing.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/money.dart';
import '../../../shared/models/entities.dart';
import '../../../shared/widgets/document_preview_actions.dart';
import '../../../shared/widgets/localized_text.dart';
import '../../../shared/widgets/ui.dart';
import '../../backend/presentation/backend_controller.dart';
import '../../home/module_screens.dart' show PagePad;
import '../../invoice_layouts/domain/invoice_layout_entities.dart';
import '../../printers/application/printer_controller.dart';
import '../../printers/application/printer_document_service.dart';
import '../../store/app_store.dart';
import '../application/quotation_pdf.dart';

final quotationsProvider = FutureProvider.autoDispose<List<Sale>>(
  (ref) => ref.read(backendControllerProvider.notifier).loadQuotations(),
);

class QuotationsScreen extends ConsumerStatefulWidget {
  const QuotationsScreen({super.key});

  @override
  ConsumerState<QuotationsScreen> createState() => _QuotationsScreenState();
}

class _QuotationsScreenState extends ConsumerState<QuotationsScreen> {
  final searchController = TextEditingController();
  String query = '';
  String? preparingId;

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(quotationsProvider);
    final compact = MediaQuery.sizeOf(context).width < 760;
    return PagePad(
      child: RefreshIndicator(
        onRefresh: () => ref.refresh(quotationsProvider.future),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            PageTitle(
              'Quotations',
              subtitle: 'View, print and share saved customer quotations.',
              action: IconButton.outlined(
                tooltip: context.tr('Refresh quotations'),
                onPressed: result.isLoading
                    ? null
                    : () => ref.invalidate(quotationsProvider),
                icon: result.isLoading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
            ),
            const SizedBox(height: 16),
            result.when(
              loading: () => const _LoadingQuotations(),
              error: (error, _) => _QuotationError(
                message: error.toString(),
                onRetry: () => ref.invalidate(quotationsProvider),
              ),
              data: (all) {
                final normalized = query.trim().toLowerCase();
                final quotations =
                    all.where((sale) {
                      if (normalized.isEmpty) return true;
                      return sale.invoiceNo.toLowerCase().contains(
                            normalized,
                          ) ||
                          sale.customer.name.toLowerCase().contains(
                            normalized,
                          ) ||
                          sale.customer.phone.toLowerCase().contains(
                            normalized,
                          ) ||
                          sale.vehicleNumber.toLowerCase().contains(
                            normalized,
                          ) ||
                          sale.quotationAttention.toLowerCase().contains(
                            normalized,
                          );
                    }).toList()..sort(
                      (left, right) =>
                          right.createdAt.compareTo(left.createdAt),
                    );
                final total = all.fold<int>(
                  0,
                  (sum, quotation) => sum + quotation.total,
                );
                return Column(
                  children: [
                    _Summary(quotations: all, total: total),
                    const SizedBox(height: 14),
                    Surface(
                      child: Column(
                        children: [
                          TextField(
                            controller: searchController,
                            onChanged: (value) => setState(() => query = value),
                            decoration: InputDecoration(
                              hintText: context.tr(
                                'Search quotation, customer, phone or vehicle',
                              ),
                              prefixIcon: const Icon(Icons.search_rounded),
                              suffixIcon: query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: context.tr('Clear search'),
                                      onPressed: () {
                                        searchController.clear();
                                        setState(() => query = '');
                                      },
                                      icon: const Icon(Icons.close_rounded),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (quotations.isEmpty)
                            EmptyState(
                              query.isEmpty
                                  ? 'No quotations have been saved yet.'
                                  : 'No quotations match your search.',
                            )
                          else if (compact)
                            ...quotations.map(_mobileCard)
                          else
                            _table(quotations),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _table(List<Sale> quotations) => SizedBox(
    width: double.infinity,
    child: DataTable(
      showCheckboxColumn: false,
      columnSpacing: 24,
      headingRowColor: WidgetStateProperty.all(const Color(0xFFF6F9F8)),
      columns: const [
        DataColumn(label: Text('Quotation')),
        DataColumn(label: Text('Customer')),
        DataColumn(label: Text('Date')),
        DataColumn(label: Text('Valid until')),
        DataColumn(label: Text('Amount'), numeric: true),
        DataColumn(label: Text('Status')),
        DataColumn(label: Text('Actions')),
      ],
      rows: quotations
          .map((sale) {
            final busy = preparingId == sale.localId;
            return DataRow(
              onSelectChanged: (_) => _showDetails(sale),
              cells: [
                DataCell(
                  Text(
                    _quotationNumber(sale),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                DataCell(
                  SizedBox(
                    width: 180,
                    child: Text(
                      sale.customer.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                DataCell(Text(_date(sale.createdAt))),
                DataCell(Text(_displayDate(sale.quotationValidityDate))),
                DataCell(
                  RiyalAmount(
                    sale.total,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const DataCell(StatusBadge('Draft')),
                DataCell(
                  _Actions(
                    busy: busy,
                    onView: () => _showDetails(sale),
                    onPreview: () => _preview(sale),
                    onPrint: () => _print(sale),
                    onDownload: () => _export(sale, share: false),
                    onShare: () => _export(sale, share: true),
                  ),
                ),
              ],
            );
          })
          .toList(growable: false),
    ),
  );

  Widget _mobileCard(Sale sale) {
    final busy = preparingId == sale.localId;
    return InkWell(
      onTap: () => _showDetails(sale),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE3E9E6)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _quotationNumber(sale),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const StatusBadge('Draft'),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              sale.customer.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _SmallValue(
                    label: 'Date',
                    value: _date(sale.createdAt),
                  ),
                ),
                Expanded(
                  child: _SmallValue(
                    label: 'Valid until',
                    value: _displayDate(sale.quotationValidityDate),
                  ),
                ),
                RiyalAmount(
                  sale.total,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: _Actions(
                busy: busy,
                onView: () => _showDetails(sale),
                onPreview: () => _preview(sale),
                onPrint: () => _print(sale),
                onDownload: () => _export(sale, share: false),
                onShare: () => _export(sale, share: true),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDetails(Sale sale) => showDialog<void>(
    context: context,
    builder: (dialogContext) => _QuotationDetails(
      sale: sale,
      onPreview: () {
        Navigator.pop(dialogContext);
        _preview(sale);
      },
      onPrint: () {
        Navigator.pop(dialogContext);
        _print(sale);
      },
      onDownload: () => _export(sale, share: false),
      onShare: () => _export(sale, share: true),
    ),
  );

  Future<ErpInvoicePdf> _pdf(Sale sale) => QuotationPdf.build(
    quotation: sale,
    business: ref.read(appStoreProvider).business,
  );

  Future<void> _preview(Sale sale) async {
    if (preparingId != null) return;
    setState(() => preparingId = sale.localId);
    try {
      final file = await _pdf(sale);
      if (!mounted) return;
      await showDocumentPreviewPrintAction(
        context,
        title: _quotationNumber(sale),
        bytes: file.bytes,
        onPrint: () => _printBytes(file.bytes, file.fileName),
      );
    } catch (error) {
      _showFailure('Unable to preview quotation', error);
    } finally {
      if (mounted) setState(() => preparingId = null);
    }
  }

  Future<void> _print(Sale sale) async {
    if (preparingId != null) return;
    setState(() => preparingId = sale.localId);
    try {
      final file = await _pdf(sale);
      await _printBytes(file.bytes, file.fileName);
    } catch (error) {
      _showFailure('Unable to print quotation', error);
    } finally {
      if (mounted) setState(() => preparingId = null);
    }
  }

  Future<void> _printBytes(Uint8List bytes, String name) async {
    final printers = ref.read(printerControllerProvider).selectedPrinters;
    await PrinterDocumentService.printPdfBytes(
      bytes,
      name: name,
      printers: printers,
    );
  }

  Future<void> _export(Sale sale, {required bool share}) async {
    if (preparingId != null) return;
    final saveDialogTitle = context.tr('Save quotation PDF');
    setState(() => preparingId = sale.localId);
    try {
      final file = await _pdf(sale);
      final number = _quotationNumber(
        sale,
      ).replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '-');
      final filename = 'quotation-$number.pdf';
      if (share) {
        await Printing.sharePdf(bytes: file.bytes, filename: filename);
      } else {
        await FilePicker.platform.saveFile(
          dialogTitle: saveDialogTitle,
          fileName: filename,
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
          bytes: file.bytes,
        );
      }
    } catch (error) {
      _showFailure('Unable to prepare quotation PDF', error);
    } finally {
      if (mounted) setState(() => preparingId = null);
    }
  }

  void _showFailure(String message, Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${context.tr(message)}: $error')));
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.quotations, required this.total});
  final List<Sale> quotations;
  final int total;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth < 650 ? 2 : 3;
      return GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: columns,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: constraints.maxWidth < 650 ? 1.9 : 2.8,
        children: [
          MetricCard(
            label: 'Saved quotations',
            value: '${quotations.length}',
            icon: Icons.request_quote_outlined,
          ),
          MetricCard(
            label: 'Quotation value',
            value: money(total),
            icon: Icons.payments_outlined,
            tint: const Color(0xFF356A8A),
          ),
          if (columns == 3)
            MetricCard(
              label: 'Customers',
              value:
                  '${quotations.map((item) => item.customer.id).toSet().length}',
              icon: Icons.people_outline,
              tint: const Color(0xFF8A5A35),
            ),
        ],
      );
    },
  );
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.busy,
    required this.onView,
    required this.onPreview,
    required this.onPrint,
    required this.onDownload,
    required this.onShare,
  });
  final bool busy;
  final VoidCallback onView, onPreview, onPrint, onDownload, onShare;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (busy)
        const Padding(
          padding: EdgeInsets.all(10),
          child: SizedBox.square(
            dimension: 17,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      else ...[
        IconButton(
          tooltip: context.tr('View details'),
          onPressed: onView,
          icon: const Icon(Icons.visibility_outlined),
        ),
        IconButton(
          tooltip: context.tr('Preview'),
          onPressed: onPreview,
          icon: const Icon(Icons.picture_as_pdf_outlined),
        ),
        IconButton(
          tooltip: context.tr('Print'),
          onPressed: onPrint,
          icon: const Icon(Icons.print_outlined),
        ),
        PopupMenuButton<String>(
          tooltip: context.tr('More actions'),
          onSelected: (value) => value == 'download' ? onDownload() : onShare(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'download', child: Text('Download PDF')),
            PopupMenuItem(value: 'share', child: Text('Share PDF')),
          ],
        ),
      ],
    ],
  );
}

class _QuotationDetails extends StatelessWidget {
  const _QuotationDetails({
    required this.sale,
    required this.onPreview,
    required this.onPrint,
    required this.onDownload,
    required this.onShare,
  });
  final Sale sale;
  final VoidCallback onPreview, onPrint, onDownload, onShare;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(20),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760, maxHeight: 780),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 10, 14),
            child: Row(
              children: [
                const Icon(
                  Icons.request_quote_outlined,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _quotationNumber(sale),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        sale.customer.name,
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                const StatusBadge('Draft'),
                IconButton(
                  tooltip: context.tr('Close'),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 26,
                    runSpacing: 12,
                    children: [
                      _Detail(label: 'Created', value: _date(sale.createdAt)),
                      _Detail(
                        label: 'Valid until',
                        value: _displayDate(sale.quotationValidityDate),
                      ),
                      if (sale.quotationDeliveryDate.isNotEmpty)
                        _Detail(
                          label: 'Delivery date',
                          value: _displayDate(sale.quotationDeliveryDate),
                        ),
                      if (sale.quotationAttention.isNotEmpty)
                        _Detail(
                          label: 'Attention',
                          value: sale.quotationAttention,
                        ),
                      if (sale.vehicleNumber.isNotEmpty)
                        _Detail(
                          label: 'Vehicle number',
                          value: sale.vehicleNumber,
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Text(
                    context.tr('Items'),
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  ...sale.items.map(
                    (line) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              line.product.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text('${line.quantity} × '),
                          RiyalAmount(line.product.sellingPrice),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      Text(
                        context.tr('Total'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const Spacer(),
                      RiyalAmount(
                        sale.total,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  if (sale.quotationTerms.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _Detail(label: 'Terms', value: sale.quotationTerms),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Share'),
                ),
                TextButton.icon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Download'),
                ),
                OutlinedButton.icon(
                  onPressed: onPrint,
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Print'),
                ),
                FilledButton.icon(
                  onPressed: onPreview,
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('Preview'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 200,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(label),
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class _SmallValue extends StatelessWidget {
  const _SmallValue({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        context.tr(label),
        style: const TextStyle(color: AppColors.muted, fontSize: 11),
      ),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
    ],
  );
}

class _LoadingQuotations extends StatelessWidget {
  const _LoadingQuotations();
  @override
  Widget build(BuildContext context) => const Surface(
    child: SizedBox(
      height: 260,
      child: Center(child: CircularProgressIndicator()),
    ),
  );
}

class _QuotationError extends StatelessWidget {
  const _QuotationError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Surface(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 42,
            color: AppColors.muted,
          ),
          const SizedBox(height: 10),
          Text(
            context.tr('Unable to load quotations'),
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 5),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    ),
  );
}

String _quotationNumber(Sale sale) => sale.invoiceNo.trim().isEmpty
    ? 'Quotation #${sale.serverId ?? sale.localId}'
    : sale.invoiceNo.trim();

String _date(DateTime value) => DateFormat('dd MMM yyyy').format(value);

String _displayDate(String value) {
  if (value.trim().isEmpty) return '—';
  final parsed = DateTime.tryParse(value);
  return parsed == null ? value : _date(parsed);
}
