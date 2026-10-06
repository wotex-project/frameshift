import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {v1Inputs} from '../js/conjunct-adapter.mjs';
const fixture=JSON.parse(readFileSync(new URL('./fixtures/conjunct-v1-inputs.expected.json',import.meta.url)));
const expand=value=>Array.isArray(value)?value.map(expand):value&&typeof value==='object'?(value.$source!==undefined?fixture.sources[value.$source]:value.$repeat!==undefined?expand(value.$repeat.value).repeat(value.$repeat.count):value.$copies!==undefined?Array.from({length:value.$copies.count},()=>expand(value.$copies.value)):value):value;

test('all original domains and complete authored success/refusal results agree',async()=>{
 assert.equal(fixture.cases.length,32);
 for(const hand of fixture.cases) assert.deepEqual(await v1Inputs(...expand(hand.args)),hand.expected,hand.id);
});

test('a complete closure stays independent and immutable for two consumers',async()=>{
 const hand=fixture.cases.find(hand=>hand.id==='complete');
 const first=await v1Inputs(...expand(hand.args)),second=await v1Inputs(...expand(hand.args));
 assert.deepEqual(first,hand.expected);assert.deepEqual(second,hand.expected);
 assert.notEqual(first.value,second.value);assert.notEqual(first.value.documents,second.value.documents);
 assert(Object.isFrozen(first.value));assert(Object.isFrozen(first.value.documents));
 for(const record of first.value.documents) assert(Object.isFrozen(record));
 assert.throws(()=>first.value.documents[0].bytes='changed',TypeError);
});

test('resource and sparse-array refusal precedes cryptography',async context=>{
 let hashes=0;
 context.mock.method(globalThis.crypto.subtle,'digest',async()=>{hashes++;throw new Error('unexpected');});
 for(const hand of fixture.cases.filter(hand=>hand.id.startsWith('document-ceiling-')||hand.id.startsWith('collection-ceiling-')||hand.id==='combined-ceiling')) {
  assert.deepEqual(await v1Inputs(...expand(hand.args)),hand.expected,hand.id);
 }
 const args=expand(fixture.cases[0].args);args[1]=new Array(1);
 assert.deepEqual(await v1Inputs(...args),{ok:false,error:'invalid_document'});
 assert.equal(hashes,0);
});
