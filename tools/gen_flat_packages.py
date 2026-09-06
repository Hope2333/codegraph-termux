#!/usr/bin/env python3
"""gen_flat_packages.py — build a flat APT Packages index from .deb files.

Self-contained (no dpkg-scanpackages / dpkg-deb needed): parses the ar archive
and its control.tar member directly. Control-parsing logic is reused verbatim
from opencode-termux tools/gen-packages-index.py, including its known pitfalls:
  - ar header layout: name = bytes[0:16], size = bytes[48:58], body at +60
  - magic must be compared as bytes: b'!<arch>\n'
  - tarfile member must be read BEFORE tf.close() (lazy reading)
  - tar member candidates: './control' then 'control'

Modes:
  add --deb DEB --state FILE
        Parse one .deb, accumulate its metadata record into the state JSON.
        Called once per downloaded asset so the caller can delete each .deb
        immediately (disk hygiene on small devices).
  finalize --state FILE --out OUT
        Apply the single-version doctrine (keep ONLY the newest version per
        Package name, sort -V semantics), write OUT as gzip -9n, hard-fail on
        zero entries.
  index --out OUT DEB [DEB...]
        One-shot in-memory variant of add+finalize.
  inspect GZ
        Verify an existing Packages.gz: gzip validity, entry count, and the
        Package/Filename pair of every stanza. Hard-fail on zero entries.

Stanzas are blank-line separated (canonical RFC822, what apt's pkgTagFile
expects). Filename is the BARE deb filename because the flat sources line is
  deb [trusted=yes] https://github.com/<owner>/<repo>/releases/latest/download/ ./
and apt joins the sources URL with Filename.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
import re
import sys
import tarfile


def read_control(deb):
    """Extract control fields from a .deb (control.tar.xz or control.tar.gz)."""
    with open(deb, 'rb') as f:
        data = f.read()
    if not data.startswith(b'!<arch>\n'):
        raise ValueError('not an ar archive: %s' % deb)
    blob = None
    pos = 8
    while pos + 60 <= len(data):
        name = data[pos:pos + 16].decode('ascii', 'replace').strip()
        size = int(data[pos + 48:pos + 58].decode('ascii', 'replace').strip() or 0)
        body = data[pos + 60:pos + 60 + size]
        if name.startswith('control.tar.'):
            blob = (name, body)
            break
        pos = pos + 60 + size + (size % 2)
    if blob is None:
        raise ValueError('no control member in %s' % deb)
    kind, ctrl_blob = blob
    mode = 'r:xz' if kind.endswith('xz') else 'r:gz'
    tf = tarfile.open(fileobj=io.BytesIO(ctrl_blob), mode=mode)
    member = None
    for cand in ('./control', 'control'):
        try:
            member = tf.extractfile(cand)
        except KeyError:
            member = None
        if member is not None:
            break
    if member is None:
        tf.close()
        raise ValueError('no control file in %s' % deb)
    ctrl = member.read().decode('utf-8', 'replace')
    tf.close()
    fields = {}
    for line in ctrl.splitlines():
        if ': ' in line and not line.startswith((' ', chr(9))):
            k, _, v = line.partition(': ')
            fields[k] = v.strip()
    return fields


def sha256_size(path):
    h = hashlib.sha256()
    sz = 0
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
            sz += len(chunk)
    return h.hexdigest(), sz


def ver_key(v):
    """Approximate sort -V: digit runs compare numerically, others lexically."""
    return tuple(
        (1, int(p), '') if p.isdigit() else (0, 0, p)
        for p in re.findall(r'\d+|\D+', v)
    )


def record_from_deb(deb):
    fields = read_control(deb)
    pkg = fields.get('Package', '')
    ver = fields.get('Version', '')
    if not pkg or not ver:
        raise ValueError('missing Package/Version in %s' % deb)
    sha, size = sha256_size(deb)
    return {
        'filename': os.path.basename(deb),
        'package': pkg,
        'version': ver,
        'architecture': fields.get('Architecture', 'aarch64'),
        'installed_size': fields.get('Installed-Size', '0'),
        'depends': fields.get('Depends', ''),
        'description': fields.get('Description', ''),
        'size': size,
        'sha256': sha,
    }


def stanza(rec):
    return '\n'.join([
        'Package: %s' % rec['package'],
        'Version: %s' % rec['version'],
        'Architecture: %s' % rec['architecture'],
        'Installed-Size: %s' % rec['installed_size'],
        'Depends: %s' % rec['depends'],
        'Description: %s' % rec['description'],
        'Filename: %s' % rec['filename'],
        'Size: %d' % rec['size'],
        'SHA256: %s' % rec['sha256'],
    ]) + '\n'


def latest_only(records):
    """Single-version doctrine: newest version per Package name (sort -V)."""
    best = {}
    for rec in sorted(records, key=lambda r: r['filename']):
        pkg = rec['package']
        key = (ver_key(rec['version']), rec['filename'])
        if pkg not in best or key > best[pkg][0]:
            best[pkg] = (key, rec)
    return [best[p][1] for p in sorted(best)]


def write_gz(blob, out):
    tmp = out + '.tmp'
    with open(tmp, 'wb') as f:
        # gzip -9n semantics: max compression, no mtime/name in the header
        f.write(gzip.compress(blob, compresslevel=9, mtime=0))
    os.replace(tmp, out)


def emit(chosen, out):
    blob = ''.join(stanza(r) for r in chosen).encode('utf-8')
    write_gz(blob, out)
    n = len(chosen)
    b = os.path.getsize(out)
    if n < 1 or b <= 0:
        raise SystemExit('FATAL: guard failed — entries=%d bytes=%d, refusing to produce an empty/broken index' % (n, b))
    print('PACKAGES_INDEX %s entries=%d bytes=%d' % (out, n, b))
    for r in chosen:
        print('ENTRY %s\t%s' % (r['package'], r['filename']))


def load_state(path):
    if os.path.exists(path):
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    return {'records': {}}


def save_state(path, state):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def parse_stanzas(text):
    stanzas, cur = [], []
    for line in text.splitlines():
        if line.strip() == '':
            if cur:
                stanzas.append(cur)
                cur = []
        else:
            cur.append(line)
    if cur:
        stanzas.append(cur)
    out = []
    for s in stanzas:
        fields = {}
        for line in s:
            if ': ' in line:
                k, _, v = line.partition(': ')
                fields[k] = v.strip()
        out.append(fields)
    return out


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest='cmd', required=True)

    a = sub.add_parser('add', help='parse one .deb into the state file')
    a.add_argument('--deb', required=True)
    a.add_argument('--state', required=True)

    f = sub.add_parser('finalize', help='single-version filter + write Packages.gz')
    f.add_argument('--state', required=True)
    f.add_argument('--out', required=True)

    i = sub.add_parser('index', help='one-shot: index local .deb paths')
    i.add_argument('--out', required=True)
    i.add_argument('debs', nargs='+')

    v = sub.add_parser('inspect', help='verify an existing Packages.gz')
    v.add_argument('gz')

    args = p.parse_args(argv)

    if args.cmd == 'add':
        rec = record_from_deb(args.deb)
        state = load_state(args.state)
        state.setdefault('records', {})[rec['filename']] = rec
        save_state(args.state, state)
        print('ADDED %s pkg=%s ver=%s size=%d' % (rec['filename'], rec['package'], rec['version'], rec['size']))
        return 0

    if args.cmd == 'finalize':
        state = load_state(args.state)
        records = list(state.get('records', {}).values())
        if not records:
            raise SystemExit('FATAL: state has zero records — refusing to generate an empty index')
        emit(latest_only(records), args.out)
        return 0

    if args.cmd == 'index':
        records = [record_from_deb(d) for d in args.debs]
        emit(latest_only(records), args.out)
        return 0

    if args.cmd == 'inspect':
        with open(args.gz, 'rb') as fh:
            raw = fh.read()
        if not raw:
            raise SystemExit('FATAL: %s is empty' % args.gz)
        try:
            blob = gzip.decompress(raw)
        except OSError as e:
            raise SystemExit('FATAL: gzip invalid in %s: %s' % (args.gz, e))
        stanzas = parse_stanzas(blob.decode('utf-8', 'replace'))
        if not stanzas:
            raise SystemExit('FATAL: zero stanzas in %s' % args.gz)
        print('PACKAGES_INDEX %s entries=%d bytes=%d' % (args.gz, len(stanzas), len(raw)))
        for s in stanzas:
            pkg = s.get('Package', '')
            fn = s.get('Filename', '')
            if not pkg or not fn:
                raise SystemExit('FATAL: stanza missing Package/Filename: %r' % s)
            print('ENTRY %s\t%s' % (pkg, fn))
        return 0

    return 1


if __name__ == '__main__':
    sys.exit(main())
