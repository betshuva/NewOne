# Tokens and estimated provider costs in the system audit

The web audit requests `costs=1`. Each step exposes input, output (including
separately reported Gemini thinking), cached input, total tokens, estimated ILS,
model, FX rate/date and completeness. Operation fields summarize all provider
calls, independently of step filtering, pagination, expansion or sorting. All
scalar columns have server-side filtering/sorting and persisted width/order;
amount filters accept decimal shekels. CSV exports include scalar totals and
calculation evidence. Clicking an amount opens the calculation details on mobile
and desktop. Colors and existing layout preferences are preserved.

Accounting uses the append-only `moderation_provider_calls` journal. A call is
counted once by its unique request ID. Existing records link through the audit
providerCallId; new records also retain audit_operation_id directly. The first
referencing event owns the step charge, so duplicate observations do not duplicate
cost. Distinct retries count separately. New operation links preserve operation
accounting when an individual audit step is deleted. Legacy links cannot be
reconstructed after their audit evidence has been deleted. No journal or historic
cost records are rewritten by this migration.

New records snapshot provider rates, cached-input usage, conversion rate/date,
and supplementary billing evidence. OpenAI output already includes reasoning;
Gemini thoughts are added to output only once. Prompt cache input is included in
input tokens and billed at the cached rate, not counted twice. Application cache
reuse and local checks incur zero external API cost, while Vision operations
have unit charges and zero tokens. Missing usage, unknown rates and incomplete
legacy pricing remain null (not zero). Partial totals retain known subtotals in
the amount details and explicitly mark missing data. No provider call is made to
estimate missing usage. The information assistant records each provider round,
including successful rounds before a subsequent failure, and web-search charges.

These are list-price estimates before taxes, account credits, free tiers, volume
discounts and infrastructure costs; they are not provider invoices. Historic USD
snapshots are preserved; conversion uses the displayed current available FX when
no historical FX snapshot exists. No unsupported historic token price is guessed.
New rates use documented standard processing; model-specific configured rates
still take precedence. Cache writes for GPT-5.6 Luna must be reported to compute
its charge; missing cache-write counts leave the price unknown. Its long-context
rates apply above 272,000 input tokens. Gemini 3.6/3.7 Flash promotional prices
switch to published 2027 standard rates on January 1.

Rates verified 2026-09-27:
- OpenAI GPT-4.1 Mini: https://developers.openai.com/api/docs/models/gpt-4.1-mini
- OpenAI GPT-4.1 Nano: https://developers.openai.com/api/docs/models/gpt-4.1-nano
- OpenAI GPT-5.6 Luna: https://developers.openai.com/api/docs/models/gpt-5.6-luna
- OpenAI tool charges: https://developers.openai.com/api/docs/pricing
- Gemini rates: https://ai.google.dev/gemini-api/docs/pricing
- Vision unit rates: https://cloud.google.com/vision/pricing
- Bank of Israel: https://boi.org.il/PublicApi/GetExchangeRates

The seeded BOI rate is 3.033 ILS/USD dated 2026-09-25. The server refreshes at
startup and at most hourly during use, using a 3-second timeout. Failures retain
the dated last-known snapshot and retry after five minutes; no date is invented.
Rate lookup is public and sends no application/user data.

Validation uses disposable PostgreSQL schemas, simulated provider responses and
browser fixtures. Live checks are authenticated GET and read-only SQL; no user
messages or paid test provider requests are sent. This is a web/server deployment;
no Git operation or APK build is required.
