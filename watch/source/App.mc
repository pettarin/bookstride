import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Media;
import Toybox.WatchUi;

class App extends Application.AudioContentProviderApp {
  function initialize() {
    AudioContentProviderApp.initialize();
  }

  // onStart() is called on application start up
  function onStart(state as Dictionary?) as Void {}

  // onStop() is called when your application is exiting
  function onStop(state as Dictionary?) as Void {}

  // Get a Media.ContentDelegate for use by the system to get and iterate through media on the device
  function getContentDelegate(arg as PersistableType) as Media.ContentDelegate {
    return new ContentDelegate();
  }

  // Get a delegate that communicates sync status to the system for syncing media content to the device
  function getSyncDelegate() as Communications.SyncDelegate? {
    return new SyncDelegate();
  }

  // Get the initial view for configuring playback
  function getPlaybackConfigurationView() as [Views] or
    [Views, InputDelegates] {
    return [new HomeView()];
  }

  // Get the initial view for configuring sync
  function getSyncConfigurationView() as [Views] or [Views, InputDelegates] {
    return [new HomeView()];
  }
}

function getApp() as App {
  return Application.getApp() as App;
}
