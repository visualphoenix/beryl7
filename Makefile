# Reproducible OpenWRT build for the GL-MT3600BE (Beryl 7) router "blackhole".
#
# SOURCE OF TRUTH (host-resident, version-controllable):
#   Dockerfile         build-container definition
#   extra-cas/*.pem    optional corp Root CAs (injected so apk/git work through
#                      an HTTPS MITM proxy); empty dir is fine if not behind one
#   openwrt.rev        pinned commit of github.com/openwrt/openwrt
#   config.seed        our .config (target = mediatek/filogic, GL-MT3600BE, +LuCI/etc.)
#   patches/<pkg>/*.patch
#                      our overrides on top of upstream openwrt; presently:
#                        patches/mt76/100-mt7996-mt7990-host-fill-txd.patch
#                        (bypasses broken connac3 SDO TX path on MT7990)
#
# DERIVATIVE (lives in podman named volume `openwrt-build`):
#   /workdir/.config, /workdir/<openwrt-tree>, /workdir/build_dir, etc.
#   Any volume can be blown away and rebuilt from the host fs above via
#   `make seed-volume`.
#
# WHY a named volume (not a bind mount): the macOS bind mount is virtiofs over
# case-INSENSITIVE APFS, which broke (1) bash heredoc temp files in $TMPDIR
# (autoconf config.status, first hit tools/m4) and (2) ncurses terminfo a/A
# dir collisions. A named volume is native XFS = case-sensitive and off
# virtiofs, fixing both.
#
# WORKFLOW:
#   First-time setup (or after losing the volume):
#       make seed-volume   # bootstrap empty volume from host overlay (~10-15 min)
#       make build         # full world build (~1-2 h cold, faster on subsequent)
#   Daily iteration:
#       edit patches/mt76/...patch     (or add new ones under patches/<pkg>/)
#       make build                     # sync-overlay runs first, then world
#   Edited menuconfig in the volume?
#       make export-config             # save volume:.config back to host:config.seed
#   Pull firmware out of volume to host:
#       make copy-out                  # firmware lands in ./firmware/bin/targets/...

VOL          := openwrt-build
OPENWRT_REPO := https://github.com/openwrt/openwrt.git
OPENWRT_REV  := $(shell cat openwrt.rev 2>/dev/null)
JOBS         := 4

DOCKER      := docker run --rm --user "$$(id -u):$$(id -g)" -v $(VOL):/workdir -w /workdir openwrt:build
DOCKER_IT   := docker run --rm -it --user "$$(id -u):$$(id -g)" -v $(VOL):/workdir -w /workdir openwrt:build
# Read-only host bind mount at /host for sync-overlay etc.
DOCKER_HOST := docker run --rm --user "$$(id -u):$$(id -g)" -v $(VOL):/workdir -v $(CURDIR):/host:ro -w /workdir openwrt:build

.PHONY: image volume seed-volume sync-overlay export-config reseed \
        shell menuconfig download build build-quiet firmware copy-out push \
        mt76-rebuild mt76-patch diffconfig clean-firmware

# ---- reproducibility: image + seed + overlay -------------------------------

# Build the build container image (debian:bookworm-slim + optional extra-cas + toolchain)
image:
	docker build --rm --tag openwrt:build .

# Idempotently create the named volume
volume:
	@docker volume inspect $(VOL) >/dev/null 2>&1 || docker volume create $(VOL)

# One-shot bootstrap: empty-or-fresh volume -> ready-to-build openwrt tree at our pin
seed-volume: image volume
	@test -n "$(OPENWRT_REV)" || (echo "ERROR: openwrt.rev is empty"; exit 1)
	@echo "==> Cloning $(OPENWRT_REPO) @ $(OPENWRT_REV) into volume"
	$(DOCKER_HOST) bash -c '\
	  if [ -d /workdir/.git ]; then \
	    echo "  /workdir already initialized; skipping clone"; \
	  else \
	    cd /tmp && rm -rf owrt && git clone $(OPENWRT_REPO) owrt && \
	    git -C owrt checkout $(OPENWRT_REV) && \
	    cp -a owrt/. /workdir/ && rm -rf owrt; \
	  fi'
	@echo "==> Applying host overlay (config + patches)"
	$(MAKE) sync-overlay
	@echo "==> feeds update + install"
	$(DOCKER) bash -c './scripts/feeds update -a && ./scripts/feeds install -a'
	@echo "==> Seeded. Run: make build"

# Push host overlay into volume. Idempotent. Run automatically before each build.
# Copies host:config.seed -> volume:.config and host:patches/<pkg>/*.patch -> volume:package/kernel/<pkg>/patches/
sync-overlay:
	@test -f config.seed || (echo "ERROR: host config.seed missing"; exit 1)
	$(DOCKER_HOST) bash -c '\
	  set -e; \
	  cp /host/config.seed /workdir/.config; \
	  for d in /host/patches/*/; do \
	    [ -d "$$d" ] || continue; \
	    pkg=$$(basename $$d); \
	    dst=/workdir/package/kernel/$$pkg/patches; \
	    if [ -d "$$dst" ]; then \
	      for p in $$d*.patch; do [ -f "$$p" ] && cp -v "$$p" "$$dst/"; done; \
	    else \
	      echo "  warn: no $$dst (pkg $$pkg not found in tree); skipping"; \
	    fi; \
	  done'

# Save volume:.config back to host:config.seed (after running menuconfig)
export-config:
	docker run --rm --user "$$(id -u):$$(id -g)" -v $(VOL):/workdir -v $(CURDIR):/out openwrt:build \
	  cp /workdir/.config /out/config.seed
	@echo "Saved volume:.config -> host:config.seed"

# Nuclear: blow away volume and reseed from host overlay.
reseed:
	@printf "Destroy volume '%s' and reseed from host? [y/N] " "$(VOL)"; \
	  read ans; [ "$$ans" = "y" ] || { echo aborted; exit 1; }
	docker volume rm $(VOL) || true
	$(MAKE) seed-volume

# ---- daily build commands --------------------------------------------------

shell:
	$(DOCKER_IT) bash

menuconfig:
	$(DOCKER_IT) make menuconfig

download: sync-overlay
	$(DOCKER) make -j$(JOBS) download

build: sync-overlay
	set -o pipefail; $(DOCKER) make -j$(JOBS) world V=s 2>&1 | tee build.log

build-quiet: sync-overlay
	$(DOCKER) make -j$(JOBS) world

# Recompile just the mt76 driver (fast iteration ~1-2 min)
mt76-rebuild: sync-overlay
	$(DOCKER) make package/kernel/mt76/{clean,compile} -j$(JOBS) V=s

# List firmware images inside the volume
firmware:
	@$(DOCKER) bash -c "ls -la bin/targets/mediatek/filogic/*gl-mt3600be* 2>/dev/null" || echo "No firmware built yet"

# Pull bin/targets out of the volume onto the host for flashing
copy-out:
	@mkdir -p firmware
	$(DOCKER) bash -c "tar cf - bin/targets 2>/dev/null" | tar xf - -C firmware
	@echo "Extracted to ./firmware/bin/targets/"
	@ls -la firmware/bin/targets/mediatek/filogic/*gl-mt3600be* 2>/dev/null || true

# Generic: push a host file to a path in the volume
push:
	@test -n "$(FILE)" || (echo "Usage: make push FILE=localpath DEST=pathInVolume" && exit 1)
	$(DOCKER_HOST) cp /host/$(FILE) /workdir/$(DEST)
	@echo "Pushed $(FILE) -> volume:/workdir/$(DEST)"

# Quilt-import a host patch file directly to the live mt76 source (ad hoc)
# For permanent patches, drop them in patches/mt76/ and rely on sync-overlay.
mt76-patch:
	@test -n "$(PATCH)" || (echo "Usage: make mt76-patch PATCH=path/to/fix.patch" && exit 1)
	$(DOCKER_HOST) bash -c "cd package/kernel/mt76 && quilt import /host/$(PATCH) && quilt push"

diffconfig:
	$(DOCKER) bash -c "./scripts/diffconfig.sh > /workdir/diffconfig.txt"
	$(DOCKER) bash -c "cat /workdir/diffconfig.txt" > diffconfig.txt
	@echo "Saved to diffconfig.txt"

clean-firmware:
	rm -rf firmware/bin
