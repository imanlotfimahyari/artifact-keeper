#!/usr/bin/env bash
# Sign synthetic RPM metadata with the trusted primary key. The backend's
# detached-signature verifier currently checks that key, not its signing subkeys.
set -euo pipefail
fixture_dir="${1:-scripts/native-tests/fixtures/curation/rpm/repodata}"
fixture_key="${2:-.pki/gpg-signing.key}"
export GNUPGHOME="$(mktemp -d)"
chmod 700 "$GNUPGHOME"
trap 'gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf "$GNUPGHOME"' EXIT
gpg --batch --import "$fixture_key"
fixture_fingerprint=$(gpg --batch --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}')
[ -n "$fixture_fingerprint" ]
python3 - "$fixture_dir" <<'PY'
from pathlib import Path
import hashlib
import sys
path = Path(sys.argv[1])
body = (path / 'primary.xml.gz').read_bytes()
(path / 'repomd.xml').write_text(
    '<repomd xmlns="http://linux.duke.edu/metadata/repo"><data type="primary">'
    '<location href="repodata/primary.xml.gz"/><checksum type="sha256">'
    + hashlib.sha256(body).hexdigest() + '</checksum><size>' + str(len(body))
    + '</size></data></repomd>')
PY
gpg --batch --yes --local-user "$fixture_fingerprint!" --armor --detach-sign "$fixture_dir/repomd.xml"
gpg --batch --verify "$fixture_dir/repomd.xml.asc" "$fixture_dir/repomd.xml"
