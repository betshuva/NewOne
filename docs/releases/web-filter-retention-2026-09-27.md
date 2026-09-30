# Web update — distinguish destination filtering from moderation

An approved file refused by destination settings is retained for a later send.
The audit status now says “לא נשלח — הגדרות סינון” with an amber filter icon.
Image notices use an amber filter marker and visible caption, and explain that
the file is retained. Modesty rejection keeps its separate concise explanation.

Synchronous upload replies identify destination filtering explicitly. The audit
projection also identifies existing events from the approved stored file and
its recorded filter decision. Delayed image/video destination refusals retain
approved moderation status and clear deletion deadlines. Cleanup excludes files
whose stored scan explicitly says they were not blocked. Actual moderation
rejection takes precedence over personal filtering.

Validation: 1,034 Node tests passed, 211 opt-in tests skipped; 37 Flutter tests
passed; targeted Dart analysis passed. The audit browser regression passed on
desktop and mobile. Additional targeted tests cover moderation precedence.
The live audit API and UI distinguish the reported existing filter refusal;
both stored copies of that image remain present, 50,750 bytes each.

Scope: web/server deployment only. No APK build, version bump or Git operation.

Web build: `806fab09fdeb0d08`.
