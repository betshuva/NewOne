'use strict';

const DEFAULT_CONTENT_FILTER = Object.freeze({
  text: true,
  video: true,
  nonHumanImages: true,
  men: true,
  women: true,
  children: true,
});

const NEW_ACCOUNT_CONTENT_FILTER = Object.freeze({
  text: true,
  video: false,
  nonHumanImages: true,
  men: false,
  women: false,
  children: false,
});

function normalizeContentFilter(value, fallback = DEFAULT_CONTENT_FILTER) {
  const input = value && typeof value === 'object' && !Array.isArray(value)
    ? value : {};
  return Object.fromEntries(Object.keys(DEFAULT_CONTENT_FILTER).map(key => [
    key, typeof input[key] === 'boolean' ? input[key] : fallback[key],
  ]));
}

// A friend- or group-specific filter replaces the general filter in both
// directions: it may be stricter or more permissive.
function resolveScopedContentFilter(generalFilter, scopedFilter) {
  const general = normalizeContentFilter(generalFilter);
  return scopedFilter == null
    ? general
    : normalizeContentFilter(scopedFilter, general);
}

function imageAllowedByFilter(filter, classification) {
  const detected = classification?.detectedCategories;
  if (Array.isArray(detected) && detected.length) {
    const specificPeopleCategories = ['men', 'women', 'children'];
    const hasSpecificPeopleCategory = detected.some(category =>
      specificPeopleCategories.includes(category));
    return detected.every(category => {
      if (category === 'people')
        return hasSpecificPeopleCategory ||
          specificPeopleCategories.every(value => filter[value] === true);
      return filter[category] === true;
    });
  }
  if (classification?.uncertain === true)
    return ['men', 'women', 'children', 'nonHumanImages']
      .every(category => filter[category] === true);
  const category = classification?.category || 'people';
  if (category === 'people')
    return filter.men && filter.women && filter.children;
  return filter[category] === true;
}

function contentAllowedByFilter(filter, type, classification) {
  const normalized = normalizeContentFilter(filter);
  if (type === 'text' || type === 'sticker' || type === 'audio')
    return normalized.text;
  if (type === 'document')
    return normalized.text &&
      (!(classification?.detectedCategories?.length > 0) ||
        imageAllowedByFilter(normalized, classification));
  if (type === 'video')
    return normalized.video && imageAllowedByFilter(normalized, classification);
  if (type === 'image') return imageAllowedByFilter(normalized, classification);
  return false;
}

module.exports = {
  DEFAULT_CONTENT_FILTER,
  NEW_ACCOUNT_CONTENT_FILTER,
  contentAllowedByFilter,
  imageAllowedByFilter,
  normalizeContentFilter,
  resolveScopedContentFilter,
};
