import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as google;

Widget renderGoogleSignInButton(double width) => google.renderButton(
      configuration: google.GSIButtonConfiguration(
        type: google.GSIButtonType.standard,
        theme: google.GSIButtonTheme.outline,
        size: google.GSIButtonSize.large,
        text: google.GSIButtonText.continueWith,
        shape: google.GSIButtonShape.pill,
        minimumWidth: width,
        locale: 'he',
      ),
    );
