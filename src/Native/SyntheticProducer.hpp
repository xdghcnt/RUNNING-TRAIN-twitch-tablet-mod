#pragma once
/*
    SyntheticProducer -- Milestone 8 stand-in for the Twitch client: a background
    thread that pushes a ChatMessage into the queue every interval, plus a burst
    of messages now and then, so the game-thread side can be tested for steady
    flow, bursts and clean shutdown before any networking exists.
*/

#include "ChatQueue.hpp"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace tt
{
    class SyntheticProducer
    {
      public:
        explicit SyntheticProducer(ChatQueue& queue) : m_queue(queue) {}
        ~SyntheticProducer() { stop(); }

        SyntheticProducer(const SyntheticProducer&) = delete;
        SyntheticProducer& operator=(const SyntheticProducer&) = delete;

        // Idempotent. intervalMs is clamped to [100, 60000].
        // Every burstEvery-th tick pushes burstSize messages at once (0 = no bursts).
        void start(int intervalMs, int burstEvery, int burstSize);
        // Idempotent; joins the thread. Returns false if it was not running.
        bool stop();
        bool running() const { return m_running.load(std::memory_order_acquire); }

      private:
        void run(int intervalMs, int burstEvery, int burstSize);

        ChatQueue& m_queue;
        std::thread m_thread;
        std::atomic<bool> m_running{false};
        std::mutex m_wakeMutex;
        std::condition_variable m_wake;
        bool m_stopRequested{false};
    };
} // namespace tt
