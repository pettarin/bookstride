using Toybox.WatchUi;
using Toybox.Application;
using Toybox.Lang;

// Menu to choose what songs to playback
class ConfigurePlaybackMenu extends WatchUi.Menu2 {
  // Constructor
  function initialize() {
    Menu2.initialize({ :title => Rez.Strings.playbackMenuTitle });

    // Get the songs on the system
    var books =
      Application.Properties.getValue("BOOKS") as Lang.Array<Lang.Dictionary>?;
    if (books == null) {
      books = [];
    }

    // For each song in the playlist, precheck the item when adding it to the menu
    for (var idx = 0; idx < books.size(); ++idx) {
      if (books[idx]["tracks"].size() == 0) {
        continue;
      }

      var refId = books[idx]["tracks"][0];
      var ref = new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO);
      var bookName = Media.getCachedContentObj(ref).getMetadata().album;
      var item = new WatchUi.MenuItem(bookName, null, books[idx]["isbn"], null);
      addItem(item);
    }

    addItem(new WatchUi.MenuItem("Add/remove books", null, null, null));
  }
}
