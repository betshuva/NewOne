'use strict';
const MODESTY_IMAGE_MESSAGE = 'התמונה נחסמה מטעמי צניעות';
function imageBlockReason(reason, fileType = 'image', blockedBy = null) {
  if (fileType !== 'image') return reason;
  if (blockedBy === 'dualModesty' || blockedBy === 'modesty' ||
      /צניעות|לא צנוע|אינ[וה] צנוע|כללי הלבוש/.test(String(reason || '')))
    return MODESTY_IMAGE_MESSAGE;
  return reason;
}
module.exports = { imageBlockReason, MODESTY_IMAGE_MESSAGE };
