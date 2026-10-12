'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const zlib = require('node:zlib');
const sharp = require('sharp');
const imageAnimationPolicy = require('../server/image-animation-policy');
const { createVisualFingerprint } = require('../server/visual-fingerprint');
const { imageClassificationOutcome } = require('../server/image-classification-outcome');
const { contentAllowedByFilter } = require('../server/content-filter-policy');

const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');
const scanStart = source.indexOf('async function scanImage(');
const scanEnd = source.indexOf('async function scanDocument(', scanStart);
assert.ok(scanStart >= 0 && scanEnd > scanStart);

const objectClassification = { category: 'nonHumanImages',
  detectedCategories: ['nonHumanImages'], uncertain: false };
const classification = category => ({ category,
  detectedCategories: [category], uncertain: false });

function scanner(overrides = {}) {
  return vm.runInNewContext(`${source.slice(scanStart, scanEnd)};scanImage`, {
    isTrustedBuiltinExpression: async () => false,
    createImageReviewState: () => ({}),
    isPotentiallyAnimatedImage: buffer => imageAnimationPolicy.potentialAnimationFormat(buffer) !== null,
    imageAnimationPolicy, imageClassificationOutcome, sharp,
    scanStaticImage: async () => ({ blocked: false, classification: objectClassification }),
    ...overrides,
  });
}

async function animation(format, frames = 2) {
  const pixels = Buffer.alloc(frames * 4);
  for (let page = 0; page < frames; page++) {
    pixels[page * 4 + page % 3] = 255;
    pixels[page * 4 + 3] = 255;
  }
  return sharp(pixels, { raw: { width: 1, height: frames, channels: 4, pageHeight: 1 } })
    [format]({ loop: 0, delay: Array(frames).fill(100), lossless: true }).toBuffer();
}

const crcTable = Array.from({ length: 256 }, (_, value) => {
  for (let bit = 0; bit < 8; bit++) value = value & 1
    ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});

function pngChunk(type, data) {
  const tag = Buffer.from(type), length = Buffer.alloc(4), checksum = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  let crc = 0xffffffff;
  for (const byte of Buffer.concat([tag, data])) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
  return Buffer.concat([length, tag, data, checksum]);
}

function animatedPng() {
  const header = Buffer.alloc(13), control = Buffer.alloc(8), frameSequence = Buffer.alloc(4);
  header.writeUInt32BE(1, 0); header.writeUInt32BE(1, 4);
  header[8] = 8; header[9] = 6;
  control.writeUInt32BE(2); frameSequence.writeUInt32BE(2);
  const frameControl = sequence => {
    const frame = Buffer.alloc(26);
    frame.writeUInt32BE(sequence); frame.writeUInt32BE(1, 4); frame.writeUInt32BE(1, 8);
    frame.writeUInt16BE(1, 20); frame.writeUInt16BE(10, 22);
    return frame;
  };
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), pngChunk('IHDR', header),
    pngChunk('acTL', control), pngChunk('fcTL', frameControl(0)),
    pngChunk('IDAT', zlib.deflateSync(Buffer.from([0, 255, 0, 0, 255]))),
    pngChunk('fcTL', frameControl(1)),
    pngChunk('fdAT', Buffer.concat([frameSequence, zlib.deflateSync(Buffer.from([0, 0, 255, 0, 255]))])),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

test('animation detection uses container chunks rather than text inside a static image', async () => {
  const png = await sharp({ create: { width: 1, height: 1, channels: 4,
    background: 'red' } }).png().toBuffer();
  const withText = Buffer.concat([png.subarray(0, png.length - 12),
    pngChunk('tEXt', Buffer.from('comment\0acTL ANIM ANMF')), png.subarray(png.length - 12)]);
  assert.equal(imageAnimationPolicy.potentialAnimationFormat(withText), null);
  assert.ok(await createVisualFingerprint(withText));
  const staticWebp = await sharp(png).webp().toBuffer();
  assert.equal(imageAnimationPolicy.potentialAnimationFormat(staticWebp), null);
  assert.ok(await createVisualFingerprint(staticWebp));
  assert.equal(imageAnimationPolicy.potentialAnimationFormat(Buffer.from('not an image')), null);
});

for (const format of ['gif', 'webp']) {
  test(`${format} scans actual decoded frames and applies later-frame recipient categories`, async () => {
    const bytes = await animation(format);
    assert.equal(imageAnimationPolicy.potentialAnimationFormat(bytes), format);
    assert.equal((await sharp(bytes, { animated: true }).metadata()).pages, 2);
    const seen = [], states = [], tracking = { storedFileId: 'fixture-only' };
    const scan = scanner({ scanStaticImage: async (frame, options) => {
      seen.push(Array.from((await sharp(frame).raw().toBuffer()).subarray(0, 3)));
      assert.equal(options.tracking, tracking); states.push(options.reviewState);
      return { blocked: false, classification: seen.length === 1
        ? objectClassification : classification('women') };
    } });
    const result = await scan(bytes, { tracking });
    assert.equal(result.blocked, false); assert.equal(result.pending, undefined);
    assert.equal(result.framesScanned, 2);
    assert.deepEqual(seen, [[255, 0, 0], [0, 255, 0]]);
    assert.equal(new Set(states).size, 1);
    assert.deepEqual(result.classification.detectedCategories, ['nonHumanImages', 'women']);
    assert.equal(contentAllowedByFilter({ women: false }, 'image', result.classification), false);
    assert.equal(contentAllowedByFilter({ women: true }, 'image', result.classification), true);
    assert.equal(await createVisualFingerprint(bytes), null);
  });

  test(`${format} merges all known demographics and does not lose a later category`, async () => {
    let calls = 0;
    const scan = scanner({ scanStaticImage: async () => ({ blocked: false,
      classification: classification(['men', 'children', 'women'][calls++]) }) });
    const result = await scan(await animation(format, 3));
    assert.deepEqual(result.classification, { category: 'people',
      detectedCategories: ['men', 'children', 'women'], uncertain: false });
    for (const category of ['men', 'women', 'children'])
      assert.equal(contentAllowedByFilter({ [category]: false }, 'image', result.classification), false);
  });

  test(`${format} never approves a later uncertain or missing classification`, async () => {
    for (const later of [{ classification: { category: 'women', uncertain: true } }, {}]) {
      let calls = 0;
      const scan = scanner({ scanStaticImage: async () => ++calls === 1
        ? { blocked: false, classification: objectClassification } : { blocked: false, ...later } });
      const result = await scan(await animation(format));
      assert.equal(result.pending, true);
      assert.equal(result.classification.uncertain, true);
      for (const category of ['men', 'women', 'children'])
        assert.equal(contentAllowedByFilter({ [category]: false }, 'image', result.classification), false);
    }
  });

  test(`${format} keeps the 12-frame limit and rejects 13 frames before calling providers`, async () => {
    let calls = 0;
    const scan = scanner({ scanStaticImage: async () => {
      calls++; return { blocked: false, classification: objectClassification };
    } });
    const twelve = await scan(await animation(format, 12));
    assert.equal(twelve.blocked, false); assert.equal(twelve.framesScanned, 12);
    assert.equal(calls, 12);
    calls = 0;
    const thirteen = await scan(await animation(format, 13));
    assert.equal(thirteen.blocked, true);
    assert.equal(thirteen.blockedBy, 'animatedImageTooManyFrames');
    assert.equal(thirteen.frameCount, 13); assert.equal(thirteen.framesScanned, 0);
    assert.equal(calls, 0);
  });
}

for (const state of ['blocked', 'pending', 'scanStopped']) {
  test(`a later ${state} frame stops the animation and retains all scanned categories`, async () => {
    let calls = 0;
    const scan = scanner({ scanStaticImage: async () => ++calls === 1
      ? { blocked: false, classification: objectClassification }
      : { [state]: true, reason: 'fixture decision', classification: classification('women') } });
    const result = await scan(await animation('gif', 3));
    assert.equal(result[state], true);
    assert.equal(result.framesScanned, 2); assert.equal(calls, 2);
    assert.deepEqual(result.classification.detectedCategories, ['nonHumanImages', 'women']);
  });
}

test('APNG is rejected before providers and cannot borrow a static first-frame fingerprint', async () => {
  const bytes = animatedPng();
  assert.equal((await sharp(bytes, { animated: true }).metadata()).format, 'png');
  assert.equal(imageAnimationPolicy.potentialAnimationFormat(bytes), 'apng');
  assert.equal(await createVisualFingerprint(bytes), null);
  const scan = scanner({ scanStaticImage: () => assert.fail('APNG must not call a provider') });
  const result = await scan(bytes);
  assert.equal(result.blocked, true); assert.equal(result.blockedBy, 'animatedPngUnsupported');
  assert.equal(result.framesScanned, 0); assert.match(result.reason, /APNG/);
  assert.match(result.reason, /GIF.*WebP/);
});

test('a single-frame GIF also stays outside the static visual cache', async () => {
  const bytes = await animation('gif', 1);
  assert.equal((await sharp(bytes, { animated: true }).metadata()).pages, 1);
  assert.equal(await createVisualFingerprint(bytes), null);
  const result = await scanner()(bytes);
  assert.equal(result.blocked, false); assert.equal(result.pending, undefined);
  assert.equal(result.framesScanned, 1);
});

test('trusted exact library bytes retain their existing exemption before animation decoding', async () => {
  const trusted = { blocked: false, scanSkipped: true, source: 'builtin-expression' };
  const scan = scanner({ isTrustedBuiltinExpression: async () => true,
    builtinExpressionResult: () => trusted,
    sharp: () => assert.fail('trusted library must not decode'),
    scanStaticImage: () => assert.fail('trusted library must not call a provider') });
  assert.equal(await scan(animatedPng()), trusted);
});

test('undecodable animated data is rejected without an approval or provider call', async () => {
  const scan = scanner({ scanStaticImage: () => assert.fail('decode must precede providers') });
  const result = await scan(Buffer.from('GIF89a broken animation'));
  assert.equal(result.blocked, true); assert.equal(result.blockedBy, 'animatedImageDecode');
});

test('a failed later-frame decode never returns the preceding frame approval', async () => {
  let calls = 0;
  const scan = scanner({ sharp: (bytes, options) => options?.page === 1
    ? { png() { return this; }, toBuffer: async () => { throw new Error('fixture decode failure'); } }
    : sharp(bytes, options),
  scanStaticImage: async () => { calls++; return { blocked: false, classification: objectClassification }; } });
  const result = await scan(await animation('gif'));
  assert.equal(result.blocked, true); assert.equal(result.blockedBy, 'animatedImageDecode');
  assert.equal(result.framesScanned, 1); assert.equal(calls, 1);
});
