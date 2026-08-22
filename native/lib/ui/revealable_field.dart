// Obscured text field with a show/hide eye toggle (owner request on the
// export-backup dialog: "passwords should have preview toggle"). Shared by
// every secret-entry field — export/import passphrases, profile password,
// key passphrases — so the affordance is consistent app-wide. Starts hidden;
// the toggle only changes VISIBILITY, never what is stored or logged.

import 'package:flutter/material.dart';

class RevealableTextField extends StatefulWidget {
  const RevealableTextField({
    super.key,
    required this.controller,
    required this.fieldKeyName,
    required this.labelText,
    this.hintText,
    this.border,
    this.enabled = true,
    this.onSubmitted,
  });

  final TextEditingController controller;

  /// String key for the inner [TextField] (kept identical to the pre-toggle
  /// keys so existing widget tests and finders stay valid). The eye toggle
  /// gets `<fieldKeyName>-reveal`.
  final String fieldKeyName;

  final String labelText;
  final String? hintText;
  final InputBorder? border;
  final bool enabled;
  final ValueChanged<String>? onSubmitted;

  @override
  State<RevealableTextField> createState() => _RevealableTextFieldState();
}

class _RevealableTextFieldState extends State<RevealableTextField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: Key(widget.fieldKeyName),
      controller: widget.controller,
      enabled: widget.enabled,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        border: widget.border,
        suffixIcon: IconButton(
          key: Key('${widget.fieldKeyName}-reveal'),
          icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility),
          tooltip: _obscured ? 'Show' : 'Hide',
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
      obscureText: _obscured,
      autocorrect: false,
      enableSuggestions: false,
      onSubmitted: widget.onSubmitted,
    );
  }
}
