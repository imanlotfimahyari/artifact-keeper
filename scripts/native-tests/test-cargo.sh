#!/bin/bash
# Cargo native client test script
# Tests push (cargo publish) and pull (cargo install) operations
set -euo pipefail

REGISTRY_URL="${REGISTRY_URL:-http://localhost:8080}"
REPO_KEY="${REPO_KEY:-test-cargo}"
CA_CERT="${CA_CERT:-}"
TEST_VERSION="1.0.$(date +%s)"

CARGO_REGISTRY_URL="$REGISTRY_URL/cargo/$REPO_KEY"

echo "==> Cargo Native Client Test"
echo "Registry: $CARGO_REGISTRY_URL"
echo "Version: $TEST_VERSION"

# Generate test crate
echo "==> Generating test crate..."
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"
mkdir -p src

cat > Cargo.toml << EOF
[package]
name = "test-crate-native"
version = "$TEST_VERSION"
edition = "2021"
description = "Test crate for native client E2E testing"
license = "MIT"

[lib]
name = "test_crate_native"
path = "src/lib.rs"
EOF

cat > src/lib.rs << EOF
pub fn hello() -> &'static str {
    "Hello from test-crate-native!"
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_hello() {
        assert_eq!(hello(), "Hello from test-crate-native!");
    }
}
EOF

# Configure cargo registry (sparse protocol)
echo "==> Configuring cargo registry..."
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
mkdir -p "$CARGO_HOME"
cat > "$CARGO_HOME/config.toml" << EOF
[registries.test-registry]
index = "sparse+$CARGO_REGISTRY_URL/"

credential-provider = "cargo:token"

[registry]
default = "test-registry"
EOF

# Set token (Basic auth encoded as expected by the backend)
# Throwaway e2e admin credential: the value is defined once, in the
# repository-root .env.test (#3490). Absent inside an e2e container, where
# compose has already injected the same variables from the same file.
_ak_test_env="$(dirname "$0")/../lib/test-env.sh"
# shellcheck source=/dev/null
[ -r "$_ak_test_env" ] && . "$_ak_test_env"
export CARGO_REGISTRIES_TEST_REGISTRY_TOKEN="Basic $(echo -n "${ADMIN_USER:-admin}:${ADMIN_PASS:-${AK_TEST_ADMIN_PASSWORD:-}}" | base64)"

# Package the crate
echo "==> Packaging crate..."
cargo package --allow-dirty --no-verify

# Push with cargo publish
echo "==> Publishing crate with cargo..."
cargo publish --registry test-registry --allow-dirty --no-verify

# Verify push
echo "==> Verifying crate was published..."
sleep 2

# Pull with cargo install (in a new directory)
echo "==> Installing crate with cargo..."
mkdir -p "$WORK_DIR/test-install"
cd "$WORK_DIR/test-install"
cargo init --name test-consumer
cat >> Cargo.toml << EOF
test-crate-native = { version = "$TEST_VERSION", registry = "test-registry" }
EOF

# Try to build (which will fetch the dependency)
cat > src/main.rs <<'RUST'
fn main() { print!("{}", test_crate_native::hello()); }
RUST
# A fresh package cache proves this consumer fetches the published crate.
cp "$CARGO_HOME/config.toml" "$WORK_DIR/registry-config.toml"
export CARGO_HOME="$WORK_DIR/fresh-cargo"
mkdir -p "$CARGO_HOME"
cp "$WORK_DIR/registry-config.toml" "$CARGO_HOME/config.toml"
cargo build
[ "$(cargo run --offline --quiet)" = 'Hello from test-crate-native!' ]

echo ""
echo "✅ Cargo native client test PASSED"
