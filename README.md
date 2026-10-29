# Panecast AirPlay Runtime

Optional, user-downloaded companion runtime that lets **Panecast（窗映）** act as an
Apple-device mirroring receiver on Windows. It is distributed separately from the main
application for licensing reasons: this repository carries the third-party GPL/LGPL
components, while the main application remains proprietary.

## Why this is separate

The AirPlay receiver is implemented as an external process:

- **UxPlay 1.73.6** (GPL-3.0-only) performs Apple's mirroring protocol negotiation,
  decryption and RTP output. It runs as an independent process and is never linked into
  the Panecast application.
- **GStreamer 1.28.5-1 UCRT64** (LGPL-2.1-or-later, plus a GPL `gst-libav` plugin)
  supplies the RTP payloaders and UDP sink used by UxPlay.
- **`dnssd.dll`** (`dnssd-compat/`, MIT) is a small DNS-SD compatibility layer built on
  `mdns-sd`; it replaces Apple's Bonjour SDK so no machine-wide Bonjour service or
  Apple SDK is required.

Because the combined runtime is GPL, it is published from this public repository and
downloaded by the user on demand. The main application never bundles it.

## Layout

- `dnssd-compat/` — MIT-licensed Rust crate that builds `dnssd.dll`.
- `patches/` — the reviewed UxPlay build patch (`uxplay-1.73.6-windows-dnssd-runtime.patch`).
- `scripts/bootstrap-toolchain.sh` — installs the pinned MSYS2 UCRT64 build toolchain.
- `scripts/build-runtime.ps1` — builds UxPlay, `dnssd.dll` and stages the runtime tree.
- `scripts/package-release.ps1` — records the per-file SBOM and licenses, then packages
  the release archive.
- `docs/BUILD.zh-CN.md` — reproducible build notes.

## Building

See `docs/BUILD.zh-CN.md`. The runtime is only supported on Windows with MSYS2 UCRT64.

## Licenses

- `LICENSE` — GNU General Public License v3 (UxPlay and the GPL build of the runtime).
- `dnssd-compat/LICENSE` — MIT (the DNS-SD compatibility layer).
- GStreamer and its dependencies are LGPL/GPL; their license texts and the per-package
  list are recorded into the release archive by `package-release.ps1`.

"Apple", "AirPlay" and related marks belong to their owners. This project only describes
itself as an Apple-device mirroring compatible receiver and makes no claim of Apple
certification or endorsement.
