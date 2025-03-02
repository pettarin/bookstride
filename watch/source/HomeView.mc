using Toybox.Application;
using Toybox.Graphics;
using Toybox.Media;
using Toybox.WatchUi;

class HomeView extends WatchUi.View {
  // Constructor
  function initialize() {
    View.initialize();
  }

  // If the page hasn't been shown yet push the Configure playback menu. Otherwise pop the page.
  function onShow() {
    var books = Application.Properties.getValue("BOOKS");

    if (books != null && books.size() != 0) {
      WatchUi.pushView(
        new ConfigurePlaybackMenu(),
        new ConfigurePlaybackMenuDelegate(),
        WatchUi.SLIDE_IMMEDIATE
      );
    } else {
      WatchUi.pushView(new ConfigureSyncView(), null, WatchUi.SLIDE_IMMEDIATE);
    }
  }
}
