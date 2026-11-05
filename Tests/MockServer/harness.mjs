// SignalSafe integration-test harness around Signal's mock server: upstream's in-tree
// Signal-Desktop/packages/mock-server (the server Signal Desktop's own ts/test-mock suite
// uses), built into .mock-server by Tools/build-mock-server.sh.
//
// Protocol: one JSON object per line.
//   stdout first line:  {"event":"ready", port, certificateAuthority, serverTrustRoots, serverPublicParams, phone, alice}
//   stdin:  {"id":N, "cmd":..., ...args}      stdout: {"id":N, "ok":true, "result":...} | {"id":N, "ok":false, "error":...}
// The process exits when stdin closes.

import { createInterface } from 'node:readline';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { Server, StorageState, loadCertificates, Proto, EMPTY_DATA_MESSAGE, ReceiptType, ServiceIdKind } from '@signalapp/mock-server';
// The exact libsignal-client instance the mock server itself loaded.
const libsignal = createRequire(import.meta.resolve('@signalapp/mock-server'))('@signalapp/libsignal-client');
const { DecryptionErrorMessage, PlaintextContent, CiphertextMessageType, ServiceId, PublicKey } = libsignal;


const log = (...a) => process.stderr.write(a.join(' ') + '\n');
const out = (o) => process.stdout.write(JSON.stringify(o, (_, v) => (typeof v === 'bigint' ? Number(v) : v)) + '\n');

const certs = await loadCertificates();
const server = new Server({ cdn3Path: mkdtempSync(join(tmpdir(), 'signalsafe-cdn3-')) });
await server.listen(0);
const { port } = server.address();
// alice first, so the phone's contact-sync blob can list her (as in Desktop's test bootstrap).
const alice = await server.createPrimaryDevice({ profileName: 'Alice' });
const phone = await server.createPrimaryDevice({ profileName: 'Phone', contacts: [alice] });
let desktop = null;  // the linked device under test
let lastStorageState = null;

const accounts = { phone, alice };

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
  const kind = Object.keys(c).find((k) => c[k] != null) ?? (sync.read?.length ? 'read' : sync.viewed?.length ? 'viewed' : 'empty');
  const out = { kind };
  if (sync.read?.length) out.read = sync.read.map((r) => ({ senderAci: aciFromBinary(r.senderAciBinary) ?? r.senderAci, timestamp: Number(r.timestamp) }));
  if (sync.viewed?.length) out.viewed = sync.viewed.map((r) => ({ senderAci: aciFromBinary(r.senderAciBinary) ?? r.senderAci, timestamp: Number(r.timestamp) }));
  if (c.sent) {
    out.sent = {
      destination: aciFromBinary(c.sent.destinationServiceIdBinary) ?? c.sent.destinationServiceId,
      timestamp: Number(c.sent.timestamp),
      body: c.sent.message?.body ?? null,
      unidentified: (c.sent.unidentifiedStatus ?? []).map((u) => u.unidentified === true),
    };
  }
  if (c.request) out.requestType = c.request.type;
  return out;
};
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
      innerType: e.envelopeType,
      timestamp: Number(e.dataMessage.timestamp),
      profileKey: b64(e.dataMessage.profileKey),
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
    let state = lastStorageState ?? (await phone.expectStorageState('update'));
    state = state.updateContact(alice, { archived: archiveAlice });
    state = await phone.setStorageState(state);
    lastStorageState = state;
    await phone.sendFetchStorage({ timestamp: Date.now() });
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
