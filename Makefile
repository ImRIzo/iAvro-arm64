# Avro Keyboard — Apple Silicon, Command Line Tools only.
APP      := Avro Keyboard
USER_DIR := $(HOME)/Library/Input Methods
SYS_DIR  := /Library/Input Methods

.PHONY: all app install pkg dist check reference uninstall purge clean

all: app

app:        ## build build/Avro Keyboard.app
	@./scripts/build.sh

install:    ## build + install to ~/Library/Input Methods
	@./scripts/build.sh --install

pkg:        ## build + build/dist/AvroKeyboard-<ver>.pkg
	@./scripts/build.sh --pkg

dist:       ## build + .pkg, .zip, SHA256SUMS.txt (release assets)
	@./scripts/build.sh --dist

check:      ## compare new dictionary engine with the original regex scan + timings
	@./scripts/engine-check.sh

reference:  ## same comparison using the Python reference implementation
	@python3 tools/reference/check_equivalence.py .

uninstall:  ## remove the app from both Input Methods folders
	-@killall "$(APP)" 2>/dev/null || true
	rm -rf "$(USER_DIR)/$(APP).app"
	@if [ -d "$(SYS_DIR)/$(APP).app" ]; then sudo rm -rf "$(SYS_DIR)/$(APP).app"; fi

purge:      ## remove every copy, registration, receipt and cache (then log out)
	@./scripts/uninstall-all.sh

clean:
	rm -rf build
