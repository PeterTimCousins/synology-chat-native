// Pure read-only contract probe. Inject transport; never retain message text.
export function assertThreadWindowRead(name, method) {
    const allowed = {'SYNO.Chat.User':'list','SYNO.Chat.Channel':'list','SYNO.Chat.Channel.Member':'get','SYNO.Chat.Post':'list'};
    if (allowed[name] !== method) throw new Error('Thread-window probe rejected a non-read operation.');
}

const positive = value => Number.isSafeInteger(value) && value > 0;
const shape = post => ({post_id:post.post_id,type:post.type,creator_id:post.creator_id});

function validate(posts, rootID, limit, rootOnly = false) {
    if (!Array.isArray(posts)) throw new Error('Thread-window response has no posts array.');
    const seen = new Set(), replies = [], echoes = [];
    for (const post of posts) {
        if (!post || !positive(post.post_id) || seen.has(post.post_id) || post.channel_id !== 93 ||
            ![6,10].includes(post.creator_id) || typeof post.type !== 'string' || !post.type ||
            post.type.length > 64) throw new Error('Thread-window response identity or scope mismatch.');
        seen.add(post.post_id);
        if (post.post_id === rootID) {
            if (post.thread_id != null && post.thread_id !== 0 && post.thread_id !== rootID) throw new Error('Thread-window root membership mismatch.');
            echoes.push(post);
        } else {
            if (rootOnly || post.thread_id !== rootID) throw new Error('Thread-window reply membership mismatch.');
            replies.push(post);
        }
    }
    if (replies.length > limit || echoes.length > 1 || (rootOnly && echoes.length !== 1)) throw new Error('Thread-window response exceeds its bound or omits root.');
    return {posts, replies, echoes};
}

function summary(page, anchor) {
    const ids = page.replies.map(p => p.post_id);
    return {rows:page.replies.map(shape),raw_order:page.posts.map(p=>p.post_id),reply_count:ids.length,
        root_echo:page.echoes.map(shape),anchor_included:ids.includes(anchor),
        before_ids:ids.filter(id=>id < anchor),after_ids:ids.filter(id=>id > anchor)};
}

export async function inspectThreadWindow({api,scopeHash,roots = [399431958799,399431958735],now = () => new Date()}) {
    if (!/^[a-f0-9]{64}$/.test(scopeHash) || !Array.isArray(roots) || roots.length < 1 || roots.length > 2 ||
        new Set(roots).size !== roots.length || !roots.every(positive)) throw new Error('Invalid bounded thread-window probe scope.');
    async function read(params) {
        assertThreadWindowRead('SYNO.Chat.Post','list');
        const result = await api('SYNO.Chat.Post','list',5,{channel_id:93,...params});
        return result?.posts;
    }
    const inspected = [];
    let selected;
    for (const rootID of roots) {
        const root = validate(await read({post_id:rootID,prev_count:0,next_count:0}),rootID,0,true);
        const latest = validate(await read({thread_id:rootID,prev_count:30,next_count:0}),rootID,31);
        inspected.push({root_id:rootID,root:root.echoes.map(shape),latest_rows:latest.replies.map(shape),latest_root_echo:latest.echoes.map(shape),latest_raw_order:latest.posts.map(p=>p.post_id)});
        const sorted = [...latest.replies].sort((a,b)=>a.post_id-b.post_id);
        // Prefer a central reply with two known neighbors on both sides so
        // count semantics are witnessed, rather than inferred at a boundary.
        const candidates = sorted.slice(1,-1).map(p=>({post:p,index:sorted.indexOf(p)}));
        const fullSides = candidates.filter(x=>x.index >= 2 && x.index < sorted.length-2);
        const middle = (fullSides.length ? fullSides : candidates).sort((a,b)=>Math.abs(a.index-(sorted.length-1)/2)-Math.abs(b.index-(sorted.length-1)/2));
        const anchor = (middle.find(x=>x.post.type === 'normal') ?? middle[0])?.post;
        if (anchor) {
            const index = sorted.findIndex(p=>p.post_id === anchor.post_id);
            selected = {rootID,anchor,before:sorted[index-1],after:sorted[index+1],beforeIDs:sorted.slice(Math.max(0,index-2),index).map(p=>p.post_id),afterIDs:sorted.slice(index+1,index+3).map(p=>p.post_id)};break;
        }
    }
    const base = {scope_sha256:scopeHash,channel_id:93,inspected_roots:inspected,verified_at:now().toISOString()};
    if (!selected) return {...base,status:'insufficient_neighbors'};
    const {rootID,anchor,before,after,beforeIDs,afterIDs} = selected;
    const windows = {};
    for (const [key,prev,next] of [['exact',0,0],['both',2,2],['previous',2,0],['following',0,2]]) {
        const page = validate(await read({thread_id:rootID,post_id:anchor.post_id,prev_count:prev,next_count:next}),rootID,prev+next+1);
        if (page.replies.filter(p=>p.post_id < anchor.post_id).length > prev || page.replies.filter(p=>p.post_id > anchor.post_id).length > next) throw new Error('Thread-window directional response exceeds its bound.');
        if (page.replies.some(p=>p.post_id === anchor.post_id && (p.creator_id !== anchor.creator_id || p.type !== anchor.type))) throw new Error('Thread-window anchor identity changed.');
        windows[key] = summary(page,anchor.post_id);
    }
    const checks = {
        exact_anchor:windows.exact.anchor_included,
        previous_witness:windows.previous.before_ids.includes(before.post_id),
        following_witness:windows.following.after_ids.includes(after.post_id),
        both_before_witness:windows.both.before_ids.includes(before.post_id),
        both_after_witness:windows.both.after_ids.includes(after.post_id),
        exact_has_no_neighbors:windows.exact.before_ids.length === 0 && windows.exact.after_ids.length === 0,
        previous_has_no_following:windows.previous.after_ids.length === 0,
        following_has_no_previous:windows.following.before_ids.length === 0,
        previous_requested_count_witnessed:beforeIDs.every(id=>windows.previous.before_ids.includes(id)),
        following_requested_count_witnessed:afterIDs.every(id=>windows.following.after_ids.includes(id)),
        both_requested_counts_witnessed:beforeIDs.every(id=>windows.both.before_ids.includes(id)) && afterIDs.every(id=>windows.both.after_ids.includes(id))
    };
    return {...base,status:Object.values(checks).every(Boolean) ? 'verified_directional_witnesses' : 'unverified_directional_witnesses',
        root_id:rootID,anchor:shape(anchor),nearest_before:shape(before),nearest_after:shape(after),known_before_ids:beforeIDs,known_after_ids:afterIDs,
        full_two_sided_count_witness:beforeIDs.length === 2 && afterIDs.length === 2 && Object.values(checks).every(Boolean),windows,checks};
}
