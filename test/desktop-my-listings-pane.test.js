'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');

const source = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

test('desktop keeps the marketplace list beside My Listings', () => {
  const start = source.indexOf('class ListingsScreen');
  const end = source.indexOf('class MyListingsScreen');
  const listings = source.slice(start, end);

  assert.match(listings, /MediaQuery\.sizeOf\(context\)\.width >= 900[\s\S]*?_showMyListings = true/);
  assert.match(listings, /Row\(children: \[[\s\S]*?SizedBox\(width: 410, child: listPane\)/);
  assert.match(listings, /_showMyListings[\s\S]*?MyListingsScreen\([\s\S]*?embedded: true/);
});

test('mobile still opens My Listings as a full route', () => {
  assert.match(source, /else \{[\s\S]*?Navigator\.push\([\s\S]*?MyListingsScreen\(token: widget\.token\)/);
});
