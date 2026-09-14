#include "TwitchClient.hpp"
#include "TlsStream.hpp"

// WIN32_LEAN_AND_MEAN and NOMINMAX come from the build script's command line.
#include <winsock2.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <deque>
#include <random>

namespace tt
{
    namespace
    {
        constexpr const char* kHost = "irc.chat.twitch.tv";
        // TLS: plain 6667 was frozen by DPI after ~12-16 KB on direct connections
        // (see TlsStream.hpp); 6697 is the same IRC inside TLS.
        constexpr const char* kPort = "6697";
        constexpr int kTlsHandshakeMs = 10000;
        // The socket is only read when select() says data is there. There used to be
        // an SO_RCVTIMEO of 500 ms instead: after such a timeout Windows leaves the
        // socket "indeterminate", and inside the game the connection then went
        // silent for good (seen 2026-09-28: 25 messages, then nothing, while the
        // same chat kept flowing in the standalone probe).
        constexpr long kPollMs = 500;                  // lets the thread notice stop / silence
        // Twitch PINGs only about every 5 minutes. After a minute without any data we
        // PING it ourselves; no answer within half a minute more = dead connection.
        constexpr int64_t kKeepaliveMs = 60 * 1000;
        constexpr int64_t kSilenceLimitMs = 90 * 1000;
        constexpr int kBackoffMinMs = 2000;
        constexpr int kBackoffMaxMs = 60000;

        const uintptr_t kNoSocket = static_cast<uintptr_t>(INVALID_SOCKET);

        int64_t nowMs()
        {
            using namespace std::chrono;
            return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
        }

        std::string normalizeChannel(std::string c)
        {
            c.erase(std::remove_if(c.begin(), c.end(), [](unsigned char ch) { return std::isspace(ch) != 0; }), c.end());
            if (!c.empty() && c[0] == '#') { c.erase(0, 1); }
            std::transform(c.begin(), c.end(), c.begin(), [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); });
            return c;
        }

        // IRCv3 tag value unescaping: \s space, \: semicolon, \\ backslash, \r \n dropped.
        std::string tagValue(const std::string& tags, const std::string& key)
        {
            size_t pos = 0;
            while (pos <= tags.size())
            {
                size_t end = tags.find(';', pos);
                if (end == std::string::npos) { end = tags.size(); }
                const size_t eq = tags.find('=', pos);
                if (eq != std::string::npos && eq < end && tags.compare(pos, eq - pos, key) == 0 && eq - pos == key.size())
                {
                    std::string out;
                    for (size_t i = eq + 1; i < end; ++i)
                    {
                        if (tags[i] == '\\' && i + 1 < end)
                        {
                            const char n = tags[++i];
                            if (n == 's') { out += ' '; }
                            else if (n == ':') { out += ';'; }
                            else if (n == '\\') { out += '\\'; }
                            // \r, \n and unknown escapes are dropped
                        }
                        else
                        {
                            out += tags[i];
                        }
                    }
                    return out;
                }
                pos = end + 1;
            }
            return {};
        }

        struct IrcLine
        {
            std::string tags, prefix, command, params, trailing;
        };

        IrcLine parse(const std::string& line)
        {
            IrcLine m;
            size_t pos = 0;
            if (!line.empty() && line[0] == '@')
            {
                const size_t sp = line.find(' ');
                if (sp == std::string::npos) { return m; }
                m.tags = line.substr(1, sp - 1);
                pos = sp + 1;
            }
            if (pos < line.size() && line[pos] == ':')
            {
                const size_t sp = line.find(' ', pos);
                if (sp == std::string::npos) { return m; }
                m.prefix = line.substr(pos + 1, sp - pos - 1);
                pos = sp + 1;
            }
            const size_t sp = line.find(' ', pos);
            m.command = line.substr(pos, sp == std::string::npos ? std::string::npos : sp - pos);
            m.params = sp == std::string::npos ? std::string() : line.substr(sp + 1);
            if (!m.params.empty() && m.params[0] == ':')
            {
                m.trailing = m.params.substr(1);
            }
            else
            {
                const size_t t = m.params.find(" :");
                if (t != std::string::npos) { m.trailing = m.params.substr(t + 2); }
            }
            return m;
        }
    } // namespace

    //--------------------------------------------------------------------------
    // public
    //--------------------------------------------------------------------------

    void TwitchClient::start(const std::string& channelIn)
    {
        const std::string channel = normalizeChannel(channelIn);
        if (channel.empty())
        {
            setError("empty channel name");
            return;
        }
        if (m_running.load(std::memory_order_acquire))
        {
            if (status().channel == channel) { return; }
            stop();
        }
        stop(); // reap a finished thread, if any
        {
            std::lock_guard<std::mutex> lock(m_wakeMutex);
            m_stopRequested = false;
        }
        {
            std::lock_guard<std::mutex> lock(m_statusMutex);
            m_status.channel = channel;
            m_status.lastError.clear();
        }
        m_running.store(true, std::memory_order_release);
        m_thread = std::thread(&TwitchClient::run, this, channel);
    }

    bool TwitchClient::stop()
    {
        const bool wasRunning = m_running.exchange(false, std::memory_order_acq_rel);
        {
            std::lock_guard<std::mutex> lock(m_wakeMutex);
            m_stopRequested = true;
        }
        m_wake.notify_all();
        dropConnection(); // unblocks connect()/recv() immediately
        if (m_thread.joinable()) { m_thread.join(); }
        if (wasRunning) { setState("stopped"); }
        return wasRunning;
    }

    void TwitchClient::dropConnection()
    {
        // Whoever swaps the handle out closes it; the session thread does the same,
        // so the socket is closed exactly once.
        const uintptr_t s = m_socket.exchange(kNoSocket);
        if (s != kNoSocket)
        {
            m_reconnectRequested.store(true, std::memory_order_release);
            closesocket(static_cast<SOCKET>(s));
        }
    }

    TwitchClient::Status TwitchClient::status() const
    {
        std::lock_guard<std::mutex> lock(m_statusMutex);
        return m_status;
    }

    //--------------------------------------------------------------------------
    // thread
    //--------------------------------------------------------------------------

    void TwitchClient::setState(const char* state)
    {
        std::lock_guard<std::mutex> lock(m_statusMutex);
        m_status.state = state;
    }

    void TwitchClient::setError(const std::string& err)
    {
        std::lock_guard<std::mutex> lock(m_statusMutex);
        m_status.lastError = err;
    }

    bool TwitchClient::sleepInterruptible(int ms)
    {
        std::unique_lock<std::mutex> lock(m_wakeMutex);
        return !m_wake.wait_for(lock, std::chrono::milliseconds(ms), [this] { return m_stopRequested; });
    }

    void TwitchClient::run(std::string channel)
    {
        WSADATA wsa{};
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0)
        {
            setError("WSAStartup failed");
            setState("stopped");
            return;
        }

        int backoff = kBackoffMinMs;
        for (;;)
        {
            m_joinedThisSession.store(false);
            if (!session(channel)) { break; }
            // A session that got into the channel was healthy: start the backoff over.
            if (m_joinedThisSession.load()) { backoff = kBackoffMinMs; }
            setState("waiting");
            if (!sleepInterruptible(backoff)) { break; }
            backoff = std::min(backoff * 2, kBackoffMaxMs);
        }

        WSACleanup();
        setState("stopped");
    }

    bool TwitchClient::session(const std::string& channel)
    {
        setState("connecting");
        m_reconnectRequested.store(false);

        addrinfo hints{};
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_protocol = IPPROTO_TCP;
        addrinfo* res = nullptr;
        if (getaddrinfo(kHost, kPort, &hints, &res) != 0 || !res)
        {
            setError("DNS lookup of irc.chat.twitch.tv failed (" + std::to_string(WSAGetLastError()) + ")");
            return true;
        }

        SOCKET sock = INVALID_SOCKET;
        for (addrinfo* ai = res; ai; ai = ai->ai_next)
        {
            sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
            if (sock == INVALID_SOCKET) { continue; }
            m_socket.store(static_cast<uintptr_t>(sock));
            // Test hook: RTTT_BIND_IP=<local IPv4> makes the connection leave through
            // that interface (e.g. around a VPN), as the game's own traffic may.
            char bindIp[64] = {};
            if (ai->ai_family == AF_INET && GetEnvironmentVariableA("RTTT_BIND_IP", bindIp, sizeof(bindIp)) > 0)
            {
                sockaddr_in local{};
                local.sin_family = AF_INET;
                if (inet_pton(AF_INET, bindIp, &local.sin_addr) == 1)
                {
                    bind(sock, reinterpret_cast<sockaddr*>(&local), sizeof(local));
                }
            }
            if (connect(sock, ai->ai_addr, static_cast<int>(ai->ai_addrlen)) == 0) { break; }
            const uintptr_t mine = m_socket.exchange(kNoSocket);
            if (mine != kNoSocket) { closesocket(sock); }
            sock = INVALID_SOCKET;
            {
                std::lock_guard<std::mutex> lock(m_wakeMutex);
                if (m_stopRequested) { break; }
            }
        }
        freeaddrinfo(res);

        {
            std::lock_guard<std::mutex> lock(m_wakeMutex);
            if (m_stopRequested)
            {
                const uintptr_t mine = m_socket.exchange(kNoSocket);
                if (mine != kNoSocket) { closesocket(static_cast<SOCKET>(mine)); }
                return false;
            }
        }
        if (sock == INVALID_SOCKET)
        {
            setError("connect to irc.chat.twitch.tv:6697 failed (" + std::to_string(WSAGetLastError()) + ")");
            return true;
        }

        TlsStream tls;
        {
            std::string tlsError;
            if (!tls.handshake(sock, L"irc.chat.twitch.tv", kTlsHandshakeMs, tlsError))
            {
                setError(tlsError);
                const uintptr_t mine = m_socket.exchange(kNoSocket);
                if (mine != kNoSocket) { closesocket(static_cast<SOCKET>(mine)); }
                std::lock_guard<std::mutex> lock(m_wakeMutex);
                return !m_stopRequested;
            }
        }

        {
            std::lock_guard<std::mutex> lock(m_statusMutex);
            ++m_status.connects;
            m_status.state = "connected";
        }

        std::random_device rd;
        const std::string nick = "justinfan" + std::to_string(10000 + rd() % 90000);
        const std::string hello = "CAP REQ :twitch.tv/tags twitch.tv/commands\r\n"
                                  "NICK " + nick + "\r\n"
                                  "JOIN #" + channel + "\r\n";
        if (!tls.send(hello)) { setError("send failed right after connect"); }

        std::string buffer;
        int64_t lastData = nowMs();
        bool pingSent = false;
        // Diagnostics for the in-game silence (2026-09-28): the last lines seen,
        // shortened, reported with the socket's state when the silence hits.
        std::deque<std::string> lastLines;
        auto describeSocket = [&]() {
            int type = 0;
            int len = sizeof(type);
            const int typeRc = getsockopt(sock, SOL_SOCKET, SO_TYPE, reinterpret_cast<char*>(&type), &len);
            sockaddr_storage peer{};
            int plen = sizeof(peer);
            char host[64] = "?";
            if (getpeername(sock, reinterpret_cast<sockaddr*>(&peer), &plen) == 0)
            {
                getnameinfo(reinterpret_cast<sockaddr*>(&peer), plen, host, sizeof(host), nullptr, 0, NI_NUMERICHOST);
            }
            else
            {
                snprintf(host, sizeof(host), "getpeername error %d", WSAGetLastError());
            }
            u_long pending = 0;
            const int ioRc = ioctlsocket(sock, FIONREAD, &pending);
            std::string out = "socket " + std::to_string(static_cast<unsigned long long>(sock)) + " type=" +
                              (typeRc == 0 ? std::to_string(type) : "error " + std::to_string(WSAGetLastError())) +
                              " peer=" + host + " unread=" + (ioRc == 0 ? std::to_string(pending) : "error") + "; last lines:";
            for (const auto& l : lastLines) { out += " | " + l; }
            return out;
        };
        for (;;)
        {
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(sock, &readable);
            timeval wait{0, kPollMs * 1000};
            const int ready = select(0, &readable, nullptr, nullptr, &wait);
            if (ready == SOCKET_ERROR)
            {
                if (!m_reconnectRequested.load()) { setError("select failed (" + std::to_string(WSAGetLastError()) + ")"); }
                break;
            }
            if (ready == 0)
            {
                const int64_t quiet = nowMs() - lastData;
                if (quiet > kSilenceLimitMs)
                {
                    setError("no data from the server for 90 s (keepalive PING unanswered); " + describeSocket());
                    break;
                }
                if (quiet > kKeepaliveMs && !pingSent)
                {
                    pingSent = true;
                    tls.send("PING :tmi.twitch.tv\r\n");
                }
                if (m_reconnectRequested.load()) { break; }
                std::lock_guard<std::mutex> lock(m_wakeMutex);
                if (m_stopRequested) { break; }
                continue;
            }
            std::string plain;
            std::string readError;
            const int rc = tls.receive(plain, readError);
            const int n = rc > 0 ? static_cast<int>(plain.size()) : rc;
            if (rc > 0 && n == 0) { continue; }   // part of a TLS record; the rest follows
            if (n > 0)
            {
                lastData = nowMs();
                pingSent = false;
                {
                    std::lock_guard<std::mutex> lock(m_statusMutex);
                    m_status.bytes += static_cast<uint64_t>(n);
                }
                buffer += plain;
                size_t eol;
                while ((eol = buffer.find("\r\n")) != std::string::npos)
                {
                    std::string line = buffer.substr(0, eol);
                    buffer.erase(0, eol + 2);
                    {
                        // Tags are long and not interesting here: keep what follows them.
                        const size_t sp = line[0] == '@' ? line.find(' ') : std::string::npos;
                        std::string brief = sp == std::string::npos ? line : line.substr(sp + 1);
                        if (brief.size() > 90) { brief.resize(90); }
                        lastLines.push_back(std::move(brief));
                        if (lastLines.size() > 4) { lastLines.pop_front(); }
                    }
                    if (!line.empty()) { handleLine(line, channel, tls); }
                }
                // A server never sends lines this long; do not let garbage grow memory.
                if (buffer.size() > 64 * 1024) { buffer.clear(); }
            }
            else if (n == 0)
            {
                setError("server closed the connection");
                break;
            }
            else
            {
                if (!m_reconnectRequested.load()) { setError(readError); }
                break;
            }
            if (m_reconnectRequested.load()) { break; }
            {
                std::lock_guard<std::mutex> lock(m_wakeMutex);
                if (m_stopRequested) { break; }
            }
        }

        const uintptr_t mine = m_socket.exchange(kNoSocket);
        if (mine != kNoSocket) { closesocket(static_cast<SOCKET>(mine)); }

        std::lock_guard<std::mutex> lock(m_wakeMutex);
        return !m_stopRequested;
    }

    void TwitchClient::handleLine(const std::string& line, const std::string& channel, TlsStream& tls)
    {
        const IrcLine m = parse(line);

        if (m.command == "PING")
        {
            tls.send("PONG :" + m.trailing + "\r\n");
            return;
        }
        if (m.command == "RECONNECT")
        {
            // Twitch asks clients to reconnect before a server restart.
            setError("server asked to RECONNECT");
            m_reconnectRequested.store(true);
            return;
        }
        if (m.command == "JOIN")
        {
            const std::string nick = m.prefix.substr(0, m.prefix.find('!'));
            if (nick.rfind("justinfan", 0) == 0)
            {
                m_joinedThisSession.store(true);
                setState("joined");
            }
            return;
        }
        if (m.command == "NOTICE")
        {
            setError("NOTICE: " + m.trailing);
            return;
        }
        if (m.command != "PRIVMSG") { return; }

        // "#channel :text" -- only our channel.
        if (m.params.compare(0, channel.size() + 1, "#" + channel) != 0) { return; }

        std::string user = tagValue(m.tags, "display-name");
        if (user.empty()) { user = m.prefix.substr(0, m.prefix.find('!')); }
        std::string text = m.trailing;

        // /me: CTCP ACTION wrapper "\x01ACTION text\x01".
        if (text.size() > 8 && text.compare(0, 8, "\x01" "ACTION ") == 0)
        {
            text = text.substr(8);
            if (!text.empty() && text.back() == '\x01') { text.pop_back(); }
        }

        m_queue.push(ChatMessage{std::move(user), std::move(text), tagValue(m.tags, "color"), tagValue(m.tags, "emotes")});
        std::lock_guard<std::mutex> lock(m_statusMutex);
        ++m_status.received;
    }
} // namespace tt
