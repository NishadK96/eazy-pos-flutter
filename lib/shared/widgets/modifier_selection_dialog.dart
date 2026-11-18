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
        backgroundColor: const Color(0xFF102A31),
        surfaceTintColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 32,
          vertical: compact ? 12 : 24,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF2B5960)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: screen.height * .80,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogHeader(compact),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 12 : 16,
                    12,
                    compact ? 12 : 16,
                    4,
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
    padding: EdgeInsets.fromLTRB(compact ? 14 : 18, 12, compact ? 6 : 10, 12),
    decoration: const BoxDecoration(
      color: Color(0xFF0C2228),
      border: Border(bottom: BorderSide(color: Color(0xFF294950))),
    ),
    child: Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: const Color(0xFF18A989).withValues(alpha: .18),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.tune_rounded,
            color: Color(0xFF39D3B2),
            size: 20,
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 17 : 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.3,
                ),
              ),
              const SizedBox(height: 1),
              const Text(
                'Choose modifiers',
                style: TextStyle(
                  color: Color(0xFF9CB1B6),
                  fontSize: 12,
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
          color: const Color(0xFFB9C8CB),
          visualDensity: VisualDensity.compact,
        ),
      ],
    ),
  );

  Widget _dialogFooter(bool compact) => Container(
    padding: EdgeInsets.fromLTRB(compact ? 12 : 16, 9, compact ? 12 : 16, 11),
    decoration: const BoxDecoration(
      color: Color(0xFF0C2228),
      border: Border(top: BorderSide(color: Color(0xFF294950))),
    ),
    child: Column(
      children: [
        if (!compact)
          const Padding(
            padding: EdgeInsets.only(bottom: 7),
            child: Row(
              children: [
                Icon(
                  Icons.keyboard_alt_outlined,
                  size: 17,
                  color: Color(0xFF82999E),
                ),
                SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Use ↑ / ↓ to move, then Space or Enter to select.',
                    style: TextStyle(color: Color(0xFF82999E), fontSize: 11),
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
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFB9C8CB),
                minimumSize: const Size(82, 40),
              ),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 10),
            Semantics(
              selected: _focusedOption == _availableOptions.length,
              child: FilledButton.icon(
                onPressed: _valid ? _confirm : null,
                style: FilledButton.styleFrom(
                  minimumSize: Size(compact ? 145 : 170, 40),
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
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF17323A),
        border: Border.all(
          color: missing ? const Color(0xFF8D4B52) : const Color(0xFF31515A),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        instruction,
                        style: const TextStyle(
                          color: Color(0xFF9CB1B6),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (minimum > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: missing
                          ? const Color(0xFF492C32)
                          : const Color(0xFF16493F),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      missing ? 'Required' : '${selected.length} selected',
                      style: TextStyle(
                        color: missing
                            ? const Color(0xFFFFA8AE)
                            : const Color(0xFF67E2C5),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF31515A)),
          if (available.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'No options are currently available.',
                  style: TextStyle(color: Color(0xFF9CB1B6)),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 7.0;
                  final columns = constraints.maxWidth >= 500 ? 2 : 1;
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
        borderRadius: BorderRadius.circular(9),
        onTap: () {
          setState(() => _focusedOption = optionIndex);
          _toggle(group, option, !isSelected);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF155044)
                : const Color(0xFF102A31),
            border: Border.all(
              color: focused || isSelected
                  ? const Color(0xFF39D3B2)
                  : const Color(0xFF31515A),
              width: focused ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: Checkbox(
                  value: isSelected,
                  activeColor: const Color(0xFF22B894),
                  checkColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF6C858B)),
                  onChanged: (value) {
                    setState(() => _focusedOption = optionIndex);
                    _toggle(group, option, value ?? false);
                  },
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),
              const SizedBox(width: 9),
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
                        fontSize: 13,
                        fontWeight: isSelected || focused
                            ? FontWeight.w800
                            : FontWeight.w600,
                        color: isSelected || focused
                            ? const Color(0xFF67E2C5)
                            : Colors.white,
                      ),
                    ),
                    if (option.subSku.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        option.subSku,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF8FA4A9),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                option.priceAdjustment == 0
                    ? 'Included'
                    : '+${money(option.priceAdjustment)}',
                style: TextStyle(
                  color: option.priceAdjustment == 0
                      ? const Color(0xFF8FA4A9)
                      : const Color(0xFF67E2C5),
                  fontSize: 11,
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
