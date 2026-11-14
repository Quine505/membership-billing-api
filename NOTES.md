# Notes

TypeScript on Node 26 with Hono. Node runs the `.ts` files directly, so there is no build step. State lives in memory.

## Run

```
docker build -t app .
docker run -p 8080:8080 app
```

Without Docker: `npm ci`, then `npm start`.

## Test

```
docker build --target test .
```

Without Docker: `npm test`. It type-checks, then runs every file in `test/`.

## Layout

`src/` has three layers.

- `server.ts` listens on 8080. `app.ts` wires the routes and the one error handler. `http.ts` has the error type and JSON body reading. `store.ts` has the in-memory maps.
- `routes/` has one file per resource. Each reads input, validates it, applies the business rules and responds.
  - `members.ts`: `POST /members` and `GET /members/lookup`.
  - `plans.ts`: `POST /plans`.
  - `agreements.ts`: `POST /agreements` and `GET /agreements/{id}/invoices`.
  - `reconciliation.ts`: `POST /reconciliation/runs` and `GET /reconciliation/runs/{id}`.
- `domain/` is pure logic with no HTTP in it.
  - `countries.ts`: the country table.
  - `phone.ts`: phone cleaning and the three spellings.
  - `schedule.ts`: the invoice schedule.
  - `dates.ts`: date parsing and day counting.
  - `money.ts`: half-up rounding on integers.

## Concurrency

Node runs handlers on one thread. Each handler reads its body first, then checks and writes with no `await` in between, so two racing requests cannot both pass a "may not" rule.

## Skipped

Nothing. All three parts are built.

## Reconciliation

Each settled row picks its invoice by looking only at itself: its agreement's invoices due that month, within 1 minor unit, earliest due date first. No row reserves an invoice, so the order of rows cannot change the result. Verdicts come afterwards, from counting how many rows landed on each invoice. A run is stored as its response body.

## Money and dates

No float ever touches an amount. Both roundings use `BigInt`: `round(a × b / c)` is `(2ab + c) / 2c` with the fraction dropped. Dates are plain year, month, day numbers, with no timezone anywhere.

## Assumptions

Contract

- Unparseable JSON, or a body that is not a JSON object, is `422 VALIDATION`.
- Unknown fields in a body are ignored.
- An unknown route is `404 NOT_FOUND`.
- `VALIDATION` is checked before any business rule, so a bad `country` wins over a bad phone.

Part 1

- Cleaning removes only the plain space, the hyphen and round brackets. A tab, a dot or a non-ASCII digit is `INVALID_PHONE`.
- A phone that is missing or not a string is `VALIDATION`. An empty string is `INVALID_PHONE`.
- `name` length counts Unicode code points, so one emoji is one character.
- On lookup, `country` must be exactly `AE`, `SA` or `BH` when present. Anything else, including an empty value, is `VALIDATION`.
- On lookup, a number that fits no spelling is `INVALID_PHONE` whether or not `country` is given. `PHONE_NEEDS_COUNTRY` is only for numbers that fit some country's national shape.
- On lookup, a national number is read in the `country` parameter, not in any member's own country. A Saudi member with a UAE SIM is found by `0501234567` with `country=AE`.
- `PHONE_COUNTRY_MISMATCH` is checked before the search, so it is returned even when nobody has the number.

Part 2

- Every plan and agreement field is required. A missing `joining_fee` is `VALIDATION`, not 0.
- A plan `id` is a non-empty string and is case-sensitive.
- `monthly` and `joining_fee` must be integers JSON carries exactly, up to 2^53 − 1. Larger is `VALIDATION`.
- A date is exactly `YYYY-MM-DD` and must be a real day. `2026-9-20`, `2026-02-30` and anything with a time are `VALIDATION`.
- On `POST /agreements` the checks run in this order: `VALIDATION`, `UNKNOWN_MEMBER`, `UNKNOWN_PLAN`, `PLAN_COUNTRY_MISMATCH`.
- A member's country is the `country` they were created with, not the country of their SIM.
- On the invoices route an unknown agreement id is `404` even when `from` or `to` is also bad. After that, a bad date is `VALIDATION` before `INVALID_RANGE` is considered.
- "More than 366 days after" means `to − from > 366`, so a gap of exactly 366 days is allowed.
- A start date equal to a clamped due date counts as a due date. Start 28 Feb with due day 31 gives the full price.
- A tiny plan can prorate to a net of 0. The invoice is still listed.

Part 3

- `month` is exactly `YYYY-MM`. `rows` must be an array and may be empty.
- Every row field is required. A malformed row is `VALIDATION`, and that is checked before `INVALID_ROWS`.
- `currency` is any string. An unfamiliar or lowercase currency on a known agreement is `CURRENCY_MISMATCH`, not `VALIDATION`.
- The three row rules apply to declined rows too.
- Two rows sharing a `gateway_txn_id` give two `DUPLICATE_TXN` entries, one per row.
- A row that breaks several rules gets one entry per code.
- A row links to an invoice of its own agreement only. Another agreement's matching total is not a candidate.
- A linked row always reports its invoice, including under `DOUBLE_CHARGE_RISK`.
- The same `gateway_txn_id` may appear in two different runs. Runs are independent.
- A stored run is a snapshot. Agreements created later do not change it.
- `agreement_id` sorts by plain string comparison.
