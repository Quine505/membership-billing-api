# Prompts

I had the result checked independently. In a separate session, I had a different, more capable model write `test.sh`, a black-box test suite that only talks to the running container over HTTP with curl. It covers the contract and all three parts, fires concurrent requests at the "may not" rules, and sends a large reconciliation file. A check is marked FAIL when the spec states the rule and WARN when the spec is silent, and every failing check prints the exact curl command to reproduce it.

The main exchanges from my conversation with Claude Code while building this API, on 13 and 14 November 2026, in order.

The full session had 61 exchanges. I kept the ones where I directed the build, plus a few where I had Claude explain a rule until I understood it. Most of the ones I cut were more of those explanations. Where a cut leaves a gap, a short note in italics says what happened in between.

## Contents
- [1. Reading the spec and choosing a stack](#1-reading-the-spec-and-choosing-a-stack)
- [2. Settling the stack](#2-settling-the-stack)
- [3. Building Part 1](#3-building-part-1)
- [4. Why [...name].length](#4-why-namelength)
- [5. Commit Part 1, build Part 2](#5-commit-part-1-build-part-2)
- [6. Commit Part 2, build Part 3](#6-commit-part-2-build-part-3)
- [7. How the routes and codebase are designed](#7-how-the-routes-and-codebase-are-designed)
- [8. Trying a stricter phone rule](#8-trying-a-stricter-phone-rule)
- [9. Practicing the stricter rule](#9-practicing-the-stricter-rule)
- [10. Why foreign SIMs are allowed](#10-why-foreign-sims-are-allowed)
- [11. A UAE number with and without the 0](#11-a-uae-number-with-and-without-the-0)
- [12. The due-date rule](#12-the-due-date-rule)
- [13. Due dates, again](#13-due-dates-again)
- [14. My answers to the practice question](#14-my-answers-to-the-practice-question)
- [15. The first-invoice rule](#15-the-first-invoice-rule)
- [16. Testing invoice 1](#16-testing-invoice-1)
- [17. Testing the other cases](#17-testing-the-other-cases)
- [18. All the maths for Parts 2 and 3](#18-all-the-maths-for-parts-2-and-3)

---

## 1. Reading the spec and choosing a stack

**Jawad**

Read `contract.md`, `part-1.md`, `part-2.md` and `part-3.md` completely and make sure you understand them.

Then suggest a tech stack for this task. I'm used to TypeScript with Node.js, Express and Hono.

For now, I only want to discuss technologies. After that, I'll ask you to implement the task.

**Claude**

**Recommendation: TypeScript on Node 24 with Hono, in-memory Maps, and almost no other dependencies.** The grader scores exactness, so every extra library is one more place for behavior you didn't choose.

| Need | Choice | Why |
|---|---|---|
| Runtime | Node 24 | Runs `.ts` files directly, so there is no build step to break in Docker. |
| HTTP | Hono + `@hono/node-server` | You know it, and it is small. |
| Storage | Plain `Map`s | The spec allows in-memory state and each run starts empty. SQLite adds a native dependency for nothing. |
| Validation | Hand-written checks | The error codes and their order are custom. Zod would need overriding for most of them. |
| Money | Integer math with `BigInt` for the rounding step | No floats ever touch an amount, so half-up rounding is exact. |
| Dates | A small hand-written module, about 40 lines | The spec has no times or timezones, only day counting and month-end clamping. Libraries bring timezone bugs here. |
| Tests | Node's built-in test runner | No dependency. The spec's worked examples become the first tests. |
| Types | `tsc --noEmit` in the `test` stage | Type checking without a compile output. |
| Docker | `node:24-alpine`, with a `test` stage and a final run stage | Matches the contract's two build commands. |

#### Why Node fits the concurrency rule

The contract says rules like "one member per phone" must hold when two requests race. Node runs your JavaScript on one thread, so two requests can't interleave inside a block of code that has no `await` in it.

So the rule for us is: read the body first, then do "check if taken, then insert" with no `await` between the two. That gives the guarantee with no locks and no database. It is also easy to explain in the interview.

#### Where I'd push back on habit

- **Zod.** It's fine for types, but it silently accepts or coerces things the spec may reject, and its errors need reshaping anyway. Around 60 lines of plain checks is easier to get exactly right and to change live.
- **A phone library** such as libphonenumber. The spec defines its own narrow shapes for three countries. A real phone library accepts numbers this spec rejects.

#### One question

The interview is on your laptop with a live feature change. Do you have Node 24 and Docker installed locally? If you're on Node 20 or 22, I'd add a tiny build step with `tsc` instead of running `.ts` directly.

---

## 2. Settling the stack

**Jawad**

I have Node v26.12.1 and Docker installed locally. Yes, go with TypeScript and Hono. Structure the folders to be as routes/ for API routes and domain/ should have pure business logic.

**Claude**

Then use Node 26 everywhere: the Docker image will be `node:26-alpine`, matching your laptop, so what you run locally in the interview behaves the same as what the grader builds. I'll confirm that image tag pulls when we build.

Node 26 runs `.ts` files directly, so the plan stands with no build step.

One limit to know: Node only strips types, it doesn't compile TypeScript-only features. So no `enum`, no `namespace`, no constructor parameter shorthand, and imports need the `.ts` extension. We use plain types and string unions instead, which is simpler anyway.

Final stack:

- Node 26, TypeScript run directly
- Hono with `@hono/node-server`
- In-memory `Map`s
- Hand-written validation, phone parsing and date math
- `BigInt` for the rounding steps
- Node's built-in test runner, plus `tsc --noEmit` in the Docker `test` stage

That is two runtime dependencies and two dev dependencies (`typescript`, `@types/node`).

Say the word and I'll implement it, starting with Part 1.

---

## 3. Building Part 1

**Jawad**

Start with Part 1. Show me a table of every possible rule and edge case, and confirm each one behaves correctly. Once that's done, guide me through running and testing Part 1 end to end.

**Claude**

Setting up the project files and installing Hono now, then I'll write the phone parser and member routes.

All 123 Part 1 tests pass locally. Next: the Dockerfile, then I'll check the real container over HTTP.

Part 1 is built and verified: 123 tests pass locally and inside Docker, and the running container answered every spec example correctly over real HTTP, including a 40-way race.

#### How it works

Every phone goes through one function that cleans it and classifies it as **international** (it knows its country from the dial code) or **national** (it needs a country to be read). The app stores only the `+966…` form, so "same phone in any spelling" becomes one map lookup.

#### Rules and edge cases

All rows below are real tests, and all pass.

**Rule 1, clean**

| Input | Result |
|---|---|
| `055 123 4567`, `055-123-4567`, `(055) 123 4567` | `+966551234567` |
| ` +966 (55) 123-4567 `, `(+966)551234567` | `+966551234567` |
| Dots, slash, letter, tab, Arabic-Indic digits | `INVALID_PHONE` |
| `++966…`, `966+55…`, trailing `+`, only `+` | `INVALID_PHONE` |
| Empty, or only separators | `INVALID_PHONE` |

**Rule 2, three spellings**

| Input | Result |
|---|---|
| `+966551234567`, `966551234567`, `0551234567` as SA | `+966551234567` |
| `+971501234567`, `971501234567`, `0501234567` as AE | `+971501234567` |
| `+97333123456`, `97333123456`, `33123456` as BH | `+97333123456` |
| `00966551234567` | `INVALID_PHONE` |
| `+0551234567`, `+9660551234567` (trunk zero after dial code) | `INVALID_PHONE` |
| `551234567` (SA without the zero), `033123456` (BH with a zero) | `INVALID_PHONE` |
| Landlines: `+966112345678`, `0112345678`, `041234567`, `17123456` | `INVALID_PHONE` |
| One digit short or long, all three countries | `INVALID_PHONE` |
| Dial code with another country's mobile shape, e.g. `+973501234567` | `INVALID_PHONE` |
| Kuwait or US number | `INVALID_PHONE` |

**Rule 3, national numbers need a country**

| Case | Result |
|---|---|
| POST, `0551234567`, member is AE | `+971551234567` |
| POST, `0551234567`, member is BH | `INVALID_PHONE` |
| POST, `33123456`, member is SA or AE | `INVALID_PHONE` |
| Lookup `0551234567` or `33123456`, no country | `PHONE_NEEDS_COUNTRY` |
| Lookup `055 123 4567`, `country=SA` | 200 |
| Lookup `33123456`, `country=SA` | `INVALID_PHONE` |
| Lookup `0551234567`, `country=AE` (a different phone) | 404 |
| Lookup `abc`, no country | `INVALID_PHONE`, not needs-country |

**Rule 4, international numbers**

| Case | Result |
|---|---|
| Lookup `+966…` with `country=SA`, or no country | 200 |
| Lookup `+966…` or `966…` with another country | `PHONE_COUNTRY_MISMATCH` |
| Mismatch when nobody has the number | still `PHONE_COUNTRY_MISMATCH` |
| POST SA member with `+971501234567` (foreign SIM) | 201, stored as `+971…` |
| That member, lookup `0501234567` + `country=AE` | 200 |
| That member, lookup `+971…` + `country=SA` | `PHONE_COUNTRY_MISMATCH` |

**Rule 5, one member per phone**

| Case | Result |
|---|---|
| Second write in any other spelling | `409 PHONE_TAKEN` with `existing_member_id` |
| Second write from a member of another country | `409 PHONE_TAKEN` |
| `0551234567` as SA, then as AE | Both 201, they are different phones |
| 50 simultaneous writes, mixed spellings | Exactly one 201, 49 `PHONE_TAKEN` pointing at the winner |
| A failed write | Does not reserve the phone |

**Name, country, body**

| Case | Result |
|---|---|
| `"  Noura Al Harbi \n"` | Stored and returned trimmed |
| 120 characters, also with padding, Arabic or emoji | 201 |
| 121 characters, empty, only spaces, number, null, missing | `422 VALIDATION` |
| Country `sa`, `KW`, a number, missing | `422 VALIDATION` |
| Phone missing, a number, null | `422 VALIDATION` |
| Body is broken JSON, empty, an array, a string, null | `422 VALIDATION` |
| Lookup with no `phone`, or `country=KW`, `sa`, empty | `422 VALIDATION` |
| Nobody has the number | `404 NOT_FOUND` |
| Unknown route | `404 NOT_FOUND` |
| `GET /health` | 200 |

#### Where the spec is silent

I picked the strictest reading and wrote each choice into `NOTES.md`. Three could plausibly go the other way with the grader:

- An empty phone string is `INVALID_PHONE`. A missing or non-string phone is `VALIDATION`.
- When both the country and the phone are bad, `VALIDATION` wins.
- Cleaning removes only the plain space, not tabs.

Tell me if you read any of these differently.

#### How to run and test it yourself

**1. Run the test suite.** It type-checks, then runs all 123 cases and prints one line each.

```
npm test
```

**2. Run the same two commands the grader runs.**

```
docker build --target test .
docker build -t app . && docker run -p 8080:8080 app
```

**3. In a second terminal, try it by hand.**

```
curl -X POST localhost:8080/members -H 'content-type: application/json' \
  -d '{"name":"Noura Al Harbi","country":"SA","phone":"055 123 4567"}'

curl 'localhost:8080/members/lookup?phone=966551234567'
curl 'localhost:8080/members/lookup?phone=%2B966551234567'
curl 'localhost:8080/members/lookup?phone=055%20123%204567&country=SA'
curl 'localhost:8080/members/lookup?phone=0551234567'
```

The first three lookups return Noura. The last returns `PHONE_NEEDS_COUNTRY`.

**4. Try the race.** This fires 40 writes of one phone at once and counts the status codes. You should see one 201 and thirty-nine 409s.

```
seq 40 | xargs -P 40 -I{} curl -s -o /dev/null -w '%{http_code}\n' \
  -X POST localhost:8080/members -H 'content-type: application/json' \
  -d '{"name":"Racer {}","country":"AE","phone":"050 111 2222"}' | sort | uniq -c
```

Press Ctrl+C in the first terminal to stop the server. To test a new case of your own, add one line to the tables at the top of `test/members.test.ts` and run `npm test`.

Still owed before submission: the folder is not a git repo yet (the grader reads the `main` branch), and `PROMPTS.md` needs your exported conversations.

---

## 4. Why `[...name].length`

**Jawad**

Why do we write `const nameLength = [...name].length` here, spreading `name` into an array and taking its length, instead of just `name.length`? I'm just curious.

**Claude**

`name.length` can overcount, so I used `[...name].length` to count characters the way a person would.

Small correction first: `[...name]` is the **spread** operator, not destructuring. It walks the string and puts each character into an array, and then `.length` counts the array.

**Why the two give different numbers.** JavaScript stores strings as 16-bit chunks, and `.length` counts chunks, not characters. Most characters fit in one chunk, including all Arabic and English letters. Emoji and some rare symbols need two.

```js
'Noura'.length        // 5
'نورة'.length         // 4
'😀'.length           // 2  ← one emoji, counted as two
[...'😀'].length      // 1
```

Iterating a string goes by real character, so spreading it puts one emoji into one array slot.

**Does it matter here?** Only at the edge. A name of 120 emoji passes with spread and fails with `.length`, which would see 240. For normal Arabic and English names the two always agree.

It's a guess, not a rule from the spec. "1 to 120 characters" doesn't say how to count. If the grader's checker is written in JavaScript and uses `.length`, the spread version would accept a name the grader expects to be rejected. That would take a 120-emoji name to show up, so the risk is tiny either way. I logged the choice in `NOTES.md`.

Spread isn't perfect either. Some emoji are several characters joined together, like 👨‍👩‍👧, which spread counts as 5. Counting what you see on screen needs `Intl.Segmenter`, and that is more than this job needs.

---

## 5. Commit Part 1, build Part 2

**Jawad**

Commit the Part 1 changes and implement Part 2. Make sure every rule is validated, and send me tables like the ones above.

**Claude**

Committing Part 1 now, then writing Part 2 (plans, agreements, invoice schedule).

All 272 tests pass, with Part 2's expected numbers worked out by hand. Now cross-checking the schedule against a brute-force day-by-day walk, then the Docker run.

The mismatch is in my checker, not the app: it only walked 800 days past the start, and this range reached further. Widening it and rerunning.

Port 8080 is taken by another container, probably your own Part 1 run. I'll leave it alone and check on a different port.

Part 1 is committed on `main`, and Part 2 is built and verified but not committed yet. All 272 tests pass locally and in Docker, and the container returned both spec examples exactly over real HTTP.

#### How it works

One function computes an agreement's invoices for a date range, and nothing is stored. It finds N (the first due date after the start), prices invoice 1 from the days between the start and N, then walks forward one month at a time.

Money never touches a decimal number. Both roundings are done on whole integers, so `.5` always goes up.

I checked the numbers two ways. I worked out every expected value in the tables below by hand from the spec. Then I compared the function against a slow day-by-day calendar walk on 4,000 random agreements, and all 23,740 invoices agreed.

#### Rules and edge cases

Every row is a real test, and all pass.

**Plans**

| Case | Result |
|---|---|
| Spec example | 201 with `"currency":"SAR"` |
| AE, SA, BH | `AED`, `SAR`, `BHD` |
| `monthly` 1, a very large `monthly`, extra fields | 201 |
| `monthly` 0, negative, `299.5`, `"29900"`, null, missing, `1e20` | `422 VALIDATION` |
| `joining_fee` negative, `0.5`, `"0"`, null, missing | `422 VALIDATION` |
| `id` missing, a number, empty | `422 VALIDATION` |
| Country `sa`, `KW`, missing | `422 VALIDATION` |
| Same `id` again, also with other values | `409 PLAN_EXISTS`, first plan unchanged |
| 50 simultaneous plans with one `id` | One 201, 49 `PLAN_EXISTS` |

**Agreements**

| Case | Result |
|---|---|
| Spec example | 201 with a new `id` |
| Same member, same plan, twice | Two agreements |
| `due_day` 1 and 31 | 201 |
| `due_day` 0, 32, `1.5`, `"1"`, null, missing | `422 VALIDATION` |
| Start `2028-02-29` (leap year) | 201 |
| Start `2026-02-29`, `2026-02-30`, `2026-09-31`, `2100-02-29` | `422 VALIDATION` |
| Start `2026-9-20`, `20260920`, `2026/09/20`, with a time | `422 VALIDATION` |
| Unknown member | `422 UNKNOWN_MEMBER` |
| Unknown plan | `422 UNKNOWN_PLAN` |
| Both unknown | `UNKNOWN_MEMBER` |
| SA member on an AE or BH plan | `422 PLAN_COUNTRY_MISMATCH` |
| Saudi member with a UAE SIM, on an AE plan | `PLAN_COUNTRY_MISMATCH` |
| Saudi member with a UAE SIM, on a SA plan | 201 |

**Rule 1, due dates clamp**

| Case | Due dates |
|---|---|
| Due 31, from Jan 2026 | 31 Jan, 28 Feb, 31 Mar, 30 Apr, 31 May, 30 Jun, 31 Jul |
| Due 31, 2028 (leap) | 29 Feb |
| Due 31, 2100 (not leap) | 28 Feb |
| Due 30, 2000 (leap) | 29 Feb, then 30 Mar |
| Due 29, 2026 | 28 Feb, then 29 Mar |

**Rule 2, first invoice.** Monthly is 10000 AED unless noted.

| Start, due day | Proration | Net, VAT, total |
|---|---|---|
| 20 Sep, due 1, SA 29900 (spec) | 11/30 | 10963, 1644, 12607 |
| 5 Sep, due 20, AE 24900 + fee 9900 (spec) | 15/31 | 21948, 1097, 23045 |
| 1 Oct, due 1, SA 29900 + fee 5000 (start is a due date) | 31/31 | 34900, 5235, 40135 |
| 28 Feb, due 31 (clamped date is a due date) | 31/31 | 10000, 500, 10500 |
| 27 Feb, due 31 | 1/28 | 357, 18, 375 |
| 1 Mar, due 31 | 30/31 | 9677, 484, 10161 |
| 30 Mar, due 31 | 1/31 | 323, 16, 339 |
| 15 Dec, due 10 (N is next year) | 26/31 | 8387, 419, 8806 |
| 5 Jan, due 10 (P is last year) | 5/31 | 1613, 81, 1694 |
| 5 Mar 2026, due 10 | 5/28 | 1786, 89, 1875 |
| 5 Mar 2028, due 10 | 5/29 | 1724, 86, 1810 |

**Rule 3, later invoices**

| Case | Result |
|---|---|
| Invoice 2 onward | `MONTHLY`, full price, `proration: null`, no joining fee |
| Start 5 Sep, due 20 | September has invoices 1 and 2 |
| Start 30 Mar, due 31 | Invoices 1 and 2 are one day apart |

**Rules 4 and 5, rounding**

| Case | Result |
|---|---|
| 101 × 15/30 = 50.5 | Net 51 |
| 45 × 21/30 = 31.5, where decimal maths gives 31 | Net 32 |
| 12 × 24/30 = 9.6 → net 10, then VAT 0.5 | VAT 1. VAT on the unrounded 9.6 would give 0. |
| Fee 1000 on the 50.5 case | Net 1051, VAT 53 |
| VAT at 5% on 50, at 15% on 30, at 10% on 25 | 3, 5, 3 |
| VAT at 5% on 9 | 0 |
| BHD, net 5790 fils | VAT 579, not 580 |
| BHD, net 24500 (Part 3's example) | Total 26950 |
| Monthly 9,000,000,000,000 | Exact |

**Range and numbering**, on the first spec agreement.

| Range | Result |
|---|---|
| 1 Nov to 31 Dec | Invoices 3 and 4, numbering does not restart |
| 1 Oct to 1 Oct | Invoice 2 only |
| 1 Sep to 20 Sep | Invoice 1 only |
| 21 Sep to 1 Oct | Invoice 2 only |
| 2 Oct to 31 Oct, or any range before the start | `[]` |
| January 2030 | Invoice 41 |
| 366 days from the start | 13 invoices, numbered 1 to 13 |
| `to` = `from`, or exactly 366 days later | 200 |
| `to` before `from`, or 367 days later | `422 INVALID_RANGE` |
| `from` or `to` missing, empty, or not a real date | `422 VALIDATION` |
| Unknown agreement id | `404 NOT_FOUND` |

#### Where the spec is silent

All choices are in `NOTES.md`. Two could go the other way with the grader:

- An unknown agreement id with a bad date range returns 404, not 422.
- A missing `joining_fee` is `VALIDATION`. I did not default it to 0.

#### How to run and test it yourself

`npm test` and the two Docker commands work as before. One thing to know first: you have a container still running on port 8080 from the Part 1 image. Stop it with Ctrl+C in its terminal, then rebuild, or you will be testing the old code.

```
docker build -t app . && docker run -p 8080:8080 app
```

Then in a second terminal, paste this block. It creates a member, a plan and an agreement, and prints the invoices from the spec.

```
J='content-type: application/json'
M=$(curl -s -X POST localhost:8080/members -H "$J" \
  -d '{"name":"Noura","country":"SA","phone":"055 123 4567"}' | sed 's/.*"id":"\([^"]*\)".*/\1/')
curl -s -X POST localhost:8080/plans -H "$J" \
  -d '{"id":"anytime-sa","country":"SA","monthly":29900,"joining_fee":0}'
A=$(curl -s -X POST localhost:8080/agreements -H "$J" \
  -d "{\"member_id\":\"$M\",\"plan_id\":\"anytime-sa\",\"start_date\":\"2026-09-20\",\"due_day\":1}" | sed 's/.*"id":"\([^"]*\)".*/\1/')
curl -s "localhost:8080/agreements/$A/invoices?from=2026-09-01&to=2026-12-31"
```

You should see invoice 1 with net 10963, VAT 1644 and total 12607, then three monthly invoices of 34385.

To try a schedule case of your own, add one entry to the `CASES` list in `test/schedule.test.ts` and run `npm test`.

The four spec files (`contract.md`, `part-1.md` and so on) are not in the commit. Say if you want them in the repo.

---

## 6. Commit Part 2, build Part 3

**Jawad**

Commit the Part 2 changes and implement Part 3.

**Claude**

Part 2 is committed. Part 3's code is written; tidying one clumsy loop, then wiring it in and testing.

One failure, and it's my hand count in the test that was off, not the code: the AE agreement's invoice 2 is October 2026, and February 2028 is 16 months later, so invoice 18. Fixing the expectation.

Part 2 is committed, and Part 3 is built and verified but not committed yet. All 359 tests pass locally and in Docker, and the container returned the spec's example response exactly, key for key.

#### How it works

A run does three things in order:

1. **Check the rows.** If any row breaks a row rule, the whole request fails and nothing is stored.
2. **Link.** Each settled row picks one invoice by looking only at itself: its own agreement's invoices due that month, within 1 minor unit of the amount, earliest due date first.
3. **Judge.** Count how many rows landed on each invoice. One row means `MATCHED` or `DUE_DAY_DRIFT`, two or more means `DOUBLE_CHARGE_RISK` for all of them.

Step 2 is why row order can't matter. No row ever reserves an invoice, so a row's pick is the same wherever it sits in the list. One test sends the same 5 rows in all 120 possible orders and gets one identical result.

#### Rules and edge cases

Every row below is a real test, and all pass. The test data for October 2026 has four expected invoices:

- `sa#2`, due 1 Oct, 34385 SAR
- `bh#2`, due 1 Oct, 26950 BHD
- `ae#1`, due 5 Oct, 3257 AED
- `ae#2`, due 20 Oct, 3255 AED

The AE agreement has two invoices in one month, two minor units apart. That is what tests the candidate rules.

**Verdicts**

| Rows | Result |
|---|---|
| `sa` 34385 on the 1st, plus a declined `bh` row (spec example) | `MATCHED sa#2`, `DECLINED`. `bh#2` is unmatched. |
| `sa` 34385 on the 3rd, or the 31st | `DUE_DAY_DRIFT` |
| Two `sa` 34385 rows, on the 1st and 2nd | Both `DOUBLE_CHARGE_RISK`, even the one on the due date |
| Three `sa` rows: 34384, 34385, 34386 | All three `DOUBLE_CHARGE_RISK` |
| One settled and one declined on `sa#2` | `MATCHED` and `DECLINED`, not a double charge |
| Only declined rows on `sa#2` | `sa#2` is unmatched |
| Unknown agreement, any currency | `MISSING_FROM_LEDGER` |
| Unknown agreement, declined | `DECLINED` |

**Candidates**

| Rows | Result |
|---|---|
| Amount 1 above or 1 below the total | Linked |
| Amount 2 above or 2 below | `MISSING_FROM_LEDGER` |
| The net amount, 29900, without VAT | `MISSING_FROM_LEDGER` |
| `sa` row with `bh`'s total | `MISSING_FROM_LEDGER`, candidates come from the row's own agreement |
| `ae` 3256, within 1 of both invoices, on the 20th | `ae#1` (earliest due date), so `DUE_DAY_DRIFT` |
| `ae` 3254 | `ae#2` only |
| `ae` 3258, and `ae` 3259 | `ae#1` only, and `MISSING_FROM_LEDGER` |
| Two `ae` 3256 rows | Both take `ae#1` and are `DOUBLE_CHARGE_RISK`. `ae#2` stays unmatched. |
| Declined 3256, then settled 3256 | The settled one is `MATCHED ae#1` |

**Month**

| Case | Result |
|---|---|
| September, `sa` 12607 on the 20th | `MATCHED sa#1`, the first invoice |
| September, `sa` 34385 (October's amount) | `MISSING_FROM_LEDGER` |
| August, before any agreement starts | Nothing expected, every row missing |
| February 2028, attempted on the 29th | Accepted |
| No rows at all | 201, all zeros, all four invoices unmatched |

**Row rules, `422 INVALID_ROWS`**

| Rows | Entries in `errors` |
|---|---|
| Two rows share an id | Two `DUPLICATE_TXN` |
| Three rows share an id, one clean row | Three `DUPLICATE_TXN`, none for the clean row |
| A duplicate where one is declined | Two `DUPLICATE_TXN` |
| Attempted 30 Sep, 1 Nov, or October of another year | `ROW_OUTSIDE_MONTH` |
| Outside the month on a declined row or unknown agreement | `ROW_OUTSIDE_MONTH` |
| `sa` agreement paid in `AED`, `USD` or lowercase | `CURRENCY_MISMATCH` |
| Wrong currency on a declined row | `CURRENCY_MISMATCH` |
| Wrong currency on an unknown agreement | No error, check is skipped |
| One row breaks all three rules | Three entries for that row |

**Response and storage**

| Case | Result |
|---|---|
| `summary` | All five verdicts, zeros included |
| `rows` | In request order |
| `unmatched_invoices` | Sorted by due date, then agreement id, then invoice number |
| `GET` the run | Byte-identical to the `POST` response |
| New agreements added after a run | The stored run does not change |
| After a run | Members, agreements and invoices are unchanged |
| Same rows posted twice | Two runs with different ids |
| `GET` an unknown run | `404 NOT_FOUND` |

**Malformed input, `422 VALIDATION`**

| Field | Rejected values |
|---|---|
| `month` | Missing, `2026-13`, `2026-00`, `2026-1`, `2026-10-01`, a number |
| `rows` | Missing, null, an object, a string |
| A row | null, a string, an array |
| `gateway_txn_id` | Missing, a number, empty |
| `agreement_id` | Missing, a number, null |
| `amount` | Missing, 0, negative, `343.85`, `"34385"` |
| `currency` | Missing, a number |
| `status` | Missing, `settled`, `REFUNDED` |
| `attempted_on` | Missing, `2026-10-1`, `2026-10-32`, with a time |
| A malformed row next to a duplicate | `VALIDATION` wins over `INVALID_ROWS` |

#### Where the spec is silent

All choices are in `NOTES.md`. Two could go the other way with the grader:

- A currency like `USD` on a known agreement is `CURRENCY_MISMATCH`. I did not make it `VALIDATION`, because the spec defines that code for exactly this.
- Two rows sharing an id produce two `DUPLICATE_TXN` entries with the same id. The spec says "for every row", so I list each one.

#### How to run and test it yourself

`npm test` and the Docker commands are unchanged. Your old container still holds port 8080, so stop it first, then rebuild:

```
docker build -t app . && docker run -p 8080:8080 app
```

In a second terminal, this block builds the spec's scenario and posts the run:

```
J='content-type: application/json'; B=localhost:8080
id() { sed 's/.*"id":"\([^"]*\)".*/\1/'; }
M1=$(curl -s -X POST $B/members -H "$J" -d '{"name":"Noura","country":"SA","phone":"055 123 4567"}' | id)
M2=$(curl -s -X POST $B/members -H "$J" -d '{"name":"Ali","country":"BH","phone":"3312 3456"}' | id)
curl -s -o /dev/null -X POST $B/plans -H "$J" -d '{"id":"sa","country":"SA","monthly":29900,"joining_fee":0}'
curl -s -o /dev/null -X POST $B/plans -H "$J" -d '{"id":"bh","country":"BH","monthly":24500,"joining_fee":0}'
A1=$(curl -s -X POST $B/agreements -H "$J" -d "{\"member_id\":\"$M1\",\"plan_id\":\"sa\",\"start_date\":\"2026-09-20\",\"due_day\":1}" | id)
A2=$(curl -s -X POST $B/agreements -H "$J" -d "{\"member_id\":\"$M2\",\"plan_id\":\"bh\",\"start_date\":\"2026-09-15\",\"due_day\":1}" | id)
curl -s -X POST $B/reconciliation/runs -H "$J" -d "{\"month\":\"2026-10\",\"rows\":[
  {\"gateway_txn_id\":\"T-88121\",\"agreement_id\":\"$A1\",\"amount\":34385,\"currency\":\"SAR\",\"status\":\"SETTLED\",\"attempted_on\":\"2026-10-01\"},
  {\"gateway_txn_id\":\"T-88122\",\"agreement_id\":\"$A2\",\"amount\":26950,\"currency\":\"BHD\",\"status\":\"DECLINED\",\"attempted_on\":\"2026-10-02\"}]}"
```

You should see one `MATCHED`, one `DECLINED`, and the BHD invoice under `unmatched_invoices`. Copy the run's `id` and read it back with `curl localhost:8080/reconciliation/runs/<id>`.

To try a case of your own, add an entry to `CASES` in `test/reconciliation.test.ts`. A row is one short string, such as `'T1 sa 34385 01'` for transaction, agreement, amount and day of October.

Still owed before you submit: commit Part 3, write `PROMPTS.md`, and push to a remote on `main`.

---

## 7. How the routes and codebase are designed

**Jawad**

Now explain how each route is designed, and walk me through the whole codebase.

**Claude**

Every route follows the same five steps, so once you know that shape, the eight routes are small variations on it.

#### The shape every route shares

1. **Read** the JSON body or the query parameters.
2. **Check the shape.** Wrong type, missing field or out-of-range value throws `422 VALIDATION`.
3. **Check the business rules.** Each has its own code, such as `PHONE_TAKEN`.
4. **Read or write the store.**
5. **Respond** with JSON.

A route never builds an error response itself. It throws an `ApiError`, and one handler in `app.ts` catches it and turns it into `{"error": {"code", "message"}}`. This is why every error in the API has the same shape.

#### The files, in three layers

**Plumbing**

- `server.ts` starts the app on port 8080.
- `app.ts` creates the store, registers the routes and holds the one error handler.
- `http.ts` has `ApiError`, a shortcut for `VALIDATION`, a "safe JSON body" reader and an integer check.
- `store.ts` is five maps: members by id, members by phone, plans, agreements, runs.
- `countries.ts` is the country table: dial code, phone shape, currency, VAT rate.

**Pure logic.** These files know nothing about HTTP. They take values and return values.

- `phone.ts` cleans and classifies phones.
- `dates.ts` parses dates and counts days.
- `money.ts` holds the one rounding function.
- `schedule.ts` computes invoices.

**Routes.** `members.ts`, `plans.ts`, `agreements.ts` and `reconciliation.ts` do the five steps and call the pure logic.

The split matters for the interview. A change to a rule goes in the pure layer, and a change to an input or output goes in a route file.

#### The routes

##### `POST /members`

Takes `name`, `country`, `phone`.

- Trims the name and checks it is 1 to 120 characters.
- Checks the country is `AE`, `SA` or `BH`.
- Calls `parsePhone`, which returns one of three things: an international number that knows its country, a national number that doesn't, or nothing (`INVALID_PHONE`).
- A national number is read in the member's own country. An international one is kept as is, since members may carry foreign SIMs.
- Looks the phone up in the phone map. If it is there, `409 PHONE_TAKEN`. If not, saves the member in both maps.

The lookup and the save have no `await` between them. That is the whole race protection.

##### `GET /members/lookup`

Takes `phone` and an optional `country` from the query string. It uses the same `parsePhone`, with stricter rules:

- International number with a `country` that disagrees: `PHONE_COUNTRY_MISMATCH`.
- National number with no `country`: `PHONE_NEEDS_COUNTRY`.
- National number that doesn't fit the given country: `INVALID_PHONE`.

Then one lookup in the phone map: the member, or `404`.

##### `POST /plans`

Takes `id`, `country`, `monthly`, `joining_fee`. It checks the types, refuses a duplicate id with `409 PLAN_EXISTS`, fills in `currency` from the country table and saves. It is the simplest route.

##### `POST /agreements`

Takes `member_id`, `plan_id`, `start_date`, `due_day`. After the shape checks, three business checks run in a fixed order: the member exists, the plan exists, and both are in the same country. Then it saves the agreement. It computes nothing, because invoices don't exist yet.

##### `GET /agreements/{id}/invoices`

Takes `from` and `to`. It finds the agreement (`404` if missing), parses both dates, and rejects a range that is reversed or longer than 366 days. Then it calls the one function that matters, `invoicesBetween`, and returns its result.

**How `invoicesBetween` works:**

1. Find N, the first due date after the start. It is this month's due date if that is still ahead, otherwise next month's.
2. Find P, the due date one month before N.
3. Invoice 1 is due on the start date. Its price is `monthly × (N − start) / (N − P)`, plus the joining fee.
4. Invoice 2 is due on N, invoice 3 a month later, and so on. Each is the full monthly price.
5. Every invoice gets VAT, then `total = net + vat`.

Two tricks keep it short:

- **Months as one number.** A month is stored as `year × 12 + month`, so "next month" is `+ 1` and December rolls into January for free.
- **Jumping, not walking.** It only visits the months the range touches. Asking for January 2030 doesn't loop from 2026.

**The rounding function**, `mulDivRound(a, b, c)`, computes `a × b / c` rounded half up using whole numbers only. Adding half before dividing is the same as rounding half up, and `(2ab + c) / 2c` is that idea written without fractions. For the spec example, `29900 × 11 / 30` becomes `657830 / 60`, which is 10963 after dropping the fraction.

##### `POST /reconciliation/runs`

Takes `month` and `rows`. It has four stages:

1. **Shape.** Every row is checked. One malformed row fails everything with `VALIDATION`.
2. **Row rules.** It collects duplicates, rows outside the month and currency mismatches into a list. If the list isn't empty, it throws `INVALID_ROWS` with the list attached.
3. **Reconcile.** It builds the expected invoices by calling `invoicesBetween` for every agreement over that month. Each settled row then picks the first invoice of its own agreement within 1 minor unit. A counter per invoice decides the verdicts.
4. **Store.** It saves the full response body under a new id and returns it.

Part 3 reuses Part 2's function unchanged. That is why a fix to invoice maths automatically fixes reconciliation.

##### `GET /reconciliation/runs/{id}`

Returns the stored body, or `404`. Because the run is stored as the exact response, reading it back can never differ from the original.

##### `GET /health`

Returns 200. The grader uses it to know the container is up.

#### The tests

Each test file is a table of cases plus a loop that runs them. Adding a case means adding one line, with no new code. `helpers.ts` holds the shared "post this and expect 201" and "expect this error" functions. Each test builds its own app, so tests never share data.

#### The Dockerfile

It has three stages. The first installs dependencies and copies the source. The `test` stage adds the tests and runs them. The last stage starts the server. The grader builds the `test` stage and the last stage separately.

I'd suggest reading `schedule.ts` next with the spec's first worked example beside it, since it is the densest 60 lines in the project. I can walk through it line by line if you want.

---

## 8. Trying a stricter phone rule

**Jawad**

I'm trying to enforce a rule here: `if (COUNTRIES[country].dial !== dial) return null`. It should stop someone from becoming a member of one country with another country's dial code.

**Claude**

That rule goes against the spec, so I'd leave it out. Part 1, rule 4 says:

> On `POST /members`, the number may be from any of the three countries, since members carry foreign SIMs.

A Saudi member with a UAE number is something the grader expects to be accepted with a 201. Your rule would turn those into 422s, and we'd lose every hidden test that checks it. Running the suite against your edit shows it: 62 of 348 tests fail, including all three "foreign SIM" cases.

#### Two bugs in the edit itself

If you ever want this rule, for practice or a real product, the current version has two problems.

**1. It breaks the lookup route.** `parsePhone` now requires a country, but lookup still calls it with one argument. TypeScript flags this, and at runtime it gets worse. Lookup's country is often missing, so `COUNTRIES[undefined].dial` throws, and every international lookup like `?phone=%2B966551234567` would return a 500.

**2. It gives the wrong error.** Returning `null` means `INVALID_PHONE`, but `+971501234567` is a valid phone. It's just from another country. The caller would be told the wrong thing.

#### Where the rule would belong

`parsePhone` answers one question: "what number is this?" Both routes share it, so a rule about members doesn't belong inside it. The rule belongs in the POST route, after parsing:

```ts
const parsed = parsePhone(body.phone)
if (!parsed) throw invalidPhone()
if (parsed.kind === 'international' && parsed.country !== body.country) {
  throw new ApiError(422, 'PHONE_COUNTRY_MISMATCH', 'phone is from another country')
}
```

That's three lines in one place, `parsePhone` stays untouched, and lookup keeps working.

My recommendation is to undo the `phone.ts` change and keep the spec's behavior. Do you want me to restore that file? Your comment edits in `members.ts` are harmless, and I'd keep them apart from the `parsePhone(body.phone, body.country)` call, which has to go back too.

There's also a `// TODO: HAMDAN` comment in `phone.ts`. It would end up in the submission if committed.

---

## 9. Practicing the stricter rule

**Jawad**

I'm just practicing. Tell me how to make member creation fail when the phone has another country's dial code. Tell me exactly what to change, and how to fix lookup.

**Claude**

You need two small changes in `src/domain/phone.ts`, and none in lookup. I tried them on a scratch copy, outside your folder, so your files are untouched.

#### Change 1: make `country` optional

```ts
export function parsePhone(raw: string, country?: Country): Phone | null {
```

The `?` means callers may leave `country` out. That fixes lookup: it calls `parsePhone(rawPhone)` with no country, which is now allowed, and the TypeScript error disappears.

#### Change 2: only check when a country was given

Replace your line:

```ts
if(COUNTRIES[country].dial !== dial) return null
```

with:

```ts
if (country && c !== country) return null
```

Two fixes are packed in here:

- **`country &&`** skips the check when no country was passed, which is the lookup case. This removes the crash: lookup never reaches `COUNTRIES[undefined]`.
- **`c !== country`** compares the country codes directly. The loop only gets to this line when `c` is the country whose dial code matched, so you don't need to look up and compare dial codes. Same meaning, less code.

Also move the `if (digits.startsWith(dial) ...` line back four spaces. It's indented one level too deep, which makes it look nested when it isn't.

The finished loop:

```ts
for (const c of COUNTRY_CODES) {
  const { dial, mobile } = COUNTRIES[c]
  if (digits.startsWith(dial) && mobile.test(digits.slice(dial.length))) {
    if (country && c !== country) return null
    return { kind: 'international', country: c, e164: '+' + digits }
  }
}
```

Keep your `members.ts` change, `parsePhone(body.phone, body.country)`, as it is. POST passes the member's country, so the rule applies there.

#### Why lookup must not pass a country

Lookup has its own check that returns `PHONE_COUNTRY_MISMATCH` when `?country=` disagrees with the dial code. If lookup passed its country into `parsePhone`, your rule would run first and return `INVALID_PHONE` instead.

#### What `npm test` will show

With both changes, it type-checks, and 46 of 348 tests fail. That's expected. Every failure comes from a member with a foreign SIM, which your rule now rejects:

- The three "foreign SIM" POST tests and two lookup tests fail directly.
- The agreement tests fail indirectly. Their setup creates a Saudi member with a UAE number before each test, that setup now gets a 422, and the test stops before reaching its own check.

A real rule change would mean updating those tests too. That's a normal part of changing behavior, and good interview practice.

This version returns `INVALID_PHONE` for a foreign number, because `parsePhone` can only say "no", not why. For a clearer code like `PHONE_COUNTRY_MISMATCH`, the check has to live in the route, as in my last message.

---

## 10. Why foreign SIMs are allowed

**Jawad**

> On POST /members, the number may be from any of the three countries, since members carry foreign SIMs.

So this rule is why the one I wanted to implement isn't valid, right?

**Claude**

Yes, exactly. The spec allows a member to register with a number from any of the three countries, whatever country the member belongs to. Your rule refuses exactly those numbers, so the two can't both hold.

A "foreign SIM" is a phone number from another country. Picture a Saudi member who works in Dubai and uses a UAE number. The spec says the gym must accept them:

```
{ "name": "Ahmad", "country": "SA", "phone": "+971512350194" }
→ 201, stored as +971512350194
```

With your rule, the same request gets `422 PHONE_COUNTRY_MISMATCH`. The grader almost certainly sends a case like this, so the rule would cost points.

"Any of the three" still has a limit. A Kuwaiti or US number is `INVALID_PHONE`, because only AE, SA and BH numbers are valid anywhere in this API.

Your practice change still taught the right lesson, though. If the interviewer asks "only allow members to use a phone from their own country", the three lines in the POST route are the answer, along with updating the tests that assumed the old rule.

---

## 11. A UAE number with and without the 0

**Jawad**

What happens if someone sends a UAE number with the leading 0, and without it? Walk me through both cases.

**Claude**

The `0` is only allowed in the national spelling. With a dial code in front, the `0` has to go. So "with 0" and "without 0" give opposite answers depending on whether the number has a dial code. I ran all four cases through `parsePhone` to confirm.

#### Without a dial code

**`050 123 4567`, with the 0: valid.**

1. Cleaning gives `0501234567`.
2. The loop checks for `971`, `966` or `973` at the front. It starts with `0`, so there's no match.
3. There's no `+`, so the national check runs. For the UAE, it strips the trunk `0`, leaving `501234567`. That fits `/^5\d{8}$/`.
4. It returns `{ kind: 'national', digits: '0501234567' }`.

What it becomes then depends on the country it's read in:

- A UAE member: `+971501234567`.
- A Saudi member: `+966501234567`. The same digits are a valid Saudi number, so the API reads it as Saudi. That's the spec's rule: a national number is read in the member's own country.
- A Bahraini member: `INVALID_PHONE`, because it doesn't fit Bahrain's shape.
- A lookup without a country: `PHONE_NEEDS_COUNTRY`.

**`50 123 4567`, without the 0: invalid.**

1. Cleaning gives `501234567`.
2. No dial code matches, and there's no `+`.
3. The UAE and Saudi checks need the number to start with the trunk `0`. It doesn't, so both fail. Bahrain needs a leading `3`, so that fails too.
4. It returns `null`, which means `INVALID_PHONE`.

The spec says UAE national mobiles are exactly 10 digits starting `05`, so 9 digits isn't one of the allowed spellings.

#### With a dial code

**`+971 50 123 4567`, without the 0: valid.**

The loop finds `971`, and `501234567` fits the UAE shape. It returns `international`, stored as `+971501234567`.

**`+971 050 123 4567`, with the 0: invalid.**

1. The loop finds `971`, but what's left is `0501234567`. It starts with `0` and has 10 digits, so it fails `/^5\d{8}$/`.
2. No other dial code matches. There's a `+`, so it returns `null` right away.

Without the `+`, `9710501234567` fails as well. It starts with `9`, so it fits no national shape either.

#### The pattern to remember

The trunk `0` is how people dial *inside* the country. A dial code is how they dial *from outside*. You use one or the other, never both. `+971 0…` is a common mistake in real life, and the spec rejects it on purpose.

---

## 12. The due-date rule

**Jawad**

Explain the following rule to me:

> Due dates. An agreement's due date in a month is min(due_day, days in that month). Due on the 31st means 30 April, 28 February (29th in a leap year) and 31 March. The anchor stays 31; only the date clamps.

**Claude**

Each agreement picks one day of the month to be billed on. When a month is too short to have that day, the bill falls on the month's last day instead.

#### The formula

`min(due_day, days in that month)` means "take whichever is smaller". With a due day of 31:

- January has 31 days, so `min(31, 31)` is the 31st.
- February 2026 has 28 days, so `min(31, 28)` is the 28th.
- April has 30 days, so `min(31, 30)` is the 30th.

"Clamping" is the word for this: the value gets pushed down to the limit when it's too big, and left alone otherwise. A due day from 1 to 28 never clamps, because every month has at least 28 days.

The leap-year rule decides February. A year divisible by 4 is a leap year, except century years, which only count if divisible by 400. So 2028 has a 29 February, 2100 doesn't, and 2000 did.

#### "The anchor stays 31"

This is the part that's easy to get wrong. After February clamps to the 28th, March goes back to the 31st:

```
31 Jan → 28 Feb → 31 Mar → 30 Apr → 31 May
```

The tempting way to build a schedule is "take the last due date and add one month". That drifts down permanently:

```
31 Jan → 28 Feb → 28 Mar → 28 Apr → 28 May   (wrong)
```

Once you step on 28 February, you've lost the information that the member chose the 31st. The rule says the 31 is never lost. It's the *anchor*, and every month's date is worked out fresh from it.

Think of a monthly alarm set for "the 31st". In February it rings on the last day, but the setting still says 31, so it rings on 31 March.

#### In the code

`dueDate` in `schedule.ts` does it in one line:

```ts
return { y, m, d: Math.min(dueDay, daysInMonth(y, m)) }
```

It always receives the agreement's original `due_day`, never the previous invoice's date. That's how the anchor stays put: no month depends on the month before it. `daysInMonth` holds the leap-year rule.

#### Why it matters for the money

Clamping changes cycle lengths, and the first invoice's proration depends on them. With due day 31, the cycle from 31 January to 28 February is 28 days, while 28 February to 31 March is 31 days. A start date on a clamped day, such as 28 February with due day 31, counts as a real due date, so that member pays the full price.

---

## 13. Due dates, again

**Jawad**

I'm still having trouble understanding this concept.

**Claude**

Let me try again with a story and no code.

#### The story

Sara joins the gym and says: "Charge me on the 31st. That's when I get paid."

The gym writes **31** on her membership card.

The problem is that some months have no 31st. So the gym follows one rule every month:

> Look at the card. If this month has that day, charge on that day. If it doesn't, charge on the last day of the month.

| Month | Has a 31st? | Sara is charged on |
|---|---|---|
| January | Yes | 31 January |
| February | No, it ends on the 28th | 28 February |
| March | Yes | 31 March |
| April | No, it ends on the 30th | 30 April |
| May | Yes | 31 May |

That's the whole rule.

#### What "the anchor stays 31" means

The card still says **31** after February. The gym never rewrites it.

So in March, the gym looks at the card, sees 31, and charges on the 31st. February's short month has no effect on March.

#### The mistake the rule prevents

Imagine a lazy clerk who never reads the card. Each month, they look at *last month's* charge date and use the same day:

- January: 31st.
- February: no 31st, so the 28th.
- March: "last month was the 28th", so the 28th.
- April, May, and every month after: the 28th.

One short February, and Sara is charged on the 28th forever, three days before her salary arrives. The spec's sentence "the anchor stays 31; only the date clamps" means: always read the card, never copy last month's date.

#### Try one yourself

Omar's card says **30**. In 2026, what's his charge date in:

1. January?
2. February?
3. March?

Tell me your three answers. If one is off, it shows me exactly which part to explain differently.

---

## 14. My answers to the practice question

**Jawad**

1. 30
2. 28
3. 30

**Claude**

All three are right.

- **January:** it has a 30th, so the 30th.
- **February:** 2026 isn't a leap year, so it ends on the 28th, and Omar is charged on the 28th.
- **March:** you read the card again and charged the 30th, not the 28th. That's the anchor rule, and it's the part most people miss.

The code does exactly what you just did in your head. The card is the agreement's `due_day`. Your rule, "that day, or the last day if the month is too short", is `Math.min(dueDay, daysInMonth(y, m))`. It runs fresh for every month from the card, never from the previous charge.

One harder question, if you want it: Omar's card still says 30. What's his February charge date in **2028**?

---

## 15. The first-invoice rule

**Jawad**

Explain this rule as well:

> First invoice. Invoice 1 has kind FIRST and is due on the start date. Let N be the first due date strictly after the start date, and P the due date one month before N.
>
> - Its net is monthly × (N − start) / (N − P), rounded, plus joining_fee.
> - Its proration is {days: N − start, cycle_days: N − P}.
> - A start date that is itself a due date gives days = cycle_days, which is the full price.

**Claude**

A member who joins partway through a billing cycle pays only for the days until their first regular charge, as a fraction of a full cycle. The joining fee is added on top.

#### The story

Sara's card says **1**, so she's charged on the 1st of each month. She joins on **20 September**.

Her regular charges start on 1 October. But she uses the gym from 20 to 30 September too. Charging a full month for 11 days would be unfair, and charging nothing would be free gym time. So the gym charges her for exactly those days, on the day she joins.

That's invoice 1, the `FIRST` invoice.

#### The two dates

- **N** is her first regular charge date after joining: **1 October**.
- **P** is the charge date one month before N: **1 September**.

From P to N is the full billing cycle she joined in the middle of.

#### The maths

```
days        = N − start = 1 Oct − 20 Sep = 11 days
cycle_days  = N − P     = 1 Oct − 1 Sep  = 30 days
net         = monthly × 11 / 30
```

With a monthly price of 299 SAR (`29900` halalas), that's `29900 × 11 / 30 = 10963.33`, rounded to `10963`. VAT goes on top as usual.

The cycle has to be measured, because months differ. Eleven days out of a 30-day September cycle costs more than 11 days out of a 31-day one.

#### Joining on a due date

Say Sara joins on **1 October**, which is already a charge day. N has to be *strictly after* the start, so N isn't 1 October, it's **1 November**. P is 1 October.

```
days = 1 Nov − 1 Oct = 31
cycle_days = 31
net = monthly × 31/31 = the full price
```

That's fair: she joined at the very start of a cycle, so she pays for the whole cycle. Invoice 2 follows on 1 November.

#### The joining fee

The fee is added **after** the proration and is never shortened. In the spec's second example, a member joins on 5 September with card 20, a monthly price of 249 AED and a joining fee of 99 AED:

```
N = 20 Sep, P = 20 Aug
days = 15, cycle_days = 31        (August has 31 days)
24900 × 15 / 31 = 12048.39  →  12048
+ joining fee 9900           →  net 21948
```

Her invoice 2 falls on 20 September, so she gets two invoices that month: one when she joins, one 15 days later.

#### How it uses the earlier rules

N and P are found with the card-and-clamp rule from before. With card 31, a cycle can be 28, 29, 30 or 31 days long, and that's exactly why `cycle_days` is part of the answer.

#### In the code

`schedule.ts` finds N with one question: is this month's charge date still ahead of the start date? If yes, that's N. If not, N is next month's charge date. P is the month before N. Then it subtracts dates to get `days` and `cycle_days`, and calls the rounding function.

#### Try one

Card says **15**. A member joins on **10 March 2026**. What are N, P, `days` and `cycle_days`?

---

## 16. Testing invoice 1

*Before this, I asked Claude for plain JSON request bodies and created the Saudi example from `part-2.md` in Postman, one request at a time: the member, the plan and the agreement. The invoices matched the spec. Those steps are left out.*

**Jawad**

How do I test invoice 1? Should I use month `2026-09` and amount `12607`?

**Claude**

Yes, exactly. Invoice 1 is due on 20 September, so it's only expected in a September run. Use `"month": "2026-09"`, `"amount": 12607`, and an `attempted_on` inside September:

**`POST http://localhost:8080/reconciliation/runs`**

```json
{
  "month": "2026-09",
  "rows": [
    { "gateway_txn_id": "T-0901", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 12607, "currency": "SAR", "status": "SETTLED", "attempted_on": "2026-09-20" }
  ]
}
```

You should get `MATCHED`, linked to `invoice_no: 1`, with `unmatched_invoices` empty. September has only that one invoice, because invoice 2 is due in October.

Three variations worth trying on the same body:

- `"attempted_on": "2026-09-22"` gives `DUE_DAY_DRIFT`: right invoice, wrong day.
- `"amount": 12608` still gives `MATCHED`: within 1 halala counts.
- `"amount": 34385` gives `MISSING_FROM_LEDGER`, and invoice 1 shows up as unmatched. That's October's amount, and no September invoice has that total.

Each run is separate, so you can send all of these one after another without restarting.

---

## 17. Testing the other cases

**Jawad**

How do I test the other possible cases now?

**Claude**

Here are the remaining reconciliation cases, all on Noura's agreement in October. Her October invoice is number 2: `34385`, due 1 October. Each run is independent, so send them in any order, without restarting.

#### 1. Card declined, then retried the next day

```json
{
  "month": "2026-10",
  "rows": [
    { "gateway_txn_id": "T-2001", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "DECLINED", "attempted_on": "2026-10-01" },
    { "gateway_txn_id": "T-2002", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "SETTLED", "attempted_on": "2026-10-02" }
  ]
}
```

T-2001 is `DECLINED`, and T-2002 is `DUE_DAY_DRIFT`. A declined row takes no part in matching, so the retry is the only payment on the invoice, and it came a day late.

#### 2. Charged twice

```json
{
  "month": "2026-10",
  "rows": [
    { "gateway_txn_id": "T-3001", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "SETTLED", "attempted_on": "2026-10-01" },
    { "gateway_txn_id": "T-3002", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "SETTLED", "attempted_on": "2026-10-03" }
  ]
}
```

Both rows are `DOUBLE_CHARGE_RISK`, even T-3001, which was on the due date.

#### 3. Only a declined attempt

```json
{
  "month": "2026-10",
  "rows": [
    { "gateway_txn_id": "T-4001", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "DECLINED", "attempted_on": "2026-10-01" }
  ]
}
```

`DECLINED`, and invoice 2 appears in `unmatched_invoices`, because nobody actually paid it.

#### 4. A payment for an agreement we don't have

```json
{
  "month": "2026-10",
  "rows": [
    { "gateway_txn_id": "T-5001", "agreement_id": "does-not-exist", "amount": 5000, "currency": "USD", "status": "SETTLED", "attempted_on": "2026-10-05" }
  ]
}
```

`MISSING_FROM_LEDGER`. The `USD` isn't an error here: the currency check is skipped when the agreement is unknown. Invoice 2 is unmatched.

#### 5. Broken rows

```json
{
  "month": "2026-10",
  "rows": [
    { "gateway_txn_id": "T-6001", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "SETTLED", "attempted_on": "2026-11-01" },
    { "gateway_txn_id": "T-6002", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "AED", "status": "SETTLED", "attempted_on": "2026-10-01" },
    { "gateway_txn_id": "T-6003", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "SETTLED", "attempted_on": "2026-10-01" },
    { "gateway_txn_id": "T-6003", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "SETTLED", "attempted_on": "2026-10-02" }
  ]
}
```

`422 INVALID_ROWS`, with four entries in `errors`:

- T-6001: `ROW_OUTSIDE_MONTH`, because it's dated November.
- T-6002: `CURRENCY_MISMATCH`, because it pays a SAR agreement in AED.
- T-6003, twice: `DUPLICATE_TXN`.

Nothing is stored when this happens.

#### 6. Malformed input

```json
{
  "month": "2026-10",
  "rows": [
    { "gateway_txn_id": "T-7001", "agreement_id": "7f6812a9-8006-4983-b127-e2a0fc9afce8", "amount": 34385, "currency": "SAR", "status": "settled", "attempted_on": "2026-10-01" }
  ]
}
```

`422 VALIDATION`, because the status must be exactly `SETTLED` or `DECLINED`. Changing `"amount"` to `0` or `"month"` to `"2026-13"` also gives `VALIDATION`.

#### 7. Reading a run back

Take the `id` from any run that returned `201`:

```
GET http://localhost:8080/reconciliation/runs/PASTE_RUN_ID
```

It returns exactly the same body as the original response. `GET /reconciliation/runs/nope` gives `404 NOT_FOUND`.

#### 8. Row order doesn't matter

Send case 1 again with the two rows swapped. Each transaction gets the same verdict as before, and only the order of the `rows` list changes, since rows always come back in request order.

---

## 18. All the maths for Parts 2 and 3

**Jawad**

Give me a full, step-by-step explanation of the math in Parts 2 and 3, all in one go.

**Claude**

Here's all the maths for Parts 2 and 3, in the order the code does it. One running example carries the whole of Part 2, with smaller examples where it doesn't cover a rule.

### Part 2: invoice maths

**Running example:** Sara joins on **5 September 2026** with due day **20**. Her plan costs **24900** fils a month (249.00 AED) plus a **9900** joining fee, and UAE VAT is **5%**.

#### Step 1: the bill date in any month

```
bill date = min(due day, days in that month)
```

For Sara in September: `min(20, 30) = 20`, so 20 September.

This only matters for due days above 28. With due day 31 in February 2026: `min(31, 28) = 28`, so 28 February. The next month starts again from 31: `min(31, 31) = 31` in March.

#### Step 2: find N, the first bill date after joining

Look at the bill date in the joining month:

- If it's **after** the join date, that's N.
- If it's on or before, N is next month's bill date.

For Sara, 20 September is after 5 September, so **N = 20 September**.

For Noura (joined 20 September, due day 1), 1 September is before 20 September, so N moves to **1 October**.

#### Step 3: find P, the bill date one month before N

Apply step 1 to the month before N. For Sara, that's August: `min(20, 31) = 20`, so **P = 20 August**.

#### Step 4: count the days

You need two counts:

```
days       = N − start = 20 Sep − 5 Sep  = 15
cycle_days = N − P     = 20 Sep − 20 Aug = 31
```

**Same month:** subtract the day numbers, `20 − 5 = 15`.

**Neighbouring months:** days left in the first month, plus days into the second:

```
20 Aug → 20 Sep = (31 − 20) + 20 = 11 + 20 = 31
```

August has 31 days, which is why this cycle is 31 long.

#### Step 5: prorate the monthly price, rounding #1

```
monthly × days / cycle_days = 24900 × 15 / 31 = 373500 / 31 = 12048.39
```

Round half up: `.39` is below `.5`, so **12048**.

#### Step 6: add the joining fee

```
net = 12048 + 9900 = 21948
```

The fee is added after rounding and is never prorated.

#### Step 7: VAT, rounding #2

```
vat = net × 5 / 100 = 21948 × 5 / 100 = 1097.4  →  1097
```

VAT is computed on the net that includes the fee. That's what "the joining fee sits inside the VAT base" means.

#### Step 8: total

```
total = net + vat = 21948 + 1097 = 23045
```

Both are whole numbers, so nothing is rounded here. That's invoice #1.

#### Step 9: every later invoice

No proration and no fee. The net is just the monthly price:

```
net   = 24900
vat   = 24900 × 5 / 100 = 1245
total = 24900 + 1245 = 26145
```

Sara's invoice #2 is due on N, 20 September, so September holds two of her invoices.

#### Step 10: invoice numbers

```
invoice number = (months after N's month) + 2
```

N's month is always #2, because #1 is the joining bill. For Sara:

```
September (N's month)  0 + 2 = #2
October                1 + 2 = #3
November               2 + 2 = #4
```

This also answers the question from before. Noura's N is October 2026. January 2027 is 3 months later, so it's **#5, due 1 January 2027**.

The code counts months by turning each one into a single number, `year × 12 + month − 1`:

```
October 2026 = 2026 × 12 + 9 = 24321
January 2027 = 2027 × 12 + 0 = 24324
difference   = 3
```

#### Step 11: a short-month example

Due day **31**, joined **15 February 2026**, 10000 fils a month, no fee, 5% VAT:

```
February bill date = min(31, 28) = 28 Feb, after 15 Feb   →  N = 28 Feb
P = January's bill date = min(31, 31)                       →  P = 31 Jan
days       = 28 − 15                   = 13
cycle_days = (31 − 31) + 28            = 28
prorated   = 10000 × 13 / 28 = 4642.86 → 4643
vat        = 4643 × 5 / 100  = 232.15  → 232
total      = 4643 + 232              = 4875
```

The next bills are 28 February (#2), then **31 March** (#3). The 31 comes back after the short month.

#### Step 12: Bahraini dinars

Ali joins on 15 September with due day 1, a plan of **24500** fils (24.500 BHD), and 10% VAT:

```
N = 1 Oct, P = 1 Sep
days = (30 − 15) + 1 = 16,  cycle_days = 30
prorated = 24500 × 16 / 30 = 13066.67 → 13067
vat      = 13067 × 10 / 100 = 1306.7  → 1307
total    = 14374 fils = 14.374 BHD
```

Everything stays in fils. If you converted the VAT to dinars, 1.3067, and rounded to two decimals out of habit, you'd get 1.31 dinars, which is 1310 fils. That's three fils wrong.

#### How the code rounds

`mulDivRound(a, b, c)` computes `a × b / c` rounded half up, using whole numbers only:

```
round(a × b / c) = (2 × a × b + c) / (2 × c), dropping the fraction
```

Adding `c` on top is the same as adding half before cutting off the fraction. Step 5 in this form:

```
(2 × 24900 × 15 + 31) / (2 × 31) = 747031 / 62 = 12048.88  →  12048
```

Same answer, and no decimal number was ever stored. That matters because JavaScript decimals are slightly inexact: `45 × 21 / 30` should be exactly 31.5, which rounds to 32, but normal decimals give 31.4999… and round to 31.

### Part 3: reconciliation maths

**Running example:** Noura's October invoice is #2, **34385**, due 1 October.

#### Step 1: is the row in the month?

Compare the first 7 characters of the date with the month:

```
"2026-10-03".slice(0, 7) = "2026-10"   matches "2026-10"  →  fine
"2026-11-01".slice(0, 7) = "2026-11"   doesn't match      →  ROW_OUTSIDE_MONTH
```

#### Step 2: expected invoices

This is Part 2's maths with the window set to the whole month: from the 1st to the last day. For October 2026, that's 1 to 31 October, which gives Noura's #2.

#### Step 3: "within 1"

```
candidate if |total − amount| ≤ 1
```

The bars mean "distance, ignoring the minus sign":

```
amount 34385:  |34385 − 34385| = 0  →  candidate
amount 34386:  |34385 − 34386| = 1  →  candidate
amount 34384:  |34385 − 34384| = 1  →  candidate
amount 34387:  |34385 − 34387| = 2  →  not a candidate
```

#### Step 4: several candidates means the earliest wins

Suppose an agreement has two October invoices totalling **3257** (due the 5th) and **3255** (due the 20th). A payment of **3256** is 1 away from both, so both are candidates. The one due on the 5th wins.

#### Step 5: count payments per invoice

Each settled row that picked an invoice adds 1 to that invoice's count:

```
T-1  34385  →  #2     count for #2: 1
T-2  34386  →  #2     count for #2: 2
T-3  declined         adds nothing
```

#### Step 6: verdicts are comparisons

Checked in this order, and the first true one wins:

```
status = DECLINED?                 →  DECLINED
no invoice picked?                 →  MISSING_FROM_LEDGER
count for its invoice > 1?         →  DOUBLE_CHARGE_RISK
attempted_on = due_date?           →  MATCHED
otherwise                          →  DUE_DAY_DRIFT
```

Here, T-1 and T-2 see count 2 > 1, so both get `DOUBLE_CHARGE_RISK`, and T-3 gets `DECLINED`.

#### Step 7: the summary

Add 1 to the verdict's counter for each row. The counters always add up to the number of rows:

```
DOUBLE_CHARGE_RISK 2 + DECLINED 1 = 3 rows
```

#### Step 8: sorting the unpaid invoices

Invoices with count 0 are unpaid. They're sorted by due date, then agreement id, then invoice number.

Dates in `YYYY-MM-DD` form sort correctly as plain text, because the biggest unit comes first and every part has a fixed width:

```
"2026-10-01" < "2026-10-20"   because at the first different character, "0" comes before "2"
```

Only when two due dates are equal does it compare agreement ids, and only when those are equal too does it compare invoice numbers.

---
