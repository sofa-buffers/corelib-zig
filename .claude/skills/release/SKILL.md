---
name: release
description: Cut a corelib-zig release — bump build.zig.zon and the README's pinned fetch ref, land them via a release PR, then tag vX.Y.Z and publish the GitHub release. Use when the user asks to release, tag or publish a new version of this library.
argument-hint: "[X.Y.Z]"
disable-model-invocation: true
---

# Releasing corelib-zig

**The git tag is the source of truth for the version.** Every file that states the
version must already say it when the tag is pushed; `version-consistency.yml` runs
on `v*` tag pushes and fails if the tag is not `vX.Y.Z`, or if `build.zig.zon` or the
README's pinned `zig fetch` ref disagrees with it.

**Tag format: a lowercase `v` followed by the semver, e.g. `v1.2.3`.** Never `V1.2.3`,
never a bare `1.2.3`, and no suffix such as `v1.2.3-release`. `version-consistency.yml`
only triggers on `v*` and strips exactly one leading `v`. The version inside
`build.zig.zon` carries no `v` (`"1.2.3"`).

The tag is what consumers fetch (`zig fetch --save git+…#vX.Y.Z`), so a pushed tag is
effectively public. Never move or delete a pushed tag — cut a new patch release instead.

## Where the version lives (exactly two places)

| File | What to change |
|---|---|
| `build.zig.zon` | `.version = "X.Y.Z",` |
| `README.md` | the install line `zig fetch --save git+https://github.com/sofa-buffers/corelib-zig#vX.Y.Z` |

**Leave these alone.** They look like versions but aren't the package version:
- `.minimum_zig_version` in `build.zig.zon`, `ZIG_VERSION` in `ci.yml`, and `version:` in
  `docs.yml`: the toolchain, which changes on its own schedule.
- `.fingerprint` in `build.zig.zon`: the package identity. Never change it.
- The API version constant in `src/types.zig` (`1`, CORELIB_PLAN §5) and the check in
  `tests/api_tests.zig`: this is the wire/API contract version, not the release.
- `"version": 1` in `assets/test_vectors.json`: the vector file format, which corelib-c-cpp owns.

If a new place ever starts carrying the version, add it to this table *and* to
`version-consistency.yml`.

## Procedure

### 1. Preconditions — stop and report if any fails

```bash
git checkout main && git pull -p
git status --porcelain                        # must be empty
PREV=$(git describe --tags --abbrev=0)        # last release, e.g. v0.10.0
git log --oneline "$PREV"..main               # must not be empty (nothing to release otherwise)
gh run list --branch main --workflow CI -L 1  # the newest run must be for HEAD and ✓
gh run list --workflow "Shared vectors" -L 1  # the vendored vectors must be current
```

If the shared-vectors run is red, `assets/test_vectors.json` is out of sync with
corelib-c-cpp. Refresh it in a separate PR before releasing. Don't fold it into the
release PR.

### 2. Choose the version

Use `$ARGUMENTS` if given. Accept `1.2.3`, `v1.2.3` or `V1.2.3`, but normalise it: `V`
is the bare `1.2.3`, and the tag is always `v$V`, with a lowercase `v`. Otherwise propose
one:

- **Pre-1.0 rule (family-wide):** a *minor* bump may break API or wire output, and a *patch*
  bump may not. Any breaking commit since `$PREV` forces a minor bump:
  ```bash
  git log --format='%h %s' "$PREV"..main | grep -E '^[0-9a-f]+ [a-z]+(\([^)]*\))?!:'
  git log --format='%h %B' "$PREV"..main | grep -n 'BREAKING CHANGE'
  ```
- **Family lockstep:** the corelibs have so far been released together at one version
  (0.10.0 went out across c-cpp, rs, go, py, ts and zig within one minute). Check where the
  siblings stand:
  ```bash
  for r in corelib-c-cpp corelib-rs corelib-go corelib-py corelib-ts; do
    printf '%-15s ' $r; gh release list -R sofa-buffers/$r -L 1 | cut -f3; done
  ```
  If the proposed version differs from the family's, point that out.

The version must be plain `X.Y.Z`, greater than `$PREV`, and must not exist as a tag
locally or on origin (`git ls-remote --tags origin "vX.Y.Z"`).
**Confirm the version with the user before touching anything.**

### 3. Verify locally

```bash
zig fmt --check build.zig src tests bench
zig build test
zig build test --release=fast
zig build test -Dtarget=x86-linux     # 32-bit usize leg, runs natively
```

CI also runs s390x under QEMU and coverage. The release PR's CI covers those, so
there's no need to run them here.

### 4. Release PR

```bash
V=X.Y.Z
git checkout -b release/v$V
sed -i -E 's/^(\s*\.version\s*=\s*")[^"]+(",)/\1'"$V"'\2/' build.zig.zon
sed -i -E 's|(git\+https://github\.com/sofa-buffers/corelib-zig#v)[0-9]+\.[0-9]+\.[0-9]+|\1'"$V"'|' README.md
git diff --stat                                   # exactly build.zig.zon and README.md, 1 line each
grep -rn --exclude-dir=.git --exclude-dir=.zig-cache --exclude-dir=zig-out -F "${PREV#v}" . \
  | grep -v assets/test_vectors.json              # review any leftover mention of the old version
zig build test                                    # README is embedded in tests; must still pass
```

Commit, following #29 / `1929d33`:

```
chore(release): X.Y.Z

The git tag is the source of truth for the version; this brings build.zig.zon
and the README's pinned fetch ref in line with the vX.Y.Z tag that follows.

<If minor: one paragraph per breaking change since $PREV — what changed for a
caller, with the spec clause (§…) / issue it comes from. Say it is API-breaking
under the pre-1.0 rule that a minor bump may break API or wire output.>
```

Push the branch and open the PR titled `chore(release): X.Y.Z`. Base the body on the
commit body, and say whether the generator (sofabgen) changed in lockstep. Wait until
every CI check is green (`gh pr checks --watch`), then merge with a **merge commit**
(as #29) and delete the branch:

```bash
gh pr merge --merge --delete-branch
git checkout main && git pull -p
```

### 5. Tag — checkpoint

Before tagging, show the user the merge commit (`git log -1 --oneline`), the version
and the release notes draft (step 6). Get an explicit go-ahead. Once the tag is
pushed, it's public.

Tag the **merge commit on `main`** with an **annotated** tag, as v0.9.0 was (v0.10.0
was lightweight by accident):

```bash
[[ "v$V" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad tag name: v$V"; exit 1; }
git tag -a v$V -m "SofaBuffers corelib $V" "$(git rev-parse origin/main)"
git push origin v$V
gh run list --workflow "Version consistency" -L 1   # then: gh run watch <id> — must be ✓
```

If the version-consistency run fails, don't delete the tag. Tell the user, fix
forward with a patch release.

### 6. GitHub release

```bash
gh release create v$V --verify-tag --latest --title "v$V" --notes-file <notes.md>
```

Notes, in the shape of the v0.10.0 release:
- one line: what the release is (and if it aligns with the family version, say so);
- `**Breaking since $PREV**`, under the pre-1.0 rule. One bullet per breaking change:
  the old API → the new API, the spec clause or issue, what a caller has to change;
- notable non-breaking fixes/features (short);
- whether sofabgen changed in lockstep and which generator release it needs.

### 7. Verify the published package

```bash
cd "$(mktemp -d)" && zig fetch "git+https://github.com/sofa-buffers/corelib-zig#v$V"
```

The fetch must succeed and print a hash. Report the release URL, the tag's commit
and that hash to the user.
