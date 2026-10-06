import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {v1Inventory} from '../js/conjunct-adapter.mjs';
const fixture=JSON.parse(readFileSync(new URL('fixtures/conjunct-v1-inventory.expected.json',import.meta.url)));
const expand=v=>Array.isArray(v)?v.map(expand):v&&typeof v==='object'?(v.$source!==undefined?fixture.sources[v.$source]:v.$repeat!==undefined?expand(v.$repeat.value).repeat(v.$repeat.count):v.$copies!==undefined?Array.from({length:v.$copies.count},()=>expand(v.$copies.value)):v):v;
const deepFrozen=value=>value===null||typeof value!=='object'||(Object.isFrozen(value)&&Object.values(value).every(deepFrozen));
test('all authored full source inventories and refusals',async()=>{
 for(const hand of fixture.cases)assert.deepEqual(await v1Inventory(...expand(hand.args)),hand.expected,hand.id);
});
test('complete immutable nodes and independent caller results',async()=>{
 const args=expand(fixture.cases.find(hand=>hand.id==='complete').args),original=structuredClone(args);
 const first=await v1Inventory(...args),second=await v1Inventory(...args);
 assert.deepEqual(args,original);assert(deepFrozen(first.value));assert.deepEqual(first,second);
 assert.notEqual(first.value,second.value);assert.notEqual(first.value.nodes,second.value.nodes);
 assert.equal(first.value.nodes.length,1050);
 assert(first.value.nodes.some(node=>node.document_kind==='compilation-context'&&node.pointer===''));
 assert(first.value.nodes.some(node=>node.pointer==='/requires'&&node.value.type==='array'&&node.value.length===0));
});
