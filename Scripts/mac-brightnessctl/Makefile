CC = clang
# Universal binary (Apple Silicon + Intel). Override with ARCHS="-arch arm64" for a quick local build.
ARCHS ?= -arch arm64 -arch x86_64
CFLAGS = -Wall -Wextra -O2 -mmacosx-version-min=14.0 $(ARCHS)
LDFLAGS = -framework Foundation

SRC = main.m BrightnessControl.m KeyboardManager.m
OUT = mac-brightnessctl

all: $(OUT)

$(OUT): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

clean:
	rm -f $(OUT)

.PHONY: all clean
