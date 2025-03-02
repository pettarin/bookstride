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
    if (item.getId() == null) {
      WatchUi.pushView(new ConfigureSyncView(), null, WatchUi.SLIDE_IMMEDIATE);
    } else {
      Application.Properties.setValue("CURRENT_ISBN", item.getId());
      System.println("select");
      Media.startPlayback(null);
    }
  }

  function onBack() {
    System.println("back2");
    Media.startPlayback(null);
  }
}
