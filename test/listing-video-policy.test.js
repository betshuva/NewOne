'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const { listingVideoApproved, validateListingVideoDuration, probeListingVideo, VIDEO_PROBE_VERSION } = require('../server/listing-video-policy');
const { normalizeListingVideoChange, mergeListingVideo } = require('../server/listing-background-images');

const frame = { classification: { category: 'nonHumanImages', detectedCategories: ['nonHumanImages'], uncertain: false } };
const scan = () => ({ classification: { category: 'video', detectedCategories: ['video', 'nonHumanImages'],
  durationSeconds: 10, uncertain: false, sampledFrames: 2, fullyScannedFrames: 2 },
  listingVideoProof: { durationSeconds: 10, source: VIDEO_PROBE_VERSION }, frameResults: [frame, frame] });
const file = details => ({ file_type: 'video', mime_type: 'video/mp4', context_type: 'listing',
  moderation_status: 'approved', moderation_details: details });

test('listing video needs independent short-duration proof and a completed object-only scan for every frame', () => {
  assert.equal(listingVideoApproved(file(scan())), true);
  assert.equal(listingVideoApproved({ ...file(scan()), released_at: 'today', backup_available: true }), true);
  assert.equal(listingVideoApproved({ ...file(scan()), released_at: 'today', backup_available: true,
    content_purged_at: 'today' }), false);
  for (const key of ['pending', 'blocked', 'scanStopped', 'senderFilterRejected', 'destinationFilterRejected', 'deliveryRejected', 'scanSkipped'])
    assert.equal(listingVideoApproved(file({ ...scan(), [key]: true })), false, key);
  for (const details of [{}, { ...scan(), listingVideoProof: undefined },
    { ...scan(), listingVideoProof: { durationSeconds: 10.01, source: VIDEO_PROBE_VERSION } },
    { ...scan(), classification: { ...scan().classification, durationSeconds: 11 } },
    { ...scan(), classification: { ...scan().classification, uncertain: true } },
    { ...scan(), frameResults: [frame] }, { ...scan(), frameResults: [frame, { ...frame, pending: true }] },
    { ...scan(), frameResults: [frame, { classification: { category: 'men', detectedCategories: ['men'] } }] },
    { ...scan(), frameResults: [frame, { ...frame, faces: [{}] }] }])
    assert.equal(listingVideoApproved(file(details)), false, JSON.stringify(details));
  for (const changes of [{ context_type: 'general' }, { file_type: 'image' }, { mime_type: 'image/png' },
    { moderation_status: 'pending' }, { content_purged_at: 'today' }, { released_at: 'today' }])
    assert.equal(listingVideoApproved({ ...file(scan()), ...changes }), false);
  for (const duration of [0, -1, undefined, NaN, Infinity, 10.01, 10.5, 11])
    assert.throws(() => validateListingVideoDuration(duration));
  assert.equal(validateListingVideoDuration(10), 10);
});

test('video scalar changes cannot introduce multiple videos or overwrite later background selection', () => {
  const first = normalizeListingVideoChange({ video_url: '/one.mp4' });
  assert.equal(mergeListingVideo(null, first), '/one.mp4');
  assert.equal(mergeListingVideo('/one.mp4', first), '/one.mp4');
  assert.throws(() => mergeListingVideo('/later.mp4', first), e => e.code === 'LISTING_VIDEO_CHANGED');
  assert.throws(() => normalizeListingVideoChange({ video_url: ['a', 'b'] }));
  assert.throws(() => normalizeListingVideoChange({ video_urls: ['a', 'b'] }));
  assert.equal(mergeListingVideo('/one.mp4', normalizeListingVideoChange({})), '/one.mp4');
});

test('actual encoded videos are checked on the server, including exact ten seconds, overrun and invalid containers', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'listing-video-test-'));
  const python = process.env.WHISPER_PYTHON || path.join(__dirname, '..', '.venv-whisper', 'bin', 'python');
  const exec = promisify(execFile);
  try {
    const program = `import av,numpy as np,sys\nfor count in (60,300,301):\n c=av.open(sys.argv[1]+'/'+str(count)+'.mp4','w'); s=c.add_stream('mpeg4',rate=30); s.width=32; s.height=32; s.pix_fmt='yuv420p'\n for i in range(count):\n  f=av.VideoFrame.from_ndarray(np.zeros((32,32,3),dtype=np.uint8),format='rgb24'); f.pts=i\n  for p in s.encode(f): c.mux(p)\n for p in s.encode(): c.mux(p)\n c.close()`;
    await exec(python, ['-c', program, directory], { timeout: 15000 });
    const short = await probeListingVideo({ path: path.join(directory, '60.mp4') });
    assert.equal(short.source, VIDEO_PROBE_VERSION); assert.ok(short.durationSeconds <= 2.01);
    const exact = await probeListingVideo({ path: path.join(directory, '300.mp4') });
    assert.equal(exact.durationSeconds, 10);
    await assert.rejects(probeListingVideo({ path: path.join(directory, '301.mp4') }), e => e.code === 'LISTING_VIDEO_TOO_LONG');
    const bytes = await fs.readFile(path.join(directory, '60.mp4'));
    assert.equal((await probeListingVideo(bytes, 'untrusted-name.png')).durationSeconds, short.durationSeconds);
    await assert.rejects(probeListingVideo(Buffer.from('invalid video'), 'fake.mp4'), e => e.code === 'LISTING_VIDEO_DURATION_UNKNOWN');
    const webm = await probeListingVideo({ path: path.join(__dirname, 'fixtures/webm-video.webm') });
    assert.ok(webm.durationSeconds > 0 && webm.durationSeconds <= 10);
  } finally { await fs.rm(directory, { recursive: true, force: true }); }
});
