'use strict';

const sharp = require('sharp');

function bitsToHex(bits) {
  let value = '';
  for (let index = 0; index < bits.length; index += 4) {
    const nibble = bits.slice(index, index + 4)
      .reduce((sum, bit) => (sum << 1) | bit, 0);
    value += nibble.toString(16);
  }
  return value;
}

function hammingHex(left, right) {
  if (!left || !right || left.length !== right.length) return Infinity;
  let distance = 0;
  for (let index = 0; index < left.length; index++) {
    let value = parseInt(left[index], 16) ^ parseInt(right[index], 16);
    while (value) { distance += value & 1; value >>>= 1; }
  }
  return distance;
}

async function createVisualFingerprint(buffer) {
  const metadata = await sharp(buffer, { animated: true }).metadata();
  if ((metadata.pages || 1) > 1 || !metadata.width || !metadata.height)
    return null;
  const rotated = [5, 6, 7, 8].includes(metadata.orientation);
  const width = rotated ? metadata.height : metadata.width;
  const height = rotated ? metadata.width : metadata.height;
  const pixels = await sharp(buffer).rotate().grayscale()
    .resize(17, 16, { fit: 'fill' }).raw().toBuffer();
  const sixteen = [];
  for (let y = 0; y < 16; y++)
    for (let x = 0; x < 16; x++) sixteen.push(pixels[y * 17 + x]);
  const average = sixteen.reduce((sum, value) => sum + value, 0) /
    sixteen.length;
  const averageHash = bitsToHex(sixteen.map(value => value >= average ? 1 : 0));
  const differences = [];
  for (let y = 0; y < 16; y++)
    for (let x = 0; x < 16; x++)
      differences.push(pixels[y * 17 + x] >= pixels[y * 17 + x + 1] ? 1 : 0);
  return {
    algorithm: 'ahash16+dhash16-v1',
    averageHash,
    differenceHash: bitsToHex(differences),
    aspect: Number((width / height).toFixed(6)),
  };
}

function visuallyEquivalent(left, right) {
  if (!left || !right || left.algorithm !== 'ahash16+dhash16-v1' ||
      right.algorithm !== left.algorithm) return false;
  if (Math.abs(Number(left.aspect) - Number(right.aspect)) > 0.01) return false;
  return hammingHex(left.averageHash, right.averageHash) <= 8 &&
    hammingHex(left.differenceHash, right.differenceHash) <= 12;
}

module.exports = { createVisualFingerprint, hammingHex, visuallyEquivalent };
