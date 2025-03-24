using Toybox.Application;
using Toybox.Graphics;
using Toybox.Lang;
using Toybox.Media;
using Toybox.WatchUi;

// View to configure what songs to play
class ConfigurePlaybackView extends WatchUi.View {
  // Indicates if the menu has been pushed or not
  private var mMenuShown = false;
  // Message to show in the view
  private var mMessage = "";

  // Constructor
  function initialize() {
    View.initialize();

    // Push the authentication view if not authenticated
    var token = Application.Properties.getValue("AUTHENTICATION_TOKEN") as Lang.String or Null;
    if (token == null || token.equals("")) {
      WatchUi.pushView(new OauthView(), null, WatchUi.SLIDE_IMMEDIATE);
    }
  }

  // If the page hasn't been shown yet push the Configure playback menu. Otherwise pop the page.
  function onShow() {
    if (!mMenuShown) {
      // See how many songs are the the system
      var books = Application.Properties.getValue("BOOKS");

      // If there are any books, push the configure playback menu. Otherwise show an error message.
      if (books != null && books.size() != 0) {
        WatchUi.pushView(
          new ConfigurePlaybackMenu(),
          new ConfigurePlaybackMenuDelegate(),
          WatchUi.SLIDE_IMMEDIATE
        );
      } else {
        mMessage = Application.loadResource(Rez.Strings.noBooks);
      }
      mMenuShown = true;
    } else {
      // NOTE: Popping the view before starting playback causes problems...
      Media.startPlayback(null);
    }
  }

  function onUpdate(dc) {
    dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
    dc.clear();
    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
    dc.drawText(
      dc.getWidth() / 2,
      dc.getHeight() / 2,
      Graphics.FONT_MEDIUM,
      mMessage,
      Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
    );
  }
}
