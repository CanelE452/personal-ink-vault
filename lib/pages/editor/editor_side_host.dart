import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/ink_ui/side_panel/audio_tab.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_pages.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/ink_ui/side_panel/outline_tab.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_undo_notice.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/pdf_outline.dart';
import 'package:saber/data/user_error.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/pages/editor/editor_add_page_host.dart';
import 'package:saber/pages/editor/editor_audio_host.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/editor/editor_quick_note_host.dart';

// the editor lays the host's notice and listening bar over its page area
export 'package:saber/components/kit/kit_undo_notice.dart' show KitUndoNotice;
export 'package:saber/pages/editor/editor_audio_host.dart'
    show EditorAudioHost, EditorListenBarLayer, EditorRecordPillLayer;
export 'package:saber/pages/editor/editor_quick_note_host.dart'
    show EditorQuickNoteHost, EditorQuickNoteLayer;

/// What the editor keeps beside its note, apart from the editor's own state
/// so that none of it builds the page again: the left panel (open, its tab),
/// the favourites and the user's outline in the note's page marks
/// attachment, with its changes to the PDF's outline, the note's recordings
/// and the listening bar ([audio], which records the note too), and the
/// undo notice, the quick note ([quickNote], whose window is
/// [quickNoteOpen]) and the 노트 추가 window ([addPage]).
///
/// The outline tab shows the PDF's outline, read again when the note's PDF
/// pages change and with the note's changes applied here (a hidden line
/// takes the lines under it with it), and the user's own lines by page,
/// then as they were made. A line whose page the note no longer has is left
/// out. Without page marks (no vault, or a format 1 one) the PDF's outline
/// is shown as it is. A name being changed when the panel closes is kept.
///
/// Favourites load once from every page marks attachment of the note,
/// merged ([NotePageMarks.merge]: two devices may each have written the
/// note's first one offline). A change goes into memory at once and is then
/// written, in order, into the attachment with the smallest entity id over
/// all its heads, merged with what the vault holds then; the others stay as
/// they are (a deletion mark would win over another device's offline
/// favourites) and are merged again on every read. An attachment with a head
/// that cannot be read is passed over (a write guarded by the heads it read
/// would miss that one every time); when none is left a new one is written,
/// and read with the rest from then on. When another head arrives
/// in between, the write is read, merged and tried once more; if that fails
/// too, [onError] hears it and the change stays in memory for the next write.
/// Outline changes go the same way, in the same order.
/// The first write saves the note first, so the page ids it names are the
/// saved ones (a page never saved gets a new id each time it is read).
class EditorSideHost extends ChangeNotifier {
  new({
    required this.binding,
    required this.saveNote,
    required this.pages,
    required this.pageOnScreen,
    required this.pageMoves,
    required this.onChanged,
    required this.onError,
    this.readOutline = readPdfOutline,
    this.quickNoteOpen,
    this.noteWritable,
  }) {
    panelOpen.addListener(onChanged);
    panelOpen.addListener(_panelChanged);
    panelOpen.addListener(_audioShown);
    tab.addListener(_audioShown);
    pageMoves.addListener(_pageMoved);
    // the record button's name follows it
    audio.recording.addListener(onChanged);
    // 노트 창 is lit while the window is open
    quickNote.open.addListener(onChanged);
  }

  /// Where the note's attachments are (the host's `noteSide`); read once,
  /// by [load].
  final NoteSideBinding? Function() binding;

  /// Saves the note: also when it has no change waiting with `force`.
  final Future<void> Function(bool force) saveNote;
  final List<EditorPage> Function() pages;
  final int Function() pageOnScreen;

  /// Tells when the page on screen may have changed (the zoom and scroll).
  final Listenable pageMoves;

  /// What the editor's actions show changed (the panel, the favourite of
  /// the page on screen).
  final VoidCallback onChanged;

  /// A favourite or an outline change could not be saved.
  final void Function(Object error) onError;

  /// Reads a note's PDF outline ([readPdfOutline]).
  final Future<List<PdfOutlineRow>> Function(
    EditorCoreInfo note,
    List<OutlineRename> edits,
  )
  readOutline;

  /// The editor's 노트 창 (the host's own when null).
  final ValueNotifier<bool>? quickNoteOpen;

  /// Whether the note may be changed, once it is read: [load] joins split
  /// attachments only then. Null: it may.
  final Future<bool> Function()? noteWritable;

  final panelOpen = ValueNotifier(false);
  final tab = ValueNotifier(KitSideTab.pages);

  /// The page on screen, while the panel may show it.
  final shownPage = ValueNotifier(0);

  /// The outline line whose name is being changed.
  final renaming = ValueNotifier<String?>(null);

  /// The undo notice over the page area.
  final notice = KitUndoNoticeController();

  /// The note's recordings (the audio tab) and the listening bar.
  late final audio = EditorAudioHost(
    notice: notice,
    onError: onError,
    showTab: () {
      tab.value = KitSideTab.audio;
      if (!panelOpen.value) togglePanel();
    },
  );

  /// The note's quick note window.
  late final quickNote = EditorQuickNoteHost(open: quickNoteOpen);

  /// The toolbar's 노트 추가 window (its button lit while it is open).
  late final addPage = EditorAddPageHost(onChanged: onChanged);

  /// Counts the changes the editor saves (not a stroke begun): the page
  /// pictures in the panel are drawn again when it moves on.
  var pictureEdits = 0;

  EditorCoreInfo? _outlineNote;

  /// The note's PDF pages the outline was last read for.
  var _outlineSources = const <PdfEditorImage>[];
  var _outlineReads = 0;
  var _pdfOutline = const <PdfOutlineRow>[];

  /// The PDF's outline is being read.
  var _reading = false;

  /// The rows [outlineOf] made last, with what they were made from: the
  /// note, its outline, the page on screen, and its pages' ids. Any change
  /// of the marks ([_changed]) drops them.
  ({List<KitOutlineRow> pdf, List<KitOutlineRow> mine})? _rows;
  (EditorCoreInfo, List<PdfOutlineRow>, int)? _rowsFrom;
  var _rowsPages = const <String>[];

  /// What has been typed into the name of the line [renaming] names.
  ({String id, String title})? _draft;

  NoteSideBinding? _binding;
  var _marks = NotePageMarks();
  var _noteSaved = false;
  Future<void> _writes = Future.value();
  bool? _shownFavorite;
  var _disposed = false;

  /// The note's vault can hold page marks (format 2): favourites and the
  /// user's outline.
  bool get favoritesAvailable => _binding != null;

  List<String> get favorites => _marks.favorites;

  /// The note may be recorded: on Android, where it keeps recordings
  /// (format 2, as its favourites).
  bool get canRecord => favoritesAvailable && EditorAudioHost.recordsHere;

  bool isFavorite(String? pageId) => favorites.contains(pageId);

  /// Reads the favourites and the recordings. Without a vault, or in a
  /// format 1 vault, there are none and [favoritesAvailable] stays false.
  /// Then, unless the note is read-only ([noteWritable]), the attachments
  /// two devices split offline are joined once (the page marks, the
  /// recordings, the quick note), so apps that do not join them (232,
  /// Windows 226) see no conflict either.
  Future<void> load() async {
    final binding = this.binding();
    if (binding == null || !binding.store.available) return;
    _binding = binding;
    quickNote.bind(binding);
    _changed();
    var split = false;
    try {
      final (records, stored) = await _read(binding);
      split = records.any((record) => record.heads.length > 1);
      _marks = NotePageMarks.merge([...stored, _marks]);
      _changed();
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
    }
    await audio.load(binding);
    if (!await (noteWritable?.call() ?? Future.value(true)) || _disposed) {
      return;
    }
    if (split) await (_writes = _writes.then((_) => _join(binding)));
    await audio.joinSplits();
    await quickNote.joinSplits();
  }

  /// Writes each page marks attachment split into two or more heads over
  /// them, with the marks of all the attachments merged. The note is not
  /// saved first: the marks name only pages the stored marks name. A
  /// failure is only logged (the user changed nothing).
  Future<void> _join(NoteSideBinding binding) async {
    try {
      final (records, stored) = await _read(binding);
      final merged = NotePageMarks.merge(stored).encode();
      for (final record in records) {
        if (record.heads.length < 2) continue;
        try {
          await binding.store.write(binding.noteId, NoteSideKind.pageMarks, {
            NoteSideKind.pageMarks.markerFile: merged,
          }, base: record);
        } on StateError catch (error, stackTrace) {
          logUserError(error, stackTrace);
        }
      }
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
    }
  }

  /// Makes [pageId] a favourite or not; done when it is written (or failed).
  Future<void> setFavorite(String pageId, bool on) {
    if (_binding == null) return Future.value();
    on ? _marks.addFavorite(pageId) : _marks.removeFavorite(pageId);
    _changed();
    return _write('즐겨찾기를 저장하지 못했습니다. 다음에 바꿀 때 다시 저장합니다.');
  }

  Future<void> toggleFavorite(String pageId) =>
      setFavorite(pageId, !isFavorite(pageId));

  void togglePanel() {
    panelOpen.value = !panelOpen.value;
    _pageMoved();
  }

  /// [note] has a page drawn from a PDF.
  bool hasPdf(EditorCoreInfo note) =>
      note.pages.any((page) => page.backgroundImage is PdfEditorImage);

  /// The PDF's outline of the note last shown is being read.
  bool get outlineLoading => _reading;

  /// The outline tab's lines of [note]: the PDF's and the user's own. In each,
  /// the line of the page on screen is lit: of the lines at or before it,
  /// the last one on the nearest page. Asked again with nothing changed, it
  /// hands back the same lists.
  ({List<KitOutlineRow> pdf, List<KitOutlineRow> mine}) outlineOf(
    EditorCoreInfo note,
  ) {
    final sources = [
      for (final page in note.pages)
        if (page.backgroundImage case final PdfEditorImage image) image,
    ];
    if (!identical(note, _outlineNote) || !_same(sources, _outlineSources)) {
      // a PDF brought into the open note adds pages to the same note
      if (!identical(note, _outlineNote) || sources.isEmpty) {
        _pdfOutline = const [];
      }
      _outlineNote = note;
      _outlineSources = sources;
      final read = ++_outlineReads;
      _reading = sources.isNotEmpty;
      if (_reading) unawaited(_readPdfOutline(note, read));
    }
    final from = (note, _pdfOutline, shownPage.value);
    if (_rows case final rows?
        when from == _rowsFrom && _samePages(note.pages)) {
      return rows;
    }
    final at = {for (final (i, page) in note.pages.indexed) page.pageId: i};
    final edits = {
      for (final edit in _marks.pdfOutlineEdits)
        (edit.pageId, edit.depth, edit.originalTitle): edit,
    };
    final pdf = <(String, String, int, int)>[];
    int? hiddenBelow;
    for (final (i, line) in _pdfOutline.indexed) {
      if (hiddenBelow != null && line.depth > hiddenBelow) continue;
      hiddenBelow = null;
      final edit = edits[(line.pageId, line.depth, line.title)];
      if (edit != null && edit.hidden) {
        hiddenBelow = line.depth;
        continue;
      }
      final page = at[line.pageId];
      if (page == null) continue;
      pdf.add(('$_pdfRow$i', edit?.title ?? line.title, page, line.depth));
    }
    final mine =
        [
          for (final entry in _marks.liveOutline)
            if (at[entry.pageId] case final page?) (entry, page),
        ]..sort(
          (a, b) => a.$2 != b.$2
              ? a.$2 - b.$2
              : a.$1.createdAt != b.$1.createdAt
              ? a.$1.createdAt.compareTo(b.$1.createdAt)
              : a.$1.id.compareTo(b.$1.id),
        );
    _rowsFrom = from;
    _rowsPages = [for (final page in note.pages) page.pageId];
    return _rows = (
      pdf: _lit(pdf),
      mine: _lit([
        for (final (entry, page) in mine)
          ('$_userRow${entry.id}', entry.title, page, 0),
      ]),
    );
  }

  static bool _same(List<Object> a, List<Object> b) =>
      a.length == b.length &&
      a.indexed.every((item) => identical(item.$2, b[item.$1]));

  bool _samePages(List<EditorPage> pages) =>
      pages.length == _rowsPages.length &&
      pages.indexed.every((page) => page.$2.pageId == _rowsPages[page.$1]);

  /// [lines] (id, title, page, depth) as rows, the page on screen's lit.
  List<KitOutlineRow> _lit(List<(String, String, int, int)> lines) {
    final shown = shownPage.value;
    int? current;
    for (final (i, line) in lines.indexed) {
      if (line.$3 <= shown &&
          (current == null || line.$3 >= lines[current].$3)) {
        current = i;
      }
    }
    return [
      for (final (i, (id, title, page, depth)) in lines.indexed)
        KitOutlineRow(
          id: id,
          title: title,
          page: page,
          depth: depth,
          current: i == current,
        ),
    ];
  }

  Future<void> _readPdfOutline(EditorCoreInfo note, int read) async {
    // the edits are applied by [outlineOf]: a hidden line is kept to know
    // the lines under it
    final lines = await readOutline(note, const []);
    if (read != _outlineReads) return;
    _pdfOutline = lines;
    _reading = false;
    _changed();
  }

  /// [title] has been typed into the name of the line [id].
  void renameDraft(String id, String title) => _draft = (id: id, title: title);

  /// The panel closed: the recordings hear it ([EditorAudioHost.panelClosed]),
  /// and an outline name being changed keeps what was typed, as a press
  /// outside the field keeps it.
  void _panelChanged() {
    if (panelOpen.value) return;
    audio.panelClosed();
    keepRenameDraft(renaming, _draft, renameOutline);
  }

  /// 「개요에 추가」: a line for the page counted [pageIndex] from 0, named
  /// 「쪽 N」, shown in the outline tab with its name open to change.
  Future<void> addOutline(int pageIndex) {
    final page = pages().elementAtOrNull(pageIndex);
    if (_binding == null || page == null) return Future.value();
    final entry = _marks.addOutline(page.pageId, '쪽 ${pageIndex + 1}');
    renaming.value = '$_userRow${entry.id}';
    tab.value = KitSideTab.outline;
    if (!panelOpen.value) togglePanel();
    _changed();
    return _write(_outlineFailed);
  }

  /// Ends the change of [id]'s name: it is [title] unless that is empty or
  /// the same. A PDF line named as the PDF names it again is not renamed.
  Future<void> renameOutline(String id, String title) {
    if (renaming.value == id) renaming.value = null;
    _draft = null;
    final name = title.trim();
    if (_binding == null || name.isEmpty) return Future.value();
    if (_entry(id) case final entry?) {
      if (entry.title == name) return Future.value();
      _marks.renameOutline(entry.id, name);
    } else if (_pdfLine(id) case final line?) {
      final edit = _pdfEdit(line);
      final renamed = name == line.title ? null : name;
      if (renamed == edit?.title) return Future.value();
      _marks.editPdfOutline(
        OutlineRename(
          pageId: line.pageId,
          depth: line.depth,
          originalTitle: line.title,
          title: renamed,
          hidden: edit?.hidden ?? false,
          updatedAt: DateTime.now(),
        ),
      );
    } else {
      return Future.value();
    }
    _changed();
    return _write(_outlineFailed);
  }

  /// 「지우기」: the line goes (a PDF line is hidden, with the lines under
  /// it), and the undo notice can bring it back.
  Future<void> removeOutline(String id) {
    if (_binding == null) return Future.value();
    final String title;
    final VoidCallback undo;
    if (_entry(id) case final entry?) {
      title = entry.title;
      _marks.removeOutline(entry.id);
      undo = () => _marks.restoreOutline(entry.id);
    } else if (_pdfLine(id) case final line?) {
      final edit = _pdfEdit(line);
      title = edit?.title ?? line.title;
      void hide(bool hidden) => _marks.editPdfOutline(
        OutlineRename(
          pageId: line.pageId,
          depth: line.depth,
          originalTitle: line.title,
          title: edit?.title,
          hidden: hidden,
          updatedAt: DateTime.now(),
        ),
      );
      hide(true);
      undo = () => hide(false);
    } else {
      return Future.value();
    }
    _changed();
    notice.show(
      KitTokens.removedNotice(title),
      onAction: () {
        if (_disposed) return;
        undo();
        _changed();
        unawaited(_write(_outlineFailed));
      },
    );
    return _write(_outlineFailed);
  }

  static const _userRow = 'me:';
  static const _pdfRow = 'pdf:';
  static const _outlineFailed = '개요를 저장하지 못했습니다. 다음에 바꿀 때 다시 저장합니다.';

  OutlineEntry? _entry(String id) => id.startsWith(_userRow)
      ? _marks.outline
            .where((row) => row.id == id.substring(_userRow.length))
            .firstOrNull
      : null;

  PdfOutlineRow? _pdfLine(String id) => id.startsWith(_pdfRow)
      ? _pdfOutline.elementAtOrNull(
          int.tryParse(id.substring(_pdfRow.length)) ?? -1,
        )
      : null;

  OutlineRename? _pdfEdit(PdfOutlineRow line) => _marks.pdfOutlineEdits
      .where(
        (edit) =>
            edit.pageId == line.pageId &&
            edit.depth == line.depth &&
            edit.originalTitle == line.title,
      )
      .firstOrNull;

  /// The audio tab came into sight: its recordings are read again (another
  /// device may have added to them).
  void _audioShown() {
    if (panelOpen.value && tab.value == KitSideTab.audio) {
      unawaited(audio.reload());
    }
  }

  /// Done when every write started so far is (written or failed), the
  /// recordings' too.
  @visibleForTesting
  Future<void> get idle async {
    for (var writes = _writes; ; writes = _writes) {
      await writes;
      await audio.idle;
      if (identical(writes, _writes)) return;
    }
  }

  /// Writes the marks after the writes before; [failed] is said if it fails.
  Future<void> _write(String failed) =>
      _writes = _writes.then((_) => _save(failed));

  Future<void> _save(String failed) async {
    final binding = _binding!;
    Object? failure;
    try {
      await saveNote(!_noteSaved);
      _noteSaved = true;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          var (records, stored) = await _read(binding);
          var (base, passed) = await _writable(binding, records);
          if (passed) {
            // a head may have arrived between the list and the check: read
            // once more, so only an attachment that still has a head the
            // list leaves out is passed over
            (records, stored) = await _read(binding);
            (base, _) = await _writable(binding, records);
          }
          final merged = NotePageMarks.merge([...stored, _marks]);
          await binding.store.write(binding.noteId, NoteSideKind.pageMarks, {
            NoteSideKind.pageMarks.markerFile: merged.encode(),
          }, base: base);
          // what changed while it was written stays (it is later)
          _marks = NotePageMarks.merge([merged, _marks]);
          _changed();
          return;
        } on StateError catch (error) {
          failure = error;
        }
      }
    } catch (error) {
      failure = error;
    }
    logUserError(failure!);
    onError(StateError(failed));
  }

  /// The note's page marks attachments and the marks of all their heads.
  Future<(List<NoteSideRecord>, List<NotePageMarks>)> _read(
    NoteSideBinding binding,
  ) async {
    final records = await binding.store.list(
      binding.noteId,
      NoteSideKind.pageMarks,
    );
    final stored = [
      for (final record in records)
        for (final head in record.heads)
          NotePageMarks.decode(
            (await binding.store.repository.readFiles(
              head,
            ))[NoteSideKind.pageMarks.markerFile]!,
          ),
    ];
    return (records, stored);
  }

  /// The first of [records] (list() orders them by entity id) with no head
  /// in the vault that it did not list ([NoteSideStore.hasUnlistedHead]:
  /// list() leaves out a head it cannot read), and whether one before it
  /// was passed over. A head that arrives between the list and this check
  /// also passes it over.
  Future<(NoteSideRecord?, bool)> _writable(
    NoteSideBinding binding,
    List<NoteSideRecord> records,
  ) async {
    for (final (i, record) in records.indexed) {
      if (!await binding.store.hasUnlistedHead(record)) return (record, i > 0);
    }
    return (null, records.isNotEmpty);
  }

  void _pageMoved() {
    if (_binding == null && !panelOpen.value) return;
    final index = pageOnScreen();
    shownPage.value = index;
    final favorite = isFavorite(pages().elementAtOrNull(index)?.pageId);
    if (favorite != _shownFavorite) {
      _shownFavorite = favorite;
      onChanged();
    }
  }

  /// A write may end after the editor is gone: it no longer hears it.
  void _changed() {
    if (_disposed) return;
    _rows = null;
    notifyListeners();
    onChanged();
  }

  @override
  void dispose() {
    _disposed = true;
    // the note closes: an outline name being changed keeps what was typed,
    // as when the panel closes (written after, unheard)
    keepRenameDraft(renaming, _draft, renameOutline);
    pageMoves.removeListener(_pageMoved);
    quickNote.open.removeListener(onChanged);
    panelOpen.dispose();
    tab.dispose();
    shownPage.dispose();
    renaming.dispose();
    audio.dispose();
    quickNote.dispose();
    addPage.dispose();
    notice.dispose();
    super.dispose();
  }
}

/// The left panel over the editor's page area, following [host] on its own
/// (opening it does not build the editor again): the pages of [coreInfo],
/// drawn small, [goTo] scrolling to one and [managePage] (a long press)
/// opening the page manager on one, the outline, its lines going to their
/// pages, and the recordings. On a phone it covers the page area and a page
/// or line press closes it. Without favourites (no vault, or a format 1 one) there are no
/// recordings either: those tabs are left out, and so is the outline of a
/// note that is not a PDF.
class EditorSidePanelLayer extends StatefulWidget {
  const new({
    super.key,
    required this.host,
    required this.coreInfo,
    required this.goTo,
    required this.managePage,
  });

  final EditorSideHost host;
  final EditorCoreInfo coreInfo;
  final void Function(int index) goTo;
  final void Function(int index) managePage;

  @override
  State<EditorSidePanelLayer> createState() => _EditorSidePanelLayerState();
}

class _EditorSidePanelLayerState extends State<EditorSidePanelLayer> {
  /// Each page's picture with what it was drawn from: the editor builds
  /// this layer again on every frame of a stroke, and a picture is handed
  /// back as it was (not built again) while the note, the page, the page
  /// count (each page shows it) and the saved changes
  /// ([EditorSideHost.pictureEdits]) stay the same.
  final _pictures = <int, (Object, Widget)>{};

  EditorSideHost get host => widget.host;
  EditorCoreInfo get coreInfo => widget.coreInfo;

  Widget _picture(int i) {
    final page = coreInfo.pages[i];
    final from = (coreInfo, page, coreInfo.pages.length, host.pictureEdits);
    final kept = _pictures[i];
    if (kept != null && kept.$1 == from) return kept.$2;
    final picture = FittedBox(
      child: CanvasPreview(pageIndex: i, height: null, coreInfo: coreInfo),
    );
    _pictures[i] = (from, picture);
    return picture;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final phone = box.maxWidth < KitTokens.sidePanelPhoneBelow;
      return ListenableBuilder(
        listenable: Listenable.merge([
          host,
          host.panelOpen,
          host.tab,
          host.shownPage,
          host.renaming,
          host.audio,
          host.audio.renaming,
        ]),
        builder: (context, _) {
          final tabs = [
            KitSideTab.pages,
            if (host.favoritesAvailable) KitSideTab.favorites,
            if (host.favoritesAvailable || host.hasPdf(coreInfo))
              KitSideTab.outline,
            if (host.favoritesAvailable) KitSideTab.audio,
          ];
          final tab = tabs.contains(host.tab.value)
              ? host.tab.value
              : KitSideTab.pages;
          return KitSidePanel(
            open: host.panelOpen.value,
            phone: phone,
            tabs: tabs,
            tab: tab,
            onTab: (t) => host.tab.value = t,
            body: _body(tab, phone),
          );
        },
      );
    },
  );

  /// Goes to the page counted [index] from 0; a phone's panel closes.
  void _go(int index, bool phone) {
    widget.goTo(index);
    host.shownPage.value = index;
    if (phone) host.panelOpen.value = false;
  }

  /// The pages tab, the favourites tab, the outline tab or the audio tab.
  Widget _body(KitSideTab tab, bool phone) {
    if (tab == KitSideTab.audio) {
      final audio = host.audio;
      return KitSideAudio(
        rows: audio.rows,
        play: audio.player.supported,
        editable: !coreInfo.readOnly,
        loading: audio.loading,
        renaming: audio.renaming.value,
        footRoom: audio.footRoom.value,
        onPlay: (row) => audio.listen(row.id),
        onRenameStart: (row) => audio.renaming.value = row.id,
        onRenameEdit: (row, title) => audio.renameDraft(row.id, title),
        onRename: (row, title) => unawaited(audio.rename(row.id, title)),
        onRemove: (row) => audio.remove(row.id),
      );
    }
    if (tab == KitSideTab.outline) {
      final outline = host.outlineOf(coreInfo);
      return KitSideOutline(
        pdf: outline.pdf,
        mine: outline.mine,
        editable: host.favoritesAvailable && !coreInfo.readOnly,
        loading: host.outlineLoading,
        renaming: host.renaming.value,
        onGo: (row) => _go(row.page, phone),
        onRenameStart: (row) => host.renaming.value = row.id,
        onRenameEdit: (row, title) => host.renameDraft(row.id, title),
        onRename: (row, title) => unawaited(host.renameOutline(row.id, title)),
        onRemove: (row) => unawaited(host.removeOutline(row.id)),
      );
    }
    _pictures.removeWhere((i, _) => i >= coreInfo.pages.length);
    final favorites = host.favorites.toSet();
    final shown = host.shownPage.value;
    final items = [
      for (final (i, page) in coreInfo.pages.indexed)
        if (tab == KitSideTab.pages || favorites.contains(page.pageId))
          KitSidePage(
            index: i,
            aspectRatio: page.size.width / page.size.height,
            favorite: favorites.contains(page.pageId),
            current: i == shown,
          ),
    ];
    if (items.isEmpty) return KitSideEmpty(tab);
    return KitSidePages(
      pages: items,
      columns: phone
          ? KitTokens.sideGridPhoneColumns
          : KitTokens.sideGridColumns,
      thumbnail: _picture,
      onPage: (i) => _go(i, phone),
      onManage: widget.managePage,
    );
  }
}
