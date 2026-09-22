'use strict';

const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { performance } = require('node:perf_hooks');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);
const MAX_INPUT_BYTES = 25 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
const MAX_PENDING_CONVERSIONS = 4;
const INPUT_FORMATS = Object.freeze({
  'audio/wav': 'wav',
  'audio/webm': 'matroska',
  'audio/ogg': 'ogg',
  'audio/mp4': 'mov',
  'audio/aac': 'aac',
  'audio/mpeg': 'mp3',
});

function audioError(code, message) {
  return Object.assign(new Error(message), { code });
}

async function runConversion(buffer, fileName, mimeType) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'betshuva-recorded-audio-'));
  const input = path.join(directory, 'recording.input');
  const output = path.join(directory, 'recording.mp3');
  try {
    await fs.writeFile(input, buffer, { flag: 'wx' });
    let result;
    try {
      result = await execFileAsync(
        process.env.WHISPER_PYTHON ||
          path.join(__dirname, '..', '.venv-whisper', 'bin', 'python'),
        [path.join(__dirname, '..', 'scripts', 'recorded_audio_mp3.py'),
          input, output, INPUT_FORMATS[mimeType]],
        { timeout: 30_000, killSignal: 'SIGKILL', maxBuffer: 64 * 1024 },
      );
    } catch (error) {
      let details;
      try { details = JSON.parse(String(error.stderr || '').trim().split('\n').at(-1)); }
      catch (_) {}
      if (details?.code === 'AUDIO_DURATION_EXCEEDED')
        throw audioError(details.code, 'Recording exceeds two minutes');
      if (details?.code === 'AUDIO_ENCODER_UNAVAILABLE' || error.code === 'ENOENT')
        throw audioError('AUDIO_CONVERSION_UNAVAILABLE', 'Recording encoder is unavailable');
      throw audioError('INVALID_AUDIO', 'Recording could not be converted');
    }
    const details = JSON.parse(result.stdout.trim());
    const size = (await fs.stat(output)).size;
    if (!Number.isFinite(details.durationSeconds) || details.durationSeconds <= 0 ||
        details.durationSeconds > 120 || size <= 0 || size > MAX_OUTPUT_BYTES)
      throw audioError('INVALID_AUDIO', 'Invalid converted recording');
    const converted = await fs.readFile(output);
    const extension = path.extname(fileName);
    return {
      buffer: converted,
      originalname: `${extension ? fileName.slice(0, -extension.length) : fileName}.mp3`,
      mimetype: 'audio/mpeg',
      size: converted.length,
      durationSeconds: details.durationSeconds,
    };
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
}

function createRecordedAudioConverter(convert = runConversion, { maxQueueWaitMs = 20_000 } = {}) {
  const queue = [];
  let active = false;

  function startNext() {
    if (active || !queue.length) return;
    const entry = queue.shift();
    clearTimeout(entry.timeout);
    if (performance.now() >= entry.deadline) {
      entry.reject(audioError('AUDIO_CONVERSION_BUSY', 'Recording encoder is busy'));
      startNext();
      return;
    }
    active = true;
    Promise.resolve().then(entry.run).then(entry.resolve, entry.reject).finally(() => {
      active = false;
      startNext();
    });
  }

  return function convertRecordedAudio(buffer, fileName, mimeType) {
    if (!Buffer.isBuffer(buffer) || !buffer.length || buffer.length > MAX_INPUT_BYTES ||
        !INPUT_FORMATS[mimeType] || typeof fileName !== 'string' || !fileName)
      return Promise.reject(audioError('INVALID_AUDIO', 'Invalid recorded audio input'));
    if (queue.length + Number(active) >= MAX_PENDING_CONVERSIONS)
      return Promise.reject(audioError('AUDIO_CONVERSION_BUSY', 'Recording encoder is busy'));
    return new Promise((resolve, reject) => {
      const entry = { run: () => convert(buffer, fileName, mimeType), resolve, reject,
        deadline: active ? performance.now() + maxQueueWaitMs : Infinity };
      // Expired requests leave the queue so they cannot upload after the client times out.
      entry.timeout = setTimeout(() => {
        const index = queue.indexOf(entry);
        if (index < 0) return;
        queue.splice(index, 1);
        reject(audioError('AUDIO_CONVERSION_BUSY', 'Recording encoder is busy'));
      }, maxQueueWaitMs);
      queue.push(entry);
      startNext();
    });
  };
}

module.exports = {
  convertRecordedAudio: createRecordedAudioConverter(),
  createRecordedAudioConverter,
};
