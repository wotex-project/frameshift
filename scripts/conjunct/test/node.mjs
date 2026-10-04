import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { Worker } from 'node:worker_threads';
import { RawKernel, WorkerKernel } from '@conjunct/kernel';
import * as data from '@conjunct/data';
import { renderGuide, prepareGeometry } from '@conjunct/guide';
import { exercise } from './consumer.mjs';

const cohort = JSON.parse(readFileSync('./cohort.json', 'utf8'));
const fixtures = Object.fromEntries(['scope', 'unsupported', 'duplicate'].map(name =>
  [name, new Uint8Array(readFileSync(`fixtures/${name}.json`))]));
globalThis.fetch = () => { throw new Error('consumer attempted network access'); };
assert.equal(typeof renderGuide, 'function');
assert.equal(typeof prepareGeometry, 'function');
const wasm = readFileSync('bundle/wasm/conjunct_abi.wasm');
const module = await WebAssembly.compile(wasm);
const raw = await RawKernel.instantiate(module);
const rawReport = await exercise(raw, data, cohort, fixtures, assert);

let afterPost = () => {};
function spawn() {
  const worker = new Worker(new URL('./worker.mjs', import.meta.url));
  return { post: (message, transfer) => { worker.postMessage(message, transfer); afterPost(message); },
    onMessage: callback => worker.on('message', callback),
    onFailure: callback => worker.on('error', callback), terminate: () => { void worker.terminate(); } };
}
const kernel = new WorkerKernel(spawn, module, { maxQueue: cohort.binding.max_queue });
try {
  assert.deepEqual(await exercise(kernel, data, cohort, fixtures, assert), rawReport);
  const configuration = readFileSync('configuration.json');
  const { context } = await kernel.create(configuration);
  kernel.close();
  await assert.rejects(kernel.load(context, fixtures.scope), { kind: 'stale_context' });
  const fresh = await kernel.create(configuration);
  assert.notEqual(fresh.context.generation, context.generation);
  const controller = new AbortController();
  afterPost = message => { if (message.op === 'load') controller.abort(); };
  const cancellation = kernel.load(fresh.context, fixtures.scope, { signal: controller.signal });
  await assert.rejects(cancellation, { kind: 'canceled' });
  afterPost = () => {};
  await assert.rejects(kernel.load(fresh.context, fixtures.scope), { kind: 'stale_context' });
  const restarted = await kernel.create(configuration);
  assert.equal(JSON.parse(new TextDecoder().decode(await kernel.load(restarted.context, fixtures.scope))).outcome, 'completed');
  writeFileSync('node-report.json', JSON.stringify(rawReport));
} finally {
  kernel.close();
}

// Queue admission happens synchronously before dispatch; no race against the
// speed of a tiny real operation is needed to establish the queue bound.
const bounded = new WorkerKernel(spawn, module, { maxQueue: 0 });
try {
  const first = bounded.describe();
  await assert.rejects(bounded.describe(), { kind: 'overloaded' });
  await first;
} finally {
  bounded.close();
}
console.log('Node: staged data, guide, raw WASM and Worker APIs pass; cancellation/replacement/queue refusal pass');
