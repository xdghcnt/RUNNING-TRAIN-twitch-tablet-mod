#include "EmoteFetcher.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <Windows.h>
#include <winhttp.h>

#include <vector>

namespace tt
{
    namespace
    {
        constexpr size_t kMaxBytes = 2 * 1024 * 1024;
        constexpr int kTimeoutMs = 8000;

        std::wstring widen(const std::string& s)
        {
            if (s.empty()) { return {}; }
            const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
            std::wstring out(static_cast<size_t>(n), L'\0');
            MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
            return out;
        }

        // Twitch ids: digits, or "emotesv2_" + hex. Anything else is not put into a URL or a file name.
        bool validId(const std::string& id)
        {
            if (id.empty() || id.size() > 64) { return false; }
            for (char c : id)
            {
                const bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
                if (!ok) { return false; }
            }
            return true;
        }

        bool fileExists(const std::wstring& path)
        {
            WIN32_FILE_ATTRIBUTE_DATA a{};
            if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &a)) { return false; }
            return (a.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 && (a.nFileSizeLow != 0 || a.nFileSizeHigh != 0);
        }

        struct Handle
        {
            HINTERNET h{nullptr};
            ~Handle() { if (h) { WinHttpCloseHandle(h); } }
        };
    } // namespace

    EmoteFetcher::~EmoteFetcher() { stop(); }

    std::string EmoteFetcher::request(const std::string& id, const std::string& path)
    {
        if (!validId(id) || path.empty()) { return "failed"; }
        std::unique_lock<std::mutex> lock(m_mutex);
        auto it = m_state.find(id);
        if (it != m_state.end())
        {
            return it->second == State::Ready ? "ready" : it->second == State::Pending ? "pending" : "failed";
        }
        if (fileExists(widen(path)))
        {
            m_state[id] = State::Ready;
            ++m_cached;
            return "ready";
        }
        if (m_stopping) { return "failed"; }
        m_state[id] = State::Pending;
        m_jobs.push_back(Job{id, path});
        if (!m_worker.joinable()) { m_worker = std::thread(&EmoteFetcher::run, this); }
        lock.unlock();
        m_cv.notify_one();
        return "pending";
    }

    EmoteFetcher::Stats EmoteFetcher::stats() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return Stats{m_downloaded, m_failed, m_cached, m_jobs.size(), m_lastError};
    }

    void EmoteFetcher::stop()
    {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_stopping = true;
            m_jobs.clear();
        }
        m_cv.notify_all();
        if (m_worker.joinable()) { m_worker.join(); }
    }

    void EmoteFetcher::run()
    {
        for (;;)
        {
            Job job;
            {
                std::unique_lock<std::mutex> lock(m_mutex);
                m_cv.wait(lock, [this] { return m_stopping || !m_jobs.empty(); });
                if (m_stopping) { return; }
                job = std::move(m_jobs.front());
                m_jobs.pop_front();
            }
            std::string error;
            const bool ok = download(job, error);
            std::lock_guard<std::mutex> lock(m_mutex);
            m_state[job.id] = ok ? State::Ready : State::Failed;
            if (ok) { ++m_downloaded; }
            else
            {
                ++m_failed;
                m_lastError = job.id + ": " + error;
            }
        }
    }

    bool EmoteFetcher::download(const Job& job, std::string& error)
    {
        Handle session;
        session.h = WinHttpOpen(L"RunningTrainTwitchTablet", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                                WINHTTP_NO_PROXY_BYPASS, 0);
        if (!session.h)
        {
            // Older Windows 10 builds lack AUTOMATIC_PROXY.
            session.h = WinHttpOpen(L"RunningTrainTwitchTablet", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME,
                                    WINHTTP_NO_PROXY_BYPASS, 0);
        }
        if (!session.h) { error = "WinHttpOpen " + std::to_string(GetLastError()); return false; }
        WinHttpSetTimeouts(session.h, kTimeoutMs, kTimeoutMs, kTimeoutMs, kTimeoutMs);

        Handle connect;
        connect.h = WinHttpConnect(session.h, L"static-cdn.jtvnw.net", INTERNET_DEFAULT_HTTPS_PORT, 0);
        if (!connect.h) { error = "WinHttpConnect " + std::to_string(GetLastError()); return false; }

        const std::wstring object = L"/emoticons/v2/" + widen(job.id) + L"/static/dark/3.0";
        Handle request;
        request.h = WinHttpOpenRequest(connect.h, L"GET", object.c_str(), nullptr, WINHTTP_NO_REFERER,
                                       WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
        if (!request.h) { error = "WinHttpOpenRequest " + std::to_string(GetLastError()); return false; }
        if (!WinHttpSendRequest(request.h, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
            !WinHttpReceiveResponse(request.h, nullptr))
        {
            error = "request " + std::to_string(GetLastError());
            return false;
        }
        DWORD status = 0;
        DWORD size = sizeof(status);
        WinHttpQueryHeaders(request.h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                            &status, &size, WINHTTP_NO_HEADER_INDEX);
        if (status != 200) { error = "HTTP " + std::to_string(status); return false; }

        std::vector<char> body;
        for (;;)
        {
            DWORD avail = 0;
            if (!WinHttpQueryDataAvailable(request.h, &avail)) { error = "read " + std::to_string(GetLastError()); return false; }
            if (avail == 0) { break; }
            const size_t at = body.size();
            if (at + avail > kMaxBytes) { error = "too large"; return false; }
            body.resize(at + avail);
            DWORD got = 0;
            if (!WinHttpReadData(request.h, body.data() + at, avail, &got)) { error = "read " + std::to_string(GetLastError()); return false; }
            body.resize(at + got);
        }
        // PNG signature: the engine's importer is the next step, give it only images.
        if (body.size() < 8 || static_cast<unsigned char>(body[0]) != 0x89 || body[1] != 'P' || body[2] != 'N' || body[3] != 'G')
        {
            error = "not a PNG";
            return false;
        }

        const std::wstring path = widen(job.path);
        const size_t slash = path.find_last_of(L"\\/");
        if (slash != std::wstring::npos) { CreateDirectoryW(path.substr(0, slash).c_str(), nullptr); }
        const std::wstring tmp = path + L".tmp";
        HANDLE f = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f == INVALID_HANDLE_VALUE) { error = "create file " + std::to_string(GetLastError()); return false; }
        DWORD written = 0;
        const BOOL wrote = WriteFile(f, body.data(), static_cast<DWORD>(body.size()), &written, nullptr);
        CloseHandle(f);
        if (!wrote || written != body.size())
        {
            DeleteFileW(tmp.c_str());
            error = "write failed";
            return false;
        }
        if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING))
        {
            DeleteFileW(tmp.c_str());
            error = "rename " + std::to_string(GetLastError());
            return false;
        }
        return true;
    }
} // namespace tt
