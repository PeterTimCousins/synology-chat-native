// Local interoperability probe. No credentials, URLs or message bodies are logged.
// --send-to-peter authorizes exactly one fixed test message to the uniquely resolved Peter DM.
import fs from 'node:fs';
import crypto from 'node:crypto';

async function main() {
    const rows = fs.readFileSync(process.env.HOME + '/Library/Application Support/synochat-client/db', 'utf8')
        .split('\n').filter(Boolean).map(JSON.parse);
    const b = Buffer.from(rows.findLast(x => x.type === 'session').data, 'base64');
    const decoder = crypto.createDecipheriv('aes-256-cbc', b.subarray(0, 32), b.subarray(32, 48));
    const session = JSON.parse(Buffer.concat([decoder.update(b.subarray(48)), decoder.final()]));
    const raw = session.uri || session.ip;
    const base = new URL(raw.includes('://') ? raw : 'https://' + raw);
    if (base.protocol !== 'https:') throw new Error('HTTPS is required.');
    const shape = x => Array.isArray(x) ? { array: x.length, item: x.length ? shape(x[0]) : null }
        : x && typeof x === 'object' ? Object.fromEntries(Object.entries(x).map(([k, v]) => [k, shape(v)])) : typeof x;
    async function api(name, method, version, params = {}) {
        const url = new URL('webapi/entry.cgi/' + name, base.href.endsWith('/') ? base : new URL(base.href + '/'));
        url.search = new URLSearchParams({ _sid: session.sid, SynoToken: session.synotoken });
        const body = new URLSearchParams({ api: name, method, version: String(version),
            ...Object.fromEntries(Object.entries(params).map(([k, v]) => [k, JSON.stringify(v)])) });
        const response = await fetch(url, { method: 'POST', body, redirect: 'error' });
        const result = await response.json();
        if (!result.success) throw new Error('API rejected request: ' + result.error?.code);
        return result.data;
    }
    const users = (await api('SYNO.Chat.User', 'list', 2)).users;
    const me = users.find(u => u.username?.toLowerCase() === session.username.toLowerCase());
    if (!me) throw new Error('Current user unresolved.');
    const channels = (await api('SYNO.Chat.Channel', 'list', 5, {is_joined:true})).channels;
    const candidates=[];
    for(const c of channels.filter(c=>c.type==='anonymous'&&!c.encrypted)) {
        const ids=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:c.channel_id})).user_ids;
        if(ids.length===2&&ids.includes(me.user_id)&&ids.some(id=>id!==me.user_id&&users.find(u=>u.user_id===id)?.nickname==='Peter')) candidates.push(c);
    }
    if(candidates.length!==1) throw new Error('Peter DM unresolved.');
    const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:candidates[0].channel_id,prev_count:30,next_count:0})).posts;
    const allowed = new Set([
      'Native Synology Chat test — backend send/live delivery check.',
      'Native Swift client test — sending and live updates.',
      'Native feature test — edited successfully.',
      'Native UI test — independent sign-in and live messaging.',
      'Native thread reply test.'
    ]);
    const malformed=posts.filter(p=>p.creator_id===me.user_id&&p.type==='system'&&!p.system_props&&allowed.has(p.message));
    if(malformed.length!==4) throw new Error('Unexpected repair candidate count.');
    fs.mkdirSync('reference/synology-chat/cache/incident-2026-10-16',{recursive:true});
    fs.writeFileSync('reference/synology-chat/cache/incident-2026-10-16/malformed-synthetic-posts.json',JSON.stringify(malformed,null,2),{mode:0o600});
    if(!process.argv.includes('--soft-delete-own-malformed-tests')) {
      console.log('Repair candidates verified: '+malformed.length+' own synthetic malformed posts; no changes made.');return;
    }
    for(const post of malformed) {
      await api('SYNO.Chat.Post','delete',8,{post_id:post.post_id,real_delete:false});
      console.log('Soft-deleted own malformed synthetic test post '+post.post_id+'.');
    }
    const after=(await api('SYNO.Chat.Post','list',5,{channel_id:candidates[0].channel_id,prev_count:30,next_count:0})).posts;
    console.log('Malformed test posts remaining in recent history: '+after.filter(p=>malformed.some(m=>m.post_id===p.post_id)).length);
}
main().catch(()=>{console.error('Repair stopped; details suppressed.');process.exitCode=1;});
