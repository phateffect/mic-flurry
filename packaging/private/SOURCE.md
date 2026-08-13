# Corresponding source

This private MicFlurry package includes its exact corresponding source in the adjacent `Source`
directory. The snapshot contains the Swift and Rust implementations, the BlackHole and btleplug
upstream sources, MicFlurry patches, package manifests, fixtures, and build/install scripts used for
this binary.

The canonical project repository is <https://github.com/phateffect/mic-flurry>. The source snapshot
is authoritative for this package, including when it was built from changes not yet committed to
the canonical repository. The root `LICENSE` contains the GPL-3.0 terms. Upstream notices and
licenses remain with their source trees.

Build the private service bundle with:

```bash
mise run swift-private-dist
```

The separately distributed AudioServerPlugIn is built from the BlackHole submodule plus
`patches/mic-flurry.patch`; its build and packaging instructions remain in the included scripts and
project documentation.
