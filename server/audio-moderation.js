'use strict';

const fs = require('fs/promises');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);
const PYTHON = process.env.WHISPER_PYTHON ||
  path.join(__dirname, '..', '.venv-whisper', 'bin', 'python');
const SCRIPT = path.join(__dirname, '..', 'scripts', 'audio_transcription.py');
const MAX_AUDIO_BYTES = 150 * 1024 * 1024;
// Two hours of mono 16 kHz / 16-bit WAV need about 220 MiB before MP3 conversion.
const MAX_RECORDING_INPUT_BYTES = 256 * 1024 * 1024;

function extensionFor(fileName) {
  const extension = path.extname(String(fileName || '')).toLowerCase();
  return /^\.[a-z0-9]{1,8}$/.test(extension) ? extension : '.audio';
}

async function runTool(mode, buffer, fileName, timeout) {
  const temporaryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'betshuva-audio-'));
  const temporaryFile = path.join(temporaryDirectory, `upload${extensionFor(fileName)}`);
  try {
    if (Buffer.isBuffer(buffer)) await fs.writeFile(temporaryFile, buffer, { flag: 'wx' });
    const { stdout } = await execFileAsync(
      PYTHON,
      [SCRIPT, mode, Buffer.isBuffer(buffer) ? temporaryFile : buffer.path],
      {
        timeout,
        maxBuffer: 4 * 1024 * 1024,

      },
    );
    return JSON.parse(stdout.trim());
  } finally {
    await fs.rm(temporaryDirectory, { recursive: true, force: true });
  }
}

async function probeAudio(buffer, fileName) {
  const result = await runTool('probe', buffer, fileName, 300_000);
  const durationSeconds = Number(result.durationSeconds);
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0)
    throw new Error('לא ניתן לזהות את משך ההקלטה');
  return { durationSeconds };
}

async function probeWebmMime(buffer, fileName) {
  const result = await runTool('webm-type', buffer, fileName, 10_000);
  if (!['audio/webm', 'video/webm'].includes(result.mime))
    throw new Error('Invalid WebM media tracks');
  return result.mime;
}

module.exports = { MAX_AUDIO_BYTES, MAX_RECORDING_INPUT_BYTES, probeAudio, probeWebmMime };
