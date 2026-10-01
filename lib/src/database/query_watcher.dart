part of 'database.dart';

/// The stream of [Database.watch]: the rows of a query now and after every
/// committed write to its table.
///
/// Why a class: it owns the subscription to the database's changes, the
/// reload in flight and the "stale" flag that coalesces bursts of commits
/// into one reload.
final class _QueryWatcher<T> {
  _QueryWatcher(this._database, this._query) {
    _controller = StreamController<Result<List<T>, DbError>>(
      onListen: _start,
      onCancel: () => _changes?.cancel(),
    );
  }

  final Database _database;
  final SelectQuery<T> _query;
  late final StreamController<Result<List<T>, DbError>> _controller;
  StreamSubscription<Set<String>>? _changes;
  bool _loading = false;
  bool _stale = false;

  /// The rows, then the rows again after each relevant commit.
  Stream<Result<List<T>, DbError>> get stream => _controller.stream;

  void _start() {
    _changes = _database.changes
        .where((tables) => tables.contains(_query.table.tableName))
        .listen((_) => _reload());
    _reload();
  }

  Future<void> _reload() async {
    if (_loading) {
      _stale = true;
      return;
    }

    _loading = true;

    do {
      _stale = false;
      final rows = await _query.load(_database);

      if (!_controller.isClosed) {
        _controller.add(rows);
      }
    } while (_stale && !_controller.isClosed);

    _loading = false;
  }
}
