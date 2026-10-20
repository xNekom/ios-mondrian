# XNU for sweet and mondrian

Built on GitHub's macOS arm64 runners by `.github/workflows/xnu.yml`, using
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) (MIT) at a pinned commit.

- `MACOS_VERSION=13.5` -> xnu-8796 (same generation as iOS 16.6/16.7, the last iOS for iPhone 8).
- `patches/*.patch` are copied into the build script's patch dir and applied to the xnu tree with `git apply`.
- Output: `kernel.<config>.vmapple` (later: our own SWEET machine config) as a workflow artifact.

There are two series, one per board:

| directory | board | machine config |
| --- | --- | --- |
| `patches/` | sweet (Redmi Note 10 Pro, SM7150) | `SWEET` |
| `patches-mondrian/` | mondrian (POCO F5 Pro, SM8475) | `MONDRIAN` |

The workflow picks the series with its `board` input. `tools/port-series.py`
ports a patch from one series to the other.

Fetch the latest build: `gh run download -R xNekom/ios-mondrian -n xnu-kernel-sweet -D xnu/out`
