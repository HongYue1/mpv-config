-- thumbfast-modern.lua
--
-- Modern, fast, reliable on-the-fly thumbnailer for mpv 0.38+
--
-- Public API kept:
--   script-message-to thumbfast thumb <time> <x> <y> [script]
--   script-message-to thumbfast clear
--   broadcasts: script-message thumbfast-info <json>
--   optional renderer callback: script-message-to <script> thumbfast-render <json>

local utils = require "mp.utils"
local options = require "mp.options"

local o = {
    -- Internal command-file base path. Empty = temp directory.
    socket = "",

    -- Thumbnail base path. Empty = temp directory.
    thumbnail = "",

    max_height = 200,
    max_width = 200,

    -- Display scale factor for overlay-add.
    scale_factor = 1,

    -- auto, no, none, clip, linear, gamma, reinhard, hable, mobius
    tone_mapping = "auto",

    overlay_id = 42,

    spawn_first = false,
    quit_after_inactivity = 0,

    network = false,
    audio = false,
    hwdec = false,

    -- Kept for config compatibility. Ignored.
    direct_io = false,

    mpv_path = "mpv",

    -- Internal tuning.
    file_check_interval = 1 / 30,
    seek_interval = 0.05,
    exact_seek_delay = 0.25,
    child_poll_interval = 1 / 60,
}

options.read_options(o, "thumbfast")

local msg = mp.msg
local noop = function() end

local platform = mp.get_property_native("platform") or ""
local is_windows = platform:find("windows", 1, true) ~= nil or package.config:sub(1, 1) == "\\"
local is_macos = platform:find("darwin", 1, true) ~= nil or platform:find("mac", 1, true) ~= nil
local sep = is_windows and "\\" or "/"

local function normalize_bool(v)
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end

    v = tostring(v or ""):lower()
    return v == "yes" or v == "true" or v == "1" or v == "on"
end

local function path_join(a, b)
    if not a or a == "" then return b end
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
    return a .. sep .. b
end

local function clamp_number(v, fallback, min_v, integer)
    v = tonumber(v)
    if v == nil then v = fallback end
    if integer then v = math.floor(v) end
    if min_v and v < min_v then v = min_v end
    return v
end

local function round(v)
    return math.floor((tonumber(v) or 0) + 0.5)
end

local function sanitize_time(v)
    v = tonumber(v)
    if not v or v ~= v then return nil end
    if v < 0 then return 0 end
    return v
end

o.max_width = clamp_number(o.max_width, 200, 1, true)
o.max_height = clamp_number(o.max_height, 200, 1, true)
o.scale_factor = clamp_number(o.scale_factor, 1, 0.001, false)

o.overlay_id = clamp_number(o.overlay_id, 42, 0, true)

o.file_check_interval = clamp_number(o.file_check_interval, 1 / 30, 0.001)
o.seek_interval = clamp_number(o.seek_interval, 0.05, 0.001)
o.child_poll_interval = clamp_number(o.child_poll_interval, 1 / 60, 0.001)

o.exact_seek_delay = tonumber(o.exact_seek_delay)
if o.exact_seek_delay == nil then o.exact_seek_delay = 0.25 end

o.quit_after_inactivity = tonumber(o.quit_after_inactivity) or 0
o.tone_mapping = tostring(o.tone_mapping or "auto"):lower()

o.spawn_first = normalize_bool(o.spawn_first)
o.network = normalize_bool(o.network)
o.audio = normalize_bool(o.audio)
o.hwdec = normalize_bool(o.hwdec)

local tmpdir =
    os.getenv("TMPDIR") or
    os.getenv("TEMP") or
    os.getenv("TMP") or
    (is_windows and "." or "/tmp")

local pid = tostring((utils.getpid and utils.getpid()) or math.floor(mp.get_time() * 1000000))
local instance = pid .. "." .. tostring(math.floor(mp.get_time() * 1000000))

if o.socket == "" then
    o.socket = path_join(tmpdir, "thumbfast-" .. instance)
else
    o.socket = o.socket .. instance
end

if o.thumbnail == "" then
    o.thumbnail = path_join(tmpdir, "thumbfast.out." .. instance)
else
    o.thumbnail = o.thumbnail .. instance
end

local thumbnail_bgra = o.thumbnail .. ".bgra"

local mpv_path = o.mpv_path
if is_windows and mpv_path == "mpv" then
    local frontend_path = mp.get_property_native("user-data/frontend/process-path")
    if type(frontend_path) == "string" and frontend_path ~= "" then
        mpv_path = frontend_path
    end
end

local properties = {}

local disabled = true
local dirty = false
local dirty_timer

local effective_w = o.max_width
local effective_h = o.max_height
local real_w, real_h
local last_real_w, last_real_h

local x, y
local last_x, last_y
local script_name
local last_script_name
local show_thumbnail = false
local overlay_visible = false

local has_vid = 0

local last_seek_time
local allow_fast_seek = true
local pending_seek = false

local last_rotate = 0
local last_vf_reset = ""
local last_full_vf = ""
local last_par = ""
local last_crop = nil
local last_tone_mapping = nil

local par = ""

local generation = 0
local current = nil
local children = {}

local seek_timer
local exact_seek_timer
local file_timer
local activity_timer

local file_poll_until = 0
local last_info_json = nil

local filters_reset = {
    ["lavfi-crop"] = true,
    ["crop"] = true,
}

local filters_all = {
    ["hflip"] = true,
    ["vflip"] = true,
    ["lavfi-crop"] = true,
    ["crop"] = true,
}

local tone_mappings = {
    ["none"] = true,
    ["clip"] = true,
    ["linear"] = true,
    ["gamma"] = true,
    ["reinhard"] = true,
    ["hable"] = true,
    ["mobius"] = true,
}

local function command_async(cmd)
    local ok, err = pcall(mp.command_native_async, cmd, noop)
    if not ok then
        msg.verbose("async command failed: " .. tostring(err))
    end
end

local function show_error(text)
    pcall(mp.commandv, "show-text", text, 5000)
end

local function subprocess_async(args, callback)
    local wrapped = noop

    if callback then
        wrapped = function(...)
            local ok, err = pcall(callback, ...)
            if not ok then
                msg.error("subprocess callback failed: " .. tostring(err))
            end
        end
    end

    local ok, handle = pcall(mp.command_native_async, {
        name = "subprocess",
        playback_only = true,
        args = args,
    }, wrapped)

    if not ok then
        msg.error("failed to start subprocess: " .. tostring(handle))
        return nil
    end

    return handle
end

local function atomic_write(path, data)
    local tmp = path .. ".tmp"
    data = tostring(data or "")

    local f, err = io.open(tmp, "wb")
    if not f then
        msg.warn("cannot open temporary command file: " .. tostring(err))
        return false
    end

    local ok_write, write_err = f:write(data)
    local ok_close, close_err = f:close()

    if not ok_write or not ok_close then
        msg.warn("cannot write temporary command file: " .. tostring(write_err or close_err))
        os.remove(tmp)
        return false
    end

    if is_windows then
        os.remove(path)
    end

    local ok_rename, rename_err = os.rename(tmp, path)
    if ok_rename then return true end

    -- Conservative fallback.
    local wf, open_err = io.open(path, "wb")
    if not wf then
        msg.warn("cannot write command file: " .. tostring(rename_err or open_err))
        os.remove(tmp)
        return false
    end

    local ok_fallback_write, fallback_write_err = wf:write(data)
    local ok_fallback_close, fallback_close_err = wf:close()
    os.remove(tmp)

    if not ok_fallback_write or not ok_fallback_close then
        msg.warn("cannot write command file: " .. tostring(fallback_write_err or fallback_close_err))
        return false
    end

    return true
end

local function move_file(from, to)
    if is_windows then os.remove(to) end
    return os.rename(from, to)
end

local function mark_dirty()
    dirty = true
    if dirty_timer and not dirty_timer:is_enabled() then
        dirty_timer:resume()
    end
end

local function vo_tone_mapping()
    local passes = mp.get_property_native("vo-passes")
    if not passes or not passes.fresh then return nil end

    for _, pass in ipairs(passes.fresh) do
        if type(pass) == "table" and pass.desc then
            local tm = tostring(pass.desc):match("([0-9a-zA-Z._-]+) tone map")
            if tm then return tm end
        end
    end

    return nil
end

local function vf_escape(v)
    return tostring(v)
        :gsub("\\", "\\\\")
        :gsub(":", "\\:")
        :gsub(",", "\\,")
end

local function resolve_tone_mapping()
    if o.tone_mapping == "no" then return nil end

    local tm = o.tone_mapping

    if tm == "auto" then
        tm = last_tone_mapping or properties["tone-mapping"]

        if tm == "auto" and properties["current-vo"] == "gpu-next" then
            tm = vo_tone_mapping()
        end
    end

    if not tone_mappings[tm] then
        tm = "hable"
    end

    last_tone_mapping = tm
    return tm
end

local function append_filter_params(vf, filter)
    local params = filter.params or {}
    local keys = {}

    for key in pairs(params) do
        keys[#keys + 1] = key
    end

    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    if #keys == 0 then
        return vf .. tostring(filter.name) .. ","
    end

    local args = {}
    for _, key in ipairs(keys) do
        args[#args + 1] = vf_escape(key) .. "=" .. vf_escape(params[key])
    end

    return vf .. tostring(filter.name) .. "=" .. table.concat(args, ":") .. ","
end

local function crop_vf()
    local crop = properties["video-crop"] or ""
    if crop == "" then return "" end

    local cw, ch, cx, cy = tostring(crop):match("^(%d*)x?(%d*)%+(%-?%d+)%+(%-?%d+)$")
    if not cx or not cy then return "" end

    if cw == "" or ch == "" then
        local params = properties["video-out-params"]
        if params then
            if cw == "" and params.dw then cw = tostring(params.dw) end
            if ch == "" and params.dh then ch = tostring(params.dh) end
        end
    end

    if cw == "" or ch == "" then return "" end

    return "lavfi-crop=w=" .. cw .. ":h=" .. ch .. ":x=" .. cx .. ":y=" .. cy .. ","
end

local function vf_string(filters, full)
    local vf = crop_vf()

    local vf_table = properties.vf
    if vf_table and #vf_table > 0 then
        for i = #vf_table, 1, -1 do
            local filter = vf_table[i]
            if filter and filter.name and filters[filter.name] then
                vf = append_filter_params(vf, filter)
            end
        end
    end

    if full and o.tone_mapping ~= "no" then
        local vp = properties["video-params"]
        local is_bt2020 = vp and vp.primaries == "bt.2020"
        local sig_peak = vp and tonumber(vp["sig-peak"])
        local looks_hdr = is_bt2020 or (sig_peak and sig_peak > 1)

        if looks_hdr then
            local tm = resolve_tone_mapping()
            if tm then
                vf = vf ..
                    "zscale=transfer=linear," ..
                    "format=gbrpf32le," ..
                    "tonemap=" .. tm .. "," ..
                    "zscale=transfer=bt709,"
            end
        end
    end

    if full then
        vf = vf ..
            "scale=w=" .. effective_w .. ":h=" .. effective_h .. par .. "," ..
            "pad=w=" .. effective_w .. ":h=" .. effective_h .. ":x=-1:y=-1," ..
            "format=bgra"
    end

    return vf
end

local function calc_dimensions()
    local params = properties["video-out-params"]
    local width = params and params.dw
    local height = params and params.dh

    if not width or not height or width <= 0 or height <= 0 then
        return false
    end

    local hidpi = tonumber(properties["display-hidpi-scale"]) or 1
    if hidpi <= 0 then hidpi = 1 end

    local max_w = o.max_width * hidpi
    local max_h = o.max_height * hidpi

    if width / height > max_w / max_h then
        effective_w = round(max_w)
        effective_h = round(height / width * effective_w)
    else
        effective_h = round(max_h)
        effective_w = round(width / height * effective_h)
    end

    local vpar = params.par or 1
    par = vpar == 1 and ":force_original_aspect_ratio=decrease" or ""

    effective_w = math.max(1, effective_w)
    effective_h = math.max(1, effective_h)

    return true
end

local function selected_video_track()
    return properties["current-tracks/video"]
end

local function video_available()
    local vid = properties.vid

    if vid == false or vid == "no" then
        return false
    end

    return has_vid ~= 0 or selected_video_track() ~= nil or properties["video-out-params"] ~= nil
end

local function compute_disabled(w, h)
    local track = selected_video_track()
    local image = track and track.image == true
    local albumart = track and track.albumart == true

    return
        (w or 0) <= 0 or
        (h or 0) <= 0 or
        not video_available() or
        (properties["demuxer-via-network"] and not o.network) or
        (albumart and not o.audio) or
        (image and not albumart)
end

local function publish_info(w, h, force)
    disabled = compute_disabled(w, h)

    local json = utils.format_json({
        width = round((w or 0) * o.scale_factor),
        height = round((h or 0) * o.scale_factor),
        scale_factor = o.scale_factor,
        disabled = disabled,
        available = true,
        socket = current and current.command_file or o.socket,
        thumbnail = o.thumbnail,
        overlay_id = o.overlay_id,
    })

    if force or json ~= last_info_json then
        last_info_json = json
        command_async({ "script-message", "thumbfast-info", json })
    end
end

local function make_child_script(command_file, token)
    local poll = string.format("%.6f", o.child_poll_interval)

    return
        "local utils = require 'mp.utils'\n" ..
        "local command_file = " .. string.format("%q", command_file) .. "\n" ..
        "local token = " .. string.format("%q", token) .. "\n" ..
        "local last_seq = -1\n" ..
        "local last_raw = nil\n" ..

        "local function read_all(path)\n" ..
        "    local f = io.open(path, 'rb')\n" ..
        "    if not f then return nil end\n" ..
        "    local s = f:read('*a')\n" ..
        "    f:close()\n" ..
        "    return s\n" ..
        "end\n" ..

        "local function apply(cmd)\n" ..
        "    if type(cmd) ~= 'table' then return end\n" ..
        "    if cmd.token ~= token then return end\n" ..
        "    if type(cmd.seq) ~= 'number' or cmd.seq <= last_seq then return end\n" ..
        "    last_seq = cmd.seq\n" ..

        "    if cmd.cmd == 'seek' then\n" ..
        "        local mode = cmd.fast and 'absolute+keyframes' or 'absolute+exact'\n" ..
        "        mp.command_native_async({'seek', tonumber(cmd.time) or 0, mode}, function() end)\n" ..
        "    elseif cmd.cmd == 'set' and cmd.property then\n" ..
        "        pcall(mp.set_property_native, cmd.property, cmd.value)\n" ..
        "    elseif cmd.cmd == 'vf' then\n" ..
        "        mp.command_native_async({'vf', 'set', cmd.value or ''}, function() end)\n" ..
        "    elseif cmd.cmd == 'quit' then\n" ..
        "        mp.commandv('quit')\n" ..
        "    end\n" ..
        "end\n" ..

        "mp.add_periodic_timer(" .. poll .. ", function()\n" ..
        "    local s = read_all(command_file)\n" ..
        "    if not s or s == '' or s == last_raw then return end\n" ..
        "    last_raw = s\n" ..
        "    local ok, cmd = pcall(utils.parse_json, s)\n" ..
        "    if ok then pcall(apply, cmd) end\n" ..
        "end)\n"
end

local function write_child_script(proc)
    local f, err = io.open(proc.script, "wb")
    if not f then
        msg.error("cannot write child script: " .. tostring(err))
        return false
    end

    local ok_write, write_err = f:write(make_child_script(proc.command_file, proc.token))
    local ok_close, close_err = f:close()

    if not ok_write or not ok_close then
        msg.error("cannot write child script: " .. tostring(write_err or close_err))
        os.remove(proc.script)
        return false
    end

    return true
end

local function cleanup_proc(proc)
    if not proc then return end

    os.remove(proc.command_file)
    os.remove(proc.command_file .. ".tmp")
    os.remove(proc.script)
    os.remove(proc.output)
    os.remove(proc.output .. ".tmp")

    children[proc.generation] = nil
end

local function cleanup_all_children()
    local list = {}

    for _, proc in pairs(children) do
        list[#list + 1] = proc
    end

    for _, proc in ipairs(list) do
        cleanup_proc(proc)
    end
end

local function write_command(proc, cmd)
    if not proc then return false end

    proc.seq = (proc.seq or 0) + 1
    cmd.seq = proc.seq
    cmd.token = proc.token

    local json = utils.format_json(cmd)
    if not json then return false end

    return atomic_write(proc.command_file, json)
end

local function terminate_proc(proc, hard)
    if not proc then return end

    proc.quitting = true

    if not proc.quit_sent then
        proc.quit_sent = true
        write_command(proc, { cmd = "quit" })
    end

    if hard and proc.async_handle then
        pcall(mp.abort_async_command, proc.async_handle)
    end
end

local function stop_current(hard)
    if current then
        local proc = current
        current = nil
        terminate_proc(proc, hard)
    end
end

local function stop_all_children(hard)
    for _, proc in pairs(children) do
        terminate_proc(proc, hard)
    end
    current = nil
end

local function bump_activity()
    if o.quit_after_inactivity <= 0 or not current or not activity_timer then
        return
    end

    if activity_timer:is_enabled() then
        activity_timer:kill()
    end

    activity_timer:resume()
end

local function arm_file_poll(seconds)
    seconds = tonumber(seconds) or 2
    file_poll_until = math.max(file_poll_until, mp.get_time() + seconds)

    if file_timer and not file_timer:is_enabled() then
        file_timer:resume()
    end
end

local function spawn(time)
    if disabled or current then return false end

    local path = properties.path
    if not path or path == "" then return false end

    local open_filename = properties["stream-open-filename"]
    if open_filename and properties["demuxer-via-network"] and path ~= open_filename then
        path = open_filename
    end

    generation = generation + 1

    local start_time = sanitize_time(time) or 0
    local full_vf = vf_string(filters_all, true)

    local proc = {
        generation = generation,
        token = pid .. ":" .. tostring(generation),
        command_file = o.socket .. ".cmd." .. tostring(generation),
        script = o.socket .. ".child." .. tostring(generation) .. ".lua",
        output = o.thumbnail .. ".raw." .. tostring(generation),
        seq = 0,
        quitting = false,
        quit_sent = false,
        start_time = start_time,
        full_vf = full_vf,
    }

    if not write_child_script(proc) then
        cleanup_proc(proc)
        return false
    end

    os.remove(proc.output)
    os.remove(proc.output .. ".tmp")

    local vid = properties.vid
    if vid == false or vid == "no" or vid == nil then
        vid = "auto"
    end

    local rotate = tonumber(properties["video-rotate"]) or last_rotate or 0

    local args = {
        mpv_path,

        "--no-config",
        "--no-resume-playback",
        "--really-quiet",
        "--msg-level=all=no",
        "--no-terminal",
        "--force-window=no",

        "--idle=yes",
        "--pause=yes",
        "--keep-open=always",

        "--load-scripts=no",
        "--scripts=" .. proc.script,

        "--osc=no",
        "--osd-level=0",
        "--ytdl=no",
        "--no-sub",
        "--no-audio",
        "--audio-file-auto=no",
        "--sub-auto=no",

        "--edition=" .. tostring(properties.edition or "auto"),
        "--vid=" .. tostring(vid),

        "--start=" .. tostring(start_time),
        allow_fast_seek and "--hr-seek=no" or "--hr-seek=yes",

        "--ytdl-format=worst",
        "--demuxer-readahead-secs=0",
        "--demuxer-max-bytes=512KiB",

        "--vd-lavc-skiploopfilter=all",
        "--vd-lavc-software-fallback=1",
        "--vd-lavc-fast",
        "--vd-lavc-threads=2",
        "--hwdec=" .. (o.hwdec and "auto" or "no"),

        "--vf=" .. full_vf,
        "--sws-scaler=fast-bilinear",
        "--sws-allow-zimg=no",

        "--video-rotate=" .. tostring(rotate),

        "--ovc=rawvideo",
        "--of=image2",
        "--ofopts=update=1",
        "--o=" .. proc.output,
    }

    if mp.get_property_native("media-controls") ~= nil then
        args[#args + 1] = "--media-controls=no"
    end

    if is_macos and properties["macos-app-activation-policy"] then
        args[#args + 1] = "--macos-app-activation-policy=accessory"
    end

    args[#args + 1] = "--"
    args[#args + 1] = path

    current = proc
    children[proc.generation] = proc

    local handle = subprocess_async(args, function(success, result)
        local status = result and result.status

        if current and current.generation == proc.generation then
            current = nil
            publish_info(real_w or effective_w, real_h or effective_h)
        end

        cleanup_proc(proc)

        if success == false or (status and status ~= 0 and status ~= -2) then
            if not proc.quitting then
                msg.error("thumbnail mpv subprocess failed")
                show_error("thumbfast: thumbnail subprocess failed")
            end
        end
    end)

    if not handle then
        if current and current.generation == proc.generation then
            current = nil
        end

        cleanup_proc(proc)
        show_error("thumbfast: cannot create mpv subprocess")
        return false
    end

    proc.async_handle = handle
    last_full_vf = full_vf

    bump_activity()
    publish_info(real_w or effective_w, real_h or effective_h)
    return true
end

local function send_seek(fast)
    if not current or last_seek_time == nil then return end

    local t = sanitize_time(last_seek_time)
    if t == nil then return end

    last_seek_time = t

    write_command(current, {
        cmd = "seek",
        time = t,
        fast = fast and true or false,
    })
end

seek_timer = mp.add_timeout(o.seek_interval, function()
    if pending_seek then
        pending_seek = false
        send_seek(allow_fast_seek)
        seek_timer:resume()
    end
end)
seek_timer:kill()

exact_seek_timer = mp.add_timeout(math.max(0.001, o.exact_seek_delay), function()
    if allow_fast_seek and o.exact_seek_delay >= 0 then
        send_seek(false)
    end
end)
exact_seek_timer:kill()

local function request_seek()
    local spawned = false

    if not current then
        spawned = spawn(last_seek_time or mp.get_property_number("time-pos", 0))
    end

    if not current then return end

    local same_as_spawn =
        spawned and
        current.start_time ~= nil and
        last_seek_time ~= nil and
        math.abs(last_seek_time - current.start_time) < 0.001

    local refinement_delay =
        allow_fast_seek and o.exact_seek_delay >= 0 and o.exact_seek_delay or 0

    arm_file_poll(refinement_delay + 2)

    if same_as_spawn then
        if allow_fast_seek and o.exact_seek_delay >= 0 then
            if exact_seek_timer:is_enabled() then exact_seek_timer:kill() end
            exact_seek_timer:resume()
        end
        return
    end

    if seek_timer:is_enabled() then
        pending_seek = true
    else
        pending_seek = false
        send_seek(allow_fast_seek)
        seek_timer:resume()
    end

    if allow_fast_seek and o.exact_seek_delay >= 0 then
        if exact_seek_timer:is_enabled() then exact_seek_timer:kill() end
        exact_seek_timer:resume()
    end
end

local function real_res(req_w, req_h, filesize)
    if not filesize or filesize <= 0 or filesize % 4 ~= 0 then
        return nil
    end

    local count = filesize / 4

    -- Only account for container/display rotation reported by video-params.
    -- Manual video-rotate is already reflected through video-out-params/filter output.
    local rotate = tonumber(properties["video-params"] and properties["video-params"].rotate) or 0

    if rotate % 180 == 90 then
        req_w, req_h = req_h, req_w
    end

    if req_w * req_h == count then
        return req_w, req_h
    end

    local threshold = 5
    local long_side, short_side = req_w, req_h
    local swapped = false

    if req_h > req_w then
        long_side, short_side = req_h, req_w
        swapped = true
    end

    for a = short_side, math.max(1, short_side - threshold), -1 do
        if count % a == 0 then
            local b = count / a
            if math.abs(long_side - b) <= threshold then
                if swapped then
                    return a, b
                else
                    return b, a
                end
            end
        end
    end

    return nil
end

local function remove_overlay()
    if overlay_visible then
        command_async({ "overlay-remove", o.overlay_id })
        overlay_visible = false
    end
end

local function draw(w, h, script)
    if not w or not h or not show_thumbnail then return end

    if x ~= nil and y ~= nil then
        local cmd = {
            "overlay-add",
            o.overlay_id,
            x,
            y,
            thumbnail_bgra,
            0,
            "bgra",
            w,
            h,
            4 * w,
        }

        if o.scale_factor ~= 1 then
            cmd[#cmd + 1] = round(w * o.scale_factor)
            cmd[#cmd + 1] = round(h * o.scale_factor)
        end

        command_async(cmd)
        overlay_visible = true
        return
    end

    remove_overlay()

    if script and script ~= "" then
        local json = utils.format_json({
            width = w,
            height = h,
            scale_factor = o.scale_factor,
            socket = current and current.command_file or o.socket,
            thumbnail = o.thumbnail,
            overlay_id = o.overlay_id,
        })

        command_async({ "script-message-to", script, "thumbfast-render", json })
    end
end

local function check_new_thumb()
    local proc = current
    if not proc then return false end

    local tmp = proc.output .. ".tmp"

    -- Move first, then inspect the moved file. This gives us a stable snapshot
    -- and avoids racing against the worker while it is replacing proc.output.
    if not move_file(proc.output, tmp) then
        return false
    end

    local finfo = utils.file_info(tmp)
    if not finfo or not finfo.is_file or finfo.size <= 0 or finfo.size % 4 ~= 0 then
        os.remove(tmp)
        return false
    end

    local w, h = real_res(effective_w, effective_h, finfo.size)
    if not w or not h then
        os.remove(tmp)
        return false
    end

    if not move_file(tmp, thumbnail_bgra) then
        os.remove(tmp)
        return false
    end

    real_w, real_h = w, h

    if real_w ~= last_real_w or real_h ~= last_real_h then
        last_real_w, last_real_h = real_w, real_h
        publish_info(real_w, real_h)
    end

    if not show_thumbnail then
        file_timer:kill()
    end

    return true
end

file_timer = mp.add_periodic_timer(o.file_check_interval, function()
    if check_new_thumb() then
        draw(real_w, real_h, script_name)
    end

    if mp.get_time() > file_poll_until
        and not pending_seek
        and not exact_seek_timer:is_enabled()
    then
        file_timer:kill()
    end
end)
file_timer:kill()

local function clear(no_activity)
    local silent = no_activity == true

    file_timer:kill()
    seek_timer:kill()
    exact_seek_timer:kill()

    file_poll_until = 0
    pending_seek = false
    last_seek_time = nil

    show_thumbnail = false
    x, y = nil, nil
    last_x, last_y = nil, nil
    script_name = nil
    last_script_name = nil

    remove_overlay()

    if not silent then
        bump_activity()
    end
end

activity_timer = mp.add_timeout(math.max(0.001, o.quit_after_inactivity), function()
    if show_thumbnail then
        bump_activity()
        return
    end

    stop_current(false)
    real_w, real_h = nil, nil
end)
activity_timer:kill()

local function thumb(time, r_x, r_y, script)
    if disabled then return end

    time = sanitize_time(time)
    if not time then return end

    local nx = tonumber(r_x)
    local ny = tonumber(r_y)

    if nx and ny then
        x = round(nx)
        y = round(ny)
    else
        x, y = nil, nil
    end

    script_name = script and script ~= "" and script or nil

    if last_x ~= x
        or last_y ~= y
        or last_script_name ~= script_name
        or not show_thumbnail
    then
        show_thumbnail = true
        last_x, last_y = x, y
        last_script_name = script_name
        draw(real_w, real_h, script_name)
    end

    if last_seek_time ~= nil and math.abs(time - last_seek_time) < 0.001 then
        bump_activity()
        return
    end

    last_seek_time = time
    request_seek()

    bump_activity()
end

local function update_property(name, value)
    properties[name] = value
end

local function update_property_dirty(name, value)
    properties[name] = value

    if name == "tone-mapping" or name == "current-vo" then
        last_tone_mapping = nil
    end

    mark_dirty()
end

local function update_current_video(name, value)
    properties[name] = value

    if properties.vid == false or properties.vid == "no" then
        has_vid = 0
    else
        has_vid = value and 1 or 0
    end

    mark_dirty()
end

local function update_tracklist(_, value)
    properties["current-tracks/video"] = nil
    has_vid = 0

    if type(value) == "table" then
        for _, track in ipairs(value) do
            if track.type == "video" and track.selected then
                properties["current-tracks/video"] = track
                has_vid = 1
                break
            end
        end
    end

    if properties.vid == false or properties.vid == "no" then
        has_vid = 0
    end

    mark_dirty()
end

local function sync_property_to_child(prop, val)
    properties[prop] = val

    if prop == "vid" then
        if val == false or val == "no" then
            has_vid = 0
            publish_info(effective_w, effective_h, true)
            clear(true)
            stop_current(true)
            mark_dirty()
            return
        else
            has_vid = 1
        end
    end

    if current then
        write_command(current, {
            cmd = "set",
            property = prop,
            value = val,
        })
    end

    mark_dirty()
end

local function remember_state(vf_reset, full_vf, rotate, crop)
    last_vf_reset = vf_reset
    last_full_vf = full_vf
    last_rotate = rotate
    last_par = par
    last_crop = crop
end

local function disable_and_stop_if_needed()
    if disabled then
        clear(true)
        stop_current(true)
        real_w, real_h = nil, nil
        last_real_w, last_real_h = nil, nil
    end
end

local function watch_changes()
    if not dirty then return end
    dirty = false

    if not properties["video-out-params"] then
        publish_info(0, 0)
        disable_and_stop_if_needed()
        return
    end

    local old_w = effective_w
    local old_h = effective_h
    local old_disabled = disabled

    if not calc_dimensions() then
        publish_info(0, 0)
        disable_and_stop_if_needed()
        return
    end

    local vf_reset = vf_string(filters_reset, false)
    local full_vf = vf_string(filters_all, true)
    local rotate = tonumber(properties["video-rotate"]) or 0
    local crop = properties["video-crop"] or ""

    local resized =
        old_w ~= effective_w or
        old_h ~= effective_h or
        last_vf_reset ~= vf_reset or
        last_rotate % 180 ~= rotate % 180 or
        par ~= last_par or
        last_crop ~= crop

    publish_info(effective_w, effective_h)

    if disabled then
        clear(true)
        stop_current(true)
        remember_state(vf_reset, full_vf, rotate, crop)
        return
    end

    if resized then
        real_w, real_h = nil, nil
        last_real_w, last_real_h = nil, nil
    end

    if current then
        if resized then
            local old_seek_time = last_seek_time
            local seek_time = old_seek_time or sanitize_time(mp.get_property_number("time-pos", 0)) or 0

            local was_showing = show_thumbnail
            local old_x, old_y = x, y
            local old_script_name = script_name

            stop_current(true)
            clear(true)

            show_thumbnail = was_showing
            last_seek_time = old_seek_time

            if was_showing then
                x, y = old_x, old_y
                script_name = old_script_name
                last_x, last_y = old_x, old_y
                last_script_name = old_script_name
            end

            if spawn(seek_time) and (was_showing or o.spawn_first) then
                arm_file_poll(2)

                if old_seek_time and allow_fast_seek and o.exact_seek_delay >= 0 then
                    if exact_seek_timer:is_enabled() then exact_seek_timer:kill() end
                    exact_seek_timer:resume()
                end
            end
        else
            local changed = false

            if rotate ~= last_rotate then
                write_command(current, {
                    cmd = "set",
                    property = "video-rotate",
                    value = rotate,
                })
                changed = true
            end

            if full_vf ~= last_full_vf then
                write_command(current, {
                    cmd = "vf",
                    value = full_vf,
                })
                changed = true
            end

            if changed then
                last_seek_time = last_seek_time or sanitize_time(mp.get_property_number("time-pos", 0)) or 0
                send_seek(false)
                arm_file_poll(1)
            end
        end
    end

    remember_state(vf_reset, full_vf, rotate, crop)

    if not current and not disabled and o.spawn_first and (resized or old_disabled) then
        spawn(sanitize_time(mp.get_property_number("time-pos", 0)) or 0)
        arm_file_poll(2)
    end
end

dirty_timer = mp.add_timeout(0.001, watch_changes)
dirty_timer:kill()

local function remove_thumbnail_files()
    os.remove(o.thumbnail)
    os.remove(thumbnail_bgra)
    os.remove(o.thumbnail .. ".tmp")
end

local function refresh_cached_file_properties()
    properties.path = mp.get_property_native("path")
    properties["stream-open-filename"] = mp.get_property_native("stream-open-filename")
    properties["demuxer-via-network"] = mp.get_property_native("demuxer-via-network")

    properties["display-hidpi-scale"] = mp.get_property_native("display-hidpi-scale")
    properties["video-out-params"] = mp.get_property_native("video-out-params")
    properties["video-params"] = mp.get_property_native("video-params")
    properties.vf = mp.get_property_native("vf")
    properties["tone-mapping"] = mp.get_property_native("tone-mapping")
    properties["current-vo"] = mp.get_property_native("current-vo")
    properties["video-rotate"] = mp.get_property_native("video-rotate")
    properties["video-crop"] = mp.get_property_native("video-crop")

    properties["macos-app-activation-policy"] = mp.get_property_native("macos-app-activation-policy")
    properties.vid = mp.get_property_native("vid")
    properties.edition = mp.get_property_native("edition")

    allow_fast_seek = (mp.get_property_number("duration", 30) or 30) >= 30

    properties["current-tracks/video"] = nil
    has_vid = 0

    local tracks = mp.get_property_native("track-list")
    if type(tracks) == "table" then
        for _, track in ipairs(tracks) do
            if track.type == "video" and track.selected then
                properties["current-tracks/video"] = track
                has_vid = 1
                break
            end
        end
    end

    local current_video = mp.get_property_native("current-tracks/video")
    if current_video ~= nil then
        properties["current-tracks/video"] = current_video
        has_vid = 1
    end

    if properties.vid == false or properties.vid == "no" then
        has_vid = 0
    end
end

local function file_loaded()
    stop_all_children(true)
    clear(true)

    disabled = true

    real_w, real_h = nil, nil
    last_real_w, last_real_h = nil, nil
    last_tone_mapping = nil
    last_seek_time = nil

    last_vf_reset = ""
    last_full_vf = ""
    last_par = ""
    last_crop = nil
    last_rotate = 0

    remove_thumbnail_files()
    refresh_cached_file_properties()

    if calc_dimensions() then
        publish_info(effective_w, effective_h, true)
    else
        publish_info(0, 0, true)
    end

    mark_dirty()
end

local function shutdown()
    remove_overlay()
    stop_all_children(true)
    cleanup_all_children()

    remove_thumbnail_files()

    os.remove(o.socket)
    os.remove(o.socket .. ".tmp")
end

local function on_duration(_, val)
    allow_fast_seek = (tonumber(val) or 30) >= 30
end

mp.observe_property("current-tracks/video", "native", update_current_video)
mp.observe_property("track-list", "native", update_tracklist)

mp.observe_property("display-hidpi-scale", "native", update_property_dirty)
mp.observe_property("video-out-params", "native", update_property_dirty)
mp.observe_property("video-params", "native", update_property_dirty)
mp.observe_property("vf", "native", update_property_dirty)
mp.observe_property("tone-mapping", "native", update_property_dirty)

mp.observe_property("demuxer-via-network", "native", update_property_dirty)
mp.observe_property("stream-open-filename", "native", update_property)
mp.observe_property("macos-app-activation-policy", "native", update_property)
mp.observe_property("current-vo", "native", update_property_dirty)
mp.observe_property("video-rotate", "native", update_property_dirty)
mp.observe_property("video-crop", "native", update_property_dirty)
mp.observe_property("path", "native", update_property)

mp.observe_property("vid", "native", sync_property_to_child)
mp.observe_property("edition", "native", sync_property_to_child)
mp.observe_property("duration", "native", on_duration)

mp.register_script_message("thumb", thumb)
mp.register_script_message("clear", clear)

mp.register_event("file-loaded", file_loaded)
mp.register_event("shutdown", shutdown)
