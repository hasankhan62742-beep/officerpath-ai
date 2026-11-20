import 'package:flutter/material.dart';
import 'package:ota_update/ota_update.dart';

import '../services/app_update_service.dart';

/// "New version available" prompt + download progress (v1.3).
///
/// [maybePromptForUpdate] runs once per launch from HomeScreen — after
/// the first frame, with a short delay, so it never blocks startup.
/// [checkForUpdatesManually] is the About screen's button: it reports
/// "up to date" too, instead of staying silent.
///
/// The user still taps "Install" on Android's own prompt — a regular
/// app can never install silently. If the download fails, the dialog
/// closes with a plain message and the user can install from the link.
Future<void> maybePromptForUpdate(BuildContext context) async {
  final service = AppUpdateService.instance;
  final update = await service.checkForUpdate();
  if (update == null) return;
  if (await service.isDismissed(update.tag)) return;
  if (!context.mounted) return;
  final go = await _showUpdateAvailableDialog(context, update);
  if (!context.mounted) return;
  if (go == true) {
    await _showUpdateDownloadDialog(context, update);
  } else {
    await service.dismiss(update.tag);
  }
}

/// Manual check (About screen). Always reports the outcome.
///
/// Play builds: self-update is forbidden, so this does NOTHING except
/// say updates come from Play — it never hits the network and never
/// offers an APK. The flag lives in [AppUpdateService.selfUpdateEnabled]
/// (`--dart-define=PLAY_BUILD=true`); the Home launch check is gated
/// the same way, inside [AppUpdateService.checkForUpdate].
Future<void> checkForUpdatesManually(BuildContext context) async {
  if (!AppUpdateService.selfUpdateEnabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Updates Play Store se aate hain — Play Store app mein '
          'OfficerPath AI update karein.',
        ),
      ),
    );
    return;
  }
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 16),
          Text('Update check ho raha hai…'),
        ],
      ),
    ),
  );
  final update = await AppUpdateService.instance.checkForUpdate();
  if (!context.mounted) return;
  Navigator.of(context).pop(); // close the checking dialog
  if (update == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'App up to date hai — aap latest version use kar rahe hain.',
        ),
      ),
    );
    return;
  }
  final go = await _showUpdateAvailableDialog(context, update);
  if (!context.mounted) return;
  if (go == true) {
    await _showUpdateDownloadDialog(context, update);
  } else {
    await AppUpdateService.instance.dismiss(update.tag);
  }
}

Future<bool?> _showUpdateAvailableDialog(
  BuildContext context,
  AppUpdateInfo update,
) {
  final sizeText = update.assetSize > 0
      ? ' (${(update.assetSize / 1048576).toStringAsFixed(0)} MB)'
      : '';
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Nayi version available hai'),
      content: Text(
        'OfficerPath AI v${update.latestVersion}$sizeText aa gayi hai. '
        'Update karein? Aap ke tests aur books mehfooz rahein ge.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Baad mein'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Update karein'),
        ),
      ],
    ),
  );
}

Future<void> _showUpdateDownloadDialog(
  BuildContext context,
  AppUpdateInfo update,
) async {
  final result = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpdateDownloadDialog(update: update),
  );
  if (result != null && result.isNotEmpty && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(result)),
    );
  }
}

/// Download progress dialog. Starts the download once in [initState];
/// closes itself when Android takes over (INSTALLING) or on failure
/// (returns the failure message for a SnackBar, or '' on success/cancel).
class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({required this.update});

  final AppUpdateInfo update;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  double _progress = 0;
  String _status = 'Download ho raha hai… 0%';
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    AppUpdateService.instance.downloadAndInstall(widget.update).listen(
      _onEvent,
      onError: (_) => _fail(
        'Update download nahi ho saka. Internet check karein ya '
        'GitHub link se install karein.',
      ),
    );
  }

  void _onEvent(OtaEvent event) {
    if (_finished || !mounted) return;
    switch (event.status) {
      case OtaStatus.DOWNLOADING:
        final pct = int.tryParse(event.value ?? '') ?? 0;
        setState(() {
          _progress = pct.clamp(0, 100) / 100;
          _status = 'Download ho raha hai… $pct%';
        });
      case OtaStatus.INSTALLING:
      case OtaStatus.INSTALLATION_DONE:
        // Android takes over with its own install prompt.
        _finished = true;
        Navigator.of(context).pop('');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Installer khul raha hai — Install dabayein.'),
          ),
        );
      case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
        _fail(
          'Install ki ijazat nahi mili. Phone ki Settings mein '
          'OfficerPath ke liye "Install unknown apps" on karein, phir '
          'dobara try karein.',
        );
      case OtaStatus.DOWNLOAD_ERROR:
      case OtaStatus.CHECKSUM_ERROR:
      case OtaStatus.INTERNAL_ERROR:
      case OtaStatus.INSTALLATION_ERROR:
      case OtaStatus.ALREADY_RUNNING_ERROR:
      case OtaStatus.CANCELED:
        _fail(
          'Update download nahi ho saka. Internet check karein ya '
          'GitHub link se install karein.',
        );
    }
  }

  void _fail(String message) {
    if (_finished || !mounted) return;
    _finished = true;
    Navigator.of(context).pop(message);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Update v${widget.update.latestVersion}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 12),
          Text(_status),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            OtaUpdate().cancel();
            Navigator.of(context).pop('');
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
