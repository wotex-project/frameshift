import {readFileSync,writeFileSync} from 'node:fs';
import {performance} from 'node:perf_hooks';
const [modulePath,inputPath,outputPath]=process.argv.slice(2);
const input=JSON.parse(readFileSync(inputPath,'utf8'));
const state=()=>({environment:{...process.env},globals:Object.getOwnPropertyNames(globalThis).sort(),handles:process.getActiveResourcesInfo().sort()});
const before=state();
writeFileSync(outputPath+'.import-original.json',JSON.stringify({modulePath,before})+'\n',{flag:'wx'});
const loaded=await import('../js/conjunct-adapter.mjs');
writeFileSync(outputPath+'.import-actual.json',JSON.stringify(state())+'\n',{flag:'wx'});
const invoke=args=>loaded.v1Inventory(...args);
const observe=async hands=>{
 const records=[];
 for(const hand of hands) records.push({id:hand.id,actual:await invoke(hand.args)});
 return records;
};
const hands=await observe(input.cases),properties=await observe(input.properties);
const preflight=await observe(input.smoke),samples=[];
for(let repeat=1;repeat<=5;repeat++) for(const hand of input.smoke){
 const started=performance.now(),actual=await invoke(hand.args),elapsed_ns=Math.round((performance.now()-started)*1000000);
 samples.push({id:hand.id,repeat,elapsed_ns,actual});
}
const deepFrozen=value=>value===null||typeof value!=='object'||(Object.isFrozen(value)&&Object.values(value).every(deepFrozen));
const frozen=[];
for(const hand of input.cases.filter(hand=>hand.expected.ok)){
 const first=await invoke(hand.args),second=await invoke(hand.args),value=first.value;
 frozen.push({id:hand.id,value,second:second.value,frozen:deepFrozen(value),array_frozen:Object.isFrozen(value.inputs.documents),records_frozen:value.inputs.documents.map(Object.isFrozen),independent:value!==second.value&&value.nodes!==second.value.nodes});
}
let snapshot=null;
if(input.snapshot){
 const args=structuredClone(input.snapshot.args),original=structuredClone(args);
 writeFileSync(outputPath+'.snapshot-original.json',JSON.stringify({args:original,expected:input.snapshot.expected})+'\n',{flag:'wx'});
 const digest=globalThis.crypto.subtle.digest,events=[];
 globalThis.crypto.subtle.digest=async function(...call){
  events.push({before:structuredClone(args)});
  for(const slot of [1,2,3]) args[slot].splice(0,args[slot].length,'changed-by-caller');
  events.at(-1).after=structuredClone(args);
  return digest.apply(this,call);
 };
 try{snapshot={original,actual:await invoke(args),after:args,events};}
 finally{globalThis.crypto.subtle.digest=digest;}
}
writeFileSync(outputPath,JSON.stringify({hands,properties,preflight,samples,frozen,snapshot})+'\n',{flag:'wx'});
