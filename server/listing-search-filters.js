const VEHICLE_SEARCH_KEYS = Object.freeze(['vehicle_type', 'manufacturer', 'model', 'trim', 'year', 'mileage',
  'fuel', 'transmission', 'engine_volume', 'engine_power', 'drivetrain', 'doors', 'seats', 'ownership',
  'battery_capacity', 'range', 'safety_systems', 'color']);
const PROPERTY_SEARCH_KEYS = Object.freeze(['deal_type', 'property_type', 'street', 'rooms', 'area_sqm', 'floor', 'entry_date', 'furniture']);
const VEHICLE_NUMERIC_KEYS = new Set(['year', 'mileage', 'engine_volume', 'engine_power', 'doors', 'seats', 'battery_capacity', 'range']);
const PROPERTY_NUMERIC_KEYS = new Set(['rooms', 'area_sqm', 'floor']);
const ENUM_KEYS = new Set(['transmission', 'deal_type', 'property_type', 'furniture']);
const NUMERIC_PATTERN = /^[+-]?\d+(?:\.\d+)?$/;

function invalidSearch(message) {
  return Object.assign(new Error(message), { status: 400, code: 'INVALID_LISTING_SEARCH' });
}

function searchNumber(value, label) {
  if (typeof value !== 'string' && typeof value !== 'number') throw invalidSearch(`${label} אינו תקין`);
  const text = String(value).trim().replace(/[\s,]/g, '');
  const number = Number(text);
  if (!NUMERIC_PATTERN.test(text) || !Number.isFinite(number)) throw invalidSearch(`${label} אינו תקין`);
  return number;
}

function parseListingPriceBounds(query) {
  const minimum = query.minPrice === undefined || query.minPrice === '' ? null : searchNumber(query.minPrice, 'מחיר המינימום');
  const maximum = query.maxPrice === undefined || query.maxPrice === '' ? null : searchNumber(query.maxPrice, 'מחיר המקסימום');
  if ((minimum !== null && minimum < 0) || (maximum !== null && maximum < 0))
    throw invalidSearch('המחיר חייב להיות אפס או מספר חיובי');
  if (minimum !== null && maximum !== null && minimum > maximum)
    throw invalidSearch('מחיר המינימום גדול ממחיר המקסימום');
  return { minimum, maximum };
}

function parseListingRadius(value) {
  if (value === undefined || value === '') return 0;
  const number = searchNumber(value, 'רדיוס החיפוש');
  if (number < 0) throw invalidSearch('רדיוס החיפוש חייב להיות אפס או מספר חיובי');
  return number;
}

function listingDetailFilters(query, category, categoryKeys, addParam) {
  const vehicle = category === 'רכב';
  const property = category === 'נדל״ן';
  const keys = vehicle ? VEHICLE_SEARCH_KEYS : property ? PROPERTY_SEARCH_KEYS : categoryKeys[category] || [];
  const column = vehicle ? 'l.vehicle_details' : property ? 'l.property_details' : 'l.category_details';
  const numericKeys = vehicle ? VEHICLE_NUMERIC_KEYS : property ? PROPERTY_NUMERIC_KEYS : new Set();
  let where = '';
  for (const key of keys) {
    const raw = query[`detail_${key}`];
    if (raw === undefined || raw === '') continue;
    if (typeof raw !== 'string') throw invalidSearch('ערך מאפיין החיפוש אינו תקין');
    const value = raw.trim().slice(0, 120);
    if (!value) continue;
    const field = `COALESCE(${column}->>${addParam(key)}, '')`;
    const numericText = value.replace(/[\s,]/g, '');
    const labeledNumber = vehicle && ['seats', 'battery_capacity'].includes(key);
    if (numericKeys.has(key) && (!labeledNumber || NUMERIC_PATTERN.test(numericText))) {
      const number = searchNumber(value, 'הערך המספרי');
      const cleaned = `regexp_replace(${field}, '[[:space:],]', '', 'g')`;
      const numeric = `(CASE WHEN ${cleaned} ~ '^[+-]?[0-9]+([.][0-9]+)?$' THEN ${cleaned}::numeric END)`;
      where += ` AND ${numeric} ${vehicle && key === 'mileage' ? '<=' : '='} ${addParam(number)}`;
    } else if (ENUM_KEYS.has(key) || labeledNumber) {
      where += ` AND LOWER(BTRIM(${field})) = LOWER(${addParam(value)})`;
    } else {
      const escaped = value.replace(/[\\%_]/g, '\\$&');
      where += ` AND ${field} ILIKE ${addParam(`%${escaped}%`)}`;
    }
  }
  return where;
}

module.exports = { VEHICLE_SEARCH_KEYS, PROPERTY_SEARCH_KEYS, listingDetailFilters, parseListingPriceBounds, parseListingRadius };
