CFLAGS = -O2 -Wall
IOKIT = -framework IOKit -framework CoreFoundation

all: pocketctl pocket-viewer

pocketctl: pocketctl.c gimbal.c gimbal.h
	clang $(CFLAGS) -o $@ pocketctl.c gimbal.c $(IOKIT)

pocket-viewer: pocket-viewer.m gimbal.c gimbal.h echocancel.m echocancel.h moviewriter.m moviewriter.h Info.plist
	clang $(CFLAGS) -fobjc-arc -o $@ pocket-viewer.m echocancel.m moviewriter.m gimbal.c $(IOKIT) \
		-framework Cocoa -framework AVFoundation -framework CoreMedia -framework QuartzCore \
		-framework CoreAudio -framework AudioToolbox \
		-sectcreate __TEXT __info_plist Info.plist

clean:
	rm -f pocketctl pocket-viewer
