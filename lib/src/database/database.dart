/// A database on an engine: statements, transactions, savepoints, reactive
/// queries, all answered as `Result`s.
library;

import 'dart:async';

import 'package:logger_rs/logger_rs.dart';
import 'package:meta/meta.dart';
import 'package:result_controller/result_controller.dart';

import '../engine/db_options.dart';
import '../engine/engine.dart';
import '../errors/db_error.dart';
import '../protocol/engine_info.dart';
import '../protocol/query_plan.dart';
import '../protocol/request.dart';
import '../protocol/statement.dart';
import '../query/queries.dart';
import '../schema/table.dart';
import '../schema/table_schema.dart';

part 'transaction.dart';
part 'write_lock.dart';
part 'query_watcher.dart';

/// Something statements run on: a [Database] (each statement in its own
/// transaction), a [Transaction] or a [ReadTransaction].
///
/// Why sealed: these three are exactly the scopes the protocol offers
/// (autocommit, interactive write, snapshot read); keeping the family closed
/// guarantees every statement goes through one of them and their rules
/// (write lock, reentrancy check, change notifications).
sealed class QueryExecutor {
  /// Runs [statement] and answers its output.
  Future<Result<O, DbError>> run<O>(Statement<O> statement);

  /// Where a query of [table] runs when it is awaited without naming an
  /// executor: the transaction running in the current zone, when it belongs
  /// to the database that opened [table]; otherwise that database.
  ///
  /// Why implicit: an app has one database loaded, and naming it on every
  /// query adds nothing; naming another one (`load(other)`,
  /// `execute(other)`) is the exception. Inside a transaction the implicit
  /// executor is the transaction, so an awaited write commits or rolls back
  /// with it instead of escaping to autocommit.
  static Result<QueryExecutor, DbError> of(DbTable<Object?> table) =>
      switch ((Database._homes[table], Zone.current[Database._scopeZone])) {
        (null, _) => Err(notOpen(table)),
        (final Database home, final Transaction tx)
            when identical(tx._database, home) =>
          Ok(tx),
        (final Database home, final ReadTransaction tx)
            when identical(tx._database, home) =>
          Ok(tx),
        (final Database home, _) => Ok(home),
      };

  /// The error of a query of [table] awaited while the table is open in no
  /// database. Used by the query builders.
  @internal
  static DbError notOpen(DbTable<Object?> table) => DbError(
    DbErrorCode.notOpen,
    '`${table.tableName}` is open in no database: open a database with it, '
    'or name the database to run on',
  );

  /// Runs [action] on [on] when given, else on the implicit executor of
  /// [table] (see [of]). Used by the query builders.
  @internal
  static Future<Result<R, DbError>> using<R>(
    DbTable<Object?> table,
    QueryExecutor? on,
    Future<Result<R, DbError>> Function(QueryExecutor executor) action,
  ) => switch (on) {
    final QueryExecutor explicit => action(explicit),
    null => of(table).when(ok: action, err: (error) async => Err(error)),
  };
}

/// A database queried Diesel-style on any [Engine]: the native engine that
/// flutter_local_db or dart_db bundle (offline_first_core, Rust + LMDB 1.0),
/// [MemoryEngine] in tests, or a third-party translator.
///
/// ```dart
/// final opened = await Database.open(engine, path: dir, tables: [users]);
///
/// // The tables are this database's now: awaiting a query runs it here.
/// final adults = await users.filter(users.age.ge(18));
/// ```
///
/// Every call answers a `Result`: `Ok` with the value, `Err` with a
/// [DbError]. Statements run on the database commit on their own; group
/// them with [transaction]. Another database of the same app is named
/// explicitly: `users.all().load(archive)`.
///
/// Why `base`: libraries that wrap an engine (flutter_local_db, dart_db)
/// extend it with their own `open`; nobody re-implements its rules.
base class Database extends QueryExecutor {
  /// A database on an open [connection]. Libraries that wrap an engine build
  /// their `open` on it; apps call [open].
  Database.connected(this._connection, this.path);

  /// Where the database lives; the engine decides its files (the native
  /// engine uses `<path>.lmdb`).
  final String path;

  final EngineConnection _connection;
  final _WriteLock _writes = _WriteLock();

  /// The tables whose queries run here by default (see [_homes]).
  final Set<DbTable<Object?>> _homed = Set.identity();
  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();
  bool _closed = false;

  /// Marks the zone of a running transaction with the transaction: queries
  /// awaited inside run on it (see [QueryExecutor.of]), and using the
  /// database itself inside a write transaction is caught (it would wait
  /// forever for its own transaction).
  static final Object _scopeZone = Object();

  /// The database each table runs on when a query of it is awaited without
  /// naming one: the first open database that defined it.
  static final Expando<Database> _homes = Expando('db_dsl home database');

  /// The database a query of [table] runs on by default, or `null` when
  /// the table is open in no database. Used by the query builders.
  @internal
  static Database? homeOf(DbTable<Object?> table) => _homes[table];

  /// Opens (or creates) the database at [path] on [engine] and defines
  /// [tables] (adding or removing indexes of existing ones).
  ///
  /// With the native engine, [DbErrorCode.legacyFormat] means the files were
  /// written by LMDB 0.9 (flutter_local_db 1.x or dart_db 0.2).
  static Future<Result<Database, DbError>> open(
    Engine engine, {
    required String path,
    List<DbTable<Object?>> tables = const [],
    DbOptions options = const DbOptions(),
  }) async {
    return (await engine.open(path, options)).when(
      ok: (connection) async {
        final database = Database.connected(connection, path);
        return (await database.defineTables(tables)).map((_) => database);
      },
      err: (error) async {
        Log.w('Cannot open the database at $path: $error');
        return Err(error);
      },
    );
  }

  /// Defines every table of [tables], in order, stopping at the first error.
  Future<Result<(), DbError>> defineTables(
    Iterable<DbTable<Object?>> tables,
  ) async {
    for (final table in tables) {
      if (await defineTable(table) case Err(:final error)) {
        return Err(error);
      }
    }

    return Ok(());
  }

  /// Defines [table], or adds and removes indexes of an existing one (new
  /// indexes are built over the existing rows). Answers whether anything
  /// changed.
  ///
  /// A table defined here for the first time, while no other open database
  /// holds it, becomes one of this database's: its queries awaited without
  /// naming a database run here.
  Future<Result<bool, DbError>> defineTable(DbTable<Object?> table) => _guarded(
    () => _writes.run(() async {
      final defined = await _send(DefineTableRequest(table.schema));

      if (defined.isOk && _homes[table] == null) {
        _homes[table] = this;
        _homed.add(table);
      }

      return defined;
    }),
  );

  /// Drops the table [name] with its rows and indexes; answers whether it
  /// existed.
  Future<Result<bool, DbError>> dropTable(String name) => _guarded(
    () => _writes.run(() async {
      final dropped = await _send(DropTableRequest(name));

      if (dropped.isOk) {
        _notify({name});
      }

      return dropped;
    }),
  );

  /// The definitions of the tables of this database.
  Future<Result<List<TableSchema>, DbError>> tables() =>
      _guarded(() => _send(const TablesRequest()));

  @override
  Future<Result<O, DbError>> run<O>(Statement<O> statement) => _guarded(
    () => switch (statement) {
      WriteStatement() => _writes.run(() async {
        final output = await _send(ExecuteRequest(statement));

        if (output.isOk) {
          _notify({statement.table});
        }

        return output;
      }),
      ReadStatement() => _send(ExecuteRequest(statement)),
    },
  );

  /// Runs [writes] in order in one transaction: all of them commit, or none
  /// does. Answers the rows each one affected.
  Future<Result<List<int>, DbError>> atomicBatch(List<WriteQuery> writes) =>
      _guarded(() async {
        final statements = <WriteStatement>[];

        for (final write in writes) {
          switch (write.prepared) {
            case Ok(:final data):
              statements.add(data);
            case Err(:final error):
              return Err(error);
          }
        }

        return _writes.run(() async {
          final outputs = await _send(BatchRequest<WriteOutput>(statements));

          if (outputs.isOk) {
            _notify({for (final statement in statements) statement.table});
          }

          return outputs.map(
            (all) => [for (final output in all) output.affected],
          );
        });
      });

  /// Runs [body] in a write transaction, like Diesel: it commits when [body]
  /// answers `Ok` and rolls back when it answers `Err`. The value is returned
  /// only after the commit succeeded.
  ///
  /// Queries awaited inside [body] run on the transaction (`tx`); naming the
  /// database itself fails with [DbErrorCode.transactionReentrancy]. A write that fails makes the
  /// transaction rollback-only (the commit then fails with
  /// [DbErrorCode.transactionAborted]); put recoverable work in
  /// [Transaction.savepoint]. Other writes of this database wait until the
  /// transaction ends. After [idleTimeout] without a statement, the engine
  /// rolls the transaction back.
  ///
  /// An exception thrown by [body] is a bug, not an outcome: the
  /// transaction is rolled back and the exception rethrown.
  Future<Result<R, DbError>> transaction<R>(
    Future<Result<R, DbError>> Function(Transaction tx) body, {
    Duration idleTimeout = BeginRequest.defaultIdleTimeout,
  }) => _guarded(
    () => _writes.run(() async {
      final begun = await _send(
        BeginRequest(TransactionMode.write, idleTimeout: idleTimeout),
      );

      return begun.when(
        ok: (id) => Transaction._(this, id)._complete(body),
        err: (error) async => Err(error),
      );
    }),
  );

  /// Runs [body] against one consistent read-only snapshot; writes committed
  /// meanwhile are not seen. The snapshot is released when [body] ends.
  Future<Result<R, DbError>> readTransaction<R>(
    Future<Result<R, DbError>> Function(ReadTransaction tx) body, {
    Duration idleTimeout = BeginRequest.defaultIdleTimeout,
  }) => _guarded(() async {
    final begun = await _send(
      BeginRequest(TransactionMode.read, idleTimeout: idleTimeout),
    );

    return begun.when(
      ok: (id) => ReadTransaction._(this, id)._complete(body),
      err: (error) async => Err(error),
    );
  });

  /// The plan the engine chooses for [query], without running it.
  Future<Result<QueryPlan, DbError>> explain(SelectQuery<Object?> query) =>
      _guarded(() => _send(ExplainRequest(query.statement)));

  /// The rows of [query] now, and again after every committed write of this
  /// database to its table.
  Stream<Result<List<T>, DbError>> watch<T>(SelectQuery<T> query) =>
      _QueryWatcher<T>(this, query).stream;

  /// Tables written by each commit of this database, for custom reactivity.
  Stream<Set<String>> get changes => _changes.stream;

  /// Facts about the database and its engine.
  Future<Result<EngineInfo, DbError>> info() =>
      _guarded(() => _send(const InfoRequest()));

  /// Waits for running writes, then releases the database; later calls fail
  /// with [DbErrorCode.closed].
  Future<Result<(), DbError>> close() async {
    if (_closed) {
      return Ok(());
    }

    return _writes.run(() async {
      _closed = true;
      _releaseTables();
      await _changes.close();
      Log.d('Closed the database at $path');
      return _connection.close();
    });
  }

  /// Runs [action] unless the database is closed or used inside one of its
  /// own transactions.
  Future<Result<R, DbError>> _guarded<R>(
    Future<Result<R, DbError>> Function() action,
  ) {
    final refusal = switch ((_closed, Zone.current[_scopeZone])) {
      (true, _) => DbError(DbErrorCode.closed, 'The database is closed'),
      (false, final Transaction owner) when identical(owner._database, this) =>
        DbError(
          DbErrorCode.transactionReentrancy,
          'The database was used inside one of its own transactions; run the '
          'statement on the transaction instead',
        ),
      _ => null,
    };

    return switch (refusal) {
      null => action(),
      final DbError error => Future.value(Err(error)),
    };
  }

  /// Gives up the tables of this database: the next database that defines
  /// one takes it.
  void _releaseTables() {
    for (final table in _homed) {
      if (identical(_homes[table], this)) {
        _homes[table] = null;
      }
    }

    _homed.clear();
  }

  /// Sends [request] and decodes its answer.
  Future<Result<O, DbError>> _send<O>(ProtocolRequest<O> request) async =>
      (await _connection.send(request)).flatMap(request.decodeOutput);

  void _notify(Set<String> tables) {
    if (tables.isNotEmpty && !_changes.isClosed) {
      _changes.add(tables);
    }
  }
}
