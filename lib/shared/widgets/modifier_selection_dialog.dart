import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../models/entities.dart';
import 'localized_text.dart';

Future<List<SelectedModifier>?> selectProductModifiers(
  BuildContext context,
  Product product, {
  List<SelectedModifier> initialModifiers = const [],
  String confirmLabel = 'Add to order',
}) {
  final groups = product.modifierGroups
      .where((group) => group.isActive)
      .toList(growable: false);
  if (groups.isEmpty) return Future.value(const <SelectedModifier>[]);
  return showDialog<List<SelectedModifier>>(
    context: context,
    builder: (_) => _ModifierSelectionDialog(
      product: product,
      groups: groups,
      initialModifiers: initialModifiers,
      confirmLabel: confirmLabel,
    ),
  );
}

class _ModifierSelectionDialog extends StatefulWidget {
  const _ModifierSelectionDialog({
    required this.product,
    required this.groups,
    required this.initialModifiers,
    required this.confirmLabel,
  });

  final Product product;
  final List<ModifierGroup> groups;
  final List<SelectedModifier> initialModifiers;
  final String confirmLabel;

  @override
  State<_ModifierSelectionDialog> createState() =>
      _ModifierSelectionDialogState();
}

class _ModifierSelectionDialogState extends State<_ModifierSelectionDialog> {
  final Map<String, Set<String>> _selected = {};
  int _focusedOption = 0;

  @override
  void initState() {
    super.initState();
    for (final modifier in widget.initialModifiers) {
      _selected
          .putIfAbsent(modifier.modifierGroupId, () => <String>{})
          .add(modifier.variationId);
    }
  }

  int _minimum(ModifierGroup group) => group.isRequired
      ? group.minSelections.clamp(1, 999999)
      : group.minSelections;

  bool get _valid => widget.groups.every((group) {
    final count = _selected[group.id]?.length ?? 0;
    final maximum = group.maxSelections;
    return count >= _minimum(group) && (maximum == null || count <= maximum);
  });

  void _toggle(ModifierGroup group, ModifierOption option, bool selected) {
    final values = _selected.putIfAbsent(group.id, () => <String>{});
    if (selected) {
      final maximum = group.maxSelections;
      if (maximum != null && maximum == 1) values.clear();
      if (maximum == null || values.length < maximum) {
        values.add(option.variationId);
      }
    } else {
      values.remove(option.variationId);
    }
    setState(() {});
  }

  void _confirm() {
    if (!_valid) return;
    final result = <SelectedModifier>[];
    for (final group in widget.groups) {
      final selected = _selected[group.id] ?? const <String>{};
      for (final option in group.options) {
        if (!selected.contains(option.variationId)) continue;
        result.add(
          SelectedModifier(
            modifierGroupId: group.id,
            modifierGroupName: group.name,
            variationId: option.variationId,
            name: option.name,
            unitPrice: option.priceAdjustment,
            priceIncludesTax: option.priceIncludesTax,
          ),
        );
      }
    }
    Navigator.of(context).pop(result);
  }

  List<({ModifierGroup group, ModifierOption option})> get _availableOptions =>
      [
        for (final group in widget.groups)
          for (final option in group.options)
            if (option.isActive && option.isAvailable)
              (group: group, option: option),
      ];

  KeyEventResult _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final options = _availableOptions;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final targetCount = options.length + 1;
      setState(() {
        _focusedOption = (_focusedOption + delta) % targetCount;
        if (_focusedOption < 0) _focusedOption += targetCount;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_focusedOption == options.length) {
        if (_valid) _confirm();
        return KeyEventResult.handled;
      }
      if (options.isEmpty) return KeyEventResult.handled;
      final focused = options[_focusedOption];
      final selected =
          _selected[focused.group.id]?.contains(focused.option.variationId) ??
          false;
      _toggle(focused.group, focused.option, !selected);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final compact = screen.width < 680;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) => _onKeyEvent(event),
      child: Dialog(
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 32,
          vertical: compact ? 16 : 28,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 900,
            maxHeight: screen.height * .86,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogHeader(compact),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 16 : 24,
                    20,
                    compact ? 16 : 24,
                    8,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final group in widget.groups) _groupCard(group),
                    ],
                  ),
                ),
              ),
              _dialogFooter(compact),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dialogHeader(bool compact) => Container(
    padding: EdgeInsets.fromLTRB(
      compact ? 16 : 24,
      compact ? 16 : 20,
      compact ? 8 : 14,
      compact ? 16 : 20,
    ),
    decoration: BoxDecoration(
      color: AppColors.primary.withValues(alpha: .07),
      border: const Border(bottom: BorderSide(color: Color(0xFFDCE7E3))),
    ),
    child: Row(
      children: [
        Container(
          width: compact ? 42 : 48,
          height: compact ? 42 : 48,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(Icons.tune_rounded, color: AppColors.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 20 : 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.3,
                ),
              ),
              const SizedBox(height: 2),
              const Text(
                'Customize this item',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );

  Widget _dialogFooter(bool compact) => Container(
    padding: EdgeInsets.fromLTRB(
      compact ? 16 : 24,
      12,
      compact ? 16 : 24,
      compact ? 16 : 20,
    ),
    decoration: const BoxDecoration(
      color: Color(0xFFFAFCFB),
      border: Border(top: BorderSide(color: Color(0xFFDCE7E3))),
    ),
    child: Column(
      children: [
        if (!compact)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Icon(
                  Icons.keyboard_alt_outlined,
                  size: 17,
                  color: AppColors.muted,
                ),
                SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Use ↑ / ↓ to move, then Space or Enter to select.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(minimumSize: const Size(96, 48)),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 10),
            Semantics(
              selected: _focusedOption == _availableOptions.length,
              child: FilledButton.icon(
                onPressed: _valid ? _confirm : null,
                style: FilledButton.styleFrom(
                  minimumSize: Size(compact ? 160 : 190, 48),
                  elevation: _focusedOption == _availableOptions.length ? 4 : 0,
                  shadowColor: AppColors.primary.withValues(alpha: .3),
                  side: BorderSide(
                    color: _focusedOption == _availableOptions.length
                        ? const Color(0xFFF4B942)
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                icon: const Icon(Icons.add_shopping_cart_rounded),
                label: Text(widget.confirmLabel),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _groupCard(ModifierGroup group) {
    final selected = _selected[group.id] ?? const <String>{};
    final available = group.options
        .where((option) => option.isActive && option.isAvailable)
        .toList(growable: false);
    final minimum = _minimum(group);
    final maximum = group.maxSelections;
    final arabic = context.isArabic;
    final instruction = maximum == 1
        ? (minimum > 0
              ? (arabic ? 'اختر خياراً واحداً' : 'Choose one')
              : (arabic ? 'اختر خياراً واحداً كحد أقصى' : 'Choose up to one'))
        : maximum == null
        ? (minimum > 0
              ? (arabic
                    ? 'اختر $minimum على الأقل'
                    : 'Choose at least $minimum')
              : (arabic ? 'اختياري' : 'Optional'))
        : minimum == maximum
        ? (arabic ? 'اختر $minimum' : 'Choose $minimum')
        : (arabic
              ? 'اختر من $minimum إلى $maximum'
              : 'Choose $minimum–$maximum');
    final missing = selected.length < minimum;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(
          color: missing ? const Color(0xFFF0C9C9) : const Color(0xFFDCE5E2),
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        instruction,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                if (minimum > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: missing
                          ? const Color(0xFFFFEEEE)
                          : AppColors.primary.withValues(alpha: .09),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      missing ? 'Required' : '${selected.length} selected',
                      style: TextStyle(
                        color: missing
                            ? const Color(0xFFB74343)
                            : AppColors.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (available.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('No options are currently available.'),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 10.0;
                  final columns = constraints.maxWidth >= 620 ? 2 : 1;
                  final width = columns == 2
                      ? (constraints.maxWidth - gap) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final option in available)
                        SizedBox(
                          width: width,
                          child: _optionTile(group, option, selected),
                        ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _optionTile(
    ModifierGroup group,
    ModifierOption option,
    Set<String> selected,
  ) {
    final optionIndex = _availableOptions.indexWhere(
      (entry) =>
          entry.group.id == group.id &&
          entry.option.variationId == option.variationId,
    );
    final focused = optionIndex == _focusedOption;
    final isSelected = selected.contains(option.variationId);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          setState(() => _focusedOption = optionIndex);
          _toggle(group, option, !isSelected);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 76),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primary.withValues(alpha: .09)
                : const Color(0xFFFAFCFB),
            border: Border.all(
              color: focused || isSelected
                  ? AppColors.primary
                  : const Color(0xFFDCE5E2),
              width: focused ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: isSelected,
                  onChanged: (value) {
                    setState(() => _focusedOption = optionIndex);
                    _toggle(group, option, value ?? false);
                  },
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      option.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: isSelected || focused
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: isSelected || focused ? AppColors.primary : null,
                      ),
                    ),
                    if (option.subSku.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        option.subSku,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                option.priceAdjustment == 0
                    ? 'Included'
                    : '+${money(option.priceAdjustment)}',
                style: TextStyle(
                  color: option.priceAdjustment == 0
                      ? AppColors.muted
                      : AppColors.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
