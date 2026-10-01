/// A Diesel-style query language for Dart.
///
/// Declare a table in one line with the app's own model, build queries and
/// writes with the Diesel vocabulary (`filter`, `order`, `limit`, `insert`,
/// `update().set()`, `delete`, `transaction`), and send them as a documented
/// protocol
/// (`PROTOCOL.md`) to any [Engine]: the native offline_first_core bundled by
/// flutter_local_db or dart_db, [MemoryEngine] for tests, or your own
/// translator. Every operation answers a `Result` (`Ok` or `Err` with a
/// [DbError]).
///
/// This library runs on every platform, the web included; the native
/// runtime lives in `package:db_dsl/native.dart`.
library;

export 'package:result_controller/result_controller.dart'
    show
        Err,
        FutureResultExtensions,
        Ok,
        Result,
        ResultCollectionExtensions,
        ResultExtensions;

export 'src/database/database.dart'
    show Database, QueryExecutor, ReadTransaction, Transaction;
export 'src/engine/db_options.dart';
export 'src/engine/engine.dart';
export 'src/errors/db_error.dart';
export 'src/memory/memory_engine.dart';
export 'src/protocol/engine_info.dart';
export 'src/protocol/envelope.dart';
export 'src/protocol/json_values.dart';
export 'src/protocol/query_plan.dart';
export 'src/protocol/request.dart';
export 'src/protocol/statement.dart';
export 'src/query/expression.dart';
export 'src/query/ordering.dart';
export 'src/query/queries.dart';
export 'src/schema/field.dart';
export 'src/schema/table.dart';
export 'src/schema/table_schema.dart';
