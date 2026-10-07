import 'dart:async';

import 'package:betshuva/listing_video_draft.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

class _VideoPicker extends ImagePickerPlatform {
  _VideoPicker(this.file);
  final XFile? file;
  final sources = <ImageSource>[];

  @override
  Future<XFile?> getVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) async {
    sources.add(source);
    return file;
  }
}

Widget _picker(ListingVideoDraft draft, Future<String> Function(XFile) upload,
        {Future<bool> Function(XFile)? validate,
        bool enabled = true,
        ValueChanged<bool>? onPreparingChanged}) =>
    MaterialApp(
      home: Scaffold(
        body: ListingVideoPicker(
          draft: draft,
          upload: upload,
          validate: validate ?? (_) async => true,
          enabled: enabled,
          onPreparingChanged: onPreparingChanged,
          preview: (url) => Text('preview:$url'),
        ),
      ),
    );

void _installPicker(_VideoPicker picker) {
  final previous = ImagePickerPlatform.instance;
  ImagePickerPlatform.instance = picker;
  addTearDown(() => ImagePickerPlatform.instance = previous);
}

void main() {
  test('pending replacement survives disposal and retains its original video',
      () async {
    final draft = ListingVideoDraft()..load('old.mp4');
    final file = XFile('new.mp4', name: 'new.mp4');
    final gate = Completer<String>();
    var notifications = 0;
    var uploads = 0;
    draft.addListener(() => notifications++);
    final operation = draft.upload(file, (_) {
      uploads++;
      return gate.future;
    });
    final pending = draft.pendingUpload!;
    expect(draft.uploading, isTrue);
    expect(draft.url, 'old.mp4');
    expect(draft.changed, isFalse);
    expect(draft.fileName, 'new.mp4');
    await draft.upload(XFile('second.mp4', name: 'second.mp4'), (_) async {
      uploads++;
      return 'second.mp4';
    });
    draft.remove();
    expect(uploads, 1);
    expect(draft.url, 'old.mp4');
    expect(draft.pendingUpload, same(pending));
    draft.dispose();
    gate.complete('approved.mp4');
    final attachment = await pending;
    await operation;
    expect(attachment!.video, isTrue);
    expect(attachment.url, 'approved.mp4');
    expect(attachment.expectedOldUrl, 'old.mp4');
    expect(draft.changed, isTrue);
    expect(draft.uploading, isFalse);
    expect(draft.pendingUpload, isNull);
    expect(notifications, 1, reason: 'Disposed forms receive no notifications');
  });

  test('failed replacement retains the old video and retries the same file',
      () async {
    final draft = ListingVideoDraft()..load('old.mp4');
    addTearDown(draft.dispose);
    final file = XFile('replacement.mp4', name: 'replacement.mp4');
    final files = <XFile>[];
    Future<String> send(XFile selected) async {
      files.add(selected);
      if (files.length == 1) throw Exception('הסרטון לא אושר');
      return 'approved.mp4';
    }

    final first = draft.upload(file, send);
    final firstPending = draft.pendingUpload!;
    await first;
    expect(await firstPending, isNull);
    expect(draft.url, 'old.mp4');
    expect(draft.changed, isFalse);
    expect(draft.error, 'הסרטון לא אושר');
    final retry = draft.retry(send);
    final retryPending = draft.pendingUpload!;
    await retry;
    final attachment = await retryPending;
    expect(attachment!.expectedOldUrl, 'old.mp4');
    expect(attachment.video, isTrue);
    expect(files, [same(file), same(file)]);
    expect(draft.url, 'approved.mp4');
    expect(draft.error, isNull);
    await draft.retry(send);
    expect(files.length, 2);
    draft.remove();
    expect(draft.url, isNull);
    expect(draft.fileName, isNull);
    expect(draft.changed, isTrue);
  });

  test('empty approved URL cannot replace an existing video', () async {
    final draft = ListingVideoDraft()..load('old.mp4');
    addTearDown(draft.dispose);
    final upload = draft.upload(
        XFile('replacement.mp4', name: 'replacement.mp4'), (_) async => '  ');
    final pending = draft.pendingUpload!;
    await upload;
    expect(await pending, isNull);
    expect(draft.url, 'old.mp4');
    expect(draft.changed, isFalse);
    expect(draft.error, contains('לא התקבלה כתובת לסרטון'));
  });

  testWidgets('gallery selection keeps one upload alive after picker closes',
      (tester) async {
    final file = XFile('gallery.mp4', name: 'gallery.mp4');
    final picker = _VideoPicker(file);
    _installPicker(picker);
    final draft = ListingVideoDraft();
    final gate = Completer<String>();
    final files = <XFile>[];
    final preparing = <bool>[];
    await tester.pumpWidget(_picker(draft, (file) {
      files.add(file);
      return gate.future;
    }, onPreparingChanged: (value) {
      preparing.add(value);
      if (!value) expect(draft.pendingUpload, isNotNull);
    }));
    await tester.tap(find.text('בחירת סרטון'));
    await tester.pump();
    expect(picker.sources, [ImageSource.gallery]);
    expect(files, [same(file)]);
    expect(preparing, [true, false]);
    expect(find.text('הסרטון עולה ונבדק. אפשר לשמור את המודעה ולהמשיך'),
        findsOneWidget);
    final pending = draft.pendingUpload!;
    final select = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'בחירת סרטון'));
    final camera = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'צילום סרטון'));
    expect(select.onPressed, isNull);
    expect(camera.onPressed, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    draft.dispose();
    gate.complete('approved.mp4');
    final attachment = await pending;
    expect(attachment!.url, 'approved.mp4');
    expect(attachment.video, isTrue);
    expect(attachment.expectedOldUrl, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid gallery video is rejected before upload',
      (tester) async {
    final file = XFile('long.mp4', name: 'long.mp4');
    final picker = _VideoPicker(file);
    _installPicker(picker);
    final draft = ListingVideoDraft();
    addTearDown(draft.dispose);
    var uploads = 0;
    await tester.pumpWidget(_picker(draft, (_) async {
      uploads++;
      return 'unapproved.mp4';
    }, validate: (picked) async {
      expect(picked, same(file));
      return false;
    }));
    await tester.tap(find.text('בחירת סרטון'));
    await tester.pumpAndSettle();
    expect(uploads, 0);
    expect(draft.pendingUpload, isNull);
    expect(draft.url, isNull);
    expect(draft.changed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saving during duration validation does not start a late upload',
      (tester) async {
    final picker = _VideoPicker(XFile('gallery.mp4', name: 'gallery.mp4'));
    _installPicker(picker);
    final draft = ListingVideoDraft();
    addTearDown(draft.dispose);
    final validation = Completer<bool>();
    final preparing = <bool>[];
    var uploads = 0;
    Future<String> upload(XFile _) async {
      uploads++;
      return 'approved.mp4';
    }

    await tester.pumpWidget(_picker(draft, upload,
        validate: (_) => validation.future, onPreparingChanged: preparing.add));
    await tester.tap(find.text('בחירת סרטון'));
    await tester.pump();
    expect(draft.pendingUpload, isNull);
    expect(preparing, [true]);
    await tester.pumpWidget(_picker(draft, upload,
        validate: (_) => validation.future,
        enabled: false,
        onPreparingChanged: preparing.add));
    validation.complete(true);
    await tester.pumpAndSettle();
    expect(uploads, 0);
    expect(preparing, [true, false]);
    expect(draft.changed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replacement error leaves preview and offers retry and removal',
      (tester) async {
    final file = XFile('gallery.mp4', name: 'gallery.mp4');
    _installPicker(_VideoPicker(file));
    final draft = ListingVideoDraft()..load('old.mp4');
    addTearDown(draft.dispose);
    var uploads = 0;
    await tester.pumpWidget(_picker(draft, (selected) async {
      expect(selected, same(file));
      if (++uploads == 1) throw Exception('הסריקה לא אישרה את הסרטון');
      return 'approved.mp4';
    }));
    await tester.tap(find.text('החלפת סרטון'));
    await tester.pumpAndSettle();
    expect(find.text('preview:old.mp4'), findsOneWidget);
    expect(find.text('הסריקה לא אישרה את הסרטון'), findsOneWidget);
    await tester.tap(find.text('ניסיון נוסף להעלאת הסרטון'));
    await tester.pumpAndSettle();
    expect(uploads, 2);
    expect(find.text('preview:approved.mp4'), findsOneWidget);
    expect(find.text('הסריקה לא אישרה את הסרטון'), findsNothing);
    await tester.tap(find.text('הסרת סרטון'));
    await tester.pumpAndSettle();
    expect(draft.url, isNull);
    expect(draft.changed, isTrue);
    expect(find.text('בחירת סרטון'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
