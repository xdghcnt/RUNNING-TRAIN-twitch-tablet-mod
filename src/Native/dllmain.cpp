/*
    RunningTrainTwitchTabletNative
    ------------------------------
    The C++ half of the TwitchTablet mod. It owns everything that must not run on
    the game thread -- background chat producers (Milestone 8: synthetic, M9:
    Twitch IRC) -- and a bounded queue. The Lua mod drains that queue on the game
    thread and does all Unreal work.

    Why C++ does no Unreal work at all: the Unreal headers (UEPseudo) are not
    available, so this DLL builds against UE4SS's public headers only, exactly
    like HeadTracking's UDP receiver (see HEADTRACKING_REFERENCE.md).

    Threading contract:
      * producer threads touch only ChatQueue (mutex-protected);
      * the Lua functions below are called by the Lua mod on the game thread only;
      * no Lua and no UObject is ever touched from a background thread.

    Lua API (registered only into the RunningTrainTwitchTablet Lua mod):
        RTTT_Version()                                   -> string
        RTTT_StartSynthetic(intervalMs, burstEvery, burstSize) -> bool
        RTTT_StopSynthetic()                             -> bool (was running)
        RTTT_PopMessage()                                -> user, text, color("#RRGGBB" or ""), emotes tag | nil
        RTTT_Status()                                    -> queued, pushed, dropped, syntheticRunning
        RTTT_TwitchStart(channel)                        -> bool
        RTTT_TwitchStop()                                -> bool (was running)
        RTTT_TwitchDrop()                                -- test: abort the connection like a network failure
        RTTT_TwitchStatus()                              -> state, channel, received, connects, lastError
        RTTT_EmoteRequest(id, path)                      -> "ready" | "pending" | "failed" (1.0)
        RTTT_EmoteStats()                                -> downloaded, failed, cached, queued, lastError (1.0)
*/

#include <Mod/CppUserModBase.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>

#include "ChatQueue.hpp"
#include "EmoteFetcher.hpp"
#include "SyntheticProducer.hpp"
#include "TwitchClient.hpp"

#include <memory>
#include <string>
#include <string_view>

namespace
{
    constexpr const char* kVersion = "1.0.0";
    constexpr size_t kQueueCapacity = 500;
} // namespace

class TwitchTabletNativeMod : public RC::CppUserModBase
{
  public:
    TwitchTabletNativeMod()
    {
        ModName = STR("RunningTrainTwitchTabletNative");
        ModVersion = STR("1.0.0");
        ModDescription = STR("Background chat producers and queue for RunningTrainTwitchTablet");
        ModAuthors = STR("RunningTrainTwitchTablet");
        s_instance = this;
    }

    ~TwitchTabletNativeMod() override
    {
        // Lua may still hold references to our functions; they check s_instance.
        s_instance = nullptr;
        m_twitch.stop();
        m_synthetic.stop();
        m_emotes.stop();
    }

    // Called for every Lua mod that starts; we only serve our own.
    auto on_lua_start(RC::StringViewType mod_name,
                      RC::LuaMadeSimple::Lua& lua,
                      RC::LuaMadeSimple::Lua& main_lua,
                      RC::LuaMadeSimple::Lua& async_lua,
                      RC::LuaMadeSimple::Lua* hook_lua) -> void override
    {
        if (mod_name != STR("RunningTrainTwitchTablet")) { return; }
        register_into(lua);
        register_into(main_lua);
        register_into(async_lua);
        if (hook_lua) { register_into(*hook_lua); }
    }

  private:
    static void register_into(RC::LuaMadeSimple::Lua& lua)
    {
        lua.register_function("RTTT_Version", &lua_version);
        lua.register_function("RTTT_StartSynthetic", &lua_start_synthetic);
        lua.register_function("RTTT_StopSynthetic", &lua_stop_synthetic);
        lua.register_function("RTTT_PopMessage", &lua_pop_message);
        lua.register_function("RTTT_Status", &lua_status);
        lua.register_function("RTTT_TwitchStart", &lua_twitch_start);
        lua.register_function("RTTT_TwitchStop", &lua_twitch_stop);
        lua.register_function("RTTT_TwitchDrop", &lua_twitch_drop);
        lua.register_function("RTTT_TwitchStatus", &lua_twitch_status);
        lua.register_function("RTTT_EmoteRequest", &lua_emote_request);
        lua.register_function("RTTT_EmoteStats", &lua_emote_stats);
    }

    static int arg_int(const RC::LuaMadeSimple::Lua& lua, int fallback)
    {
        if (lua.is_number()) { return static_cast<int>(lua.get_number()); }
        return fallback;
    }

    static int lua_version(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.set_string(std::string_view(kVersion));
        return 1;
    }

    static int lua_start_synthetic(const RC::LuaMadeSimple::Lua& lua)
    {
        if (!s_instance)
        {
            lua.set_bool(false);
            return 1;
        }
        const int interval = arg_int(lua, 3000);
        const int burstEvery = arg_int(lua, 0);
        const int burstSize = arg_int(lua, 20);
        s_instance->m_synthetic.start(interval, burstEvery, burstSize);
        lua.set_bool(s_instance->m_synthetic.running());
        return 1;
    }

    static int lua_stop_synthetic(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.set_bool(s_instance ? s_instance->m_synthetic.stop() : false);
        return 1;
    }

    static int lua_pop_message(const RC::LuaMadeSimple::Lua& lua)
    {
        if (!s_instance)
        {
            lua.set_nil();
            return 1;
        }
        auto msg = s_instance->m_queue.pop();
        if (!msg)
        {
            lua.set_nil();
            return 1;
        }
        lua.set_string(std::string_view(msg->user));
        lua.set_string(std::string_view(msg->text));
        lua.set_string(std::string_view(msg->color));
        lua.set_string(std::string_view(msg->emotes));
        return 4;
    }

    static int lua_emote_request(const RC::LuaMadeSimple::Lua& lua)
    {
        if (!s_instance || !lua.is_string())
        {
            lua.set_string(std::string_view("failed"));
            return 1;
        }
        // Each get_string() pops and returns a view: copy before the next call.
        const std::string id(lua.get_string());
        if (!lua.is_string())
        {
            lua.set_string(std::string_view("failed"));
            return 1;
        }
        const std::string path(lua.get_string());
        const std::string state = s_instance->m_emotes.request(id, path);
        lua.set_string(std::string_view(state));
        return 1;
    }

    static int lua_emote_stats(const RC::LuaMadeSimple::Lua& lua)
    {
        tt::EmoteFetcher::Stats st{};
        if (s_instance) { st = s_instance->m_emotes.stats(); }
        lua.set_integer(static_cast<int64_t>(st.downloaded));
        lua.set_integer(static_cast<int64_t>(st.failed));
        lua.set_integer(static_cast<int64_t>(st.cached));
        lua.set_integer(static_cast<int64_t>(st.queued));
        lua.set_string(std::string_view(st.lastError));
        return 5;
    }

    static int lua_twitch_start(const RC::LuaMadeSimple::Lua& lua)
    {
        if (!s_instance || !lua.is_string())
        {
            lua.set_bool(false);
            return 1;
        }
        // get_string() pops the argument and returns a view into it: copy at once,
        // before anything else can run the Lua GC.
        const std::string channel(lua.get_string());
        s_instance->m_twitch.start(channel);
        lua.set_bool(true);
        return 1;
    }

    static int lua_twitch_stop(const RC::LuaMadeSimple::Lua& lua)
    {
        lua.set_bool(s_instance ? s_instance->m_twitch.stop() : false);
        return 1;
    }

    static int lua_twitch_drop(const RC::LuaMadeSimple::Lua&)
    {
        if (s_instance) { s_instance->m_twitch.dropConnection(); }
        return 0;
    }

    static int lua_twitch_status(const RC::LuaMadeSimple::Lua& lua)
    {
        tt::TwitchClient::Status st;
        if (s_instance) { st = s_instance->m_twitch.status(); }
        else { st.state = "unloaded"; }
        lua.set_string(std::string_view(st.state));
        lua.set_string(std::string_view(st.channel));
        lua.set_integer(static_cast<int64_t>(st.received));
        lua.set_integer(static_cast<int64_t>(st.connects));
        lua.set_string(std::string_view(st.lastError));
        lua.set_integer(static_cast<int64_t>(st.bytes));
        return 6;
    }

    static int lua_status(const RC::LuaMadeSimple::Lua& lua)
    {
        if (!s_instance)
        {
            lua.set_integer(0);
            lua.set_integer(0);
            lua.set_integer(0);
            lua.set_bool(false);
            return 4;
        }
        const auto st = s_instance->m_queue.stats();
        lua.set_integer(static_cast<int64_t>(st.queued));
        lua.set_integer(static_cast<int64_t>(st.pushed));
        lua.set_integer(static_cast<int64_t>(st.dropped));
        lua.set_bool(s_instance->m_synthetic.running());
        return 4;
    }

    tt::ChatQueue m_queue{kQueueCapacity};
    tt::SyntheticProducer m_synthetic{m_queue};
    tt::TwitchClient m_twitch{m_queue};
    tt::EmoteFetcher m_emotes;

    static TwitchTabletNativeMod* s_instance;
};

TwitchTabletNativeMod* TwitchTabletNativeMod::s_instance = nullptr;

extern "C"
{
    __declspec(dllexport) RC::CppUserModBase* start_mod()
    {
        return new TwitchTabletNativeMod();
    }

    __declspec(dllexport) void uninstall_mod(RC::CppUserModBase* mod)
    {
        delete mod;
    }
}
