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

const UNFILTERED_ASSISTANT_IDS = Object.freeze([
  '00000000-0000-4000-8000-000000000002',
  '00000000-0000-4000-8000-000000000003',
]);

// Only private conversations with these built-in accounts ignore category
// preferences. File safety, access, and group policies remain separate checks.
function isUnfilteredAssistantConversation(firstId, secondId) {
  return UNFILTERED_ASSISTANT_IDS.includes(firstId) ||
    UNFILTERED_ASSISTANT_IDS.includes(secondId);
}

function normalizeContentFilter(value, fallback = DEFAULT_CONTENT_FILTER) {
  const input = value && typeof value === 'object' && !Array.isArray(value)
    ? value : {};
  // Text and non-human images remain available even for saved legacy filters.
  return Object.fromEntries(Object.keys(DEFAULT_CONTENT_FILTER).map(key => [
    key, key === 'text' || key === 'nonHumanImages'
      ? true : typeof input[key] === 'boolean' ? input[key] : fallback[key],
  ]));
}

// General settings are inherited by default. Optional enforcement makes them
// an upper bound: a scoped override may tighten, but cannot permit blocked types.
function resolveScopedContentFilter(generalFilter, scopedFilter) {
  const general = normalizeContentFilter(generalFilter);
  const scoped = normalizeContentFilter(scopedFilter, general);
  if (generalFilter?.enforceGeneralFilter !== true) return scoped;
  return Object.fromEntries(Object.keys(DEFAULT_CONTENT_FILTER).map(key =>
    [key, general[key] && scoped[key]]));
}

function imageAllowedByFilter(filter, classification) {
  const detected = classification?.detectedCategories;
  if (Array.isArray(detected) && detected.length) {
    const specificPeopleCategories = ['men', 'women', 'children'];
    const hasSpecificPeopleCategory = detected.some(category =>
      specificPeopleCategories.includes(category));
    return detected.every(category => {
      if (category === 'nonHumanImages') return true;
      if (category === 'people')
        return hasSpecificPeopleCategory ||
          specificPeopleCategories.every(value => filter[value] === true);
      return filter[category] === true;
    });
  }
  if (classification?.uncertain === true)
    return ['men', 'women', 'children']
      .every(category => filter[category] === true);
  const category = classification?.category || 'people';
  if (category === 'nonHumanImages') return true;
  if (category === 'people')
    return filter.men && filter.women && filter.children;
  return filter[category] === true;
}

// A caption adds visual categories; it never replaces the attached file's scan.
function combineMessageClassifications(fileClassification, emojiClassification, fileType = null) {
  if (emojiClassification?.inlineEmoji !== true) return fileClassification || null;
  if (!fileClassification && ['image', 'video'].includes(fileType))
    fileClassification = { category: 'people', uncertain: true };
  const categories = value => {
    const detected = Array.isArray(value?.detectedCategories) && value.detectedCategories.length
      ? value.detectedCategories : value?.category ? [value.category] : [];
    // A known caption category cannot resolve an uncertain or unspecified
    // person in the file's independent scan (or the other way around).
    const people = ['men', 'women', 'children'];
    return value?.uncertain === true ||
      (detected.includes('people') && !detected.some(category => people.includes(category)))
      ? [...detected, ...people] : detected;
  };
  return { ...(fileClassification || emojiClassification),
    detectedCategories: [...new Set([...categories(fileClassification), ...categories(emojiClassification)])],
    uncertain: fileClassification?.uncertain === true || emojiClassification.uncertain === true,
    inlineEmoji: true,
    ...Object.fromEntries(['artworkVersion', 'moderationVersion', 'artworkHash']
      .filter(key => emojiClassification[key] !== undefined)
      .map(key => [key, emojiClassification[key]])) };
}

function contentAllowedByFilter(filter, type, classification) {
  const normalized = normalizeContentFilter(filter);
  if (classification?.inlineEmoji === true && !imageAllowedByFilter(normalized, classification))
    return false;
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
  UNFILTERED_ASSISTANT_IDS,
  isUnfilteredAssistantConversation,
  contentAllowedByFilter,
  combineMessageClassifications,
  imageAllowedByFilter,
  normalizeContentFilter,
  resolveScopedContentFilter,
};
