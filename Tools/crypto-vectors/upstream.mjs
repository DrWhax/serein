// Signal-Desktop's own modules, loaded unmodified (through hooks.mjs), and the helpers the
// vector generator and the reverse check share.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { transform } from 'esbuild';

export const desktop = new URL('../../Signal-Desktop/', import.meta.url);
export const up = path => import(new URL(path, desktop).href);

const { Environment, setEnvironment } = await up('ts/environment.std.ts');
setEnvironment(Environment.Test, false); // permits upstream's test-only fixed IVs

export const C = await up('ts/Crypto.node.ts');
export const A = await up('ts/AttachmentCrypto.node.ts');
export const { CipherType } = await up('ts/types/Crypto.std.ts');
export const { logPadSize } = await up('ts/util/logPadSize.std.ts');
export const { getAesCbcCiphertextSize, getAttachmentCiphertextSize } = await up('ts/util/AttachmentCrypto.std.ts');
export const { MediaTier } = await up('ts/types/AttachmentDownload.std.ts');
export const { default: ProvisioningCipher } = await up('ts/textsecure/ProvisioningCipher.node.ts');
export const { SignalService: Proto } = await up('ts/protobuf/index.std.ts');

// Functions that live in modules too entangled to import (Electron, the whole message
// pipeline): the upstream source text itself is cut out, transpiled and evaluated.
export async function extract(path, start, end, name, rewrite = text => text) {
  const source = readFileSync(new URL(path, desktop), 'utf8');
  const from = source.indexOf(start);
  const to = source.indexOf(end, from);
  if (from < 0 || to < 0) throw new Error(`extract: markers not found in ${path}`);
  const { code } = await transform(rewrite(source.slice(from, to)), { loader: 'ts' });
  return new Function(`${code}\nreturn ${name};`)();
}
export const padMessage = await extract('ts/textsecure/OutgoingMessage.preload.ts', 'const PADDING_BLOCK', 'export default class', 'padMessage',
  text => text.replace('export function', 'function'));
// A private method: `#unpad(…) {…}` becomes `function unpad(…) {…}`.
export const unpad = await extract('ts/textsecure/MessageReceiver.preload.ts', '#unpad(paddedPlaintext', 'async #decryptSealedSender', 'unpad',
  text => `function ${text.slice(1)}`);

// MARK: helpers

export const hex = bytes => Buffer.from(bytes).toString('hex');
export const utf8 = s => new Uint8Array(Buffer.from(s, 'utf8'));
export const cat = (...parts) => new Uint8Array(Buffer.concat(parts.map(p => Buffer.from(p))));
/** Deterministic test bytes: SHA-256(label ‖ counter) stream. */
export function det(label, length) {
  const out = Buffer.alloc(length);
  for (let i = 0, block = 0; i < length; block += 1) {
    const h = createHash('sha256').update(`${label}:${block}`).digest();
    i += h.copy(out, i, 0, Math.min(32, length - i));
  }
  return new Uint8Array(out);
}
/** The plaintext pattern UpstreamVectorTests regenerates for large attachments. */
export function pattern(size) {
  const out = new Uint8Array(size);
  for (let i = 0; i < size; i += 1) out[i] = (i * 131 + (i >>> 8) * 17 + 89) & 0xff;
  return out;
}
/** Runs the oracle and records whether it accepted. */
export function verdict(fn) {
  try {
    return { ok: true, ...fn() };
  } catch (error) {
    return { ok: false, error: String(error.message).slice(0, 80) };
  }
}
/** A clamped X25519 scalar (upstream warns about unclamped private keys). */
export function scalar(label) {
  const k = det(label, 32);
  k[0] &= 248; k[31] &= 127; k[31] |= 64;
  return k;
}
export function flip(bytes, index) {
  const out = new Uint8Array(bytes);
  out[(index + out.length) % out.length] ^= 0x01;
  return out;
}

/** The bytes of a hex string. */
export const unhex = text => new Uint8Array(Buffer.from(text, 'hex'));

/**
 * A ProvisioningCipher whose key pair is `privateKey`: upstream generates it internally, so
 * it is pinned at the libsignal boundary for the one call that creates it.
 */
export function provisioningCipher(PrivateKey, privateKey) {
  const cipher = new ProvisioningCipher();
  const generate = PrivateKey.generate;
  PrivateKey.generate = () => privateKey;
  try { cipher.getPublicKey(); } finally { PrivateKey.generate = generate; }
  if (hex(cipher.getPublicKey().serialize()) !== hex(privateKey.getPublicKey().serialize())) throw new Error('could not pin the provisioning key pair');
  return cipher;
}

