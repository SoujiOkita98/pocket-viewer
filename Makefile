CFLAGS = -O2 -Wall
IOKIT = -framework IOKit -framework CoreFoundation

all: pocketctl pocket-viewer plugins

SWIFTC = swiftc -O -parse-as-library
plugins: plugins/bin/face-follow plugins/bin/interpreter

plugins/bin/face-follow: plugins/swift/PocketViewer.swift plugins/swift/FaceFollow.swift
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ $^

plugins/bin/interpreter: plugins/swift/PocketViewer.swift plugins/swift/Interpreter.swift plugins/swift/Interpreter-Info.plist
	@mkdir -p plugins/bin
	$(SWIFTC) -o $@ plugins/swift/PocketViewer.swift plugins/swift/Interpreter.swift \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker plugins/swift/Interpreter-Info.plist

pocketctl: pocketctl.c gimbal.c gimbal.h
	clang $(CFLAGS) -o $@ pocketctl.c gimbal.c $(IOKIT)

pocket-viewer: pocket-viewer.m gimbal.c gimbal.h echocancel.m echocancel.h moviewriter.m moviewriter.h \
		plugins.m plugins.h Info.plist
	clang $(CFLAGS) -fobjc-arc -o $@ pocket-viewer.m echocancel.m moviewriter.m plugins.m gimbal.c $(IOKIT) \
		-framework Cocoa -framework AVFoundation -framework CoreMedia -framework QuartzCore \
		-framework CoreAudio -framework AudioToolbox -framework CoreImage \
		-sectcreate __TEXT __info_plist Info.plist

.PHONY: all plugins clean

clean:
	rm -rf pocketctl pocket-viewer plugins/bin
