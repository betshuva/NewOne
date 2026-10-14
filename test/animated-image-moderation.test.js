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
    ANIMATED_SCAN_VERSION: 'fixture-gif3-webp20',
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

async function indexedAnimation(format, delays) {
  const pixels = Buffer.alloc(delays.length * 4);
  for (let frame = 0; frame < delays.length; frame++) {
    pixels[frame * 4] = frame + 11;
    pixels[frame * 4 + 1] = (frame * 7 + 31) % 256;
    pixels[frame * 4 + 2] = (frame * 13 + 71) % 256;
    pixels[frame * 4 + 3] = 255;
  }
  const bytes = await sharp(pixels, { raw: {
    width: 1, height: delays.length, channels: 4, pageHeight: 1,
  } })[format]({ loop: 0, delay: delays, lossless: true }).toBuffer();
  return { bytes, pixels };
}

test('GIF scans beginning, temporal midpoint and end only', () => {
  assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({
    format: 'gif', pages: 37, delay: Array(37).fill(100),
  }), [
    { frameIndex: 0, timeSeconds: 0 },
    { frameIndex: 18, timeSeconds: 1.8 },
    { frameIndex: 36, timeSeconds: 3.6 },
  ]);
  for (const pages of [1, 2, 3]) {
    assert.equal(imageAnimationPolicy.sampleAnimationFrames({ format: 'gif', pages }).length, pages);
  }
  const delay = Array(37).fill(100);
  delay[9] = 10000;
  assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({
    format: 'gif', pages: 37, delay,
  }).map(frame => frame.frameIndex), [0, 9, 36]);
});

test('animation sampling checks every short animation frame with its original timestamp', () => {
  for (const frameCount of [1, 2, 12, 13, 20]) {
    assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({
      pages: frameCount, delay: Array(frameCount).fill(100),
    }), Array.from({ length: frameCount }, (_, frameIndex) =>
      ({ frameIndex, timeSeconds: frameIndex / 10 })));
  }
  assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({}), [{ frameIndex: 0, timeSeconds: 0 }]);
});

test('animation sampling selects exact displayed frames uniformly over the full duration', () => {
  const samples = imageAnimationPolicy.sampleAnimationFrames({ pages: 37, delay: Array(37).fill(100) });
  const expected = [0, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31, 33, 35, 36];
  assert.deepEqual(samples.map(sample => sample.frameIndex), expected);
  assert.deepEqual(samples.map(sample => sample.timeSeconds), expected.map(index => index / 10));
});

test('animation sampling honors long displayed holds and deduplicates repeated timeline selections', () => {
  const delay = Array(37).fill(100);
  delay[9] = 10000;
  const samples = imageAnimationPolicy.sampleAnimationFrames({ pages: 37, delay });
  assert.deepEqual(samples, [
    { frameIndex: 0, timeSeconds: 0 }, { frameIndex: 7, timeSeconds: .7 },
    { frameIndex: 9, timeSeconds: .9 }, { frameIndex: 15, timeSeconds: 11.4 },
    { frameIndex: 22, timeSeconds: 12.1 }, { frameIndex: 29, timeSeconds: 12.8 },
    { frameIndex: 36, timeSeconds: 13.5 },
  ]);
  const finalHold = Array(37).fill(100);
  finalHold[36] = 100000;
  const ending = imageAnimationPolicy.sampleAnimationFrames({ pages: 37, delay: finalHold });
  assert.deepEqual(ending.map(sample => sample.frameIndex), [0, 36]);
});

test('animation sampling chooses the next source frame at exact duration boundaries', () => {
  const samples = imageAnimationPolicy.sampleAnimationFrames({ pages: 38, delay: Array(38).fill(100) });
  assert.deepEqual(samples.map(sample => sample.frameIndex),
    [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 37]);
});

test('animation sampling handles missing and invalid delays without invalid timestamps', () => {
  const expected = [
    { frameIndex: 0, timeSeconds: 0 }, { frameIndex: 1, timeSeconds: .05 },
    { frameIndex: 2, timeSeconds: .15 }, { frameIndex: 3, timeSeconds: .25 },
    { frameIndex: 4, timeSeconds: .35 }, { frameIndex: 5, timeSeconds: .45 },
    { frameIndex: 6, timeSeconds: .55 }, { frameIndex: 7, timeSeconds: .65 },
  ];
  assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({ pages: 8,
    delay: [50, 0, -1, NaN, Infinity, Number.MAX_VALUE, '100'],
  }), expected);
  const uniform = imageAnimationPolicy.sampleAnimationFrames({ pages: 37, delay: Array(37).fill(100) });
  for (const invalid of [undefined, null, {}, 100, []]) {
    assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({ pages: 37, delay: invalid }), uniform);
  }
  assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({ pages: 3, delay: [10] }), [
    { frameIndex: 0, timeSeconds: 0 }, { frameIndex: 1, timeSeconds: .01 },
    { frameIndex: 2, timeSeconds: .11 },
  ]);
});

test('animation sampling retains valid submillisecond durations and rejects invalid frame counts', () => {
  assert.deepEqual(imageAnimationPolicy.sampleAnimationFrames({ pages: 3, delay: [.5, 1.5, 3] }), [
    { frameIndex: 0, timeSeconds: 0 }, { frameIndex: 1, timeSeconds: .0005 },
    { frameIndex: 2, timeSeconds: .002 },
  ]);
  for (const pages of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
    assert.throws(() => imageAnimationPolicy.sampleAnimationFrames({ pages }), RangeError);
  }
});

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

  test(`${format} respects its sample limit for twenty-frame and longer animations`, async () => {
    let calls = 0;
    const scan = scanner({ scanStaticImage: async () => {
      calls++; return { blocked: false, classification: objectClassification };
    } });
    const twenty = await scan(await animation(format, 20));
    assert.equal(twenty.blocked, false); assert.equal(twenty.framesScanned, format === 'gif' ? 3 : 20);
    assert.equal(twenty.sampledFrames, format === 'gif' ? 3 : 20); assert.equal(calls, format === 'gif' ? 3 : 20);
    calls = 0;
    const longer = await scan(await animation(format, 37));
    assert.equal(longer.blocked, false); assert.equal(longer.blockedBy, null);
    assert.equal(longer.frameCount, 37); assert.equal(longer.framesScanned, format === 'gif' ? 3 : 20);
    assert.equal(longer.sampledFrames, format === 'gif' ? 3 : 20); assert.equal(calls, format === 'gif' ? 3 : 20);
  });

  test(`${format} scans exactly the selected decoded frames and clears first-frame SafeSearch reuse`, async () => {
    for (const count of [25, 37]) {
      const delay = Array(count).fill(100);
      if (count === 37) delay[9] = 10000;
      const { bytes, pixels } = await indexedAnimation(format, delay);
      const metadata = await sharp(bytes, { animated: true }).metadata();
      assert.equal(metadata.pages, count);
      const expected = imageAnimationPolicy.sampleAnimationFrames(metadata);
      const seen = [], states = [], tracking = { storedFileId: 'fixture-only' };
      const precomputed = { adult: 'VERY_UNLIKELY', racy: 'VERY_UNLIKELY' };
      const scan = scanner({ scanStaticImage: async (frame, options) => {
        assert.equal(options.googleSafeSearch, undefined);
        assert.equal(options.tracking, tracking);
        states.push(options.reviewState);
        seen.push(Array.from((await sharp(frame).raw().toBuffer()).subarray(0, 3)));
        return { blocked: false, classification: objectClassification };
      } });
      const result = await scan(bytes, { tracking, googleSafeSearch: precomputed });
      assert.equal(result.blocked, false);
      assert.equal(result.frameCount, count);
      assert.equal(result.framesScanned, expected.length);
      assert.equal(result.sampledFrames, expected.length);
      assert.ok(expected.length <= 20);
      assert.equal(new Set(states).size, 1);
      assert.deepEqual(seen, expected.map(({ frameIndex }) => Array.from(
        pixels.subarray(frameIndex * 4, frameIndex * 4 + 3))));
      assert.equal(result.moderationVersion, 'fixture-gif3-webp20');
      assert.deepEqual(JSON.parse(JSON.stringify(result.frameSamples)), expected);
      assert.deepEqual(Array.from(result.frameResults, ({ frameIndex, timeSeconds }) =>
        ({ frameIndex, timeSeconds })), expected);
      assert.equal(precomputed.adult, 'VERY_UNLIKELY');
      assert.equal(await createVisualFingerprint(bytes), null);
    }
  });

  test(`${format} stops on the last sampled source frame and reports its original number`, async () => {
    const count = 37;
    const { bytes, pixels } = await indexedAnimation(format, Array(count).fill(100));
    let calls = 0;
    const scan = scanner({ scanStaticImage: async frame => {
      calls++;
      const pixel = await sharp(frame).raw().toBuffer();
      const last = pixel[0] === pixels[(count - 1) * 4];
      return { blocked: last, reason: last ? 'fixture final-frame block' : undefined,
        classification: last ? classification('women') : objectClassification };
    } });
    const result = await scan(bytes);
    assert.equal(result.blocked, true);
    assert.equal(result.framesScanned, format === 'gif' ? 3 : 20); assert.equal(calls, format === 'gif' ? 3 : 20);
    assert.match(result.reason, /37/);
    assert.equal(result.frameResults.at(-1).frameIndex, 36);
    assert.deepEqual(result.classification.detectedCategories, ['nonHumanImages', 'women']);
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

test('a failed sampled source-frame decode preserves earlier samples without approving the animation', async () => {
  const { bytes } = await indexedAnimation('webp', Array(37).fill(100));
  let calls = 0;
  const scan = scanner({ sharp: (input, options) => options?.page === 7
    ? { png() { return this; }, toBuffer: async () => { throw new Error('fixture sampled decode failure'); } }
    : sharp(input, options),
  scanStaticImage: async () => {
    calls++; return { blocked: false, classification: objectClassification };
  } });
  const result = await scan(bytes);
  assert.equal(result.blocked, true);
  assert.equal(result.blockedBy, 'animatedImageDecode');
  assert.equal(result.frameCount, 37);
  assert.equal(result.sampledFrames, 20);
  assert.equal(result.framesScanned, 4); assert.equal(calls, 4);
  assert.match(result.reason, /8/);
  assert.deepEqual(Array.from(result.frameResults, result => result.frameIndex), [0, 1, 3, 5]);
});

test('animation metadata avoids the stacked pixel limit while each selected frame retains its limit', async () => {
  const pixels = Buffer.alloc(2 * 2 * 3 * 4);
  for (let page = 0; page < 3; page++) for (let pixel = 0; pixel < 4; pixel++) {
    const start = (page * 4 + pixel) * 4;
    pixels[start + page] = 255; pixels[start + 3] = 255;
  }
  const bytes = await sharp(pixels, { raw: {
    width: 2, height: 6, channels: 4, pageHeight: 2,
  } }).gif({ loop: 0, delay: [100, 1000, 100] }).toBuffer();
  await assert.rejects(sharp(bytes, { animated: true, limitInputPixels: 8 }).metadata(),
    /pixel limit/i);
  const seen = [];
  const scan = scanner({ sharp: (input, options) => sharp(input, {
    limitInputPixels: 8, ...options,
  }), scanStaticImage: async frame => {
    const decoded = await sharp(frame, { limitInputPixels: 8 }).raw()
      .toBuffer({ resolveWithObject: true });
    assert.equal(decoded.info.width, 2); assert.equal(decoded.info.height, 2);
    seen.push(Array.from(decoded.data.subarray(0, 3)));
    return { blocked: false, classification: objectClassification };
  } });
  const result = await scan(bytes);
  assert.equal(result.blocked, false);
  assert.equal(result.frameCount, 3); assert.equal(result.framesScanned, 3);
  assert.deepEqual(seen, [[255, 0, 0], [0, 255, 0], [0, 0, 255]]);
  assert.deepEqual(Array.from(result.frameSamples, sample => sample.timeSeconds), [0, .1, 1.1]);
});
