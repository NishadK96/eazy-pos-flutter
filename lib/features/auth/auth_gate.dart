import 'package:flutter/material.dart' hide Text;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:eazy_pos/shared/widgets/localized_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../home/app_shell.dart';
import 'auth_controller.dart';
import '../backend/presentation/backend_controller.dart';
import '../backend/data/eazyerp_backend_repository.dart';
import '../app_update/presentation/windows_update_gate.dart';

class AuthGate extends ConsumerWidget {
  const AuthGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    return auth.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => _returnToLogin(context),
      data: (token) {
        if (token == null || token.isEmpty) return _returnToLogin(context);
        final sync = ref.watch(backendControllerProvider);
        return sync.when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (error, _) => Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text(error.toString(), textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () =>
                          ref.invalidate(backendControllerProvider),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                    TextButton.icon(
                      onPressed: () => _copyDiagnosticDetails(context, error),
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Copy diagnostic details'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          data: (_) => WindowsUpdateGate(
            accessToken: token,
            child: AppShell(child: child),
          ),
        );
      },
    );
  }

  Widget _returnToLogin(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) context.go('/login');
    });
    return const Scaffold(body: SizedBox.shrink());
  }
}

Future<void> _copyDiagnosticDetails(BuildContext context, Object error) async {
  final failure = error is StartupSyncFailure ? error : null;
  var version = 'Unavailable';
  try {
    final package = await PackageInfo.fromPlatform();
    version = '${package.version}+${package.buildNumber}';
  } catch (_) {
    // Keep diagnostics available even if package metadata cannot be read.
  }
  final details = [
    'Eazy POS startup sync',
    'UTC: ${(failure?.occurredAt ?? DateTime.now().toUtc()).toIso8601String()}',
    'Platform: ${kIsWeb ? 'web' : defaultTargetPlatform.name}',
    'Build: $version',
    'Step: ${failure?.step ?? 'Unavailable'}',
    'Error type: ${failure?.category ?? error.runtimeType}',
    if (failure != null) 'Elapsed: ${failure.elapsed.inMilliseconds} ms',
    if (failure?.statusCode case final status?) 'HTTP status: $status',
  ].join('\n');
  try {
    await Clipboard.setData(ClipboardData(text: details));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostic details copied')),
      );
    }
  } catch (_) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Diagnostic details'),
        content: SelectableText(details),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
