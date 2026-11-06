FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
SWIFTFLAGS := -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(LIB)

.PHONY: build test fixtures app probe

build:
	swift build $(SWIFTFLAGS)

test:
	swift test $(SWIFTFLAGS)

probe:
	swift run $(SWIFTFLAGS) ljprobe

fixtures:
	swift run $(SWIFTFLAGS) ljprobe fixtures out/fixtures

app:
	scripts/make-app.sh
