'use strict';

const fs = require('fs');
const path = require('path');

const catalogPath = path.join(__dirname, '..', 'listing-catalog.json');
const allowedModes = new Set(['add', 'set', 'remove']);

function readCatalog() {
  const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
  if (catalog.schema_version !== 1 || !Array.isArray(catalog.option_rules)) {
    throw new Error('Invalid listing catalog schema');
  }
  for (const rule of catalog.option_rules) {
    if (!rule.category || !rule.field || !allowedModes.has(rule.mode) ||
        !Array.isArray(rule.values) || rule.values.some(value =>
          typeof value !== 'string' || !value.trim())) {
      throw new Error(`Invalid option rule: ${JSON.stringify(rule)}`);
    }
    if (rule.parents != null &&
        (typeof rule.parents !== 'object' || Array.isArray(rule.parents))) {
      throw new Error('Rule parents must be an object');
    }
  }
  return catalog;
}

function writeCatalog(catalog) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backupPath = `${catalogPath}.${stamp}.bak`;
  const temporaryPath = `${catalogPath}.${process.pid}.tmp`;
  fs.copyFileSync(catalogPath, backupPath, fs.constants.COPYFILE_EXCL);
  catalog.version = new Date().toISOString().replace(/\D/g, '').slice(0, 14);
  catalog.updated_at = new Date().toISOString();
  fs.writeFileSync(temporaryPath, `${JSON.stringify(catalog, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
  });
  fs.renameSync(temporaryPath, catalogPath);
  console.log(JSON.stringify({ ok: true, version: catalog.version, backupPath }));
}

const [command = 'validate', category, field, parentsJson = '{}', ...values] =
  process.argv.slice(2);
const catalog = readCatalog();

if (command === 'validate') {
  console.log(JSON.stringify({
    ok: true,
    version: catalog.version,
    categories: catalog.category_order.length,
    rules: catalog.option_rules.length,
  }));
  process.exit(0);
}

if (!allowedModes.has(command) || !category || !field || values.length === 0) {
  throw new Error(
    'Usage: update-listing-catalog.js add|set|remove <category> <field> <parents-json> <value...>');
}

const parents = JSON.parse(parentsJson);
if (parents == null || typeof parents !== 'object' || Array.isArray(parents)) {
  throw new Error('parents-json must be a JSON object');
}

const normalizedValues = [...new Set(values.map(value => value.trim()).filter(Boolean))];
if (normalizedValues.length === 0) throw new Error('At least one value is required');

catalog.option_rules.push({
  category,
  field,
  parents,
  mode: command,
  values: normalizedValues,
});
writeCatalog(catalog);
