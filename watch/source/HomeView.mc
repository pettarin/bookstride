using Toybox.Application;
using Toybox.Graphics;
using Toybox.Media;
using Toybox.WatchUi;

class HomeView extends WatchUi.View {
  // Constructor
  function initialize() {
    View.initialize();
  }
  private var mShownPlayback = false;
  private var mShownSync = false;

  function onShow() {
    var books = Application.Properties.getValue("BOOKS");

    if (books != null && books.size() != 0 || mShownSync) {
      if (mShownPlayback) {
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        return;
      }
      WatchUi.pushView(
        new ConfigurePlaybackMenu(),
        new ConfigurePlaybackMenuDelegate(),
        WatchUi.SLIDE_IMMEDIATE
      );
      mShownPlayback = true;
    } else {
      WatchUi.pushView(new ConfigureSyncView(), null, WatchUi.SLIDE_IMMEDIATE);
      mShownSync = true;
    }
  }
}
