import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { constants, closeSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve, sep } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { readReleaseInput, withReleaseInput } from './files.mjs';
import { verifyInputs } from './inputs.mjs';
import { releaseGit } from './source.mjs';

const owner = resolve(new URL('..', import.meta.url).pathname);
const helper = join(owner, 'release/core-material.exs');
const encode = value => Buffer.from(JSON.stringify(value) + '\n');
const hash = value => createHash('sha256').update(value).digest('hex');
const same = isDeepStrictEqual;
const maximumRecord = 16 * 1024 * 1024;
const fail = message => { throw new Error(message); };
const identity = stat => ['dev', 'ino', 'mode', 'uid', 'gid'].map(key => String(stat[key]));
const safePath = path => typeof path === 'string' && Buffer.byteLength(path) <= 512 && !/[\u0000-\u001f\u007f\\]/.test(path) && path.split('/').length <= 32 && path.split('/').every(part => part && part !== '.' && part !== '..');

export function coreMaterialParse(operation, bytes, timeout = 60_000) {
  const env = { ...process.env, HEX_OFFLINE: '1' };
  for (const name of Object.keys(env)) if (name.startsWith('GIT_')) delete env[name];
  const result = spawnSync('mise', ['exec', '--', 'mix', 'run', '--no-mix-exs', '--no-start', '--no-compile', '--no-deps-check', helper, operation],
    { cwd: owner, env, input: bytes, timeout, killSignal: 'SIGKILL', maxBuffer: maximumRecord });
  if (result.error || result.status !== 0) fail('core dependency parser unavailable or refused input');
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(result.stdout)); } catch { fail('core dependency parser output refused'); }
}

function directory(path, privateMode = false) {
  const stat = lstatSync(path, { bigint: true });
  if (!stat.isDirectory() || stat.uid !== BigInt(process.getuid()) || (privateMode ? (stat.mode & 0o7777n) !== 0o700n : (stat.mode & 0o022n) !== 0n)) fail('unsafe core material directory');
  return stat;
}
function synchronize(path, isDirectory = false) {
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK | (isDirectory ? constants.O_DIRECTORY : 0));
  try {
    const stat = fstatSync(fd), named = lstatSync(path);
    if (!(isDirectory ? stat.isDirectory() && named.isDirectory() : stat.isFile() && named.isFile()) || stat.dev !== named.dev || stat.ino !== named.ino) fail('core material sync custody changed');
    fsyncSync(fd);
  } finally { closeSync(fd); }
}
export async function lockedSourceFacts(path, expected, budget) {
  budget();
  const named = lstatSync(path, { bigint: true });
  if (!named.isFile() || named.nlink !== 1n || named.uid !== BigInt(process.getuid()) || (named.mode & 0o7002n) !== 0n || (named.mode & 0o400n) === 0n) fail('unsafe core source file or alias');
  const result = await withReleaseInput(path, { minimum: 0, maximum: 128 * 1024 * 1024 }, async (handle, size) => {
    const sha = createHash('sha256'), blob = createHash('sha1').update(`blob ${size}\0`), block = Buffer.alloc(64 * 1024);
    for (let offset = 0; offset < size;) {
      budget();
      const { bytesRead } = await handle.read(block, 0, Math.min(block.length, size - offset), offset);
      if (!bytesRead) fail('core source changed');
      sha.update(block.subarray(0, bytesRead)); blob.update(block.subarray(0, bytesRead)); offset += bytesRead;
    }
    if ((await handle.read(block, 0, 1, size)).bytesRead) fail('core source grew');
    return { bytes: size, sha256: sha.digest('hex'), blob: blob.digest('hex') };
  });
  const final = lstatSync(path, { bigint: true });
  if (['dev', 'ino', 'size', 'mode', 'uid', 'gid', 'nlink', 'mtimeNs', 'ctimeNs'].some(key => named[key] !== final[key])) fail('core source custody changed');
  const mode = Number(named.mode & 0o7777n);
  if (mode !== expected.mode || (expected.sha256 && (result.bytes !== expected.bytes || result.sha256 !== expected.sha256)) || (expected.blob && result.blob !== expected.blob)) fail('core source differs from locked archive or Git blob');
  return { path: expected.path, mode, bytes: result.bytes, sha256: result.sha256 };
}

const generated = new Set(['exile/priv/exile.so', 'exile/priv/spawner', 'exqlite/priv/sqlite3_nif.so', 'exqlite/priv/sqlite3_nif.a', 'file_system/priv/mac_listener']);
const generatedSources = new Map([
  ['earmark_parser/src/earmark_parser_link_text_lexer.erl', 'src/earmark_parser_link_text_lexer.xrl'],
  ['earmark_parser/src/earmark_parser_link_text_parser.erl', 'src/earmark_parser_link_text_parser.yrl'],
  ['earmark_parser/src/earmark_parser_string_lexer.erl', 'src/earmark_parser_string_lexer.xrl'],
  ['erlex/src/erlex_lexer.erl', 'src/erlex_lexer.xrl'], ['erlex/src/erlex_parser.erl', 'src/erlex_parser.yrl'],
]);
export const generatedCoreSourceInput = path => generatedSources.get(path);
async function dependencyFiles(root, lock, expected, archiveDirectories, budget, limits) {
  const observed = [], seen = new Set(), directories = [];
  const parents = new Set(['']);
  for (const path of archiveDirectories) {
    parents.add(path); let parent = dirname(path);
    while (parent !== '.') { parents.add(parent); parent = dirname(parent); }
  }
  for (const file of expected.values()) {
    let path = dirname(file.path);
    while (path !== '.') { parents.add(path); path = dirname(path); }
  }
  if (lock.type === 'hex' && ['exile', 'exqlite', 'file_system'].includes(lock.key)) parents.add('priv');
  async function visit(relative, depth) {
    budget();
    if (++limits.entries > 8192 || depth > 32 || (relative && !safePath(relative))) fail('core material entry limit');
    const path = join(root, relative), stat = lstatSync(path, { bigint: true });
    if (stat.isDirectory()) {
      if (!parents.has(relative)) fail('additional core source directory');
      directory(path); const before = readdirSync(path).sort();
      directories.push({ path: relative, mode: Number(stat.mode & 0o7777n) });
      for (const name of before) {
        const local = relative ? `${relative}/${name}` : name;
        // An expected archive/blob member always wins over generated exclusions.
        if (!expected.has(local) && ((lock.type === 'git' && !relative && name === '.git') || ['_build', '.elixir_ls', '.DS_Store'].includes(name))) continue;
        const generatedInput = generatedSources.get(`${lock.key}/${local}`);
        if (!expected.has(local) && (generated.has(`${lock.key}/${local}`) || (generatedInput && expected.has(generatedInput)) || /\.(?:o|beam|d)$/.test(name))) {
          const generatedStat = lstatSync(join(root, local));
          if (!generatedStat.isFile() || generatedStat.nlink !== 1) fail('generated core output alias or special file');
          continue;
        }
        await visit(local, depth + 1);
      }
      if (!same(before, readdirSync(path).sort()) || !same(identity(stat), identity(directory(path)))) fail('core material namespace changed');
    } else {
      const entry = expected.get(relative);
      if (!entry) fail('additional core source file');
      const file = await lockedSourceFacts(path, entry, budget);
      if ((limits.bytes += file.bytes) > 512 * 1024 * 1024) fail('core material byte limit');
      observed.push(file); seen.add(relative);
    }
  }
  await visit('', 0);
  if (seen.size !== expected.size) fail('missing locked core source file');
  return { files: observed, directories };
}

async function inspect(repository, cache, parse, budget) {
  const lockBytes = await readReleaseInput(join(repository, 'apps/core/mix.lock'), { maximum: 64 * 1024 });
  const locks = parse('lock', lockBytes);
  const deps = join(repository, 'apps/core/deps'), initial = directory(deps), names = readdirSync(deps).sort();
  if (!same(names, locks.map(lock => lock.key))) fail('core dependency namespace differs from lock');
  const cacheStat = directory(cache), cacheNames = readdirSync(cache).sort(), packages = [], limits = { entries: 0, bytes: 0 };
  for (const lock of locks) {
    budget();
    const root = join(deps, lock.key); directory(root);
    let expected, parser, archiveDirectories = [];
    if (lock.type === 'hex') {
      const archive = join(cache, `${lock.name}-${lock.version}.tar`);
      if (lstatSync(archive).nlink !== 1) fail('core package archive alias');
      const bytes = await readReleaseInput(archive, { maximum: 64 * 1024 * 1024 });
      if (lstatSync(archive).nlink !== 1) fail('core package archive alias');
      if (hash(bytes) !== lock.outer) fail('core package archive differs from frozen checksum');
      const result = parse('package', bytes);
      if (result.name !== lock.name || result.version !== lock.version || result.inner !== lock.inner || result.outer !== lock.outer) fail('core package identity differs from lock');
      const manifestBytes = await readReleaseInput(join(root, '.hex'), { maximum: 64 * 1024 });
      if (!same(parse('manifest', manifestBytes), { name: lock.name, version: lock.version, inner: lock.inner, outer: lock.outer, repo: lock.repo, managers: lock.managers })) fail('core Hex manifest differs from lock');
      expected = new Map(result.files.map(file => [file.path, file]));
      expected.set('hex_metadata.config', { path: 'hex_metadata.config', mode: 0o644, ...result.metadata });
      expected.set('.hex', { path: '.hex', mode: 0o644, bytes: manifestBytes.length, sha256: hash(manifestBytes) });
      parser = result.parser;
      archiveDirectories = result.directories;
    } else {
      const git = args => releaseGit(root, ['--no-lazy-fetch', '--literal-pathspecs', '-c', 'protocol.allow=never', '-c', 'core.fsmonitor=false', ...args]);
      if (git(['rev-parse', 'HEAD']).trim() !== lock.commit) fail('core Git checkout differs from lock');
      const tree = git(['ls-tree', '-r', '-z', '--full-tree', lock.commit, '--', ...(lock.sparse ? [lock.sparse] : [])]).split('\0').filter(Boolean);
      if (!tree.length || tree.length > 8192) fail('core Git source entry limit');
      expected = new Map(tree.map(entry => {
        const match = /^(100644|100755) blob ([0-9a-f]{40})\t(.+)$/.exec(entry);
        if (!match || !safePath(match[3]) || (lock.sparse && !match[3].startsWith(lock.sparse + '/'))) fail('unsupported locked Git source');
        return [match[3], { path: match[3], mode: match[1] === '100755' ? 0o755 : 0o644, blob: match[2] }];
      }));
      if (expected.size !== tree.length) fail('duplicate core Git source');
    }
    const material = await dependencyFiles(root, lock, expected, archiveDirectories, budget, limits);
    packages.push({ lock, ...(parser ? { parser } : {}), ...material });
  }
  if (!same(names, readdirSync(deps).sort()) || !same(identity(initial), identity(directory(deps))) || !same(cacheNames, readdirSync(cache).sort()) || !same(identity(cacheStat), identity(directory(cache)))) fail('core dependency/cache namespace changed');
  return { material: { lockSha256: hash(lockBytes), packages }, namespace: { cacheNames, cacheIdentity: identity(cacheStat), dependencyIdentity: identity(initial) } };
}

export async function checkCoreMaterial({ repository, tag, commit, sourcePath, cache, output }, { parse = coreMaterialParse, budgetMs = 180_000 } = {}) {
  repository = realpathSync(repository); cache = resolve(cache); directory(cache); cache = realpathSync(cache); output = resolve(output);
  const deadline = performance.now() + budgetMs;
  const budget = () => { if (performance.now() >= deadline) fail('core dependency processing deadline'); };
  const parser = (operation, bytes) => { budget(); const result = parse(operation, bytes, Math.max(1, Math.min(60_000, Math.floor(deadline - performance.now())))); budget(); return result; };
  const source = await verifyInputs(repository, tag, commit, sourcePath); budget();
  const helperBytes = await readReleaseInput(helper, { maximum: 64 * 1024 });
  const observation = await inspect(repository, cache, parser, budget), material = observation.material;
  const record = { schemaVersion: 1, kind: 'locked-core-source-material', product: source.product, tag, version: source.version, sourceCommit: commit,
    sourceInputsSha256: hash(encode(source)), parserSourceSha256: hash(helperBytes), publicationAuthority: 'none', ...material };
  const bytes = encode(record); if (bytes.length > maximumRecord) fail('core material receipt limit');
  const parent = dirname(output); directory(parent);
  const physical = join(realpathSync(parent), basename(output));
  if (physical === repository || physical === cache || physical.startsWith(cache + sep) || cache.startsWith(physical + sep) ||
      physical === join(repository, 'apps/core/deps') || physical.startsWith(join(repository, 'apps/core/deps') + sep) || (physical.startsWith(repository + sep) && !releaseGit(repository, ['check-ignore', '--no-index', physical]).length)) fail('core material output overlaps inputs');
  const receipt = join(output, 'core-material.json');
  let exists = false;
  try { lstatSync(output); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  let created;
  if (exists) {
    created = directory(output, true);
    if (!same(readdirSync(output).sort(), ['core-material.json']) || lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: maximumRecord, privateKey: true })).equals(bytes)) fail('incomplete or conflicting core material output');
  } else {
    mkdirSync(output, { mode: 0o700 }); created = directory(output, true);
    writeFileSync(join(output, 'check.pending'), 'incomplete core dependency source check\n', { flag: 'wx', mode: 0o600 });
    synchronize(join(output, 'check.pending')); synchronize(output, true);
  }
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(observation, await inspect(repository, cache, parser, budget)) || !(await readReleaseInput(helper, { maximum: 64 * 1024 })).equals(helperBytes)) fail('core source material changed during check');
  await verifyInputs(repository, tag, commit, sourcePath); budget();
  if (!same(identity(created), identity(directory(output, true))) || !same(readdirSync(output).sort(), exists ? ['core-material.json'] : ['check.pending'])) fail('core receipt output custody changed');
  if (exists) {
    if (lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: maximumRecord, privateKey: true })).equals(bytes)) fail('core receipt changed during replay');
  } else {
    const pending = join(output, 'check.pending');
    if (lstatSync(pending).nlink !== 1 || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(Buffer.from('incomplete core dependency source check\n'))) fail('core receipt pending custody changed');
    writeFileSync(receipt, bytes, { flag: 'wx', mode: 0o600 }); synchronize(receipt);
    if (!same(identity(created), identity(directory(output, true))) || !same(readdirSync(output).sort(), ['check.pending', 'core-material.json']) || lstatSync(receipt).nlink !== 1 || !(await readReleaseInput(receipt, { maximum: maximumRecord, privateKey: true })).equals(bytes) || !(await readReleaseInput(pending, { maximum: 1024, privateKey: true })).equals(Buffer.from('incomplete core dependency source check\n'))) fail('core receipt output changed');
    unlinkSync(pending); synchronize(output, true); synchronize(parent, true);
  }
  return { publicationAuthority: 'none', packages: material.packages.length, files: material.packages.reduce((sum, item) => sum + item.files.length, 0), receiptSha256: hash(bytes), disposition: exists ? 'retained-bytes-verified' : 'source-bytes-recorded' };
}
