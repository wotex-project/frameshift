import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const application = resolve(fileURLToPath(new URL('..', import.meta.url)));
const chromePath = process.env.FRAMESHIFT_CHROME || (process.platform === 'darwin'
  ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : '/usr/bin/google-chrome');
if (!existsSync(chromePath)) throw new Error('Set FRAMESHIFT_CHROME to an installed Chrome executable');
const directory = mkdtempSync(join(tmpdir(), 'frameshift-session-browser-'));
const stateFile = join(directory, 'fixture.json');
const profile = join(directory, 'chrome');
const backend = spawn('mise', ['exec', '--', 'mix', 'run', '--no-start', 'test/support/session_browser_fixture.exs'], {
  cwd: application, env: { ...process.env, MIX_ENV: 'test', FRAMESHIFT_SESSION_BROWSER_STATE: stateFile },
  stdio: ['pipe', 'pipe', 'pipe'],
});
// Raw dependency/request diagnostics never become browser-fixture output.
backend.stdout.resume();
backend.stderr.resume();
let chrome;
let socket;
let sequence = 0;
let stopRequested = false;
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
async function waitFor(check, description, milliseconds = 10_000) {
  const deadline = Date.now() + milliseconds;
  while (Date.now() < deadline) {
    if (await check()) return;
    await pause(50);
  }
  throw new Error(`Fixture deadline: ${description}`);
}
try {
  await waitFor(() => {
    if (backend.exitCode !== null) throw new Error('Isolated backend refused startup');
    return existsSync(stateFile);
  }, 'backend startup', 30_000);
  const fixture = JSON.parse(readFileSync(stateFile, 'utf8'));
  const control = async operation => {
    backend.stdin.write(`${operation}\n`);
    if (operation === 'stop') stopRequested = true;
    const expected = ++sequence;
    await waitFor(() => JSON.parse(readFileSync(stateFile, 'utf8')).sequence === expected, 'private fixture control');
  };
  const origin = fixture.origin;
  chrome = spawn(chromePath, ['--headless=new', '--no-first-run', '--disable-gpu',
    '--disable-background-networking', '--disable-component-update', '--disable-sync',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
  await waitFor(() => existsSync(join(profile, 'DevToolsActivePort')), 'Chrome startup');
  const port = Number(readFileSync(join(profile, 'DevToolsActivePort'), 'utf8').split('\n')[0]);
  const pages = await (await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(5000) })).json();
  const target = pages.find(page => page.type === 'page');
  assert.ok(target);
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true });
    socket.addEventListener('error', reject, { once: true });
  });
  let requestId = 0;
  const pending = new Map();
  const exceptions = [];
  const violations = [];
  const requests = [];
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails.text);
    if (message.method === 'Log.entryAdded' && message.params.entry.source === 'security') violations.push(message.params.entry.text);
    if (message.method === 'Network.requestWillBeSent') requests.push({ url: message.params.request.url, method: message.params.request.method });
    const promise = pending.get(message.id);
    if (!promise) return;
    pending.delete(message.id);
    if (message.error) promise.reject(new Error(message.error.message));
    else promise.resolve(message.result);
  });
  const command = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++requestId;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP deadline: ${method}`)); }, 10_000);
    pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const result = await command('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error('Browser evaluation refused');
    return result.result.value;
  };
  const text = () => evaluate('document.querySelector(".account")?.innerText || ""');
  const click = name => evaluate(`Array.from(document.querySelectorAll('.account button')).find(button => button.textContent.trim() === ${JSON.stringify(name)}).click()`);
  const open = async () => {
    await evaluate('document.querySelector(".account summary").focus()');
    assert.equal(await evaluate('document.activeElement.localName'), 'summary');
    await command('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    await command('Input.dispatchKeyEvent', { type: 'char', key: 'Enter', code: 'Enter', text: '\r', windowsVirtualKeyCode: 13 });
    await command('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    await waitFor(() => evaluate('document.querySelector(".account").open'), 'keyboard account open');
  };
  const password = async value => {
    await evaluate('document.querySelector("input[name=password]").focus()');
    await command('Input.insertText', { text: value });
  };
  const login = async value => {
    await evaluate('document.querySelector("input[name=email]").focus()');
    await command('Input.insertText', { text: fixture.email });
    await password(value);
    await command('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    await command('Input.dispatchKeyEvent', { type: 'char', key: 'Enter', code: 'Enter', text: '\r', windowsVirtualKeyCode: 13 });
    await command('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  };
  await command('Page.enable');
  await command('Runtime.enable');
  await command('Log.enable');
  await command('Network.enable');
  const version = await command('Browser.getVersion');
  await command('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await command('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }] });
  await command('Page.navigate', { url: origin });
  await waitFor(() => evaluate('!!document.querySelector("input[name=password]")'), 'Svelte and anonymous session hydration');
  await open();
  await waitFor(() => evaluate('!!document.querySelector("input[name=password]")'), 'anonymous session');
  assert.equal(await evaluate('document.documentElement.scrollWidth === innerWidth'), true);
  assert.equal(await evaluate('document.querySelector(".account .panel").getBoundingClientRect().left >= 0'), true);
  await evaluate('document.documentElement.style.fontSize = "200%"');
  assert.equal(await evaluate('document.documentElement.scrollWidth === innerWidth && document.querySelector(".account .panel").getBoundingClientRect().left >= 0'), true);
  const accessibility = await command('Accessibility.getFullAXTree');
  assert.deepEqual(accessibility.nodes.filter(node => !node.ignored && ['button', 'textField', 'DisclosureTriangle'].includes(node.role?.value) && !String(node.name?.value || '').trim()).map(node => node.role.value), []);
  await login('wrong fixture password');
  await waitFor(async () => (await text()).includes('Email or password was not accepted.'), 'credential refusal').catch(async error => {
    console.error('Public account state:', await text());
    console.error('Session request methods:', requests.filter(request => request.url.endsWith('/api/session')).map(request => request.method));
    throw error;
  });
  assert.equal(await evaluate('document.querySelector("input[name=password]").value === ""'), true);
  await evaluate('document.querySelector("input[name=email]").value = ""');
  await login(fixture.password);
  await waitFor(async () => (await text()).includes('Signed in.'), 'real HTTP sign-in');
  assert.equal(await evaluate('document.activeElement?.textContent === "Sign out"'), true);
  const cookies = await command('Network.getAllCookies');
  assert.deepEqual(cookies.cookies.filter(cookie => cookie.name === '_frameshift_session').map(cookie => ({ httpOnly: cookie.httpOnly, path: cookie.path, sameSite: cookie.sameSite })), [{ httpOnly: true, path: '/', sameSite: 'Strict' }]);
  assert.equal(await evaluate('document.cookie.includes("_frameshift_session")'), false);
  const previousDocument = await evaluate('performance.timeOrigin');
  await command('Page.reload', { ignoreCache: true });
  await waitFor(() => evaluate(`performance.timeOrigin !== ${JSON.stringify(previousDocument)} && document.readyState === 'complete' && document.querySelector('.account summary')?.innerText.includes('Signed in')`), 'new document and verified session refresh');
  await open();
  await control('down');
  const signedInDocument = await evaluate('performance.timeOrigin');
  await command('Page.reload', { ignoreCache: true });
  await waitFor(() => evaluate(`performance.timeOrigin !== ${JSON.stringify(signedInDocument)} && !!document.querySelector('.account button')`), 'new document with unavailable session');
  await open();
  await waitFor(async () => (await text()).includes('Account status is temporarily unavailable.'), 'lookup outage');
  await waitFor(() => evaluate('document.querySelectorAll(".profile-list li").length === 3'), 'public catalog during account outage');
  assert.equal(await evaluate('!document.querySelector("input[name=password]") && !document.querySelector(".account").textContent.includes("Signed out.")'), true);
  await control('restore');
  await click('Check account status');
  await waitFor(async () => (await text()).includes('Signed in.'), 'lookup recovery');
  await control('down');
  await click('Sign out');
  await waitFor(async () => (await text()).includes('Sign-out could not be confirmed.'), 'failed logout');
  await waitFor(async () => (await text()).includes('Last verified status: signed in.'), 'retained verified status').catch(async error => {
    console.error('Public failed logout state:', await evaluate('({open: document.querySelector(".account").open, text: document.querySelector(".account").textContent, visible: document.querySelector(".account").innerText})'));
    throw error;
  });
  assert.equal(await evaluate('document.activeElement?.textContent === "Check account status"'), true);
  await control('restore');
  await click('Check account status');
  await waitFor(() => evaluate('!!Array.from(document.querySelectorAll(".account button")).find(button => button.textContent.trim() === "Sign out")'), 'restored current account');
  await click('Sign out');
  await waitFor(async () => (await text()).includes('Signed out.'), 'verified logout');
  assert.equal(await evaluate('document.activeElement?.name === "email"'), true);
  assert.deepEqual(await evaluate('Object.keys(localStorage)'), []);
  // SvelteKit persists navigation scroll positions and empty snapshots on reload.
  assert.deepEqual(await evaluate('Object.keys(sessionStorage).sort()'), ['sveltekit:scroll', 'sveltekit:snapshot']);
  assert.equal(await evaluate(`Object.values(JSON.parse(sessionStorage['sveltekit:scroll'])).every(position => Object.keys(position).sort().join(',') === 'x,y' && Number.isFinite(position.x) && Number.isFinite(position.y)) && Object.values(JSON.parse(sessionStorage['sveltekit:snapshot'])).every(snapshot => Array.isArray(snapshot) && snapshot.every(value => value === undefined || value === null))`), true);
  assert.equal(await evaluate('document.querySelector("input[name=password]").value === ""'), true);
  const credentialRequests = requests.filter(request => request.method === 'POST' && request.url === `${origin}/api/session`);
  assert.equal(credentialRequests.length, 2);
  assert.equal(requests.filter(request => request.method === 'DELETE' && request.url === `${origin}/api/session`).length, 2);
  assert.deepEqual(requests.filter(request => !request.url.startsWith(origin) && !request.url.startsWith('data:')), []);
  assert.deepEqual(requests.filter(request => request.url.includes(fixture.password) || request.url.includes(fixture.email)), []);
  assert.deepEqual(exceptions, []);
  assert.deepEqual(violations, []);
  if (process.env.FRAMESHIFT_SESSION_SCREENSHOT) {
    const screenshot = await command('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    writeFileSync(process.env.FRAMESHIFT_SESSION_SCREENSHOT, Buffer.from(screenshot.data, 'base64'));
  }
  await evaluate('document.documentElement.style.fontSize = "200%"');
  assert.equal(await evaluate('document.documentElement.scrollWidth === innerWidth'), true);
  for (let step = 0; step < 2; step++) {
    await command('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
    await command('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  }
  assert.equal(await evaluate('document.activeElement?.textContent === "Sign in" && document.activeElement.getBoundingClientRect().top >= 0 && document.activeElement.getBoundingClientRect().bottom <= innerHeight'), true);
  if (process.env.FRAMESHIFT_SESSION_SCREENSHOT) {
    const largeText = await command('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    writeFileSync(`${process.env.FRAMESHIFT_SESSION_SCREENSHOT}.large-text.png`, Buffer.from(largeText.data, 'base64'));
  }
  await control('stop');
  console.log(`${version.product} session join passed: generated schema/routes, keyboard, narrow/reduced-motion/200% text UI, native sign-in/refusal, HttpOnly cookie, reload, lookup outage, failed logout custody, recovery and verified logout; navigation-only browser storage and no credential URL or automatic retry.`);
} finally {
  socket?.close();
  if (chrome && chrome.exitCode === null) {
    await new Promise(resolve => { chrome.once('exit', resolve); chrome.kill('SIGTERM'); });
  }
  if (backend.exitCode === null) {
    backend.stdin.end(stopRequested ? undefined : 'stop\n');
    await Promise.race([new Promise(resolve => backend.once('exit', resolve)), pause(5000)]);
    if (backend.exitCode === null) backend.kill('SIGTERM');
  }
  rmSync(directory, { recursive: true, force: true, maxRetries: 20, retryDelay: 50 });
}
