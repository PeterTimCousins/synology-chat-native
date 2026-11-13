// Synthetic-only wire-format fixtures. Never load account/session data here.
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const sodium = require('../reference/synology-chat/cache/crypto-interop/node_modules/libsodium-wrappers');
await sodium.ready;
const fixturePath = fileURLToPath(new URL('../Tests/SynologyChatNativeTests/Fixtures/ChatCrypto.json', import.meta.url));
const b64 = bytes => sodium.to_base64(bytes, sodium.base64_variants.ORIGINAL);
const wrapped64 = bytes => b64(bytes).match(/.{1,76}/g).join('\r\n');
const un64 = text => sodium.from_base64(text.replace(/\s/g, ''), sodium.base64_variants.ORIGINAL);
const join = (a, b) => new Uint8Array([...a, ...b]);
const open = (bytes, key) => sodium.crypto_secretbox_open_easy(bytes.subarray(24), bytes.subarray(0,24), key);
if (process.argv[2] === '--verify-native-invitations') {
    const native = JSON.parse(fs.readFileSync(process.argv[3]));
    assert.equal(native.synthetic_only, true);
    assert.deepEqual(native.user_ids, [20, 30]);
    assert.equal(native.envelopes.length, 2);
    assert.equal(native.public_keys.length, 2);
    assert.equal(native.private_keys.length, 2);
    for (let index = 0; index < 2; index++) {
        const opened = sodium.crypto_box_seal_open(un64(native.envelopes[index]), un64(native.public_keys[index]), un64(native.private_keys[index]));
        assert.equal(sodium.to_string(opened), native.channel_key);
        const wrong = 1 - index;
        assert.throws(() => sodium.crypto_box_seal_open(un64(native.envelopes[index]), un64(native.public_keys[wrong]), un64(native.private_keys[wrong])));
    }
    assert.notEqual(native.envelopes[0], native.envelopes[1]);
    console.log('JavaScript verified two native invitation envelopes in recipient order; each wrong recipient fails. Synthetic keys only.');
} else if (process.argv[2] === '--verify-native') {
    const fixture = JSON.parse(fs.readFileSync(fixturePath));
    const native = JSON.parse(fs.readFileSync(process.argv[3]));
    const key = un64(fixture.channelKey);
    assert.equal(sodium.to_string(open(un64(native.message), key)), fixture.message);
    assert.equal(sodium.to_string(open(sodium.from_hex(native.filename), key)), fixture.filename);
    assert.equal(b64(open(un64(native.attachment), key)), fixture.attachment);
    const passwordKey = sodium.crypto_generichash(32, sodium.from_string(fixture.password));
    assert.equal(sodium.to_string(open(un64(native.privateKey), passwordKey)), fixture.privateKey);
    assert.equal(sodium.to_string(sodium.crypto_box_seal_open(un64(native.channelKey), un64(fixture.publicKey), un64(fixture.privateKey))), fixture.channelKey);
    console.log('JavaScript verified all five native encryption outputs: message, filename, attachment, wrapped private key and sealed channel key.');
} else if (process.argv[2] === '--generate') {
    const pair = sodium.crypto_box_seed_keypair(Uint8Array.from({length:32},(_,i)=>i));
    const channel = Uint8Array.from({length:32},(_,i)=>i+32);
    const password = 'Synthetic encryption password — not an account credential';
    const passwordKey = sodium.crypto_generichash(32,sodium.from_string(password));
    const seal = (bytes,key,offset) => {
        const nonce = Uint8Array.from({length:24},(_,i)=>i+offset);
        return join(nonce,sodium.crypto_secretbox_easy(bytes,nonce,key));
    };
    const message = 'Synthetic encrypted message — café 👋\n' + 'Interoperability text. '.repeat(8);
    const filename = 'synthetic report — café.png';
    const attachment = Uint8Array.from({length:256},(_,i)=>i);
    const fixture = {
        generator:'libsodium-wrappers 0.8.4; synthetic keys only; fixed nonces are fixture-only',
        password,privateKey:b64(pair.privateKey),publicKey:b64(pair.publicKey),channelKey:b64(channel),
        wrappedPrivateKey:wrapped64(seal(sodium.from_string(b64(pair.privateKey)),passwordKey,1)),
        wrappedChannelKey:wrapped64(sodium.crypto_box_seal(sodium.from_string(b64(channel)),pair.publicKey)),
        message,encryptedMessage:wrapped64(seal(sodium.from_string(message),channel,31)),
        filename,encryptedFilename:sodium.to_hex(seal(sodium.from_string(filename),channel,61)),
        attachment:b64(attachment),encryptedAttachment:wrapped64(seal(attachment,channel,91))
    };
    fs.writeFileSync(fixturePath,JSON.stringify(fixture,null,2)+'\n');
    console.log('Wrote synthetic JavaScript encryption interoperability fixture.');
} else {
    console.error('Use --generate, --verify-native PATH or --verify-native-invitations PATH.'); process.exitCode=1;
}
