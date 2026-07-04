-- ytsub.lua
-- YouTube/yt-dlp subtitle loader for mpv
--
-- Named bindings if this file is named ytsub.lua:
--   script-binding ytsub/auto
--   script-binding ytsub/load
--
-- Script messages:
--   script-message-to ytsub auto
--   script-message-to ytsub load
--   script-message-to ytsub load-lang en
--   script-message-to ytsub load-lang en secondary

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local function try_require(name)
    local ok, mod = pcall(require, name)
    if ok then
        return mod
    end
    return nil
end

local input = try_require("mp.input")
local http = try_require("socket.http")
local https = try_require("ssl.https")

local options = {
    -- Secondary/source subtitle language.
    -- Empty = disabled.
    -- Supports comma/semicolon preference list:
    --   source_lang=en,en-US,ja
    source_lang = "",

    -- Manual language picker.
    -- Empty = no default hotkey, but script-binding ytsub/load remains available.
    load_autosub_binding = "Alt+Y",

    -- Auto-load original language.
    -- Empty = no default hotkey, but script-binding ytsub/auto remains available.
    autoload_autosub_binding = "Alt+y",

    -- Automatically run auto mode after file load.
    autoload_on_file_load = false,
    autoload_delay = 0.35,

    -- Cache directory.
    cache_dir = "~~/ytsub_cache_dir",

    -- Legacy workaround from the original script.
    filter_sub_single_line = false,

    -- Download methods.
    use_lua_http = true,
    use_curl = true,
    use_ytdlp_fallback = true,

    -- Direct URL fallback is disabled by default because YouTube often returns 429,
    -- and mpv may fail asynchronously after sub-add returns.
    try_direct_url_fallback = false,
    direct_url_verify_delay = 1.0,

    -- Manual menu only shows captions with a direct or derivable VTT URL.
    only_show_vtt_in_menu = true,

    -- Also include normal/manual subtitles from yt-dlp's "subtitles" field.
    -- Auto captions are preferred when both exist for a language.
    include_manual_subs = false,

    -- Executable names/paths.
    -- Empty ytdlp_path means: use mpv ytdl-hook path, then "yt-dlp".
    curl_path = "curl",
    ytdlp_path = "",

    -- Optional extra yt-dlp arguments.
    -- Generic default: empty.
    -- Example if you personally need cookies:
    --   ytdlp_extra_args=--cookies-from-browser chrome
    ytdlp_extra_args = "",

    -- Network options.
    user_agent = "Mozilla/5.0",
    network_timeout = 20,
    curl_retries = 2,
}

require("mp.options").read_options(options)

local SCRIPT = "ytsub"

math.randomseed(os.time())

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function non_empty(value)
    value = trim(value)
    if value == "" then
        return nil
    end
    return value
end

local function osd(level, text)
    local line = SCRIPT .. ": " .. tostring(text)

    if level == "warn" then
        msg.warn(text)
    elseif level == "error" then
        msg.error(text)
    else
        msg.info(text)
    end

    mp.osd_message(line, 5)
end

local function osd_info(text)
    osd("info", text)
end

local function osd_warn(text)
    osd("warn", text)
end

local function expand_path(path)
    local ok, expanded = pcall(mp.command_native, { "expand-path", path })

    if ok and type(expanded) == "string" and expanded ~= "" then
        return expanded
    end

    return path
end

options.cache_dir = expand_path(options.cache_dir)

local function platform_is_windows()
    local platform = tostring(mp.get_property_native("platform") or ""):lower()
    return platform:find("windows", 1, true) or platform:find("win32", 1, true)
end

local function short_error(text)
    text = tostring(text or "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("\r", "")
    text = text:match("([^\n]+)") or text

    if #text > 300 then
        text = text:sub(1, 300) .. "..."
    end

    if text == "" then
        return "unknown error"
    end

    return text
end

local function run_subprocess(args)
    local ok, result = pcall(mp.command_native, {
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    })

    if not ok then
        return nil, tostring(result)
    end

    if type(result) ~= "table" then
        return nil, "no subprocess result"
    end

    if result.status ~= 0 then
        return nil, short_error(result.stderr or result.stdout or ("exit status " .. tostring(result.status)))
    end

    return result, nil
end

local function ensure_dir(path)
    local info = utils.file_info(path)

    if info and info.is_dir then
        return true
    end

    if info and not info.is_dir then
        osd_warn("cache path exists but is not a directory: " .. path)
        return false
    end

    local args

    if platform_is_windows() then
        args = { "cmd", "/d", "/c", "mkdir", path }
    else
        args = { "mkdir", "-p", path }
    end

    local _, err = run_subprocess(args)

    if err then
        osd_warn("failed to create cache directory: " .. err)
        return false
    end

    local created = utils.file_info(path)

    if not created or not created.is_dir then
        osd_warn("failed to create cache directory: " .. path)
        return false
    end

    return true
end

local function file_exists(path)
    local info = utils.file_info(path)
    return info and info.is_file and info.size and info.size > 0
end

local function delete_file(path)
    if path and path ~= "" then
        os.remove(path)
    end
end

local function replace_file(src, dst)
    delete_file(dst)

    local ok, err = os.rename(src, dst)

    if not ok then
        delete_file(src)
        osd_warn("failed to move subtitle into cache: " .. tostring(err))
        return false
    end

    return true
end

local function temp_path_for(path)
    return path .. ".part-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999))
end

local function is_probably_vtt(path)
    local file = io.open(path, "rb")

    if not file then
        return false
    end

    local head = file:read(512) or ""
    file:close()

    head = head:gsub("^\239\187\191", "")
    return head:match("^%s*WEBVTT") ~= nil
end

local function valid_cached_vtt(path)
    return file_exists(path) and is_probably_vtt(path)
end

local function safe_filename_component(value)
    value = tostring(value or "unknown")
    value = value:gsub("[/\\:%*%?\"<>|%c]", "_")
    value = value:gsub("^%s+", "")
    value = value:gsub("%s+$", "")
    value = value:gsub("%s+", " ")

    if value == "" then
        value = "unknown"
    end

    if #value > 180 then
        value = value:sub(1, 180)
    end

    return value
end

local function get_subtitle_paths(cache_key, lang)
    local base = utils.join_path(options.cache_dir, safe_filename_component(cache_key))
    local subfile = base .. "." .. safe_filename_component(lang) .. ".vtt"

    return base, subfile
end

local function filter_sub(path)
    -- Kept only for compatibility with the old script.
    -- Disabled by default because it is format-specific and destructive.
    local lines = {}

    local read_ok, read_err = pcall(function()
        for line in io.lines(path) do
            table.insert(lines, line)
        end
    end)

    if not read_ok then
        osd_warn("failed to read subtitle for filtering: " .. tostring(read_err))
        return
    end

    local out, err = io.open(path, "w")

    if not out then
        osd_warn("failed to filter subtitle: " .. tostring(err))
        return
    end

    for i, line in ipairs(lines) do
        if i < 5 or i % 8 == 5 or i % 8 == 7 or i % 8 == 0 then
            out:write(line)
            out:write("\n")
        end
    end

    out:close()
end

local function name_to_string(name)
    if type(name) == "string" then
        return name
    end

    if type(name) == "table" then
        return name.simple_text or name.text or name[1]
    end

    return nil
end

local function looks_like_youtube_caption_url(url)
    url = tostring(url or "")
    return url:find("timedtext", 1, true) ~= nil or url:find("fmt=", 1, true) ~= nil
end

local function url_with_vtt_format(url)
    url = non_empty(url)

    if not url then
        return nil
    end

    if url:find("[?&]fmt=vtt") then
        return url
    end

    if url:find("[?&]fmt=") then
        return url:gsub("([?&])fmt=[^&]*", "%1fmt=vtt", 1)
    end

    local sep = url:find("?", 1, true) and "&" or "?"
    return url .. sep .. "fmt=vtt"
end

local function get_caption_info(caption_formats)
    if type(caption_formats) ~= "table" then
        return nil, nil, nil
    end

    local lang_name
    local fallback_url
    local vtt_url

    for _, item in ipairs(caption_formats) do
        if type(item) == "table" then
            lang_name = lang_name or name_to_string(item.name)

            local url = non_empty(item.url)

            if url then
                fallback_url = fallback_url or url

                if tostring(item.ext or ""):lower() == "vtt" then
                    lang_name = name_to_string(item.name) or lang_name
                    vtt_url = url
                    break
                end
            end
        end
    end

    -- yt-dlp may expose YouTube timedtext URLs in another format first.
    -- Adding/replacing fmt=vtt usually gives a VTT URL.
    if not vtt_url and fallback_url and looks_like_youtube_caption_url(fallback_url) then
        vtt_url = url_with_vtt_format(fallback_url)
    end

    return lang_name, vtt_url, fallback_url
end

local function get_lang_display_name(lang, caption_formats)
    local lang_name = get_caption_info(caption_formats)

    if lang_name and lang_name ~= "" then
        return lang_name .. " [" .. lang .. "]"
    end

    return lang
end

local function write_atomic(destination, data)
    local tmp = temp_path_for(destination)

    local file, err = io.open(tmp, "wb")

    if not file then
        osd_warn("failed to write subtitle file: " .. tostring(err))
        return false
    end

    local ok, write_err = file:write(data)
    local close_ok, close_err = file:close()

    if not ok or not close_ok then
        delete_file(tmp)
        osd_warn("failed to write subtitle file: " .. tostring(write_err or close_err))
        return false
    end

    if not valid_cached_vtt(tmp) then
        delete_file(tmp)
        return false
    end

    return replace_file(tmp, destination)
end

local function download_with_lua_http(url, destination)
    if not options.use_lua_http then
        return false
    end

    url = non_empty(url)

    if not url then
        return false
    end

    local client

    if url:match("^https://") then
        client = https
    elseif url:match("^http://") then
        client = http
    end

    if not client or not client.request then
        return false
    end

    local timeout = tonumber(options.network_timeout or 0)

    if timeout and timeout > 0 then
        if http then
            http.TIMEOUT = timeout
        end

        if https then
            https.TIMEOUT = timeout
        end
    end

    local ok, body, status = pcall(client.request, {
        url = url,
        headers = {
            ["User-Agent"] = options.user_agent,
        },
    })

    -- Some LuaSocket/LuaSec versions are picky; retry with the simple form.
    if not ok or type(body) ~= "string" then
        ok, body, status = pcall(client.request, url)
    end

    status = tonumber(status)

    if not ok or type(body) ~= "string" or not status or status < 200 or status >= 300 then
        msg.warn("Lua HTTP subtitle download failed with status: " .. tostring(status))
        return false
    end

    if not write_atomic(destination, body) then
        msg.warn("Lua HTTP subtitle download did not produce valid VTT")
        return false
    end

    return true
end

local function download_with_curl(url, destination)
    if not options.use_curl then
        return false
    end

    url = non_empty(url)

    if not url then
        return false
    end

    local tmp = temp_path_for(destination)

    local args = {
        options.curl_path,
        "-L",
        "--fail",
        "--silent",
        "--show-error",
        "--compressed",
        "--retry", tostring(options.curl_retries),
        "-A", options.user_agent,
        "-o", tmp,
    }

    local timeout = tonumber(options.network_timeout or 0)

    if timeout and timeout > 0 then
        table.insert(args, "--connect-timeout")
        table.insert(args, tostring(timeout))
        table.insert(args, "--max-time")
        table.insert(args, tostring(timeout * 2))
    end

    table.insert(args, url)

    local _, err = run_subprocess(args)

    if err then
        msg.warn("curl subtitle download failed: " .. err)
        delete_file(tmp)
        return false
    end

    if not valid_cached_vtt(tmp) then
        msg.warn("curl subtitle download did not produce valid VTT")
        delete_file(tmp)
        return false
    end

    return replace_file(tmp, destination)
end

local function download_direct(url, destination)
    if download_with_lua_http(url, destination) then
        return true
    end

    if download_with_curl(url, destination) then
        return true
    end

    return false
end

local function get_ytdlp_path()
    local configured = non_empty(options.ytdlp_path)

    if configured then
        return configured
    end

    local hook_path = mp.get_property_native("user-data/mpv/ytdl/path")

    if type(hook_path) == "table" then
        hook_path = hook_path[1]
    end

    if type(hook_path) == "string" and hook_path ~= "" then
        return hook_path
    end

    return "yt-dlp"
end

local function split_commandline_args(text)
    local args = {}
    text = tostring(text or "")

    local current = ""
    local quote = nil
    local escape = false

    for i = 1, #text do
        local c = text:sub(i, i)

        if escape then
            current = current .. c
            escape = false
        elseif c == "\\" then
            escape = true
        elseif quote then
            if c == quote then
                quote = nil
            else
                current = current .. c
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c:match("%s") then
            if current ~= "" then
                table.insert(args, current)
                current = ""
            end
        else
            current = current .. c
        end
    end

    if current ~= "" then
        table.insert(args, current)
    end

    return args
end

local function append_extra_args(args, extra)
    for _, arg in ipairs(split_commandline_args(extra)) do
        table.insert(args, arg)
    end
end

local function download_with_ytdlp(lang, subfile_base, expected_subfile, video_url)
    if not options.use_ytdlp_fallback then
        return false
    end

    video_url = non_empty(video_url)

    if not video_url then
        return false
    end

    local args = {
        get_ytdlp_path(),
        "--no-playlist",
        "--skip-download",
        "--write-auto-subs",
        "--sub-langs", lang,
        "--sub-format", "vtt",
        "-o", subfile_base,
    }

    if options.include_manual_subs then
        table.insert(args, "--write-subs")
    end

    append_extra_args(args, options.ytdlp_extra_args)

    table.insert(args, "--")
    table.insert(args, video_url)

    local _, err = run_subprocess(args)

    if err then
        msg.warn("yt-dlp subtitle download failed: " .. err)
        return false
    end

    if not valid_cached_vtt(expected_subfile) then
        delete_file(expected_subfile)
        msg.warn("yt-dlp did not produce valid VTT")
        return false
    end

    return true
end

local function get_sub_track_ids()
    local ids = {}
    local tracks = mp.get_property_native("track-list") or {}

    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.id ~= nil then
            ids[track.id] = true
        end
    end

    return ids
end

local function find_existing_sub_track(path_or_url)
    local tracks = mp.get_property_native("track-list") or {}
    local expanded = expand_path(path_or_url)

    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.id ~= nil then
            local external = track["external-filename"]

            if external == path_or_url or external == expanded then
                return track.id
            end
        end
    end

    return nil
end

local function find_new_sub_id(before)
    local tracks = mp.get_property_native("track-list") or {}

    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.id ~= nil and not before[track.id] then
            return track.id
        end
    end

    return nil
end

local function select_subtitle_id(id, is_primary)
    if not id then
        return false
    end

    if is_primary then
        mp.set_property_native("sid", id)
        return true
    end

    local ok, err = pcall(mp.set_property_native, "secondary-sid", id)

    if not ok then
        osd_warn("could not select secondary subtitle: " .. tostring(err))
        return false
    end

    return true
end

local function add_subtitle_track(path_or_url, is_primary, lang)
    local existing_id = find_existing_sub_track(path_or_url)

    if existing_id then
        return select_subtitle_id(existing_id, is_primary)
    end

    local before = get_sub_track_ids()
    local title = "youtube auto-sub"
    local flag = is_primary and "select" or "cached"

    local ok, err = pcall(mp.commandv, "sub-add", path_or_url, flag, title, lang)

    -- Older mpv builds may not like "cached"; fall back to "auto".
    if not ok and not is_primary then
        ok, err = pcall(mp.commandv, "sub-add", path_or_url, "auto", title, lang)
    end

    if not ok then
        osd_warn("failed to add subtitle: " .. tostring(err))
        return false
    end

    if is_primary then
        return true
    end

    local new_id = find_new_sub_id(before)

    if new_id then
        return select_subtitle_id(new_id, false)
    end

    osd_warn("subtitle loaded, but could not select it as secondary subtitle")
    return false
end

local function add_url_subtitle_track_verified(path_or_url, is_primary, lang, lang_name)
    local before = get_sub_track_ids()
    local title = "youtube auto-sub"
    local flag = is_primary and "select" or "cached"

    local ok, err = pcall(mp.commandv, "sub-add", path_or_url, flag, title, lang)

    if not ok and not is_primary then
        ok, err = pcall(mp.commandv, "sub-add", path_or_url, "auto", title, lang)
    end

    if not ok then
        osd_warn("failed to add subtitle URL: " .. tostring(err))
        return false
    end

    local delay = tonumber(options.direct_url_verify_delay) or 1.0

    mp.add_timeout(delay, function()
        local id = find_existing_sub_track(path_or_url) or find_new_sub_id(before)

        if id then
            select_subtitle_id(id, is_primary)
            osd_info(lang_name .. " loaded from URL")
        else
            osd_warn(lang_name .. " direct URL fallback failed")
        end
    end)

    return true
end

local function load_autosub(lang, caption_formats, cache_key, video_url, is_primary)
    lang = non_empty(lang)

    if not lang then
        osd_info("no subtitle language specified")
        return false
    end

    if type(caption_formats) ~= "table" then
        osd_info("no subtitle available for " .. lang)
        return false
    end

    if not ensure_dir(options.cache_dir) then
        return false
    end

    local lang_name, vtt_url, fallback_url = get_caption_info(caption_formats)
    local direct_url = vtt_url or fallback_url

    lang_name = lang_name or lang

    if not direct_url then
        osd_info("no downloadable subtitle URL for " .. lang_name)
        return false
    end

    osd_info("loading " .. lang_name)

    local subfile_base, subfile = get_subtitle_paths(cache_key, lang)
    local available = valid_cached_vtt(subfile)

    if not available then
        delete_file(subfile)

        if vtt_url then
            available = download_direct(vtt_url, subfile)
        end
    end

    if not available then
        available = download_with_ytdlp(lang, subfile_base, subfile, video_url)
    end

    if available and options.filter_sub_single_line then
        filter_sub(subfile)
    end

    if available then
        if add_subtitle_track(subfile, is_primary, lang) then
            osd_info(lang_name .. " loaded")
            return true
        end

        return false
    end

    if options.try_direct_url_fallback and direct_url then
        osd_warn("failed to cache " .. lang_name .. ", trying direct URL")
        add_url_subtitle_track_verified(direct_url, is_primary, lang, lang_name)
        return true
    end

    osd_info("failed to download " .. lang_name)
    return false
end

local function get_ytdl_json()
    local parsed = mp.get_property_native("user-data/mpv/ytdl/json")

    if type(parsed) == "table" then
        return parsed
    end

    local result = mp.get_property_native("user-data/mpv/ytdl/json-subprocess-result")

    if type(result) ~= "table" or type(result.stdout) ~= "string" or result.stdout == "" then
        osd_info("no yt-dlp info available")
        return nil
    end

    local json, err = utils.parse_json(result.stdout)

    if type(json) ~= "table" then
        osd_warn("failed to parse yt-dlp info: " .. tostring(err))
        return nil
    end

    return json
end

local function sorted_lang_keys(subs)
    local langs = {}

    if type(subs) ~= "table" then
        return langs
    end

    for lang in pairs(subs) do
        table.insert(langs, lang)
    end

    table.sort(langs, function(a, b)
        return a:lower() < b:lower()
    end)

    return langs
end

local function get_available_subs(ytdl_info)
    local out = {}

    local auto = ytdl_info and ytdl_info.automatic_captions

    if type(auto) == "table" then
        for lang, formats in pairs(auto) do
            out[lang] = formats
        end
    end

    if options.include_manual_subs then
        local manual = ytdl_info and ytdl_info.subtitles

        if type(manual) == "table" then
            for lang, formats in pairs(manual) do
                if out[lang] == nil then
                    out[lang] = formats
                end
            end
        end
    end

    return out
end

local function build_lang_menu_items(subs)
    local items = {}

    for lang, formats in pairs(subs) do
        local _, vtt_url = get_caption_info(formats)

        if not options.only_show_vtt_in_menu or vtt_url then
            table.insert(items, {
                lang = lang,
                label = get_lang_display_name(lang, formats),
            })
        end
    end

    table.sort(items, function(a, b)
        return a.label:lower() < b.label:lower()
    end)

    return items
end

local function pattern_escape(text)
    return tostring(text):gsub("([^%w])", "%%%1")
end

local function find_matching_lang(subs, wanted)
    wanted = non_empty(wanted)

    if not wanted or type(subs) ~= "table" then
        return nil
    end

    if subs[wanted] then
        return wanted
    end

    if subs[wanted .. "-orig"] then
        return wanted .. "-orig"
    end

    local wanted_lower = wanted:lower()
    local langs = sorted_lang_keys(subs)

    for _, lang in ipairs(langs) do
        local lower = lang:lower()

        if lower == wanted_lower or lower == wanted_lower .. "-orig" then
            return lang
        end
    end

    local prefix = "^" .. pattern_escape(wanted_lower) .. "[-_]"

    for _, lang in ipairs(langs) do
        if lang:lower():match(prefix) then
            return lang
        end
    end

    return nil
end

local function split_lang_list(value)
    local list = {}

    for part in tostring(value or ""):gmatch("[^,;]+") do
        part = trim(part)

        if part ~= "" then
            table.insert(list, part)
        end
    end

    return list
end

local function find_first_preferred_lang(subs, value)
    for _, wanted in ipairs(split_lang_list(value)) do
        local found = find_matching_lang(subs, wanted)

        if found then
            return found
        end
    end

    return nil
end

local function find_original_lang(subs, ytdl_info)
    local candidates = {
        ytdl_info and ytdl_info.language,
        ytdl_info and ytdl_info.original_language,
    }

    for _, candidate in ipairs(candidates) do
        local found = find_matching_lang(subs, candidate)

        if found then
            return found
        end
    end

    for _, lang in ipairs(sorted_lang_keys(subs)) do
        local lower = lang:lower()

        if lower:find("%-orig$") or lower:find("orig", 1, true) then
            return lang
        end
    end

    return sorted_lang_keys(subs)[1]
end

local function get_video_url(ytdl_info)
    if ytdl_info then
        if non_empty(ytdl_info.webpage_url) then
            return ytdl_info.webpage_url
        end

        if non_empty(ytdl_info.original_url) then
            return ytdl_info.original_url
        end

        if non_empty(ytdl_info.id) then
            return "https://www.youtube.com/watch?v=" .. ytdl_info.id
        end
    end

    return mp.get_property("path")
end

local function get_cache_key(ytdl_info)
    local extractor = non_empty(ytdl_info and (ytdl_info.extractor_key or ytdl_info.extractor)) or "site"
    local id = non_empty(ytdl_info and (ytdl_info.id or ytdl_info.display_id)) or non_empty(mp.get_property("filename")) or
    "unknown"

    return safe_filename_component(extractor .. "_" .. id)
end

local function get_context()
    local ytdl_info = get_ytdl_json()

    if not ytdl_info then
        return nil
    end

    local subs = get_available_subs(ytdl_info)

    if type(subs) ~= "table" or next(subs) == nil then
        osd_info("no subtitles found")
        return nil
    end

    return {
        ytdl_info = ytdl_info,
        subs = subs,
        cache_key = get_cache_key(ytdl_info),
        video_url = get_video_url(ytdl_info),
    }
end

local function ytsub_auto()
    local ctx = get_context()

    if not ctx then
        return
    end

    local orig_lang = find_original_lang(ctx.subs, ctx.ytdl_info)

    if not orig_lang then
        osd_info("could not find original subtitle language")
        return
    end

    load_autosub(orig_lang, ctx.subs[orig_lang], ctx.cache_key, ctx.video_url, true)

    local source_lang = find_first_preferred_lang(ctx.subs, options.source_lang)

    if source_lang then
        if source_lang == orig_lang then
            osd_info("source language and original language are the same: " .. source_lang)
        else
            load_autosub(source_lang, ctx.subs[source_lang], ctx.cache_key, ctx.video_url, false)
        end
    elseif non_empty(options.source_lang) then
        osd_info("source language not available: " .. options.source_lang)
    end
end

local function ytsub_menu()
    local ctx = get_context()

    if not ctx then
        return
    end

    if not input or not input.select then
        osd_warn("mp.input is not available in this mpv build")
        return
    end

    local lang_items = build_lang_menu_items(ctx.subs)
    local labels = {}

    for _, item in ipairs(lang_items) do
        table.insert(labels, item.label)
    end

    if #labels == 0 then
        osd_info("no downloadable VTT subtitles found")
        return
    end

    input.select({
        prompt = "Select a YouTube subtitle language",
        items = labels,
        submit = function(selected)
            if not selected then
                return
            end

            local item

            if type(selected) == "number" then
                item = lang_items[selected]
            else
                for _, candidate in ipairs(lang_items) do
                    if candidate.label == selected then
                        item = candidate
                        break
                    end
                end
            end

            if not item then
                return
            end

            load_autosub(item.lang, ctx.subs[item.lang], ctx.cache_key, ctx.video_url, true)
        end,
    })
end

local function ytsub_load_lang(lang, where)
    lang = non_empty(lang)

    if not lang then
        osd_info("no language specified")
        return
    end

    local ctx = get_context()

    if not ctx then
        return
    end

    local found = find_matching_lang(ctx.subs, lang)

    if not found then
        osd_info("language not available: " .. lang)
        return
    end

    local is_primary = not (where == "secondary" or where == "2" or where == "false")
    load_autosub(found, ctx.subs[found], ctx.cache_key, ctx.video_url, is_primary)
end

local function normalize_key(key)
    return non_empty(key)
end

mp.add_key_binding(normalize_key(options.autoload_autosub_binding), "auto", ytsub_auto)
mp.add_key_binding(normalize_key(options.load_autosub_binding), "load", ytsub_menu)

mp.register_script_message("auto", ytsub_auto)
mp.register_script_message("load", ytsub_menu)
mp.register_script_message("load-lang", ytsub_load_lang)

if options.autoload_on_file_load then
    mp.register_event("file-loaded", function()
        local delay = tonumber(options.autoload_delay) or 0.35
        mp.add_timeout(delay, ytsub_auto)
    end)
end
