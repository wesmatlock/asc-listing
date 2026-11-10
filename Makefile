BIN := $(HOME)/.local/bin

.PHONY: build test install uninstall

build:
	swift build -c release

test:
	swift test

install: build
	mkdir -p $(BIN)
	ln -sf "$(CURDIR)/.build/release/asc-listing" $(BIN)/asc-listing

uninstall:
	rm -f $(BIN)/asc-listing
