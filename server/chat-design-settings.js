'use strict';

const { randomUUID } = require('node:crypto');
const KEY = 'chat_design_v1';
const DEFAULTS = Object.freeze({
  messageHorizontalPadding: 8, messageVerticalPadding: 5, messageGap: 4,
  privateBubbleWidth: 0.72, groupBubbleWidth: 0.75, voicePlayerWidth: 285,
  composerMinHeight: 36, composerVerticalPadding: 8, composerFontSize: 13,
  composerIconSize: 20, composerActionSize: 44, composerIconGap: 6,
  composerShortcutHeight: 36, composerBackground: '#F0F6FC',
  composerBorderColor: '#C5DFF2', composerIconColor: '#1B6CA8',
  textScale: 1, accentColor: '#1B6CA8', chatBackground: '#EDF5FD',
  incomingBubble: '#FFFFFF', outgoingBubble: '#D8EAFE',
  showFileNames: true, showScanMetadata: true, showGroupDeliverySummary: true,
  compactBlockedMedia: true, compactScanCards: true, compactErrorCards: true,
  compactWaitingCards: true, compactVoicePlayer: true, compactPolls: true,
  showMessageTime: true, timeBesideName: true, showDeliveryStatus: true,
  showComposerEmoji: true, showComposerStickers: true, showTypingIndicator: true,
  showMediaMetadata: true, showVoiceWaveform: true,
  mediaMaxWidth: 220, mediaMaxHeight: 380, gifMaxHeight: 220,
  scanCardWidth: 285, noticeFontSize: 12, voiceWaveformHeight: 40,
  pollOptionSpacing: 4,
  listingLayout: 'list', listingSearchSide: 'right',
  listingImageSize: 110, listingCardPadding: 12, listingCardGap: 12,
  listingCornerRadius: 14, listingTitleSize: 15, listingResultsWidth: 410,
  listingSearchWidth: 760, listingFieldGap: 12,
  listingBackground: '#F5F7FA', listingCardBackground: '#FFFFFF',
  listingShowPrice: true, listingShowLocation: true, listingShowDate: true,
  listingShowPublisher: true, listingShowImages: true, listingShowAi: true,
  listingShowSale: true, listingShowFree: true, listingShowPost: true,
  listingSingleFieldRows: true, listingShowClearButtons: true,
  listingCategoryOrder: [], listingSearchFieldOrder: [],
  dismissComposerOnOutsideTap: true, composerToolsVisibility: 'focused', dismissKeyboardOnSend: true,
  dismissKeyboardOnPicker: true, restoreKeyboardAfterPicker: true,
  closePickerAfterSelection: false, closePickerOnOutsideTap: true,
  messageMenuPresentation: 'auto', messageMenuDismissOnOutsideTap: true,
  messageMenuOrder: [], cardDetailsPresentation: 'dialog',
  cardTapAction: 'details', cardLongPressAction: 'menu',
  autoScrollMode: 'nearBottom', autoScrollDistance: 80, autoScrollDurationMs: 300,
  listingSearchAsYouType: true, listingSearchOnEnter: true,
  listingSearchDebounceMs: 350, listingSearchSectionOrder: [],

});
const ENUMS = {
  composerToolsVisibility: ['always', 'focused', 'withText'],
  messageMenuPresentation: ['auto', 'sheet', 'dialog'],
  cardDetailsPresentation: ['dialog', 'sheet'],
  cardTapAction: ['details', 'none'], cardLongPressAction: ['menu', 'details', 'none'],
  autoScrollMode: ['nearBottom', 'always', 'manual'],
  listingLayout: ['list', 'cards'], listingSearchSide: ['left', 'right'],
};
const RANGES = {
  autoScrollDistance: [0, 240], autoScrollDurationMs: [0, 800], listingSearchDebounceMs: [0, 1500],
  mediaMaxWidth: [140, 330], mediaMaxHeight: [160, 480], gifMaxHeight: [120, 360],
  scanCardWidth: [220, 330], noticeFontSize: [11, 16], voiceWaveformHeight: [24, 64],
  pollOptionSpacing: [0, 16], listingImageSize: [64, 160],
  listingCardPadding: [6, 20], listingCardGap: [4, 24], listingCornerRadius: [0, 24],
  listingTitleSize: [13, 20], listingResultsWidth: [320, 560],
  listingSearchWidth: [320, 900], listingFieldGap: [6, 24],
  composerMinHeight: [36, 60], composerVerticalPadding: [4, 12],
  composerFontSize: [12, 18], composerIconSize: [16, 28], composerActionSize: [36, 56],
  composerIconGap: [0, 12], composerShortcutHeight: [24, 48],
  messageHorizontalPadding: [4, 16], messageVerticalPadding: [2, 12],
  messageGap: [0, 16], privateBubbleWidth: [0.55, 0.9],
  groupBubbleWidth: [0.55, 0.9], voicePlayerWidth: [220, 330], textScale: [0.9, 1.25],
};
function luminance(hex) {
  const channels = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}
function validateSettings(patch) {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) throw new Error('נדרש אובייקט הגדרות');
  const result = {};
  for (const [key, value] of Object.entries(patch)) {
    if (!Object.hasOwn(DEFAULTS, key)) throw new Error(`הגדרה לא מוכרת: ${key}`);
    if (RANGES[key]) {
      const [min, max] = RANGES[key];
      if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max)
        throw new Error(`ערך מחוץ לטווח: ${key}`);
    } else if (ENUMS[key]) {
      if (!ENUMS[key].includes(value)) throw new Error(`אפשרות לא תקינה: ${key}`);
    } else if (['listingCategoryOrder', 'listingSearchFieldOrder', 'messageMenuOrder', 'listingSearchSectionOrder'].includes(key)) {
      if (!Array.isArray(value) || value.length > 50 || new Set(value).size !== value.length ||
          value.some(v => typeof v !== 'string' || !v.trim() || v.length > 80))
        throw new Error('סדר קטגוריות לא תקין');
    } else if (typeof DEFAULTS[key] === 'boolean') {
      if (typeof value !== 'boolean') throw new Error(`נדרש ערך כן או לא: ${key}`);
    } else {
      if (typeof value !== 'string' || !/^#[0-9a-f]{6}$/i.test(value)) throw new Error(`צבע לא תקין: ${key}`);
      const light = luminance(value);
      if (['accentColor', 'composerIconColor'].includes(key) ? 1.05 / (light + 0.05) < 4.5 : light < 0.6)
        throw new Error(`הצבע אינו קריא: ${key}`);
    }
    result[key] = value;
  }
  return result;
}
function decodeDocument(value) {
  try {
    const document = typeof value === 'string' ? JSON.parse(value) : value;
    if (document?.schemaVersion !== 1 || typeof document.revision !== 'string') throw new Error('schema');
    return { schemaVersion: 1, revision: document.revision,
      settings: { ...DEFAULTS, ...validateSettings(document.settings) } };
  } catch (_) { return { schemaVersion: 1, revision: 'initial', settings: { ...DEFAULTS } }; }
}
function registerChatDesignRoutes(app, { getPool, adminAuth, notify = () => {} }) {
  let cached;
  async function read() {
    if (cached && cached.until > Date.now()) return cached.document;
    const pool = await getPool();
    const result = await pool.query('SELECT value FROM app_settings WHERE key_name=$1', [KEY]);
    const document = decodeDocument(result.rows[0]?.value);
    cached = { document, until: Date.now() + 15000 };
    return document;
  }
  app.get('/api/chat-design', async (_req, res) => {
    res.set('Cache-Control', 'no-store');
    try { res.json(await read()); }
    catch (_) { res.status(503).json({ error: 'ההגדרות אינן זמינות כרגע' }); }
  });
  app.get('/api/admin/chat-design', adminAuth, async (_req, res) => {
    res.set('Cache-Control', 'no-store');
    try { res.json({ ...await read(), defaults: DEFAULTS, ranges: RANGES, options: ENUMS }); }
    catch (_) { res.status(503).json({ error: 'ההגדרות אינן זמינות כרגע' }); }
  });
  app.put('/api/admin/chat-design', adminAuth, async (req, res) => {
    if (req.adminPerm !== 'edit') return res.status(403).json({ error: 'נדרשת הרשאת עריכה' });
    let patch;
    try { patch = validateSettings(req.body?.settings); }
    catch (error) { return res.status(400).json({ error: error.message }); }
    if (typeof req.body?.expectedRevision !== 'string')
      return res.status(400).json({ error: 'נדרשת גרסת ההגדרות הקיימת' });
    let client;
    try {
      client = await (await getPool()).connect();
      await client.query('BEGIN');
      await client.query('SELECT pg_advisory_xact_lock(671734295)');
      const result = await client.query('SELECT value FROM app_settings WHERE key_name=$1 FOR UPDATE', [KEY]);
      const current = decodeDocument(result.rows[0]?.value);
      if (current.revision !== req.body.expectedRevision) {
        await client.query('ROLLBACK');
        return res.status(409).json({ error: 'ההגדרות השתנו; טען אותן מחדש' });
      }
      const document = { schemaVersion: 1, revision: randomUUID(), settings: { ...current.settings, ...patch } };
      await client.query(`INSERT INTO app_settings(key_name,value,updated_at) VALUES($1,$2,now())
        ON CONFLICT(key_name) DO UPDATE SET value=EXCLUDED.value,updated_at=now()`, [KEY, JSON.stringify(document)]);
      await client.query('COMMIT');
      cached = { document, until: Date.now() + 15000 };
      res.json(document);
      try { notify({ revision: document.revision }); } catch (_) {}
    } catch (_) {
      if (client) await client.query('ROLLBACK').catch(() => {});
      res.status(500).json({ error: 'שמירת ההגדרות נכשלה' });
    } finally { client?.release(); }
  });
}
module.exports = { DEFAULTS, RANGES, ENUMS, KEY, validateSettings, decodeDocument, registerChatDesignRoutes };
