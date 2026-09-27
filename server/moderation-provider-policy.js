'use strict';

function openAIEnabled() {
  return String(process.env.OPENAI_ENABLED || '').trim().toLowerCase() !== 'false';
}

function openAIModerationEnabled() {
  return openAIEnabled() &&
    String(process.env.MODERATION_OPENAI_ENABLED || '').trim().toLowerCase() !== 'false';
}

function moderationProviderPolicy() {
  if (!openAIModerationEnabled()) return 'google_gemini';
  return openAIModerationRequired() ? 'google_openai_gemini' : 'google_gemini_optional_openai';
}

function openAIModerationRequired() {
  return openAIModerationEnabled() &&
    String(process.env.MODERATION_OPENAI_REQUIRED || '').trim().toLowerCase() !== 'false';
}

function disabledModerationProviderResult() {
  return { configured: false, available: false, required: false,
    status: 'disabled', reasonCode: 'provider_disabled' };
}

module.exports = { openAIEnabled, openAIModerationEnabled, openAIModerationRequired, moderationProviderPolicy,
  disabledModerationProviderResult };
