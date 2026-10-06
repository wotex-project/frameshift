import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {readFileSync,writeFileSync,mkdirSync,readdirSync,lstatSync,readlinkSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const root=resolve(process.argv[2]),directory=resolve(process.argv[3]),packageRoot=join(root,'packages/build-spec'),norm='aad37551838779cfe6a54d1b870638fb05026c2d';
const retain=(name,value)=>writeFileSync(join(directory,name),JSON.stringify(value,null,2)+'\n',{flag:'wx'});
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const command=(id,executable,args,cwd=packageRoot,environment={})=>{
 retain(id+'-command-original.json',{executable,args,cwd,environment});
 const actual=spawnSync(executable,args,{cwd,env:{...process.env,...environment},encoding:'utf8',maxBuffer:16*1024*1024});
 retain(id+'-command-actual.json',{status:actual.status,signal:actual.signal,error:actual.error?.message??null,stdout:actual.stdout,stderr:actual.stderr});
 assert.equal(actual.error,undefined,id+': infrastructure failure');assert.equal(actual.status,0,id+': command failed');return actual.stdout;
};
const inventory=(base,relative='')=>{
 const path=join(base,relative),stat=lstatSync(path);
 if(stat.isDirectory()) return readdirSync(path).sort().flatMap(name=>inventory(base,join(relative,name)));
 if(stat.isSymbolicLink()) return [{path:relative,type:'symlink',mode:stat.mode&0o7777,target:readlinkSync(path)}];
 assert(stat.isFile());const bytes=readFileSync(path);
 return [{path:relative,type:'file',mode:stat.mode&0o7777,bytes:bytes.toString('base64'),sha256:digest(bytes)}];
};
const normFiles=['docs/architecture/conjunct-v1-inputs.md','packages/build-spec/test/fixtures/conjunct-v1-inputs.expected.json'];
for(const [index,file] of normFiles.entries()){
 const bytes=command('norm-'+index,'git',['show',norm+':'+file],root);
 retain('norm-'+index+'-original.json',{file,bytes});assert.equal(readFileSync(join(root,file),'utf8'),bytes,'committed norm changed');
}
const paths=['packages/build-spec/lib','packages/build-spec/js','packages/build-spec/src','packages/build-spec/checks','packages/build-spec/test','packages/build-spec/_build/test/lib/frameshift_build/ebin','packages/build-spec/_build/test/lib/frameshift_decisions/ebin','packages/build-spec/build/dev/javascript','packages/decision-kernel/src'];
let sourceCount=0;
const source=()=>({git:command('git-'+(sourceCount++),'git',['status','--porcelain=v1','--untracked-files=all'],root),trees:paths.map(path=>({path,entries:inventory(join(root,path))})),configuration:['.mise.toml','packages/build-spec/mix.exs','packages/build-spec/mix.lock','packages/build-spec/gleam.toml','packages/build-spec/manifest.toml','scripts/check-conjunct-v1-inputs','scripts/check-build-spec'].map(path=>({path,bytes:readFileSync(join(root,path)).toString('base64')}))});
const runtime={node:{version:process.version,executable:process.execPath,platform:process.platform,architecture:process.arch},elixir:command('elixir-version','elixir',['--version']),gleam:command('gleam-version','gleam',['--version']),revision:command('revision','git',['rev-parse','HEAD'],root)};retain('runtime-original.json',runtime);
const selected=source();retain('source-original.json',selected);
const fixture=JSON.parse(readFileSync(join(root,normFiles[1])));
const expand=value=>Array.isArray(value)?value.map(expand):value&&typeof value==='object'?(value.$source!==undefined?fixture.sources[value.$source]:value.$repeat!==undefined?expand(value.$repeat.value).repeat(value.$repeat.count):value.$copies!==undefined?Array.from({length:value.$copies.count},()=>expand(value.$copies.value)):value):value;
const identity=(kind,bytes)=>'sha256:'+digest(fixture.domains[kind]+'\n'+bytes);
const expected=args=>{
 const [assembly,p,m,l,context]=args;
 const groups=[['assembly',[assembly]],['component-profile',p],['signal-mapping',m],['artifact-layout',l],['compilation-context',[context]]];
 const documents=groups.flatMap(([kind,values])=>values.map(bytes=>({kind,identity:identity(kind,bytes),bytes}))).sort((a,b)=>a.kind<b.kind?-1:a.kind>b.kind?1:a.identity<b.identity?-1:a.identity>b.identity?1:0);
 return {ok:true,value:{format:'frameshift.conjunct.v1-inputs/1',assembly_identity:identity('assembly',assembly),context_identity:identity('compilation-context',context),documents}};
};
const cases=fixture.cases.map(hand=>({...hand,args:expand(hand.args)}));
assert.equal(cases.length,32);
for(const hand of cases.filter(hand=>hand.expected.ok)) assert.deepEqual(hand.expected,expected(hand.args),'independent authored identity mismatch');
const find=id=>{const hand=cases.find(hand=>hand.id===id);assert(hand);return hand;};
const properties=[];
for(const seed of fixture.seeds){
 let state=BigInt(seed);const draw=n=>{state=(1664525n*state+1013904223n)%4294967296n;return Number((state>>16n)%BigInt(n));};
 const permute=values=>{const result=[...values];for(let i=result.length-1;i>0;i--){const j=draw(i+1);[result[i],result[j]]=[result[j],result[i]];}return result;};
 for(let index=0;index<fixture.runs_per_seed;index++){
  const mode=draw(4),base=find(mode===1?'without-bindings':'complete'),args=structuredClone(base.args);
  for(const slot of [1,2,3]) args[slot]=permute(args[slot]);
  if(mode===2) args[4]=args[4].slice(0,-1);
  if(mode===3) args[4]=fixture.sources['context-without-bindings'];
  properties.push({id:`${seed}-${index}`,args,expected:mode<2?expected(args):{ok:false,error:'context_mismatch'}});
 }
}
const original={cases,properties,smoke:fixture.smoke.case_ids.map(find),snapshot:find('complete')};retain('original.json',original);
const observe=(runtime,module,name,input,beams=null)=>{
 const own=join(directory,name);mkdirSync(own);const inputPath=join(own,'input-original.json'),output=join(own,'actual.json');
 writeFileSync(inputPath,JSON.stringify(input)+'\n',{flag:'wx'});
 if(runtime==='javascript'){
  const template=readFileSync(join(packageRoot,'checks/conjunct-v1-inputs-js-observe.mjs'),'utf8'),anchor="'../js/conjunct-adapter.mjs'";
  assert.equal(template.split(anchor).length,2,'literal observer module anchor');
  const program=template.replace(anchor,JSON.stringify(pathToFileURL(module).href)),caller=join(own,'caller.mjs');
  writeFileSync(caller,program,{flag:'wx'});writeFileSync(join(own,'caller-original.json'),JSON.stringify({template,program,module})+'\n',{flag:'wx'});
  command(name,'node',[caller,module,inputPath,output]);
 }else command(name,'elixir',[...(beams?['-pa',beams]:[]),'-pa',join(packageRoot,'_build/test/lib/frameshift_build/ebin'),'-pa',join(packageRoot,'_build/test/lib/frameshift_decisions/ebin'),'checks/conjunct-v1-inputs-observe.exs',inputPath,output,module,own]);
 return {actual:JSON.parse(readFileSync(output)),own};
};
const differences=(input,result)=>{
 const mismatches=[];
 for(const group of ['cases','properties']){
  const actual=result[group==='cases'?'hands':group];assert.equal(actual.length,input[group].length,'truncated observations');
  for(let index=0;index<actual.length;index++){
   assert.equal(actual[index].id,input[group][index].id,'wrong observation identity');
   try{assert.deepEqual(actual[index].actual,input[group][index].expected);}catch{mismatches.push({group,id:actual[index].id,original:input[group][index],actual:actual[index].actual});}
  }
 }
 return mismatches;
};
for(const [runtime,module] of [['javascript',join(packageRoot,'js/conjunct-adapter.mjs')],['elixir','FrameshiftBuild.ConjunctInputs']]){
 const {actual,own}=observe(runtime,module,'baseline-'+runtime,original),bad=differences(original,actual);retain('baseline-'+runtime+'-comparison.json',{bad});assert.equal(bad.length,0,'baseline semantic mismatch');
 assert.equal(actual.preflight.length,2);assert.equal(actual.samples.length,10);
 for(const row of [...actual.preflight,...actual.samples]) assert.deepEqual(row.actual,find(row.id).expected);
 for(const row of actual.samples) assert(Number.isSafeInteger(row.elapsed_ns)&&row.elapsed_ns>=0);
 if(runtime==='javascript'){
  const before=JSON.parse(readFileSync(join(own,'actual.json.import-original.json'))),after=JSON.parse(readFileSync(join(own,'actual.json.import-actual.json')));
  assert.deepEqual(after,before.before,'ordinary import effects');
  for(const row of actual.frozen){assert.equal(row.frozen,true);assert.equal(row.array_frozen,true);assert(row.records_frozen.every(Boolean));assert.equal(row.independent,true);assert.deepEqual(row.value,row.second);}
  assert.equal(actual.frozen.length,4);assert(actual.snapshot.events.length>0);assert.deepEqual(actual.snapshot.actual,find('complete').expected);assert.deepEqual(actual.snapshot.original,find('complete').args);assert.notDeepEqual(actual.snapshot.after,actual.snapshot.original);
 }
}
const mutations=[
 ['context','  defp same_context(bytes, bytes), do: :ok\n  defp same_context(_, _), do: {:error, "context_mismatch"}','  defp same_context(_original, _supplied), do: :ok','if (resolved.canonical !== context)','if (false)'],
 ['missing','  defp complete(_), do: {:error, "missing_profile"}','  defp complete(_), do: :ok','if (resolution.resolution.missing.toArray().length !== 0)','if (false)'],
];
for(const [id,beforeE,afterE,beforeJ,afterJ] of mutations){
 const own=join(directory,'fault-'+id);mkdirSync(own);
 const originals={elixir:readFileSync(join(packageRoot,'lib/frameshift_build/conjunct_inputs.ex'),'utf8'),javascript:readFileSync(join(packageRoot,'js/v1-inputs.mjs'),'utf8')};
 assert.equal(originals.elixir.split(beforeE).length,2);assert.equal(originals.javascript.split(beforeJ).length,2);
 const module='FrameshiftBuild.ConjunctInputs.Fault'+id;
 const elixir=originals.elixir.replace('defmodule FrameshiftBuild.ConjunctInputs do','defmodule '+module+' do').replace(beforeE,afterE);
 const javascript=originals.javascript.replace(beforeJ,afterJ).replaceAll("from './",`from '${pathToFileURL(join(packageRoot,'js/')).href}`);
 retain(id+'-fault-original.json',{originals,beforeE,afterE,beforeJ,afterJ,module,elixir,javascript});
 const sourcePath=join(own,'fault.ex'),jsPath=join(own,'fault.mjs'),beams=join(own,'beams');writeFileSync(sourcePath,elixir,{flag:'wx'});writeFileSync(jsPath,javascript,{flag:'wx'});
 command(id+'-compile','mix',['run','--no-start','--no-compile','checks/conjunct-adapter-fault.exs',sourcePath,beams,join(own,'diagnostics.etf')],packageRoot,{MIX_ENV:'test'});
 const first=find(id==='context'?'context-truncated':'missing-one-profile');
 const minimal=id==='context'?{id:'context-without-bindings-truncated',args:[...find('without-bindings').args.slice(0,4),fixture.sources['context-without-bindings'].slice(0,-1)],expected:{ok:false,error:'context_mismatch'}}:find('missing-all-profiles');
 const reductions=[first,minimal].map(hand=>({cases:[hand],properties:[],smoke:[],snapshot:null}));
 retain(id+'-reduction-original.json',{budget:fixture.reduction_trials,inputs:reductions});
 assert(Buffer.byteLength(JSON.stringify(minimal.args))<Buffer.byteLength(JSON.stringify(first.args)),'reduction must remove actual input bytes');
 for(const runtime of ['javascript','elixir']){
  const target=runtime==='javascript'?jsPath:module,runInput={...original,snapshot:null};
  const actual=observe(runtime,target,id+'-fault-'+runtime,runInput,beams).actual,bad=differences(runInput,actual);retain(id+'-fault-'+runtime+'-comparison.json',{bad});assert(bad.length>0,'actual source fault survived');
  for(const [index,reduced] of reductions.entries()){
   const name=id+'-reduced-'+runtime+'-'+index,small=observe(runtime,target,name,reduced,beams).actual,badSmall=differences(reduced,small);
   retain(name+'-comparison.json',{trial:index+1,bad:badSmall});assert.equal(badSmall.length,1);
  }
 }
}
const after=source();retain('source-after.json',after);assert.deepEqual(after,selected,'source or actual BEAM changed');
retain('report.json',{format:'frameshift/conjunct-v1-inputs-quality/1',state:'passed',norm,runtime,hands:32,properties_per_runtime:900,runtimes:['elixir','javascript'],actual_source_faults_per_runtime:2,reduced_witnesses_per_runtime:2,smoke_calls_per_runtime:10,latency_budget_ns:null,memory_budget_bytes:null,controlled_resource_qualified:false,installed_consumer_qualified:false,successor_migration_qualified:false});
console.log('Exact retained v1 inputs passed: 32 hands, 900 schedules, two actual faults/reduced witnesses and ten null-budget smoke calls per runtime; '+directory);
