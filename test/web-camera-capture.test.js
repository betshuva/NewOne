'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const source = fs.readFileSync(path.join(
  __dirname, '..', 'flutter_app', 'lib', 'web_capture_picker_web.dart'), 'utf8');

test('web camera explicitly starts and verifies the preview', () => {
  assert.match(source, /await _preview\.play\(\)/);
  assert.match(source, /_preview\.videoWidth <= 0/);
  assert.match(source, /_preview\.onCanPlay\.first\.timeout/);
});

test('web recorder handles unsupported codecs and empty recordings', () => {
  assert.match(source, /String\? _supportedMime\(\)/);
  assert.match(source, /html\.MediaRecorder\(_stream!\)/);
  assert.match(source, /_chunks\.isEmpty/);
  assert.match(source, /bytes\.isEmpty/);
  assert.match(source, /addEventListener\('error'/);
  assert.match(source, /recorder\.start\(\);/);
  assert.doesNotMatch(source, /recorder\.start\(1000\)/);
  assert.match(source, /bytes\[0\] == 0x1A[\s\S]*?bytes\[3\] == 0xA3/);
});

test('invalid recorded WebM is rejected before it can be uploaded', () => {
  const serverSource = fs.readFileSync(
    path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
  const mainSource = fs.readFileSync(
    path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(serverSource, /INVALID_VIDEO_CONTAINER/);
  assert.match(serverSource, /hasWebMSignature/);
  assert.match(mainSource, /isVideo \? 210 : 60/);
  assert.match(mainSource, /הזמן המוצג הוא זמן שחלף/);
});

test('camera failures offer an in-dialog retry', () => {
  assert.match(source, /OutlinedButton\.icon\(\s*onPressed: _openCamera/);
  assert.match(source, /label: const Text\('נסה שוב'\)/);
});

test('recording clock uses wall time and an unambiguous LTR display', () => {
  assert.match(source, /final Stopwatch _recordingClock = Stopwatch\(\)/);
  assert.match(source, /_recordingClock\.elapsed\.inSeconds\.clamp\(0, 30\)/);
  assert.match(source, /Duration\(milliseconds: 200\)/);
  assert.match(source, /_recordingClock\.elapsed >= const Duration\(seconds: 30\)/);
  assert.match(source, /textDirection: TextDirection\.ltr/);
  assert.match(source, /_recordingTime\(\)\} \/ 00:30/);
});

test('photo capture prevents duplicate dialogs and duplicate snapshots', () => {
  const mainSource = fs.readFileSync(
    path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
  assert.match(mainSource, /bool _cameraCaptureOpen = false/);
  assert.match(mainSource, /if \(_cameraCaptureOpen\) return/);
  assert.match(mainSource, /finally \{\s*_cameraCaptureOpen = false/);
  assert.match(source, /bool _capturingPhoto = false/);
  assert.match(source, /if \(_capturingPhoto \|\|\s*_preview\.videoWidth <= 0/);
  assert.match(source, /setState\(\(\) => _capturingPhoto = true\)/);
  assert.match(source, /Text\('מעבד את התמונה\.\.\.'\)/);
  assert.match(source, /_ready && !_capturingPhoto \? _takePhoto : null/);
});
