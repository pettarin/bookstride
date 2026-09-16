using Toybox.WatchUi;
using Toybox.Application;
using Toybox.Lang;

class ConfigurePlaybackMenu extends WatchUi.Menu2 {
  // Constructor
  function initialize() {
    var title = Rez.Strings.playbackMenuTitle;
    if (DataStore.getAuthStale()) {
      // Auth failures surface as a one-line hint, not a prompt; the
      // OAuth flow re-establishes the token, after which pending position
      // pushes flush.
      title = "Sign-in expired";
    }
    Menu2.initialize({ :title => title });

    var books = DataStore.getBooks();
    var modifiedBooks = false;

    for (var idx = 0; idx < books.size(); ++idx) {
      var tracks = books[idx]["tracks"];

      var first = 0;
      if (first < tracks.size()) {
        var refId = tracks[first];
        var ref = new Media.ContentRef(refId, Media.CONTENT_TYPE_AUDIO);
        var cachedRef = Media.getCachedContentObj(ref);
        if (cachedRef == null) {
          // Despite the type checker saying this is impossible, this can happen when the device loses access to the content (e.g., sideloading after first having installed app)
          // It also turns out that this resets the refIds, so if we don't clean it up before adding more content, they'll be duplicated content IDs. I'm not going to
          // worry about that case here.
          books.remove(books[idx]);
          modifiedBooks = true;
          idx -= 1;
        } else {
          var bookName = cachedRef.getMetadata().album;
          var item = new WatchUi.MenuItem(bookName, null, books[idx]["isbn"], null);
          addItem(item);
        }
      }
    }

    if (modifiedBooks) {
      DataStore.setBooks(books);
    }
    addItem(new WatchUi.MenuItem("Add/remove books", null, null, null));
  }
}
