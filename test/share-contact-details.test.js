'use strict';

const fs = require('fs');
const path = require('path');

const server = fs.readFileSync(path.join(__dirname, '..', 'server', 'index.js'), 'utf8');
const flutter = fs.readFileSync(
  path.join(__dirname, '..', 'flutter_app', 'lib', 'main.dart'), 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(server.includes('name, phone, email, city, street, house_number, apartment'),
  'share card must return address fields to the owner');
assert(server.includes("app.patch('/api/profile/share-details'"),
  'missing contact details need a consent-only persistence endpoint');
assert(server.includes("logActivity(req.user.id, 'save_shared_contact_details'"),
  'saving shared contact details must be audited');
assert(flutter.includes('var sharePhone = false;') &&
  flutter.includes('var shareEmail = false;') &&
  flutter.includes('var shareCity = false;') &&
  flutter.includes('var shareAddress = false;'),
  'only the name may be selected by default');
assert(flutter.includes('לשמור את הפרטים בפרופיל לשימוש עתידי?'),
  'missing fields must ask for explicit future-use consent');
assert(flutter.includes("if (selection['city'] == true) 'city': contact['city']!"),
  'selected city must be included in the shared card');
assert(flutter.includes("if (selection['address'] == true) 'address': formattedAddress()"),
  'selected address must be included in the shared card');

console.log('share contact details checks passed');
