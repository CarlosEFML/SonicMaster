import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/preset_json.dart';
import '../model/preset_ref.dart';
import '../protocol/parameter_values_decoder.dart';
import '../protocol/preset_state_decoder.dart';
import '../protocol/selected_effects_decoder.dart';
import 'data_providers.dart';
import 'device_providers.dart';
import 'file_download.dart';
import 'import_exception.dart';
import 'names_providers.dart';
import 'preset_io.dart';
import 'preset_providers.dart';

/// `type` marker of a full-backup file (distinguishes it from a single preset).
const presetBackupType = 'sonicmaster-backup';

/// Version of the backup container (each entry is a regular preset JSON doc).
const presetBackupVersion = '1.0';

const _userSlots = 50;

/// Thrown when the user cancels a running backup/restore.
class BackupCancelled implements Exception {
  const BackupCancelled();
}

/// Reads all 50 User presets (P01–P50) from the pedal and writes them to one
/// JSON backup file. Each slot is selected on the device in turn and its state
/// dumped, so the live (unsaved) edits of the current preset are discarded —
/// the caller confirms first. The originally selected preset is re-selected at
/// the end. Progress goes to [importProgressProvider]/[presetLoadStatusProvider].
///
/// Returns the saved path (or file name on web), or null if the user cancelled
/// the save dialog. Throws [ImportException] on any device failure, or
/// [BackupCancelled] if [cancel] turns true — nothing is written in either case.
Future<String?> backupAllPresets(
  WidgetRef ref, {
  ValueListenable<bool>? cancel,
}) async {
  if (ref.read(presetLoadingProvider)) {
    throw const ImportException('The pedal is busy — try again in a moment.');
  }

  final data = ref.read(dataAssetsProvider).valueOrNull;

  if (data == null) throw const ImportException('Device data not loaded yet.');

  final service = ref.read(deviceServiceProvider);
  final status = ref.read(presetLoadStatusProvider.notifier);
  final progress = ref.read(importProgressProvider.notifier);
  final original = ref.read(currentPresetProvider);

  ref.read(presetLoadingProvider.notifier).state = true;
  progress.state = 0;

  final entries = <Map<String, dynamic>>[];

  try {
    if (ref.read(presetNamesProvider).isEmpty) await refreshNames(ref);

    final names = ref.read(presetNamesProvider);

    for (var slot = 1; slot <= _userSlots; slot++) {
      if (cancel?.value ?? false) throw const BackupCancelled();

      final label = PresetRef(.user, slot).label;

      status.state = 'Reading $label ($slot/$_userSlots)…';
      progress.state = (slot - 1) / _userSlots;

      final select = data.commands.presetSelect(.user, slot);

      if (select == null || !await service.sendAndAwaitAck(select)) {
        throw ImportException('$label: the pedal did not confirm the select.');
      }

      // Let the pedal settle on the new preset before dumping its state.
      await Future<void>.delayed(const Duration(milliseconds: 150));

      String? dump;

      for (var attempt = 0; attempt < 3 && dump == null; attempt++) {
        dump = await service.requestStateDump(
          timeout: const Duration(seconds: 3),
        );
      }

      if (dump == null) {
        throw ImportException('$label: no state received from the pedal.');
      }

      final state = PresetStateDecoder(data.modules).decode(dump);

      if (state == null) {
        throw ImportException('$label: could not decode the preset state.');
      }

      final selected = SelectedEffectsDecoder(data.signatures).decode(dump);

      entries.add({
        'slot': slot,
        'preset': presetToJson(
          state: state,
          selected: selected,
          params: ParameterValuesDecoder(
            data.parameters,
          ).decode(dump, selected, data.effects),
          data: data,
          presetName: names[PresetRef(.user, slot)] ?? '',
        ),
      });
    }
  } finally {
    // Put the pedal back on the preset the user was editing.
    status.state = 'Restoring selection…';

    ref.read(presetLoadingProvider.notifier).state = false;
    progress.state = null;

    if (original != null) {
      await loadPreset(ref, original);
    }
  }

  final doc = {
    'type': presetBackupType,
    'version': presetBackupVersion,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'presets': entries,
  };

  final stamp = DateTime.now().toIso8601String().substring(0, 10);

  try {
    final saved = await saveBytesFile(
      fileName: 'SonicMaster_backup_$stamp.json',
      bytes: utf8.encode(const JsonEncoder.withIndent('  ').convert(doc)),
      dialogTitle: 'Save full backup',
      extensions: const ['json'],
    );

    status.state = saved == null
        ? 'backup cancelled'
        : 'backup of $_userSlots presets saved';

    return saved;
  } catch (e) {
    throw ImportException('Could not write the backup file:\n$e');
  }
}

/// A validated backup file, ready to be written back to the pedal.
class PresetBackup {
  PresetBackup(this.presets);

  /// User slot (1–50) -> converted preset.
  final Map<int, ImportedPreset> presets;

  /// User slot -> preset name from the file.
  final Map<int, String> names = {};
}

/// Lets the user pick a backup file and validates all of it up front (so a bad
/// file is rejected before anything is written to the pedal). Returns null if
/// the picker was cancelled. Throws [ImportException] for an invalid file.
Future<PresetBackup?> pickPresetBackup(WidgetRef ref) async {
  final data = ref.read(dataAssetsProvider).valueOrNull;

  if (data == null) throw const ImportException('Device data not loaded yet.');

  final res = await FilePicker.platform.pickFiles(
    dialogTitle: 'Restore backup',
    type: .custom,
    allowedExtensions: const ['json'],
    withData: true,
  );

  final bytes = res?.files.single.bytes;

  if (bytes == null) return null;

  try {
    final json = jsonDecode(utf8.decode(bytes));

    if (json is! Map<String, dynamic> || json['type'] != presetBackupType) {
      throw const FormatException(
        'This is not a SonicMaster full-backup file.',
      );
    }

    if (json['version'] != presetBackupVersion) {
      throw FormatException('Unsupported backup version: ${json['version']}');
    }

    final backup = PresetBackup({});

    for (final raw in json['presets'] as List) {
      final entry = raw as Map<String, dynamic>;
      final slot = entry['slot'] as int;

      if (slot < 1 || slot > _userSlots) {
        throw FormatException('Invalid slot $slot in backup.');
      }

      final preset = entry['preset'] as Map<String, dynamic>;

      backup.presets[slot] = importedPresetFromJson(preset, data);
      backup.names[slot] = (preset['presetName'] as String?) ?? '';
    }

    if (backup.presets.isEmpty) {
      throw const FormatException('The backup contains no presets.');
    }

    return backup;
  } on FormatException catch (e) {
    throw ImportException('Invalid backup file:\n${e.message}');
  } catch (e) {
    throw ImportException('Invalid backup file:\n$e');
  }
}

/// Writes every preset of [backup] into its User slot on the pedal (select ->
/// push -> save). Overwrites the slots' current contents. Stops at the first
/// failing slot and throws [ImportException] naming it (earlier slots stay
/// restored); throws [BackupCancelled] if [cancel] turns true (same); the originally selected preset is re-selected at the end.
Future<void> restorePresetBackup(
  WidgetRef ref,
  PresetBackup backup, {
  ValueListenable<bool>? cancel,
}) async {
  if (ref.read(presetLoadingProvider)) {
    throw const ImportException('The pedal is busy — try again in a moment.');
  }

  final status = ref.read(presetLoadStatusProvider.notifier);
  final progress = ref.read(importProgressProvider.notifier);
  final original = ref.read(currentPresetProvider);
  final slots = backup.presets.keys.toList()..sort();

  progress.state = 0;

  try {
    for (final (i, slot) in slots.indexed) {
      // Checked only between slots, so a slot is never left half-written.
      if (cancel?.value ?? false) throw const BackupCancelled();

      final target = PresetRef(.user, slot);
      final fallback = 'Preset $slot';
      final name = backup.names[slot]!.trim().isEmpty
          ? fallback
          : backup.names[slot]!;

      progress.state = i / slots.length;

      await loadPreset(ref, target);

      if (ref.read(currentPresetProvider) != target) {
        throw ImportException('${target.label}: could not select the slot.');
      }

      if (!await pushImportedPreset(ref, backup.presets[slot]!)) {
        throw ImportException('${target.label}: could not apply the preset.');
      }

      // Same flow as the Save dialog; the name field is 10 characters.
      final saved = await savePreset(
        ref,
        slot,
        name.length > 10 ? name.substring(0, 10) : name,
      );

      if (!saved) throw ImportException('${target.label}: save failed.');

      status.state = 'Restored ${target.label} (${i + 1}/${slots.length})';
    }

    status.state = 'restored ${slots.length} presets';
  } finally {
    progress.state = null;

    if (original != null) await loadPreset(ref, original);
  }
}
