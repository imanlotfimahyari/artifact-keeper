"""Verify Hex registry signatures and the fixture's protobuf identities."""
import gzip
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile


def fields(data):
    """Decode the small protobuf wire subset used by Hex registry resources."""
    position = 0

    def varint():
        nonlocal position
        value = 0
        for shift in range(0, 70, 7):
            assert position < len(data), "truncated protobuf varint"
            byte = data[position]
            position += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise AssertionError("oversized protobuf varint")

    result = {}
    while position < len(data):
        tag = varint()
        number, wire = tag >> 3, tag & 7
        assert number, "invalid protobuf field"
        if wire == 0:
            value = varint()
        elif wire == 2:
            length = varint()
            assert position + length <= len(data), "truncated protobuf field"
            value = data[position:position + length]
            position += length
        else:
            raise AssertionError(f"unexpected protobuf wire type {wire}")
        result.setdefault(number, []).append(value)
    return result


resource, public_key, name, version, repository, kind = sys.argv[1:]
envelope = fields(gzip.decompress(Path(resource).read_bytes()))
assert len(envelope[1]) == len(envelope[2]) == 1
payload, signature = envelope[1][0], envelope[2][0]
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "payload").write_bytes(payload)
    (path / "signature").write_bytes(signature)
    subprocess.run(["openssl", "dgst", "-sha512", "-verify", public_key,
                    "-signature", str(path / "signature"), str(path / "payload")], check=True)
message = fields(payload)
if kind.startswith("packages/"):
    assert message[2] == [name.encode()]
    assert message[3] == [repository.encode()]
    releases = [fields(value) for value in message[1]]
    release = next(value for value in releases if value[1] == [version.encode()])
    tarball = Path(resource).parent / f"{name}-{version}.tar"
    assert release[5] == [hashlib.sha256(tarball.read_bytes()).digest()]
    import tarfile
    with tarfile.open(tarball) as archive:
        expected = archive.extractfile("CHECKSUM").read().strip().decode()
    assert release[2] == [bytes.fromhex(expected)]
else:
    assert message[2] == [repository.encode()]
    package = next(fields(value) for value in message[1]
                   if fields(value)[1] == [name.encode()])
    if kind == "versions":
        assert version.encode() in package[2]
print(f"PASS: authenticated Hex {kind}")
