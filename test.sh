#!/usr/bin/env bash
# =============================================================================
#  gymtest.sh - curl test suite for the Gulf gym invoice API
#
#  Usage:   ./gymtest.sh [contract|part1|part2|part3|e2e|all]      (default: all)
#
#  Start the submission first:   docker build -t app . && docker run --rm -p 8080:8080 app
#
#  Env:     BASE=http://localhost:8080   where the API listens
#           V=1                          print the curl command behind every check
#           Q=1                          print failures only
#           RUN=123                      fix the 3-digit tag used in phones / plan ids
#           BIG=1500                     rows in the large reconciliation file
#
#  Needs:   bash, curl, jq.
#
#  Every check is one HTTP call. A failing check prints the exact curl command
#  to paste into a terminal to reproduce it.
#
#  FAIL = the spec states the rule explicitly.
#  WARN = the spec is silent or ambiguous; this is the most likely reading.
#
#  Phones and plan ids carry a random 3-digit tag, so the script can be re-run
#  against a container that already holds data from an earlier run.
# =============================================================================

BASE=${BASE:-http://localhost:8080}
TIMEOUT=${TIMEOUT:-20}
BIG=${BIG:-1500}
RUN=${RUN:-$(printf '%03d' $(( (RANDOM + $$) % 1000 )))}

command -v curl >/dev/null || { echo "curl is required"; exit 2; }
command -v jq   >/dev/null || { echo "jq is required (brew install jq / apt install jq)"; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; WARN=0; N5XX=0; LEVEL=fail; SEC=0; SEQ=0
: > "$TMP/failures"; : > "$TMP/warnings"; : > "$TMP/5xx"
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'; else G=; R=; Y=; B=; Z=; fi
curl --help all 2>/dev/null | grep -q -- '--parallel-immediate' && HAVE_Z=1 || HAVE_Z=0

# ----------------------------------------------------------------------------- helpers
sq()  { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
enc() { jq -rn --arg s "$1" '$s|@uri'; }
section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
note()    { [ "${Q:-0}" = 1 ] || printf '   %s\n' "$1"; }

# call METHOD PATH [JSON_BODY]   -> STATUS, BODY, CURL
call() {
  local method=$1 path=$2
  if [ $# -ge 3 ]; then
    CURL="curl -i -X $method '$BASE$path' -H 'Content-Type: application/json' -d '$(sq "$3")'"
    STATUS=$(curl -sS -m "$TIMEOUT" -o "$TMP/body" -w '%{http_code}' -X "$method" "$BASE$path" \
             -H 'Content-Type: application/json' --data-binary "$3" 2>/dev/null) || STATUS=000
  else
    CURL="curl -i '$BASE$path'"
    STATUS=$(curl -sS -m "$TIMEOUT" -o "$TMP/body" -w '%{http_code}' -X "$method" "$BASE$path" 2>/dev/null) || STATUS=000
  fi
  BODY=$(cat "$TMP/body" 2>/dev/null)
  case "$STATUS" in 5*|000) N5XX=$((N5XX+1)); printf '%s  ->  HTTP %s\n' "$CURL" "$STATUS" >> "$TMP/5xx";; esac
  [ "${V:-0}" = 1 ] && printf '   $ %s\n' "$CURL"
  return 0
}

ok() { PASS=$((PASS+1)); [ "${Q:-0}" = 1 ] || printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
bad() { # DESC EXPECTED [GOT]
  local got=${3:-"HTTP $STATUS  $(printf '%s' "$BODY" | head -c 700)"}
  if [ "$LEVEL" = warn ]; then
    WARN=$((WARN+1)); printf '  %sWARN%s %s\n' "$Y" "$Z" "$1"; printf '%s\n' "$1" >> "$TMP/warnings"
  else
    FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$R" "$Z" "$1"; printf '%s\n' "$1" >> "$TMP/failures"
  fi
  printf '        expected: %s\n        got:      %s\n        repro:    %s\n' "$2" "$got" "$CURL"
}
soft() { LEVEL=warn; "$@"; local r=$?; LEVEL=fail; return $r; }

# expect DESC STATUS [JQ_FILTER [jq options...]]   (checks the last call)
expect() {
  local desc=$1 st=$2; shift 2
  local filt=true; if [ $# -gt 0 ]; then filt=$1; shift; fi
  if [ "$STATUS" != "$st" ]; then bad "$desc" "HTTP $st${EXPECT_HINT:+  $EXPECT_HINT}"; return 1; fi
  if ! printf '%s' "$BODY" | jq -e "$@" "$filt" >/dev/null 2>&1; then
    bad "$desc" "HTTP $st, body satisfying  ${EXPECT_HINT:-$filt}"; return 1
  fi
  ok "$desc"
}
# expect_err DESC STATUS CODE   (also checks the error envelope)
expect_err() {
  EXPECT_HINT="{\"error\":{\"code\":\"$3\",\"message\":\"...\"}}" \
  expect "$1" "$2" '(.error|type=="object") and .error.code==$c and (.error.message|type=="string")' --arg c "$3"
}
# expect_err_any DESC STATUS CODE1 CODE2
expect_err_any() {
  EXPECT_HINT="error.code $3 or $4" \
  expect "$1" "$2" '(.error|type=="object") and (.error.code==$a or .error.code==$b) and (.error.message|type=="string")' --arg a "$3" --arg b "$4"
}
fixture_fail() { LEVEL=fail; bad "FIXTURE: $1 (the checks that depend on it are skipped)" "HTTP 201"; return 1; }

# fresh phone digits: T8 = 8 free digits for AE/SA (after the 5), T7 = 7 free digits for BH (after the 3)
t8() { SEQ=$((SEQ+1)); T8=$(printf '%s%s%04d' "$SEC" "$RUN" "$SEQ"); }
t7() { SEQ=$((SEQ+1)); T7=$(printf '%s%s%03d' "$SEC" "$RUN" "$SEQ"); }

member_body() { jq -cn --arg n "$1" --arg c "$2" --arg p "$3" '{name:$n,country:$c,phone:$p}'; }
post_member() { call POST /members "$(member_body "$1" "$2" "$3")"; }
# mk_member NAME COUNTRY PHONE -> MID (for URLs), MIDJ (JSON-encoded, for bodies)
mk_member() {
  post_member "$1" "$2" "$3"
  [ "$STATUS" = 201 ] || { fixture_fail "POST /members $2 $3"; return 1; }
  MIDJ=$(printf '%s' "$BODY" | jq -c '.id'); MID=$(printf '%s' "$BODY" | jq -r '.id')
}
lookup() { # PHONE [COUNTRY]
  if [ $# -ge 2 ]; then call GET "/members/lookup?phone=$(enc "$1")&country=$2"; else call GET "/members/lookup?phone=$(enc "$1")"; fi
}
plan_body() { jq -cn --arg i "$1" --arg c "$2" --argjson m "$3" --argjson f "$4" '{id:$i,country:$c,monthly:$m,joining_fee:$f}'; }
mk_plan() { # ID COUNTRY MONTHLY FEE
  call POST /plans "$(plan_body "$1" "$2" "$3" "$4")"
  [ "$STATUS" = 201 ] || { fixture_fail "POST /plans $1"; return 1; }
}
agreement_body() { jq -cn --argjson m "$1" --arg p "$2" --arg s "$3" --argjson d "$4" '{member_id:$m,plan_id:$p,start_date:$s,due_day:$d}'; }
# mk_agreement MEMBER_ID_JSON PLAN START DUE_DAY -> AID, AIDJ
mk_agreement() {
  call POST /agreements "$(agreement_body "$1" "$2" "$3" "$4")"
  [ "$STATUS" = 201 ] || { fixture_fail "POST /agreements plan=$2 start=$3 due_day=$4"; return 1; }
  AIDJ=$(printf '%s' "$BODY" | jq -c '.id'); AID=$(printf '%s' "$BODY" | jq -r '.id')
}
invoices() { call GET "/agreements/$1/invoices?from=$2&to=$3"; }

# want_invoices CUR "NO DUE KIND DAYS/CYCLE|- NET VAT TOTAL" ...  -> JSON array
want_invoices() {
  local cur=$1; shift
  [ $# -eq 0 ] && { echo '[]'; return; }
  printf '%s\n' "$@" | jq -Rcn --arg cur "$cur" '[inputs | split(" ") | {invoice_no:(.[0]|tonumber), due_date:.[1], kind:.[2],
     proration:(if .[3]=="-" then null else (.[3]|split("/")|{days:(.[0]|tonumber),cycle_days:(.[1]|tonumber)}) end),
     net:(.[4]|tonumber), vat:(.[5]|tonumber), total:(.[6]|tonumber), currency:$cur}]'
}
# expect_invoices DESC CUR line...   (exact list, in order; extra response fields are tolerated)
expect_invoices() {
  local desc=$1 want; shift; want=$(want_invoices "$@")
  EXPECT_HINT="$want" expect "$desc" 200 \
    '(type=="array") and (map({invoice_no,due_date,kind,proration,net,vat,total,currency}) == $want) and all(.[]; has("proration"))' \
    --argjson want "$want"
}
# schedule_case DESC COUNTRY MONTHLY FEE START DUE_DAY FROM TO line...   (own member + plan + agreement)
schedule_case() {
  local desc=$1 c=$2 monthly=$3 fee=$4 start=$5 dd=$6 from=$7 to=$8 cur; shift 8
  case $c in AE) cur=AED;; SA) cur=SAR;; BH) cur=BHD;; esac
  if [ "$c" = BH ]; then t7; mk_member "Sched $SEQ" BH "+9733$T7" || return
  elif [ "$c" = AE ]; then t8; mk_member "Sched $SEQ" AE "+9715$T8" || return
  else t8; mk_member "Sched $SEQ" SA "+9665$T8" || return; fi
  local pid="p$SEC-$RUN-$SEQ"
  mk_plan "$pid" "$c" "$monthly" "$fee" || return
  mk_agreement "$MIDJ" "$pid" "$start" "$dd" || return
  invoices "$AID" "$from" "$to"
  expect_invoices "$desc" "$cur" "$@"
}

# burst PATH BODY...   fires all bodies at the same moment -> $TMP/burst/codes ("N CODE"), $TMP/burst/N.body
burst() {
  local path=$1 i=0 b; shift
  rm -rf "$TMP/burst"; mkdir -p "$TMP/burst"
  CURL="(concurrent burst of $# x POST $BASE$path - e.g.)  curl -i -X POST '$BASE$path' -H 'Content-Type: application/json' -d '$(sq "$1")'"
  if [ "$HAVE_Z" = 1 ]; then
    local args=()
    for b in "$@"; do i=$((i+1)); [ $i -gt 1 ] && args+=(--next)
      args+=(-sS -m "$TIMEOUT" -X POST "$BASE$path" -H 'Content-Type: application/json' --data-binary "$b"
             -o "$TMP/burst/$i.body" -w '%{filename_effective} %{http_code}\n'); done
    curl -Z --parallel-immediate --parallel-max 64 "${args[@]}" 2>/dev/null \
      | sed -e 's#^.*/\([0-9]*\)\.body #\1 #' > "$TMP/burst/codes"
  else
    for b in "$@"; do i=$((i+1))
      ( c=$(curl -sS -m "$TIMEOUT" -o "$TMP/burst/$i.body" -w '%{http_code}' -X POST "$BASE$path" \
              -H 'Content-Type: application/json' --data-binary "$b" 2>/dev/null); echo "$i $c" > "$TMP/burst/$i.code" ) &
    done; wait; cat "$TMP/burst/"*.code > "$TMP/burst/codes"
  fi
  if grep -Eq ' (5[0-9][0-9]|000)$' "$TMP/burst/codes"; then N5XX=$((N5XX+1)); echo "$CURL  ->  5xx inside burst" >> "$TMP/5xx"; fi
}
burst_count() { grep -c " $1\$" "$TMP/burst/codes"; }
burst_summary() { awk '{print $2}' "$TMP/burst/codes" | sort | uniq -c | awk '{printf "%sx%s ", $1, $2}'; }

need_server() {
  call GET /health
  if [ "$STATUS" != 200 ]; then echo "${R}GET $BASE/health returned HTTP $STATUS - is the container running?  docker run --rm -p 8080:8080 app${Z}"; exit 2; fi
}

# ============================================================================= CONTRACT
contract() {
  SEC=0; section "CONTRACT - health, 404s, error envelope"
  call GET /health;                                  expect "GET /health -> 200" 200
  call GET "/agreements/no-such-agreement/invoices?from=2026-01-01&to=2026-01-31"
  expect_err "unknown agreement id in URL -> 404 NOT_FOUND" 404 NOT_FOUND
  call GET /reconciliation/runs/no-such-run;         expect_err "unknown run id in URL -> 404 NOT_FOUND" 404 NOT_FOUND
  call GET "/members/lookup?phone=%2B966500000000";  expect_err "lookup of a valid phone nobody has -> 404 NOT_FOUND" 404 NOT_FOUND

  call POST /members '{"name": "Broken", "country": "SA", "phone": '
  soft expect_err "POST /members with truncated JSON -> 422 VALIDATION" 422 VALIDATION
  call POST /members '[]';       soft expect_err "POST /members with a JSON array body -> 422 VALIDATION" 422 VALIDATION
  call POST /plans '"hello"';    soft expect_err "POST /plans with a JSON string body -> 422 VALIDATION" 422 VALIDATION
  call POST /agreements 'null';  soft expect_err "POST /agreements with null body -> 422 VALIDATION" 422 VALIDATION
  call POST /reconciliation/runs '';  soft expect_err "POST /reconciliation/runs with empty body -> 422 VALIDATION" 422 VALIDATION
  call GET /no-such-route
  soft expect "unknown route -> 404 with the standard error envelope" 404 '(.error.code|type=="string") and (.error.message|type=="string")'
}

# ============================================================================= PART 1
part1() {
  SEC=1; SEQ=0
  p1_spec_example; p1_countries; p1_foreign_sim; p1_invalid_phones; p1_validation; p1_phone_taken; p1_race
}

p1_spec_example() {
  section "PART 1.1 - create + lookup in all three spellings (spec example)"
  t8; local nat="05$T8" e164="+9665$T8" bare="9665$T8" spaced="05${T8:0:1} ${T8:1:3} ${T8:4:4}"
  post_member "Noura Al Harbi" SA "$spaced"
  expect "POST national '05X XXX XXXX' -> 201 with E.164 phone, id is a non-empty string" 201 \
    '(.id|type=="string") and (.id|length>0) and .name=="Noura Al Harbi" and .country=="SA" and .phone==$p' --arg p "$e164" || return
  local idj; idj=$(printf '%s' "$BODY" | jq -c .id)
  local same='.id==$id and .name=="Noura Al Harbi" and .country=="SA" and .phone==$p'
  lookup "$bare";                expect "lookup 9665XXXXXXXX (no plus) -> same member"            200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "$e164";                expect "lookup %2B9665XXXXXXXX -> same member"                   200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "$spaced" SA;           expect "lookup national with spaces + country=SA -> same member" 200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "$nat" SA;              expect "lookup national no spaces + country=SA -> same member"   200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "$e164" SA;             expect "lookup international + matching country=SA -> 200"        200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "$bare" SA;             expect "lookup no-plus international + matching country=SA -> 200" 200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "+966 (5${T8:0:1}) ${T8:1:3}-${T8:4:4}"
                                 expect "lookup '+966 (5X) XXX-XXXX' (spaces, hyphen, brackets cleaned) -> same member" 200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "(+966) 5$T8";          expect "lookup '(+966) 5XXXXXXXX' (plus is leading once brackets are removed) -> same member" 200 "$same" --argjson id "$idj" --arg p "$e164"
  call GET "/members/lookup?phone=+9665$T8"
                                 expect "lookup with a raw '+' in the query (decodes to a space or a plus; both are valid) -> same member" 200 "$same" --argjson id "$idj" --arg p "$e164"
  lookup "$nat";                 expect_err "lookup national without country -> 422 PHONE_NEEDS_COUNTRY" 422 PHONE_NEEDS_COUNTRY
  lookup "$e164" AE;             expect_err "lookup +966... with country=AE -> 422 PHONE_COUNTRY_MISMATCH" 422 PHONE_COUNTRY_MISMATCH
  lookup "$bare" BH;             expect_err "lookup 966... (no plus) with country=BH -> 422 PHONE_COUNTRY_MISMATCH" 422 PHONE_COUNTRY_MISMATCH
  lookup "$nat" AE;              expect_err "lookup same national digits read as AE (different number, nobody has it) -> 404 NOT_FOUND" 404 NOT_FOUND
  lookup "$nat" BH;              expect_err "lookup 05X national with country=BH (does not fit BH shape) -> 422 INVALID_PHONE" 422 INVALID_PHONE
}

p1_countries() {
  section "PART 1.2 - normalisation for AE and BH, every spelling"
  t8; post_member "Ahmed Al Mansoori" AE "05${T8:0:1} ${T8:1:3} ${T8:4:4}"
  expect "AE national -> +9715XXXXXXXX" 201 '.phone==$p and .country=="AE"' --arg p "+9715$T8"
  local aej; aej=$(printf '%s' "$BODY" | jq -c .id)
  lookup "9715$T8";    expect "AE lookup without plus -> same member" 200 '.id==$id' --argjson id "$aej"
  lookup "05$T8" AE;   expect "AE lookup national + country=AE -> same member" 200 '.id==$id' --argjson id "$aej"
  t8; post_member "Fatima" AE "9715$T8"
  expect "AE dial+mobile without plus on POST -> stored as +9715XXXXXXXX" 201 '.phone==$p' --arg p "+9715$T8"
  t8; post_member "Hamad" AE "+971-5${T8:0:1}-${T8:1:3}-${T8:4:4}"
  expect "AE '+971-5X-XXX-XXXX' -> +9715XXXXXXXX" 201 '.phone==$p' --arg p "+9715$T8"

  t7; post_member "Maryam Al Khalifa" BH "3${T7:0:3} ${T7:3:4}"
  expect "BH national '3XXX XXXX' (8 digits, no trunk zero) -> +9733XXXXXXX" 201 '.phone==$p and .country=="BH"' --arg p "+9733$T7"
  local bhj; bhj=$(printf '%s' "$BODY" | jq -c .id)
  lookup "9733$T7";    expect "BH lookup 9733XXXXXXX without plus -> same member" 200 '.id==$id' --argjson id "$bhj"
  lookup "+9733$T7";   expect "BH lookup +9733XXXXXXX -> same member" 200 '.id==$id' --argjson id "$bhj"
  lookup "3$T7" BH;    expect "BH lookup national + country=BH -> same member" 200 '.id==$id' --argjson id "$bhj"
  lookup "3$T7";       expect_err "BH national without country -> 422 PHONE_NEEDS_COUNTRY" 422 PHONE_NEEDS_COUNTRY
  lookup "3$T7" SA;    expect_err "BH-shaped national with country=SA -> 422 INVALID_PHONE" 422 INVALID_PHONE
  lookup "+9733$T7" SA; expect_err "BH international with country=SA -> 422 PHONE_COUNTRY_MISMATCH" 422 PHONE_COUNTRY_MISMATCH
  t7; lookup "3$T7";   expect_err "unregistered BH-shaped national, no country -> still 422 PHONE_NEEDS_COUNTRY (not 404)" 422 PHONE_NEEDS_COUNTRY
  t8; lookup "05$T8";  expect_err "unregistered 05X national, no country -> still 422 PHONE_NEEDS_COUNTRY (not 404)" 422 PHONE_NEEDS_COUNTRY
  t7; post_member "Yousif" BH "+973 3${T7:0:3} ${T7:3:4}"
  expect "BH '+973 3XXX XXXX' -> +9733XXXXXXX" 201 '.phone==$p' --arg p "+9733$T7"

  note "same national digits in two countries are two different phones"
  t8; post_member "Twin AE" AE "05$T8"; expect "AE member with national 05N" 201 '.phone==$p' --arg p "+9715$T8"
  local t1; t1=$(printf '%s' "$BODY" | jq -c .id)
  post_member "Twin SA" SA "05$T8";     expect "SA member with the same national digits -> 201 (different E.164)" 201 '.phone==$p and .id!=$o' --arg p "+9665$T8" --argjson o "$t1"
  local t2; t2=$(printf '%s' "$BODY" | jq -c .id)
  lookup "05$T8" AE;   expect "lookup 05N country=AE -> the AE member" 200 '.id==$id' --argjson id "$t1"
  lookup "05$T8" SA;   expect "lookup 05N country=SA -> the SA member" 200 '.id==$id' --argjson id "$t2"

  note "national numbers on POST are read in the member's own country and must fit its shape"
  t8; post_member "Wrong shape" BH "05$T8"; expect_err "POST country=BH with an 05X national -> 422 INVALID_PHONE" 422 INVALID_PHONE
  t7; post_member "Wrong shape" SA "3$T7";  expect_err "POST country=SA with a BH-shaped national -> 422 INVALID_PHONE" 422 INVALID_PHONE
  lookup "+9733$T7";   expect_err "the rejected POST stored nothing -> 404 NOT_FOUND" 404 NOT_FOUND
  post_member "Wrong shape" AE "3$T7";      expect_err "POST country=AE with a BH-shaped national -> 422 INVALID_PHONE" 422 INVALID_PHONE
}

p1_foreign_sim() {
  section "PART 1.3 - foreign SIMs: international number from another country"
  t8; post_member "Expat in Riyadh" SA "+9715$T8"
  expect "POST country=SA with +971 number -> 201, phone stays +971, country stays SA" 201 '.phone==$p and .country=="SA"' --arg p "+9715$T8" || return
  local idj; idj=$(printf '%s' "$BODY" | jq -c .id)
  lookup "+9715$T8";     expect "lookup +971... -> the SA member" 200 '.id==$id and .country=="SA"' --argjson id "$idj"
  lookup "+9715$T8" AE;  expect "lookup +971... country=AE (agrees with the dial code) -> 200" 200 '.id==$id' --argjson id "$idj"
  lookup "+9715$T8" SA;  expect_err "lookup +971... country=SA -> 422 PHONE_COUNTRY_MISMATCH (country is checked against the dial code, not the member)" 422 PHONE_COUNTRY_MISMATCH
  lookup "05$T8" AE;     expect "lookup national 05N country=AE -> finds the SA member holding that AE number" 200 '.id==$id' --argjson id "$idj"
  lookup "05$T8" SA;     expect_err "lookup national 05N country=SA -> a different number, 404 NOT_FOUND" 404 NOT_FOUND
  t7; post_member "Bahraini SIM in Dubai" AE "9733$T7"
  expect "POST country=AE with 9733... (no plus) -> 201 +9733..." 201 '.phone==$p and .country=="AE"' --arg p "+9733$T7"
  t8; post_member "Saudi SIM in Manama" BH "+9665$T8"
  expect "POST country=BH with +966 number -> 201" 201 '.phone==$p and .country=="BH"' --arg p "+9665$T8"
}

p1_invalid_phones() {
  section "PART 1.4 - INVALID_PHONE table (POST /members)"
  local c p why
  while IFS='|' read -r c p why; do
    [ -z "$c" ] && continue
    post_member "Bad Phone" "$c" "$p"
    expect_err "POST $c '$p' -> 422 INVALID_PHONE  ($why)" 422 INVALID_PHONE
  done <<'EOF'
SA|00966551234567|00 prefix
SA|+00966551234567|plus then 00
AE|00971501234567|00 prefix
BH|0097333123456|00 prefix
SA|+9660551234567|trunk zero kept after the dial code
SA|9660551234567|trunk zero kept after the dial code, no plus
AE|+9710501234567|trunk zero kept after the dial code
SA|551234567|national without the leading 0
AE|501234567|national without the leading 0
SA|+966112345678|Saudi landline
SA|0112345678|Saudi landline, national
SA|+966651234567|mobile part must start with 5
SA|0651234567|national must start 05
SA|+96655123456|one digit short
SA|+9665512345678|one digit long
SA|055123456|national one digit short
SA|05512345678|national one digit long
SA|96655123456|no-plus international one digit short
AE|+97141234567|Dubai landline
AE|041234567|Dubai landline, national
AE|+97150123456|one digit short
AE|+9715012345678|one digit long
BH|+97317123456|Bahrain landline
BH|17123456|Bahrain landline, national
BH|+9733312345|one digit short
BH|+973331234567|one digit long
BH|3312345|national 7 digits
BH|331234567|national 9 digits
BH|033123456|Bahrain has no trunk zero
BH|+973033123456|trunk zero after the dial code
BH|63123456|national must start with 3
SA|++966551234567|two plus signs
SA|+966+551234567|second plus in the middle
SA|966551234567+|trailing plus
SA|+|plus only
SA|055.123.4567|dots are not cleaned
SA|055/123/4567|slashes are not cleaned
SA|055_123_4567|underscores are not cleaned
SA|[055] 123 4567|square brackets are not cleaned
SA|055 123 4567 ext 2|letters
SA|+96655123456x|letter
SA|abc|letters only
SA|+966 55 123 4567;|semicolon
SA|+1 415 555 2671|country outside AE/SA/BH
SA|+965 5123 4567|Kuwait
SA|+44 7911 123456|UK
SA|+968 9123 4567|Oman
SA|5|single digit
EOF

  section "PART 1.5 - INVALID_PHONE on lookup"
  while IFS='|' read -r c p why; do
    [ -z "$p" ] && continue
    if [ "$c" = - ]; then lookup "$p"; else lookup "$p" "$c"; fi
    expect_err "lookup '$p' country=$c -> 422 INVALID_PHONE  ($why)" 422 INVALID_PHONE
  done <<'EOF'
-|00966551234567|00 prefix
-|+9660551234567|trunk zero after the dial code
-|966-055-123-4567|trunk zero after the dial code
-|+966112345678|landline
-|0112345678|landline national, fits no country
-|551234567|national without the 0
-|055.123.4567|dots
-|05512345ab|letters
-|++966551234567|two plus signs
-|+1 415 555 2671|other country
-|17123456|Bahrain landline
SA|00966551234567|00 prefix with country
SA|551234567|national without the 0, with country
BH|033123456|trunk zero in Bahrain, with country
AE|+97141234567|landline with country
EOF

  note "edge cases the spec does not spell out"
  post_member "Arabic digits" SA "٠٥٥١٢٣٤٥٦٧"
  if [ "$STATUS" = 201 ]; then soft expect "Arabic-Indic digits: if accepted, the stored phone must be ASCII E.164" 201 '.phone|test("^\\+[0-9]+$")'
  else soft expect_err "Arabic-Indic digits ٠٥٥١٢٣٤٥٦٧ are not ASCII digits -> 422 INVALID_PHONE" 422 INVALID_PHONE; fi
  post_member "Fullwidth digits" SA "０５５１２３４５６７"
  soft expect_err "full-width digits ０５５… -> 422 INVALID_PHONE" 422 INVALID_PHONE
  post_member "Empty phone" SA "";      soft expect_err_any "empty phone string -> 422 INVALID_PHONE (or VALIDATION)" 422 INVALID_PHONE VALIDATION
  post_member "Blank phone" SA "   ";   soft expect_err_any "phone of only spaces -> 422 INVALID_PHONE (or VALIDATION)" 422 INVALID_PHONE VALIDATION
  post_member "Brackets only" SA "(-)"; soft expect_err_any "phone '(-)' -> 422 INVALID_PHONE (or VALIDATION)" 422 INVALID_PHONE VALIDATION
  t8; post_member "Tab" SA "05$T8	";  soft expect_err "phone with a TAB (only spaces, hyphens, round brackets are cleaned) -> 422 INVALID_PHONE" 422 INVALID_PHONE
}

p1_validation() {
  section "PART 1.6 - 422 VALIDATION on POST /members and lookup"
  t8; local p="+9665$T8"
  call POST /members "{\"country\":\"SA\",\"phone\":\"$p\"}";                    expect_err "missing name -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"phone\":\"$p\"}";                        expect_err "missing country -> 422 VALIDATION" 422 VALIDATION
  call POST /members '{"name":"A","country":"SA"}';                              expect_err "missing phone -> 422 VALIDATION" 422 VALIDATION
  call POST /members '{}';                                                       expect_err "empty object -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":123,\"country\":\"SA\",\"phone\":\"$p\"}";       expect_err "name is a number -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":null,\"country\":\"SA\",\"phone\":\"$p\"}";      expect_err "name is null -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"\",\"country\":\"SA\",\"phone\":\"$p\"}";      expect_err "name is empty -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"     \",\"country\":\"SA\",\"phone\":\"$p\"}"; expect_err "name is only spaces (empty after trim) -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"country\":\"KW\",\"phone\":\"$p\"}";     expect_err "country KW -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"country\":\"\",\"phone\":\"$p\"}";       expect_err "country empty -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"country\":null,\"phone\":\"$p\"}";       expect_err "country null -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"country\":\"SAU\",\"phone\":\"$p\"}";    expect_err "country SAU -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"country\":\"sa\",\"phone\":\"$p\"}";     soft expect_err "country lowercase 'sa' -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"country\":\"SA\",\"phone\":9665$T8}";    expect_err "phone is a JSON number -> 422 VALIDATION" 422 VALIDATION
  call POST /members '{"name":"A","country":"SA","phone":null}';                 expect_err "phone is null -> 422 VALIDATION" 422 VALIDATION
  call POST /members "{\"name\":\"A\",\"country\":\"SA\",\"phone\":[\"$p\"]}";   expect_err "phone is an array -> 422 VALIDATION" 422 VALIDATION
  lookup "$p"; expect_err "none of the rejected requests created a member -> 404 NOT_FOUND" 404 NOT_FOUND

  local n120 n121; n120=$(printf 'N%.0s' $(seq 1 120)); n121="${n120}N"
  post_member "$n121" SA "$p";              expect_err "name of 121 characters -> 422 VALIDATION" 422 VALIDATION
  post_member "$n120" SA "$p";              expect "name of exactly 120 characters -> 201" 201 '.name|length==120'
  t8; post_member "   $n120   " SA "+9665$T8"; expect "120 characters padded with spaces -> 201 (trim first, then measure)" 201 '.name==$n' --arg n "$n120"
  t8; post_member "  Noura Al Harbi  " SA "+9665$T8"; expect "name is returned trimmed" 201 '.name=="Noura Al Harbi"'
  lookup "+9665$T8";                        expect "lookup returns the trimmed name too" 200 '.name=="Noura Al Harbi"'
  t8; post_member "X" SA "+9665$T8";        expect "one-character name -> 201" 201 '.name=="X"'
  t8; post_member " Y " SA "+9665$T8";      expect "one character after trimming -> 201" 201 '.name=="Y"'
  t8; post_member "Noura  Al   Harbi" SA "+9665$T8"; expect "inner spaces are kept (only the ends are trimmed)" 201 '.name=="Noura  Al   Harbi"'
  local ar120; ar120=$(printf 'ن%.0s' $(seq 1 120))
  t8; post_member "$ar120" SA "+9665$T8";   expect "120 Arabic characters (240 bytes) -> 201; length is characters, not bytes" 201 '.name==$n' --arg n "$ar120"
  t8; post_member "${ar120}ن" SA "+9665$T8"; expect_err "121 Arabic characters -> 422 VALIDATION" 422 VALIDATION
  t8; post_member "نورة الحربي" SA "+9665$T8"; expect "Arabic name round-trips unchanged" 201 '.name=="نورة الحربي"'

  call GET /members/lookup;                           expect_err "lookup without phone -> 422 VALIDATION" 422 VALIDATION
  call GET "/members/lookup?country=SA";              expect_err "lookup with country but no phone -> 422 VALIDATION" 422 VALIDATION
  lookup "+966551234567" XX;                          expect_err "lookup country=XX -> 422 VALIDATION" 422 VALIDATION
  lookup "0551234567" KW;                             expect_err "lookup national with country=KW -> 422 VALIDATION" 422 VALIDATION
  lookup "+966551234567" sa;                          soft expect_err "lookup country=sa (lowercase) -> 422 VALIDATION" 422 VALIDATION
}

p1_phone_taken() {
  section "PART 1.7 - one member per phone, in any spelling"
  t8; mk_member "Original Owner" SA "05$T8" || return
  local idj=$MIDJ taken='.error.code=="PHONE_TAKEN" and (.error.message|type=="string") and .error.existing_member_id==$id'
  EXPECT_HINT='error.code PHONE_TAKEN with error.existing_member_id = first member id'
  post_member "Dup" SA "05$T8";                                expect "same national again -> 409 PHONE_TAKEN + existing_member_id" 409 "$taken" --argjson id "$idj"
  post_member "Dup" SA "+9665$T8";                             expect "+966 spelling -> 409 PHONE_TAKEN + existing_member_id" 409 "$taken" --argjson id "$idj"
  post_member "Dup" SA "9665$T8";                              expect "966 spelling without plus -> 409 PHONE_TAKEN" 409 "$taken" --argjson id "$idj"
  post_member "Dup" SA "(05${T8:0:1}) ${T8:1:3}-${T8:4:4}";    expect "'(05X) XXX-XXXX' -> 409 PHONE_TAKEN" 409 "$taken" --argjson id "$idj"
  post_member "Dup" AE "+9665$T8";                             expect "another country's member with the same +966 number -> 409 PHONE_TAKEN" 409 "$taken" --argjson id "$idj"
  post_member "Dup" BH "9665$T8";                              expect "BH member, 966 spelling -> 409 PHONE_TAKEN" 409 "$taken" --argjson id "$idj"
  EXPECT_HINT=
  expect "existing_member_id sits inside error, not at the top level" 409 '(.error|has("existing_member_id")) and (has("existing_member_id")|not)'
  lookup "+9665$T8"; expect "the original member is untouched after the 409s" 200 '.id==$id and .name=="Original Owner" and .country=="SA"' --argjson id "$idj"
  t8; mk_member "Second" SA "05$T8" || return
  expect "a different phone -> new member with a different id" 201 '.id!=$id' --argjson id "$idj"
}

p1_race() {
  section "PART 1.8 - PHONE_TAKEN under concurrency"
  local round bodies winners losers okc win bad_ids
  for round in 1 2 3 4 5; do
    t8
    local spell=("05$T8" "+9665$T8" "9665$T8" "05${T8:0:1} ${T8:1:3} ${T8:4:4}" "+966 5${T8:0:1} ${T8:1:3} ${T8:4:4}" "(9665)$T8")
    bodies=(); local i
    for i in $(seq 0 23); do bodies+=("$(member_body "Racer $i" SA "${spell[$((i % 6))]}")"); done
    burst /members "${bodies[@]}"
    winners=$(burst_count 201); losers=$(burst_count 409)
    if [ "$winners" = 1 ] && [ "$losers" = 23 ]; then
      win=$(for i in $(seq 1 24); do grep -q "^$i 201\$" "$TMP/burst/codes" && jq -c .id "$TMP/burst/$i.body"; done)
      bad_ids=0
      for i in $(seq 1 24); do grep -q "^$i 409\$" "$TMP/burst/codes" || continue
        jq -e --argjson w "$win" '.error.code=="PHONE_TAKEN" and .error.existing_member_id==$w' "$TMP/burst/$i.body" >/dev/null 2>&1 || bad_ids=$((bad_ids+1)); done
      if [ "$bad_ids" = 0 ]; then ok "round $round: 24 simultaneous POSTs, 6 spellings of one phone -> exactly one 201, 23 x 409 pointing at the winner"
      else bad "round $round: every 409 must carry existing_member_id of the winner" "23 x PHONE_TAKEN with existing_member_id=$win" "$bad_ids responses with a wrong code or id"; fi
      lookup "+9665$T8"; expect "round $round: lookup returns the winner" 200 '.id==$w' --argjson w "$win"
    else
      bad "round $round: 24 simultaneous POSTs for one phone" "1 x 201 and 23 x 409" "$(burst_summary)"
    fi
  done
  bodies=()
  for i in $(seq 1 40); do t8; bodies+=("$(member_body "Crowd $i" SA "+9665$T8")"); done
  burst /members "${bodies[@]}"
  okc=$(burst_count 201)
  local uniq; uniq=$(cat "$TMP"/burst/*.body | jq -c '.id' 2>/dev/null | sort -u | wc -l | tr -d ' ')
  if [ "$okc" = 40 ] && [ "$uniq" = 40 ]; then ok "40 simultaneous POSTs with different phones -> 40 x 201, 40 unique ids"
  else bad "40 simultaneous POSTs with different phones" "40 x 201 with 40 unique ids" "$(burst_summary) / $uniq unique ids"; fi
}

# ============================================================================= PART 2
part2() {
  SEC=2; SEQ=0
  p2_plans; p2_agreements; p2_worked_examples; p2_range; p2_due_dates; p2_rounding; p2_bhd
}

p2_plans() {
  section "PART 2.1 - plans"
  local id="p2-$RUN-anytime-sa"
  call POST /plans "$(plan_body "$id" SA 29900 0)"
  expect "POST /plans SA -> 201 with currency SAR" 201 '.id==$i and .country=="SA" and .currency=="SAR" and .monthly==29900 and .joining_fee==0' --arg i "$id"
  call POST /plans "$(plan_body "$id" SA 29900 0)";       expect_err "same id again -> 409 PLAN_EXISTS" 409 PLAN_EXISTS
  call POST /plans "$(plan_body "$id" AE 100 5)";         expect_err "same id with different content -> 409 PLAN_EXISTS" 409 PLAN_EXISTS
  call POST /plans "$(plan_body "p2-$RUN-ae" AE 24900 9900)"; expect "AE plan -> currency AED" 201 '.currency=="AED" and .joining_fee==9900 and .monthly==24900'
  call POST /plans "$(plan_body "p2-$RUN-bh" BH 24500 0)";    expect "BH plan -> currency BHD" 201 '.currency=="BHD" and .monthly==24500'
  call POST /plans "$(plan_body "p2-$RUN-min" SA 1 0)";       expect "monthly = 1, joining_fee = 0 (smallest legal values) -> 201" 201 '.monthly==1 and .joining_fee==0'
  call POST /plans "$(plan_body "p2-$RUN-huge" SA 3000000000 0)"; soft expect "monthly = 3000000000 (above 32-bit) -> 201, value intact" 201 '.monthly==3000000000'
  call POST /plans "{\"id\":\"p2-$RUN-cur\",\"country\":\"SA\",\"monthly\":100,\"joining_fee\":0,\"currency\":\"AED\"}"
  if [ "$STATUS" = 201 ]; then soft expect "caller-supplied currency is ignored; currency comes from the country" 201 '.currency=="SAR"'; fi

  local v="p2-$RUN-v" body why
  while IFS='|' read -r body why; do
    [ -z "$body" ] && continue
    body=$(printf '%s' "$body" | sed "s/@ID/$v/")
    call POST /plans "$body"; expect_err "plan with $why -> 422 VALIDATION" 422 VALIDATION
  done <<'EOF'
{"id":"@ID","country":"SA","monthly":0,"joining_fee":0}|monthly 0
{"id":"@ID","country":"SA","monthly":-100,"joining_fee":0}|monthly negative
{"id":"@ID","country":"SA","monthly":299.5,"joining_fee":0}|monthly 299.5
{"id":"@ID","country":"SA","monthly":"29900","joining_fee":0}|monthly as a string
{"id":"@ID","country":"SA","monthly":null,"joining_fee":0}|monthly null
{"id":"@ID","country":"SA","monthly":true,"joining_fee":0}|monthly true
{"id":"@ID","country":"SA","joining_fee":0}|monthly missing
{"id":"@ID","country":"SA","monthly":29900,"joining_fee":-1}|joining_fee -1
{"id":"@ID","country":"SA","monthly":29900,"joining_fee":0.5}|joining_fee 0.5
{"id":"@ID","country":"SA","monthly":29900,"joining_fee":"0"}|joining_fee as a string
{"id":"@ID","country":"SA","monthly":29900,"joining_fee":null}|joining_fee null
{"id":"@ID","country":"QA","monthly":29900,"joining_fee":0}|country QA
{"id":"@ID","monthly":29900,"joining_fee":0}|country missing
{"id":"@ID","country":784,"monthly":29900,"joining_fee":0}|country as a number
{"country":"SA","monthly":29900,"joining_fee":0}|id missing
{"id":12345,"country":"SA","monthly":29900,"joining_fee":0}|id as a number
{"id":null,"country":"SA","monthly":29900,"joining_fee":0}|id null
EOF
  call POST /plans "{\"id\":\"$v-nofee\",\"country\":\"SA\",\"monthly\":29900}"; soft expect_err "joining_fee missing -> 422 VALIDATION" 422 VALIDATION
  call POST /plans '{"id":"","country":"SA","monthly":29900,"joining_fee":0}';   soft expect_err "empty plan id -> 422 VALIDATION" 422 VALIDATION
  call POST /plans "$(plan_body "$v" SA 29900 0)"; expect "the id used in the rejected requests is still free -> 201" 201

  local bodies=() i okc dup
  for i in $(seq 1 20); do bodies+=("$(plan_body "p2-$RUN-race" SA $((1000 + i)) 0)"); done
  burst /plans "${bodies[@]}"; okc=$(burst_count 201); dup=$(burst_count 409)
  if [ "$okc" = 1 ] && [ "$dup" = 19 ]; then ok "20 simultaneous POST /plans with one id -> exactly one 201, 19 x 409"
  else bad "20 simultaneous POST /plans with one id" "1 x 201 and 19 x 409" "$(burst_summary)"; fi
}

p2_agreements() {
  section "PART 2.2 - agreements"
  t8; mk_member "Agreement SA" SA "+9665$T8" || return; local sa=$MIDJ
  t8; mk_member "Agreement AE" AE "+9715$T8" || return; local ae=$MIDJ
  t8; mk_member "Expat SA member, AE SIM" SA "+9715$T8" || return; local expat=$MIDJ
  local psa="p2-$RUN-ag-sa" pae="p2-$RUN-ag-ae"
  mk_plan "$psa" SA 29900 0 || return; mk_plan "$pae" AE 24900 9900 || return

  call POST /agreements "$(agreement_body "$sa" "$psa" 2026-09-20 1)"
  expect "POST /agreements -> 201 echoing member_id, plan_id, start_date, due_day; id is a string" 201 \
    '(.id|type=="string") and (.id|length>0) and .member_id==$m and .plan_id==$p and .start_date=="2026-09-20" and .due_day==1' --argjson m "$sa" --arg p "$psa"
  local first; first=$(printf '%s' "$BODY" | jq -c .id)
  call POST /agreements "$(agreement_body "$sa" "$psa" 2026-09-20 1)"
  expect "a member may hold several agreements (identical second one) -> 201 with a new id" 201 '.id!=$f' --argjson f "$first"
  call POST /agreements "$(agreement_body "$sa" "$psa" 2028-02-29 31)"; expect "start_date 2028-02-29 (leap day), due_day 31 -> 201" 201 '.due_day==31 and .start_date=="2028-02-29"'
  call POST /agreements "$(agreement_body "$expat" "$psa" 2026-09-20 1)"; expect "SA member carrying an AE SIM + SA plan -> 201 (country is the member's, not the phone's)" 201
  call POST /agreements "$(agreement_body "$expat" "$pae" 2026-09-20 1)"; expect_err "SA member carrying an AE SIM + AE plan -> 422 PLAN_COUNTRY_MISMATCH" 422 PLAN_COUNTRY_MISMATCH
  call POST /agreements "$(agreement_body "$sa" "$pae" 2026-09-20 1)";    expect_err "SA member + AE plan -> 422 PLAN_COUNTRY_MISMATCH" 422 PLAN_COUNTRY_MISMATCH
  call POST /agreements "$(agreement_body "$ae" "$psa" 2026-09-20 1)";    expect_err "AE member + SA plan -> 422 PLAN_COUNTRY_MISMATCH" 422 PLAN_COUNTRY_MISMATCH
  call POST /agreements "$(agreement_body '"no-such-member"' "$psa" 2026-09-20 1)"; expect_err "unknown member -> 422 UNKNOWN_MEMBER (not 404)" 422 UNKNOWN_MEMBER
  call POST /agreements "$(agreement_body "$sa" "no-such-plan-$RUN" 2026-09-20 1)"; expect_err "unknown plan -> 422 UNKNOWN_PLAN (not 404)" 422 UNKNOWN_PLAN

  local m; m=$sa
  local tmpl why field val
  while IFS='|' read -r field val why; do
    [ -z "$field" ] && continue
    call POST /agreements "$(jq -cn --argjson m "$m" --arg p "$psa" --arg f "$field" --argjson v "$val" \
        '{member_id:$m,plan_id:$p,start_date:"2026-09-20",due_day:1} | .[$f]=$v')"
    expect_err "agreement with $why -> 422 VALIDATION" 422 VALIDATION
  done <<'EOF'
due_day|0|due_day 0
due_day|32|due_day 32
due_day|-1|due_day -1
due_day|1.5|due_day 1.5
due_day|"1"|due_day as a string
due_day|null|due_day null
due_day|true|due_day true
start_date|"2026-02-30"|start_date 2026-02-30 (no such day)
start_date|"2027-02-29"|start_date 2027-02-29 (not a leap year)
start_date|"2026-13-01"|start_date month 13
start_date|"2026-00-10"|start_date month 00
start_date|"2026-09-31"|start_date 2026-09-31
start_date|"20-09-2026"|start_date DD-MM-YYYY
start_date|"2026/09/20"|start_date with slashes
start_date|"2026-9-20"|start_date without zero padding
start_date|"20260920"|start_date without separators
start_date|"2026-09-20T00:00:00Z"|start_date with a time and zone
start_date|"2026-09-20 00:00:00"|start_date with a time
start_date|""|start_date empty
start_date|null|start_date null
start_date|20260920|start_date as a number
start_date|"tomorrow"|start_date as a word
plan_id|null|plan_id null
plan_id|17|plan_id as a number
member_id|null|member_id null
EOF
  for field in member_id plan_id start_date due_day; do
    call POST /agreements "$(jq -cn --argjson m "$m" --arg p "$psa" --arg f "$field" '{member_id:$m,plan_id:$p,start_date:"2026-09-20",due_day:1} | del(.[$f])')"
    expect_err "agreement missing $field -> 422 VALIDATION" 422 VALIDATION
  done
}

p2_worked_examples() {
  section "PART 2.3 - the two worked examples, exactly"
  schedule_case "worked example 1: SA 29900, start 20 Sep, due day 1 -> 11/30, net 10963, VAT 1644 (not 1645), total 12607" \
    SA 29900 0 2026-09-20 1 2026-09-01 2026-12-31 \
    "1 2026-09-20 FIRST 11/30 10963 1644 12607" "2 2026-10-01 MONTHLY - 29900 4485 34385" \
    "3 2026-11-01 MONTHLY - 29900 4485 34385" "4 2026-12-01 MONTHLY - 29900 4485 34385"
  WE1=$AID
  if printf '%s' "$BODY" | grep -Eq '"(net|vat|total|invoice_no)" *: *[0-9]+\.[0-9]'; then
    LEVEL=warn; bad "money fields are JSON integers, not 10963.0" "integers" "a decimal point in net / vat / total"; LEVEL=fail
  else ok "money fields are JSON integers, not 10963.0"; fi
  schedule_case "worked example 2: AE 24900 + joining fee 9900, start 5 Sep, due day 20 -> 15/31, net 21948, VAT 1097, total 23045; September has two invoices" \
    AE 24900 9900 2026-09-05 20 2026-09-01 2026-10-31 \
    "1 2026-09-05 FIRST 15/31 21948 1097 23045" "2 2026-09-20 MONTHLY - 24900 1245 26145" "3 2026-10-20 MONTHLY - 24900 1245 26145"
  WE2=$AID
  invoices "$WE2" 2026-09-01 2027-09-02
  expect "worked example 2 over a 366-day window -> 13 invoices, numbered 1..13, joining fee only on invoice 1" 200 \
    'length==13 and ([.[].invoice_no]==[range(1;14)]) and ([.[1:][]|.net]|unique==[24900]) and ([.[1:][]|.kind]|unique==["MONTHLY"]) and .[12].due_date=="2027-08-20"'
}

p2_range() {
  section "PART 2.4 - from / to filtering, invoice_no, INVALID_RANGE"
  [ -n "${WE1:-}" ] || { note "skipped: worked example 1 agreement was not created"; return; }
  local a=$WE1
  invoices "$a" 2026-09-20 2026-09-20; expect_invoices "from = to = start date -> only invoice 1 (both ends inclusive)" SAR "1 2026-09-20 FIRST 11/30 10963 1644 12607"
  invoices "$a" 2026-10-01 2026-10-01; expect_invoices "from = to = 2026-10-01 -> only invoice 2" SAR "2 2026-10-01 MONTHLY - 29900 4485 34385"
  invoices "$a" 2026-09-21 2026-09-30; expect_invoices "window between two due dates -> empty list" SAR
  invoices "$a" 2026-01-01 2026-09-19; expect_invoices "window entirely before the start date -> empty list" SAR
  invoices "$a" 2026-10-02 2026-11-01; expect_invoices "to is inclusive: 2026-10-02..2026-11-01 -> only invoice 3" SAR "3 2026-11-01 MONTHLY - 29900 4485 34385"
  invoices "$a" 2026-10-01 2026-10-31; expect_invoices "from is inclusive: October -> invoice 2, numbered 2 (invoice_no does not restart)" SAR "2 2026-10-01 MONTHLY - 29900 4485 34385"
  invoices "$a" 2030-01-01 2030-01-31; expect_invoices "January 2030 -> invoice_no 41 (position in the whole schedule)" SAR "41 2030-01-01 MONTHLY - 29900 4485 34385"
  invoices "$a" 2026-01-01 2027-01-02; expect "exactly 366 days (2026-01-01..2027-01-02) is allowed -> 200 with 5 invoices" 200 'length==5 and .[4].due_date=="2027-01-01" and .[4].invoice_no==5'
  invoices "$a" 2026-01-01 2027-01-03; expect_err "367 days -> 422 INVALID_RANGE" 422 INVALID_RANGE
  invoices "$a" 2028-01-01 2029-01-01; expect "366 days across leap year 2028 (2028-01-01..2029-01-01) -> 200" 200 'length==13'
  invoices "$a" 2028-01-01 2029-01-02; expect_err "367 days across leap year 2028 -> 422 INVALID_RANGE" 422 INVALID_RANGE
  invoices "$a" 2026-10-01 2026-09-30; expect_err "to one day before from -> 422 INVALID_RANGE" 422 INVALID_RANGE
  invoices "$a" 2027-01-01 2026-01-01; expect_err "to a year before from -> 422 INVALID_RANGE" 422 INVALID_RANGE
  invoices "$a" 2026-01-01 2036-01-01; expect_err "ten-year window -> 422 INVALID_RANGE" 422 INVALID_RANGE
  call GET "/agreements/$a/invoices?to=2026-12-31";                 expect_err "from missing -> 422 VALIDATION" 422 VALIDATION
  call GET "/agreements/$a/invoices?from=2026-09-01";               expect_err "to missing -> 422 VALIDATION" 422 VALIDATION
  call GET "/agreements/$a/invoices";                               expect_err "from and to missing -> 422 VALIDATION" 422 VALIDATION
  invoices "$a" 2026-02-30 2026-12-31;                              expect_err "from=2026-02-30 -> 422 VALIDATION" 422 VALIDATION
  invoices "$a" 2026-09-01 2026-11-31;                              expect_err "to=2026-11-31 -> 422 VALIDATION" 422 VALIDATION
  invoices "$a" 2026-9-1 2026-12-31;                                expect_err "from=2026-9-1 -> 422 VALIDATION" 422 VALIDATION
  invoices "$a" 2026-09-01 "2026-12-31T00:00:00";                   expect_err "to with a time part -> 422 VALIDATION" 422 VALIDATION
  invoices "$a" 01-09-2026 31-12-2026;                              expect_err "DD-MM-YYYY dates -> 422 VALIDATION" 422 VALIDATION
  invoices "$a" yesterday today;                                    expect_err "words instead of dates -> 422 VALIDATION" 422 VALIDATION
  call GET "/agreements/$a/invoices?from=&to=";                     expect_err "empty from and to -> 422 VALIDATION" 422 VALIDATION
  call GET "/agreements/no-such-agreement-$RUN/invoices?from=2026-09-01&to=2026-12-31"; expect_err "unknown agreement -> 404 NOT_FOUND" 404 NOT_FOUND
}

p2_due_dates() {
  section "PART 2.5 - due-date clamping, N and P"
  schedule_case "due day 31, start 31 Jan 2027: start is a due date -> 28/28 full price; then 28 Feb, 31 Mar, 30 Apr ... the anchor stays 31" \
    SA 29900 0 2027-01-31 31 2027-01-01 2027-12-31 \
    "1 2027-01-31 FIRST 28/28 29900 4485 34385" "2 2027-02-28 MONTHLY - 29900 4485 34385" "3 2027-03-31 MONTHLY - 29900 4485 34385" \
    "4 2027-04-30 MONTHLY - 29900 4485 34385" "5 2027-05-31 MONTHLY - 29900 4485 34385" "6 2027-06-30 MONTHLY - 29900 4485 34385" \
    "7 2027-07-31 MONTHLY - 29900 4485 34385" "8 2027-08-31 MONTHLY - 29900 4485 34385" "9 2027-09-30 MONTHLY - 29900 4485 34385" \
    "10 2027-10-31 MONTHLY - 29900 4485 34385" "11 2027-11-30 MONTHLY - 29900 4485 34385" "12 2027-12-31 MONTHLY - 29900 4485 34385"
  invoices "$AID" 2028-02-01 2028-03-31
  expect_invoices "same agreement in leap year 2028 -> 29 Feb then 31 Mar" SAR "14 2028-02-29 MONTHLY - 29900 4485 34385" "15 2028-03-31 MONTHLY - 29900 4485 34385"
  schedule_case "due day 30, start 10 Feb 2027: N = 28 Feb, P = 30 Jan (not 28 Jan) -> 18/29" \
    SA 29900 0 2027-02-10 30 2027-02-01 2027-03-31 \
    "1 2027-02-10 FIRST 18/29 18559 2784 21343" "2 2027-02-28 MONTHLY - 29900 4485 34385" "3 2027-03-30 MONTHLY - 29900 4485 34385"
  schedule_case "due day 29, start 10 Feb 2027: N = 28 Feb, P = 29 Jan -> 18/30; March goes back to the 29th" \
    SA 29900 0 2027-02-10 29 2027-02-01 2027-03-31 \
    "1 2027-02-10 FIRST 18/30 17940 2691 20631" "2 2027-02-28 MONTHLY - 29900 4485 34385" "3 2027-03-29 MONTHLY - 29900 4485 34385"
  schedule_case "due day 30, start 10 Feb 2028 (leap): N = 29 Feb, P = 30 Jan -> 19/30" \
    SA 29900 0 2028-02-10 30 2028-02-01 2028-03-31 \
    "1 2028-02-10 FIRST 19/30 18937 2841 21778" "2 2028-02-29 MONTHLY - 29900 4485 34385" "3 2028-03-30 MONTHLY - 29900 4485 34385"
  schedule_case "due day 31, start 10 Mar 2027: N = 31 Mar, P = 28 Feb (clamped) -> 21/31" \
    SA 29900 0 2027-03-10 31 2027-03-01 2027-04-30 \
    "1 2027-03-10 FIRST 21/31 20255 3038 23293" "2 2027-03-31 MONTHLY - 29900 4485 34385" "3 2027-04-30 MONTHLY - 29900 4485 34385"
  schedule_case "due day 31, start 28 Feb 2027: the clamped date is itself a due date -> 31/31 full price, invoice 2 on 31 Mar" \
    SA 29900 0 2027-02-28 31 2027-02-01 2027-04-30 \
    "1 2027-02-28 FIRST 31/31 29900 4485 34385" "2 2027-03-31 MONTHLY - 29900 4485 34385" "3 2027-04-30 MONTHLY - 29900 4485 34385"
  schedule_case "due day 31, start 30 Apr 2027: clamped due date -> 31/31, then 31 May, 30 Jun" \
    SA 29900 0 2027-04-30 31 2027-04-01 2027-06-30 \
    "1 2027-04-30 FIRST 31/31 29900 4485 34385" "2 2027-05-31 MONTHLY - 29900 4485 34385" "3 2027-06-30 MONTHLY - 29900 4485 34385"
  schedule_case "start on the due day (15 Sep, due day 15) -> 30/30, one invoice in September, invoice 2 on 15 Oct" \
    SA 29900 0 2026-09-15 15 2026-09-01 2026-10-31 \
    "1 2026-09-15 FIRST 30/30 29900 4485 34385" "2 2026-10-15 MONTHLY - 29900 4485 34385"
  schedule_case "start one day before the due day (14 Sep, due day 15) -> 1/31, invoice 2 the next day" \
    SA 29900 0 2026-09-14 15 2026-09-01 2026-10-31 \
    "1 2026-09-14 FIRST 1/31 965 145 1110" "2 2026-09-15 MONTHLY - 29900 4485 34385" "3 2026-10-15 MONTHLY - 29900 4485 34385"
  schedule_case "start one day after the due day (16 Sep, due day 15) -> 29/30" \
    SA 29900 0 2026-09-16 15 2026-09-01 2026-10-31 \
    "1 2026-09-16 FIRST 29/30 28903 4335 33238" "2 2026-10-15 MONTHLY - 29900 4485 34385"
  schedule_case "N in the next year (start 25 Dec 2026, due day 5) -> N = 5 Jan 2027, P = 5 Dec 2026, 11/31" \
    SA 29900 0 2026-12-25 5 2026-12-01 2027-02-28 \
    "1 2026-12-25 FIRST 11/31 10610 1592 12202" "2 2027-01-05 MONTHLY - 29900 4485 34385" "3 2027-02-05 MONTHLY - 29900 4485 34385"
  schedule_case "P in the previous year (start 3 Jan 2027, due day 20) -> P = 20 Dec 2026, 17/31" \
    SA 29900 0 2027-01-03 20 2027-01-01 2027-02-28 \
    "1 2027-01-03 FIRST 17/31 16397 2460 18857" "2 2027-01-20 MONTHLY - 29900 4485 34385" "3 2027-02-20 MONTHLY - 29900 4485 34385"
  schedule_case "28-day cycle (start 22 Feb 2027, due day 1) -> 7/28" \
    SA 29900 0 2027-02-22 1 2027-02-01 2027-03-31 \
    "1 2027-02-22 FIRST 7/28 7475 1121 8596" "2 2027-03-01 MONTHLY - 29900 4485 34385"
  schedule_case "26 years in: start 31 Jan 2000, due day 31, window Feb-Apr 2026 -> invoices 314, 315, 316 on 28 Feb, 31 Mar, 30 Apr" \
    SA 29900 0 2000-01-31 31 2026-02-01 2026-04-30 \
    "314 2026-02-28 MONTHLY - 29900 4485 34385" "315 2026-03-31 MONTHLY - 29900 4485 34385" "316 2026-04-30 MONTHLY - 29900 4485 34385"
}

p2_rounding() {
  section "PART 2.6 - rounding: half up, twice per invoice, integers only"
  schedule_case "proration lands on .5: 20025 x 11/30 = 7342.5 -> 7343 (banker's rounding and float maths give 7342)" \
    SA 20025 0 2026-09-20 1 2026-09-01 2026-10-31 "1 2026-09-20 FIRST 11/30 7343 1101 8444" "2 2026-10-01 MONTHLY - 20025 3004 23029"
  schedule_case "proration lands on .5: 30723 x 15/30 = 15361.5 -> 15362 (daily-rate-first float maths gives 15361)" \
    SA 30723 0 2026-09-16 1 2026-09-01 2026-10-31 "1 2026-09-16 FIRST 15/30 15362 2304 17666" "2 2026-10-01 MONTHLY - 30723 4608 35331"
  schedule_case "proration lands on .5: 28698 x 7/28 = 7174.5 -> 7175" \
    SA 28698 0 2027-02-22 1 2027-02-01 2027-03-31 "1 2027-02-22 FIRST 7/28 7175 1076 8251" "2 2027-03-01 MONTHLY - 28698 4305 33003"
  schedule_case "SA VAT lands on .5: 29910 x 15% = 4486.5 -> 4487" \
    SA 29910 0 2026-09-01 1 2026-09-01 2026-10-31 "1 2026-09-01 FIRST 30/30 29910 4487 34397" "2 2026-10-01 MONTHLY - 29910 4487 34397"
  schedule_case "AE VAT lands on .5: 24930 x 5% = 1246.5 -> 1247" \
    AE 24930 0 2026-09-01 1 2026-09-01 2026-10-31 "1 2026-09-01 FIRST 30/30 24930 1247 26177" "2 2026-10-01 MONTHLY - 24930 1247 26177"
  schedule_case "BH VAT lands on .5: 24505 x 10% = 2450.5 -> 2451" \
    BH 24505 0 2026-09-01 1 2026-09-01 2026-10-31 "1 2026-09-01 FIRST 30/30 24505 2451 26956" "2 2026-10-01 MONTHLY - 24505 2451 26956"
  schedule_case "joining fee sits inside one VAT base: (110 + 110) x 5% = 11, not 6 + 6; fee is not prorated and not on invoice 2" \
    AE 110 110 2026-09-01 1 2026-09-01 2026-10-31 "1 2026-09-01 FIRST 30/30 220 11 231" "2 2026-10-01 MONTHLY - 110 6 116"
  schedule_case "smallest plan: monthly 1 x 11/30 = 0.37 -> net 0, VAT 0, total 0" \
    SA 1 0 2026-09-20 1 2026-09-01 2026-10-31 "1 2026-09-20 FIRST 11/30 0 0 0" "2 2026-10-01 MONTHLY - 1 0 1"
}

p2_bhd() {
  section "PART 2.7 - BHD has three decimals: never round in major units"
  schedule_case "BH 5790 -> VAT 579 fils (0.579 BHD, not 0.58)" \
    BH 5790 0 2026-09-01 1 2026-09-01 2026-10-31 "1 2026-09-01 FIRST 30/30 5790 579 6369" "2 2026-10-01 MONTHLY - 5790 579 6369"
  schedule_case "BH 24500, 11/30 -> net 8983, VAT 898, total 9881 (not 8980 / 9880)" \
    BH 24500 0 2026-09-20 1 2026-09-01 2026-10-31 "1 2026-09-20 FIRST 11/30 8983 898 9881" "2 2026-10-01 MONTHLY - 24500 2450 26950"
  schedule_case "BH 24500 + joining fee 5005, 11/30 -> net 13988, VAT 1399, total 15387" \
    BH 24500 5005 2026-09-20 1 2026-09-01 2026-10-31 "1 2026-09-20 FIRST 11/30 13988 1399 15387" "2 2026-10-01 MONTHLY - 24500 2450 26950"
}

# ============================================================================= PART 3
row() { # TXN AGREEMENT_ID_JSON AMOUNT CURRENCY STATUS DATE
  jq -cn --arg t "$1" --argjson a "$2" --argjson m "$3" --arg c "$4" --arg s "$5" --arg d "$6" \
    '{gateway_txn_id:$t,agreement_id:$a,amount:$m,currency:$c,status:$s,attempted_on:$d}'
}
run_body() { local month=$1; shift; printf '%s\n' "$@" | jq -cs --arg m "$month" '{month:$m,rows:.}'; }
post_run() { call POST /reconciliation/runs "$(run_body "$@")"; }
# verdict DESC TXN VERDICT [AGREEMENT_ID_JSON INVOICE_NO]
verdict() {
  if [ $# -ge 5 ]; then
    EXPECT_HINT="row $2: verdict $3, invoice {agreement_id:$4, invoice_no:$5}" \
    expect "$1" 201 '[.rows[]|select(.gateway_txn_id==$t)] | length==1 and .[0].verdict==$v and .[0].invoice=={agreement_id:$a,invoice_no:$n}' --arg t "$2" --arg v "$3" --argjson a "$4" --argjson n "$5"
  else
    EXPECT_HINT="row $2: verdict $3, invoice null" \
    expect "$1" 201 '[.rows[]|select(.gateway_txn_id==$t)] | length==1 and .[0].verdict==$v and (.[0]|has("invoice")) and .[0].invoice==null' --arg t "$2" --arg v "$3"
  fi
}
summary_is() { # DESC MATCHED DRIFT DOUBLE MISSING DECLINED
  EXPECT_HINT="summary {MATCHED:$2, DUE_DAY_DRIFT:$3, DOUBLE_CHARGE_RISK:$4, MISSING_FROM_LEDGER:$5, DECLINED:$6}" \
  expect "$1" 201 '.summary=={MATCHED:$a,DUE_DAY_DRIFT:$b,DOUBLE_CHARGE_RISK:$c,MISSING_FROM_LEDGER:$d,DECLINED:$e}' \
    --argjson a "$2" --argjson b "$3" --argjson c "$4" --argjson d "$5" --argjson e "$6"
}
# unmatched_has DESC AGREEMENT_ID_JSON NO DUE TOTAL CUR    /   unmatched_lacks DESC AGREEMENT_ID_JSON [NO]
unmatched_has() {
  EXPECT_HINT="unmatched_invoices contains {agreement_id:$2, invoice_no:$3, due_date:$4, total:$5, currency:$6}" \
  expect "$1" 201 '[.unmatched_invoices[]|select(.agreement_id==$a and .invoice_no==$n)] | length==1 and (.[0]|.due_date==$d and .total==$t and .currency==$c)' \
    --argjson a "$2" --argjson n "$3" --arg d "$4" --argjson t "$5" --arg c "$6"
}
unmatched_lacks() {
  if [ $# -ge 3 ]; then EXPECT_HINT="unmatched_invoices has no entry for agreement $2 invoice $3" \
    expect "$1" 201 '[.unmatched_invoices[]|select(.agreement_id==$a and .invoice_no==$n)]|length==0' --argjson a "$2" --argjson n "$3"
  else EXPECT_HINT="unmatched_invoices has no entry for agreement $2" \
    expect "$1" 201 '[.unmatched_invoices[]|select(.agreement_id==$a)]|length==0' --argjson a "$2"; fi
}
unmatched_sorted() {
  EXPECT_HINT="unmatched_invoices sorted by due_date, agreement_id, invoice_no" \
  expect "$1" 201 '.unmatched_invoices == (.unmatched_invoices|sort_by(.due_date,.agreement_id,.invoice_no))'
}
# errors_are DESC "TXN CODE" ...     (exact multiset, any order)
errors_are() {
  local desc=$1 want; shift
  want=$(printf '%s\n' "$@" | jq -Rcn '[inputs|split(" ")|{gateway_txn_id:.[0],code:.[1]}]|sort_by(.gateway_txn_id,.code)')
  EXPECT_HINT="error.code INVALID_ROWS with error.errors (any order) = $want" \
  expect "$desc" 422 '.error.code=="INVALID_ROWS" and (.error.message|type=="string") and ((.error.errors|map({gateway_txn_id,code})|sort_by(.gateway_txn_id,.code))==$w)' --argjson w "$want"
}

part3() {
  SEC=3; SEQ=0
  p3_fixtures || { note "Part 3 skipped: fixtures could not be created (Parts 1 and 2 must work first)"; return; }
  p3_spec_example; p3_verdicts; p3_candidates; p3_invalid_rows; p3_validation; p3_month_edges; p3_stored; p3_stress
}

p3_fixtures() {
  section "PART 3.0 - fixtures"
  PSA="p3-$RUN-sa"; PBH="p3-$RUN-bh"; PAE="p3-$RUN-ae"
  mk_plan "$PSA" SA 29900 0 || return 1; mk_plan "$PBH" BH 24500 0 || return 1; mk_plan "$PAE" AE 24900 9900 || return 1
  t8; mk_member "P3 Saudi" SA "+9665$T8" || return 1; MSA=$MIDJ
  t7; mk_member "P3 Bahraini" BH "+9733$T7" || return 1; MBH=$MIDJ
  t8; mk_member "P3 Emirati" AE "+9715$T8" || return 1; MAE=$MIDJ
  mk_agreement "$MSA" "$PSA" 2026-09-20 1 || return 1; ASA=$AIDJ; ASA_URL=$AID   # Oct: #2 due 10-01 total 34385 SAR
  mk_agreement "$MBH" "$PBH" 2026-09-20 1 || return 1; ABH=$AIDJ                 # Oct: #2 due 10-01 total 26950 BHD
  mk_agreement "$MAE" "$PAE" 2026-09-05 20 || return 1; AAE=$AIDJ                # Sep: #1 09-05 23045, #2 09-20 26145; Oct: #3 10-20 26145 AED
  GHOST="\"ghost-agreement-$RUN\""
  ok "3 plans, 3 members, 3 agreements created"
}

p3_spec_example() {
  section "PART 3.1 - the spec example, read-back, untouched agreements"
  post_run 2026-10 "$(row "T1-$RUN" "$ASA" 34385 SAR SETTLED 2026-10-01)" "$(row "T2-$RUN" "$ABH" 26950 BHD DECLINED 2026-10-02)"
  expect "POST /reconciliation/runs -> 201 with string id, month echoed, rows in request order" 201 \
    '(.id|type=="string") and (.id|length>0) and .month=="2026-10" and ([.rows[].gateway_txn_id]==[$a,$b])' --arg a "T1-$RUN" --arg b "T2-$RUN" || return
  local run=$BODY rid; rid=$(printf '%s' "$BODY" | jq -r .id)
  summary_is "summary has a key for every verdict, zeros included" 1 0 0 0 1
  verdict "settled row, exact amount, on the due date -> MATCHED invoice 2" "T1-$RUN" MATCHED "$ASA" 2
  verdict "declined row -> DECLINED with invoice: null" "T2-$RUN" DECLINED
  unmatched_has "invoice whose only row was declined is in unmatched_invoices (BHD, total 26950)" "$ABH" 2 2026-10-01 26950 BHD
  unmatched_has "agreement that no row mentions is still expected: its October invoice is unmatched" "$AAE" 3 2026-10-20 26145 AED
  unmatched_lacks "the matched invoice is not in unmatched_invoices" "$ASA"
  expect "unmatched entries carry exactly agreement_id, invoice_no, due_date, total, currency" 201 \
    '.unmatched_invoices|length>0 and all(.[]; (.agreement_id!=null) and (.invoice_no|type=="number") and (.due_date|type=="string") and (.total|type=="number") and (.currency|type=="string"))'
  unmatched_sorted "unmatched_invoices is sorted by due_date, agreement_id, invoice_no"
  call GET "/reconciliation/runs/$rid"
  EXPECT_HINT="the same JSON the POST returned" expect "GET /reconciliation/runs/{id} -> 200 with exactly the POST body" 200 '. == $r' --argjson r "$run"
  call GET "/reconciliation/runs/$rid-nope";  expect_err "unknown run id -> 404 NOT_FOUND" 404 NOT_FOUND
  invoices "$ASA_URL" 2026-10-01 2026-10-31
  expect_invoices "a run never changes agreements: the schedule is unchanged" SAR "2 2026-10-01 MONTHLY - 29900 4485 34385"
}

p3_verdicts() {
  section "PART 3.2 - every verdict in one file (October 2026)"
  local i b; for i in 1 2 3 4 5 6 7 8 9 10; do mk_agreement "$MSA" "$PSA" 2026-09-20 1 || return; eval "B$i=\$AIDJ"; done
  mk_agreement "$MSA" "$PSA" 2026-11-15 1 || return; local late=$AIDJ          # starts after October: no October invoice
  local r="V$RUN"
  local rows=(
    "$(row "$r-exact"    "$B1"  34385 SAR SETTLED  2026-10-01)"
    "$(row "$r-plus1"    "$B2"  34386 SAR SETTLED  2026-10-01)"
    "$(row "$r-minus1"   "$B3"  34384 SAR SETTLED  2026-10-01)"
    "$(row "$r-plus2"    "$B4"  34387 SAR SETTLED  2026-10-01)"
    "$(row "$r-minus2"   "$B5"  34383 SAR SETTLED  2026-10-01)"
    "$(row "$r-drift"    "$B6"  34385 SAR SETTLED  2026-10-03)"
    "$(row "$r-dbl-a"    "$B7"  34385 SAR SETTLED  2026-10-01)"
    "$(row "$r-dbl-b"    "$B7"  34385 SAR SETTLED  2026-10-05)"
    "$(row "$r-dec-then" "$B8"  34385 SAR DECLINED 2026-10-01)"
    "$(row "$r-retry-ok" "$B8"  34385 SAR SETTLED  2026-10-01)"
    "$(row "$r-dec-only" "$B9"  34385 SAR DECLINED 2026-10-01)"
    "$(row "$r-tri-a"    "$B10" 34384 SAR SETTLED  2026-10-01)"
    "$(row "$r-tri-b"    "$B10" 34385 SAR SETTLED  2026-10-02)"
    "$(row "$r-tri-c"    "$B10" 34386 SAR SETTLED  2026-10-31)"
    "$(row "$r-ghost"    "$GHOST" 34385 SAR SETTLED 2026-10-01)"
    "$(row "$r-ghost-cur" "$GHOST" 500 AED SETTLED 2026-10-09)"
    "$(row "$r-ghost-dec" "$GHOST" 34385 SAR DECLINED 2026-10-01)"
    "$(row "$r-other-agr" "$AAE" 34385 AED SETTLED 2026-10-20)"
    "$(row "$r-other-mon" "$ABH" 9881 BHD SETTLED 2026-10-01)"
    "$(row "$r-late"     "$late" 34385 SAR SETTLED 2026-10-01)"
    "$(row "$r-late-first" "$late" 18339 SAR SETTLED 2026-10-15)"
  )
  post_run 2026-10 "${rows[@]}"
  expect "run accepted -> 201, 21 rows back in request order" 201 '[.rows[].gateway_txn_id]==$ids' --argjson ids "$(printf '%s\n' "${rows[@]}" | jq -cs 'map(.gateway_txn_id)')" || return
  local fwd=$BODY
  verdict "amount = total, on the due date -> MATCHED"                       "$r-exact"  MATCHED "$B1" 2
  verdict "amount = total + 1 -> still a candidate -> MATCHED"               "$r-plus1"  MATCHED "$B2" 2
  verdict "amount = total - 1 -> still a candidate -> MATCHED"               "$r-minus1" MATCHED "$B3" 2
  verdict "amount = total + 2 -> no candidate -> MISSING_FROM_LEDGER"        "$r-plus2"  MISSING_FROM_LEDGER
  verdict "amount = total - 2 -> no candidate -> MISSING_FROM_LEDGER"        "$r-minus2" MISSING_FROM_LEDGER
  verdict "right amount two days late -> DUE_DAY_DRIFT"                      "$r-drift"  DUE_DAY_DRIFT "$B6" 2
  verdict "two settled rows on one invoice: the one on the due date -> DOUBLE_CHARGE_RISK" "$r-dbl-a" DOUBLE_CHARGE_RISK "$B7" 2
  verdict "two settled rows on one invoice: the later one -> DOUBLE_CHARGE_RISK"           "$r-dbl-b" DOUBLE_CHARGE_RISK "$B7" 2
  verdict "declined attempt -> DECLINED, invoice null"                       "$r-dec-then" DECLINED
  verdict "settled retry after a decline -> MATCHED (declined rows take no part in matching)" "$r-retry-ok" MATCHED "$B8" 2
  verdict "declined only -> DECLINED"                                        "$r-dec-only" DECLINED
  verdict "three settled rows on one invoice (a) -> DOUBLE_CHARGE_RISK"      "$r-tri-a" DOUBLE_CHARGE_RISK "$B10" 2
  verdict "three settled rows on one invoice (b) -> DOUBLE_CHARGE_RISK"      "$r-tri-b" DOUBLE_CHARGE_RISK "$B10" 2
  verdict "three settled rows on one invoice (c) -> DOUBLE_CHARGE_RISK"      "$r-tri-c" DOUBLE_CHARGE_RISK "$B10" 2
  verdict "unknown agreement, settled -> MISSING_FROM_LEDGER"                "$r-ghost" MISSING_FROM_LEDGER
  verdict "unknown agreement with any currency skips the currency check -> MISSING_FROM_LEDGER" "$r-ghost-cur" MISSING_FROM_LEDGER
  verdict "unknown agreement, declined -> DECLINED"                          "$r-ghost-dec" DECLINED
  verdict "amount equals another agreement's invoice, not its own -> MISSING_FROM_LEDGER" "$r-other-agr" MISSING_FROM_LEDGER
  verdict "amount equals the agreement's September invoice, not an October one -> MISSING_FROM_LEDGER" "$r-other-mon" MISSING_FROM_LEDGER
  verdict "agreement starting in November has no October invoice -> MISSING_FROM_LEDGER" "$r-late" MISSING_FROM_LEDGER
  verdict "amount of a November invoice attempted in October -> MISSING_FROM_LEDGER" "$r-late-first" MISSING_FROM_LEDGER
  summary_is "summary: 4 MATCHED, 1 DUE_DAY_DRIFT, 5 DOUBLE_CHARGE_RISK, 8 MISSING_FROM_LEDGER, 3 DECLINED" 4 1 5 8 3
  unmatched_has "invoice of the +2 row is unmatched"                 "$B4" 2 2026-10-01 34385 SAR
  unmatched_has "invoice of the -2 row is unmatched"                 "$B5" 2 2026-10-01 34385 SAR
  unmatched_has "invoice with only a declined row is unmatched"      "$B9" 2 2026-10-01 34385 SAR
  unmatched_has "AE invoice (row had the wrong amount) is unmatched" "$AAE" 3 2026-10-20 26145 AED
  unmatched_has "BH invoice (row had the wrong amount) is unmatched" "$ABH" 2 2026-10-01 26950 BHD
  unmatched_lacks "drifted invoice is linked, so not unmatched"      "$B6"
  unmatched_lacks "double-charged invoice is linked, so not unmatched" "$B7"
  unmatched_lacks "invoice settled after a decline is not unmatched" "$B8"
  unmatched_lacks "agreement with no October invoice has nothing in unmatched" "$late"
  unmatched_sorted "unmatched_invoices sorted by due_date, then agreement_id, then invoice_no (many share 2026-10-01)"

  note "same file in reverse order: verdicts must not depend on row order"
  local rev=() n=${#rows[@]}; for ((i=n-1; i>=0; i--)); do rev+=("${rows[$i]}"); done
  post_run 2026-10 "${rev[@]}"
  expect "reversed file -> rows come back in the new request order" 201 '[.rows[].gateway_txn_id]==$ids' --argjson ids "$(printf '%s\n' "${rev[@]}" | jq -cs 'map(.gateway_txn_id)')"
  EXPECT_HINT="the same verdict and invoice per gateway_txn_id as in the forward run" \
  expect "reversed file -> identical verdict and invoice for every row" 201 '(.rows|sort_by(.gateway_txn_id))==($f.rows|sort_by(.gateway_txn_id))' --argjson f "$fwd"
  expect "reversed file -> identical summary and unmatched_invoices" 201 '.summary==$f.summary and .unmatched_invoices==$f.unmatched_invoices' --argjson f "$fwd"
}

p3_candidates() {
  section "PART 3.3 - picking a candidate: earliest due date, already-linked invoices still count"
  # AE, monthly 3100, fee 1600, start 5 Sep, due day 20: invoice 1 (05 Sep) total 3255, invoice 2 (20 Sep) total 3255
  local pa="p3-$RUN-twin" pb="p3-$RUN-near" r="C$RUN"
  mk_plan "$pa" AE 3100 1600 || return; mk_plan "$pb" AE 3100 1599 || return
  mk_agreement "$MAE" "$pa" 2026-09-05 20 || return; local t1=$AIDJ
  mk_agreement "$MAE" "$pa" 2026-09-05 20 || return; local t2=$AIDJ
  mk_agreement "$MAE" "$pa" 2026-09-05 20 || return; local t3=$AIDJ
  # second plan: invoice 1 total 3254, invoice 2 total 3255
  mk_agreement "$MAE" "$pb" 2026-09-05 20 || return; local n1=$AIDJ
  mk_agreement "$MAE" "$pb" 2026-09-05 20 || return; local n2=$AIDJ
  mk_agreement "$MAE" "$pb" 2026-09-05 20 || return; local n3=$AIDJ
  post_run 2026-09 \
    "$(row "$r-one"   "$t1" 3255 AED SETTLED 2026-09-20)" \
    "$(row "$r-two-a" "$t2" 3255 AED SETTLED 2026-09-05)" \
    "$(row "$r-two-b" "$t2" 3255 AED SETTLED 2026-09-20)" \
    "$(row "$r-dec"   "$t3" 3255 AED DECLINED 2026-09-05)" \
    "$(row "$r-after" "$t3" 3255 AED SETTLED 2026-09-20)" \
    "$(row "$r-near"  "$n1" 3255 AED SETTLED 2026-09-20)" \
    "$(row "$r-only2" "$n2" 3256 AED SETTLED 2026-09-20)" \
    "$(row "$r-only1" "$n3" 3253 AED SETTLED 2026-09-05)"
  expect "run accepted" 201 || return
  verdict "two invoices with the same total, one row paid on the 2nd due date -> links the EARLIEST (invoice 1) -> DUE_DAY_DRIFT" "$r-one" DUE_DAY_DRIFT "$t1" 1
  unmatched_has "...and invoice 2 stays unmatched" "$t1" 2 2026-09-20 3255 AED
  verdict "two rows, two equal invoices: row on 5 Sep links invoice 1 -> DOUBLE_CHARGE_RISK" "$r-two-a" DOUBLE_CHARGE_RISK "$t2" 1
  verdict "two rows, two equal invoices: row on 20 Sep ALSO links invoice 1 (linked invoices still count) -> DOUBLE_CHARGE_RISK" "$r-two-b" DOUBLE_CHARGE_RISK "$t2" 1
  unmatched_has "...so invoice 2 is unmatched, not quietly paired with the second row" "$t2" 2 2026-09-20 3255 AED
  unmatched_lacks "...and invoice 1 is not unmatched" "$t2" 1
  verdict "a declined row on invoice 1 does not reserve it: the settled row still links invoice 1 -> DUE_DAY_DRIFT" "$r-after" DUE_DAY_DRIFT "$t3" 1
  verdict "candidates 3254 (5 Sep) and 3255 (20 Sep), amount 3255 -> earliest due date wins over the exact amount -> DUE_DAY_DRIFT on invoice 1" "$r-near" DUE_DAY_DRIFT "$n1" 1
  verdict "amount 3256 is within 1 of invoice 2 only -> MATCHED invoice 2" "$r-only2" MATCHED "$n2" 2
  unmatched_has "...and its invoice 1 is unmatched" "$n2" 1 2026-09-05 3254 AED
  verdict "amount 3253 is within 1 of invoice 1 only -> MATCHED invoice 1" "$r-only1" MATCHED "$n3" 1
  summary_is "summary: 2 MATCHED, 3 DUE_DAY_DRIFT, 2 DOUBLE_CHARGE_RISK, 0 MISSING, 1 DECLINED" 2 3 2 0 1
  unmatched_sorted "unmatched_invoices sorted (two due dates, several agreements)"

  note "FIRST invoices are expected invoices too"
  post_run 2026-09 "$(row "$r-first-sa" "$ASA" 12607 SAR SETTLED 2026-09-20)" "$(row "$r-first-ae" "$AAE" 23045 AED SETTLED 2026-09-06)" "$(row "$r-second-ae" "$AAE" 26145 AED SETTLED 2026-09-20)"
  verdict "prorated FIRST invoice paid on the start date -> MATCHED invoice 1" "$r-first-sa" MATCHED "$ASA" 1
  verdict "FIRST invoice with joining fee, paid a day late -> DUE_DAY_DRIFT invoice 1" "$r-first-ae" DUE_DAY_DRIFT "$AAE" 1
  verdict "second invoice of the same month -> MATCHED invoice 2" "$r-second-ae" MATCHED "$AAE" 2
  unmatched_has "BH FIRST invoice (nobody paid) is unmatched with its prorated total 9881" "$ABH" 1 2026-09-20 9881 BHD
}

p3_invalid_rows() {
  section "PART 3.4 - 422 INVALID_ROWS"
  local r="E$RUN"
  post_run 2026-10 "$(row "$r-d" "$ASA" 34385 SAR SETTLED 2026-10-01)" "$(row "$r-d" "$ASA" 34385 SAR SETTLED 2026-10-01)"
  errors_are "same gateway_txn_id twice -> DUPLICATE_TXN for both rows" "$r-d DUPLICATE_TXN" "$r-d DUPLICATE_TXN"
  expect "INVALID_ROWS keeps the standard envelope; errors sits inside error" 422 '(.error.message|type=="string") and (.error.errors|type=="array") and (has("errors")|not)'
  post_run 2026-10 "$(row "$r-t" "$ASA" 34385 SAR SETTLED 2026-10-01)" "$(row "$r-ok" "$ABH" 26950 BHD SETTLED 2026-10-01)" \
                   "$(row "$r-t" "$GHOST" 1 SAR DECLINED 2026-10-02)" "$(row "$r-t" "$AAE" 26145 AED SETTLED 2026-10-20)"
  errors_are "same id three times (different content) -> three DUPLICATE_TXN entries, none for the clean row" "$r-t DUPLICATE_TXN" "$r-t DUPLICATE_TXN" "$r-t DUPLICATE_TXN"
  post_run 2026-10 "$(row "$r-before" "$ASA" 34385 SAR SETTLED 2026-09-30)" "$(row "$r-in" "$ABH" 26950 BHD SETTLED 2026-10-01)" "$(row "$r-after" "$AAE" 26145 AED SETTLED 2026-11-01)"
  errors_are "attempted_on 30 Sep and 1 Nov for month 2026-10 -> ROW_OUTSIDE_MONTH for those two only" "$r-before ROW_OUTSIDE_MONTH" "$r-after ROW_OUTSIDE_MONTH"
  post_run 2026-10 "$(row "$r-yr" "$ASA" 34385 SAR SETTLED 2027-10-01)"
  errors_are "right month, wrong year -> ROW_OUTSIDE_MONTH" "$r-yr ROW_OUTSIDE_MONTH"
  post_run 2026-10 "$(row "$r-dec-out" "$ASA" 34385 SAR DECLINED 2026-11-02)" "$(row "$r-ghost-out" "$GHOST" 5 SAR SETTLED 2026-09-01)"
  errors_are "ROW_OUTSIDE_MONTH applies to declined rows and unknown agreements too" "$r-dec-out ROW_OUTSIDE_MONTH" "$r-ghost-out ROW_OUTSIDE_MONTH"
  post_run 2026-10 "$(row "$r-cur" "$ASA" 34385 AED SETTLED 2026-10-01)"
  errors_are "SAR agreement charged in AED -> CURRENCY_MISMATCH" "$r-cur CURRENCY_MISMATCH"
  post_run 2026-10 "$(row "$r-cur-dec" "$ABH" 26950 SAR DECLINED 2026-10-01)"
  errors_are "CURRENCY_MISMATCH applies to declined rows too" "$r-cur-dec CURRENCY_MISMATCH"
  post_run 2026-10 "$(row "$r-cur-ghost" "$GHOST" 26950 BHD SETTLED 2026-10-01)"
  verdict "unknown agreement skips the currency check -> 201, MISSING_FROM_LEDGER" "$r-cur-ghost" MISSING_FROM_LEDGER
  post_run 2026-10 "$(row "$r-multi" "$ASA" 34385 BHD SETTLED 2026-12-25)"
  errors_are "one row breaking two rules -> one entry per code" "$r-multi CURRENCY_MISMATCH" "$r-multi ROW_OUTSIDE_MONTH"
  post_run 2026-10 \
    "$(row "$r-a" "$ASA" 34385 SAR SETTLED 2026-10-01)" \
    "$(row "$r-b" "$ASA" 34385 SAR SETTLED 2026-10-01)" \
    "$(row "$r-b" "$ABH" 26950 AED SETTLED 2026-11-30)" \
    "$(row "$r-c" "$AAE" 26145 SAR DECLINED 2026-10-20)" \
    "$(row "$r-d2" "$GHOST" 100 SAR SETTLED 2026-09-15)" \
    "$(row "$r-e" "$ABH" 26950 BHD SETTLED 2026-10-01)"
  errors_are "all offending rows are reported in one response (no fail-fast): 2 x DUPLICATE_TXN + ROW_OUTSIDE_MONTH + CURRENCY_MISMATCH on b, CURRENCY_MISMATCH on c, ROW_OUTSIDE_MONTH on d2" \
    "$r-b DUPLICATE_TXN" "$r-b DUPLICATE_TXN" "$r-b ROW_OUTSIDE_MONTH" "$r-b CURRENCY_MISMATCH" "$r-c CURRENCY_MISMATCH" "$r-d2 ROW_OUTSIDE_MONTH"
}

p3_validation() {
  section "PART 3.5 - 422 VALIDATION on malformed runs"
  local good; good=$(row "M$RUN-1" "$ASA" 34385 SAR SETTLED 2026-10-01)
  local m why
  while IFS='|' read -r m why; do
    [ -z "$m" ] && continue
    call POST /reconciliation/runs "{\"month\":$m,\"rows\":[$good]}"; expect_err "month $why -> 422 VALIDATION" 422 VALIDATION
  done <<'EOF'
"2026-13"|2026-13
"2026-00"|2026-00
"2026-1"|2026-1 (no zero padding)
"2026-10-01"|a full date
"10-2026"|MM-YYYY
"2026/10"|with a slash
"October 2026"|as words
""|empty
202610|as a number
null|null
EOF
  call POST /reconciliation/runs "{\"rows\":[$good]}";                    expect_err "month missing -> 422 VALIDATION" 422 VALIDATION
  call POST /reconciliation/runs '{"month":"2026-10"}';                   expect_err "rows missing -> 422 VALIDATION" 422 VALIDATION
  call POST /reconciliation/runs '{"month":"2026-10","rows":null}';       expect_err "rows null -> 422 VALIDATION" 422 VALIDATION
  call POST /reconciliation/runs "{\"month\":\"2026-10\",\"rows\":$good}"; expect_err "rows is an object, not an array -> 422 VALIDATION" 422 VALIDATION
  call POST /reconciliation/runs '{"month":"2026-10","rows":"none"}';     expect_err "rows is a string -> 422 VALIDATION" 422 VALIDATION
  call POST /reconciliation/runs '{"month":"2026-10","rows":["x"]}';      expect_err "a row that is a string -> 422 VALIDATION" 422 VALIDATION
  local f v
  while IFS='|' read -r f v why; do
    [ -z "$f" ] && continue
    call POST /reconciliation/runs "$(printf '%s' "$good" | jq -c --arg f "$f" --argjson v "$v" '{month:"2026-10",rows:[.[$f]=$v]}')"
    expect_err "row with $why -> 422 VALIDATION" 422 VALIDATION
  done <<'EOF'
amount|0|amount 0
amount|-34385|amount negative
amount|343.85|amount 343.85
amount|"34385"|amount as a string
amount|null|amount null
amount|true|amount true
status|"PENDING"|status PENDING
status|"REFUNDED"|status REFUNDED
status|""|status empty
status|null|status null
status|1|status as a number
attempted_on|"2026-10-32"|attempted_on 2026-10-32
attempted_on|"2026-02-30"|attempted_on 2026-02-30
attempted_on|"01-10-2026"|attempted_on DD-MM-YYYY
attempted_on|"2026-10-01T09:30:00Z"|attempted_on with a time
attempted_on|"2026-10-1"|attempted_on without zero padding
attempted_on|null|attempted_on null
attempted_on|20261001|attempted_on as a number
gateway_txn_id|null|gateway_txn_id null
gateway_txn_id|88121|gateway_txn_id as a number
currency|null|currency null
currency|682|currency as a number
agreement_id|null|agreement_id null
EOF
  for f in gateway_txn_id agreement_id amount currency status attempted_on; do
    call POST /reconciliation/runs "$(printf '%s' "$good" | jq -c --arg f "$f" '{month:"2026-10",rows:[del(.[$f])]}')"
    expect_err "row missing $f -> 422 VALIDATION" 422 VALIDATION
  done
  call POST /reconciliation/runs "$(printf '%s' "$good" | jq -c '{month:"2026-10",rows:[.status="settled"]}')"
  soft expect_err "status lowercase 'settled' -> 422 VALIDATION" 422 VALIDATION
  call POST /reconciliation/runs '{"month":"2026-10","rows":[]}'
  soft expect "empty rows array -> 201, all-zero summary, every expected invoice unmatched" 201 \
    '.summary=={MATCHED:0,DUE_DAY_DRIFT:0,DOUBLE_CHARGE_RISK:0,MISSING_FROM_LEDGER:0,DECLINED:0} and .rows==[] and ([.unmatched_invoices[]|select(.agreement_id==$a)]|length==1)' --argjson a "$ASA"
}

p3_month_edges() {
  section "PART 3.6 - month boundaries, February, clamped due dates"
  local r="F$RUN"
  mk_agreement "$MSA" "$PSA" 2027-01-31 31 || return; local c=$AIDJ           # Feb 2027: #2 due 02-28; Feb 2028: #14 due 02-29
  post_run 2026-10 "$(row "$r-first" "$GHOST" 1 SAR SETTLED 2026-10-01)" "$(row "$r-last" "$GHOST" 1 SAR SETTLED 2026-10-31)"
  expect "first and last day of the month are inside the month -> 201" 201
  post_run 2027-02 "$(row "$r-feb" "$c" 34385 SAR SETTLED 2027-02-28)"
  verdict "due day 31 in February 2027: paid on the 28th -> MATCHED (clamped due date)" "$r-feb" MATCHED "$c" 2
  post_run 2027-02 "$(row "$r-mar" "$c" 34385 SAR SETTLED 2027-03-01)"
  errors_are "1 March for month 2027-02 -> ROW_OUTSIDE_MONTH" "$r-mar ROW_OUTSIDE_MONTH"
  call POST /reconciliation/runs "{\"month\":\"2027-02\",\"rows\":[$(row "$r-29" "$c" 34385 SAR SETTLED 2027-02-29)]}"
  expect_err "attempted_on 2027-02-29 does not exist -> 422 VALIDATION (not ROW_OUTSIDE_MONTH)" 422 VALIDATION
  post_run 2028-02 "$(row "$r-leap" "$c" 34385 SAR SETTLED 2028-02-29)"
  verdict "leap February 2028: paid on the 29th -> MATCHED invoice 14" "$r-leap" MATCHED "$c" 14
  post_run 2028-02 "$(row "$r-leap28" "$c" 34385 SAR SETTLED 2028-02-28)"
  verdict "leap February 2028: paid on the 28th -> DUE_DAY_DRIFT" "$r-leap28" DUE_DAY_DRIFT "$c" 14
  post_run 2026-12 "$(row "$r-dec31" "$GHOST" 1 SAR SETTLED 2026-12-31)"
  expect "31 December is inside month 2026-12 -> 201" 201
  post_run 2026-12 "$(row "$r-jan1" "$GHOST" 1 SAR SETTLED 2027-01-01)"
  errors_are "1 January 2027 for month 2026-12 -> ROW_OUTSIDE_MONTH" "$r-jan1 ROW_OUTSIDE_MONTH"
  post_run 2026-08 "$(row "$r-early" "$ASA" 34385 SAR SETTLED 2026-08-01)"
  verdict "month before the agreement starts: nothing expected -> MISSING_FROM_LEDGER" "$r-early" MISSING_FROM_LEDGER
  unmatched_lacks "...and that agreement contributes nothing to unmatched_invoices for that month" "$ASA"
}

p3_stored() {
  section "PART 3.7 - runs are stored, independent, and safe under concurrency"
  local r="S$RUN" body
  body=$(run_body 2026-10 "$(row "$r-1" "$ASA" 34385 SAR SETTLED 2026-10-01)" "$(row "$r-2" "$ABH" 26950 BHD SETTLED 2026-10-04)")
  call POST /reconciliation/runs "$body"; expect "first run -> 201" 201 || return
  local one=$BODY id1; id1=$(printf '%s' "$BODY" | jq -r .id)
  call POST /reconciliation/runs "$body"
  soft expect "the same file posted again -> 201 with a new id and the same verdicts (runs do not affect each other)" 201 '.id!=$o.id and .rows==$o.rows and .summary==$o.summary' --argjson o "$one"
  call GET "/reconciliation/runs/$id1"; expect "the first run still reads back unchanged" 200 '.==$o' --argjson o "$one"
  local bodies=() i
  for i in $(seq 1 12); do bodies+=("$(run_body 2026-10 "$(row "$r-c$i-1" "$ASA" 34385 SAR SETTLED 2026-10-01)" "$(row "$r-c$i-2" "$ASA" 34385 SAR SETTLED 2026-10-02)" "$(row "$r-c$i-3" "$ABH" 26950 BHD SETTLED 2026-10-09)")"); done
  burst /reconciliation/runs "${bodies[@]}"
  local okc uniq good
  okc=$(burst_count 201); uniq=$(cat "$TMP"/burst/*.body | jq -c .id 2>/dev/null | sort -u | wc -l | tr -d ' ')
  good=$(cat "$TMP"/burst/*.body | jq -c 'select(.summary=={MATCHED:0,DUE_DAY_DRIFT:1,DOUBLE_CHARGE_RISK:2,MISSING_FROM_LEDGER:0,DECLINED:0})' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$okc" = 12 ] && [ "$uniq" = 12 ] && [ "$good" = 12 ]; then ok "12 simultaneous runs -> 12 x 201, 12 unique ids, each judged on its own rows only"
  else bad "12 simultaneous runs" "12 x 201, 12 unique ids, each with 2 DOUBLE_CHARGE_RISK + 1 DUE_DAY_DRIFT" "$(burst_summary) / $uniq unique ids / $good correct summaries"; fi
}

p3_stress() {
  section "PART 3.8 - a large gateway file ($BIG rows)"
  local body
  body=$(jq -cn --argjson n "$BIG" --arg r "$RUN" --argjson a "$ASA" --argjson b "$ABH" '
    {month:"2026-10", rows:[range(0;$n) as $i |
      if   $i==0 then {gateway_txn_id:"L\($r)-\($i)",agreement_id:$a,amount:34385,currency:"SAR",status:"SETTLED",attempted_on:"2026-10-01"}
      elif $i==1 then {gateway_txn_id:"L\($r)-\($i)",agreement_id:$b,amount:26950,currency:"BHD",status:"SETTLED",attempted_on:"2026-10-07"}
      elif $i%3==0 then {gateway_txn_id:"L\($r)-\($i)",agreement_id:"ghost-\($i)",amount:($i+1),currency:"SAR",status:"DECLINED",attempted_on:"2026-10-\(($i%31)+1|tostring|if length==1 then "0"+. else . end)"}
      else {gateway_txn_id:"L\($r)-\($i)",agreement_id:"ghost-\($i)",amount:($i+1),currency:"AED",status:"SETTLED",attempted_on:"2026-10-\(($i%31)+1|tostring|if length==1 then "0"+. else . end)"} end]}')
  printf '%s' "$body" > "$TMP/big.json"
  STATUS=$(curl -sS -m 60 -o "$TMP/body" -w '%{http_code}' -X POST "$BASE/reconciliation/runs" -H 'Content-Type: application/json' --data-binary "@$TMP/big.json" 2>/dev/null) || STATUS=000
  BODY=$(cat "$TMP/body"); CURL="curl -i -X POST '$BASE/reconciliation/runs' -H 'Content-Type: application/json' -d @big.json   # $BIG generated rows"
  case "$STATUS" in 5*|000) N5XX=$((N5XX+1)); echo "$CURL  ->  HTTP $STATUS" >> "$TMP/5xx";; esac
  local dec=$(( (BIG - 1) / 3 ))          # rows 3, 6, 9 ... are declined
  local miss=$(( BIG - 2 - dec ))        # everything else except rows 0 and 1 is an unknown agreement
  EXPECT_HINT="201 with $BIG rows: 1 MATCHED, 1 DUE_DAY_DRIFT, $miss MISSING_FROM_LEDGER, $dec DECLINED" \
  expect "$BIG-row file -> 201, counts add up, rows in order" 201 \
    '(.rows|length)==$n and .summary=={MATCHED:1,DUE_DAY_DRIFT:1,DOUBLE_CHARGE_RISK:0,MISSING_FROM_LEDGER:$m,DECLINED:$d} and .rows[0].verdict=="MATCHED" and .rows[1].verdict=="DUE_DAY_DRIFT" and (.rows[-1].gateway_txn_id=="L\($r)-\($n-1)")' \
    --argjson n "$BIG" --argjson m "$miss" --argjson d "$dec" --arg r "$RUN"
}

# ============================================================================= END TO END
e2e() {
  SEC=4; SEQ=0
  section "END TO END - three countries, one month (February 2027), every part together"
  call GET /health; expect "service is healthy" 200

  note "members, one per spelling"
  t8; local sa8=$T8
  post_member "  Noura Al Harbi " SA "05${T8:0:1} ${T8:1:3} ${T8:4:4}"
  expect "SA member from a national number -> +966, trimmed name" 201 '.phone==$p and .name=="Noura Al Harbi" and (.id|type=="string")' --arg p "+9665$T8" || return
  local noura; noura=$(printf '%s' "$BODY" | jq -c .id)
  t8; post_member "Ahmed Al Mansoori" AE "9715$T8"; expect "AE member from 971... without plus -> +971" 201 '.phone==$p' --arg p "+9715$T8" || return
  local ahmed; ahmed=$(printf '%s' "$BODY" | jq -c .id)
  t7; post_member "Maryam Al Khalifa" BH "3${T7:0:3}-${T7:3:4}"; expect "BH member from an 8-digit national number -> +973" 201 '.phone==$p' --arg p "+9733$T7" || return
  local maryam; maryam=$(printf '%s' "$BODY" | jq -c .id)
  t8; local ex8=$T8
  post_member "Omar (Saudi member, UAE SIM)" SA "+971 5${T8:0:1} ${T8:1:3} ${T8:4:4}"; expect "SA member with a UAE SIM -> 201" 201 '.phone==$p and .country=="SA"' --arg p "+9715$T8" || return
  local omar; omar=$(printf '%s' "$BODY" | jq -c .id)
  post_member "Impostor" AE "05$ex8"; expect "an AE member trying Omar's number in national form -> 409 PHONE_TAKEN pointing at Omar" 409 '.error.code=="PHONE_TAKEN" and .error.existing_member_id==$o' --argjson o "$omar"
  lookup "9665$sa8";      expect "front desk looks Noura up by 966..." 200 '.id==$n' --argjson n "$noura"
  lookup "05$sa8" SA;     expect "...and by 05... + country" 200 '.id==$n' --argjson n "$noura"
  lookup "05$sa8";        expect_err "...but 05... without a country -> PHONE_NEEDS_COUNTRY" 422 PHONE_NEEDS_COUNTRY
  lookup "05$ex8" AE;     expect "Omar is found through his UAE national number + country=AE" 200 '.id==$o' --argjson o "$omar"

  note "plans and agreements"
  local psa="e2e-$RUN-sa" pae="e2e-$RUN-ae" pbh="e2e-$RUN-bh"
  call POST /plans "$(plan_body "$psa" SA 29900 0)";    expect "SA plan" 201 '.currency=="SAR"' || return
  call POST /plans "$(plan_body "$pae" AE 24900 9900)"; expect "AE plan with joining fee" 201 '.currency=="AED"' || return
  call POST /plans "$(plan_body "$pbh" BH 24500 5000)"; expect "BH plan with joining fee" 201 '.currency=="BHD"' || return
  call POST /plans "$(plan_body "$psa" SA 1 1)";        expect_err "plan id reuse -> PLAN_EXISTS" 409 PLAN_EXISTS
  call POST /agreements "$(agreement_body "$omar" "$pae" 2027-02-10 15)"; expect_err "Omar (SA member) on the AE plan -> PLAN_COUNTRY_MISMATCH" 422 PLAN_COUNTRY_MISMATCH
  mk_agreement "$noura"  "$psa" 2026-09-20 1  || return; local a_sa=$AIDJ u_sa=$AID
  mk_agreement "$ahmed"  "$pae" 2026-09-05 20 || return; local a_ae=$AIDJ u_ae=$AID
  mk_agreement "$maryam" "$pbh" 2026-12-15 31 || return; local a_bh=$AIDJ u_bh=$AID
  mk_agreement "$omar"   "$psa" 2027-02-10 15 || return; local a_ex=$AIDJ u_ex=$AID
  mk_agreement "$noura"  "$psa" 2027-01-01 1  || return; local a_s2=$AIDJ u_s2=$AID
  ok "five agreements created (Noura holds two)"

  note "schedules"
  invoices "$u_sa" 2027-02-01 2027-02-28; expect_invoices "Noura, February 2027 -> invoice 6" SAR "6 2027-02-01 MONTHLY - 29900 4485 34385"
  invoices "$u_ae" 2027-02-01 2027-02-28; expect_invoices "Ahmed, February 2027 -> invoice 7, no joining fee" AED "7 2027-02-20 MONTHLY - 24900 1245 26145"
  invoices "$u_bh" 2026-12-01 2027-03-31
  expect_invoices "Maryam, due day 31 from 15 Dec: 16/31 + fee 5000, VAT 1764.5 -> 1765; then 31 Dec, 31 Jan, 28 Feb, 31 Mar" BHD \
    "1 2026-12-15 FIRST 16/31 17645 1765 19410" "2 2026-12-31 MONTHLY - 24500 2450 26950" "3 2027-01-31 MONTHLY - 24500 2450 26950" \
    "4 2027-02-28 MONTHLY - 24500 2450 26950" "5 2027-03-31 MONTHLY - 24500 2450 26950"
  invoices "$u_ex" 2027-02-01 2027-03-31
  expect_invoices "Omar, start 10 Feb, due day 15 -> 5/31, two invoices in February" SAR \
    "1 2027-02-10 FIRST 5/31 4823 723 5546" "2 2027-02-15 MONTHLY - 29900 4485 34385" "3 2027-03-15 MONTHLY - 29900 4485 34385"
  invoices "$u_s2" 2027-01-01 2027-02-28
  expect_invoices "Noura's second agreement, start on the due day -> 31/31 full price" SAR "1 2027-01-01 FIRST 31/31 29900 4485 34385" "2 2027-02-01 MONTHLY - 29900 4485 34385"

  note "the gateway file for February 2027"
  local g="G$RUN" ghost="\"ghost-e2e-$RUN\""
  local rows=(
    "$(row "$g-1" "$a_sa" 34385 SAR SETTLED  2027-02-01)"
    "$(row "$g-2" "$a_ae" 26145 AED SETTLED  2027-02-22)"
    "$(row "$g-3" "$a_bh" 26951 BHD SETTLED  2027-02-28)"
    "$(row "$g-4" "$a_ex" 5546  SAR SETTLED  2027-02-10)"
    "$(row "$g-5" "$a_ex" 5546  SAR SETTLED  2027-02-11)"
    "$(row "$g-6" "$a_ex" 34385 SAR DECLINED 2027-02-15)"
    "$(row "$g-7" "$ghost" 10000 SAR SETTLED 2027-02-03)"
    "$(row "$g-8" "$a_sa" 34388 SAR SETTLED  2027-02-01)"
  )
  post_run 2027-02 "${rows[@]}" "$(row "$g-1" "$a_sa" 34385 SAR SETTLED 2027-02-01)" \
                   "$(row "$g-9" "$a_ae" 26145 AED SETTLED 2027-03-01)" "$(row "$g-10" "$a_bh" 26950 SAR SETTLED 2027-02-28)"
  errors_are "first upload has a duplicate, a March row and a SAR charge on a BHD agreement -> 422 INVALID_ROWS listing all four" \
    "$g-1 DUPLICATE_TXN" "$g-1 DUPLICATE_TXN" "$g-9 ROW_OUTSIDE_MONTH" "$g-10 CURRENCY_MISMATCH"
  post_run 2027-02 "${rows[@]}"
  expect "corrected upload -> 201, rows in request order" 201 '(.id|type=="string") and .month=="2027-02" and ([.rows[].gateway_txn_id]==[$g+"-1",$g+"-2",$g+"-3",$g+"-4",$g+"-5",$g+"-6",$g+"-7",$g+"-8"])' --arg g "$g" || return
  local run=$BODY rid; rid=$(printf '%s' "$BODY" | jq -r .id)
  summary_is "summary: 2 MATCHED, 1 DUE_DAY_DRIFT, 2 DOUBLE_CHARGE_RISK, 2 MISSING_FROM_LEDGER, 1 DECLINED" 2 1 2 2 1
  verdict "Noura paid on the 1st -> MATCHED invoice 6" "$g-1" MATCHED "$a_sa" 6
  verdict "Ahmed paid two days late -> DUE_DAY_DRIFT invoice 7" "$g-2" DUE_DAY_DRIFT "$a_ae" 7
  verdict "Maryam paid 1 fil over on 28 Feb (due day 31, clamped) -> MATCHED invoice 4" "$g-3" MATCHED "$a_bh" 4
  verdict "Omar's first invoice charged twice (a) -> DOUBLE_CHARGE_RISK" "$g-4" DOUBLE_CHARGE_RISK "$a_ex" 1
  verdict "Omar's first invoice charged twice (b) -> DOUBLE_CHARGE_RISK" "$g-5" DOUBLE_CHARGE_RISK "$a_ex" 1
  verdict "Omar's second invoice was declined -> DECLINED" "$g-6" DECLINED
  verdict "charge for an agreement we do not know -> MISSING_FROM_LEDGER" "$g-7" MISSING_FROM_LEDGER
  verdict "Noura charged 3 halalas over -> MISSING_FROM_LEDGER (and does not turn row 1 into a double charge)" "$g-8" MISSING_FROM_LEDGER
  EXPECT_HINT="unmatched for these agreements = [second agreement inv 2 (02-01), Omar inv 2 (02-15)], in that order" \
  expect "unmatched_invoices for these five agreements: Noura's second agreement, then Omar's declined invoice" 201 \
    '[.unmatched_invoices[]|select(.agreement_id==$s2 or .agreement_id==$ex or .agreement_id==$sa or .agreement_id==$ae or .agreement_id==$bh)]
       == [{agreement_id:$s2,invoice_no:2,due_date:"2027-02-01",total:34385,currency:"SAR"},{agreement_id:$ex,invoice_no:2,due_date:"2027-02-15",total:34385,currency:"SAR"}]' \
    --argjson s2 "$a_s2" --argjson ex "$a_ex" --argjson sa "$a_sa" --argjson ae "$a_ae" --argjson bh "$a_bh"
  unmatched_sorted "unmatched_invoices as a whole is sorted"
  call GET "/reconciliation/runs/$rid"; EXPECT_HINT="the same JSON the POST returned" expect "the run reads back identically" 200 '.==$r' --argjson r "$run"

  note "nothing else moved"
  lookup "+9665$sa8"; expect "Noura is unchanged after the run" 200 '.id==$n and .name=="Noura Al Harbi" and .country=="SA"' --argjson n "$noura"
  invoices "$u_ex" 2027-02-01 2027-02-28
  expect_invoices "Omar's February schedule is unchanged after the run" SAR "1 2027-02-10 FIRST 5/31 4823 723 5546" "2 2027-02-15 MONTHLY - 29900 4485 34385"
}

# ============================================================================= main
finish() {
  printf '\n%s== RESULT ==%s  tag RUN=%s  base %s\n' "$B" "$Z" "$RUN" "$BASE"
  printf '  %s%d passed%s   %s%d failed%s   %s%d warnings%s   %s%d responses were 5xx / no answer%s\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$Y" "$WARN" "$Z" "$R" "$N5XX" "$Z"
  if [ "$FAIL" -gt 0 ]; then printf '\n%sFailed (spec rule broken):%s\n' "$R" "$Z"; sed 's/^/  - /' "$TMP/failures"; fi
  if [ "$WARN" -gt 0 ]; then printf '\n%sWarnings (spec is silent; likely reading not met):%s\n' "$Y" "$Z"; sed 's/^/  - /' "$TMP/warnings"; fi
  if [ "$N5XX" -gt 0 ]; then printf '\n%sRequests answered with 5xx or not at all (always a bug):%s\n' "$R" "$Z"; sed 's/^/  /' "$TMP/5xx" | head -40; fi
  [ "$FAIL" -eq 0 ] && [ "$N5XX" -eq 0 ]
}

need_server
case "${1:-all}" in
  contract) contract ;;
  part1) part1 ;;
  part2) part2 ;;
  part3) part3 ;;
  e2e)   e2e ;;
  all)   contract; part1; part2; part3; e2e ;;
  *) echo "usage: $0 [contract|part1|part2|part3|e2e|all]"; exit 2 ;;
esac
finish
