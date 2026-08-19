import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:time_app/features/chatbot/application/model_setup_controller.dart';
import 'package:time_app/features/chatbot/data/model_downloader.dart';
import 'package:time_app/features/chatbot/data/model_manifest.dart';
import 'package:time_app/features/chatbot/data/model_store.dart';
import 'package:time_app/features/chatbot/domain/model_setup_state.dart';

/// Part 1 of the on-device chatbot: acquiring the model files.
///
/// The two things worth testing here are the two that can silently produce a
/// **corrupt file that looks finished** — the resume/restart decision, and the
/// verify-before-install discipline. Everything else in the feature is UI.
void main() {
  late Directory temp;
  late ModelStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('chatbot_model_test');
    // The real manifest's digests describe 143MB of release assets, which no
    // test can produce. `_testManifest` describes the body the mock server
    // returns instead, so the state-machine tests run the **strict** digest
    // path — the one that ships — rather than a weakened one.
    store = ModelStore(supportDirectory: () async => temp, files: _testManifest);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  // ---- the manifest -------------------------------------------------------

  group('manifest', () {
    test('every filename is safe to append to a directory path', () {
      // A name with a separator in it would place a downloaded file outside the
      // model directory, where deleteAll would never find it again.
      for (final file in kModelFiles) {
        expect(file.isSafeName, isTrue, reason: 'unsafe name: ${file.name}');
      }
    });

    test('filenames are unique', () {
      final names = kModelFiles.map((f) => f.name).toSet();
      expect(names, hasLength(kModelFiles.length));
    });

    test('a URL is the base plus the name', () {
      expect(kModelFiles.first.url,
          '$kModelReleaseBaseUrl/${kModelFiles.first.name}');
    });

    test('the total is null while any size is unknown', () {
      // UI-RULES.md §6.7: never fake a total. This is the value the UI reads to
      // decide between a bar and a spinner.
      final anyUnknown = kModelFiles.any((f) => f.sizeBytes == null);
      expect(kModelTotalBytes == null, anyUnknown);
    });

    test('every shipped file is strongly verifiable', () {
      // The whole point of the release being real: size alone would accept a
      // 118MB file of the right length and the wrong contents. If a future
      // model revision lands without its digests filled in, this fails here
      // rather than on someone's phone.
      for (final file in kModelFiles) {
        expect(file.isPlaceholder, isFalse,
            reason: '${file.name} has no digest or no size');
        expect(file.sha256, hasLength(64), reason: file.name);
        expect(file.sizeBytes, greaterThan(0), reason: file.name);
      }
    });

    test('the names are the release asset names, exactly', () {
      // These strings ARE the URLs. A rename on the release side, or a typo
      // here, is a 404 the user reads as "the app needs an update" — worth
      // pinning rather than discovering on a device.
      expect(kModelFiles.map((f) => f.name), [
        'minilm-multilingual.int8.onnx',
        'tokenizer.json',
        'subs_embeddings_int8.npz',
        'subs_meta.json',
        'subs_en.json',
      ]);
      expect(kModelTotalBytes, 143450484);
    });

    test('a file with no digest and no size reports itself as a placeholder',
        () {
      const placeholder = ModelFile(name: 'a.bin', description: 'A');
      const real = ModelFile(
          name: 'b.bin', description: 'B', sha256: 'ab', sizeBytes: 1);
      expect(placeholder.isPlaceholder, isTrue);
      expect(real.isPlaceholder, isFalse);
    });
  });

  // ---- verification -------------------------------------------------------

  group('ModelStore.verifyAt', () {
    test('missing file', () async {
      final expected = _fileFor('x.bin', 'hello');
      expect(await store.verifyAt(File('${temp.path}/nope.bin'), expected),
          ModelFileProblem.missing);
    });

    test('right bytes verifies', () async {
      final expected = _fileFor('x.bin', 'hello');
      final actual = _write('x.bin', 'hello');
      expect(await store.verifyAt(actual, expected), isNull);
    });

    test('wrong length is caught before the hash', () async {
      final expected = _fileFor('x.bin', 'hello');
      final actual = _write('x.bin', 'hello there');
      expect(await store.verifyAt(actual, expected), ModelFileProblem.wrongSize);
    });

    test('right length, wrong bytes is caught by the hash', () async {
      final expected = _fileFor('x.bin', 'hello');
      // Same five bytes' worth of length, different content — the exact case a
      // size check alone would wave through.
      final actual = _write('x.bin', 'olleh');
      expect(
          await store.verifyAt(actual, expected), ModelFileProblem.wrongChecksum);
    });

    test('digest comparison is case-insensitive', () async {
      final lower = _fileFor('x.bin', 'hello');
      final upper = ModelFile(
        name: lower.name,
        description: lower.description,
        sha256: lower.sha256!.toUpperCase(),
        sizeBytes: lower.sizeBytes,
      );
      expect(await store.verifyAt(_write('x.bin', 'hello'), upper), isNull);
    });

    test('a placeholder entry verifies on presence alone', () async {
      // Null digest and null size mean "verify what is knowable" — the byte
      // count against Content-Length, which happens in the downloader. The
      // store must not invent a failure it cannot substantiate.
      const placeholder = ModelFile(name: 'x.bin', description: 'X');
      expect(await store.verifyAt(_write('x.bin', 'anything'), placeholder),
          isNull);
    });
  });

  group('ModelStore', () {
    test('install renames the part file onto the real name', () async {
      final file = _fileFor('x.bin', 'hello');
      (await store.partFileFor(file)).writeAsStringSync('hello');

      await store.install(file);

      expect((await store.partFileFor(file)).existsSync(), isFalse);
      expect(await store.verify(file), isNull);
    });

    test('install replaces a previously installed file', () async {
      final file = _fileFor('x.bin', 'new');
      (await store.fileFor(file)).writeAsStringSync('old and longer');
      (await store.partFileFor(file)).writeAsStringSync('new');

      await store.install(file);

      expect((await store.fileFor(file)).readAsStringSync(), 'new');
    });

    test('partialBytes reports a resumable prefix, and zero when clean',
        () async {
      final file = _fileFor('x.bin', 'hello');
      expect(await store.partialBytes(file), 0);

      (await store.partFileFor(file)).writeAsStringSync('hel');
      expect(await store.partialBytes(file), 3);

      await store.discardPartial(file);
      expect(await store.partialBytes(file), 0);
    });

    test('isReady is false while any manifest file is absent', () async {
      expect(await store.isReady(), isFalse);
    });

    test('deleteAll removes the directory and its contents', () async {
      final file = _fileFor('x.bin', 'hello');
      (await store.fileFor(file)).writeAsStringSync('hello');

      await store.deleteAll();

      expect(Directory('${temp.path}/chatbot_model').existsSync(), isFalse);
    });
  });

  // ---- downloading --------------------------------------------------------

  group('ModelDownloader', () {
    test('a clean download installs a verified file', () async {
      final file = _fileFor('x.bin', 'hello world');
      final downloader = ModelDownloader(
        store,
        client: _server(body: 'hello world'),
      );

      final progress = <(int, int?)>[];
      await downloader.ensure(file, onProgress: (r, t) => progress.add((r, t)));

      expect((await store.fileFor(file)).readAsStringSync(), 'hello world');
      expect((await store.partFileFor(file)).existsSync(), isFalse);
      expect(progress.last, (11, 11));
    });

    test('an already-good file is not downloaded again', () async {
      final file = _fileFor('x.bin', 'hello');
      (await store.fileFor(file)).writeAsStringSync('hello');

      var called = false;
      final downloader = ModelDownloader(
        store,
        client: MockClient.streaming((_, _) async {
          called = true;
          return http.StreamedResponse(const Stream.empty(), 200);
        }),
      );

      await downloader.ensure(file, onProgress: (_, _) {});
      expect(called, isFalse);
    });

    test('a partial download resumes and asks for the right range', () async {
      final file = _fileFor('x.bin', 'hello world');
      (await store.partFileFor(file)).writeAsStringSync('hello ');

      String? rangeHeader;
      final downloader = ModelDownloader(
        store,
        client: MockClient.streaming((request, _) async {
          rangeHeader = request.headers['Range'];
          // 206 carries the length of the RANGE, not of the whole file.
          return _response(206, 'world');
        }),
      );

      await downloader.ensure(file, onProgress: (_, _) {});

      expect(rangeHeader, 'bytes=6-');
      expect((await store.fileFor(file)).readAsStringSync(), 'hello world');
    });

    test(
        'a server that ignores Range and answers 200 restarts instead of '
        'appending', () async {
      // The corruption this whole design exists to prevent: appending a full
      // body to a partial file yields a plausible-looking file of wrong length.
      final file = _fileFor('x.bin', 'hello world');
      (await store.partFileFor(file)).writeAsStringSync('hello ');

      final downloader = ModelDownloader(
        store,
        client: _server(body: 'hello world', status: 200),
      );

      await downloader.ensure(file, onProgress: (_, _) {});

      expect((await store.fileFor(file)).readAsStringSync(), 'hello world');
    });

    test('416 discards the stale part and fails asking for a fresh start',
        () async {
      final file = _fileFor('x.bin', 'hello');
      (await store.partFileFor(file)).writeAsStringSync('hello and then some');

      final downloader = ModelDownloader(
        store,
        client: MockClient.streaming((_, _) async => _response(416, '')),
      );

      await expectLater(
        downloader.ensure(file, onProgress: (_, _) {}),
        throwsA(isA<ModelDownloadFailure>()
            .having((e) => e.message, 'message', contains('start it fresh'))),
      );
      expect(await store.partialBytes(file), 0);
    });

    test('404 says the build is pointing at the wrong release', () async {
      final file = _fileFor('x.bin', 'hello');
      final downloader = ModelDownloader(
        store,
        client: MockClient.streaming((_, _) async => _response(404, '')),
      );

      await expectLater(
        downloader.ensure(file, onProgress: (_, _) {}),
        throwsA(isA<ModelDownloadFailure>()
            .having((e) => e.message, 'message', contains('needs an update'))),
      );
    });

    test('a truncated stream fails and KEEPS the part for a resume', () async {
      final file = _fileFor('x.bin', 'hello world');
      // Declares 11 bytes, delivers 6.
      final downloader = ModelDownloader(
        store,
        client: MockClient.streaming((_, _) async => http.StreamedResponse(
              Stream.value(utf8.encode('hello ')),
              200,
              contentLength: 11,
            )),
      );

      await expectLater(
        downloader.ensure(file, onProgress: (_, _) {}),
        throwsA(isA<ModelDownloadFailure>().having(
            (e) => e.message, 'message', contains('picks up where it left'))),
      );
      // The whole point: the next attempt resumes rather than restarting.
      expect(await store.partialBytes(file), 6);
      expect((await store.fileFor(file)).existsSync(), isFalse);
    });

    test('bytes that arrive complete but wrong are discarded, not installed',
        () async {
      final file = _fileFor('x.bin', 'hello world');
      final downloader = ModelDownloader(
        store,
        // Right length, wrong content — only the checksum catches this.
        client: _server(body: 'HELLO WORLD'),
      );

      await expectLater(
        downloader.ensure(file, onProgress: (_, _) {}),
        throwsA(isA<ModelDownloadFailure>()
            .having((e) => e.message, 'message', contains('damaged'))),
      );
      expect((await store.fileFor(file)).existsSync(), isFalse);
      // Discarded rather than kept: resuming from known-bad bytes would append
      // good bytes to bad ones forever.
      expect(await store.partialBytes(file), 0);
    });

    test('an installed-but-corrupt file is replaced, not left beside the part',
        () async {
      final file = _fileFor('x.bin', 'hello');
      (await store.fileFor(file)).writeAsStringSync('junk!');

      final downloader = ModelDownloader(store, client: _server(body: 'hello'));
      await downloader.ensure(file, onProgress: (_, _) {});

      expect(await store.verify(file), isNull);
    });

    test('no connection reads as a connection problem', () async {
      final file = _fileFor('x.bin', 'hello');
      final downloader = ModelDownloader(
        store,
        client: MockClient.streaming(
            (_, _) async => throw const SocketException('nope')),
      );

      await expectLater(
        downloader.ensure(file, onProgress: (_, _) {}),
        throwsA(isA<ModelDownloadFailure>().having((e) => e.message, 'message',
            contains('internet connection'))),
      );
    });

    test('an unknown Content-Length yields a null total, never a fake one',
        () async {
      final file = _fileFor('x.bin', 'hello');
      final downloader = ModelDownloader(
        store,
        client: MockClient.streaming((_, _) async => http.StreamedResponse(
              Stream.value(utf8.encode('hello')),
              200,
            )),
      );

      final totals = <int?>[];
      await downloader.ensure(file, onProgress: (_, t) => totals.add(t));

      expect(totals, everyElement(isNull));
    });
  });

  // ---- the state machine --------------------------------------------------

  group('ModelSetupController', () {
    test('downloads every manifest file and ends ready', () async {
      final container = _container(store, _server(body: 'x'));
      addTearDown(container.dispose);

      final state = await _settle(container);

      expect(state, isA<ModelReady>());
      expect(await store.isReady(), isTrue);
    });

    test('files already on disk go straight to ready with no network',
        () async {
      for (final file in store.files) {
        (await store.fileFor(file)).writeAsStringSync('x');
      }
      var called = false;
      final container = _container(
        store,
        MockClient.streaming((_, _) async {
          called = true;
          return _response(200, 'x');
        }),
      );
      addTearDown(container.dispose);

      expect(await _settle(container), isA<ModelReady>());
      expect(called, isFalse);
    });

    test('entering the feature checks, and downloads NOTHING', () async {
      // 143MB is not something to start on someone's behalf because they opened
      // a screen. `build` may look at the disk; only a tap may open a socket.
      var called = false;
      final container = _container(
        store,
        MockClient.streaming((_, _) async {
          called = true;
          return _response(200, 'x');
        }),
      );
      addTearDown(container.dispose);

      container.read(modelSetupControllerProvider);
      await Future<void>.delayed(Duration.zero);
      await container.read(modelSetupControllerProvider.notifier).check();

      expect(called, isFalse);
      expect(container.read(modelSetupControllerProvider), isA<ModelNeeded>());
    });

    test('the check offers the total size, so the prompt can state it', () async {
      final container = _container(store, _server(body: 'x'));
      addTearDown(container.dispose);

      await container.read(modelSetupControllerProvider.notifier).check();
      final state = container.read(modelSetupControllerProvider) as ModelNeeded;
      expect(state.totalBytes, kModelTotalBytes);
    });

    test('a returning user with the files already there checks straight to ready',
        () async {
      for (final file in store.files) {
        (await store.fileFor(file)).writeAsStringSync('x');
      }
      final container = _container(store, _server(body: 'x'));
      addTearDown(container.dispose);

      await container.read(modelSetupControllerProvider.notifier).check();
      expect(container.read(modelSetupControllerProvider), isA<ModelReady>());
    });

    test('a check while a download is running does not stomp on its progress',
        () async {
      // Re-reading the disk mid-download would report ModelNeeded over live
      // progress, and the screen would offer a Download button for a download
      // already in flight.
      final gate = Completer<void>();
      final container = _container(
        store,
        MockClient.streaming((_, _) async {
          await gate.future;
          return _response(200, 'x');
        }),
      );
      addTearDown(container.dispose);

      final notifier = container.read(modelSetupControllerProvider.notifier);
      final run = notifier.start();
      await Future<void>.delayed(Duration.zero);

      await notifier.check();
      expect(container.read(modelSetupControllerProvider), isNot(isA<ModelNeeded>()));

      gate.complete();
      await run;
      expect(container.read(modelSetupControllerProvider), isA<ModelReady>());
    });

    test('a failure surfaces the message the layer below wrote', () async {
      final container = _container(
        store,
        MockClient.streaming((_, _) async => _response(404, '')),
      );
      addTearDown(container.dispose);

      final state = await _settle(container);
      expect(state, isA<ModelFailed>());
      expect((state as ModelFailed).message, contains('needs an update'));
    });

    test('retry after a failure completes', () async {
      var failNext = true;
      final container = _container(
        store,
        MockClient.streaming((_, _) async {
          if (failNext) {
            failNext = false;
            return _response(500, '');
          }
          return _response(200, 'x');
        }),
      );
      addTearDown(container.dispose);

      expect(await _settle(container), isA<ModelFailed>());

      await container.read(modelSetupControllerProvider.notifier).start();
      expect(container.read(modelSetupControllerProvider), isA<ModelReady>());
    });

    test('a second start while one is running is ignored', () async {
      final gate = Completer<void>();
      final container = _container(
        store,
        MockClient.streaming((_, _) async {
          await gate.future;
          return _response(200, 'x');
        }),
      );
      addTearDown(container.dispose);

      final notifier = container.read(modelSetupControllerProvider.notifier);
      await Future<void>.delayed(Duration.zero); // let build's own run begin
      final first = notifier.start();
      final second = notifier.start();

      // The same run, not a second writer on the same `.part` file.
      expect(identical(first, second), isTrue);

      gate.complete();
      await first;
      expect(container.read(modelSetupControllerProvider), isA<ModelReady>());
    });
  });
}

// ---- helpers --------------------------------------------------------------

/// A stand-in manifest for the state-machine tests: four entries whose digests
/// and sizes describe the body `_server` returns.
///
/// Same shape as the real one (four files, big-to-small), so the "File n of 4"
/// bookkeeping is exercised for real.
final List<ModelFile> _testManifest = [
  _fileFor('model.onnx', 'x'),
  _fileFor('tokenizer.json', 'x'),
  _fileFor('embeddings.npz', 'x'),
  _fileFor('meta.json', 'x'),
];

/// A manifest entry whose digest and size describe [content] exactly, so the
/// strict verification path is what runs — the placeholder path is tested
/// separately and on purpose.
ModelFile _fileFor(String name, String content) {
  final bytes = utf8.encode(content);
  return ModelFile(
    name: name,
    description: 'Test file',
    sha256: sha256.convert(bytes).toString(),
    sizeBytes: bytes.length,
  );
}

File _write(String name, String content) {
  final dir = Directory.systemTemp;
  final file = File('${dir.createTempSync('chatbot_verify').path}/$name')
    ..writeAsStringSync(content);
  addTearDown(() {
    if (file.parent.existsSync()) file.parent.deleteSync(recursive: true);
  });
  return file;
}

http.StreamedResponse _response(int status, String body) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream.value(bytes),
    status,
    contentLength: bytes.length,
  );
}

/// A server that always answers with [body], in chunks, so the progress and
/// append paths run for real rather than as a single write.
MockClient _server({required String body, int status = 206}) {
  return MockClient.streaming((request, _) async {
    final bytes = utf8.encode(body);
    // Only claim partial content when a range was actually asked for; a plain
    // request gets a plain 200.
    final code = request.headers.containsKey('Range') ? status : 200;
    return http.StreamedResponse(
      Stream.fromIterable(bytes.map((b) => [b])),
      code,
      contentLength: bytes.length,
    );
  });
}

ProviderContainer _container(ModelStore store, http.Client client) {
  return ProviderContainer(
    overrides: [
      chatbotModelStoreProvider.overrideWithValue(store),
      chatbotModelDownloaderProvider
          .overrideWithValue(ModelDownloader(store, client: client)),
    ],
  );
}

/// Read the controller, then wait for the run its `build` kicked off.
Future<ModelSetupState> _settle(ProviderContainer container) async {
  container.read(modelSetupControllerProvider);
  // `build` defers the first run by a microtask; `start` is re-entrant-safe, so
  // awaiting it here either joins the in-flight run or is a no-op after it.
  await Future<void>.delayed(Duration.zero);
  await container.read(modelSetupControllerProvider.notifier).start();
  return container.read(modelSetupControllerProvider);
}
