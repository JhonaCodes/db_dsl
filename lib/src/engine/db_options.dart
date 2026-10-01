/// How a database is opened: limits and durability (`PROTOCOL.md`,
/// "Open options").
library;

/// How commits reach stable storage.
///
/// Why an enum and not a flag: the three levels are distinct guarantees an
/// app chooses on purpose, and each maps to one engine setting.
enum Durability {
  /// Every commit is flushed before it completes (default): a committed
  /// transaction survives a power loss.
  full('full'),

  /// Data is flushed on commit but the metadata page is not: a system crash
  /// may undo the last transaction, never corrupt the database.
  noMetaSync('no_meta_sync'),

  /// Flushing is left to the operating system: a system crash may undo the
  /// last transactions. An app crash loses nothing.
  noSync('no_sync');

  const Durability(this.wire);

  /// The `durability` of the protocol.
  final String wire;
}

/// Options for opening a database; they apply when the database is first
/// opened in the process.
final class DbOptions {
  /// Options with the engine defaults.
  const DbOptions({
    this.maxTables = 1024,
    this.initialSize = 64 << 20,
    this.maxSize = 16 << 30,
    this.durability = Durability.full,
  });

  /// Maximum number of tables plus indexes.
  final int maxTables;

  /// Initial size of the memory map in bytes: address space, not disk.
  final int initialSize;

  /// The map doubles when full, up to this size in bytes; beyond it writes
  /// fail with `DbErrorCode.mapFull`.
  final int maxSize;

  /// How commits reach stable storage.
  final Durability durability;

  /// The protocol form (the `options` of `ofc_open`).
  Map<String, Object?> toJson() => {
    'max_dbs': maxTables,
    'initial_map_size': initialSize,
    'max_map_size': maxSize,
    'durability': durability.wire,
  };
}
