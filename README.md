This app lets you download <https://libro.fm> books you have purchased onto your Garmin device.

You can download it at <https://apps.garmin.com/apps/9ec9794e-aba5-481d-98f6-1a9604064875>

It has two parts:

## The server

It provides OAuth and proxies libro.fm's API.
`cd ./server && cargo run`

## The watch app
Requires the Connect IQ SDK. I use https://github.com/lindell/connect-iq-sdk-manager-cli.

```
# make build/fr265s.prg        # build the app for a given physical device (in this case the Forerunner 265s)
# make build/fr265s_sim.prg    # build the app for a given simulated device (in this case, for the Forerunner 265s)
 			                   # you an then run use `monkeydo build/fr265s_sim.prg fr265s` to run on sim
# make build/App.iq            # build the store package (all manifest products)
# make supported_devices       $ print ciq >= 5.0 audioContent devices (e.g., for manifest.xml)
```
