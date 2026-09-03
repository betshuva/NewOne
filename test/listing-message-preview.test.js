const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const app = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');
const server = fs.readFileSync(
  path.join(__dirname, '..', 'server', 'index.js'), 'utf8');

test('listing chat cards display the primary image without counting a view', () => {
  assert.match(server, /app\.get\('\/api\/listings\/:id\/preview'/);
  const previewRoute = server.slice(
    server.indexOf("app.get('/api/listings/:id/preview'"),
    server.indexOf("app.get('/api/listings/:id',"));
  assert.match(previewRoute, /ORDER BY li\.sort_order LIMIT 1/);
  assert.doesNotMatch(previewRoute, /listing_views|view_count/);
  assert.match(app, /class _ListingMessageCard/);
  assert.match(app, /listings\/\$listingId\/preview/);
  assert.match(app, /_PersistentMediaImage\([\s\S]*?url: imageUrl/);
  assert.match(app, /_ListingMessageCard\([\s\S]*?listingId: listingId/);
});
