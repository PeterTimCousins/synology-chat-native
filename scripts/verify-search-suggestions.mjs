// Execute only the reviewed, standalone matcher from the cached vendor source.
// No DOM, network, saved session or app initialization is evaluated.
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
const sourceURL = new URL('../reference/synology-chat/cache/server-synochat-common.js',import.meta.url);
const fixtureURL = new URL('../Tests/SynologyChatNativeTests/Fixtures/SearchFuzzyContract.json',import.meta.url);
const source = fs.readFileSync(sourceURL,'utf8');
const match = /fuzzyMatch:(function\(t,e,n\)\{[\s\S]*?\}),getBoldHTML:/.exec(source);
assert.ok(match,'Reviewed vendor matcher not found');
const score = vm.runInNewContext('('+match[1]+')',Object.create(null),{timeout:1000});
const pairs = [
 ['Peter Cousins','pc'],['peter','pe'],['Other Peter','pe'],['pepper','per'],['blue','pe'],['',''],['name',''],['','x'],['123','13'],
 ['Alpha','AA'],['Alpha','AA',true],['Alpha','A',true],['Alpha','a',true],['😀 Peter','pe'],['🟢Blue','blue'],['😀','😀'],['😀','😁'],
 ['CAFÉ','café'],['e\u0301','é'],['é','e\u0301'],['İstanbul','ist'],['I','ı'],['Kelvin','kel'],['Straße','strasse'],['Straße','sße'],
 ['𝔄Alpha','al'],['A𐐀','a𐐨'],['ΟΣ','ος'],['ΟΣ','οσ'],['中文chat','中c'],['from:','fo'],['bookmark','bm']
];
const output = {version:1,source:'reference/synology-chat/cache/server-synochat-common.js',sha256:crypto.createHash('sha256').update(source).digest('hex'),character_offset:match.index,cases:pairs.map(([text,query,caseSensitive=false])=>({text,query,caseSensitive,score:score(text,query,caseSensitive)}))};
if (process.argv[2] === '--write') fs.writeFileSync(fixtureURL,JSON.stringify(output,null,2)+'\n');
else assert.deepEqual(JSON.parse(fs.readFileSync(fixtureURL,'utf8')),output);
console.log(`Verified ${output.cases.length} cached-vendor fuzzy scores; all-menu has eight operators and suggestion list truncation is 100.`);
assert.ok(source.includes('xtype:"chat_search_suggestion_list",truncateCount:100'));
assert.ok(source.includes('getAllMenu:function(){return{name:"all",re:/(^| )$/'));
assert.ok(source.includes('concat([{key:"@"'));
assert.ok(source.includes('{key:"#",desc:'));
