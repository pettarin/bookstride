# make build/fr265s.prg		# build the app for a given physical device (in this case the Forerunner 265s)
#				# then, copy it to e.g., mtp:/Forerunner 265S/Internal Storage/GARMIN/Apps to sideload
# make build/fr265s_sim.prg	# build the app for a given simulated device (in this case, for the Forerunner 265s)
#			       	# then, run `monkeydo build/fr265s_sim.prg fr265s` with the simulator to test it on the simulator
# make build/App.iq            	# build the store package (all manifest products)
# make supported_devices       	# print ciq >= 5.0 audioContent devices (e.g., for manifest.xml)

KEY      := ../../keys/developer_key
JUNGLE   := monkey.jungle
BUILD    := build
WARN     := -w

MONKEYDO := monkeydo

SRCS     := $(shell find source resources -type f) manifest.xml monkey.jungle

.PHONY: debug clean all supported_devices

all:	$(BUILD)/App.iq

# Order-only: create the build directory.
$(BUILD):
	mkdir -p $@

$(BUILD)/%.prg: $(SRCS) | $(BUILD)
	monkeyc -f $(JUNGLE) -d $* -o $@ -y $(KEY) $(WARN)

# release mode
$(BUILD)/App.iq: $(SRCS) | $(BUILD)
	monkeyc -f $(JUNGLE) -o $@ -y $(KEY) -e -r $(WARN)

clean:
	rm -fr $(BUILD)

supported_devices:
	find ~/.Garmin/ConnectIQ/Devices/ -name compiler.json | xargs jq -s -r '[ .[] | select( ( (.partNumbers | map(.connectIQVersion | split(".") | map(tonumber)) | max) as $$v | $$v[0] >= 5 ) and ([.appTypes[].type] | index("audioContentProvider"))) | .deviceId ] | sort | .[]'
