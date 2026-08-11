import 'package:flutter/material.dart';

/// Runs [task] behind a non-dismissible progress dialog. The task reports
/// progress through the callback it receives; the dialog closes when the
/// task completes (or throws — the error is rethrown to the caller).
Future<T> runWithProgressDialog<T>({
  required BuildContext context,
  required String title,
  required Future<T> Function(void Function(int done, int total) report) task,
}) async {
  final progress = ValueNotifier<(int, int)>((0, 0));

  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: progress,
            builder: (context, value, _) {
              final (done, total) = value;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: total == 0 ? null : done / total,
                  ),
                  const SizedBox(height: 12),
                  Text(total == 0 ? 'Preparing…' : '$done / $total'),
                ],
              );
            },
          ),
        ),
      );
    },
  );

  try {
    return await task((done, total) => progress.value = (done, total));
  } finally {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    // Let the dialog future settle before disposing the notifier.
    await dialog;
    progress.dispose();
  }
}
