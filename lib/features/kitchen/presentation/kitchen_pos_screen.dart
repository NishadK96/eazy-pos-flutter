import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide Text;
import 'package:eazy_pos/shared/widgets/localized_text.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../apis/api.dart';
import '../../../core/network/api_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/money.dart';
import '../../../shared/models/entities.dart';
import '../../../shared/widgets/product_card_style_picker.dart';
import '../../../shared/widgets/modifier_selection_dialog.dart';
import '../../../shared/widgets/ui.dart' show ProductImage;
import '../../store/app_store.dart';
import '../../auth/auth_controller.dart';
import '../../backend/presentation/backend_controller.dart';
import '../../cash_register/domain/cash_register_entities.dart';
import '../../cash_register/presentation/cash_register_controller.dart';
import '../../cash_register/presentation/cash_register_dialog.dart';
import '../../invoice_layouts/presentation/invoice_layout_controller.dart';
import '../../offline_pos/presentation/offline_pos_controller.dart';
import '../../printers/application/printer_controller.dart';
import '../../settings/application/order_type_settings_controller.dart';
import '../../settings/application/payment_method_settings_controller.dart';
import '../../settings/application/pos_operating_mode_controller.dart';
import 'kitchen_printing_controller.dart';

typedef _RestaurantContext = ({
  List<RestaurantTable> tables,
  List<LookupOption> staff,
  List<LookupOption> serviceTypes,
});

final kitchenRestaurantContextProvider = FutureProvider.autoDispose
    .family<_RestaurantContext, String>((ref, locationId) async {
      Future<_RestaurantContext> load(String token) async {
        final api = ref.read(apiProvider);
        final results = await Future.wait<Object>([
          api.restaurantTables(token, locationId),
          api.restaurantServiceStaff(token),
          api.restaurantServiceTypes(token),
        ]);
        return (
          tables: results[0] as List<RestaurantTable>,
          staff: results[1] as List<LookupOption>,
          serviceTypes: results[2] as List<LookupOption>,
        );
      }

      var token = await ref.watch(authControllerProvider.future);
      if (token == null || token.isEmpty || token == 'offline-local-session') {
        throw const ApiException(
          'Restaurant order details require an online session.',
        );
      }
      try {
        return await load(token);
      } on ApiException catch (error) {
        if (error.statusCode != 401) rethrow;
        token = await ref
            .read(authControllerProvider.notifier)
            .refreshAccessToken();
        return load(token);
      }
    });

final kitchenOrdersProvider = FutureProvider.autoDispose
    .family<List<Sale>, String>((ref, locationId) async {
      // Capture provider dependencies before the first async gap. This provider
      // is refreshed explicitly, so its Ref can be disposed while an older
      // request is still completing.
      final api = ref.read(apiProvider);
      final store = ref.read(appStoreProvider);
      final auth = ref.read(authControllerProvider.notifier);
      final authFuture = ref.watch(authControllerProvider.future);

      Future<List<Sale>> load(String token) {
        return api.kitchenOrders(
          accessToken: token,
          products: store.products,
          customers: store.customers,
          locationId: locationId,
        );
      }

      var token = await authFuture;
      if (token == null || token.isEmpty || token == 'offline-local-session') {
        throw const ApiException(
          'Recent kitchen orders require an online session.',
        );
      }
      try {
        return await load(token);
      } on ApiException catch (error) {
        if (error.statusCode != 401) rethrow;
        token = await auth.refreshAccessToken();
        return load(token);
      }
    });

/// A restaurant-focused order entry surface. Its draft is deliberately separate
/// from the retail POS cart so switching modes cannot change an open sale.
class KitchenPosScreen extends ConsumerStatefulWidget {
  const KitchenPosScreen({super.key});

  @override
  ConsumerState<KitchenPosScreen> createState() => _KitchenPosScreenState();
}

class _KitchenResizeHandle extends StatelessWidget {
  const _KitchenResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.resizeLeftRight,
    child: Semantics(
      button: true,
      label: 'Resize current order panel',
      hint: 'Drag left or right to resize',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: SizedBox(
          width: 18,
          child: Center(
            child: Container(
              width: 6,
              height: 58,
              decoration: BoxDecoration(
                color: const Color(0xFFD3E1DC),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.drag_indicator_rounded,
                size: 13,
                color: AppColors.primary,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _KitchenCategoryOrderDialog extends StatefulWidget {
  const _KitchenCategoryOrderDialog({
    required this.categories,
    required this.dark,
  });

  final List<Category> categories;
  final bool dark;

  @override
  State<_KitchenCategoryOrderDialog> createState() =>
      _KitchenCategoryOrderDialogState();
}

class _KitchenCategoryOrderDialogState
    extends State<_KitchenCategoryOrderDialog> {
  late final List<Category> _items = [...widget.categories];

  void _move(int oldIndex, int newIndex) {
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    if (target == oldIndex) return;
    setState(() => _items.insert(target, _items.removeAt(oldIndex)));
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.dark;
    final colors = dark
        ? const ColorScheme.dark(
            surface: Color(0xFF10232D),
            onSurface: Colors.white,
            onSurfaceVariant: Color(0xFFA8B7BE),
            primary: Color(0xFF2BC5A0),
            onPrimary: Color(0xFF092820),
          )
        : Theme.of(context).colorScheme;
    final card = dark ? const Color(0xFF172C37) : const Color(0xFFF5F9F8);
    final border = dark ? const Color(0xFF314752) : const Color(0xFFDCE5E2);
    final changed = _items.asMap().entries.any(
      (entry) => entry.value.id != widget.categories[entry.key].id,
    );
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    return Theme(
      data: Theme.of(context).copyWith(colorScheme: colors),
      child: AlertDialog(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
        titlePadding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18),
        actionsPadding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
        title: Row(
          children: [
            Icon(Icons.reorder_rounded, color: colors.primary),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'Reorder kitchen categories',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: colors.onSurface,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          height: min(370, MediaQuery.sizeOf(context).height * .48),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.drag_indicator_rounded, color: colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Drag the dotted handle up or down, or use the arrows. Then select Save order.',
                        style: TextStyle(fontSize: 12, color: colors.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: _items.length,
                  onReorder: _move,
                  itemBuilder: (_, index) {
                    final category = _items[index];
                    final name = arabic && category.nameAr.trim().isNotEmpty
                        ? category.nameAr
                        : !arabic && category.nameEn.trim().isNotEmpty
                        ? category.nameEn
                        : category.name;
                    return Container(
                      key: ValueKey(category.id),
                      margin: const EdgeInsets.only(bottom: 5),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: border),
                      ),
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: index,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.grab,
                              child: Tooltip(
                                message: context.tr('Drag to reorder'),
                                child: SizedBox.square(
                                  dimension: 40,
                                  child: Icon(
                                    Icons.drag_indicator_rounded,
                                    color: colors.primary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 27,
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: colors.onSurface,
                                    ),
                                  ),
                                  if (!category.active)
                                    Text(
                                      'Inactive',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: context.tr('Move up'),
                            onPressed: index == 0
                                ? null
                                : () => _move(index, index - 1),
                            icon: const Icon(Icons.keyboard_arrow_up),
                          ),
                          IconButton(
                            tooltip: context.tr('Move down'),
                            onPressed: index == _items.length - 1
                                ? null
                                : () => _move(index, index + 2),
                            icon: const Icon(Icons.keyboard_arrow_down),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: changed ? () => Navigator.pop(context, _items) : null,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Save order'),
          ),
        ],
      ),
    );
  }
}

enum _KitchenLayout { modern, light, classic }

enum _KitchenCardSize {
  compact('Compact', .76),
  small('Small', .88),
  standard('Standard', 1),
  large('Large', 1.2);

  const _KitchenCardSize(this.label, this.scale);

  final String label;
  final double scale;
}

class _KitchenPosScreenState extends ConsumerState<KitchenPosScreen> {
  static const _border = Color(0xFFDCE5E2);
  static const _cardSizePreference = 'kitchen_pos_product_card_size';
  Color get _desktopCanvas =>
      _lightLayout ? const Color(0xFFEDF4F2) : const Color(0xFF091720);
  Color get _desktopSurface =>
      _lightLayout ? const Color(0xFFFFFFFF) : const Color(0xFF10232D);
  Color get _desktopSurfaceRaised =>
      _lightLayout ? const Color(0xFFF5F9F8) : const Color(0xFF172C37);
  Color get _desktopBorder =>
      _lightLayout ? const Color(0xFFCCDCD7) : const Color(0xFF314752);
  Color get _desktopTextMuted =>
      _lightLayout ? const Color(0xFF506762) : const Color(0xFFA8B7BE);
  Color get _desktopAccent =>
      _lightLayout ? const Color(0xFF08745D) : const Color(0xFF2BC5A0);
  static const _categoryBackgrounds = <Color>[
    Color(0xFFE8F7ED),
    Color(0xFFE9F3FF),
    Color(0xFFFFF1E7),
    Color(0xFFF2ECFF),
    Color(0xFFFFEAF1),
    Color(0xFFE8FAF7),
  ];
  static const _categoryBorders = <Color>[
    Color(0xFFBDE4C9),
    Color(0xFFBEDAF7),
    Color(0xFFF4CBAE),
    Color(0xFFD8C8F3),
    Color(0xFFF1BED0),
    Color(0xFFB8E8E0),
  ];
  static const _productBackgrounds = <Color>[
    Color(0xFFFFF8E3),
    Color(0xFFEAF6FF),
    Color(0xFFFFEDF3),
    Color(0xFFEBF8ED),
    Color(0xFFFFF0E6),
    Color(0xFFF2EDFF),
  ];
  static const _productBorders = <Color>[
    Color(0xFFF1D797),
    Color(0xFFB9DDF3),
    Color(0xFFF2C2D2),
    Color(0xFFBFE1C5),
    Color(0xFFF0C8AD),
    Color(0xFFD6C8F0),
  ];
  final _search = TextEditingController();
  final _focus = FocusNode();
  final Map<String, CartLine> _lines = {};
  String _category = '';
  String? _selectedService;
  String get _service {
    final settings = ref.read(orderTypeSettingsProvider);
    final selected = _selectedService;
    return selected != null &&
            settings.apply().any((item) => item.code == selected)
        ? selected
        : settings.kitchenDefault;
  }

  String? _tableId;
  String? _waiterId;
  String? _savedServiceTypeId;
  String? get _serviceTypeId {
    final service = _service;
    if (_selectedService == service && _savedServiceTypeId != null) {
      return _savedServiceTypeId;
    }
    final locationId = _locationId(ref.read(appStoreProvider));
    if (locationId == null || locationId.isEmpty) return null;
    final serviceTypes = ref
        .read(kitchenRestaurantContextProvider(locationId))
        .asData
        ?.value
        .serviceTypes;
    final code = service.toLowerCase().replaceAll(' ', '');
    return serviceTypes
        ?.where((option) {
          final name = option.name.toLowerCase().replaceAll(' ', '');
          return name.isNotEmpty &&
              (name.contains(code) || code.contains(name));
        })
        .firstOrNull
        ?.id;
  }

  String _note = '';
  int _guests = 1;
  int _grossDiscount = 0;
  int _addQuantity = 1;
  String? _selectedLineId;
  String _keypadInput = '';
  String _keypadMode = 'qty';
  bool _showMobileOrder = false;
  _KitchenLayout _layout = _KitchenLayout.modern;
  _KitchenCardSize _cardSize = _KitchenCardSize.standard;
  bool get _modernLayout => _layout != _KitchenLayout.classic;
  bool get _lightLayout => _layout == _KitchenLayout.light;
  Color get _desktopText => _lightLayout ? AppColors.ink : Colors.white;
  bool _sending = false;
  bool _savingCategoryOrder = false;
  double _classicOrderPanelWidth = 360;
  double _categoryPanelWidth = 148;
  String? _pendingClientTransactionId;
  String? _offlineDraftClientId;
  String? _savedTransactionId;
  Sale? _activeOrder;

  bool get _orderLocked => _pendingClientTransactionId != null;

  bool _useModernDesktop(BuildContext context) =>
      _modernLayout && MediaQuery.sizeOf(context).width >= 1100;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLayoutPreference());
  }

  Future<void> _loadLayoutPreference() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted) return;
    final cardSizeName = preferences.getString(_cardSizePreference);
    setState(() {
      _cardSize = _KitchenCardSize.values.firstWhere(
        (size) => size.name == cardSizeName,
        orElse: () => _KitchenCardSize.standard,
      );
      _layout = preferences.getBool('kitchen_pos_light_layout') == true
          ? _KitchenLayout.light
          : preferences.getBool('kitchen_pos_modern_layout') == false
          ? _KitchenLayout.classic
          : _KitchenLayout.modern;
    });
  }

  Future<void> _selectCardSize(_KitchenCardSize size) async {
    if (_cardSize == size) return;
    setState(() => _cardSize = size);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_cardSizePreference, size.name);
  }

  Future<void> _selectLayout(_KitchenLayout layout) async {
    if (_layout == layout) return;
    setState(() => _layout = layout);
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      'kitchen_pos_light_layout',
      layout == _KitchenLayout.light,
    );
    await preferences.setBool(
      'kitchen_pos_modern_layout',
      layout != _KitchenLayout.classic,
    );
  }

  bool get _offlineSession =>
      ref.read(authControllerProvider).asData?.value == 'offline-local-session';

  bool _isConnectionFailure(Object error) =>
      error is TimeoutException ||
      error is http.ClientException ||
      (error is ApiException &&
          ((error.statusCode == null &&
                  (error.message.contains('could not be reached') ||
                      error.message.contains('did not respond'))) ||
              error.statusCode == 408 ||
              error.statusCode == 429 ||
              (error.statusCode ?? 0) >= 500));

  Future<Sale> _queueOfflineOrder(
    String status, {
    String paymentMethod = 'due',
    String? cashRegisterId,
    bool resetOrder = true,
  }) async {
    final store = ref.read(appStoreProvider);
    final locationId = _locationId(store);
    final customer = _customer(store);
    if (locationId == null || customer == null) {
      throw const ApiException(
        'Cached customer and location data are required.',
      );
    }
    _pendingClientTransactionId ??=
        _offlineDraftClientId ?? _newClientTransactionId();
    final sale = await ref
        .read(offlinePosControllerProvider.notifier)
        .queueKitchenOrder(
          locationId: locationId,
          customer: customer,
          lines: _lines.values.toList(growable: false),
          clientTransactionId: _pendingClientTransactionId!,
          saleNote: _composedSaleNote(),
          status: status,
          tableId: _service == 'Dine in' ? _tableId : null,
          serviceStaffId: _waiterId,
          serviceTypeId: _serviceTypeId,
          grossDiscount: _grossDiscount,
          paymentMethod: paymentMethod,
          cashRegisterId: cashRegisterId,
        );
    if (!mounted) return sale;
    if (resetOrder) _resetOrder();
    _show(
      '${status == 'draft'
          ? 'Offline draft'
          : paymentMethod == 'due'
          ? 'Offline sale'
          : 'Offline paid sale'} ${sale.invoiceNo} saved successfully on this device. It will sync automatically when the connection returns. No kitchen ticket has printed yet.',
    );
    return sale;
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  List<Product> _visible(AppState store) {
    final query = _search.text.trim().toLowerCase();
    return store.products
        .where((product) {
          if (!product.active) return false;
          if (_category.isNotEmpty && product.categoryId != _category)
            return false;
          if (query.isEmpty) return true;
          return product.name.toLowerCase().contains(query) ||
              product.nameEn.toLowerCase().contains(query) ||
              product.nameAr.contains(query) ||
              product.sku.toLowerCase().contains(query) ||
              product.barcode.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _add(Product product) async {
    if (_orderLocked) return;
    final modifiers = await selectProductModifiers(
      context,
      product,
      light: _lightLayout,
    );
    if (modifiers == null || !mounted || _orderLocked) return;
    final newLine = CartLine(
      product: product,
      quantity: _addQuantity.toDouble(),
      modifiers: modifiers,
      // A configured product added from the catalog is a distinct order line.
      // This lets the cashier add the same product again with its own choices.
      instanceId: modifiers.isEmpty ? null : _newLineInstanceId(product.id),
    );
    final lineId = newLine.lineId;
    setState(() {
      final old = _lines[lineId];
      _lines[lineId] = old == null
          ? newLine
          : old.copyWith(quantity: old.quantity + _addQuantity);
    });
    _focus.requestFocus();
  }

  Future<void> _editModifiers(CartLine line) async {
    if (_orderLocked) return;
    final modifiers = await selectProductModifiers(
      context,
      line.product,
      initialModifiers: line.modifiers,
      confirmLabel: 'Update item',
      light: _lightLayout,
    );
    if (modifiers == null || !mounted || _orderLocked) return;
    final updated = line.copyWith(
      modifiers: modifiers,
      // Editing from the cart must keep this item independent rather than
      // merging it into another line that happens to share the same choices.
      instanceId: line.instanceId ?? _newLineInstanceId(line.product.id),
    );
    setState(() {
      _lines.remove(line.lineId);
      final existing = _lines[updated.lineId];
      _lines[updated.lineId] = existing == null
          ? updated
          : existing.copyWith(
              quantity: existing.quantity + updated.quantity,
              discount: existing.discount + updated.discount,
              itemNote: existing.itemNote.isEmpty
                  ? updated.itemNote
                  : existing.itemNote,
            );
      _selectedLineId = updated.lineId;
    });
  }

  String _newLineInstanceId(String productId) =>
      'kitchen-$productId-${DateTime.now().microsecondsSinceEpoch}';

  void _changeQuantity(CartLine line, int delta) {
    if (_orderLocked) return;
    setState(() {
      final next = line.quantity + delta;
      if (next <= 0) {
        _lines.remove(line.lineId);
      } else {
        _lines[line.lineId] = line.copyWith(quantity: next);
      }
    });
  }

  void _selectLine(CartLine line) => setState(() {
    _selectedLineId = line.lineId;
    _keypadInput = '';
  });

  void _keypadPress(String value) {
    if (_orderLocked || _lines.isEmpty) return;
    if (value == 'clear') {
      setState(() => _keypadInput = '');
      return;
    }
    if (value == 'backspace') {
      setState(() {
        if (_keypadInput.isNotEmpty) {
          _keypadInput = _keypadInput.substring(0, _keypadInput.length - 1);
        }
      });
      return;
    }
    final line = _lines[_selectedLineId] ?? _lines.values.last;
    if (value == '+' || value == '-') {
      _changeQuantity(line, value == '+' ? 1 : -1);
      return;
    }
    if (value == 'enter') {
      final enteredAmount = double.tryParse(_keypadInput);
      final enteredQuantity = int.tryParse(_keypadInput);
      if (_keypadMode == 'discount' &&
          enteredAmount != null &&
          enteredAmount >= 0) {
        setState(() {
          final maximum = _lines.values.fold<int>(
            0,
            (sum, item) => sum + _kitchenLineTotal(item),
          );
          _grossDiscount = min((enteredAmount * 100).round(), maximum);
          _keypadInput = '';
        });
      } else if (_keypadMode == 'price' &&
          enteredAmount != null &&
          enteredAmount >= 0) {
        setState(() {
          final updated = line.copyWith(
            unitPriceOverride: (enteredAmount * 100).round(),
          );
          _lines[line.lineId] = updated.copyWith(
            discount: updated.discount.clamp(0, updated.subtotal),
          );
          final maximum = _lines.values.fold<int>(
            0,
            (sum, item) => sum + _kitchenLineTotal(item),
          );
          _grossDiscount = min(_grossDiscount, maximum);
          _keypadInput = '';
          _selectedLineId = line.lineId;
        });
      } else if (enteredQuantity != null &&
          enteredQuantity > 0 &&
          enteredQuantity <= 999) {
        setState(() {
          _lines[line.lineId] = line.copyWith(
            quantity: enteredQuantity.toDouble(),
          );
          _keypadInput = '';
          _selectedLineId = line.lineId;
        });
      }
      return;
    }
    if (value == '.') {
      if (_keypadMode != 'qty' && !_keypadInput.contains('.')) {
        setState(
          () => _keypadInput = _keypadInput.isEmpty ? '0.' : '$_keypadInput.',
        );
      }
      return;
    }
    final maximumLength = _keypadMode == 'qty' ? 3 : 8;
    if (_keypadInput.length < maximumLength) {
      setState(() => _keypadInput += value);
    }
  }

  void _show(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _sendToKitchen() => unawaited(_submitKitchenOrder());

  void _sendToKitchenAndPrint() =>
      unawaited(_submitKitchenOrder(printBill: true));

  String _composedSaleNote() => [
    _service,
    'Pax $_guests',
    if (_note.trim().isNotEmpty) _note.trim(),
  ].join(' · ');

  // Kitchen lines do not support per-item discounts. Build the payable amount
  // from the visible line subtotal so stale/legacy discount values cannot make
  // a newly entered kitchen order appear as zero.
  int _kitchenLineTotal(CartLine line) =>
      line.subtotal + (line.product.sellingPriceIncludesTax ? 0 : line.tax);

  Customer? _customer(AppState store) =>
      store.customer ?? store.customers.firstOrNull;

  String? _locationId(AppState store) {
    final access = ref.read(posRoleAccessProvider).asData?.value.access;
    if (access == null) return null;
    final kitchen = ref.read(kitchenPrintingControllerProvider).asData?.value;
    if (kitchen != null && access.allowsLocation(kitchen.locationId)) {
      return kitchen.locationId;
    }
    final register = ref.read(cashRegisterControllerProvider).asData?.value;
    if (register != null && access.allowsLocation(register.locationId)) {
      return register.locationId;
    }
    if (store.locations.any((item) => item.id == access.defaultLocationId)) {
      return access.defaultLocationId;
    }
    return store.locations
        .where((item) => access.allowsLocation(item.id))
        .firstOrNull
        ?.id;
  }

  void _newOrder() {
    if (_lines.isNotEmpty || _orderLocked || _savedTransactionId != null) {
      _show('Save or clear the current order before starting another one.');
      return;
    }
    _resetOrder();
  }

  void _resetOrder() {
    setState(() {
      _lines.clear();
      _activeOrder = null;
      _savedTransactionId = null;
      _pendingClientTransactionId = null;
      _offlineDraftClientId = null;
      _tableId = null;
      _waiterId = null;
      _savedServiceTypeId = null;
      _selectedService = null;
      _guests = 1;
      _note = '';
      _grossDiscount = 0;
      _selectedLineId = null;
      _keypadInput = '';
      _keypadMode = 'qty';
      _showMobileOrder = false;
    });
  }

  Sale? _currentSale(String transactionId, String paymentMethod) {
    final store = ref.read(appStoreProvider);
    final customer = _customer(store);
    if (customer == null) return null;
    final lines = _lines.values.toList(growable: false);
    final total = max(
      0,
      lines.fold<int>(0, (sum, line) => sum + _kitchenLineTotal(line)) -
          _grossDiscount,
    );
    return Sale(
      localId: 'server-$transactionId',
      serverId: transactionId,
      invoiceNo: _activeOrder?.invoiceNo ?? '',
      createdAt: _activeOrder?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      customer: customer,
      items: lines,
      paymentMethod: paymentMethod,
      total: total,
      tax: lines.fold<int>(0, (sum, line) => sum + line.tax),
      discount: _grossDiscount,
      syncStatus: SyncStatus.synced,
      status: 'final',
      paymentStatus: paymentMethod == 'due' ? 'due' : 'paid',
      locationId: _locationId(store) ?? '',
      tableId: _tableId ?? '',
      waiterId: _waiterId ?? '',
      serviceTypeId: _serviceTypeId ?? '',
      saleNote: _composedSaleNote(),
      isKitchenOrder: true,
    );
  }

  Future<void> _printBill({String? paymentMethod}) async {
    final transactionId = _savedTransactionId;
    if (transactionId == null || transactionId.isEmpty) {
      _show('Save or send the order before printing its bill.');
      return;
    }
    final sale = _currentSale(
      transactionId,
      paymentMethod ?? _activeOrder?.paymentMethod ?? 'due',
    );
    if (sale == null) return;
    setState(() => _sending = true);
    try {
      final store = ref.read(appStoreProvider);
      final printers = ref.read(printerControllerProvider);
      await ref
          .read(invoiceLayoutControllerProvider.notifier)
          .printSale(
            sale: sale,
            businessName: store.business?.name ?? 'Eazy POS',
            settings: printers.settings,
            printers: printers.selectedPrinters,
            arabic:
                Localizations.localeOf(context).languageCode.toLowerCase() ==
                'ar',
          );
      if (mounted) _show('Bill sent to the selected billing printer.');
    } catch (error) {
      if (mounted) _show('Unable to print this bill: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _previewSavedOrderBill(Sale order) async {
    try {
      final store = ref.read(appStoreProvider);
      final printers = ref.read(printerControllerProvider);
      await ref
          .read(invoiceLayoutControllerProvider.notifier)
          .previewSale(
            sale: order,
            businessName: store.business?.name ?? 'Eazy POS',
            settings: printers.settings,
            arabic:
                Localizations.localeOf(context).languageCode.toLowerCase() ==
                'ar',
          );
    } catch (error) {
      if (mounted) _show('Unable to preview this bill: $error');
    }
  }

  Future<void> _printSavedOrderBill(Sale order) async {
    try {
      final store = ref.read(appStoreProvider);
      final printers = ref.read(printerControllerProvider);
      await ref
          .read(invoiceLayoutControllerProvider.notifier)
          .printSale(
            sale: order,
            businessName: store.business?.name ?? 'Eazy POS',
            settings: printers.settings,
            printers: printers.selectedPrinters,
            arabic:
                Localizations.localeOf(context).languageCode.toLowerCase() ==
                'ar',
          );
      if (mounted) _show('Bill sent to the selected billing printer.');
    } catch (error) {
      if (mounted) _show('Unable to print this bill: $error');
    }
  }

  Future<void> _printSavedKitchenTicket(Sale order) async {
    final transactionId = order.serverId;
    if (transactionId == null || transactionId.isEmpty) {
      _show('This order has not been synced yet.');
      return;
    }
    try {
      final summary = await ref
          .read(kitchenPrintingControllerProvider.notifier)
          .reprintTransaction(
            transactionId,
            locationId: order.locationId.isEmpty
                ? (_locationId(ref.read(appStoreProvider)) ?? '')
                : order.locationId,
          );
      if (mounted) _show('${summary.printedCount} kitchen ticket(s) printed.');
    } catch (error) {
      if (mounted) _show('Unable to print the kitchen ticket: $error');
    }
  }

  Future<void> _processKitchenPrintingInBackground(
    String transactionId,
    String locationId,
  ) async {
    try {
      final summary = await ref
          .read(kitchenPrintingControllerProvider.notifier)
          .processTransaction(transactionId, locationId: locationId);
      if (mounted) {
        _show('${summary.printedCount} kitchen ticket(s) printed.');
      }
    } catch (error) {
      debugPrint('Kitchen printing needs attention: $error');
      if (mounted) {
        _show(
          'Order #$transactionId is paid and saved, but no kitchen ticket was printed. Retry it from Kitchen orders.',
        );
      }
    }
  }

  Future<void> _billAndPay({
    bool sendToKitchen = true,
    bool printCustomerBill = true,
  }) async {
    if (_sending || _lines.isEmpty) return;
    final store = ref.read(appStoreProvider);
    final locationId = _locationId(store);
    final customer = _customer(store);
    if (locationId == null || locationId.isEmpty || customer == null) {
      _show('Refresh customer and business location data before billing.');
      return;
    }
    final register = await _requireOpenRegister(locationId);
    if (register == null || !mounted) return;
    final methods = ref
        .read(paymentMethodSettingsProvider)
        .apply(
          ref
              .read(appStoreProvider)
              .checkoutPaymentOptions
              .where((option) {
                // Bill & Pay settles the order. Create Bill handles unpaid orders.
                final code = option.code.trim().toLowerCase();
                return code.isNotEmpty && code != 'due' && code != 'credit';
              })
              .toList(growable: false),
        );
    if (methods.isEmpty) {
      _show('No payment methods are enabled for this location.');
      return;
    }
    final method = await showDialog<PaymentOption>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Select payment method'),
        children: [
          for (final option in methods)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, option),
              child: ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: Text(option.label),
              ),
            ),
        ],
      ),
    );
    if (method == null || !mounted) return;
    setState(() => _sending = true);
    try {
      if (_offlineSession && _savedTransactionId == null) {
        final sale = await _queueOfflineOrder(
          'final',
          paymentMethod: method.code,
          cashRegisterId: register.id,
          resetOrder: false,
        );
        if (!mounted) return;
        if (printCustomerBill) await _printSavedOrderBill(sale);
        if (!mounted) return;
        _resetOrder();
        return;
      }
      var transactionId = _savedTransactionId;
      final creatingSale = transactionId == null;
      if (transactionId == null) {
        _pendingClientTransactionId ??= _newClientTransactionId();
        transactionId = await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .createKitchenOrder(
              locationId: locationId,
              cashRegisterId: register.id,
              customer: customer,
              lines: _lines.values.toList(growable: false),
              clientTransactionId: _pendingClientTransactionId!,
              saleNote: _composedSaleNote(),
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              grossDiscount: _grossDiscount,
              paymentMethod: method.code,
            );
        if (!mounted) return;
        setState(() => _savedTransactionId = transactionId);
      }
      if (!creatingSale) {
        await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .updateKitchenOrder(
              transactionId: transactionId,
              locationId: locationId,
              customer: customer,
              lines: _lines.values.toList(growable: false),
              status: 'final',
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              saleNote: _composedSaleNote(),
              grossDiscount: _grossDiscount,
              paymentMethod: method.code,
            );
      }
      // Kitchen job generation can involve several backend requests and must
      // not hold up the customer receipt after payment has succeeded.
      if (sendToKitchen) {
        unawaited(
          _processKitchenPrintingInBackground(transactionId, locationId),
        );
      }
      if (!mounted) return;
      if (printCustomerBill) {
        await _printBill(paymentMethod: method.code);
      }
      if (!mounted) return;
      ref.invalidate(kitchenOrdersProvider(locationId));
      _resetOrder();
      _show(
        sendToKitchen
            ? 'Order #$transactionId paid. Receipt sent to the billing printer; kitchen printing is continuing.'
            : 'Order #$transactionId billed and paid.',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 403 && _savedTransactionId != null) {
        _show(
          'This account cannot settle an existing kitchen order. Ask an administrator to enable the Sell Update permission.',
        );
      } else if (error.statusCode == 403) {
        _show(
          'This account cannot create a sale. Ask an administrator to enable Sell Create or Direct Sell Access.',
        );
      } else if (_savedTransactionId == null &&
          _isConnectionFailure(error) &&
          ref.read(offlinePosControllerProvider).value?.ready == true) {
        try {
          final sale = await _queueOfflineOrder(
            'final',
            paymentMethod: method.code,
            cashRegisterId: register.id,
            resetOrder: false,
          );
          if (!mounted) return;
          if (printCustomerBill) await _printSavedOrderBill(sale);
          if (!mounted) return;
          _resetOrder();
        } catch (queueError) {
          if (mounted) {
            _show('Unable to save this paid order offline: $queueError');
          }
        }
      } else {
        _show('Billing needs attention: ${error.message}');
      }
    } catch (error) {
      if (mounted) _show('Billing needs attention: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<CashRegister?> _requireOpenRegister(String locationId) async {
    CashRegister? register;
    try {
      register = await ref.read(cashRegisterControllerProvider.future);
    } catch (error) {
      debugPrint('Unable to load cash register: $error');
    }
    if (!mounted) return null;
    if (register == null) {
      final openRegister = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.point_of_sale_rounded),
          title: const Text('Open cash register'),
          content: const Text(
            'A cashier shift must be open before Bill & Pay can complete this order. The current order is safe and will not be created again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not now'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.lock_open_rounded),
              label: const Text('Open register'),
            ),
          ],
        ),
      );
      if (openRegister != true || !mounted) return null;
      await showCashRegisterDialog(context, ref);
      if (!mounted) return null;
      register = ref.read(cashRegisterControllerProvider).asData?.value;
      if (register == null) {
        _show('Open the cash register to continue with Bill & Pay.');
        return null;
      }
    }
    if (register.locationId != locationId) {
      _show(
        'The open cash register belongs to another location. Close it and open a register for this store.',
      );
      return null;
    }
    return register;
  }

  Future<void> _editGrossDiscount() async {
    var text = (_grossDiscount / 100).toStringAsFixed(2);
    final amount = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Order discount'),
        content: TextFormField(
          initialValue: text,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Discount amount'),
          onChanged: (value) => text = value,
          onFieldSubmitted: (_) => Navigator.pop(
            dialogContext,
            ((double.tryParse(text) ?? 0) * 100).round(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              dialogContext,
              ((double.tryParse(text) ?? 0) * 100).round(),
            ),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    final maximum = _lines.values.fold<int>(
      0,
      (sum, line) => sum + _kitchenLineTotal(line),
    );
    if (amount != null && mounted) {
      setState(() => _grossDiscount = amount.clamp(0, maximum));
    }
  }

  Future<void> _editItemNote(CartLine line) async {
    final controller = TextEditingController(text: line.itemNote);
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Note: ${line.product.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Preparation instructions for this item',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (note != null && mounted) {
      setState(() {
        _lines[line.lineId] = line.copyWith(itemNote: note.trim());
      });
    }
  }

  Future<void> _editLinePrice(CartLine line) async {
    final controller = TextEditingController(
      text: (line.unitPrice / 100).toStringAsFixed(2),
    );
    final formKey = GlobalKey<FormState>();
    final amount = await showDialog<int>(
      context: context,
      builder: (dialogContext) {
        void apply() {
          if (!formKey.currentState!.validate()) return;
          Navigator.pop(
            dialogContext,
            (double.parse(controller.text.trim()) * 100).round(),
          );
        }

        return AlertDialog(
          title: Text('Edit price: ${line.product.name}'),
          content: Form(
            key: formKey,
            child: TextFormField(
              key: const ValueKey('kitchen-line-price-field'),
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Unit price',
                helperText: 'Price for one item, before modifiers',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
              validator: (value) {
                final parsed = double.tryParse(value?.trim() ?? '');
                return parsed == null || parsed < 0
                    ? 'Enter a valid amount'
                    : null;
              },
              onFieldSubmitted: (_) => apply(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            if (line.unitPriceOverride != null)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, -1),
                child: const Text('Use default price'),
              ),
            FilledButton(onPressed: apply, child: const Text('Apply')),
          ],
        );
      },
    );
    Future<void>.delayed(const Duration(milliseconds: 400), controller.dispose);
    if (amount == null || !mounted || _orderLocked) return;
    setState(() {
      final current = _lines[line.lineId];
      if (current == null) return;
      final updated = amount < 0
          ? current.copyWith(clearUnitPriceOverride: true)
          : current.copyWith(unitPriceOverride: amount);
      _lines[line.lineId] = updated.copyWith(
        discount: updated.discount.clamp(0, updated.subtotal),
      );
      _selectedLineId = line.lineId;
    });
  }

  Future<void> _showOrders(String locationId, {required bool heldOnly}) async {
    if (_orderLocked) return;
    setState(() => _sending = true);
    try {
      final localOrders = ref
          .read(appStoreProvider)
          .sales
          .where(
            (order) =>
                order.isKitchenOrder &&
                order.locationId == locationId &&
                order.localId.startsWith('kitchen-') &&
                order.serverId == null,
          )
          .toList();
      List<Sale> remoteOrders = const [];
      if (!_offlineSession) {
        try {
          remoteOrders = await ref.refresh(
            kitchenOrdersProvider(locationId).future,
          );
        } catch (error) {
          if (localOrders.isEmpty) rethrow;
        }
      }
      final loadedOrders = [...localOrders, ...remoteOrders];
      final orders = loadedOrders
          .where(
            (order) =>
                heldOnly ? order.status == 'draft' : order.status != 'draft',
          )
          .toList(growable: false);
      if (!mounted) return;
      final selected = await showDialog<Sale>(
        context: context,
        builder: (dialogContext) {
          final theme = Theme.of(dialogContext);
          final colors = theme.colorScheme;
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700, maxHeight: 640),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: colors.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            heldOnly
                                ? Icons.pause_circle_outline_rounded
                                : Icons.history_rounded,
                            color: colors.onPrimaryContainer,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                heldOnly ? 'Held orders' : 'Previous orders',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              SizedBox(height: 3),
                              Text(
                                heldOnly
                                    ? 'Resume an unfinished kitchen order.'
                                    : 'Review completed and recently sent kitchen orders.',
                                style: TextStyle(color: Color(0xFF64726F)),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _OrderSummaryChip(
                      icon: heldOnly
                          ? Icons.pause_circle_outline_rounded
                          : Icons.receipt_long_outlined,
                      label: heldOnly
                          ? '${orders.length} held'
                          : '${orders.length} previous',
                      emphasized: orders.isNotEmpty,
                    ),
                    const SizedBox(height: 16),
                    if (orders.isEmpty)
                      Container(
                        height: 190,
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLowest,
                          border: Border.all(color: colors.outlineVariant),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.receipt_long_outlined, size: 38),
                            SizedBox(height: 10),
                            Text(
                              'No kitchen orders found',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                            SizedBox(height: 4),
                            Text(
                              heldOnly
                                  ? 'Held orders will appear here.'
                                  : 'Sent kitchen orders will appear here.',
                            ),
                          ],
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: orders.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, index) {
                            final order = orders[index];
                            final isHeld = heldOnly;
                            final orderNumber = order.invoiceNo.isEmpty
                                ? 'Order #${order.serverId}'
                                : order.invoiceNo;
                            return Material(
                              color: isHeld
                                  ? const Color(0xFFF2FAF7)
                                  : colors.surfaceContainerLowest,
                              shape: RoundedRectangleBorder(
                                side: BorderSide(
                                  color: isHeld
                                      ? const Color(0xFFB9E3D6)
                                      : colors.outlineVariant,
                                ),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () {
                                  if (isHeld) {
                                    Navigator.pop(dialogContext, order);
                                  } else {
                                    showDialog<void>(
                                      context: dialogContext,
                                      builder: (_) => KitchenOrderDetailsDialog(
                                        order: order,
                                        onPreviewBill: () =>
                                            _previewSavedOrderBill(order),
                                        onPrintBill: () =>
                                            _printSavedOrderBill(order),
                                        onPrintKitchenTicket:
                                            order.serverId == null
                                            ? null
                                            : () => _printSavedKitchenTicket(
                                                order,
                                              ),
                                      ),
                                    );
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final compact =
                                          constraints.maxWidth < 500;
                                      final details = Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  orderNumber,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 17,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 9,
                                                      vertical: 4,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: isHeld
                                                      ? const Color(0xFFD5F3E9)
                                                      : colors
                                                            .secondaryContainer,
                                                  borderRadius:
                                                      BorderRadius.circular(99),
                                                ),
                                                child: Text(
                                                  isHeld
                                                      ? 'Held'
                                                      : order.paymentStatus,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            order.customer.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Color(0xFF56635F),
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            '${order.items.length} items  •  ${money(order.total)}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      );
                                      final action = FilledButton.icon(
                                        onPressed: () {
                                          if (isHeld) {
                                            Navigator.pop(dialogContext, order);
                                          } else {
                                            showDialog<void>(
                                              context: dialogContext,
                                              builder: (_) =>
                                                  KitchenOrderDetailsDialog(
                                                    order: order,
                                                    onPreviewBill: () =>
                                                        _previewSavedOrderBill(
                                                          order,
                                                        ),
                                                    onPrintBill: () =>
                                                        _printSavedOrderBill(
                                                          order,
                                                        ),
                                                    onPrintKitchenTicket:
                                                        order.serverId == null
                                                        ? null
                                                        : () =>
                                                              _printSavedKitchenTicket(
                                                                order,
                                                              ),
                                                  ),
                                            );
                                          }
                                        },
                                        icon: Icon(
                                          isHeld
                                              ? Icons.play_arrow_rounded
                                              : Icons.visibility_outlined,
                                          size: 18,
                                        ),
                                        label: Text(
                                          isHeld
                                              ? 'Resume order'
                                              : 'View order',
                                        ),
                                      );
                                      final deleteAction = IconButton.outlined(
                                        tooltip: 'Remove held order',
                                        onPressed: !isHeld
                                            ? null
                                            : () async {
                                                final deleted =
                                                    await _deleteHeldOrder(
                                                      order,
                                                    );
                                                if (!deleted ||
                                                    !dialogContext.mounted) {
                                                  return;
                                                }
                                                Navigator.pop(dialogContext);
                                                if (mounted) {
                                                  unawaited(
                                                    _showOrders(
                                                      locationId,
                                                      heldOnly: true,
                                                    ),
                                                  );
                                                }
                                              },
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 19,
                                        ),
                                        color: colors.error,
                                      );
                                      return Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.center,
                                        children: [
                                          Container(
                                            width: 44,
                                            height: 44,
                                            decoration: BoxDecoration(
                                              color: isHeld
                                                  ? const Color(0xFFD5F3E9)
                                                  : colors.secondaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(13),
                                            ),
                                            child: Icon(
                                              isHeld
                                                  ? Icons.pause_rounded
                                                  : Icons.receipt_long_outlined,
                                              color: isHeld
                                                  ? const Color(0xFF08745D)
                                                  : colors.onSecondaryContainer,
                                            ),
                                          ),
                                          const SizedBox(width: 13),
                                          Expanded(
                                            child: compact
                                                ? Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .stretch,
                                                    children: [
                                                      details,
                                                      const SizedBox(
                                                        height: 12,
                                                      ),
                                                      Row(
                                                        children: [
                                                          Expanded(
                                                            child: action,
                                                          ),
                                                          if (isHeld) ...[
                                                            const SizedBox(
                                                              width: 8,
                                                            ),
                                                            deleteAction,
                                                          ],
                                                        ],
                                                      ),
                                                    ],
                                                  )
                                                : Row(
                                                    children: [
                                                      Expanded(child: details),
                                                      const SizedBox(width: 16),
                                                      action,
                                                      if (isHeld) ...[
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
                                                        deleteAction,
                                                      ],
                                                    ],
                                                  ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
      if (selected != null && mounted) {
        if (selected.serverId == null && selected.status != 'draft') {
          _show('This order is waiting to sync and cannot be edited yet.');
        } else {
          _loadOrder(selected);
        }
      }
    } catch (error, stackTrace) {
      debugPrint('Unable to load recent kitchen orders: $error\n$stackTrace');
      if (mounted) {
        _show(
          'Unable to load ${heldOnly ? 'held' : 'previous'} orders. Check the connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<bool> _deleteHeldOrder(Sale order) async {
    final transactionId = order.serverId;
    if (transactionId == null || transactionId.isEmpty) {
      _show('This held order has no server ID and cannot be removed.');
      return false;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (confirmContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('Remove held order?'),
        content: Text(
          'Order ${order.invoiceNo.isEmpty ? '#$transactionId' : order.invoiceNo} will be permanently removed. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(confirmContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(confirmContext).colorScheme.error,
              foregroundColor: Theme.of(confirmContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(confirmContext, true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Remove order'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;

    try {
      await ref
          .read(kitchenPrintingControllerProvider.notifier)
          .deleteKitchenOrder(transactionId);
      final locationId = _locationId(ref.read(appStoreProvider));
      if (locationId != null && locationId.isNotEmpty) {
        ref.invalidate(kitchenOrdersProvider(locationId));
      }
      if (_savedTransactionId == transactionId) _resetOrder();
      if (mounted) _show('Held order removed.');
      return true;
    } catch (error) {
      if (mounted) _show('Unable to remove held order: $error');
      return false;
    }
  }

  void _loadOrder(Sale order) {
    final pax = RegExp(
      r'(?:Pax|Guests?)\s+(\d+)',
      caseSensitive: false,
    ).firstMatch(order.saleNote);
    final service = order.saleNote.split('·').first.trim();
    ref.read(appStoreProvider.notifier).selectCustomer(order.customer);
    setState(() {
      _lines
        ..clear()
        ..addEntries(order.items.map((line) => MapEntry(line.lineId, line)));
      _activeOrder = order;
      _savedTransactionId = order.serverId;
      _pendingClientTransactionId = null;
      _offlineDraftClientId =
          order.localId.startsWith('kitchen-') && order.serverId == null
          ? order.localId.substring('kitchen-'.length)
          : null;
      _tableId = order.tableId.isEmpty ? null : order.tableId;
      _waiterId = order.waiterId.isEmpty ? null : order.waiterId;
      _savedServiceTypeId = order.serviceTypeId.isEmpty
          ? null
          : order.serviceTypeId;
      final enabledServices = ref.read(orderTypeSettingsProvider).apply();
      _selectedService = enabledServices.any((item) => item.code == service)
          ? service
          : null;
      _guests = int.tryParse(pax?.group(1) ?? '') ?? 1;
      _note = order.saleNote
          .split('·')
          .skip(2)
          .map((part) => part.trim())
          .where((part) => part.isNotEmpty)
          .join(' · ');
      _grossDiscount = order.discount;
      _showMobileOrder = true;
    });
  }

  Future<void> _printAndHoldKitchenOrder() async {
    if (_lines.isEmpty || _orderLocked || _sending) return;
    await _saveDraft(printBill: true);
  }

  Future<void> _saveDraft({bool printBill = false}) async {
    if (_sending || _orderLocked || _lines.isEmpty) return;
    final store = ref.read(appStoreProvider);
    final locationId = _locationId(store);
    final customer = _customer(store);
    if (locationId == null || locationId.isEmpty || customer == null) {
      _show('Refresh customer and business location data before saving.');
      return;
    }
    if (_offlineSession && _savedTransactionId == null) {
      try {
        await _queueOfflineOrder('draft');
      } catch (error) {
        if (mounted) _show('Unable to save offline draft: $error');
      }
      return;
    }
    setState(() => _sending = true);
    try {
      var transactionId = _savedTransactionId;
      if (transactionId == null) {
        _pendingClientTransactionId ??= _newClientTransactionId();
        transactionId = await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .createKitchenOrder(
              locationId: locationId,
              customer: customer,
              lines: _lines.values.toList(growable: false),
              clientTransactionId: _pendingClientTransactionId!,
              saleNote: _composedSaleNote(),
              status: 'draft',
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              suspended: true,
              grossDiscount: _grossDiscount,
            );
      } else {
        await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .updateKitchenOrder(
              transactionId: transactionId,
              locationId: locationId,
              customer: customer,
              lines: _lines.values.toList(growable: false),
              status: 'draft',
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              saleNote: _composedSaleNote(),
              grossDiscount: _grossDiscount,
              suspended: true,
            );
      }
      ref.invalidate(kitchenOrdersProvider(locationId));
      if (!mounted) return;
      if (printBill) {
        await _printBill(paymentMethod: 'due');
        if (!mounted) return;
      }
      _show('Order #$transactionId saved as draft.');
      _resetOrder();
    } catch (error) {
      if (_savedTransactionId == null && _isConnectionFailure(error)) {
        try {
          await _queueOfflineOrder('draft');
        } catch (queueError) {
          if (mounted) _show('Unable to save offline draft: $queueError');
        }
      } else if (mounted) {
        _show('Unable to save this draft: $error');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _createBill({bool print = false}) async {
    if (_sending || _lines.isEmpty) return;
    final store = ref.read(appStoreProvider);
    final locationId = _locationId(store);
    final customer = _customer(store);
    if (locationId == null || locationId.isEmpty || customer == null) {
      _show('Refresh customer and business location data before billing.');
      return;
    }
    if (_offlineSession && _savedTransactionId == null) {
      setState(() => _sending = true);
      try {
        final sale = await _queueOfflineOrder('final', resetOrder: false);
        if (!mounted) return;
        if (print) {
          await _printSavedOrderBill(sale);
          if (!mounted) return;
        }
        _resetOrder();
      } catch (error) {
        if (mounted) _show('Unable to create offline sale: $error');
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    setState(() => _sending = true);
    try {
      var transactionId = _savedTransactionId;
      if (transactionId == null) {
        _pendingClientTransactionId ??= _newClientTransactionId();
        transactionId = await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .createKitchenOrder(
              locationId: locationId,
              customer: customer,
              lines: _lines.values.toList(growable: false),
              clientTransactionId: _pendingClientTransactionId!,
              saleNote: _composedSaleNote(),
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              grossDiscount: _grossDiscount,
            );
        if (!mounted) return;
        setState(() => _savedTransactionId = transactionId);
      } else {
        await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .updateKitchenOrder(
              transactionId: transactionId,
              locationId: locationId,
              customer: customer,
              lines: _lines.values.toList(growable: false),
              status: 'final',
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              saleNote: _composedSaleNote(),
              grossDiscount: _grossDiscount,
            );
      }
      if (print) await _printBill(paymentMethod: 'due');
      if (!mounted) return;
      ref.invalidate(kitchenOrdersProvider(locationId));
      _resetOrder();
      _show(
        print
            ? 'Bill #$transactionId saved and printed.'
            : 'Bill #$transactionId saved as due.',
      );
    } catch (error) {
      if (_savedTransactionId == null &&
          _isConnectionFailure(error) &&
          ref.read(offlinePosControllerProvider).value?.ready == true) {
        try {
          final sale = await _queueOfflineOrder('final', resetOrder: false);
          if (!mounted) return;
          if (print) {
            await _printSavedOrderBill(sale);
            if (!mounted) return;
          }
          _resetOrder();
        } catch (queueError) {
          if (mounted) _show('Unable to create offline sale: $queueError');
        }
      } else if (mounted) {
        // A rejected bill (for example an inventory validation error) was
        // leaving the idempotency marker set and locking the entire cart.
        // Clear it for deterministic 4xx responses so the cashier can fix the
        // order and continue adding products. Keep it for network/5xx errors,
        // where the server may have accepted the original request.
        final status = error is ApiException ? error.statusCode : null;
        if (status != null && status >= 400 && status < 500 && status != 401) {
          setState(() {
            _pendingClientTransactionId = null;
            _showMobileOrder = true;
          });
        }
        _show('Unable to create this bill: $error');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _submitKitchenOrder({bool printBill = false}) async {
    if (_sending) return;
    if (_lines.isEmpty && _savedTransactionId == null) {
      _show('Add an item before sending an order.');
      return;
    }
    if (_offlineSession && _savedTransactionId == null) {
      try {
        await _queueOfflineOrder('final');
      } catch (error) {
        if (mounted) _show('Unable to queue kitchen order: $error');
      }
      return;
    }
    final kitchen = ref.read(kitchenPrintingControllerProvider).asData?.value;
    if (_savedTransactionId == null && kitchen?.hasActiveRoutes != true) {
      final kitchenLoad = ref.read(kitchenPrintingControllerProvider);
      if (kitchenLoad.hasError &&
          _isConnectionFailure(kitchenLoad.error!) &&
          ref.read(offlinePosControllerProvider).value?.ready == true) {
        try {
          await _queueOfflineOrder('final');
        } catch (error) {
          if (mounted) _show('Unable to queue kitchen order: $error');
        }
        return;
      }
      _show('Set up a kitchen printer route in Printer settings first.');
      return;
    }
    final store = ref.read(appStoreProvider);
    final locationId = _locationId(store);
    final customer = store.customer ?? store.customers.firstOrNull;
    if (_savedTransactionId == null &&
        (locationId == null || locationId.isEmpty || customer == null)) {
      _show('Refresh customer and business location data before sending.');
      return;
    }
    setState(() => _sending = true);
    try {
      var transactionId = _savedTransactionId;
      if (transactionId == null) {
        _pendingClientTransactionId ??= _newClientTransactionId();
        final note = _composedSaleNote();
        transactionId = await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .createKitchenOrder(
              locationId: locationId!,
              customer: customer!,
              lines: _lines.values.toList(growable: false),
              clientTransactionId: _pendingClientTransactionId!,
              saleNote: note,
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              grossDiscount: _grossDiscount,
            );
        if (!mounted) return;
        setState(() => _savedTransactionId = transactionId);
      } else if (_activeOrder != null) {
        await ref
            .read(kitchenPrintingControllerProvider.notifier)
            .updateKitchenOrder(
              transactionId: transactionId,
              locationId: locationId!,
              customer: customer!,
              lines: _lines.values.toList(growable: false),
              status: 'final',
              tableId: _service == 'Dine in' ? _tableId : null,
              serviceStaffId: _waiterId,
              serviceTypeId: _serviceTypeId,
              saleNote: _composedSaleNote(),
              grossDiscount: _grossDiscount,
            );
      }
      final summary = await ref
          .read(kitchenPrintingControllerProvider.notifier)
          .processTransaction(transactionId, locationId: locationId);
      if (!mounted) return;
      ref.invalidate(kitchenOrdersProvider(locationId!));
      _show(
        'Kitchen order #$transactionId saved and ${summary.printedCount} '
        'ticket(s) sent to the paired printer(s).',
      );
      if (printBill) {
        await _printBill();
        if (!mounted) return;
      }
      _resetOrder();
    } catch (error) {
      if (!mounted) return;
      if (_savedTransactionId == null && _isConnectionFailure(error)) {
        try {
          await _queueOfflineOrder('final');
        } catch (queueError) {
          if (mounted) _show('Unable to queue kitchen order: $queueError');
        }
        return;
      }
      setState(() => _showMobileOrder = true);
      _show(
        _savedTransactionId == null
            ? 'Kitchen order not confirmed. Retry this same order: $error'
            : 'Kitchen order #$_savedTransactionId is saved. Printing needs attention; retry without creating another sale: $error',
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _newClientTransactionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final value = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${value.substring(0, 8)}-${value.substring(8, 12)}-'
        '${value.substring(12, 16)}-${value.substring(16, 20)}-'
        '${value.substring(20)}';
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(appStoreProvider);
    final orderTypes = ref.watch(orderTypeSettingsProvider).apply();
    final products = _visible(store);
    final width = MediaQuery.sizeOf(context).width;
    final modernDesktop = _modernLayout && width >= 1100;
    final classicDesktop = !_modernLayout && width >= 960;
    final desktop = modernDesktop || classicDesktop;
    final subtotal = _lines.values.fold<int>(
      0,
      (sum, line) => sum + line.subtotal,
    );
    final tax = _lines.values.fold<int>(0, (sum, line) => sum + line.tax);
    final total = max(
      0,
      _lines.values.fold<int>(0, (sum, line) => sum + _kitchenLineTotal(line)) -
          _grossDiscount,
    );
    ref.watch(kitchenPrintingControllerProvider);
    final locationId = _locationId(store) ?? '';
    final restaurantContext = locationId.isEmpty
        ? null
        : ref.watch(kitchenRestaurantContextProvider(locationId)).asData?.value;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f6): () =>
            unawaited(_saveDraft()),
        const SingleActivator(LogicalKeyboardKey.f8): () =>
            unawaited(_printBill()),
        const SingleActivator(LogicalKeyboardKey.f9): _sendToKitchen,
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: modernDesktop ? _desktopCanvas : AppColors.canvas,
          child: Column(
            children: [
              _header(desktop, restaurantContext, locationId, orderTypes),
              Expanded(
                child: modernDesktop
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 44,
                              child: _catalog(store, products, desktop: true),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 31,
                              child: _order(
                                total,
                                subtotal: subtotal,
                                tax: tax,
                                desktop: true,
                                showControls: false,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(flex: 25, child: _desktopControlRail()),
                          ],
                        ),
                      )
                    : classicDesktop
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _catalog(store, products, desktop: true),
                          ),
                          _KitchenResizeHandle(
                            onDrag: (delta) => setState(() {
                              _classicOrderPanelWidth =
                                  (_classicOrderPanelWidth - delta).clamp(
                                    340.0,
                                    width - 560.0,
                                  );
                            }),
                          ),
                          SizedBox(
                            width: _classicOrderPanelWidth.clamp(
                              340.0,
                              width - 560.0,
                            ),
                            child: _order(
                              total,
                              subtotal: subtotal,
                              tax: tax,
                              desktop: true,
                              showControls: true,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          if (_showMobileOrder)
                            Expanded(
                              child: SingleChildScrollView(
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 12),
                                  child: _order(
                                    total,
                                    subtotal: subtotal,
                                    tax: tax,
                                    desktop: false,
                                    showControls: true,
                                  ),
                                ),
                              ),
                            )
                          else
                            Expanded(
                              child: _catalog(store, products, desktop: true),
                            ),
                          Material(
                            color: Colors.white,
                            child: InkWell(
                              key: const ValueKey(
                                'kitchen-mobile-order-toggle',
                              ),
                              onTap: () => setState(
                                () => _showMobileOrder = !_showMobileOrder,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      _showMobileOrder
                                          ? Icons.restaurant_menu_outlined
                                          : Icons.receipt_long_outlined,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _showMobileOrder
                                            ? 'Back to menu'
                                            : 'View order (${_lines.length})',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    RiyalAmount(total),
                                    const SizedBox(width: 8),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickPrintToggle() {
    final printerState = ref.watch(printerControllerProvider);
    final enabled = printerState.settings.posPrintingEnabled;
    return Tooltip(
      message: context.tr(
        enabled
            ? 'Automatic invoice printing is on'
            : 'Invoice printing is off',
      ),
      child: InkWell(
        onTap: printerState.loading
            ? null
            : () async {
                final settings = ref.read(printerControllerProvider).settings;
                await ref
                    .read(printerControllerProvider.notifier)
                    .update(settings.copyWith(posPrintingEnabled: !enabled));
                if (!mounted) return;
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      duration: const Duration(seconds: 2),
                      content: Text(
                        context.tr(
                          enabled
                              ? 'Invoice printing disabled.'
                              : 'Invoice printing enabled.',
                        ),
                      ),
                    ),
                  );
              },
        borderRadius: BorderRadius.circular(6),
        child: Semantics(
          button: true,
          toggled: enabled,
          label: context.tr('Automatic invoice printing'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  enabled
                      ? Icons.print_outlined
                      : Icons.print_disabled_outlined,
                  size: 19,
                  color: enabled ? Colors.white : const Color(0xFFFFB4AB),
                ),
                Text(
                  context.tr(enabled ? 'On' : 'Off'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopControlRail() {
    final short = MediaQuery.sizeOf(context).height < 850;
    return Container(
      padding: EdgeInsets.all(short ? 10 : 14),
      decoration: BoxDecoration(
        color: _desktopSurface,
        border: Border.all(color: _desktopBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: _desktopBorder,
          colorScheme: Theme.of(context).colorScheme.copyWith(
            surface: _desktopSurfaceRaised,
            onSurface: _desktopText,
          ),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: _desktopText),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: .22),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.dialpad_rounded,
                        color: _desktopAccent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quick edit keypad',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            'Select an item, then enter a value',
                            style: TextStyle(
                              color: _desktopTextMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _numericKeypad(),
                SizedBox(height: short ? 12 : 20),
                Divider(height: short ? 1 : 8),
                SizedBox(height: short ? 10 : 14),
                _desktopRailActions(compact: short),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopRailActions({required bool compact}) {
    final disabled = _lines.isEmpty || _sending;

    Widget button({
      Key? key,
      required String label,
      required IconData icon,
      required VoidCallback? onPressed,
      bool primary = false,
    }) {
      final style = primary
          ? FilledButton.styleFrom(
              minimumSize: Size(double.infinity, compact ? 44 : 50),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            )
          : OutlinedButton.styleFrom(
              foregroundColor: _desktopText,
              disabledForegroundColor: _desktopTextMuted.withValues(alpha: .68),
              side: BorderSide(
                color: _lightLayout
                    ? _desktopBorder
                    : onPressed == null
                    ? const Color(0xFF42565E)
                    : const Color(0xFF7F949B),
              ),
              minimumSize: Size(double.infinity, compact ? 44 : 50),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            );
      final child = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      );
      return primary
          ? FilledButton(
              key: key,
              onPressed: onPressed,
              style: style,
              child: child,
            )
          : OutlinedButton(
              key: key,
              onPressed: onPressed,
              style: style,
              child: child,
            );
    }

    Widget row(List<Widget> children, {List<int>? flex}) => Row(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(width: 7),
          Expanded(flex: flex?[index] ?? 1, child: children[index]),
        ],
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row(
          [
            button(
              label: 'Save as Draft',
              icon: Icons.pause_outlined,
              onPressed: _lines.isEmpty || _orderLocked || _sending
                  ? null
                  : () => unawaited(_saveDraft()),
            ),
            button(
              label: 'KOT & Pay',
              icon: Icons.point_of_sale_outlined,
              onPressed: disabled ? null : () => unawaited(_billAndPay()),
              primary: true,
            ),
          ],
          flex: const [2, 3],
        ),
        const SizedBox(height: 7),
        row([
          button(
            key: const ValueKey('send-to-kitchen'),
            label: 'Send KOT',
            icon: Icons.soup_kitchen_rounded,
            onPressed: disabled ? null : _sendToKitchen,
          ),
          button(
            label: 'Print & Hold',
            icon: Icons.print_outlined,
            onPressed: _lines.isEmpty || _orderLocked || _sending
                ? null
                : _printAndHoldKitchenOrder,
          ),
          button(
            label: 'KOT & Print',
            icon: Icons.print_outlined,
            onPressed: disabled ? null : _sendToKitchenAndPrint,
          ),
        ]),
        const SizedBox(height: 7),
        row([
          button(
            label: 'Create Bill',
            icon: Icons.receipt_long_outlined,
            onPressed: disabled ? null : () => unawaited(_createBill()),
          ),
          button(
            label: 'Bill & Pay',
            icon: Icons.payments_outlined,
            onPressed: disabled
                ? null
                : () => unawaited(
                    _billAndPay(sendToKitchen: false, printCustomerBill: false),
                  ),
          ),
          button(
            label: 'Bill & Print',
            icon: Icons.print_rounded,
            onPressed: disabled
                ? null
                : () => unawaited(_createBill(print: true)),
          ),
        ]),
      ],
    );
  }

  Widget _header(
    bool desktop,
    _RestaurantContext? restaurant,
    String locationId,
    List<PosOrderType> orderTypes,
  ) {
    final store = ref.watch(appStoreProvider);
    final customer = _customer(store);
    final controls = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _orderTypeDropdown(orderTypes),
        if (_service == 'Dine in') _tableCard(restaurant?.tables ?? const []),
        _customerButton(store, customer),
      ],
    );
    Widget title({required bool inlineControls}) => Row(
      children: [
        const Icon(Icons.soup_kitchen_rounded, color: Colors.white, size: 25),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Kitchen POS',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        if (inlineControls) ...[controls, const SizedBox(width: 10)],
        PopupMenuButton<_KitchenLayout>(
          key: const ValueKey('kitchen-layout-switcher'),
          tooltip: 'Kitchen POS layout',
          initialValue: _layout,
          onSelected: (value) => unawaited(_selectLayout(value)),
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: _KitchenLayout.modern,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.dashboard_customize_outlined),
                title: Text('Modern layout'),
              ),
            ),
            PopupMenuItem(
              value: _KitchenLayout.light,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.light_mode_outlined),
                title: Text('Light layout'),
              ),
            ),
            PopupMenuItem(
              value: _KitchenLayout.classic,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.view_sidebar_outlined),
                title: Text('Classic layout'),
              ),
            ),
          ],
          icon: Icon(switch (_layout) {
            _KitchenLayout.modern => Icons.dashboard_customize_outlined,
            _KitchenLayout.light => Icons.light_mode_outlined,
            _KitchenLayout.classic => Icons.view_sidebar_outlined,
          }, color: Colors.white),
        ),
        _quickPrintToggle(),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'New order',
          onPressed: _newOrder,
          icon: const Icon(Icons.add_circle_outline),
          color: Colors.white,
          visualDensity: VisualDensity.compact,
        ),
        if (desktop) ...[
          OutlinedButton.icon(
            key: const ValueKey('kitchen-held-orders'),
            onPressed: locationId.isEmpty
                ? null
                : () => _showOrders(locationId, heldOnly: true),
            icon: const Icon(Icons.pause_circle_outline_rounded, size: 17),
            label: const Text('Held'),
            style: _headerOrderButtonStyle(),
          ),
          const SizedBox(width: 6),
          OutlinedButton.icon(
            key: const ValueKey('kitchen-previous-orders'),
            onPressed: locationId.isEmpty
                ? null
                : () => _showOrders(locationId, heldOnly: false),
            icon: const Icon(Icons.history_rounded, size: 17),
            label: const Text('Previous'),
            style: _headerOrderButtonStyle(),
          ),
        ] else ...[
          IconButton(
            key: const ValueKey('kitchen-held-orders'),
            tooltip: 'Held orders',
            onPressed: locationId.isEmpty
                ? null
                : () => _showOrders(locationId, heldOnly: true),
            icon: const Icon(Icons.pause_circle_outline_rounded),
            color: Colors.white,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            key: const ValueKey('kitchen-previous-orders'),
            tooltip: 'Previous orders',
            onPressed: locationId.isEmpty
                ? null
                : () => _showOrders(locationId, heldOnly: false),
            icon: const Icon(Icons.history_rounded),
            color: Colors.white,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ],
    );
    return Container(
      margin: EdgeInsets.fromLTRB(desktop ? 10 : 8, 6, desktop ? 10 : 8, 0),
      padding: EdgeInsets.symmetric(
        horizontal: desktop ? 14 : 10,
        vertical: desktop ? 8 : 5,
      ),
      decoration: BoxDecoration(
        color: AppColors.primaryDark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 1000) return title(inlineControls: true);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title(inlineControls: false),
              const SizedBox(height: 6),
              controls,
            ],
          );
        },
      ),
    );
  }

  ButtonStyle _headerOrderButtonStyle() => OutlinedButton.styleFrom(
    foregroundColor: Colors.white,
    side: const BorderSide(color: Colors.white54),
    minimumSize: const Size(0, 34),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );

  Widget _customerButton(
    AppState store,
    Customer? customer, {
    bool mobile = false,
  }) => SizedBox(
    width: mobile ? double.infinity : 180,
    height: mobile ? 44 : 36,
    child: OutlinedButton.icon(
      key: const ValueKey('kitchen-customer-selector'),
      onPressed: _orderLocked ? null : () => _showCustomerSelector(store),
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.ink,
        side: const BorderSide(color: _border),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      icon: const Icon(Icons.person_outline_rounded, size: 17),
      label: Text(
        customer?.name ?? 'Select customer',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );

  Future<void> _showCustomerSelector(AppState store) => showDialog<void>(
    context: context,
    builder: (_) => _KitchenCustomerDialog(
      customers: store.customers,
      selected: store.customer,
      onSelected: (customer) =>
          ref.read(appStoreProvider.notifier).selectCustomer(customer),
      onCreate: ({required name, required mobile, required email}) => ref
          .read(backendControllerProvider.notifier)
          .createCustomer(name: name, mobile: mobile, email: email),
    ),
  );

  void _selectService(String label) {
    if (label == _service) return;
    setState(() {
      _selectedService = label;
      _savedServiceTypeId = null;
      if (label != 'Dine in') _tableId = null;
    });
  }

  Widget _orderTypeDropdown(List<PosOrderType> orderTypes) => Container(
    width: 146,
    height: 36,
    padding: const EdgeInsets.symmetric(horizontal: 9),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: const ValueKey('kitchen-order-type'),
        isExpanded: true,
        isDense: true,
        value: orderTypes.isEmpty ? null : _service,
        hint: const Text('Order type'),
        items: [
          for (final option in orderTypes)
            DropdownMenuItem(
              value: option.code,
              child: Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: _orderLocked
            ? null
            : (code) {
                if (code != null) _selectService(code);
              },
      ),
    ),
  );

  Widget _tableCard(List<RestaurantTable> tables, {bool mobile = false}) =>
      Container(
        key: const ValueKey('kitchen-table-card'),
        width: mobile ? double.infinity : 156,
        height: mobile ? 44 : 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.table_restaurant_outlined,
              size: 17,
              color: AppColors.ink,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: tables.any((table) => table.id == _tableId)
                      ? _tableId
                      : null,
                  isExpanded: true,
                  hint: const Text('Select table'),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('No table'),
                    ),
                    for (final table in tables)
                      DropdownMenuItem<String?>(
                        value: table.id,
                        child: Text(
                          table.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _orderLocked
                      ? null
                      : (value) => setState(() => _tableId = value),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _catalog(
    AppState store,
    List<Product> products, {
    required bool desktop,
  }) {
    final categories = store.categories.where((item) => item.active).toList();
    final arabic = Localizations.localeOf(context).languageCode == 'ar';
    final wide = _useModernDesktop(context);
    return Container(
      padding: EdgeInsets.all(wide ? 10 : 8),
      decoration: BoxDecoration(
        color: wide ? _desktopSurface : const Color(0xFFFAFCFB),
        border: wide ? Border.all(color: _desktopBorder) : null,
        borderRadius: wide ? BorderRadius.circular(12) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: desktop ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  focusNode: _focus,
                  style: TextStyle(color: wide ? _desktopText : AppColors.ink),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) {
                    if (products.length == 1) _add(products.first);
                  },
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: wide ? _desktopSurfaceRaised : Colors.white,
                    hintStyle: TextStyle(
                      color: wide ? _desktopTextMuted : AppColors.muted,
                    ),
                    prefixIconColor: wide ? _desktopTextMuted : null,
                    hintText: MediaQuery.sizeOf(context).width < 600
                        ? 'Search items'
                        : 'Search item name, SKU or barcode…',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty
                        ? MediaQuery.sizeOf(context).width < 600
                              ? IconButton(
                                  tooltip: 'Focus barcode scanner input',
                                  onPressed: _focus.requestFocus,
                                  icon: const Icon(
                                    Icons.qr_code_scanner_outlined,
                                  ),
                                )
                              : null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () => setState(_search.clear),
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ),
              if (MediaQuery.sizeOf(context).width >= 600) ...[
                const SizedBox(width: 7),
                IconButton.outlined(
                  tooltip: 'Focus barcode scanner input',
                  onPressed: _focus.requestFocus,
                  icon: const Icon(Icons.qr_code_scanner_outlined),
                  style: IconButton.styleFrom(
                    foregroundColor: wide ? _desktopText : AppColors.ink,
                    side: BorderSide(color: wide ? _desktopBorder : _border),
                  ),
                ),
                const SizedBox(width: 6),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: wide ? _desktopSurfaceRaised : Colors.white,
                    border: Border.all(color: wide ? _desktopBorder : _border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: wide ? _desktopText : AppColors.ink,
                    ),
                    child: IconTheme(
                      data: IconThemeData(
                        color: wide ? _desktopText : AppColors.ink,
                      ),
                      child: const ProductCardStylePicker(mode: 'kitchen'),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              IconButton(
                key: const ValueKey('kitchen-reorder-categories'),
                tooltip: 'Reorder categories',
                onPressed: store.categories.length > 1 && !_savingCategoryOrder
                    ? () => _showKitchenCategoryOrder(store.categories)
                    : null,
                icon: _savingCategoryOrder
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.low_priority_rounded, size: 22),
                style: IconButton.styleFrom(
                  backgroundColor: wide
                      ? _desktopSurfaceRaised
                      : const Color(0xFFE5F4F0),
                  foregroundColor: wide
                      ? const Color(0xFF42D8B4)
                      : AppColors.primary,
                  side: BorderSide(
                    color: wide ? _desktopBorder : const Color(0xFF9BC9BD),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<_KitchenCardSize>(
                key: const ValueKey('kitchen-card-size'),
                tooltip: context.tr('Product card size'),
                initialValue: _cardSize,
                onSelected: (size) => unawaited(_selectCardSize(size)),
                icon: Icon(
                  Icons.grid_view_rounded,
                  color: wide ? _desktopText : AppColors.ink,
                ),
                itemBuilder: (_) => [
                  for (final size in _KitchenCardSize.values)
                    CheckedPopupMenuItem(
                      key: ValueKey('kitchen-card-size-${size.name}'),
                      value: size,
                      checked: size == _cardSize,
                      child: Text(size.label),
                    ),
                ],
              ),
              if (MediaQuery.sizeOf(context).width < 600) ...[
                const SizedBox(width: 6),
                OutlinedButton(
                  key: const ValueKey('kitchen-add-quantity'),
                  onPressed: _orderLocked ? null : _editAddQuantity,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                  ),
                  child: Text('x$_addQuantity'),
                ),
              ] else
                Tooltip(
                  message: 'Quantity added per product tap',
                  child: Container(
                    decoration: BoxDecoration(
                      color: wide ? _desktopSurfaceRaised : Colors.white,
                      border: Border.all(
                        color: wide ? _desktopBorder : _border,
                      ),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Decrease add quantity',
                          onPressed: _addQuantity <= 1
                              ? null
                              : () => setState(() => _addQuantity--),
                          icon: const Icon(Icons.remove, size: 16),
                          color: wide ? _desktopText : AppColors.ink,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 29,
                            height: 38,
                          ),
                        ),
                        Text(
                          'x$_addQuantity',
                          style: TextStyle(
                            color: wide ? _desktopText : AppColors.ink,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Increase add quantity',
                          onPressed: () => setState(() => _addQuantity++),
                          icon: const Icon(Icons.add, size: 16),
                          color: wide ? _desktopText : AppColors.ink,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 29,
                            height: 38,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (desktop)
            Expanded(child: _categoryProductArea(products, categories, arabic))
          else
            SizedBox(
              height: 420,
              child: _categoryProductArea(products, categories, arabic),
            ),
        ],
      ),
    );
  }

  Widget _categoryProductArea(
    List<Product> products,
    List<Category> categories,
    bool arabic,
  ) {
    final mobile = MediaQuery.sizeOf(context).width < 600;
    final desktop = _useModernDesktop(context);
    if (desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            key: const ValueKey('kitchen-category-panel'),
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _categoryChip('', 'All', horizontal: true),
                for (var index = 0; index < categories.length; index++)
                  _categoryChip(
                    categories[index].id,
                    arabic && categories[index].nameAr.trim().isNotEmpty
                        ? categories[index].nameAr
                        : categories[index].nameEn.trim().isNotEmpty
                        ? categories[index].nameEn
                        : categories[index].name,
                    paletteIndex: index,
                    horizontal: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _productGrid(products, categories)),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('kitchen-category-panel'),
          width: mobile ? 112 : _categoryPanelWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Categories',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    _categoryChip('', 'All'),
                    for (var index = 0; index < categories.length; index++)
                      _categoryChip(
                        categories[index].id,
                        arabic && categories[index].nameAr.trim().isNotEmpty
                            ? categories[index].nameAr
                            : categories[index].nameEn.trim().isNotEmpty
                            ? categories[index].nameEn
                            : categories[index].name,
                        paletteIndex: index,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (!mobile)
          _KitchenResizeHandle(
            onDrag: (delta) => setState(() {
              _categoryPanelWidth = (_categoryPanelWidth + delta).clamp(
                120.0,
                280.0,
              );
            }),
          )
        else
          const SizedBox(width: 8),
        Expanded(child: _productGrid(products, categories)),
      ],
    );
  }

  Future<void> _showKitchenCategoryOrder(List<Category> categories) async {
    final ordered = await showDialog<List<Category>>(
      context: context,
      builder: (_) => _KitchenCategoryOrderDialog(
        categories: categories,
        dark: _layout == _KitchenLayout.modern,
      ),
    );
    if (ordered == null || !mounted) return;
    final previous = ref.read(appStoreProvider).categories;
    final expectedVersion = previous.isEmpty ? 1 : previous.first.orderVersion;
    final optimistic = [
      for (var index = 0; index < ordered.length; index++)
        ordered[index].copyWith(sortOrder: index),
    ];
    ref.read(appStoreProvider.notifier).replaceCategories(optimistic);
    setState(() => _savingCategoryOrder = true);
    try {
      var token = await ref.read(authControllerProvider.future);
      if (token == null || token.isEmpty || token == 'offline-local-session') {
        throw const ApiException(
          'Category ordering requires an online session.',
        );
      }
      int version;
      try {
        version = await ref
            .read(apiProvider)
            .reorderCategories(
              accessToken: token,
              parentId: null,
              orderedIds: ordered.map((item) => item.id).toList(),
              expectedVersion: expectedVersion,
            );
      } on ApiException catch (error) {
        if (error.statusCode != 401) rethrow;
        token = await ref
            .read(authControllerProvider.notifier)
            .refreshAccessToken();
        version = await ref
            .read(apiProvider)
            .reorderCategories(
              accessToken: token,
              parentId: null,
              orderedIds: ordered.map((item) => item.id).toList(),
              expectedVersion: expectedVersion,
            );
      }
      ref.read(appStoreProvider.notifier).replaceCategories([
        for (var index = 0; index < ordered.length; index++)
          ordered[index].copyWith(sortOrder: index, orderVersion: version),
      ]);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Kitchen category order saved.')),
        );
      }
    } catch (error) {
      ref.read(appStoreProvider.notifier).replaceCategories(previous);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save category order: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingCategoryOrder = false);
    }
  }

  Widget _categoryChip(
    String id,
    String label, {
    int? paletteIndex,
    bool horizontal = false,
  }) {
    final selected = _category == id;
    final desktop = _useModernDesktop(context);
    final colorIndex = (paletteIndex ?? 0) % _categoryBackgrounds.length;
    final background = id.isEmpty
        ? AppColors.primary
        : _categoryBackgrounds[colorIndex];
    final border = id.isEmpty
        ? AppColors.primary
        : _categoryBorders[colorIndex];
    return Padding(
      padding: EdgeInsets.only(
        right: horizontal ? 7 : 0,
        bottom: horizontal ? 0 : 6,
      ),
      child: OutlinedButton(
        key: ValueKey(
          id.isEmpty ? 'kitchen-category-all' : 'kitchen-category-$id',
        ),
        onPressed: () => setState(() => _category = id),
        style: OutlinedButton.styleFrom(
          backgroundColor: selected
              ? AppColors.primary
              : desktop && horizontal
              ? _desktopSurfaceRaised
              : background,
          foregroundColor: selected
              ? Colors.white
              : desktop && horizontal
              ? _desktopText
              : AppColors.ink,
          side: BorderSide(
            color: selected
                ? _desktopAccent
                : desktop && horizontal
                ? _desktopBorder
                : border,
          ),
          minimumSize: Size(
            horizontal ? 74 : double.infinity,
            horizontal ? 40 : 46,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Future<void> _editAddQuantity() async {
    var entered = '$_addQuantity';
    final quantity = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Quantity per item tap'),
        content: TextFormField(
          initialValue: entered,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'Quantity'),
          onChanged: (value) => entered = value,
          onFieldSubmitted: (_) =>
              Navigator.pop(dialogContext, int.tryParse(entered)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(entered)),
            child: const Text('Set quantity'),
          ),
        ],
      ),
    );
    if (mounted && quantity != null && quantity >= 1 && quantity <= 999) {
      setState(() => _addQuantity = quantity);
    }
  }

  Widget _productGrid(List<Product> products, List<Category> categories) {
    if (products.isEmpty) {
      return const Center(child: Text('No items match this filter.'));
    }
    final showImages = ref.watch(productCardImagesProvider)['kitchen'] == true;
    final scale = _cardSize.scale;
    final fontSize = 13 * scale;
    final spacing = 6 * scale;
    final scaledFontSize = MediaQuery.textScalerOf(context).scale(fontSize);
    final height =
        (showImages ? 142 : 82) * scale +
        max(0.0, scaledFontSize - fontSize) * 5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = _useModernDesktop(context);
        final standardColumns = constraints.maxWidth >= 1120
            ? 8
            : constraints.maxWidth >= 800
            ? 6
            : constraints.maxWidth >= 620
            ? 5
            : constraints.maxWidth >= 440
            ? 4
            : constraints.maxWidth >= 220
            ? 2
            : 1;
        final columns = max(1, (standardColumns / scale).round());
        return GridView.builder(
          itemCount: products.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: height,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
          ),
          itemBuilder: (_, index) {
            final product = products[index];
            final categoryIndex = categories.indexWhere(
              (category) => category.id == product.categoryId,
            );
            final paletteIndex = categoryIndex >= 0
                ? categoryIndex % _productBackgrounds.length
                : product.categoryId.hashCode.abs() %
                      _productBackgrounds.length;
            return Material(
              color: desktop
                  ? _desktopSurfaceRaised
                  : _productBackgrounds[paletteIndex],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7 * scale),
                side: BorderSide(
                  color: desktop
                      ? _desktopBorder
                      : _productBorders[paletteIndex],
                ),
              ),
              child: InkWell(
                key: ValueKey('kitchen-product-${product.id}'),
                borderRadius: BorderRadius.circular(7 * scale),
                onTap: _orderLocked ? null : () => _add(product),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 7 * scale,
                    vertical: spacing,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (showImages) ...[
                        Expanded(
                          child: ProductImage(
                            product.imageUrl,
                            width: double.infinity,
                            fit: BoxFit.contain,
                          ),
                        ),
                        SizedBox(height: spacing),
                      ],
                      Text(
                        product.displayName(
                          Localizations.localeOf(context).languageCode == 'ar',
                        ),
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: desktop ? _desktopText : AppColors.ink,
                          fontSize: fontSize,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 3 * scale),
                      RiyalAmount(
                        product.sellingPrice,
                        style: TextStyle(
                          color: desktop ? _desktopAccent : AppColors.primary,
                          fontSize: fontSize,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _order(
    int total, {
    required int subtotal,
    required int tax,
    required bool desktop,
    required bool showControls,
  }) {
    final modernStyle = _useModernDesktop(context);
    return Container(
      margin: desktop ? EdgeInsets.zero : const EdgeInsets.fromLTRB(0, 8, 8, 8),
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).height < 720 ? 7 : 10),
      decoration: BoxDecoration(
        color: modernStyle ? _desktopSurface : Colors.white,
        border: Border.all(color: modernStyle ? AppColors.primary : _border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: modernStyle ? _desktopText : AppColors.ink),
        child: Column(
          mainAxisSize: desktop ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Current Order',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  '${_lines.length} items',
                  style: TextStyle(
                    fontSize: 11,
                    color: modernStyle ? _desktopTextMuted : AppColors.muted,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _note.isEmpty ? 'Add order note' : 'Edit order note',
                  onPressed: _orderLocked ? null : _editNote,
                  icon: const Icon(Icons.note_add_outlined, size: 17),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                ),
                TextButton(
                  onPressed: _lines.isEmpty || _orderLocked
                      ? null
                      : () => setState(() {
                          _lines.clear();
                          _grossDiscount = 0;
                        }),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, size: 17),
                      SizedBox(width: 4),
                      Text('Clear All'),
                    ],
                  ),
                ),
              ],
            ),
            Divider(
              height: desktop && MediaQuery.sizeOf(context).height < 720
                  ? 4
                  : 10,
            ),
            if (desktop)
              Expanded(child: _orderItems())
            else
              SizedBox(height: 220, child: _orderItems()),
            if (!desktop || _note.isNotEmpty)
              OutlinedButton.icon(
                onPressed: _orderLocked ? null : _editNote,
                icon: const Icon(Icons.note_add_outlined, size: 17),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _note.isEmpty ? 'Add order note…' : _note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: AppColors.muted,
                ),
              ),
            Divider(
              height: desktop && MediaQuery.sizeOf(context).height < 720
                  ? 6
                  : 12,
            ),
            if (desktop && MediaQuery.sizeOf(context).height < 720)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${context.tr('Sub')} ${moneyAmount(subtotal)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  Text(
                    '${context.tr('Tax')} ${moneyAmount(tax)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  InkWell(
                    onTap: _lines.isEmpty || _orderLocked
                        ? null
                        : _editGrossDiscount,
                    child: Text(
                      '${context.tr('Disc')} ${moneyAmount(_grossDiscount)}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              )
            else ...[
              _amountRow('Subtotal', subtotal),
              const SizedBox(height: 5),
              _amountRow('Tax', tax),
              const SizedBox(height: 5),
              InkWell(
                onTap: _lines.isEmpty || _orderLocked
                    ? null
                    : _editGrossDiscount,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Discount')),
                      RiyalAmount(-_grossDiscount),
                      const SizedBox(width: 4),
                      const Icon(Icons.edit_outlined, size: 15),
                    ],
                  ),
                ),
              ),
            ],
            Divider(
              height: desktop && MediaQuery.sizeOf(context).height < 720
                  ? 6
                  : 12,
            ),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Total',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                RiyalAmount(
                  total,
                  key: const ValueKey('kitchen-order-total'),
                  style: TextStyle(
                    color: modernStyle ? _desktopAccent : AppColors.primary,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            SizedBox(
              height: desktop && MediaQuery.sizeOf(context).height < 720
                  ? 3
                  : 6,
            ),
            if (_savedTransactionId != null || _orderLocked) ...[
              Text(
                _savedTransactionId != null
                    ? 'Order #$_savedTransactionId is saved. Retry kitchen printing; do not create the sale again.'
                    : 'Submission was not confirmed. Retry this same order to avoid a duplicate sale.',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              const SizedBox(height: 6),
            ],
            if (showControls &&
                desktop &&
                MediaQuery.sizeOf(context).height < 800)
              _compactOrderActions()
            else if (showControls) ...[
              _restaurantOrderActions(),
            ],
            if (showControls && desktop) ...[
              SizedBox(height: MediaQuery.sizeOf(context).height < 720 ? 0 : 6),
              _numericKeypad(),
            ],
            if (_activeOrder != null) ...[
              const SizedBox(height: 6),
              Text(
                'Editing ${_activeOrder!.invoiceNo.isEmpty ? 'order #${_activeOrder!.serverId}' : _activeOrder!.invoiceNo}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _compactOrderActions() {
    return _restaurantOrderActions(compact: true);
  }

  Widget _restaurantOrderActions({bool compact = false}) {
    Widget action({
      Key? key,
      required String label,
      required IconData icon,
      required VoidCallback? onPressed,
      bool filled = false,
    }) => Expanded(
      child: filled
          ? FilledButton.icon(
              key: key,
              onPressed: onPressed,
              icon: Icon(icon, size: 16),
              label: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              style: FilledButton.styleFrom(
                minimumSize: Size(0, compact ? 30 : 46),
                padding: const EdgeInsets.symmetric(horizontal: 3),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: TextStyle(fontSize: compact ? 9 : 11),
              ),
            )
          : OutlinedButton.icon(
              key: key,
              onPressed: onPressed,
              icon: Icon(icon, size: 16),
              label: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: Size(0, compact ? 30 : 46),
                padding: const EdgeInsets.symmetric(horizontal: 3),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: TextStyle(fontSize: compact ? 9 : 11),
              ),
            ),
    );

    Widget actionRow(List<Widget> children) => Row(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0) const SizedBox(width: 5),
          children[index],
        ],
      ],
    );

    final disabled = _lines.isEmpty || _sending;
    if (compact) {
      return Column(
        children: [
          actionRow([
            action(
              label: 'Draft',
              icon: Icons.pause_outlined,
              onPressed: _lines.isEmpty || _orderLocked || _sending
                  ? null
                  : () => unawaited(_saveDraft()),
            ),
            action(
              key: const ValueKey('send-to-kitchen'),
              label: 'Send KOT',
              icon: Icons.soup_kitchen_rounded,
              onPressed: disabled ? null : _sendToKitchen,
              filled: true,
            ),
            action(
              label: 'Print & Hold',
              icon: Icons.print_outlined,
              onPressed: _lines.isEmpty || _orderLocked || _sending
                  ? null
                  : _printAndHoldKitchenOrder,
            ),
          ]),
          const SizedBox(height: 5),
          actionRow([
            action(
              label: 'KOT & Print',
              icon: Icons.print_outlined,
              onPressed: disabled ? null : _sendToKitchenAndPrint,
            ),
            action(
              label: 'KOT & Pay',
              icon: Icons.payments_outlined,
              onPressed: disabled ? null : () => unawaited(_billAndPay()),
              filled: true,
            ),
          ]),
        ],
      );
    }
    return Column(
      children: [
        if (!compact) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _lines.isEmpty || _orderLocked || _sending
                  ? null
                  : () => unawaited(_saveDraft()),
              icon: const Icon(Icons.pause_outlined, size: 17),
              label: const Text('Save as Draft'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 38),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ),
          const SizedBox(height: 5),
        ],
        actionRow([
          if (compact)
            action(
              label: 'Draft',
              icon: Icons.pause_outlined,
              onPressed: _lines.isEmpty || _orderLocked || _sending
                  ? null
                  : () => unawaited(_saveDraft()),
            ),
          action(
            key: const ValueKey('send-to-kitchen'),
            label: 'Send KOT',
            icon: Icons.soup_kitchen_rounded,
            onPressed: disabled ? null : _sendToKitchen,
            filled: true,
          ),
          action(
            label: 'Print & Hold',
            icon: Icons.print_outlined,
            onPressed: _lines.isEmpty || _orderLocked || _sending
                ? null
                : _printAndHoldKitchenOrder,
          ),
          action(
            label: 'KOT & Print',
            icon: Icons.print_outlined,
            onPressed: disabled ? null : _sendToKitchenAndPrint,
          ),
          action(
            label: 'KOT & Pay',
            icon: Icons.point_of_sale_outlined,
            onPressed: disabled ? null : () => unawaited(_billAndPay()),
            filled: true,
          ),
        ]),
        SizedBox(height: compact ? 0 : 5),
        actionRow([
          action(
            label: 'Bill',
            icon: Icons.receipt_long_outlined,
            onPressed: disabled ? null : () => unawaited(_createBill()),
          ),
          action(
            label: 'Bill & Pay',
            icon: Icons.payments_outlined,
            onPressed: disabled
                ? null
                : () => unawaited(
                    _billAndPay(sendToKitchen: false, printCustomerBill: false),
                  ),
            filled: true,
          ),
          action(
            label: 'Bill & Print',
            icon: Icons.print_rounded,
            onPressed: disabled
                ? null
                : () => unawaited(_createBill(print: true)),
          ),
        ]),
      ],
    );
  }

  Widget _numericKeypad() {
    final compactHeight = MediaQuery.sizeOf(context).height < 850;
    final modernStyle = _useModernDesktop(context);
    final keyHeight = modernStyle
        ? (compactHeight ? 42.0 : 50.0)
        : (compactHeight ? 44.0 : 48.0);
    final modeHeight = modernStyle
        ? (compactHeight ? 40.0 : 42.0)
        : (compactHeight ? 38.0 : 42.0);
    final keyFontSize = compactHeight ? 17.0 : 19.0;
    final gap = modernStyle
        ? (compactHeight ? 5.0 : 8.0)
        : (compactHeight ? 5.0 : 7.0);
    Widget keypadKey(
      String label, {
      String? value,
      Color foregroundColor = AppColors.ink,
      Color backgroundColor = const Color(0xFFF5F8F9),
      Color borderColor = const Color(0xFFCBD8DC),
    }) => Expanded(
      child: OutlinedButton(
        key: ValueKey('kitchen-keypad-${value ?? label}'),
        onPressed: _orderLocked ? null : () => _keypadPress(value ?? label),
        style: OutlinedButton.styleFrom(
          minimumSize: Size(0, keyHeight),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
          disabledForegroundColor: AppColors.muted,
          disabledBackgroundColor: const Color(0xFFF2F4F3),
          side: BorderSide(color: borderColor),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: TextStyle(
            fontSize: keyFontSize,
            fontWeight: FontWeight.w900,
          ),
        ),
        child: Text(label),
      ),
    );

    Widget keypadRow(List<Widget> children) => Row(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          children[index],
          if (index != children.length - 1) SizedBox(width: gap),
        ],
      ],
    );

    ButtonStyle modeStyle(bool selected) => OutlinedButton.styleFrom(
      minimumSize: Size(0, modeHeight),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      backgroundColor: selected
          ? AppColors.primary
          : _lightLayout
          ? _desktopSurfaceRaised
          : const Color(0xFF18343C),
      foregroundColor: selected
          ? Colors.white
          : _lightLayout
          ? _desktopText
          : const Color(0xFFB8CFD3),
      disabledBackgroundColor: const Color(0xFFF1F3F2),
      disabledForegroundColor: const Color(0xFF9AA5A2),
      side: BorderSide(
        color: selected
            ? AppColors.primary
            : _lightLayout
            ? _desktopBorder
            : const Color(0xFF456069),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      textStyle: TextStyle(
        fontSize: compactHeight ? 14 : 15,
        fontWeight: FontWeight.w800,
      ),
    );
    return Column(
      children: [
        if (modernStyle)
          Container(
            width: double.infinity,
            height: compactHeight ? 50 : 58,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            margin: EdgeInsets.only(bottom: gap),
            decoration: BoxDecoration(
              color: _lightLayout
                  ? _desktopSurfaceRaised
                  : const Color(0xFF0A1E24),
              border: Border.all(
                color: _lightLayout ? _desktopBorder : const Color(0xFF35515A),
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        switch (_keypadMode) {
                          'discount' => 'DISCOUNT',
                          'price' => 'UNIT PRICE',
                          _ => 'QUANTITY',
                        },
                        style: TextStyle(
                          color: _desktopTextMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _keypadInput.isEmpty ? '—' : _keypadInput,
                        key: const ValueKey('kitchen-keypad-display'),
                        style: TextStyle(
                          color: _desktopText,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  switch (_keypadMode) {
                    'discount' => Icons.percent_rounded,
                    'price' => Icons.price_change_outlined,
                    _ => Icons.numbers_rounded,
                  },
                  color: _desktopAccent,
                  size: 23,
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() {
                  _keypadMode = 'qty';
                  _keypadInput = '';
                }),
                style: modeStyle(_keypadMode == 'qty'),
                child: Text(
                  _keypadMode == 'qty' && _keypadInput.isNotEmpty
                      ? '${context.tr('Qty')} $_keypadInput'
                      : 'Qty',
                ),
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: OutlinedButton(
                onPressed: _orderLocked || _lines.isEmpty
                    ? null
                    : () => setState(() {
                        _keypadMode = 'price';
                        _keypadInput = '';
                      }),
                style: modeStyle(_keypadMode == 'price'),
                child: Text(
                  _keypadMode == 'price' && _keypadInput.isNotEmpty
                      ? 'Price $_keypadInput'
                      : 'Price',
                ),
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() {
                  _keypadMode = 'discount';
                  _keypadInput = '';
                }),
                style: modeStyle(_keypadMode == 'discount'),
                child: Text(
                  _keypadMode == 'discount' && _keypadInput.isNotEmpty
                      ? '${context.tr('Disc')} $_keypadInput'
                      : 'Disc',
                ),
              ),
            ),
            SizedBox(width: gap),
            keypadKey(
              'Clear',
              value: 'clear',
              foregroundColor: AppColors.danger,
              backgroundColor: const Color(0xFFFFEEEE),
              borderColor: const Color(0xFFF0B8B8),
            ),
          ],
        ),
        SizedBox(height: gap),
        keypadRow([
          keypadKey('7'),
          keypadKey('8'),
          keypadKey('9'),
          keypadKey(
            '+',
            foregroundColor: AppColors.primary,
            backgroundColor: const Color(0xFFDFF1EC),
            borderColor: const Color(0xFF9DC9BE),
          ),
        ]),
        SizedBox(height: gap),
        keypadRow([
          keypadKey('4'),
          keypadKey('5'),
          keypadKey('6'),
          keypadKey(
            '−',
            value: '-',
            foregroundColor: AppColors.primary,
            backgroundColor: const Color(0xFFDFF1EC),
            borderColor: const Color(0xFF9DC9BE),
          ),
        ]),
        SizedBox(height: gap),
        keypadRow([
          keypadKey('1'),
          keypadKey('2'),
          keypadKey('3'),
          keypadKey(
            '⌫',
            value: 'backspace',
            foregroundColor: const Color(0xFF8A5A18),
            backgroundColor: const Color(0xFFFFF3DA),
            borderColor: const Color(0xFFE8CA8C),
          ),
        ]),
        SizedBox(height: gap),
        keypadRow([
          keypadKey('0'),
          keypadKey('.'),
          Expanded(
            flex: 2,
            child: FilledButton(
              key: const ValueKey('kitchen-keypad-enter'),
              onPressed: _orderLocked ? null : () => _keypadPress('enter'),
              style: FilledButton.styleFrom(
                minimumSize: Size(0, keyHeight),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              child: const Text('Enter'),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _amountRow(String label, int amount) {
    final desktop = _useModernDesktop(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: desktop ? _desktopTextMuted : AppColors.muted,
            ),
          ),
        ),
        RiyalAmount(
          amount,
          style: TextStyle(color: desktop ? _desktopText : AppColors.ink),
        ),
      ],
    );
  }

  Widget _orderItems() {
    if (_lines.isEmpty) {
      return const Center(child: Text('Tap an item to start an order.'));
    }
    final lines = _lines.values.toList(growable: false);
    final desktop = _useModernDesktop(context);
    final selectedLineId = _lines.containsKey(_selectedLineId)
        ? _selectedLineId
        : lines.last.lineId;
    return ListView.separated(
      itemCount: lines.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (_, index) {
        final line = lines[index];
        final selected = selectedLineId == line.lineId;
        return InkWell(
          key: ValueKey('kitchen-order-line-${line.lineId}'),
          onTap: () => _selectLine(line),
          borderRadius: BorderRadius.circular(9),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: BoxDecoration(
              color: selected
                  ? desktop
                        ? AppColors.primary.withValues(alpha: .22)
                        : const Color(0xFFE3F4EF)
                  : Colors.transparent,
              border: Border.all(
                color: selected
                    ? (desktop ? _desktopAccent : AppColors.primary)
                    : Colors.transparent,
                width: selected ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(9),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: .14),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            key: ValueKey(
                              'kitchen-cart-modifiers-${line.lineId}',
                            ),
                            onTap:
                                line.product.modifierGroups.any(
                                      (group) => group.isActive,
                                    ) &&
                                    !_orderLocked
                                ? () => unawaited(_editModifiers(line))
                                : null,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      line.product.displayName(
                                        Localizations.localeOf(
                                              context,
                                            ).languageCode ==
                                            'ar',
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: desktop
                                            ? _desktopText
                                            : AppColors.ink,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Wrap(
                            spacing: 7,
                            runSpacing: 3,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              RiyalAmount(
                                line.subtotal,
                                style: TextStyle(
                                  color: desktop
                                      ? _desktopAccent
                                      : AppColors.ink,
                                ),
                              ),
                              if (line.unitPriceOverride != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withValues(
                                      alpha: .16,
                                    ),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    'Custom price',
                                    style: TextStyle(
                                      color: desktop
                                          ? _desktopAccent
                                          : AppColors.primary,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton.outlined(
                      tooltip: 'Decrease quantity',
                      onPressed: () => _changeQuantity(line, -1),
                      icon: const Icon(Icons.remove, size: 16),
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        foregroundColor: desktop ? _desktopText : AppColors.ink,
                        minimumSize: const Size.square(30),
                        maximumSize: const Size.square(30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: const BorderSide(color: Color(0xFF98A6A1)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text('${line.quantity}'),
                    const SizedBox(width: 4),
                    IconButton.outlined(
                      tooltip: 'Increase quantity',
                      onPressed: () => _changeQuantity(line, 1),
                      icon: const Icon(Icons.add, size: 16),
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 30,
                      ),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        foregroundColor: desktop ? _desktopText : AppColors.ink,
                        minimumSize: const Size.square(30),
                        maximumSize: const Size.square(30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        side: const BorderSide(color: Color(0xFF98A6A1)),
                      ),
                    ),
                    IconButton(
                      key: ValueKey('kitchen-edit-price-${line.lineId}'),
                      tooltip: 'Edit unit price',
                      onPressed: _orderLocked
                          ? null
                          : () => unawaited(_editLinePrice(line)),
                      icon: const Icon(Icons.price_change_outlined, size: 17),
                      color: desktop ? _desktopAccent : AppColors.primary,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 30,
                      ),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(28, 30),
                        maximumSize: const Size(28, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove item',
                      onPressed: () =>
                          setState(() => _lines.remove(line.lineId)),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      color: AppColors.danger,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 30,
                      ),
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        minimumSize: const Size(28, 30),
                        maximumSize: const Size(28, 30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (line.product.modifierGroups.any(
                      (group) => group.isActive,
                    ))
                      OutlinedButton.icon(
                        key: ValueKey(
                          'kitchen-cart-add-modifiers-${line.lineId}',
                        ),
                        onPressed: _orderLocked
                            ? null
                            : () => unawaited(_editModifiers(line)),
                        icon: const Icon(Icons.tune_rounded, size: 15),
                        label: Text(
                          line.modifiers.isEmpty
                              ? 'Add modifiers'
                              : 'Edit modifiers',
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          backgroundColor: const Color(0xFFEAF6F2),
                          side: const BorderSide(color: Color(0xFF9FCFC2)),
                          minimumSize: const Size(0, 34),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          textStyle: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    OutlinedButton.icon(
                      key: ValueKey('kitchen-item-note-${line.lineId}'),
                      onPressed: _orderLocked
                          ? null
                          : () => unawaited(_editItemNote(line)),
                      icon: const Icon(Icons.edit_note_rounded, size: 18),
                      label: Text(
                        line.itemNote.isEmpty ? 'Add note' : 'Edit note',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: desktop
                            ? _desktopAccent
                            : AppColors.primary,
                        backgroundColor: AppColors.primary.withValues(
                          alpha: desktop && !_lightLayout ? .24 : .08,
                        ),
                        side: BorderSide(
                          color: _orderLocked
                              ? (desktop ? _desktopBorder : _border)
                              : (desktop ? _desktopAccent : AppColors.primary),
                        ),
                        minimumSize: const Size(0, 34),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                    ),
                    if (line.modifiers.isNotEmpty)
                      Text(
                        line.modifiers
                            .map((modifier) => modifier.name)
                            .join(' • '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: desktop ? _desktopTextMuted : AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    if (line.itemNote.isNotEmpty)
                      Text(
                        line.itemNote,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: desktop ? _desktopTextMuted : AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _editNote() async {
    final controller = TextEditingController(text: _note);
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Order note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Preparation instructions',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (note != null && mounted) setState(() => _note = note.trim());
    controller.dispose();
  }
}

class KitchenOrderDetailsDialog extends StatelessWidget {
  const KitchenOrderDetailsDialog({
    super.key,
    required this.order,
    this.onPreviewBill,
    this.onPrintBill,
    this.onPrintKitchenTicket,
  });

  final Sale order;
  final Future<void> Function()? onPreviewBill;
  final Future<void> Function()? onPrintBill;
  final Future<void> Function()? onPrintKitchenTicket;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final orderNumber = order.invoiceNo.isEmpty
        ? 'Order #${order.serverId ?? order.localId}'
        : order.invoiceNo;
    return SafeArea(
      child: Dialog(
        insetPadding: EdgeInsets.all(compact ? 12 : 28),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 16 : 22,
                  compact ? 16 : 20,
                  12,
                  16,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFFDDF5ED),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Icon(
                        Icons.receipt_long_outlined,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  orderNumber,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFE8D1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  order.paymentStatus.isEmpty
                                      ? order.status
                                      : order.paymentStatus,
                                  style: const TextStyle(
                                    color: Color(0xFFB65C00),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            order.customer.name,
                            style: const TextStyle(color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 22,
                    18,
                    compact ? 14 : 22,
                    20,
                  ),
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final facts = [
                          _OrderFact(
                            icon: Icons.calendar_today_outlined,
                            label: 'Order time',
                            text: order.createdAt.toString().split('.').first,
                          ),
                          _OrderFact(
                            icon: Icons.payments_outlined,
                            label: 'Status',
                            text: order.paymentStatus.isEmpty
                                ? order.status
                                : order.paymentStatus,
                          ),
                          _OrderFact(
                            icon: Icons.shopping_bag_outlined,
                            label: 'Total items',
                            text: '${order.items.length} items',
                          ),
                        ];
                        if (constraints.maxWidth < 500) {
                          return Column(
                            children: facts
                                .map(
                                  (fact) => Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: fact,
                                  ),
                                )
                                .toList(),
                          );
                        }
                        return Row(
                          children: facts
                              .map(
                                (fact) => Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                    ),
                                    child: fact,
                                  ),
                                ),
                              )
                              .toList(),
                        );
                      },
                    ),
                    if (order.saleNote.trim().isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 13,
                        ),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFE8F8F3), Color(0xFFF3FBF8)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.takeout_dining_outlined,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                order.saleNote,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    const Text(
                      'Order items',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...order.items.map(
                      (line) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFFDCE5E2)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                width: 54,
                                height: 54,
                                color: const Color(0xFFF5F7F6),
                                alignment: Alignment.center,
                                child: ProductImage(
                                  line.product.imageUrl,
                                  width: 54,
                                  height: 54,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFDDF5ED),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${line.quantity}×',
                                style: const TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    line.product.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  if (line.modifiers.isNotEmpty)
                                    Text(
                                      line.modifiers
                                          .map(
                                            (modifier) =>
                                                '${modifier.quantity}× ${modifier.name}',
                                          )
                                          .join(' · '),
                                      style: const TextStyle(
                                        color: AppColors.primary,
                                      ),
                                    ),
                                  if (line.itemNote.trim().isNotEmpty)
                                    Text(
                                      line.itemNote,
                                      style: const TextStyle(
                                        color: AppColors.muted,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            RiyalAmount(line.total),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F7F6),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        children: [
                          _OrderTotalRow(
                            label: 'Subtotal',
                            value: order.total - order.tax + order.discount,
                          ),
                          _OrderTotalRow(label: 'Tax', value: order.tax),
                          if (order.discount > 0)
                            _OrderTotalRow(
                              label: 'Discount',
                              value: -order.discount,
                            ),
                          const Divider(height: 22),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFFE0F5EF), Color(0xFFF0FAF7)],
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: _OrderTotalRow(
                              label: 'Total',
                              value: order.total,
                              total: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: EdgeInsets.all(compact ? 12 : 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final actions = <Widget>[
                      OutlinedButton.icon(
                        onPressed: onPreviewBill == null
                            ? null
                            : () => onPreviewBill!(),
                        icon: const Icon(Icons.visibility_outlined),
                        label: const Text('Preview bill'),
                      ),
                      OutlinedButton.icon(
                        onPressed: onPrintBill == null
                            ? null
                            : () => onPrintBill!(),
                        icon: const Icon(Icons.print_outlined),
                        label: const Text('Print bill'),
                      ),
                      FilledButton.icon(
                        onPressed: onPrintKitchenTicket == null
                            ? null
                            : () => onPrintKitchenTicket!(),
                        icon: const Icon(Icons.restaurant_rounded),
                        label: const Text('Print kitchen ticket'),
                      ),
                    ];
                    if (constraints.maxWidth < 520) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: actions
                            .map(
                              (action) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: action,
                              ),
                            )
                            .toList(),
                      );
                    }
                    return Row(
                      children: actions
                          .map(
                            (action) => Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: action,
                              ),
                            ),
                          )
                          .toList(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OrderFact extends StatelessWidget {
  const _OrderFact({
    required this.icon,
    required this.label,
    required this.text,
  });
  final IconData icon;
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFFF7F9F8),
      border: Border.all(color: const Color(0xFFE7ECEA)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(
            color: Color(0xFFE3F6F0),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _OrderTotalRow extends StatelessWidget {
  const _OrderTotalRow({
    required this.label,
    required this.value,
    this.total = false,
  });
  final String label;
  final int value;
  final bool total;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: total ? 17 : 14,
            fontWeight: total ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
        const Spacer(),
        RiyalAmount(
          value,
          style: TextStyle(
            color: total ? AppColors.primary : null,
            fontSize: total ? 20 : 14,
            fontWeight: total ? FontWeight.w900 : FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _KitchenCustomerDialog extends StatefulWidget {
  const _KitchenCustomerDialog({
    required this.customers,
    required this.selected,
    required this.onSelected,
    required this.onCreate,
  });

  final List<Customer> customers;
  final Customer? selected;
  final ValueChanged<Customer> onSelected;
  final Future<Customer> Function({
    required String name,
    required String mobile,
    required String email,
  })
  onCreate;

  @override
  State<_KitchenCustomerDialog> createState() => _KitchenCustomerDialogState();
}

class _KitchenCustomerDialogState extends State<_KitchenCustomerDialog> {
  final _search = TextEditingController();
  late final List<Customer> _customers = [...widget.customers];
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final visible = _customers
        .where((customer) {
          if (query.isEmpty) return true;
          return customer.name.toLowerCase().contains(query) ||
              customer.businessName.toLowerCase().contains(query) ||
              customer.phone.toLowerCase().contains(query) ||
              customer.email.toLowerCase().contains(query);
        })
        .toList(growable: false);
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 620;

    return Dialog(
      insetPadding: EdgeInsets.all(compact ? 12 : 28),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 620,
          maxHeight: compact ? size.height - 24 : 620,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF5F1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.people_outline_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Customers',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          'Select a customer for this kitchen order.',
                          style: TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _search,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  hintText: 'Search name, business, phone or email',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('No customers found.'))
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: visible.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 58),
                      itemBuilder: (_, index) {
                        final customer = visible[index];
                        final selected = widget.selected?.id == customer.id;
                        final details = [
                          if (customer.businessName.isNotEmpty)
                            customer.businessName,
                          if (customer.phone.isNotEmpty) customer.phone,
                          if (customer.email.isNotEmpty) customer.email,
                        ].join('  •  ');
                        return ListTile(
                          selectedTileColor: const Color(0xFFF0F8F5),
                          selected: selected,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          leading: CircleAvatar(
                            backgroundColor: const Color(0xFFEAF5F1),
                            child: Icon(
                              customer.isBusiness
                                  ? Icons.storefront_outlined
                                  : Icons.person_outline_rounded,
                              color: AppColors.primary,
                            ),
                          ),
                          title: Text(
                            customer.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: details.isEmpty ? null : Text(details),
                          trailing: selected
                              ? const Icon(
                                  Icons.check_circle_rounded,
                                  color: AppColors.primary,
                                )
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: () {
                            widget.onSelected(customer);
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: const BoxDecoration(
                color: Color(0xFFFAFBFB),
                border: Border(top: BorderSide(color: Color(0xFFE2E8E5))),
              ),
              child: Row(
                children: [
                  Text(
                    '${visible.length} customer${visible.length == 1 ? '' : 's'}',
                    style: const TextStyle(color: AppColors.muted),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _createCustomer,
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                    label: const Text('Add customer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createCustomer() async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController();
    final mobile = TextEditingController();
    final email = TextEditingController();
    var saving = false;
    String? error;
    final customer = await showDialog<Customer>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Add customer'),
          content: SizedBox(
            width: 420,
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Customer name',
                    ),
                    validator: (value) => value?.trim().isEmpty ?? true
                        ? 'Customer name is required'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: mobile,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Mobile number',
                    ),
                    validator: (value) => value?.trim().isEmpty ?? true
                        ? 'Mobile number is required'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email (optional)',
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: saving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      update(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        final created = await widget.onCreate(
                          name: name.text.trim(),
                          mobile: mobile.text.trim(),
                          email: email.text.trim(),
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, created);
                        }
                      } on ApiException catch (exception) {
                        update(() {
                          saving = false;
                          error = exception.message;
                        });
                      } catch (_) {
                        update(() {
                          saving = false;
                          error =
                              'Unable to create customer. Please try again.';
                        });
                      }
                    },
              icon: saving
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded),
              label: Text(saving ? 'Saving...' : 'Create'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    mobile.dispose();
    email.dispose();
    if (customer == null || !mounted) return;
    setState(() => _customers.add(customer));
    widget.onSelected(customer);
    Navigator.pop(context);
  }
}

class _OrderSummaryChip extends StatelessWidget {
  const _OrderSummaryChip({
    required this.icon,
    required this.label,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: emphasized
            ? const Color(0xFFDDF5ED)
            : colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 17,
            color: emphasized
                ? const Color(0xFF08745D)
                : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: emphasized
                  ? const Color(0xFF075E4D)
                  : colors.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
