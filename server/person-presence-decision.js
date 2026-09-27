'use strict';

const PERSON_PRESENCE_PROMPT = 'Classify whether any human figure is visibly depicted. Count real people, people inside screenshots or embedded photos, and recognizable people in illustrations, drawings or cartoons. Symbols, icons, signs, objects and scenery without a recognizable human figure are non_human. When human figures are present, list every visible demographic category supported by the image: men (adult men), women (adult women), and children (children or teenagers). Multiple categories may apply. Never infer child merely because a face or body is cropped. Return only JSON: {"decision":"person|non_human|uncertain","person_categories":["men|women|children"],"person_category":"men|women|children|uncertain","confidence":0.0,"reason":"short"}.';

function parsePersonPresenceDecision(text) {
  try {
    const cleaned = String(text || '').replace(/^```(?:json)?\s*|\s*```$/g, '');
    const value = JSON.parse(cleaned);
    if (!['person', 'non_human', 'uncertain'].includes(value.decision)) return null;
    const personCategory = ['men', 'women', 'children', 'uncertain']
      .includes(value.person_category) ? value.person_category : null;
    const personCategories = Array.isArray(value.person_categories)
      ? [...new Set(value.person_categories.filter(category =>
          ['men', 'women', 'children'].includes(category)))]
      : [];
    if (!personCategories.length &&
        ['men', 'women', 'children'].includes(personCategory))
      personCategories.push(personCategory);
    return {
      decision: value.decision,
      confidence: Math.max(0, Math.min(1, Number(value.confidence) || 0)),
      reason: String(value.reason || '').slice(0, 300),
      ...(personCategory ? { personCategory } : {}),
      ...(personCategories.length ? { personCategories } : {}),
    };
  } catch (_) {
    return null;
  }
}

module.exports = { PERSON_PRESENCE_PROMPT, parsePersonPresenceDecision };
