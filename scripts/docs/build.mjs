import { execFileSync } from 'node:child_process';
import { cpSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { canonicalDocumentationMetadata, pathExists, checkDocumentationIndex, checkLinks, digest, documentationPolicy, headersForPath, inventory, labelHeadingAnchors, releaseSourceIdentity, sharedVersionMenu, siteHeaders, sourceIdentity, validateDevelopmentOutput, validateReleaseDocumentationOutput } from './site.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const arguments_ = process.argv.slice(2);
const releaseDocs = arguments_.length === 3 && arguments_[0] === '--release-docs';
if (!releaseDocs && arguments_.length && (arguments_.length !== 1 || arguments_[0] !== '--preview')) {
  throw new Error('usage: scripts/build-site [--preview | --release-docs vX.Y.Z COMMIT]');
}
const preview = arguments_[0] === '--preview';
const git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8' }).trim();
const getIdentity = () => releaseDocs ? releaseSourceIdentity(repository, arguments_[1], arguments_[2]) : sourceIdentity(repository, preview);
const identity = getIdentity();
const { commit, dirty } = identity;
if (Object.keys(process.env).some(key => key.startsWith('FRAMESHIFT_RELEASE_') && process.env[key])) {
  throw new Error('Development site does not promote release inputs');
}

const sources = git(['ls-files', '--cached', '--others', '--exclude-standard', '-z'])
  .split('\0').filter(Boolean).sort();
const inputs = sources.map(path => {
  const target = join(repository, path);
  if (!lstatSync(target).isFile()) throw new Error(`Non-regular build input: ${path}`);
  return { path, sha256: digest(readFileSync(target)) };
});
const pages = sources.filter(path => /^docs\/.*\.md$/.test(path) || /(?:^|\/)README\.md$/.test(path))
  .map(source => ({ source, id: source.replace(/\.md$/, '').replaceAll('/', '--').toLowerCase() }));
if (new Set(pages.map(page => page.id)).size !== pages.length) throw new Error('Documentation page identity collision');
if (!pages.some(page => page.source === 'docs/README.md')) throw new Error('Documentation index missing');

const output = join(repository, 'var', releaseDocs ? `site-${identity.tag}` : preview ? 'site-preview' : 'site');
const validateOutput = () => releaseDocs ? validateReleaseDocumentationOutput(output, identity) : validateDevelopmentOutput(output);
if (pathExists(output)) validateOutput();
mkdirSync(dirname(output), { recursive: true });
const stage = mkdtempSync(join(dirname(output), '.site-stage-'));
const inputPath = join(stage, '.build-input.json');
try {
  execFileSync(join(repository, 'scripts/build-guide'), { cwd: repository, stdio: 'inherit' });
  cpSync(join(repository, 'apps/guide/dist'), stage, { recursive: true });
  execFileSync('mise', ['exec', '--', 'mix', 'compile', '--force', '--warnings-as-errors'],
    { cwd: join(repository, 'apps/core'), env: { ...process.env, MIX_ENV: 'dev' }, stdio: 'inherit' });
  const versions = [{ channel: 'development', route: '/docs/dev/' }];
  if (releaseDocs) versions.push({ channel: 'release-documentation', version: identity.version, route: `/docs/${identity.tag}/` });
  for (const version of versions) {
    const docs = join(stage, version.route.slice(1));
    mkdirSync(docs, { recursive: true });
    writeFileSync(inputPath, JSON.stringify({ root: repository, output: docs, commit, dirty, preview, pages, ...version }));
    execFileSync('mise', ['exec', '--', 'mix', 'run', '--no-start', '../../scripts/docs/render.exs', inputPath],
      { cwd: join(repository, 'apps/core'), env: { ...process.env, MIX_ENV: 'dev' }, stdio: 'inherit' });
    rmSync(inputPath);
    canonicalDocumentationMetadata(docs);
    for (const file of inventory(docs).filter(file => file.path.endsWith('.html'))) {
      const path = join(docs, file.path);
      writeFileSync(path, sharedVersionMenu(labelHeadingAnchors(readFileSync(path, 'utf8'))));
    }
    writeFileSync(join(docs, 'build.json'), JSON.stringify({ schemaVersion: 1,
      ...version, commit, dirty, preview, tag: version.version ? identity.tag : null,
      publishableDevelopment: version.channel === 'development' && identity.publishableDevelopment,
      pages, inputs, toolchains: { mise: readFileSync(join(repository, '.mise.toml'), 'utf8') },
      files: inventory(docs) }, null, 2) + '\n');
    version.policy = documentationPolicy(docs);
  }
  const nodes = versions.map(version => ({ version: version.version ? `v${version.version}` : 'v0.1.0-dev (unreleased)', url: version.route.slice(0, -1) }));
  writeFileSync(join(stage, 'docs/docs_config.js'), `var versionNodes = ${JSON.stringify(nodes)};\n`);

  const css = 'body{font:1rem/1.65 system-ui,sans-serif;margin:0;color:#242424;background:#faf9f6}main,nav{max-width:64rem;margin:auto;padding:1.5rem}a{color:#164f82}td,th{padding:.75rem;text-align:left;border-bottom:1px solid #ccc}table{border-collapse:collapse;width:100%}code{overflow-wrap:anywhere}.skip{position:absolute;left:-9999px}.skip:focus{left:1rem}';
  writeFileSync(join(stage, 'site.css'), css);
  function page(title, content) {
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title} · Frameshift</title><link rel="stylesheet" href="/site.css"></head><body><a class="skip" href="#content">Skip to content</a><nav aria-label="Site"><a href="/">Guide</a> · <a href="/download/">Downloads</a> · <a href="/docs/">Documentation</a></nav><main id="content"><h1>${title}</h1>${content}</main></body></html>\n`;
  }
  mkdirSync(join(stage, 'download'));
  writeFileSync(join(stage, 'download/index.html'), page('Downloads', '<p>No qualified release or installer is available.</p><p>Intended host targets are macOS on Intel and Apple Silicon, and Ubuntu on amd64 and arm64. Platform installation and release qualification remain open.</p><p>The development app and browser simulation are not released installers.</p><p><a href="/docs/dev/">Read unreleased development documentation</a>.</p>'));
  writeFileSync(join(stage, 'docs/index.html'), page('Documentation', '<p>No release is available.</p><p><a href="/docs/dev/">Unreleased development documentation</a> describes the intended product and current implementation evidence.</p>'));
  writeFileSync(join(stage, '404.html'), page('Page not found', '<p>The requested page does not exist. Use the guide or documentation navigation to continue.</p>'));
  const guidePath = join(stage, 'index.html');
  const guide = readFileSync(guidePath, 'utf8');
  if (!guide.includes('<nav aria-label="Guide sections">')) throw new Error('Guide navigation contract changed');
  writeFileSync(guidePath, guide.replace('</nav>', '<a href="/download/">Downloads</a><a href="/docs/">Docs</a></nav>'));

  const headers = siteHeaders(readFileSync(join(stage, '_headers'), 'utf8'), versions[0].policy, versions.slice(1));
  if (headers.split('\n').some(line => line.length > 2_000)) throw new Error('Static header line exceeds the hosting limit');
  for (const file of inventory(stage).filter(file => file.path.endsWith('.html'))) {
    const csp = headersForPath(headers, '/' + file.path)['content-security-policy'];
    if (!csp || csp.includes(', ')) throw new Error(`Missing or overlapping CSP: ${file.path}`);
  }
  writeFileSync(join(stage, '_headers'), headers);
  const links = checkLinks(stage);
  checkDocumentationIndex(stage, pages);
  if (releaseDocs) checkDocumentationIndex(stage, pages, `/docs/${identity.tag}/`);
  const manifest = { schemaVersion: 1, channel: releaseDocs ? 'release-documentation' : 'development',
    commit, dirty, release: null, links, files: inventory(stage) };
  if (releaseDocs) Object.assign(manifest, { publishable: false, documentation: { tag: identity.tag, version: identity.version } });
  writeFileSync(join(stage, 'site-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

  if (JSON.stringify(getIdentity()) !== JSON.stringify(identity) ||
      git(['ls-files', '--cached', '--others', '--exclude-standard', '-z']).split('\0').filter(Boolean).sort().join('\0') !== sources.join('\0') ||
      inputs.some(input => digest(readFileSync(join(repository, input.path))) !== input.sha256)) {
    throw new Error('Source changed during the documentation build');
  }

  // This first-stage builder must never erase a retained release or its index.
  if (pathExists(output)) {
    const previousManifest = validateOutput();
    if (releaseDocs) {
      const retained = file => file.path.startsWith(`docs/${identity.tag}/`);
      const before = previousManifest.files.filter(retained);
      const after = manifest.files.filter(retained);
      if (JSON.stringify(before) !== JSON.stringify(after)) {
        const old = new Map(before.map(file => [file.path, file.sha256]));
        const changed = after.filter(file => old.get(file.path) !== file.sha256).map(file => file.path);
        throw new Error('Conflicting content for an existing documentation version: ' + changed.slice(0, 20).join(', '));
      }
      console.log(`Identical release documentation verified: ${identity.tag} at ${commit}`);
    }
  }
  if (!(releaseDocs && pathExists(output))) {
    const previous = output + '.previous';
    if (pathExists(previous)) throw new Error('Unreconciled previous site staging directory');
    if (pathExists(output)) renameSync(output, previous);
    try { renameSync(stage, output); }
    catch (error) { if (pathExists(previous)) renameSync(previous, output); throw error; }
    rmSync(previous, { recursive: true, force: true });
    console.log(`${releaseDocs ? 'Release documentation candidate' : 'Development site'} built: ${pages.length} maintained pages; ${links.pages} HTML pages; ${links.links} local links; ${output}`);
  }
} finally {
  rmSync(stage, { recursive: true, force: true });
}
