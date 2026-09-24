import fs from 'node:fs';

const COLLECTION_KINDS = new Map([
  ['systems', 'System'],
  ['bodies', 'Body'],
  ['biomes', 'Biome'],
  ['materialfamilies', 'MaterialFamily'],
  ['environments', 'Environment'],
  ['terrainfeatures', 'TerrainFeature'],
  ['regions', 'Region'],
  ['dressings', 'EnvironmentDressing'],
  ['dressingoverrides', 'EnvironmentDressingOverride'],
  ['nonheightfieldgeometry', 'EnvironmentGeometry'],
]);

function normalizeKey(value) {
  return String(value ?? '').replaceAll('_', '').toLowerCase();
}

function getField(object, ...names) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) {
    return undefined;
  }
  const wanted = new Set(names.map(normalizeKey));
  for (const [key, value] of Object.entries(object)) {
    if (wanted.has(normalizeKey(key))) {
      return value;
    }
  }
  return undefined;
}

export function persistentIdValue(value) {
  if (typeof value === 'string') {
    return value;
  }
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    const nested = getField(value, 'value');
    return typeof nested === 'string' ? nested : '';
  }
  return '';
}

function stringField(object, ...names) {
  const value = getField(object, ...names);
  if (typeof value === 'string') {
    return value;
  }
  return persistentIdValue(value);
}

function numberField(object, ...names) {
  const value = getField(object, ...names);
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function entityMetadata(kind, definition, context) {
  const persistentId = persistentIdValue(getField(definition, 'persistentId'));
  const ownEnvironmentId = stringField(definition, 'environmentId');
  const ownBodyId = stringField(definition, 'bodyId');

  return {
    kind,
    persistentId,
    environmentId: ownEnvironmentId || context.environmentId || '',
    systemId: context.systemId || '',
    bodyId: ownBodyId || context.bodyId || '',
    definition,
  };
}

function childContext(kind, entity, parentContext) {
  const context = { ...parentContext };
  if (kind === 'System') {
    context.systemId = entity.persistentId;
  } else if (kind === 'Body') {
    context.bodyId = entity.persistentId;
  } else if (kind === 'Environment') {
    context.environmentId = entity.persistentId;
    context.bodyId = '';
    context.systemId = '';
  }
  return context;
}

function collectLogicalEntities(object, context, output) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) {
    return;
  }

  for (const [key, value] of Object.entries(object)) {
    if (!Array.isArray(value)) {
      continue;
    }

    const kind = COLLECTION_KINDS.get(normalizeKey(key));
    if (!kind) {
      continue;
    }

    for (const definition of value) {
      if (!definition || typeof definition !== 'object' || Array.isArray(definition)) {
        continue;
      }
      const entity = entityMetadata(kind, definition, context);
      if (!entity.persistentId) {
        continue;
      }
      output.push(entity);
      collectLogicalEntities(definition, childContext(kind, entity, context), output);
    }
  }
}

export function loadWorldSnapshot(snapshotPath) {
  if (!snapshotPath) {
    throw new Error('Le chemin du snapshot World Director n\'est pas configuré.');
  }

  let text;
  try {
    text = fs.readFileSync(snapshotPath, 'utf8');
  } catch (error) {
    throw new Error(`Snapshot World Director illisible : ${error.message}`);
  }

  let root;
  try {
    root = JSON.parse(text);
  } catch (error) {
    throw new Error(`Snapshot World Director invalide : ${error.message}`);
  }

  const world = getField(root, 'world') ?? root;
  if (!world || typeof world !== 'object' || Array.isArray(world)) {
    throw new Error('Le snapshot World Director ne contient pas de WorldState exploitable.');
  }
  return world;
}

export function indexWorld(world) {
  const entities = [];
  collectLogicalEntities(world, { environmentId: '', systemId: '', bodyId: '' }, entities);
  return entities;
}

function compactProperties(entity) {
  const definition = entity.definition;
  const properties = {};
  const copyString = (targetName, ...sourceNames) => {
    const value = stringField(definition, ...sourceNames);
    if (value) properties[targetName] = value;
  };
  const copyNumber = (targetName, ...sourceNames) => {
    const value = numberField(definition, ...sourceNames);
    if (value !== undefined) properties[targetName] = value;
  };

  copyString('displayName', 'displayName');
  copyString('type', 'type', 'semanticType');
  copyString('assetId', 'assetId');
  copyString('regionId', 'regionId');
  copyString('biomeId', 'biomeId');
  copyString('materialFamilyId', 'materialFamilyId');
  copyString('targetDressingId', 'targetDressingId');

  copyNumber('centerXMeters', 'centerXMeters', 'environmentCenterXMeters');
  copyNumber('centerYMeters', 'centerYMeters', 'environmentCenterYMeters');
  copyNumber('elevationOffsetMeters', 'elevationOffsetMeters');
  copyNumber('radiusMeters', 'radiusMeters');
  copyNumber('widthMeters', 'widthMeters');
  copyNumber('depthMeters', 'depthMeters');
  copyNumber('heightMeters', 'heightMeters');
  copyNumber('yawDegrees', 'yawDegrees');
  copyNumber('compositionOrder', 'compositionOrder');
  copyNumber('seed', 'seed');
  copyNumber('density', 'density');
  copyNumber('densityMultiplier', 'densityMultiplier');

  if (entity.kind === 'Environment') {
    const terrain = getField(definition, 'terrain');
    const hasTerrain = getField(definition, 'bHasTerrain', 'hasTerrain');
    if (typeof hasTerrain === 'boolean') properties.hasTerrain = hasTerrain;
    if (terrain && typeof terrain === 'object' && !Array.isArray(terrain)) {
      const requestedWidthMeters = numberField(terrain, 'requestedWidthMeters', 'widthMeters');
      const requestedHeightMeters = numberField(terrain, 'requestedHeightMeters', 'heightMeters');
      const profile = stringField(terrain, 'profile');
      properties.terrain = {
        ...(requestedWidthMeters !== undefined ? { requestedWidthMeters } : {}),
        ...(requestedHeightMeters !== undefined ? { requestedHeightMeters } : {}),
        ...(profile ? { profile } : {}),
      };
    }
  }

  return properties;
}

export function getWorldSummary(snapshotPath) {
  const world = loadWorldSnapshot(snapshotPath);
  const entities = indexWorld(world);
  const entityCounts = {};
  for (const entity of entities) {
    entityCounts[entity.kind] = (entityCounts[entity.kind] ?? 0) + 1;
  }

  const environments = entities
    .filter((entity) => entity.kind === 'Environment')
    .map((environment) => {
      const localCounts = {};
      for (const entity of entities) {
        if (entity.environmentId === environment.persistentId && entity.kind !== 'Environment') {
          localCounts[entity.kind] = (localCounts[entity.kind] ?? 0) + 1;
        }
      }
      const properties = compactProperties(environment);
      return {
        persistentId: environment.persistentId,
        displayName: stringField(environment.definition, 'displayName'),
        ...(properties.hasTerrain !== undefined ? { hasTerrain: properties.hasTerrain } : {}),
        ...(properties.terrain ? { terrain: properties.terrain } : {}),
        entityCounts: localCounts,
      };
    });

  return {
    source: 'WorldStateSnapshot',
    totalEntities: entities.length,
    entityCounts,
    environments,
  };
}

export function listEntities(snapshotPath, { kind = '', environmentId = '' } = {}) {
  const world = loadWorldSnapshot(snapshotPath);
  const normalizedKind = normalizeKey(kind);
  const entities = indexWorld(world).filter((entity) => {
    if (normalizedKind && normalizeKey(entity.kind) !== normalizedKind) {
      return false;
    }
    if (environmentId && entity.environmentId !== environmentId) {
      return false;
    }
    return true;
  });

  return {
    count: entities.length,
    entities: entities.map((entity) => ({
      persistentId: entity.persistentId,
      kind: entity.kind,
      ...(entity.environmentId ? { environmentId: entity.environmentId } : {}),
      ...(entity.systemId ? { systemId: entity.systemId } : {}),
      ...(entity.bodyId ? { bodyId: entity.bodyId } : {}),
      properties: compactProperties(entity),
    })),
  };
}

export function getEntity(snapshotPath, id) {
  if (typeof id !== 'string' || !id.trim()) {
    throw new Error('get_entity requiert un id non vide.');
  }

  const world = loadWorldSnapshot(snapshotPath);
  const matches = indexWorld(world).filter((entity) => entity.persistentId === id);
  if (matches.length === 0) {
    return {
      found: false,
      diagnostic: `Aucune entité World Director ne possède le PersistentId '${id}'.`,
    };
  }
  if (matches.length > 1) {
    return {
      found: false,
      ambiguous: true,
      diagnostic: `Le PersistentId '${id}' est ambigu dans le snapshot (${matches.length} entités).`,
      matches: matches.map((entity) => ({ kind: entity.kind, persistentId: entity.persistentId })),
    };
  }

  const entity = matches[0];
  return {
    found: true,
    persistentId: entity.persistentId,
    kind: entity.kind,
    ...(entity.environmentId ? { environmentId: entity.environmentId } : {}),
    ...(entity.systemId ? { systemId: entity.systemId } : {}),
    ...(entity.bodyId ? { bodyId: entity.bodyId } : {}),
    definition: entity.definition,
  };
}
