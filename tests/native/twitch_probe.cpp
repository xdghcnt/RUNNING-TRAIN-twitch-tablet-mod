/*
    twitch_probe -- runs the mod's TwitchClient + ChatQueue outside the game.

        twitch_probe <channel> [seconds]

    Connects, prints state changes and chat lines, simulates a network drop
    halfway through (dropConnection), checks that it reconnects, then stops and
    reports whether stop() returned promptly. Same sources as main.dll, no UE4SS.
*/

#include "ChatQueue.hpp"
#include "TwitchClient.hpp"

#include <chrono>
#include <cstdio>
#include <string>
#include <thread>

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        std::printf("usage: twitch_probe <channel> [seconds]\n");
        return 2;
    }
    const std::string channel = argv[1];
    const int seconds = argc > 2 ? std::atoi(argv[2]) : 30;

    tt::ChatQueue queue(500);
    tt::TwitchClient client(queue);
    client.start(channel);

    using clock = std::chrono::steady_clock;
    const auto t0 = clock::now();
    std::string lastState, lastError;
    bool dropped = false;
    uint64_t connectsAtDrop = 0;

    for (;;)
    {
        const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(clock::now() - t0).count();
        const auto st = client.status();
        if (st.state != lastState || st.lastError != lastError)
        {
            std::printf("[%3llds] state=%s channel=%s connects=%llu received=%llu error=\"%s\"\n",
                        static_cast<long long>(elapsed), st.state.c_str(), st.channel.c_str(),
                        static_cast<unsigned long long>(st.connects), static_cast<unsigned long long>(st.received),
                        st.lastError.c_str());
            lastState = st.state;
            lastError = st.lastError;
        }
        while (auto msg = queue.pop())
        {
            std::printf("  <%s|%s> %s\n", msg->user.c_str(), msg->color.c_str(), msg->text.c_str());
        }
        if (!dropped && elapsed >= seconds / 2)
        {
            dropped = true;
            connectsAtDrop = st.connects;
            std::printf("[%3llds] --- simulating network drop ---\n", static_cast<long long>(elapsed));
            client.dropConnection();
        }
        if (elapsed >= seconds) { break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    const auto st = client.status();
    const auto s0 = clock::now();
    const bool wasRunning = client.stop();
    const auto stopMs = std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - s0).count();
    std::printf("stop(): wasRunning=%d took %lld ms, final state=%s\n", wasRunning ? 1 : 0,
                static_cast<long long>(stopMs), client.status().state.c_str());
    std::printf("RESULT connects=%llu (before drop %llu) received=%llu reconnected=%s\n",
                static_cast<unsigned long long>(st.connects), static_cast<unsigned long long>(connectsAtDrop),
                static_cast<unsigned long long>(st.received), st.connects > connectsAtDrop ? "yes" : "NO");
    return st.connects > connectsAtDrop && stopMs < 2000 ? 0 : 1;
}
