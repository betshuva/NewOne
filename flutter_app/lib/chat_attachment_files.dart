const maxChatAttachments = 20;

// Matches the upload endpoint's supported formats; the server still validates
// the actual content and applies sender/recipient moderation to every file.
const _types = <String, String>{
  'jpg': 'image',
  'jpeg': 'image',
  'png': 'image',
  'webp': 'image',
  'gif': 'image',
  'pdf': 'document',
  'docx': 'document',
  'xlsx': 'document',
  'mp3': 'audio',
  'aac': 'audio',
  'm4a': 'audio',
  'ogg': 'audio',
  'wav': 'audio',
  'mp4': 'video',
  'webm': 'video',
  'mov': 'video',
};

final chatAttachmentExtensions = _types.keys.toList(growable: false);

String? chatAttachmentType(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? null : _types[name.substring(dot + 1).toLowerCase()];
}
