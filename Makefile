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
#   make test-profile   check the MLP1 default pad profile
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

.PHONY: all standalone verify-standalone package-mlp1 dist-pakrat dist-source validate test-wrapper test-profile check clean distclean help

all: dist-pakrat

help:
	@sed -n '1,16p' $(lastword $(MAKEFILE_LIST))

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

dist-pakrat: package-mlp1
	@mkdir -p "$(DIST)"
	@rm -f "$(ARTIFACT)"
	@cd "$(BUILD)/package" && zip -q -r -X "$(ARTIFACT)" "DSperate.pak"
	@python3 -c "import hashlib,sys;p=sys.argv[1];print('sha256', hashlib.sha256(open(p,'rb').read()).hexdigest())" "$(ARTIFACT)"
	@echo "wrote $(ARTIFACT)"

# GPL corresponding source for the exact binary this repo ships. Publish the
# archive next to the artifact; a written offer is weaker than the source.
dist-source:
	@mkdir -p "$(DIST)"
	@[ -d "$(BUILD)/dsperate-src/.git" ] || { \
		echo "no source clone yet; run 'make standalone' first" >&2; exit 1; }
	@tar -czf "$(DIST)/dsperate-corresponding-source.tar.gz" \
		-C "$(BUILD)" \
		--exclude='dsperate-src/.git' \
		dsperate-src
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

test-profile:
	@sh "$(REPO_ROOT)/tests/test-profile.sh"

check: validate test-wrapper test-profile package-mlp1
	@python3 "$(REPO_ROOT)/scripts/validate-pak.py" \
		--contract "$(CONTRACT_DIR)" --pak "$(PACKAGE)" --packaged

clean:
	@rm -rf "$(BUILD)/package" "$(BUILD)/dist" "$(BUILD)/contract"

distclean:
	@rm -rf "$(BUILD)"
