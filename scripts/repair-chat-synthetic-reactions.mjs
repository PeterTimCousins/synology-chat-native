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
    const users=(await api('SYNO.Chat.User','list',2)).users;
    const me=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
    if(!me) throw new Error('Unresolved user');
    const channels=(await api('SYNO.Chat.Channel','list',5,{is_joined:true})).channels;
    const targets=[];
    for(const c of channels.filter(c=>c.type==='anonymous'&&!c.encrypted)){
      const ids=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:c.channel_id})).user_ids;
      if(ids.length===2&&ids.includes(me.user_id)&&ids.some(id=>id!==me.user_id&&users.find(u=>u.user_id===id)?.nickname==='Peter'))targets.push(c);
    }
    if(targets.length!==1)throw new Error('Peter not unique');
    const channel=targets[0].channel_id;
    const recent=(await api('SYNO.Chat.Post','list',5,{channel_id:channel,prev_count:30,next_count:0})).posts;
    const roots=recent.filter(p=>p.creator_id===me.user_id&&p.type==='normal'&&p.message==='Native interoperability test — edited normal message.');
    if(roots.length!==1)throw new Error('Root not unique');
    const root=roots[0];
    const thread=(await api('SYNO.Chat.Post','list',5,{channel_id:channel,thread_id:root.post_id,prev_count:30,next_count:0})).posts;
    const own=[root,...thread.filter(p=>p.post_id!==root.post_id&&p.creator_id===me.user_id&&p.type==='normal'&&p.message==='Native interoperability reply — normal thread message.')];
    if(own.length!==2)throw new Error('Unexpected candidates');
    for(const post of own){
      if(post.reactions.some(r=>r.sticker_name===':thumbsup:'&&r.user_ids.includes(me.user_id))){
        await api('SYNO.Chat.Post.Reaction','delete',1,{post_id:post.post_id,sticker_name:':thumbsup:'});
        console.log('Removed own shorthand reaction from synthetic post '+post.post_id+'.');
      }
    }
}
main().catch(()=>{console.error('Controlled reaction repair stopped.');process.exitCode=1;});
