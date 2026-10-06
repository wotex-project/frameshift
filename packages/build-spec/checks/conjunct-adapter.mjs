// Retained exact conversion qualification, with an independent corner model.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {mkdirSync, readdirSync, readFileSync, writeFileSync, lstatSync, readlinkSync} from 'node:fs';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const root = resolve(process.argv[2]);
const directory = resolve(process.argv[3]);
const packageRoot = join(root, 'packages/build-spec');
const norm = 'c11f31dc393499c13ce0795763eee2134f3f4c7e';
const retain = (name, value) => writeFileSync(join(directory, name), JSON.stringify(value, null, 2)+'\n', {flag:'wx'});
const digest = raw => createHash('sha256').update(raw).digest('hex');
const command = (id, executable, args, cwd, environment={}) => {
  retain(`${id}-command-original.json`, {executable,args,cwd,environment});
  const actual = spawnSync(executable,args,{cwd,env:{...process.env,...environment},encoding:'utf8',maxBuffer:16*1024*1024});
  retain(`${id}-command-actual.json`, {status:actual.status,signal:actual.signal,error:actual.error?.message??null,stdout:actual.stdout,stderr:actual.stderr});
  assert.equal(actual.error,undefined,`${id}: infrastructure error`);
  assert.equal(actual.status,0,`${id}: command failed`);
  return actual.stdout;
};
const source = relative => ({path:relative,bytes:readFileSync(join(root,relative)).toString('base64')});
const inventory = (base, relative='') => {
  const file=join(base,relative), stat=lstatSync(file);
  if (stat.isDirectory()) return readdirSync(file).sort().flatMap(name=>inventory(base,join(relative,name)));
  if (stat.isSymbolicLink()) return [{path:relative,type:'symlink',mode:stat.mode&0o7777,target:readlinkSync(file)}];
  assert(stat.isFile(),'nonregular selected source');
  const bytes=readFileSync(file);
  return [{path:relative,mode:stat.mode&0o7777,bytes:bytes.toString('base64'),sha256:digest(bytes)}];
};
const normFiles=['docs/architecture/conjunct-integration.md','packages/build-spec/test/fixtures/conjunct-adapter-v1.expected.json'];
for (const relative of normFiles) {
  const authored=command(`norm-${normFiles.indexOf(relative)}`,'git',['show',`${norm}:${relative}`],root);
  assert.equal(readFileSync(join(root,relative),'utf8'),authored,'authored norm changed');
}
const selected={
  norm,git:command('source-git','git',['status','--porcelain=v1','--untracked-files=all'],root),
  files:normFiles.concat(['packages/build-spec/lib/frameshift_build/conjunct_adapter.ex','packages/build-spec/js/conjunct-adapter.mjs',
    'packages/build-spec/checks/conjunct-adapter.mjs','packages/build-spec/checks/conjunct-adapter-js-observe.mjs','packages/build-spec/checks/conjunct-adapter-observe.exs','packages/build-spec/checks/conjunct-adapter-fault.exs',
    'packages/build-spec/lib/frameshift_build/conjunct_inputs.ex','packages/build-spec/js/v1-inputs.mjs',
    'scripts/check-conjunct-adapter','scripts/check-build-spec','scripts/check','packages/build-spec/mix.exs','packages/build-spec/mix.lock',
    'packages/build-spec/gleam.toml','packages/build-spec/manifest.toml']).map(source),
  buildSpec:inventory(join(packageRoot,'src')),physical:inventory(join(root,'packages/decision-kernel/src')),
  javascript:inventory(join(packageRoot,'build/dev/javascript')),
};
retain('source-original.json',selected);
const hands=JSON.parse(readFileSync(join(packageRoot,'test/fixtures/conjunct-adapter-v1.expected.json')));
assert.equal(hands.cases.length,44);
const rational=(n,d=1n)=>{
  n=BigInt(n);d=BigInt(d);let a=n<0n?-n:n,b=d;
  while(b){[a,b]=[b,a%b];}
  return {n:String(n/a),d:String(d/a)};
};
// Construct the rotated-origin correction from all corners, without its table.
const originalPoint=(turn,p,w,h,point)=>{
  const rotate=([x,y,z])=>{
    for(let i=0;i<turn/90;i++) [x,y]=[-y,x];
    return [x,y,z];
  };
  const corners=[];
  for(const x of [0,w]) for(const y of [0,h]) corners.push(rotate([x,y,0]));
  const min=[0,1].map(axis=>Math.min(...corners.map(c=>c[axis])));
  const value=rotate(point);
  const actual=[p[0]+value[0]-min[0],p[1]+value[1]-min[1],p[2]+value[2]];
  return [actual[0],-actual[1],-actual[2]].map(n=>rational(n,1000000n));
};
const properties=[];
for(const seed of [20261006,27182818,31415926]){
  let state=BigInt(seed);
  const draw=maximum=>{state=(1664525n*state+1013904223n)%4294967296n;return Number(state%BigInt(maximum));};
  for(let i=0;i<300;i++){
    const turn=draw(4)*90,w=draw(5000000)+1,h=draw(5000000)+1,p=[draw(5000001),draw(5000001),draw(5000001)];
    const point=[draw(2)*w,draw(2)*h,draw(5000001)];
    properties.push({id:`${seed}-${i}`,operation:'transform',args:[turn,p,[w,w],[h,h]],point,expected_point:originalPoint(turn,p,w,h,point)});
  }
}
const smoke=hands.smoke.case_ids.map(id=>{const hand=hands.cases.find(c=>c.id===id);assert(hand);return hand;});
const original={cases:hands.cases,properties,smoke};
retain('original.json',original);
const observe=async(path,name,input)=>{
  const template=readFileSync(join(packageRoot,'checks/conjunct-adapter-js-observe.mjs'),'utf8');
  const program=template.replace("'../js/conjunct-adapter.mjs'",`'${pathToFileURL(path).href}'`);
  const caller=join(directory,`${name}-caller.mjs`),inputPath=join(directory,`${name}-input-original.json`),output=join(directory,`${name}-actual.json`);
  retain(`${name}-caller-original.json`,{template,program,path,input});
  writeFileSync(caller,program,{flag:'wx'});retain(`${name}-input-original.json`,input);
  command(name,'node',[caller,inputPath,output],packageRoot);
  return JSON.parse(readFileSync(output));
};
const elixir=(module,name,inputPath)=>{
  const own=join(directory,name);mkdirSync(own);
  const output=join(own,'actual.json');
  command(name,'mix',['run','--no-start','--no-compile','checks/conjunct-adapter-observe.exs',inputPath,output,module,own],packageRoot,{MIX_ENV:'test'});
  return JSON.parse(readFileSync(output));
};
const pointFor=(transform,point)=>{
  assert.equal(transform.rotation.length,9);assert.equal(transform.translation.length,3);
  const add=(a,b)=>rational(BigInt(a.n)*BigInt(b.d)+BigInt(b.n)*BigInt(a.d),BigInt(a.d)*BigInt(b.d));
  const mul=(a,b)=>rational(BigInt(a.n)*BigInt(b.n),BigInt(a.d)*BigInt(b.d));
  const converted=[point[0],-point[1],-point[2]].map(n=>rational(n,1000000n));
  return [0,1,2].map(row=>converted.reduce((sum,p,column)=>add(sum,mul(transform.rotation[row*3+column],p)),transform.translation[row]));
};
const differences=(input,result)=>{
  assert.equal(result.hands.length,input.cases.length,'truncated actual hands');
  assert.equal(result.properties.length,input.properties.length,'truncated actual properties');
  const bad=[];
  for(let i=0;i<input.cases.length;i++){
    assert.equal(result.hands[i].id,input.cases[i].id);
    if(JSON.stringify(result.hands[i].actual)!==JSON.stringify(input.cases[i].expected)){
      try{assert.deepEqual(result.hands[i].actual,input.cases[i].expected);}catch{bad.push(input.cases[i].id);}
    }
  }
  for(let i=0;i<input.properties.length;i++){
    assert.equal(result.properties[i].id,input.properties[i].id);
    assert.equal(result.properties[i].actual.ok,true,'fault did not execute a transform');
    try{assert.deepEqual(pointFor(result.properties[i].actual.value,input.properties[i].point),input.properties[i].expected_point);}
    catch{bad.push(input.properties[i].id);}
  }
  return bad;
};
const js=await observe(join(packageRoot,'js/conjunct-adapter.mjs'),'javascript',original);
const beam=elixir('FrameshiftBuild.ConjunctAdapter','elixir',join(directory,'original.json'));
for(const [runtime,result] of [['javascript',js],['elixir',beam]]){
  const bad=differences(original,result);retain(`${runtime}-comparison.json`,{bad});assert.deepEqual(bad,[]);
  assert.equal(result.samples.length,10);
  for(const entry of [...result.preflight,...result.samples]) assert.deepEqual(entry.actual,smoke.find(c=>c.id===entry.id).expected);
}
const reduced={
  offset:{cases:[],properties:[{id:'reduced-offset',operation:'transform',args:[90,[0,0,0],[1,1],[1,1]],point:[0,0,0],expected_point:[rational(1,1000000n),rational(0),rational(0)]}],smoke:[]},
  temperature:{cases:[{id:'reduced-temperature',operation:'quantity',args:['component','temperature.operating','mc',0,0],expected:{ok:true,value:{type:'interval',lower:{quantity_kind:'temperature',unit:'K',value:rational(27315,100)},upper:{quantity_kind:'temperature',unit:'K',value:rational(27315,100)}}}}],properties:[],smoke:[]},
};
const mutations=[
  ['offset','Enum.map([x, -y, -z],','Enum.map(Enum.zip_with(position, [1, -1, -1], &*/2),','[x,-y,-z].map','[position[0],-position[1],-position[2]].map'],
  ['temperature','1_000, 273_150, 300_000','1_000, 0, 300_000','? 0 : 273150','? 0 : 0'],
];
for(const [id,elixBefore,elixAfter,jsBefore,jsAfter] of mutations){
  const own=join(directory,id);mkdirSync(own);
  const sources={elixir:readFileSync(join(packageRoot,'lib/frameshift_build/conjunct_adapter.ex'),'utf8'),javascript:readFileSync(join(packageRoot,'js/conjunct-adapter.mjs'),'utf8')};
  assert.equal(sources.elixir.split(elixBefore).length,2);assert.equal(sources.javascript.split(jsBefore).length,2);
  const module=`FrameshiftBuild.ConjunctAdapter.Fault${id}`;
  let elixSource=sources.elixir.replace('defmodule FrameshiftBuild.ConjunctAdapter do',`defmodule ${module} do`).replace(elixBefore,elixAfter);
  if(id==='offset') elixSource=elixSource.replace('[x, y, z] = Enum.zip_with','[_x, _y, _z] = Enum.zip_with');
  const jsSource=sources.javascript.replace(jsBefore,jsAfter)
    .replaceAll("'../build/dev/javascript/",`'${pathToFileURL(join(packageRoot,'build/dev/javascript/')).href}`)
    .replace("'./v1-inputs.mjs'",`'${pathToFileURL(join(packageRoot,'js/v1-inputs.mjs')).href}'`);
  writeFileSync(join(own,'fault.ex'),elixSource,{flag:'wx'});writeFileSync(join(own,'fault.mjs'),jsSource,{flag:'wx'});
  retain(`${id}-mutation-original.json`,{sources,replacements:{elixBefore,elixAfter,jsBefore,jsAfter},module,elixSource,jsSource});
  command(`${id}-compile`,'mix',['run','--no-start','--no-compile','checks/conjunct-adapter-fault.exs',join(own,'fault.ex'),join(own,'beams'),join(own,'diagnostics.etf')],packageRoot,{MIX_ENV:'test'});
  const jsActual=await observe(join(own,'fault.mjs'),`${id}-javascript`,original);
  const output=join(own,'elixir');mkdirSync(output);
  command(`${id}-elixir`,'elixir',['-pa',join(own,'beams'),'-pa',join(packageRoot,'_build/test/lib/frameshift_build/ebin'),'checks/conjunct-adapter-observe.exs',join(directory,'original.json'),join(output,'actual.json'),module,output],packageRoot);
  const elixActual=JSON.parse(readFileSync(join(output,'actual.json')));
  for(const [runtime,result] of [['javascript',jsActual],['elixir',elixActual]]){
    const bad=differences(original,result);retain(`${id}-${runtime}-comparison.json`,{bad});assert(bad.length>0,'actual source fault survived');
  }
  retain(`${id}-reduced-original.json`,reduced[id]);
  const jsReduced=await observe(join(own,'fault.mjs'),`${id}-javascript-reduced`,reduced[id]);
  const out=join(own,'reduced-elixir');mkdirSync(out);
  command(`${id}-elixir-reduced`,'elixir',['-pa',join(own,'beams'),'-pa',join(packageRoot,'_build/test/lib/frameshift_build/ebin'),'checks/conjunct-adapter-observe.exs',join(directory,`${id}-reduced-original.json`),join(out,'actual.json'),module,out],packageRoot);
  const elixReduced=JSON.parse(readFileSync(join(out,'actual.json')));
  for(const [runtime,result] of [['javascript',jsReduced],['elixir',elixReduced]]){
    const bad=differences(reduced[id],result);retain(`${id}-${runtime}-reduced-comparison.json`,{bad});assert.equal(bad.length,1,'actual reduced fault survived');
  }
}
const after={...selected,git:command('final-git','git',['status','--porcelain=v1','--untracked-files=all'],root),files:selected.files.map(f=>source(f.path)),
  buildSpec:inventory(join(packageRoot,'src')),physical:inventory(join(root,'packages/decision-kernel/src')),javascript:inventory(join(packageRoot,'build/dev/javascript'))};
retain('source-after.json',after);assert.deepEqual(after,selected,'selected source changed');
retain('report.json',{format:'frameshift/conjunct-adapter-quality/1',state:'passed',norm,hands:44,properties_per_runtime:900,runtimes:['elixir','javascript'],actual_source_faults_per_runtime:2,actual_reduced_faults_per_runtime:2,smoke_calls_per_runtime:10,latency_budget_ns:null,memory_budget_bytes:null,controlled_resource_qualified:false,installed_consumer_qualified:false,whole_adapter_qualified:false});
console.log(`Exact conversion primitives passed on both runtimes: 44 hands, 900 corner properties, two actual reduced source faults and ten smoke calls each; ${directory}`);
