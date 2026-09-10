# Safe Information web search — 9 September 2026

Safe Information offers hosted `web_search` alongside the internal marketplace tool, including listing searches and rounds following internal search results. Explicit internet requests force search; appraisals with internal references first load every referenced listing before forcing the price-comparison search. The assistant may research external listings, current prices and manufacturer specifications without asking the user to request internet research separately. Listing replies retain only internal Betshuva opening links. External URLs, website names/attributions and source/date footers are omitted; search citations still undergo internal validation before their claims can be shown.

Listing appraisals use a strict structured response containing a reasoned `conclusion` and exactly two `checks`; the client receives ordinary Hebrew prose, not JSON. The prompt targets roughly 60–90 words overall: a two- or three-sentence conclusion of 45–55 words and up to 12 words per check. The conclusion explains the price comparison's relevance, connects meaningful listing facts or actual photo observations to the decision, and identifies missing information that could change the assessment. It must not pad a sparse answer or treat a seller's claimed condition or mileage as proof of soundness. Server formatting allows up to 58 words/500 characters for the conclusion and 14 words/125 characters per check, keeping the complete answer below 90 words/800 characters and preserving uncertainty when shortening. Appraisals require an actual completed hosted web search after current listing facts and available photos are loaded. A failed or ignored search, inaccessible listing, missing evidence or rejected source cannot produce an unverified buying verdict. The fallback retains a known requested price and two checks; vehicle details are recognized both as objects and as the marketplace's serialized JSON. Explicit internet opt-outs and internal-only requests are respected, and photo-only comparisons do not become price appraisals. Listing searches still show up to three concise results and use the existing 80-word/600-character bound. Ordinary information questions keep their verified visible web citations.

After an adult's marketplace lookup, the server loads up to eight images belonging to the returned active, unexpired listings and attaches them as labelled `input_image` inputs. Opening a specific listing keeps its images separate from unrelated listings returned during the same answer. Registered photos must belong to the listing's owner and have approved moderation status; the server also recognizes its own public demo assets. Local reads and the fixed-origin cloud-media fallback are bounded, decoded, resized and stripped of metadata before sending JPEG data. Missing photos leave the text answer available. The assistant describes visible details only and must not infer mechanical condition, warranty or hidden defects from a photo.

External claims are displayed only after citations accepted from API URL annotations or exact URLs present in the hosted search tool's returned sources pass the application's existing link inspection. Unknown links are removed; failed source validation withholds the researched answer. In ordinary information replies, the web client displays accepted HTTPS links inline and uses its existing confirmation before leaving the application. In listing replies these links stay hidden. Teen searches use a limited official/service-domain list and cannot access the marketplace. Previously rejected secret messages are excluded from provider history.

For a brief listing answer containing neither citation annotations nor visible web addresses, the server also accepts up to five eligible consulted sources returned by the hosted search itself and runs the same source checks on them. Missing citations in intentionally link-free prose therefore do not automatically reject the answer. An invented visible URL or rejected annotation cannot use this fallback. If external validation still fails, the researched answer is discarded: current authorized internal listing titles, requested prices and declared conditions produce a short factual response that says there is insufficient information to compare prices. That fallback never reuses the failed research's market price, photo claims or buying recommendation.

The temporary Safe Information link rejection was removed from private routes. Normal link checks remain. The accidental copy in the group socket handler was removed, eliminating the undefined `toUserId` reference while preserving group moderation and permissions.

API schema references: [OpenAI web search documentation](https://developers.openai.com/api/docs/guides/tools-web-search), including `web_search_call.action.sources` and inline citations, and [OpenAI Docs: image inputs](https://developers.openai.com/api/docs/guides/images-vision), using labelled user content with `input_image`, JPEG data URLs and `detail: auto`.

Appraisal API contract: [forced tool selection](https://developers.openai.com/api/docs/guides/function-calling) and [structured output schemas](https://developers.openai.com/api/docs/guides/structured-outputs). Exact listing lookup and hosted web comparison are forced on successive requests while preserving function outputs and image inputs.

Initial web-search release validation (before the later listing expansion):

- 22 focused Safe Information/marketplace tests passed.
- 12 group regression/teen-safety tests passed.
- 3 clickable-source widget tests passed; targeted Flutter analysis and release web build passed.
- Live configured `gpt-5.6-luna` tests completed a hosted web search with an official citation and a synthetic internal listing search without sources or external search. No user messages were sent.
- Full server suite: 382 passed, 4 skipped, 1 unrelated failure in `test/guide-data-plan.test.js`: its required-field assertion omits `group_scope` and `contact_filter` from the existing guide data schema. Those files were not changed for this release.

Listing expansion validation:

- 69 focused tests passed across Safe Information, listing orchestration, image loading, group-link regression and teen access. They cover listing-topic isolation, available web tools, inline citation validation, source-footer removal (including labels between results), actual image inputs, authorization, deduplication and image-load failures.
- A live `gpt-5.6-luna` check used a synthetic listing and a generated solid-color photo: the model invoked the marketplace tool, received the image and identified its color. No user conversation was created or sent.
- A live external-listing search returned a current official-store offer with an opening link and no source footer. This probe used a restricted official-domain validation callback; production continues to use `inspectExternalLink`.
- Read-only production checks loaded one JPEG from each actual storage category: a registered local photo, a released cloud photo and a public demo photo. These photos were not sent to the model.

Brief listing replies (later display update):

- 76 focused tests passed, including hidden external links/site names, preserved prices/condition/model names, short contextual follow-ups, bounded output and unaffected general web citations.
- A live `gpt-5.6-luna` listing search returned a concise offer and price with no visible external URL, website name or source footer. Source validation was exercised before rendering; no user message was sent.

Hidden-source validation regression:

- 84 focused tests passed. A live `gpt-5.6-luna` probe returned hosted source metadata with zero citation annotations; source validation succeeded and the displayed answer contained only the item and price.
- Source-metadata-only listing replies are accepted after validation. Invented URLs, rejected annotations and missing authorization cannot produce unsupported claims.
- On a real verification failure, the current listing's known price and declared condition survive; unverified comparisons and unrelated earlier listings do not.

Required appraisal comparison — 10 September 2026:

- 120 focused tests passed across appraisal research/formatting, Safe Information, marketplace, image loading, group-link regression, teen access and provider usage logging; server syntax checks passed.
- Regression coverage includes mandatory lookup-before-web order, two-listing comparisons, missing/denied listings, ignored web calls, HTTP failures/timeouts, failed evidence validation, opt-outs, ordinary price-filtered searches and actual invocation of the history-scope assertions.
- Formatter coverage includes the strict two-check contract, conservative shortening, legacy answers, source names in price/reporting phrases and serialized vehicle details.
- A live configured `gpt-5.6-luna` probe used a synthetic VITO listing with the user's example facts. It completed the forced marketplace lookup followed by a forced hosted web search, returned a short conclusion and two checks, and displayed no external link, website name or source footer. The probe exercised the provider/search/formatting contract with an HTTPS validation callback; production continues to use the existing link inspection. No user messages were sent or production listing records changed.

Reasoned appraisal update — 10 September 2026:

- 121 focused tests and server syntax checks passed. The new regression preserves an entire 48-word conclusion, including its comparison rationale, listing-specific implications and uncertainty, which exceeded the previous conclusion limit.
- A live configured `gpt-5.6-luna` synthetic-listing probe returned 70 words after a forced listing lookup and hosted web comparison. Its answer distinguished price-guide figures from transaction prices, identified a missing vehicle variant, explained why declared mileage alone does not establish value, and retained two checks. No external links or website names were displayed. This again tested the provider/search/formatting contract with an HTTPS validation callback, without sending a user message or changing listing records.
