import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../l10n/generated/app_localizations.dart';
import '../lock/privacy_signals.dart';
import '../session/note_session.dart';
import '../vault/vault_types.dart';

/// Write and Preview for one note, saving every real edit through [NoteSession].
///
/// Preview renders with a parser only: the `img` builder replaces every image
/// with an offline notice before any image provider could run, and the `a`
/// builder returns plain selectable text instead of a tappable recognizer. The
/// screen owns no key and no second copy of the note beyond its controllers.
class NoteEditor extends StatefulWidget {
  const NoteEditor({super.key, required this.session, required this.note});

  final NoteSession session;
  final Note note;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late TextEditingController _title;
  late TextEditingController _markdown;
  bool _preview = false;
  bool _saved = false;
  String? _error;
  int _saveGeneration = 0;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.note.title);
    _markdown = TextEditingController(text: widget.note.markdown);
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(NoteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
    // An echo of our own save must not move the cursor; only a different note
    // replaces the draft.
    if (oldWidget.note.id != widget.note.id) {
      _title.dispose();
      _markdown.dispose();
      _title = TextEditingController(text: widget.note.title);
      _markdown = TextEditingController(text: widget.note.markdown);
      _saved = false;
      _error = null;
      _saveGeneration++;
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _title.dispose();
    _markdown.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    if (widget.session.phase != SessionPhase.unlocked) {
      // The session already holds every accepted keystroke, so a lock or a
      // save failure may drop the controllers' copy at once.
      _title.clear();
      _markdown.clear();
      setState(() {
        _saved = false;
        _error = null;
      });
    }
  }

  Note _draft() => Note(
    id: widget.note.id,
    title: _title.text,
    markdown: _markdown.text,
    createdAt: widget.note.createdAt,
    updatedAt: DateTime.now().toUtc(),
  );

  void _saveDraft() {
    final generation = ++_saveGeneration;
    setState(() {
      _saved = false;
      _error = null;
    });
    final l10n = AppLocalizations.of(context)!;
    unawaited(
      widget.session
          .saveNote(_draft())
          .then((_) {
            if (!mounted || generation != _saveGeneration) return;
            if (widget.session.phase != SessionPhase.unlocked) return;
            setState(() => _saved = true);
          })
          .catchError((Object error) {
            if (!mounted || generation != _saveGeneration) return;
            if (widget.session.phase != SessionPhase.unlocked) return;
            final rejected =
                error is VaultException && error.code == FailureCode.limit;
            if (rejected) _restoreAccepted();
            setState(() {
              _saved = false;
              _error = rejected ? l10n.noteTooLarge : l10n.noteSaveFailed;
            });
          }),
    );
  }

  /// Puts the last accepted title and source back after a rejected draft.
  ///
  /// The session never accepted the draft, so the stored note is the only copy
  /// that survives; keeping the rejected text would silently disagree with what
  /// is actually saved. Assigning `value` does not fire `onChanged`, so this
  /// produces neither a save nor an activity signal.
  void _restoreAccepted() {
    var accepted = widget.note;
    for (final note in widget.session.data?.notes ?? const <Note>[]) {
      if (note.id == widget.note.id) {
        accepted = note;
        break;
      }
    }
    _setText(_title, accepted.title);
    _setText(_markdown, accepted.markdown);
  }

  void _setText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _onTitleChanged(String _) {
    PrivacySignals.reportActivity(context);
    _saveDraft();
  }

  void _onMarkdownChanged(String _) {
    PrivacySignals.reportActivity(context);
    _saveDraft();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: false, label: Text(l10n.writeTab)),
                  ButtonSegment(value: true, label: Text(l10n.previewTab)),
                ],
                selected: {_preview},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(Size(64, 48)),
                ),
                onSelectionChanged: (selection) {
                  setState(() => _preview = selection.single);
                },
              ),
              if (_saved)
                Text(
                  l10n.savedLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('titleInput'),
            controller: _title,
            textInputAction: TextInputAction.next,
            onChanged: _onTitleChanged,
            decoration: InputDecoration(
              labelText: l10n.noteTitleLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: _preview
                ? _previewBody(context, l10n)
                : _sourceBody(context),
          ),
        ],
      ),
    );
  }

  Widget _sourceBody(BuildContext context) => TextField(
    key: const ValueKey('markdownInput'),
    controller: _markdown,
    expands: true,
    minLines: null,
    maxLines: null,
    textAlignVertical: TextAlignVertical.top,
    keyboardType: TextInputType.multiline,
    style: const TextStyle(fontFamily: 'monospace'),
    onChanged: _onMarkdownChanged,
    decoration: const InputDecoration(
      border: OutlineInputBorder(),
      alignLabelWithHint: true,
    ),
  );

  Widget _previewBody(BuildContext context, AppLocalizations l10n) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: SingleChildScrollView(
        key: const ValueKey('previewScroll'),
        padding: const EdgeInsets.all(16),
        child: MarkdownBody(
          data: _markdown.text,
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(theme),
          builders: {
            'img': _OfflineImageBuilder(l10n.imageUnavailableOffline),
            'a': _PlainLinkBuilder(),
          },
        ),
      ),
    );
  }
}

/// Every image reference becomes the same offline notice; no provider runs.
class _OfflineImageBuilder extends MarkdownElementBuilder {
  _OfflineImageBuilder(this.message);

  final String message;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text(message, style: Theme.of(context).textTheme.bodySmall);
}

/// A link is its text, selectable, with no recognizer that could launch it.
class _PlainLinkBuilder extends MarkdownElementBuilder {
  _PlainLinkBuilder();

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) =>
      SelectableText(element.textContent, style: preferredStyle ?? parentStyle);
}
