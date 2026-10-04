import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkDocumentationIndex, checkLinks, digest, documentationPolicy, headersForPath, inventory, labelHeadingAnchors, siteHeaders, sourceIdentity, validateDevelopmentOutput } from './site.mjs';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const arguments_ = process.argv.slice(2);
if (arguments_.length && (arguments_.length !== 1 || arguments_[0] !== '--preview')) {
  throw new Error('usage: scripts/build-site [--preview]');
}
const preview = arguments_[0] === '--preview';
const git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8' }).trim();
const identity = sourceIdentity(repository, preview);
const { commit, branch, dirty } = identity;
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

const output = join(repository, 'var', preview ? 'site-preview' : 'site');
if (existsSync(output)) validateDevelopmentOutput(output);
mkdirSync(dirname(output), { recursive: true });
const stage = mkdtempSync(join(dirname(output), '.site-stage-'));
const inputPath = join(stage, '.build-input.json');
try {
  execFileSync(join(repository, 'scripts/build-guide'), { cwd: repository, stdio: 'inherit' });
  cpSync(join(repository, 'apps/guide/dist'), stage, { recursive: true });
  const docs = join(stage, 'docs/dev');
  mkdirSync(docs, { recursive: true });
  writeFileSync(inputPath, JSON.stringify({ root: repository, output: docs, commit, dirty, preview, pages }));
  execFileSync('mise', ['exec', '--', 'mix', 'compile', '--force', '--warnings-as-errors'],
    { cwd: join(repository, 'apps/core'), env: { ...process.env, MIX_ENV: 'dev' }, stdio: 'inherit' });
  execFileSync('mise', ['exec', '--', 'mix', 'run', '--no-start', '../../scripts/docs/render.exs', inputPath],
    { cwd: join(repository, 'apps/core'), env: { ...process.env, MIX_ENV: 'dev' }, stdio: 'inherit' });
  rmSync(inputPath);
  for (const file of inventory(docs).filter(file => file.path.endsWith('.html'))) {
    const path = join(docs, file.path);
    writeFileSync(path, labelHeadingAnchors(readFileSync(path, 'utf8')));
  }

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

  const policy = documentationPolicy(docs);
  const headers = siteHeaders(readFileSync(join(stage, '_headers'), 'utf8'), policy);
  if (headers.split('\n').some(line => line.length > 2_000)) throw new Error('Static header line exceeds the hosting limit');
  for (const file of inventory(stage).filter(file => file.path.endsWith('.html'))) {
    const csp = headersForPath(headers, '/' + file.path)['content-security-policy'];
    if (!csp || csp.includes(', ')) throw new Error(`Missing or overlapping CSP: ${file.path}`);
  }
  writeFileSync(join(stage, '_headers'), headers);
  const links = checkLinks(stage);
  checkDocumentationIndex(stage, pages);
  writeFileSync(join(stage, 'docs/dev/build.json'), JSON.stringify({ schemaVersion: 1,
    channel: 'development', commit, dirty, preview, publishableDevelopment: identity.publishableDevelopment,
    pages, inputs, toolchains: { mise: readFileSync(join(repository, '.mise.toml'), 'utf8') } }, null, 2) + '\n');
  writeFileSync(join(stage, 'site-manifest.json'), JSON.stringify({ schemaVersion: 1, channel: 'development',
    commit, dirty, release: null, links, files: inventory(stage) }, null, 2) + '\n');

  if (JSON.stringify(sourceIdentity(repository, preview)) !== JSON.stringify(identity) ||
      git(['ls-files', '--cached', '--others', '--exclude-standard', '-z']).split('\0').filter(Boolean).sort().join('\0') !== sources.join('\0') ||
      inputs.some(input => digest(readFileSync(join(repository, input.path))) !== input.sha256)) {
    throw new Error('Source changed during the documentation build');
  }

  // This first-stage builder must never erase a retained release or its index.
  if (existsSync(output)) validateDevelopmentOutput(output);
  const previous = output + '.previous';
  if (existsSync(previous)) throw new Error('Unreconciled previous site staging directory');
  if (existsSync(output)) renameSync(output, previous);
  try { renameSync(stage, output); }
  catch (error) { if (existsSync(previous)) renameSync(previous, output); throw error; }
  rmSync(previous, { recursive: true, force: true });
  console.log(`Development site built: ${pages.length} maintained pages; ${links.pages} HTML pages; ${links.links} local links; ${output}`);
} finally {
  rmSync(stage, { recursive: true, force: true });
}
