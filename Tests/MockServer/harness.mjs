// SignalSafe integration-test harness around Signal's mock server: upstream's in-tree
// Signal-Desktop/packages/mock-server (the server Signal Desktop's own ts/test-mock suite
// uses), built into .mock-server by Tools/build-mock-server.sh.
//
// Protocol: one JSON object per line.
//   stdout first line:  {"event":"ready", port, certificateAuthority, serverTrustRoots, serverPublicParams, phone, alice}
//   stdin:  {"id":N, "cmd":..., ...args}      stdout: {"id":N, "ok":true, "result":...} | {"id":N, "ok":false, "error":...}
// The process exits when stdin closes.

import { createInterface } from 'node:readline';
import https from 'node:https';
import http from 'node:http';
import net from 'node:net';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import crypto from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { Server, StorageState, loadCertificates, Proto, EMPTY_DATA_MESSAGE, ReceiptType, ServiceIdKind, Group } from '@signalapp/mock-server';
// The exact libsignal-client instance the mock server itself loaded.
const libsignal = createRequire(import.meta.resolve('@signalapp/mock-server'))('@signalapp/libsignal-client');
const { DecryptionErrorMessage, PlaintextContent, CiphertextMessageType, ServiceId, PublicKey, Fingerprint } = libsignal;
const { GroupSecretParams, GroupMasterKey } = createRequire(import.meta.resolve('@signalapp/mock-server'))('@signalapp/libsignal-client/zkgroup');


// ts/util/logPadSize.std.ts
const logPadSize = (size) => Math.max(541, Math.floor(1.05 ** Math.ceil(Math.log(size) / Math.log(1.05))));
const log = (...a) => process.stderr.write(a.join(' ') + '\n');
const out = (o) => process.stdout.write(JSON.stringify(o, (_, v) => (typeof v === 'bigint' ? Number(v) : v)) + '\n');

const certs = await loadCertificates();
const cdn3Path = mkdtempSync(join(tmpdir(), 'signalsafe-cdn3-'));
process.on('exit', () => { try { rmSync(cdn3Path, { recursive: true, force: true }); } catch {} });
const server = new Server({ cdn3Path });
await server.listen(0);
const { port } = server.address();
// alice first, so the phone's contact-sync blob can list her (as in Desktop's test bootstrap).
const alice = await server.createPrimaryDevice({ profileName: 'Alice' });
const phone = await server.createPrimaryDevice({ profileName: 'Phone', contacts: [alice] });
let desktop = null;  // the linked device under test
let lastStorageState = null;
let previewProxy = null, previewRoutes = {}, previewConnects = [], previewRequests = [];
// A phone-side storage write on top of the server's current state (the desktop may have
// written since), deleting the keys it replaces.
async function phoneStorageWrite(change) {
  const base = (await phone.getStorageState()) ?? lastStorageState;
  const next = await phone.setStorageState(change(base), base);
  lastStorageState = next;
  return next;
}

const accounts = { phone, alice };
const groups = new Map();   // id → mock Group (latest revision seen by the harness)

// PrimaryDevice has no queue for typing indicators, and its message/receipt queues report the
// *inner* message type of a sealed-sender envelope. Both are recorded from its decrypt step:
// the outermost decrypt call sees the envelope type as delivered by the server.
const typingQueues = new Map();
const outerTypes = new Map();  // name -> { message: [], receipt: [] }, FIFO in queue order
function instrumentTyping(name, primary) {
  const queue = [];
  const outer = { message: [], receipt: [] };
  typingQueues.set(name, queue);
  outerTypes.set(name, outer);
  const decrypt = primary.decrypt.bind(primary);
  let depth = 0;
  primary.decrypt = async (...args) => {
    const envelopeType = args[2];
    depth += 1;
    let result;
    try { result = await decrypt(...args); } finally { depth -= 1; }
    if (depth > 0) return result;
    const c = result?.content?.content;
    if (c?.typingMessage) {
      queue.push({ source: result.unsealedSource?.aci, action: c.typingMessage.action, timestamp: Number(c.typingMessage.timestamp), envelopeType });
    }
    if (c?.dataMessage) outer.message.push(envelopeType);
    if (c?.receiptMessage) outer.receipt.push(envelopeType);
    return result;
  };
}
instrumentTyping('phone', phone);
instrumentTyping('alice', alice);

const withTimeout = (promise, ms, what) =>
  Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms))]);
const b64 = (bytes) => (bytes == null ? null : Buffer.from(bytes).toString('base64'));
const aciFromBinary = (bytes) => (bytes?.length ? ServiceId.parseFromServiceIdBinary(Buffer.from(bytes)).getServiceIdString() : null);
const summarizeSync = (sync) => {
  const c = sync.content ?? {};
  const kind = Object.keys(c).find((k) => c[k] != null)
    ?? (sync.read?.length ? 'read' : sync.viewed?.length ? 'viewed' : sync.stickerPackOperation?.length ? 'stickerPackOperation' : 'empty');
  const out = { kind };
  if (sync.stickerPackOperation?.length) {
    out.stickerPackOperation = sync.stickerPackOperation.map((o) => ({
      packId: Buffer.from(o.packId).toString('hex'), packKey: b64(o.packKey), type: o.type === Proto.SyncMessage.StickerPackOperation.Type.INSTALL ? 'install' : 'remove' }));
  }
  if (sync.read?.length) out.read = sync.read.map((r) => ({ senderAci: aciFromBinary(r.senderAciBinary) ?? r.senderAci, timestamp: Number(r.timestamp) }));
  if (sync.viewed?.length) out.viewed = sync.viewed.map((r) => ({ senderAci: aciFromBinary(r.senderAciBinary) ?? r.senderAci, timestamp: Number(r.timestamp) }));
  if (c.sent) {
    out.sent = {
      destination: aciFromBinary(c.sent.destinationServiceIdBinary) ?? c.sent.destinationServiceId,
      timestamp: Number(c.sent.timestamp),
      body: c.sent.message?.body ?? null,
      sticker: c.sent.message?.sticker ? { packId: Buffer.from(c.sent.message.sticker.packId).toString('hex'), stickerId: c.sent.message.sticker.stickerId } : null,
      unidentified: (c.sent.unidentifiedStatus ?? []).map((u) => u.unidentified === true),
    };
  }
  if (c.request) out.requestType = c.request.type;
  if (c.callEvent) {
    out.callEvent = { conversationId: b64(c.callEvent.conversationId), callId: String(c.callEvent.callId), type: c.callEvent.type,
      direction: c.callEvent.direction, event: c.callEvent.event, timestamp: Number(c.callEvent.timestamp) };
  }
  if (c.callLinkUpdate) out.callLinkUpdate = { rootKey: b64(c.callLinkUpdate.rootKey), adminPasskey: c.callLinkUpdate.adminPasskey ? b64(c.callLinkUpdate.adminPasskey) : null };
  if (c.callLogEvent) out.callLogEvent = { type: c.callLogEvent.type, timestamp: Number(c.callLogEvent.timestamp) };
  return out;
};

// Specs → DataMessage fields; a target author is an account name or an ACI string.
const aciBin = (x) => (x == null ? null : accounts[x] ? Buffer.from(accounts[x].device.aciRawUuid) : Buffer.from(String(x).replace(/-/g, ''), 'hex'));
function buildDataMessage(spec, timestamp) {
  const m = { ...dataMessage(spec.body ?? '', timestamp) };
  if (spec.groupId) {
    const g = groups.get(spec.groupId);
    m.groupV2 = { masterKey: g.masterKey, revision: g.revision, groupChange: null };
  }
  const T = (t) => BigInt(t);
  if (spec.reaction) m.reaction = { emoji: spec.reaction.emoji ?? null, remove: !!spec.reaction.remove, targetAuthorAci: null,
    targetAuthorAciBinary: aciBin(spec.reaction.targetAuthor), targetSentTimestamp: T(spec.reaction.targetSentTimestamp) };
  if (spec.delete) m.delete = { targetSentTimestamp: T(spec.delete.targetSentTimestamp) };
  if (spec.adminDelete) m.adminDelete = { targetAuthorAciBinary: aciBin(spec.adminDelete.targetAuthor), targetSentTimestamp: T(spec.adminDelete.targetSentTimestamp) };
  if (spec.pollCreate) m.pollCreate = { question: spec.pollCreate.question, allowMultiple: !!spec.pollCreate.allowMultiple, options: spec.pollCreate.options };
  if (spec.pollVote) m.pollVote = { targetAuthorAciBinary: aciBin(spec.pollVote.targetAuthor), targetSentTimestamp: T(spec.pollVote.targetSentTimestamp),
    optionIndexes: spec.pollVote.optionIndexes, voteCount: spec.pollVote.voteCount };
  if (spec.pollTerminate) m.pollTerminate = { targetSentTimestamp: T(spec.pollTerminate.targetSentTimestamp) };
  if (spec.pinMessage) m.pinMessage = { targetAuthorAciBinary: aciBin(spec.pinMessage.targetAuthor), targetSentTimestamp: T(spec.pinMessage.targetSentTimestamp),
    pinDuration: spec.pinMessage.seconds ? { pinDurationSeconds: spec.pinMessage.seconds } : { pinDurationForever: true } };
  if (spec.unpinMessage) m.unpinMessage = { targetAuthorAciBinary: aciBin(spec.unpinMessage.targetAuthor), targetSentTimestamp: T(spec.unpinMessage.targetSentTimestamp) };
  if (spec.isViewOnce) m.isViewOnce = true;
  if (spec.expireTimer != null) { m.expireTimer = spec.expireTimer; m.expireTimerVersion = spec.expireTimerVersion ?? 1; }
  if (spec.flags != null) m.flags = spec.flags;
  return m;
}
const summarizeData = (d) => ({
  reaction: d.reaction ? { emoji: d.reaction.emoji ?? null, remove: !!d.reaction.remove, targetSentTimestamp: Number(d.reaction.targetSentTimestamp),
    targetAuthor: aciFromBinary(d.reaction.targetAuthorAciBinary) } : null,
  delete: d.delete ? { targetSentTimestamp: Number(d.delete.targetSentTimestamp) } : null,
  adminDelete: d.adminDelete ? { targetSentTimestamp: Number(d.adminDelete.targetSentTimestamp), targetAuthor: aciFromBinary(d.adminDelete.targetAuthorAciBinary) } : null,
  pollCreate: d.pollCreate ? { question: d.pollCreate.question, options: d.pollCreate.options, allowMultiple: !!d.pollCreate.allowMultiple } : null,
  pollVote: d.pollVote ? { optionIndexes: d.pollVote.optionIndexes, voteCount: d.pollVote.voteCount, targetSentTimestamp: Number(d.pollVote.targetSentTimestamp) } : null,
  pollTerminate: d.pollTerminate ? { targetSentTimestamp: Number(d.pollTerminate.targetSentTimestamp) } : null,
  pinMessage: d.pinMessage ? { targetSentTimestamp: Number(d.pinMessage.targetSentTimestamp) } : null,
  unpinMessage: d.unpinMessage ? { targetSentTimestamp: Number(d.unpinMessage.targetSentTimestamp) } : null,
  isViewOnce: !!d.isViewOnce, expireTimer: d.expireTimer ?? null, expireTimerVersion: d.expireTimerVersion ?? null, flags: d.flags ?? null,
});
const account = (name) => {
  const a = accounts[name ?? 'alice'];
  if (!a) throw new Error(`unknown account ${name}`);
  return a;
};
const wrap = (content) => ({ content, senderKeyDistributionMessage: null, pniSignatureMessage: null });
const dataMessage = (body, timestamp) => ({ ...EMPTY_DATA_MESSAGE, body, groupV2: null, timestamp: BigInt(timestamp) });
const needDesktop = () => {
  if (!desktop) throw new Error('not linked yet');
  return desktop;
};

const commands = {
  async provision({ url }) {
    const pending = await server.waitForProvision();
    desktop = await pending.complete({ provisionURL: url, primaryDevice: phone });
    // As Signal Desktop's test bootstrap does: the phone and each contact open a session
    // to the new device from one of its uploaded one-time keys.
    await phone.addSingleUseKey(desktop, await desktop.popSingleUseKey());
    await alice.addSingleUseKey(desktop, await desktop.popSingleUseKey(ServiceIdKind.ACI), ServiceIdKind.ACI);
    return { deviceId: desktop.deviceId, aci: desktop.aci, pni: desktop.pni ?? null, number: desktop.number ?? null };
  },
  // Server-side view of the linked device's uploaded keys.
  async keyCounts() {
    const d = needDesktop();
    return {
      aci: { preKeys: await d.getPreKeyCount(ServiceIdKind.ACI), kyberPreKeys: await d.getKyberPreKeyCount(ServiceIdKind.ACI) },
      pni: d.pni ? { preKeys: await d.getPreKeyCount(ServiceIdKind.PNI), kyberPreKeys: await d.getKyberPreKeyCount(ServiceIdKind.PNI) } : null,
    };
  },
  async sendText({ from, text, timestamp, sealed = false, distributionId, withProfileKey = false }) {
    await account(from).sendText(needDesktop(), text, { timestamp, sealed, distributionId, withProfileKey });
    return {};
  },
  // Attachment v2 as upstream Desktop does it (ts/AttachmentCrypto.node.ts), written
  // independently here: zero padding to logPadSize, AES-256-CBC, HMAC-SHA256, SHA-256 digest.
  async fetchAndDecryptAttachment({ cdnKey, key, digest, size }) {
    const blob = readFileSync(join(cdn3Path, 'attachments', cdnKey));
    const keys = Buffer.from(key, 'base64');
    const aesKey = keys.subarray(0, 32), macKey = keys.subarray(32);
    if (!crypto.createHash('sha256').update(blob).digest().equals(Buffer.from(digest, 'base64'))) throw new Error('bad digest');
    const body = blob.subarray(0, blob.length - 32);
    if (!crypto.createHmac('sha256', macKey).update(body).digest().equals(blob.subarray(blob.length - 32))) throw new Error('bad mac');
    const decipher = crypto.createDecipheriv('aes-256-cbc', aesKey, body.subarray(0, 16));
    const padded = Buffer.concat([decipher.update(body.subarray(16)), decipher.final()]);
    return { plaintext: padded.subarray(0, size).toString('base64'), paddedLength: padded.length, logPadSize: logPadSize(size) };
  },
  // A sticker pack on CDN 0, encrypted as upstream's sticker creator does (encryptAttachmentV1
  // under HKDF(packKey, 0^32, "Sticker Pack")). `images` are base64; ids are their indexes.
  async createStickerPack({ images, emojis = [], title = 'Test pack', author = 'Harness', corruptSticker = null }) {
    const packId = crypto.randomBytes(16), packKey = crypto.randomBytes(32);
    const keys = Buffer.from(crypto.hkdfSync('sha256', packKey, Buffer.alloc(32), Buffer.from('Sticker Pack'), 64));
    const encrypt = (plaintext) => {
      const iv = crypto.randomBytes(16);
      const cipher = crypto.createCipheriv('aes-256-cbc', keys.subarray(0, 32), iv);
      const body = Buffer.concat([iv, cipher.update(plaintext), cipher.final()]);
      return Buffer.concat([body, crypto.createHmac('sha256', keys.subarray(32)).update(body).digest()]);
    };
    const stickers = images.map((_, id) => ({ id, emoji: emojis[id] ?? '🙂' }));
    const manifest = Proto.StickerPack.encode({ title, author, cover: stickers[0], stickers });
    const blobs = images.map((b, id) => {
      const blob = encrypt(Buffer.from(b, 'base64'));
      if (id === corruptSticker) blob[blob.length - 1] ^= 1;
      return blob;
    });
    await server.storeStickerPack({ id: packId, manifest: encrypt(Buffer.from(manifest)), stickers: blobs });
    return { packId: packId.toString('hex'), packKey: packKey.toString('base64') };
  },
  async sendSticker({ from = 'alice', packId, packKey, stickerId, data, contentType = 'image/webp', timestamp }) {
    const plaintext = Buffer.from(data, 'base64');
    const keys = crypto.randomBytes(64), iv = crypto.randomBytes(16);
    const padded = Buffer.concat([plaintext, Buffer.alloc(logPadSize(plaintext.length) - plaintext.length)]);
    const cipher = crypto.createCipheriv('aes-256-cbc', keys.subarray(0, 32), iv);
    const body = Buffer.concat([iv, cipher.update(padded), cipher.final()]);
    const blob = Buffer.concat([body, crypto.createHmac('sha256', keys.subarray(32)).update(body).digest()]);
    const digest = crypto.createHash('sha256').update(blob).digest();
    const cdnKey = crypto.randomUUID();
    await server.storeAttachmentOnCdn(3, cdnKey, blob);
    const message = { ...dataMessage('', timestamp), sticker: { packId: Buffer.from(packId, 'hex'), packKey: Buffer.from(packKey, 'base64'), stickerId,
      emoji: '🙂', data: { attachmentIdentifier: { cdnKey }, cdnNumber: 3, contentType, key: keys, digest, size: plaintext.length } } };
    await account(from).sendRaw(needDesktop(), wrap({ dataMessage: message }), { timestamp });
    return {};
  },
  async sendStickerPackSync({ packId, packKey, type }) {
    await phone.sendStickerPackSync({ packId: Buffer.from(packId, 'hex'), packKey: Buffer.from(packKey, 'base64'), type, timestamp: Date.now() });
    return {};
  },
  // A web site for link previews: an HTTPS server (preview-cert.pem, *.signalsafe.app, from the
  // mock CA) behind an HTTP CONNECT proxy that sends every tunnel to it and logs the targets.
  // `routes`: { "host/path": { status, headers, body (base64) } }.
  async setPreviewSite({ routes }) {
    previewRoutes = routes;
    if (!previewProxy) {
      const certsDir = join(import.meta.dirname, '.mock-server', 'certs');
      const site = https.createServer({ key: readFileSync(join(certsDir, 'key.pem')), cert: readFileSync(join(certsDir, 'preview-cert.pem')) }, (req, res) => {
        previewRequests.push({ host: req.headers.host, path: req.url, userAgent: req.headers['user-agent'] ?? null });
        const route = previewRoutes[`${(req.headers.host ?? '').split(':')[0]}${req.url}`];
        if (!route) { res.writeHead(404); res.end(); return; }
        res.writeHead(route.status ?? 200, route.headers ?? {});
        res.end(Buffer.from(route.body ?? '', 'base64'));
      });
      await new Promise((r) => site.listen(0, '127.0.0.1', r));
      const sitePort = site.address().port;
      previewProxy = http.createServer((req, res) => { res.writeHead(405); res.end(); });
      previewProxy.on('connect', (req, clientSocket, head) => {
        previewConnects.push(req.url);
        const upstream = net.connect(sitePort, '127.0.0.1', () => {
          clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
          upstream.write(head);
          upstream.pipe(clientSocket);
          clientSocket.pipe(upstream);
        });
        upstream.on('error', () => clientSocket.destroy());
        clientSocket.on('error', () => upstream.destroy());
      });
      await new Promise((r) => previewProxy.listen(0, '127.0.0.1', r));
    }
    return { proxyPort: previewProxy.address().port };
  },
  async previewLog() {
    const out = { connects: previewConnects, requests: previewRequests };
    previewConnects = []; previewRequests = [];
    return out;
  },
  async sendTextWithPreview({ from = 'alice', text, timestamp, previews }) {
    const message = { ...dataMessage(text, timestamp), preview: previews.map((p) => ({ url: p.url, title: p.title ?? null, description: p.description ?? null,
      date: p.date != null ? BigInt(p.date) : null, image: null })) };
    await account(from).sendRaw(needDesktop(), wrap({ dataMessage: message }), { timestamp });
    return {};
  },
  async sendDataMessage({ from = 'alice', timestamp, message }) {
    await account(from).sendRaw(needDesktop(), wrap({ dataMessage: buildDataMessage(message, timestamp) }), { timestamp });
    return {};
  },
  async sendEditMessage({ from = 'alice', timestamp, targetSentTimestamp, message }) {
    const editMessage = { targetSentTimestamp: BigInt(targetSentTimestamp), dataMessage: buildDataMessage(message, timestamp) };
    await account(from).sendRaw(needDesktop(), wrap({ editMessage }), { timestamp });
    return {};
  },
  // A SyncMessage from the phone: { sent: {timestamp, destination?, message?, editTarget?} } or any SyncMessage content as JSON.
  async phoneSync({ timestamp, sent = null, viewOnceOpen = null, deleteForMe = null, messageRequestResponse = null, verified = null,
                    callEvent = null, callLogEvent = null, callLinkUpdate = null }) {
    let content;
    if (callEvent) {
      const E = Proto.SyncMessage.CallEvent;
      content = { callEvent: { conversationId: Buffer.from(callEvent.conversationId, 'base64'), callId: BigInt(callEvent.callId),
        timestamp: BigInt(callEvent.timestamp), type: E.Type[callEvent.type], direction: E.Direction[callEvent.direction], event: E.Event[callEvent.event] } };
    } else if (callLogEvent) {
      content = { callLogEvent: { type: Proto.SyncMessage.CallLogEvent.Type[callLogEvent.type], timestamp: BigInt(callLogEvent.timestamp),
        conversationId: null, callId: callLogEvent.callId != null ? BigInt(callLogEvent.callId) : null } };
    } else if (callLinkUpdate) {
      content = { callLinkUpdate: { rootKey: Buffer.from(callLinkUpdate.rootKey, 'base64'),
        adminPasskey: callLinkUpdate.adminPasskey ? Buffer.from(callLinkUpdate.adminPasskey, 'base64') : null, type: 0 } };
    } else if (sent) {
      const s = { destinationServiceId: null, destinationServiceIdBinary: sent.destination ? aciBin(sent.destination) : null, timestamp: BigInt(sent.timestamp),
        expirationStartTimestamp: null, unidentifiedStatus: [], isRecipientUpdate: false, storyMessage: null, storyMessageRecipients: [], destinationE164: null };
      if (sent.editTarget != null) s.editMessage = { targetSentTimestamp: BigInt(sent.editTarget), dataMessage: buildDataMessage(sent.message, sent.timestamp) };
      else s.message = buildDataMessage(sent.message, sent.timestamp);
      content = { sent: s };
    } else if (viewOnceOpen) {
      content = { viewOnceOpen: { senderAci: null, senderAciBinary: aciBin(viewOnceOpen.sender), timestamp: BigInt(viewOnceOpen.timestamp) } };
    } else if (deleteForMe) {
      const conv = (c) => (c.groupId ? { threadGroupId: Buffer.from(c.groupId, 'base64') } : { threadServiceIdBinary: aciBin(c.serviceId) });
      const msg = (m) => ({ author: { authorServiceIdBinary: aciBin(m.author) }, sentTimestamp: BigInt(m.sentTimestamp) });
      content = { deleteForMe: {
        messageDeletes: (deleteForMe.messageDeletes ?? []).map((d) => ({ conversation: { identifier: conv(d.conversation) }, messages: d.messages.map(msg) })),
        conversationDeletes: (deleteForMe.conversationDeletes ?? []).map((d) => ({ conversation: { identifier: conv(d.conversation) },
          mostRecentMessages: d.mostRecentMessages.map(msg), mostRecentNonExpiringMessages: [], isFullDelete: !!d.isFullDelete })),
        localOnlyConversationDeletes: [], attachmentDeletes: [] } };
    } else if (messageRequestResponse) {
      const T = Proto.SyncMessage.MessageRequestResponse.Type;
      content = { messageRequestResponse: { threadAci: null, threadAciBinary: messageRequestResponse.thread ? aciBin(messageRequestResponse.thread) : null,
        groupId: messageRequestResponse.groupId ? Buffer.from(messageRequestResponse.groupId, 'base64') : null, type: T[messageRequestResponse.type] } };
    } else if (verified) {
      content = { verified: { destinationAci: null, destinationAciBinary: aciBin(verified.destination), identityKey: Buffer.from(verified.identityKey, 'base64'),
        state: Proto.Verified.State[verified.state], nullMessage: null } };
    }
    const syncMessage = { content, read: [], viewed: [], stickerPackOperation: [], padding: null };
    await phone.sendRaw(needDesktop(), wrap({ syncMessage }), { timestamp });
    return {};
  },
  async waitForEdit({ account: name = 'alice', timeout = 15000 }) {
    const e = await withTimeout(account(name).waitForEditMessage(), timeout, `edit to ${name}`);
    return { targetSentTimestamp: Number(e.editMessage.targetSentTimestamp), body: e.editMessage.dataMessage?.body ?? null,
      timestamp: Number(e.editMessage.dataMessage?.timestamp ?? 0) };
  },
  // `name`'s side of the safety number with another account (by ACI + identity key).
  async safetyNumber({ name = 'alice', otherAci, otherIdentityKey }) {
    const me = account(name);
    const f = Fingerprint.new(5200, 2, Buffer.from(me.device.aciRawUuid), me.publicKey, Buffer.from(otherAci.replace(/-/g, ''), 'hex'),
      PublicKey.deserialize(Buffer.from(otherIdentityKey, 'base64')));
    return { digits: f.displayableFingerprint().toString(), scannable: b64(f.scannableFingerprint().toBuffer()) };
  },
  async sendAttachment({ from, data, contentType, timestamp, fileName = null }) {
    const plaintext = Buffer.from(data, 'base64');
    const keys = crypto.randomBytes(64), iv = crypto.randomBytes(16);
    const padded = Buffer.concat([plaintext, Buffer.alloc(logPadSize(plaintext.length) - plaintext.length)]);
    const cipher = crypto.createCipheriv('aes-256-cbc', keys.subarray(0, 32), iv);
    const body = Buffer.concat([iv, cipher.update(padded), cipher.final()]);
    const blob = Buffer.concat([body, crypto.createHmac('sha256', keys.subarray(32)).update(body).digest()]);
    const digest = crypto.createHash('sha256').update(blob).digest();
    const cdnKey = crypto.randomUUID();
    await server.storeAttachmentOnCdn(3, cdnKey, blob);
    const message = { ...dataMessage('', timestamp),
      attachments: [{ attachmentIdentifier: { cdnKey }, cdnNumber: 3, contentType, key: keys, digest, size: plaintext.length, fileName }] };
    await account(from).sendRaw(needDesktop(), wrap({ dataMessage: message }), { timestamp });
    return { cdnKey, digest: digest.toString('base64') };
  },
  // Groups v2 (the mock primary's group helpers).
  async createGroup({ by = 'alice', title, members = ['alice', 'phone'], link = null }) {
    const inviteLinkPassword = link ? crypto.randomBytes(16) : undefined;
    const addFromInviteLink = link === 'any' ? Proto.AccessControl.AccessRequired.ANY
      : link === 'admin' ? Proto.AccessControl.AccessRequired.ADMINISTRATOR : undefined;
    const group = await account(by).createGroup({ title, members: members.map(account), addFromInviteLink, inviteLinkPassword });
    groups.set(group.id, group);
    return { id: group.id, masterKey: group.masterKey.toString('base64'), revision: group.revision,
      inviteLinkPassword: inviteLinkPassword ? inviteLinkPassword.toString('base64') : null };
  },
  async sendGroupText({ from = 'alice', groupId, text, timestamp }) {
    await account(from).sendText(needDesktop(), text, { timestamp, group: groups.get(groupId) });
    return {};
  },
  async modifyGroupTimer({ by = 'alice', groupId, seconds, timestamp }) {
    const group = await account(by).modifyGroupDisappearingMessageTimer(groups.get(groupId), seconds,
      { timestamp, sendUpdateTo: [{ device: needDesktop() }] });
    groups.set(group.id, group);
    return { revision: group.revision };
  },
  // A group someone else (Desktop) created: looked up by its master key.
  async adoptGroup({ masterKey }) {
    const secretParams = GroupSecretParams.deriveFromMasterKey(new GroupMasterKey(Buffer.from(masterKey, 'base64')));
    const serverGroup = await server.getGroup(Buffer.from(secretParams.getPublicParams().serialize()));
    if (!serverGroup) throw new Error('group not found');
    const group = new Group({ secretParams, groupState: serverGroup.state });
    groups.set(group.id, group);
    return { id: group.id, revision: group.revision };
  },
  async groupState({ by = 'alice', groupId, wait = true }) {
    let group;
    if (wait) {
      group = await account(by).waitForGroupUpdate(groups.get(groupId));
    } else {
      const known = groups.get(groupId);
      const serverGroup = await server.getGroup(Buffer.from(known.publicParams.serialize()));
      group = new Group({ secretParams: known.secretParams, groupState: serverGroup.state });
    }
    groups.set(group.id, group);
    return {
      revision: group.revision, title: group.title,
      members: group.state.members.map((m) => group.decryptServiceId(m.userId)),
      pending: (group.state.membersPendingProfileKey ?? []).map((m) => group.decryptServiceId(m.member.userId)),
      requesting: (group.state.membersPendingAdminApproval ?? []).map((m) => group.decryptServiceId(m.userId)),
    };
  },
  async addAccount({ name, profileName }) {
    if (!accounts[name]) {
      accounts[name] = await server.createPrimaryDevice({ profileName: profileName ?? name });
      instrumentTyping(name, accounts[name]);
      // A session with the linked desktop, as alice gets one at link time.
      if (desktop) await accounts[name].addSingleUseKey(desktop, await desktop.popSingleUseKey(ServiceIdKind.ACI), ServiceIdKind.ACI);
    }
    return { aci: accounts[name].device.aci };
  },
  async accountInfo({ name }) {
    const a = account(name);
    return {
      aci: a.device.aci,
      number: a.device.number ?? null,
      profileName: a.profileName,
      profileKey: b64(a.profileKey.serialize()),
      identityKey: b64(a.publicKey.serialize()),
      devices: [a.device.deviceId, ...a.secondaryDevices.map((d) => d.deviceId)],
    };
  },
  // Messages a mock account received from the linked device.
  async waitForMessage({ account: name, timeout = 15000 }) {
    const e = await withTimeout(account(name).waitForMessage(), timeout, `message to ${name}`);
    return {
      body: e.body,
      source: e.source?.aci ?? null,
      sourceDevice: e.source?.deviceId ?? null,
      envelopeType: outerTypes.get(name).message.shift() ?? e.envelopeType,
      groupId: e.dataMessage.groupV2?.masterKey ? b64(e.dataMessage.groupV2.masterKey) : null,
      innerType: e.envelopeType,
      timestamp: Number(e.dataMessage.timestamp),
      profileKey: b64(e.dataMessage.profileKey),
      ...summarizeData(e.dataMessage),
      preview: (e.dataMessage.preview ?? []).map((p) => ({ url: p.url ?? null, title: p.title ?? null, description: p.description ?? null,
        date: p.date != null ? Number(p.date) : null,
        image: p.image ? { cdnKey: p.image.attachmentIdentifier?.cdnKey ?? null, key: b64(p.image.key), digest: b64(p.image.digest), size: p.image.size ?? null,
          contentType: p.image.contentType ?? null, width: p.image.width ?? null, height: p.image.height ?? null } : null })),
      sticker: e.dataMessage.sticker ? {
        packId: Buffer.from(e.dataMessage.sticker.packId).toString('hex'), packKey: b64(e.dataMessage.sticker.packKey), stickerId: e.dataMessage.sticker.stickerId,
        emoji: e.dataMessage.sticker.emoji ?? null,
        data: { cdnKey: e.dataMessage.sticker.data?.attachmentIdentifier?.cdnKey ?? null, contentType: e.dataMessage.sticker.data?.contentType ?? null,
          size: e.dataMessage.sticker.data?.size ?? null, key: b64(e.dataMessage.sticker.data?.key), digest: b64(e.dataMessage.sticker.data?.digest),
          width: e.dataMessage.sticker.data?.width ?? null, height: e.dataMessage.sticker.data?.height ?? null } } : null,
      attachments: (e.dataMessage.attachments ?? []).map((a) => ({
        cdnKey: a.attachmentIdentifier?.cdnKey ?? null, cdnNumber: a.cdnNumber ?? null, contentType: a.contentType ?? null, size: a.size ?? null,
        key: b64(a.key), digest: b64(a.digest), incrementalMac: b64(a.incrementalMac), chunkSize: a.chunkSize ?? null,
        fileName: a.fileName ?? null, width: a.width ?? null, height: a.height ?? null, blurHash: a.blurHash ?? null,
      })),
    };
  },
  async waitForReceipt({ account: name, timeout = 15000 }) {
    const e = await withTimeout(account(name).waitForReceipt(), timeout, `receipt to ${name}`);
    const type = { [Proto.ReceiptMessage.Type.DELIVERY]: 'delivery', [Proto.ReceiptMessage.Type.READ]: 'read', [Proto.ReceiptMessage.Type.VIEWED]: 'viewed' }[e.receiptMessage.type];
    return {
      type, timestamps: (e.receiptMessage.timestamp ?? []).map(Number), source: e.source?.aci ?? null,
      envelopeType: outerTypes.get(name).receipt.shift() ?? e.envelopeType, innerType: e.envelopeType,
    };
  },
  async receiptQueueSize({ account: name }) {
    return { size: account(name).getReceiptQueueSize() };
  },
  async waitForSyncMessage({ account: name = 'phone', kind, timeout = 15000 }) {
    const e = await withTimeout(account(name).waitForSyncMessage((entry) => !kind || summarizeSync(entry.syncMessage).kind === kind), timeout, `sync ${kind ?? ''}`);
    return { source: e.source?.aci ?? null, sourceDevice: e.source?.deviceId ?? null, ...summarizeSync(e.syncMessage) };
  },
  async waitForTyping({ account: name, timeout = 15000 }) {
    const queue = typingQueues.get(name);
    const deadline = Date.now() + timeout;
    while (queue.length === 0) {
      if (Date.now() > deadline) throw new Error(`timed out waiting for typing to ${name}`);
      await new Promise((r) => setTimeout(r, 20));
    }
    const t = queue.shift();
    return { ...t, action: t.action === Proto.TypingMessage.Action.STARTED ? 'started' : 'stopped' };
  },
  // A second device on a contact's account: the next send to them gets 409 (missing device).
  async addSecondaryDevice({ account: name }) {
    const device = await server.createSecondaryDevice(account(name));
    return { deviceId: device.deviceId };
  },
  // The contact re-installs: new identity and registration ids, same ACI → 410 (stale devices).
  async reregister({ account: name }) {
    const old = account(name);
    const fresh = await server.reregisterPrimaryDevice({ aci: old.device.aci, profileName: old.profileName });
    accounts[name] = fresh;
    instrumentTyping(name, fresh);
    return { aci: fresh.device.aci, identityKey: b64(fresh.publicKey.serialize()) };
  },
  async setStorageState() {
    let state = StorageState.getEmpty();
    state = state.updateAccount({
      profileKey: phone.profileKey.serialize(),
      givenName: 'Phone',
      familyName: 'Owner',
      readReceipts: true,
      typingIndicators: true,
      linkPreviews: false,
      universalExpireTimer: 3600,
      preferredReactionEmoji: ['👍', '🫖'],
      noteToSelfMarkedUnread: true,
    });
    state = state.addContact(alice, {
      identityState: Proto.ContactRecord.IdentityState.VERIFIED,
      identityKey: alice.publicKey.serialize(),
      whitelisted: true,
      profileKey: alice.profileKey.serialize(),
      givenName: 'Alice',
      familyName: 'Liddell',
      systemGivenName: 'Ally',
      markedUnread: true,
      note: 'met at the tea party',
    });
    const group = await phone.createGroup({ title: 'Tea party', members: [phone, alice] });
    state = state.addGroup(group, { whitelisted: true, archived: true, mutedUntilTimestamp: 4102444800000n });
    state = state.pin(alice);
    state = state.pinGroup(group);
    state = await phone.setStorageState(state);
    lastStorageState = state;
    return { version: Number(state.version), groupMasterKey: b64(group.masterKey), aliceIdentityKey: b64(alice.publicKey.serialize()) };
  },
  // A later change by the phone, announced with SyncMessage.FetchLatest(STORAGE_MANIFEST).
  async updateStorageState({ archiveAlice = true }) {
    const state = await phoneStorageWrite((st) => st.updateContact(alice, { archived: archiveAlice }));
    await phone.sendFetchStorage({ timestamp: Date.now() });
    return { version: Number(state.version) };
  },
  // Every non-conversation record type, an unknown item type, and AccountRecord fields this
  // client only passes through (payments, donor, backup tier).
  async setStorageRecords() {
    const state = await phoneStorageWrite((base) => {
    let state = base;
    const T = Proto.ManifestRecord.Identifier.Type;
    const now = Date.now();
    const uuid = (s) => Buffer.from(s.replace(/-/g, ''), 'hex');
    const aliceRecipient = { identifier: { contact: { serviceIdBinary: alice.device.aciBinary } } };
    state = state.updateAccount({
      payments: { enabled: true, entropy: Buffer.alloc(32, 7) },
      donorSubscriberId: Buffer.alloc(32, 9),
      donorSubscriberCurrencyCode: 'EUR',
      backupTier: 200n,
      notificationProfileManualOverride: { override: { disabledAtTimestampMs: BigInt(now - 1000) } },
      usernameLink: { entropy: Buffer.alloc(32, 3), serverId: Buffer.alloc(16, 4), color: Proto.AccountRecord.UsernameLink.Color.GREEN },
    });
    state = state.addRecord({ type: T.STORY_DISTRIBUTION_LIST, record: { storyDistributionList: {
      identifier: uuid('2f8d8d6e-7b55-4c3b-9c1e-1a2b3c4d5e6f'), name: 'Close friends', allowsReplies: true, isBlockList: false,
      recipientServiceIdsBinary: [alice.device.aciBinary], deletedAtTimestamp: 0n } } });
    state = state.addRecord({ type: T.STICKER_PACK, record: { installedStickerPack: {
      packId: Buffer.alloc(16, 0xaa), packKey: Buffer.alloc(32, 0xbb), position: 2 } } });
    state = state.addRecord({ type: T.STICKER_PACK, record: { installedStickerPack: {
      packId: Buffer.alloc(16, 0xcc), deletedAtTimestamp: BigInt(now - 60_000) } } });
    state = state.addRecord({ type: T.FAVORITE_STICKER_PACK, record: { sticker: {
      packId: Buffer.alloc(16, 0xaa), packKey: Buffer.alloc(32, 0xbb), stickerId: 3, favoritedAtTimestamp: BigInt(now - 5000) } } });
    state = state.addRecord({ type: T.CALL_LINK, record: { callLink: {
      rootKey: Buffer.alloc(16, 0x11), deletedAtTimestampMs: BigInt(now - 120_000) } } });
    state = state.addRecord({ type: T.CHAT_FOLDER, record: { chatFolder: {
      id: uuid('6a1c3a52-0c2e-4b8e-8f00-123456789abc'), name: 'Tea', position: 1, showOnlyUnread: false, showMutedChats: true,
      includeAllIndividualChats: false, includeAllGroupChats: true, folderType: Proto.ChatFolderRecord.FolderType.CUSTOM,
      includedRecipients: [aliceRecipient], excludedRecipients: [], deletedAtTimestampMs: 0n } } });
    state = state.addRecord({ type: T.NOTIFICATION_PROFILE, record: { notificationProfile: {
      id: Buffer.alloc(16, 0x5a), name: 'Work', emoji: '💼', color: 0xff00ff00, createdAtMs: BigInt(now - 86_400_000), allowAllCalls: true,
      allowAllMentions: false, allowedMembers: [aliceRecipient], scheduleEnabled: true, scheduleStartTime: 900, scheduleEndTime: 1730,
      scheduleDaysEnabled: [1, 2, 3, 4, 5], deletedAtTimestampMs: 0n } } });
    state = state.addRecord({ type: T.HIDDEN_STICKER_PACK, record: { hiddenStickerPack: {
      packId: Buffer.alloc(16, 0xdd), packKey: Buffer.alloc(32, 0xee) } } });
    return state;
    });
    return { version: Number(state.version) };
  },
  // The phone's view of storage once its version passes `after`: every record, bytes as base64.
  async storageRecords({ after = -1, timeout = 10000 }) {
    let state = await phone.getStorageState();
    if (!state || !(Number(state.version) > after)) {
      state = await phone.waitForStorageState({ after: state, predicate: (st) => Number(st.version) > after, timeout });
    }
    lastStorageState = state;
    const plain = (v) => JSON.parse(JSON.stringify(v, (_, x) => {
      if (typeof x === 'bigint') return Number(x);
      if (x && x.type === 'Buffer' && Array.isArray(x.data)) return Buffer.from(x.data).toString('base64');
      if (x instanceof Uint8Array) return Buffer.from(x).toString('base64');
      return x;
    }));
    const records = state.filterRecords(() => true).map((r) => ({ type: r.type, key: b64(r.key), record: plain(r.record) }));
    return { version: Number(state.version), records, orphaned: phone.getOrphanedStorageKeys().length };
  },
  // A phone-side change made while the desktop also changes something (409 path).
  async updateAliceRecord({ markedUnread = false, nickname = null }) {
    const state = await phoneStorageWrite((st) =>
      st.updateContact(alice, { markedUnread, ...(nickname ? { nickname: { given: nickname, family: '' } } : {}) }));
    return { version: Number(state.version) };
  },
  async sendSenderKey({ from }) {
    return { distributionId: await account(from).sendSenderKey(needDesktop()) };
  },
  async sendSyncSent({ text, timestamp, destination = 'alice' }) {
    const env = await phone.encryptSyncSent(needDesktop(), text, { timestamp, destinationServiceId: account(destination).device.aci });
    await server.send(needDesktop(), env);
    return {};
  },
  async sendReceipt({ from, type, timestamps, timestamp }) {
    if (type === 'viewed') {
      // PrimaryDevice.sendReceipt only knows Delivery and Read.
      const receiptMessage = { type: Proto.ReceiptMessage.Type.VIEWED, timestamp: timestamps.map((t) => BigInt(t)) };
      await account(from).sendRaw(needDesktop(), wrap({ receiptMessage }), { timestamp });
      return {};
    }
    const t = { delivery: ReceiptType.Delivery, read: ReceiptType.Read }[type];
    await account(from).sendReceipt(needDesktop(), { type: t, messageTimestamps: timestamps, timestamp });
    return {};
  },
  async sendTyping({ from, action, timestamp }) {
    const a = action === 'started' ? Proto.TypingMessage.Action.STARTED : Proto.TypingMessage.Action.STOPPED;
    await account(from).sendRaw(needDesktop(), wrap({ typingMessage: { timestamp: BigInt(timestamp), action: a, groupId: null } }), { timestamp });
    return {};
  },
  async sendEdit({ from, targetTimestamp, text, timestamp }) {
    await account(from).sendRaw(
      needDesktop(),
      wrap({ editMessage: { targetSentTimestamp: BigInt(targetTimestamp), dataMessage: dataMessage(text, timestamp) } }),
      { timestamp },
    );
    return {};
  },
  async sendDecryptionError({ from, timestamp, plaintext = false, originalDevice = 1 }) {
    const sender = account(from);
    const dem = DecryptionErrorMessage.forOriginal(Buffer.from([0]), CiphertextMessageType.SenderKey, timestamp, originalDevice);
    if (!plaintext) {
      await sender.sendRaw(needDesktop(), wrap({ decryptionErrorMessage: dem.serialize() }), { timestamp });
      return {};
    }
    // Real clients send decryption errors as PLAINTEXT_CONTENT envelopes.
    const envelope = Proto.Envelope.encode({
      type: Proto.Envelope.Type.PLAINTEXT_CONTENT,
      sourceServiceIdBinary: sender.device.aciBinary,
      sourceDeviceId: sender.device.deviceId,
      destinationServiceIdBinary: ServiceId.parseFromServiceIdString(needDesktop().aci).getServiceIdBinary(),
      updatedPniBinary: null,
      serverTimestamp: BigInt(timestamp),
      clientTimestamp: BigInt(timestamp),
      content: PlaintextContent.from(dem).serialize(),
      serverGuid: null, ephemeral: null, urgent: null, story: null, reportSpamToken: null, serverGuidBinary: null,
      sourceServiceId: null, destinationServiceId: null, updatedPni: null,
    });
    await server.send(needDesktop(), Buffer.from(envelope));
    return {};
  },
};

const mockRequire = createRequire(import.meta.resolve('@signalapp/mock-server'));
const { realpathSync } = await import('node:fs');
out({
  event: 'ready',
  port,
  mockServer: {
    version: mockRequire('../package.json').version,
    path: realpathSync(join(import.meta.dirname, 'node_modules/@signalapp/mock-server')),
    libsignal: mockRequire('@signalapp/libsignal-client/package.json').version,
  },
  certificateAuthority: certs.certificateAuthority,
  serverTrustRoots: certs.serverTrustRoots,
  serverPublicParams: certs.serverPublicParams,
  genericServerPublicParams: certs.genericServerPublicParams,
  phone: { aci: phone.device.aci, pni: phone.device.pni ?? null, number: phone.device.number ?? null },
  alice: { aci: alice.device.aci, number: alice.device.number ?? null },
});

const rl = createInterface({ input: process.stdin });
rl.on('line', async (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  const fn = commands[msg.cmd];
  try {
    if (!fn) throw new Error(`unknown command ${msg.cmd}`);
    out({ id: msg.id, ok: true, result: await fn(msg) });
  } catch (error) {
    log('command failed', msg.cmd, error?.stack ?? error);
    out({ id: msg.id, ok: false, error: String(error?.message ?? error) });
  }
});
rl.on('close', async () => { await server.close(); process.exit(0); });
