using Toybox.Media;
using Toybox.WatchUi;
using Toybox.Application;
using Toybox.System;

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
      Media.startPlayback(null);
    }
  }

  function onBack() {
    var isbn = Application.Properties.getValue("CURRENT_ISBN");
    var books = Application.Properties.getValue("BOOKS");
    if (books != null) {
      for (var i = 0; i < books.size(); i += 1) {
        if (books[i]["isbn"] == isbn) {
          Media.startPlayback(null);
          return;
        }
      }
    }

    System.exit();
  }
}
