const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const filters = require('../server/listing-search-filters');
const source = fs.readFileSync(require.resolve('../server/index.js'), 'utf8');

test('listing search validates price/radius and builds only whitelisted parameterized conditions', () => {
  assert.deepEqual(filters.parseListingPriceBounds({ minPrice: '1,000', maxPrice: '2000' }), { minimum: 1000, maximum: 2000 });
  assert.deepEqual(filters.parseListingPriceBounds({}), { minimum: null, maximum: null });
  for (const query of [{ minPrice: '-1' }, { maxPrice: 'abc' }, { minPrice: '200', maxPrice: '100' },
    { minPrice: ['100'] }, { maxPrice: 'Infinity' }])
    assert.throws(() => filters.parseListingPriceBounds(query), { status: 400 });
  assert.equal(filters.parseListingRadius('0'), 0);
  assert.equal(filters.parseListingRadius('10'), 10);
  for (const radius of ['-1', '10km', 'NaN', ['10']]) assert.throws(() => filters.parseListingRadius(radius), { status: 400 });
  const values = [];
  const sql = filters.listingDetailFilters({ detail_model: "Corolla' OR 1=1 --", detail_unknown: 'anything',
    detail_mileage: '100,000', detail_transmission: 'automatic' }, 'רכב', {}, value => { values.push(value); return `$${values.length}`; });
  assert(!sql.includes('Corolla'));
  assert(!sql.includes('unknown'));
  assert(values.includes("%Corolla' OR 1=1 --%"));
  assert(values.includes(100000));
  assert(sql.includes('<=') && sql.includes('LOWER(BTRIM'));
  assert.equal(filters.VEHICLE_SEARCH_KEYS.length, 18);
});

test('actual listing GET filters every vehicle key, property fields and existing combined search in temporary PostgreSQL tables',
  { skip: process.env.EDUCATION_TEST_DB !== '1' && process.env.RUN_DB_TESTS !== '1' }, async () => {
  require('dotenv').config({ quiet: true });
  const { Client } = require('pg');
  const db = new Client({ connectionString: process.env.DATABASE_URL,
    ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: process.env.DB_REJECT_UNAUTHORIZED !== 'false' } : false });
  await db.connect();
  try {
    await db.query('SET search_path TO pg_temp, public');
    await db.query(`CREATE TEMP TABLE users(id uuid PRIMARY KEY,name text,phone text,email text,profile_pic_url text,
      latitude double precision,longitude double precision);
      CREATE TEMP TABLE listings(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),user_id uuid,type text DEFAULT 'sale',
        title text,description text DEFAULT '',price numeric DEFAULT 100,city text DEFAULT 'רחובות',image_url text,video_url text,
        category text,status text DEFAULT 'active',expires_at timestamptz DEFAULT '2035-01-01',created_at timestamptz DEFAULT now(),
        item_condition text DEFAULT 'good',negotiable boolean,quantity integer,delivery_method text,pickup_details text,
        contact_phone_visible boolean DEFAULT false,contact_preferences jsonb DEFAULT '{}',license_plate text,
        vehicle_details jsonb,property_details jsonb,category_details jsonb,view_count integer DEFAULT 0,contact_count integer DEFAULT 0,
        latitude double precision DEFAULT 31.89,longitude double precision DEFAULT 34.81);
      CREATE TEMP TABLE listing_images(listing_id uuid,url text,sort_order integer);`);
    const [viewer, seller] = [crypto.randomUUID(), crypto.randomUUID()];
    await db.query('INSERT INTO users(id,name,phone,email,latitude,longitude) VALUES($1,$3,$4,$5,31.89,34.81),($2,$3,$4,$5,NULL,NULL)',
      [viewer, seller, 'מוכר', '0551234567', 'private@example.test']);
    const keyStart = source.indexOf('const LISTING_CATEGORY_DETAIL_KEYS =');
    const categoryKeys = vm.runInNewContext(source.slice(keyStart, source.indexOf('function sanitizeListingCategoryDetails', keyStart)) + ';LISTING_CATEGORY_DETAIL_KEYS');
    let handler;
    const start = source.indexOf("app.get('/api/listings', auth,");
    vm.runInNewContext(source.slice(start, source.indexOf('// A compact chat preview', start)), {
      app: { get(route, auth, callback) { handler = callback; } }, auth() {}, getPool: async () => db,
      LISTING_CATEGORY_DETAIL_KEYS: categoryKeys, ...filters, projectProfileImages: async (pool, user, rows) => rows,
    });
    async function search(query, isTeen = false) {
      const res = { code: 200, status(value) { this.code = value; return this; }, set() { return this; },
        json(value) { this.body = value; return this; } };
      await handler({ user: { id: viewer, isTeen }, query }, res);
      return res;
    }
    async function listing(category, details, overrides = {}) {
      const body = { user_id: seller, category, title: crypto.randomUUID(), ...overrides,
        [category === 'רכב' ? 'vehicle_details' : category === 'נדל״ן' ? 'property_details' : 'category_details']: details };
      const keys = Object.keys(body), values = Object.values(body);
      return (await db.query(`INSERT INTO listings(${keys.join(',')}) VALUES(${values.map((_, index) => `$${index + 1}`).join(',')}) RETURNING id`, values)).rows[0].id;
    }
    const vehicle = { vehicle_type: 'משפחתי', manufacturer: 'Toyota', model: 'Corolla', trim: 'יוקרה', year: '2020', mileage: '80,000',
      fuel: 'בנזין', transmission: 'automatic', engine_volume: '1,598', engine_power: '150', drivetrain: 'הנעה קדמית', doors: '4',
      seats: '5', ownership: 'פרטית', battery_capacity: '61–75 קוט״ש', range: '350', safety_systems: 'בלימה אוטונומית', color: 'לבן' };
    const vehicleId = await listing('רכב', vehicle);
    const nonmatching = { vehicle_type: 'מסחרי', manufacturer: 'Honda', model: 'Civic', trim: 'בסיסית', year: '20201', mileage: '150000',
      fuel: 'דיזל', transmission: 'semiautomatic', engine_volume: '15980', engine_power: '1500', drivetrain: '4×4', doors: '14', seats: '15',
      ownership: 'חברה', battery_capacity: '31–45 קוט״ש', range: '3500', safety_systems: 'לא ידוע', color: 'שחור' };
    await listing('רכב', nonmatching);
    for (const key of filters.VEHICLE_SEARCH_KEYS) {
      const result = await search({ category: 'רכב', [`detail_${key}`]: key === 'mileage' ? '100000' : vehicle[key] });
      assert.equal(result.code, 200, `${key}: ${JSON.stringify(result.body)}`);
      assert.deepEqual(result.body.map(item => item.id), [vehicleId], key);
    }
    assert.deepEqual((await search({ category: 'רכב', detail_mileage: '79000' })).body, []);
    assert.equal((await search({ category: 'רכב', detail_mileage: 'not numeric' })).code, 400);
    const seatLabel = await listing('רכב', { seats: '9 ומעלה' });
    assert.deepEqual((await search({ category: 'רכב', detail_seats: '9 ומעלה' })).body.map(item => item.id), [seatLabel]);
    const numericBattery = await listing('רכב', { battery_capacity: '75.0' });
    assert.deepEqual((await search({ category: 'רכב', detail_battery_capacity: '75' })).body.map(item => item.id), [numericBattery]);
    const property = { deal_type: 'rent', property_type: 'apartment', street: 'הרצל', rooms: '4', area_sqm: '100.0', floor: '-1', entry_date: '2026-11-01', furniture: 'full' };
    const propertyId = await listing('נדל״ן', property);
    await listing('נדל״ן', { deal_type: 'for_rent', property_type: 'garden_apartment', street: 'הנביאים', rooms: '14',
      area_sqm: '1000', floor: '-10', entry_date: '2027-01-01', furniture: 'fully_equipped' });
    for (const key of filters.PROPERTY_SEARCH_KEYS) {
      const result = await search({ category: 'נדל״ן', [`detail_${key}`]: property[key] });
      assert.equal(result.code, 200, `${key}: ${JSON.stringify(result.body)}`);
      assert.deepEqual(result.body.map(item => item.id), [propertyId], key);
    }
    const fridge = await listing('מוצרי חשמל', { appliance_type: 'מקרר', brand: 'Samsung', model: 'RB-123' },
      { title: 'מקרר למכירה', price: 500, contact_preferences: { phone: false, email: false } });
    await listing('מוצרי חשמל', { appliance_type: 'מקרר', brand: 'Samsung', model: 'RB-123' }, { title: 'מקרר ישן', price: 50, city: 'חיפה' });
    await listing('מוצרי חשמל', { appliance_type: 'מקרר', brand: 'Samsung' }, { title: 'מקרר סגור', price: 500, status: 'expired' });
    const combined = await search({ category: 'מוצרי חשמל', detail_brand: 'Samsung', q: 'RB-123', minPrice: '100', maxPrice: '600',
      type: 'sale', city: 'רחובות', condition: 'good', sort: 'price_asc' });
    assert.equal(combined.code, 200);
    assert.deepEqual(combined.body.map(item => item.id), [fridge]);
    assert.equal(combined.body[0].seller_phone, null);
    assert.equal(combined.body[0].seller_email, null);
    const giveaway = await listing('רהיטים', { material: 'עץ' }, { type: 'free', price: null, title: 'כיסא למסירה', city: 'רחובות' });
    assert.deepEqual((await search({ category: 'רהיטים', detail_material: 'עץ', type: 'free', maxPrice: '0', city: 'אזור המרכז' })).body.map(item => item.id), [giveaway]);
    const otherCity = await listing('רהיטים', { material: 'עץ' }, { type: 'free', price: null, title: 'כיסא רחוק', city: 'חיפה', latitude: 32.81, longitude: 34.99 });
    const paidChair = await listing('רהיטים', { material: 'עץ' }, { price: 100, title: 'כיסא בתשלום' });
    const byPrice = await search({ category: 'רהיטים', city: 'רחובות', sort: 'price_asc' });
    assert.deepEqual(byPrice.body.map(item => item.id), [giveaway, paidChair]);
    const descending = await search({ category: 'רהיטים', city: 'רחובות', sort: 'price_desc' });
    assert.deepEqual(descending.body.map(item => item.id), [paidChair, giveaway]);
    const nearby = await search({ category: 'רהיטים', radius: '10' });
    assert.equal(nearby.code, 200, JSON.stringify(nearby.body));
    assert(nearby.body.some(item => item.id === giveaway));
    assert(!nearby.body.some(item => item.id === otherCity));
    assert.equal(nearby.body.find(item => item.id === giveaway).distance_km, '0.0');
    for (const query of [{ minPrice: '-1' }, { minPrice: '200', maxPrice: '100' }, { maxPrice: 'bad' }, { radius: 'NaN' }])
      assert.equal((await search(query)).code, 400);
    await db.query('UPDATE users SET latitude=NULL,longitude=NULL WHERE id=$1', [viewer]);
    const missingLocation = await search({ radius: '10' });
    assert.equal(missingLocation.code, 400);
    assert.equal(missingLocation.body.code, 'LISTING_LOCATION_REQUIRED');
    assert.equal((await search({ radius: '0' })).code, 200);
    assert.equal((await search({}, true)).body.length, 0);
    assert.equal((await db.query('SELECT sum(view_count) AS views,sum(contact_count) AS contacts FROM listings')).rows[0].views, '0');
    assert.equal((await db.query('SELECT sum(contact_count) AS contacts FROM listings')).rows[0].contacts, '0');
  } finally { await db.end(); }
});
