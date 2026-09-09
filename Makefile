.PHONY: help build build-debug build-release test test-suite clean clean-build release

help:
	@echo "Available targets:"
	@echo "  make build          - Build the project (debug)"
	@echo "  make build-debug    - Build debug version"
	@echo "  make build-release  - Build optimized release"
	@echo "  make test           - Run all tests (eunit + Common Test)"
	@echo "  make test-suite     - Run Common Test suite only"
	@echo "  make release        - Create release package"
	@echo "  make clean          - Clean all build artifacts"
	@echo "  make clean-build    - Clean only rebar3 and cargo artifacts"
	@echo "  make help           - Show this help message"

build:
	rebar3 compile

build-debug: build

build-release:
	rebar3 as prod compile

test:
	rebar3 test

test-suite:
	rebar3 ct

release:
	rebar3 as prod release

clean:
	rebar3 clean
	rm -rf _build
	cd native_gliner_worker && cargo clean || true

clean-build:
	rebar3 clean
	cd native_gliner_worker && cargo clean || true
