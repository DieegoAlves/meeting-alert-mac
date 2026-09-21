#!/usr/bin/env bash
# Generates Sources/Core/Secrets.swift from the environment at BUILD TIME.
#
# WHY: for a distributed build we embed the Google OAuth Desktop-app Client ID + Secret so
# other people can just download the DMG and sign in — no Google Cloud project of their own.
# For a "Desktop app" OAuth client the secret is NOT confidential (OAuth 2.0 for installed
# apps, RFC 8252 §8.5 / Google's own docs), so embedding it in the shipped binary is the
# accepted pattern. It still must NEVER live in the repository — this file is GITIGNORED and
# produced fresh on every build from env vars GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET.
#
# No env vars → a Secrets.swift with `nil` values is written, so `swift build` still succeeds
# and the app shows a clear "configure OAuth" instruction instead of crashing. This is exactly
# the CI (ci.yml) path: it proves the build passes with NO credentials.
#
# Usage:  GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… scripts/gen-secrets.sh
#     or  scripts/gen-secrets.sh            # writes nil placeholders
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$REPO_ROOT/Sources/Core/Secrets.swift"

CID="${GOOGLE_CLIENT_ID:-}"
CSECRET="${GOOGLE_CLIENT_SECRET:-}"

# Swift-literal for an optional String: `"value"` (escaped) or `nil`.
swift_optional() {
  local v="$1"
  if [[ -z "$v" ]]; then
    printf 'nil'
  else
    # Escape backslashes and double-quotes for a Swift string literal.
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "$v"
  fi
}

CID_LIT="$(swift_optional "$CID")"
CSECRET_LIT="$(swift_optional "$CSECRET")"

cat > "$OUT" <<EOF
// GENERATED FILE — DO NOT EDIT, DO NOT COMMIT (gitignored).
// Produced by scripts/gen-secrets.sh from env GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET at build time.
//
// For a Google "Desktop app" OAuth client the client secret is not treated as confidential
// (OAuth 2.0 for installed apps), so it is embedded in the distributed binary. It is NEVER
// committed to git. With both values nil the app falls back to the user-provided client
// (Preferences → "Usar meu próprio client OAuth") or shows a setup instruction.
import Foundation

public enum Secrets {
    public static let googleClientID: String? = $CID_LIT
    public static let googleClientSecret: String? = $CSECRET_LIT
}
EOF

if [[ -n "$CID" ]]; then
  echo "[gen-secrets] wrote $OUT WITH embedded credentials (values not printed)."
else
  echo "[gen-secrets] wrote $OUT with nil placeholders (no credentials in environment)."
fi
