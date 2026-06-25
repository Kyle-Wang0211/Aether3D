// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// streaming_orchestrator.cc — implementation of the per-frame streaming loop +
// bounded queue. See streaming_orchestrator.h for the design rationale.
//
// Threading model (two workers, overlapping stages):
//
//   producer (camera) ─submit_frame()─▶ [ bounded queue_ ] ─▶ GPU thread
//                                                                  │ ExtractFn
//                                                                  ▼
//                                          [ stage_ depth-2 ] ─▶ SfM thread
//                                                                  │ IngestFn
//                                                                  ▼
//                                                            CloudSink (UI)
//
// Back-pressure / drop happens ONLY at the front bounded queue_. The inter-stage
// slot is a tiny (depth-2) hand-off that gives the GPU exactly one frame of
// run-ahead so the two stages overlap; it never grows.

#include "aether/gpu/streaming_orchestrator.h"

#include <chrono>
#include <utility>

namespace aether {
namespace gpu {

StreamingOrchestrator::StreamingOrchestrator(ExtractFn extract, IngestFn ingest,
                                             CloudSink sink,
                                             OrchestratorConfig config) noexcept
    : extract_(std::move(extract)),
      ingest_(std::move(ingest)),
      sink_(std::move(sink)),
      config_(config) {}

StreamingOrchestrator::~StreamingOrchestrator() noexcept {
    // Default teardown discards any backlog (hard stop). Callers that want the
    // queue drained must call stop_capture() first.
    stop_now();
}

void StreamingOrchestrator::start() noexcept {
    bool expected = false;
    if (!running_.compare_exchange_strong(expected, true)) return;  // already up
    accepting_.store(true);
    drain_.store(true);
    gpu_thread_ = std::thread(&StreamingOrchestrator::gpu_thread_func, this);
    sfm_thread_ = std::thread(&StreamingOrchestrator::sfm_thread_func, this);
}

bool StreamingOrchestrator::submit_frame(const CaptureFrame& frame) noexcept {
    submitted_.fetch_add(1, std::memory_order_relaxed);
    if (!accepting_.load(std::memory_order_acquire)) return false;

    QueuedFrame q;
    q.frame = frame;
    // Copy the grayscale buffer so the camera can recycle its frame immediately.
    if (frame.gray && frame.width > 0 && frame.height > 0) {
        const std::size_t n =
            static_cast<std::size_t>(frame.width) * frame.height;
        q.gray_owned.assign(frame.gray, frame.gray + n);
        // Re-point the carried frame at our owned copy (stable across the queue).
        q.frame.gray = q.gray_owned.data();
    }

    bool accepted = false;
    {
        std::lock_guard<std::mutex> lk(queue_mu_);
        if (queue_.size() >= config_.max_queue_depth) {
            // Queue full: apply drop policy.
            if (config_.drop_policy == OrchestratorConfig::DropPolicy::kDropNewest) {
                dropped_newest_.fetch_add(1, std::memory_order_relaxed);
                // accepted stays false; frame refused (camera back-pressure).
            } else {
                // kDropOldest: evict the stalest queued frame, keep the fresh one.
                queue_.pop_front();
                dropped_oldest_.fetch_add(1, std::memory_order_relaxed);
                queue_.push_back(std::move(q));
                accepted = true;
            }
        } else {
            queue_.push_back(std::move(q));
            accepted = true;
        }
        // Track high-water mark for the queue-bounded proof.
        const std::size_t d = queue_.size();
        std::size_t prev = peak_queue_depth_.load(std::memory_order_relaxed);
        while (d > prev && !peak_queue_depth_.compare_exchange_weak(
                               prev, d, std::memory_order_relaxed)) {
        }
    }
    if (accepted) {
        enqueued_.fetch_add(1, std::memory_order_relaxed);
        queue_cv_.notify_one();
    }
    return accepted;
}

// GPU stage: pop the bounded queue, run ExtractFn, push to the depth-2 slot.
void StreamingOrchestrator::gpu_thread_func() noexcept {
    for (;;) {
        QueuedFrame q;
        {
            std::unique_lock<std::mutex> lk(queue_mu_);
            queue_cv_.wait(lk, [&] {
                return !queue_.empty() || !running_.load(std::memory_order_acquire);
            });
            if (queue_.empty()) {
                // Woken with empty queue → we are shutting down. If draining, the
                // queue is already empty so nothing is lost; exit.
                if (!running_.load(std::memory_order_acquire)) break;
                continue;
            }
            q = std::move(queue_.front());
            queue_.pop_front();
        }

        gpu_busy_.store(true, std::memory_order_release);
        ExtractedItem item;
        item.frame = q.frame;
        item.gray_owned = std::move(q.gray_owned);
        item.frame.gray = item.gray_owned.data();  // re-point to the moved buffer
        bool ok = false;
        if (extract_) ok = extract_(item.frame, &item.feats);
        extracted_.fetch_add(1, std::memory_order_relaxed);
        gpu_busy_.store(false, std::memory_order_release);

        if (!ok || item.feats.count <= 0) {
            // Extraction failed / empty frame: skip ingest, keep streaming.
            continue;
        }

        // Hand off to the SfM stage through the bounded depth-2 slot. This blocks
        // only if the SfM stage is more than one frame behind — which is exactly
        // the back-pressure that keeps the inter-stage buffer from growing and
        // pushes the wait back onto the (bounded) front queue.
        {
            std::unique_lock<std::mutex> lk(stage_mu_);
            stage_cv_.wait(lk, [&] {
                return stage_.size() < kStageCapacity ||
                       !running_.load(std::memory_order_acquire);
            });
            if (!running_.load(std::memory_order_acquire) &&
                stage_.size() >= kStageCapacity) {
                break;  // hard stop with full slot: drop this frame
            }
            stage_.push_back(std::move(item));
        }
        stage_cv_.notify_one();
    }
    // GPU thread exiting: wake the SfM thread so it can observe shutdown.
    stage_cv_.notify_all();
}

// SfM stage: take features, run IngestFn (register + local-BA), publish the
// growing cloud snapshot to the sink (the UI feed).
void StreamingOrchestrator::sfm_thread_func() noexcept {
    for (;;) {
        ExtractedItem item;
        {
            std::unique_lock<std::mutex> lk(stage_mu_);
            stage_cv_.wait(lk, [&] {
                return !stage_.empty() ||
                       !running_.load(std::memory_order_acquire);
            });
            if (stage_.empty()) {
                if (!running_.load(std::memory_order_acquire)) break;
                continue;
            }
            item = std::move(stage_.front());
            stage_.pop_front();
        }
        stage_cv_.notify_one();  // a slot opened: let the GPU run ahead

        sfm_busy_.store(true, std::memory_order_release);
        CloudSnapshot snap;
        bool registered = false;
        if (ingest_) registered = ingest_(item.frame, item.feats, &snap);
        ingested_.fetch_add(1, std::memory_order_relaxed);
        if (registered) registered_.fetch_add(1, std::memory_order_relaxed);
        sfm_busy_.store(false, std::memory_order_release);

        // Publish the growing sparse cloud to the UI sink. This is the user's
        // real-time feedback — the actual SfM cloud, not a proxy.
        if (sink_) sink_(snap);
    }
}

void StreamingOrchestrator::stop_capture() noexcept {
    if (!running_.load(std::memory_order_acquire)) return;
    // 1) Stop accepting new frames, but keep draining what is already queued.
    accepting_.store(false, std::memory_order_release);
    drain_.store(true, std::memory_order_release);

    // 2) Block until the front queue is empty AND no frame is mid-flight, so the
    //    backlog accepted before stop is fully processed (the drain guarantee).
    for (;;) {
        bool idle;
        {
            std::lock_guard<std::mutex> lk(queue_mu_);
            idle = queue_.empty();
        }
        if (idle) {
            std::lock_guard<std::mutex> lk(stage_mu_);
            idle = stage_.empty();
        }
        idle = idle && !gpu_busy_.load(std::memory_order_acquire) &&
               !sfm_busy_.load(std::memory_order_acquire);
        if (idle) break;
        // Yield briefly; the workers are chewing through the backlog.
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        queue_cv_.notify_all();
        stage_cv_.notify_all();
    }

    // 3) Backlog drained — now tear down the workers.
    running_.store(false, std::memory_order_release);
    queue_cv_.notify_all();
    stage_cv_.notify_all();
    if (gpu_thread_.joinable()) gpu_thread_.join();
    if (sfm_thread_.joinable()) sfm_thread_.join();
}

void StreamingOrchestrator::stop_now() noexcept {
    if (!running_.exchange(false)) {
        // Not running. Still join any lingering threads (defensive).
        if (gpu_thread_.joinable()) gpu_thread_.join();
        if (sfm_thread_.joinable()) sfm_thread_.join();
        return;
    }
    accepting_.store(false, std::memory_order_release);
    drain_.store(false, std::memory_order_release);
    // Discard the pending queue so we don't waste work on teardown.
    {
        std::lock_guard<std::mutex> lk(queue_mu_);
        queue_.clear();
    }
    queue_cv_.notify_all();
    stage_cv_.notify_all();
    if (gpu_thread_.joinable()) gpu_thread_.join();
    if (sfm_thread_.joinable()) sfm_thread_.join();
}

OrchestratorStats StreamingOrchestrator::stats() const noexcept {
    OrchestratorStats s;
    s.submitted = submitted_.load(std::memory_order_relaxed);
    s.enqueued = enqueued_.load(std::memory_order_relaxed);
    s.dropped_newest = dropped_newest_.load(std::memory_order_relaxed);
    s.dropped_oldest = dropped_oldest_.load(std::memory_order_relaxed);
    s.extracted = extracted_.load(std::memory_order_relaxed);
    s.ingested = ingested_.load(std::memory_order_relaxed);
    s.registered = registered_.load(std::memory_order_relaxed);
    s.peak_queue_depth = peak_queue_depth_.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lk(queue_mu_);
        s.queue_depth = queue_.size();
    }
    return s;
}

bool StreamingOrchestrator::busy() const noexcept {
    {
        std::lock_guard<std::mutex> lk(queue_mu_);
        if (!queue_.empty()) return true;
    }
    {
        std::lock_guard<std::mutex> lk(stage_mu_);
        if (!stage_.empty()) return true;
    }
    return gpu_busy_.load(std::memory_order_acquire) ||
           sfm_busy_.load(std::memory_order_acquire);
}

}  // namespace gpu
}  // namespace aether
