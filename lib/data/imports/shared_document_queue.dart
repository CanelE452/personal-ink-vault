import 'package:flutter/foundation.dart';

final _recoveredScope = Object();

final class SharedDocumentRequest {
  new _(
    this.id,
    this.path,
    this._onRelease,
    this.sharedRequestId,
    bool recovered,
  ) {
    if (recovered) _scope = _recoveredScope;
  }
  final int id;
  final String path;
  final String? sharedRequestId;
  final Future<void> Function()? _onRelease;
  Object? _scope;
  Object? _failure;
  Object? get scope => _scope;
  Object? get failure => _failure;
  bool get needsDestinationConfirmation => identical(_scope, _recoveredScope);

  void _release() {
    final release = _onRelease;
    if (release != null) Future<void>.sync(release).ignore();
  }
}

final class SharedDocumentLease {
  new _(this.owner, this.request);
  final Object owner;
  final SharedDocumentRequest request;
}

class SharedDocumentInbox extends ValueNotifier<String?> {
  new() : super(null);
  final _pending = <SharedDocumentRequest>[];
  SharedDocumentLease? _active;
  var _sequence = 0;

  List<SharedDocumentRequest> get pending => List.unmodifiable(_pending);
  bool get processing => _active != null;

  @override
  set value(String? path) {
    if (path == null) {
      for (final request in _pending) {
        if (!identical(_active?.request, request)) request._release();
      }
      _pending.clear();
      _publish();
      return;
    }
    enqueue(path);
  }

  bool enqueue(
    String path, {
    Future<void> Function()? onRelease,
    String? sharedRequestId,
    bool recovered = false,
  }) {
    if (_active?.request.path == path ||
        _pending.any((request) => request.path == path))
      return false;
    _pending.add(
      SharedDocumentRequest._(
        ++_sequence,
        path,
        onRelease,
        sharedRequestId,
        recovered,
      ),
    );
    _publish();
    return true;
  }

  void bindUnassigned(Object scope) {
    var changed = false;
    for (final request in _pending) {
      if (request._scope == null) {
        request._scope = scope;
        changed = true;
      }
    }
    if (changed) _publish();
  }

  SharedDocumentLease? claim({required Object owner, required Object scope}) {
    if (_active != null || _pending.isEmpty) return null;
    final request = _pending.first;
    if (request.failure != null ||
        request.scope != null && request.scope != scope)
      return null;
    request._scope ??= scope;
    final lease = SharedDocumentLease._(owner, request);
    _active = lease;
    _publish();
    return lease;
  }

  bool isCurrent(SharedDocumentLease lease) =>
      identical(_active, lease) && _pending.contains(lease.request);

  bool finish(SharedDocumentLease lease, {Object? failure}) {
    if (!identical(_active, lease)) return false;
    _active = null;
    final present = _pending.contains(lease.request);
    if (!present) {
      lease.request._release();
    } else {
      if (failure == null) {
        _pending.remove(lease.request);
        lease.request._release();
      } else {
        lease.request._failure = failure;
      }
    }
    _publish();
    return present;
  }

  bool retry(int id) {
    if (_active != null || _pending.firstOrNull?.id != id) return false;
    _pending.first._failure = null;
    _publish();
    return true;
  }

  bool defer(int id) {
    if (_active != null || _pending.firstOrNull?.id != id) return false;
    _pending.removeAt(0)._release();
    _publish();
    return true;
  }

  bool useScope(int id, Object scope) {
    if (_active != null || _pending.firstOrNull?.id != id) return false;
    _pending.first
      .._scope = scope
      .._failure = null;
    _publish();
    return true;
  }

  void _publish() {
    final next = _pending.lastOrNull?.path;
    if (super.value == next)
      notifyListeners();
    else
      super.value = next;
  }
}
