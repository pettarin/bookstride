using Toybox.Application;
using Toybox.Lang;
using Toybox.Media;
using Toybox.System;

typedef Book as {
    :isbn as Lang.Long,
    :tracks as Lang.Array<Lang.Object>,
};

module DataStore {
  var mIsbn as Lang.String = "";
  var mTrack as Lang.Number = 0;
  var mPosition as Lang.Number = 0;
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
    var position = Application.Properties.getValue("CURRENT_POSITION");
    if (position instanceof Lang.Number) {
      mPosition = position;
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

  // Position within the current track, in SECONDS. This matches
  // Media.ContentDelegate.onSong's playbackPosition Number and
  // Media.ActiveContent's playbackStartPos, both of which are seconds
  // per the Connect IQ API docs — no conversion happens at either
  // boundary, and PositionSync pushes it to the cloud as-is (libro.fm's
  // track_seconds is also seconds).
  function getCurrentPosition() as Lang.Number {
    maybeInit();
    if (mPosition instanceof Lang.Number) {
      return mPosition;
    }
    return 0;
  }
  
  function setCurrentPosition(position as Lang.Number) {
    maybeInit();
    Application.Properties.setValue("CURRENT_POSITION", position);
    mPosition = position;
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

  // ------------------------------------------------------------------
  // Position-sync state (see docs/watch-position-sync-design.md).
  // Snapshots are dictionaries {isbn, track, seconds, changed_at} in
  // cloud units (track zero-indexed, seconds a float). These live in
  // Application Storage, not Properties, because they are structured
  // values rather than declared settings.
  // ------------------------------------------------------------------

  function getPendingPosition() as Lang.Dictionary? {
    maybeInit();
    var v = Application.Storage.getValue("PENDING_POSITION");
    return v instanceof Lang.Dictionary ? v : null;
  }

  function setPendingPosition(pos as Lang.Dictionary?) {
    if (pos == null) {
      try {
        Application.Storage.deleteValue("PENDING_POSITION");
      } catch (e) {
        // Already absent.
      }
    } else {
      Application.Storage.setValue("PENDING_POSITION", pos);
    }
  }

  function getLastSynced() as Lang.Dictionary? {
    maybeInit();
    var v = Application.Storage.getValue("LAST_SYNCED");
    return v instanceof Lang.Dictionary ? v : null;
  }

  function setLastSynced(synced as Lang.Dictionary) {
    Application.Storage.setValue("LAST_SYNCED", synced);
  }

  function getDivergenceDeclined() as Lang.Boolean {
    maybeInit();
    var v = Application.Storage.getValue("DIVERGENCE_DECLINED");
    return v instanceof Lang.Boolean ? v : false;
  }

  function setDivergenceDeclined(flag as Lang.Boolean) {
    Application.Storage.setValue("DIVERGENCE_DECLINED", flag);
  }

  function getAuthStale() as Lang.Boolean {
    maybeInit();
    var v = Application.Storage.getValue("AUTH_STALE");
    return v instanceof Lang.Boolean ? v : false;
  }

  function setAuthStale(flag as Lang.Boolean) {
    Application.Storage.setValue("AUTH_STALE", flag);
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
