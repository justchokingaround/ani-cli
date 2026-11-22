-- party.lua: watch-together glue for `ani-cli --party` (Syncplay shared playlist)
--
-- Syncplay opens shared playlist entries with a bare `loadfile <url>`, so the
-- per-file Referer/Origin/audio/subtitle options travel in the url fragment:
--   https://cdn/master.m3u8#ap&r=<referer>&o=<origin>&a=<audio>&s=<subs>&t=<title>&h=1&p=<start>&i=<id>&e=<ep>
-- This hook strips the fragment and turns it into file-local mpv options, so
-- both viewers' mpv fetch the stream directly with the right headers.
--
-- Host only (--script-opts=ani_party-host=yes,ani_party-cmd=/path/to/ani-cli,...):
--   * at queue_at of an episode, asks ani-cli for the next episode's url and
--     queues it into the Syncplay room ("/qa <url>" through Syncplay's chat hook)
--   * saves the position to `state` for `ani-cli --party -c` resume

local mp = require "mp"
local msg = require "mp.msg"

local o = {
    host = false,
    cmd = "ani-cli",
    mode = "sub",
    quality = "best",
    state = "",
    queue_at = 80, -- percent
    sub_delay = 0, -- seconds, applied to every episode (friend: `--script-opts=ani_party-sub_delay=-1.5`)
    -- mpv's default readahead (150 MiB) pulls ~90 segments in seconds and the CDNs answer
    -- 429 and segments get skipped; 90 s of cache keeps it at one segment per segment length
    cache_secs = 90,
}
require("mp.options").read_options(o, "ani_party")

local cur -- parsed fragment of the playing file

local function unesc(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse(url)
    local base, frag = url:match("^(https?://[^#]+)#ap&(.*)$")
    if not base then return nil end
    local t = {}
    for k, v in frag:gmatch("([^&=]+)=([^&]*)") do t[k] = unesc(v) end
    return base, t
end

mp.add_hook("on_load", 9, function()
    local base, t = parse(mp.get_property("stream-open-filename", ""))
    cur = t
    if not base then return end
    local fl = "file-local-options/"
    mp.set_property("stream-open-filename", base)
    mp.set_property(fl .. "ytdl", "no")
    if t.r then mp.set_property(fl .. "referrer", t.r) end
    if t.o then mp.set_property_native(fl .. "http-header-fields", { "Origin: " .. t.o }) end
    if t.a then mp.set_property_native(fl .. "audio-files", { t.a }) end
    if t.s then mp.set_property_native(fl .. "sub-files", { t.s }) end
    -- same rule as ani-cli: forcing the hls demuxer would also apply to the sub file
    if t.h == "1" and not t.s then
        mp.set_property(fl .. "demuxer-lavf-format", "hls")
    end
    if t.t then mp.set_property(fl .. "force-media-title", t.t) end
    if tonumber(o.cache_secs) > 0 then mp.set_property(fl .. "cache-secs", o.cache_secs) end
    if tonumber(o.sub_delay) ~= 0 then mp.set_property(fl .. "sub-delay", o.sub_delay) end
    msg.info("ani-party: " .. (t.t or base))
end)

if not o.host then return end

local queued = {}

-- resume: seek when the host first unpauses. Earlier is useless: Syncplay ignores the player
-- position for 11 s after loading a stream, and a friend whose file is still loading reports 0
-- and drags the room back. After the first unpause both sides are loaded and the seek propagates.
local resume_at
mp.register_event("file-loaded", function()
    resume_at = cur and tonumber(cur.p)
    if resume_at then
        mp.osd_message(string.format("ani-party: press space when everyone is in, resumes at %d:%02d",
            math.floor(resume_at / 60), math.floor(resume_at % 60)), 8)
    end
end)
mp.observe_property("pause", "bool", function(_, paused)
    if paused or not resume_at then return end
    local p = resume_at
    resume_at = nil
    if (mp.get_property_number("time-pos") or 0) < p - 5 then
        mp.add_timeout(0.5, function() mp.set_property_number("time-pos", p) end)
    end
end)

local function save(pos)
    if o.state == "" or not cur or not cur.i then return end
    local f = io.open(o.state, "w")
    if not f then return end
    f:write(string.format("%s\t%s\t%d\n", cur.i, cur.e or "", math.floor(pos or 0)))
    f:close()
end

local function queue_next(t)
    local key = t.i .. "\t" .. (t.e or "")
    if queued[key] then return end
    queued[key] = true
    mp.osd_message("ani-party: fetching next episode...", 3)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        args = { o.cmd, "--party-next", t.i, t.e or "", o.mode, o.quality, ((t.t or ""):gsub(" Episode [^ ]*$", "")) },
    }, function(ok, res)
        local url = ok and res.status == 0 and res.stdout:match("(https?://[^\r\n]+)")
        if not url then
            mp.osd_message("ani-party: no next episode", 4)
            return
        end
        -- Syncplay's mpv interface executes "<chat>/cmd</chat>" lines as Syncplay commands
        mp.commandv("print-text", "<chat>/qa " .. url .. "</chat>")
        mp.osd_message("ani-party: next episode queued", 3)
    end)
end

local last = 0
mp.observe_property("time-pos", "number", function(_, pos)
    if not pos or not cur or not cur.i then return end
    if math.abs(pos - last) >= 5 then
        last = pos
        save(pos)
    end
    local pct = mp.get_property_number("percent-pos", 0)
    if pct >= tonumber(o.queue_at) then queue_next(cur) end
end)

mp.register_event("end-file", function(e)
    if cur and cur.i and e.reason == "eof" then save(0) end
end)
