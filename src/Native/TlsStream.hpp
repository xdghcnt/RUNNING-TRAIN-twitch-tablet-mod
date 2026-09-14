#pragma once
/*
    TlsStream -- TLS over an already connected socket, with Windows' own
    Schannel (no extra libraries). Client side only; the server certificate is
    validated by Windows against the host name.

    Why the Twitch client needs it (2026-09-28): plain IRC on port 6667 to
    Twitch's chat servers was frozen after ~12-16 KB on a direct connection
    from Russia -- no more data, not even PONG, while the socket stayed open.
    The same chat over TLS on 6697 ran for minutes without a stall.

    Used from one thread only (the Twitch client's).
*/

#include <winsock2.h>

#define SECURITY_WIN32
#include <security.h>
#include <schannel.h>

#include <string>

namespace tt
{
    class TlsStream
    {
      public:
        TlsStream() = default;
        ~TlsStream();
        TlsStream(const TlsStream&) = delete;
        TlsStream& operator=(const TlsStream&) = delete;

        // Blocking handshake on a connected socket, up to timeoutMs overall.
        bool handshake(SOCKET s, const std::wstring& host, int timeoutMs, std::string& error);

        bool send(const std::string& data);

        // One recv() from the socket, then every complete TLS record is decrypted
        // and appended to `out` (which may stay empty: a record can span reads).
        // Returns 1 = ok, 0 = the peer closed the connection, -1 = error.
        int receive(std::string& out, std::string& error);

      private:
        void release();

        SOCKET m_socket{INVALID_SOCKET};
        CredHandle m_cred{};
        CtxtHandle m_ctx{};
        bool m_haveCred{false};
        bool m_haveCtx{false};
        SecPkgContext_StreamSizes m_sizes{};
        std::string m_cipher; // received, not yet decrypted
    };
} // namespace tt
