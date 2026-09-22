import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'google_web_sign_in_button_stub.dart'
    if (dart.library.html) 'google_web_sign_in_button_web.dart' as platform;

/// GIS must own the web button so a click can open Google's interactive login,
/// including when the browser has no Google session. One Tap is not a fallback.
class GoogleWebSignInButton extends StatefulWidget {
  const GoogleWebSignInButton({
    super.key,
    required this.googleSignIn,
    required this.onSignedIn,
    this.enabled = true,
  });

  final GoogleSignIn googleSignIn;
  final Future<void> Function(GoogleSignInAccount account) onSignedIn;
  final bool enabled;

  @override
  State<GoogleWebSignInButton> createState() => _GoogleWebSignInButtonState();
}

class _GoogleWebSignInButtonState extends State<GoogleWebSignInButton> {
  late final StreamSubscription<GoogleSignInAccount?> _subscription;
  late Future<void> _ready;
  bool _handling = false;
  String? _error;
  double? _buttonWidth;
  Widget? _button;

  @override
  void initState() {
    super.initState();
    _subscription = widget.googleSignIn.onCurrentUserChanged.listen(_onAccount);
    _ready = _prepare();
  }

  Future<void> _prepare() async {
    // Initializes GIS and its credential stream without prompting One Tap.
    // Reset only the app's Google state, not the browser's Google session.
    await widget.googleSignIn.signOut().timeout(const Duration(seconds: 15));
  }

  Future<void> _onAccount(GoogleSignInAccount? account) async {
    if (!mounted ||
        account == null ||
        !widget.enabled ||
        _handling ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    setState(() {
      _handling = true;
      _error = null;
    });
    try {
      await widget.onSignedIn(account);
    } catch (_) {
      if (mounted) _error = 'הכניסה עם Google נכשלה. אפשר לנסות שוב.';
    } finally {
      if (mounted) {
        // A refused server login must still allow choosing the same account
        // again: google_sign_in emits only changes to the current account.
        setState(() {
          _handling = false;
          _ready = _prepare();
        });
      }
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return TextButton.icon(
              onPressed: widget.enabled
                  ? () => setState(() {
                        _ready = _prepare();
                      })
                  : null,
              icon: const Icon(Icons.refresh),
              label: const Text('טעינת Google נכשלה — נסה שוב'),
            );
          }
          if (snapshot.connectionState != ConnectionState.done ||
              !widget.enabled ||
              _handling) {
            return const SizedBox(
              height: 44,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child:
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              LayoutBuilder(builder: (context, constraints) {
                final width = constraints.maxWidth.clamp(1.0, 400.0);
                if (_button == null || _buttonWidth != width) {
                  _buttonWidth = width;
                  _button = platform.renderGoogleSignInButton(width);
                }
                return Center(child: _button);
              }),
            ],
          );
        },
      );
}
