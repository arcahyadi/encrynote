import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../session/note_session.dart';
import '../settings/settings_screen.dart';
import '../vault/vault_types.dart';
import 'note_editor.dart';

/// The unlocked notes surface: list, CRUD and the Write/Preview editor.
///
/// Wide windows keep the list beside the editor; narrow ones swap between them
/// inside this widget, so a lock replaces the whole surface instead of leaving
/// a pushed editor or dialog with captured text above the auth screen. Every
/// mutation is checked against [NoteSession.canMutate] at the moment it is
/// confirmed, and no note content is copied outside the session.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.session});

  static const double sideBySideBreakpoint = 720;

  final NoteSession session;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  String? _selectedId;

  NoteSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(NotesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
      _selectedId = null;
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// Once the session stops being unlocked, this surface is replaced by the
  /// auth screen. Clearing the selection here drops the editor's captured title
  /// and source; the delete dialog gates and closes itself.
  void _onSessionChanged() {
    if (!mounted || _session.phase == SessionPhase.unlocked) return;
    setState(() => _selectedId = null);
  }

  Note? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    final notes = _session.data?.notes ?? const <Note>[];
    for (final note in notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  List<Note> get _orderedNotes {
    final notes = [...?_session.data?.notes];
    notes.sort((a, b) {
      final byUpdate = b.updatedAt.compareTo(a.updatedAt);
      return byUpdate != 0 ? byUpdate : a.id.compareTo(b.id);
    });
    return notes;
  }

  void _select(String id) {
    if (_selectedId != null && _selectedId != id) _flushEditor();
    setState(() => _selectedId = id);
  }

  /// Switching or leaving a note writes the last accepted keystroke now
  /// instead of leaving it to the session debounce.
  void _flushEditor() {
    unawaited(_session.flushSave().catchError((Object _) {}));
  }

  void _closeEditor() {
    _flushEditor();
    setState(() => _selectedId = null);
  }

  Future<void> _createNote() async {
    if (!_session.canMutate) return;
    _flushEditor();
    final now = DateTime.now().toUtc();
    final note = Note(
      id: _session.newNoteId(),
      title: '',
      markdown: '',
      createdAt: now,
      updatedAt: now,
    );
    setState(() => _selectedId = note.id);
    // Accepted into session state synchronously; the debounce owns the write.
    unawaited(_session.saveNote(note).catchError((Object _) {}));
  }

  Future<void> _delete(Note note) async {
    if (!_session.canMutate) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _DeleteDialog(session: _session, title: note.title),
    );
    if (!mounted) return;
    if (confirmed != true || !_session.canMutate) return;
    final id = note.id;
    if (_selectedId == id) setState(() => _selectedId = null);
    try {
      await _session.deleteNote(id);
    } on VaultException {
      // The session has already frozen and published the failure.
    }
  }

  Future<void> _lock() async {
    // A lock flushes the last accepted edit before the key is dropped.
    await _session.lock();
  }

  Future<void> _openSettings() async {
    _flushEditor();
    await Navigator.of(context).pushNamed(SettingsScreen.routeName);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final wide =
        MediaQuery.sizeOf(context).width >= NotesScreen.sideBySideBreakpoint;
    final selected = _selected;
    return Scaffold(
      key: const ValueKey('notesScreen'),
      appBar: AppBar(
        leading: !wide && selected != null
            ? IconButton(
                key: const ValueKey('editorBackButton'),
                icon: const Icon(Icons.arrow_back),
                tooltip: l10n.backToNotesTooltip,
                onPressed: _closeEditor,
              )
            : null,
        title: Text(l10n.notesTitle),
        actions: [
          if (selected != null)
            IconButton(
              key: const ValueKey('deleteNoteButton'),
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.deleteNoteButton,
              onPressed: _session.canMutate ? () => _delete(selected) : null,
            ),
          IconButton(
            key: const ValueKey('lockNowButton'),
            icon: const Icon(Icons.lock_outline),
            tooltip: l10n.lockNowButton,
            onPressed: _lock,
          ),
          IconButton(
            key: const ValueKey('settingsButton'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.settingsButton,
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: wide || selected == null
          ? FloatingActionButton.extended(
              key: const ValueKey('newNoteButton'),
              onPressed: _session.canMutate ? _createNote : null,
              icon: const Icon(Icons.note_add_outlined),
              label: Text(l10n.newNoteButton),
            )
          : null,
      body: PopScope(
        canPop: wide || selected == null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && selected != null) {
            _closeEditor();
          }
        },
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 320,
                    child: _list(context, l10n, selectedId: _selectedId),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: _detail(context, l10n, selected)),
                ],
              )
            : selected == null
            ? _list(context, l10n, selectedId: null)
            : _detail(context, l10n, selected),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n, {
    required String? selectedId,
  }) {
    final notes = _orderedNotes;
    if (notes.isEmpty) {
      return _EmptyNotes(l10n: l10n);
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 96),
      itemCount: notes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final note = notes[index];
        return ListTile(
          key: ValueKey('noteTile:${note.id}'),
          selected: note.id == selectedId,
          minVerticalPadding: 12,
          title: Text(
            note.title.isEmpty ? l10n.untitledNote : note.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _summary(note.markdown),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _select(note.id),
        );
      },
    );
  }

  Widget _detail(BuildContext context, AppLocalizations l10n, Note? note) {
    if (note == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.selectNoteHint,
            key: const ValueKey('selectNoteHint'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return NoteEditor(session: _session, note: note);
  }

  String _summary(String markdown) {
    final line = markdown
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return line;
  }
}

class _EmptyNotes extends StatelessWidget {
  const _EmptyNotes({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n.noNotesTitle,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l10n.noNotesBody,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );
}

/// Confirms one delete. Its content is gated on the session: as soon as the
/// vault is no longer unlocked the title disappears and the route closes, so a
/// captured note title cannot be painted over the unlock form.
class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.session, required this.title});

  final NoteSession session;
  final String title;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_closeIfLocked);
  }

  @override
  void dispose() {
    widget.session.removeListener(_closeIfLocked);
    super.dispose();
  }

  void _closeIfLocked() {
    if (_closing || !mounted || widget.session.phase == SessionPhase.unlocked) {
      return;
    }
    _closing = true;
    // Replace the content in this frame, then leave the route on the next one;
    // popping inside the notification would re-enter Navigator.
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (widget.session.phase != SessionPhase.unlocked) {
      return const SizedBox.shrink();
    }
    return AlertDialog(
      title: Text(l10n.deleteNoteTitle),
      content: Text(
        widget.title.isEmpty
            ? l10n.deleteNoteBodyUntitled
            : l10n.deleteNoteBody(widget.title),
      ),
      actions: [
        TextButton(
          key: const ValueKey('cancelDeleteButton'),
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(64, 48)),
          ),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancelButton),
        ),
        FilledButton(
          key: const ValueKey('confirmDeleteButton'),
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(64, 48)),
          ),
          onPressed: () {
            // Checked at confirmation time, not when the dialog opened.
            if (!widget.session.canMutate) return;
            Navigator.of(context).pop(true);
          },
          child: Text(l10n.deleteNoteButton),
        ),
      ],
    );
  }
}
