'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const main = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
const scanner = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'document_scanner.dart'),
  'utf8');
const attachmentMenu = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'chat_attachment_menu.dart'),
  'utf8');

test('private and group menus offer document scanning by photo', () => {
  assert.match(attachmentMenu,
    /_item\(\s*'סריקת מסמך',\s*[\w.]+,\s*[\w.]+,\s*action:\s*ChatAttachmentAction\.scan,\s*allowed:\s*widget\.textAllowed\s*,?\s*\)/);
  const menus = main.match(
    /Future<void>\s+_showAttachMenu\(\)\s+async\s*\{[\s\S]*?\n  \}/g,
  ) || [];
  assert.equal(menus.length, 2);
  for (const scope of ['recipient', 'group']) {
    const allowsText = `_${scope}AllowsText`;
    const matchingMenus = menus.filter((menu) =>
      new RegExp(`textAllowed:\\s*${allowsText}\\b`).test(menu));
    assert.equal(matchingMenus.length, 1, `${scope} uses its text permission`);
    const menu = matchingMenus[0];
    assert.match(menu, /await\s+showChatAttachmentMenu\(/);
    const permissionSwitch = menu.match(
      /final\s+allowed\s*=\s*switch\s*\(action\)\s*\{([\s\S]*?)\};/,
    );
    assert.ok(permissionSwitch, `${scope} checks the selected action`);
    assert.match(permissionSwitch[1],
      new RegExp(`_\\s*=>\\s*${allowsText}\\b`));
    assert.doesNotMatch(permissionSwitch[1], /ChatAttachmentAction\.scan/,
      `${scope} scanning uses the default text permission`);
    assert.match(menu,
      /if\s*\(!allowed\)\s*\{[^}]*\breturn;\s*\}\s*switch\s*\(action\)\s*\{[\s\S]*?case\s+ChatAttachmentAction\.scan:\s*await\s+_scanDocument\(\);/);
  }
});

test('document scanner supports preview, removal and up to twenty PDF pages', () => {
  assert.match(scanner, /int maxPages = 20/);
  assert.match(scanner, /Image\.memory\(/);
  assert.match(scanner, /מחק עמוד/);
  assert.match(scanner, /צלם עמוד נוסף/);
  assert.match(scanner, /הכן PDF/);
  assert.match(scanner, /for \(final pageBytes in pages\)/);
  assert.match(scanner, /pw\.Document\(\)/);
  assert.match(scanner, /PdfPageFormat\.a4/);
  assert.match(scanner, /mimeType: 'application\/pdf'/);
});

test('scanned PDF requires destination confirmation and uses normal document upload', () => {
  assert.match(scanner, /המסמך יישלח אל \$destinationName כקובץ PDF/);
  assert.match(scanner, /צור ושלח/);
  assert.match(main,
    /scanDocumentToPdf\([\s\S]*?_uploadAndSend\(pdf, pdf\.name, 'document'\)/);
  assert.match(main,
    /scanDocumentToPdf\([\s\S]*?_uploadGroupFile\(pdf, pdf\.name, 'document'\)/);
});
