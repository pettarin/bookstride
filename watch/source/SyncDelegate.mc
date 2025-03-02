using Toybox.Application;
using Toybox.Communications;
using Toybox.Media;
using Toybox.PersistedContent;
using Toybox.Lang;
using Toybox.Timer;

// Performs the sync with the music provider
class SyncDelegate extends Communications.SyncDelegate {
  // The list of isbns to sync
  private var mSyncList as Lang.Array<Lang.String>;
  // The list of isbns to delete
  private var mDeleteList as Lang.Array<Lang.String>;
  // The count of isbns to delete and download
  private var mTotalIsbnsToSync;
  // The cont of songs that have been deleted or downloaded
  private var mBooksSynced;

  private var mCurrentTrack as Lang.Number = 0;
  private var mTrackCount as Lang.Number = 0;

  // Constructor
  function initialize() {
    SyncDelegate.initialize();
    System.println("del init");

    // Get the sync list
    mSyncList = Application.Properties.getValue("PENDING_SYNC");
    if (mSyncList == null) {
      mSyncList = [];
    }
    System.println("mSyncList");
    System.println(mSyncList);

    // Get the delete list
    mDeleteList = Application.Properties.getValue("PENDING_DELETE");
    if (mDeleteList == null) {
      mDeleteList = [];
    }
    System.println("mDeleteList.");

    mBooksSynced = 0;
  }

  // Starts the sync with the system
  function onStartSync() {
    // Calculate the number of songs to be synced so the
    // progress can be updated properly
    mTotalIsbnsToSync = mSyncList.size() + mDeleteList.size();

    // Delete all the songs from the system
    deleteSongs();

    // Grab the first song from the server
    syncNextIsbn();
  }

  // Determines if a sync is needed or not
  function isSyncNeeded() {
    System.println("call isSyncNeeded");
    return mSyncList.size() != 0 || mDeleteList.size() != 0;
  }

  // Delete songs off the system
  function deleteSongs() {
    // Remove the song from the system
    var downloadedBooks =
      Application.Properties.getValue("BOOKS") as Lang.Array<Lang.Dictionary>;
    if (downloadedBooks == null) {
      downloadedBooks = [];
    }

    // Delete each song from the system
    for (var i = 0; i < mDeleteList.size(); i += 1) {
      for (var j = 0; j < downloadedBooks.size(); j += 1) {
        if (downloadedBooks[j]["isbn"] == mDeleteList[i]) {
          for (var k = 0; k < downloadedBooks[j]["tracks"].size(); k += 1) {
            Media.deleteCachedItem(
              new Media.ContentRef(
                downloadedBooks[j]["tracks"][k],
                Media.CONTENT_TYPE_AUDIO
              )
            );
          }

          downloadedBooks.remove(downloadedBooks[j]);
        }
      }
      onSongSynced();
    }

    // Remove the delete list from the system
    Application.Properties.setValue("PENDING_DELETE", []);
    Application.Properties.setValue("BOOKS", downloadedBooks);
  }

  // Downloads the next song to be synced
  function syncNextIsbn() {
    if (mSyncList.size() == 0) {
      Communications.notifySyncComplete(null);
      return;
    }

    var token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
    var isbn = mSyncList[0];

    System.println(Constants.BOOK_URL + isbn + Constants.START_DOWNLOAD);
    var downloadedBooks =
      Application.Properties.getValue("BOOKS") as Lang.Array<Lang.Dictionary>?;

    var foundBook = false;
    if (downloadedBooks == null) {
      downloadedBooks = [];
    }
    for (var i = 0; i < downloadedBooks.size(); i += 1) {
      if (downloadedBooks[i]["isbn"] == isbn) {
        foundBook = true;
        downloadedBooks[i]["tracks"] = [];
      }
    }
    if (!foundBook) {
      downloadedBooks.add({
        "isbn" => isbn,
        "tracks" => [],
      });
    }
    Application.Properties.setValue("BOOKS", downloadedBooks);

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
    System.println("DID DOWNLOAD");
    if (responseCode == 202) {
      System.println(data);
      mTrackCount = data["tracks"];
      mCurrentTrack = 0;
      syncNextTrack();
    } else {
      var errorString = "Conversion failed with error code: " + responseCode;
      Communications.notifySyncComplete(errorString);
    }
  }

  function syncNextTrack() as Void {
    if (mSyncList.size() == 0) {
      Communications.notifySyncComplete(null);
      return;
    }

    var token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
    var isbn = mSyncList[0];

    // var delegate = new RequestDelegate(method(:onSongDownloaded), context);
    // delegate.makeWebRequest(mSyncList[ids[0]][SongInfo.URL], null, options);
    System.println(
      Constants.BOOK_URL + isbn + "/" + mCurrentTrack + Constants.TRACK
    );
    System.println(token);
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
      // var app = Application.getApp();
      var trackId = (data as Media.ContentRef).getId();

      var downloadedBooks = Application.Properties.getValue("BOOKS");
      if (downloadedBooks == null) {
        downloadedBooks = [];
      }
      var foundBook = false;
      for (var i = 0; i < downloadedBooks.size(); i += 1) {
        if (downloadedBooks[i]["isbn"] == mSyncList[0]) {
          foundBook = true;
          downloadedBooks[i]["tracks"].add(trackId);
        }
      }
      if (!foundBook) {
        Communications.notifySyncComplete("missing ISBN");
      }

      Application.Properties.setValue("BOOKS", downloadedBooks);

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
}
