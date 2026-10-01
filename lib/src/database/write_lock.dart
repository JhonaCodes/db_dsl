part of 'database.dart';

/// Serializes the writes of one [Database].
///
/// Why it exists: a transaction holds the engine's single writer. A write
/// sent from outside meanwhile would wait inside the engine and, with the
/// native engine's single worker isolate, block the transaction's own
/// statements behind it. Queueing writes here keeps them in order instead.
final class _WriteLock {
  Future<void> _tail = Future<void>.value();

  /// Runs [action] after every write queued before it.
  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;

    return previous.then((_) => action()).whenComplete(done.complete);
  }
}
