/// The answer of `info`: what the engine is and how big the database is.
library;

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';

/// Facts about an open database and its engine.
final class EngineInfo {
  /// Info of an engine speaking [protocol].
  const EngineInfo({
    required this.protocol,
    required this.tables,
    required this.storage,
    required this.mapSize,
  });

  /// Protocol version the engine speaks.
  final int protocol;

  /// Number of defined tables.
  final int tables;

  /// The storage and its version: the LMDB version (`"1.0.2"`) for LMDB
  /// engines, `"memory"` for [MemoryEngine].
  final String storage;

  /// Current size of the memory map in bytes (0 when not mapped).
  final int mapSize;

  /// The protocol form.
  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'tables': tables,
    'lmdb': storage,
    'map_size': mapSize,
  };

  /// The info encoded in [json].
  static Result<EngineInfo, DbError> decode(Object? json) => switch (json) {
    {
      'protocol': final int protocol,
      'tables': final int tables,
      'lmdb': final String storage,
      'map_size': final int mapSize,
    } =>
      Ok(
        EngineInfo(
          protocol: protocol,
          tables: tables,
          storage: storage,
          mapSize: mapSize,
        ),
      ),
    _ => Err(DbError(DbErrorCode.unsupportedProtocol, 'Bad info: $json')),
  };

  @override
  String toString() => 'EngineInfo(${toJson()})';
}
