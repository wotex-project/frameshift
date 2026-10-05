import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readReleaseInput } from './files.mjs';
import { verifyManifestSignature, verifyPublishedFile, verifyRelease } from './manifest.mjs';

const encode = value => JSON.stringify(value) + '\n';
const same = (a, b) => encode(a) === encode(b);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const maximumChannelFile = 2 * 1024 * 1024 * 1024;
const id = value => Number.isSafeInteger(value) && value > 0;

export function channelGhRead(path, timeout = 15_000) {
  const result = spawnSync('gh', ['api', '--hostname', 'github.com', '--method', 'GET', '--include',
    '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2026-03-10', path],
  { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout, maxBuffer: 256 * 1024,
    env: { ...process.env, GH_PROMPT_DISABLED: '1' } });
  if (result.error || result.signal || typeof result.stdout !== 'string') throw new Error('release channel request unavailable');
  const response = result.stdout.replace(/\r\n/g, '\n');
  const line = /^HTTP\/(?:1\.[01]|2(?:\.0)?|3(?:\.0)?) ([1-5][0-9]{2})(?: [^\n]*)?\n/.exec(response);
  const separator = response.indexOf('\n\n');
  if (!line || separator < 0 || !/^Content-Type: application\/json(?:;[^\n]*)?$/im.test(response.slice(0, separator))) throw new Error('invalid release channel response');
  const status = Number(line[1]);
  if ((result.status !== 0 && status !== 404) || ![200, 404].includes(status)) throw new Error('release channel response unavailable');
  try { return { status, data: JSON.parse(response.slice(separator + 2)) }; }
  catch { throw new Error('invalid release channel JSON'); }
}

function repositoryName(repository) {
  if (typeof repository !== 'string' || repository.length > 200 || repository.trim() !== repository ||
      !/^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(repository)) throw new Error('unsupported public release repository');
}

function channelCoordinates(repository, manifest) {
  const prefix = `https://github.com/${repository}/releases/download/v${manifest.version}/`;
  for (const artifact of manifest.artifacts) {
    if (artifact.bytes >= maximumChannelFile || artifact.url !== prefix + artifact.file) throw new Error('release channel URL or size mismatch');
  }
  return { tag: `v${manifest.version}`, prefix };
}

async function metadataFiles(options, prefix) {
  const fields = [
    ['manifestPath', 'manifest.json', { minimum: 2, maximum: 64 * 1024 }],
    ['signaturePath', 'manifest.sig', { minimum: 64, maximum: 64 }],
    ['publicKeyPath', 'release.pub.pem', { maximum: 16 * 1024 }]
  ];
  const files = [];
  for (const [key, file, bounds] of fields) {
    const bytes = await readReleaseInput(options[key], bounds);
    files.push({ file, url: prefix + file, bytes: bytes.length, sha256: digest(bytes) });
  }
  return files;
}

function remoteSnapshot(repository, tag, expected, read) {
  const repo = read(`repos/${repository}`);
  if (repo.status !== 200 || !id(repo.data?.id) || repo.data.full_name !== repository || repo.data.private !== false || repo.data.visibility !== 'public') throw new Error('public release repository mismatch');
  const repositoryId = repo.data.id;
  const reference = read(`repos/${repository}/releases/tags/${tag}`);
  if (reference.status === 404) return { repositoryId, state: 'not-published', releaseId: null, assets: [], missing: expected.map(file => file.file), interrupted: [] };
  const release = reference.data;
  if (reference.status !== 200 || !id(release?.id) || release.tag_name !== tag || typeof release.draft !== 'boolean' ||
      release.prerelease !== false || release.html_url !== `https://github.com/${repository}/releases/tag/${tag}`) throw new Error('release channel identity mismatch');
  if (release.draft) return { repositoryId, state: 'not-published', releaseId: release.id, assets: [], missing: expected.map(file => file.file), interrupted: [] };
  if (typeof release.published_at !== 'string' || !Number.isFinite(Date.parse(release.published_at))) throw new Error('release publication identity missing');
  const listed = read(`repos/${repository}/releases/${release.id}/assets?per_page=100&page=1`);
  if (listed.status !== 200 || !Array.isArray(listed.data) || listed.data.length > expected.length) throw new Error('unsupported release asset inventory');
  const admitted = new Map(expected.map(file => [file.file, file]));
  const names = new Set();
  const ids = new Set();
  const assets = [];
  const interrupted = [];
  for (const asset of listed.data) {
    const file = admitted.get(asset?.name);
    if (!file || names.has(asset.name) || !id(asset.id) || ids.has(asset.id) || asset.browser_download_url !== file.url ||
        !['uploaded', 'starter'].includes(asset.state) || !Number.isSafeInteger(asset.size) || asset.size < 0 || asset.size > file.bytes) throw new Error('conflicting release asset');
    names.add(asset.name); ids.add(asset.id);
    const apiDigest = asset.digest ?? null;
    if (apiDigest !== null && apiDigest !== 'sha256:' + file.sha256) throw new Error('conflicting release digest');
    if (asset.state === 'uploaded' && asset.size !== file.bytes) throw new Error('conflicting release size');
    if (asset.state === 'starter') interrupted.push(asset.name);
    assets.push({ name: asset.name, id: asset.id, state: asset.state, bytes: asset.size, url: file.url, apiDigest });
  }
  const missing = expected.filter(file => !names.has(file.file)).map(file => file.file);
  return { repositoryId, state: missing.length || interrupted.length ? 'incomplete' : 'complete', releaseId: release.id,
    publishedAt: release.published_at, assets: assets.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0), missing, interrupted: interrupted.sort() };
}

export async function inspectReleaseChannel(options, request = channelGhRead, fetcher = fetch) {
  const { repository } = options;
  repositoryName(repository);
  const signed = await verifyManifestSignature(options);
  const { tag, prefix } = channelCoordinates(repository, signed);
  if (!same(signed, await verifyRelease(options))) throw new Error('local release changed before inspection');
  const metadata = await metadataFiles(options, prefix);
  const files = [...signed.artifacts.map(({ file, url, bytes, sha256 }) => ({ file, url, bytes, sha256 })), ...metadata];
  if (new Set(files.map(file => file.file)).size !== files.length) throw new Error('conflicting release filenames');
  let deadline = performance.now() + 60_000;
  const read = path => {
    const remaining = deadline - performance.now();
    if (remaining <= 0) throw new Error('release channel processing deadline');
    return request(path, Math.min(15_000, Math.ceil(remaining)));
  };
  const before = remoteSnapshot(repository, tag, files, read);
  if (before.state === 'complete') for (const file of files) await verifyPublishedFile(file, fetcher);
  if (!same(signed, await verifyRelease(options)) || !same(metadata, await metadataFiles(options, prefix))) throw new Error('local release changed during inspection');
  deadline = performance.now() + 60_000;
  if (!same(before, remoteSnapshot(repository, tag, files, read))) throw new Error('release channel changed during inspection');
  return { schemaVersion: 1, kind: 'public-release-observation', product: signed.product, publicationAuthority: 'none',
    repository, repositoryId: before.repositoryId, tag, version: signed.version, state: before.state === 'complete' ? 'public-bytes-verified' : before.state,
    releaseId: before.releaseId, files, assets: before.assets, missing: before.missing, interrupted: before.interrupted };
}
