/// The native runtime of db_dsl: [NativeEngine] runs the protocol on a
/// loaded offline_first_core (Rust + LMDB 1.0) through one worker isolate.
///
/// db_dsl bundles no binary. flutter_local_db and dart_db each bring theirs
/// with a build hook and hand the addresses of its functions to
/// [NativeSymbols]. Import this library only on platforms with `dart:ffi`
/// (not the web).
library;

export 'src/native/native_engine.dart';
export 'src/native/native_key_value_store.dart';
export 'src/native/native_symbols.dart';
export 'src/native/native_worker.dart' show KeyValueCall, NativeWorker;
