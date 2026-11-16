#!/usr/bin/env bash
# Provisions the proxy root CA secret on OpenBao (docs/plan.md §4.2).
#
#   legacy CA on the volume, secret absent  -> empty placeholder
#   no CA on the volume,     secret absent  -> generate a CA and store it
#   secret present                          -> nothing (never overwrites)
#
# Never prints keys or tokens. The last line is "RESULT: <action>".
set -euo pipefail

: "${BAO_ADDR:?BAO_ADDR is required}"
: "${BAO_ROLE:?BAO_ROLE is required}"
: "${SECRET_PATH:?SECRET_PATH is required (KV v2 API path, e.g. secret/data/proxy/ns/root-ca)}"
BAO_AUTH_PATH="${BAO_AUTH_PATH:-kubernetes}"
LEGACY_CA_DIR="${LEGACY_CA_DIR:-/legacy-certs/_ca}"
CA_SUBJECT="${CA_SUBJECT:-/CN=Proxy Root CA}"
CA_DAYS="${CA_DAYS:-3650}"
CA_KEY_ALG="${CA_KEY_ALG:-rsa:4096}"
SA_TOKEN_FILE="${SA_TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/provision.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# bao_request <method> <api path> [json body file]
# Prints the HTTP status code; the response body is left in $WORK/resp.
# The token header is read from a file, so it never appears in argv.
bao_request() {
  local method="$1" path="$2" body="${3:-}" args=()
  [[ ! -f "$WORK/auth-header" ]] || args+=(-H "@$WORK/auth-header")
  [[ -z "$body" ]] || args+=(-H "Content-Type: application/json" --data-binary "@$body")
  curl -sS --retry 5 --retry-connrefused --retry-delay 2 \
    -o "$WORK/resp" -w '%{http_code}' -X "$method" "${args[@]}" "$BAO_ADDR/v1/$path"
}

# --- 1. login ----------------------------------------------------------------
[[ -r "$SA_TOKEN_FILE" ]] || die "service account token not readable: $SA_TOKEN_FILE"
jq -n --arg role "$BAO_ROLE" --rawfile jwt "$SA_TOKEN_FILE" '{role: $role, jwt: ($jwt | rtrimstr("\n"))}' \
  >"$WORK/login.json"
status="$(bao_request POST "auth/$BAO_AUTH_PATH/login" "$WORK/login.json")"
rm -f "$WORK/login.json"
[[ "$status" == 200 ]] || die "login on auth/$BAO_AUTH_PATH with role $BAO_ROLE failed: HTTP $status"
jq -r '"X-Vault-Token: " + .auth.client_token' "$WORK/resp" >"$WORK/auth-header"
rm -f "$WORK/resp"
log "logged in to $BAO_ADDR (auth/$BAO_AUTH_PATH, role $BAO_ROLE)"

# --- 2. legacy volume ----------------------------------------------------------
key_file="$LEGACY_CA_DIR/private-key.pem"
cert_file="$LEGACY_CA_DIR/certificate.pem"
if [[ -s "$key_file" && -s "$cert_file" ]]; then
  volume=present
elif [[ ! -e "$key_file" && ! -e "$cert_file" ]]; then
  volume=absent
else
  die "incomplete CA on legacy volume $LEGACY_CA_DIR: expected both private-key.pem and certificate.pem, non-empty"
fi

# --- 3. secret -------------------------------------------------------------------
# secret_state: absent | empty | data | partial
secret_state() {
  local status
  status="$(bao_request GET "$SECRET_PATH")"
  case "$status" in
    200) jq -r '.data.data as $d
                | [($d.private_key // "") != "", ($d.certificate // "") != ""]
                | if all then "data" elif any then "partial" else "empty" end' "$WORK/resp" ;;
    404) echo absent ;;
    *) die "reading $SECRET_PATH failed: HTTP $status" ;;
  esac
  rm -f "$WORK/resp"
}
secret="$(secret_state)"
log "legacy volume: $volume, secret $SECRET_PATH: $secret"

# --- 4. decision -----------------------------------------------------------------
# write_secret <json body file>: create-only write (cas=0).
# If it fails because the secret appeared meanwhile, that is a no-op.
write_secret() {
  local status now
  status="$(bao_request POST "$SECRET_PATH" "$1")"
  rm -f "$1"
  [[ "$status" == 200 || "$status" == 204 ]] && return 0
  warn "create-only write of $SECRET_PATH failed: HTTP $status; checking whether it exists now"
  now="$(secret_state)"
  [[ "$now" != absent ]] || die "cannot create $SECRET_PATH (HTTP $status)"
  log "secret created concurrently by someone else, leaving it untouched"
  log "RESULT: noop"
  exit 0
}

fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | tr 'A-F' 'a-f'
}

if [[ "$secret" != absent ]]; then
  case "$volume/$secret" in
    present/data)    warn "secret has data: the proxy will use the CA from OpenBao, not the one on the legacy volume" ;;
    absent/empty)    warn "secret is an empty placeholder and the legacy volume has no CA: the proxy will fail (no root CA available)" ;;
    */partial)       warn "secret has only one of private_key/certificate: the proxy will fail (partial configuration)" ;;
  esac
  log "RESULT: noop"
  exit 0
fi

if [[ "$volume" == present ]]; then
  jq -n '{options: {cas: 0}, data: {private_key: "", certificate: ""}}' >"$WORK/body.json"
  write_secret "$WORK/body.json"
  log "RESULT: placeholder-created"
  exit 0
fi

log "generating root CA: subject '$CA_SUBJECT', $CA_KEY_ALG, $CA_DAYS days"
openssl req -x509 -newkey "$CA_KEY_ALG" -nodes -sha256 -days "$CA_DAYS" -subj "$CA_SUBJECT" \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" 2>/dev/null \
  || die "openssl failed to generate the root CA"
base64 <"$WORK/ca.key" | tr -d '\n' >"$WORK/ca.key.b64"
base64 <"$WORK/ca.crt" | tr -d '\n' >"$WORK/ca.crt.b64"
jq -n --rawfile k "$WORK/ca.key.b64" --rawfile c "$WORK/ca.crt.b64" \
  '{options: {cas: 0}, data: {private_key: $k, certificate: $c}}' >"$WORK/body.json"
rm -f "$WORK/ca.key" "$WORK/ca.key.b64" "$WORK/ca.crt.b64"
write_secret "$WORK/body.json"
log "FINGERPRINT_SHA256: $(fingerprint "$WORK/ca.crt")"
log "RESULT: ca-generated"
