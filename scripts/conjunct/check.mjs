import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { cohort, digest, inventory, verifyBundle } from './artifacts.mjs';

const repository = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const [bundleArgument, expectedDigest] = process.argv.slice(2);
assert(bundleArgument && expectedDigest, 'usage: check.mjs BUNDLE MANIFEST_DIGEST');
const sourceBundle = resolve(bundleArgument);
verifyBundle(sourceBundle, expectedDigest);
const work = mkdtempSync(join(tmpdir(), 'frameshift-conjunct-consumer-'));
const bundle = join(work, 'bundle');
cpSync(sourceBundle, bundle, { recursive: true });
const manifest = verifyBundle(bundle, expectedDigest);
const tsc = join(repository, 'apps/build-platform/assets/node_modules/typescript/bin/tsc');

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: work, stdio: 'inherit', ...options });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command} failed`);
}

async function browser() {
  const chromePath = process.env.FRAMESHIFT_CHROME || (process.platform === 'darwin'
    ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : '/usr/bin/google-chrome');
  assert(existsSync(chromePath), `Chrome required: set FRAMESHIFT_CHROME (${chromePath})`);
  const profile = join(work, 'chrome');
  const mime = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
    '.html': 'text/html', '.wasm': 'application/wasm' };
  const server = createServer((request, response) => {
    const path = resolve(work, `.${new URL(request.url, 'http://localhost').pathname}`);
    if (!path.startsWith(work + sep)) return response.writeHead(403).end();
    try {
      response.setHeader('Content-Type', mime[extname(path)] || 'application/octet-stream');
      response.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'");
      response.end(readFileSync(path));
    } catch { response.writeHead(404).end(); }
  });
  let chrome;
  let socket;
  const pending = new Map();
  let sequence = 0;
  const requests = [];
  const exceptions = [];
  const delay = ms => new Promise(resolve_ => setTimeout(resolve_, ms));
  async function wait(check, description) {
    for (let attempt = 0; attempt < 200; attempt++) {
      const result = await check();
      if (result) return result;
      await delay(50);
    }
    throw new Error(`timed out: ${description}`);
  }
  try {
    await new Promise(resolve_ => server.listen(0, '127.0.0.1', resolve_));
    const origin = `http://127.0.0.1:${server.address().port}`;
    const url = `${origin}/index.html`;
    chrome = spawn(chromePath, ['--headless=new', '--no-first-run', '--disable-gpu',
      '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { stdio: 'ignore' });
    const active = join(profile, 'DevToolsActivePort');
    await wait(() => existsSync(active), 'Chrome DevTools');
    const port = Number(readFileSync(active, 'utf8').split('\n')[0]);
    const pages = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    const page = pages.find(item => item.type === 'page');
    socket = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((resolve_, reject) => {
      socket.addEventListener('open', resolve_, { once: true });
      socket.addEventListener('error', reject, { once: true });
    });
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.method === 'Network.requestWillBeSent') requests.push(message.params.request.url);
      if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails);
      const request = pending.get(message.id);
      if (request) {
        pending.delete(message.id);
        clearTimeout(request.timer);
        if (message.error) request.reject(new Error(JSON.stringify(message.error)));
        else request.resolve(message.result);
      }
    });
    const command = (method, params = {}) => new Promise((resolve_, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 15_000);
      pending.set(id, { resolve: resolve_, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
    const evaluate = async expression => {
      const result = await command('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
      assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
      return result.result.value;
    };
    await command('Runtime.enable');
    await command('Network.enable');
    await command('Page.navigate', { url });
    await wait(() => evaluate('globalThis.conjunctReady === true'), 'browser Worker readiness');
    // After loading local artifacts, an actual browser network disconnect
    // establishes that data and kernel work do not call a host service.
    await command('Network.emulateNetworkConditions', { offline: true, latency: 0, downloadThroughput: 0, uploadThroughput: 0 });
    const report = await evaluate('globalThis.runConjunct()');
    assert.deepEqual(report, JSON.parse(readFileSync(join(work, 'node-report.json'), 'utf8')));
    assert.equal(exceptions.length, 0, JSON.stringify(exceptions));
    assert(requests.every(request => request.startsWith(origin + '/')), 'browser requested an external resource');
    writeFileSync(join(work, 'browser-report.json'), JSON.stringify(report));
    const version = await command('Browser.getVersion');
    return { browser: version.product, offline: true, external_requests: 0 };
  } finally {
    socket?.close();
    for (const item of pending.values()) clearTimeout(item.timer);
    if (chrome) {
      const exited = new Promise(resolve_ => chrome.once('exit', resolve_));
      chrome.kill('SIGTERM');
      await Promise.race([exited, delay(3000).then(() => chrome.kill('SIGKILL'))]);
    }
    await new Promise(resolve_ => server.close(resolve_));
  }
}

try {
  mkdirSync(join(work, 'node_modules/@conjunct'), { recursive: true });
  for (const name of ['kernel', 'data', 'guide']) cpSync(join(bundle, 'js', name), join(work, 'node_modules/@conjunct', name), { recursive: true });
  for (const name of ['consumer.mjs', 'node.mjs', 'worker.mjs', 'browser.mjs', 'types.ts', 'elixir.exs', 'fixtures']) {
    cpSync(new URL(`./test/${name}`, import.meta.url), join(work, name), { recursive: true });
  }
  writeFileSync(join(work, 'package.json'), JSON.stringify({ type: 'module', private: true }));
  writeFileSync(join(work, 'cohort.json'), JSON.stringify(cohort));
  writeFileSync(join(work, 'configuration.json'), JSON.stringify({ protocol: cohort.protocol, contract: cohort.contract, limits: cohort.limits }));
  writeFileSync(join(work, 'wrong-contract.json'), JSON.stringify({ protocol: cohort.protocol,
    contract: { ...cohort.contract, digest: 'sha256:' + '0'.repeat(64) }, limits: cohort.limits }));
  writeFileSync(join(work, 'index.html'), '<!doctype html><html lang="en"><meta charset="utf-8"><title>Conjunct consumer</title><script type="module" src="./browser.mjs"></script></html>');
  run(process.execPath, [tsc, '--noEmit', '--strict', '--skipLibCheck', 'false', '--moduleResolution', 'bundler',
    '--module', 'esnext', '--target', 'es2024', 'types.ts']);
  run(process.execPath, ['node.mjs']);
  const dependencies = ['conjunct_kernel', 'conjunct_wire', 'conjunct_data', 'telemetry'].map(name =>
    `{:${name}, path: ${JSON.stringify(join(bundle, 'elixir', name))}, override: true}`).join(',\n');
  writeFileSync(join(work, 'mix.exs'), `defmodule FrameshiftConsumer.MixProject do
  @moduledoc """
  Isolated qualification project consuming only verified staged producer packages.

  Local dependency paths bind the copied artifact bundle; no source checkout or
  package repository is consulted by the consumer. It starts no host service.
  """

  use Mix.Project
  def project, do: [app: :frameshift_consumer, version: "0.1.0", deps: [${dependencies}]]
end
`);
  const offline = { ...process.env, MIX_ENV: 'prod', HEX_OFFLINE: '1', CJ_LOCAL_DEPS: '0', ERL_FLAGS: '+S 2:2',
    MIX_HOME: join(work, 'mix-home'), HEX_HOME: join(work, 'hex-home') };
  // Rebar is a build tool supplied by the pinned Mix installation, not a
  // package fetched by the isolated consumer. Runtime packages are all staged.
  const rebar = spawnSync('mix', ['local.rebar', '--if-missing'], { cwd: repository, encoding: 'utf8' });
  assert.equal(rebar.status, 0, rebar.stderr);
  const rebarPath = process.env.MIX_REBAR3 || join(process.env.MIX_HOME || join(process.env.HOME, '.mix'), 'elixir/1-20-otp-29/rebar3');
  assert(existsSync(rebarPath), 'pinned Mix rebar3 unavailable');
  offline.MIX_REBAR3 = rebarPath;
  mkdirSync(offline.MIX_HOME);
  mkdirSync(offline.HEX_HOME);
  run('mix', ['deps.get', '--offline'], { env: offline });
  run('mix', ['compile', '--warnings-as-errors'], { env: offline });
  run('mix', ['run', 'elixir.exs', bundle, manifest.target, join(work, 'elixir-report.json')], { env: offline });
  assert.deepEqual(JSON.parse(readFileSync(join(work, 'elixir-report.json'), 'utf8')),
    JSON.parse(readFileSync(join(work, 'node-report.json'), 'utf8')), 'port/WASM original responses differ');
  const browserResult = await browser();
  const evidence = mkdtempSync(join(sourceBundle, '..', `${sourceBundle.split(sep).at(-1)}-consumer-`));
  for (const name of ['elixir-report.json', 'node-report.json', 'browser-report.json', 'frame-profile-probe.json',
    'configuration.json', 'wrong-contract.json', 'fixtures']) cpSync(join(work, name), join(evidence, name), { recursive: true });
  const output = join(evidence, 'report.json');
  const report = { version: 'frameshift.conjunct-consumer.v1', cohort_revision: cohort.revision,
    manifest_digest: expectedDigest, target: manifest.target, browser: browserResult,
    elixir_tests: 3, semantic_qualification: false,
    checker_files: inventory(fileURLToPath(new URL('.', import.meta.url))),
    responses_digest: digest(readFileSync(join(work, 'elixir-report.json'))) };
  writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
  console.log(`Staged Elixir/Node/browser consumers pass: ${output}`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
