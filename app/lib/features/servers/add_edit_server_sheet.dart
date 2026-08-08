import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection/connection.dart';
import '../../core/connection/connection_providers.dart';
import '../../core/tokens.dart';
import '../../data/db/db_providers.dart';

/// Add a new server, or edit one, as a **bottom sheet**.
///
/// It was a full page pushed onto the stack, which made adding a server the one
/// small form in the app that took over the screen — everything else that asks
/// for a few fields (start an agent, start new work, pick a directory, create a
/// PR) is a sheet. This is the same flow, same fields, same validation, same
/// save semantics; only the container changed.
///
/// **The keyboard is the whole trick here**, and it is why this uses the app's
/// existing sheet recipe verbatim rather than a new one:
///
///   - `isScrollControlled: true` lets the sheet grow past the default 9/16 of
///     the screen, which a three-field form plus a keyboard needs;
///   - `useSafeArea: true` keeps it clear of the status bar and the home
///     indicator;
///   - the outer `Padding` on `viewInsets.bottom` lifts the whole sheet by
///     exactly the keyboard's height, so the buttons ride above it instead of
///     under it;
///   - the content is a `SingleChildScrollView`, so when the lift leaves less
///     room than the form needs it **scrolls** rather than clipping or
///     overflowing.
///
/// All four together. Dropping any one of them reproduces the failure we hit
/// before — the layout shifting under a finger, so a field moves out from under
/// the tap that was aimed at it.
Future<void> showAddServerSheet(BuildContext context) =>
    _show(context, serverId: null);

/// Edit the saved server [serverId].
Future<void> showEditServerSheet(BuildContext context, String serverId) =>
    _show(context, serverId: serverId);

Future<void> _show(BuildContext context, {required String? serverId}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _ServerSheet(serverId: serverId),
    ),
  );
}

class _ServerSheet extends ConsumerStatefulWidget {
  const _ServerSheet({required this.serverId});

  /// Null = adding a new server; non-null = editing that server.
  final String? serverId;

  bool get isEditing => serverId != null;

  @override
  ConsumerState<_ServerSheet> createState() => _ServerSheetState();
}

class _ServerSheetState extends ConsumerState<_ServerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _baseUrl = TextEditingController();
  final _bearer = TextEditingController();
  bool _obscure = true;
  bool _saving = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) _loadExisting();
  }

  Future<void> _loadExisting() async {
    setState(() => _loading = true);
    final db = ref.read(databaseProvider);
    final repo = ref.read(serversRepositoryProvider);
    final row = await db.profileById(widget.serverId!);
    final bearer = await repo.bearerFor(widget.serverId!);
    if (!mounted) return;
    if (row != null) {
      _name.text = row.name;
      _baseUrl.text = row.baseUrl;
      _bearer.text = bearer ?? '';
    }
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _bearer.dispose();
    super.dispose();
  }

  String _newId() =>
      'srv_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    // Captured before the first await: this sheet pops on success, so neither
    // its own context nor anything looked up through it survives to the end.
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context);

    final id = widget.serverId ?? _newId();
    final connection = Connection(
      id: id,
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), ''),
      bearer: _bearer.text.trim(),
    );

    final repo = ref.read(serversRepositoryProvider);
    final result = await repo.save(connection);
    // Adding a server also selects it, so you land straight in its flock.
    if (!widget.isEditing) {
      await ref.read(activeServerIdProvider.notifier).set(result.saved.id);
    }

    if (!mounted) return;
    setState(() => _saving = false);
    navigator.pop();
    if (result.existed && !widget.isEditing) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('${result.saved.name} already exists — updated it'),
        ),
      );
    }
    if (!widget.isEditing) router.go('/inbox');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.dns_outlined, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.isEditing ? 'Edit server' : 'Add a server',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Mac Studio',
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Give it a name' : null,
              ),
              const SizedBox(height: Space.lg),
              TextFormField(
                controller: _baseUrl,
                textInputAction: TextInputAction.next,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Bridge base URL',
                  hintText: 'https://…ts.net',
                  prefixIcon: Icon(Icons.link),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (!t.startsWith('http')) return 'Must start with http(s)://';
                  if (Uri.tryParse(t) == null) return 'Not a valid URL';
                  return null;
                },
              ),
              const SizedBox(height: Space.lg),
              TextFormField(
                controller: _bearer,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Bearer token',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Token required' : null,
              ),
              const SizedBox(height: Space.md),
              Text(
                'The token is stored in the device keystore, never in the '
                'database. Pairing by QR fills these in automatically.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Space.xl),
              Row(
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  if (!widget.isEditing) ...[
                    TextButton.icon(
                      onPressed: _saving
                          ? null
                          : () {
                              Navigator.pop(context);
                              context.push('/pair');
                            },
                      icon: const Icon(Icons.qr_code_scanner, size: 18),
                      label: const Text('Scan QR'),
                    ),
                    const SizedBox(width: Space.md),
                  ],
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined, size: 18),
                    label: Text(widget.isEditing ? 'Save' : 'Add & open'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
