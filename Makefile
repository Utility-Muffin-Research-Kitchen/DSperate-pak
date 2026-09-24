# DSperate content pak for Leaf.
#
# A clean clone of this repository plus Docker, make and python3 is the whole
# toolchain. Nothing here reaches outside the repository: no sibling checkouts,
# no UMRK workspace layout, no locally built images. If a target of yours needs
# a path starting with ../, it does not belong in this file.
#
#   make standalone     build the pinned DSperate binary (long; cached)
#   make package-mlp1   assemble build/package/DSperate.pak
#   make dist-pakrat    zip it into build/dist/DSperate.mlp1.pak.zip
#   make dist-source    GPL corresponding-source archive for the shipped binary
#   make validate       check pak.json against the content-pak contract
#   make test-wrapper   check the launch wrapper (no build needed)
#   make test-profile   check the MLP1 default pad (controller) profile
#   make test-pgo       check the locked PGO profile and the strict build gate
#   make test-lock      check pak.json, the lock and the patches agree
#   make test-docs      check README and PROVENANCE quote the locked build
#   make test-archive-cli  run the archive CLI checks against the built binary
#   make test-version   --version from the git build and from the source tar
#   make test-archives  build both archives twice and compare their bytes
#   make check          validate + tests + package + validate the packaged tree
#   make clean          remove build/ outputs (keeps the cached source and build)
#   make distclean      remove build/ entirely, including the source clone

SHELL := /bin/bash
REPO_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD ?= $(REPO_ROOT)/build
PACKAGE := $(BUILD)/package/DSperate.pak
DIST := $(BUILD)/dist
ARTIFACT := $(DIST)/DSperate.mlp1.pak.zip

# The contract this pak is validated against: content-paks-v1, its schema, and
# its reference validator. It lives in `leaf-contracts`, which is public
# precisely so that a contract a third party is judged against is one they can
# read. CI pins a SHA; a local clone is fine for development.
CONTRACT_REPO ?= https://github.com/Utility-Muffin-Research-Kitchen/leaf-contracts.git
CONTRACT_REF ?= 699ce2dbced68c8f2529c3a5ffc51dda106e2df7
CONTRACT_DIR ?= $(BUILD)/contract

LOCK := $(REPO_ROOT)/standalone/upstream.lock.json
lock_get = $(shell python3 -c 'import functools,json,sys;print(functools.reduce(lambda v,k:v[int(k)] if isinstance(v,list) else v[k],sys.argv[2:],json.load(open(sys.argv[1]))))' "$(LOCK)" $(1))
# The archives are written inside the digest-pinned toolchain image: its Python
# and zlib are fixed, so the compressed bytes are the same on every machine.
IMAGE_REF = $(firstword $(subst :, ,$(call lock_get,toolchain image)))@$(call lock_get,toolchain digest)
SOURCE_EPOCH = $(call lock_get,build source_date_epoch)
SOURCE_ARCHIVE := $(DIST)/dsperate-corresponding-source.tar.gz
IN_IMAGE = docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp \
	-v "$(REPO_ROOT)":"$(REPO_ROOT)":ro -v "$(BUILD)":"$(BUILD)" -w "$(REPO_ROOT)" \
	"$(IMAGE_REF)"

.PHONY: all standalone verify-standalone package-mlp1 dist-pakrat dist-source validate test-wrapper test-profile test-pgo test-lock test-docs test-archive-cli test-version test-archives check clean distclean help

all: dist-pakrat

help:
	@sed -n '1,22p' $(lastword $(MAKEFILE_LIST))

standalone:
	@"$(REPO_ROOT)/standalone/build-dsperate.sh"

verify-standalone:
	@FORCE=0 "$(REPO_ROOT)/standalone/build-dsperate.sh"

# A pure content pak carrying a standalone executable. The manifest declares
# the wrapper as its `type: "path"` core; the compiled binary, its first-run
# defaults and the licence notice ship beside it. No launch.sh, no Apps entry.
package-mlp1: standalone
	@rm -rf "$(PACKAGE)"
	@mkdir -p "$(PACKAGE)/scripts" "$(PACKAGE)/bin" "$(PACKAGE)/defaults" "$(PACKAGE)/art" "$(PACKAGE)/res"
	@cp "$(REPO_ROOT)/pak/pak.json" "$(PACKAGE)/pak.json"
	@cp "$(REPO_ROOT)/pak/art/"* "$(PACKAGE)/art/"
	@cp "$(REPO_ROOT)/pak/res/icon.png" "$(PACKAGE)/res/icon.png"
	@cp "$(REPO_ROOT)/pak/scripts/run.sh" "$(PACKAGE)/scripts/run.sh"
	@cp "$(REPO_ROOT)/pak/defaults/dsperate.ini" "$(PACKAGE)/defaults/dsperate.ini"
	@cp "$(REPO_ROOT)/pak/defaults/config.version" "$(PACKAGE)/defaults/config.version"
	@cp "$(BUILD)/standalone/dsperate" "$(PACKAGE)/bin/dsperate"
	@cp "$(BUILD)/standalone/dsperate-notice" "$(PACKAGE)/bin/dsperate-notice"
	@chmod 755 "$(PACKAGE)/scripts/run.sh" "$(PACKAGE)/bin/dsperate" "$(PACKAGE)/bin/dsperate-notice"
	@cp "$(REPO_ROOT)/LICENSES/DSPERATE-LICENSE.txt" "$(PACKAGE)/LICENSE-DSPERATE.txt"
	@cp "$(REPO_ROOT)/LICENSES/REPO-LICENSE.txt" "$(PACKAGE)/LICENSE-REPO.txt"
	@for notice in src/core/bios/LICENSE.freebios src/core/cart/miniz/LICENSE \
		src/cheevos/rcheevos/LICENSE src/net/enet/LICENSE src/net/slirp/LICENSE \
		src/net/slirp/COPYRIGHT src/core/io/dsi_font/LICENSE-NotoSans-OFL-1.1.txt \
		src/core/io/dsi_font/LICENSE-WenQuanYi-MicroHei.txt; do \
		printf '\n=== %s ===\n\n' "$$notice"; \
		cat "$(BUILD)/dsperate-src/$$notice" || exit 1; \
	 done > "$(PACKAGE)/LICENSE-THIRD-PARTY.txt"
	@echo "packaged $(PACKAGE)"
	@echo "note: no launch.sh -- this is a pure content pak and is not listed in Apps."

# Byte-deterministic: sorted entries, SOURCE_DATE_EPOCH mtimes, fixed modes, no
# extra fields. See scripts/make-archive.py; `make test-archives` proves it.
dist-pakrat: package-mlp1
	@mkdir -p "$(DIST)"
	@rm -f "$(ARTIFACT)"
	@$(IN_IMAGE) python3 "$(REPO_ROOT)/scripts/make-archive.py" zip \
		--epoch "$(SOURCE_EPOCH)" --out "$(ARTIFACT)" --root "$(BUILD)/package" DSperate.pak
	@python3 -c "import hashlib,sys;p=sys.argv[1];print('sha256', hashlib.sha256(open(p,'rb').read()).hexdigest())" "$(ARTIFACT)"
	@echo "wrote $(ARTIFACT)"

# GPL corresponding source for the exact binary this repo ships. Publish the
# archive next to the artifact; a written offer is weaker than the source.
dist-source:
	@mkdir -p "$(DIST)"
	@[ -d "$(BUILD)/dsperate-src/.git" ] || { \
		echo "no source clone yet; run 'make standalone' first" >&2; exit 1; }
	@rm -f "$(SOURCE_ARCHIVE)"
	@$(IN_IMAGE) python3 "$(REPO_ROOT)/scripts/make-archive.py" tar \
		--epoch "$(SOURCE_EPOCH)" --out "$(SOURCE_ARCHIVE)" \
		--member dsperate-src="$(BUILD)/dsperate-src" \
		--member standalone="$(REPO_ROOT)/standalone" \
		--member LICENSES="$(REPO_ROOT)/LICENSES" \
		--member Makefile="$(REPO_ROOT)/Makefile" \
		--member README.md="$(REPO_ROOT)/README.md" \
		--member pak="$(REPO_ROOT)/pak" \
		--member pakrat.json="$(REPO_ROOT)/pakrat.json" \
		--member scripts="$(REPO_ROOT)/scripts" \
		--member tests="$(REPO_ROOT)/tests"
	@python3 "$(REPO_ROOT)/tests/test-source-archive.py" "$(SOURCE_ARCHIVE)"
	@cp "$(REPO_ROOT)/standalone/upstream.lock.json" "$(DIST)/upstream.lock.json"
	@python3 -c "import hashlib,sys;p=sys.argv[1];print('sha256', hashlib.sha256(open(p,'rb').read()).hexdigest())" \
		"$(DIST)/dsperate-corresponding-source.tar.gz"
	@echo "wrote $(DIST)/dsperate-corresponding-source.tar.gz"

$(CONTRACT_DIR):
	@mkdir -p "$(BUILD)"
	@echo "fetching contract $(CONTRACT_REF) from $(CONTRACT_REPO)"
	@(git init -q "$(CONTRACT_DIR)" && \
	  git -C "$(CONTRACT_DIR)" fetch -q --depth 1 "$(CONTRACT_REPO)" "$(CONTRACT_REF)" && \
	  git -C "$(CONTRACT_DIR)" checkout -q --detach FETCH_HEAD) \
		|| (rm -rf "$(CONTRACT_DIR)"; \
		    echo ""; \
		    echo "could not fetch the content-pak contract." >&2; \
		    echo "" >&2; \
		    echo "  It lives in the public leaf-contracts repository. If you have" >&2; \
		    echo "  a local clone, point at it:" >&2; \
		    echo "" >&2; \
		    echo "      make validate CONTRACT_DIR=/path/to/leaf-contracts" >&2; \
		    echo "" >&2; \
		    echo "  Otherwise check your network. Every other target in this" >&2; \
		    echo "  repository is self-contained and still works offline:" >&2; \
		    echo "      make standalone / package-mlp1 / dist-pakrat / dist-source" >&2; \
		    echo "" >&2; \
		    exit 1)

validate: | $(CONTRACT_DIR)
	@python3 "$(REPO_ROOT)/scripts/validate-pak.py" \
		--contract "$(CONTRACT_DIR)" --pak "$(REPO_ROOT)/pak"

test-wrapper:
	@sh "$(REPO_ROOT)/tests/test-wrapper.sh"

# The MLP1 default *pad* profile (controls), not the PGO profile.
test-profile:
	@sh "$(REPO_ROOT)/tests/test-profile.sh"

# The locked PGO profile: directory sha256, file count, MANIFEST fingerprint,
# compiler, commit and scenes against the lock, and the strict build gate in
# build-in-container.sh. Needs no build, no Docker and no device. It does not
# measure performance; that is a device measurement.
test-pgo:
	@python3 "$(REPO_ROOT)/tests/test-pgo.py"

test-lock:
	@python3 "$(REPO_ROOT)/tests/test-lock.py"

test-docs:
	@python3 "$(REPO_ROOT)/tests/test-docs.py"

# The real executable, run in the pinned AArch64 image through the SDK loader.
test-archive-cli: standalone
	@$(IN_IMAGE) sh -c 'sysroot=/opt/mlp1-toolchain/aarch64-buildroot-linux-gnu/sysroot; \
		python3 "$(REPO_ROOT)/tests/test-archive-cli.py" "$$sysroot/lib/ld-linux-aarch64.so.1" \
		--library-path "$$sysroot/lib:$$sysroot/usr/lib" "$(BUILD)/standalone/dsperate"'

# --version from the git-checkout build, then a rebuild from the extracted
# corresponding-source archive, which must reproduce the locked binary too.
test-version: standalone dist-source
	@bash "$(REPO_ROOT)/tests/test-version.sh" "$(BUILD)" "$(IMAGE_REF)"

test-archives: package-mlp1
	@bash "$(REPO_ROOT)/tests/test-archives.sh" "$(BUILD)"

check: validate test-wrapper test-profile test-pgo test-lock test-docs package-mlp1 test-archive-cli
	@python3 "$(REPO_ROOT)/scripts/validate-pak.py" \
		--contract "$(CONTRACT_DIR)" --pak "$(PACKAGE)" --packaged

clean:
	@rm -rf "$(BUILD)/package" "$(BUILD)/dist" "$(BUILD)/contract"

distclean:
	@rm -rf "$(BUILD)"
