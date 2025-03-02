using Toybox.Application;
using Toybox.Graphics;
using Toybox.WatchUi;
using Toybox.Communications;
using Toybox.Lang;

// View to get the OAuth credentials from the user
class OauthView extends WatchUi.View {
  function initialize() {
    View.initialize();

    Communications.registerForOAuthMessages(method(:onOAuthComplete));
    Communications.makeOAuthRequest(
      Constants.PROVIDER_URL,
      { "redirectUrl" => Constants.REDIRECT_URL },
      Constants.REDIRECT_URL,
      Communications.OAUTH_RESULT_TYPE_URL,
      { "token" => "token", "errorMessage" => "errorMessage" }
    );
  }

  // Update the view
  function onUpdate(dc) {
    var configureSyncMessage = Application.loadResource(
      Rez.Strings.continueOnPhone
    );

    dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
    dc.clear();
    dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);

    dc.drawText(
      dc.getWidth() / 2,
      dc.getHeight() / 2,
      Graphics.FONT_SMALL,
      configureSyncMessage,
      Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
    );
  }

  // Callback for OAuth completion
  function onOAuthComplete(response as Communications.OAuthMessage) as Void {
    var data = response.data as Lang.Dictionary;
    // If OK, store the token. Otherwise show the error.
    if (response.responseCode == 200 && response.data != null) {
      var token = data["token"];
      if (token != null) {
        Application.Properties.setValue("AUTHENTICATION_TOKEN", token);
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
      }
    } else if (data != null) {
      var message = "Unable to get token:\n" + data["errorMessage"];
      WatchUi.switchToView(
        new ErrorView(message),
        null,
        WatchUi.SLIDE_IMMEDIATE
      );
    } else {
      var message = "Unable to get token:\nUnknown error";
      WatchUi.switchToView(
        new ErrorView(message),
        null,
        WatchUi.SLIDE_IMMEDIATE
      );
    }
  }
}
