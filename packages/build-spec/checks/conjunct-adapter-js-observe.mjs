import {readFileSync, writeFileSync} from 'node:fs';
import {quantity, transform, localId} from '../js/conjunct-adapter.mjs';

const input = JSON.parse(readFileSync(process.argv[2]));
const operations = {quantity, transform, local_id:localId};
const call = hand => operations[hand.operation](...hand.args);
const results = {runtime:{node:process.version,platform:process.platform,arch:process.arch},hands:[],properties:[],preflight:[],samples:[]};
for(const hand of input.cases) results.hands.push({id:hand.id,actual:await call(hand)});
for(const property of input.properties) results.properties.push({id:property.id,actual:await call(property)});
for(const hand of input.smoke) results.preflight.push({id:hand.id,actual:await call(hand)});
for(let repeat=1;repeat<=2;repeat++) for(const hand of input.smoke){
  const before=process.hrtime.bigint(),actual=await call(hand),elapsed=process.hrtime.bigint()-before;
  results.samples.push({id:hand.id,repeat,elapsed_ns:String(elapsed),actual});
}
writeFileSync(process.argv[3],JSON.stringify(results,null,2)+'\n',{flag:'wx'});
