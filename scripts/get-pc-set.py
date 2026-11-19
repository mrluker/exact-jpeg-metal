"""Download the public image set of exact-gpu-jpeg (bench/public_set.py) and make its 102 test JPEGs, for `ejm pc-set`.

The set is imagecompression.info's 8-bit RGB test images (rgb8bit.zip, 14 photos) and libjpeg-turbo's three
benchmark frames (3dtestimages.tar.bz2). Both archives are checked by SHA-256 before use. Every PPM is saved as JPEG
by Pillow at 6 settings (quality 95 at 4:2:0, 4:2:2, 4:4:4 and gray; quality 90 at 4:2:0; quality 95 at 4:2:0 with
optimised Huffman tables), and every JPEG is checked against testdata/pc-set-SHA256SUMS, so the files are the same
bytes the PC library and this repository's results were measured on. Needs Pillow 13.0.0 (it bundles libjpeg-turbo
3.2.0); another version may write different bytes, which the check reports.

usage: python3 scripts/get-pc-set.py <dir outside the repository>
then:  Tools/.build/release/ejm pc-set <dir>
The images' licence notice (readme.txt from rgb8bit.zip) stays with them in <dir>; keep the images out of git.
"""
import glob, hashlib, io, os, sys, tarfile, urllib.request, zipfile
from PIL import Image, __version__ as PIL_VERSION

Image.MAX_IMAGE_PIXELS = None
ARCHIVES = [
    dict(folder="imagecompression_info", name="rgb8bit.zip", images=14,
         url="https://imagecompression.info/test_images/rgb8bit.zip",
         sha256="16c273504425923259b1ddf8e39dfa9cb27585d249f6263cfc6bea39cfafa660"),
    dict(folder="libjpeg_turbo_3dtest", name="3dtestimages.tar.bz2", images=3,
         url="https://libjpeg-turbo.org/pmwiki/uploads/About/3dtestimages.tar.bz2",
         sha256="60e5cac0da25712a9b49da60212f14266d07c586dfb5d6c968e34fec6937b667"),
]
SETTINGS = [("q95_420", 95, 2, False, False), ("q95_422", 95, 1, False, False), ("q95_444", 95, 0, False, False),
            ("q95_gray", 95, None, False, True), ("q90_420", 90, 2, False, False), ("q95_420_opt", 95, 2, True, False)]
HERE = os.path.dirname(os.path.abspath(__file__))
EXPECTED = os.path.join(HERE, "..", "testdata", "pc-set-SHA256SUMS")


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def fetch(root):
    for a in ARCHIVES:
        d = os.path.join(root, a["folder"])
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, a["name"])
        if not os.path.exists(p):
            print(f"downloading {a['url']} ...", flush=True)
            urllib.request.urlretrieve(a["url"], p + ".part")
            os.replace(p + ".part", p)
        with open(p, "rb") as f:
            got = sha256(f.read())
        if got != a["sha256"]:
            sys.exit(f"{p}: SHA-256 {got}, expected {a['sha256']}")
        if len(glob.glob(os.path.join(d, "*.ppm"))) != a["images"]:
            if p.endswith(".zip"):
                with zipfile.ZipFile(p) as z:
                    for m in z.namelist():
                        if m.lower().endswith((".ppm", ".txt")) and os.path.basename(m) == m:
                            z.extract(m, d)
            else:
                with tarfile.open(p) as t:
                    for m in t.getmembers():
                        if m.isfile() and m.name.lower().endswith(".ppm") and os.path.basename(m.name) == m.name:
                            t.extract(m, d)
        assert len(glob.glob(os.path.join(d, "*.ppm"))) == a["images"], a["name"]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = os.path.abspath(sys.argv[1])
    if PIL_VERSION != "13.0.0":
        print(f"warning: Pillow {PIL_VERSION}, not 13.0.0; the JPEG bytes may differ from the published set")
    fetch(root)
    expected = {}
    with open(EXPECTED) as f:
        for line in f:
            h, n = line.split()
            expected[n] = h
    out = os.path.join(root, "jpegs")
    os.makedirs(out, exist_ok=True)
    files = sorted(glob.glob(os.path.join(root, "imagecompression_info", "*.ppm"))) + \
        sorted(glob.glob(os.path.join(root, "libjpeg_turbo_3dtest", "*.ppm")))
    sums, bad = [], 0
    for p in files:
        name = os.path.splitext(os.path.basename(p))[0]
        im = Image.open(p).convert("RGB")
        for tag, q, sub, opt, gray in SETTINGS:
            kw = dict(quality=q, optimize=opt)
            if not gray:
                kw["subsampling"] = sub
            b = io.BytesIO()
            (im.convert("L") if gray else im).save(b, "JPEG", **kw)
            data = b.getvalue()
            fn = f"{name}__{tag}.jpg"
            with open(os.path.join(out, fn), "wb") as f:
                f.write(data)
            h = sha256(data)
            sums.append(f"{h}  {fn}")
            if expected.get(fn) != h:
                bad += 1
                print(f"MISMATCH {fn}: {h}, expected {expected.get(fn)}")
    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        f.write("\n".join(sums) + "\n")
    print(f"{len(sums)} JPEGs in {out}; {len(sums) - bad} match testdata/pc-set-SHA256SUMS")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
