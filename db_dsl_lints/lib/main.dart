/// The entry point the analysis server loads.
///
/// Enable it in `analysis_options.yaml`:
///
/// ```yaml
/// plugins:
///   db_dsl_lints: ^0.1.0
/// ```
library;

import 'src/db_dsl_plugin.dart';

/// The plugin. The analysis server requires this top-level variable by name,
/// so it is the one top-level declaration of the package.
final plugin = DbDslPlugin();
