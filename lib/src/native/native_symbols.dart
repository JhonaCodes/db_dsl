/// The C ABI of offline_first_core, as function addresses.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `ofc_open(path, options, out) -> response`.
typedef OfcOpen =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
    );

/// `ofc_execute(handle, request) -> response`.
typedef OfcExecute = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);

/// `ofc_free_string(response)`.
typedef OfcFreeString = Void Function(Pointer<Utf8>);

/// A call on a handle: `close_database(handle)`, `get_all(handle)`,
/// `clear_all_records(handle)`.
typedef OfcHandleCall = Pointer<Utf8> Function(Pointer<Void>);

/// A call on a handle with a string: `push_data`, `update_data`,
/// `get_by_id`, `delete_by_id`.
typedef OfcHandleStringCall =
    Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);

/// `ldb_open(path, path_len, options, options_len, out, response) ->
/// status` of the ABI v2.
typedef LdbOpen =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Uint64>,
      Pointer<Uint64>,
    );

/// `ldb_execute(database, request, request_len, response) -> status`.
typedef LdbExecute =
    Int32 Function(Uint64, Pointer<Uint8>, Size, Pointer<Uint64>);

/// `ldb_buffer_view(buffer, data, len) -> status`.
typedef LdbBufferView =
    Int32 Function(Uint64, Pointer<Pointer<Uint8>>, Pointer<Size>);

/// `ldb_buffer_release(buffer)` and `ldb_close(database)` -> status.
typedef LdbHandleCall = Int32 Function(Uint64);

/// Where the functions of a loaded offline_first_core live.
///
/// Why addresses and not a library path: the library that bundles the
/// binary (flutter_local_db, dart_db) resolves it through its own build
/// hook, with `@Native` bindings; it hands their addresses here
/// (`Native.addressOf`), so db_dsl never loads a binary itself.
final class NativeSymbols {
  /// The query API symbols, plus [keyValue] when the library also exposes
  /// the key-value API, and [abiV2] when it has the ABI v2 (offline_first_core
  /// 0.7.6 and later): the query API then runs on it.
  const NativeSymbols({
    required this.open,
    required this.execute,
    required this.freeString,
    required this.close,
    this.keyValue,
    this.abiV2,
  });

  /// `ofc_open`.
  final Pointer<NativeFunction<OfcOpen>> open;

  /// `ofc_execute`.
  final Pointer<NativeFunction<OfcExecute>> execute;

  /// `ofc_free_string`.
  final Pointer<NativeFunction<OfcFreeString>> freeString;

  /// `close_database`.
  final Pointer<NativeFunction<OfcHandleCall>> close;

  /// The key-value API (the 0.5 C ABI kept by offline_first_core).
  final KeyValueSymbols? keyValue;

  /// The ABI v2 (`include/localdb.h` of offline_first_core), when given.
  final AbiV2Symbols? abiV2;

  /// The addresses as plain integers, the form that crosses to the worker
  /// isolate.
  List<int> get addresses => [
    open.address,
    execute.address,
    freeString.address,
    close.address,
    ...?keyValue?.addresses,
  ];
}

/// The key-value C ABI of offline_first_core (`push_data`, `update_data`,
/// `get_by_id`, `delete_by_id`, `get_all`, `clear_all_records`).
final class KeyValueSymbols {
  /// Every key-value function.
  const KeyValueSymbols({
    required this.push,
    required this.update,
    required this.getById,
    required this.deleteById,
    required this.getAll,
    required this.clear,
  });

  /// `push_data`.
  final Pointer<NativeFunction<OfcHandleStringCall>> push;

  /// `update_data`.
  final Pointer<NativeFunction<OfcHandleStringCall>> update;

  /// `get_by_id`.
  final Pointer<NativeFunction<OfcHandleStringCall>> getById;

  /// `delete_by_id`.
  final Pointer<NativeFunction<OfcHandleStringCall>> deleteById;

  /// `get_all`.
  final Pointer<NativeFunction<OfcHandleCall>> getAll;

  /// `clear_all_records`.
  final Pointer<NativeFunction<OfcHandleCall>> clear;

  /// The addresses, in declaration order.
  List<int> get addresses => [
    push.address,
    update.address,
    getById.address,
    deleteById.address,
    getAll.address,
    clear.address,
  ];
}

/// The ABI v2 of offline_first_core (0.7.6 and later): `u64` handles that
/// the library validates, so a handle used after it was closed answers an
/// error instead of undefined behaviour, and requests and responses as
/// bytes with a length.
final class AbiV2Symbols {
  /// Every function of the ABI v2.
  const AbiV2Symbols({
    required this.open,
    required this.execute,
    required this.bufferView,
    required this.bufferRelease,
    required this.close,
  });

  /// `ldb_open`.
  final Pointer<NativeFunction<LdbOpen>> open;

  /// `ldb_execute`.
  final Pointer<NativeFunction<LdbExecute>> execute;

  /// `ldb_buffer_view`.
  final Pointer<NativeFunction<LdbBufferView>> bufferView;

  /// `ldb_buffer_release`.
  final Pointer<NativeFunction<LdbHandleCall>> bufferRelease;

  /// `ldb_close`.
  final Pointer<NativeFunction<LdbHandleCall>> close;

  /// The addresses, in declaration order.
  List<int> get addresses => [
    open.address,
    execute.address,
    bufferView.address,
    bufferRelease.address,
    close.address,
  ];
}
