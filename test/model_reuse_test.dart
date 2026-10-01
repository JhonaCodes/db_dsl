import 'package:db_dsl/db_dsl.dart';
import 'package:test/test.dart';

/// A model an app already has (from an API, with its own `fromJson` and
/// `toJson`) is a table in one line, and every field type filters by the
/// form the model stores.
void main() {
  late MemoryEngine engine;
  var next = 0;

  setUp(() => engine = MemoryEngine());

  Future<Database> open(List<DbTable<Object?>> tables) async =>
      value(await Database.open(engine, path: 'm-${next++}', tables: tables));

  group('a model of an API', () {
    late DbTable<Member> members;

    setUp(
      () => members = DbTable<Member>(
        'members',
        key: 'id',
        fromJson: Member.fromJson,
        autoIncrement: true,
        indexes: [
          Index(['status', 'joined']),
        ],
      ),
    );

    test('is stored and read back as it writes itself', () async {
      final db = await open([members]);

      final stored = value(await members.insert(Member.all).getResults());
      expect(stored.map((member) => member.id), [1, 2, 3]);
      expect(value(await members.find(2)), Member.all[1].copyWith(id: 2));
      await db.close();
    });

    test('is filtered by its enum, its date and a nested field', () async {
      final db = await open([members]);
      value(await members.insert(Member.all));

      final status = members.field<Status>('status');
      final joined = members.field<DateTime>('joined');
      final city = members.field<String>('address.city');

      expect(names(value(await members.filter(status.eq(Status.active)))), [
        'Ada',
        'Linus',
      ]);
      expect(
        names(value(await members.filter(joined.gt(DateTime.utc(2024))))),
        ['Grace', 'Linus'],
      );
      expect(names(value(await members.filter(city.eq('Bogotá')))), ['Grace']);
      expect(
        value(
          await members.all().order(joined.asc()).pluck(joined),
        ).map((date) => date?.year),
        [2023, 2024, 2025],
      );
      await db.close();
    });
  });

  test('a serializer with another name is passed once', () async {
    final notes = DbTable<Note>(
      'notes',
      key: 'id',
      fromJson: Note.fromMap,
      toJson: (note) => note.toMap(),
    );
    final db = await open([notes]);

    value(await notes.insert(Note.all));

    expect(
      value(
        await notes.filter(notes.field<Status>('status').eq(Status.archived)),
      ).map((note) => note.id),
      ['n2'],
    );
    expect(value(await notes.find('n1')), Note.all.first);
    await db.close();
  });

  test('a field of a custom type encodes and decodes as told', () async {
    final products = DbTable<Product>(
      'products',
      key: 'sku',
      fromJson: Product.fromJson,
    );
    final price = products.field<Money>(
      'price',
      encode: (money) => money.cents,
      decode: (stored) => Money(stored as int),
    );
    final db = await open([products]);

    value(await products.insert(Product.all));

    expect(
      value(
        await products.filter(price.gt(const Money(1000))),
      ).map((product) => product.sku),
      ['b'],
    );
    expect(value(await products.all().order(price.asc()).pluck(price)), [
      const Money(500),
      const Money(2500),
    ]);
    await db.close();
  });

  test('a row JSON cannot hold is an error, not an exception', () async {
    final bare = DbTable<Bare>('bare', key: 'id', fromJson: Bare.fromJson);
    final odd = DbTable<Bare>(
      'odd',
      key: 'id',
      fromJson: Bare.fromJson,
      toJson: (row) => {'id': row.id, 'handle': Object()},
    );
    final db = await open([bare, odd]);

    expect(code(await bare.insert(const [Bare('a')])), DbErrorCode.rowMapping);
    expect(code(await odd.insert(const [Bare('a')])), DbErrorCode.rowMapping);
    expect(
      code(
        await db.atomicBatch([
          bare.insert(const [Bare('a')]),
        ]),
      ),
      DbErrorCode.rowMapping,
    );
    await db.close();
  });

  test('indexes are named after their fields', () {
    expect(const Index(['city', 'age']).name, 'by_city_age');
    expect(const Index.unique(['email']).name, 'unique_email');
    expect(const Index(['address.city']).name, 'by_address_city');
    expect(const Index(['city'], name: 'cities').name, 'cities');
  });
}

/// The value of an `Ok`; fails the test on an `Err`.
T value<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => data, err: (error) => fail('Err: $error'));

/// The code of an `Err`; fails the test on an `Ok`.
DbErrorCode code<T>(Result<T, DbError> result) =>
    result.when(ok: (data) => fail('Ok: $data'), err: (error) => error.code);

List<String> names(List<Member> members) => [
  for (final member in members) member.name,
];

enum Status { active, archived }

/// A nested model with its own `toJson`, left as an object by its parent's
/// `toJson` (as json_serializable does without `explicitToJson`).
final class Address {
  const Address(this.city, this.zip);

  factory Address.fromJson(Map<String, dynamic> json) =>
      Address(json['city'] as String, json['zip'] as String);

  final String city;
  final String zip;

  Map<String, dynamic> toJson() => {'city': city, 'zip': zip};

  @override
  bool operator ==(Object other) =>
      other is Address && other.city == city && other.zip == zip;

  @override
  int get hashCode => Object.hash(city, zip);
}

/// A model as an API client writes it: enum by name, dates in ISO 8601, a
/// nested object, a list, and a key the database generates.
final class Member {
  const Member({
    required this.name,
    required this.status,
    required this.joined,
    required this.address,
    this.id,
    this.tags = const [],
  });

  factory Member.fromJson(Map<String, dynamic> json) => Member(
    id: json['id'] as int?,
    name: json['name'] as String,
    status: Status.values.byName(json['status'] as String),
    joined: DateTime.parse(json['joined'] as String),
    address: Address.fromJson(json['address'] as Map<String, dynamic>),
    tags: (json['tags'] as List<dynamic>).cast<String>(),
  );

  static final List<Member> all = [
    Member(
      name: 'Ada',
      status: Status.active,
      joined: DateTime.utc(2023, 5, 1),
      address: const Address('Lima', '15001'),
      tags: const ['math'],
    ),
    Member(
      name: 'Grace',
      status: Status.archived,
      joined: DateTime.utc(2024, 2, 1),
      address: const Address('Bogotá', '110111'),
    ),
    Member(
      name: 'Linus',
      status: Status.active,
      joined: DateTime.utc(2025, 1, 1),
      address: const Address('Lima', '15002'),
      tags: const ['kernel', 'git'],
    ),
  ];

  final int? id;
  final String name;
  final Status status;
  final DateTime joined;
  final Address address;
  final List<String> tags;

  Member copyWith({int? id}) => Member(
    id: id ?? this.id,
    name: name,
    status: status,
    joined: joined,
    address: address,
    tags: tags,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'status': status.name,
    'joined': joined.toIso8601String(),
    'address': address,
    'tags': tags,
  };

  @override
  bool operator ==(Object other) =>
      other is Member &&
      other.id == id &&
      other.name == name &&
      other.status == status &&
      other.joined == joined &&
      other.address == address &&
      other.tags.join(',') == tags.join(',');

  @override
  int get hashCode => Object.hash(id, name, status, joined, address);

  @override
  String toString() => 'Member($id, $name)';
}

/// A model whose serializer has another name and leaves an enum and a date
/// as Dart values.
final class Note {
  const Note(this.id, this.status, this.at);

  factory Note.fromMap(Map<String, Object?> map) => Note(
    map['id']! as String,
    Status.values.byName(map['status']! as String),
    DateTime.parse(map['at']! as String),
  );

  static final List<Note> all = [
    Note('n1', Status.active, DateTime.utc(2025, 3, 1)),
    Note('n2', Status.archived, DateTime.utc(2025, 4, 1)),
  ];

  final String id;
  final Status status;
  final DateTime at;

  Map<String, Object?> toMap() => {'id': id, 'status': status, 'at': at};

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.id == id &&
      other.status == status &&
      other.at == at;

  @override
  int get hashCode => Object.hash(id, status, at);
}

/// A value object the model stores as an integer number of cents.
final class Money {
  const Money(this.cents);

  final int cents;

  @override
  bool operator ==(Object other) => other is Money && other.cents == cents;

  @override
  int get hashCode => cents.hashCode;

  @override
  String toString() => 'Money($cents)';
}

final class Product {
  const Product(this.sku, this.price);

  factory Product.fromJson(Map<String, dynamic> json) =>
      Product(json['sku'] as String, Money(json['price'] as int));

  static const List<Product> all = [
    Product('a', Money(500)),
    Product('b', Money(2500)),
  ];

  final String sku;
  final Money price;

  Map<String, dynamic> toJson() => {'sku': sku, 'price': price.cents};
}

/// A model without `toJson`.
final class Bare {
  const Bare(this.id);

  factory Bare.fromJson(Map<String, dynamic> json) =>
      Bare(json['id'] as String);

  final String id;
}
