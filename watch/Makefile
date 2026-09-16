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

# Device the unit-test build targets (must be in manifest.xml products).
TEST_DEVICE  := fr265s_sim
TEST_RUN_DEV := fr265s

SRCS     := $(shell find source resources -type f) manifest.xml monkey.jungle

.PHONY: debug clean all supported_devices tests

all:	$(BUILD)/App.iq

# Order-only: create the build directory.
$(BUILD):
	mkdir -p $@

$(BUILD)/%.prg: $(SRCS) | $(BUILD)
	monkeyc -f $(JUNGLE) -d $* -o $@ -y $(KEY) $(WARN)

# Run No Evil unit tests (watch/source/PositionSyncTests.mc). Builds a
# simulator executable with the (:test) code included (-t), then runs the
# suite in the simulator with monkeydo -t. The simulator must be running
# first (`connectiq` from the SDK bin dir); add a test name after -t to
# run a single test, e.g.
#   PATH=<sdk>/bin:$$PATH make tests
#   monkeydo build/tests.prg fr265s -t testFormatHms
$(BUILD)/tests.prg: $(SRCS) | $(BUILD)
	monkeyc -f $(JUNGLE) -d $(TEST_DEVICE) -o $@ -y $(KEY) -t $(WARN)

tests: $(BUILD)/tests.prg
	@out=$$($(MONKEYDO) $(BUILD)/tests.prg $(TEST_RUN_DEV) -t 2>&1); \
	  echo "$$out"; \
	  (echo "$$out" | grep -qE 'FAILED|Simulator not found|Unable to connect') && exit 1 || true; \
	  echo "$$out" | grep -q 'PASSED' || exit 1

# release mode
$(BUILD)/App.iq: $(SRCS) | $(BUILD)
	monkeyc -f $(JUNGLE) -o $@ -y $(KEY) -e -r $(WARN)

clean:
	rm -fr $(BUILD)

supported_devices:
	find ~/.Garmin/ConnectIQ/Devices/ -name compiler.json | xargs jq -s -r '[ .[] | select( ( (.partNumbers | map(.connectIQVersion | split(".") | map(tonumber)) | max) as $$v | $$v[0] >= 5 ) and ([.appTypes[].type] | index("audioContentProvider"))) | .deviceId ] | sort | .[]'
