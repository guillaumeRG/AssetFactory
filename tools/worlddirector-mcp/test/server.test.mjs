import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { TOOL_DEFINITIONS, handleRequest } from '../server.mjs';
import { getEntity, getWorldSummary, listEntities } from '../world-state.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = path.join(here, 'fixtures', 'world_state.json');

test('get_world_summary compte les entités logiques', () => {
  const summary = getWorldSummary(fixture);
  assert.equal(summary.entityCounts.Environment, 1);
  assert.equal(summary.entityCounts.EnvironmentGeometry, 6);
  assert.equal(summary.entityCounts.TerrainFeature, 1);
  assert.equal(summary.entityCounts.EnvironmentDressing, 1);
  assert.equal(summary.entityCounts.Biome, 1);
});

test('list_entities retourne exactement les six EnvironmentGeometry', () => {
  const result = listEntities(fixture, { kind: 'EnvironmentGeometry', environmentId: 'Environment_001' });
  assert.equal(result.count, 6);
  assert.deepEqual(result.entities.map((entity) => entity.persistentId), [
    'Geometry_001', 'Geometry_002', 'Geometry_003', 'Geometry_004', 'Geometry_005', 'Geometry_006',
  ]);
});

test('list_entities expose les dimensions du terrain Environment pour un placement global', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'worlddirector-mcp-'));
  const terrainFixture = path.join(directory, 'world_state.json');
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const world = JSON.parse(fs.readFileSync(fixture, 'utf8'));
  world.environments[0].bHasTerrain = true;
  world.environments[0].terrain = {
    requestedWidthMeters: 2000,
    requestedHeightMeters: 2000,
    profile: 'Hills',
  };
  fs.writeFileSync(terrainFixture, JSON.stringify(world), 'utf8');

  const result = listEntities(terrainFixture, { kind: 'Environment' });
  assert.equal(result.count, 1);
  assert.equal(result.entities[0].properties.hasTerrain, true);
  assert.deepEqual(result.entities[0].properties.terrain, {
    requestedWidthMeters: 2000,
    requestedHeightMeters: 2000,
    profile: 'Hills',
  });

  const summary = getWorldSummary(terrainFixture);
  assert.equal(summary.environments[0].hasTerrain, true);
  assert.deepEqual(summary.environments[0].terrain, {
    requestedWidthMeters: 2000,
    requestedHeightMeters: 2000,
    profile: 'Hills',
  });
});

test('get_entity retourne exactement Geometry_003', () => {
  const result = getEntity(fixture, 'Geometry_003');
  assert.equal(result.found, true);
  assert.equal(result.persistentId, 'Geometry_003');
  assert.equal(result.kind, 'EnvironmentGeometry');
  assert.equal(result.definition.centerXMeters, -330);
  assert.equal(result.definition.assetId, 'Geometry.Rock.Cliff01');
});

test('get_entity diagnostique un identifiant inexistant', () => {
  const result = getEntity(fixture, 'IdInexistant');
  assert.equal(result.found, false);
  assert.match(result.diagnostic, /Aucune entité/);
});

test('get_entity diagnostique un PersistentId ambigu', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'worlddirector-mcp-'));
  const ambiguousFixture = path.join(directory, 'world_state.json');
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));

  const world = JSON.parse(fs.readFileSync(fixture, 'utf8'));
  world.environments[0].nonHeightfieldGeometry[5].persistentId = 'Geometry_003';
  fs.writeFileSync(ambiguousFixture, JSON.stringify(world), 'utf8');

  const result = getEntity(ambiguousFixture, 'Geometry_003');
  assert.equal(result.found, false);
  assert.equal(result.ambiguous, true);
  assert.equal(result.matches.length, 2);
  assert.match(result.diagnostic, /ambigu/);
});

test('le serveur expose uniquement trois outils read-only', () => {
  assert.deepEqual(TOOL_DEFINITIONS.map((tool) => tool.name), [
    'get_world_summary', 'list_entities', 'get_entity',
  ]);
  for (const tool of TOOL_DEFINITIONS) {
    assert.equal(tool.annotations.readOnlyHint, true);
    assert.equal(tool.annotations.destructiveHint, false);
    assert.equal(Object.hasOwn(tool.inputSchema.properties ?? {}, 'path'), false);
    assert.equal(Object.hasOwn(tool.inputSchema.properties ?? {}, 'snapshot'), false);
    assert.equal(Object.hasOwn(tool.inputSchema.properties ?? {}, 'snapshotPath'), false);
  }
  assert.equal(TOOL_DEFINITIONS.some((tool) => /create|modify|delete|spawn|apply|undo|redo/i.test(tool.name)), false);
});

test('handshake legacy et discovery 2026-07-28 sont disponibles', () => {
  const legacy = handleRequest({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25' } }, fixture);
  assert.equal(legacy.result.protocolVersion, '2025-11-25');
  assert.deepEqual(legacy.result.capabilities, { tools: {} });

  const modern = handleRequest({ jsonrpc: '2.0', id: 2, method: 'server/discover', params: { _meta: {} } }, fixture);
  assert.deepEqual(modern.result.supportedVersions, ['2026-07-28']);
  assert.deepEqual(modern.result.capabilities, { tools: {} });
});

test('tools/call list_entities conserve le compte attendu', () => {
  const message = handleRequest({
    jsonrpc: '2.0',
    id: 3,
    method: 'tools/call',
    params: { name: 'list_entities', arguments: { kind: 'EnvironmentGeometry' } },
  }, fixture);
  assert.equal(message.result.structuredContent.count, 6);
  assert.equal(message.result.isError, false);
});


test('transport stdio exécutable expose et appelle les trois tools', async (t) => {
  const serverPath = path.join(here, '..', 'server.mjs');
  const child = spawn(process.execPath, [serverPath, '--snapshot', fixture], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => {
    if (!child.killed) child.kill();
  });

  let stdout = '';
  const replies = [];
  const completed = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`Timeout MCP stdio. stdout=${stdout}`)), 3000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
      const lines = stdout.split('\n');
      stdout = lines.pop() ?? '';
      for (const line of lines) {
        if (!line.trim()) continue;
        replies.push(JSON.parse(line));
        if (replies.length >= 3) {
          clearTimeout(timer);
          resolve();
        }
      }
    });
    child.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once('exit', (code) => {
      if (replies.length < 3) {
        clearTimeout(timer);
        reject(new Error(`Serveur MCP arrêté trop tôt (code=${code}).`));
      }
    });
  });

  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-11-25' } })}\n`);
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} })}\n`);
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'list_entities', arguments: { kind: 'EnvironmentGeometry' } } })}\n`);

  await completed;
  assert.equal(replies[0].result.protocolVersion, '2025-11-25');
  assert.deepEqual(replies[1].result.tools.map((tool) => tool.name), [
    'get_world_summary', 'list_entities', 'get_entity',
  ]);
  assert.equal(replies[2].result.structuredContent.count, 6);
});
