#pragma once
/*
    ChatQueue -- the hand-off point between background producers (synthetic
    generator now, Twitch client later) and the game thread.

    Producers call push() from any thread. The Lua mod calls pop() on the game
    thread. Nothing here knows about Unreal or Lua.

    Bounded: when the game thread cannot keep up (or is not draining at all, e.g.
    in a menu), the OLDEST messages are dropped and counted, so a chat burst can
    never grow memory without limit.
*/

#include <cstdint>
#include <deque>
#include <mutex>
#include <optional>
#include <string>

namespace tt
{
    // Same shape as ChatMessage in the Lua mod (tt/chatmodel.lua): UTF-8 strings.
    struct ChatMessage
    {
        std::string user;
        std::string text;
        std::string color; // "#RRGGBB" from the source, or empty for "pick one"
        // Twitch "emotes" tag as sent: "<id>:<first>-<last>,.../<id>:..." with code-point
        // positions into text; empty when the message has none.
        std::string emotes;
    };

    class ChatQueue
    {
      public:
        explicit ChatQueue(size_t capacity) : m_capacity(capacity) {}

        void push(ChatMessage msg);
        std::optional<ChatMessage> pop();

        struct Stats
        {
            size_t queued;
            uint64_t pushed;
            uint64_t dropped;
        };
        Stats stats() const;

      private:
        const size_t m_capacity;
        mutable std::mutex m_mutex;
        std::deque<ChatMessage> m_items;
        uint64_t m_pushed{0};
        uint64_t m_dropped{0};
    };
} // namespace tt
