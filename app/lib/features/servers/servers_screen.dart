import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/connection/connection_providers.dart';

/// The home screen: the list of saved bridges ("servers"). Add one, pick one to
/// open its inbox, edit or remove. New servers are added manually today and via
/// QR pairing later — both land here.
class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});

  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  @override
  void initState() {
    super.initState();
    // Seed the optional dev server (from --dart-define) once on a fresh install.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(serversRepositoryProvider).ensureDevSeed();
    });
  }

  Future<void> _open(ServerSummary server) async {
    await ref.read(activeServerIdProvider.notifier).set(server.id);
    if (mounted) context.go('/inbox');
  }

  Future<void> _confirmDelete(ServerSummary server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${server.name}?'),
        content: const Text(
          'This deletes the saved server and its token from this device.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(serversRepositoryProvider).delete(server.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(serversProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Servers')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/servers/add'),
        tooltip: 'Add server',
        child: const Icon(Icons.add),
      ),
      body: servers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyServers();
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = list[i];
              return _ServerTile(
                server: s,
                onTap: () => _open(s),
                onEdit: () => context.push('/servers/${s.id}/edit'),
                onDelete: () => _confirmDelete(s),
              );
            },
          );
        },
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.server,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  final ServerSummary server;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: server.isActive
            ? scheme.primary
            : scheme.surfaceContainerHighest,
        child: Icon(
          Icons.dns_outlined,
          color: server.isActive ? scheme.onPrimary : scheme.onSurfaceVariant,
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (server.isActive) ...[
            const SizedBox(width: 8),
            _ActivePill(scheme: scheme),
          ],
        ],
      ),
      subtitle: Text(
        Uri.tryParse(server.baseUrl)?.host ?? server.baseUrl,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Remove')),
        ],
      ),
    );
  }
}

class _ActivePill extends StatelessWidget {
  const _ActivePill({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Active',
        style: TextStyle(
          color: scheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyServers extends StatelessWidget {
  const _EmptyServers();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No servers yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Add a gothalo bridge to see your agents. Enter its URL and token, '
              'or pair by scanning a QR.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => context.push('/servers/add'),
              icon: const Icon(Icons.add),
              label: const Text('Add your first server'),
            ),
          ],
        ),
      ),
    );
  }
}
