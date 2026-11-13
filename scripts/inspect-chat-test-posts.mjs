// Local interoperability probe. Credentials and session URLs are never logged.
// Mutation modes require their specific bounded authorization; default modes are read-only.
// --send-to-peter authorizes exactly one fixed test message to the uniquely resolved Peter DM.
import fs from 'node:fs';
import crypto from 'node:crypto';

async function main() {
    const rows = fs.readFileSync(process.env.HOME + '/Library/Application Support/synochat-client/db', 'utf8')
        .split('\n').filter(Boolean).map(JSON.parse);
    const current = new Map();
    for (const row of rows) {
        if (!row._id) continue;
        current.delete(row._id);
        if (row.$$deleted !== true) current.set(row._id, row);
    }
    const b = Buffer.from([...current.values()].findLast(x => x.type === 'session').data, 'base64');
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
    if(process.argv.includes('--reminder-delivery-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(own?.user_id!==10||JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Authorized reminder scope changed.');
        const channels=(await api('SYNO.Chat.Channel','list',5)).channels??[],spaces=channels.filter(c=>c.type==='synobot');
        const records=[];for(const channel of spaces){const memberIDs=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:channel.channel_id})).user_ids??[];records.push({channel_id:channel.channel_id,creator_id:channel.creator_id,type:channel.type,member_ids:memberIDs,unread:channel.unread??0});}
        const source=(await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:399431958766,prev_count:0,next_count:0})).posts?.find(p=>p.post_id===399431958766);
        if(source?.creator_id!==10||source.type!=='normal'||source.message!=='Native scheduled delivery test — Peter.')throw new Error('Exact synthetic reminder source changed.');
        const reminder=await api('SYNO.Chat.Post.Reminder','get',1,{post_id:source.post_id});
        let copies=[],testCopyAbsent=false;
        try { copies=(await api('SYNO.Chat.Post','list',5,{channel_id:10,post_id:42949673051,prev_count:0,next_count:0})).posts??[]; } catch(error) { if(error.message!=='API rejected request: 402')throw error;testCopyAbsent=true; }
        const testCopies=copies.filter(p=>p.props?.forward?.type==='reminder'&&p.props.forward.origin_post_id===source.post_id).map(p=>({post_id:p.post_id,creator_id:p.creator_id,type:p.type,origin_user_id:p.props.forward.origin_user_id,message_matches_source:p.message===source.message,creator_record:users.filter(u=>u.user_id===p.creator_id).map(u=>({user_id:u.user_id,type:u.type,username:u.username}))}));
        const p=(await api('SYNO.Chat.User.Preference','get',4)).preferences??{};
        const personalAlerts=(await api('SYNO.Chat.Channel.Preference','get',3,{channel_id:10})).preferences;
        console.log(JSON.stringify({personal_alerts:personalAlerts&&Object.fromEntries(['notification_desktop','notification_mobile'].map(k=>[k,personalAlerts[k]])),test_copy_absent:testCopyAbsent,test_copies:testCopies,own_id:10,source:{post_id:source.post_id,channel_id:93,message_sha256:crypto.createHash('sha256').update(source.message).digest('hex')},reminder,synobot_channels:records,notification_preferences:Object.fromEntries(['notification_showmessage','notification_mute','notification_browser_active','snooze','snooze_schedule_enable','snooze_schedule_start','snooze_schedule_end'].filter(k=>k in p).map(k=>[k,p[k]]))}));return;
    }
    if(process.argv.includes('--search-operators-readiness')||process.argv.includes('--search-calendar-readiness')||process.argv.includes('--search-general-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(own?.user_id!==10||JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Authorized search scope changed.');
        const cases={
            gif:{query:'Native from:u:10 in:@c:93 has:file filetype:gif after:2026-10-01 before:2026-10-31',params:{keyword:'Native',from:[10],in:[93],post_type:['file'],file_type:['gif'],after:new Date(2026,9,1).getTime(),before:new Date(2026,9,31,23,59,59).getTime()}},
            links:{query:'has:url in:@c:93',params:{keyword:'',in:[93],has:['url']}},
            pins:{query:'has:pin in:@c:93',params:{keyword:'',in:[93],has:['pin']}},
            bookmarks:{query:'has:bookmark in:@c:93',params:{keyword:'',in:[93],has:['star']}},
            hashtag:{query:'#NativeParity20261016 in:@c:93',params:{keyword:'',in:[93],hashtag:['NativeParity20261016']}},
            mention:{query:'@u:6 in:@c:93',params:{keyword:'',in:[93],mention:[6]}},
            multi:{query:'from:u:10 from:u:6 has:url has:reaction in:@c:93',params:{keyword:'',in:[93],from:[10,6],has:['url','reaction']}},
            files:{query:'has:file in:@c:93',params:{keyword:'',in:[93],post_type:['file']}}
        };
        const selectedCases=process.argv.includes('--search-general-readiness')?{
            author_files:{query:'in:@c:93 has:file from:u:10 before:2026-10-31',params:{keyword:'',in:[93],from:[10],post_type:['file'],before:new Date(2026,9,31,23,59,59).getTime()}},
            plain_keyword:{query:'in:@c:93 Pe',params:{keyword:'Pe',in:[93]}}
        }:process.argv.includes('--search-calendar-readiness')?{
            calendar:{query:'in:@c:93 has:file filetype:gif after:2026-10-19',params:{keyword:'',in:[93],post_type:['file'],file_type:['gif'],after:new Date(2026,9,19).getTime()}},
            caret_files:{query:'in:@c:93 has:file before:2026-10-31',params:{keyword:'',in:[93],post_type:['file'],before:new Date(2026,9,31,23,59,59).getTime()}},
            unselected_return:cases.pins,
            filetype:{query:'in:@c:93 filetype:gif',params:{keyword:'',in:[93],file_type:['gif']}},
            date_today:{query:'in:@c:93 has:file after:2026-10-20',params:{keyword:'',in:[93],post_type:['file'],after:new Date(2026,9,20).getTime()}}
        }:cases;
        for(const item of Object.values(selectedCases)) {
            let offset=0,pages=0,more=true,total=null;const posts=[];
            while(more&&pages<10){const result=await api('SYNO.Chat.Post','search',5,{...item.params,offset,limit:25});const rows=result.search_results??[];posts.push(...rows);offset+=rows.length;pages++;total=result.total??null;more=rows.length>=25&&(total===null||offset<total);}
            if(more||posts.some(p=>p.channel_id!==93))throw new Error('Scoped search exceeded bounds.');
            Object.assign(item,{total,pages,post_ids:posts.map(p=>p.post_id)});
        }
        console.log(JSON.stringify({channel_id:93,member_ids:[6,10],local_timezone:Intl.DateTimeFormat().resolvedOptions().timeZone,cases:selectedCases}));return;
    }
    if(process.argv.some(x=>['--emoji-preferences-readiness','--prepare-emoji-recent-test','--emoji-recent-test-state','--restore-emoji-recent-test'].includes(x))) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        if(own?.user_id!==10)throw new Error('Own emoji account changed.');
        const settings=await api('SYNO.Core.UserSettings','get',1);
        const catalogue=new Set([...fs.readFileSync(new URL('../reference/synology-chat/cache/server-emojione-rulemap.js',import.meta.url),'utf8').matchAll(/name:"([A-Za-z0-9_+\-]+)",unicode:/g)].map(m=>m[1]));
        const stable=v=>Array.isArray(v)?v.map(stable):v&&typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,stable(v[k])])):v;
        const chat=settings['SYNO.SDS.Chat.Application'];const others={...settings};delete others['SYNO.SDS.Chat.Application'];
        const chatOther=chat&&typeof chat==='object'?{...chat}:{};delete chatOther.recent_emojies;
        const hash=v=>crypto.createHash('sha256').update(JSON.stringify(stable(v))).digest('hex');
        if(!process.argv.includes('--emoji-preferences-readiness')) {
            if(!Array.isArray(chat?.recent_emojies)||!chat.recent_emojies.every(x=>catalogue.has(x)))throw new Error('Exact known recent-list baseline required.');
            const scope=hash([base.origin,base.pathname.replace(/\/+$/,''),own.user_id]);
            const path=new URL('../reference/synology-chat/evidence/2026-10-20/emoji-recent-live-receipt.json',import.meta.url);
            let receipt=fs.existsSync(path)?JSON.parse(fs.readFileSync(path,'utf8')):null;
            let observedRecent=chat.recent_emojies;
            const save=phase=>{receipt={...receipt,phase};fs.writeFileSync(path,JSON.stringify(receipt,null,2)+'\n');};
            if(process.argv.includes('--prepare-emoji-recent-test')) {
                if(receipt||chat.recent_emojies.includes('heart'))throw new Error('Test already prepared or marker already present.');
                receipt={scope_sha256:scope,original_recent:chat.recent_emojies,expected_recent:['heart',...chat.recent_emojies].slice(0,24),unrelated_chat_sha256:hash(chatOther),unrelated_desktop_sha256:hash(others)};save('prepared');
            } else {
                if(!receipt||receipt.scope_sha256!==scope)throw new Error('Exact account receipt required.');
                const original=JSON.stringify(chat.recent_emojies)===JSON.stringify(receipt.original_recent),expected=JSON.stringify(chat.recent_emojies)===JSON.stringify(receipt.expected_recent);
                if(expected&&receipt.phase==='prepared'){receipt={...receipt,observed_unrelated_chat_sha256:hash(chatOther),observed_unrelated_desktop_sha256:hash(others)};save('observed');}
                if(original&&receipt.phase==='restore_dispatched')save('restored_confirmed');
                if(process.argv.includes('--restore-emoji-recent-test')) {
                    if(receipt.phase==='restored_confirmed'){console.log(JSON.stringify({phase:receipt.phase,write_dispatched:false}));return;}
                    if(receipt.phase!=='observed'||!expected)throw new Error('Recent list changed or previous dispatch unresolved; no retry.');
                    save('restore_dispatched');
                    await api('SYNO.Core.UserSettings','apply',1,{data:JSON.stringify({'SYNO.SDS.Chat.Application':{...chat,recent_emojies:receipt.original_recent}})});
                    const after=await api('SYNO.Core.UserSettings','get',1),afterChat={...after['SYNO.SDS.Chat.Application']},afterOthers={...after};delete afterOthers['SYNO.SDS.Chat.Application'];
                    if(JSON.stringify(afterChat.recent_emojies)!==JSON.stringify(receipt.original_recent))throw new Error('Restore unconfirmed; no retry.');
                    observedRecent=afterChat.recent_emojies;
                    delete afterChat.recent_emojies;
                    if(hash(afterChat)!==hash(chatOther)||hash(afterOthers)!==hash(others))throw new Error('Unrelated setting fingerprint changed; inspect without replay.');
                    receipt={...receipt,after_unrelated_chat_sha256:hash(afterChat),after_unrelated_desktop_sha256:hash(afterOthers)};save('restored_confirmed');
                }
            }
            console.log(JSON.stringify({phase:receipt.phase,current_recent:observedRecent,scope_sha256:scope,unrelated_chat_sha256:hash(chatOther),unrelated_desktop_sha256:hash(others)}));return;
        }
        console.log(JSON.stringify({own_id:10,chat_present:!!chat,chat_keys:chat?Object.keys(chat).sort():[],recent_type:chat?.recent_emojies===undefined?'absent':Array.isArray(chat.recent_emojies)?'array':typeof chat.recent_emojies,recent:Array.isArray(chat?.recent_emojies)?chat.recent_emojies.filter(x=>catalogue.has(x)):[],invalid_recent_count:Array.isArray(chat?.recent_emojies)?chat.recent_emojies.filter(x=>!catalogue.has(x)).length:0,unrelated_chat_sha256:hash(chatOther),unrelated_desktop_sha256:hash(others)}));return;
    }
    if(process.argv.includes('--image-gallery-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(own?.user_id!==10||JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Authorized image scope changed.');
        const result=await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:399431958768,prev_count:50,next_count:50,file_type:['image']});
        const shape=p=>({post_id:p.post_id,type:p.type,channel_id:p.channel_id,thread_id:p.thread_id??0,is_image:p.file_props?.is_image??false,deleted:!!p.delete_at,filename_sha256:crypto.createHash('sha256').update(p.file_props?.name??'').digest('hex')});
        const reply=(await api('SYNO.Chat.Post','search',5,{keyword:'',in:[93],post_type:['file'],file_type:['image'],offset:0,limit:25})).search_results?.find(p=>p.thread_id>0&&p.thread_id!==p.post_id);
        if(!reply?.thread_id)throw new Error('Synthetic image reply scope changed.');
        const thread=await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:reply.post_id,thread_id:reply.thread_id,prev_count:50,next_count:50,file_type:['image']});
        console.log(JSON.stringify({channel_id:93,anchor:399431958768,rows:(result.posts??[]).map(shape),thread:{anchor:reply.post_id,root:reply.thread_id,rows:(thread.posts??[]).map(shape)}}));return;
    }
    if(process.argv.some(x=>/^--collection-live-(create|edit|delete|state)$/.test(x))) {
        const mode=process.argv.find(x=>/^--collection-live-/.test(x)).replace('--collection-live-','');
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(own?.user_id!==10||JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Authorized collection scope changed.');
        const hash=s=>crypto.createHash('sha256').update(s).digest('hex');
        const scope=hash(JSON.stringify([base.origin,base.pathname.replace(/\/+$/,''),own.user_id]));
        const oldURL='https://www.synology.com/en-global/dsm/feature/chat';
        const newURL=oldURL+'?native_collection_test=20261020';
        const initial='Native collection live test 20261020 — '+oldURL+' '+newURL;
        const edited='Native collection live test 20261020 — edited '+newURL;
        const path=new URL('../reference/synology-chat/evidence/2026-10-20/collection-live-receipt.json',import.meta.url);
        let receipt=fs.existsSync(path)?JSON.parse(fs.readFileSync(path,'utf8')):null;
        const save=(phase,extra={})=>{receipt={...receipt,scope_sha256:scope,channel_id:93,initial_sha256:hash(initial),edited_sha256:hash(edited),phase,...extra};fs.writeFileSync(path,JSON.stringify(receipt,null,2)+'\n');};
        if(receipt&&(receipt.scope_sha256!==scope||receipt.channel_id!==93||receipt.initial_sha256!==hash(initial)||receipt.edited_sha256!==hash(edited)))throw new Error('Collection receipt scope changed.');
        const canonical=async()=>{try{return ((await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:receipt.post_id,prev_count:0,next_count:0})).posts??[]).find(p=>p.post_id===receipt.post_id);}catch(e){if(e.message==='API rejected request: 402')return null;throw e;}};
        if(mode==='create') {
            if(receipt)throw new Error('Creation already attempted; no automatic retry.');
            const recent=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:50,next_count:0})).posts??[];
            if(recent.some(p=>p.message===initial||p.message===edited))throw new Error('Marker already exists.');
            const baseline=await api('SYNO.Chat.Post','search',5,{keyword:'',in:[93],has:['url'],offset:0,limit:25});
            if((baseline.search_results??[]).some(p=>(p.url_props??[]).some(u=>u.url===newURL)))throw new Error('Unique URL already exists.');
            save('create_dispatched',{baseline_source_ids:(baseline.search_results??[]).map(p=>p.post_id),old_url_sha256:hash(oldURL),new_url_sha256:hash(newURL)});
            const post=await api('SYNO.Chat.Post','create',5,{channel_id:93,type:'normal',message:initial,is_thread:false,thread_id:0,conn_id:''});
            if(!post?.post_id||post.channel_id!==93||post.creator_id!==10||post.message!==initial)throw new Error('Create response unconfirmed; no retry.');
            save('created',{post_id:post.post_id});
        } else if(mode!=='state') {
            if(!receipt?.post_id)throw new Error('Exact synthetic receipt missing.');
            const post=await canonical();
            if(!post||post.channel_id!==93||post.creator_id!==10||post.type!=='normal'||![initial,edited].includes(post.message))throw new Error('Exact own synthetic target changed.');
            if(mode==='edit') {
                if(receipt.phase!=='created'||post.message!==initial)throw new Error('Edit already attempted or wrong phase.');
                save('edit_dispatched');
                await api('SYNO.Chat.Post','set',8,{post_id:post.post_id,channel_id:93,thread_id:0,message:edited});
                const updated=await canonical();if(updated?.message!==edited)throw new Error('Edit unconfirmed; no retry.');
                save('edited');
            } else {
                if(!['created','edited'].includes(receipt.phase))throw new Error('Delete already attempted or unresolved.');
                save('delete_dispatched');
                await api('SYNO.Chat.Post','delete',8,{post_id:post.post_id,real_delete:false});
                const deleted=await canonical();if(deleted&&!deleted.delete_at)throw new Error('Delete unconfirmed; no retry.');
                save('deleted_confirmed',{real_delete:false,confirmation:deleted?'tombstone':'kPostNotFound402'});
            }
        }
        const post=receipt?.post_id?await canonical():null;
        console.log(JSON.stringify({phase:receipt?.phase??null,post_id:receipt?.post_id??null,exists:!!post,url_hashes:(post?.url_props??[]).map(u=>hash(u.url??'')),message_sha256:post?hash(post.message??''):null}));return;
    }
    if(process.argv.includes('--link-library-duplicate-state')||process.argv.includes('--cleanup-link-library-duplicate')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(own?.user_id!==10||JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Authorized duplicate test scope changed.');
        const scope=crypto.createHash('sha256').update(JSON.stringify([base.origin,base.pathname.replace(/\/+$/,''),own.user_id])).digest('hex');
        const text='Native link-library duplicate test 20261020 — https://www.synology.com/en-global/dsm/feature/chat';
        const receiptPath=new URL('../reference/synology-chat/evidence/2026-10-20/link-library-duplicate-cleanup.json',import.meta.url);
        const receipt=fs.existsSync(receiptPath)?JSON.parse(fs.readFileSync(receiptPath,'utf8')):null;
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:50,next_count:0})).posts??[];
        const matches=posts.filter(p=>p.channel_id===93&&p.creator_id===10&&p.type==='normal'&&p.message===text&&!p.delete_at);
        if(matches.length>1)throw new Error('Duplicate test marker is ambiguous; no cleanup dispatched.');
        if(!process.argv.includes('--cleanup-link-library-duplicate')) {
            if(matches.length===1&&!receipt)fs.writeFileSync(receiptPath,JSON.stringify({channel_id:93,scope_sha256:scope,post_id:matches[0].post_id,message_sha256:crypto.createHash('sha256').update(text).digest('hex'),phase:'observed'},null,2)+'\n');
            if(matches.length===1&&receipt&&receipt.post_id!==matches[0].post_id)throw new Error('Duplicate receipt identity changed.');
            const recorded=receipt?posts.find(p=>p.post_id===receipt.post_id):null;
            let lookup=null;if(receipt){try{const data=await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:receipt.post_id,prev_count:0,next_count:0});const found=data?.posts?.find(p=>p.post_id===receipt.post_id);lookup={found:!!found,deleted:!!found?.delete_at};}catch(error){const code=/^API rejected request: ([0-9]+)$/.exec(error.message);lookup={api_error_code:code?Number(code[1]):null};}}
            console.log(JSON.stringify({matches:matches.map(p=>({post_id:p.post_id,channel_id:p.channel_id,creator_id:p.creator_id,url_count:(p.url_props??[]).length})),receipt_phase:receipt?.phase??null,scope_sha256:scope,recorded_recent:recorded?{post_id:recorded.post_id,deleted:!!recorded.delete_at,type:recorded.type}:null,lookup}));return;
        }
        if(!receipt||receipt.scope_sha256!==scope||receipt.channel_id!==93||receipt.message_sha256!==crypto.createHash('sha256').update(text).digest('hex'))throw new Error('Exact test cleanup receipt missing.');
        let absentCode=null;
        const canonical=async()=>{try{return ((await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:receipt.post_id,prev_count:0,next_count:0}))?.posts??[]).find(p=>p.post_id===receipt.post_id);}catch(error){if(error.message==='API rejected request: 402'){absentCode=402;return null;}throw error;}};
        let current=await canonical();
        if(!current||current.delete_at){fs.writeFileSync(receiptPath,JSON.stringify({...receipt,phase:'deleted_confirmed',real_delete:false,confirmation:absentCode===402?'kPostNotFound402':'absent_or_tombstone'},null,2)+'\n');console.log(JSON.stringify({post_id:receipt.post_id,deleted:true,write_dispatched:false}));return;}
        if(receipt.phase!=='observed')throw new Error('Previous cleanup dispatch is unresolved; no automatic retry.');
        if(current.channel_id!==93||current.creator_id!==10||current.type!=='normal'||current.message!==text||matches.length!==1||matches[0].post_id!==receipt.post_id)throw new Error('Exact own synthetic cleanup target changed.');
        fs.writeFileSync(receiptPath,JSON.stringify({...receipt,phase:'delete_dispatched'},null,2)+'\n');
        await api('SYNO.Chat.Post','delete',8,{post_id:receipt.post_id,real_delete:false});
        current=await canonical();if(current&&!current.delete_at)throw new Error('Synthetic deletion unconfirmed; no retry.');
        fs.writeFileSync(receiptPath,JSON.stringify({...receipt,phase:'deleted_confirmed',real_delete:false,confirmation:absentCode===402?'kPostNotFound402':'absent_or_tombstone'},null,2)+'\n');
        console.log(JSON.stringify({post_id:receipt.post_id,deleted:true,write_dispatched:true}));return;
    }
    if(process.argv.includes('--link-library-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        if(own?.user_id!==10)throw new Error('Authorized link account changed.');
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Peter membership changed.');
        const posts=[];let offset=0,more=true,pages=0,total=null;
        while(more&&pages<10){const result=await api('SYNO.Chat.Post','search',5,{keyword:'',in:[93],has:['url'],offset,limit:25});const page=result.search_results??[];posts.push(...page);offset+=page.length;total=result.total??null;pages++;more=page.length>=25&&(total===null||offset<total);}
        if(more)throw new Error('Link baseline exceeded bounded page budget.');
        const seen=new Set(),entries=[];
        for(const post of posts){if(post.delete_at||post.props?.encrypted===true)continue;for(const preview of post.url_props??[]){
            const raw=preview.url;if(typeof raw!=='string'||raw.length>8192)continue;let url;try{url=new URL(raw);if(!['http:','https:'].includes(url.protocol)||!url.hostname||url.username||url.password||/\p{Cc}/u.test(decodeURIComponent(raw))||[...url.searchParams.keys()].some(k=>['_sid','synotoken'].includes(k.toLowerCase())))continue;}catch{continue;}
            if(seen.has(raw))continue;seen.add(raw);entries.push({url_sha256:crypto.createHash('sha256').update(raw).digest('hex'),post_id:post.post_id,channel_id:post.channel_id,time:post.update_at||post.create_at,has_title:typeof preview.title==='string'&&preview.title.length>0,has_description:typeof preview.description==='string'&&preview.description.length>0,has_image:typeof preview.image==='string'&&preview.image.length>0,hidden:preview.hidden===true,safe:post.props?.safe_url!==false});
        }}
        entries.sort((a,b)=>b.time-a.time);
        const settings=await api('SYNO.Chat.Admin.Setting','get',5);
        console.log(JSON.stringify({channel_id:93,member_ids:[6,10],source_post_ids:posts.map(p=>p.post_id),source_count:posts.length,total,pages,url_property_count:posts.reduce((n,p)=>n+(p.url_props??[]).length,0),inline_previews_hidden:settings.hide_post_url_preview!==false,entries}));return;
    }
    if(process.argv.includes('--file-library-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        if(own?.user_id!==10)throw new Error('Authorized test account changed.');
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Peter membership changed.');
        const channel=(await api('SYNO.Chat.Channel','list',5)).channels?.find(c=>c.channel_id===93);
        if(!channel||channel.encrypted||channel.is_closed)throw new Error('Peter file scope changed.');
        const orders={};for(const category of ['all','image'])for(const sort of ['create_at','file_name']) {
            const rows=[];let total=null,offset=0,pages=0,more=true;
            while(more&&pages<10) {
                const result=await api('SYNO.Chat.Post','search',5,{keyword:'',in:[93],post_type:['file'],file_type:category==='image'?['image']:[],sort_by:sort,offset,limit:25});
                const page=result.search_results??[];total=result.total??null;rows.push(...page);offset+=page.length;pages++;more=page.length>=25&&(total===null||offset<total);
            }
            if(more)throw new Error('File baseline exceeded bounded page budget.');
            orders[category+':'+sort]={total,pages,rows:rows.map(p=>({post_id:p.post_id,type:p.type,is_image:p.file_props?.is_image??null,filename_sha256:crypto.createHash('sha256').update(p.file_props?.name??'').digest('hex')}))};
        }
        const links=await api('SYNO.Chat.Post','search',5,{keyword:'',in:[93],has:['url'],offset:0,limit:25});
        console.log(JSON.stringify({channel_id:93,member_ids:[6,10],orders,links:{total:links.total??null,post_ids:(links.search_results??[]).map(p=>p.post_id)}}));return;
    }
    if(process.argv.includes('--pin-order-readiness')||process.argv.includes('--pin-order-system-audit')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        if(own?.user_id!==10)throw new Error('Authorized test account changed.');
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Peter membership changed.');
        const channel=(await api('SYNO.Chat.Channel','list',5)).channels?.find(c=>c.channel_id===93);
        if(!channel||channel.encrypted)throw new Error('Peter channel changed.');
        if(process.argv.includes('--pin-order-system-audit')) {
            const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:15,next_count:0})).posts??[];
            console.log(JSON.stringify(posts.filter(p=>p.post_id>399431958772).map(p=>({post_id:p.post_id,channel_id:p.channel_id,type:p.type,creator_id:p.creator_id,event:p.system_props?.event??null,trigger_user_id:p.system_props?.trigger_user_id??null}))));return;
        }
        const targets=[];
        for(const [id,text] of [[399431958768,'Native animated image viewer test — synthetic colours only.'],[399431958767,'Native NAS file-copy test — synthetic content only.']]) {
            const p=(await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:id,prev_count:0,next_count:0})).posts?.find(p=>p.post_id===id&&p.channel_id===93&&p.creator_id===10&&p.message===text&&!p.delete_at);
            if(!p)throw new Error('Synthetic pin target changed.');
            const stable=[p.post_id,p.channel_id,p.creator_id,p.message,p.type,p.create_at,p.file_props??null,p.props??null,p.reactions??[],p.hashtags??[],p.hashtags_additional??[]];
            targets.push({post_id:id,thread_id:p.thread_id??0,comment_count:p.comment_count??0,last_pin_at:p.last_pin_at??0,is_sticky:p.is_sticky??false,last_comment_at:p.last_comment_at??0,stable_post_sha256:crypto.createHash('sha256').update(JSON.stringify(stable)).digest('hex')});
        }
        const orders={};for(const sort of ['last_pin_at','last_comment_at','create_at']) {const page=await api('SYNO.Chat.Post','search',5,{keyword:'',in:[93],has:['pin'],sort_by:sort,sort_by_array:['is_sticky',sort],offset:0,limit:25});orders[sort]=(page.search_results??[]).map(p=>({post_id:p.post_id,is_sticky:p.is_sticky??false,last_comment_at:p.last_comment_at??null}));}
        console.log(JSON.stringify({channel_id:93,member_ids:[6,10],subscribes:channel.subscribes??null,targets,orders}));return;
    }
    if(process.argv.includes('--additional-hashtag-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        if(own?.user_id!==10)throw new Error('Authorized test account changed.');
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Peter test membership changed.');
        const result=await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:399431958768,prev_count:0,next_count:0});
        const post=result.posts?.find(p=>p.post_id===399431958768&&p.channel_id===93&&p.creator_id===10&&p.message==='Native animated image viewer test — synthetic colours only.'&&!p.delete_at);
        if(!post)throw new Error('Synthetic tag target changed.');
        const catalogue=await api('SYNO.Chat.Channel.Hashtag','list',1,{channel_id:93});
        const stable=[post.post_id,post.channel_id,post.creator_id,post.message,post.type,post.create_at,post.file_props??null,post.props??null,post.reactions??[]];
        console.log(JSON.stringify({channel_id:93,post_id:post.post_id,member_ids:[6,10],indexed:post.hashtags??[],additional:post.hashtags_additional??[],stable_post_sha256:crypto.createHash('sha256').update(JSON.stringify(stable)).digest('hex'),catalogue_count:(catalogue.hashtags??[]).length,synthetic_tag_in_catalogue:(catalogue.hashtags??[]).includes('NativeAdditional20261020')}));return;
    }
    if(process.argv.includes('--reaction-details-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase()),peer=users.find(u=>u.user_id===6&&u.nickname==='Peter');
        if(own?.user_id!==10||!peer)throw new Error('Authorized test identities changed.');
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
        if(JSON.stringify([...members].sort((a,b)=>a-b))!=='[6,10]')throw new Error('Peter test membership changed.');
        const result=await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:399431958768,prev_count:0,next_count:0});
        const post=result.posts?.find(p=>p.post_id===399431958768&&p.channel_id===93&&p.creator_id===10&&p.message==='Native animated image viewer test — synthetic colours only.'&&!p.delete_at);
        if(!post)throw new Error('Synthetic reaction-details target changed.');
        console.log(JSON.stringify({channel_id:93,post_id:post.post_id,member_ids:[6,10],reactions:post.reactions??[]}));return;
    }
    if(process.argv.includes('--name-format-readiness')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],own=users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase()),peer=users.find(u=>u.user_id===6&&u.nickname==='Peter'&&u.type==='human'&&u.human_type==='dsm');
        if(own?.user_id!==10||!peer)throw new Error('Authorized test identities changed.');
        const members=await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93});
        if(JSON.stringify([...(members.user_ids??[])].sort((a,b)=>a-b))!==JSON.stringify([6,10]))throw new Error('Peter test membership changed.');
        const result=await api('SYNO.Chat.User.Preference','get',4),prefs=result.preferences??{};
        const fingerprint=u=>crypto.createHash('sha256').update(JSON.stringify([u.user_id,u.username??null,u.nickname,u.type,u.human_type])).digest('hex');
        console.log(JSON.stringify({channel_id:93,member_ids:[6,10],mode:prefs.prefer_user_name_format,raw_identity_sha256:{owner:fingerprint(own),peer:fingerprint(peer)},other_preferences:Object.fromEntries(['sidebar_pinning_unread','notification_showmessage','notification_browser_active','notification_mute','calendar_enable'].filter(k=>k in prefs).map(k=>[k,prefs[k]]))}));return;
    }
    if(process.argv.includes('--sidebar-preference-readiness')) {
        const result=await api('SYNO.Chat.User.Preference','get',4);
        const channels=await api('SYNO.Chat.Channel','list',5,{is_joined:true});
        const prefs=result.preferences??{};
        console.log(JSON.stringify({preferences:Object.fromEntries(['sidebar_pinning_unread','notification_showmessage','notification_browser_active','notification_mute','calendar_enable','prefer_user_name_format'].filter(k=>k in prefs).map(k=>[k,prefs[k]])),channel_count:channels.channels?.length??0,raw_unread_channel_count:(channels.channels??[]).filter(c=>(c.unread??0)>0||Object.values(c.unread_thread??{}).some(n=>n>0)).length}));return;
    }
    if(process.argv.includes('--channel-alert-readiness')||process.argv.includes('--channel-alert-self-channel-readiness')) {
        const selfChannel=process.argv.includes('--channel-alert-self-channel-readiness'),channelID=selfChannel?96:93,wanted=selfChannel?[10]:[6,10];
        if(selfChannel){const result=await api('SYNO.Chat.Channel','list',5,{is_joined:true});if(!result.channels?.some(c=>c.channel_id===96&&c.type==='private'&&c.name==='Peter-Native-API-test'&&!c.is_closed))throw new Error('Synthetic self-only channel changed.');}
        const ids=await api('SYNO.Chat.Channel.Member','get',1,{channel_id:channelID});
        if(JSON.stringify([...(ids.user_ids??[])].sort((a,b)=>a-b))!==JSON.stringify(wanted))throw new Error('Authorized test membership changed.');
        const result=await api('SYNO.Chat.Channel.Preference','get',3,{channel_id:channelID});
        console.log(JSON.stringify({channel_id:channelID,member_ids:wanted,schema:shape(result),preferences:{notification_desktop:result.preferences?.notification_desktop,notification_mobile:result.preferences?.notification_mobile,notification_mute:result.preferences?.notification_mute}}));return;
    }
    if(process.argv.includes('--channel-close-read-schema')) {
        const joined=await api('SYNO.Chat.Channel','list',5,{is_joined:true});
        const fixture=joined.channels?.find(c=>c.channel_id===97&&c.name==='Peter-Native-Archive-test');
        if(!fixture) throw new Error('Approved fixture unavailable.');
        const result=await api('SYNO.Chat.Channel','get',4,{channel_id:fixture.channel_id});
        const reasons=[];
        for(const type of ['private','anonymous']) {
            const names=await api('SYNO.Chat.Archive','list_name',1,{type});
            for(const name of names.channel_names??[]) {
                const periods=await api('SYNO.Chat.Archive','list',1,{type,channel_name:name});
                for(const period of periods.archives??[]) reasons.push({type,archive_id:period.archive_id,reason:period.props?.reason,encrypted:period.props?.channel?.encrypted});
            }
        }
        console.log(JSON.stringify({schema:shape(result),channel_id:result.channel?.channel_id??result.channel_id??null,is_closed:result.channel?.is_closed??result.is_closed??null,archive_reasons:reasons}));return;
    }
    if(process.argv.includes('--archive-search-schema')) {
        const out=[];
        for(const type of ['private','anonymous']) {
            const names=await api('SYNO.Chat.Archive','list_name',1,{type});
            for(const name of names.channel_names??[]) {
                const data=await api('SYNO.Chat.Archive','list',1,{type,channel_name:name});
                const ids=(data.archives??[]).filter(a=>!a.props.channel.encrypted).map(a=>a.archive_id);
                if(!ids.length) continue;
                for(const mode of ['all','pin','star','file','url']) {
                    const params={archives:ids,in:[],keyword:'',offset:0,limit:25};
                    if(['pin','star','url'].includes(mode)) params.has=[mode];
                    if(mode==='file') {params.post_type=['file'];params.sort_by='create_at';}
                    if(mode==='pin') {params.sort_by='last_pin_at';params.sort_by_array=['is_sticky','last_pin_at'];}
                    const page=await api('SYNO.Chat.Post','search',5,params);
                    out.push({type,archive_ids:ids,mode,schema:shape(page),total:page.total,count:page.search_results?.length??null,
                        all_in_scope:(page.search_results??[]).every(p=>data.archives.some(a=>a.props.channel.channel_id===p.channel_id&&p.post_id>=a.post_id_start&&p.post_id<=a.post_id_end))});
                }
            }
        }
        console.log(JSON.stringify(out));return;
    }
    if(process.argv.includes('--archive-thread-schema')) {
        const out=[];
        for(const type of ['private','anonymous']) {
            const names=await api('SYNO.Chat.Archive','list_name',1,{type});
            for(const name of names.channel_names??[]) {
                const data=await api('SYNO.Chat.Archive','list',1,{type,channel_name:name});
                for(const archive of data.archives??[]) {
                    if(archive.props.channel.encrypted) continue;
                    const page=await api('SYNO.Chat.Post','list',5,{archive_id:archive.archive_id,channel_id:archive.props.channel.channel_id,prev_count:30,next_count:0});
                    const roots=(page.posts??[]).filter(p=>p.comment_count>0&&(!p.thread_id||p.thread_id===p.post_id));
                    const threads=[];
                    for(const root of roots) {
                        const result=await api('SYNO.Chat.Post','list',5,{archive_id:archive.archive_id,channel_id:archive.props.channel.channel_id,thread_id:root.post_id,prev_count:30,next_count:0});
                        threads.push({root_id:root.post_id,comment_count:root.comment_count,reply_count:result.posts?.length??0,schema:shape(result),all_match:(result.posts??[]).every(p=>p.post_id===root.post_id||p.thread_id===root.post_id)});
                    }
                    out.push({type,archive_id:archive.archive_id,root_count:roots.length,threads,system_events:(page.posts??[]).filter(p=>p.type==='system').map(p=>({post_id:p.post_id,event:p.system_props?.event,effective_user_id:p.system_props?.effective_user_id,update_attrs:p.system_props?.extra?.update_info?.map(u=>u.attr)??[]}))});
                }
            }
        }
        console.log(JSON.stringify(out));return;
    }
    if(process.argv.includes('--archive-list-schema')) {
        const out=[];
        for(const type of ['private','public','anonymous','chatbot']) {
            try {
                const names=await api('SYNO.Chat.Archive','list_name',1,{type});
                const first=names.channel_names?.[0];
                const realname=typeof first==='string'?first:first?.realname;
                const records=realname ? await api('SYNO.Chat.Archive','list',1,{type,channel_name:realname}) : {archives:[]};
                const firstArchive=records.archives?.[0];
                const posts=firstArchive&&!firstArchive.props?.channel?.encrypted ? await api('SYNO.Chat.Post','list',5,{archive_id:firstArchive.archive_id,channel_id:firstArchive.props.channel.channel_id,prev_count:30,next_count:0}) : null;
                out.push({type,names_schema:shape(names),schema:shape(records),post_schema:shape(posts),post_count:posts?.posts?.length??null,reason:firstArchive?.props?.reason??null,count:records.archives?.length??null,
                    first_metadata:records.archives?.[0] ? Object.fromEntries(Object.entries(records.archives[0]).filter(([k])=>!['props','name','channel_name'].includes(k))) : null});
            } catch(error) {out.push({type,error_code:/API rejected request: (\d+)/.exec(error.message)?.[1]??'local'});}
        }
        console.log(JSON.stringify(out));return;
    }
    if(process.argv.includes('--archive-bundle-contract')) {
        // Filename is declared in the installed server's Chat config manifest.
        const url=new URL('/webman/3rdparty/Chat/synochat-archive.js',base);
        const r=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(20000)});
        if(!r.ok) throw new Error('Archive bundle unavailable: '+r.status);
        const text=await r.text();
        if(text.length>12000000||!text.includes('SYNO.SDS.Chat.Archive')||text.includes(session.sid)||text.includes(session.synotoken)) throw new Error('Refusing invalid or credential-bearing bundle.');
        const path='reference/synology-chat/cache/server-synochat-archive.js';fs.writeFileSync(path,text);
        console.log(JSON.stringify({path,source_path:url.pathname,bytes:Buffer.byteLength(text),sha256:crypto.createHash('sha256').update(text).digest('hex')}));return;
    }
    if(process.argv.includes('--desktop-settings-config')) {
        const data=await api('SYNO.Core.Desktop.Initdata','get',1,{action:'jsconfig',launch_app:'SYNO.SDS.Chat.Application'});
        const config=data.JSConfig??{},paths=new Set();
        function visit(v) { if(typeof v==='string'&&/\.js(?:[?]|$)/.test(v)&&v.length<1024) {try {const u=new URL(v,base);if(u.origin===base.origin) paths.add(u.pathname);}catch{}} else if(Array.isArray(v)) v.forEach(visit);else if(v&&typeof v==='object') Object.values(v).forEach(visit); }
        visit(config);console.log(JSON.stringify({top_keys:Object.keys(data),settings_libraries:Object.fromEntries(Object.entries(config).map(([path,value])=>[path,Object.keys(value??{}).filter(name=>/DateTime|Profile.Panel|UserSettings|AppLauncher.Panel|FileChooser/.test(name))]).filter(([,names])=>names.length)),paths:[...paths]}));return;
    }
    if(process.argv.includes('--cache-desktop-settings-source')) {
        const assets=[];
        for(const source of ['/webman/modules/FileChooser/FileChooser.js','/synoSDSjslib/dist/extjs-patch.bundle.js','/webman/3rdparty/SynologyApplicationService/AppLauncher.js','/webman/3rdparty/SynologyApplicationService/Profile.js','/synoSDSjslib/dist/vendor.bundle.js','/webman/entry/dist/dsm.entry.bundle.js','/synoSDSjslib/dist/sds.bundle.js','/webman/sds/dist/dsm.common.bundle.js','/webman/sds/dist/dsm.sds.bundle.js','/webman/desktop/dist/dsm.desktop.bundle.js']) {
            const url=new URL(source,base),response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(20000)});if(!response.ok) throw new Error('Desktop source unavailable.');
            const bytes=Buffer.from(await response.arrayBuffer()),text=bytes.toString('utf8');if(bytes.length>20*1024*1024||text.includes(session.sid)||text.includes(session.synotoken)) throw new Error('Refusing invalid source cache.');
            const path='reference/synology-chat/cache/server-'+source.split('/').at(-1);fs.writeFileSync(path,bytes);assets.push({path,source,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});
        }
        console.log(JSON.stringify({assets}));return;
    }
    if(process.argv.includes('--desktop-script-paths')) {
        const url=new URL('/',base);url.search=new URLSearchParams({launchApp:'SYNO.SDS.Chat.Application',_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(20000)});if(!response.ok) throw new Error('Desktop shell unavailable.');
        const html=await response.text();if(html.length>2*1024*1024) throw new Error('Desktop shell too large.');
        const scripts=[...html.matchAll(/<script[^>]+src=["']([^"']+)["']/gi)].map(m=>new URL(m[1].replaceAll('&amp;','&'),base)).filter(u=>u.origin===base.origin);
        const quoted=[...html.matchAll(/["']([^"'\r\n]*\.js[^"'\r\n]*)["']/gi)].flatMap(m=>{try { const u=new URL(m[1],base);return u.origin===base.origin ? [u.pathname] : []; } catch { return []; }});
        console.log(JSON.stringify({quoted_paths:[...new Set(quoted)],scripts:scripts.map(u=>({path:u.pathname,parameters:Object.fromEntries([...u.searchParams].filter(([k])=>['api','method','version','name','app','type'].includes(k)))}))}));return;
    }
    if(process.argv.includes('--archive-resource-contract')) {
        const url=new URL('/',base);url.search=new URLSearchParams({launchApp:'SYNO.SDS.Chat.Archive.Application',_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(20000)});
        if(!response.ok) throw new Error('Archive shell unavailable.');
        const html=await response.text();if(html.length>2*1024*1024) throw new Error('Archive shell too large.');
        const scripts=[...html.matchAll(/<script[^>]+src=["']([^"']+)["']/gi)].map(m=>new URL(m[1].replaceAll('&amp;','&'),base));
        let manifestPaths=[];
        const defs=scripts.find(u=>u.searchParams.get('api')==='SYNO.Core.Desktop.Defs');
        if(defs) {
            defs.searchParams.set('_sid',session.sid);defs.searchParams.set('SynoToken',session.synotoken);
            const r=await fetch(defs,{redirect:'error',signal:AbortSignal.timeout(20000)});
            if(r.ok) {
                const text=await r.text();if(text.length>4*1024*1024||text.includes(session.sid)||text.includes(session.synotoken)) throw new Error('Refusing credential-bearing or oversized app manifest.');
                fs.writeFileSync('reference/synology-chat/cache/server-archive-defs.js',text);
                manifestPaths=[...text.matchAll(/["']([^"'\r\n]*(?:chat|archive)[^"'\r\n]*\.js[^"'\r\n]*)["']/gi)].flatMap(m=>{try { const u=new URL(m[1],base);return u.origin===base.origin&&u.pathname.length<512 ? [u] : []; } catch { return []; }});
            }
        }
        const quoted=[...html.matchAll(/["']([^"'\r\n]*\.js[^"'\r\n]*)["']/gi)].flatMap(m=>{try { const u=new URL(m[1].replaceAll('&amp;','&'),base);return u.origin===base.origin ? [u] : []; } catch { return []; }});
        const own=[...new Map([...scripts,...quoted,...manifestPaths].filter(u=>u.origin===base.origin&&/chat|archive/i.test(u.pathname)).map(u=>[u.pathname,u])).values()];
        const assets=[];
        for(const [index,asset] of own.entries()) {
            const file=await fetch(asset,{redirect:'error',signal:AbortSignal.timeout(20000)});if(!file.ok) continue;
            const bytes=Buffer.from(await file.arrayBuffer());if(bytes.length>12*1024*1024) throw new Error('Archive asset too large.');
            const text=bytes.toString('utf8');if(text.includes(session.sid)||text.includes(session.synotoken)) throw new Error('Refusing credential-bearing source cache.');
            const path='reference/synology-chat/cache/server-archive-'+index+'.js';fs.writeFileSync(path,bytes);
            assets.push({path,source_path:asset.pathname,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});
        }
        console.log(JSON.stringify({shell_status:response.status,html_bytes:html.length,title:html.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1]??null,bootstrap_script_paths:scripts.map(u=>u.pathname),bootstrap_entries:scripts.filter(u=>u.pathname.endsWith('entry.cgi')).map(u=>({path:u.pathname,parameters:Object.fromEntries([...u.searchParams].filter(([k])=>['api','method','version','name','app','type'].includes(k)))})),script_paths:own.map(u=>u.pathname),assets}));return;
    }
    if(process.argv.includes('--sticker-catalog-schema')) {
        const data=await api('SYNO.Chat.Sticker','list',1);
        console.log(JSON.stringify({schema:shape(data),categories:(data.categories??[]).map(c=>({
            category_id:c.category_id,type:c.type,is_emoji:c.is_emoji,is_emojione:c.is_emojione,
            count:(c.stickers??[]).length,firstStickerSchema:shape(c.stickers?.[0]??null)}))}));return;
    }
    if(process.argv.includes('--link-display-contract')) {
        const settings=await api('SYNO.Chat.Admin.Setting','get',5);
        console.log(JSON.stringify({hide_post_url_preview:settings.hide_post_url_preview,
            hide_flag_type:typeof settings.hide_post_url_preview}));return;
    }
    if(process.argv.includes('--locale-settings-schema')) {
        const settings=await api('SYNO.Core.UserSettings','get',1),zones=await api('SYNO.Core.Region.NTP','listzone',1),defaults=await api('SYNO.Core.Desktop.Initdata','get_user_service',1,{launch_app:'SYNO.SDS.Chat.Application'});
        const own=(await api('SYNO.Chat.User','list',2)).users.find(u=>u.username?.toLowerCase()===session.username.toLowerCase());
        const discovery=await api('SYNO.API.Info','query',1,{query:'SYNO.Core.UserSettings,SYNO.Core.Region.NTP'});
        console.log(JSON.stringify({personal_sha256:crypto.createHash('sha256').update(JSON.stringify(Object.fromEntries(Object.entries(settings.Personal??{}).sort(([a],[b])=>a.localeCompare(b))))).digest('hex'),timezone:own?.user_props?.timezone,timezoneUTC:own?.user_props?.timezoneUTC,defaults:Object.fromEntries(['date_format','time_format','lang'].map(k=>[k,defaults.Session?.[k]])),personal_keys:Object.keys(settings.Personal??{}),values:Object.fromEntries(['lang','dateFormat','timeFormat'].filter(k=>k in (settings.Personal??{})).map(k=>[k,settings.Personal[k]])),zonedata_schema:shape(zones),zone_first:zones.zonedata?.[0],zone_london:zones.zonedata?.filter(z=>/London/i.test(z.display??'')),api_info:discovery}));return;
    }
    if(process.argv.includes('--application-launcher-schema')) {
        const data=await api('SYNO.Personal.Application.Info','get',1,{is_app_portal:true,app_name:'SYNO.SDS.Chat.Application'});
        console.log(JSON.stringify({schema:shape(data),applications:(data.applications??[]).map(a=>{let url;try{url=new URL(a.launch_url,base);}catch{}return {name:a.name,appname:a.appname,type:a.type,launch_path:url?.pathname,launch_scheme:url?.protocol,same_origin:url?.origin===base.origin,query_keys:url?[...url.searchParams.keys()]:[],launch_app:url?.searchParams.get('launchApp')};})}));return;
    }
    if(process.argv.includes('--restore-drive-synthetic-access')) {
        const baseline=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-20/drive-live-before.json','utf8'));
        const fixture=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-18/nas-synthetic-fixture.json','utf8'));
        const users=(await api('SYNO.Chat.User','list',2)).users,own=users.find(u=>u.username===session.username),peer=users.find(u=>u.user_id===6&&u.nickname==='Peter'&&u.type==='human'&&u.human_type==='dsm');
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids.slice().sort((a,b)=>a-b);
        if(own?.user_id!==10||!peer||!Number.isSafeInteger(Number(peer.dsm_uid))||Number(peer.dsm_uid)<=0||JSON.stringify(members)!=='[6,10]'||baseline.sharing_count!==0) throw new Error('Bounded synthetic cleanup identity not confirmed.');
        const page=await api('SYNO.SynologyDrive.Files','list',2,{path:'/mydrive',offset:0,limit:100,filter:{include_transient:true}}),matches=page.items?.filter(f=>f.name===fixture.filename&&f.size===fixture.bytes&&f.owner?.name===session.username);
        if(matches?.length!==1) throw new Error('Synthetic file unresolved.');const id=matches[0].file_id,path='id:'+id;
        if(crypto.createHash('sha256').update(id).digest('hex')!==baseline.file_id_sha256) throw new Error('Synthetic file identity changed.');
        const data=await api('SYNO.SynologyDrive.Files','get',2,{path});
        if(data.shared_with.length===0) {console.log(JSON.stringify({restored:true,write:false}));return;}
        const entry=data.shared_with[0];
        if(data.shared_with.length!==1||entry.type!=='user'||entry.name!==peer.username||entry.role!=='viewer'||entry.inherited===true) throw new Error('Unexpected sharing entries; refuse cleanup.');
        const marker='reference/synology-chat/evidence/2026-10-20/drive-live-access-restore.json';if(fs.existsSync(marker)) throw new Error('Cleanup already dispatched; inspect current state before repeating.');
        fs.writeFileSync(marker,JSON.stringify({phase:'before removal of synthetic peer-only viewer permission',channel_id:93,filename:fixture.filename,time:new Date().toISOString()},null,2)+'\n',{flag:'wx'});
        await api('SYNO.SynologyDrive.Sharing','update',1,{path,permissions:[{action:'delete',member:{type:'user',uid:Number(peer.dsm_uid)}}]});
        const receipt=await api('SYNO.SynologyDrive.Files','get',2,{path});const hash=crypto.createHash('sha256').update(JSON.stringify(receipt.shared_with)).digest('hex');
        if(hash!==baseline.sharing_sha256||receipt.size!==fixture.bytes||receipt.name!==fixture.filename) throw new Error('Synthetic access restoration not confirmed.');
        fs.writeFileSync(marker,JSON.stringify({phase:'original empty permissions restored',filename:fixture.filename,sharing_sha256:hash,time:new Date().toISOString()},null,2)+'\n');console.log(JSON.stringify({restored:true,sharing_sha256:hash}));return;
    }
    if(process.argv.includes('--drive-search-label-schema')) {
        const fixture=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-18/nas-synthetic-fixture.json','utf8'));
        const labels=await api('SYNO.SynologyDrive.Labels','list',1);
        const search=await api('SYNO.SynologyDrive.Files','search',2,{keyword:fixture.filename,location:'any',offset:0,limit:100,content_snippet:false,sort_by:'score',sort_direction:'asc'});
        console.log(JSON.stringify({labels_schema:shape(labels),search_schema:shape(search),synthetic_matches:search.items?.filter(f=>f.name===fixture.filename).length??0,labels_count:labels.items?.length??0}));return;
    }
    if(process.argv.includes('--drive-synthetic-state')) {
        const fixture=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-18/nas-synthetic-fixture.json','utf8'));
        const page=await api('SYNO.SynologyDrive.Files','list',2,{path:'/mydrive',offset:0,limit:100,sort_by:'name',sort_direction:'asc',filter:{include_transient:true}});
        const candidates=page.items?.filter(f=>f.name===fixture.filename&&f.size===fixture.bytes&&f.owner?.name===session.username);
        if(candidates?.length!==1) throw new Error('Own synthetic Drive file unresolved.');
        const data=await api('SYNO.SynologyDrive.Files','get',2,{path:'id:'+candidates[0].file_id});
        const link=new URL(data.permanent_link,base);
        const record={filename:fixture.filename,bytes:data.size,file_id_sha256:crypto.createHash('sha256').update(data.file_id).digest('hex'),sharing_sha256:crypto.createHash('sha256').update(JSON.stringify(data.shared_with)).digest('hex'),sharing_count:data.shared_with.length,sharing_roles:data.shared_with.map(e=>({type:e.type,role:e.role,inherited:e.inherited??null,has_uid:typeof e.uid==='number'})),link:{protocol:link.protocol,same_origin:link.origin===base.origin,pathname_shape:link.pathname.replace(/[a-zA-Z0-9_-]{10,}/g,'[opaque]'),query_names:[...link.searchParams.keys()]},source_sha256:fixture.sha256,time:new Date().toISOString()};
        console.log(JSON.stringify(record));return;
    }
    if(process.argv.includes('--drive-synthetic-info')) {
        const fixture=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-18/nas-synthetic-fixture.json','utf8'));
        const page=await api('SYNO.SynologyDrive.Files','list',2,{path:'/mydrive',offset:0,limit:100,sort_by:'name',sort_direction:'asc',filter:{include_transient:true}});
        const item=page.items?.find(f=>f.name===fixture.filename);
        if(!item||item.size!==fixture.bytes||item.owner?.name!==session.username) throw new Error('Own synthetic Drive file unresolved.');
        const data=await api('SYNO.SynologyDrive.Files','get',2,{path:'id:'+item.file_id});
        console.log(JSON.stringify({schema:shape(data),file_id_type:typeof data.file_id,type:data.type,permanent_link_present:!!data.permanent_link,capabilities:data.capabilities,shared_with_count:data.shared_with?.length,owner_matches: data.owner?.name===session.username}));return;
    }
    if(process.argv.includes('--drive-files-schema')) {
        const pages=[];
        for(const [method,name,version,params] of [['list','SYNO.SynologyDrive.Files',2,{path:'/mydrive',offset:0,limit:100,sort_by:'name',sort_direction:'asc',filter:{include_transient:true}}],['list','SYNO.SynologyDrive.TeamFolders',1,{offset:0,limit:100}],['shared_with_me','SYNO.SynologyDrive.Files',2,{offset:0,limit:100}],['list_starred','SYNO.SynologyDrive.Files',2,{offset:0,limit:100}],['recent','SYNO.SynologyDrive.Files',2,{offset:0,limit:100}]]) {
            try {const data=await api(name,method,version,params);pages.push({method,api:name,schema:shape(data),count:data.items?.length,sample_nonprivate:data.items?.[0]?Object.fromEntries(Object.entries(data.items[0]).filter(([k])=>['type','capabilities','size','removed','encrypted','disable_download'].includes(k))):null});}catch(e){pages.push({method,code:/API rejected request: (\d+)/.exec(e.message)?.[1]??'local'});}
        }
        console.log(JSON.stringify(pages));return;
    }
    if(process.argv.includes('--calendar-synthetic-roundtrip')) {
        const marker='reference/synology-chat/evidence/2026-10-20/calendar-synthetic-state.json';
        if(fs.existsSync(marker)) throw new Error('Calendar mutation already attempted; inspect its state before another action.');
        const list=await api('SYNO.Cal.Cal','list',5,{cal_type:'event'}),own=list.list?.filter(c=>c.original_ug_name===session.username&&c.cal_privilege==='RW'&&c.cal_public_sharing_id==='');
        if(own?.length!==1) throw new Error('Unique own nonpublic calendar unavailable.');
        const cal=await api('SYNO.Cal.Cal','get',5,{cal_id:own[0].cal_id}),sharing=(await api('SYNO.Cal.Sharing','get',1,{cal_id:cal.cal_id}))[cal.cal_id];
        if(cal.original_ug_name!==session.username||cal.cal_privilege!=='RW'||cal.cal_public_sharing_id!==''||Object.keys(sharing??{}).sort().join(',')!=='DSM_GROUP,DSM_USER'||!Object.values(sharing).every(v=>Array.isArray(v)&&v.length===0)) throw new Error('Calendar privacy not established.');
        const state={title:'Native Calendar API synthetic roundtrip 20261020',started_at:new Date().toISOString(),phase:'create-dispatch'};
        fs.writeFileSync(marker,JSON.stringify(state,null,2));
        let event;
        try {
            event=await api('SYNO.Cal.Event','create',5,{cal_id:cal.cal_id,original_cal_id:cal.original_cal_id,summary:state.title,is_all_day:false,tz_id:'Europe/London',dtstart:1894701600,dtend:1894705200,is_repeat_evt:false,color:'',description:'',participant:[],notify_setting:[],from_syno_app_url:{app:'SYNO.SDS.Chat.Application'}});
            state.event_id=event.evt_id;state.phase='created';fs.writeFileSync(marker,JSON.stringify(state,null,2));
            const canonical=await api('SYNO.Cal.Event','get',5,{evt_id:event.evt_id});
            if(canonical.summary!==state.title||canonical.original_cal_id!==cal.original_cal_id||canonical.dtstart!==1894701600||canonical.dtend!==1894705200||canonical.participant?.length!==0) throw new Error('Calendar readback mismatched.');
            state.create_schema=shape(event);state.get_schema=shape(canonical);state.phase='verified';fs.writeFileSync(marker,JSON.stringify(state,null,2));
        } finally {
            if(event?.evt_id) {
                const target=await api('SYNO.Cal.Event','get',5,{evt_id:event.evt_id});
                if(target.summary!==state.title||target.original_cal_id!==cal.original_cal_id||target.participant?.length!==0) throw new Error('Cleanup target no longer matches synthetic event.');
                state.phase='delete-dispatch';fs.writeFileSync(marker,JSON.stringify(state,null,2));
                await api('SYNO.Cal.Event','delete',5,{evt_id:event.evt_id});
                try {await api('SYNO.Cal.Event','get',5,{evt_id:event.evt_id});throw new Error('Deleted event remains readable.');} catch(e) {if(!/API rejected request: \d+/.test(e.message)) throw e;state.deleted_get_error=/API rejected request: (\d+)/.exec(e.message)?.[1];}
                state.phase='deleted-and-verified';state.finished_at=new Date().toISOString();fs.writeFileSync(marker,JSON.stringify(state,null,2));
            }
        }
        console.log(JSON.stringify({phase:state.phase,create_schema:state.create_schema,get_schema:state.get_schema,deleted_get_error:state.deleted_get_error}));return;
    }
    if(process.argv.includes('--calendar-ui-inspect')||process.argv.includes('--calendar-ui-cleanup')) {
        const marker='reference/synology-chat/evidence/2026-10-20/calendar-ui-state.json',state=JSON.parse(fs.readFileSync(marker,'utf8'));
        const cals=await api('SYNO.Cal.Cal','list',5,{cal_type:'event'}),own=cals.list?.filter(c=>c.original_ug_name===session.username&&c.cal_privilege==='RW'&&c.cal_public_sharing_id==='');
        if(own?.length!==1) throw new Error('Unique own calendar unavailable.');
        const page=await api('SYNO.Cal.Event','list',5,{cal_id_list:[own[0].cal_id],start:1894665600,end:1894838400});
        const arrays=Object.values(page).filter(Array.isArray),events=arrays.flat().filter(e=>e?.summary===state.event_title&&e?.original_cal_id===own[0].original_cal_id);
        const posts=await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:30,next_count:0});
        const messages=posts.posts?.filter(p=>p.message===state.message)??[];
        if(messages.length===1) state.post_id=messages[0].post_id;
        state.event_list_schema=shape(page);state.matching_events=events.length;state.matching_messages=messages.length;
        if(events.length===1) {
            const event=await api('SYNO.Cal.Event','get',5,{evt_id:events[0].evt_id});
            if(event.summary!==state.event_title||event.original_cal_id!==own[0].original_cal_id||event.participant?.length!==0||event.notify_setting?.length!==0||event.dtstart!==1894701600||event.dtend!==1894705200) throw new Error('UI event differs from bounded fixture.');
            state.event_id=event.evt_id;state.canonical_schema=shape(event);state.canonical_verified=true;
            if(process.argv.includes('--calendar-ui-cleanup')) {
                if(state.phase==='deleted-and-verified') throw new Error('UI cleanup already performed.');
                state.phase='delete-dispatch';fs.writeFileSync(marker,JSON.stringify(state,null,2));
                await api('SYNO.Cal.Event','delete',5,{evt_id:event.evt_id});
                try {await api('SYNO.Cal.Event','get',5,{evt_id:event.evt_id});throw new Error('UI event remains readable.');} catch(e) {if(!/API rejected request: \d+/.test(e.message)) throw e;state.deleted_get_error=/API rejected request: (\d+)/.exec(e.message)?.[1];}
                state.phase='deleted-and-verified';
            }
        } else if(process.argv.includes('--calendar-ui-cleanup')) {throw new Error('Unique UI synthetic event not found.');}
        fs.writeFileSync(marker,JSON.stringify(state,null,2));
        console.log(JSON.stringify({phase:state.phase,list_schema:state.event_list_schema,matching_events:events.length,matching_messages:messages.length,canonical_verified:state.canonical_verified??false,deleted_get_error:state.deleted_get_error??null}));return;
    }
    if(process.argv.includes('--quick-switch-readiness')) {
        const channels=(await api('SYNO.Chat.Channel','list',5,{is_joined:true})).channels??[];
        const peter=channels.find(c=>c.channel_id===93),acl=await api('SYNO.Chat.Misc','acl',1);
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids?.slice().sort((a,b)=>a-b);
        if(peter?.type!=='anonymous'||peter.encrypted||JSON.stringify(members)!=='[6,10]') throw new Error('Authorized Peter conversation changed.');
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:10,next_count:0})).posts??[];
        console.log(JSON.stringify({channel_count:channels.length,order_time_number_count:channels.filter(c=>typeof c.channel_order_time==='number').length,recent_count:channels.filter(c=>c.channel_order_time>0).length,can_start:acl.acls?.find(a=>a.acl_name==='channel_anonymous')?.allow===true,peter:{channel_id:93,member_ids:members,order_time_positive:peter.channel_order_time>0,latest_post_id:Math.max(...posts.map(p=>p.post_id)),unread:peter.unread}}));return;
    }
    if(process.argv.includes('--chatbot-catalogue-schema')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[];
        const channels=(await api('SYNO.Chat.Channel','list',5,{is_joined:true})).channels??[];
        const blocked=await api('SYNO.Chat.Channel.Chatbot','list_blocked',1);
        const membership=[];for(const c of channels.filter(c=>c.type==='chatbot'&&[16,12].includes(c.creator_id))) { const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:c.channel_id})).user_ids; if(JSON.stringify(members)!=='[10]') throw new Error('Bot channel is not self-only.'); const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:c.channel_id,prev_count:30,next_count:0})).posts??[]; membership.push({channel_id:c.channel_id,user_ids:members,post_ids:posts.map(p=>p.post_id)}); }
        console.log(JSON.stringify({membership,blocked_schema:shape(blocked),blocked_ids:blocked.blocked_user_ids,chatbots:users.filter(u=>u.type==='bot'&&u.bot_type==='chatbot').map(u=>({id:u.user_id,nickname:u.nickname,disabled:u.is_disabled,delete_at:u.delete_at,props_schema:shape(u.chatbot_props),hidden:u.chatbot_props?.hide_from_user,purpose:u.chatbot_props?.purpose})),channels:channels.filter(c=>c.type==='chatbot').map(c=>({id:c.channel_id,creator_id:c.creator_id,encrypted:c.encrypted,is_joined:c.is_joined,hide_global_at:c.hide_global_at,unread:c.unread}))}));return;
    }
    if(process.argv.includes('--webhook-post-audit')) {
        const page=await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:20,next_count:0});
        console.log(JSON.stringify({post_ids:page.posts?.map(p=>p.post_id),new_posts:page.posts?.filter(p=>p.post_id>399431958770).map(p=>({id:p.post_id,creator_id:p.creator_id,type:p.type,event:p.system_props?.event??null})),active_webhooks:((await api('SYNO.Chat.User','list',2)).users??[]).filter(u=>['incoming','outgoing'].includes(u.bot_type)&&!u.deleted&&!(u.delete_at>0)).length}));return;
    }
    if(process.argv.includes('--webhook-observe-fixtures')) {
        const state=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-20/webhook-live-state.json','utf8'));
        const users=(await api('SYNO.Chat.User','list',2)).users??[];
        const fixtures=[];
        for(const f of state.fixtures) {
            const user=users.find(u=>u.user_id===f.id);
            if(user?.creator_id!==10||user.bot_type!==f.type.toLowerCase()||user.nickname!==f.name||!user.is_disabled) throw new Error('Fixture observation guard failed.');
            const d=await api('SYNO.Chat.Webhook.'+f.type,'get',1,{user_id:f.id});
            fixtures.push({id:f.id,type:f.type,disabled:d.is_disabled,channel_id:d.channel_id,name_restored:d.nickname===f.name,native_trigger_verified:f.type==='Incoming'||d.trigger_word==='__native_webhook_ui_test__',callback_matches:f.type==='Incoming'||d.url==='https://example.invalid/native-chat-test'});
        }
        const posts=await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:1,next_count:0});
        const active=users.filter(u=>u.type==='bot'&&['incoming','outgoing'].includes(u.bot_type)&&!u.deleted&&!(u.delete_at>0));
        console.log(JSON.stringify({fixtures,active_ids:active.map(u=>u.user_id),latest_peter_post:posts.posts?.at(-1)?.post_id??null}));return;
    }
    if(process.argv.includes('--webhook-create-fixtures') || process.argv.includes('--webhook-cleanup-fixtures')) {
        const path='reference/synology-chat/evidence/2026-10-20/webhook-live-state.json';
        const hash=x=>crypto.createHash('sha256').update(JSON.stringify(x)).digest('hex');
        const users=(await api('SYNO.Chat.User','list',2)).users??[];
        if(!users.some(u=>u.user_id===10&&u.username===session.username&&u.type==='human')) throw new Error('Own account mismatch.');
        const acl=await api('SYNO.Chat.Misc','acl',1);
        if(!['webhook_read','webhook_create'].every(key=>acl.acls?.some(a=>a.acl_name===key&&a.allow===true))) throw new Error('Webhook permissions unavailable.');
        const inventory=users.filter(u=>u.type==='bot'&&['incoming','outgoing'].includes(u.bot_type));
        const save=state=>fs.writeFileSync(path,JSON.stringify(state,null,2)+'\n',{mode:0o600});
        if(process.argv.includes('--webhook-create-fixtures')) {
            const state={phase:'started',baseline_ids:inventory.map(u=>u.user_id),baseline_hash:hash(inventory),fixtures:[]};
            if(fs.existsSync(path)) { const prior=JSON.parse(fs.readFileSync(path,'utf8')); if(prior.phase!=='started'||prior.fixtures.length!==0) throw new Error('One-shot creation already spent.'); } else fs.writeFileSync(path,JSON.stringify(state,null,2)+'\n',{flag:'wx',mode:0o600});
            const channel=(await api('SYNO.Chat.Channel','list',5,{is_joined:true})).channels?.find(c=>c.channel_id===93);
            const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids??[];
            if(channel.channel_id!==93||channel.type!=='anonymous'||channel.encrypted||members.length!==2||!members.includes(10)||!members.includes(6)) throw new Error('Peter context mismatch.');
            for(const type of ['Incoming','Outgoing']) {
                state.phase='creating-'+type;save(state);
                const created=await api('SYNO.Chat.Webhook.'+type,'create',1);
                if(!Number.isSafeInteger(created.user_id)||created.user_id<=1||state.baseline_ids.includes(created.user_id)) throw new Error('Unconfirmed new integration.');
                const fixture={id:created.user_id,type,phase:'created'};state.fixtures.push(fixture);save(state);
                let current=(await api('SYNO.Chat.User','list',2)).users?.find(u=>u.user_id===fixture.id);
                if(current?.creator_id!==10||current.bot_type!==type.toLowerCase()||current.app_id) throw new Error('New integration ownership mismatch.');
                await api('SYNO.Chat.Bot','disable',1,{user_id:fixture.id});fixture.phase='disabled';save(state);
                let detail=await api('SYNO.Chat.Webhook.'+type,'get',1,{user_id:fixture.id});
                fixture.schema=shape(detail);fixture.initial_disabled=detail.is_disabled===true;save(state);
                if(detail.user_id!==fixture.id||detail.is_disabled!==true) throw new Error('New integration not disabled.');
                fixture.name='Native-API-webhook-test-'+type;
                await api('SYNO.Chat.Bot','set',1,{user_id:fixture.id,nickname:fixture.name});
                await api('SYNO.Chat.Webhook.'+type,'set',1,{user_id:fixture.id,channel_id:93,...(type==='Outgoing'?{trigger_word:'__native_webhook_test__',url:'https://example.invalid/native-chat-test'}:{})});
                const before=detail.token;
                const rotated=await api('SYNO.Chat.Bot','regen_token',1,{user_id:fixture.id});
                detail=await api('SYNO.Chat.Webhook.'+type,'get',1,{user_id:fixture.id});
                fixture.configured=detail.channel_id===93&&detail.nickname===fixture.name&&detail.is_disabled===true;
                fixture.token_replaced=typeof rotated.token==='string'&&rotated.token!==before&&rotated.token===detail.token;
                fixture.callback_matches=type==='Incoming'||detail.url==='https://example.invalid/native-chat-test';
                fixture.phase='configured-disabled';save(state);
                if(!fixture.configured||!fixture.token_replaced||!fixture.callback_matches) throw new Error('Fixture readback mismatch.');
            }
            state.phase='ready-for-native-read';save(state);console.log(JSON.stringify(state));return;
        }
        const state=JSON.parse(fs.readFileSync(path,'utf8'));
        for(const fixture of state.fixtures) {
            let current=(await api('SYNO.Chat.User','list',2)).users?.find(u=>u.user_id===fixture.id);
            if(!current||current.deleted||current.delete_at>0) {fixture.phase='removed';save(state);continue;}
            if(state.baseline_ids.includes(fixture.id)||current.creator_id!==10||current.bot_type!==fixture.type.toLowerCase()||current.nickname!==fixture.name||!current.is_disabled||current.app_id) throw new Error('Fixture cleanup guard failed.');
            fixture.phase='removing';save(state);
            await api('SYNO.Chat.Bot','delete',1,{user_id:fixture.id,real_delete:false});
            current=(await api('SYNO.Chat.User','list',2)).users?.find(u=>u.user_id===fixture.id);
            if(current&&!current.deleted&&!(current.delete_at>0)) throw new Error('Removal unconfirmed.');
            fixture.phase='removed';fixture.canonical_absent_or_deleted=true;save(state);
        }
        const after=(await api('SYNO.Chat.User','list',2)).users?.filter(u=>state.baseline_ids.includes(u.user_id))??[];
        state.existing_integrations_unchanged=hash(after)===state.baseline_hash;
        state.phase='removed';save(state);console.log(JSON.stringify(state));return;
    }
    if(process.argv.includes('--webhook-list-schema')) {
        const result=[];
        for(const type of ['Incoming','Outgoing']) {try {const data=await api('SYNO.Chat.Webhook.'+type,'list',1);result.push({type,schema:shape(data),array_counts:Object.fromEntries(Object.entries(data).filter(([,v])=>Array.isArray(v)).map(([k,v])=>[k,v.length]))});}catch(e){result.push({type,code:/API rejected request: (\d+)/.exec(e.message)?.[1]??'local'});}}
        const users=(await api('SYNO.Chat.User','list',2)).users??[];
        console.log(JSON.stringify({lists:result,visible_integrations:users.filter(u=>u.type==='bot'&&['incoming','outgoing'].includes(u.bot_type)).map(u=>({schema:shape(u),type:u.bot_type,owned:u.creator_id===10}))}));return;
    }
    if(process.argv.includes('--own-profile-hash')) {
        const users=(await api('SYNO.Chat.User','list',2)).users??[],me=users.find(u=>u.username===session.username&&u.type==='human');
        if(me?.user_id!==10) throw new Error('Expected own Peter account unavailable.');
        console.log(JSON.stringify({user_id:me.user_id,nickname_present:typeof me.nickname==='string',description_present:typeof me.user_props?.description==='string',nickname_sha256:crypto.createHash('sha256').update(me.nickname??'').digest('hex'),description_sha256:crypto.createHash('sha256').update(me.user_props?.description??'').digest('hex')}));return;
    }
    if(process.argv.includes('--slash-live-observe')) {
        const marker='reference/synology-chat/evidence/2026-10-20/slash-live-state.json',state=JSON.parse(fs.readFileSync(marker,'utf8'));
        const channel=(await api('SYNO.Chat.Channel','list',5,{is_joined:true})).channels?.find(c=>c.channel_id===93),members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids?.slice().sort((a,b)=>a-b);
        if(channel?.type!=='anonymous'||channel.encrypted||JSON.stringify(members)!=='[6,10]') throw new Error('Bounded Peter source changed.');
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:30,next_count:0})).posts??[];
        const added=posts.filter(p=>p.post_id>state.baseline_latest_post_id);
        state.new_posts=added.map(p=>({post_id:p.post_id,creator_id:p.creator_id,type:p.type,message_length:p.message?.length??0,message_sha256:crypto.createHash('sha256').update(p.message??'').digest('hex'),url_sha256s:(p.message?.match(/https?:\/\/[^\s<>]+/g)??[]).map(u=>crypto.createHash('sha256').update(u.replace(/[.,!?]+$/,'')).digest('hex')),attachment_schema:shape(p.props?.attachments),url_preview_count:p.url_props?.length??0,contains_markdown_url:/<https?:/.test(p.message??''),contains_html_link:/<a\s/i.test(p.message??'')}));
        state.latest_post_id=posts.at(-1)?.post_id??null;state.observed_at=new Date().toISOString();
        fs.writeFileSync(marker,JSON.stringify(state,null,2));console.log(JSON.stringify({new_posts:state.new_posts,latest_post_id:state.latest_post_id}));return;
    }
    if(process.argv.includes('--slash-catalog-schema')) {
        const data=await api('SYNO.Chat.User','list',2),commands=data.users?.filter(u=>u.type==='bot'&&u.bot_type==='slash'&&!u.is_disabled&&!u.delete_at)??[];
        console.log(JSON.stringify({count:commands.length,commands:commands.map(u=>({user_id:u.user_id,props_schema:shape(u.slash_props),cmd:u.slash_props?.cmd,description:u.slash_props?.description,usage:u.slash_props?.usage})).map(v=>({...v,description:typeof v.description==='string'&&/^[a-z_]+:[a-z_]+$/.test(v.description)?v.description:{length:v.description?.length??0},usage:typeof v.usage==='string'&&/^[a-z_]+:[a-z_]+$/.test(v.usage)?v.usage:{length:v.usage?.length??0}}))}));return;
    }
    if(process.argv.includes('--bot-attachments-schema')) {
        const data=await api('SYNO.Chat.Channel','list',5,{is_joined:true}),bots=data.channels?.filter(c=>c.type==='chatbot')??[],result=[];
        for(const channel of bots.slice(0,4)) {
            const page=await api('SYNO.Chat.Post','list',5,{channel_id:channel.channel_id,prev_count:30,next_count:0}),posts=page.posts??[],cards=posts.flatMap(p=>Array.isArray(p.props?.attachments)?p.props.attachments:[]);
            result.push({channel_type:channel.type,posts_read:posts.length,posts_with_attachments:posts.filter(p=>Array.isArray(p.props?.attachments)&&p.props.attachments.length>0).length,attachment_count:cards.length,schemas:cards.slice(0,3).map(shape)});
        }
        console.log(JSON.stringify({bot_channel_count:bots.length,channels:result}));return;
    }
    if(process.argv.includes('--promotion-readiness')) {
        const data=await api('SYNO.Chat.Channel','list',5,{is_joined:true}),channel=data.channels?.find(c=>c.channel_id===93);
        const acl=await api('SYNO.Chat.Misc','acl',1),members=await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93});
        const posts=await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:1,next_count:0});
        const ids=members.user_ids?.slice().sort((a,b)=>a-b);
        if(channel?.type!=='anonymous'||channel.encrypted||JSON.stringify(ids)!=='[6,10]') throw new Error('Bounded Peter source no longer matches.');
        console.log(JSON.stringify({channel_id:93,type:channel.type,encrypted:channel.encrypted,is_joined:channel.is_joined,member_ids:ids,latest_post_id:posts.posts?.at(-1)?.post_id??null,channel_name:channel.name,create_allowed:acl.acls?.find(a=>a.acl_name==='channel_create')?.allow===true,invite_allowed:acl.acls?.find(a=>a.acl_name==='channel_invite')?.allow===true}));return;
    }
    if(process.argv.includes('--calendar-sharing-schema')) {
        const list=await api('SYNO.Cal.Cal','list',5,{cal_type:'event'}),own=list.list?.filter(c=>c.original_ug_name===session.username&&c.cal_privilege==='RW');
        if(own?.length!==1) throw new Error('Unique own calendar unavailable.');
        const data=await api('SYNO.Cal.Sharing','get',1,{cal_id:own[0].cal_id});
        const sharing=data[own[0].cal_id];
        console.log(JSON.stringify({schema:shape(sharing),is_array:Array.isArray(sharing),count:Array.isArray(sharing)?sharing.length:null,entries:Array.isArray(sharing)?sharing.map(e=>({keys:Object.keys(e),privilege:e.privilege,type:e.type,owner_name_matches:e.name===session.username})):null}));return;
    }
    if(process.argv.includes('--calendar-own-schema')) {
        const list=await api('SYNO.Cal.Cal','list',5,{cal_type:'event'}),own=list.list?.filter(c=>c.original_ug_name===session.username&&c.cal_privilege==='RW');
        if(own?.length!==1) throw new Error('Unique own calendar unavailable.');
        const data=await api('SYNO.Cal.Cal','get',5,{cal_id:own[0].cal_id}),settings=await api('SYNO.Cal.Setting','get',5);
        console.log(JSON.stringify({calendar_schema:shape(data),settings_schema:shape(settings),sharing_schema:shape(data.cal_share_setting),public:!!data.cal_public_sharing_id,owner_matches:data.original_ug_name===session.username}));return;
    }
    if(process.argv.includes('--calendar-list-schema')) {
        const data=await api('SYNO.Cal.Cal','list',5,{cal_type:'event'});
        console.log(JSON.stringify({schema:shape(data),count:data.list?.length??null,metadata:(data.list??[]).map(c=>({privilege:c.cal_privilege,type:c.cal_type,hidden:c.is_hidden_in_list,sharing_type:typeof c.cal_share_setting,sharing_schema:shape(c.cal_share_setting),public:!!c.cal_public_sharing_id,owner_name_matches:c.original_ug_name===session.username}))}));return;
    }
    if(process.argv.includes('--calendar-popup-contract')) {
        const data=await api('SYNO.Core.Desktop.Initdata','get',1,{action:'jsconfig',launch_app:'SYNO.SDS.Chat.Application'}),config=data.JSConfig??{};
        const entries=Object.entries(config).filter(([,v])=>Object.keys(v??{}).some(n=>['SYNO.Cal.Create.Popup.Container','SYNO.Cal.EventUtils','SYNO.Cal.DateUtils','SYNO.Cal.WebAPI','SYNO.Cal.CalUtils','SYNO.Cal.Controller.EventCommon','SYNO.Cal.DataController.Calendar'].includes(n)));
        const assets=[];
        for(const [path,defs] of entries) {
            const url=new URL('/'+path.replace(/^\//,''),base),response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(20000)});if(!response.ok) throw new Error('Calendar source unavailable.');const bytes=Buffer.from(await response.arrayBuffer()),text=bytes.toString('utf8');if(bytes.length>20*1024*1024||text.includes(session.sid)||text.includes(session.synotoken)) throw new Error('Refusing invalid Calendar source.');const local='reference/synology-chat/cache/server-calendar-'+path.split('/').at(-1);fs.writeFileSync(local,bytes);assets.push({path:local,source:url.pathname,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),definition:defs['SYNO.Cal.Create.Popup.Container']});
        }
        const pref=await api('SYNO.Chat.User.Preference','get',4);
        console.log(JSON.stringify({assets,calendar_enable:pref.preferences?.calendar_enable??null}));return;
    }
    if(process.argv.includes('--drive-picker-contract')) {
        const data=await api('SYNO.Core.Desktop.Initdata','get',1,{action:'jsconfig',launch_app:'SYNO.SDS.Chat.Application'});
        const config=data.JSConfig??{};
        const relevant=Object.fromEntries(Object.entries(config).filter(([,value])=>Object.keys(value??{}).some(name=>['SYNO.SDS.Drive.PackageUtils.UploadWindow','SYNO.SDS.Drive.Upload.IFrameApplication','SYNO.SDS.Drive.VuePanel'].includes(name))));
        const assets=[];
        for(const path of Object.keys(relevant)) {
            const url=new URL('/'+path.replace(/^\//,''),base);const response=await fetch(url,{redirect:'error',signal:AbortSignal.timeout(20000)});if(!response.ok) throw new Error('Drive source unavailable.');const bytes=Buffer.from(await response.arrayBuffer()),text=bytes.toString('utf8');if(bytes.length>20*1024*1024||text.includes(session.sid)||text.includes(session.synotoken)) throw new Error('Refusing invalid Drive source.');const local='reference/synology-chat/cache/server-drive-'+path.split('/').at(-1);fs.writeFileSync(local,bytes);assets.push({path:local,source:url.pathname,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});
        }
        const settings=await api('SYNO.SynologyDrive.Settings','list',1);
        const admin=await api('SYNO.Chat.Admin.Setting','get',5);
        console.log(JSON.stringify({libraries:Object.fromEntries(Object.entries(relevant).map(([p,v])=>[p,Object.keys(v).filter(name=>/Upload.IFrameApplication|PackageUtils.UploadWindow|VuePanel/.test(name))])),assets,settings_schema:shape(settings),sharing_policy:settings.sharing_permission,allow_drive_upload:admin.allow_drive_upload}));return;
    }
    if(process.argv.includes('--nas-file-picker-schema')) {
        const settings=await api('SYNO.Chat.Admin.Setting','get',5);
        const data=await api('SYNO.Core.File','list',1,{folder_path:'/',filetype:'all',offset:0,limit:200,sort_by:'name',sort_direction:'ASC',status_filter:'valid',additional:['size','time','perm','type']});
        const root=Array.isArray(data)?data.find(n=>n.spath&&n.spath!=='/home'):null;
        const children=root?await api('SYNO.Core.File','list',1,{folder_path:root.spath,filetype:'all',offset:0,limit:50,sort_by:'name',sort_direction:'ASC',additional:['size','time','perm','type']}):null;
        const candidate=children?.files?.find(f=>!f.isdir);const info=candidate?await api('SYNO.FileStation.List','getinfo',2,{path:[candidate.path],additional:['size','time','perm','type']}):null;
        console.log(JSON.stringify({allow_ds_upload:settings.allow_ds_upload,file_size_limit:settings.file_size_limit,root_schema:shape(data),children_schema:shape(children),fresh_info_schema:shape(info)}));return;
    }
    if(process.argv.includes('--prepare-native-nas-fixture')||process.argv.includes('--verify-native-nas-fixture')) {
        const marker='reference/synology-chat/evidence/2026-10-18/nas-synthetic-fixture.json';
        const info=await api('SYNO.FileStation.List','getinfo',2,{path:['/home'],additional:['real_path','owner','perm']});
        const home=info.files?.length===1?info.files[0]:null,candidate='/homes/'+session.username;
        if(!home?.isdir||home.additional?.owner?.user!==session.username||!home.additional?.real_path?.endsWith(candidate)||!home.additional?.perm?.acl?.read||!home.additional?.perm?.acl?.write||session.username.includes('/')||session.username.includes('\0')) throw new Error('Own writable home could not be established.');
        const content=Buffer.from('Synthetic Synology Chat NAS attachment test.\nNo private data.\n'),hash=crypto.createHash('sha256').update(content).digest('hex');
        let record;
        if(process.argv.includes('--prepare-native-nas-fixture')) {
            if(fs.existsSync(marker)) throw new Error('NAS fixture dispatch already recorded. Verify existing fixture; never upload again automatically.');
            record={phase:'before_upload',filename:'Native-Chat-API-synthetic-nas-'+crypto.randomUUID()+'.txt',bytes:content.length,sha256:hash,owner_sha256:crypto.createHash('sha256').update(session.username).digest('hex'),location:'authenticated account own home',authorization:'User permits own-account tests; fixed synthetic file only; destination chat Peter only.'};
            await api('SYNO.FileStation.CheckPermission','write',3,{path:candidate,filename:record.filename,overwrite:false,create_only:true});
            fs.writeFileSync(marker,JSON.stringify(record,null,2)+'\n',{flag:'wx'});
            const url=new URL('webapi/entry.cgi/SYNO.FileStation.Upload',base.href.endsWith('/')?base:new URL(base.href+'/'));url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken,api:'SYNO.FileStation.Upload',method:'upload',version:'2'});
            const body=new FormData();for(const [key,value] of Object.entries({api:'SYNO.FileStation.Upload',version:'2',method:'upload',path:candidate,create_parents:'false',overwrite:'false'})) body.append(key,value);body.append('file',new Blob([content],{type:'text/plain'}),record.filename);
            const response=await fetch(url,{method:'POST',body,redirect:'error',signal:AbortSignal.timeout(30000)}),result=await response.json();if(!response.ok||!result.success) throw new Error('Synthetic NAS upload not confirmed: '+result.error?.code);
            record.phase='upload_acknowledged';fs.writeFileSync(marker,JSON.stringify(record,null,2)+'\n');
        } else {record=JSON.parse(fs.readFileSync(marker,'utf8'));}
        if(record.owner_sha256!==crypto.createHash('sha256').update(session.username).digest('hex')||record.sha256!==hash||record.bytes!==content.length||!/^Native-Chat-API-synthetic-nas-[a-f0-9-]+\.txt$/.test(record.filename)) throw new Error('Synthetic NAS manifest mismatch.');
        const path=candidate+'/'+record.filename,metadata=await api('SYNO.FileStation.List','getinfo',2,{path:[path],additional:['size','time','perm']});
        if(metadata.files?.length!==1||metadata.files[0].path!==path||metadata.files[0].isdir||metadata.files[0].additional?.size!==content.length) throw new Error('Synthetic NAS file metadata mismatch.');
        const url=new URL('webapi/entry.cgi/SYNO.FileStation.Download',base.href.endsWith('/')?base:new URL(base.href+'/'));url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{method:'POST',body:new URLSearchParams({api:'SYNO.FileStation.Download',method:'download',version:'2',path:JSON.stringify([path]),mode:JSON.stringify('open')}),redirect:'error',signal:AbortSignal.timeout(20000)});const bytes=Buffer.from(await response.arrayBuffer());
        if(!response.ok||bytes.length!==content.length||crypto.createHash('sha256').update(bytes).digest('hex')!==hash) throw new Error('Synthetic NAS file bytes mismatch.');
        record.phase='own_home_fixture_bytes_verified';fs.writeFileSync(marker,JSON.stringify(record,null,2)+'\n');console.log(JSON.stringify({filename:record.filename,bytes:bytes.length,sha256:hash,own_home_confirmed:true,phase:record.phase}));return;
    }
    if(process.argv.includes('--nas-home-schema')) {
        const info=await api('SYNO.FileStation.List','getinfo',2,{path:['/home'],additional:['real_path','owner','perm','size','time','type']});
        const home=info.files?.length===1?info.files[0]:null;
        const roots=await api('SYNO.Core.File','list',1,{folder_path:'/',status_filter:'valid',superuser:false});
        const candidate='/homes/'+session.username;
        console.log(JSON.stringify({schema:shape(info),home_is_directory:home?.isdir===true,owner_matches_account:home?.additional?.owner?.user===session.username,home_readable:home?.additional?.perm?.acl?.read===true,home_writable:home?.additional?.perm?.acl?.write===true,canonical_home_suffix_matches:home?.additional?.real_path?.endsWith(candidate)===true,homes_share_available:roots.some(r=>r.spath==='/homes')}));return;
    }
    if(process.argv.includes('--paired-device-schema')) {
        const data=await api('SYNO.Personal.Notification.Device','list',2,{package:'Chat'});
        console.log(JSON.stringify({schema:shape(data),count:data.list?.length??null,versions:(data.list??[]).map(d=>({firmware_version:d.firmware_version,app_version:d.app_version})),registrations_sha256:crypto.createHash('sha256').update(JSON.stringify((data.list??[]).map(d=>Object.fromEntries(Object.entries(d).sort(([a],[b])=>a.localeCompare(b)))).sort((a,b)=>a.id-b.id))).digest('hex')}));return;
    }
    if(process.argv.includes('--notification-preferences')) {
        const data = await api('SYNO.Chat.User.Preference','get',4);
        console.log(JSON.stringify(Object.fromEntries(Object.entries(data.preferences ?? {}).filter(([key]) => key.startsWith('notification_') || key.startsWith('snooze')))));return;
    }
    if(process.argv.includes('--notification-preference-schema')) {
        console.log(JSON.stringify(shape(await api('SYNO.Chat.User.Preference','get',4))));return;
    }
    const users = (await api('SYNO.Chat.User', 'list', 2)).users;
    const me = users.find(u => u.username?.toLowerCase() === session.username.toLowerCase());
    if (!me) throw new Error('Current user unresolved.');
    if(process.argv.includes('--nas-copy-chat-proof')||process.argv.includes('--arm-nas-copy-test')) {
        const fixture=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-18/nas-synthetic-fixture.json','utf8'));
        const marker='reference/synology-chat/evidence/2026-10-18/nas-live-send-dispatch.json';
        const caption='Native NAS file-copy test — synthetic content only.';
        const channels=(await api('SYNO.Chat.Channel','list',5,{is_joined:true})).channels;
        const channel=channels.find(c=>c.channel_id===93&&c.type==='anonymous'&&!c.encrypted);
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:93})).user_ids.slice().sort((a,b)=>a-b);
        if(me.user_id!==10||!channel||users.find(u=>u.user_id===6)?.nickname!=='Peter'||JSON.stringify(members)!=='[6,10]'||fixture.owner_sha256!==crypto.createHash('sha256').update(session.username).digest('hex')) throw new Error('Authorized NAS destination/account not confirmed.');
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:100,next_count:0})).posts??[];
        const matches=posts.filter(p=>p.file_props?.name===fixture.filename);
        if(process.argv.includes('--arm-nas-copy-test')) {
            if(matches.length||fs.existsSync(marker)) throw new Error('NAS test already armed or delivered. Do not repeat automatically.');
            const record={phase:'before_native_send',channel_id:93,member_ids:members,filename:fixture.filename,caption,time:new Date().toISOString()};
            fs.writeFileSync(marker,JSON.stringify(record,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify(record));return;
        }
        if(matches.length!==1) throw new Error('Expected exactly one synthetic NAS copy.');
        const post=matches[0];
        if(post.creator_id!==10||post.type!=='file'||post.message!==caption||post.channel_id!==93) throw new Error('NAS copy receipt mismatch.');
        const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{method:'POST',redirect:'error',signal:AbortSignal.timeout(20000),body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(post.post_id)})});
        const bytes=Buffer.from(await response.arrayBuffer()),sha256=crypto.createHash('sha256').update(bytes).digest('hex');
        if(!response.ok||!response.headers.has('content-disposition')||bytes.length!==fixture.bytes||sha256!==fixture.sha256) throw new Error('Copied NAS bytes mismatch.');
        const proof={phase:'native_copy_download_verified',channel_id:93,member_ids:members,post_id:post.post_id,filename:fixture.filename,caption,bytes:bytes.length,sha256,time:new Date().toISOString()};
        fs.writeFileSync('reference/synology-chat/evidence/2026-10-18/nas-live-copy-proof.json',JSON.stringify(proof,null,2)+'\n');console.log(JSON.stringify(proof));return;
    }
    if(process.argv.includes('--manual-presence-state')) {
        const preferences=await api('SYNO.Chat.User.Preference','get',4);
        const unrelated={...me.user_props};delete unrelated.is_always_offline;
        console.log(JSON.stringify({user_id:me.user_id,away:me.user_props?.is_always_offline,unrelated_profile_sha256:crypto.createHash('sha256').update(JSON.stringify({nickname:me.nickname,avatar_version:me.avatar_version,props:unrelated})).digest('hex'),notification_preferences:Object.fromEntries(Object.entries(preferences.preferences??{}).filter(([key])=>key.startsWith("notification_")||key.startsWith("snooze")))}));return;
    }
    if(process.argv.includes('--profile-edit-schema')) {
        const settings=await api('SYNO.Chat.Admin.Setting','get',5);
        console.log(JSON.stringify({readonly_profile:settings.readonly_profile??null,own_profile_fields:shape({nickname:me.nickname,description:me.user_props?.description}),nickname_length:me.nickname?.length,description_length:me.user_props?.description?.length,avatar_version_type:typeof me.avatar_version}));return;
    }
    if(process.argv.includes('--snooze-settings-schema')) {
        const preferences=await api('SYNO.Chat.User.Preference','get',4);
        const start=Date.now(),clock=await api('SYNO.Chat.Misc','ntp',1),end=Date.now();
        console.log(JSON.stringify({preferences:Object.fromEntries(Object.entries(preferences.preferences??{}).filter(([key])=>key.startsWith('notification_')||key.startsWith('snooze'))),clock_schema:shape(clock),server_offset_ms:typeof clock.time==='number'?Math.round(clock.time-(start+end)/2):null,timezone:me.user_props?.timezoneUTC??null,is_always_offline:me.user_props?.is_always_offline??null}));return;
    }
    if(process.argv.includes('--encryption-schema')) {
      console.log(JSON.stringify({currentUserKeyPairSchema:shape(me.user_props?.key_pair??null),currentUserHasWrappedPrivateKey:!!me.user_props?.key_pair?.private_key_enc}));return;
    }
    if(process.argv.includes('--unjoined-channel-schema')) {
        const page=await api('SYNO.Chat.Channel','list',5,{is_joined:false});
        console.log(JSON.stringify({schema:shape(page),count:page.channels?.length??null,types:[...new Set((page.channels??[]).map(c=>c.type))],joined_count:(page.channels??[]).filter(c=>c.is_joined).length}));return;
    }
    if(process.argv.includes('--user-type-schema')) {
      console.log(JSON.stringify({fields:shape(me),types:[...new Set(users.map(u=>u.type))]}));return;
    }
    const channels = (await api('SYNO.Chat.Channel', 'list', 5, {is_joined:true})).channels;
    if(process.argv.includes('--archive-approved-live-fixture')) {
        const dispatchPath='reference/synology-chat/evidence/2026-10-18/archive-live-mutation-dispatch.json';
        if(fs.existsSync(dispatchPath)) throw new Error('Archive dispatch already recorded; do not repeat.');
        const channel=channels.find(c=>c.channel_id===97&&c.name==='Peter-Native-Archive-test'&&c.type==='private'&&!c.encrypted);
        if(me.user_id!==10||!channel||channels.filter(c=>c.name===channel.name).length!==1) throw new Error('Approved fixture unresolved.');
        const acl=await api('SYNO.Chat.Misc','acl',1);
        if(!acl.acls?.some(a=>a.acl_name==='channel_archive'&&a.allow)) throw new Error('Archive permission unavailable.');
        const members=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:97})).user_ids.slice().sort((a,b)=>a-b);
        if(JSON.stringify(members)!=='[10]') throw new Error('Fixture is not self-only.');
        const history=(await api('SYNO.Chat.Post','list',5,{channel_id:97,prev_count:30,next_count:0})).posts??[];
        const files=history.filter(p=>p.type!=='system');
        const originals=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-18/archive-live-original-hashes.json','utf8'));
        const names=['synthetic-archive.txt','synthetic-archive-a.png','synthetic-archive-b.png','synthetic-archive.pdf','synthetic-archive.wav','synthetic-archive.mp4'].sort();
        if(files.length!==6||originals.length!==6||JSON.stringify(files.map(p=>p.file_props?.name).sort())!==JSON.stringify(names)||JSON.stringify(originals.map(x=>x.name).sort())!==JSON.stringify(names)||files.some(p=>p.type!=='file'||p.creator_id!==10)) throw new Error('Unexpected live fixture contents.');
        if((await api('SYNO.Chat.Archive','list',1,{type:'private',channel_name:channel.name})).archives?.length!==0) throw new Error('Test archive already exists.');
        const verified=[];
        for(const post of files) {
            const original=originals.find(x=>x.name===post.file_props.name);
            const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
            url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
            const body=new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(post.post_id)});
            const response=await fetch(url,{method:'POST',body,redirect:'error',signal:AbortSignal.timeout(30000)});
            if(response.status!==200||!response.headers.has('content-disposition')) throw new Error('Fixture attachment unavailable.');
            const bytes=Buffer.from(await response.arrayBuffer()),sha256=crypto.createHash('sha256').update(bytes).digest('hex');
            if(bytes.length!==original.bytes||sha256!==original.sha256) throw new Error('Fixture bytes mismatch.');
            verified.push({post_id:post.post_id,name:original.name,bytes:bytes.length,sha256});
        }
        fs.writeFileSync('reference/synology-chat/evidence/2026-10-18/archive-live-prearchive-hashes.json',JSON.stringify(verified,null,2)+'\n');
        fs.writeFileSync(dispatchPath,JSON.stringify({channel_id:97,name:channel.name,member_ids:members,files:6,phase:'dispatching approved archive once',time:new Date().toISOString()})+'\n');
        await api('SYNO.Chat.Channel','archive',2,{channel_id:97});
        const archives=(await api('SYNO.Chat.Archive','list',1,{type:'private',channel_name:channel.name})).archives??[];
        if(archives.length!==1||archives[0].props?.channel?.channel_id!==97) throw new Error('Archive dispatched but canonical receipt not confirmed.');
        console.log(JSON.stringify({channel_id:97,archive_id:archives[0].archive_id,member_ids:members,verified_files:verified,reason:archives[0].props?.reason,post_id_start:archives[0].post_id_start,post_id_end:archives[0].post_id_end}));return;
    }
    if(process.argv.includes('--archive-live-state')) {
        const matches=channels.filter(c=>c.name==='Peter-Native-Archive-test'&&c.type==='private'&&!c.encrypted);
        if(me.user_id!==10||matches.length!==1) throw new Error('Approved archive channel unresolved.');
        const channel=matches[0];
        const ids=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:channel.channel_id})).user_ids.slice().sort((a,b)=>a-b);
        if(JSON.stringify(ids)!=='[10]') throw new Error('Archive fixture is not self-only.');
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:channel.channel_id,prev_count:30,next_count:0})).posts??[];
        const archives=(await api('SYNO.Chat.Archive','list',1,{type:'private',channel_name:channel.name})).archives??[];
        const archived_files=[];
        if(process.argv.includes('--verify-archive-fixture-files')) {
            if(archives.length!==1||archives[0].archive_id!==26||archives[0].props?.channel?.channel_id!==97) throw new Error('Approved archive receipt changed.');
            const archived=(await api('SYNO.Chat.Post','list',5,{archive_id:26,channel_id:97,prev_count:30,next_count:0})).posts??[];
            const files=archived.filter(p=>p.type!=='system'),originals=JSON.parse(fs.readFileSync('reference/synology-chat/evidence/2026-10-18/archive-live-original-hashes.json','utf8'));
            if(files.length!==6||files.some(p=>p.type!=='file'||p.creator_id!==10)) throw new Error('Unexpected archived fixture contents.');
            for(const post of files) {
                const original=originals.find(x=>x.name===post.file_props?.name);
                if(!original) throw new Error('Unexpected archived filename.');
                const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
                url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
                const body=new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(post.post_id)});
                const response=await fetch(url,{method:'POST',body,redirect:'error',signal:AbortSignal.timeout(30000)});
                if(response.status!==200||!response.headers.has('content-disposition')) throw new Error('Archived attachment unavailable.');
                const bytes=Buffer.from(await response.arrayBuffer()),sha256=crypto.createHash('sha256').update(bytes).digest('hex');
                if(bytes.length!==original.bytes||sha256!==original.sha256) throw new Error('Archived fixture bytes mismatch.');
                archived_files.push({post_id:post.post_id,name:original.name,bytes:bytes.length,sha256,original_matches:true});
            }
        }
        console.log(JSON.stringify({channel_id:channel.channel_id,name:channel.name,member_ids:ids,archived_files,live_files:posts.filter(p=>p.type==='file').map(p=>({post_id:p.post_id,name:p.file_props?.name,size:p.file_props?.size})),live_non_system_count:posts.filter(p=>p.type!=='system').length,archives:archives.map(a=>({archive_id:a.archive_id,post_id_start:a.post_id_start,post_id_end:a.post_id_end,post_start:a.post_start,post_end:a.post_end,channel_id:a.props?.channel?.channel_id,reason:a.props?.reason}))}));return;
    }
    if (process.argv.includes('--management-test-state')) {
        const matches = channels.filter(c => c.name === 'Peter-Native-API-test' && c.type === 'private' && !c.encrypted);
        if (me.user_id !== 10 || users.find(u => u.user_id === 6)?.nickname !== 'Peter' || matches.length !== 1) {
            throw new Error('Approved private test channel/account unresolved.');
        }
        const channel = matches[0];
        const ids = (await api('SYNO.Chat.Channel.Member', 'get', 1, {channel_id: channel.channel_id})).user_ids;
        if (!ids.includes(me.user_id) || ids.some(id => ![6, 10].includes(id))) throw new Error('Unexpected test-channel membership.');
        const posts = (await api('SYNO.Chat.Post', 'list', 5, {channel_id: channel.channel_id, prev_count: 30, next_count: 0})).posts ?? [];
        if (!channels.some(c => c.channel_id === 93 && c.type === 'anonymous')) throw new Error('Original Peter DM unavailable.');
        const originalIDs = (await api('SYNO.Chat.Channel.Member', 'get', 1, {channel_id: 93})).user_ids.slice().sort((a,b)=>a-b);
        if (JSON.stringify(originalIDs) !== '[6,10]') throw new Error('Original Peter DM membership changed.');
        console.log(JSON.stringify({channel_id: channel.channel_id, type: channel.type, encrypted: channel.encrypted,
            member_ids: ids.slice().sort((a,b)=>a-b), non_system_posts: posts.filter(p=>p.type!=='system').length,
            original_peter_dm_members: originalIDs}));
        return;
    }
    if(process.argv.includes('--find-paged-thread')) {
        let best=null;
        for(const c of channels.filter(c=>!c.encrypted)) {
            const data=await api('SYNO.Chat.Post','list',5,{channel_id:c.channel_id,prev_count:30,next_count:0});
            for(const p of data.posts??[]) if(p.comment_count>=30&&(!best||p.comment_count>best.comment_count)) best={channel_id:c.channel_id,post_id:p.post_id,comment_count:p.comment_count};
        }
        console.log(JSON.stringify({candidate:best}));return;
    }
    if(process.argv.includes('--thread-fixture-state')) {
        const fixture=JSON.parse(fs.readFileSync('/private/tmp/synology-chat-thread-test.json','utf8'));
        const data=await api('SYNO.Chat.Post','list',5,{channel_id:fixture.channelID,prev_count:40,next_count:0});
        const thread=await api('SYNO.Chat.Post','list',5,{channel_id:fixture.channelID,thread_id:fixture.rootID,prev_count:40,next_count:0});
        console.log(JSON.stringify({posts:[...(data.posts??[]),...(thread.posts??[])].filter(p=>p.message?.startsWith(fixture.text)).map(p=>({post_id:p.post_id,type:p.type,thread_id:p.thread_id,creator_id:p.creator_id,comment_count:p.comment_count,keys:Object.keys(p)}))}));return;
    }
    if(process.argv.includes('--unread-counts')) {
        console.log(JSON.stringify({channels:channels.map(c=>({type:c.type,encrypted:c.encrypted,unread:c.unread,mentions:c.unread_mention,threads:c.unread_thread})),
            allUnread:channels.reduce((n,c)=>n+(c.unread??0),0)}));return;
    }
    const candidates=[];
    for(const c of channels.filter(c=>c.type==='anonymous'&&!c.encrypted)) {
        const ids=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:c.channel_id})).user_ids;
        if(ids.length===2&&ids.includes(me.user_id)&&ids.some(id=>id!==me.user_id&&users.find(u=>u.user_id===id)?.nickname==='Peter')) candidates.push(c);
    }
    if(candidates.length!==1) throw new Error('Peter DM unresolved.');
    if (process.argv.includes('--channel-details-state')) {
        const channel=channels.find(c=>c.channel_id===96);
        if(me.user_id!==10 || !channel || channel.type!=='private' || channel.encrypted || !['Peter-Native-API-test','Peter-Native-API-test-renamed'].includes(channel.name)) throw new Error('Details test target mismatch.');
        const ids=(await api('SYNO.Chat.Channel.Member','get',1,{channel_id:96})).user_ids.slice().sort((a,b)=>a-b);
        if(JSON.stringify(ids)!=='[10]') throw new Error('Details target is no longer self-only.');
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:96,prev_count:30,next_count:0})).posts??[];
        console.log(JSON.stringify({channel_id:96,name:channel.name,purpose:channel.purpose??'',type:channel.type,is_joined:channel.is_joined,is_closed:channel.is_closed,member_ids:ids,non_system_posts:posts.filter(p=>p.type!=='system').length}));return;
    }
    if (process.argv.includes('--organization-state')) {
        const channel=candidates[0];
        if(channel.channel_id!==93 || me.user_id!==10) throw new Error('Organization target mismatch.');
        const keys=['channel_id','type','is_joined','encrypted','is_star','last_hide_at','last_view_at','last_post_at','last_mention_at','last_comment_at','last_view_comment_at','last_mention_comment_at','hide_global_at','unread','unread_mention','unread_comment','unread_thread','preferences'];
        console.log(JSON.stringify(Object.fromEntries(keys.filter(k=>k in channel).map(k=>[k,channel[k]]))));return;
    }
    if (process.argv.includes('--reminder-contract-test')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Reminder target mismatch.');
        const post_id=399431958766;
        const found=(await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id,prev_count:0,next_count:0})).posts??[];
        if(!found.some(p=>p.post_id===post_id&&p.creator_id===10&&p.message==='Native scheduled delivery test — Peter.'&&p.type==='normal')) throw new Error('Synthetic source mismatch.');
        const get=()=>api('SYNO.Chat.Post.Reminder','get',1,{post_id});
        if((await get()).remind_at!==0) throw new Error('Existing reminder must not be replaced.');
        const initial=(await api('SYNO.Chat.Post.Reminder','list',1,{channel_id:93})).posts??[];
        const first=Math.ceil((Date.now()+3600000)/60000)*60000,second=first+3600000;
        let proof={post_id,channel_id:93,first,second,initial_count:initial.length};
        try {
            await api('SYNO.Chat.Post.Reminder','set',1,{post_id,remind_at:first});
            proof.created=await get();
            const page=await api('SYNO.Chat.Post.Reminder','list',1,{channel_id:93});
            proof.list_schema=shape(page);proof.synthetic=page.posts?.filter(p=>p.post_id===post_id);
            try {
                const all=await api('SYNO.Chat.Post.Reminder','list',1,{channel_id:0});
                proof.all_schema=shape(all);proof.global_contains_synthetic=!!all.posts?.some(p=>p.post_id===post_id);
            } catch { proof.global_scope_supported=false; }
            if(proof.created.remind_at!==first || !proof.synthetic?.some(p=>p.props?.remind_at===first)) throw new Error('Creation readback mismatch.');
            await api('SYNO.Chat.Post.Reminder','set',1,{post_id,remind_at:second});proof.edited=await get();
            if(proof.edited.remind_at!==second) throw new Error('Edit readback mismatch.');
        } finally {
            await api('SYNO.Chat.Post.Reminder','delete',1,{post_id});proof.final=await get();
            const after=(await api('SYNO.Chat.Post.Reminder','list',1,{channel_id:93})).posts??[];
            proof.final_count=after.length;proof.removed=!after.some(p=>p.post_id===post_id);
            if(proof.final.remind_at!==0 || !proof.removed) throw new Error('Reminder cleanup not confirmed.');
        }
        console.log(JSON.stringify(proof));return;
    }
    if (process.argv.includes('--reminder-contract-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Reminder target mismatch.');
        const post_id=399431958766;
        const found=(await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id,prev_count:0,next_count:0})).posts??[];
        if(!found.some(p=>p.post_id===post_id&&p.creator_id===10&&p.message==='Native scheduled delivery test — Peter.'&&p.type==='normal')) throw new Error('Synthetic reminder source mismatch.');
        const current=await api('SYNO.Chat.Post.Reminder','get',1,{post_id});
        const pending=await api('SYNO.Chat.Post.Reminder','list',1,{channel_id:93});
        console.log(JSON.stringify({channel_id:93,post_id,current,schema:shape(pending),count:pending.posts?.length??null,synthetic:pending.posts?.filter(p=>p.post_id===post_id)}));return;
    }
    if(process.argv.includes('--peter-notification-settings')) {
        const channel = candidates[0];
        const member = await api('SYNO.Chat.Channel.Member','get',1,{channel_id:channel.channel_id});
        console.log(JSON.stringify({channelSchema:shape(channel),memberSchema:shape(member),
            notificationFields:Object.fromEntries(Object.entries(channel).filter(([key])=>/notif|mute|snooze/.test(key))),
            preferences:Object.fromEntries(Object.entries(channel.preferences??{}).filter(([key])=>key.startsWith("notification_")))}));return;
    }
    if (process.argv.includes('--profile-avatar-contract')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Profile target mismatch.');
        const result=[];
        for(const id of [10,6]) {
            const user=users.find(u=>u.user_id===id);if(!user) throw new Error('Peter profile missing.');
            const item={user_id:id,nickname:user.nickname,user_type:user.type,avatar_version:user.avatar_version,avatar_version_type:typeof user.avatar_version,props_schema:shape(user.user_props),has_email:!!user.user_props?.email,description_length:(user.user_props?.description??'').length,timezone:user.user_props?.timezone};
            if(user.avatar_version) {
                item.images=[];
                for(const size of ['S','L']) {
                    const url=new URL('webapi/entry.cgi/SYNO.Chat.User.Avatar',base.href.endsWith('/')?base:new URL(base.href+'/'));
                    url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
                    const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.User.Avatar',method:'get',version:'1',user_id:String(id),type:JSON.stringify(size),v:JSON.stringify(user.avatar_version)})});
                    const bytes=Buffer.from(await response.arrayBuffer());item.images.push({size,status:response.status,mime:response.headers.get('content-type'),bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')});
                }
            }
            result.push(item);
        }
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--scheduled-native-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Schedule target mismatch.');
        const allowed=['Native scheduled message test — Peter.','Native scheduled message test — Peter. Edited.','Native scheduled delivery test — Peter.'];
        const pending=(await api('SYNO.Chat.Post.Schedule','list',1,{channel_id:93})).schedule_posts??[];
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:30,next_count:0})).posts??[];
        console.log(JSON.stringify({channel_id:93,synthetic_pending:pending.filter(p=>allowed.includes(p.message)),other_pending_count:pending.filter(p=>!allowed.includes(p.message)).length,delivered:posts.filter(p=>allowed.includes(p.message)&&p.creator_id===10).map(p=>({post_id:p.post_id,channel_id:p.channel_id,creator_id:p.creator_id,create_at:p.create_at,type:p.type,thread_id:p.thread_id,message:p.message}))}));return;
    }
    if (process.argv.includes('--schedule-contract-test')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Schedule target mismatch.');
        const message='Native schedule contract test — Peter.',edited=message+' Edited.';
        const list=async()=> (await api('SYNO.Chat.Post.Schedule','list',1,{channel_id:93})).schedule_posts??[];
        const matches=xs=>xs.filter(p=>p.message===message || p.message===edited);
        if(matches(await list()).length) throw new Error('A synthetic schedule already exists; inspect before retrying.');
        const result={};let active;
        try {
            const send_at=Math.ceil(Date.now()/60000)*60000+20*60000;
            result.create_response_schema=shape(await api('SYNO.Chat.Post.Schedule','create',1,{channel_id:93,message,send_at}));
            const created=matches(await list());if(created.length!==1) throw new Error('Scheduled creation unconfirmed.');active=created[0];
            result.created=active;
            result.edit_response_schema=shape(await api('SYNO.Chat.Post.Schedule','set',1,{cronjob_id:active.cronjob_id,message:edited,send_at:send_at+600000}));
            const updated=matches(await list());if(updated.length!==1 || updated[0].message!==edited || updated[0].send_at!==send_at+600000) throw new Error('Scheduled edit unconfirmed.');result.edited=updated[0];
        } finally {
            const remaining=matches(await list());
            for(const p of remaining) { if(p.cronjob_id==null) throw new Error('No cancellation identity; synthetic schedule remains.');await api('SYNO.Chat.Post.Schedule','delete',1,{cronjob_id:p.cronjob_id}); }
            result.pending_after_cleanup=matches(await list()).length;
            if(result.pending_after_cleanup!==0) throw new Error('Synthetic schedule cancellation unconfirmed.');
        }
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--scheduled-schema')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Schedule target mismatch.');
        let schedules;try { schedules=await api('SYNO.Chat.Post.Schedule','list',1,{channel_id:93}); } catch(error) { if(/^API rejected request: [0-9]+$/.test(error.message)) { console.log(JSON.stringify({rejected:error.message}));return; }throw error; }
        console.log(JSON.stringify({schema:shape(schedules),count:schedules.schedule_posts?.length??null}));return;
    }
    if (process.argv.includes('--forward-native-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Forward test target mismatch.');
        const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:30,next_count:0})).posts??[];
        const expected=fs.readFileSync('reference/synology-chat/evidence/2026-10-16/snippet-root-edited.txt');
        const selected=posts.filter(p=>[399431958761,399431958763,399431958764,399431958765].includes(p.post_id));
        if(selected.length!==4) throw new Error('Expected synthetic forward sources/copies absent.');
        const results=[];
        for(const p of selected) {
            if(p.creator_id!==10 || p.channel_id!==93 || p.type!=='file' || p.message!=='Native snippet root test — edited.' || p.file_props?.name!=='native-snippet-root-edited.py') throw new Error('Forwarded fixture changed.');
            const bodies=[];
            for(const [apiName,version] of [['SYNO.Chat.Post.Snippet',1],['SYNO.Chat.Post.File',2]]) {
                const url=new URL('webapi/entry.cgi/'+apiName,base.href.endsWith('/')?base:new URL(base.href+'/'));
                url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
                const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:apiName,method:'get',version:String(version),post_id:String(p.post_id)})});
                if(response.status!==200) throw new Error('Forwarded fixture download failed.');
                const body=Buffer.from(await response.arrayBuffer());if(!body.equals(expected)) throw new Error('Forwarded source byte mismatch.');bodies.push(body);
            }
            results.push({post_id:p.post_id,creator_id:p.creator_id,channel_id:p.channel_id,thread_id:p.thread_id,type:p.type,props:p.props,file_props:p.file_props,bytes:bodies[0].length,sha256:crypto.createHash('sha256').update(bodies[0]).digest('hex'),raw_byte_equal:true,original_byte_equal:true});
        }
        const origins={399431958763:399431958761,399431958764:399431958763,399431958765:399431958764};
        for(const result of results) if(origins[result.post_id] && result.props?.forward?.origin_post_id!==origins[result.post_id]) throw new Error('Immediate-source forward metadata mismatch.');
        console.log(JSON.stringify({source_and_copies:results,source_unchanged:true,immediate_source_chain_verified:true}));return;
    }
    if (process.argv.includes('--forward-snippet-contract')) {
        if (candidates[0].channel_id !== 93 || me.user_id !== 10) throw new Error('Forward test target mismatch.');
        const src = (await api('SYNO.Chat.Post','list',5,{channel_id:93,post_id:399431958761,prev_count:0,next_count:0})).posts?.find(p=>p.post_id===399431958761);
        if (!src || src.creator_id!==10 || src.type!=='file' || src.message!=='Native snippet root test — edited.' || src.file_props?.name!=='native-snippet-root-edited.py') throw new Error('Synthetic forward source mismatch.');
        const latest = async()=> (await api('SYNO.Chat.Post','list',5,{channel_id:93,prev_count:30,next_count:0})).posts??[];
        const copies = xs=>xs.filter(p=>p.post_id!==src.post_id && p.creator_id===10 && p.type==='file' && p.message===src.message && p.file_props?.name===src.file_props.name && p.props?.forward?.origin_post_id===src.post_id);
        let after=copies(await latest()),responseShape=null;
        if (!after.length) { responseShape=shape(await api('SYNO.Chat.Post','forward',5,{post_id:src.post_id,channel_ids:[93]}));after=copies(await latest()); }
        if(after.length!==1) throw new Error('Forward receipt not uniquely established; no retry.');
        const p=after[0];console.log(JSON.stringify({source_id:src.post_id,response_shape:responseShape,forwarded:{post_id:p.post_id,channel_id:p.channel_id,creator_id:p.creator_id,type:p.type,thread_id:p.thread_id,message:p.message,file_props:p.file_props,props:p.props},source_unchanged:true}));return;
    }
    if (process.argv.includes('--hashtag-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Hashtag test target mismatch.');
        const tag='NativeParity20261016';
        const catalogue=await api('SYNO.Chat.Channel.Hashtag','list',1,{channel_id:93});
        const search=await api('SYNO.Chat.Post','search',5,{keyword:'',in:[93],hashtag:[tag],offset:0,limit:25});
        const found=(search.search_results??[]).filter(p=>p.creator_id===10 && p.message==='Native hashtag test — #NativeParity20261016 with `#LiteralNativeTag`.');
        if(found.length!==1) throw new Error('Synthetic hashtag search mismatch.');
        console.log(JSON.stringify({tag,catalogue_contains_tag:(catalogue.hashtags??[]).includes(tag),catalogue_count:(catalogue.hashtags??[]).length,
            search_ids:(search.search_results??[]).map(p=>p.post_id),post:{post_id:found[0].post_id,channel_id:found[0].channel_id,creator_id:found[0].creator_id,
                hashtags:found[0].hashtags??null,message:found[0].message}}));return;
    }
    if (process.argv.includes('--hashtag-contract')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Hashtag test target mismatch.');
        const data=await api('SYNO.Chat.Channel.Hashtag','list',1,{channel_id:93});
        console.log(JSON.stringify({schema:shape(data)}));return;
    }
    const posts=(await api('SYNO.Chat.Post','list',5,{channel_id:candidates[0].channel_id,prev_count:30,next_count:0})).posts;
    if (process.argv.includes('--snippet-native-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Snippet target mismatch.');
        const page=await api('SYNO.Chat.Post','search',5,{keyword:'Native snippet',in:[93],post_type:['file'],offset:0,limit:25});
        const definitions={'native-snippet-root.swift':['snippet-root-initial.txt',0,'Native snippet root test — Peter.'],'native-snippet-root-edited.py':['snippet-root-edited.txt',0,'Native snippet root test — edited.'],'native-snippet-thread.js':['snippet-thread.txt',399431958735,'Native snippet thread test — Peter.']};
        const result=[],seen=new Set();
        for(const p of page.search_results??[]) {
            const definition=definitions[p.file_props?.name];if(!definition || (p.props?.forward?.type && p.props.forward.type!=='none')) continue;
            if(p.creator_id!==10 || p.channel_id!==93 || p.type!=='file' || !p.file_props?.is_snippet || (p.thread_id??0)!==definition[1] || p.message!==definition[2] || seen.has(p.file_props.name)) throw new Error('Synthetic snippet identity mismatch.');
            seen.add(p.file_props.name);
            const expected=fs.readFileSync('reference/synology-chat/evidence/2026-10-16/'+definition[0]);
            async function download(name,method,version) {
                const url=new URL('webapi/entry.cgi/'+name,base.href.endsWith('/')?base:new URL(base.href+'/'));
                url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
                const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:name,method,version:String(version),post_id:JSON.stringify(p.post_id)})});
                if(response.status!==200) throw new Error('Synthetic snippet download failed.');
                return Buffer.from(await response.arrayBuffer());
            }
            const raw=await download('SYNO.Chat.Post.Snippet','get',1),original=await download('SYNO.Chat.Post.File','get',2);
            if(!raw.equals(expected)||!original.equals(expected)) throw new Error('Snippet raw/original byte mismatch.');
            result.push({post_id:p.post_id,channel_id:93,creator_id:10,thread_id:p.thread_id??0,caption:p.message,file_props:p.file_props,bytes:raw.length,sha256:crypto.createHash('sha256').update(raw).digest('hex'),raw_byte_equal:true,original_byte_equal:true});
        }
        if(!result.length) throw new Error('No synthetic native snippet found.');
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--snippet-existing-contract')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Snippet target mismatch.');
        const p=posts.find(p=>p.post_id===399431958748&&p.creator_id===10&&p.type==='file'&&p.file_props?.name==='native-drop-root-a.txt');
        if(!p) throw new Error('Known synthetic text file not found.');
        const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.Snippet',base.href.endsWith('/')?base:new URL(base.href+'/'));
        url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.Snippet',method:'get',version:'1',post_id:JSON.stringify(p.post_id)})});
        const bytes=Buffer.from(await response.arrayBuffer());
        if(response.status!==200 || !bytes.equals(Buffer.from('Synthetic native dropped file root a. No private data.\n'))) throw new Error('Synthetic snippet bytes mismatch.');
        console.log(JSON.stringify({post_id:p.post_id,file_props:p.file_props,content_type:response.headers.get('content-type'),content_disposition:!!response.headers.get('content-disposition'),bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')}));return;
    }
    if (process.argv.includes('--poll-native-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Poll target mismatch.');
        const result=[];
        for(const question of ['Native poll contract test — Peter.','Native anonymous poll test — Peter.']) {
            const page=await api('SYNO.Chat.Post','search',5,{keyword:question,in:[93],post_type:['vote'],offset:0,limit:25});
            const found=(page.search_results??[]).filter(p=>p.type==='vote'&&p.message===question);
            if(found.length!==1 || found[0].creator_id!==10 || found[0].channel_id!==93) throw new Error('Unique synthetic poll unresolved.');
            const p=found[0],choices=await api('SYNO.Chat.Post.Vote','get_choices',1,{post_id:p.post_id});
            if(p.props.vote.options.anonymous && (choices.choices??[]).some(c=>(c.voters??[]).some(id=>id!==10))) throw new Error('Anonymous poll exposed another voter identity.');
            result.push({post_id:p.post_id,channel_id:p.channel_id,creator_id:p.creator_id,message:p.message,thread_id:p.thread_id??0,poll:p.props.vote,choices:choices.choices});
        }
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--poll-contract-create') || process.argv.includes('--poll-contract-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Poll fixture target mismatch.');
        const question='Native poll contract test — Peter.';
        let found=(await api('SYNO.Chat.Post','search',5,{keyword:question,in:[93],post_type:['vote'],offset:0,limit:25})).search_results??[];
        found=found.filter(p=>p.message===question);
        if(found.length===0 && process.argv.includes('--poll-contract-create')) {
            const created=await api('SYNO.Chat.Post.Vote','create',1,{channel_id:93,message:question,choices:[{text:'Native option A'},{text:'Native option B'}],options:{multiple:true,anonymous:false,add_option:true,expire_at:0}});
            console.log(JSON.stringify({create_schema:shape(created),create_result:created}));return;
        }
        if(found.length!==1 || found[0].creator_id!==10 || found[0].channel_id!==93 || found[0].type!=='vote') throw new Error('Unique synthetic poll not found.');
        const choices=await api('SYNO.Chat.Post.Vote','get_choices',1,{post_id:found[0].post_id});
        console.log(JSON.stringify({post:found[0],choices}));return;
    }
    if (process.argv.includes('--media-playback-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Media target mismatch.');
        const folders=fs.readdirSync(process.env.TMPDIR,{withFileTypes:true}).filter(f=>f.isDirectory()&&f.name.startsWith('native-media-fixture-'));
        if(folders.length!==1) throw new Error('Unique synthetic media folder not found.');
        const result=[];
        for(const [kind,name] of [['audio','native-audio-preview.wav'],['video','native-video-preview.mp4']]) {
            const found=posts.filter(p=>p.creator_id===10 && p.channel_id===93 && p.type==='file' && p.message==='Native '+kind+' playback test — Peter.' && p.file_props?.name===name && !(p.thread_id??0));
            if(found.length!==1) throw new Error('Unique synthetic media post not found.');
            const p=found[0];
            const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
            url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
            const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(p.post_id)})});
            if(response.status!==200||!response.headers.get('content-disposition')) throw new Error('Media fixture unavailable.');
            const bytes=Buffer.from(await response.arrayBuffer()),original=process.env.TMPDIR+'/'+folders[0].name+'/'+name;
            if(!bytes.equals(fs.readFileSync(original))) throw new Error('Media bytes mismatch.');
            fs.writeFileSync('reference/synology-chat/evidence/2026-10-16/'+name,bytes);
            result.push({post_id:p.post_id,channel_id:93,creator_id:10,thread_id:p.thread_id??0,filename:name,file_type:p.file_props.type,caption:p.message,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),byte_equal:true});
        }
        const active=fs.readdirSync(process.env.TMPDIR,{withFileTypes:true}).filter(f=>f.isDirectory()&&f.name.startsWith('native-chat-media-'));
        console.log(JSON.stringify({posts:result,active_player_temporary_folders:active.length}));return;
    }
    if (process.argv.includes('--document-preview-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Document fixture target mismatch.');
        const found=posts.filter(p=>p.creator_id===10 && p.channel_id===93 && p.type==='file' && p.message==='Native PDF preview test — Peter.' && p.file_props?.name==='native-document-preview.pdf' && !(p.thread_id??0));
        if(found.length!==1) throw new Error('Unique synthetic document not found.');
        const p=found[0];
        const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
        url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(p.post_id)})});
        if(response.status!==200||!response.headers.get('content-disposition')) throw new Error('Document fixture unavailable.');
        const bytes=Buffer.from(await response.arrayBuffer());
        const folders=fs.readdirSync(process.env.TMPDIR,{withFileTypes:true}).filter(f=>f.isDirectory()&&f.name.startsWith('native-document-fixture-'));
        const originals=folders.map(f=>process.env.TMPDIR+'/'+f.name+'/native-document-preview.pdf').filter(f=>fs.existsSync(f));
        if(originals.length!==1 || !bytes.equals(fs.readFileSync(originals[0])) || !bytes.subarray(0,10).includes(Buffer.from('%PDF-'))) throw new Error('Synthetic PDF bytes mismatch.');
        const destination='reference/synology-chat/evidence/2026-10-16/document-preview-original.pdf';
        fs.writeFileSync(destination,bytes);
        console.log(JSON.stringify({post_id:p.post_id,channel_id:93,creator_id:10,thread_id:p.thread_id??0,filename:p.file_props.name,caption:p.message,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),byte_equal:true,local_fixture:destination}));return;
    }
    if (process.argv.includes('--composer-ingestion-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Composer ingestion target mismatch.');
        const rows=[];
        for(const keyword of ['Native clipboard image','Native drop files']) {
            const page=await api('SYNO.Chat.Post','search',5,{keyword,in:[93],post_type:['file'],offset:0,limit:25});
            rows.push(...(page.search_results??[]));
        }
        const result=[];const seen=new Set();
        for(const p of rows) {
            if(seen.has(p.post_id)) continue;seen.add(p.post_id);
            if(p.creator_id!==10 || p.channel_id!==93) throw new Error('Composer fixture identity mismatch.');
            const pasted=/^Native clipboard image (root|thread) test — Peter\.$/.exec(p.message);
            const dropped=/^native-drop-(root|thread)-([ab])\.txt$/.exec(p.file_props?.name??'');
            if(!pasted&&!dropped) continue;
            const scope=pasted?pasted[1]:dropped[1];
            if((p.thread_id??0)!==(scope==='root'?0:399431958735)) throw new Error('Composer fixture destination mismatch.');
            if(pasted && p.file_props?.name!=='Pasted image.png') throw new Error('Clipboard filename mismatch.');
            if(dropped && p.message!=='Native drop files '+scope+' test — '+(dropped[2]==='a'?'Peter.':'second file.')) throw new Error('Dropped caption mismatch.');
            const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
            url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
            const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(p.post_id)})});
            if(response.status!==200||!response.headers.get('content-disposition')) throw new Error('Composer fixture download unavailable.');
            const bytes=Buffer.from(await response.arrayBuffer());const hash=crypto.createHash('sha256').update(bytes).digest('hex');
            if(pasted && hash!=='a66926da4ea9f7d3586a12e6d01a5030a59173607346c1381dec1a8adb951f67') throw new Error('Pasted image byte mismatch.');
            if(dropped && !bytes.equals(Buffer.from('Synthetic native dropped file '+scope+' '+dropped[2]+'. No private data.\n'))) throw new Error('Dropped file byte mismatch.');
            result.push({post_id:p.post_id,thread_id:p.thread_id??0,filename:p.file_props.name,caption:p.message,bytes:bytes.length,sha256:hash,byte_equal:true});
        }
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--multi-attachment-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Multi-file test target mismatch.');
        const data=await api('SYNO.Chat.Post','search',5,{keyword:'Native multi',in:[93],post_type:['file'],offset:0,limit:25});
        const result=[];const seen=new Set();
        for(const p of data.search_results??[]) {
            const match=/^native-multi-(root|thread|thread-context)-([ab])\.txt$/.exec(p.file_props?.name??'');
            if(!match) continue;
            const [,scope,letter]=match;
            if(p.creator_id!==10 || p.channel_id!==93 || (p.thread_id??0)!==(scope==='root'?0:399431958735) || seen.has(p.file_props.name)) throw new Error('Multi-file fixture identity/destination mismatch.');
            seen.add(p.file_props.name);
            const expectedCaption='Native multi '+scope.replaceAll('-',' ')+' test — '+(letter==='a'?'first':'second')+' file.';
            if(p.message!==expectedCaption) throw new Error('Multi-file caption mismatch.');
            const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
            url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
            const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(p.post_id)})});
            if(response.status!==200||!response.headers.get('content-disposition')) throw new Error('Multi-file download unavailable.');
            const bytes=Buffer.from(await response.arrayBuffer());
            const expected=Buffer.from('Synthetic native multi-file '+scope+' '+letter+' fixture. No private data.\n');
            if(!bytes.equals(expected)) throw new Error('Multi-file byte mismatch.');
            result.push({post_id:p.post_id,channel_id:p.channel_id,thread_id:p.thread_id??0,filename:p.file_props.name,caption:p.message,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),byte_equal:true});
        }
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--pin-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Pin test target mismatch.');
        const keyword='Native link preview test';
        const ordinary=await api('SYNO.Chat.Post','search',5,{keyword,in:[93],offset:0,limit:25});
        const rows=ordinary.search_results??[];
        if(rows.length!==1 || rows[0].post_id!==399431958731 || rows[0].creator_id!==10) throw new Error('Synthetic pin fixture mismatch.');
        const pinned=await api('SYNO.Chat.Post','search',5,{keyword,in:[93],offset:0,limit:25,has:['pin'],sort_by:'last_pin_at',sort_by_array:['is_sticky','last_pin_at']});
        console.log(JSON.stringify({post_id:rows[0].post_id,thread_id:rows[0].thread_id??0,comment_count:rows[0].comment_count??0,last_pin_at:rows[0].last_pin_at??0,is_sticky:rows[0].is_sticky??false,pinned_ids:(pinned.search_results??[]).map(p=>p.post_id),subscribes:candidates[0].subscribes??null}));return;
    }
    if (process.argv.includes('--read-status-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Read-status target mismatch.');
        const settings=await api('SYNO.Chat.Admin.Setting','get',5);
        if(settings.allow_read_status!==true) { console.log(JSON.stringify({allow_read_status:settings.allow_read_status??null,queried:false}));return; }
        const result=[];
        for(const id of [399431958731,399431958736]) {
            const data=await api('SYNO.Chat.Post','get_read_status',6,{post_id:id});
            result.push({post_id:id,schema:shape(data),read_users:data.read_users,unread_users:data.unread_users});
        }
        console.log(JSON.stringify({allow_read_status:true,queried:true,cases:result}));return;
    }
    if (process.argv.includes('--threads-all-schema')) {
        try {
            const page=await api('SYNO.Chat.Post','thread_list',5,{offset:0,limit:25,related_comment_count:1});
            console.log(JSON.stringify({supported:true,keys:Object.keys(page),total:page.total??null,count:(page.search_results??[]).length,channels:[...new Set((page.search_results??[]).map(p=>p.channel_id))]}));
        } catch(error) { console.log(JSON.stringify({supported:false,error:error.message})); }
        return;
    }
    if (process.argv.includes('--threads-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Threads read target mismatch.');
        const page=await api('SYNO.Chat.Post','thread_list',5,{channel_id:93,offset:0,limit:25,related_comment_count:1});
        console.log(JSON.stringify({keys:Object.keys(page),total:page.total??null,subscribes:candidates[0].subscribes??null,threads:(page.search_results??[]).map(p=>({post_id:p.post_id,channel_id:p.channel_id,thread_id:p.thread_id??0,comment_count:p.comment_count,is_subscribed:p.is_subscribed??null})),related:(page.related_posts??[]).map(p=>({post_id:p.post_id,channel_id:p.channel_id,thread_id:p.thread_id,creator_id:p.creator_id}))}));return;
    }
    if (process.argv.includes('--bookmark-test-cleanup')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Bookmark cleanup target mismatch.');
        const page=await api('SYNO.Chat.Post','search',5,{keyword:'Native link preview test',in:[93],offset:0,limit:25});
        const rows=page.search_results??[];
        if(rows.length!==1 || rows[0].post_id!==399431958731 || rows[0].creator_id!==10 || rows[0].message!=='Native link preview test — https://www.synology.com/en-global/dsm/feature/chat') throw new Error('Synthetic bookmark cleanup fixture mismatch.');
        if(rows[0].is_star===true) await api('SYNO.Chat.Post','unstar',5,{post_id:399431958731});
        const saved=await api('SYNO.Chat.Post','search',5,{keyword:'Native link preview test',has:['star'],offset:0,limit:25});
        if((saved.search_results??[]).some(p=>p.post_id===399431958731)) throw new Error('Bookmark cleanup not confirmed.');
        console.log(JSON.stringify({post_id:399431958731,restored_unbookmarked:true}));return;
    }
    if (process.argv.includes('--bookmark-test-state') || process.argv.includes('--bookmark-thread-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Bookmark test target mismatch.');
        const thread=process.argv.includes('--bookmark-thread-test-state');
        const keyword=thread?'Native mention reply':'Native link preview test';
        const id=thread?399431958736:399431958731;
        const page=await api('SYNO.Chat.Post','search',5,{keyword,in:[93],offset:0,limit:25});
        const rows=page.search_results??[];
        if(rows.length!==1 || rows[0].post_id!==id || rows[0].creator_id!==10) throw new Error('Synthetic bookmark fixture mismatch.');
        const saved=await api('SYNO.Chat.Post','search',5,{keyword,has:['star'],offset:0,limit:25});
        console.log(JSON.stringify({post_id:id,thread_id:rows[0].thread_id??0,is_star:rows[0].is_star??null,star_at:rows[0].star_at??null,saved_ids:(saved.search_results??[]).map(p=>p.post_id),saved_dates:(saved.search_results??[]).map(p=>p.star_at??null)}));return;
    }
    if (process.argv.includes('--library-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Library test target mismatch.');
        const cases=[['files','',{post_type:['file']}],['images','Native image viewer test',{post_type:['file']}],['link','Native link preview test',{has:['url']}],['thread','Native Swift thread attachment test',{post_type:['file']}],['empty','NoSuchNativeLibraryFixture20261016',{post_type:['file']}]];
        const result=[];
        for(const [name,keyword,filters] of cases) {
            const page=await api('SYNO.Chat.Post','search',5,{keyword,in:[93],offset:0,limit:25,...filters});
            const rows=page.search_results??[];
            result.push({name,total:page.total??null,count:rows.length,same_channel:rows.every(p=>p.channel_id===93),ids:rows.map(p=>p.post_id),thread_ids:rows.filter(p=>p.thread_id).map(p=>p.thread_id)});
        }
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--advanced-search-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Search filter test target mismatch.');
        function day(value,after) { const date=new Date(value);date.setHours(after?0:23,after?0:59,after?0:59,0);return date.getTime(); }
        const cases=[
            ['author_positive','Native hashtag test',{from:[10]},[399431958739]],
            ['author_negative','Native hashtag test',{from:[6]},[]],
            ['mention_positive','Native mention test',{mention:[6]},[399431958735]],
            ['mention_negative','Native mention test',{mention:[10]},[]],
            ['file_png','Native image viewer test',{post_type:['file'],file_type:['png']},[399431958729,399431958730]],
            ['file_pdf_negative','Native image viewer test',{post_type:['file'],file_type:['pdf']},[]],
            ['has_url','Native link preview test',{has:['url']},[399431958731]],
            ['date_today','Native hashtag test',{after:day('2026-10-16',true),before:day('2026-10-16',false)},[399431958739]],
            ['date_previous_negative','Native hashtag test',{before:day('2026-10-15',false)},[]]
        ];
        const result=[];
        for(const [name,keyword,filters,expected] of cases) {
            const data=await api('SYNO.Chat.Post','search',5,{keyword,in:[93],offset:0,limit:25,...filters});
            const ids=(data.search_results??[]).map(p=>p.post_id).sort((a,b)=>a-b);
            const matches=JSON.stringify(ids)===JSON.stringify(expected);
            result.push({name,ids,expected,matches});
        }
        console.log(JSON.stringify(result));return;
    }
    if (process.argv.includes('--toolbar-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Synthetic toolbar target mismatch.');
        const matches=posts.filter(p=>p.creator_id===10 && p.type==='normal' && p.message.startsWith('Native toolbar test — ') && !p.delete_at);
        if(matches.length!==1) throw new Error('Synthetic toolbar post not unique.');
        const root=matches[0];
        const thread=(await api('SYNO.Chat.Post','list',5,{channel_id:93,thread_id:root.post_id,prev_count:30,next_count:0})).posts??[];
        const selected=[root,...thread.filter(p=>p.creator_id===10 && p.message.startsWith('Native toolbar code reply — '))];
        console.log(JSON.stringify(selected.map(p=>({post_id:p.post_id,channel_id:p.channel_id,type:p.type,message:p.message,creator_id:p.creator_id,thread_id:p.thread_id??0}))));return;
    }
    if (process.argv.includes('--mention-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Synthetic mention target mismatch.');
        const matches=posts.filter(p=>p.creator_id===10 && p.type==='normal' && p.message.startsWith('Native mention test — cursor insert: ') && !p.delete_at);
        if(matches.length!==1) throw new Error('Synthetic mention post not unique.');
        const root=matches[0];
        const thread=(await api('SYNO.Chat.Post','list',5,{channel_id:93,thread_id:root.post_id,prev_count:30,next_count:0})).posts??[];
        const selected=[root,...thread.filter(p=>p.creator_id===10 && p.message.startsWith('Native mention reply — '))];
        console.log(JSON.stringify(selected.map(p=>({post_id:p.post_id,channel_id:p.channel_id,type:p.type,message:p.message,creator_id:p.creator_id,thread_id:p.thread_id??0,
            mention_fields:Object.fromEntries(Object.entries(p).filter(([key])=>key.toLowerCase().includes('mention')))}))));return;
    }
    if (process.argv.includes('--formatting-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Synthetic formatting target mismatch.');
        const matches=posts.filter(p=>p.creator_id===10 && p.type==='normal' && p.message.startsWith('Native formatting test — native rich text.\n') && !p.delete_at);
        if(matches.length!==1) throw new Error('Synthetic formatting post not unique.');
        const p=matches[0];
        console.log(JSON.stringify({post_id:p.post_id,channel_id:p.channel_id,type:p.type,message:p.message,creator_id:p.creator_id}));return;
    }
    if (process.argv.includes('--sticker-test-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Synthetic sticker target mismatch.');
        const matches=posts.filter(p=>p.creator_id===10 && p.type==='sticker' &&
            p.create_at>=Date.UTC(2026,9,16,18,0,0) && [':dog_01:',':dog_02:'].includes(p.message));
        const roots=matches.filter(p=>(p.thread_id??0)===0 || p.thread_id===p.post_id);
        for(const root of roots) {
            const thread=(await api('SYNO.Chat.Post','list',5,{channel_id:93,thread_id:root.post_id,prev_count:30,next_count:0})).posts??[];
            for(const p of thread) if(p.type==='sticker' && p.creator_id===10 && p.message===':dog_02:' && !matches.some(x=>x.post_id===p.post_id)) matches.push(p);
        }
        console.log(JSON.stringify(matches.map(p=>({post_id:p.post_id,channel_id:p.channel_id,type:p.type,message:p.message,
            creator_id:p.creator_id,thread_id:p.thread_id??0,delete_at:p.delete_at??0,reactions:p.reactions??[]}))));return;
    }
    if (process.argv.includes('--reaction-catalog-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Synthetic reaction target mismatch.');
        const matches=posts.filter(p=>p.post_id===399431958731 && p.creator_id===10 &&
            p.message==='Native link preview test — https://www.synology.com/en-global/dsm/feature/chat' && !p.delete_at);
        if(matches.length!==1)throw new Error('Synthetic reaction post unresolved.');
        console.log(JSON.stringify({post_id:matches[0].post_id,reactions:matches[0].reactions??[]}));return;
    }
    if (process.argv.includes('--link-preview-state')) {
        const matches=posts.filter(p=>p.message==='Native link preview test — https://www.synology.com/en-global/dsm/feature/chat' && !p.delete_at);
        if(matches.length!==1)throw new Error('Synthetic link fixture not unique.');
        const p=matches[0];
        console.log(JSON.stringify({post_id:p.post_id,channel_id:p.channel_id,type:p.type,creator_id:p.creator_id,
            url_props:p.url_props??null,props:p.props??null}));return;
    }
    if(process.argv.includes('--arm-animated-viewer')||process.argv.includes('--animated-viewer-proof')) {
        if(candidates[0].channel_id!==93||me.user_id!==10) throw new Error('Authorized Peter target unresolved.');
        const caption='Native animated image viewer test — synthetic colours only.',filename='native-animated-viewer.gif',marker='reference/synology-chat/evidence/2026-10-20/animated-viewer-dispatch.json';
        const matches=posts.filter(p=>p.creator_id===10&&p.type==='file'&&p.file_props?.name===filename&&p.message===caption&&!p.delete_at);
        if(process.argv.includes('--arm-animated-viewer')) {
            if(matches.length||fs.existsSync(marker)) throw new Error('Animated fixture already armed or delivered; do not repeat.');
            const temp=process.env.TMPDIR;if(!temp) throw new Error('Temporary fixture directory unavailable.');
            const staged=fs.readdirSync(temp).filter(n=>n.startsWith('native-animated-fixture-')).map(n=>temp.replace(/\/$/,'')+'/'+n+'/'+filename).filter(p=>fs.existsSync(p)).sort((a,b)=>fs.statSync(b).mtimeMs-fs.statSync(a).mtimeMs);
            if(!staged.length) throw new Error('Native synthetic fixture not staged.');const bytes=fs.readFileSync(staged[0]);if(bytes.length>64000||!['GIF87a','GIF89a'].includes(bytes.subarray(0,6).toString())||bytes.readUInt16LE(6)!==360||bytes.readUInt16LE(8)!==220) throw new Error('Synthetic GIF mismatch.');
            fs.writeFileSync('reference/synology-chat/evidence/2026-10-20/animated-source.gif',bytes,{flag:'wx'});
            const record={phase:'before native send once',channel_id:93,filename,caption,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),time:new Date().toISOString()};fs.writeFileSync(marker,JSON.stringify(record,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify(record));return;
        }
        const record=JSON.parse(fs.readFileSync(marker,'utf8'));if(matches.length!==1) throw new Error('Expected exactly one animated synthetic post.');const post=matches[0],responses=[];
        for(const [name,method,type] of [['original','get',null],['XL','thumbnail','XL'],['full-thumbnail','thumbnail','']]) {
            const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
            const body=new URLSearchParams({api:'SYNO.Chat.Post.File',method,version:'2',post_id:JSON.stringify(post.post_id)});if(type!==null) body.set('type',JSON.stringify(type));
            const response=await fetch(url,{method:'POST',body,redirect:'error',signal:AbortSignal.timeout(20000)}),bytes=Buffer.from(await response.arrayBuffer());
            if(!response.ok||bytes.length>32*1024*1024) throw new Error('Synthetic image response unavailable.');const hash=crypto.createHash('sha256').update(bytes).digest('hex');if(name==='original'&&hash!==record.sha256) throw new Error('Synthetic original byte mismatch.');
            fs.writeFileSync('reference/synology-chat/evidence/2026-10-20/animated-nas-'+name+'.bin',bytes);responses.push({route:name,mime:response.headers.get('content-type'),bytes:bytes.length,sha256:hash});
        }
        const proof={channel_id:93,post_id:post.post_id,filename,caption,responses,time:new Date().toISOString()};fs.writeFileSync('reference/synology-chat/evidence/2026-10-20/animated-backend-proof.json',JSON.stringify(proof,null,2)+'\n');console.log(JSON.stringify(proof));return;
    }
    if (process.argv.includes('--image-viewer-state')) {
        if(candidates[0].channel_id!==93 || me.user_id!==10) throw new Error('Synthetic image target mismatch.');
        const fixtures=[['landscape','17cc5e2769fe5005d01e9f694f7b8670e756432e8c3833c42dfbe687d1bcf596'],
                        ['portrait','e7c20413088ddafcce5e177f5e9d567e620ad95984150143cab948f74eb07cbc']];
        const found=[];
        for(const [kind,expected] of fixtures) {
            const matches=posts.filter(p=>p.file_props?.name==='synology-native-viewer-'+kind+'.png' &&
                p.message==='Native image viewer test — synthetic '+kind+'.' && p.creator_id===10 && !p.delete_at);
            if(matches.length!==1 || matches[0].type!=='file' || (matches[0].thread_id??0)!==0 || !matches[0].file_props?.is_image)
                throw new Error('Synthetic image receipt mismatch.');
            const post=matches[0];
            const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
            url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
            const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:String(post.post_id)})});
            if(!response.ok || !response.headers.get('content-disposition'))throw new Error('Synthetic image download rejected.');
            const bytes=Buffer.from(await response.arrayBuffer());const digest=crypto.createHash('sha256').update(bytes).digest('hex');
            if(digest!==expected)throw new Error('Synthetic original image differs.');
            found.push({post_id:post.post_id,channel_id:93,type:post.type,thread_id:post.thread_id??0,creator_id:10,
                filename:post.file_props.name,is_image:true,bytes:bytes.length,sha256:digest,byte_equal:true});
        }
        console.log(JSON.stringify({channel_id:93,images:found,unique:true}));return;
    }
    if (process.argv.includes('--normal208-state')) {
        const expected=[['Native optimized208 verification — Peter.',10],['Native optimized208 inbound verification — Peter.',6],
            ['Native optimized208 closed-window notification — Peter.',6]];
        const found=expected.map(([message,author])=>{
            const matches=posts.filter(p=>p.message===message && p.creator_id===author && !p.delete_at);
            if(matches.length!==1 || matches[0].type!=='normal' || (matches[0].thread_id??0)!==0)
                throw new Error('Optimized208 fixture receipt mismatch.');
            const p=matches[0];return {post_id:p.post_id,creator_id:p.creator_id,channel_id:p.channel_id,type:p.type,thread_id:p.thread_id??0};
        });
        console.log(JSON.stringify({channel_id:candidates[0].channel_id,unread:candidates[0].unread,posts:found,unique:true}));return;
    }
    if (process.argv.includes('--relay-attachment-state')) {
        const matches=posts.filter(p=>p.type==='file' && !p.delete_at && p.creator_id===me.user_id
            && p.file_props?.name==='native-swift-relay-attachment-test.txt'
            && p.message==='Native relay attachment verification — Peter.');
        if(matches.length!==1)throw new Error('Relay test attachment is not unique.');
        const post=matches[0];
        const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
        url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(post.post_id)})});
        if(response.status!==200||!response.headers.get('content-disposition'))throw new Error('Relay test attachment unavailable.');
        const bytes=Buffer.from(await response.arrayBuffer());
        if(!bytes.equals(Buffer.from('Synthetic native Swift attachment transfer test. No private data.\n')))throw new Error('Relay attachment mismatch.');
        console.log(JSON.stringify({channel_id:post.channel_id,post_id:post.post_id,creator_id:post.creator_id,type:post.type,
            thread_id:post.thread_id??0,bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),byte_equal:true,read_via_direct_route:true}));return;
    }
    if (process.argv.includes('--ui-upload-cancel-state')) {
        const root=posts.find(p=>p.post_id===399431958721 && p.creator_id===me.user_id
            && p.message?.startsWith('Native action verification — root, 16 October 15:11.'));
        if(!root)throw new Error('Controlled UI cancellation thread unresolved.');
        const replies=(await api('SYNO.Chat.Post','list',5,{channel_id:candidates[0].channel_id,
            thread_id:root.post_id,prev_count:30,next_count:0})).posts??[];
        const matches=[...posts,...replies].filter(p=>p.creator_id===me.user_id
            && (p.file_props?.name==='synology-native-ui-cancel-test-512MiB.bin'
                || p.message==='Native UI upload cancellation — retain this unsent caption.'));
        console.log(JSON.stringify({channel_id:candidates[0].channel_id,root_id:root.post_id,
            root_reply_count:root.comment_count??0,matches:matches.map(p=>({post_id:p.post_id,
            type:p.type,thread_id:p.thread_id??0,deleted:!!p.delete_at}))}));return;
    }
    if (process.argv.includes('--upload-cancel-state')) {
        const matches=posts.filter(p=>p.type==='file' && p.creator_id===me.user_id
            && p.file_props?.name==='synology-native-cancel-test-512MiB.bin');
        console.log(JSON.stringify({channel_id:candidates[0].channel_id,matches:matches.map(p=>({post_id:p.post_id,channel_id:p.channel_id,
            type:p.type,thread_id:p.thread_id??0,creator_id:p.creator_id,size:p.file_props?.size,deleted:!!p.delete_at}))}));return;
    }
    if (process.argv.includes('--transfer-recovery-state')) {
        const matches = posts.filter(p=>p.type==='file' && !p.delete_at && p.creator_id===me.user_id
            && p.message==='Native transfer recovery test — caption retained after unreadable file.'
            && p.file_props?.name==='synology-native-unreadable-fixture.txt');
        if (matches.length!==1) throw new Error('Recovery post is not unique.');
        const post=matches[0];
        const url=new URL('webapi/entry.cgi/SYNO.Chat.Post.File',base.href.endsWith('/')?base:new URL(base.href+'/'));
        url.search=new URLSearchParams({_sid:session.sid,SynoToken:session.synotoken});
        const response=await fetch(url,{method:'POST',redirect:'error',body:new URLSearchParams({api:'SYNO.Chat.Post.File',method:'get',version:'2',post_id:JSON.stringify(post.post_id)})});
        if(response.status!==200||!response.headers.get('content-disposition'))throw new Error('Attachment unavailable.');
        const received=Buffer.from(await response.arrayBuffer());
        const source=fs.readFileSync('/private/tmp/synology-native-unreadable-fixture.txt');
        if(!received.equals(source))throw new Error('Byte mismatch.');
        console.log(JSON.stringify({channel_id:post.channel_id,post_id:post.post_id,type:post.type,thread_id:post.thread_id??0,creator_id:post.creator_id,
            controlled_posts:matches.length,bytes:received.length,sha256:crypto.createHash('sha256').update(received).digest('hex'),byte_equal:true}));return;
    }
    if (process.argv.includes('--notification-review-state')) {
        const matches = posts.filter(p=>p.message==='Native notification privacy review — Peter.'&&p.creator_id===6&&p.type==='normal'&&!p.delete_at);
        console.log(JSON.stringify({channel_id:candidates[0].channel_id,matches:matches.map(p=>({post_id:p.post_id,creator_id:p.creator_id,type:p.type,thread_id:p.thread_id??0}))}));return;
    }
    if (process.argv.includes('--native-action-state')) {
        const roots = posts.filter(p=>p.creator_id===me.user_id&&p.message?.startsWith('Native action verification — root, 16 October 15:11.'));
        if(roots.length!==1) throw new Error('Controlled action root unresolved.');
        const root = roots[0];
        const thread=(await api('SYNO.Chat.Post','list',5,{channel_id:candidates[0].channel_id,thread_id:root.post_id,prev_count:30,next_count:0})).posts??[];
        console.log(JSON.stringify({channel_id:candidates[0].channel_id,root:{post_id:root.post_id,creator_id:root.creator_id,comment_count:root.comment_count??0,keyboard_edit_verified:root.message.includes('Keyboard edit verified.'),thread_shortcut_verified:root.message.includes('Thread shortcut verified.'),failure_recovery_verified:root.message.includes('Failure recovery verified.')},unexpected_guard_posts:posts.filter(p=>['Unsent composer guard verification','Unsent thread guard verification'].includes(p.message)).map(p=>p.post_id),
            replies:thread.filter(p=>p.post_id!==root.post_id).map(p=>({post_id:p.post_id,creator_id:p.creator_id,thread_id:p.thread_id,type:p.type,deleted:!!p.delete_at,
                synthetic:p.message?.startsWith('Native action verification — reply'),edited:p.message==='Native action verification — reply after edit.',thumbs_up:(p.reactions??[]).some(r=>r.sticker_name==='thumbsup'&&r.user_ids.includes(me.user_id))}))}));return;
    }
    if (process.argv.includes('--large-transfer-state')) {
        const settings = await api('SYNO.Chat.Admin.Setting', 'get', 5);
        const matches = posts.filter(p=>p.type==='file'&&p.file_props?.name==='synology-native-transfer-test-32MiB.bin');
        console.log(JSON.stringify({channel_id:candidates[0].channel_id,file_size_limit_mb:settings.file_size_limit,
            matches:matches.map(p=>({post_id:p.post_id,channel_id:p.channel_id,type:p.type,thread_id:p.thread_id??0,creator_id:p.creator_id,size:p.file_props?.size,deleted:!!p.delete_at}))}));return;
    }
    if (process.argv.includes('--account-notification-state')) {
        const labels = ['Native account-bound notification test — Peter.', 'Native account-bound closed-window test — Peter.'];
        const matches = posts.filter(p => labels.includes(p.message) && p.creator_id === 6 && p.type === 'normal' && !p.delete_at);
        console.log(JSON.stringify({matches: matches.length, posts: matches.map(p=>({channel_id:p.channel_id, post_id:p.post_id, creator_id:p.creator_id, type:p.type, thread_id:p.thread_id??0, closed_window:p.message===labels[1]}))}));
        return;
    }
    if(process.argv.includes('--optimized-release-state')) {
        const sent = posts.filter(p=>p.message==='Native release verification — independent QuickConnect session.'&&p.creator_id===me.user_id);
        const received = posts.filter(p=>p.message==='Native release reply — inbound event verification.'&&p.creator_id!==me.user_id);
        console.log(JSON.stringify({sent:sent.map(p=>({post_id:p.post_id,type:p.type,thread_id:p.thread_id,own:true})),received:received.map(p=>({post_id:p.post_id,type:p.type,thread_id:p.thread_id,own:false}))}));return;
    }
    if(process.argv.includes('--normal-thread-schema')) {
        const roots=posts.filter(p=>p.creator_id===me.user_id&&p.message==='Native interoperability test — edited normal message.');
        if(roots.length!==1) throw new Error('Synthetic root not unique.');
        const root=roots[0];
        const thread=(await api('SYNO.Chat.Post','list',5,{channel_id:candidates[0].channel_id,thread_id:root.post_id,prev_count:30,next_count:0})).posts;
        console.log(JSON.stringify({root:{post_id:root.post_id,type:root.type,thread_id:root.thread_id,comment_count:root.comment_count},
          replies:thread.filter(p=>p.post_id!==root.post_id).map(p=>({post_id:p.post_id,type:p.type,thread_id:p.thread_id,own:p.creator_id===me.user_id,synthetic:p.message==='Native interoperability reply — normal thread message.',thumbsUp:(p.reactions??[]).some(r=>r.sticker_name==='thumbsup'&&r.user_ids.includes(me.user_id))}))}));return;
    }
    for(const p of posts.filter(p=>p.create_at>=Date.UTC(2026,9,16))) {
        console.log(JSON.stringify({post_id:p.post_id,type:p.type,creator_id:p.creator_id,system_props:p.system_props??null,
          props:p.type==='system'?p.props:undefined,keys:Object.keys(p),synthetic:p.message?.startsWith('Native ')}));
    }
}
main().catch(()=>{console.error('Local diagnostic failed; details suppressed.');process.exitCode=1;});
