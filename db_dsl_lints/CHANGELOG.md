## 0.1.1

Documentation only; no change in behaviour.

- README: "How it works" (how the plugin finds the tables, reads what a
  model stores, compares and writes the fields), and the setup note that
  `flutter analyze` does not report plugin diagnostics: run `dart analyze`.

## 0.1.0

First release: the analyzer plugin of db_dsl.

- Reads what each model stores from its `toJson` (a map literal, a block
  that returns one, or json_serializable's generated `_$TToJson`), from a
  `toJson:` passed to the table, and through nested models.
- `missing_query_fields` (warning): the model stores fields its table does
  not expose as typed getters yet. Fix: *Write the query fields from the
  model*.
- `unknown_field` (error): a `field('...')` or an `Index([...])` names a
  field the model does not store. Fixes: the closest stored name, or
  writing the fields again from the model.
- `field_type_mismatch` (error): a field read as another type than the
  model stores. Fix: the stored type.
- `unknown_key` (error): the `key:` of a table is not a stored field. Fix:
  the closest stored name.
- Assist *Write the query fields of the table*: writes (or rewrites) the
  documented `extension <T>Fields on DbTable<T>`, with the `encode` and
  `decode` of a `DateTime` stored as epoch milliseconds or microseconds.
- Reports nothing for a model it cannot read, and never writes a second
  extension when one already lives in another file.
