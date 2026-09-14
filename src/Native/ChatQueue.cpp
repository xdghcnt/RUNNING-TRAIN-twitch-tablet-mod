#include "ChatQueue.hpp"

namespace tt
{
    void ChatQueue::push(ChatMessage msg)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_items.push_back(std::move(msg));
        ++m_pushed;
        while (m_items.size() > m_capacity)
        {
            m_items.pop_front();
            ++m_dropped;
        }
    }

    std::optional<ChatMessage> ChatQueue::pop()
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_items.empty()) { return std::nullopt; }
        ChatMessage msg = std::move(m_items.front());
        m_items.pop_front();
        return msg;
    }

    ChatQueue::Stats ChatQueue::stats() const
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        return Stats{m_items.size(), m_pushed, m_dropped};
    }
} // namespace tt
