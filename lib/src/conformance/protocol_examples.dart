/// The request and answer examples of `PROTOCOL.md`, as data: the
/// conformance suite replays them on every engine, and a test checks that
/// the document shows exactly these.
library;

import 'dart:convert';

/// One exchange of the protocol: a request and what the engine answers.
final class ProtocolExample {
  /// An example titled [title]; exactly one of [ok] and [errorCode] is set.
  const ProtocolExample(this.title, this.request, {this.ok, this.errorCode});

  /// What it shows.
  final String title;

  /// The request, as sent on the wire.
  final Map<String, Object?> request;

  /// The `ok` payload of the answer. The string [ProtocolExamples.any]
  /// matches any value, and [ProtocolExamples.transaction] captures the
  /// transaction id that later requests reuse.
  final Map<String, Object?>? ok;

  /// The `code` of an error answer (its message is free text).
  final String? errorCode;

  /// The answer as the wire shows it.
  Map<String, Object?> get answer => switch ((ok, errorCode)) {
    (final Map<String, Object?> payload, _) => {'v': 1, 'ok': payload},
    (_, final String code) => {
      'v': 1,
      'error': {'code': code, 'message': ProtocolExamples.any},
    },
    _ => const {},
  };

  /// The example as it appears in `PROTOCOL.md`.
  String get markdown =>
      '#### $title\n\n'
      '```json\n${_pretty.convert(request)}\n```\n\n'
      '```json\n${_pretty.convert(answer)}\n```\n';

  static const JsonEncoder _pretty = JsonEncoder.withIndent('  ');
}

/// The scenario of `PROTOCOL.md`, in order: each request runs on the state
/// the previous ones left.
abstract final class ProtocolExamples {
  /// Matches any value in an expected answer.
  static const String any = '…';

  /// Stands for the id answered by `begin`, captured and reused.
  static const String transaction = r'$transaction';

  /// Every example, in order.
  static const List<ProtocolExample> scenario = [
    ProtocolExample(
      'Define a table with a composite index and a unique index',
      {
        'v': 1,
        'op': 'define_table',
        'table': {
          'name': 'users',
          'primary_key': 'id',
          'auto_increment': true,
          'indexes': [
            {
              'name': 'by_city_age',
              'fields': ['city', 'age'],
              'unique': false,
            },
            {
              'name': 'by_email',
              'fields': ['email'],
              'unique': true,
            },
          ],
        },
      },
      ok: {'changed': true},
    ),
    ProtocolExample(
      'Define a second table',
      {
        'v': 1,
        'op': 'define_table',
        'table': {
          'name': 'posts',
          'primary_key': 'id',
          'auto_increment': false,
          'indexes': [
            {
              'name': 'by_author',
              'fields': ['author_id'],
              'unique': false,
            },
          ],
        },
      },
      ok: {'changed': true},
    ),
    ProtocolExample(
      'Insert rows; the auto-increment key is generated',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'insert',
          'table': 'users',
          'on_conflict': 'error',
          'rows': [
            {
              'name': 'Ada',
              'email': 'ada@example.com',
              'city': 'Lima',
              'age': 36,
            },
            {
              'name': 'Grace',
              'email': 'grace@example.com',
              'city': 'Bogotá',
              'age': 45,
            },
            {'name': 'Linus', 'email': null, 'city': 'Lima', 'age': 28},
          ],
        },
      },
      ok: {
        'affected': 3,
        'rows': [
          {
            'name': 'Ada',
            'email': 'ada@example.com',
            'city': 'Lima',
            'age': 36,
            'id': 1,
          },
          {
            'name': 'Grace',
            'email': 'grace@example.com',
            'city': 'Bogotá',
            'age': 45,
            'id': 2,
          },
          {'name': 'Linus', 'email': null, 'city': 'Lima', 'age': 28, 'id': 3},
        ],
      },
    ),
    ProtocolExample(
      'A duplicate value of a unique index fails the whole insert',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'insert',
          'table': 'users',
          'rows': [
            {'name': 'Ada II', 'email': 'ada@example.com', 'city': 'Lima'},
          ],
        },
      },
      errorCode: 'UniqueViolation',
    ),
    ProtocolExample(
      'Select with a filter, an order and a limit',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'select',
          'table': 'users',
          'filter': {
            'op': 'and',
            'args': [
              {'op': 'eq', 'field': 'city', 'value': 'Lima'},
              {'op': 'gt', 'field': 'age', 'value': 30},
            ],
          },
          'order': [
            {'field': 'age', 'desc': true},
          ],
          'limit': 10,
        },
      },
      ok: {
        'rows': [
          {
            'name': 'Ada',
            'email': 'ada@example.com',
            'city': 'Lima',
            'age': 36,
            'id': 1,
          },
        ],
      },
    ),
    ProtocolExample(
      'Project two fields, each value once',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'select',
          'table': 'users',
          'order': [
            {'field': 'city', 'desc': false},
          ],
          'fields': ['city'],
          'distinct': true,
        },
      },
      ok: {
        'rows': [
          {'city': 'Bogotá'},
          {'city': 'Lima'},
        ],
      },
    ),
    ProtocolExample(
      'Count and aggregate',
      {
        'v': 1,
        'op': 'batch',
        'statements': [
          {
            'op': 'count',
            'table': 'users',
            'filter': {'op': 'is_null', 'field': 'email'},
          },
          {
            'op': 'aggregate',
            'table': 'users',
            'function': 'avg',
            'field': 'age',
          },
        ],
      },
      ok: {
        'results': [
          {'count': 1},
          {'value': 36.333333333333336},
        ],
      },
    ),
    ProtocolExample(
      'Group by with aggregates and having',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'group',
          'table': 'users',
          'by': ['city'],
          'aggregates': [
            {'function': 'count', 'as': 'people'},
            {'function': 'max', 'field': 'age', 'as': 'oldest'},
          ],
          'having': {'op': 'ge', 'field': 'people', 'value': 2},
        },
      },
      ok: {
        'rows': [
          {'city': 'Lima', 'people': 2, 'oldest': 36},
        ],
      },
    ),
    ProtocolExample(
      'Insert into the second table',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'insert',
          'table': 'posts',
          'rows': [
            {'id': 'p1', 'author_id': 1, 'title': 'Types', 'views': 0},
            {'id': 'p2', 'author_id': 1, 'title': 'Joins'},
          ],
        },
      },
      ok: {
        'affected': 2,
        'rows': [
          {'id': 'p1', 'author_id': 1, 'title': 'Types', 'views': 0},
          {'id': 'p2', 'author_id': 1, 'title': 'Joins'},
        ],
      },
    ),
    ProtocolExample(
      'Left join: every user, with their posts or null',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'join',
          'from': {'table': 'users', 'as': 'users'},
          'joins': [
            {
              'table': 'posts',
              'as': 'posts',
              'kind': 'left',
              'on': {'left': 'users.id', 'right': 'author_id'},
            },
          ],
          'filter': {'op': 'eq', 'field': 'users.city', 'value': 'Lima'},
          'order': [
            {'field': 'posts.id', 'desc': false},
          ],
        },
      },
      ok: {
        'rows': [
          {
            'users': {
              'name': 'Linus',
              'email': null,
              'city': 'Lima',
              'age': 28,
              'id': 3,
            },
            'posts': null,
          },
          {
            'users': {
              'name': 'Ada',
              'email': 'ada@example.com',
              'city': 'Lima',
              'age': 36,
              'id': 1,
            },
            'posts': {'id': 'p1', 'author_id': 1, 'title': 'Types', 'views': 0},
          },
          {
            'users': {
              'name': 'Ada',
              'email': 'ada@example.com',
              'city': 'Lima',
              'age': 36,
              'id': 1,
            },
            'posts': {'id': 'p2', 'author_id': 1, 'title': 'Joins'},
          },
        ],
      },
    ),
    ProtocolExample(
      'Update with a counter; a missing value counts as 0',
      {
        'v': 1,
        'op': 'execute',
        'statement': {
          'op': 'update',
          'table': 'posts',
          'filter': {'op': 'eq', 'field': 'author_id', 'value': 1},
          'set': {'title': 'Updated'},
          'increment': {'views': 1},
          'expect': 2,
        },
      },
      ok: {'affected': 2, 'rows': <Object?>[]},
    ),
    ProtocolExample(
      'Begin a write transaction',
      {'v': 1, 'op': 'begin', 'mode': 'write', 'timeout_ms': 30000},
      ok: {'transaction': transaction},
    ),
    ProtocolExample(
      'Write inside the transaction',
      {
        'v': 1,
        'op': 'tx_execute',
        'transaction': transaction,
        'statement': {
          'op': 'delete',
          'table': 'posts',
          'filter': {'op': 'eq', 'field': 'id', 'value': 'p2'},
        },
      },
      ok: {'affected': 1, 'rows': <Object?>[]},
    ),
    ProtocolExample('Open a savepoint', {
      'v': 1,
      'op': 'savepoint',
      'transaction': transaction,
    }, ok: <String, Object?>{}),
    ProtocolExample('A failed write inside the savepoint', {
      'v': 1,
      'op': 'tx_execute',
      'transaction': transaction,
      'statement': {
        'op': 'insert',
        'table': 'posts',
        'rows': [
          {'id': 'p1', 'author_id': 2, 'title': 'Duplicate'},
        ],
      },
    }, errorCode: 'DuplicateKey'),
    ProtocolExample('Roll the savepoint back; the transaction goes on', {
      'v': 1,
      'op': 'rollback_to',
      'transaction': transaction,
    }, ok: <String, Object?>{}),
    ProtocolExample('Commit', {
      'v': 1,
      'op': 'commit',
      'transaction': transaction,
    }, ok: <String, Object?>{}),
    ProtocolExample(
      'The committed state',
      {
        'v': 1,
        'op': 'execute',
        'statement': {'op': 'find', 'table': 'posts', 'key': 'p1'},
      },
      ok: {
        'row': {'id': 'p1', 'author_id': 1, 'title': 'Updated', 'views': 1},
      },
    ),
    ProtocolExample('A closed transaction cannot be used', {
      'v': 1,
      'op': 'commit',
      'transaction': transaction,
    }, errorCode: 'TransactionClosed'),
    ProtocolExample(
      'Every table definition, in name order',
      {'v': 1, 'op': 'tables'},
      ok: {
        'tables': [
          {
            'name': 'posts',
            'primary_key': 'id',
            'auto_increment': false,
            'indexes': [
              {
                'name': 'by_author',
                'fields': ['author_id'],
                'unique': false,
              },
            ],
          },
          {
            'name': 'users',
            'primary_key': 'id',
            'auto_increment': true,
            'indexes': [
              {
                'name': 'by_city_age',
                'fields': ['city', 'age'],
                'unique': false,
              },
              {
                'name': 'by_email',
                'fields': ['email'],
                'unique': true,
              },
            ],
          },
        ],
      },
    ),
    ProtocolExample(
      'Explain a query; each engine chooses its own plan',
      {
        'v': 1,
        'op': 'explain',
        'query': {
          'table': 'users',
          'filter': {'op': 'eq', 'field': 'city', 'value': 'Lima'},
        },
      },
      ok: {
        'plan': {
          'table': 'users',
          'access': any,
          'index': any,
          'descending': any,
          'presorted': any,
          'exact': any,
        },
      },
    ),
    ProtocolExample(
      'Describe the database',
      {'v': 1, 'op': 'info'},
      ok: {'protocol': 1, 'tables': 2, 'lmdb': any, 'map_size': any},
    ),
    ProtocolExample(
      'Begin a read transaction',
      {'v': 1, 'op': 'begin', 'mode': 'read', 'timeout_ms': 30000},
      ok: {'transaction': transaction},
    ),
    ProtocolExample(
      'Read inside it, from its snapshot',
      {
        'v': 1,
        'op': 'tx_execute',
        'transaction': transaction,
        'statement': {'op': 'count', 'table': 'users'},
      },
      ok: {'count': 3},
    ),
    ProtocolExample('A read transaction refuses writes', {
      'v': 1,
      'op': 'tx_execute',
      'transaction': transaction,
      'statement': {'op': 'delete', 'table': 'users'},
    }, errorCode: 'ReadOnlyTransaction'),
    ProtocolExample('End it', {
      'v': 1,
      'op': 'rollback',
      'transaction': transaction,
    }, ok: <String, Object?>{}),
    ProtocolExample(
      'Begin another write transaction',
      {'v': 1, 'op': 'begin', 'mode': 'write', 'timeout_ms': 30000},
      ok: {'transaction': transaction},
    ),
    ProtocolExample('Open a savepoint in it', {
      'v': 1,
      'op': 'savepoint',
      'transaction': transaction,
    }, ok: <String, Object?>{}),
    ProtocolExample(
      'Write inside the savepoint',
      {
        'v': 1,
        'op': 'tx_execute',
        'transaction': transaction,
        'statement': {
          'op': 'insert',
          'table': 'posts',
          'rows': [
            {'id': 'p9', 'author_id': 1, 'title': 'Kept'},
          ],
        },
      },
      ok: {
        'affected': 1,
        'rows': [
          {'id': 'p9', 'author_id': 1, 'title': 'Kept'},
        ],
      },
    ),
    ProtocolExample(
      'Release the savepoint; its write stays in the transaction',
      {'v': 1, 'op': 'release', 'transaction': transaction},
      ok: <String, Object?>{},
    ),
    ProtocolExample('Roll the whole transaction back', {
      'v': 1,
      'op': 'rollback',
      'transaction': transaction,
    }, ok: <String, Object?>{}),
    ProtocolExample(
      'Nothing of a rolled back transaction is stored',
      {
        'v': 1,
        'op': 'execute',
        'statement': {'op': 'find', 'table': 'posts', 'key': 'p9'},
      },
      ok: {'row': null},
    ),
    ProtocolExample(
      'Drop a table with its rows and indexes',
      {'v': 1, 'op': 'drop_table', 'name': 'posts'},
      ok: {'dropped': true},
    ),
    ProtocolExample(
      'Dropping it again answers false',
      {'v': 1, 'op': 'drop_table', 'name': 'posts'},
      ok: {'dropped': false},
    ),
    ProtocolExample('Another protocol version is refused', {
      'v': 2,
      'op': 'tables',
    }, errorCode: 'UnsupportedProtocol'),
  ];
}
