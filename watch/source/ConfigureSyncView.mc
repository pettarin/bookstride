using Toybox.Application;
using Toybox.Communications;
using Toybox.Graphics;
using Toybox.System;
using Toybox.WatchUi;
using Toybox.Lang;

// View for choosing what songs to download
class ConfigureSyncView extends WatchUi.View {
    // The songs fetched from the server
    private var mSongs;
    // Wheter the view has been shown or not
    private var mMenuShown;

    // Constructor
    function initialize() {
        View.initialize();
        mMenuShown = false;
    }

    // When shown, decide if the songs should be fetched or the view popped (when returning from the menu)
    function onShow() {
        // If not authenticated, get authentication first
        var token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
        if (token == null || token.equals("")) {
             WatchUi.pushView(new OauthView(), null, WatchUi.SLIDE_IMMEDIATE);
        } else if (mMenuShown) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        } else {
            token = Application.Properties.getValue("AUTHENTICATION_TOKEN");
            Communications.makeWebRequest(Constants.LIBRARY_URL + "1", null, {:headers => {"Authorization" => "Bearer " + token}}, method(:onFileListing));
            mSongs = {};
        }
    }

    // Handle updating the view
    function onUpdate(dc) {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);

        // Indicate that the songs are being fetched
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_MEDIUM, WatchUi.loadResource(Rez.Strings.fetchingBooks), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // Store the fetched songs
    function onFileListing(responseCode as Lang.Number, data as Lang.Dictionary) as Void {
        if (responseCode == 200) {
            mSongs = data["res"];
            pushSyncMenu();
        } else {
            if (data != null) {
                WatchUi.pushView(new ErrorView(data["errorMessage"]), null, WatchUi.SLIDE_IMMEDIATE);
            } else {
                WatchUi.pushView(new ErrorView("Unknown Error"), null, WatchUi.SLIDE_IMMEDIATE);
            }
        }
        WatchUi.requestUpdate();
    }

    // Populates the sync menu with the songs from the server
    function pushSyncMenu() {
        var menu = new WatchUi.CheckboxMenu({:title => Rez.Strings.syncMenuTitle});
        var precheckedItems = {};

        // Add in songs on the system to the prechecked list
        var downloadedBooks = Application.Properties.getValue("BOOKS") as Lang.Array<Lang.Dictionary> or Null;
        if (downloadedBooks == null) {
            downloadedBooks = [];
        }

        for (var idx = 0; idx < downloadedBooks.size(); ++idx) {
            var isbn = downloadedBooks[idx]["isbn"];
            precheckedItems[isbn] = true;
        }

        // Add in songs that need to be synced to the prechecked list
        var isbnsToSync = Application.Properties.getValue("PENDING_SYNC") as Lang.Array<Lang.Dictionary> or Null;
        if (isbnsToSync == null) {
            isbnsToSync = [];
        }

        for (var idx = 0; idx < isbnsToSync.size(); ++idx) {
            precheckedItems[isbnsToSync[idx]] = true;
        }

        // Create the menu, prechecking anything that is to be or has been synced
        for (var idx = 0; idx < mSongs.size(); ++idx) {
            var item = new WatchUi.CheckboxMenuItem(mSongs[idx]["title"],
                                                    null,
                                                    mSongs[idx]["isbn"],
                                                    precheckedItems.hasKey(mSongs[idx]["isbn"]),
                                                    {});
            menu.addItem(item);
        }
        WatchUi.pushView(menu, new ConfigureSyncMenuDelegate(), WatchUi.SLIDE_IMMEDIATE);
        mMenuShown = true;
    }
}
