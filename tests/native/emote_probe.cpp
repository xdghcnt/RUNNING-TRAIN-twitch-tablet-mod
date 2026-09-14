// Emote download check outside the game: the mod's EmoteFetcher against the
// real Twitch CDN. Exit code 0 = all good. Built and run by Test-EmoteProbe.ps1.

#include "EmoteFetcher.hpp"

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <string>
#include <thread>

int main(int argc, char** argv)
{
    const std::string dir = argc > 1 ? argv[1] : "emote_probe_cache";
    std::filesystem::remove_all(dir);
    auto path = [&](const std::string& id) { return dir + "\\" + id + ".png"; };

    tt::EmoteFetcher f;
    const char* ids[] = {"25", "1902", "999999999999"};   // Kappa, Keepo, one that does not exist
    for (const char* id : ids) { std::printf("request %s -> %s\n", id, f.request(id, path(id)).c_str()); }
    std::printf("bad id -> %s\n", f.request("../evil", path("evil")).c_str());

    std::string s25, s1902, sBad;
    for (int i = 0; i < 100; ++i)
    {
        s25 = f.request("25", path("25"));
        s1902 = f.request("1902", path("1902"));
        sBad = f.request("999999999999", path("999999999999"));
        if (s25 != "pending" && s1902 != "pending" && sBad != "pending") { break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    const auto st = f.stats();
    std::printf("25 %s, 1902 %s, missing %s | downloaded %llu failed %llu | last error: %s\n", s25.c_str(), s1902.c_str(),
                sBad.c_str(), static_cast<unsigned long long>(st.downloaded), static_cast<unsigned long long>(st.failed),
                st.lastError.c_str());
    const bool files = std::filesystem::exists(path("25")) && std::filesystem::file_size(path("25")) > 100;
    std::printf("25.png on disk: %s (%llu bytes)\n", files ? "yes" : "no",
                files ? static_cast<unsigned long long>(std::filesystem::file_size(path("25"))) : 0ull);

    // A fresh fetcher must see the files as a cache, without downloading.
    tt::EmoteFetcher again;
    const std::string cached = again.request("25", path("25"));
    std::printf("fresh fetcher: 25 -> %s (cached %llu)\n", cached.c_str(), static_cast<unsigned long long>(again.stats().cached));

    const bool ok = s25 == "ready" && s1902 == "ready" && sBad == "failed" && files && cached == "ready";
    std::printf("%s\n", ok ? "EMOTE PROBE OK" : "EMOTE PROBE FAILED");
    return ok ? 0 : 1;
}
