/// The analyzer plugin of db_dsl.
library;

import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'corrections/add_query_fields.dart';
import 'corrections/field_fixes.dart';
import 'rules/table_fields_rule.dart';

/// Registers the rule that checks table fields against their models, its
/// fixes, and the assist that writes the fields of a table.
final class DbDslPlugin extends Plugin {
  @override
  String get name => 'db_dsl';

  @override
  void register(PluginRegistry registry) {
    registry
      ..registerWarningRule(TableFieldsRule())
      ..registerFixForRule(TableFieldsRule.unknownField, UseClosestField.new)
      ..registerFixForRule(TableFieldsRule.unknownField, RewriteQueryFields.new)
      ..registerFixForRule(
        TableFieldsRule.missingQueryFields,
        RewriteQueryFields.new,
      )
      ..registerFixForRule(TableFieldsRule.unknownKey, UseClosestField.new)
      ..registerFixForRule(TableFieldsRule.fieldTypeMismatch, UseStoredType.new)
      ..registerAssist(AddQueryFields.new);
  }
}
