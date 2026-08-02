import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection/connection.dart';
import '../../core/connection/connection_providers.dart';
import '../../data/db/db_providers.dart';

/// Add a new server or edit an existing one. The manual path into the
/// `{baseUrl, bearer}` seam; QR pairing (coming) writes the same [Connection]
/// via the same [ServersRepository.save].
class AddEditServerScreen extends ConsumerStatefulWidget {
  const AddEditServerScreen({super.key, this.serverId});

  /// Null = adding a new server; non-null = editing that server.
  final String? serverId;

  bool get isEditing => serverId != null;

  @override
  ConsumerState<AddEditServerScreen> createState() =>
      _AddEditServerScreenState();
}

class _AddEditServerScreenState extends ConsumerState<AddEditServerScreen> {
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

    final id = widget.serverId ?? _newId();
    final connection = Connection(
      id: id,
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), ''),
      bearer: _bearer.text.trim(),
    );

    final repo = ref.read(serversRepositoryProvider);
    await repo.save(connection);
    // Adding a server also selects it, so you land straight in its inbox.
    if (!widget.isEditing) {
      await ref.read(activeServerIdProvider.notifier).set(id);
    }

    if (!mounted) return;
    setState(() => _saving = false);
    if (widget.isEditing) {
      if (context.canPop()) context.pop();
    } else {
      context.go('/inbox');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit server' : 'Add server'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _name,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'Mac Studio',
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Give it a name'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _baseUrl,
                    textInputAction: TextInputAction.next,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Bridge base URL',
                      hintText: 'https://…ts.net',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (!t.startsWith('http')) {
                        return 'Must start with http(s)://';
                      }
                      if (Uri.tryParse(t) == null) return 'Not a valid URL';
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _bearer,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Bearer token',
                      prefixIcon: const Icon(Icons.key_outlined),
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Token required'
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The token is stored in the device keystore, never in the '
                    'database. QR pairing will fill these in automatically.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(widget.isEditing ? 'Save' : 'Add & open'),
                  ),
                  if (!widget.isEditing) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('QR pairing arrives with the /pair flow'),
                        ),
                      ),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('Pair with QR (soon)'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
