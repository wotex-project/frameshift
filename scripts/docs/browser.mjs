import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { extname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { headersForPath, resolveRoute } from './site.mjs';

const repository = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const output = join(repository, 'var/site-preview');
const chromePath = process.env.FRAMESHIFT_CHROME || (process.platform === 'darwin'
  ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : '/usr/bin/google-chrome');
if (!existsSync(chromePath)) throw new Error('Set FRAMESHIFT_CHROME to an installed Chrome executable');
const headerRules = readFileSync(join(output, '_headers'), 'utf8');
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.jpg': 'image/jpeg', '.woff2': 'font/woff2' };
const server = createServer((request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  const target = resolveRoute(output, path);
  const found = target && existsSync(target);
  const file = found ? target : join(output, '404.html');
  response.writeHead(found ? 200 : 404, { ...headersForPath(headerRules, found ? path : '/404.html'),
    'Content-Type': types[extname(file)] || 'application/octet-stream' });
  response.end(readFileSync(file));
});
const profile = mkdtempSync(join(tmpdir(), 'frameshift-docs-chrome-'));
let chrome;
let socket;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function waitFor(check, description) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await check()) return;
    await delay(50);
  }
  throw new Error(`Timed out: ${description}`);
}

try {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  for (const path of ['/docs/', '/download/', '/docs/dev/', '/docs/dev/Frameshift.Library.html', '/docs/dev/missing.html']) {
    const response = await fetch(origin + path);
    assert.equal(response.status, path.includes('missing') ? 404 : 200, path);
  }
  const url = origin + '/docs/dev/';
  chrome = spawn(chromePath, ['--headless=new', '--no-first-run', '--disable-gpu',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, url], { stdio: 'ignore' });
  await waitFor(() => existsSync(join(profile, 'DevToolsActivePort')), 'Chrome port');
  const port = Number(readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0]);
  const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const target = pages.find(page => page.type === 'page' && page.url.startsWith(origin));
  assert.ok(target);
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  let sequence = 0;
  const pending = new Map();
  const exceptions = [];
  const violations = [];
  const requests = [];
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails.text);
    if (message.method === 'Log.entryAdded' && message.params.entry.source === 'security') violations.push(message.params.entry.text);
    if (message.method === 'Network.requestWillBeSent') requests.push(message.params.request.url);
    const item = pending.get(message.id);
    if (!item) return;
    pending.delete(message.id);
    if (message.error) item.reject(new Error(message.error.message));
    else item.resolve(message.result);
  });
  const command = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timeout = setTimeout(() => { pending.delete(id); reject(new Error(`CDP deadline: ${method}`)); }, 10_000);
    pending.set(id, { resolve: result => { clearTimeout(timeout); resolve(result); }, reject: error => { clearTimeout(timeout); reject(error); } });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const result = await command('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    return result.result.value;
  };
  const navigate = async path => {
    await command('Page.navigate', { url: origin + path });
    const expected = new URL(path, origin).pathname;
    await waitFor(() => evaluate(`location.pathname === ${JSON.stringify(expected)} && document.readyState === 'complete'`), path);
  };
  await command('Page.enable');
  await command('Runtime.enable');
  await command('Log.enable');
  await command('Network.enable');
  await command('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await navigate('/docs/dev/docs--readme.html');
  assert.match(await evaluate('document.body.innerText'), /Unreleased preview/);
  await waitFor(() => evaluate('document.querySelector("#sidebar-list-nav")'), 'ExDoc navigation');
  assert.deepEqual(await evaluate('({viewport:innerWidth,document:document.documentElement.scrollWidth})'), { viewport: 390, document: 390 });
  const ax = await command('Accessibility.getFullAXTree');
  const interactive = new Set(['button', 'link', 'textField', 'comboBox']);
  assert.deepEqual(ax.nodes.filter(node => !node.ignored && interactive.has(node.role?.value) && !String(node.name?.value || '').trim()).map(node => node.role.value), []);
  await evaluate('document.querySelector(".search-input").focus()');
  await command('Input.insertText', { text: 'restore_master' });
  await command('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await command('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await waitFor(() => evaluate('document.querySelector("#search")?.innerText.includes("restore_master")'), 'real ExDoc search result');
  await navigate('/docs/dev/Frameshift.Library.html#restore_master/3');
  assert.equal(await evaluate('!!document.getElementById("restore_master/3")'), true);
  assert.equal(await evaluate('document.documentElement.scrollWidth === innerWidth'), true);
  assert.equal(await evaluate('versionNodes[0].url'), '/docs/dev/');
  if (process.env.FRAMESHIFT_DOCS_SCREENSHOT) {
    const screenshot = await command('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    writeFileSync(process.env.FRAMESHIFT_DOCS_SCREENSHOT, Buffer.from(screenshot.data, 'base64'));
  }
  await command('Emulation.setScriptExecutionDisabled', { value: true });
  await navigate('/docs/dev/docs--architecture--library-backup.html');
  assert.match(await evaluate('document.querySelector("main").innerText'), /Restore/);
  await navigate('/download/');
  assert.match(await evaluate('document.querySelector("main").innerText'), /No qualified release or installer/);
  await command('Emulation.setScriptExecutionDisabled', { value: false });
  await navigate('/');
  await waitFor(() => evaluate('document.querySelector("#profile-result")?.textContent'), 'combined guide hydration');
  assert.equal(await evaluate('document.documentElement.scrollWidth === innerWidth'), true);
  assert.deepEqual(exceptions, []);
  assert.deepEqual(violations, []);
  assert.deepEqual(requests.filter(url => !url.startsWith(origin) && !url.startsWith('data:')), []);
  console.log('Chrome docs smoke passed: routes/404, narrow viewport, named controls, keyboard search, API anchor, version data, no-JS recovery/download text and generated CSP.');
} finally {
  socket?.close();
  if (chrome && chrome.exitCode === null) {
    await new Promise(resolve => {
      chrome.once('exit', resolve);
      chrome.kill('SIGTERM');
    });
  }
  await new Promise(resolve => server.close(resolve));
  rmSync(profile, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 });
}
