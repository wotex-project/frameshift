import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';
import {quantity, transform, localId} from '../js/conjunct-adapter.mjs';

const hands = JSON.parse(readFileSync(new URL('fixtures/conjunct-adapter-v1.expected.json', import.meta.url)));
const operations = {quantity, transform, local_id: localId};

test('all complete authored conversion hands preserve exact values and refusals', async () => {
  assert.equal(hands.cases.length, 44);
  for (const hand of hands.cases) {
    const original = JSON.stringify(hand.args);
    const actual = await operations[hand.operation](...hand.args);
    assert.deepEqual(actual, hand.expected, hand.id);
    assert.equal(JSON.stringify(hand.args), original);
  }
});

test('integers beyond the v1 ceiling refuse before exact conversion', () => {
  assert.deepEqual(quantity('component', 'mass', 'g', 0, 2**53), {ok:false,error:'invalid_range'});
  assert.deepEqual(transform(0, [2**53,0,0], null, null), {ok:false,error:'invalid_range'});
});
