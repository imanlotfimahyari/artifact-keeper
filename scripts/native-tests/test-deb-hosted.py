#!/usr/bin/env python3
"""Verify a hosted Debian repository with isolated native APT state.

Uses a synthetic unsigned package, queries suite/component metadata, and checks
that APT downloads the exact bytes uploaded. Does not install packages or
change the host's APT configuration. Requires dpkg-deb and apt-get.
"""
import os, json, time, hashlib, urllib.request, urllib.error, subprocess, tempfile, pathlib, zipfile, io
BASE = 'http://127.0.0.1:18080'
TOKEN = None
ROOT = pathlib.Path.cwd()
PROFILE = 'deb'

def api(method, path, data=None, headers=None):
    h = dict(headers or {})
    if TOKEN:
        h['Authorization'] = 'Bearer ' + TOKEN
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        h['Content-Type'] = 'application/json'
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as f:
            return (f.status, f.read())
    except urllib.error.HTTPError as e:
        return (e.code, e.read())

def ok(method, path, data=None, headers=None):
    code, body = api(method, path, data, headers)
    assert 200 <= code < 300, (method, path, code, body[:180])
    return body

def cmd(args, **kw):
    r = subprocess.run(args, text=True, capture_output=True, **kw)
    if r.returncode:
        print(r.stdout[-4000:], flush=True)
        print(r.stderr[-4000:], flush=True)
        raise RuntimeError('native command failed: ' + args[0] + ' exit=' + str(r.returncode))
    return r.stdout
for _ in range(90):
    try:
        if api('GET', '/health')[0] == 200:
            break
    except OSError:
        pass
    time.sleep(1)
else:
    raise AssertionError('backend readiness timed out')
TOKEN = json.loads(ok('POST', '/api/v1/auth/login', {'username': 'admin', 'password': os.environ['ADMIN_PASS']}))['access_token']
key = 'strict-' + PROFILE
fmt = 'debian'
ok('POST', '/api/v1/repositories', {'key': key, 'name': 'Synthetic ' + PROFILE, 'format': fmt, 'repo_type': 'local', 'is_public': True})
with tempfile.TemporaryDirectory() as td:
    d = pathlib.Path(td)
    d.chmod(493)
    pkg = d / 'pkg'
    (pkg / 'DEBIAN').mkdir(parents=True)
    (pkg / 'usr/share/ca-native-deb').mkdir(parents=True)
    (pkg / 'DEBIAN/control').write_text('Package: ca-native-deb\nVersion: 1.0.0\nArchitecture: all\nMaintainer: Test <test@example.com>\nDescription: synthetic validation package\n')
    (pkg / 'usr/share/ca-native-deb/data').write_text('synthetic fixture\n')
    package = d / 'ca-native-deb_1.0.0_all.deb'
    cmd(['dpkg-deb', '--build', '--root-owner-group', str(pkg), str(package)])
    path = '/debian/' + key + '/pool/main/c/ca-native-deb/' + package.name
    ok('PUT', path, package.read_bytes(), {'Content-Type': 'application/vnd.debian.binary-package'})
    assert ok('GET', path) == package.read_bytes()
    lists = d / 'lists'
    (lists / 'partial').mkdir(parents=True)
    cache = d / 'apt-cache'
    (cache / 'archives/partial').mkdir(parents=True)
    sources = d / 'sources.list'
    sources.write_text('deb [trusted=yes] ' + BASE + '/debian/' + key + ' stable main\n')
    parts = d / 'parts'
    parts.mkdir()
    opts = ['-o', 'Dir::Etc::sourcelist=' + str(sources), '-o', 'Dir::Etc::sourceparts=' + str(parts), '-o', 'Dir::State::lists=' + str(lists), '-o', 'Dir::Cache=' + str(cache), '-o', 'APT::Get::List-Cleanup=0']
    cmd(['apt-get', *opts, 'update'])
    (d / 'download').mkdir()
    cmd(['apt-get', *opts, 'download', 'ca-native-deb=1.0.0'], cwd=d / 'download')
    assert (d / 'download' / package.name).read_bytes() == package.read_bytes()
    print('PASS: strict DEB build/upload, native APT metadata/download and byte equality (unsigned test fixture)')
