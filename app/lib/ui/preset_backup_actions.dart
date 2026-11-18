import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../state/import_exception.dart';
import '../state/preset_backup.dart';
import '../state/preset_providers.dart';
import '../theme/app_text.dart';
import 'import_dialogs.dart';
import 'sonic_controls.dart';
import 'unsaved_changes_dialog.dart';

/// Backs up all 50 User presets (P01–P50) to one file. Selecting each slot on
/// the pedal discards the current preset's unsaved edits, so those are
/// confirmed first.
Future<void> runBackupAll(BuildContext context, WidgetRef ref) async {
  if (ref.read(presetModifiedProvider) &&
      !await showUnsavedChangesDialog(context)) {
    return;
  }

  if (!context.mounted) return;

  String? saved;

  final ok = await _runWithProgress(
    context,
    ref,
    title: 'Backing up presets',
    errorTitle: 'Backup failed',
    action: (cancel) async =>
        saved = await backupAllPresets(ref, cancel: cancel),
  );

  if (ok && saved != null && context.mounted) {
    await _showInfo(
      context,
      'Backup complete',
      'All 50 presets saved to:\n$saved',
    );
  }
}

/// Restores a backup file into the User slots, after an overwrite warning.
Future<void> runRestoreBackup(BuildContext context, WidgetRef ref) async {
  final PresetBackup? backup;

  try {
    backup = await pickPresetBackup(ref);
  } on ImportException catch (e) {
    if (context.mounted) await _showInfo(context, 'Restore failed', e.message);

    return;
  }

  if (backup == null || !context.mounted) return;

  final slots = backup.presets.length;

  final confirmed =
      await showSonicDialog<bool>(
        context: context,
        builder: (context) => SonicDialog(
          maxWidth: 460,
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .stretch,
            children: [
              const Text('Restore backup?', style: AppText.dialogTitle),
              const SizedBox(height: 12),
              Text(
                'This overwrites $slots User preset${slots == 1 ? '' : 's'} '
                'on the pedal with the contents of the backup, and discards '
                'any unsaved edits. This cannot be undone.',
                style: AppText.dialogBody,
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: .end,
                children: [
                  SonicButton(
                    label: 'Cancel',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 10),
                  SonicButton(
                    label: 'Restore',
                    isAccent: true,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ) ??
      false;

  if (!confirmed || !context.mounted) return;

  final ok = await _runWithProgress(
    context,
    ref,
    title: 'Restoring presets',
    errorTitle: 'Restore failed',
    action: (cancel) => restorePresetBackup(ref, backup!, cancel: cancel),
  );

  if (ok && context.mounted) {
    await _showInfo(
      context,
      'Restore complete',
      '$slots preset${slots == 1 ? '' : 's'} written to the pedal.',
    );
  }
}

/// Shows the non-dismissible progress modal around [action], then an error
/// dialog if it throws [ImportException]. The modal has a Cancel button that
/// flips the `cancel` notifier handed to [action]. Returns true on success;
/// false on failure or cancellation.
Future<bool> _runWithProgress(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String errorTitle,
  required Future<void> Function(ValueNotifier<bool> cancel) action,
}) async {
  final cancel = ValueNotifier<bool>(false);

  unawaited(
    showSonicDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ImportProgressDialog(title: title, cancel: cancel),
    ),
  );

  ImportException? failure;
  var cancelled = false;

  try {
    await action(cancel);
  } on ImportException catch (e) {
    failure = e;
  } on BackupCancelled {
    cancelled = true;
  } finally {

    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  if (failure != null && context.mounted) {
    await _showInfo(context, errorTitle, failure.message);
  }

  return failure == null && !cancelled;
}

Future<void> _showInfo(BuildContext context, String title, String message) {
  return showSonicDialog<void>(
    context: context,
    builder: (_) => ImportErrorDialog(title: title, message: message),
  );
}
