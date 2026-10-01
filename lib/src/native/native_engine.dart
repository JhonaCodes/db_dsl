/// The native offline_first_core as an [Engine].
library;

import 'dart:convert';

import 'package:result_controller/result_controller.dart';

import '../engine/db_options.dart';
import '../engine/engine.dart';
import '../errors/db_error.dart';
import '../protocol/envelope.dart';
import '../protocol/request.dart';
import 'native_symbols.dart';
import 'native_worker.dart';

/// The offline_first_core library (Rust + LMDB 1.0) as an [Engine].
///
/// The library that bundles the binary builds it from the addresses of its
/// functions:
///
/// ```dart
/// final engine = NativeEngine(
///   NativeSymbols(
///     open: Native.addressOf(Bindings.open),
///     execute: Native.addressOf(Bindings.execute),
///     freeString: Native.addressOf(Bindings.freeString),
///     close: Native.addressOf(Bindings.close),
///   ),
/// );
/// ```
///
/// Every call runs on the library's [NativeWorker] isolate.
final class NativeEngine implements Engine {
  /// The engine of the library whose functions are [symbols].
  const NativeEngine(this.symbols);

  /// The functions of the library.
  final NativeSymbols symbols;

  @override
  Future<Result<EngineConnection, DbError>> open(
    String path,
    DbOptions options,
  ) async {
    final opened = await NativeWorker.openOn(
      symbols,
      path,
      jsonEncode(options.toJson()),
    );

    return opened.map<EngineConnection>(
      (open) => NativeConnection._(open.$1, open.$2),
    );
  }
}

/// An open database of a [NativeEngine].
final class NativeConnection implements EngineConnection {
  NativeConnection._(this._worker, this._handle);

  final NativeWorker _worker;
  final int _handle;
  bool _closed = false;

  @override
  Future<Result<Map<String, Object?>, DbError>> send(
    ProtocolRequest<Object?> request,
  ) async {
    if (_closed) {
      return Err(DbError(DbErrorCode.closed, 'The database is closed'));
    }

    final String json;

    try {
      json = jsonEncode(request.toJson());
    } on JsonUnsupportedObjectError catch (error) {
      return Err(
        DbError(
          DbErrorCode.invalidRequest,
          'The request is not JSON: ${error.unsupportedObject}',
        ),
      );
    }

    return (await _worker.execute(
      _handle,
      json,
    )).flatMap(ProtocolEnvelope.decode);
  }

  @override
  Future<Result<(), DbError>> close() async {
    if (_closed) {
      return Ok(());
    }

    _closed = true;
    return (await _worker.close(_handle)).map((_) => ());
  }
}
