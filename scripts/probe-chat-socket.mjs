// Local interoperability probe. No credentials, URLs or message bodies are logged.
// --send-to-peter authorizes exactly one fixed test message to the uniquely resolved Peter DM.
import fs from 'node:fs';
import crypto from 'node:crypto';
import WebSocket from '../reference/synology-chat/cache/reverse-engineering-2026-10-16/rea-runtime/node_modules/ws/wrapper.mjs';

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
    const manifest = await (await fetch(new URL('webman/3rdparty/Chat/config', base), { redirect: 'error' })).json();
    const version = manifest['libs.skip.js']['SYNO.SDS.Chat.SocketIO'].version;
    let target;
    if (process.argv.includes('--send-to-peter')) {
        const users = (await api('SYNO.Chat.User', 'list', 2)).users;
        const me = users.find(u => u.username?.toLowerCase() === session.username.toLowerCase());
        if (!me) throw new Error('Cannot identify current user.');
        const channels = (await api('SYNO.Chat.Channel', 'list', 5, { is_joined: true })).channels;
        const candidates = [];
        for (const channel of channels.filter(c => c.type === 'anonymous' && !c.encrypted)) {
            const members = (await api('SYNO.Chat.Channel.Member', 'get', 1, { channel_id: channel.channel_id })).user_ids;
            const others = members.filter(id => id !== me.user_id);
            if (members.length === 2 && others.length === 1 && users.find(u => u.user_id === others[0])?.nickname === 'Peter') candidates.push(channel);
        }
        if (candidates.length !== 1) throw new Error('Peter DM did not resolve uniquely. No message sent.');
        target = candidates[0];
        console.log('Resolved the unique Peter direct conversation.');
    }
    const url = new URL('sc/socket.io/', base);
    url.protocol = 'wss:';
    url.search = new URLSearchParams({ EIO: '3', transport: 'websocket', SynoToken: session.synotoken, client: 'browser', version_ui: version });
    const ws = new WebSocket(url, { headers: { Cookie: 'id=' + session.sid, Origin: base.origin } });
    let heartbeat;
    let sent = false;
    const timeout = setTimeout(() => { console.log('Observation finished.'); ws.close(); }, 35000);
    ws.on('message', async bytes => {
        const packet = bytes.toString();
        try {
            if (packet.startsWith('0')) {
                const hello = JSON.parse(packet.slice(1));
                console.log('Engine.IO v3 handshake', { pingInterval: hello.pingInterval, pingTimeout: hello.pingTimeout });
                heartbeat = setInterval(() => ws.send('2'), hello.pingInterval);
            } else if (packet === '3') console.log('Heartbeat pong received.');
            else if (packet.startsWith('42')) {
                const [name, payload] = JSON.parse(packet.slice(2));
                console.log('Socket event:', name, JSON.stringify(shape(payload)));
                if (name === 'client.init') {
                    ws.send('42["client.initdone"]');
                    if (target && !sent) {
                        sent = true;
                        const result = process.argv.includes('--resume-post-actions')
                            ? (await api('SYNO.Chat.Post', 'list', 5, { channel_id: target.channel_id, prev_count: 30, next_count: 0 })).posts.find(p => p.message === 'Native feature test — edited successfully.')
                            : await api('SYNO.Chat.Post', 'create', 5, { channel_id: target.channel_id,
                            type: 'normal', message: process.argv.includes('--exercise-post-actions') ? 'Native feature test — thread and reaction validation.' : 'Native Synology Chat test — backend send/live delivery check.',
                            is_thread: false, thread_id: 0, conn_id: '' });
                        if (!result) throw new Error('Synthetic test root was not found.');
                        console.log(process.argv.includes('--resume-post-actions') ? 'Resuming own synthetic test post. Response schema:' : 'One test message sent to Peter. Response schema:', JSON.stringify(shape(result)));
                        if (process.argv.includes('--upload-synthetic-file')) {
                            const content = process.argv.includes('--upload-synthetic-image')
                                ? Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=', 'base64')
                                : Buffer.from('Synthetic native client attachment test. No private data.');
                            const url = new URL('webapi/entry.cgi/SYNO.Chat.Post', base);
                            url.search = new URLSearchParams({ _sid: session.sid, SynoToken: session.synotoken });
                            const form = new FormData();
                            for (const [key, value] of Object.entries({ api: 'SYNO.Chat.Post', method: 'create', version: '5',
                                channel_id: String(target.channel_id), type: 'file', message: 'Native attachment test.',
                                is_thread: 'false', thread_id: '0', conn_id: '' })) form.append(key, value);
                            form.append('file', new Blob([content], { type: process.argv.includes('--upload-synthetic-image') ? 'image/png' : 'text/plain' }), process.argv.includes('--upload-synthetic-image') ? 'native-client-test.png' : 'native-client-test.txt');
                            const upload = await (await fetch(url, { method: 'POST', body: form, redirect: 'error' })).json();
                            if (!upload.success) throw new Error('API rejected request: ' + upload.error?.code);
                            console.log('Synthetic attachment upload schema:', JSON.stringify(shape(upload.data)));
                            const downloadURL = new URL('webapi/entry.cgi/SYNO.Chat.Post.File', base);
                            downloadURL.search = new URLSearchParams({ _sid: session.sid, SynoToken: session.synotoken });
                            const download = await fetch(downloadURL, { method: 'POST', redirect: 'error', body: new URLSearchParams({
                                api: 'SYNO.Chat.Post.File', method: 'get', version: '2', post_id: String(upload.data.post_id) }) });
                            console.log('Attachment byte-for-byte readback verified:', Buffer.from(await download.arrayBuffer()).equals(content),
                                'Content-Disposition present:', download.headers.has('Content-Disposition'));
                            if (process.argv.includes('--upload-synthetic-image')) {
                                const thumb = await fetch(downloadURL, { method: 'POST', redirect: 'error', body: new URLSearchParams({
                                    api: 'SYNO.Chat.Post.File', method: 'thumbnail', version: '2', post_id: String(upload.data.post_id), type: '"M"' }) });
                                console.log('Thumbnail status:', thumb.status, 'MIME:', thumb.headers.get('Content-Type'), 'Bytes:', (await thumb.arrayBuffer()).byteLength);
                            }
                        }
                        if (process.argv.includes('--exercise-post-actions')) {
                            await api('SYNO.Chat.Post', 'set', 8, { channel_id: target.channel_id, post_id: result.post_id,
                                thread_id: 0, message: 'Native feature test — edited successfully.' });
                            console.log('Own synthetic test post edited.');
                            const reply = await api('SYNO.Chat.Post', 'create', 5, { channel_id: target.channel_id,
                                type: 'normal', message: 'Native thread reply test.', is_thread: false,
                                thread_id: result.post_id, conn_id: '' });
                            const thread = await api('SYNO.Chat.Post', 'list', 5, { channel_id: target.channel_id,
                                thread_id: result.post_id, prev_count: 30, next_count: 0 });
                            console.log('Thread reply and history verified:', thread.posts.some(p => p.post_id === reply.post_id));
                            await api('SYNO.Chat.Post.Reaction', 'set', 1, { post_id: result.post_id, sticker_name: 'thumbsup' });
                            console.log('Thumbs-up reaction request accepted.');
                            await api('SYNO.Chat.Post', 'delete', 8, { post_id: reply.post_id, real_delete: false });
                            console.log('Own synthetic reply soft-deleted.');
                        }
                    }
                }
            } else console.log('Control packet:', packet.slice(0, 2));
        } catch (error) { console.log(error.message.startsWith('API rejected request:') ? error.message : 'Probe request or frame failed; no automatic resend.'); ws.close(); }
    });
    ws.on('error', () => console.log('Socket error (details suppressed).'));
    ws.on('close', code => { clearTimeout(timeout); clearInterval(heartbeat); console.log('Socket closed:', code); });
}
main().catch(error => { console.error(error.message.startsWith('API rejected') || error.message.includes('Peter') || error.message === 'Cannot identify current user.' ? error.message : 'Probe failed; details suppressed to protect credentials.'); process.exitCode = 1; });
