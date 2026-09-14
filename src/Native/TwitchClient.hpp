#pragma once
/*
    TwitchClient -- read-only, anonymous Twitch chat over IRC (Milestone 9).

    One background thread owns the socket:

        connect irc.chat.twitch.tv:6667
        CAP REQ :twitch.tv/tags twitch.tv/commands     (display-name + name colour)
        NICK justinfan<random>                           (anonymous: no PASS needed)
        JOIN #<channel>
        PRIVMSG  -> ChatMessage -> ChatQueue
        PING     -> PONG
        RECONNECT / error / silence -> reconnect with backoff 2 s .. 60 s

    Plain TCP, no TLS: anonymous read access to a public chat carries no secret.

    Never touches Lua or Unreal. State for the Lua side is exposed through
    status(), a snapshot taken under a mutex.
*/

#include "ChatQueue.hpp"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

namespace tt
{
    class TwitchClient
    {
      public:
        explicit TwitchClient(ChatQueue& queue) : m_queue(queue) {}
        ~TwitchClient() { stop(); }

        TwitchClient(const TwitchClient&) = delete;
        TwitchClient& operator=(const TwitchClient&) = delete;

        // Idempotent for the same channel; a different channel restarts the thread.
        void start(const std::string& channel);
        // Idempotent; closes the socket and joins the thread. Returns false if not running.
        bool stop();
        // Test hook: aborts the current connection as if the network dropped.
        void dropConnection();

        struct Status
        {
            std::string state; // "stopped", "connecting", "connected", "joined", "waiting"
            std::string channel;
            std::string lastError;
            uint64_t received{0};
            uint64_t connects{0};
            uint64_t bytes{0};     // raw bytes read from the socket, all sessions
        };
        Status status() const;

      private:
        void run(std::string channel);
        bool session(const std::string& channel);   // one connection; false = stop requested
        void handleLine(const std::string& line, const std::string& channel, class TlsStream& tls);
        void setState(const char* state);
        void setError(const std::string& err);
        bool sleepInterruptible(int ms);            // false = stop requested

        ChatQueue& m_queue;
        std::thread m_thread;
        std::atomic<bool> m_running{false};
        std::atomic<uintptr_t> m_socket{~uintptr_t{0}}; // SOCKET; ~0 == INVALID_SOCKET when none
        std::atomic<bool> m_reconnectRequested{false};
        std::atomic<bool> m_joinedThisSession{false};

        std::mutex m_wakeMutex;
        std::condition_variable m_wake;
        bool m_stopRequested{false};

        mutable std::mutex m_statusMutex;
        Status m_status{"stopped", "", "", 0, 0, 0};
    };
} // namespace tt
