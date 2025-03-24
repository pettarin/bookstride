using Toybox.WatchUi;
using Toybox.Application;
using Toybox.Communications;

// Menu delegate for Sync Menu
class ConfigureSyncMenuDelegate extends WatchUi.Menu2InputDelegate {
  private var mSyncList;
  private var mDeleteList;

  // Constructor
  function initialize() {
    Menu2InputDelegate.initialize();
    mSyncList = [];
    mDeleteList = [];
  }

  // Either add it or remove the item from the
  // list of songs to sync or delete
  function onSelect(item) {
    if ((item as WatchUi.CheckboxMenuItem).isChecked()) {
      mSyncList.add(item.getId());
      mDeleteList.remove(item.getId());
    } else {
      mSyncList.remove(item.getId());
      mDeleteList.add(item.getId());
    }
  }

  // Pop the view when back is pushed
  function onBack() {
    // Get the songs currently on the system
    var downloadedBooks = Application.Properties.getValue("BOOKS");
    if (downloadedBooks == null) {
      downloadedBooks = [];
    }

    Application.Properties.setValue("PENDING_SYNC", mSyncList);
    Application.Properties.setValue("PENDING_DELETE", mDeleteList);

    if (mSyncList.size() > 0 || mDeleteList.size() > 0) {
      Communications.startSync();
    } else {
      WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
  }

  // Stores the songs to delete and download in the object store
  function onDone() {
    // Get the songs currently on the system
    var downloadedBooks = Application.Properties.getValue("BOOKS");
    if (downloadedBooks == null) {
      downloadedBooks = [];
    }

    Application.Properties.setValue("PENDING_SYNC", mSyncList);
    Application.Properties.setValue("PENDING_DELETE", mDeleteList);

    if (mSyncList.size() > 0 || mDeleteList.size() > 0) {
      Communications.startSync();
    } else {
      WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }
  }

  // Utility function to get the ContentRefId from the already downloaded songs.
  // Converts songId, the ID from the server, to the stored ref id
  function getRefIdsFromBooks(isbn, downloadedBooks) {
    for (var i = 0; i < downloadedBooks.size(); i += 1) {
      if (downloadedBooks[i]["isbn"] == isbn) {
        return downloadedBooks[i]["tracks"];
      }
    }

    return null;
  }
}
