#!/bin/bash
# Hex native client test script
# Tests publish and download operations via the Hex repository API
#
# Hex tarballs are outer tar archives containing:
#   VERSION        (text file: "3")
#   metadata.config (Erlang term format with name/version)
#   contents.tar.gz (the actual package source)
#   CHECKSUM       (SHA-256 of the concatenated above)
#
# Usage:
#   ./test-hex.sh                                        # localhost:30080
#   REGISTRY_URL=http://backend:8080 ./test-hex.sh       # Docker compose
set -euo pipefail

REGISTRY_URL="${REGISTRY_URL:-http://localhost:30080}"
HEX_REPO_KEY="${HEX_REPO_KEY:-test-hex}"
HEX_URL="$REGISTRY_URL/hex/$HEX_REPO_KEY"
ADMIN_USER="${ADMIN_USER:-admin}"
# Throwaway e2e admin credential: the value is defined once, in the
# repository-root .env.test (#3490). Absent inside an e2e container, where
# compose has already injected the same variables from the same file.
_ak_test_env="$(dirname "$0")/../lib/test-env.sh"
# shellcheck source=/dev/null
[ -r "$_ak_test_env" ] && . "$_ak_test_env"
ADMIN_PASS="${ADMIN_PASS:-${AK_TEST_ADMIN_PASSWORD:-}}"
TEST_VERSION="0.1.$(date +%s)"
PKG_NAME="test_hex_pkg"

echo "==> Hex Native Client Test"
echo "Registry: $HEX_URL"
echo "Package:  $PKG_NAME@$TEST_VERSION"

# Check prerequisites
command -v curl >/dev/null || { echo "SKIP: curl not found"; exit 0; }
command -v tar  >/dev/null || { echo "SKIP: tar not found"; exit 0; }
command -v jq   >/dev/null || { echo "SKIP: jq not found"; exit 0; }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- Build a minimal hex tarball ----
echo "==> Building hex tarball..."

# VERSION file
echo -n "3" > "$WORK_DIR/VERSION"

# metadata.config in Erlang term format
cat > "$WORK_DIR/metadata.config" << EOF
{<<"name">>, <<"$PKG_NAME">>}.
{<<"version">>, <<"$TEST_VERSION">>}.
{<<"description">>, <<"Test package for artifact-keeper Hex E2E">>}.
{<<"app">>, <<"$PKG_NAME">>}.
EOF

# contents.tar.gz (a tiny Elixir module)
mkdir -p "$WORK_DIR/contents/lib"
cat > "$WORK_DIR/contents/lib/${PKG_NAME}.ex" << EOF
defmodule TestHexPkg do
  def hello, do: "Hello from test_hex_pkg!"
end
EOF
(cd "$WORK_DIR/contents" && tar czf "$WORK_DIR/contents.tar.gz" .)

# CHECKSUM: SHA-256 of VERSION + metadata.config + contents.tar.gz concatenated
cat "$WORK_DIR/VERSION" "$WORK_DIR/metadata.config" "$WORK_DIR/contents.tar.gz" \
  | shasum -a 256 | awk '{print $1}' > "$WORK_DIR/CHECKSUM"

# Build outer tarball
TARBALL="$WORK_DIR/${PKG_NAME}-${TEST_VERSION}.tar"
(cd "$WORK_DIR" && tar cf "$TARBALL" VERSION metadata.config contents.tar.gz CHECKSUM)

TARBALL_SIZE=$(wc -c < "$TARBALL" | tr -d ' ')
echo "  Built tarball: ${PKG_NAME}-${TEST_VERSION}.tar (${TARBALL_SIZE} bytes)"

# Base64 credentials for Basic auth
AUTH_HEADER="$(echo -n "${ADMIN_USER}:${ADMIN_PASS}" | base64)"

# ---- Test 1: Publish package ----
echo "==> [1/6] Publishing package..."
PUBLISH_CODE=$(curl -s -o "$WORK_DIR/publish-resp.json" -w "%{http_code}" \
  -X POST "$HEX_URL/publish" \
  -H "Authorization: Basic $AUTH_HEADER" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@$TARBALL")
if [ "$PUBLISH_CODE" = "200" ] || [ "$PUBLISH_CODE" = "201" ]; then
    echo "  Published: $PKG_NAME@$TEST_VERSION"
else
    echo "  FAIL: Publish returned HTTP $PUBLISH_CODE"
    cat "$WORK_DIR/publish-resp.json" 2>/dev/null || true
    exit 1
fi

# ---- Test 2: Signed protobuf registry and native Hex verification ----
echo "==> [2/6] Verifying signed registry resources..."
curl -fsS "$HEX_URL/public_key" -o "$WORK_DIR/registry-key.pem"
for resource in "packages/$PKG_NAME" names versions; do
    file="$WORK_DIR/$(basename "$resource").gz"
    curl -fsS "$HEX_URL/$resource" -o "$file"
    python3 "$(dirname "$0")/verify-hex-resource.py" "$file" "$WORK_DIR/registry-key.pem" "$PKG_NAME" "$TEST_VERSION" "$HEX_REPO_KEY" "$resource"
done
command -v mix >/dev/null || { echo "FAIL: native Mix client is required"; exit 1; }
export MIX_HOME="$WORK_DIR/mix" HEX_HOME="$WORK_DIR/hex"
mix local.hex 2.5.2 --force
mix hex.repo add "$HEX_REPO_KEY" "$HEX_URL" --public-key="$WORK_DIR/registry-key.pem"
mix hex.package fetch "$PKG_NAME" "$TEST_VERSION" --repo="$HEX_REPO_KEY" --output="$WORK_DIR/native"
cmp "$TARBALL" "$WORK_DIR/native/${PKG_NAME}-${TEST_VERSION}.tar"
echo "  Native Hex fetched and verified the exact published tarball"

# ---- Test 3: Download tarball ----
echo "==> [3/6] Downloading tarball..."
DL_CODE=$(curl -s -o "$WORK_DIR/downloaded.tar" -w "%{http_code}" \
  "$HEX_URL/tarballs/${PKG_NAME}-${TEST_VERSION}.tar")
if [ "$DL_CODE" = "200" ]; then
    DL_SIZE=$(wc -c < "$WORK_DIR/downloaded.tar" | tr -d ' ')
    if [ "$DL_SIZE" -gt 50 ]; then
        echo "  Downloaded: ${PKG_NAME}-${TEST_VERSION}.tar (${DL_SIZE} bytes)"
    else
        echo "  FAIL: Downloaded tarball too small (${DL_SIZE} bytes)"
        exit 1
    fi
else
    echo "  FAIL: Download returned HTTP $DL_CODE"
    exit 1
fi

# ---- Test 4: Verify tarball contents ----
echo "==> [4/6] Verifying tarball contents..."
EXTRACTED_DIR="$WORK_DIR/extracted"
mkdir -p "$EXTRACTED_DIR"
(cd "$EXTRACTED_DIR" && tar xf "$WORK_DIR/downloaded.tar")
if [ -f "$EXTRACTED_DIR/metadata.config" ] && [ -f "$EXTRACTED_DIR/VERSION" ]; then
    EXTRACTED_NAME=$(grep '<<"name">>' "$EXTRACTED_DIR/metadata.config" | sed 's/.*<<"\([^"]*\)">>.*<<"\([^"]*\)">>.*/\2/')
    if [ "$EXTRACTED_NAME" = "$PKG_NAME" ]; then
        echo "  Tarball contents verified (metadata.config present, name=$EXTRACTED_NAME)"
    else
        echo "  FAIL: Extracted name '$EXTRACTED_NAME' does not match '$PKG_NAME'"
        exit 1
    fi
else
    echo "  FAIL: Tarball missing expected files"
    ls -la "$EXTRACTED_DIR"
    exit 1
fi

echo "==> [5/6] Signed names resource verified"
echo "==> [6/6] Signed versions resource verified"
echo "PASS: Hex publish, signed registry, native fetch and content round-trip"
