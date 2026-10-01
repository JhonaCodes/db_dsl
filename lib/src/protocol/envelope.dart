/// The envelope of every answer on the wire (`PROTOCOL.md`, "Envelope").
library;

import 'dart:convert';

import 'package:result_controller/result_controller.dart';

import '../errors/db_error.dart';
import 'request.dart';

/// Encodes and decodes the JSON envelope an engine answers on the wire:
/// `{"v": 1, "ok": <payload>}` or
/// `{"v": 1, "error": {"code": "<Code>", "message": "..."}}`.
///
/// Why it is public: engines that speak JSON strings (the native one, or a
/// translator over a socket) all need the same envelope; writing it once
/// keeps every side byte-compatible.
abstract final class ProtocolEnvelope {
  /// The payload or error of a JSON [response].
  static Result<Map<String, Object?>, DbError> decode(String response) {
    final Object? json;

    try {
      json = jsonDecode(response);
    } on FormatException catch (error) {
      return Err(
        DbError(
          DbErrorCode.unsupportedProtocol,
          'The engine answered something that is not JSON: $error',
        ),
      );
    }

    return switch (json) {
      {'v': ProtocolRequest.version, 'ok': final Map<String, Object?> ok} => Ok(
        ok,
      ),
      {
        'v': ProtocolRequest.version,
        'error': {'code': final String code, 'message': final String message},
      } =>
        Err(DbError.fromWire(code, message)),
      _ => Err(
        DbError(
          DbErrorCode.unsupportedProtocol,
          'The engine answered outside the envelope: $response',
        ),
      ),
    };
  }

  /// The JSON answer carrying [payload].
  static String ok(Map<String, Object?> payload) =>
      jsonEncode({'v': ProtocolRequest.version, 'ok': payload});

  /// The JSON answer carrying [error].
  static String error(DbError error) => jsonEncode({
    'v': ProtocolRequest.version,
    'error': {'code': error.wireCode, 'message': error.message},
  });
}
