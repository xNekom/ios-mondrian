# XNU for sweet and mondrian

Built on GitHub's macOS arm64 runners by `.github/workflows/xnu.yml`, using
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build) (MIT)
at a pinned commit.

- `MACOS_VERSION=13.5` → xnu-8796.141.3 (same generation as iOS 16.6/16.7).
- The staging scripts (`00NN-stage-*.sh`) fetch Apple's open-source libpthread,
  HFS and BearSSL sources; the `*.patch` files are applied to the xnu tree with
  `git apply`, in order.
- Output: `kernel.development.<board>`, uploaded as a workflow artifact.

There are two series, one per board; the workflow picks one with its `board`
input:

| directory | board | machine config |
| --- | --- | --- |
| `patches/` | sweet (Redmi Note 10 Pro, SM7150) | `SWEET` |
| `patches-mondrian/` | mondrian (POCO F5 Pro, SM8475) | `MONDRIAN` |

Think before spending a CI run: the workflow **skips** a patch that does not
apply and still reports success. `tools/apply-series.py` applies a series to a
fresh tree locally in seconds, and `tools/check-patches.sh` checks it against
the cached tree in `research/`; both name the patch that does not apply.

Fetch the latest build:

```sh
gh run download -R xNekom/ios-mondrian -n xnu-kernel-mondrian -D xnu/out
```
