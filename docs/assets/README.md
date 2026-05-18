# docs/assets — GitHub Pages mirror

The brand SVGs in this directory are byte-for-byte copies of the files in
the repo root `assets/` directory. Both locations are intentional and each
serves a different consumer:

| Location | Consumer | Why |
| --- | --- | --- |
| `assets/` (repo root) | `README.md` `<img src="assets/...">` tags | GitHub renders README relative to the repo root, so root-relative paths work |
| `docs/assets/` | `docs/index.html` `src="assets/..."` paths | GitHub Pages serves from `docs/`, so the landing page's relative `src=` paths resolve to `docs/assets/` |

**Files that live only in `assets/` (root):** `ziggyzag.ico`, `ziggyzag-256.png`,
`app.rc` — these are build artifacts for the Windows icon and are not needed
by the landing page.

**Keeping them in sync:** when any SVG under `assets/` is updated, copy it to
`docs/assets/` as well (or vice-versa). The easiest check:

```sh
for f in assets/*.svg; do
  diff -q "$f" "docs/$f" || echo "DIVERGED: $f"
done
```

Last verified identical: 2026-05-17.
