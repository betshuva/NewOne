const modestyImageMessage = 'התמונה נחסמה מטעמי צניעות';

bool isModestyBlockReason(String? reason) =>
    RegExp(r'צניעות|לא צנוע|אינ[וה] צנוע|כללי הלבוש').hasMatch(reason ?? '');

const filterOnlyMessage = 'לא נשלח — הגדרות סינון';
const retainedFilterFileMessage =
    'הקובץ נשמר. אפשר לשלוח שוב לאחר שינוי הגדרות הסינון, או להעביר ליעד שמאפשר אותו.';

bool isFilterBlockReason(String? reason) =>
    !isModestyBlockReason(reason) &&
    RegExp(r'הגדרות הסינון|הגדרות סינון|הגדרות הקבוצה|הגדרות הנמען|הסינון של הקבוצה')
        .hasMatch(reason ?? '');
