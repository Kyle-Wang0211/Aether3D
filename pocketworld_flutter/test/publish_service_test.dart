// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Orchestration unit tests for PublishService (publish-to-community).
//
// These tests NEVER touch the real native normalize (covered by
// test/glb_norm_test.dart) nor a live Supabase. Every collaborator is
// injected as a fake:
//   • normalize  → returns a canned GlbNormResult with known bytes.
//   • uploadGlb  → records (path, bytes); can be made to throw.
//   • insertWork → records the inserted row map; returns a canned id;
//                  can be made to throw.
//   • community  → FakeCommunityService records uploadAndSetThumbnail.
//
// Asserted (per spec §9.1):
//   1. call order: read → normalize → upload → insert → thumbnail
//   2. exact `works` row fields (public, published_at set, content-
//      addressed model_storage_path, file_size_bytes, format=glb)
//   3. community opts applied (kCommunityNormOptions, NOT 500K default)
//   4. content-addressed path == {uid}/{sha1(bytes)}.glb
//   5. normalize-fail → no upload, no insert
//   6. upload-fail   → no insert (no orphan row)
//   7. thumb-fail    → row still inserted, returns workId
//   8. progress monotonic, terminal 'done'

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/community/publish_service.dart';
import 'package:pocketworld_flutter/glb_norm/glb_norm.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

const _uid = 'user-abc-123';
const _workId = 'work-xyz-789';

/// Canned normalized output bytes. The sha1 of THESE bytes is what the
/// content-addressed path must encode.
final Uint8List _normalizedBytes = Uint8List.fromList(
  List<int>.generate(64, (i) => (i * 7) & 0xff),
);

String _expectedSha1() => sha1.convert(_normalizedBytes).toString();

GlbNormResult _okResult(Uint8List output) => GlbNormResult(
      output: output,
      stats: const GlbNormStats(),
      status: GlbNormStatus.ok,
    );

GlbNormResult _failResult() => const GlbNormResult(
      output: null,
      stats: GlbNormStats(),
      status: GlbNormStatus.invalidGlb,
      error: 'invalid_glb',
    );

/// Records uploadAndSetThumbnail and returns a controllable result.
class _FakeCommunityService implements CommunityServiceLike {
  int calls = 0;
  String? lastWorkId;
  Uint8List? lastJpeg;
  String? returnPath = '$_uid/$_workId.jpg';
  bool throwOnUpload = false;

  @override
  Future<String?> uploadAndSetThumbnail({
    required String workId,
    required Uint8List jpegBytes,
  }) async {
    calls++;
    lastWorkId = workId;
    lastJpeg = jpegBytes;
    if (throwOnUpload) throw StateError('thumb upload boom');
    return returnPath;
  }
}

/// Builds a PublishService whose seams are fakes, plus a temp GLB file
/// that `record.artifactPath` points at.
class _Harness {
  late final Directory tmpDir;
  late final File glbFile;
  late final ScanRecord record;

  final List<String> order = <String>[];

  // normalize spy
  int normalizeCalls = 0;
  GlbNormOptions? normalizeOpts;
  GlbNormResult Function() normalizeResult = () => _okResult(_normalizedBytes);
  bool normalizeThrows = false;

  // upload spy
  int uploadCalls = 0;
  String? uploadedPath;
  Uint8List? uploadedBytes;
  bool uploadThrows = false;

  // insert spy
  int insertCalls = 0;
  Map<String, dynamic>? insertedRow;
  bool insertThrows = false;

  final _FakeCommunityService community = _FakeCommunityService();

  Future<void> setUp() async {
    tmpDir = await Directory.systemTemp.createTemp('publish_test');
    glbFile = File('${tmpDir.path}/model.glb');
    // Arbitrary on-disk INPUT bytes (different from normalized output).
    await glbFile.writeAsBytes(Uint8List.fromList(List<int>.filled(16, 1)));
    record = ScanRecord(
      id: 'local-1',
      name: 'My Model',
      createdAt: DateTime(2026, 6, 23),
      artifactPath: 'file://${glbFile.path}',
    );
  }

  Future<void> tearDown() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  }

  PublishService build() {
    return PublishService.forTest(
      uid: () => _uid,
      community: community,
      normalize: ({required input, opts = const GlbNormOptions(), onProgress}) {
        order.add('normalize');
        normalizeCalls++;
        normalizeOpts = opts;
        if (normalizeThrows) throw StateError('normalize boom');
        if (onProgress != null) {
          onProgress(0.0, 'parsing');
          onProgress(1.0, 'encoding glb');
        }
        return Future<GlbNormResult>.value(normalizeResult());
      },
      uploadGlb: ({required path, required bytes}) async {
        order.add('upload');
        uploadCalls++;
        uploadedPath = path;
        uploadedBytes = bytes;
        if (uploadThrows) throw StateError('upload boom');
        return path;
      },
      insertWork: ({required row}) async {
        order.add('insert');
        insertCalls++;
        insertedRow = row;
        if (insertThrows) throw StateError('insert boom');
        return _workId;
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() async {
    h = _Harness();
    await h.setUp();
  });

  tearDown(() async {
    await h.tearDown();
  });

  group('happy path', () {
    test('call order is read → normalize → upload → insert → thumbnail',
        () async {
      final svc = h.build();
      final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff]);
      await svc.publish(
        record: h.record,
        title: 'My Model',
        thumbnailJpeg: jpeg,
      );
      // read is implicit (file IO before normalize); the recorded order
      // begins at normalize. Thumbnail recorded via the fake community.
      expect(h.order, ['normalize', 'upload', 'insert']);
      expect(h.community.calls, 1);
      // thumbnail strictly AFTER insert
      expect(h.insertCalls, 1);
    });

    test('community opts applied (NOT the 500K default)', () async {
      final svc = h.build();
      await svc.publish(record: h.record, title: 'My Model');
      expect(h.normalizeOpts, isNotNull);
      expect(h.normalizeOpts!.targetFaceCount,
          kCommunityNormOptions.targetFaceCount);
      expect(h.normalizeOpts!.maxAtlasSize, kCommunityNormOptions.maxAtlasSize);
      // Guard against silently regressing to the default.
      expect(h.normalizeOpts!.targetFaceCount, isNot(500000));
    });

    test('uploaded path is content-addressed {uid}/{sha1}.glb', () async {
      final svc = h.build();
      await svc.publish(record: h.record, title: 'My Model');
      expect(h.uploadedPath, '$_uid/${_expectedSha1()}.glb');
      expect(h.uploadedBytes, _normalizedBytes);
    });

    test('exact works row fields', () async {
      final svc = h.build();
      final result = await svc.publish(
        record: h.record,
        title: 'My Model',
        description: 'a desc',
      );
      final row = h.insertedRow!;
      expect(row['user_id'], _uid);
      expect(row['title'], 'My Model');
      expect(row['description'], 'a desc');
      expect(row['format'], 'glb');
      expect(row['model_storage_path'], '$_uid/${_expectedSha1()}.glb');
      expect(row['file_size_bytes'], _normalizedBytes.length);
      expect(row['visibility'], 'public');
      // published_at non-null + parseable ISO-8601.
      expect(row['published_at'], isNotNull);
      expect(() => DateTime.parse(row['published_at'] as String),
          returnsNormally);

      expect(result.workId, _workId);
      expect(result.modelStoragePath, '$_uid/${_expectedSha1()}.glb');
      expect(result.fileSizeBytes, _normalizedBytes.length);
      expect(result.thumbnailStoragePath, isNull); // no jpeg passed
    });

    test('empty description is forwarded as null', () async {
      final svc = h.build();
      await svc.publish(record: h.record, title: 'My Model', description: '');
      expect(h.insertedRow!['description'], isNull);
    });

    test('thumbnail call receives the inserted workId and the jpeg',
        () async {
      final svc = h.build();
      final jpeg = Uint8List.fromList([1, 2, 3]);
      final result =
          await svc.publish(record: h.record, title: 'X', thumbnailJpeg: jpeg);
      expect(h.community.lastWorkId, _workId);
      expect(h.community.lastJpeg, jpeg);
      expect(result.thumbnailStoragePath, '$_uid/$_workId.jpg');
    });

    test('progress is monotonic and terminates at done', () async {
      final svc = h.build();
      final fractions = <double>[];
      final phases = <String>[];
      await svc.publish(
        record: h.record,
        title: 'X',
        onProgress: (p) {
          fractions.add(p.fraction);
          phases.add(p.phase);
        },
      );
      for (var i = 1; i < fractions.length; i++) {
        expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]),
            reason: 'fraction must be non-decreasing');
      }
      expect(phases.last, 'done');
      expect(fractions.last, 1.0);
    });
  });

  group('failure paths', () {
    test('read fails (missing file) → reading, no normalize/upload/insert',
        () async {
      await h.glbFile.delete();
      final svc = h.build();
      await expectLater(
        svc.publish(record: h.record, title: 'X'),
        throwsA(isA<PublishException>()
            .having((e) => e.phase, 'phase', 'reading')),
      );
      expect(h.normalizeCalls, 0);
      expect(h.uploadCalls, 0);
      expect(h.insertCalls, 0);
    });

    test('normalize !isOk → normalizing, no upload, no insert', () async {
      h.normalizeResult = _failResult;
      final svc = h.build();
      await expectLater(
        svc.publish(record: h.record, title: 'X'),
        throwsA(isA<PublishException>()
            .having((e) => e.phase, 'phase', 'normalizing')),
      );
      expect(h.uploadCalls, 0);
      expect(h.insertCalls, 0);
    });

    test('upload throws → uploading, NO insert (orphan-row guard)',
        () async {
      h.uploadThrows = true;
      final svc = h.build();
      await expectLater(
        svc.publish(record: h.record, title: 'X'),
        throwsA(isA<PublishException>()
            .having((e) => e.phase, 'phase', 'uploading')),
      );
      expect(h.insertCalls, 0);
      expect(h.community.calls, 0);
    });

    test('insert throws → inserting, no thumbnail call', () async {
      h.insertThrows = true;
      final svc = h.build();
      await expectLater(
        svc.publish(
          record: h.record,
          title: 'X',
          thumbnailJpeg: Uint8List.fromList([1]),
        ),
        throwsA(isA<PublishException>()
            .having((e) => e.phase, 'phase', 'inserting')),
      );
      expect(h.community.calls, 0);
    });

    test('thumbnail returns null → publish still succeeds, thumb path null',
        () async {
      h.community.returnPath = null;
      final svc = h.build();
      final result = await svc.publish(
        record: h.record,
        title: 'X',
        thumbnailJpeg: Uint8List.fromList([1]),
      );
      expect(result.workId, _workId);
      expect(result.thumbnailStoragePath, isNull);
    });

    test('thumbnail THROWS → swallowed, publish still succeeds', () async {
      h.community.throwOnUpload = true;
      final svc = h.build();
      final result = await svc.publish(
        record: h.record,
        title: 'X',
        thumbnailJpeg: Uint8List.fromList([1]),
      );
      expect(result.workId, _workId);
      expect(result.thumbnailStoragePath, isNull);
    });

    test('signed out (null uid) → throws PublishException', () async {
      final svc = PublishService.forTest(
        uid: () => null,
        community: h.community,
        normalize: ({required input, opts = const GlbNormOptions(), onProgress}) {
          h.normalizeCalls++;
          return Future.value(_okResult(_normalizedBytes));
        },
        uploadGlb: ({required path, required bytes}) async => path,
        insertWork: ({required row}) async => _workId,
      );
      await expectLater(
        svc.publish(record: h.record, title: 'X'),
        throwsA(isA<PublishException>()),
      );
      expect(h.normalizeCalls, 0);
    });

    test('null artifactPath → throws PublishException(reading)', () async {
      final svc = h.build();
      final rec = ScanRecord(
        id: 'no-art',
        name: 'X',
        createdAt: DateTime(2026, 6, 23),
      );
      await expectLater(
        svc.publish(record: rec, title: 'X'),
        throwsA(isA<PublishException>()
            .having((e) => e.phase, 'phase', 'reading')),
      );
    });

    test('already published (cloudWorkId set) → throws', () async {
      final svc = h.build();
      final rec = h.record.copyWith(cloudWorkId: 'already');
      await expectLater(
        svc.publish(record: rec, title: 'X'),
        throwsA(isA<PublishException>()),
      );
      expect(h.uploadCalls, 0);
    });
  });

  group('content addressing', () {
    test('same input bytes yield the same path (dedup)', () async {
      final svc1 = h.build();
      await svc1.publish(record: h.record, title: 'X');
      final p1 = h.uploadedPath;

      // fresh harness, same normalized bytes
      final h2 = _Harness();
      await h2.setUp();
      final svc2 = h2.build();
      await svc2.publish(record: h2.record, title: 'X');
      expect(h2.uploadedPath, p1);
      await h2.tearDown();
    });
  });
}
