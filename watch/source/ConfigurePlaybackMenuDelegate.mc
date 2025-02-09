using Toybox.Media;
using Toybox.WatchUi;
using Toybox.Application;

// Delegate for playback menu
class ConfigurePlaybackMenuDelegate extends WatchUi.Menu2InputDelegate {

    // Constructor
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        Application.Properties.setValue("CURRENT_ISBN", item.getId());
        System.println("select");
        Media.startPlayback(null);
    }
}
