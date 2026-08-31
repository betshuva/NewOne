'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const sharp = require('sharp');
const { createVisualFingerprint, hammingHex, visuallyEquivalent } =
  require('../server/visual-fingerprint');

test('visual fingerprint recognizes recompression and resizing', async () => {
  const source = await sharp({ create: { width: 240, height: 160, channels: 3,
    background: '#d9a441' } }).composite([
      { input: Buffer.from('<svg width="100" height="100"><circle cx="50" cy="50" r="38" fill="#174f88"/></svg>'), left: 70, top: 30 },
    ]).png().toBuffer();
  const changedEncoding = await sharp(source).resize(480, 320).jpeg({ quality: 82 }).toBuffer();
  assert.equal(visuallyEquivalent(await createVisualFingerprint(source),
    await createVisualFingerprint(changedEncoding)), true);
});

test('visual fingerprint rejects a materially different image', async () => {
  const black = await sharp({ create: { width: 200, height: 120, channels: 3,
    background: 'black' } }).png().toBuffer();
  const split = await sharp({ create: { width: 200, height: 120, channels: 3,
    background: 'white' } }).composite([{ input: Buffer.from('<svg width="100" height="120"><rect width="100" height="120" fill="black"/></svg>'), left: 0, top: 0 }]).png().toBuffer();
  assert.equal(visuallyEquivalent(await createVisualFingerprint(black),
    await createVisualFingerprint(split)), false);
  assert.equal(hammingHex('0', 'f'), 4);
});
