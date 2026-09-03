'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');

test('pending scan queue prioritizes images while protecting aged videos', () => {
  const queue = source.slice(
    source.indexOf('async function retryPendingScans'),
    source.indexOf('async function recoverOrphanedPendingScans'));
  assert.match(queue,
    /WHEN ps\.file_type='video'[\s\S]*interval '15 minutes' THEN 0[\s\S]*WHEN ps\.file_type='image' THEN 1[\s\S]*WHEN ps\.file_type='video' THEN 3/);
  assert.match(queue,
    /priorityClass === 'deferred_video'[\s\S]*file_type='image'[\s\S]*pendingScanRetryRequested = true/);
  assert.match(queue, /A video already being scanned is never interrupted/);
});

test('queue wait time is persisted separately for each file type', () => {
  assert.match(source, /CREATE TABLE IF NOT EXISTS scan_queue_wait_metrics/);
  assert.match(source,
    /INSERT INTO scan_queue_wait_metrics[\s\S]*file_type,priority_class,queue_wait_ms/);
  assert.match(source,
    /SELECT file_type,priority_class,COUNT\(\*\)::int AS samples[\s\S]*PERCENTILE_CONT\(0\.95\)/);
  assert.match(source, /queueWait: queueWaitResult\.rows\.map/);
});
