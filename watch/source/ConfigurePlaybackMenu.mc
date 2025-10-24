using Toybox.WatchUi;
using Toybox.Application;
using Toybox.Lang;

// Menu to choose what songs to playback
class ConfigurePlaybackMenu extends WatchUi.Menu2 {
  // Constructor
  function initialize() {
    Menu2.initialize({ :title => Rez.Strings.playbackMenuTitle });

    // Get the songs on the system
    var books = DataStore.getBooks();

    // For each song in the playlist, precheck the item when adding it to the menu
    for (var idx = 0; idx < books.size(); ++idx) {
      var tracks = books[idx]["tracks"];

      var first = 0;
      if (first < tracks.size()) {
        var refId = tracks[first];
        var ref = new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO);
        var cachedRef = Media.getCachedContentObj(ref);
        // It should be redundent, but it's not.
        if (cachedRef != null) {
          var bookName = cachedRef.getMetadata().album;
          var item = new WatchUi.MenuItem(bookName, null, books[idx]["isbn"], null);
          addItem(item);
        }
      }
    }

    addItem(new WatchUi.MenuItem("Add/remove books", null, null, null));
  }
}
