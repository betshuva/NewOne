const modestyImageMessage = 'התמונה נחסמה מטעמי צניעות';

bool isModestyBlockReason(String? reason) =>
    RegExp(r'צניעות|לא צנוע|אינ[וה] צנוע|כללי הלבוש').hasMatch(reason ?? '');
