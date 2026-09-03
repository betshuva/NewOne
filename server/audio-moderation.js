'use strict';

const crypto = require('crypto');
const fs = require('fs/promises');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');
const { promisify } = require('util');

const execFileAsync = promisify(execFile);
const PYTHON = process.env.WHISPER_PYTHON ||
  path.join(__dirname, '..', '.venv-whisper', 'bin', 'python');
const SCRIPT = path.join(__dirname, '..', 'scripts', 'audio_transcription.py');
const MODEL_DIR = process.env.WHISPER_MODEL_DIR ||
  path.join(__dirname, '..', 'backups', 'whisper-models');
const MAX_AUDIO_SECONDS = 120;

let transcriptionQueue = Promise.resolve();
let queuedTranscriptions = 0;

function extensionFor(fileName) {
  const extension = path.extname(String(fileName || '')).toLowerCase();
  return /^\.[a-z0-9]{1,8}$/.test(extension) ? extension : '.audio';
}

async function runTool(mode, buffer, fileName, timeout) {
  const temporaryDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'betshuva-audio-'));
  const temporaryFile = path.join(temporaryDirectory, `upload${extensionFor(fileName)}`);
  try {
    await fs.writeFile(temporaryFile, buffer, { flag: 'wx' });
    const { stdout } = await execFileAsync(
      PYTHON,
      [SCRIPT, mode, temporaryFile],
      {
        timeout,
        maxBuffer: 4 * 1024 * 1024,
        env: {
          ...process.env,
          WHISPER_MODEL: process.env.WHISPER_MODEL || 'small',
          WHISPER_MODEL_DIR: MODEL_DIR,
        },
      },
    );
    return JSON.parse(stdout.trim());
  } finally {
    await fs.rm(temporaryDirectory, { recursive: true, force: true });
  }
}

async function probeAudio(buffer, fileName) {
  const result = await runTool('probe', buffer, fileName, 30_000);
  const durationSeconds = Number(result.durationSeconds);
  if (!Number.isFinite(durationSeconds) || durationSeconds <= 0)
    throw new Error('לא ניתן לזהות את משך ההקלטה');
  return { durationSeconds };
}

function transcribeAudio(buffer, fileName) {
  queuedTranscriptions += 1;
  const task = () => runTool('transcribe', buffer, fileName, 10 * 60_000);
  const result = transcriptionQueue.then(task, task);
  transcriptionQueue = result.catch(() => {});
  return result.finally(() => { queuedTranscriptions -= 1; });
}

function isAudioTranscriptionBusy() {
  return queuedTranscriptions > 0;
}

function transcriptDigest(transcript) {
  return crypto.createHash('sha256').update(String(transcript || '')).digest('hex');
}

module.exports = {
  MAX_AUDIO_SECONDS,
  probeAudio,
  transcribeAudio,
  transcriptDigest,
  isAudioTranscriptionBusy,
};
