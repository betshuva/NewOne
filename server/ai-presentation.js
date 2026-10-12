'use strict';
const { PREFIX, decryptMessageText } = require('./message-at-rest');

function createAiPresentation(answer, verifiedCitations) {
  const citations = [];
  const seen = new Set();
  for (const citation of Array.isArray(verifiedCitations) ? verifiedCitations : []) {
    try {
      const parsed = new URL(citation.url);
      if (parsed.protocol !== 'https:' || parsed.username || parsed.password || seen.has(parsed.href)) continue;
      seen.add(parsed.href);
      citations.push({ index: citations.length + 1,
        title: String(citation.title || parsed.hostname).replace(/[\u0000-\u001f\u007f\u202a-\u202e\u2066-\u2069]/g, ' ')
          .replace(/\s+/g, ' ').trim().slice(0, 100) || parsed.hostname,
        url: parsed.href });
      if (citations.length >= 5) break;
    } catch (_) {}
  }
  if (!citations.length) return null;
  const byUrl = new Map(citations.map(citation => [citation.url, citation.index]));
  const references = [];
  for (const match of String(answer || '').matchAll(/https:\/\/[^\s<>"\\]+/g)) {
    let url = match[0];
    while (!byUrl.has(url) && /[.,;:)\]}!?]$/.test(url)) url = url.slice(0, -1);
    if (!byUrl.has(url)) continue;
    references.push({ index: byUrl.get(url), startIndex: match.index, endIndex: match.index + url.length });
  }
  return { version: 1, format: 'markdown', citations, references };
}

function readAiPresentation(value, answer) {
  if (typeof value !== 'string' || !value.startsWith(PREFIX)) return null;
  try {
    const parsed = JSON.parse(decryptMessageText(value));
    if (parsed.version !== 1 || parsed.format !== 'markdown' || !Array.isArray(parsed.citations)) return null;
    return createAiPresentation(answer, parsed.citations);
  } catch (_) { return null; }
}

module.exports = { createAiPresentation, readAiPresentation };
