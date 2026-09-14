#pragma once
/*
    EmoteFetcher -- downloads Twitch emote images in the background.

    The Lua mod asks for an emote by id and says where the file should be; this
    class fetches

        https://static-cdn.jtvnw.net/emoticons/v2/<id>/static/dark/3.0

    (PNG; "static" is the first frame of an animated emote) on its own thread
    with WinHTTP and writes it there through a .tmp file, so a half-written file
    is never seen. Lua polls the state and loads the file into the engine itself.

    A file already on disk counts as ready at once: the folder is a cache that
    survives restarts. A failed download is not retried this session.

    Nothing here knows about Unreal or Lua.
*/

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

namespace tt
{
    class EmoteFetcher
    {
      public:
        EmoteFetcher() = default;
        ~EmoteFetcher();
        EmoteFetcher(const EmoteFetcher&) = delete;
        EmoteFetcher& operator=(const EmoteFetcher&) = delete;

        // Returns "ready", "pending" or "failed"; queues the download on first ask.
        // path: UTF-8, the file to write (its folder is created if missing).
        std::string request(const std::string& id, const std::string& path);

        struct Stats
        {
            uint64_t downloaded;
            uint64_t failed;
            uint64_t cached;
            size_t queued;
            std::string lastError;
        };
        Stats stats() const;

        void stop();

      private:
        enum class State { Pending, Ready, Failed };
        struct Job
        {
            std::string id;
            std::string path;
        };

        void run();
        bool download(const Job& job, std::string& error);

        mutable std::mutex m_mutex;
        std::condition_variable m_cv;
        std::deque<Job> m_jobs;
        std::unordered_map<std::string, State> m_state;
        std::thread m_worker;
        bool m_stopping{false};
        uint64_t m_downloaded{0};
        uint64_t m_failed{0};
        uint64_t m_cached{0};
        std::string m_lastError;
    };
} // namespace tt
