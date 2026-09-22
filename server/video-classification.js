'use strict';

function videoDetectedCategories(frameResults) {
  const categories = new Set(['video']);
  // Raw video scores are diagnostic only. Each frame has already passed the
  // same person verification and content checks used for still images.
  for (const frame of frameResults) {
    for (const category of frame?.classification?.detectedCategories || [])
      categories.add(category);
  }
  return [...categories];
}

module.exports = { videoDetectedCategories };
