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

  function onSelect(item as Toybox.WatchUi.MenuItem) {
    var id = item.getId();
    if (id != null) {
      if (DataStore.getCurrentIsbn() != id) {
        DataStore.setCurrentIsbn(id.toString());
        DataStore.setCurrentTrack(0);
      }
      DataStore.syncAndPlay();
    } else {
      WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
      DataStore.setDeleteList([]);
      DataStore.setSyncList([]);
      Media.stopPlayback();
      WatchUi.pushView(new ConfigureSyncView(), null, WatchUi.SLIDE_IMMEDIATE);
    }
  }

  function onBack() {
    var isbn = DataStore.getCurrentIsbn();
    var books = DataStore.getBooks();
    for (var i = 0; i < books.size(); i += 1) {
      if (books[i]["isbn"] == isbn) {
        DataStore.syncAndPlay();
        return;
      }
    }

    WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
  }
}
