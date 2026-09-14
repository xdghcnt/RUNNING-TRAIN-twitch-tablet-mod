#include "TlsStream.hpp"

#include <chrono>
#include <vector>

namespace tt
{
    namespace
    {
        int64_t nowMs()
        {
            return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch())
                .count();
        }

        bool sendRaw(SOCKET s, const char* data, size_t size)
        {
            while (size > 0)
            {
                const int n = ::send(s, data, static_cast<int>(size), 0);
                if (n == SOCKET_ERROR || n == 0) { return false; }
                data += n;
                size -= static_cast<size_t>(n);
            }
            return true;
        }

        // Waits up to ms for data, then reads what is there. >0 bytes, 0 closed, -1 error/timeout.
        int recvWithin(SOCKET s, char* buf, int size, int ms)
        {
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(s, &readable);
            timeval wait{ms / 1000, (ms % 1000) * 1000};
            const int ready = select(0, &readable, nullptr, nullptr, &wait);
            if (ready <= 0) { return -1; }
            const int n = ::recv(s, buf, size, 0);
            return n == SOCKET_ERROR ? -1 : n;
        }

        std::string hex(SECURITY_STATUS st)
        {
            char b[16];
            snprintf(b, sizeof(b), "0x%08lX", static_cast<unsigned long>(st));
            return b;
        }
    } // namespace

    TlsStream::~TlsStream() { release(); }

    void TlsStream::release()
    {
        if (m_haveCtx) { DeleteSecurityContext(&m_ctx); m_haveCtx = false; }
        if (m_haveCred) { FreeCredentialsHandle(&m_cred); m_haveCred = false; }
    }

    bool TlsStream::handshake(SOCKET s, const std::wstring& host, int timeoutMs, std::string& error)
    {
        m_socket = s;
        SCHANNEL_CRED cred{};
        cred.dwVersion = SCHANNEL_CRED_VERSION;
        // Windows checks the certificate chain and the host name itself.
        cred.dwFlags = SCH_CRED_AUTO_CRED_VALIDATION | SCH_USE_STRONG_CRYPTO | SCH_CRED_NO_DEFAULT_CREDS;
        TimeStamp expiry{};
        SECURITY_STATUS st = AcquireCredentialsHandleW(nullptr, const_cast<wchar_t*>(UNISP_NAME_W), SECPKG_CRED_OUTBOUND,
                                                       nullptr, &cred, nullptr, nullptr, &m_cred, &expiry);
        if (st != SEC_E_OK) { error = "TLS credentials " + hex(st); return false; }
        m_haveCred = true;

        const DWORD flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                            ISC_REQ_EXTENDED_ERROR | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
        DWORD outFlags = 0;
        const int64_t deadline = nowMs() + timeoutMs;
        std::string in;             // handshake bytes from the server not consumed yet
        bool first = true;
        std::vector<char> chunk(16 * 1024);

        for (;;)
        {
            SecBuffer inBufs[2]{};
            inBufs[0].BufferType = SECBUFFER_TOKEN;
            inBufs[0].pvBuffer = in.empty() ? nullptr : in.data();
            inBufs[0].cbBuffer = static_cast<unsigned long>(in.size());
            inBufs[1].BufferType = SECBUFFER_EMPTY;
            SecBufferDesc inDesc{SECBUFFER_VERSION, 2, inBufs};

            SecBuffer outBufs[1]{};
            outBufs[0].BufferType = SECBUFFER_TOKEN;
            SecBufferDesc outDesc{SECBUFFER_VERSION, 1, outBufs};

            st = InitializeSecurityContextW(&m_cred, first ? nullptr : &m_ctx, const_cast<wchar_t*>(host.c_str()), flags, 0,
                                            0, first ? nullptr : &inDesc, 0, first ? &m_ctx : nullptr, &outDesc, &outFlags,
                                            nullptr);
            if (first) { m_haveCtx = true; first = false; }

            if (st == SEC_E_INCOMPLETE_MESSAGE)
            {
                // Need more of the server's handshake: read and try again.
            }
            else if (st == SEC_E_OK || st == SEC_I_CONTINUE_NEEDED || st == SEC_I_INCOMPLETE_CREDENTIALS)
            {
                if (outBufs[0].cbBuffer > 0 && outBufs[0].pvBuffer)
                {
                    const bool sent = sendRaw(s, static_cast<const char*>(outBufs[0].pvBuffer), outBufs[0].cbBuffer);
                    FreeContextBuffer(outBufs[0].pvBuffer);
                    if (!sent) { error = "TLS handshake send failed"; return false; }
                }
                if (inBufs[1].BufferType == SECBUFFER_EXTRA && inBufs[1].cbBuffer > 0)
                {
                    in = in.substr(in.size() - inBufs[1].cbBuffer);
                }
                else
                {
                    in.clear();
                }
                if (st == SEC_E_OK)
                {
                    // Anything left over is already application data.
                    m_cipher = in;
                    st = QueryContextAttributesW(&m_ctx, SECPKG_ATTR_STREAM_SIZES, &m_sizes);
                    if (st != SEC_E_OK) { error = "TLS stream sizes " + hex(st); return false; }
                    return true;
                }
                if (!in.empty()) { continue; }   // the server's next message is already here
            }
            else
            {
                if (outBufs[0].pvBuffer) { FreeContextBuffer(outBufs[0].pvBuffer); }
                error = "TLS handshake " + hex(st);
                return false;
            }

            const int64_t left = deadline - nowMs();
            if (left <= 0) { error = "TLS handshake timed out"; return false; }
            const int n = recvWithin(s, chunk.data(), static_cast<int>(chunk.size()), static_cast<int>(left));
            if (n <= 0) { error = n == 0 ? "server closed during TLS handshake" : "TLS handshake read failed"; return false; }
            in.append(chunk.data(), static_cast<size_t>(n));
        }
    }

    bool TlsStream::send(const std::string& data)
    {
        size_t pos = 0;
        while (pos < data.size())
        {
            const size_t len = std::min<size_t>(data.size() - pos, m_sizes.cbMaximumMessage);
            std::vector<char> msg(m_sizes.cbHeader + len + m_sizes.cbTrailer);
            memcpy(msg.data() + m_sizes.cbHeader, data.data() + pos, len);
            SecBuffer bufs[4]{};
            bufs[0] = {m_sizes.cbHeader, SECBUFFER_STREAM_HEADER, msg.data()};
            bufs[1] = {static_cast<unsigned long>(len), SECBUFFER_DATA, msg.data() + m_sizes.cbHeader};
            bufs[2] = {m_sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, msg.data() + m_sizes.cbHeader + len};
            bufs[3] = {0, SECBUFFER_EMPTY, nullptr};
            SecBufferDesc desc{SECBUFFER_VERSION, 4, bufs};
            if (EncryptMessage(&m_ctx, 0, &desc, 0) != SEC_E_OK) { return false; }
            const size_t total = bufs[0].cbBuffer + bufs[1].cbBuffer + bufs[2].cbBuffer;
            if (!sendRaw(m_socket, msg.data(), total)) { return false; }
            pos += len;
        }
        return true;
    }

    int TlsStream::receive(std::string& out, std::string& error)
    {
        char chunk[16 * 1024];
        const int n = ::recv(m_socket, chunk, static_cast<int>(sizeof(chunk)), 0);
        if (n == 0) { return 0; }
        if (n == SOCKET_ERROR)
        {
            error = "recv failed (" + std::to_string(WSAGetLastError()) + ")";
            return -1;
        }
        m_cipher.append(chunk, static_cast<size_t>(n));

        while (!m_cipher.empty())
        {
            SecBuffer bufs[4]{};
            bufs[0] = {static_cast<unsigned long>(m_cipher.size()), SECBUFFER_DATA, m_cipher.data()};
            bufs[1] = {0, SECBUFFER_EMPTY, nullptr};
            bufs[2] = {0, SECBUFFER_EMPTY, nullptr};
            bufs[3] = {0, SECBUFFER_EMPTY, nullptr};
            SecBufferDesc desc{SECBUFFER_VERSION, 4, bufs};
            const SECURITY_STATUS st = DecryptMessage(&m_ctx, &desc, 0, nullptr);
            if (st == SEC_E_INCOMPLETE_MESSAGE) { break; }   // wait for the rest of the record
            if (st == SEC_I_CONTEXT_EXPIRED) { return 0; }  // TLS close_notify
            if (st != SEC_E_OK)
            {
                // SEC_I_RENEGOTIATE included: not worth supporting, reconnecting is cheap.
                error = "TLS decrypt " + hex(st);
                return -1;
            }
            std::string extra;
            for (auto& b : bufs)
            {
                if (b.BufferType == SECBUFFER_DATA && b.cbBuffer > 0) { out.append(static_cast<const char*>(b.pvBuffer), b.cbBuffer); }
                if (b.BufferType == SECBUFFER_EXTRA && b.cbBuffer > 0) { extra.assign(static_cast<const char*>(b.pvBuffer), b.cbBuffer); }
            }
            m_cipher = std::move(extra);
        }
        return 1;
    }
} // namespace tt
