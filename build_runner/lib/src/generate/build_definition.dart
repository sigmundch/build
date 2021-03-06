// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:watcher/watcher.dart';

import '../asset/build_cache.dart';
import '../asset/reader.dart';
import '../asset/writer.dart';
import '../asset_graph/exceptions.dart';
import '../asset_graph/graph.dart';
import '../asset_graph/node.dart';
import '../changes/build_script_updates.dart';
import '../logging/logging.dart';
import '../package_graph/package_graph.dart';
import '../util/constants.dart';
import 'exceptions.dart';
import 'options.dart';
import 'phase.dart';

final _logger = new Logger('BuildDefinition');

class BuildDefinition {
  final AssetGraph assetGraph;

  final DigestAssetReader reader;
  final RunnerAssetWriter writer;

  final PackageGraph packageGraph;
  final bool deleteFilesByDefault;
  final ResourceManager resourceManager;

  final BuildScriptUpdates buildScriptUpdates;

  /// Whether or not to run in a mode that conserves RAM at the cost of build
  /// speed.
  final bool enableLowResourcesMode;

  final OnDelete onDelete;

  BuildDefinition._(
      this.assetGraph,
      this.reader,
      this.writer,
      this.packageGraph,
      this.deleteFilesByDefault,
      this.resourceManager,
      this.buildScriptUpdates,
      this.enableLowResourcesMode,
      this.onDelete);

  static Future<BuildDefinition> prepareWorkspace(
          BuildOptions options, List<BuildAction> buildActions,
          {void onDelete(AssetId id)}) =>
      new _Loader(options, buildActions, onDelete).prepareWorkspace();
}

class _Loader {
  final List<BuildAction> _buildActions;
  final BuildOptions _options;
  final OnDelete _onDelete;

  _Loader(this._options, this._buildActions, this._onDelete);

  Future<BuildDefinition> prepareWorkspace() async {
    _checkBuildActions();

    _logger.info('Initializing inputs');
    var inputSources = await _findInputSources();
    var cacheDirSources = await _findCacheDirSources();
    var internalSources = await _findInternalSources();

    var assetGraph = await _tryReadCachedAssetGraph();

    BuildScriptUpdates buildScriptUpdates;
    if (assetGraph != null) {
      var updates = await logTimedAsync(
          _logger,
          'Checking for updates since last build',
          () => _updateAssetGraph(assetGraph, _buildActions, inputSources,
              cacheDirSources, internalSources));

      buildScriptUpdates =
          await BuildScriptUpdates.create(_options, assetGraph);
      if (!_options.skipBuildScriptCheck &&
          buildScriptUpdates.hasBeenUpdated(updates.keys.toSet())) {
        _logger.warning('Invalidating asset graph due to build script update');
        await _deleteGeneratedDir();
        assetGraph = null;
        buildScriptUpdates = null;
      }
    }

    if (assetGraph == null) {
      Set<AssetId> conflictingOutputs;

      await logTimedAsync(_logger, 'Building new asset graph', () async {
        assetGraph = await AssetGraph.build(_buildActions, inputSources,
            internalSources, _options.packageGraph, _options.reader);
        buildScriptUpdates =
            await BuildScriptUpdates.create(_options, assetGraph);
        conflictingOutputs = assetGraph.outputs
            .where((n) => n.package == _options.packageGraph.root.name)
            .where(inputSources.contains)
            .toSet();
        final conflictsInDeps = assetGraph.outputs
            .where((n) => n.package != _options.packageGraph.root.name)
            .where(inputSources.contains)
            .toSet();
        if (conflictsInDeps.isNotEmpty) {
          throw new UnexpectedExistingOutputsException(conflictsInDeps);
        }
      });

      await logTimedAsync(
          _logger,
          'Checking for unexpected pre-existing outputs.',
          () => _initialBuildCleanup(
              conflictingOutputs, _wrapWriter(_options.writer, assetGraph),
              deleteFilesByDefault: _options.deleteFilesByDefault,
              assumeTty: _options.assumeTty));
    }

    return new BuildDefinition._(
        assetGraph,
        _wrapReader(_options.reader, assetGraph),
        _wrapWriter(_options.writer, assetGraph),
        _options.packageGraph,
        _options.deleteFilesByDefault,
        new ResourceManager(),
        buildScriptUpdates,
        _options.enableLowResourcesMode,
        _onDelete);
  }

  /// Checks that the [_buildActions] are valid based on whether they are
  /// written to the build cache.
  void _checkBuildActions() {
    final root = _options.packageGraph.root.name;
    for (final action in _buildActions) {
      if (!action.hideOutput &&
          action.package != _options.packageGraph.root.name) {
        throw new InvalidBuildActionException.nonRootPackage(action, root);
      }
    }
  }

  /// Deletes the generated output directory.
  ///
  /// Typically this should be done whenever an asset graph is thrown away.
  Future<Null> _deleteGeneratedDir() async {
    var generatedDir = new Directory(generatedOutputDirectory);
    if (await generatedDir.exists()) {
      await generatedDir.delete(recursive: true);
    }
  }

  /// Returns the all the sources found in the cache directory.
  Future<Set<AssetId>> _findCacheDirSources() =>
      _listGeneratedAssetIds().toSet();

  /// Returns all the internal sources, such as those under [entryPointDir].
  Future<Set<AssetId>> _findInternalSources() {
    return _options.reader.findAssets(new Glob('$entryPointDir/**')).toSet();
  }

  /// Attempts to read in an [AssetGraph] from disk, and returns `null` if it
  /// fails for any reason.
  Future<AssetGraph> _tryReadCachedAssetGraph() async {
    final assetGraphId =
        new AssetId(_options.packageGraph.root.name, assetGraphPath);
    if (!await _options.reader.canRead(assetGraphId)) {
      return null;
    }

    return logTimedAsync(_logger, 'Reading cached asset graph', () async {
      try {
        var cachedGraph = new AssetGraph.deserialize(JSON
            .decode(await _options.reader.readAsString(assetGraphId)) as Map);
        if (computeBuildActionsDigest(_buildActions) !=
            cachedGraph.buildActionsDigest) {
          _logger.warning(
              'Throwing away cached asset graph because the build actions have '
              'changed. This could happen as a result of adding a new '
              'dependency, or if you are using a build script which changes '
              'the build structure based on command line flags or other '
              'configuration.');
          return null;
        }
        return cachedGraph;
      } on AssetGraphVersionException catch (_) {
        // Start fresh if the cached asset_graph version doesn't match up with
        // the current version. We don't currently support old graph versions.
        _logger.warning(
            'Throwing away cached asset graph due to version mismatch.');
        await _deleteGeneratedDir();
        return null;
      }
    });
  }

  /// Updates [assetGraph] based on a the new view of the world.
  ///
  /// Once done, this returns a map of [AssetId] to [ChangeType] for all the
  /// changes.
  Future<Map<AssetId, ChangeType>> _updateAssetGraph(
      AssetGraph assetGraph,
      List<BuildAction> buildActions,
      Set<AssetId> inputSources,
      Set<AssetId> cacheDirSources,
      Set<AssetId> internalSources) async {
    var updates = await _findSourceUpdates(
        assetGraph, inputSources, cacheDirSources, internalSources);
    updates.addAll(_computeBuilderOptionsUpdates(assetGraph, buildActions));
    await assetGraph.updateAndInvalidate(
        _buildActions,
        updates,
        _options.packageGraph.root.name,
        (id) => _delete(id, _wrapWriter(_options.writer, assetGraph)),
        _wrapReader(_options.reader, assetGraph));
    return updates;
  }

  /// Wraps [original] in a [BuildCacheWriter].
  RunnerAssetWriter _wrapWriter(
      RunnerAssetWriter original, AssetGraph assetGraph) {
    assert(assetGraph != null);
    return new BuildCacheWriter(
        original, assetGraph, _options.packageGraph.root.name);
  }

  /// Wraps [original] in a [BuildCacheReader].
  DigestAssetReader _wrapReader(
      DigestAssetReader original, AssetGraph assetGraph) {
    assert(assetGraph != null);
    return new BuildCacheReader(
        original, assetGraph, _options.packageGraph.root.name);
  }

  /// Finds the asset changes which have happened while unwatched between builds
  /// by taking a difference between the assets in the graph and the assets on
  /// disk.
  Future<Map<AssetId, ChangeType>> _findSourceUpdates(
      AssetGraph assetGraph,
      Set<AssetId> inputSources,
      Set<AssetId> generatedSources,
      Set<AssetId> internalSources) async {
    final allSources = new Set<AssetId>()
      ..addAll(inputSources)
      ..addAll(generatedSources)
      ..addAll(internalSources);
    var updates = <AssetId, ChangeType>{};
    addUpdates(Iterable<AssetId> assets, ChangeType type) {
      for (var asset in assets) {
        updates[asset] = type;
      }
    }

    var newSources = inputSources.difference(assetGraph.allNodes
        .where((node) => node.isValidInput)
        .map((node) => node.id)
        .toSet());
    addUpdates(newSources, ChangeType.ADD);
    var removedAssets = assetGraph.allNodes
        .where((n) {
          if (!n.isReadable) return false;
          if (n is GeneratedAssetNode) return n.wasOutput;
          return true;
        })
        .map((n) => n.id)
        .where((id) => !allSources.contains((id)));

    addUpdates(removedAssets, ChangeType.REMOVE);

    var originalGraphSources = assetGraph.sources.toSet();
    var preExistingSources = originalGraphSources.intersection(inputSources)
      ..addAll(internalSources.where((id) => assetGraph.contains(id)));
    var modifyChecks = preExistingSources.map((id) async {
      var node = assetGraph.get(id);
      if (node == null) throw id;
      var originalDigest = node.lastKnownDigest;
      if (originalDigest == null) return;
      var currentDigest = await _options.reader.digest(id);
      if (currentDigest != originalDigest) {
        updates[id] = ChangeType.MODIFY;
      }
    });
    await Future.wait(modifyChecks);
    return updates;
  }

  /// Checks for any updates to the [BuilderOptionsAssetNode]s for
  /// [buildActions] compared to the last known state.
  Map<AssetId, ChangeType> _computeBuilderOptionsUpdates(
      AssetGraph assetGraph, List<BuildAction> buildActions) {
    var result = <AssetId, ChangeType>{};
    for (var phase = 0; phase < buildActions.length; phase++) {
      var action = buildActions[phase];
      var builderOptionsId = builderOptionsIdForPhase(action.package, phase);
      var builderOptionsNode =
          assetGraph.get(builderOptionsId) as BuilderOptionsAssetNode;
      var oldDigest = builderOptionsNode.lastKnownDigest;
      builderOptionsNode.lastKnownDigest =
          computeBuilderOptionsDigest(action.builderOptions);
      if (builderOptionsNode.lastKnownDigest != oldDigest) {
        result[builderOptionsId] = ChangeType.MODIFY;
      }
    }
    return result;
  }

  /// Returns the set of original package inputs on disk.
  Future<Set<AssetId>> _findInputSources() {
    final packageNames = new Stream<PackageNode>.fromIterable(
        _options.packageGraph.allPackages.values);
    return packageNames.asyncExpand(_listAssetIds).toSet();
  }

  Stream<AssetId> _listAssetIds(PackageNode package) async* {
    for (final glob in _packageIncludes(package)) {
      yield* _options.reader.findAssets(new Glob(glob), package: package.name);
    }
  }

  List<String> _packageIncludes(PackageNode package) => package.isRoot
      ? rootPackageFilesWhitelist
      : package.name == r'$sdk'
          ? const ['lib/dev_compiler/**.js']
          : const ['lib/**'];

  Stream<AssetId> _listGeneratedAssetIds() async* {
    var glob = new Glob('$generatedOutputDirectory/**');
    await for (var id in _options.reader.findAssets(glob)) {
      var packagePath = id.path.substring(generatedOutputDirectory.length + 1);
      var firstSlash = packagePath.indexOf('/');
      var package = packagePath.substring(0, firstSlash);
      var path = packagePath.substring(firstSlash + 1);
      yield new AssetId(package, path);
    }
  }

  /// Handles cleanup of pre-existing outputs for initial builds (where there is
  /// no cached graph).
  Future<Null> _initialBuildCleanup(
      Set<AssetId> conflictingAssets, RunnerAssetWriter writer,
      {@required bool deleteFilesByDefault, @required bool assumeTty}) async {
    if (conflictingAssets.isEmpty) return;

    // Skip the prompt if using this option.
    if (deleteFilesByDefault) {
      _logger.info('Deleting ${conflictingAssets.length} declared outputs '
          'which already existed on disk.');
      await Future.wait(conflictingAssets.map((id) => _delete(id, writer)));
      return;
    }

    // Prompt the user to delete files that are declared as outputs.
    _logger.info('Found ${conflictingAssets.length} declared outputs '
        'which already exist on disk. This is likely because the'
        '`$cacheDir` folder was deleted, or you are submitting generated '
        'files to your source repository.');

    // If not in a standard terminal then we just exit, since there is no way
    // for the user to provide a yes/no answer.
    bool runningInPubRunTest() => Platform.script.scheme == 'data';
    if (!assumeTty &&
        (stdioType(stdin) != StdioType.TERMINAL || runningInPubRunTest())) {
      throw new UnexpectedExistingOutputsException(conflictingAssets);
    }

    // Give a little extra space after the last message, need to make it clear
    // this is a prompt.
    stdout.writeln();
    var done = false;
    while (!done) {
      stdout.write('\nDelete these files (y/n) (or list them (l))?: ');
      var input = stdin.readLineSync();
      switch (input.toLowerCase()) {
        case 'y':
          stdout.writeln('Deleting files...');
          done = true;
          await Future.wait(conflictingAssets.map((id) => _delete(id, writer)));
          break;
        case 'n':
          throw new UnexpectedExistingOutputsException(conflictingAssets);
          break;
        case 'l':
          for (var output in conflictingAssets) {
            stdout.writeln(output);
          }
          break;
        default:
          stdout.writeln('Unrecognized option $input, (y/n/l) expected.');
      }
    }
  }

  Future _delete(AssetId id, RunnerAssetWriter writer) {
    _onDelete?.call(id);
    return writer.delete(id);
  }
}
