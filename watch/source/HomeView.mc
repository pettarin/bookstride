using Toybox.Application;
using Toybox.Graphics;
using Toybox.Media;
using Toybox.WatchUi;

class HomeView extends WatchUi.View {
  // Constructor
  function initialize() {
    View.initialize();
  }
  private var mShownSync = false;

  function onShow() {
    // App-open position check. Non-blocking; may prompt if another
    // device moved the current book's cloud position.
    PositionSync.checkAtOpen();

    var books = DataStore.getBooks();

    if (books.size() != 0 || mShownSync) {
      if (DataStore.getLastViewWasPlayback()) {
        DataStore.setLastViewWasPlayback(false);
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return;
      }
      DataStore.setLastViewWasPlayback(true);
      WatchUi.pushView(
        new ConfigurePlaybackMenu(),
        new ConfigurePlaybackMenuDelegate(),
        WatchUi.SLIDE_IMMEDIATE
      );
    } else {
      DataStore.setLastViewWasPlayback(false);
      WatchUi.pushView(new ConfigureSyncView(), null, WatchUi.SLIDE_IMMEDIATE);
      mShownSync = true;
    }
  }
}
