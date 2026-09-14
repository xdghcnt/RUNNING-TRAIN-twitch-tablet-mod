#include "SyntheticProducer.hpp"

#include <algorithm>
#include <chrono>
#include <string>

namespace tt
{
    namespace
    {
        const char* const kUsers[] = {"synthetic_bot", "nyanya", "driver228", "TrainSpotter_JP", "mascon_enjoyer"};

        // UTF-8 literals (the source is UTF-8 and compiled with /utf-8, so narrow literals stay UTF-8): Latin, Cyrillic and Japanese, so the
        // whole path from a background thread to the Canvas is exercised.
        const char* const kTexts[] = {
            "background thread says hi",
            "сообщение из фонового потока",
            "バックグラウンドから",
            "queue -> game thread -> ChatModel -> render target",
        };
    } // namespace

    void SyntheticProducer::start(int intervalMs, int burstEvery, int burstSize)
    {
        if (m_running.load(std::memory_order_acquire)) { return; }
        stop(); // reap a thread that ended on its own, if any

        intervalMs = std::clamp(intervalMs, 100, 60000);
        burstEvery = std::max(burstEvery, 0);
        burstSize = std::clamp(burstSize, 1, 200);
        {
            std::lock_guard<std::mutex> lock(m_wakeMutex);
            m_stopRequested = false;
        }
        m_running.store(true, std::memory_order_release);
        m_thread = std::thread(&SyntheticProducer::run, this, intervalMs, burstEvery, burstSize);
    }

    bool SyntheticProducer::stop()
    {
        const bool wasRunning = m_running.exchange(false, std::memory_order_acq_rel);
        {
            std::lock_guard<std::mutex> lock(m_wakeMutex);
            m_stopRequested = true;
        }
        m_wake.notify_all();
        if (m_thread.joinable()) { m_thread.join(); }
        return wasRunning;
    }

    void SyntheticProducer::run(int intervalMs, int burstEvery, int burstSize)
    {
        uint64_t tick = 0;
        uint64_t seq = 0;
        std::unique_lock<std::mutex> lock(m_wakeMutex);
        for (;;)
        {
            // Interruptible sleep: stop() wakes us immediately.
            if (m_wake.wait_for(lock, std::chrono::milliseconds(intervalMs), [this] { return m_stopRequested; }))
            {
                break;
            }
            ++tick;
            const int count = (burstEvery > 0 && tick % static_cast<uint64_t>(burstEvery) == 0) ? burstSize : 1;
            lock.unlock();
            for (int i = 0; i < count; ++i)
            {
                ++seq;
                const size_t u = seq % std::size(kUsers);
                const size_t t = seq % std::size(kTexts);
                std::string text = "#" + std::to_string(seq) + (count > 1 ? " [burst] " : " ") + kTexts[t];
                m_queue.push(ChatMessage{kUsers[u], std::move(text)});
            }
            lock.lock();
        }
    }
} // namespace tt
