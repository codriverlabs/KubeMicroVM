# Release Versioning

## Tag notation

```
v<major>.<minor>.<patch>-rc<N>
```

Examples: `v0.0.1-rc1`, `v0.0.1-rc2`, `v0.1.0-rc1`, `v1.0.0-rc1`

## Rules

- All releases start as release candidates (`-rcN`).
- GA release drops the suffix: `v0.0.1-rc1` → `v0.0.1`.
- First release: **`v0.0.1-rc1`**.
- Increment `rc` for fixes on the same version: `v0.0.1-rc1` → `v0.0.1-rc2`.
- Promote to next minor/major when there are breaking changes or significant new features.

## Creating a release

```bash
git tag v0.0.1-rc1 && git push --tags
```

This triggers the GitHub Actions release workflow which:
1. Builds native binaries for linux/amd64 and linux/arm64
2. Builds and pushes multi-arch container images to GHCR
3. Packages and pushes the Helm chart to `oci://ghcr.io/codriverlabs/helm`
4. Creates a GitHub Release with binaries, Helm chart, and checksums
