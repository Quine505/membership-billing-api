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

- `src/countries.ts`: the country table.
- `src/phone.ts`: phone cleaning and the three spellings.
- `src/members.ts`: `POST /members` and `GET /members/lookup`.
- `src/http.ts`: the error type and JSON body reading.
- `src/store.ts`: the in-memory maps.
- `src/app.ts`: wires routes and error handling. `src/server.ts` listens on 8080.

## Concurrency

Node runs handlers on one thread. Each handler reads its body first, then checks and writes with no `await` in between, so two racing requests cannot both pass a "may not" rule.

## Skipped

Parts 2 and 3 are not built yet.

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
