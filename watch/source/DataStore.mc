using Toybox.Application;
using Toybox.Lang;
using Toybox.Media;

typedef Book as {
    :isbn as Lang.Long,
    :tracks as Lang.Array<Lang.Object>,
};

module DataStore {
  var mIsbn as Lang.String = "";
  var mTrack as Lang.Number = 0;
  var mBooks as Lang.Array<Book> = [];
  var mSyncList as Lang.Array<Lang.Long> = [];
  var mDeleteList as Lang.Array<Lang.Long> = [];
  var mLastViewWasPlayback = false;
  var mInit = false;

  function maybeInit() {
    if (mInit) {
        return;
    }

    mInit = true;
    var isbn = Application.Properties.getValue("CURRENT_ISBN");
    if (isbn instanceof Lang.String) {
      mIsbn = isbn;
    } else if (isbn instanceof Lang.Long) {
      mIsbn = isbn.toString();
    } else if (isbn instanceof Lang.Object) {
      mIsbn = isbn.toString();
    }
    var track = Application.Properties.getValue("CURRENT_TRACK");
    if (track instanceof Lang.Number) {
      mTrack = track;
    }
    var books = Application.Properties.getValue("BOOKS");
    if (books instanceof Lang.Array) {
      mBooks = [];
      for (var i = 0; i < books.size(); i+= 1) {
        mBooks.add(books[i] as Book);
      }
    }
    var syncList = Application.Properties.getValue("PENDING_SYNC");
    if (syncList instanceof Lang.Array) {
      mSyncList = syncList as Lang.Array<Lang.Long>;
    }
    var deleteList = Application.Properties.getValue("PENDING_DELETE");
    if (deleteList instanceof Lang.Array) {
      mDeleteList = deleteList as Lang.Array<Lang.Long>;
    }

    for (var i = mBooks.size() - 1; i >= 0; i -= 1) {
      var book = mBooks[i];
      if (book == null || book["tracks"] == null || book["tracks"].size() == 0) {
        mBooks.remove(book);
      }
    }
  }

  function getCurrentIsbn() as Lang.Long {
    maybeInit();

    return mIsbn.toLong();
  }

  function setCurrentIsbn(isbn as Lang.String) {
    maybeInit();
    Application.Properties.setValue("CURRENT_ISBN", isbn.toString());
    mIsbn = isbn;
  }

  function getCurrentTrack() as Lang.Number {
    maybeInit();
    if (mTrack instanceof Lang.Number) {
      return mTrack;
    }
    return 0;
  }

  function setCurrentTrack(track as Lang.Number) {
    maybeInit();
    Application.Properties.setValue("CURRENT_TRACK", track);
    mTrack = track;
  }

  function getBooks() as Lang.Array<Book> {
    maybeInit();
    if (mBooks instanceof Lang.Array) {
      return mBooks;
    }
    return [];
  }

  function setBooks(books as Lang.Array<Book>) {
    maybeInit();
    mBooks = books;
    var booksCopy = [];
    for (var i = 0; i < mBooks.size(); i += 1) {
      booksCopy.add(mBooks[i]);
    }
    Application.Properties.setValue("BOOKS", booksCopy);
  }

  function getSyncList() as Lang.Array<Lang.Long> {
    maybeInit();
    if (mSyncList instanceof Lang.Array) {
      return mSyncList;
    }
    return [];
  }

  function setSyncList(books as Lang.Array<Lang.Long>) {
    maybeInit();
    Application.Properties.setValue("PENDING_SYNC", books);
    mSyncList = books;
  }


  function getDeleteList() as Lang.Array<Lang.Long> {
    maybeInit();
    if (mDeleteList instanceof Lang.Array) {
      return mDeleteList;
    }
    return [];
  }

  function setDeleteList(books as Lang.Array<Lang.Long>) {
    maybeInit();
    Application.Properties.setValue("PENDING_DELETE", books);
    mDeleteList = books;
  }

  function syncAndPlay() {
    DataStore.setLastViewWasPlayback(false);
    if (getCurrentTrack() == 0) {
      Media.startPlayback(getCurrentIsbn());
    } else {
      Media.startPlayback(null);
    }
  }

  function setLastViewWasPlayback(flag as Lang.Boolean) {
    mLastViewWasPlayback = flag;
  }
  function getLastViewWasPlayback() as Lang.Boolean {
    return mLastViewWasPlayback;
  }
}
