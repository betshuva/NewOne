require('dotenv').config({ path: require('path').join(__dirname, '..', '.env'), quiet: true });
const { Client } = require('pg');
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const sellers = [
  '5b2f3bbe-547a-4fe4-aa16-a81642f7cec8', // נאור הכהן
  'affae284-09e0-44ce-86da-9bb944327b4a', // אביב אליהו
];
const cities = ['ירושלים', 'רחובות', 'בני ברק', 'פתח תקווה', 'אשדוד', 'נתניה', 'חיפה', 'בית שמש', 'ראשון לציון', 'מודיעין'];
const cityCoordinates = {
  'ירושלים': [31.7683, 35.2137], 'רחובות': [31.8948, 34.8113],
  'בני ברק': [32.0849, 34.8352], 'פתח תקווה': [32.0840, 34.8878],
  'אשדוד': [31.8014, 34.6435], 'נתניה': [32.3215, 34.8532],
  'חיפה': [32.7940, 34.9896], 'בית שמש': [31.7470, 34.9881],
  'ראשון לציון': [31.9730, 34.7925], 'מודיעין': [31.8969, 35.0104],
};
const categories = {
  'רכב': ['אופני עיר', 'קורקינט מתקפל', 'קסדת רכיבה', 'כיסא בטיחות', 'מטען לרכב', 'ארגונית לתא מטען'],
  'רהיטים': ['שולחן כתיבה', 'כוננית ספרים', 'שידת מגירות', 'כיסא עץ', 'שולחן סלון', 'ארון אחסון'],
  'אלקטרוניקה': ['מסך מחשב', 'מקלדת אלחוטית', 'רמקול נייד', 'נתב אלחוטי', 'מנורת שולחן חכמה', 'אוזניות'],
  'בגדים': ['מעיל חורף', 'נעלי הליכה', 'תיק גב', 'חולצה חדשה', 'מארז צעיפים', 'חליפה חגיגית'],
  'ספרים': ['סט ספרי קודש', 'ספרי ילדים', 'אנציקלופדיה', 'ספרי בישול', 'ספרי לימוד', 'רומנים שמורים'],
  'כלי בית': ['סט סירים', 'מיקסר', 'קומקום חשמלי', 'מארז כלי אחסון', 'מנורת תקרה', 'שואב אבק'],
  'צעצועים': ['ערכת בנייה', 'פאזל גדול', 'משחק קופסה', 'מטבח צעצוע', 'רכבת עץ', 'ערכת יצירה'],
  'אחר': ['עציץ קרמי', 'מזוודה', 'ארגז כלי עבודה', 'ציוד קמפינג', 'מעמד אופניים', 'שעון קיר'],
};
const featuredPhotoSets = [
  Array.from({ length: 8 }, (_, index) =>
    `/betshuva-app/uploads/demo-listings/bike-photo-${index + 1}.jpg`),
  Array.from({ length: 8 }, (_, index) =>
    `/betshuva-app/uploads/demo-listings/desk-photo-${index + 1}.jpg`),
];
const palettes = [
  ['#E3F2FD', '#1976D2', '#90CAF9'], ['#FFF3E0', '#EF6C00', '#FFCC80'],
  ['#E8F5E9', '#2E7D32', '#A5D6A7'], ['#F3E5F5', '#7B1FA2', '#CE93D8'],
  ['#FFF8E1', '#F9A825', '#FFE082'], ['#E0F2F1', '#00796B', '#80CBC4'],
];

function escapeXml(value) {
  return String(value).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&apos;' }[c]));
}

function productSvg(category, label, variant) {
  const [bg, accent, soft] = palettes[variant % palettes.length];
  const x = 220 + variant * 18;
  const shape = category === 'ספרים'
    ? `<rect x="210" y="245" width="420" height="70" rx="12"/><rect x="250" y="330" width="390" height="70" rx="12"/><rect x="190" y="415" width="450" height="70" rx="12"/>`
    : category === 'רהיטים'
      ? `<rect x="230" y="270" width="500" height="190" rx="24"/><path d="M280 460v95M680 460v95M245 335h470"/>`
      : category === 'אלקטרוניקה'
        ? `<rect x="210" y="190" width="540" height="330" rx="28"/><rect x="420" y="520" width="120" height="55"/><path d="M350 580h260"/>`
        : category === 'רכב'
          ? `<circle cx="310" cy="455" r="95"/><circle cx="650" cy="455" r="95"/><path d="M310 455l120-190h130l90 190M430 265l110 190H310"/>`
          : category === 'כלי בית'
            ? `<path d="M300 260h360l-35 270H335z"/><path d="M360 260v-55h240v55M285 325h-75q-55 0-55 60t105 70"/>`
            : category === 'צעצועים'
              ? `<rect x="220" y="370" width="170" height="170" rx="20"/><rect x="395" y="265" width="170" height="275" rx="20"/><rect x="570" y="335" width="170" height="205" rx="20"/>`
              : category === 'בגדים'
                ? `<path d="M370 210l110 65 110-65 150 110-80 110-70-45v190H370V385l-70 45-80-110z"/>`
                : `<rect x="${x}" y="210" width="460" height="330" rx="55"/><circle cx="480" cy="375" r="105"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="960" height="720" viewBox="0 0 960 720">
  <defs><linearGradient id="b" x1="0" y1="0" x2="1" y2="1"><stop stop-color="${bg}"/><stop offset="1" stop-color="#fff"/></linearGradient></defs>
  <rect width="960" height="720" fill="url(#b)"/><circle cx="90" cy="90" r="150" fill="${soft}" opacity=".32"/><circle cx="870" cy="650" r="190" fill="${soft}" opacity=".25"/>
  <g fill="${soft}" stroke="${accent}" stroke-width="18" stroke-linejoin="round" stroke-linecap="round">${shape}</g>
  <text x="480" y="650" text-anchor="middle" direction="rtl" font-family="Arial,sans-serif" font-size="38" font-weight="700" fill="${accent}">${escapeXml(label)}</text>
  <rect x="30" y="30" width="95" height="42" rx="21" fill="${accent}" opacity=".9"/><text x="77" y="59" text-anchor="middle" font-family="Arial,sans-serif" font-size="20" fill="#fff">${variant + 1}/6</text>
</svg>`;
}

async function main() {
  const outputDir = path.join(__dirname, '..', 'uploads', 'demo-listings');
  fs.mkdirSync(outputDir, { recursive: true });
  for (const [category, products] of Object.entries(categories)) {
    for (let variant = 0; variant < 8; variant++) {
      const file = `${Buffer.from(category).toString('hex')}-${variant + 1}.png`;
      await sharp(Buffer.from(productSvg(category, products[variant % products.length], variant)))
        .png({ compressionLevel: 9 })
        .toFile(path.join(outputDir, file));
    }
  }

  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    await client.query('BEGIN');
    const before = (await client.query('SELECT COUNT(*)::int AS n FROM listings')).rows[0].n;
    await client.query('DELETE FROM listing_views');
    await client.query('DELETE FROM listing_images');
    await client.query('DELETE FROM listings');

    const entries = Object.entries(categories);
    for (let i = 0; i < 100; i++) {
      const [category, products] = entries[i % entries.length];
      const product = products[Math.floor(i / entries.length) % products.length];
      const isFree = i % 4 === 0 || i % 11 === 0;
      const condition = ['new', 'like_new', 'good', 'fair', 'for_parts'][i % 5];
      const delivery = ['pickup', 'delivery', 'both'][i % 3];
      const city = cities[i % cities.length];
      const [latitude, longitude] = cityCoordinates[city];
      const price = isFree ? null : 25 + ((i * 73) % 2475);
      const adjective = ['שמור במיוחד', 'איכותי', 'במצב מצוין', 'שימושי לבית', 'מוכן לשימוש'][i % 5];
      const title = `${product} ${adjective}`;
      const description = `${product} ${isFree ? 'למסירה ללא תשלום' : 'למכירה'} ב${city}. המוצר נקי, תואר בכנות ומוכן לאיסוף. כל הפרטים והתמונות מופיעים במודעה. ניתן לפנות בצ׳אט לתיאום.`;
      const featuredPhotos = featuredPhotoSets[i];
      const primaryImageUrl = featuredPhotos?.[0] ||
        `/betshuva-app/uploads/demo-listings/${Buffer.from(category).toString('hex')}-1.png`;
      const inserted = await client.query(
        `INSERT INTO listings
         (user_id,type,title,description,price,city,latitude,longitude,image_url,category,status,
          item_condition,negotiable,quantity,delivery_method,pickup_details,
          contact_phone_visible,created_at,expires_at)
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'active',$11,$12,$13,$14,$15,FALSE,
                now()-($16::text||' hours')::interval,now()+interval '60 days') RETURNING id`,
        [sellers[i % sellers.length], isFree ? 'free' : 'sale', title, description,
         price, city, latitude, longitude,
         primaryImageUrl,
         category, condition, !isFree && i % 3 === 0, 1 + (i % 4), delivery,
         delivery === 'delivery' ? 'משלוח בתיאום מראש' : `איסוף מ${city}`, i]);
      const listingId = inserted.rows[0].id;
      for (let variant = 0; variant < 8; variant++) {
        const url = featuredPhotos?.[variant] || (variant === 0
          ? primaryImageUrl
          : `/betshuva-app/uploads/demo-listings/${Buffer.from(category).toString('hex')}-${variant + 1}.png`);
        await client.query('INSERT INTO listing_images(listing_id,url,sort_order) VALUES($1,$2,$3)', [listingId, url, variant]);
      }
    }
    await client.query('COMMIT');
    const after = await client.query(`SELECT COUNT(*)::int AS listings,
      (SELECT COUNT(*)::int FROM listing_images) AS images FROM listings`);
    console.log({ deletedListings: before, ...after.rows[0] });
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    await client.end();
  }
}

main().catch(error => { console.error(error); process.exit(1); });
