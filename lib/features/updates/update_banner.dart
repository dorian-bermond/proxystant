import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/providers.dart';
import '../../services/update_service.dart';

/// Wraps the app and, once per launch, checks whether a newer release exists.
///
/// When one does, a dismissible [MaterialBanner] offers a link to the release
/// page. Sits above the router so the check is not tied to any one screen, and
/// stays silent when up to date or when the check fails.
class UpdateBanner extends ConsumerStatefulWidget {
  final Widget child;

  const UpdateBanner({super.key, required this.child});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  @override
  void initState() {
    super.initState();
    // After the first frame, so a Scaffold is registered with the messenger.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    final update = await ref.read(updateServiceProvider).checkForUpdate();
    if (update == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.showMaterialBanner(
      MaterialBanner(
        content: Text(
          'Version ${update.latestVersion} is available '
          '(you have ${update.currentVersion}).',
        ),
        leading: const Icon(Icons.system_update_outlined),
        actions: [
          TextButton(
            onPressed: () => messenger.hideCurrentMaterialBanner(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              _openDownloadPage(update.downloadUrl);
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }

  Future<void> _openDownloadPage(String url) async {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);

    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Could not open the browser. Visit ${UpdateService.releasesPage}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
