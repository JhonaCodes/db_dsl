/// Diesel-style queries bound to a table: immutable builders that run when
/// awaited, and terminals that send one statement and map its answer.
library;

import 'dart:async';
import 'dart:convert';

import 'package:result_controller/result_controller.dart';

import '../database/database.dart';
import '../errors/db_error.dart';
import '../protocol/json_values.dart';
import '../protocol/query_plan.dart';
import '../protocol/statement.dart';
import '../schema/field.dart';
import '../schema/table.dart';
import 'expression.dart';
import 'ordering.dart';

part 'builders/select_query.dart';
part 'builders/find_query.dart';
part 'builders/write_queries.dart';
part 'builders/result_rows.dart';
part 'builders/projection_queries.dart';
part 'builders/group_query.dart';
part 'builders/join_query.dart';
part 'builders/associations.dart';
part 'builders/relation.dart';

/// Makes a finished query awaitable: `await users.filter(...)` runs it on
/// the implicit executor of its table (see [QueryExecutor.using]) — the
/// database that holds it (the default one, the first time it is used), or
/// the transaction running around it.
///
/// Why a `Future`: running is the one thing done with a finished query, so
/// awaiting it is enough, as in Supabase's builders. Naming an executor is
/// the exception, for another database of the same app (`load(other)`,
/// `execute(other)`). Each `await` runs the query again.
mixin _RunsWhenAwaited<R> implements Future<Result<R, DbError>> {
  /// The table whose database runs the query.
  DbTable<Object?> get _homeTable;

  /// Runs the query on [executor].
  Future<Result<R, DbError>> _runOn(QueryExecutor executor);

  Future<Result<R, DbError>> _run() =>
      QueryExecutor.using(_homeTable, null, _runOn);

  @override
  Future<S> then<S>(
    FutureOr<S> Function(Result<R, DbError> value) onValue, {
    Function? onError,
  }) => _run().then(onValue, onError: onError);

  @override
  Future<Result<R, DbError>> catchError(
    Function onError, {
    bool Function(Object error)? test,
  }) => _run().catchError(onError, test: test);

  @override
  Future<Result<R, DbError>> whenComplete(FutureOr<void> Function() action) =>
      _run().whenComplete(action);

  @override
  Future<Result<R, DbError>> timeout(
    Duration timeLimit, {
    FutureOr<Result<R, DbError>> Function()? onTimeout,
  }) => _run().timeout(timeLimit, onTimeout: onTimeout);

  @override
  Stream<Result<R, DbError>> asStream() => _run().asStream();
}
