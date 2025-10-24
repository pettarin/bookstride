using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.PersistedContent;
using Toybox.Lang;
using Toybox.Timer;

// Performs the sync with the music provider
class SyncDelegate extends Communications.SyncDelegate {
  // The list of isbns to sync
  private var mSyncList as Lang.Array<Lang.Long>;
  // The list of isbns to delete
  private var mDeleteList as Lang.Array<Lang.Long>;
  // The count of isbns to delete and download
  private var mTotalIsbnsToSync;
  // The count of songs that have been deleted or downloaded
  private var mBooksSynced;

  private var mBooks as Lang.Array<Book>;

  private var mCurrentTrack as Lang.Number = 0;
  private var mTrackCount as Lang.Number = 0;

  // Constructor
  function initialize() {
    SyncDelegate.initialize();

    // Get the sync list
    mSyncList = DataStore.getSyncList();

    // Get the delete list
    mDeleteList = DataStore.getDeleteList();

    var books = DataStore.getBooks();

    // Make a copy so we don't end up in a half-baked state.
    mBooks = [];
    for (var i = 0; i < books.size(); i += 1) {
      mBooks.add(books[i]);
    }

    mBooksSynced = 0;
  }

  // Starts the sync with the system
  function onStartSync() {
    // Calculate the number of songs to be synced so the
    // progress can be updated properly
    mTotalIsbnsToSync = mSyncList.size() + mDeleteList.size();
    var books = DataStore.getBooks();

    // Make a copy so we don't end up in a half-baked state.
    mBooks = [];
    for (var i = 0; i < books.size(); i += 1) {
      mBooks.add(books[i]);
    }

    purgeBadMedia();

    // Delete deselected media.
    deleteBooks();

    // Grab the first song from the server
    syncNextIsbn();
  }

  // Determines if a sync is needed or not
  function isSyncNeeded() {
    return mSyncList.size() != 0 || mDeleteList.size() != 0;
  }

  // Delete newly unsynced books.
  function deleteBooks() {
    // Remove the song from the system
    var downloadedBooks = DataStore.getBooks();

    // Delete each song from the system
    for (var i = 0; i < mDeleteList.size(); i += 1) {
      for (var j = 0; j < downloadedBooks.size(); j += 1) {
        if (downloadedBooks[j]["isbn"] == mDeleteList[i]) {
          for (var k = 0; k < (downloadedBooks[j]["tracks"] as Lang.Array).size(); k += 1) {
            var obj = Media.getCachedContentObj(
              new Media.ContentRef(
                downloadedBooks[j]["tracks"][k],
                Media.CONTENT_TYPE_AUDIO
              )
            );
            if (obj != null) {
              Media.deleteCachedItem(
                new Media.ContentRef(
                  downloadedBooks[j]["tracks"][k],
                  Media.CONTENT_TYPE_AUDIO
                )
              );
            }
          }

          downloadedBooks.remove(downloadedBooks[j]);
        }
      }
    }

    // Remove the delete list from the system
    DataStore.setDeleteList([]);
  }

  // Downloads the next song to be synced
  function syncNextIsbn() {
    if (mSyncList.size() == 0) {
      DataStore.setDeleteList([]);
      DataStore.setSyncList([]);
      DataStore.setBooks(mBooks);
      Communications.notifySyncComplete(null);
      return;
    }

    var token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
    var isbn = mSyncList[0];

    var foundBook = false;
    for (var i = 0; i < mBooks.size(); i += 1) {
      if (mBooks[i]["isbn"] == isbn) {
        foundBook = true;
        mBooks[i]["tracks"] = [];
      }
    }
    if (!foundBook) {
      mBooks.add({
        "isbn" => isbn,
        "tracks" => [],
      });
    }

    Communications.makeWebRequest(
      Constants.BOOK_URL + isbn + Constants.START_DOWNLOAD,
      {},
      {
        :method => Communications.HTTP_REQUEST_METHOD_POST,
        :headers => { "Authorization" => "Bearer " + token },
      },
      method(:onDownloadTriggered)
    );
  }

  function onDownloadTriggered(
    responseCode as Lang.Number,
    data as Lang.Dictionary
  ) as Void {
    if (responseCode == 202) {
      mTrackCount = data["tracks"];
      mCurrentTrack = 0;
      syncNextTrack();
    } else {
      var errorString = "Conversion failed with error code: " + responseCode;
      DataStore.setDeleteList([]);
      DataStore.setSyncList([]);
      Communications.notifySyncComplete(errorString);
    }
  }

  function syncNextTrack() as Void {
    if (mSyncList.size() == 0) {
      DataStore.setDeleteList([]);
      DataStore.setSyncList([]);
      DataStore.setBooks(mBooks);
      Communications.notifySyncComplete(null);
      return;
    }

    var token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
    var isbn = mSyncList[0];

    // var delegate = new RequestDelegate(method(:onSongDownloaded), context);
    // delegate.makeWebRequest(mSyncList[ids[0]][SongInfo.URL], null, options);
    Communications.makeWebRequest(
      Constants.BOOK_URL + isbn + "/" + mCurrentTrack + Constants.TRACK,
      {},
      {
        :method => Communications.HTTP_REQUEST_METHOD_GET,
        :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
        :mediaEncoding => Media.ENCODING_MP3,
        :headers => { "Authorization" => "Bearer " + token },
      },
      method(:onTrackDownloaded)
    );
  }

  // Callback for when a track is downloaded
  function onTrackDownloaded(
    responseCode as Lang.Number,
    data as Lang.Dictionary
  ) as Void {
    if (responseCode == 429) {
      var timer = new Timer.Timer();
      timer.start(method(:syncNextTrack), 5000, false);
    } else if (responseCode == 200) {
      var trackId = (data as Media.ContentRef).getId();

      var foundBook = false;
      for (var i = 0; i < mBooks.size(); i += 1) {
        if (mBooks[i]["isbn"] == mSyncList[0]) {
          foundBook = true;
          (mBooks[i]["tracks"] as Lang.Array).add(trackId);
        }
      }
      if (!foundBook) {
        DataStore.setDeleteList([]);
        DataStore.setSyncList([]);
        Communications.notifySyncComplete("missing ISBN");
      }

      // Update the progress
      mCurrentTrack += 1;
      onSongSynced();

      if (mCurrentTrack < mTrackCount) {
        syncNextTrack();
      } else {
        mSyncList.remove(mSyncList[0]);
        syncNextIsbn();
      }
    } else {
      var errorString = "error code: " + responseCode;
      DataStore.setDeleteList([]);
      DataStore.setSyncList([]);
      Communications.notifySyncComplete(errorString);
    }
  }

  // Update the system with the current sync progress
  function onSongSynced() {
    var bookProgress =
      (mCurrentTrack.toFloat() + 1.0) / (mTrackCount.toFloat() + 1.0);

    var progress =
      (mBooksSynced.toFloat() + bookProgress) / mTotalIsbnsToSync.toFloat();

    progress = (progress * 100).toNumber();

    Communications.notifySyncProgress(progress);
  }

  function purgeBadMedia() {
    var knownTracks = {};
    var downloadedBooks = DataStore.getBooks();
    for (var i = 0; i < downloadedBooks.size(); i += 1) {
      var tracks = downloadedBooks[i]["tracks"];
      for (var j = 0; j < tracks.size(); j += 1) {
        knownTracks.put(tracks[j], true);
      }
    }

    // Purge medias without book

    var medias = Media.getContentRefIter({
      :contentType => Media.CONTENT_TYPE_AUDIO,
    });
    if (medias != null) {
      var media = medias.next();
      while (media != null) {
        if (!knownTracks.hasKey(media.getId())) {
          var ref = new Media.ContentRef(
            media.getId(),
            Media.CONTENT_TYPE_AUDIO
          );
          Media.deleteCachedItem(ref);
        }
        media = medias.next();
      }
    }
  }
}
