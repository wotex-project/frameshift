import { constants, closeSync, cpSync, fsyncSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { verifyManifestSignature, verifyPublishedArtifacts, verifyRelease } from '../../release/manifest.mjs';
import { readPinnedFingerprint, readReleaseInput } from '../../release/files.mjs';
import { installVerifiedRelease } from '../../apps/guide/release-markup.mjs';
import { pathExists, checkLinks, digest, documentationPolicy, headersForPath, inventory, siteHeaders, validateDevelopmentOutput, validateReleaseDocumentationOutput } from './site.mjs';

const stable = version => typeof version === 'string' && version.length <= 32 && /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(version);
const hash = value => typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
const source = value => typeof value === 'string' && /^[0-9a-f]{40}$/.test(value);
const json = path => JSON.parse(readFileSync(path, 'utf8'));
const manifestHash = directory => digest(readFileSync(join(directory, 'site-manifest.json')));
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);

function privateDirectory(path, exact = true) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & (exact ? 0o777 : 0o022)) !== (exact ? 0o700 : 0)) {
    throw new Error('Site custody requires an owned real private output and protected parent');
  }
}

function syncDirectory(path) {
  const file = openSync(path, constants.O_RDONLY);
  try { fsyncSync(file); } finally { closeSync(file); }
}

function syncTree(path) {
  for (const name of readdirSync(path)) {
    const child = join(path, name);
    if (lstatSync(child).isDirectory()) syncTree(child);
    else {
      const file = openSync(child, constants.O_RDONLY | constants.O_NOFOLLOW);
      try { fsyncSync(file); } finally { closeSync(file); }
    }
  }
  syncDirectory(path);
}

async function trustedDigest(path) {
  if (!path) throw new Error('Retained release validation requires the separately pinned trust file');
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.size > 128 || ![0, process.getuid()].includes(stat.uid) ||
      (stat.mode & 0o022) !== 0) throw new Error('Invalid pinned trust file custody');
  return readPinnedFingerprint(path);
}

const signedBounds = { manifestPath: { minimum: 2, maximum: 64 * 1024 },
  signaturePath: { minimum: 64, maximum: 64 }, publicKeyPath: { maximum: 16 * 1024 } };
async function signedBytes(paths) {
  return Object.fromEntries(await Promise.all(Object.entries(signedBounds)
    .map(async ([key, bounds]) => [key, await readReleaseInput(paths[key], bounds)])));
}

function developmentBundle(directory) {
  privateDirectory(directory);
  validateDevelopmentOutput(directory);
  const manifest = json(join(directory, 'site-manifest.json'));
  const build = json(join(directory, 'docs/dev/build.json'));
  if (manifest.dirty !== false || !source(manifest.commit) || build.commit !== manifest.commit ||
      build.channel !== 'development' || build.dirty !== false || build.preview !== false ||
      build.publishableDevelopment !== true) throw new Error('Site assembly requires eligible clean-main development docs');
  validateDocumentation(directory, { route: '/docs/dev/', commit: manifest.commit });
  return manifest;
}

function validateDocumentation(directory, identity) {
  const docs = join(directory, identity.route.slice(1));
  const build = json(join(docs, 'build.json'));
  const files = inventory(docs).filter(file => file.path !== 'build.json');
  if (build.commit !== identity.commit || build.route !== identity.route || build.dirty !== false ||
      !equal(build.files, files) || (identity.version &&
      (build.version !== identity.version || build.tag !== `v${identity.version}` ||
       build.channel !== 'release-documentation' || build.preview !== false))) {
    throw new Error('Documentation identity or retained inventory changed');
  }
  return build;
}

export function compareVersions(a, b) {
  if (!stable(a) || !stable(b)) throw new Error('Invalid stable documentation version');
  const left = a.split('.').map(BigInt);
  const right = b.split('.').map(BigInt);
  for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return left[i] < right[i] ? -1 : 1;
  return 0;
}

function releasePaths(directory, version) {
  const root = join(directory, 'release-records', `v${version}`);
  return { manifestPath: join(root, 'manifest.json'), signaturePath: join(root, 'manifest.sig'), publicKeyPath: join(root, 'release.pub.pem') };
}

export async function validateAssembly(directory, trustFile) {
  privateDirectory(directory);
  const manifest = json(join(directory, 'site-manifest.json'));
  if (manifest.schemaVersion !== 2 || manifest.channel !== 'assembly' ||
      !source(manifest.development?.commit) || !Array.isArray(manifest.releases) ||
      manifest.releases.length > 32 ||
      !equal(manifest.files, inventory(directory).filter(file => file.path !== 'site-manifest.json'))) {
    throw new Error('Unowned or changed site assembly');
  }
  const names = new Set();
  for (const entry of manifest.releases) {
    if (!stable(entry.version) || !source(entry.commit) || !hash(entry.documentationSha256) ||
        !hash(entry.manifestSha256) || names.has(entry.version)) throw new Error('Invalid retained release identity');
    names.add(entry.version);
    const route = `/docs/v${entry.version}/`;
    validateDocumentation(directory, { ...entry, route });
    if (digest(readFileSync(join(directory, route.slice(1), 'build.json'))) !== entry.documentationSha256 ||
        digest(await readReleaseInput(releasePaths(directory, entry.version).manifestPath, signedBounds.manifestPath)) !== entry.manifestSha256) {
      throw new Error('Retained release provenance changed');
    }
    const signed = await verifyManifestSignature({ ...releasePaths(directory, entry.version), trustedKeyDigest: await trustedDigest(trustFile) });
    if (signed.version !== entry.version) throw new Error('Retained signed version mismatch');
  }
  const actual = inventory(directory).filter(file => /^docs\/v[^/]+\//.test(file.path));
  if (actual.some(file => !names.has(file.path.split('/')[1].slice(1)))) throw new Error('Unrecorded retained documentation');
  const sorted = [...names].sort(compareVersions).reverse();
  if (manifest.latest !== (sorted[0] || null)) throw new Error('Stable entry point does not name the greatest admitted version');
  validateDocumentation(directory, { route: '/docs/dev/', commit: manifest.development.commit });
  if (!equal(checkLinks(directory), manifest.links)) throw new Error('Assembly link inventory changed');
  return manifest;
}

function guideHeaders(directory) {
  const headers = readFileSync(join(directory, '_headers'), 'utf8');
  const common = headers.match(/^\/\*\n([\s\S]*?)(?=\n\S)/)?.[1];
  const policy = headersForPath(headers, '/')['content-security-policy'];
  if (!common || !policy || policy.includes(', ')) throw new Error('Guide header contract missing');
  return `/*\n  Content-Security-Policy: ${policy}\n${common.trimEnd()}\n`;
}

function escape(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

function statusPage(title, content) {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} · Frameshift</title><link rel="stylesheet" href="/site.css"></head><body><a href="#content">Skip to content</a><nav aria-label="Site"><a href="/">Guide</a> · <a href="/download/">Downloads</a> · <a href="/docs/">Documentation</a></nav><main id="content"><h1>${title}</h1>${content}</main></body></html>\n`;
}

function promoteGlobals(stage, candidate, signed) {
  // Only the release's accepted source supplies global guide assets. A later
  // development update keeps these and both stable entry points byte-for-byte.
  for (const file of inventory(candidate)) {
    if (file.path.startsWith('docs/') || file.path.startsWith('release-records/') ||
        file.path === 'site-manifest.json' || file.path === '_headers') continue;
    mkdirSync(dirname(join(stage, file.path)), { recursive: true });
    cpSync(join(candidate, file.path), join(stage, file.path));
  }
  const guide = join(stage, 'index.html');
  writeFileSync(guide, installVerifiedRelease(readFileSync(guide, 'utf8'), signed));
  const labels = { macos: 'macOS universal DMG', ubuntu: 'Ubuntu DEB', 'nerves-rpi5': 'Nerves Pi 5 firmware' };
  const links = signed.artifacts.map(artifact => `<li><a href="${escape(artifact.url)}">${labels[artifact.platform]} · ${artifact.architecture}</a> · SHA-256 <code>${artifact.sha256}</code></li>`).join('');
  writeFileSync(join(stage, 'download/index.html'), statusPage('Downloads', `<p>Verified host release ${signed.version}. Use the artifact for your platform; frame qualification and physical pairing remain separate.</p><ul>${links}</ul><p>Direct package installation and update acceptance remain attached to the released platform. <a href="/docs/v${signed.version}/">Read its exact documentation</a>.</p>`));
}

function writeJournal(lock, record) {
  const next = join(lock, 'journal.next');
  writeFileSync(next, JSON.stringify(record) + '\n', { mode: 0o600, flag: 'wx' });
  const file = openSync(next, constants.O_RDONLY);
  try { fsyncSync(file); } finally { closeSync(file); }
  renameSync(next, join(lock, 'journal.json'));
  syncDirectory(lock);
}

export async function assembleSite({ development, output, release, trustFile }, { fetcher = fetch, afterSwap = () => {} } = {}) {
  output = resolve(output);
  privateDirectory(dirname(output), false);
  const lock = output + '.lock';
  const previous = output + '.previous';
  if (pathExists(previous)) throw new Error('Unreconciled previous site; run local recovery');
  mkdirSync(lock, { mode: 0o700 }); // Existing lock refuses; never steal another writer's custody.
  let stage;
  let swapping = false;
  try {
    const old = pathExists(output) ? await validateAssembly(output, trustFile) : null;
    const before = old ? manifestHash(output) : null;
    const dev = developmentBundle(development);
    const devHash = manifestHash(development);
    stage = mkdtempSync(join(dirname(output), '.site-assembly-'));
    const journal = { schemaVersion: 1, output: basename(output), stage: basename(stage), before, after: null };
    writeJournal(lock, journal);
    cpSync(old ? output : development, stage, { recursive: true });
    rmSync(join(stage, 'site-manifest.json'));
    rmSync(join(stage, 'docs/dev'), { recursive: true });
    cpSync(join(development, 'docs/dev'), join(stage, 'docs/dev'), { recursive: true });
    const releases = [...(old?.releases || [])];
    const retainedSignedBytes = release ? await signedBytes(release) : null;
    const signedInputs = retainedSignedBytes ? Object.fromEntries(Object.entries(retainedSignedBytes)
      .map(([key, bytes]) => [key, digest(bytes)])) : null;
    let baseHeaders = guideHeaders(old ? output : development);
    let latest = old?.latest || null;
    let candidateHash;
    if (release) {
      const { candidate, sourceCommit, ...verification } = release;
      const signed = await verifyRelease({ ...verification, trustedKeyDigest: await trustedDigest(trustFile) });
      privateDirectory(candidate);
      validateReleaseDocumentationOutput(candidate, { commit: sourceCommit, version: signed.version, tag: `v${signed.version}` });
      const entry = { version: signed.version, commit: sourceCommit,
        documentationSha256: digest(readFileSync(join(candidate, `docs/v${signed.version}/build.json`))),
        manifestSha256: signedInputs.manifestPath };
      validateDocumentation(candidate, { ...entry, route: `/docs/v${signed.version}/` });
      candidateHash = manifestHash(candidate);
      await verifyPublishedArtifacts(signed, fetcher);
      const retained = releases.find(item => item.version === signed.version);
      if (retained && !equal(retained, entry)) throw new Error('Conflicting source/docs/artifacts for retained release');
      if (!retained) {
        if (releases.length >= 32) throw new Error('Retained release budget exhausted; no version may be deleted automatically');
        cpSync(join(candidate, `docs/v${signed.version}`), join(stage, `docs/v${signed.version}`), { recursive: true });
        const paths = releasePaths(stage, signed.version);
        mkdirSync(dirname(paths.manifestPath), { recursive: true, mode: 0o700 });
        for (const [key, bytes] of Object.entries(retainedSignedBytes)) writeFileSync(paths[key], bytes, { flag: 'wx', mode: 0o600 });
        releases.push(entry);
      }
      if (!latest || compareVersions(signed.version, latest) > 0) {
        latest = signed.version;
        promoteGlobals(stage, candidate, signed);
        baseHeaders = guideHeaders(candidate);
      }
    }
    releases.sort((a, b) => compareVersions(b.version, a.version));
    const nodes = releases.map(entry => ({ version: `v${entry.version}`, url: `/docs/v${entry.version}`, ...(entry.version === latest ? { latest: true } : {}) }));
    nodes.push({ version: 'v0.1.0-dev (unreleased)', url: '/docs/dev' });
    writeFileSync(join(stage, 'docs/docs_config.js'), `var versionNodes = ${JSON.stringify(nodes)};\n`);
    if (latest) writeFileSync(join(stage, 'docs/index.html'), statusPage('Documentation', `<p>Latest verified host release: <a href="/docs/v${latest}/">v${latest}</a>.</p><ul>${releases.map(entry => `<li><a href="/docs/v${entry.version}/">v${entry.version}</a> · source <code>${entry.commit}</code></li>`).join('')}</ul><p><a href="/docs/dev/">Unreleased development documentation</a>.</p>`));
    const policies = releases.map(entry => ({ version: entry.version, policy: documentationPolicy(join(stage, `docs/v${entry.version}`)) }));
    const headers = siteHeaders(baseHeaders, documentationPolicy(join(stage, 'docs/dev')), policies);
    if (headers.split('\n').some(line => line.length > 2_000)) throw new Error('Static header line exceeds hosting limit');
    for (const file of inventory(stage).filter(file => file.path.endsWith('.html'))) {
      const csp = headersForPath(headers, '/' + file.path)['content-security-policy'];
      if (!csp || csp.includes(', ')) throw new Error('Missing or overlapping assembly CSP');
    }
    writeFileSync(join(stage, '_headers'), headers);
    if (old) {
      const retained = path => old.releases.some(entry => path.startsWith(`docs/v${entry.version}/`) ||
        path.startsWith(`release-records/v${entry.version}/`));
      if (!equal(old.files.filter(file => retained(file.path)), inventory(stage).filter(file => retained(file.path)))) {
        throw new Error('Assembly would change retained version bytes');
      }
    }
    const manifest = { schemaVersion: 2, channel: 'assembly', development: { commit: dev.commit }, releases, latest,
      links: checkLinks(stage), files: inventory(stage) };
    writeFileSync(join(stage, 'site-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
    await validateAssembly(stage, trustFile);
    syncTree(stage);
    journal.after = manifestHash(stage);
    writeJournal(lock, journal);
    if (manifestHash(development) !== devHash || !equal(developmentBundle(development), dev)) {
      throw new Error('Site inputs changed during assembly');
    }
    if (release) {
      const signed = await verifyRelease({ ...release, trustedKeyDigest: await trustedDigest(trustFile) });
      validateReleaseDocumentationOutput(release.candidate, { commit: release.sourceCommit, version: signed.version, tag: `v${signed.version}` });
      const currentSigned = await signedBytes(release);
      if (manifestHash(release.candidate) !== candidateHash ||
          Object.entries(signedInputs).some(([key, value]) => digest(currentSigned[key]) !== value) ||
          digest(currentSigned.manifestPath) !== releases.find(entry => entry.version === signed.version)?.manifestSha256) {
        throw new Error('Site inputs changed during assembly');
      }
    }
    if (old && (manifestHash(output) !== before || !equal(await validateAssembly(output, trustFile), old))) throw new Error('Prior site changed during assembly');
    swapping = true;
    if (old) renameSync(output, previous);
    syncDirectory(dirname(output));
    afterSwap('previous');
    renameSync(stage, output);
    syncDirectory(dirname(output));
    afterSwap('current');
    await validateAssembly(output, trustFile);
    rmSync(previous, { recursive: true, force: true });
    rmSync(lock, { recursive: true });
    syncDirectory(dirname(output));
    return manifest;
  } catch (error) {
    if (swapping) throw new Error('Site assembly outcome uncertain; run local recover before another write', { cause: error });
    if (stage) rmSync(stage, { recursive: true, force: true });
    rmSync(lock, { recursive: true });
    throw error;
  }
}

export async function recoverSite(target, trustFile) {
  const output = resolve(target);
  privateDirectory(dirname(output), false);
  const lock = output + '.lock';
  if (!pathExists(lock) && !pathExists(output + '.previous')) {
    await validateAssembly(output, trustFile);
    return 'verified';
  }
  privateDirectory(lock);
  const file = join(lock, 'journal.json');
  const stat = lstatSync(file);
  if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600 || stat.size > 4_096) throw new Error('Unsafe recovery journal');
  const journal = json(file);
  if (journal.schemaVersion !== 1 || journal.output !== basename(output) ||
      !/^\.site-assembly-[A-Za-z0-9]+$/.test(journal.stage) ||
      (journal.before !== null && !hash(journal.before)) || (journal.after !== null && !hash(journal.after))) throw new Error('Invalid recovery journal');
  const stage = join(dirname(output), journal.stage);
  if (pathExists(stage)) privateDirectory(stage);
  const previous = output + '.previous';
  const matches = async (path, expected) => {
    if (!expected || !pathExists(path)) return false;
    await validateAssembly(path, trustFile);
    return manifestHash(path) === expected;
  };
  if (pathExists(stage) && journal.after !== null && !await matches(stage, journal.after)) {
    throw new Error('Changed staged site; recovery preserves bytes');
  }
  let result;
  if (await matches(output, journal.after)) {
    if (pathExists(previous) && !await matches(previous, journal.before)) throw new Error('Conflicting previous site; recovery preserves bytes');
    result = 'completed';
  } else if (await matches(output, journal.before)) {
    if (pathExists(previous)) throw new Error('Conflicting prior custody; recovery preserves bytes');
    result = 'restored';
  } else if (!pathExists(output) && await matches(previous, journal.before)) {
    renameSync(previous, output);
    result = 'restored';
  } else if (!pathExists(output) && !pathExists(previous) && journal.before === null && journal.after === null) {
    result = 'discarded';
  } else throw new Error('Unknown local site state; recovery preserves all bytes');
  if (pathExists(stage)) rmSync(stage, { recursive: true });
  rmSync(previous, { recursive: true, force: true });
  syncDirectory(dirname(output));
  rmSync(lock, { recursive: true });
  syncDirectory(dirname(output));
  return result;
}
