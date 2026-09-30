# חיבור המייל הפרטי לשרת

המסך נמצא ב־https://betshuva.com/betshuva-app/admin-gmail.html ומקושר מלוח הניהול.
הגישה מחייבת משתמש בעל כתובת מאומתת `yanive8@gmail.com` וסשן תקף. אין צורך בהרשאת מנהל מערכת.
אפשר להתחבר ישירות במסך באמצעות Google. קריאת המיילים אינה מסמנת אותם כנקראו.
התשובות נשלחות בלחיצה על „שליחת תשובה”, לנמען המוצג ובשרשור המקורי.

## הגדרה ב־Google Cloud

1. בפרויקט Google Cloud של לקוח ה־OAuth הקיים, הפעל Gmail API.
2. בשימוש בלקוח Google הקיים נעשה שימוש בכתובת החזרה שכבר הוגדרה ל־Drive:
   `https://betshuva.com/betshuva-app/api/backup/google/callback`.
   בקשות Gmail מזוהות בנפרד באמצעות מצב חד־פעמי בעל קידומת `gmail_`.
   אם מגדירים לקוח OAuth נפרד ל־Gmail, יש להוסיף בו Authorized redirect URI:
   `https://betshuva.com/betshuva-app/api/admin/gmail/callback`.
3. במסך ההסכמה הגדר את ההרשאות `gmail.readonly` ו־`gmail.send`. אם האפליקציה במצב Testing,
   הוסף את `yanive8@gmail.com` כמשתמש בדיקה. הרשאה במצב זה עשויה לדרוש חידוש אחרי שבעה ימים.
4. במסך המייל לחץ על „חיבור Gmail דרך Google”, בחר את החשבון ואשר את שתי ההרשאות.

השרת משתמש ב־`GMAIL_OAUTH_CLIENT_ID` וב־`GMAIL_OAUTH_CLIENT_SECRET` אם הוגדרו.
אחרת נעשה שימוש בזוג הקיים `GOOGLE_DRIVE_OAUTH_CLIENT_ID` / `GOOGLE_DRIVE_OAUTH_CLIENT_SECRET`.
`GMAIL_OAUTH_REDIRECT_URI` מאפשר בחירה מפורשת באחת משתי כתובות החזרה לעיל.
האישור ל־Gmail נפרד מהאישור ל־Drive ואינו מחליף אותו.
מפתח ההצפנה הוא `GMAIL_TOKEN_ENCRYPTION_KEY`, או `BACKUP_TOKEN_ENCRYPTION_KEY` הקיים;
נדרשים לפחות 32 תווים. אין למסור סודות או סיסמאות בצ'אט ואין לשמור אותם במאגר הקוד.
`GMAIL_ACCOUNT_EMAIL` מאפשר להגדיר את בעל התיבה בשרת; קישור הניווט הנוכחי מיועד לחשבון יניב.

## התנהגות ותפעול

- הרשאות OAuth נשמרות מוצפנות בטבלה ייעודית; תוכן המיילים אינו נשמר במסד הנתונים.
- OAuth משתמש ב־PKCE ובמצב חד־פעמי הקשור לדפדפן ולגרסת הסשן.
- מסך ההודעות מציג טקסט בלבד, ללא טעינת תמונות מעקב או הפעלת HTML מהמייל.
- מזהה השליחה מונע שליחה כפולה. אם התוצאה אינה ודאית, יש לבדוק את תיקיית „נשלחו” לפני שליחה חדשה.
- אין מענה אוטומטי ברקע. אין תמיכה בהורדת קבצים מצורפים או בשליחת קבצים במסך זה.
- ביטול גישה נעשה דרך חיבורי צד שלישי בחשבון Google. יש לחדש הרשאה במסך במקרה של ביטול או פקיעת תוקף.

תיעוד: [הרשאות Gmail](https://developers.google.com/workspace/gmail/api/auth/scopes),
[OAuth לשרת](https://developers.google.com/identity/protocols/oauth2/web-server),
[מענה בשרשור](https://developers.google.com/workspace/gmail/api/guides/sending).
