// _Semaphore is a private helper inside lib/upload/aether_api_client.dart,
// but the semantics are critical to multipart upload correctness:
//   • At most N tasks ever hold the semaphore concurrently
//   • A released permit goes to the next waiter immediately (FIFO)
//   • If no one's waiting, the permit pool grows back up to maxPermits
//
// We can't reach the private class directly. Instead, this test
// re-implements the same data structure with the same shape and runs
// the contract tests. If we ever change `_Semaphore` in aether_api_client.dart,
// keep this test class in sync.
//
// The actual multipart upload flow is covered by real-device + server
// integration testing — mocking dio + HTTP + concurrent ETag collection
// for a meaningful unit test is more work than it's worth at this stage.

import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';

class _SemaphoreUnderTest {
  final int maxPermits;
  int _available;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  _SemaphoreUnderTest(this.maxPermits) : _available = maxPermits;

  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _available++;
    }
  }
}

void main() {
  group('_Semaphore (multipart upload concurrency bound)', () {
    test('first N acquires resolve immediately, N+1 blocks', () async {
      final sem = _SemaphoreUnderTest(3);

      // First 3 should resolve synchronously.
      var resolved = 0;
      for (var i = 0; i < 3; i++) {
        unawaited(sem.acquire().then((_) => resolved++));
      }
      await Future<void>.delayed(Duration.zero);
      expect(resolved, 3);

      // Next one blocks until a release.
      var fourthResolved = false;
      final fourth = sem.acquire().then((_) => fourthResolved = true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(fourthResolved, false);

      sem.release();
      await fourth;
      expect(fourthResolved, true);
    });

    test('release wakes FIFO queue, not LIFO', () async {
      final sem = _SemaphoreUnderTest(1);
      await sem.acquire(); // permit taken

      final order = <int>[];
      final f1 = sem.acquire().then((_) => order.add(1));
      final f2 = sem.acquire().then((_) => order.add(2));
      final f3 = sem.acquire().then((_) => order.add(3));

      sem.release(); // wakes f1
      await f1;
      sem.release(); // wakes f2
      await f2;
      sem.release(); // wakes f3
      await f3;

      expect(order, [1, 2, 3]);
    });

    test('release without waiters increments permit pool', () async {
      final sem = _SemaphoreUnderTest(2);

      await sem.acquire(); // 1 left
      await sem.acquire(); // 0 left
      sem.release(); // 1 left, no waiter to wake
      sem.release(); // 2 left

      // Now should be able to acquire 2 again immediately.
      var resolved = 0;
      unawaited(sem.acquire().then((_) => resolved++));
      unawaited(sem.acquire().then((_) => resolved++));
      await Future<void>.delayed(Duration.zero);
      expect(resolved, 2);
    });

    test('concurrent acquires honour the cap', () async {
      // Simulates the multipart upload pattern: N=20 parts, semaphore=4.
      final sem = _SemaphoreUnderTest(4);
      var holding = 0;
      var maxHeldAtOnce = 0;

      Future<void> work() async {
        await sem.acquire();
        holding++;
        if (holding > maxHeldAtOnce) maxHeldAtOnce = holding;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        holding--;
        sem.release();
      }

      await Future.wait(List.generate(20, (_) => work()));

      expect(maxHeldAtOnce, lessThanOrEqualTo(4));
      // And every task actually got the permit eventually.
      expect(holding, 0);
    });
  });
}
