/// The key-value C ABI of offline_first_core.
library;

import 'dart:convert';

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import 'native_symbols.dart';
import 'native_worker.dart';

/// A database opened for the key-value API of offline_first_core
/// (`push_data`, `get_by_id`, ...), the API flutter_local_db 1.x shipped.
///
/// Why it lives next to [NativeEngine]: both call the same library through
/// the same worker isolate; flutter_local_db's `LocalDB` and dart_db use it
/// without a second copy of that machinery. Answers are the raw JSON
/// strings of that API; their meaning belongs to the caller.
final class NativeKeyValueStore {
  NativeKeyValueStore._(this._worker, this._handle);

  final NativeWorker _worker;
  final int _handle;

  /// Opens `<path>.lmdb` with the library of [symbols], which must include
  /// [NativeSymbols.keyValue].
  static Future<Result<NativeKeyValueStore, DbError>> open(
    NativeSymbols symbols,
    String path,
  ) async {
    if (symbols.keyValue == null) {
      return Err(
        DbError(
          DbErrorCode.nativeLibrary,
          'The library was given without its key-value symbols',
        ),
      );
    }

    return (await NativeWorker.openOn(
      symbols,
      path,
      jsonEncode(const {}),
    )).map((open) => NativeKeyValueStore._(open.$1, open.$2));
  }

  /// Runs [call] with [argument]; answers the raw response of the library.
  Future<Result<String, DbError>> call(KeyValueCall call, [String? argument]) =>
      _worker.keyValue(_handle, call, argument);

  /// Releases the database.
  Future<Result<(), DbError>> close() async =>
      (await _worker.close(_handle)).map((_) => ());
}
