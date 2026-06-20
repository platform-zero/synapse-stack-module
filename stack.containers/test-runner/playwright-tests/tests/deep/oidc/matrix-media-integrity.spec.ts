import { expect, test } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';
import { webcrypto, createHash, randomBytes } from 'crypto';
import { Client } from 'pg';
import { domain } from '../shared/oidc';

const homeserverUrl = `https://matrix.${domain}`;
const senderUserId = `@roombot:matrix.${domain}`;
const receiverUserId = `@gerald:matrix.${domain}`;
const senderMobileUserAgent = 'Element Classic/1.6.56 (samsung SM-S721B; Android 16; Flavour GooglePlay; MatrixAndroidSdk2 1.6.56)';
const receiverMobileUserAgent = 'Element Classic/1.6.56 (Google Pixel 9 Pro XL; Android 16; Flavour GooglePlay; MatrixAndroidSdk2 1.6.56)';

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required for the Matrix media integrity e2e test`);
  }
  return value;
}

async function fetchMatrixAccessToken(userId: string): Promise<string> {
  const client = new Client({
    host: process.env.MATRIX_POSTGRES_HOST || 'postgres',
    port: Number(process.env.MATRIX_POSTGRES_PORT || '5432'),
    database: process.env.MATRIX_POSTGRES_DB || 'synapse',
    user: process.env.MATRIX_POSTGRES_USER || 'synapse',
    password: requireEnv('MATRIX_POSTGRES_PASSWORD'),
  });

  await client.connect();
  try {
    const result = await client.query<{ token: string }>(
      'SELECT token FROM access_tokens WHERE user_id = $1 ORDER BY id DESC LIMIT 1',
      [userId],
    );
    const token = result.rows[0]?.token || '';
    expect(token, `Synapse access token for ${userId}`).toBeTruthy();
    return token;
  } finally {
    await client.end();
  }
}

function oggCrc(data: Buffer): number {
  let crc = 0;
  for (const value of data) {
    crc ^= value << 24;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 0x80000000) !== 0
        ? ((crc << 1) ^ 0x04c11db7) >>> 0
        : (crc << 1) >>> 0;
    }
  }
  return crc >>> 0;
}

function oggPage(options: {
  serial: number;
  sequence: number;
  granule: bigint;
  headerType: number;
  payload: Buffer;
}): Buffer {
  const lacingValues: number[] = [];
  let remaining = options.payload.length;
  while (remaining >= 255) {
    lacingValues.push(255);
    remaining -= 255;
  }
  lacingValues.push(remaining);

  const page = Buffer.alloc(27 + lacingValues.length + options.payload.length);
  page.write('OggS', 0, 'ascii');
  page[4] = 0;
  page[5] = options.headerType;
  page.writeBigUInt64LE(options.granule, 6);
  page.writeUInt32LE(options.serial >>> 0, 14);
  page.writeUInt32LE(options.sequence >>> 0, 18);
  page.writeUInt32LE(0, 22);
  page[26] = lacingValues.length;
  Buffer.from(lacingValues).copy(page, 27);
  options.payload.copy(page, 27 + lacingValues.length);
  page.writeUInt32LE(oggCrc(page), 22);
  return page;
}

function voiceLikeOggPayload(): Buffer {
  const serial = 0x4d545258;
  const uint32Le = (value: number): Buffer => {
    const buffer = Buffer.alloc(4);
    buffer.writeUInt32LE(value, 0);
    return buffer;
  };
  const opusHead = Buffer.concat([
    Buffer.from('OpusHead', 'ascii'),
    Buffer.from([1, 1]),
    Buffer.from([0x38, 0x01]),
    Buffer.from([0x80, 0xbb, 0x00, 0x00]),
    Buffer.from([0x00, 0x00]),
  ]);
  const vendor = Buffer.from('webservices-matrix-media-integrity', 'utf8');
  const opusTags = Buffer.concat([
    Buffer.from('OpusTags', 'ascii'),
    uint32Le(vendor.length),
    vendor,
    uint32Le(0),
  ]);
  const pages = [
    oggPage({ serial, sequence: 0, granule: 0n, headerType: 0x02, payload: opusHead }),
    oggPage({ serial, sequence: 1, granule: 0n, headerType: 0x00, payload: opusTags }),
  ];

  for (let sequence = 2; sequence < 18; sequence += 1) {
    const payload = createHash('sha256')
      .update(`voice-frame-${sequence}`)
      .digest()
      .subarray(0, 24 + (sequence % 7));
    pages.push(oggPage({
      serial,
      sequence,
      granule: BigInt((sequence - 1) * 960),
      headerType: sequence === 17 ? 0x04 : 0x00,
      payload,
    }));
  }

  return Buffer.concat(pages);
}

function parseOggPages(data: Buffer): Array<{ offset: number; serial: number; sequence: number; length: number }> {
  const pages: Array<{ offset: number; serial: number; sequence: number; length: number }> = [];
  let offset = 0;
  while (offset < data.length) {
    expect(data.subarray(offset, offset + 4).toString('ascii'), `Ogg capture pattern at byte ${offset}`).toBe('OggS');
    const segmentCount = data[offset + 26];
    const segmentTableStart = offset + 27;
    const segmentTableEnd = segmentTableStart + segmentCount;
    expect(segmentTableEnd, `Ogg segment table at byte ${offset}`).toBeLessThanOrEqual(data.length);
    const payloadLength = data.subarray(segmentTableStart, segmentTableEnd).reduce((sum, value) => sum + value, 0);
    const pageLength = 27 + segmentCount + payloadLength;
    expect(offset + pageLength, `Ogg page length at byte ${offset}`).toBeLessThanOrEqual(data.length);

    const crcPage = Buffer.from(data.subarray(offset, offset + pageLength));
    const expectedCrc = crcPage.readUInt32LE(22);
    crcPage.writeUInt32LE(0, 22);
    expect(oggCrc(crcPage), `Ogg CRC at byte ${offset}`).toBe(expectedCrc);

    pages.push({
      offset,
      serial: data.readUInt32LE(offset + 14),
      sequence: data.readUInt32LE(offset + 18),
      length: pageLength,
    });
    offset += pageLength;
  }
  return pages;
}

function assertSingleSerialSequentialOgg(data: Buffer): void {
  const pages = parseOggPages(data);
  expect(pages.length, 'voice payload should contain multiple Ogg pages').toBeGreaterThan(3);
  const serial = pages[0].serial;
  for (const [index, page] of pages.entries()) {
    expect(page.serial, `Ogg serial at page ${index}`).toBe(serial);
    expect(page.sequence, `Ogg sequence at page ${index}`).toBe(index);
  }
}

function base64Url(data: Buffer): string {
  return data.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function fromBase64Url(value: string): Buffer {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  return Buffer.from(normalized + '='.repeat((4 - (normalized.length % 4)) % 4), 'base64');
}

async function encryptAttachment(plain: Buffer): Promise<{
  encrypted: Buffer;
  metadata: {
    key: { kty: string; alg: string; ext: boolean; key_ops: string[]; k: string };
    iv: string;
    hashes: { sha256: string };
    v: string;
  };
}> {
  const keyBytes = randomBytes(32);
  const iv = randomBytes(16);
  iv[8] &= 0x7f;
  for (let index = 9; index < 16; index += 1) iv[index] = 0;
  const key = await webcrypto.subtle.importKey('raw', keyBytes, 'AES-CTR', false, ['encrypt']);
  const encrypted = Buffer.from(await webcrypto.subtle.encrypt(
    { name: 'AES-CTR', counter: iv, length: 64 },
    key,
    plain,
  ));
  return {
    encrypted,
    metadata: {
      key: {
        kty: 'oct',
        alg: 'A256CTR',
        ext: true,
        key_ops: ['encrypt', 'decrypt'],
        k: base64Url(keyBytes),
      },
      iv: iv.toString('base64').replace(/=+$/g, ''),
      hashes: {
        sha256: base64Url(createHash('sha256').update(encrypted).digest()),
      },
      v: 'v2',
    },
  };
}

async function decryptAttachment(encrypted: Buffer, metadata: Awaited<ReturnType<typeof encryptAttachment>>['metadata']): Promise<Buffer> {
  expect(base64Url(createHash('sha256').update(encrypted).digest()), 'encrypted attachment SHA-256').toBe(metadata.hashes.sha256);
  const key = await webcrypto.subtle.importKey('raw', fromBase64Url(metadata.key.k), 'AES-CTR', false, ['decrypt']);
  const iv = Buffer.from(metadata.iv + '='.repeat((4 - (metadata.iv.length % 4)) % 4), 'base64');
  return Buffer.from(await webcrypto.subtle.decrypt(
    { name: 'AES-CTR', counter: iv, length: 64 },
    key,
    encrypted,
  ));
}

async function uploadMedia(
  request: APIRequestContext,
  accessToken: string,
  userAgent: string,
  body: Buffer,
  contentType: string,
): Promise<string> {
  const response = await request.post(`${homeserverUrl}/_matrix/media/r0/upload?filename=voice-message.ogg`, {
    data: body,
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': contentType,
      'User-Agent': userAgent,
    },
  });
  const text = await response.text();
  expect(response.ok(), `Matrix media upload failed: ${response.status()} ${text}`).toBe(true);
  const payload = JSON.parse(text) as { content_uri?: string };
  expect(payload.content_uri, 'uploaded Matrix content URI').toMatch(/^mxc:\/\//);
  return payload.content_uri || '';
}

async function downloadMedia(
  request: APIRequestContext,
  accessToken: string,
  userAgent: string,
  contentUri: string,
): Promise<Buffer> {
  const [, serverName, mediaId] = /^mxc:\/\/([^/]+)\/(.+)$/.exec(contentUri) || [];
  expect(serverName, `server name in ${contentUri}`).toBeTruthy();
  expect(mediaId, `media id in ${contentUri}`).toBeTruthy();
  const response = await request.get(
    `${homeserverUrl}/_matrix/client/v1/media/download/${serverName}/${mediaId}`,
    {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'User-Agent': userAgent,
      },
    },
  );
  const body = await response.body();
  expect(response.ok(), `Matrix media download failed: ${response.status()} ${body.toString('utf8', 0, 200)}`).toBe(true);
  return Buffer.from(body);
}

test('Matrix external media route preserves mobile voice attachment bytes across two devices', async ({ request }) => {
  const senderToken = await fetchMatrixAccessToken(senderUserId);
  const receiverToken = await fetchMatrixAccessToken(receiverUserId);
  const voicePayload = voiceLikeOggPayload();
  assertSingleSerialSequentialOgg(voicePayload);

  const plainUri = await uploadMedia(request, senderToken, senderMobileUserAgent, voicePayload, 'audio/ogg; codecs=opus');
  const plainDownloaded = await downloadMedia(request, receiverToken, receiverMobileUserAgent, plainUri);
  expect(plainDownloaded.equals(voicePayload), 'plain voice media should roundtrip byte-for-byte').toBe(true);
  assertSingleSerialSequentialOgg(plainDownloaded);

  const encryptedAttachment = await encryptAttachment(voicePayload);
  const encryptedUri = await uploadMedia(
    request,
    senderToken,
    senderMobileUserAgent,
    encryptedAttachment.encrypted,
    'application/octet-stream',
  );
  const encryptedDownloaded = await downloadMedia(request, receiverToken, receiverMobileUserAgent, encryptedUri);
  const decryptedDownloaded = await decryptAttachment(encryptedDownloaded, encryptedAttachment.metadata);
  expect(decryptedDownloaded.equals(voicePayload), 'encrypted voice media should decrypt to original bytes').toBe(true);
  assertSingleSerialSequentialOgg(decryptedDownloaded);
});
