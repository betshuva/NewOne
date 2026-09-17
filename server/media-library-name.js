'use strict';

function mediaLibraryName(input, originalName) {
  if (typeof input !== 'string') return null;
  let name = input.trim().normalize('NFC');
  if (!name || name === '.' || name === '..' || /[\x00-\x1f\x7f/\\]/.test(name)) return null;
  const extension = /\.[a-z0-9]{1,16}$/i.exec(originalName || '')?.[0] || '';
  if (extension) {
    if (name.toLowerCase().endsWith(extension.toLowerCase())) {
      name = name.slice(0, -extension.length);
      if (!name.trim() || name === '.' || name === '..') return null;
    }
    // Keep the exact original extension, including its case. Dots within the
    // basename are allowed, but cannot replace the stored file's extension.
    name += extension;
  }
  return [...name].length <= 255 ? name : null;
}

module.exports = { mediaLibraryName };
