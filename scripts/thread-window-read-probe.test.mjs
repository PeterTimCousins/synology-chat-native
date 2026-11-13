import test from 'node:test';
import assert from 'node:assert/strict';
import {assertThreadWindowRead,inspectThreadWindow} from './lib/thread-window-read-probe.mjs';

const root = 399431958799,scopeHash = 'a'.repeat(64);
const post = (id,extra = {}) => ({post_id:id,channel_id:93,thread_id:root,creator_id:10,type:'normal',message:'PRIVATE BODY NEVER EMITTED',...extra});
const rootPost = () => post(root,{thread_id:0,creator_id:6});
const ids = [root+1,root+2,root+3,root+4,root+5];
function transport(change = page=>page) {
    const calls = [];
    return {calls,api:async (name,method,version,params) => {
        assertThreadWindowRead(name,method);calls.push(params);
        let page;
        if (!params.thread_id) page = [rootPost()];
        else if (!params.post_id) page = [rootPost(),...ids.map(id=>post(id))];
        else {
            const anchor = params.post_id;
            page = ids.filter(id=>id === anchor || (id < anchor && id >= anchor-params.prev_count) || (id > anchor && id <= anchor+params.next_count)).map(id=>post(id));
            page.unshift(rootPost());
        }
        return {posts:change(page,params)};
    }};
}
const run = api => inspectThreadWindow({api,scopeHash,roots:[root],now:()=>new Date('2026-11-13T00:00:00Z')});

test('read allowlist refuses every mutation before transport',() => {
    for (const [api,method] of [['SYNO.Chat.Post','create'],['SYNO.Chat.Post','delete'],['SYNO.Chat.User','set'],['SYNO.Chat.Post.Schedule','list']]) {
        assert.throws(()=>assertThreadWindowRead(api,method),/non-read/);
    }
});
test('bounded windows preserve raw order, separate root and prove neighbor witnesses without text',async () => {
    const t = transport(),result = await run(t.api);
    assert.equal(result.status,'verified_directional_witnesses');
    assert.equal(t.calls.length,6);
    assert.deepEqual(t.calls.slice(2).map(p=>[p.prev_count,p.next_count]),[[0,0],[2,2],[2,0],[0,2]]);
    assert.ok(t.calls.every(p=>p.channel_id === 93 && !('file_type' in p)));
    assert.equal(result.windows.exact.root_echo.length,1);
    assert.equal(result.windows.exact.reply_count,1);
    assert.equal(JSON.stringify(result).includes('PRIVATE BODY'),false);
    assert.ok(Object.values(result.checks).every(Boolean));
    assert.equal(result.anchor.post_id,ids[2]);
    assert.deepEqual(result.known_before_ids,ids.slice(0,2));
    assert.deepEqual(result.known_after_ids,ids.slice(3));
    assert.equal(result.full_two_sided_count_witness,true);
});
test('foreign channel, creator, wrong thread, malformed root and duplicate IDs reject',async () => {
    for (const extra of [{channel_id:94},{creator_id:20},{thread_id:999},{post_id:0}]) {
        const t = transport((page,p)=>p.thread_id && !p.post_id ? [post(ids[0],extra)] : page);
        await assert.rejects(run(t.api),/scope|membership/);
    }
    await assert.rejects(run(transport((page,p)=>!p.thread_id ? [post(root,{thread_id:123})] : page).api),/root membership/);
    await assert.rejects(run(transport((page,p)=>p.thread_id && !p.post_id ? [post(ids[0]),post(ids[0])] : page).api),/scope/);
    await assert.rejects(run(transport((page,p)=>!p.thread_id ? [] : page).api),/omits root/);
});
test('insufficient neighbors performs no anchored reads',async () => {
    const t = transport((page,p)=>p.thread_id && !p.post_id ? [post(ids[0]),post(ids[1])] : page);
    const result = await run(t.api);
    assert.equal(result.status,'insufficient_neighbors');assert.equal(t.calls.length,2);
});
test('responses exceeding latest or anchored bounds reject',async () => {
    await assert.rejects(run(transport((page,p)=>p.thread_id && !p.post_id ? Array.from({length:32},(_,i)=>post(root+i+1)) : page).api),/bound/);
    await assert.rejects(run(transport((page,p)=>p.thread_id && p.post_id && p.prev_count === 0 && p.next_count === 0 ? [post(ids[0]),post(ids[1])] : page).api),/bound/);
});
test('missing directional witness reports unverified instead of false success',async () => {
    const t = transport((page,p)=>p.thread_id && p.post_id && p.prev_count === 2 && p.next_count === 0 ? page.filter(x=>x.post_id >= p.post_id || x.post_id === root) : page);
    const result = await run(t.api);
    assert.equal(result.status,'unverified_directional_witnesses');assert.equal(result.checks.previous_witness,false);
});
test('invalid scope and more than two roots reject without transport',async () => {
    let calls = 0;const api = async ()=>{calls++;throw new Error('unexpected transport');};
    await assert.rejects(inspectThreadWindow({api,scopeHash:'not-a-scope'}),/scope/);
    await assert.rejects(inspectThreadWindow({api,scopeHash,roots:[1,2,3]}),/scope/);
    assert.equal(calls,0);
});
test('missing anchor cannot hide a directional count overflow',async () => {
    const t = transport((page,p)=>p.thread_id && p.post_id && p.prev_count === 2 && p.next_count === 0 ? [post(root-1),post(ids[0]),post(ids[1])] : page);
    await assert.rejects(run(t.api),/directional.*bound/);
});
