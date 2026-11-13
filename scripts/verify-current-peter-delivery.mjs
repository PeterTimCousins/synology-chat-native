// Bounded own-account acceptance probe. Credentials stay in memory and are never printed.
// Default is read-only. --send-once dispatches one fixed synthetic DM after fresh scope checks.
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import {assertThreadWindowRead,inspectThreadWindow} from './lib/thread-window-read-probe.mjs';

async function main() {
    const mode = process.argv[2] ?? '--readiness';
    const youtubePreview = process.argv.includes('--youtube-preview');
    const notificationCheck = process.argv.includes('--notification-check');
    const officialNotification = process.argv.includes('--official-notification');
    const inactiveNotification = process.argv.includes('--inactive-notification');
    const soundNotification = process.argv.includes('--sound-notification');
    if ([youtubePreview,notificationCheck,officialNotification,inactiveNotification,soundNotification].filter(Boolean).length>1) throw new Error('Choose one test scope.');
    if (officialNotification && mode==='--send-once') throw new Error('Official notification test must be sent through its actual UI.');
    if (process.argv.slice(3).some(value => !['--youtube-preview','--notification-check','--official-notification','--inactive-notification','--sound-notification'].includes(value))) throw new Error('Unknown option.');
    if (!['--readiness', '--send-once', '--readback', '--verify-reply', '--arm-attachment', '--verify-attachment', '--inspect-reactions', '--arm-thread-image', '--verify-thread-image', '--inspect-history-window', '--inspect-thread-window', '--arm-long-snippet', '--verify-long-snippet'].includes(mode)) throw new Error('Unknown mode.');
    const state = new Map();
    const lines = fs.readFileSync(path.join(process.env.HOME, 'Library/Application Support/synochat-client/db'), 'utf8').split('\n').filter(Boolean);
    for (const [position, line] of lines.entries()) {
        const row = JSON.parse(line);
        if (!row._id) { if (row.type === 'session') throw new Error('Invalid session record.'); continue; }
        if (row.$$deleted === true) state.delete(row._id);
        else state.set(row._id, { row, position });
    }
    const record = [...state.values()].filter(x => x.row.type === 'session').sort((a,b) => b.position-a.position)[0]?.row;
    if (!record?.data) throw new Error('Official saved session unavailable.');
    const bytes = Buffer.from(record.data, 'base64');
    if (bytes.length <= 48) throw new Error('Invalid saved session.');
    const decrypt = crypto.createDecipheriv('aes-256-cbc', bytes.subarray(0,32), bytes.subarray(32,48));
    const session = JSON.parse(Buffer.concat([decrypt.update(bytes.subarray(48)), decrypt.final()]));
    const address = session.uri || session.ip;
    const base = new URL(address.includes('://') ? address : `${session.isHTTPS ? 'https' : 'http'}://${address}`);
    if (base.protocol !== 'https:' || base.username || base.password || !session.sid || !session.synotoken) throw new Error('Invalid HTTPS session.');
    base.search = ''; base.hash = ''; if (!base.pathname.endsWith('/')) base.pathname += '/';
    async function api(name, method, version, params = {}) {
        if (['--inspect-thread-window','--inspect-history-window'].includes(mode)) assertThreadWindowRead(name,method);
        const url = new URL(`webapi/entry.cgi/${name}`, base);
        url.search = new URLSearchParams({_sid:session.sid, SynoToken:session.synotoken});
        const body = new URLSearchParams({api:name, method, version:String(version), ...Object.fromEntries(Object.entries(params).map(([k,v])=>[k,JSON.stringify(v)]))});
        const response = await fetch(url, {method:'POST', body, redirect:'error', signal:AbortSignal.timeout(20000)});
        const result = await response.json();
        if (!response.ok || !result.success) throw new Error(`API rejected request: ${result.error?.code ?? response.status}`);
        return result.data;
    }
    const users = (await api('SYNO.Chat.User','list',2)).users ?? [];
    const own = users.find(u => u.username?.toLowerCase() === session.username?.toLowerCase());
    const peter = users.find(u => u.user_id === 6 && u.nickname === 'Peter' && u.type === 'human');
    const other = users.find(u => u.user_id === 10 && u.type === 'human');
    const channels = (await api('SYNO.Chat.Channel','list',5,{is_joined:true})).channels ?? [];
    const channel = channels.find(c => c.channel_id === 93 && c.type === 'anonymous' && !c.encrypted);
    const members = (await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids ?? [];
    if (own?.user_id !== 6 || !peter || !other || !channel || JSON.stringify([...members].sort((a,b)=>a-b)) !== '[6,10]') throw new Error('Own Peter account/channel scope changed; no mutation.');
    const scope = crypto.createHash('sha256').update(JSON.stringify([base.origin,base.pathname,own.user_id,93,members.slice().sort((a,b)=>a-b)])).digest('hex');
    if (mode === '--inspect-thread-window') { console.log(JSON.stringify(await inspectThreadWindow({api,scopeHash:scope})));return; }
    const receiptPath = new URL(soundNotification ? '../reference/synology-chat/evidence/2026-11-12/sound-peter-delivery-dispatch.json' : inactiveNotification ? '../reference/synology-chat/evidence/2026-11-12/inactive-peter-delivery-dispatch.json' : officialNotification ? '../reference/synology-chat/evidence/2026-11-12/official-notification-peter-delivery-dispatch.json' : notificationCheck ? '../reference/synology-chat/evidence/2026-11-12/notification-visible-peter-delivery-dispatch.json' : youtubePreview ? '../reference/synology-chat/evidence/2026-11-12/youtube-optimized-peter-delivery-dispatch.json' : '../reference/synology-chat/evidence/2026-11-12/current-peter-delivery-dispatch.json', import.meta.url);
    if (mode === '--readiness') { console.log(JSON.stringify({official_user_id:6,peer_user_id:10,peer_nickname:other.nickname,channel_id:93,member_ids:[6,10],scope_sha256:scope})); return; }
    if (['--arm-long-snippet','--verify-long-snippet'].includes(mode)) {
        const manifestURL = new URL('../reference/synology-chat/evidence/2026-11-12/current-peter-long-snippet.json',import.meta.url);
        if (mode === '--arm-long-snippet') {
            if(fs.existsSync(manifestURL)) throw new Error('Long snippet already armed; do not prepare another send.');
            const marker=crypto.randomUUID(),text=`Synthetic long-message snippet check — ${marker}\n`+'A synthetic paragraph with emoji 😀 and combining é.\r\n'.repeat(60);
            const manifest={scope_sha256:scope,phase:'before_single_native_conversion',channel_id:93,creator_id:10,filename:`Native long message ${marker}.txt`,caption:'Synthetic native long-message conversion — Peter accounts only.',text,bytes:Buffer.byteLength(text),sha256:crypto.createHash('sha256').update(text).digest('hex'),time:new Date().toISOString()};
            fs.writeFileSync(manifestURL,JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});
            console.log(JSON.stringify({phase:manifest.phase,channel_id:93,creator_id:10,filename:manifest.filename,bytes:manifest.bytes,sha256:manifest.sha256}));return;
        }
        let manifest=JSON.parse(fs.readFileSync(manifestURL,'utf8'));
        if(manifest.scope_sha256!==scope || manifest.channel_id!==93 || manifest.creator_id!==10 || Buffer.byteLength(manifest.text)!==manifest.bytes || crypto.createHash('sha256').update(manifest.text).digest('hex')!==manifest.sha256) throw new Error('Long snippet scope or synthetic bytes changed.');
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:100,next_count:0})).posts??[];
        const matches=posts.filter(p=>p.type==='file' && p.channel_id===93 && p.creator_id===10 && (!p.thread_id || p.thread_id===p.post_id) && p.file_props?.is_snippet===true && p.file_props?.name===manifest.filename && p.message===manifest.caption && !p.delete_at);
        if(matches.length!==1) throw new Error('Exactly one matching snippet not established; do not resend.');
        const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.Snippet',base);url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{method:'POST',redirect:'error',signal:AbortSignal.timeout(20000),body:new URLSearchParams({api:'SYNO.Chat.Post.Snippet',method:'get',version:'1',post_id:JSON.stringify(matches[0].post_id)})});
        const bytes=Buffer.from(await response.arrayBuffer());
        if(!response.ok || !response.headers.get('content-type')?.startsWith('text/plain') || bytes.length!==manifest.bytes || crypto.createHash('sha256').update(bytes).digest('hex')!==manifest.sha256) throw new Error('Other own-account snippet readback did not match original bytes.');
        manifest={...manifest,phase:'canonical_snippet_and_exact_bytes_verified',post_id:matches[0].post_id,verified_at:new Date().toISOString(),downloaded_through_official_account:6};
        fs.writeFileSync(manifestURL,JSON.stringify(manifest,null,2)+'\n');console.log(JSON.stringify({phase:manifest.phase,channel_id:93,creator_id:10,post_id:manifest.post_id,bytes:manifest.bytes,sha256:manifest.sha256,pin_state:{last_pin_at:matches[0].last_pin_at??0,is_sticky:matches[0].is_sticky??false},verified_at:manifest.verified_at}));return;
    }
    if (mode === '--inspect-history-window') {
        const parent=JSON.parse(fs.readFileSync(new URL('../reference/synology-chat/evidence/2026-11-12/sound-peter-delivery-dispatch.json',import.meta.url),'utf8'));
        if(parent.scope_sha256!==scope || parent.post_id!==399431958799) throw new Error('History scope mismatch.');
        const validate=(rows,anchor,previous,following,maximum)=>{
            if(!Array.isArray(rows) || rows.length>maximum || new Set(rows.map(p=>p.post_id)).size!==rows.length ||
               rows.some(p=>!Number.isSafeInteger(p.post_id) || p.post_id<=0 || p.channel_id!==93 || !Number.isSafeInteger(p.creator_id) || p.creator_id<0) ||
               (anchor!=null && (rows.filter(p=>p.post_id<anchor).length>previous || rows.filter(p=>p.post_id>anchor).length>following))) throw new Error('Raw main history bounds diagnostic: '+JSON.stringify({anchor,previous,following,maximum,count:Array.isArray(rows)?rows.length:null,unique:Array.isArray(rows)?new Set(rows.map(p=>p.post_id)).size:null,foreign_channels:Array.isArray(rows)?rows.filter(p=>p.channel_id!==93).length:null,creator_ids:Array.isArray(rows)?[...new Set(rows.map(p=>p.creator_id))]:[],invalid_ids:Array.isArray(rows)?rows.filter(p=>!Number.isSafeInteger(p.post_id)||p.post_id<=0).length:null,before:Array.isArray(rows)&&anchor!=null?rows.filter(p=>p.post_id<anchor).length:null,after:Array.isArray(rows)&&anchor!=null?rows.filter(p=>p.post_id>anchor).length:null}));
        };
        const latest=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:30,next_count:0})).posts;
        validate(latest,null,30,0,30);
        const context=(await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:parent.post_id,prev_count:15,next_count:15})).posts??[];
        validate(context,parent.post_id,15,15,31);
        if(context.filter(p=>p.post_id===parent.post_id && p.channel_id===93 && p.creator_id===6 && p.message===parent.message).length!==1 || context.some(p=>p.channel_id!==93)) throw new Error('Canonical history context mismatch.');
        const ids=context.map(p=>p.post_id).sort((a,b)=>a-b),oldest=ids[0];
        const previous=(await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:oldest,prev_count:30,next_count:0})).posts??[];
        const next=(await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:oldest,prev_count:0,next_count:30})).posts??[];
        validate(previous,oldest,30,0,31);validate(next,oldest,0,30,31);
        if(previous.some(p=>p.channel_id!==93) || next.some(p=>p.channel_id!==93)) throw new Error('History page scope mismatch.');
        console.log(JSON.stringify({scope_sha256:scope,channel_id:93,latest_raw_count:latest.length,latest_raw_ids:latest.map(p=>p.post_id),raw_bounds_validated:true,anchor:parent.post_id,context_count:ids.length,preceding:ids.filter(id=>id<parent.post_id).length,following:ids.filter(id=>id>parent.post_id).length,oldest,older_page_count:previous.length,strictly_older_than_context:previous.filter(p=>p.post_id<oldest).length,older_page_includes_boundary:previous.some(p=>p.post_id===oldest),newer_page_count:next.length,strictly_newer_than_context_boundary:next.filter(p=>p.post_id>oldest).length,newer_page_includes_boundary:next.some(p=>p.post_id===oldest),older_content_profile:previous.map(p=>({post_id:p.post_id,type:p.type,text_utf16_units:(p.message??'').length,lines:(p.message??'').split(/\r\n|\r|\n/).length,is_image:p.file_props?.is_image??false,is_snippet:p.file_props?.is_snippet??false,file_extension:p.file_props?.name?path.extname(p.file_props.name).toLowerCase():null,preview_count:p.url_props?.length??0,reply_count:p.comment_count??0})),verified_at:new Date().toISOString()}));return;
    }
    if (['--arm-thread-image','--verify-thread-image'].includes(mode)) {
        const manifestURL = new URL('../reference/synology-chat/evidence/2026-11-12/current-peter-thread-image.json',import.meta.url);
        const parent = JSON.parse(fs.readFileSync(new URL('../reference/synology-chat/evidence/2026-11-12/sound-peter-delivery-dispatch.json',import.meta.url),'utf8'));
        if (parent.scope_sha256 !== scope || parent.post_id !== 399431958799 || parent.channel_id !== 93 || parent.creator_id !== 6) throw new Error('Thread parent scope mismatch.');
        const roots = (await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:parent.post_id,prev_count:0,next_count:0})).posts ?? [];
        if (roots.filter(p=>p.post_id===parent.post_id && p.channel_id===93 && p.creator_id===6 && (!p.thread_id || p.thread_id===p.post_id) && p.message===parent.message && !p.delete_at).length!==1) throw new Error('Canonical synthetic thread parent unavailable.');
        if (mode === '--arm-thread-image') {
            if (fs.existsSync(manifestURL)) throw new Error('Thread image check already armed; do not upload again.');
            const original = fs.readFileSync(new URL('../reference/synology-chat/evidence/2026-11-12/attachment-review-renders/dark-attachment-portrait.png',import.meta.url));
            const digest = crypto.createHash('sha256').update(original).digest('hex');
            if (digest !== '5c90083c4a5c2f5b171ef773acfd8bc03e380ca497383debaee4f0924eae9b06') throw new Error('Synthetic image source changed.');
            const directory = fs.mkdtempSync('/private/tmp/native-peter-thread-image-');
            const filename = `Native thread image check ${crypto.randomUUID()}.png`,file = path.join(directory,filename);
            fs.writeFileSync(file,original,{flag:'wx',mode:0o600});
            const manifest = {scope_sha256:scope,phase:'before_single_native_thread_upload',channel_id:93,root_id:parent.post_id,creator_id:10,filename,local_file:file,caption:'Synthetic native thread image check — Peter accounts only.',bytes:original.length,sha256:digest,time:new Date().toISOString()};
            fs.writeFileSync(manifestURL,JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify(manifest));return;
        }
        let manifest = JSON.parse(fs.readFileSync(manifestURL,'utf8'));
        if (manifest.scope_sha256!==scope || manifest.root_id!==parent.post_id || manifest.channel_id!==93 || manifest.creator_id!==10) throw new Error('Thread image manifest mismatch.');
        const posts = (await api('SYNO.Chat.Post','list',5,{channel_id:93,thread_id:parent.post_id,prev_count:100,next_count:0})).posts ?? [];
        const matches = posts.filter(p=>p.type==='file' && p.channel_id===93 && p.thread_id===parent.post_id && p.creator_id===10 && p.file_props?.name===manifest.filename && p.message===manifest.caption && !p.delete_at);
        if(matches.length!==1) throw new Error('Exactly one matching thread image not established; do not resend.');
        const url = new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base);url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response = await fetch(url,{method:'POST',redirect:'error',signal:AbortSignal.timeout(20000),body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(matches[0].post_id)})});
        const bytes=Buffer.from(await response.arrayBuffer());
        if(!response.ok || !response.headers.has('content-disposition') || bytes.length!==manifest.bytes || crypto.createHash('sha256').update(bytes).digest('hex')!==manifest.sha256) throw new Error('Thread image original bytes mismatch.');
        manifest={...manifest,phase:'canonical_thread_post_and_original_bytes_verified',post_id:matches[0].post_id,verified_at:new Date().toISOString(),downloaded_through_official_account:6};
        fs.writeFileSync(manifestURL,JSON.stringify(manifest,null,2)+'\n');console.log(JSON.stringify(manifest));return;
    }
    if (['--arm-attachment','--verify-attachment'].includes(mode)) {
        const manifestURL = new URL('../reference/synology-chat/evidence/2026-11-12/current-peter-pdf-attachment.json',import.meta.url);
        if (mode === '--arm-attachment') {
            if (fs.existsSync(manifestURL)) throw new Error('Attachment check already armed; do not upload again.');
            const original = fs.readFileSync(new URL('../reference/synology-chat/evidence/2026-11-12/preview-raster-probe/synthetic-source.pdf',import.meta.url));
            const digest = crypto.createHash('sha256').update(original).digest('hex');
            if (digest !== '611fccb987a914a60e27958036f33804d75a2c26794ffd858e9d77a8a32afdf8') throw new Error('Synthetic PDF source changed.');
            const directory = fs.mkdtempSync('/private/tmp/native-peter-pdf-');
            const name = `Native PDF check ${crypto.randomUUID()}.pdf`,file = path.join(directory,name);
            fs.writeFileSync(file,original,{flag:'wx',mode:0o600});
            const manifest = {scope_sha256:scope,phase:'before_single_native_upload',channel_id:93,creator_id:10,filename:name,local_file:file,caption:'Synthetic native PDF delivery check — Peter accounts only.',bytes:original.length,sha256:digest,time:new Date().toISOString()};
            fs.writeFileSync(manifestURL,JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});
            console.log(JSON.stringify(manifest));return;
        }
        let manifest = JSON.parse(fs.readFileSync(manifestURL,'utf8'));
        if (manifest.scope_sha256 !== scope || manifest.channel_id !== 93 || manifest.creator_id !== 10) throw new Error('Attachment account scope mismatch.');
        const posts = (await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:100,next_count:0})).posts ?? [];
        const matches = posts.filter(p=>p.type === 'file' && p.channel_id === 93 && p.creator_id === 10 && (!p.thread_id || p.thread_id===p.post_id) && p.file_props?.name === manifest.filename && p.message === manifest.caption);
        if (matches.length !== 1) throw new Error('Exactly one native attachment not established; do not upload again.');
        const post = matches[0],url = new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base);
        url.search = new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response = await fetch(url,{method:'POST',redirect:'error',signal:AbortSignal.timeout(20000),body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(post.post_id)})});
        const content = Buffer.from(await response.arrayBuffer());
        if (!response.ok || !response.headers.has('content-disposition') || content.length !== manifest.bytes || crypto.createHash('sha256').update(content).digest('hex') !== manifest.sha256) throw new Error('Official-account download does not match original synthetic PDF.');
        manifest = {...manifest,phase:'canonical_post_and_original_bytes_verified',post_id:post.post_id,verified_at:new Date().toISOString(),downloaded_through_official_account:6};
        fs.writeFileSync(manifestURL,JSON.stringify(manifest,null,2)+'\n');console.log(JSON.stringify(manifest));return;
    }
    let receipt;
    if (mode === '--send-once') {
        const marker = soundNotification ? `Native notification sound check — ${crypto.randomUUID()}` : inactiveNotification ? `Native inactive delivery check — ${crypto.randomUUID()}` : notificationCheck ? `Native notification visibility check — ${crypto.randomUUID()}` : youtubePreview ? `Native YouTube preview check — ${crypto.randomUUID()} https://www.youtube.com/watch?v=M7lc1UVf-VE` : `Native updated-client incoming check — ${crypto.randomUUID()}`;
        receipt = {scope_sha256:scope,phase:'before_single_dispatch',channel_id:93,creator_id:6,message:marker,time:new Date().toISOString()};
        fs.writeFileSync(receiptPath, JSON.stringify(receipt,null,2)+'\n', {flag:'wx'});
        // Never retry a failed or ambiguous create; subsequent runs use read-only readback.
        await api('SYNO.Chat.Post','create',5,{channel_id:93,type:'normal',message:marker,is_thread:false,thread_id:0,conn_id:''});
    } else receipt = JSON.parse(fs.readFileSync(receiptPath,'utf8'));
    if (receipt.scope_sha256 !== scope) throw new Error('Receipt account scope mismatch.');
    const posts = (await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:100,next_count:0})).posts ?? [];
    const matches = posts.filter(p => p.message === receipt.message && p.creator_id === 6 && p.channel_id === 93 && p.type === 'normal' && (!p.thread_id || p.thread_id===p.post_id));
    if (matches.length !== 1) throw new Error('Exactly one canonical message not established; do not resend.');
    if (mode === '--inspect-reactions') {
        const reactions = (matches[0].reactions ?? []).map(r => {
            if (typeof r.sticker_name !== 'string' || !Array.isArray(r.user_ids) || r.user_ids.some(id => ![6,10].includes(id))) throw new Error('Unexpected reaction scope.');
            return {name:r.sticker_name,user_ids:[...r.user_ids].sort((a,b)=>a-b)};
        }).sort((a,b)=>a.name.localeCompare(b.name));
        console.log(JSON.stringify({scope_sha256:scope,channel_id:93,post_id:matches[0].post_id,creator_id:6,reactions,verified_at:new Date().toISOString()}));return;
    }
    const display = youtubePreview ? await api('SYNO.Chat.Admin.Setting','get',5) : null;
    receipt = {...receipt,phase:'canonical_readback',post_id:matches[0].post_id,verified_at:new Date().toISOString(),url_preview_count:matches[0].url_props?.length??0,preview_hosts:(matches[0].url_props??[]).map(p=>{try{return new URL(p.url).hostname}catch{return null}}),...(youtubePreview?{safe_url:matches[0].props?.safe_url??null,preview_hidden_flags:(matches[0].url_props??[]).map(p=>p.hidden??null),global_hide_post_url_preview:display?.hide_post_url_preview??null}: {})};
    if (mode === '--verify-reply') {
        const replyText = `Native updated-client reply — ${receipt.post_id}`;
        const replies = posts.filter(p => p.message === replyText && p.creator_id === 10 && p.channel_id === 93 && p.type === 'normal' && (!p.thread_id || p.thread_id===p.post_id));
        if (replies.length !== 1) throw new Error('Exactly one native reply not established; do not resend.');
        receipt.native_reply = {post_id:replies[0].post_id,creator_id:10,message:replyText,canonical_from_official_account:true};
    }
    fs.writeFileSync(receiptPath,JSON.stringify(receipt,null,2)+'\n');
    console.log(JSON.stringify(receipt));
}
main().catch(error => { console.error(error instanceof Error && !error.message.includes('fetch') ? error.message : 'Network request failed; no automatic retry.'); process.exitCode=1; });
