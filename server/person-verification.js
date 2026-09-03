'use strict';

const { recordProviderCall } = require('./provider-usage-log');

function hasLocalPeople(classification) {
  return Array.isArray(classification?.detectedCategories) &&
    classification.detectedCategories.some(category =>
      ['men', 'women', 'children', 'people'].includes(category));
}

function nonHumanClassification(classification, verification) {
  return {
    ...classification,
    category: 'nonHumanImages',
    detectedCategories: ['nonHumanImages'],
    uncertain: false,
    uncertainStage: null,
    people: null,
    originalDetectedCategories: classification?.detectedCategories || [],
    stages: [
      ...(classification?.stages || []),
      {
        name: 'personVerification',
        decision: 'nonHumanImages',
        confidence: verification.confidence,
        providers: verification.providers,
      },
    ],
  };
}

function parseOpenAIDecision(text) {
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

async function classifyOpenAIPersonPresence(buffer, options = {}) {
  const startedAt = performance.now();
  const apiKey = String(options.apiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
  if (!apiKey) return { configured: false, available: false, status: 'not_configured' };
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const model = options.model || process.env.OPENAI_VISION_MODEL || 'gpt-5.6-luna';
  let usageLogged = false;
  let capturedUsage = null;
  try {
    const response = await fetchImpl('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        reasoning: { effort: 'none' },
        max_output_tokens: 120,
        input: [{
          role: 'user',
          content: [
            { type: 'input_text', text: 'Classify whether any human figure is visibly depicted. Count real people, people inside screenshots or embedded photos, and recognizable people in illustrations, drawings or cartoons. Symbols, icons, signs, objects and scenery without a recognizable human figure are non_human. When human figures are present, list every visible demographic category supported by the image: men (adult men), women (adult women), and children (children or teenagers). Multiple categories may apply. Never infer child merely because a face or body is cropped. Return only JSON: {"decision":"person|non_human|uncertain","person_categories":["men|women|children"],"person_category":"men|women|children|uncertain","confidence":0.0,"reason":"short"}.' },
            { type: 'input_image', image_url: `data:image/jpeg;base64,${buffer.toString('base64')}`, detail: 'low' },
          ],
        }],
      }),
      signal: AbortSignal.timeout(30000),
    });
    const data = await response.json().catch(() => ({}));
    const usage = {
      inputTokens: Number(data.usage?.input_tokens || 0),
      outputTokens: Number(data.usage?.output_tokens || 0),
      totalTokens: Number(data.usage?.total_tokens || 0),
    };
    capturedUsage = usage;
    if (!response.ok) {
      await recordProviderCall({ provider: 'openai', model,
        operation: 'person_presence', tracking: options.tracking, status: 'failed',
        usage, usageReported: Boolean(data.usage),
        durationMs: Math.round(performance.now() - startedAt),
        errorCode: data?.error?.code || `HTTP_${response.status}` });
      usageLogged = true;
      throw new Error(data?.error?.message || `OpenAI HTTP ${response.status}`);
    }
    const text = data.output_text || data.output?.flatMap(item => item.content || [])
      .find(item => item.type === 'output_text')?.text;
    const result = parseOpenAIDecision(text);
    if (!result) throw new Error('OpenAI returned an invalid classification');
    await recordProviderCall({ provider: 'openai', model,
      operation: 'person_presence', tracking: options.tracking, status: 'completed',
      usage, usageReported: true,
      durationMs: Math.round(performance.now() - startedAt) });
    usageLogged = true;
    return { configured: true, available: true, status: 'completed', model, ...result,
      durationMs: Math.round(performance.now() - startedAt),
      usage };
  } catch (error) {
    if (!usageLogged) await recordProviderCall({ provider: 'openai', model,
      operation: 'person_presence', tracking: options.tracking, status: 'failed',
      usage: capturedUsage, usageReported: capturedUsage != null,
      durationMs: Math.round(performance.now() - startedAt),
      errorCode: error?.code || error?.name || 'INVALID_RESPONSE' });
    return { configured: true, available: false, status: 'error',
      error: String(error?.message || error).slice(0, 300),
      durationMs: Math.round(performance.now() - startedAt) };
  }
}

async function verifyPersonClassification(buffer, classification, options) {
  // Google person and face detection run for every image. Besides enforcing
  // the final decision, this gives us a stable reference for measuring the
  // local classifier's real-world agreement rate.
  const [objects, faces] = await Promise.all([
    options.scanObjects(buffer),
    options.scanFaces(buffer),
  ]);
  const googleAvailable = objects.available === true && faces.available === true;
  const googleFoundPerson = objects.personDetected === true || faces.faceDetected === true;
  const providers = { googleObjectLocalization: objects, googleFaceDetection: faces };
  const googlePersonCount = Math.max(
    Number(faces.faceCount || faces.faces?.length || 0),
    Number(objects.persons?.length || 0),
  );
  const localCategories = (classification.detectedCategories || [])
    .filter(category => ['men', 'women', 'children'].includes(category));
  // A single local demographic for a photo containing several people is often
  // incomplete (for example, adults surrounding a child). Ask the multimodal
  // model for all visible categories instead of accepting that partial result.
  const needsDemographicReview = googleAvailable && googleFoundPerson && (
    localCategories.length === 0 ||
    (googlePersonCount >= 2 && localCategories.length < 2) ||
    (googlePersonCount === 1 && localCategories.length > 1)
  );
  if (needsDemographicReview) {
    const openai = await (options.classifyOpenAI || classifyOpenAIPersonPresence)(
      buffer, { tracking: options.tracking });
    providers.openai = openai;
    if (openai.available && openai.decision === 'person') {
      const reviewedCategories = Array.isArray(openai.personCategories)
        ? openai.personCategories
        : ['men', 'women', 'children'].includes(openai.personCategory)
          ? [openai.personCategory] : [];
      // This is a corrective review: use the multimodal result rather than
      // retaining the contradictory local category that triggered it.
      const categories = [...new Set(reviewedCategories)];
      if (categories.length) {
        const verifiedClassification = {
          ...classification,
          category: categories.length === 1 ? categories[0] : 'people',
          detectedCategories: categories,
          uncertain: false,
          uncertainStage: null,
        };
        return { classification: verifiedClassification, verification: {
          required: true, decision: 'demographics_reviewed_by_openai',
          confidence: openai.confidence, providers,
        } };
      }
    }
  }
  if (googleFoundPerson) {
    const verifiedClassification = localCategories.length
      ? classification
      : { ...classification, category: 'people', detectedCategories: [],
        uncertain: true, uncertainStage: 'demographics' };
    return { classification: verifiedClassification, verification: {
      required: true, decision: 'person_confirmed',
      confidence: objects.maxPersonScore || faces.faces?.[0]?.detectionConfidence || 0,
      providers,
    } };
  }

  if (!hasLocalPeople(classification) &&
      classification?.uncertain !== true) {
    const verification = {
      required: true,
      decision: 'non_human_google_consensus',
      confidence: 1,
      providers,
    };
    return {
      classification: nonHumanClassification(classification, verification),
      verification,
    };
  }

  const openai = await (options.classifyOpenAI || classifyOpenAIPersonPresence)(
    buffer, { tracking: options.tracking });
  providers.openai = openai;
  if (openai.available && openai.decision === 'person') {
    const categories = Array.isArray(openai.personCategories)
      ? openai.personCategories
      : ['men', 'women', 'children'].includes(openai.personCategory)
        ? [openai.personCategory] : [];
    const verifiedClassification = categories.length
      ? { ...classification,
        category: categories.length === 1 ? categories[0] : 'people',
        detectedCategories: categories,
        uncertain: false, uncertainStage: null }
      : { ...classification, category: 'people', detectedCategories: [],
        uncertain: true, uncertainStage: 'demographics' };
    return { classification: verifiedClassification, verification: { required: true,
      decision: 'person_confirmed_by_openai', confidence: openai.confidence, providers } };
  }
  if (openai.available && openai.decision === 'uncertain') {
    return { classification, verification: { required: true,
      decision: 'uncertain', confidence: openai.confidence, providers } };
  }

  if (!googleAvailable && (!openai.available || openai.decision !== 'non_human')) {
    return { classification, verification: {
      required: true, decision: 'uncertain', confidence: openai.confidence || 0,
      providers,
    } };
  }

  const verification = {
    required: true,
    decision: openai.available ? 'non_human_confirmed' : 'non_human_google_consensus',
    confidence: openai.available ? openai.confidence : 1,
    providers,
  };
  return { classification: nonHumanClassification(classification, verification), verification };
}

module.exports = {
  classifyOpenAIPersonPresence,
  hasLocalPeople,
  parseOpenAIDecision,
  verifyPersonClassification,
};
