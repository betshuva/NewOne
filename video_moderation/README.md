# Local Video Classification Server

שירות בדיקה מקומי לסיווג סרטונים. הוא דוגם פריימים, מזהה אנשים באמצעות YOLO,
מסווג `child` / `woman` / `man` / `landscape` באמצעות CLIP ובודק תוכן רגיש
באמצעות מודל מקומי. הסרטון הזמני נמחק בסיום הבדיקה.

טווחי ההחלטה אינם חופפים: ציון מתחת ל־`0.50` מאושר, `0.50–0.74` מועבר
ל־`review` ואינו נשלח אוטומטית, ו־`0.75` ומעלה נחסם.

> הסיווג הדמוגרפי הוא הערכת מודל ואינו ודאי. אין להשתמש בו כהחלטה אנושית או
> בטיחותית יחידה. התוצאה `review` נועדה למקרים שאינם ודאיים.

## הרצה ב-Docker

```bash
cd video_moderation
docker compose up --build
```

בפעם הראשונה יורדים קובצי המודלים, ולכן האתחול והבדיקה הראשונה אורכים יותר.
התיעוד האינטראקטיבי זמין ב-`http://SERVER_IP:8080/docs`.

## בדיקה

```bash
curl -X POST http://localhost:8080/analyze \
  -F "video=@sample.mp4"
```

## GPU

ה-Dockerfile הבסיסי עובד עם CPU. בשרת NVIDIA יש להתקין NVIDIA Container Toolkit,
להשתמש בגרסת PyTorch תואמת CUDA, להגדיר `MODEL_DEVICE=0`, ולהוסיף לשירות Compose:

```yaml
gpus: all
```

## שילוב באפליקציה

הנתיב `POST /analyze` מקבל multipart בשם `video`. התשובה כוללת `decision`
(`allowed`, `review`, `blocked`), ציוני `labels`, זמנים שבהם נמצאו סיווגים והסבר.
מומלץ להציב את השירות מאחורי HTTPS ואימות לפני חשיפה לאינטרנט.

כל סרטון נדגם בהתחלה, באמצע ובפריים האחרון, ובנוסף כל 5 שניות.
פריים שנבחר פעמיים נבדק פעם אחת. סרטון עם פחות משלושה פריימים ניתנים לפענוח אינו מאושר.


Uploads are accepted without a configured byte-size ceiling. Video duration is
limited to 90 minutes. Packet timestamps and keyframe seeks choose at most 20
unique frames spaced uniformly over the actual video timeline, always including
the first and last decodable frames. Both endpoints are analyzed before interior
frames. Short clips with fewer frames are sampled without duplicates. The
service rejects unreadable timelines instead of approving an incomplete scan.
