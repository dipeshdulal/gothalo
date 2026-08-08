import 'package:flutter/material.dart';

/// A search field — the one shape the app's [InputDecorationTheme] cannot
/// express on its own, because it needs a glyph and a clear affordance.
///
/// Everything about how it *looks* still comes from the theme: this only adds
/// the leading search glyph and the trailing clear button, so a search box on
/// one screen cannot drift from a search box on another. There is no border,
/// fill or radius declared here on purpose — the moment a widget restates those
/// it becomes a second treatment.
class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hintText,
    this.focusNode,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;
  final FocusNode? focusNode;

  /// Off by default, deliberately. A search sheet that raises the keyboard on
  /// open loses half its results to it — see the Jump sheet, where that was the
  /// single biggest usability complaint.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: Icon(
          Icons.search,
          size: 18,
          color: scheme.onSurfaceVariant,
        ),
        // Rebuilt from the controller rather than from a parent `setState`, so a
        // field in a sheet does not need its host to rebuild to show the clear.
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
      ),
    );
  }
}
