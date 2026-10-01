import 'package:db_dsl/db_dsl.dart';
import 'package:test/test.dart';

/// `and`, `or` and `not` build the protocol forms of `PROTOCOL.md`
/// ("Expressions"), as Diesel's `.and()`, `.or()` and `not()` do.
void main() {
  const city = Field<String>('city');
  const age = Field<int>('age');
  final lima = city.eq('Lima');
  final adult = age.ge(18);
  final senior = age.ge(65);

  test('and combines both conditions, flattening nested ands', () {
    expect(lima.and(adult).and(senior).toJson(), {
      'op': 'and',
      'args': [lima.toJson(), adult.toJson(), senior.toJson()],
    });
  });

  test('or keeps either condition, flattening nested ors', () {
    expect(lima.or(adult).or(senior).toJson(), {
      'op': 'or',
      'args': [lima.toJson(), adult.toJson(), senior.toJson()],
    });
  });

  test('not negates the condition', () {
    expect(lima.not().toJson(), {'op': 'not', 'arg': lima.toJson()});
  });

  test('and and or nest without flattening into each other', () {
    expect(lima.and(adult.or(senior)).toJson(), {
      'op': 'and',
      'args': [
        lima.toJson(),
        {
          'op': 'or',
          'args': [adult.toJson(), senior.toJson()],
        },
      ],
    });
  });
}
