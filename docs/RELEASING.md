# Release process

Until the first actual release is published, distribution is local: a clean
source tree, a locked local build, and a versioned archive with a recorded
checksum. There is no GitHub attestation chain to trust yet — the release
download path in `scripts/build-backend.sh` (see below) stays dormant until
that first tag exists.

## Versioned local release

1. Update `manifest.json`, `backend/Cargo.toml`, `backend/Cargo.lock`, and
   `CHANGELOG.md` together. The manifest version and the backend crate
   version must match.
2. Run the whole gate:

   ```bash
   ./scripts/test.sh
   ```

3. Commit and tag `v<manifest version>` at that exact, clean commit. Never
   move or reuse a release tag; fix a failed release forward with a new
   version.
4. Build and install the backend from that tree:

   ```bash
   ./scripts/build-backend.sh
   ```

   The script builds `Cargo.lock` with `cargo build --locked --release`,
   compiling outside the plugin directory to
   `$XDG_CACHE_HOME/omarchy-navidrome/target`, and installs the binary to
   `~/.local/lib/omarchy-navidrome/omarchy-navidrome-backend`.
5. Create the versioned source archive and record its checksum with the
   built binary's checksum in a local checksum note (for example a
   `SHA256SUMS` file kept beside the archive):

   ```bash
   git archive --format=tar.gz -o "omarchy-navidrome-v0.1.0.tar.gz" v0.1.0
   sha256sum "omarchy-navidrome-v0.1.0.tar.gz" \
     "$HOME/.local/lib/omarchy-navidrome/omarchy-navidrome-backend" >> SHA256SUMS
   ```

   Bind the binary to its source in the note as well: the exact
   `backend-source-id.sh` output for the tagged commit. A checksum stored
   beside an otherwise unproven binary is a convenience record, not
   provenance — the binding that matters is that the recorded source id
   matches the tagged tree the binary was built from.

The installed backend carries its own machine-checked checksum record: three
owner-only sidecar files next to the binary (`backend-source.sha256`,
`backend-binary.sha256`, `backend-origin`), written atomically by
`scripts/build-backend.sh`. `scripts/playback-runtime.sh` re-derives the
source id and verifies the binary hash on every start, and `scripts/setup.sh`
rebuilds the backend whenever either stops matching the checkout — so a
stale or modified install is replaced automatically.

## Verified-release download path (dormant)

`scripts/build-backend.sh` retains a GitHub verified-release path for the
day a release is actually published: it downloads the raw backend for the
current architecture from the exact `v<version>` tag, checks the release's
`SHA256SUMS`, then requires GitHub's signed build provenance to match this
repository, the pinned release workflow, the exact tag and tagged commit,
and a GitHub-hosted runner (`gh attestation verify` with
`--cert-identity`, `--source-ref`, `--source-digest`, and
`--deny-self-hosted-runners`). The tagged commit must be an ancestor of the
checkout, and the backend source and Rust toolchain must be unchanged
between them; a same-release checksum alone is never accepted as
provenance.

Until the first release exists that path simply finds no release asset and
falls back to the locked source build — which is the supported flow today.
`.github/workflows/release-backend.yml` remains in the tree, with every
action pinned to an immutable commit, so the first tag starts a
provenance-attested build without further changes; when that happens, the
attestation-chain verification rules described here become binding instead
of dormant.
