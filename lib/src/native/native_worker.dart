/// The isolate that owns every call into a loaded offline_first_core.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import '../protocol/envelope.dart';
import 'native_symbols.dart';

/// The calls of the key-value C ABI.
enum KeyValueCall {
  /// `push_data(handle, json)`.
  push,

  /// `update_data(handle, json)`.
  update,

  /// `get_by_id(handle, id)`.
  getById,

  /// `delete_by_id(handle, id)`.
  deleteById,

  /// `get_all(handle)`.
  getAll,

  /// `clear_all_records(handle)`.
  clear,
}

/// The isolate that runs every call into one native library, alive while
/// a database of that library is open.
///
/// Why an isolate: a native call blocks its thread until LMDB answers (a
/// durable commit waits for the disk). Running them here keeps the caller's
/// isolate — the UI, in an app — free. Requests are served in order and
/// matched to their replies by id.
///
/// Why it stops: its reply port, open in the caller's isolate, would keep a
/// program alive forever after its last database closed (a CLI that never
/// ends), and the isolate would stay in memory in an app that keeps running.
/// When the last handle is closed and no call is pending, it closes that
/// port and ends the isolate; the next open starts a new worker.
final class NativeWorker {
  NativeWorker._(this._commands, this._replies, this._key);

  final SendPort _commands;
  final ReceivePort _replies;
  final int _key;
  final Map<int, _PendingCall> _pending = {};
  int _nextId = 0;
  int _openHandles = 0;
  bool _stopped = false;

  /// One running worker per library, by the address of its `ofc_open`.
  static final Map<int, Future<NativeWorker>> _workers = {};

  /// The running worker of the library of [symbols], started on demand.
  static Future<NativeWorker> of(NativeSymbols symbols) =>
      _workers[symbols.open.address] ??= _spawn(
        symbols.open.address,
        symbols.addresses,
      );

  static Future<NativeWorker> _spawn(int key, List<int> addresses) async {
    final port = ReceivePort();
    await Isolate.spawn(_NativeCalls.serve, (
      port.sendPort,
      addresses,
    ), debugName: 'db_dsl native worker');

    // The first message is the command port; the next ones are replies. No
    // reply arrives before the first command is sent.
    final messages = port.asBroadcastStream();
    final worker = NativeWorker._(await messages.first as SendPort, port, key);
    messages.listen(worker._onReply);

    return worker;
  }

  /// Opens `<path>.lmdb` with [options] (JSON) on a running worker of
  /// [symbols]: answers the worker and the handle, or the error the engine
  /// answered (such as [DbErrorCode.legacyFormat]).
  static Future<Result<(NativeWorker, int), DbError>> openOn(
    NativeSymbols symbols,
    String path,
    String options,
  ) async {
    final worker = await of(symbols);

    // A worker that stopped meanwhile is no longer listed: ask again.
    if (worker._stopped) {
      return openOn(symbols, path, options);
    }

    return (await worker._call('open', [path, options])).flatMap(
      (reply) => switch (reply) {
        [0, final String response] => ProtocolEnvelope.decode(response).flatMap(
          (payload) => Err(
            DbError(
              DbErrorCode.unsupportedProtocol,
              'The engine opened nothing but answered $payload',
            ),
          ),
        ),
        [final int handle, String()] => Ok((worker, handle)),
        _ => Err(_malformed(reply)),
      },
    );
  }

  /// Runs one JSON [request] of the protocol on [handle].
  Future<Result<String, DbError>> execute(int handle, String request) async =>
      (await _call('execute', [handle, request])).flatMap(_text);

  /// Releases [handle].
  Future<Result<String, DbError>> close(int handle) async =>
      (await _call('close', [handle])).flatMap(_text);

  /// Runs one key-value [call] on [handle].
  Future<Result<String, DbError>> keyValue(
    int handle,
    KeyValueCall call,
    String? argument,
  ) async =>
      (await _call('key_value', [handle, call.index, argument])).flatMap(_text);

  Future<Result<Object?, DbError>> _call(String operation, List<Object?> args) {
    if (_stopped) {
      return Future.value(
        Err(DbError(DbErrorCode.closed, 'The native worker has stopped')),
      );
    }

    final id = _nextId++;
    final completer = Completer<Result<Object?, DbError>>();
    _pending[id] = (operation: operation, completer: completer);
    _commands.send([id, operation, args]);

    return completer.future;
  }

  void _onReply(Object? message) {
    if (message case [final int id, final bool ok, final Object? payload]) {
      final call = _pending.remove(id);
      _countHandles(call?.operation, ok, payload);
      call?.completer.complete(
        ok ? Ok(payload) : Err(DbError(DbErrorCode.nativeLibrary, '$payload')),
      );
      _stopWhenIdle();
    }
  }

  /// Counts the handles a reply opened or closed. It runs before the caller
  /// sees the reply, so the worker never stops between an open and its use.
  void _countHandles(String? operation, bool ok, Object? payload) =>
      _openHandles += switch ((operation, ok, payload)) {
        ('open', true, [final int handle, _]) when handle != 0 => 1,
        ('close', true, _) => -1,
        _ => 0,
      };

  void _stopWhenIdle() {
    if (_openHandles > 0 || _pending.isNotEmpty || _stopped) {
      return;
    }

    _stopped = true;
    _workers.remove(_key);
    _commands.send(const [-1, 'stop', <Object?>[]]);
    _replies.close();
  }

  static Result<String, DbError> _text(Object? reply) => switch (reply) {
    final String text => Ok(text),
    _ => Err(_malformed(reply)),
  };

  static DbError _malformed(Object? reply) =>
      DbError(DbErrorCode.nativeLibrary, 'Unexpected worker reply: $reply');
}

/// A call sent to the worker and waiting for its reply.
typedef _PendingCall = ({
  String operation,
  Completer<Result<Object?, DbError>> completer,
});

/// The native functions, rebuilt inside the worker isolate from their
/// addresses.
final class _NativeCalls {
  _NativeCalls(List<int> addresses)
    : _open = Pointer<NativeFunction<OfcOpen>>.fromAddress(
        addresses[0],
      ).asFunction<_Open>(),
      _execute = Pointer<NativeFunction<OfcExecute>>.fromAddress(
        addresses[1],
      ).asFunction<_HandleString>(),
      _free = Pointer<NativeFunction<OfcFreeString>>.fromAddress(
        addresses[2],
      ).asFunction<_Free>(),
      _close = Pointer<NativeFunction<OfcHandleCall>>.fromAddress(
        addresses[3],
      ).asFunction<_Handle>(),
      _keyValue = addresses.length < 10
          ? null
          : _KeyValueCalls(addresses.sublist(4, 10));

  final _Open _open;
  final _HandleString _execute;
  final _Free _free;
  final _Handle _close;
  final _KeyValueCalls? _keyValue;

  /// Entry point of the worker isolate: serves commands until it is told
  /// to stop.
  static void serve((SendPort, List<int>) start) {
    final (replies, addresses) = start;
    final calls = _NativeCalls(addresses);
    final commands = ReceivePort();
    replies.send(commands.sendPort);

    commands.listen((message) {
      switch (message) {
        // The last database closed: closing the port ends this isolate.
        case [_, 'stop', _]:
          commands.close();
        case [final int id, final String operation, final List<Object?> args]:
          try {
            replies.send([id, true, calls._run(operation, args)]);
          } on Object catch (error) {
            replies.send([id, false, error.toString()]);
          }
      }
    });
  }

  Object _run(String operation, List<Object?> args) => switch ((
    operation,
    args,
  )) {
    ('open', [final String path, final String options]) => _openDatabase(
      path,
      options,
    ),
    ('execute', [final int handle, final String request]) => _take(
      _cString(request, (text) => _execute(Pointer.fromAddress(handle), text)),
    ),
    ('close', [final int handle]) => _take(_close(Pointer.fromAddress(handle))),
    ('key_value', [final int handle, final int call, final String? argument]) =>
      _runKeyValue(handle, KeyValueCall.values[call], argument),
    _ => throw ArgumentError('Unknown worker command $operation $args'),
  };

  List<Object> _openDatabase(String path, String options) {
    final out = malloc<Pointer<Void>>();

    try {
      final response = _cString(
        path,
        (pathText) => _cString(
          options,
          (optionsText) => _open(pathText, optionsText, out),
        ),
      );

      return [out.value.address, _take(response)];
    } finally {
      malloc.free(out);
    }
  }

  String _runKeyValue(int handle, KeyValueCall call, String? argument) {
    final calls = switch (_keyValue) {
      final _KeyValueCalls available => available,
      null => throw StateError('This library has no key-value API'),
    };
    final target = Pointer<Void>.fromAddress(handle);

    String withArgument(_HandleString function) =>
        _take(_cString(argument ?? '', (text) => function(target, text)));

    return switch (call) {
      KeyValueCall.push => withArgument(calls.push),
      KeyValueCall.update => withArgument(calls.update),
      KeyValueCall.getById => withArgument(calls.getById),
      KeyValueCall.deleteById => withArgument(calls.deleteById),
      KeyValueCall.getAll => _take(calls.getAll(target)),
      KeyValueCall.clear => _take(calls.clear(target)),
    };
  }

  /// Passes [value] as a C string to [use], and frees it afterwards.
  static R _cString<R>(String value, R Function(Pointer<Utf8> text) use) {
    final text = value.toNativeUtf8();

    try {
      return use(text);
    } finally {
      malloc.free(text);
    }
  }

  /// Copies a response into Dart and releases it in Rust, exactly once.
  String _take(Pointer<Utf8> response) {
    if (response == nullptr) {
      throw StateError('offline_first_core returned no response');
    }

    try {
      return response.toDartString();
    } finally {
      _free(response);
    }
  }
}

/// The key-value functions, rebuilt from their addresses.
final class _KeyValueCalls {
  _KeyValueCalls(List<int> addresses)
    : push = _withString(addresses[0]),
      update = _withString(addresses[1]),
      getById = _withString(addresses[2]),
      deleteById = _withString(addresses[3]),
      getAll = _onHandle(addresses[4]),
      clear = _onHandle(addresses[5]);

  static _HandleString _withString(int address) =>
      Pointer<NativeFunction<OfcHandleStringCall>>.fromAddress(
        address,
      ).asFunction<_HandleString>();

  static _Handle _onHandle(int address) =>
      Pointer<NativeFunction<OfcHandleCall>>.fromAddress(
        address,
      ).asFunction<_Handle>();

  final _HandleString push;
  final _HandleString update;
  final _HandleString getById;
  final _HandleString deleteById;
  final _Handle getAll;
  final _Handle clear;
}

typedef _Open =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
    );
typedef _HandleString = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>);
typedef _Handle = Pointer<Utf8> Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Utf8>);
