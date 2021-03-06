// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

String normalizeBuilderKeyDefinition(String builderKey, String packageName) =>
    _normalizeDefinition(builderKey, packageName, '|');

String normalizeBuilderKeyUsage(String builderKey, String packageName) =>
    _normalizeUsage(builderKey, packageName, '|');

String normalizeTargetKeyDefinition(String targetKey, String packageName) =>
    _normalizeDefinition(targetKey, packageName, ':');

String normalizeTargetKeyUsage(String targetKey, String packageName) =>
    _normalizeUsage(targetKey, packageName, ':');

/// Gives a full unique key for [name] used from [packageName].
///
/// If [name] omits the separator we assume it's referring to a target or
/// builder named after a package (which is not this package). If [name] starts
/// with the separator we assume it's referring to a target within the package
/// it's used from.
///
/// For example: If I depend on `angular` from `my_package` it is treated as a
/// dependency on the globally unique `angular:angular`.
String _normalizeUsage(String name, String packageName, String separator) {
  if (name.startsWith(separator)) return '$packageName$name';
  if (!name.contains(separator)) return '$name$separator$name';
  return name;
}

/// Gives a full unique key for [name] definied within [packageName].
///
/// The result is always '$packageName$separator$name since at definition the
/// key must be referring to something within [packageName].
///
/// For example: If I expose a builder `my_builder` within `my_package` it is
/// turned into the globally unique `my_package|my_builder`.
String _normalizeDefinition(String name, String packageName, String separator) {
  if (name.startsWith(separator)) return '$packageName$name';
  if (!name.contains(separator)) return '$packageName$separator$name';
  return name;
}
