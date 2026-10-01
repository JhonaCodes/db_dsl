/// The plug between the DSL and whatever answers its messages.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../protocol/request.dart';
import 'db_options.dart';

/// Something that answers the db_dsl protocol (`PROTOCOL.md`).
///
/// Why an interface: the DSL only speaks the language; who answers is
/// pluggable. flutter_local_db and dart_db each bundle the native
/// offline_first_core as a `NativeEngine`, [MemoryEngine] answers in memory
/// for tests, and anyone can write a translator to another store.
abstract interface class Engine {
  /// Opens (or creates) the database at [path].
  Future<Result<EngineConnection, DbError>> open(
    String path,
    DbOptions options,
  );
}

/// An open database of an [Engine].
abstract interface class EngineConnection {
  /// Answers [request] with its `ok` payload (`PROTOCOL.md`, "Envelope"), or
  /// with the error the engine reported.
  Future<Result<Map<String, Object?>, DbError>> send(
    ProtocolRequest<Object?> request,
  );

  /// Releases the database; later requests fail with
  /// [DbErrorCode.closed].
  Future<Result<(), DbError>> close();
}
