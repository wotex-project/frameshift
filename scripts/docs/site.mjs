import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { lstatSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { extname, join, resolve, sep } from 'node:path';
export { releaseSourceIdentity } from '../../release/source.mjs';

export const digest = bytes => createHash('sha256').update(bytes).digest('hex');

export function pathExists(path) {
  try { lstatSync(path); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

export function sourceIdentity(repository, preview = false) {
  const git = args => execFileSync('git', args, { cwd: repository, encoding: 'utf8' }).trim();
  const commit = git(['rev-parse', 'HEAD']);
  const branch = git(['branch', '--show-current']);
  const dirty = git(['status', '--porcelain']).length !== 0;
  if (!preview && (branch !== 'main' || dirty)) throw new Error('Development site requires clean main; use --preview for uncommitted inspection');
  if (!/^[0-9a-f]{40}$/.test(commit)) throw new Error('Unsupported source commit identity');
  return { commit, branch, dirty, publishableDevelopment: !preview && !dirty && branch === 'main' };
}

export function headersForPath(text, pathname) {
  const headers = {};
  let matched = false;
  for (const line of text.split('\n')) {
    if (!line.trim() || line.startsWith('#')) continue;
    if (!/^\s/.test(line)) {
      const expression = line.trim().split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*');
      matched = new RegExp(`^${expression}$`).test(pathname);
    } else if (matched) {
      const position = line.indexOf(':');
      if (position < 0) throw new Error('Invalid static header rule');
      const name = line.slice(0, position).trim().toLowerCase();
      const value = line.slice(position + 1).trim();
      headers[name] = headers[name] ? headers[name] + ', ' + value : value;
    }
  }
  return headers;
}

export function siteHeaders(guideHeaders, policy, releases = []) {
  const guidePolicy = guideHeaders.match(/^\s+Content-Security-Policy: (.+)$/m)?.[1];
  if (!guidePolicy) throw new Error('Guide security policy missing');
  const common = guideHeaders.replace(/^\s+Content-Security-Policy: .+\n/m, '\n');
  const paths = ['/', '/index.html', '/404.html', '/download/*', '/docs/', '/docs/index.html'];
  return common + '\n' + paths.map(path => `${path}\n  Content-Security-Policy: ${guidePolicy}\n`).join('\n') +
    `\n/docs/dev/*\n  Content-Security-Policy: ${policy}\n  Cache-Control: no-cache\n` +
    releases.map(release => `\n/docs/v${release.version}/*\n  Content-Security-Policy: ${release.policy}\n  Cache-Control: public, max-age=31536000, immutable\n`).join('') +
    '\n/docs/docs_config.js\n  Cache-Control: no-cache\n\n/docs/\n  Cache-Control: no-cache\n\n/docs/index.html\n  Cache-Control: no-cache\n\n/download/*\n  Cache-Control: no-cache\n';
}

export function inventory(directory) {
  const files = [];
  function visit(relative) {
    const path = join(directory, relative);
    const stat = lstatSync(path);
    if (stat.isDirectory()) {
      for (const name of readdirSync(path).sort()) visit(join(relative, name));
    } else if (stat.isFile()) {
      if (stat.size > 25 * 1024 * 1024) throw new Error(`Oversized static asset: ${relative}`);
      files.push({ path: relative.split(sep).join('/'), bytes: stat.size, sha256: digest(readFileSync(path)) });
    } else {
      throw new Error(`Non-regular static asset: ${relative}`);
    }
  }
  visit('');
  if (files.length > 20_000) throw new Error('Static asset count exceeds the build budget');
  return files;
}

export function validateDevelopmentOutput(directory) {
  if (!lstatSync(directory).isDirectory()) throw new Error('Existing site output must be a real directory');
  const files = inventory(directory).filter(file => file.path !== 'site-manifest.json');
  if (files.some(file => /^docs\/v\d+\.\d+\.\d+\//.test(file.path))) {
    throw new Error('Retained release docs require the qualified publication assembler');
  }
  const manifest = JSON.parse(readFileSync(join(directory, 'site-manifest.json'), 'utf8'));
  if (manifest.schemaVersion !== 1 || manifest.channel !== 'development' || manifest.release !== null ||
      JSON.stringify(manifest.files) !== JSON.stringify(files)) {
    throw new Error('Existing development output inventory is unowned or changed');
  }
}

function unescapeHTML(text) {
  return text.replace(/&(?:amp|quot|apos|lt|gt|#\d+|#x[0-9a-f]+);/gi, entity => {
    const values = { '&amp;': '&', '&quot;': '"', '&apos;': "'", '&lt;': '<', '&gt;': '>' };
    if (values[entity]) return values[entity];
    const value = entity.slice(2, -1);
    return String.fromCodePoint(value[0].toLowerCase() === 'x' ? parseInt(value.slice(1), 16) : parseInt(value, 10));
  });
}

export function checkLinks(directory) {
  const files = inventory(directory);
  const paths = new Set(files.map(file => file.path));
  const ids = new Map();
  const documents = files.filter(file => extname(file.path) === '.html');
  for (const file of documents) {
    const html = readFileSync(join(directory, file.path), 'utf8');
    ids.set(file.path, new Set([...html.matchAll(/\bid=["']([^"']*)["']/g)].map(match => unescapeHTML(match[1]))));
  }
  const errors = [];
  let checked = 0;
  for (const file of documents) {
    const html = readFileSync(join(directory, file.path), 'utf8');
    for (const match of html.matchAll(/\b(?:href|src)=["']([^"']*)["']/g)) {
      const link = unescapeHTML(match[1]);
      const url = new URL(link, `https://frameshift.wotex.io/${file.path}`);
      if (url.origin !== 'https://frameshift.wotex.io') continue;
      let path = decodeURIComponent(url.pathname).slice(1);
      if (!path || path.endsWith('/')) path += 'index.html';
      if (!paths.has(path)) {
        errors.push(`${file.path}: missing ${link}`);
      } else if (url.hash && ids.has(path) && !ids.get(path).has(decodeURIComponent(url.hash.slice(1)))) {
        errors.push(`${file.path}: missing anchor ${link}`);
      }
      checked += 1;
    }
  }
  if (errors.length) throw new Error(`Broken site links (${errors.length}):\n${errors.slice(0, 50).join('\n')}`);
  return { pages: documents.length, links: checked };
}

export function checkDocumentationIndex(directory, pages, route = '/docs/dev/') {
  const html = readFileSync(join(directory, route.slice(1), 'docs--readme.html'), 'utf8');
  const linked = new Set([...html.matchAll(/href="([^"#]+)\.html/g)]
    .filter(match => match[1].startsWith(route)).map(match => match[1].slice(route.length)));
  const missing = pages.filter(page => page.source.startsWith('docs/') && page.source !== 'docs/README.md' && !linked.has(page.id));
  if (missing.length) throw new Error(`Documentation index omits: ${missing.map(page => page.source).join(', ')}`);
}

export function sharedVersionMenu(html) {
  return html.replaceAll('src="docs_config.js"', 'src="/docs/docs_config.js"');
}

export function canonicalDocumentationMetadata(directory) {
  // ExDoc 0.40.4 serializes maps in VM iteration order. Its search/sidebar
  // properties have identical meaning but may produce different asset hashes.
  // Keep lists and strings intact; sort only object keys before freezing bytes.
  const stableObject = value => Array.isArray(value) ? value.map(stableObject) :
    value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, stableObject(value[key])])) : value;
  const files = inventory(directory);
  const rewrites = files.filter(file => /^dist\/(search_data|sidebar_items)-[A-F0-9]{8}\.js$/.test(file.path)).map(file => {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(join(directory, file.path)));
    const match = /^(searchData|sidebarNodes)=(\{[\s\S]*\})$/.exec(text);
    const expected = file.path.startsWith('dist/search_data-') ? 'searchData' : 'sidebarNodes';
    if (!match || match[1] !== expected) throw new Error('Unsupported ExDoc metadata assignment');
    const content = match[1] + '=' + JSON.stringify(stableObject(JSON.parse(match[2])));
    const revision = createHash('md5').update(content).digest('hex').slice(0, 8).toUpperCase();
    const path = file.path.replace(/-[A-F0-9]{8}\.js$/, `-${revision}.js`);
    return { old: file.path, path, content };
  });
  if (rewrites.length !== 2 || !rewrites.some(item => item.old.startsWith('dist/search_data-')) ||
      !rewrites.some(item => item.old.startsWith('dist/sidebar_items-'))) {
    throw new Error('Expected the pinned ExDoc search and sidebar metadata assets');
  }
  for (const file of files.filter(file => file.path.endsWith('.html') || file.path === '.build')) {
    const path = join(directory, file.path);
    let text = readFileSync(path, 'utf8');
    for (const item of rewrites) text = text.replaceAll(item.old, item.path);
    writeFileSync(path, text);
  }
  for (const item of rewrites) {
    writeFileSync(join(directory, item.path), item.content);
    if (item.old !== item.path) rmSync(join(directory, item.old));
  }
}

export function validateReleaseDocumentationOutput(directory, identity) {
  if (!lstatSync(directory).isDirectory()) throw new Error('Existing release docs must be a real directory');
  const manifest = JSON.parse(readFileSync(join(directory, 'site-manifest.json'), 'utf8'));
  const files = inventory(directory).filter(file => file.path !== 'site-manifest.json');
  if (manifest.schemaVersion !== 1 || manifest.channel !== 'release-documentation' ||
      manifest.publishable !== false || manifest.release !== null ||
      manifest.commit !== identity.commit || manifest.documentation?.tag !== identity.tag ||
      manifest.documentation?.version !== identity.version ||
      JSON.stringify(manifest.files) !== JSON.stringify(files)) {
    throw new Error('Existing release documentation is conflicting, unowned or changed');
  }
  return manifest;
}

export function documentationPolicy(directory) {
  const hashes = new Set();
  for (const file of inventory(directory).filter(file => extname(file.path) === '.html')) {
    const html = readFileSync(join(directory, file.path), 'utf8');
    for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      if (!/\bsrc\s*=/.test(match[1])) {
        hashes.add(`'sha256-${createHash('sha256').update(match[2]).digest('base64')}'`);
      }
    }
  }
  return `default-src 'none'; script-src 'self' ${[...hashes].sort().join(' ')}; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`;
}

export function labelHeadingAnchors(html) {
  return html.replace(/(<a\b[^>]*class="hover-link"[^>]*)>/g, (match, attributes) =>
    /\baria-label=/.test(attributes) ? match : `${attributes} aria-label="Link to this section">`);
}

export function resolveRoute(directory, pathname) {
  const decoded = decodeURIComponent(pathname);
  const target = resolve(directory, `.${decoded}`);
  if ((target !== resolve(directory) && !target.startsWith(resolve(directory) + sep)) || decoded.split('/').some(part => part.startsWith('_'))) return null;
  try {
    return statSync(target).isDirectory() ? join(target, 'index.html') : target;
  } catch {
    return null;
  }
}
