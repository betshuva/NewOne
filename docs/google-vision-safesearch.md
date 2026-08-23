# Google Vision SafeSearch

The backend runs Google Cloud Vision SafeSearch on image bytes before an
approved upload can be delivered. The key is server-only and must never be
added to Flutter, the web bundle, or Git.

## Google Cloud setup

1. Enable billing and the **Cloud Vision API** in the Google Cloud project.
2. Create a dedicated API key for this server.
3. Restrict the key to the **Cloud Vision API** and to the server's outgoing IP.
4. Add the following values to the untracked `/home/yaniv/NewOne/.env` file:

   ```dotenv
   GOOGLE_VISION_API_KEY=replace-with-the-dedicated-server-key
   GOOGLE_SAFESEARCH_BLOCK_THRESHOLD=POSSIBLE
   GOOGLE_VISION_TIMEOUT_MS=15000
   ```

5. Protect the environment file and restart the backend:

   ```bash
   chmod 600 /home/yaniv/NewOne/.env
   sudo systemctl restart betshuva-app.service
   ```

The status is visible in the admin Vision screen. Once a key is configured,
SafeSearch is enforced: `adult` at the configured threshold blocks the image;
`racy` blocks only at `VERY_LIKELY`, so a standalone `racy: LIKELY` result is
allowed. A timeout, quota/authentication error, or missing annotation keeps
the image pending for retry and never approves it. An `UNKNOWN` moderation
result is rejected immediately because there is no manual-review queue.

Only `SAFE_SEARCH_DETECTION` is requested. Label and face detection are not
sent to Google, which avoids unnecessary feature charges. Local CLIP modesty
and classification checks continue to run as separate required stages.

Uploads larger than the safe inline REST size are converted to a smaller JPEG
in memory for the Google request. The original stored and delivered image is
never changed. Google is called only after the required local stages pass; an
available Google result is reused if a separate local stage requires a retry.
Upload, admin test, and historical report routes are rate-limited. Historical
scans are report-only and never delete or change an already delivered message.

Official references:

- https://docs.cloud.google.com/vision/docs/detecting-safe-search
- https://docs.cloud.google.com/vision/docs/reference/rest/v1/images/annotate
- https://cloud.google.com/vision/pricing
