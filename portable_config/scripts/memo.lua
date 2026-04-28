-- memo.lua
--
-- Modern optimized recent-files menu for mpv.
--
-- Recommended mpv: 0.39+
-- Optional: uosc 5+
--
-- History format: JSON Lines.
-- Use a new history file if migrating from the original memo.lua.

local mp = mp
local utils = require "mp.utils"
local options_mod = require "mp.options"
local assdraw = require "mp.assdraw"
local msg = require "mp.msg"

local unpack = table.unpack or unpack
local script_name = mp.get_script_name()

local options = {
    -- Empty = in-memory only.
    history_path = "~~/memo-history.jsonl",

    entries = 10,
    pagination = true,

    hide_duplicates = true,
    hide_deleted = true,
    hide_same_dir = false,

    timestamp_format = "%Y-%m-%d %H:%M:%S",

    use_titles = true,
    truncate_titles = 60,

    enabled = true,

    up_binding = "UP WHEEL_UP",
    down_binding = "DOWN WHEEL_DOWN",
    select_binding = "RIGHT ENTER",
    append_binding = "Shift+RIGHT Shift+ENTER",
    close_binding = "LEFT ESC",

    -- 0 = read entire history file.
    max_scan_lines = 5000,

    path_prefixes = "pattern:.*",
}

local function parse_path_prefixes(value)
    local prefixes = {}

    for prefix in tostring(value or ""):gmatch("([^|]+)") do
        if prefix:sub(1, 8) == "pattern:" then
            prefixes[#prefixes + 1] = {
                pattern = prefix:sub(9),
                plain = false,
            }
        else
            prefixes[#prefixes + 1] = {
                pattern = prefix,
                plain = true,
            }
        end
    end

    return prefixes
end

local parsed_path_prefixes = parse_path_prefixes(options.path_prefixes)

options_mod.read_options(options, "memo", function(changed)
    if changed.path_prefixes then
        parsed_path_prefixes = parse_path_prefixes(options.path_prefixes)
    end
end)

local history_path = nil

if options.history_path ~= "" then
    history_path = mp.command_native({ "expand-path", options.history_path })
end

local memory_history = {}
local history_writer = nil

local history_dirty = true
local cached_records = nil
local cached_history_key = nil

local uosc_available = false

local menu_open = false
local menu_data = nil
local current_page = 1
local selected_index = 1

local search_query = nil
local search_words = nil

local palette_mode = false
local dir_menu = false
local dir_prefixes = parsed_path_prefixes

local fallback_bound = false

local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 2000
overlay.hidden = true

local data_protocols = {
    edl = true,
    data = true,
    null = true,
    memory = true,
    hex = true,
    fd = true,
    fdclose = true,
    mf = true,
}

local function semver_lt(a, b)
    local ai = tostring(a or ""):gmatch("%d+")
    local bi = tostring(b or ""):gmatch("%d+")

    while true do
        local av = ai()
        local bv = bi()

        if not bv then return false end
        if not av then return true end

        av = tonumber(av)
        bv = tonumber(bv)

        if av < bv then return true end
        if av > bv then return false end
    end
end

mp.register_script_message("uosc-version", function(version)
    uosc_available = not semver_lt(version, "5.0.0")
end)

pcall(function()
    mp.commandv("script-message-to", "uosc", "get-version", script_name)
end)

local function protocol_of(path)
    if type(path) ~= "string" then return nil end

    return path:match("^(%a[%w%.%+%-]*)://")
        or path:match("^(%a[%w%.%+%-]*):%?")
end

local function is_remote_path(path)
    local proto = protocol_of(path)
    return proto ~= nil and proto ~= "file"
end

local function normalize_path(path)
    if not path or path == "" then return path end
    if is_remote_path(path) then return path end

    local ok, normalized = pcall(mp.command_native, { "normalize-path", path })

    if ok and normalized and normalized ~= "" then
        return normalized
    end

    return path
end

local function current_path()
    local path = mp.get_property("path")

    if not path or path == "" or path == "-" or path == "/dev/stdin" then
        return nil
    end

    if not is_remote_path(path) then
        path = normalize_path(path)
    end

    return path
end

local function url_decode(str)
    return tostring(str or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function display_path(path)
    path = tostring(path or "")

    if path:sub(1, 7) == "file://" then
        return path:sub(8)
    end

    if is_remote_path(path) then
        return url_decode(path)
    end

    return path
end

local function dirname_of(path)
    local dir = utils.split_path(path)
    return dir ~= "" and dir or "."
end

local function basename_of(path)
    local _, base = utils.split_path(path)
    return base ~= "" and base or path
end

local accent_map = {
    ["À"] = "A",
    ["Á"] = "A",
    ["Â"] = "A",
    ["Ã"] = "A",
    ["Ä"] = "A",
    ["Å"] = "A",
    ["Ā"] = "A",
    ["Ă"] = "A",
    ["Ą"] = "A",
    ["Ç"] = "C",
    ["Ć"] = "C",
    ["Ĉ"] = "C",
    ["Ċ"] = "C",
    ["Č"] = "C",
    ["È"] = "E",
    ["É"] = "E",
    ["Ê"] = "E",
    ["Ë"] = "E",
    ["Ē"] = "E",
    ["Ĕ"] = "E",
    ["Ė"] = "E",
    ["Ę"] = "E",
    ["Ě"] = "E",
    ["Ì"] = "I",
    ["Í"] = "I",
    ["Î"] = "I",
    ["Ï"] = "I",
    ["Ĩ"] = "I",
    ["Ī"] = "I",
    ["Ĭ"] = "I",
    ["Į"] = "I",
    ["İ"] = "I",
    ["Ñ"] = "N",
    ["Ń"] = "N",
    ["Ņ"] = "N",
    ["Ň"] = "N",
    ["Ò"] = "O",
    ["Ó"] = "O",
    ["Ô"] = "O",
    ["Õ"] = "O",
    ["Ö"] = "O",
    ["Ø"] = "O",
    ["Ō"] = "O",
    ["Ŏ"] = "O",
    ["Ő"] = "O",
    ["Ù"] = "U",
    ["Ú"] = "U",
    ["Û"] = "U",
    ["Ü"] = "U",
    ["Ũ"] = "U",
    ["Ū"] = "U",
    ["Ŭ"] = "U",
    ["Ů"] = "U",
    ["Ű"] = "U",
    ["Ų"] = "U",
    ["Ý"] = "Y",
    ["Ÿ"] = "Y",
    ["Ŷ"] = "Y",
    ["Ź"] = "Z",
    ["Ż"] = "Z",
    ["Ž"] = "Z",

    ["à"] = "a",
    ["á"] = "a",
    ["â"] = "a",
    ["ã"] = "a",
    ["ä"] = "a",
    ["å"] = "a",
    ["ā"] = "a",
    ["ă"] = "a",
    ["ą"] = "a",
    ["ç"] = "c",
    ["ć"] = "c",
    ["ĉ"] = "c",
    ["ċ"] = "c",
    ["č"] = "c",
    ["è"] = "e",
    ["é"] = "e",
    ["ê"] = "e",
    ["ë"] = "e",
    ["ē"] = "e",
    ["ĕ"] = "e",
    ["ė"] = "e",
    ["ę"] = "e",
    ["ě"] = "e",
    ["ì"] = "i",
    ["í"] = "i",
    ["î"] = "i",
    ["ï"] = "i",
    ["ĩ"] = "i",
    ["ī"] = "i",
    ["ĭ"] = "i",
    ["į"] = "i",
    ["ı"] = "i",
    ["ñ"] = "n",
    ["ń"] = "n",
    ["ņ"] = "n",
    ["ň"] = "n",
    ["ò"] = "o",
    ["ó"] = "o",
    ["ô"] = "o",
    ["õ"] = "o",
    ["ö"] = "o",
    ["ø"] = "o",
    ["ō"] = "o",
    ["ŏ"] = "o",
    ["ő"] = "o",
    ["ù"] = "u",
    ["ú"] = "u",
    ["û"] = "u",
    ["ü"] = "u",
    ["ũ"] = "u",
    ["ū"] = "u",
    ["ŭ"] = "u",
    ["ů"] = "u",
    ["ű"] = "u",
    ["ų"] = "u",
    ["ý"] = "y",
    ["ÿ"] = "y",
    ["ŷ"] = "y",
    ["ź"] = "z",
    ["ż"] = "z",
    ["ž"] = "z",
}

local utf8_pattern = "[%z\1-\127\194-\244][\128-\191]*"

local function fold(str)
    str = tostring(str or "")
    str = str:gsub(utf8_pattern, accent_map)
    str = str:gsub("[%z\1-\31\127]", "")
    str = str:gsub("\226\128[\139-\143]", "")
    str = str:gsub("\239\187\191", "")
    return str:lower()
end

local function utf8_chars(str)
    local chars = {}

    for char in tostring(str or ""):gmatch(utf8_pattern) do
        chars[#chars + 1] = char
    end

    return chars
end

local function char_width(char)
    return #char > 2 and 2 or 1
end

local function visual_width(str)
    local width = 0

    for _, char in ipairs(utf8_chars(str)) do
        width = width + char_width(char)
    end

    return width
end

local function truncate_title(title, max_width)
    if max_width <= 0 or visual_width(title) <= max_width then
        return title
    end

    local chars = utf8_chars(title)
    local out = {}
    local width = 0
    local limit = math.max(max_width - 3, 1)

    for _, char in ipairs(chars) do
        local cw = char_width(char)

        if width + cw > limit then
            break
        end

        out[#out + 1] = char
        width = width + cw
    end

    local shortened = table.concat(out):gsub("[%s%._%-%(%)%[%]]+$", "")

    if shortened == "" then
        shortened = table.concat(out)
    end

    return shortened .. "..."
end

local function ass_escape(str)
    str = tostring(str or "")
    str = str:gsub("\\", "\\\239\187\191")
    str = str:gsub("{", "\\{")
    str = str:gsub("}", "\\}")
    return str
end

local function parse_query_parts(query)
    local parts = {}
    local pos = query:find("%S")
    local len = #query

    while pos and pos <= len do
        local first = query:sub(pos, pos)
        local part
        local stop

        if first == '"' or first == "'" then
            stop = query:find(first, pos + 1, true)

            if not stop then
                part = query:sub(pos + 1)
                stop = len
            else
                part = query:sub(pos + 1, stop - 1)
            end
        else
            stop = query:find("%s", pos) or (len + 1)
            part = query:sub(pos, stop - 1)
        end

        if part ~= "" then
            parts[#parts + 1] = part
        end

        pos = query:find("%S", stop + 1)
    end

    return parts
end

local function set_search(query)
    query = tostring(query or "")

    if query == "" then
        search_query = nil
        search_words = nil
        return
    end

    search_query = query
    search_words = parse_query_parts(fold(query))
end

local function matches_search(text)
    if not search_words then return true end

    text = fold(text)

    for _, word in ipairs(search_words) do
        if not text:find(word, 1, true) then
            return false
        end
    end

    return true
end

local function ensure_history_writer()
    if not history_path then return nil end

    if history_writer then
        return history_writer
    end

    local file, err = io.open(history_path, "ab")

    if not file then
        msg.warn("cannot open history file: " .. tostring(err))
        return nil
    end

    history_writer = file
    return history_writer
end

local function append_history(record)
    if not history_path then
        memory_history[#memory_history + 1] = record
        history_dirty = true
        return true
    end

    local json = utils.format_json(record)

    if not json then
        msg.warn("could not serialize history entry")
        return false
    end

    local file = ensure_history_writer()

    if not file then
        return false
    end

    file:write(json, "\n")
    file:flush()

    history_dirty = true
    return true
end

local function current_title()
    local pos = mp.get_property_number("playlist-pos", -1)
    local title = ""

    if pos >= 0 then
        title = mp.get_property("playlist/" .. pos .. "/title", "") or ""
    end

    if title == "" then
        title = mp.get_property("media-title", "") or ""
    end

    return title:gsub("\n", " ")
end

local function write_history(show_osd)
    local path = current_path()

    if not path then
        if show_osd then mp.osd_message("[memo] no path to log") end
        return
    end

    local proto = protocol_of(path)

    if proto and data_protocols[proto] then
        if show_osd then
            mp.osd_message("[memo] not logging " .. proto .. " entry")
        end

        return
    end

    local ok = append_history({
        v = 1,
        time = os.time(),
        title = current_title(),
        path = path,
    })

    if ok then
        msg.debug("logged: " .. path)

        if show_osd then
            mp.osd_message("[memo] logged current file")
        end
    elseif show_osd then
        mp.osd_message("[memo] failed to write history")
    end
end

local function count_newlines(str)
    local _, count = str:gsub("\n", "")
    return count
end

local function tail_lines(path, max_lines)
    if history_writer then
        history_writer:flush()
    end

    local file = io.open(path, "rb")
    if not file then return {} end

    local size = file:seek("end") or 0
    local data = ""

    if max_lines == 0 then
        file:seek("set", 0)
        data = file:read("*a") or ""
    else
        local pos = size
        local chunk_size = 65536
        local chunks = {}
        local lines_seen = 0

        while pos > 0 and lines_seen <= max_lines do
            local read_size = math.min(chunk_size, pos)
            pos = pos - read_size

            file:seek("set", pos)

            local chunk = file:read(read_size) or ""
            chunks[#chunks + 1] = chunk
            lines_seen = lines_seen + count_newlines(chunk)
        end

        local ordered = {}

        for i = #chunks, 1, -1 do
            ordered[#ordered + 1] = chunks[i]
        end

        data = table.concat(ordered)

        -- If we started reading in the middle of a file, discard the partial line.
        if pos > 0 then
            local first_newline = data:find("\n", 1, true)
            data = first_newline and data:sub(first_newline + 1) or ""
        end
    end

    file:close()

    if data == "" then return {} end
    if data:sub(-1) ~= "\n" then data = data .. "\n" end

    local lines = {}

    for line in data:gmatch("(.-)\n") do
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end

    if max_lines > 0 and #lines > max_lines then
        local trimmed = {}
        local start = #lines - max_lines + 1

        for i = start, #lines do
            trimmed[#trimmed + 1] = lines[i]
        end

        lines = trimmed
    end

    return lines
end

local function history_stat_key()
    if not history_path then
        return "memory:" .. tostring(#memory_history)
    end

    local info = utils.file_info(history_path)

    if not info then
        return "missing"
    end

    return tostring(info.size or 0) .. ":" .. tostring(info.mtime or 0)
end

local function load_history_records()
    if not history_path then
        return memory_history
    end

    local key = history_stat_key()

    if not history_dirty and cached_records and cached_history_key == key then
        return cached_records
    end

    local lines = tail_lines(history_path, tonumber(options.max_scan_lines) or 5000)
    local records = {}

    for _, line in ipairs(lines) do
        local ok, record = pcall(utils.parse_json, line)

        if ok and type(record) == "table" and type(record.path) == "string" then
            records[#records + 1] = record
        end
    end

    cached_records = records
    cached_history_key = key
    history_dirty = false

    return records
end

local function history_iterator()
    local records = load_history_records()
    local i = #records + 1

    return function()
        i = i - 1
        return records[i]
    end
end

local function record_meta(record)
    local meta = record._memo_meta

    if meta then
        return meta
    end

    local path = record.path
    local remote = is_remote_path(path)
    local shown = display_path(path)
    local effective = remote and path or normalize_path(path)

    meta = {
        path = path,
        remote = remote,
        shown = shown,
        effective = effective,
        key = effective,
    }

    record._memo_meta = meta
    return meta
end

local function find_prefix(path, prefixes)
    for _, prefix in ipairs(prefixes or {}) do
        local start_pos, end_pos = path:find(prefix.pattern, 1, prefix.plain)

        if start_pos then
            return start_pos, end_pos
        end
    end
end

local function directory_menu_title(path)
    local dir = dirname_of(path)

    if dir == "." then return nil end

    local unix = dir:gsub("\\", "/")

    if unix:sub(-1) ~= "/" then
        unix = unix .. "/"
    end

    local parent = unix:sub(1, -2):match("^(.*)/") or ""
    local _, stop = find_prefix(parent, dir_prefixes)

    if not stop then
        return nil
    end

    local rest = unix:sub(stop + 1)
    local name = rest:match("^/?([^/]+)/")

    if not name or name == "" then
        return nil
    end

    return name, unix
end

local function file_exists(path, cache)
    local cached = cache[path]

    if cached ~= nil then
        return cached
    end

    local exists = utils.file_info(path) ~= nil
    cache[path] = exists

    return exists
end

local function make_item(record, known_files, known_dirs, exists_cache)
    local meta = record_meta(record)

    if options.hide_duplicates and known_files[meta.key] then
        return nil
    end

    if dir_menu and meta.remote then
        return nil
    end

    local title
    local dir_key = nil

    if dir_menu then
        title, dir_key = directory_menu_title(meta.shown)

        if not title then
            return nil
        end

        if known_dirs[dir_key] then
            return nil
        end
    else
        title = options.use_titles and tostring(record.title or "") or ""

        if title == "" then
            title = meta.remote and meta.shown or basename_of(meta.shown)
        end

        if options.hide_same_dir and not meta.remote then
            dir_key = dirname_of(meta.shown)

            if known_dirs[dir_key] then
                return nil
            end
        end
    end

    title = title:gsub("\n", " ")

    local searchable = options.use_titles and title or meta.shown

    if not matches_search(searchable) then
        return nil
    end

    if options.hide_deleted and not meta.remote then
        if not file_exists(meta.effective, exists_cache) then
            return nil
        end
    end

    if options.truncate_titles > 0 then
        title = truncate_title(title, options.truncate_titles)
    end

    known_files[meta.key] = true

    if dir_key then
        known_dirs[dir_key] = true
    end

    local timestamp = tonumber(record.time)
    local hint = timestamp and os.date(options.timestamp_format, timestamp) or ""

    return {
        title = title,
        hint = hint,
        value = { "loadfile", meta.path, "replace" },
    }
end

local function build_matches(limit)
    local iter = history_iterator()
    local known_files = {}
    local known_dirs = {}
    local exists_cache = {}
    local items = {}

    while true do
        local record = iter()

        if not record then
            break
        end

        local item = make_item(record, known_files, known_dirs, exists_cache)

        if item then
            items[#items + 1] = item

            if limit and #items >= limit then
                break
            end
        end
    end

    return items
end

local function menu_title()
    local title

    if search_query then
        title = search_query
    elseif dir_menu then
        title = "Directories"
    else
        title = "History"
    end

    title = title .. " (memo)"

    if options.pagination or current_page ~= 1 then
        title = title .. " - Page " .. current_page
    end

    return title
end

local function build_page()
    local per_page = math.max(tonumber(options.entries) or 10, 1)
    local extra = options.pagination and 1 or 0
    local needed = current_page * per_page + extra
    local matches = build_matches(needed)

    local first = (current_page - 1) * per_page + 1

    if first > #matches and current_page > 1 then
        current_page = current_page - 1
        return build_page()
    end

    local last = math.min(current_page * per_page, #matches)
    local items = {}

    for i = first, last do
        items[#items + 1] = matches[i]
    end

    if options.pagination then
        if #matches > current_page * per_page then
            items[#items + 1] = {
                title = "Older entries",
                hint = "",
                icon = "navigate_next",
                italic = true,
                muted = true,
                keep_open = true,
                value = { "script-binding", "memo-next" },
            }
        end

        if current_page > 1 then
            items[#items + 1] = {
                title = "Newer entries",
                hint = "",
                icon = "navigate_before",
                italic = true,
                muted = true,
                keep_open = true,
                value = { "script-binding", "memo-prev" },
            }
        end
    end

    return {
        type = "memo-history",
        title = menu_title(),
        items = items,
        on_search = { "script-message-to", script_name, "memo-search-uosc:" },
        on_close = { "script-message-to", script_name, "memo-clear" },
        palette = palette_mode,
        search_style = palette_mode and "palette" or nil,
    }
end

local function uosc_update()
    local json = utils.format_json(menu_data) or "{}"

    mp.commandv(
        "script-message-to",
        "uosc",
        menu_open and "update-menu" or "open-menu",
        json
    )

    menu_open = true
end

local function bind_keys(keys, name, fn, opts)
    if not keys or keys == "" then return end

    local i = 1

    for key in keys:gmatch("%S+") do
        local suffix = i == 1 and "" or tostring(i)
        mp.add_forced_key_binding(key, name .. suffix, fn, opts)
        i = i + 1
    end
end

local function unbind_keys(keys, name)
    if not keys or keys == "" then return end

    local i = 1

    for _ in keys:gmatch("%S+") do
        local suffix = i == 1 and "" or tostring(i)
        mp.remove_key_binding(name .. suffix)
        i = i + 1
    end
end

local function playlist_contains(path)
    local wanted = is_remote_path(path) and path or normalize_path(path)
    local playlist = mp.get_property_native("playlist", {})

    for _, item in ipairs(playlist) do
        local filename = item.filename

        if filename then
            local candidate = is_remote_path(filename) and filename or normalize_path(filename)

            if candidate == wanted then
                return true
            end
        end
    end

    return false
end

local close_menu

local function select_current(append)
    if not menu_data or not menu_data.items then return end

    local item = menu_data.items[selected_index]

    if not item or not item.value then return end

    local command = {}

    for i, value in ipairs(item.value) do
        command[i] = value
    end

    if append and command[1] == "loadfile" then
        if playlist_contains(command[2]) then
            mp.osd_message("[memo] file is already in playlist")
            return
        end

        command[3] = "append-play"
    end

    if not item.keep_open then
        close_menu()
    end

    mp.commandv(unpack(command))
end

local function draw_fallback()
    if not menu_open or not menu_data then return end

    local width, height = mp.get_osd_size()
    local font_size = mp.get_property_number("osd-font-size", 36)
    local line_height = font_size * 1.25
    local x = font_size * 0.6
    local y = font_size * 0.8

    local items = menu_data.items or {}

    if #items > 0 then
        selected_index = math.max(1, math.min(selected_index, #items))
    else
        selected_index = 0
    end

    local visible = math.max(1, math.floor((height - y - line_height * 2) / line_height))
    local first = 1

    if selected_index > 0 then
        first = math.max(1, selected_index - math.floor(visible / 2))
        first = math.min(first, math.max(1, #items - visible + 1))
    end

    local last = math.min(#items, first + visible - 1)

    local ass = assdraw.ass_new()

    ass.text = "{\\rDefault\\pos(0,0)\\an7\\1c&H000000&\\alpha&H80&}"
    ass:draw_start()
    ass:rect_cw(0, 0, width, height)
    ass:draw_stop()

    ass:new_event()
    ass:pos(x, y)
    ass:append("{\\rDefault\\an7\\fs" .. font_size .. "\\bord2\\b1}")
    ass:append(ass_escape(menu_data.title))
    ass:append("{\\b0}")

    if #items == 0 then
        ass:new_event()
        ass:pos(x, y + line_height * 1.5)
        ass:append("{\\rDefault\\an7\\fs" .. font_size .. "\\bord2}")
        ass:append("No entries")
    else
        for i = first, last do
            local item = items[i]
            local marker = i == selected_index and "●" or "○"
            local line = item.title or ""

            if item.hint and item.hint ~= "" then
                line = line .. "    " .. item.hint
            end

            ass:new_event()
            ass:pos(x, y + line_height * (i - first + 1.5))
            ass:append("{\\rDefault\\an7\\fs" .. font_size .. "\\bord2}")
            ass:append(ass_escape(marker .. " " .. line))
        end
    end

    overlay.res_x = width
    overlay.res_y = height
    overlay.hidden = false
    overlay.data = ass.text
    overlay:update()
end

local function fallback_open()
    if fallback_bound then
        draw_fallback()
        return
    end

    fallback_bound = true

    bind_keys(options.up_binding, "memo-up", function()
        if not menu_data or not menu_data.items or #menu_data.items == 0 then return end
        selected_index = math.max(selected_index - 1, 1)
        draw_fallback()
    end, { repeatable = true })

    bind_keys(options.down_binding, "memo-down", function()
        if not menu_data or not menu_data.items or #menu_data.items == 0 then return end
        selected_index = math.min(selected_index + 1, #menu_data.items)
        draw_fallback()
    end, { repeatable = true })

    bind_keys(options.select_binding, "memo-select", function()
        select_current(false)
    end)

    bind_keys(options.append_binding, "memo-append", function()
        select_current(true)
    end)

    bind_keys(options.close_binding, "memo-close", function()
        close_menu()
    end)

    menu_open = true
    draw_fallback()
end

local function fallback_close()
    if fallback_bound then
        unbind_keys(options.up_binding, "memo-up")
        unbind_keys(options.down_binding, "memo-down")
        unbind_keys(options.select_binding, "memo-select")
        unbind_keys(options.append_binding, "memo-append")
        unbind_keys(options.close_binding, "memo-close")
        fallback_bound = false
    end

    overlay.hidden = true
    overlay.data = ""
    overlay:update()
end

close_menu = function()
    if uosc_available and menu_open then
        mp.commandv("script-message-to", "uosc", "close-menu", "memo-history")
    end

    fallback_close()

    menu_open = false
    menu_data = nil
    selected_index = 1
    palette_mode = false
end

local function render_menu()
    menu_data = build_page()

    if #menu_data.items > 0 then
        selected_index = math.max(1, math.min(selected_index, #menu_data.items))
    else
        selected_index = 0
    end

    if uosc_available then
        uosc_update()
    else
        fallback_open()
    end
end

local function open_history()
    current_page = 1
    selected_index = 1
    search_query = nil
    search_words = nil
    palette_mode = false
    dir_menu = false
    dir_prefixes = parsed_path_prefixes

    render_menu()
end

local function open_dirs(prefixes)
    current_page = 1
    selected_index = 1
    search_query = nil
    search_words = nil
    palette_mode = false
    dir_menu = true
    dir_prefixes = prefixes and parse_path_prefixes(prefixes) or parsed_path_prefixes

    render_menu()
end

local function next_page()
    current_page = current_page + 1
    selected_index = 1
    render_menu()
end

local function prev_page()
    current_page = math.max(1, current_page - 1)
    selected_index = 1
    render_menu()
end

local function open_last()
    local now = current_path()

    local old_hide_duplicates = options.hide_duplicates
    local old_hide_deleted = options.hide_deleted
    local old_hide_same_dir = options.hide_same_dir

    local old_search_query = search_query
    local old_search_words = search_words
    local old_dir_menu = dir_menu

    options.hide_duplicates = true
    options.hide_deleted = true
    options.hide_same_dir = false

    search_query = nil
    search_words = nil
    dir_menu = false

    local matches = build_matches(3)

    options.hide_duplicates = old_hide_duplicates
    options.hide_deleted = old_hide_deleted
    options.hide_same_dir = old_hide_same_dir

    search_query = old_search_query
    search_words = old_search_words
    dir_menu = old_dir_menu

    for _, item in ipairs(matches) do
        local path = item.value and item.value[2]

        if path and path ~= now then
            mp.commandv(unpack(item.value))
            return
        end
    end

    mp.osd_message("[memo] no recent files to open")
end

local function file_loaded()
    if options.enabled then
        write_history(false)
    end

    if menu_open and current_page == 1 then
        render_menu()
    end
end

mp.register_script_message("memo-clear", function()
    menu_open = false
    menu_data = nil
    selected_index = 1
    search_query = nil
    search_words = nil
    palette_mode = false
    dir_menu = false
end)

mp.register_script_message("memo-search:", function(...)
    mp.commandv("keypress", "ESC")

    set_search(table.concat({ ... }, " "))

    current_page = 1
    selected_index = 1
    palette_mode = false

    render_menu()
end)

mp.register_script_message("memo-search-uosc:", function(query)
    set_search(query)

    current_page = 1
    selected_index = 1

    render_menu()
end)

mp.register_script_message("memo-dirs", function(prefixes)
    open_dirs(prefixes)
end)

mp.add_key_binding(nil, "memo-next", next_page)
mp.add_key_binding(nil, "memo-prev", prev_page)

mp.add_key_binding(nil, "memo-log", function()
    write_history(true)

    if menu_open and current_page == 1 then
        render_menu()
    end
end)

mp.add_key_binding(nil, "memo-last", open_last)

mp.add_key_binding(nil, "memo-search", function()
    if uosc_available then
        current_page = 1
        selected_index = 1
        palette_mode = true
        render_menu()
        return
    end

    if menu_open then
        close_menu()
    end

    mp.commandv("script-message-to", "console", "type", "script-message memo-search: ")
end)

mp.add_key_binding("h", "memo-history", open_history)

mp.register_event("file-loaded", file_loaded)
