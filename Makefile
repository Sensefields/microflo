# User configuration options
GRAPH=examples/blink.fbp
MODEL=uno
AVRMODEL=at90usb1287
MBED_GRAPH=examples/blink-mbed.fbp
LINUX_GRAPH=examples/blink-rpi.fbp
STELLARIS_GRAPH=examples/blink-stellaris.fbp
UPLOAD_DIR=/mnt

# SERIALPORT=/dev/somecustom
# ARDUINO=/home/user/Arduino-1.0.5
# LIBRARY= arduino-standard|arduino-minimal

AVRSIZE=avr-size
AVRGCC=avr-g++
AVROBJCOPY=avr-objcopy
DFUPROGRAMMER=dfu-programmer
VERSION=$(shell git describe --tags --always)
OSX_ARDUINO_APP=/Applications/Arduino.app
AVR_FCPU=1000000UL

# Not normally customized
CPPFLAGS=-ffunction-sections -fshort-enums -fdata-sections -g -Os -w
DEFINES=
ifeq ($(LIBRARY),arduino-standard)
DEFINES+=-DHAVE_DALLAS_TEMPERATURE -DHAVE_ADAFRUIT_NEOPIXEL -DHAVE_ADAFRUIT_WS2801
endif

ifdef NO_DEBUG
DEFINES+=-DMICROFLO_DISABLE_DEBUG
endif

ifdef NO_SUBGRAPHS
DEFINES+=-DMICROFLO_DISABLE_SUBGRAPHS
endif

ifdef LIBRARY
LIBRARYOPTION=--library=microflo/components/$(LIBRARY).json
endif

INOOPTIONS=--board-model=$(MODEL)

ifdef SERIALPORT
INOUPLOADOPTIONS=--serial-port=$(SERIALPORT)
endif

ifdef ARDUINO
INOOPTIONS+=--arduino-dist=$(ARDUINO)
endif

EMSCRIPTEN_EXPORTS='["_emscripten_runtime_new", "_emscripten_runtime_free", "_emscripten_runtime_run", "_emscripten_runtime_send", "_emscripten_runtime_setup"]'

# Platform specifics
ifeq ($(OS),Windows_NT)
	# TODO, test and fix
else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Darwin)
        AVRSIZE=$(OSX_ARDUINO_APP)/Contents/Resources/Java/hardware/tools/avr/bin/avr-size
	AVRGCC=$(OSX_ARDUINO_APP)/Contents/Resources/Java/hardware/tools/avr/bin/avr-g++
	AVROBJCOPY=$(OSX_ARDUINO_APP)/Contents/Resources/Java/hardware/tools/avr/bin/avr-objcopy
    endif
    ifeq ($(UNAME_S),Linux)
        # Nothing needed :D
    endif
endif

# Rules
all: build

build-arduino: update-defs
	mkdir -p build/arduino/src
	mkdir -p build/arduino/lib
	ln -sf `pwd`/microflo build/arduino/lib/
	unzip -q -n ./thirdparty/OneWire.zip -d build/arduino/lib/
	unzip -q -n ./thirdparty/DallasTemperature.zip -d build/arduino/lib/
	cd thirdparty/Adafruit_NeoPixel && git checkout-index -f -a --prefix=../../build/arduino/lib/Adafruit_NeoPixel/
	cd thirdparty/Adafruit_WS2801 && git checkout-index -f -a --prefix=../../build/arduino/lib/Adafruit_WS2801/
	cd build/arduino/lib && test -e patched || patch -p0 < ../../../thirdparty/DallasTemperature.patch
	cd build/arduino/lib && test -e patched || patch -p0 < ../../../thirdparty/OneWire.patch
	touch build/arduino/lib/patched
	node microflo.js generate $(GRAPH) build/arduino/src/firmware.cpp arduino
	cd build/arduino && ino build $(INOOPTIONS) --verbose --cppflags="$(CPPFLAGS) $(DEFINES)"
	$(AVRSIZE) -A build/arduino/.build/$(MODEL)/firmware.elf

build-avr: update-defs
	mkdir -p build/avr
	node microflo.js generate $(GRAPH) build/avr/firmware.cpp avr
	cd build/avr && $(AVRGCC) -o firmware.elf firmware.cpp -I../../microflo -DF_CPU=$(AVR_FCPU) -DAVR=1 -Wall -Werror -Wno-error=overflow -mmcu=$(AVRMODEL) -fno-exceptions -fno-rtti $(CPPFLAGS)
	cd build/avr && $(AVROBJCOPY) -j .text -j .data -O ihex firmware.elf firmware.hex
	$(AVRSIZE) -A build/avr/firmware.elf

build-mbed: update-defs
	cd thirdparty/mbed && python2 workspace_tools/build.py -t GCC_ARM -m LPC1768
	rm -rf build/mbed
	mkdir -p build/mbed
	node microflo.js generate $(MBED_GRAPH) build/mbed/main.cpp mbed
	cp Makefile.mbed build/mbed/Makefile
	cd build/mbed && make ROOT_DIR=./../../

build-stellaris: update-defs
	rm -rf build/stellaris
	mkdir -p build/stellaris
	node microflo.js generate $(STELLARIS_GRAPH) build/stellaris/main.cpp stellaris
	cp Makefile.stellaris build/stellaris/Makefile
	cp startup_gcc.c build/stellaris/
	cp stellaris.ld build/stellaris/
	cd build/stellaris && make ROOT=../../thirdparty/stellaris

# Build microFlo components as an object library, build/lib/componentlib.o
# (the microflo/componentlib.cpp pulls in all available components, as defined from components.json)
build-microflo-complib:
	mkdir -p build/lib
	node microflo.js componentlib $(shell pwd)/microflo/components.json $(shell pwd)/microflo createComponent
	g++ -c microflo/componentlib.cpp -o build/lib/componentlib.o -std=c++0x -DLINUX -Wall -Werror

# Build microFlo runtime as a dynamic loadable library, build/lib/libmicroflo.so
build-microflo-sharedlib: 
	rm -rf build/lib
	mkdir -p build/lib
	g++ -fPIC -c microflo/microflo.cpp -o microflo/microflo.o -std=c++0x -DLINUX -Wall -Werror
	g++ -shared -Wl,-soname,libmicroflo.so -o build/lib/libmicroflo.so microflo/microflo.o

# Build microFlo runtime as an object library (to be static linked with app), build/lib/microflolib.o
build-microflo-objlib: 
	rm -rf build/lib
	mkdir -p build/lib
	g++ -c microflo/microflo.cpp -o build/lib/microflolib.o -std=c++0x -DLINUX -Wall -Werror

# Build firmware linked to microflo runtime as dynamic loadable library, build/lib/libmicroflo.so
build-linux-sharedlib: update-defs build-microflo-sharedlib
	rm -rf build/linux
	mkdir -p build/linux
	node microflo.js generate $(LINUX_GRAPH) build/linux/main.cpp linux
	g++ -o build/linux/firmware build/linux/main.cpp -std=c++0x -Wl,-rpath=$(shell pwd)/build/lib -DLINUX -I. -I./microflo -Wall -Werror -lrt -L./build/lib -lmicroflo

# Build firmware statically linked to microflo runtime as object file, build/lib/microflolib.o
build-linux: update-defs build-microflo-objlib build-microflo-complib
	rm -rf build/linux
	mkdir -p build/linux
	node microflo.js generate $(LINUX_GRAPH) build/linux/main.cpp linux
	g++ -o build/linux/firmware build/linux/main.cpp -std=c++0x build/lib/microflolib.o build/lib/componentlib.o -DLINUX -I. -I./microflo -Wall -Werror -lrt

build-emscripten: update-defs
	rm -rf build/emscripten
	mkdir -p build/emscripten
	node microflo.js generate $(GRAPH) build/emscripten/main.cpp emscripten
	cd build/emscripten && EMCC_FAST_COMPILER=0 emcc -o microflo-runtime.html main.cpp -I../../microflo -Wall -s NO_DYNAMIC_EXECUTION=1 -s EXPORTED_FUNCTIONS=$(EMSCRIPTEN_EXPORTS)

build: build-arduino build-avr

upload: build-arduino
	cd build/arduino && ino upload $(INOUPLOADOPTIONS) $(INOOPTIONS)

upload-dfu: build-avr
	cd build/avr && sudo $(DFUPROGRAMMER) $(AVRMODEL) erase
	sleep 1
	cd build/avr && sudo $(DFUPROGRAMMER) $(AVRMODEL) flash firmware.hex || sudo $(DFUPROGRAMMER) $(AVRMODEL) flash firmware.hex || sudo $(DFUPROGRAMMER) $(AVRMODEL) flash firmware.hex || sudo $(DFUPROGRAMMER) $(AVRMODEL) flash firmware.hex || sudo $(DFUPROGRAMMER) $(AVRMODEL) flash firmware.hex
	sudo $(DFUPROGRAMMER) $(AVRMODEL) start

upload-mbed: build-mbed
	cd build/mbed && sudo cp firmware.bin $(UPLOAD_DIR)

debug-stellaris:
	arm-none-eabi-gdb build/stellaris/gcc/main.axf --command=./stellaris.load.gdb

upload-stellaris: build-stellaris
	sudo lm4flash build/stellaris/gcc/main.bin

clean:
	git clean -dfx --exclude=node_modules

build-host:
	grunt build

update-defs: build-host
	node microflo.js update-defs $(LIBRARYOPTION)

release-arduino:
	rm -rf build/microflo-arduino
	mkdir -p build/microflo-arduino/microflo/examples/Standalone
	cp -r microflo build/microflo-arduino/
	cp build/arduino/src/firmware.cpp build/microflo-arduino/microflo/examples/Standalone/Standalone.pde
	cd build/microflo-arduino && zip -q -r ../microflo-arduino.zip microflo

release-mbed: build-mbed
    # TODO: package into something usable with MBed tools

release-linux: build-linux
    # TODO: package?

release-stellaris: build-stellaris
    # TODO: package?

release-emscripten: build-emscripten
    # TODO: package?

release: update-defs build release-mbed release-linux release-microflo release-arduino release-stellaris release-emscripten
	rm -rf build/microflo-$(VERSION)
	mkdir -p build/microflo-$(VERSION)
	cp -r build/microflo-arduino.zip build/microflo-$(VERSION)/
	cp README.release.txt build/microflo-$(VERSION)/README.txt
    # FIXME: copy in a README/HTML pointing to Flowhub app, and instructions to flash device
	cd build && zip -q --symlinks -r microflo-$(VERSION).zip microflo-$(VERSION)

check-release: release
	rm -rf build/check-release
	mkdir -p build/check-release
	cd build/check-release && unzip -q ../microflo-$(VERSION)
    # TODO: check npm and component.io packages
    # TODO: check arduino package by importing with ino, building

check: build-emscripten
	npm test

.PHONY: all build update-defs clean release release-microflo release-arduino check-release

