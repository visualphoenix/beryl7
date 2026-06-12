# OpenWRT build for the GL-MT3600BE (Beryl 7)

This repo builds a custom OpenWRT firmware for the GL-MT3600BE
(`mediatek/filogic`). It pins a specific upstream commit, carries a saved kernel
and package config, and applies a small driver patch — so the same firmware
comes out every time. The build itself runs in a Docker container; all you need
on the host is Docker.

## Why

The Beryl 7's MT7990 radio has an upstream bug: TX speeds are unstable and
collapse under load (download throughput dropping from ~833 to ~92 Mbit/s). It's
described in [this GL.iNet forum thread][bug]. Stock firmware doesn't fix it, so
this build patches the `mt76` driver to work around the broken connac3 TX path
and produces a firmware that holds full speed.

The patch is a variant of the one [kyoto44 posted on openwrt/mt76 #1043][patch].
Their version forces the host to fill the TXWI for every chip; ours scopes that
to the MT7990 only (`is_mt7990()`), leaving the SDO path untouched on MT7996 and
MT7992. See `patches/mt76/100-mt7996-mt7990-host-fill-txd.patch`.

[bug]: https://forum.gl-inet.com/t/beryl-7-gl-mt3600be-tx-speeds-unstable/67283
[patch]: https://github.com/openwrt/mt76/issues/1043#issuecomment-4414905981

## How it works

The OpenWRT source tree and everything the build produces live in a Docker named
volume called `openwrt-build`, not on your disk. Think of that volume as a cache:
it's disposable, and you can recreate it from this repo whenever you want.

This repo holds the parts that actually matter — the inputs that determine the
firmware:

- **`openwrt.rev`** — one line, the upstream `openwrt/openwrt` commit the build
  is pinned to. Bump it to move to a newer OpenWRT.
- **`config.seed`** — the OpenWRT `.config`, saved from `menuconfig`. It picks
  the target, the GL-MT3600BE profile, LuCI, and the package set.
- **`patches/`** — patches applied on top of upstream, one folder per package.
  Right now there's a single `mt76` patch that works around the broken connac3
  TX path on the MT7990 radio.
- **`Dockerfile`** — the build environment: Debian plus the OpenWRT toolchain.
- **`Makefile`** — how you drive all of it; every command below is a target.
- **`extra-cas/`** — optional, for corporate proxies (see the bottom).

Build output (`firmware/`, `build.log`) is generated locally and gitignored.

## Getting started

You need Docker, about 10 GB of disk, and an hour or two for the first build.

Bootstrap the volume, build the world, and pull the firmware out:

```sh
make seed-volume   # build image, create volume, clone OpenWRT at the pin
make build         # compile everything (slow the first time, cached after)
make copy-out      # firmware lands in ./firmware/bin/targets/mediatek/filogic/
```

Flash the image from that last directory. You only run `seed-volume` once; after
that, `make build` is the everyday command.

## The everyday loop

`make build` syncs your `config.seed` and `patches/` into the volume and then
compiles. When you're iterating on the mt76 patch, skip the full build and
recompile just the driver with `make mt76-rebuild` — it's a minute or two
instead of an hour.

To change the config, edit it interactively with `make menuconfig`, then run
`make export-config` to write your changes back to `config.seed` so they're
committed and reproducible. (Editing in the container alone doesn't persist —
the volume is disposable, remember.)

A few more targets you'll reach for occasionally:

- `make shell` — a bash prompt inside the build container.
- `make download` — pre-fetch package sources without compiling.
- `make firmware` — list the images already built in the volume.
- `make reseed` — throw the volume away and bootstrap it fresh.
- `make diffconfig` — write a minimal config diff to `diffconfig.txt`.

## Behind a HTTPS proxy

If your network intercepts TLS, `git` and downloads inside the container will
fail to verify certificates. Export the proxy's root CA into `extra-cas/` and
rebuild the image:

```sh
/usr/bin/security find-certificate -c "<CA common name>" -p > extra-cas/corp-root-ca.pem
make image
```

Any `*.pem`/`*.crt` there gets trusted; the folder is empty by default and the
build works fine without it. Certs you drop in are gitignored.

## Why a named volume, not a bind mount

The build needs a case-sensitive filesystem. On macOS a host bind mount is
virtiofs over case-insensitive APFS, which breaks OpenWRT in subtle ways
(autoconf temp files, ncurses `a`/`A` collisions). A native named volume is
case-sensitive and sidesteps the whole problem.
