// Settings panel — the flat Settings page body (#512, #552, #897).
//
// #897 reshape: settings are no longer wrapped in a self-collapsing
// `ExpansionTile`. Every control is a TOP-LEVEL row under a light, NON-collapsing
// subheader (General / Background / Terminal / Detection). The panel is composed
// into the single Settings page (settings_screen.dart) above the flattened
// [DiagnosticsSection]. A destructive "Reset settings" action sits at the bottom.
//
// Exposes the keep-alive-in-background toggle (#512), the terminal font-size
// slider (#552), the terminal-engine selector (#684/#725), the tmux control-mode
// opt-in (#913), and the structured-text detection toggles (#888). The font size
// persists via `fontSizeProvider` (SharedPreferences) and is applied live to the
// terminal.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/battery_optimization.dart';
import '../services/clipboard.dart';
import '../state/detection_exceptions_providers.dart';
import '../state/detection_providers.dart';
import '../state/detection_style_providers.dart';
import '../state/keepalive_providers.dart';
import '../state/sessions.dart';
import '../state/terminal_backend.dart';
import '../state/tmux_control_mode_setting.dart';
import '../state/ui_prefs_providers.dart';
import '../storage/detection_exceptions_store.dart';
import '../util/relative_time.dart';
import 'detection_lab_screen.dart';
import 'feedback_overlay.dart' show VersionResolver, resolveBuildVersion;
import 'keys_screen.dart';
import 'settings_subheader.dart';
import 'top_toast.dart';

class SettingsPanel extends ConsumerWidget {
  /// Injectable so widget tests can supply a fixed build string without a
  /// PackageInfo platform channel. Defaults to [resolveBuildVersion] — the SAME
  /// source of truth the bug-report `version` field uses, so the row shows the
  /// owner the exact build string he'd otherwise only see in an upload.
  const SettingsPanel({super.key, this.versionResolver = resolveBuildVersion});

  final VersionResolver versionResolver;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keepalive = ref.watch(keepaliveEnabledProvider);
    final fontSize = ref.watch(fontSizeProvider);
    final fontFamily = ref.watch(fontFamilyProvider);
    final controlMode = ref.watch(tmuxControlModeProvider);
    final detection = ref.watch(detectionSettingsProvider);
    // #995: persisted "Not a URL" / "Not a file" reports — listed for review,
    // each removable (removal restores detection of that text).
    final exceptions = ref.watch(detectionExceptionsProvider);
    // Flat layout (#897): a Column of top-level controls grouped by light,
    // non-collapsing subheaders. The 'settings-section' key is retained on the
    // root so existing tests / screenshots can still address the block, but it
    // no longer collapses — every control is visible without a tap.
    return Column(
      key: const ValueKey('settings-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsSubheader('General'),
        // App-version row. Shows the SAME build string the bug-report carries
        // (`[<version>+<build> <gitHash>]`) so the owner can read/screenshot the
        // running build on-device instead of pulling it from a feedback upload.
        // Tap copies the full string to the clipboard. (#897.)
        FutureBuilder<String>(
          future: versionResolver(),
          builder: (context, snap) {
            final version = snap.data ?? '…';
            return ListTile(
              key: const ValueKey('app-version-tile'),
              leading: const Icon(Icons.info_outline),
              title: const Text('App version'),
              subtitle: Text(
                version,
                key: const ValueKey('app-version-value'),
              ),
              trailing: const Icon(Icons.copy),
              onTap: snap.hasData
                  ? () => _copyVersion(context, version)
                  : null,
            );
          },
        ),
        const SettingsSubheader('Keys'),
        // #1088: the SSH key library — named, reusable keys managed independently
        // of any profile. Import here, then attach to one or more profiles from
        // the profile editor's key-source picker. Its own route (a manager, not a
        // settings toggle). Monochrome outlined icon.
        ListTile(
          key: const ValueKey('ssh-keys-tile'),
          leading: const Icon(Icons.vpn_key_outlined),
          title: const Text('SSH keys'),
          subtitle: const Text(
            'Manage named private keys you can attach to profiles.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showKeysScreen(context),
        ),
        const SettingsSubheader('Background'),
        SwitchListTile(
          key: const ValueKey('keepalive-toggle'),
          title: const Text('Keep alive in background'),
          subtitle: const Text(
            'Show an ongoing notification so Android keeps the SSH '
            'session connected when you swap to another app.',
          ),
          value: keepalive,
          onChanged: (v) => ref.read(keepaliveEnabledProvider.notifier).set(v),
        ),
        // #738: explicit battery-optimization exemption affordance. The
        // one-time auto-prompt fires on first connect, but a user who declined
        // (or wants to re-grant) can request it here. Excluding the app from
        // Doze battery optimization is what lets the keep-alive service hold the
        // connection through an ordinary screen-off sleep.
        ListTile(
          key: const ValueKey('battery-opt-tile'),
          leading: const Icon(Icons.battery_saver_outlined),
          title: const Text('Allow background battery use'),
          subtitle: const Text(
            'Exclude MobiSSH from battery optimization so Android keeps SSH '
            'sessions alive while the screen is off. Without this, the system '
            'may freeze the connection during sleep.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _requestBatteryOptExemption(context, ref),
        ),
        const SettingsSubheader('Terminal'),
        ListTile(
          key: const ValueKey('font-size-tile'),
          title: const Text('Terminal font size'),
          subtitle: Text('${fontSize.toStringAsFixed(0)} px'),
          trailing: Text(
            fontSize.toStringAsFixed(0),
            key: const ValueKey('font-size-value'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            key: const ValueKey('font-size-slider'),
            min: kFontSizeMin,
            max: kFontSizeMax,
            divisions: (kFontSizeMax - kFontSizeMin).round(),
            value: fontSize.clamp(kFontSizeMin, kFontSizeMax),
            label: fontSize.toStringAsFixed(0),
            onChanged: (v) => ref.read(fontSizeProvider.notifier).set(v),
          ),
        ),
        // Default terminal font (companion to #679's per-session picker). Sets
        // the GLOBAL default face a new/un-customized session inherits; a
        // per-session override from the session menu still wins for that
        // session. Tapping opens a bottom-sheet picker of the bundled families.
        ListTile(
          key: const ValueKey('default-font-tile'),
          leading: const Icon(Icons.font_download_outlined),
          title: const Text('Default terminal font'),
          subtitle: Text(_fontFamilyLabel(fontFamily)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pickDefaultFont(context, ref, fontFamily),
        ),
        // #966: the terminal-engine SELECTOR is retired from the release build.
        // Ghostty (flterm) is the whole product — gutter copy, detection, marks,
        // soft-wrap join are all Ghostty-only; a user flipping to the xterm
        // fallback silently lost every headline feature. The xterm backend +
        // render switch stay in code as an internal fallback (terminalBackendProvider
        // defaults to Ghostty; Reset restores it), just no longer user-facing.
        // #913 Part D: tmux control-mode (`tmux -CC`) opt-in. Default OFF — the
        // proven screen-scrape path stays the default; enabling this drives
        // `SshConnectCommand.controlMode` so NEW sessions enter control mode for
        // authoritative window/size + real switch gestures. Read at connect time
        // (restart-to-apply, like the engine selector). Monochrome outlined icon.
        SwitchListTile(
          key: const ValueKey('tmux-control-mode-toggle'),
          secondary: const Icon(Icons.cable_outlined),
          title: const Text('Terminal: tmux control mode (experimental)'),
          subtitle: const Text(
            'Drive tmux via control mode (-CC): authoritative windows/size + '
            'real switch gestures. Requires tmux on the host. Live sessions '
            'reconnect to apply.',
          ),
          value: controlMode,
          onChanged: (v) async {
            // #913: persist + sync the per-isolate global (read at connect time).
            await ref.read(tmuxControlModeProvider.notifier).set(v);
            // #916: the flag is read ONCE at connect — flipping it on a LIVE
            // session does nothing until a reconnect (the owner's "hadn't
            // reconnected after control mode on": gestures fired into a still-
            // scrape session). Trigger a clean reconnect of every connected
            // session so the new mode actually engages, and surface a hint.
            final reconnected = ref
                .read(sessionsProvider.notifier)
                .reconnectForControlModeChange();
            if (reconnected > 0 && context.mounted) {
              final mode = v ? 'control mode' : 'scrape mode';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Reconnecting $reconnected session'
                    '${reconnected == 1 ? '' : 's'} to apply $mode…',
                  ),
                ),
              );
            }
          },
        ),
        const SettingsSubheader('Detection'),
        // #888 Part A: in-terminal structured-text DETECTION. Master switch +
        // per-type toggles (URLs, file paths). When a type is off, the flterm
        // controller never registers that pattern (no scan, no decoration);
        // changes re-apply LIVE. Monochrome outlined icons only.
        SwitchListTile(
          key: const ValueKey('detection-master-toggle'),
          secondary: const Icon(Icons.search_outlined),
          title: const Text('Detect links & paths in terminal'),
          subtitle: Text(
            kDetectionDisabled971
                ? 'Temporarily turned off while we fix a repaint issue (#971). '
                  'Your setting is remembered and comes back when it\'s fixed.'
                : 'Find URLs, file paths and command lines in terminal '
                  'output and make them tappable.',
          ),
          value: detection.enabled,
          onChanged: (v) =>
              ref.read(detectionSettingsProvider.notifier).setEnabled(v),
        ),
        SwitchListTile(
          key: const ValueKey('detection-url-toggle'),
          secondary: const Icon(Icons.link_outlined),
          contentPadding: const EdgeInsets.only(left: 32, right: 16),
          title: const Text('URLs'),
          subtitle: const Text('Detect and tap http/https links.'),
          value: detection.url,
          onChanged: detection.enabled
              ? (v) => ref.read(detectionSettingsProvider.notifier).setUrl(v)
              : null,
        ),
        SwitchListTile(
          key: const ValueKey('detection-path-toggle'),
          secondary: const Icon(Icons.folder_outlined),
          contentPadding: const EdgeInsets.only(left: 32, right: 16),
          title: const Text('File paths'),
          subtitle: const Text('Detect absolute paths and open them in files.'),
          value: detection.path,
          onChanged: detection.enabled
              ? (v) => ref.read(detectionSettingsProvider.notifier).setPath(v)
              : null,
        ),
        // #1036: relative-path detection — cwd-resolved and VERIFICATION-gated
        // (an anchor only ever shows once its resolved path exists on the host).
        SwitchListTile(
          key: const ValueKey('detection-relpath-toggle'),
          secondary: const Icon(Icons.subdirectory_arrow_right),
          contentPadding: const EdgeInsets.only(left: 32, right: 16),
          title: const Text('Relative paths'),
          subtitle: const Text(
            'Detect paths relative to the shell directory; shown only after '
            'they verify on the host.',
          ),
          value: detection.relpath,
          onChanged: detection.enabled
              ? (v) =>
                  ref.read(detectionSettingsProvider.notifier).setRelpath(v)
              : null,
        ),
        // #998 slice C: command-line detection — a gutter chip that copies the
        // whole prompt-anchored command line paste-exact.
        SwitchListTile(
          key: const ValueKey('detection-command-toggle'),
          secondary: const Icon(Icons.terminal),
          contentPadding: const EdgeInsets.only(left: 32, right: 16),
          title: const Text('Command lines'),
          subtitle: const Text(
            'Detect command lines at a shell prompt; the gutter chip copies '
            'the whole command.',
          ),
          value: detection.command,
          onChanged: detection.enabled
              ? (v) =>
                  ref.read(detectionSettingsProvider.notifier).setCommand(v)
              : null,
        ),
        // #1031 slice 2: the Detection LAB — per-pattern colors, intensity,
        // live previews, behavior knobs. Its OWN route (a workbench, not a
        // settings row — the deliberate #897 exception per the reviewed IA);
        // the everyday toggles above stay here and the lab binds the SAME
        // providers. Placed after the type toggles, before exceptions, so the
        // section reads simple → deep.
        ListTile(
          key: const ValueKey('detection-lab-tile'),
          leading: const Icon(Icons.science_outlined),
          title: const Text('Detection lab'),
          subtitle: const Text(
            'Colors, intensity, and live previews per pattern.',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const DetectionLabScreen(),
            ),
          ),
        ),
        // #995: reviewable detection exceptions — the saved "Not a URL" /
        // "Not a file" reports. Each entry shows the suppressed text + when/
        // where it was reported, with a per-entry remove that restores
        // detection. NOT cleared by Reset settings (user data, like favorites).
        const SettingsSubheader('Detection exceptions'),
        if (exceptions.isEmpty)
          const ListTile(
            key: ValueKey('detection-exceptions-empty'),
            leading: Icon(Icons.playlist_remove_outlined),
            title: Text('No exceptions'),
            subtitle: Text(
              'Use "Not a URL" / "Not a file" / "Not a command" on a '
              'detected item to stop detecting that exact text. Saved '
              'reports appear here.',
            ),
          )
        else
          for (var i = 0; i < exceptions.length; i++)
            ListTile(
              key: ValueKey('detection-exception-$i'),
              leading: Icon(switch (exceptions[i].family) {
                'path' => Icons.folder_off_outlined,
                // #998 D: "Not a command" reports (family 'command').
                'command' => Icons.terminal,
                _ => Icons.link_off,
              }),
              title: Text(
                exceptions[i].matchedText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(_exceptionSubtitle(exceptions[i])),
              trailing: IconButton(
                key: ValueKey('detection-exception-remove-$i'),
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove exception (detect again)',
                onPressed: () => ref
                    .read(detectionExceptionsProvider.notifier)
                    .removeException(exceptions[i]),
              ),
            ),
        const SizedBox(height: 16),
        // #897: destructive reset. Confirms, then restores every persisted user
        // pref to its documented default by calling each provider's setter (NOT
        // a blind key wipe) so the UI reflects defaults immediately and no
        // corrupt/partial state can result.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            key: const ValueKey('settings-reset-button'),
            onPressed: () => _confirmAndReset(context, ref),
            icon: const Icon(Icons.restart_alt),
            style: OutlinedButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            label: const Text('Reset settings'),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// The human label for a bundled font-family id, for the default-font row.
  /// Falls back to the raw id for an unknown value (never blank).
  String _fontFamilyLabel(String id) {
    for (final f in terminalFontFamilies) {
      if (f.id == id) return f.label;
    }
    return id;
  }

  /// Bottom-sheet picker for the GLOBAL default terminal font. Lists the bundled
  /// families with the current default checked; tapping one persists it via
  /// [fontFamilyProvider] (new/un-customized sessions then inherit it) and
  /// closes the sheet.
  Future<void> _pickDefaultFont(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in terminalFontFamilies)
                ListTile(
                  key: ValueKey('default-font-option-${f.id}'),
                  title: Text(f.label),
                  trailing: f.id == current
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(f.id),
                ),
            ],
          ),
        );
      },
    );
    if (picked != null) {
      await ref.read(fontFamilyProvider.notifier).set(picked);
    }
  }

  /// Subtitle for one detection-exception row (#995): "when · host", dropping
  /// whichever segment is unknown (a record may carry neither).
  String _exceptionSubtitle(DetectionException e) {
    final when = formatRelative(e.tsMs > 0 ? e.tsMs ~/ 1000 : null);
    return [
      if (when.isNotEmpty) when,
      if (e.host.isNotEmpty) e.host,
    ].join(' · ');
  }

  Future<void> _copyVersion(BuildContext context, String version) async {
    final ok = await copyToClipboard(version);
    if (!context.mounted) return;
    if (ok) {
      showTopToast(context, 'Copied version');
    }
  }

  Future<void> _requestBatteryOptExemption(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = ref.read(batteryOptimizationProvider);
    final result = await controller.requestNow();
    if (messenger == null) return;
    final String message;
    switch (result.outcome) {
      case BatteryOptPromptOutcome.alreadyExempt:
        message = 'Already excluded from battery optimization.';
        break;
      case BatteryOptPromptOutcome.prompted:
        message = result.granted
            ? 'Excluded from battery optimization.'
            : 'Not excluded — sessions may drop during long sleeps.';
        break;
      case BatteryOptPromptOutcome.alreadyAsked:
      case BatteryOptPromptOutcome.unavailable:
        message = 'Battery optimization settings are unavailable here.';
        break;
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Confirm, then reset every persisted user preference to its documented
  /// default (#897). Each pref is reset via its provider's own setter so the
  /// state notifier emits and the UI updates live — no localStorage-key wipe,
  /// no schema-bump. Saved profiles + credentials are untouched.
  ///
  /// NOT reset here: the battery-optimization exemption is an OS-level system
  /// setting (and a one-time "asked" flag), not a value with a MobiSSH default —
  /// there is no safe in-app default to restore, so it is deliberately left
  /// alone (see TRACE).
  Future<void> _confirmAndReset(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('settings-reset-dialog'),
        title: const Text('Reset settings?'),
        content: const Text(
          'Restore all MobiSSH settings — font size, default font, terminal '
          'engine, keep-alive, link/path detection, detection lab tuning, and '
          'tmux control mode — to their defaults. Saved profiles, credentials, '
          'and detection exceptions are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('settings-reset-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(fontSizeProvider.notifier).set(fontSizeDefault);
    await ref.read(fontFamilyProvider.notifier).set(fontFamilyDefault);
    await ref.read(terminalBackendProvider.notifier).set(terminalBackendDefault);
    await ref.read(keepaliveEnabledProvider.notifier).set(keepaliveEnabledDefault);
    await ref.read(tmuxControlModeProvider.notifier).set(tmuxControlModeDefault);
    // Detection has no single-shot reset; restore each field to its default
    // (all-true — the documented no-regression default in detection_providers).
    final detectionNotifier = ref.read(detectionSettingsProvider.notifier);
    await detectionNotifier.setEnabled(true);
    await detectionNotifier.setUrl(true);
    await detectionNotifier.setPath(true);
    await detectionNotifier.setCommand(true);
    await detectionNotifier.setRelpath(true);
    // #1031 slice 2: lab styles are TUNED settings → reset with the rest.
    // AUTHORED data survives (detection exceptions here; custom pattern
    // definitions in slice 3) — the IA's one-sentence reset rule.
    await ref.read(detectionStylesProvider.notifier).clearAllTuned();

    if (context.mounted) {
      showTopToast(context, 'Settings reset to defaults');
    }
  }
}
