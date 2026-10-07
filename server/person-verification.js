'use strict';

const { recordProviderCall } = require('./provider-usage-log');
const { guardModerationProvider, providerRequestSignal } = require('./moderation-provider-guard');
const { openAIModerationEnabled, openAIModerationRequired } = require('./moderation-provider-policy');
const { classifyGeminiPersonPresence } = require('./gemini-person-verification');
const { PERSON_PRESENCE_PROMPT, parsePersonPresenceDecision: parseOpenAIDecision } =
  require('./person-presence-decision');
const sharp = require('sharp');

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

async function classifyOpenAIPersonPresence(buffer, options = {}) {
  const apiKey = String(options.apiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
  return guardModerationProvider({ provider: 'openai', operation: 'person_presence',
    apiKey, options, run: () => requestOpenAIPersonPresence(buffer, options) });
}

async function requestOpenAIPersonPresence(buffer, options) {
  const startedAt = performance.now();
  const apiKey = String(options.apiKey ?? process.env.OPENAI_API_KEY ?? '').trim();
  if (!apiKey) return { configured: false, available: false, status: 'not_configured' };
  const fetchImpl = options.fetchImpl || globalThis.fetch;
  const model = options.model || process.env.OPENAI_VISION_MODEL || 'gpt-5.6-luna';
  let capturedUsage = null;
  let capturedUsageReported = false;
  try {
    const response = await fetchImpl('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        store: false,
        reasoning: { effort: 'none' },
        max_output_tokens: 120,
        input: [{
          role: 'user',
          content: [
            { type: 'input_text', text: PERSON_PRESENCE_PROMPT },
            // Small background details must remain distinguishable from people.
            // Use the same fidelity as the clothing review, without cropping.
            { type: 'input_image', image_url: `data:image/jpeg;base64,${buffer.toString('base64')}`, detail: 'high' },
          ],
        }],
      }),
      signal: providerRequestSignal(options, 30000),
    });
    const data = await response.json().catch(() => ({}));
    const usage = {
      inputTokens: Number(data.usage?.input_tokens || 0),
      cachedInputTokens: Number(data.usage?.input_tokens_details?.cached_tokens || 0),
      cacheWriteTokens: data.usage?.input_tokens_details?.cache_write_tokens ?? null,
      outputTokens: Number(data.usage?.output_tokens || 0),
      totalTokens: Number(data.usage?.total_tokens || 0),
    };
    capturedUsage = usage;
    capturedUsageReported = Boolean(data.usage);
    if (!response.ok) {
      const error = new Error(data?.error?.message || `OpenAI HTTP ${response.status}`);
      error.code = data?.error?.code || `HTTP_${response.status}`;
      throw error;
    }
    const text = data.output_text || data.output?.flatMap(item => item.content || [])
      .find(item => item.type === 'output_text')?.text;
    const result = parseOpenAIDecision(text);
    if (!result) throw Object.assign(new Error('OpenAI returned an invalid classification'), { code: 'INVALID_RESPONSE' });
    const responseResult = { configured: true, available: true, status: 'completed', model, ...result,
      durationMs: Math.round(performance.now() - startedAt), usage };
    await recordProviderCall({ provider: 'openai', model,
      operation: 'person_presence', tracking: options.tracking, status: 'completed',
      usage, usageReported: capturedUsageReported,
      durationMs: responseResult.durationMs, result: responseResult });
    return responseResult;
  } catch (error) {
    const result = { configured: true, available: false, status: 'error',
      errorCode: String(error?.code || error?.name || 'INVALID_RESPONSE'),
      error: String(error?.message || error).slice(0, 300),
      durationMs: Math.round(performance.now() - startedAt) };
    await recordProviderCall({ provider: 'openai', model,
      operation: 'person_presence', tracking: options.tracking, status: 'failed',
      usage: capturedUsage, usageReported: capturedUsageReported,
      durationMs: result.durationMs, errorCode: result.errorCode, result });
    return result;
  }
}

async function verifyPersonClassification(buffer, classification, options) {
  let reviewProvider = openAIModerationEnabled() ? 'openai' : 'gemini';
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
  const classifyPerson = async (expectPerson = false) => {
    let review;
    if (reviewProvider === 'openai') {
      review = await (options.classifyOpenAI || classifyOpenAIPersonPresence)(buffer,
        { tracking: options.tracking });
      providers.openai = review;
      const categories = review.personCategories || [review.personCategory];
      const resolved = review.available === true && (!expectPerson && review.decision === 'non_human' ||
        review.decision === 'person' && categories.some(value => ['men', 'women', 'children'].includes(value)));
      if (openAIModerationRequired() || resolved) return review;
      reviewProvider = 'gemini';
    }
    review = await (options.classifyGemini || classifyGeminiPersonPresence)(buffer,
      { tracking: options.tracking });
    providers.gemini = review;
    return review;
  };
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
    const review = await classifyPerson(true);
    providers[reviewProvider] = review;
    if (review.available && review.decision === 'person') {
      const reviewedCategories = Array.isArray(review.personCategories)
        ? review.personCategories
        : ['men', 'women', 'children'].includes(review.personCategory)
          ? [review.personCategory] : [];
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
          required: true, decision: `demographics_reviewed_by_${reviewProvider}`,
          confidence: review.confidence, providers,
        } };
      }
    }
    if (reviewProvider === 'gemini') {
      return { classification: {
        ...classification, category: 'people', detectedCategories: localCategories,
        uncertain: true, uncertainStage: 'demographics',
      }, verification: {
        required: true, decision: 'uncertain', confidence: review.confidence || 0,
        providers,
      } };
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

  if (googleAvailable && !hasLocalPeople(classification) &&
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

  // A covered video lens can produce only black pixels plus compression noise.
  // Inspect every pixel, without resizing; a dark scene with visible detail
  // must still receive the normal person review.
  if (options.videoFrame === true && googleAvailable &&
      !hasLocalPeople(classification)) {
    const pixels = await sharp(buffer).removeAlpha().stats().catch(() => null);
    if (pixels?.channels.length &&
        pixels.channels.every(channel => channel.max <= 4)) {
      providers.videoFramePixels = {
        available: true,
        maximum: Math.max(...pixels.channels.map(channel => channel.max)),
        blackThreshold: 4,
      };
      const verification = {
        required: true, decision: 'non_human_blank_video_frame',
        confidence: 1, providers,
      };
      return {
        classification: nonHumanClassification(classification, verification),
        verification,
      };
    }
  }

  // Face/object detection can miss recognizable human drawings. Negative
  // Google results cannot erase local human evidence when the drawing-aware
  // review is unavailable or uncertain.
  const review = await classifyPerson();
  providers[reviewProvider] = review;
  if (review.available && review.decision === 'person') {
    const categories = Array.isArray(review.personCategories)
      ? review.personCategories
      : ['men', 'women', 'children'].includes(review.personCategory)
        ? [review.personCategory] : [];
    const verifiedClassification = categories.length
      ? { ...classification,
        category: categories.length === 1 ? categories[0] : 'people',
        detectedCategories: categories,
        uncertain: false, uncertainStage: null }
      : { ...classification, category: 'people', detectedCategories: [],
        uncertain: true, uncertainStage: 'demographics' };
    return { classification: verifiedClassification, verification: { required: true,
      decision: `person_confirmed_by_${reviewProvider}`, confidence: review.confidence, providers } };
  }
  if (!review.available || review.decision !== 'non_human') {
    const localPeople = hasLocalPeople(classification);
    return { classification: {
      ...classification,
      category: localPeople ? classification.category : null,
      detectedCategories: localPeople ? classification.detectedCategories : [],
      uncertain: true,
      uncertainStage: 'personVerification',
    }, verification: {
      required: true, decision: 'uncertain', confidence: review.confidence || 0,
      providers,
    } };
  }

  const verification = {
    required: true,
    decision: reviewProvider === 'gemini' ? 'non_human_confirmed_by_gemini' : 'non_human_confirmed',
    confidence: review.confidence,
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
