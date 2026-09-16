"use strict";
const { IANAZone } = require("luxon");
const { CANDLE_LIGHTING_MINUTES } = require("./calendar-policy");
const { find: findTimezones } = require("geo-tz/all");
const dataset = require("./data/calendar-locations.json");
const fail = (status, message) => Object.assign(new Error(message), { status });
const normalizeCity = (value) =>
  String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[\u0591-\u05c7]/g, "")
    .replace(/קריית/g, "קרית")
    .replace(/תקווה/g, "תקוה")
    .replace(/[\s\-־–—'"״׳]/g, "");
const isIsrael = (country) =>
  ["ישראל", "israel", "il"].includes(
    String(country || "")
      .trim()
      .toLowerCase(),
  );
const timezoneList = () =>
  [...new Set(["Asia/Jerusalem", "UTC", ...Intl.supportedValuesOf("timeZone")])]
    .filter((zone) => IANAZone.isValidZone(zone))
    .sort();
const countryNames = new Intl.DisplayNames(["he"], { type: "region" });
const englishCountries = new Intl.DisplayNames(["en"], { type: "region" });
const countries = new Map();
for (const row of dataset.places) {
  const code = row[3];
  for (const name of [code, countryNames.of(code), englishCountries.of(code)])
    countries.set(String(name).toLowerCase(), code);
}
function countryCode(country) {
  if (isIsrael(country)) return "IL";
  const alias = {
    ארהב: "US",
    usa: "US",
    us: "US",
    unitedstatesofamerica: "US",
    אנגליה: "GB",
    בריטניה: "GB",
    uk: "GB",
  }[normalizeCity(country)];
  if (alias) return alias;
  return (
    countries.get(
      String(country || "")
        .trim()
        .toLowerCase(),
    ) || null
  );
}
const names = new Map();
for (const row of dataset.places) {
  for (const name of [row[0], ...row[5]]) {
    const key = normalizeCity(name);
    if (!names.has(key)) names.set(key, []);
    if (!names.get(key).includes(row)) names.get(key).push(row);
  }
}
function distance(lat, lon, row) {
  const rad = Math.PI / 180;
  const a =
    Math.sin(((row[1] - lat) * rad) / 2) ** 2 +
    Math.cos(lat * rad) *
      Math.cos(row[1] * rad) *
      Math.sin(((row[2] - lon) * rad) / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
function createLocationResolver(cities) {
  const presetCountry = (item) =>
    item.israel
      ? "IL"
      : { לונדון: "GB", "ניו יורק": "US", פריז: "FR" }[item.city];
  const fromRow = (row, city = row[0]) => {
    return {
      city,
      country: row[3],
      latitude: row[1],
      longitude: row[2],
      timezone: row[4],
      israel: row[3] === "IL",
      candle_minutes: CANDLE_LIGHTING_MINUTES,
    };
  };
  return async ({ city, country, latitude, longitude }) => {
    if (
      (city != null && typeof city !== "string") ||
      (country != null && typeof country !== "string")
    )
      throw fail(400, "שם העיר או המדינה אינו תקין");
    if (typeof city === "string" && city.trim()) {
      city = city.trim();
      if (city.length > 100) throw fail(400, "שם העיר אינו תקין");
      const code = countryCode(country);
      if (country && !code)
        throw fail(404, "לא נמצא מיקום עבור המדינה שהוגדרה");
      const name = normalizeCity(city);
      const alias =
        { תלאביביפו: "תלאביב", telavivyafo: "תלאביב", jerusalem: "ירושלים" }[
          name
        ] || name;
      const preset = cities.find(
        (item) =>
          normalizeCity(item.city) === alias &&
          (!country ||
            code ===
              (item.israel
                ? "IL"
                : { לונדון: "GB", "ניו יורק": "US", פריז: "FR" }[item.city])),
      );
      if (preset)
        return {
          ...preset,
          city,
          country: presetCountry(preset),
          candle_minutes: CANDLE_LIGHTING_MINUTES,
        };
      const matches = (names.get(name) || []).filter(
        (row) => !code || row[3] === code,
      );
      // The project locality picker is Israeli. Prefer its exact locality name
      // when no country was provided, never substitute a geographically nearby city.
      const match =
        matches.find(
          (row) => row[3] === "IL" && row[6] && normalizeCity(row[0]) === name,
        ) ||
        matches.find((row) => row[3] === "IL" && row[6]) ||
        matches.find(
          (row) => row[3] === "IL" && normalizeCity(row[0]) === name,
        ) ||
        (matches.length === 1 ? matches[0] : null);
      if (!match)
        throw fail(
          404,
          "לא נמצא מיקום חד־משמעי עבור העיר שנבחרה. בחרו עיר אחרת מהרשימה",
        );
      return fromRow(match, city);
    }
    const numeric = (value) =>
      typeof value === "number" ||
      (typeof value === "string" && /^[-+]?\d+(?:\.\d+)?$/.test(value.trim()));
    if (
      !numeric(latitude) ||
      !numeric(longitude) ||
      !Number.isFinite(Number(latitude)) ||
      !Number.isFinite(Number(longitude)) ||
      Math.abs(Number(latitude)) > 65 ||
      Math.abs(Number(longitude)) > 180
    )
      throw fail(400, "לא ניתן לחשב זמני שבת וחג עבור המיקום שנבחר");
    latitude = Number(latitude);
    longitude = Number(longitude);
    const zones = findTimezones(latitude, longitude);
    let nearest = null,
      nearestKm = 50;
    const points = [
      ...cities.map((item) => [
        item.city,
        item.latitude,
        item.longitude,
        presetCountry(item),
        item.timezone,
        [],
        true,
      ]),
      ...dataset.places,
    ];
    for (const row of points) {
      if (row[3] === "IL" && !row[6]) continue;
      if (Math.abs(row[1] - latitude) > 0.5 || !zones.includes(row[4]))
        continue;
      const km = distance(latitude, longitude, row);
      if (km < nearestKm) {
        nearest = row;
        nearestKm = km;
      }
    }
    if (!nearest)
      throw fail(404, "לא נמצא יישוב קרוב למיקום. ניתן לבחור עיר מהרשימה");
    return fromRow(nearest);
  };
}
module.exports = {
  createLocationResolver,
  normalizeCity,
  isIsrael,
  timezoneList,
};
