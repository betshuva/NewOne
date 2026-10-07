import 'package:http/http.dart' as http;

class ListingUploadBrowser {
  void install() {}
  List<http.Request> get requests => const [];
  List<Map<String, dynamic>> get records => const [];
  List<Map<String, dynamic>> get chunks => const [];
  void failOnce(String name, int status, Map<String, dynamic> body) {}
  void markPending(String name) {}
  void complete(String name) {}
  void dispose() {}
}
