#!/usr/bin/env node
'use strict';

const { performance } = require('node:perf_hooks');

const target = process.env.LOAD_TARGET || 'http://127.0.0.1:3000/api/version';
const stages = (process.env.LOAD_STAGES || '1,10,25,50,100,250')
  .split(',').map(Number).filter(Number.isFinite);
const durationMs = Number(process.env.LOAD_STAGE_SECONDS || 20) * 1000;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const percentile = (values, p) => {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1)];
};

async function stage(vus) {
  const end = Date.now() + durationMs;
  const timings = [];
  const statuses = new Map();
  let failures = 0;

  async function worker(id) {
    while (Date.now() < end) {
      const started = performance.now();
      try {
        const response = await fetch(target, {
          headers: { 'X-Real-IP': `198.51.100.${(id % 250) + 1}` },
          signal: AbortSignal.timeout(5000),
        });
        await response.arrayBuffer();
        statuses.set(response.status, (statuses.get(response.status) || 0) + 1);
        if (response.status >= 500) failures++;
      } catch (_) {
        failures++;
      } finally {
        timings.push(performance.now() - started);
      }
      await sleep(1000);
    }
  }

  await Promise.all(Array.from({ length: vus }, (_, id) => worker(id)));
  const total = timings.length;
  return {
    vus, total, rps: +(total / (durationMs / 1000)).toFixed(2),
    p50: +percentile(timings, .50).toFixed(1),
    p95: +percentile(timings, .95).toFixed(1),
    p99: +percentile(timings, .99).toFixed(1),
    max: +Math.max(...timings).toFixed(1),
    failures, errorRate: +(failures / Math.max(total, 1) * 100).toFixed(3),
    statuses: Object.fromEntries([...statuses].sort(([a], [b]) => a - b)),
  };
}

(async () => {
  console.log(JSON.stringify({ event: 'start', target, stages, durationSeconds: durationMs / 1000 }));
  for (const vus of stages) {
    const result = await stage(vus);
    console.log(JSON.stringify({ event: 'stage', ...result }));
    if (result.errorRate > 2 || result.p95 > 2000) {
      console.log(JSON.stringify({ event: 'stopped', reason: 'safety-threshold' }));
      process.exitCode = 2;
      return;
    }
    await sleep(2000);
  }
  console.log(JSON.stringify({ event: 'complete' }));
})().catch(error => {
  console.error(JSON.stringify({ event: 'fatal', error: error.message }));
  process.exitCode = 1;
});
