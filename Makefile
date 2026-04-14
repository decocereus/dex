#!/usr/bin/make -f

SHELL := /bin/bash
.DEFAULT_GOAL := all

# Prefer rustup-managed toolchain over Homebrew Rust for cross-compilation targets.
RUSTUP_TOOLCHAIN_BIN := $(shell rustup which cargo 2>/dev/null | xargs dirname 2>/dev/null)
CARGO_BIN := $(HOME)/.cargo/bin
ifneq ($(RUSTUP_TOOLCHAIN_BIN),)
  export PATH := $(RUSTUP_TOOLCHAIN_BIN):$(CARGO_BIN):$(PATH)
else ifneq ($(wildcard $(CARGO_BIN)),)
  export PATH := $(CARGO_BIN):$(PATH)
endif

ROOT := $(shell pwd)
STAMPS := $(ROOT)/.build-stamps
RUST_DIR := $(ROOT)/shared/rust-bridge
RUST_TARGET := $(RUST_DIR)/target
SUBMODULE_DIR := $(ROOT)/shared/third_party/codex
IOS_DIR := $(ROOT)/apps/ios
IOS_SCRIPTS := $(IOS_DIR)/scripts
IOS_FW_DIR := $(IOS_DIR)/Frameworks
IOS_GENERATED := $(IOS_DIR)/GeneratedRust
IOS_SOURCES := $(IOS_DIR)/Sources
GENERATED_DIR := $(RUST_DIR)/generated
PATCHES_DIR := $(ROOT)/patches/codex

IOS_DEPLOYMENT_TARGET ?= 18.0
IOS_SIM_DEVICE ?= iPhone 17 Pro
IOS_SCHEME ?= Litter
XCODE_CONFIG ?= Debug
CARGO_FEATURES ?=
IOS_RUN_ARTIFACTS_DIR ?= $(ROOT)/artifacts/ios-device-run
IOS_DEVICE_PROFILE ?= 0
IOS_DEVICE_PROFILE_TEMPLATE ?= Time Profiler
IOS_DEVICE_PROFILE_TIME_LIMIT ?=
IOS_SIM_RUN_ARTIFACTS_DIR ?= $(ROOT)/artifacts/ios-sim-run
IOS_SIM_PROFILE ?= 1
IOS_SIM_PROFILE_TEMPLATE ?= Time Profiler
IOS_SIM_PROFILE_TIME_LIMIT ?=

# Source local env (credentials, overrides) if present.
-include .env

AWS_SHARED_CREDENTIALS_FILE ?= $(HOME)/.aws/credentials

define aws_profile_credential
$(strip $(shell PROFILE='$(AWS_PROFILE)' CREDS_FILE='$(AWS_SHARED_CREDENTIALS_FILE)' KEY='$(1)' /bin/bash -lc '\
if [ -n "$$PROFILE" ] && [ -f "$$CREDS_FILE" ]; then \
  awk -F" *= *" -v profile="$$PROFILE" -v key="$$KEY" '\''
    $$0 == "[" profile "]" { in_profile = 1; next } \
    /^\[/ { in_profile = 0 } \
    in_profile && $$1 == key { print $$2; exit }\
  '\'' "$$CREDS_FILE"; \
fi'))
endef

SCCACHE := $(shell command -v sccache 2>/dev/null)
ifneq ($(SCCACHE),)
  ifeq ($(strip $(AWS_ACCESS_KEY_ID)),)
    AWS_ACCESS_KEY_ID := $(call aws_profile_credential,aws_access_key_id)
  endif
  ifeq ($(strip $(AWS_SECRET_ACCESS_KEY)),)
    AWS_SECRET_ACCESS_KEY := $(call aws_profile_credential,aws_secret_access_key)
  endif
  ifeq ($(strip $(AWS_SESSION_TOKEN)),)
    AWS_SESSION_TOKEN := $(call aws_profile_credential,aws_session_token)
  endif
  export RUSTC_WRAPPER := $(SCCACHE)
  ifdef SCCACHE_BUCKET
    export SCCACHE_BUCKET
    export SCCACHE_ENDPOINT
    export SCCACHE_REGION
    export SCCACHE_S3_KEY_PREFIX
    ifneq ($(strip $(AWS_ACCESS_KEY_ID)),)
      export AWS_ACCESS_KEY_ID
    endif
    ifneq ($(strip $(AWS_SECRET_ACCESS_KEY)),)
      export AWS_SECRET_ACCESS_KEY
    endif
    ifneq ($(strip $(AWS_SESSION_TOKEN)),)
      export AWS_SESSION_TOKEN
    endif
    $(info [cache] Using sccache: $(SCCACHE) → s3://$(SCCACHE_BUCKET))
  else
    $(info [cache] Using sccache: $(SCCACHE) (local only))
  endif
endif

PACKAGE_CARGO_ENV := CARGO_INCREMENTAL=0
DEV_CARGO_ENV := env -u CARGO_INCREMENTAL

PATCH_FILES := \
	$(PATCHES_DIR)/ios-exec-hook.patch \
	$(PATCHES_DIR)/client-controlled-handoff.patch \
	$(PATCHES_DIR)/mobile-code-mode-stub.patch \
	$(PATCHES_DIR)/thread-read-permissions.patch

BOUNDARY_SOURCES := \
	$(RUST_DIR)/codex-mobile-client/Cargo.toml \
	$(RUST_DIR)/codex-mobile-client/src/lib.rs \
	$(RUST_DIR)/codex-mobile-client/src/conversation_uniffi.rs \
	$(RUST_DIR)/codex-mobile-client/src/discovery_uniffi.rs

BOUNDARY_SOURCES += $(shell find $(RUST_DIR)/codex-mobile-client/src -type f -name '*.rs' 2>/dev/null)

STAMP_SYNC := $(STAMPS)/sync
STAMP_BINDINGS_S := $(STAMPS)/bindings-swift
STAMP_IOS_SYSTEM := $(STAMPS)/ios-system-frameworks
STAMP_XCGEN := $(STAMPS)/xcgen

$(shell mkdir -p $(STAMPS))

.PHONY: all help \
	ios ios-sim ios-sim-fast ios-sim-run ios-device ios-device-fast ios-device-run ios-run \
	ios-dex-companion ios-dex-companion-device \
	ios-build ios-build-sim ios-build-sim-fast ios-build-device ios-build-device-fast verify-ios-project \
	rust-ios rust-ios-package rust-ios-device-release rust-ios-device-fast rust-ios-sim-fast rust-check rust-test rust-host-dev \
	bindings bindings-swift sync patch unpatch xcgen ios-frameworks ios-local-setup \
	test test-rust test-ios testflight appstore-release ios-release-prep \
	clean clean-rust clean-ios rebuild-bindings screenshots screenshots-ios \
	tui tui-run export-fixture export-fixture-run

all: ios

ios-build-sim: rust-ios-package ios-frameworks xcgen
ios-build-device: rust-ios-package ios-frameworks xcgen
ios-build-sim-fast: rust-ios-sim-fast ios-frameworks xcgen
ios-build-device-fast: rust-ios-device-fast ios-frameworks xcgen

ios: ios-build-sim
ios-sim: ios-build-sim
ios-sim-fast: ios-build-sim-fast
ios-device: ios-build-device
ios-device-fast: ios-build-device-fast

ios-sim-run: ios-sim-fast
	@echo "==> Installing and launching on booted simulator with saved logs/profile..."
	@cd $(ROOT) && \
	IOS_SIM_PROFILE='$(IOS_SIM_PROFILE)' \
	IOS_SIM_PROFILE_TEMPLATE='$(IOS_SIM_PROFILE_TEMPLATE)' \
	IOS_SIM_PROFILE_TIME_LIMIT='$(IOS_SIM_PROFILE_TIME_LIMIT)' \
	IOS_SIM_RUN_ARTIFACTS_DIR='$(IOS_SIM_RUN_ARTIFACTS_DIR)' \
	$(IOS_SCRIPTS)/run-sim.sh

ios-device-run: ios-device-fast
	@echo "==> Installing and launching on connected device with saved logs/profile..."
	@cd $(ROOT) && \
	IOS_DEVICE_PROFILE='$(IOS_DEVICE_PROFILE)' \
	IOS_DEVICE_PROFILE_TEMPLATE='$(IOS_DEVICE_PROFILE_TEMPLATE)' \
	IOS_DEVICE_PROFILE_TIME_LIMIT='$(IOS_DEVICE_PROFILE_TIME_LIMIT)' \
	IOS_RUN_ARTIFACTS_DIR='$(IOS_RUN_ARTIFACTS_DIR)' \
	$(IOS_SCRIPTS)/run-device.sh

ios-run: ios
	@open $(IOS_DIR)/Litter.xcodeproj

ios-dex-companion: xcgen
	@echo "==> Building DexCompanion ($(XCODE_CONFIG), simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme DexCompanion \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		build

ios-dex-companion-device: xcgen
	@echo "==> Building DexCompanion ($(XCODE_CONFIG), device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme DexCompanion \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		build

rust-ios: rust-ios-package

rust-ios-package: $(STAMP_SYNC)
	@echo "==> Packaging Rust for iOS (device + simulator + xcframework)..."
	@cd $(ROOT) && $(PACKAGE_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current $(CARGO_FEATURES)

rust-ios-device-release: $(STAMP_SYNC)
	@echo "==> Building Rust for iOS release archive prep (device staticlib + headers)..."
	@cd $(ROOT) && $(PACKAGE_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --device-only $(CARGO_FEATURES)

rust-ios-device-fast: $(STAMP_SYNC)
	@echo "==> Building Rust for fast iOS device iteration (raw staticlib + headers)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-device $(CARGO_FEATURES)

rust-ios-sim-fast: $(STAMP_SYNC)
	@echo "==> Building Rust for fast iOS simulator iteration (raw staticlib + headers)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-sim $(CARGO_FEATURES)

rust-check:
	@echo "==> cargo check (host, shared crates)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo check --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client -p codex-ios-audio

rust-test:
	@echo "==> cargo test (host, shared crates)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo test --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client --lib

rust-host-dev: rust-check rust-test

help:
	@printf '%s\n' \
		'make ios-local-setup     configure local bundle IDs + team ID for this machine' \
		'make ios                 full iOS package lane + simulator build' \
		'make ios-sim-fast        fast simulator lane using raw staticlib outputs' \
		'make ios-sim-run         fast sim build + install + launch on booted simulator; saves logs/profile under artifacts/ios-sim-run' \
		'make ios-device          full iOS package lane + device build' \
		'make ios-device-fast     fast device lane using raw staticlib outputs' \
		'make ios-device-run      fast device build + install + launch on connected device; saves logs/profile under artifacts/ios-device-run' \
		'make ios-dex-companion   build the additive DexCompanion target for the simulator' \
		'make ios-dex-companion-device build the additive DexCompanion target for a generic iOS device' \
		'make rust-ios-package    full Rust iOS package lane (bindings + xcframework)' \
		'make rust-ios-sim-fast   fast Rust iOS simulator lane (raw staticlib only)' \
		'make rust-ios-device-fast fast Rust iOS device lane (raw staticlib only)' \
		'make rust-check          host cargo check for shared crates' \
		'make rust-test           host cargo test for shared crates' \
		'make test                run Rust + iOS tests'

ios-local-setup:
	@./tools/scripts/setup-ios-local.sh

sync: $(STAMP_SYNC)
$(STAMP_SYNC):
	@echo "==> Syncing codex submodule..."
	@$(IOS_SCRIPTS)/sync-codex.sh --preserve-current
	@touch $@

patch: $(STAMP_SYNC)
	@echo "==> Verifying codex patch set..."
	@$(IOS_SCRIPTS)/sync-codex.sh --preserve-current

unpatch:
	@echo "==> Reverting codex patches..."
	@for pf in $(PATCH_FILES); do \
		if git -C $(SUBMODULE_DIR) apply --reverse --check "$$pf" >/dev/null 2>&1; then \
			git -C $(SUBMODULE_DIR) apply --reverse "$$pf"; \
		fi; \
	done
	@rm -f $(STAMP_SYNC)

bindings: bindings-swift

bindings-swift: $(STAMP_BINDINGS_S)
$(STAMP_BINDINGS_S): $(STAMP_SYNC) $(BOUNDARY_SOURCES)
	@echo "==> Generating Swift bindings..."
	@cd $(RUST_DIR) && ./generate-bindings.sh --swift-only
	@mkdir -p $(IOS_GENERATED)/Headers
	@cp $(GENERATED_DIR)/swift/codex_mobile_client.swift $(IOS_SOURCES)/Litter/Bridge/UniFFICodexClient.generated.swift
	@cp $(GENERATED_DIR)/swift/codex_mobile_clientFFI.h $(IOS_GENERATED)/Headers/codex_mobile_clientFFI.h
	@cp $(GENERATED_DIR)/swift/codex_mobile_clientFFI.modulemap $(IOS_GENERATED)/Headers/codex_mobile_clientFFI.modulemap
	@cp $(GENERATED_DIR)/swift/module.modulemap $(IOS_GENERATED)/Headers/module.modulemap
	@touch $@

ios-frameworks: $(STAMP_IOS_SYSTEM)
$(STAMP_IOS_SYSTEM):
	@echo "==> Downloading ios_system frameworks..."
	@$(IOS_SCRIPTS)/download-ios-system.sh
	@touch $@

xcgen: $(STAMP_XCGEN)
$(STAMP_XCGEN): $(IOS_DIR)/project.yml
	@echo "==> Regenerating Xcode project..."
	@$(IOS_SCRIPTS)/regenerate-project.sh
	@touch $@

verify-ios-project:
	@$(IOS_SCRIPTS)/regenerate-project.sh --repair-only

ios-build-sim: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		build

ios-build-sim-fast: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), fast simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		build

ios-build-device: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		build

ios-build-device-fast: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), fast device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		-allowProvisioningUpdates \
		build

ios-build: ios-build-sim

test: test-rust test-ios

test-rust:
	@echo "==> Running Rust tests..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo test --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client --lib

test-ios: xcgen
	@echo "==> Running iOS tests..."
	@xcodebuild test -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)'

ios-release-prep: rust-ios-device-release ios-frameworks xcgen

testflight: ios-release-prep
	@echo "==> Uploading to TestFlight..."
	@$(IOS_SCRIPTS)/testflight-upload.sh

appstore-release: ios-release-prep
	@echo "==> Submitting current repo version to the App Store..."
	@$(IOS_SCRIPTS)/app-store-release.sh

clean: clean-rust clean-ios
	@rm -rf $(STAMPS)
	@echo "==> Clean complete"

clean-rust:
	@echo "==> Cleaning Rust build artifacts..."
	@rm -rf $(RUST_TARGET)

clean-ios:
	@echo "==> Cleaning iOS artifacts..."
	@rm -rf $(IOS_FW_DIR)/codex_mobile_client.xcframework $(IOS_GENERATED)
	@rm -f $(STAMP_IOS_SYSTEM) $(STAMP_XCGEN) $(STAMP_BINDINGS_S)

rebuild-bindings:
	@rm -f $(STAMP_BINDINGS_S)
	@$(MAKE) bindings

screenshots: screenshots-ios

screenshots-ios:
	@echo "── Capturing iOS screenshots ──"
	cd $(IOS_DIR) && bundle exec fastlane screenshots

tui:
	@echo "── Building codex-tui ──"
	cd shared/rust-bridge && cargo build -p codex-tui --release

tui-run:
	@echo "── Running codex-tui ──"
	cd shared/rust-bridge && cargo run -p codex-tui --release

export-fixture:
	@echo "── Building export-fixture ──"
	cd shared/rust-bridge && cargo build -p codex-tui --bin export-fixture --release

export-fixture-run:
	@cd shared/rust-bridge && cargo run -p codex-tui --bin export-fixture --release -- $(ARGS)
