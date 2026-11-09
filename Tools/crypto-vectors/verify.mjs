// The other direction: what the Swift port encrypted, read by Signal-Desktop's own code.
//
// UpstreamVectorTests' `exportsForUpstream` writes its ciphertexts to a file (when
// CRYPTO_VECTORS_EXPORT names one); this decrypts each with upstream's unmodified functions
// and compares with the plaintext Swift says it encrypted. Any mismatch is an exit code 1.
//
//   node --no-warnings --import ./register.mjs verify.mjs <swift-export.json>

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Readable, Writable } from 'node:stream';
import { PrivateKey, PublicKey } from '@signalapp/libsignal-client';
import { A, C, Proto, hex, unhex, unpad, provisioningCipher } from './upstream.mjs';

const input = JSON.parse(readFileSync(process.argv[2], 'utf8'));
let checks = 0;
const failures = [];
function check(what, actual, expected) {
  checks += 1;
  if (JSON.stringify(actual) !== JSON.stringify(expected)) failures.push(`${what}: upstream read ${JSON.stringify(actual)}, Swift encrypted ${JSON.stringify(expected)}`);
}
function attempt(what, fn) {
  try { return fn(); } catch (error) { checks += 1; failures.push(`${what}: upstream refused it (${error.message})`); return undefined; }
}
const text = bytes => Buffer.from(bytes).toString('utf8');

// Device names (decryptDeviceName).
{
  const identity = PrivateKey.deserialize(Buffer.from(unhex(input.deviceName.identityPrivateKey)));
  for (const c of input.deviceName.cases) {
    attempt(`device name ${JSON.stringify(c.name)}`, () => {
      const proto = Proto.DeviceName.decode(unhex(c.proto));
      const name = C.decryptDeviceName(
        { ephemeralPublic: PublicKey.deserialize(Buffer.from(proto.ephemeralPublic)), syntheticIv: proto.syntheticIv, ciphertext: proto.ciphertext }, identity);
      check(`device name ${JSON.stringify(c.name)}`, name, c.name);
    });
  }
}

// Profile names (decryptProfileName) and the padded length upstream would have chosen.
{
  const key = unhex(input.profile.profileKey);
  for (const c of input.profile.names) {
    attempt(`profile name ${JSON.stringify(c.given)}`, () => {
      const { given, family } = C.decryptProfileName(Buffer.from(unhex(c.encrypted)).toString('base64'), key);
      check(`profile name ${JSON.stringify(c.given)}`, [text(given), family == null ? null : text(family)], [c.given, c.family]);
      const raw = Buffer.from(c.family == null ? c.given : `${c.given}\0${c.family}`, 'utf8');
      check(`profile name length ${JSON.stringify(c.given)}`, unhex(c.encrypted).length, C.encryptProfileItemWithPadding(new Uint8Array(raw), key, C.PaddedLengths.Name).length);
    });
  }
}

// Sticker pack uploads (deriveStickerPackKey + decryptAttachmentV1).
for (const c of input.stickers.cases) {
  attempt('sticker', () => check(`sticker of ${c.plaintext.length / 2} bytes`,
    hex(C.decryptAttachmentV1(unhex(c.blob), C.deriveStickerPackKey(unhex(input.stickers.packKey)))), c.plaintext));
}

// Storage service items and manifest (deriveStorage…Key + decryptProfile, as storage.preload does).
{
  const storageServiceKey = unhex(input.storage.storageKey);
  for (const c of input.storage.items) {
    attempt('storage item', () => {
      const key = C.deriveStorageItemKey({ storageServiceKey, recordIkm: c.recordIkm ? unhex(c.recordIkm) : undefined, key: unhex(c.raw) });
      const record = Proto.StorageRecord.decode(C.decryptProfile(unhex(c.value), key));
      check(`storage item (${c.recordIkm ? 'recordIkm' : 'legacy'} key)`, record.record?.contact?.note, c.note);
    });
  }
  attempt('storage manifest', () => {
    const key = C.deriveStorageManifestKey(storageServiceKey, BigInt(input.storage.manifest.version));
    check('storage manifest', hex(C.decryptProfile(unhex(input.storage.manifest.value), key)), input.storage.manifest.plaintext);
  });
}

// Provisioning envelope (ProvisioningCipher.decrypt).
attempt('provisioning envelope', () => {
  const p = input.provisioning;
  const cipher = provisioningCipher(PrivateKey, PrivateKey.deserialize(Buffer.from(unhex(p.recipientPrivateKey))));
  const result = cipher.decrypt(Proto.ProvisionEnvelope.decode(unhex(p.envelope)));
  check('provisioning envelope', [result.aci, result.number, result.provisioningCode, hex(result.aciKeyPair.privateKey.serialize())],
    [p.aci, p.number, p.provisioningCode, p.aciPrivateKey]);
});

// Transport padding (unpad).
for (const c of input.padding) attempt('padding', () => check(`padding of ${c.plaintext.length / 2} bytes`, hex(unpad(unhex(c.padded))), c.plaintext));

// Attachments (the streaming decryptAttachmentV2, with digest and incremental MAC).
for (const c of input.attachments) {
  const chunks = [];
  const sink = new Writable({ write(chunk, _enc, done) { chunks.push(Buffer.from(chunk)); done(); } });
  const keys = unhex(c.keys);
  try {
    await A.decryptAttachmentV2ToSink({
      idForLogging: 'swift', size: c.size, ciphertextStream: Readable.from([Buffer.from(unhex(c.blob))]), type: 'standard',
      theirIncrementalMac: c.incrementalMac ? unhex(c.incrementalMac) : undefined, theirChunkSize: c.chunkSize ?? undefined,
      integrityCheck: { type: 'encrypted', digest: unhex(c.digest) }, aesKey: keys.subarray(0, 32), macKey: keys.subarray(32, 64),
    }, sink);
    check(`attachment of ${c.size} bytes`, createHash('sha256').update(Buffer.concat(chunks)).digest('hex'), c.plaintextSha256);
  } catch (error) {
    checks += 1;
    failures.push(`attachment of ${c.size} bytes: upstream refused it (${error.message})`);
  }
}

if (failures.length > 0) {
  console.error(failures.map(f => `FAILED ${f}`).join('\n'));
  process.exit(1);
}
console.log(`upstream read all ${checks} Swift outputs`);
