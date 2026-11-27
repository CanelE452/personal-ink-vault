import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:bson/bson.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show RevisionRecord;
import 'package:logging/logging.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:sbn/read_only_reason.dart';

/// The quick note of a note: one page of ink in a window over the note, one per note. It is kept in the note's
/// [NoteSideKind.quickNote] attachment: `quick-note.json` (schema 1, the version and size of the page, when it was
/// written) and `quick-note.sbn2`, a one-page note in the editor's own format, so it is version 19 like other notes.
///
/// The stroke being drawn is [currentStroke], never [Pen.currentStroke]: the editor draws that one on its page with
/// the same index, so a quick note stroke there would also show on the note's first page. Undo is [history], apart
/// from the note's.
///
/// It saves [saveDelay] after the last change and on [flush]. A failed save never drops ink: the page stays in memory
/// and [hasUnsavedChanges] stays true until a later save goes through. When another head arrived, the save lists the
/// heads again and joins their strokes. An attachment with a head this device cannot read (the list left it out, or its
/// page does not load) is never written over, since the store's guard cannot match it (see [NoteSideStore.write]) and
/// its ink must not be buried; its readable heads still join, and the ink goes to another attachment. A head from a
/// newer app makes the quick note [readOnly]: it is not written over.
///
/// Joining heads (two devices offline) and attachments (two devices each made the note's first quick note) adds up
/// their strokes, each stroke once: a stroke is known by its saved bytes (points, pen, colour, options), since strokes
/// have no id, and a head that holds the same bytes n times gives n strokes. A stroke rubbed out on this device after
/// it was seen stays out; one rubbed out on another device can come back. The first writable attachment by id keeps
/// the strokes, so every device keeps the same one; the other joined attachments get an empty page, never a deletion
/// mark (the list hides an attachment with a deletion mark on any head, so strokes another device writes there offline
/// would be lost). Clearing also writes an empty page.
class QuickNote {
  new _(this._store, this.noteId, this.core, this.saveDelay);

  static final _log = Logger('QuickNote');
  static const _kind = NoteSideKind.quickNote;
  static const _sbnFile = 'quick-note.sbn2';
  static const _path = '/quick-note';

  final NoteSideStore _store;
  final String noteId;

  /// One page of the default size, no pattern.
  final EditorCoreInfo core;
  final Duration saveDelay;
  final history = EditorHistory();

  final _stroke = _CurrentStroke();

  /// The stroke being drawn; it notifies on every point.
  ValueNotifier<Stroke?> get currentStroke => _stroke;

  EditorPage get page => core.pages.single;

  /// A head was written by a newer app: the quick note shows and keeps it as it is.
  bool get readOnly => _readOnly;
  var _readOnly = false;

  bool get hasUnsavedChanges => _changes != _savedChanges;
  var _changes = 0;
  var _savedChanges = 0;

  /// Tells when [hasUnsavedChanges] or [readOnly] changes: after a change,
  /// and after a save (also one that found a head from a newer app).
  Listenable get saveState => _saveState;
  final _saveState = _Signal();
  var _told = (unsaved: false, readOnly: false);

  /// The attachment the next save writes over (null: a new one).
  NoteSideRecord? _record;

  /// The attachments that may be written over, from the last list.
  var _writable = <NoteSideRecord>[];

  /// Other writable attachments that still hold strokes, to empty once a save goes through.
  var _others = <NoteSideRecord>[];

  /// Attachments whose writes kept failing because a head arrived that this device cannot read.
  final _dead = <String>{};

  /// Attachments whose heads hold strokes, from the last list.
  final _withStrokes = <String>{};

  /// How many of each stroke ([_keyOf]) this quick note has seen saved or read at most.
  final _seen = <String, int>{};

  final _eraser = Eraser();
  Pen? _pen;
  Timer? _timer;
  Future<void> _queue = Future.value();
  var _disposed = false;

  /// Reads every quick note attachment of [noteId] and joins them. Without any, the quick note starts empty and its
  /// first save makes the attachment.
  static Future<QuickNote> open(
    NoteSideStore store,
    String noteId, {
    Duration saveDelay = const Duration(seconds: 2),
  }) async {
    final core = EditorCoreInfo(filePath: _path)
      ..backgroundPattern = .none
      ..pages.add(EditorPage());
    final quick = QuickNote._(store, noteId, core, saveDelay);
    if (!store.available) return quick;
    quick._choose(await quick._absorb(await store.list(noteId, _kind)));
    // Heads to join, or another attachment to empty: the joined page is a change to save.
    if (!quick._readOnly &&
        ((quick._record?.heads.length ?? 0) > 1 || quick._others.isNotEmpty)) {
      quick._changed();
    }
    return quick;
  }

  /// Starts a stroke with [pen] (the screen passes the last pen kind when the lasso, text box or laser is in hand).
  void penDown(
    Offset position,
    Pen pen,
    double? pressure, {
    double screenScale = 1,
  }) {
    if (_readOnly) return;
    _pen = pen;
    _stroke.value = pen.createStroke(page, 0, screenScale: screenScale)
      ..addPoint(position, pressure);
  }

  void penMove(Offset position, double? pressure) {
    final stroke = _stroke.value;
    if (stroke == null) return;
    stroke.addPoint(position, pressure);
    // The highlighter's straight line, as Highlighter.onDragUpdate keeps it for the note.
    if (_pen is Highlighter && stows.highlighterStraightLine.value) {
      stroke.straightenWhileDrawing(axisLock: stows.highlighterAxisLock.value);
    }
    _stroke.changed();
  }

  /// Ends the stroke or the erasing touch, each one undo step.
  void penUp() {
    final stroke = _stroke.value;
    if (stroke != null) {
      _stroke.value = null;
      // Finished as Pen.onDragEnd finishes the note's strokes.
      stroke
        ..stabilise(0)
        ..options.isComplete = true
        ..markPolygonNeedsUpdating();
      page.insertStroke(stroke);
      page.redrawStrokes();
      history.recordChange(
        EditorHistoryItem(
          type: .draw,
          pageIndex: 0,
          strokes: [stroke],
          images: [],
        ),
      );
      _changed();
    }
    final erased = _eraser.onDragEnd();
    if (erased.isNotEmpty) {
      history.recordChange(
        EditorHistoryItem(
          type: .erase,
          pageIndex: 0,
          strokes: erased,
          images: [],
        ),
      );
      _changed();
    }
  }

  /// Rubs out the whole strokes the eraser touches at [position]; [penUp] ends the touch.
  void eraseAt(Offset position) {
    if (_readOnly) return;
    final erased = _eraser.checkForOverlappingStrokes(position, page.strokes);
    if (erased.isEmpty) return;
    page.strokes.removeWhere(erased.contains);
    page.redrawStrokes();
  }

  /// Rubs out every stroke as one undo step.
  void clear() {
    if (_readOnly || page.strokes.isEmpty) return;
    final strokes = [...page.strokes];
    page.strokes.clear();
    page.redrawStrokes();
    history.recordChange(
      EditorHistoryItem(
        type: .erase,
        pageIndex: 0,
        strokes: strokes,
        images: [],
      ),
    );
    _changed();
  }

  void undo() {
    if (_readOnly || !history.canUndo) return;
    _apply(history.undo(), undo: true);
    history.canRedo = true;
  }

  void redo() {
    if (_readOnly || !history.canRedo) return;
    _apply(history.redo(), undo: false);
  }

  void _apply(EditorHistoryItem item, {required bool undo}) {
    final add = (item.type == .draw) != undo;
    for (final stroke in item.strokes) {
      if (add) {
        page.insertStroke(stroke);
      } else {
        page.strokes.remove(stroke);
      }
    }
    page.redrawStrokes();
    _changed();
  }

  /// Saves now if anything changed, after any save already going on. It does not throw: a failed save keeps
  /// [hasUnsavedChanges] true and the next one tries again.
  Future<void> flush() {
    _timer?.cancel();
    return _queue = _queue.then((_) => _save());
  }

  /// Call after [flush] has finished.
  void dispose() {
    if (_disposed) return;
    if (hasUnsavedChanges) {
      _log.warning('Quick note of $noteId closed with ink not saved');
    }
    _disposed = true;
    _timer?.cancel();
    _stroke.dispose();
    _saveState.dispose();
    core.dispose();
  }

  void _changed() {
    _changes++;
    _tell();
    _timer?.cancel();
    if (!_disposed) _timer = Timer(saveDelay, () => unawaited(flush()));
  }

  /// [saveState] hears a change of [hasUnsavedChanges] or [readOnly].
  void _tell() {
    final now = (unsaved: hasUnsavedChanges, readOnly: _readOnly);
    if (_disposed || now == _told) return;
    _told = now;
    _saveState.changed();
  }

  Future<void> _save() async {
    if (_disposed || _readOnly || !hasUnsavedChanges) return;
    final changes = _changes;
    try {
      await _write();
      _savedChanges = changes;
    } on Object catch (error, stack) {
      _log.warning(
        'Quick note of $noteId kept in memory: $error',
        error,
        stack,
      );
    }
    _tell();
  }

  Future<void> _write() async {
    final first = _record;
    try {
      return await _writeOver(first);
    } on StateError {
      // A new attachment is refused only when the note is missing, conflicted or in the trash.
      if (first == null) rethrow;
    }
    // Another head arrived after reading: read every head again and join them.
    _choose(await _absorb(await _store.list(noteId, _kind)));
    _requireWritable();
    final second = _record;
    try {
      return await _writeOver(second);
    } on StateError {
      if (second == null || !await _store.hasUnlistedHead(second)) rethrow;
    }
    // A head this device cannot read arrived after the list, so no write over this attachment can go through: write
    // over the next one, or a new one.
    _log.warning('Quick note ${second.entityId} has an unreadable head');
    _dead.add(second.entityId);
    _choose(_writable);
    _requireWritable();
    await _writeOver(_record);
  }

  void _requireWritable() {
    if (_readOnly) throw StateError('A newer app wrote this quick note');
  }

  Future<void> _writeOver(NoteSideRecord? base) async {
    final keys = [for (final stroke in page.strokes) _keyOf(stroke)];
    final (bson, _) = core.saveToBinary(currentPageIndex: null);
    _record = await _store.write(
      noteId,
      _kind,
      _files(bson, core.versionToWrite()),
      base: base,
    );
    _see(keys);
    final others = _others;
    _others = [];
    if (others.isEmpty) return;
    final empty = EditorCoreInfo(filePath: _path)
      ..backgroundPattern = .none
      ..pages.add(EditorPage());
    final (emptyBson, _) = empty.saveToBinary(currentPageIndex: null);
    final emptyFiles = _files(emptyBson, empty.versionToWrite());
    empty.dispose();
    for (final other in others) {
      try {
        await _store.write(noteId, _kind, emptyFiles, base: other);
        _withStrokes.remove(other.entityId);
      } on Object catch (error) {
        // It changed since it was read, or could not be written: the ink is
        // saved all the same, and the next open joins it again.
        _log.warning('Quick note ${other.entityId} not emptied: $error');
      }
    }
  }

  Map<String, Uint8List> _files(Uint8List bson, int version) => {
    _kind.markerFile: Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'sbnVersion': version,
          'width': page.size.width,
          'height': page.size.height,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      ),
    ),
    _sbnFile: bson,
  };

  /// Writes over the first of [writable] by id, so every device keeps the same one; the others that hold strokes get
  /// an empty page after it.
  void _choose(List<NoteSideRecord> writable) {
    _writable = [
      for (final record in writable)
        if (!_dead.contains(record.entityId)) record,
    ];
    _record = _writable.firstOrNull;
    _others = [
      for (final record in _writable.skip(1))
        if (_withStrokes.contains(record.entityId)) record,
    ];
  }

  /// Adds the strokes of every head of [records] that this quick note has not seen: the n-th copy of a stroke in a head
  /// comes in unless n copies are already on the page or were seen before (then it was rubbed out here). Returns the
  /// records that may be written over: every head listed was read, and the list left none out.
  Future<List<NoteSideRecord>> _absorb(List<NoteSideRecord> records) async {
    final onPage = <String, int>{};
    for (final stroke in page.strokes) {
      final key = _keyOf(stroke);
      onPage[key] = (onPage[key] ?? 0) + 1;
    }
    final writable = <NoteSideRecord>[];
    var added = false;
    for (final record in records) {
      var allRead = true;
      var withStrokes = false;
      for (final head in record.heads) {
        final other = await _load(head);
        if (other == null) {
          allRead = false;
          continue;
        }
        if (other.readOnlyReason == .versionTooNew) _readOnly = true;
        final keys = <String>[];
        final inHead = <String, int>{};
        for (final stroke in other.pages.first.strokes) {
          withStrokes = true;
          final key = _keyOf(stroke);
          keys.add(key);
          final copies = inHead[key] = (inHead[key] ?? 0) + 1;
          if (copies <= max(_seen[key] ?? 0, onPage[key] ?? 0)) continue;
          onPage[key] = (onPage[key] ?? 0) + 1;
          final copy = Stroke.fromJson(
            stroke.toJson(),
            fileVersion: EditorCoreInfo.sbnVersion,
            pageIndex: 0,
            page: page,
          );
          _keys[copy] = key;
          page.insertStroke(copy);
          added = true;
        }
        _see(keys);
        other.dispose();
      }
      if (withStrokes) {
        _withStrokes.add(record.entityId);
      } else {
        _withStrokes.remove(record.entityId);
      }
      if (allRead && !await _store.hasUnlistedHead(record))
        writable.add(record);
    }
    if (added) page.redrawStrokes();
    return writable;
  }

  /// Counts [keys] (one page's strokes) into [_seen].
  void _see(List<String> keys) {
    final counts = <String, int>{};
    for (final key in keys) {
      counts[key] = (counts[key] ?? 0) + 1;
    }
    for (final MapEntry(:key, :value) in counts.entries) {
      _seen[key] = max(_seen[key] ?? 0, value);
    }
  }

  /// The page of [head], or null when it cannot be read.
  Future<EditorCoreInfo?> _load(RevisionRecord head) async {
    try {
      final core = await EditorCoreInfo.loadFromFileContents(
        bsonBytes: await _store.repository.readRevisionFile(head, _sbnFile),
        path: _path,
        onlyFirstPage: true,
      );
      final reason = core.readOnlyReason;
      if (core.pages.isNotEmpty &&
          (reason == null || reason == ReadOnlyReason.versionTooNew)) {
        return core;
      }
      core.dispose();
    } on Object catch (error) {
      _log.warning('Skipped quick note head ${head.revisionId}: $error');
    }
    return null;
  }

  static final _keys = Expando<String>('quick note stroke key');

  /// A finished stroke's identity: the hash of its saved bytes.
  static String _keyOf(Stroke stroke) => _keys[stroke] ??= sha256
      .convert(BsonCodec.serialize(stroke.toJson()).byteList)
      .toString();
}

class _CurrentStroke extends ValueNotifier<Stroke?> {
  new() : super(null);

  /// The stroke has a new point.
  void changed() => notifyListeners();
}

class _Signal extends ChangeNotifier {
  void changed() => notifyListeners();
}
