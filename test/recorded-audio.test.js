'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { execFile, spawnSync } = require('node:child_process');
const { promisify } = require('node:util');
const test = require('node:test');
const { convertRecordedAudio, createRecordedAudioConverter } = require('../server/recorded-audio');
const { probeAudio } = require('../server/audio-moderation');

const execFileAsync = promisify(execFile);
const python = process.env.WHISPER_PYTHON || path.join(__dirname, '..', '.venv-whisper/bin/python');
const hasEncoder = spawnSync(python,
  ['-c', 'import av; assert "libmp3lame" in av.codecs_available']).status === 0;
const recordingName = 'betshuva-audio-2026-09-23_14-07-36-25-ID-742';

function wav(seconds = 0.25) {
  const rate = 16000;
  const samples = Math.round(seconds * rate);
  const buffer = Buffer.alloc(44 + samples * 2);
  buffer.write('RIFF');
  buffer.writeUInt32LE(buffer.length - 8, 4);
  buffer.write('WAVEfmt ', 8);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(rate, 24);
  buffer.writeUInt32LE(rate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write('data', 36);
  buffer.writeUInt32LE(samples * 2, 40);
  for (let sample = 0; sample < samples; sample++)
    buffer.writeInt16LE(Math.round(1200 * Math.sin(sample * 2 * Math.PI * 440 / rate)), 44 + sample * 2);
  return buffer;
}

test('recording conversion accepts only bounded audio buffers', async () => {
  let conversions = 0;
  const convert = createRecordedAudioConverter(async () => { conversions++; });
  for (const [bytes, name, type] of [
    [Buffer.alloc(0), 'voice.wav', 'audio/wav'],
    [Buffer.alloc(25 * 1024 * 1024 + 1), 'voice.wav', 'audio/wav'],
    [Buffer.from('data'), 'voice.mp4', 'video/mp4'],
    [Buffer.from('data'), '', 'audio/wav'],
    ['not a buffer', 'voice.wav', 'audio/wav'],
  ]) await assert.rejects(convert(bytes, name, type), { code: 'INVALID_AUDIO' });
  assert.equal(conversions, 0);
});

test('recording conversions are serialized, bounded, and recover after failure', async () => {
  let active = 0;
  let peak = 0;
  let calls = 0;
  let releaseFirst;
  const gate = new Promise(resolve => { releaseFirst = resolve; });
  const convert = createRecordedAudioConverter(async () => {
    calls++;
    active++;
    peak = Math.max(peak, active);
    try {
      await gate;
      if (calls === 1) throw new Error('test conversion failed');
      return calls;
    } finally { active--; }
  });
  const tasks = Array.from({ length: 4 }, () => convert(wav(), 'voice.wav', 'audio/wav'));
  const settled = Promise.allSettled(tasks);
  await assert.rejects(convert(wav(), 'voice.wav', 'audio/wav'), { code: 'AUDIO_CONVERSION_BUSY' });
  releaseFirst();
  const results = await settled;
  assert.deepEqual(results.map(result => result.status), ['rejected', 'fulfilled', 'fulfilled', 'fulfilled']);
  assert.equal(peak, 1);
  assert.equal(await convert(wav(), 'voice.wav', 'audio/wav'), 5);
});

test('expired queue entries reject promptly, release capacity, and never convert later', async () => {
  const calls = [];
  let releaseFirst;
  const gate = new Promise(resolve => { releaseFirst = resolve; });
  const convert = createRecordedAudioConverter(async (_buffer, fileName) => {
    calls.push(fileName);
    if (fileName === 'first.wav') await gate;
    return fileName;
  }, { maxQueueWaitMs: 20 });
  const first = convert(wav(), 'first.wav', 'audio/wav');
  const waiting = Array.from({ length: 3 }, (_, index) =>
    convert(wav(), `expired-${index}.wav`, 'audio/wav'));
  const settled = Promise.allSettled(waiting);
  await assert.rejects(convert(wav(), 'full.wav', 'audio/wav'), { code: 'AUDIO_CONVERSION_BUSY' });
  const expired = await settled;
  assert.ok(expired.every(result => result.status === 'rejected' &&
    result.reason.code === 'AUDIO_CONVERSION_BUSY'));
  assert.deepEqual(calls, ['first.wav']);

  const replacement = convert(wav(), 'replacement.wav', 'audio/wav');
  releaseFirst();
  assert.equal(await first, 'first.wav');
  assert.equal(await replacement, 'replacement.wav');
  assert.equal(await convert(wav(), 'next.wav', 'audio/wav'), 'next.wav');
  assert.deepEqual(calls, ['first.wav', 'replacement.wav', 'next.wav']);
});

test('queue expiry is cancelled when conversion starts, even for a longer active conversion', async () => {
  let release;
  let started;
  const gate = new Promise(resolve => { release = resolve; });
  const running = new Promise(resolve => { started = resolve; });
  const convert = createRecordedAudioConverter(async () => {
    started();
    await gate;
    return 'converted';
  }, { maxQueueWaitMs: 5 });
  const result = convert(wav(), 'voice.wav', 'audio/wav');
  await running;
  await new Promise(resolve => setTimeout(resolve, 20));
  release();
  assert.equal(await result, 'converted');
});

test('a queued recording cannot start past its deadline before the timer callback runs', async () => {
  const calls = [];
  let release;
  let started;
  const gate = new Promise(resolve => { release = resolve; });
  const running = new Promise(resolve => { started = resolve; });
  const convert = createRecordedAudioConverter(async (_buffer, fileName) => {
    calls.push(fileName);
    started();
    await gate;
  }, { maxQueueWaitMs: 5 });
  const first = convert(wav(), 'first.wav', 'audio/wav');
  await running;
  const waiting = convert(wav(), 'expired.wav', 'audio/wav');
  const rejected = assert.rejects(waiting, { code: 'AUDIO_CONVERSION_BUSY' });
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  release();
  await first;
  await rejected;
  assert.deepEqual(calls, ['first.wav']);
});

test('real MP3 conversion keeps the complete creator ID/timestamp stem and codec',
  { skip: !hasEncoder }, async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'betshuva-mp3-test-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const result = await convertRecordedAudio(wav(), `${recordingName}_2.wav`, 'audio/wav');
    assert.equal(result.originalname, `${recordingName}_2.mp3`);
    assert.equal(result.mimetype, 'audio/mpeg');
    assert.equal(result.size, result.buffer.length);
    assert.equal(result.durationSeconds, 0.25);
    const mp3 = path.join(directory, 'converted.mp3');
    await fs.writeFile(mp3, result.buffer);
    const { stdout } = await execFileAsync(python, ['-c',
      'import av,json,sys; c=av.open(sys.argv[1]); s=c.streams.audio[0]; print(json.dumps({"format":c.format.name,"codec":s.codec_context.name,"samples":sum(f.samples for f in c.decode(s))}))',
      mp3]);
    const decoded = JSON.parse(stdout);
    assert.equal(decoded.format, 'mp3');
    assert.match(decoded.codec, /^mp3/);
    assert.ok(decoded.samples > 0);
    if (process.env.FFPROBE) {
      const probe = await execFileAsync(process.env.FFPROBE,
        ['-v', 'error', '-show_entries', 'stream=codec_name:format=format_name', '-of', 'json', mp3]);
      const independent = JSON.parse(probe.stdout);
      assert.equal(independent.format.format_name, 'mp3');
      assert.equal(independent.streams[0].codec_name, 'mp3');
    }
    const audio = await probeAudio(result.buffer, result.originalname);
    assert.equal(audio.durationSeconds, 0.25);
    const repeated = await convertRecordedAudio(wav(), `${recordingName}.wav`, 'audio/wav');
    assert.deepEqual(repeated.buffer, result.buffer, 'conversion is stable for hash-based deduplication');
  });

test('real MP3 conversion handles WebM audio but rejects video disguised as audio',
  { skip: !hasEncoder }, async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'betshuva-webm-audio-test-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const input = path.join(directory, 'voice.wav');
    await fs.writeFile(input, wav());
    const fixture = `import av,sys
source=av.open(sys.argv[1])
target=av.open(sys.argv[2], "w", format="webm")
audio=target.add_stream("libopus", rate=48000)
audio.layout="mono"
if sys.argv[3] == "video":
    video=target.add_stream("libvpx", rate=25)
    video.width=16
    video.height=16
    video.pix_fmt="yuv420p"
    frame=av.VideoFrame(16,16,"yuv420p")
    for plane in frame.planes: plane.update(bytes(plane.buffer_size))
    frame.pts=0
    for packet in video.encode(frame): target.mux(packet)
    for packet in video.encode(None): target.mux(packet)
resample=av.AudioResampler(format="fltp", layout="mono", rate=48000)
for decoded in source.decode(audio=0):
    for frame in resample.resample(decoded):
        for packet in audio.encode(frame): target.mux(packet)
for frame in resample.resample(None):
    for packet in audio.encode(frame): target.mux(packet)
for packet in audio.encode(None): target.mux(packet)
target.close()
source.close()
`;
    for (const kind of ['audio', 'video']) {
      const output = path.join(directory, `${kind}.webm`);
      await execFileAsync(python, ['-c', fixture, input, output, kind]);
      const task = convertRecordedAudio(await fs.readFile(output), `${recordingName}.webm`, 'audio/webm');
      if (kind === 'video') await assert.rejects(task, { code: 'INVALID_AUDIO' });
      else {
        const result = await task;
        assert.equal(result.originalname, `${recordingName}.mp3`);
        assert.equal(result.mimetype, 'audio/mpeg');
        assert.ok(Math.abs((await probeAudio(result.buffer, result.originalname)).durationSeconds - 0.25) < 0.01);
      }
    }
  });

test('real conversion enforces decoded duration and accepts exactly two minutes without MP3 padding',
  { skip: !hasEncoder }, async () => {
    await assert.rejects(convertRecordedAudio(wav(121), 'voice.wav', 'audio/wav'),
      { code: 'AUDIO_DURATION_EXCEEDED' });
    const result = await convertRecordedAudio(wav(120), 'voice.wav', 'audio/wav');
    assert.equal(result.durationSeconds, 120);
    assert.equal((await probeAudio(result.buffer, result.originalname)).durationSeconds, 120);
    assert.ok(result.size < 2 * 1024 * 1024);
  });

test('real conversion rejects malformed bytes and does not treat them as a playlist',
  { skip: !hasEncoder }, async () => {
    for (const bytes of [Buffer.from('invalid wav'), Buffer.from('#EXTM3U\nfile:///etc/passwd')])
      await assert.rejects(convertRecordedAudio(bytes, 'voice.wav', 'audio/wav'), { code: 'INVALID_AUDIO' });
  });
