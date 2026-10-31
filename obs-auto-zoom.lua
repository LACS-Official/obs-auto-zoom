-- OBS Auto Zoom
-- Copyright (c) 领创工作室.  All rights reserved.

--
-- OBS Zoom to Mouse
-- An OBS lua script to zoom a display-capture source to focus on the mouse.
-- Copyright (c) BlankSourceCode.  All rights reserved.
--


local obs = obslua
local ffi = require("ffi")
local bit = require("bit")
local VERSION = "1.0.2"
local CROP_FILTER_NAME = "obs-zoom-to-mouse-crop"

local socket_available, socket = pcall(require, "ljsocket")
local socket_server = nil
local socket_mouse = nil

local source_name = ""
local source = nil
local sceneitem = nil
local sceneitem_info_orig = nil
local sceneitem_crop_orig = nil
local sceneitem_info = nil
local sceneitem_crop = nil
local crop_filter = nil
local crop_filter_temp = nil
local crop_filter_settings = nil
local crop_filter_info_orig = { x = 0, y = 0, w = 0, h = 0 }
local crop_filter_info = { x = 0, y = 0, w = 0, h = 0 }
local monitor_info = nil
local zoom_info = {
    source_size = { width = 0, height = 0 },
    source_crop = { x = 0, y = 0, w = 0, h = 0 },
    source_crop_filter = { x = 0, y = 0, w = 0, h = 0 },
    zoom_to = 2
}
local zoom_time = 0
local zoom_target = nil
local locked_center = nil
local locked_last_pos = nil
local hotkey_zoom_id = nil
local hotkey_follow_id = nil
local is_timer_running = false
local zoom_start_crop = { x = 0, y = 0, w = 0, h = 0 }

-- Physics and custom controls
local spring_strength = 0.0
local damping_ratio = 0.6
local cam_vel_x = 0.0
local cam_vel_y = 0.0
local last_timer_time = 0.0
local is_zoom_locked = false
local locked_crop_pos = { x = 0, y = 0 }
local zoom_step = 0.5
local hotkey_lock_id = nil
local hotkey_zoom_in_id = nil
local hotkey_zoom_out_id = nil
local script_settings = nil

-- Auto reset zoom on idle variables
local use_auto_reset_zoom = false
local auto_reset_zoom_delay = 3.0
local idle_time = 0.0
local last_mouse_pos = { x = 0, y = 0 }
local target_zoom_factor = 1.0
local zoom_curve = "ease_in_out"

local win_point = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil

local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local is_following_mouse = false
local follow_speed = 0.1
local follow_border = 0
local follow_safezone_sensitivity = 10
local use_follow_auto_lock = false
local zoom_value = 2
local zoom_speed = 0.1
local allow_all_sources = false
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 0
local monitor_override_h = 0
local monitor_override_sx = 0
local monitor_override_sy = 0
local monitor_override_dw = 0
local monitor_override_dh = 0
local use_socket = false
local socket_port = 0
local socket_poll = 1000
local debug_logs = false
local is_obs_loaded = false
local is_script_loaded = false

-- Version Check Variables
local latest_version = nil
local latest_release_url = "https://github.com/LACS-Official/obs-auto-zoom/releases"
local has_update_available = false
local is_checking_update = false

-- Keystroke Visualizer variables
local enable_keystroke = false
local keystroke_pos = "follow_mouse"
local keystroke_offset_x = 30
local keystroke_offset_y = 30
local keystroke_duration = 1.5
local keystroke_font_size = 32
local keystroke_include_mouse = true
local keystroke_modifier_only = true
local keystroke_source = nil
local keystroke_sceneitem = nil
local keystroke_fade_timer = 0.0
local keystroke_last_time = 0.0
local keystroke_prev_keys = {}
local keystroke_prev_modifiers = {}
local is_keystroke_timer_running = false

-- Config Backup & WebDAV variables
local webdav_url = "https://dav.jianguoyun.com/dav/"
local webdav_user = ""
local webdav_pass = ""
local webdav_folder = "obsautozoom"
local webdav_file = "obs-auto-zoom-config.json"
local backup_status_msg = "暂无备份/恢复记录"

-- Forward declarations for Keystroke & WebDAV
local ensure_keystroke_item = nil
local apply_keystroke_styling = nil
local set_keystroke_text = nil
local show_keystroke_sceneitem = nil
local hide_keystroke_sceneitem = nil
local update_keystroke_position = nil
local on_keystroke_timer = nil

local export_local_config = nil
local import_local_config = nil
local webdav_backup_config = nil
local webdav_restore_config = nil
local webdav_test_connection = nil

function open_url(url)
    if not url or url == "" then return end
    if ffi.os == "Windows" then
        pcall(function()
            local shell32 = ffi.load("shell32")
            if shell32 then
                ffi.cdef([[
                    void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int nShowCmd);
                ]])
                shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
            else
                os.execute('start "" "' .. url .. '"')
            end
        end)
    elseif ffi.os == "OSX" then
        os.execute('open "' .. url .. '"')
    else
        os.execute('xdg-open "' .. url .. '"')
    end
end

function parse_version_nums(v_str)
    if not v_str then return {0, 0, 0} end
    local clean = v_str:match("v?(%d+%.?%d*%.?%d*)") or v_str
    local parts = {}
    for num in clean:gmatch("(%d+)") do
        table.insert(parts, tonumber(num) or 0)
    end
    while #parts < 3 do
        table.insert(parts, 0)
    end
    return parts
end

function is_version_newer(latest, current)
    local p1 = parse_version_nums(latest)
    local p2 = parse_version_nums(current)
    for i = 1, math.max(#p1, #p2) do
        local n1 = p1[i] or 0
        local n2 = p2[i] or 0
        if n1 > n2 then return true end
        if n1 < n2 then return false end
    end
    return false
end

function http_get(url)
    if ffi.os == "Windows" then
        local success, res = pcall(function()
            local wininet = ffi.load("wininet")
            if not wininet then return nil end

            ffi.cdef([[
                typedef void* HINTERNET;
                HINTERNET InternetOpenA(const char* lpszAgent, uint32_t dwAccessType, const char* lpszProxy, const char* lpszProxyBypass, uint32_t dwFlags);
                HINTERNET InternetOpenUrlA(HINTERNET hInternet, const char* lpszUrl, const char* lpszHeaders, uint32_t dwHeadersLength, uint32_t dwFlags, uintptr_t dwContext);
                int InternetReadFile(HINTERNET hFile, void* lpBuffer, uint32_t dwNumberOfBytesToRead, uint32_t* lpdwNumberOfBytesRead);
                int InternetCloseHandle(HINTERNET hInternet);
            ]])

            local hInternet = wininet.InternetOpenA("obs-auto-zoom-script", 0, nil, nil, 0)
            if hInternet == nil or hInternet == ffi.cast("void*", 0) then return nil end

            local flags = 0x80000000 + 0x00800000 + 0x04000000 -- RELOAD + SECURE + NO_CACHE_WRITE
            local headers = "User-Agent: obs-auto-zoom-script\r\nAccept: application/vnd.github.v3+json\r\n"
            local hUrl = wininet.InternetOpenUrlA(hInternet, url, headers, -1, flags, 0)

            local content = nil
            if hUrl ~= nil and hUrl ~= ffi.cast("void*", 0) then
                local buffer_size = 4096
                local buffer = ffi.new("char[?]", buffer_size)
                local read_bytes = ffi.new("uint32_t[1]")
                local chunks = {}

                repeat
                    local ok = wininet.InternetReadFile(hUrl, buffer, buffer_size - 1, read_bytes)
                    if ok ~= 0 and read_bytes[0] > 0 then
                        table.insert(chunks, ffi.string(buffer, read_bytes[0]))
                    else
                        break
                    end
                until read_bytes[0] == 0

                wininet.InternetCloseHandle(hUrl)
                content = table.concat(chunks)
            end
            wininet.InternetCloseHandle(hInternet)
            return content
        end)
        if success and res and #res > 0 then
            return res
        end
    end

    local cmd
    if ffi.os == "Windows" then
        cmd = 'curl -s -L -A "obs-auto-zoom-script" "' .. url .. '"'
    else
        cmd = 'curl -s -L -A "obs-auto-zoom-script" "' .. url .. '"'
    end

    local handle = io.popen(cmd)
    if handle then
        local content = handle:read("*a")
        handle:close()
        if content and #content > 0 then
            return content
        end
    end

    return nil
end

function check_for_updates(is_manual)
    if is_checking_update then return false end
    is_checking_update = true

    local tag = nil
    local html_url = nil

    -- Method 1: Raw GitHub File CDN (Bypasses GitHub REST API rate limits completely)
    local raw_url = "https://raw.githubusercontent.com/LACS-Official/obs-auto-zoom/main/obs-auto-zoom.lua"
    local raw_resp = http_get(raw_url)
    if raw_resp and #raw_resp > 0 then
        local remote_ver = raw_resp:match('local%s+VERSION%s*=%s*"([^"]+)"')
        if remote_ver then
            tag = remote_ver
            html_url = "https://github.com/LACS-Official/obs-auto-zoom/releases/tag/" .. remote_ver
        end
    end

    -- Method 2: GitHub Releases latest page
    if not tag then
        local rel_url = "https://github.com/LACS-Official/obs-auto-zoom/releases/latest"
        local rel_resp = http_get(rel_url)
        if rel_resp and #rel_resp > 0 then
            local rel_tag = rel_resp:match('/releases/tag/([^"/?#]+)')
            if rel_tag then
                tag = rel_tag
                html_url = "https://github.com/LACS-Official/obs-auto-zoom/releases/tag/" .. rel_tag
            end
        end
    end

    -- Method 3: GitHub REST API
    if not tag then
        local api_url = "https://api.github.com/repos/LACS-Official/obs-auto-zoom/releases/latest"
        local api_resp = http_get(api_url)
        if api_resp and #api_resp > 0 then
            tag = api_resp:match('"tag_name"%s*:%s*"([^"]+)"')
            local matched_url = api_resp:match('"html_url"%s*:%s*"([^"]+)"')
            if matched_url then
                html_url = matched_url:gsub("\\/", "/")
            end
        end
    end

    is_checking_update = false

    if tag then
        latest_version = tag:gsub("^v", "")
        if html_url then
            latest_release_url = html_url
        else
            latest_release_url = "https://github.com/LACS-Official/obs-auto-zoom/releases/tag/" .. tag
        end

        if is_version_newer(latest_version, VERSION) then
            has_update_available = true
            obs.script_log(obs.OBS_LOG_WARNING,
                "\n----------------------------------------------------\n" ..
                "🚀 [obs-auto-zoom] 检测到 GitHub 新版本发布！\n" ..
                "当前版本: v" .. VERSION .. "\n" ..
                "最新版本: v" .. latest_version .. "\n" ..
                "更新下载地址: " .. latest_release_url .. "\n" ..
                "----------------------------------------------------\n")
        else
            has_update_available = false
            if is_manual then
                obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] 当前已是最新版本 (v" .. VERSION .. ")")
            end
        end
        return true
    end

    if is_manual then
        obs.script_log(obs.OBS_LOG_WARNING, "[obs-auto-zoom] 无法连接到 GitHub 检查更新，请稍后再试。")
    end
    return false
end

function on_initial_update_check_timer()
    obs.timer_remove(on_initial_update_check_timer)
    check_for_updates(false)
end

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

local version = obs.obs_get_version_string()
local m1, m2 = version:match("(%d+%.%d+)%.(%d+)")
local major = tonumber(m1) or 0
local minor = tonumber(m2) or 0

-- Define the mouse cursor functions for each platform
local win_user32 = nil
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
        short GetAsyncKeyState(int vKey);
    ]])
    win_point = ffi.new("POINT[1]")
    pcall(function() win_user32 = ffi.load("user32") end)
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
    ]])

    x11_lib = ffi.load("X11.so.6")
    x11_display = x11_lib.XOpenDisplay(nil)
    if x11_display ~= nil then
        x11_root = x11_lib.XDefaultRootWindow(x11_display)
        x11_mouse = {
            root_win = ffi.new("Window[1]"),
            child_win = ffi.new("Window[1]"),
            root_x = ffi.new("int[1]"),
            root_y = ffi.new("int[1]"),
            win_x = ffi.new("int[1]"),
            win_y = ffi.new("int[1]"),
            mask = ffi.new("unsigned int[1]")
        }
    end
elseif ffi.os == "OSX" then
    ffi.cdef([[
        typedef struct {
            double x;
            double y;
        } CGPoint;
        typedef void* SEL;
        typedef void* id;
        typedef void* Method;

        SEL sel_registerName(const char *str);
        id objc_getClass(const char*);
        Method class_getClassMethod(id cls, SEL name);
        void* method_getImplementation(Method);
        int access(const char *path, int amode);
    ]])

    osx_lib = ffi.load("libobjc")
    if osx_lib ~= nil then
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
        end
    end
end

---
-- Get the current mouse position
---@return table Mouse position
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if socket_mouse ~= nil then
        mouse.x = socket_mouse.x
        mouse.y = socket_mouse.y
    else
        if ffi.os == "Windows" then
            if win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
                mouse.x = win_point[0].x
                mouse.y = win_point[0].y
            end
        elseif ffi.os == "Linux" then
            if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
                if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                    mouse.x = tonumber(x11_mouse.win_x[0])
                    mouse.y = tonumber(x11_mouse.win_y[0])
                end
            end
        elseif ffi.os == "OSX" then
            if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
                local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
                mouse.x = point.x
                if monitor_info ~= nil then
                    if monitor_info.display_height > 0 then
                        mouse.y = monitor_info.display_height - point.y
                    else
                        mouse.y = monitor_info.height - point.y
                    end
                end
            end
        end
    end

    return mouse
end

---
-- Get the information about display capture sources for the current platform
---@return any
function get_dc_info()
    if ffi.os == "Windows" then
        return {
            source_id = "monitor_capture",
            prop_id = "monitor_id",
            prop_type = "string"
        }
    elseif ffi.os == "Linux" then
        return {
            source_id = "xshm_input",
            prop_id = "screen",
            prop_type = "int"
        }
    elseif ffi.os == "OSX" then
        if major > 29.0 then
            return {
                source_id = "screen_capture",
                prop_id = "display_uuid",
                prop_type = "string"
            }
        else
            return {
                source_id = "display_capture",
                prop_id = "display",
                prop_type = "int"
            }
        end
    end

    return nil
end

---
-- Logs a message to the OBS script console
---@param msg string The message to log
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

---
-- Format the given lua table into a string
---@param tbl any
---@param indent any
---@return string result The formatted string
function format_table(tbl, indent)
    if not indent then
        indent = 0
    end

    local str = "{\n"
    for key, value in pairs(tbl) do
        local tabs = string.rep("  ", indent + 1)
        if type(value) == "table" then
            str = str .. tabs .. key .. " = " .. format_table(value, indent + 1) .. ",\n"
        else
            str = str .. tabs .. key .. " = " .. tostring(value) .. ",\n"
        end
    end
    str = str .. string.rep("  ", indent) .. "}"

    return str
end

---
-- Linear interpolate between v0 and v1
---@param v0 number The start position
---@param v1 number The end position
---@param t number Time
---@return number value The interpolated value
function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t;
end

---
-- Get the ease progress value based on curve type and current time t
---@param curve_type string The name of easing curve
---@param t number Time between 0 and 1
---@return number value Ease progress
function get_ease_value(curve_type, t)
    if curve_type == "linear" then
        return t
    elseif curve_type == "ease_in" then
        return t * t * t
    elseif curve_type == "ease_out" then
        return 1 - (1 - t) * (1 - t) * (1 - t)
    elseif curve_type == "overshoot" then
        local s = 1.70158
        local t_norm = t - 1
        return t_norm * t_norm * ((s + 1) * t_norm + s) + 1
    else -- "ease_in_out"
        t = t * 2
        if t < 1 then
            return 0.5 * t * t * t
        else
            t = t - 2
            return 0.5 * (t * t * t + 2)
        end
    end
end

---
-- Clamps a given value between min and max
---@param min number The min value
---@param max number The max value
---@param value number The number to clamp
---@return number result the clamped number
function clamp(min, max, value)
    return math.max(min, math.min(max, value))
end

---
-- Get the size and position of the monitor so that we know the top-left mouse point
---@param source any The OBS source
---@return table|nil monitor_info The monitor size/top-left point
function get_monitor_info(source)
    local info = nil

    -- Only do the expensive look up if we are using automatic calculations on a display source
    if is_display_capture(source) and not use_monitor_override then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            local props = obs.obs_source_properties(source)
            if props ~= nil then
                local monitor_id_prop = obs.obs_properties_get(props, dc_info.prop_id)
                if monitor_id_prop then
                    local found = nil
                    local settings = obs.obs_source_get_settings(source)
                    if settings ~= nil then
                        local to_match
                        if dc_info.prop_type == "string" then
                            to_match = obs.obs_data_get_string(settings, dc_info.prop_id)
                        elseif dc_info.prop_type == "int" then
                            to_match = obs.obs_data_get_int(settings, dc_info.prop_id)
                        end

                        local item_count = obs.obs_property_list_item_count(monitor_id_prop);
                        for i = 0, item_count - 1 do
                            local name = obs.obs_property_list_item_name(monitor_id_prop, i)
                            local value
                            if dc_info.prop_type == "string" then
                                value = obs.obs_property_list_item_string(monitor_id_prop, i)
                            elseif dc_info.prop_type == "int" then
                                value = obs.obs_property_list_item_int(monitor_id_prop, i)
                            end

                            if value == to_match then
                                found = name
                                break
                            end
                        end
                        obs.obs_data_release(settings)
                    end

                    if found then
                        log("Parsing display name: " .. found)
                        local x, y = found:match("(-?%d+),%s*(-?%d+)")
                        local width, height = found:match("(%d+)%s*x%s*(%d+)")

                        local nx = tonumber(x, 10)
                        local ny = tonumber(y, 10)
                        local nw = tonumber(width, 10)
                        local nh = tonumber(height, 10)

                        if nx and ny and nw and nh and nw > 0 and nh > 0 then
                            info = {
                                x = nx,
                                y = ny,
                                width = nw,
                                height = nh,
                                scale_x = 1,
                                scale_y = 1,
                                display_width = nw,
                                display_height = nh
                            }
                            log("Parsed the following display information\n" .. format_table(info))
                        else
                            log("警告：无法从显示名称解析分辩率和位置: " .. found)
                        end
                    end
                end

                obs.obs_properties_destroy(props)
            end
        end
    end

    if use_monitor_override then
        info = {
            x = monitor_override_x,
            y = monitor_override_y,
            width = monitor_override_w,
            height = monitor_override_h,
            scale_x = monitor_override_sx,
            scale_y = monitor_override_sy,
            display_width = monitor_override_dw,
            display_height = monitor_override_dh
        }
    end

    if not info then
        log("警告：无法自动计算缩放源的位置和大小。\n" ..
            "         请尝试启用“设置手动源位置”选项并填写覆盖值")
    end

    return info
end

---
-- Check to see if the specified source is a display capture source
-- If the source_to_check is nil then the answer will be false
---@param source_to_check any The source to check
---@return boolean result True if source is a display capture, false if it nil or some other source type
function is_display_capture(source_to_check)
    if source_to_check ~= nil then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            -- Do a quick check to ensure this is a display capture
            if allow_all_sources then
                return true
            else
                local source_type = obs.obs_source_get_id(source_to_check)
                if source_type == dc_info.source_id then
                    return true
                end
            end
        end
    end

    return false
end

---
-- Releases the current sceneitem and resets data back to default
function release_sceneitem()
    if is_timer_running then
        obs.timer_remove(on_timer)
        is_timer_running = false
    end

    zoom_state = ZoomState.None

    if sceneitem ~= nil then
        if crop_filter ~= nil and source ~= nil then
            log("Zoom crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end

        if crop_filter_temp ~= nil and source ~= nil then
            log("Conversion crop filter removed")
            obs.obs_source_filter_remove(source, crop_filter_temp)
            obs.obs_source_release(crop_filter_temp)
            crop_filter_temp = nil
        end

        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        if sceneitem_info_orig ~= nil then
            log("Transform info reset back to original")
            obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info_orig)
            sceneitem_info_orig = nil
        end

        if sceneitem_crop_orig ~= nil then
            log("Transform crop reset back to original")
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop_orig)
            sceneitem_crop_orig = nil
        end

        obs.obs_sceneitem_release(sceneitem)
        sceneitem = nil
    end

    if source ~= nil then
        obs.obs_source_release(source)
        source = nil
    end
end

---
-- Updates the current sceneitem with a refreshed set of data from the source
-- Optionally will release the existing sceneitem and get a new one from the current scene
---@param find_newest boolean True to release the current sceneitem and get a new one
function refresh_sceneitem(find_newest)
    -- TODO: Figure out why we need to get the size from the named source during update instead of via the sceneitem source
    local source_raw = { width = 0, height = 0 }

    if find_newest then
        -- Release the current sceneitem now that we are replacing it
        release_sceneitem()

        -- Quit early if we are using no zoom source
        -- This allows users to reset the crop data back to the original,
        -- update it, and then force the conversion to happen by re-selecting it.
        if source_name == "obs-zoom-to-mouse-none" then
            return
        end

        -- Get a matching source we can use for zooming in the current scene
        log("Finding sceneitem for Zoom Source '" .. source_name .. "'")
        if source_name ~= nil then
            source = obs.obs_get_source_by_name(source_name)
            if source ~= nil then
                -- Get the source size, for some reason this works during load but the sceneitem source doesn't
                source_raw.width = obs.obs_source_get_width(source)
                source_raw.height = obs.obs_source_get_height(source)

                -- Get the current scene
                local scene_source = obs.obs_frontend_get_current_scene()
                if scene_source ~= nil then
                    local function find_scene_item_by_name(root_scene)
                        local queue = {}
                        table.insert(queue, root_scene)

                        while #queue > 0 do
                            local s = table.remove(queue, 1)
                            log("Looking in scene '" .. obs.obs_source_get_name(obs.obs_scene_get_source(s)) .. "'")

                            -- Check if the current scene has the target scene item
                            local found = obs.obs_scene_find_source(s, source_name)
                            if found ~= nil then
                                log("Found sceneitem '" .. source_name .. "'")
                                obs.obs_sceneitem_addref(found)
                                return found
                            end

                            -- If the current scene has nested scenes, enqueue them for later examination
                            local all_items = obs.obs_scene_enum_items(s)
                            if all_items then
                                for _, item in pairs(all_items) do
                                    local nested = obs.obs_sceneitem_get_source(item)
                                    if nested ~= nil then
                                        if obs.obs_source_is_scene(nested) then
                                            local nested_scene = obs.obs_scene_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        elseif obs.obs_source_is_group(nested) then
                                            local nested_scene = obs.obs_group_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        end
                                    end
                                end
                                obs.sceneitem_list_release(all_items)
                            end
                        end

                        return nil
                    end

                    -- Find the sceneitem for the source_name by looking through all the items
                    -- We start at the current scene and use a BFS to look into any nested scenes
                    local current = obs.obs_scene_from_source(scene_source)
                    sceneitem = find_scene_item_by_name(current)

                    obs.obs_source_release(scene_source)
                end

                if not sceneitem then
                    log("警告：源不属于当前场景层级。\n" ..
                        "         请尝试选择其他缩放源或切换场景。")
                    obs.obs_sceneitem_release(sceneitem)
                    obs.obs_source_release(source)

                    sceneitem = nil
                    source = nil
                    return
                end
            end
        end
    end

    if not monitor_info then
        monitor_info = get_monitor_info(source)
    end

    local is_non_display_capture = not is_display_capture(source)
    if is_non_display_capture then
        if not use_monitor_override then
            log("错误：选定的缩放源不是显示器采集源。\n" ..
                "       您必须启用“设置手动源位置”并填写正确的大小和位置覆盖值。")
        end
    end

    if sceneitem ~= nil then
        -- Capture the original settings so we can restore them later
        sceneitem_info_orig = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info_orig)

        sceneitem_crop_orig = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

        sceneitem_info = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info)

        sceneitem_crop = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

        if is_non_display_capture then
            -- Non-Display Capture sources don't correctly report crop values
            sceneitem_crop_orig.left = 0
            sceneitem_crop_orig.top = 0
            sceneitem_crop_orig.right = 0
            sceneitem_crop_orig.bottom = 0
        end

        -- Get the current source size (this will be the value after any applied crop filters)
        if not source then
            log("ERROR: Could not get source for sceneitem (" .. source_name .. ")")
        end

        -- TODO: Figure out why we need this fallback code
        local source_width = obs.obs_source_get_base_width(source)
        local source_height = obs.obs_source_get_base_height(source)

        if source_width == 0 then
            source_width = source_raw.width
        end
        if source_height == 0 then
            source_height = source_raw.height
        end

        if source_width == 0 or source_height == 0 then
            if monitor_info ~= nil and monitor_info.width > 0 and monitor_info.height > 0 then
                log("警告：确定源大小时出现问题。\n" ..
                    "         使用信息中的源大小：" .. monitor_info.width .. ", " .. monitor_info.height)
                source_width = monitor_info.width
                source_height = monitor_info.height
            else
                log("错误：确定源大小时出现问题。\n" ..
                "       请尝试启用“设置手动源位置”选项并填写覆盖值")
            end
        else
            log("Using source size: " .. source_width .. ", " .. source_height)
        end

        -- Convert the current transform into one we can correctly modify for zooming
        -- Ideally the user just has a valid one set and we don't have to change anything because this might not work 100% of the time
        if sceneitem_info.bounds_type == obs.OBS_BOUNDS_NONE then
            sceneitem_info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
            sceneitem_info.bounds_alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT) (0 == OBS_ALIGN_CENTER)
            sceneitem_info.bounds.x = source_width * sceneitem_info.scale.x
            sceneitem_info.bounds.y = source_height * sceneitem_info.scale.y

            obs.obs_sceneitem_set_info2(sceneitem, sceneitem_info)

            log("警告：检测到已存在的非边界框(boundingbox)变换。这可能会导致缩放问题。\n" ..
                "         设置已自动转换为边界框缩放变换。\n" ..
                "         如果您的布局出现问题，请考虑手动将变换修改为边界框。")
        end

        -- Get information about any existing crop filters (that aren't ours)
        zoom_info.source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }
        local found_crop_filter = false
        local filters = obs.obs_source_enum_filters(source)
        if filters ~= nil then
            for k, v in pairs(filters) do
                local id = obs.obs_source_get_id(v)
                if id == "crop_filter" then
                    local name = obs.obs_source_get_name(v)
                    if name ~= CROP_FILTER_NAME and name ~= "temp_" .. CROP_FILTER_NAME then
                        found_crop_filter = true
                        local settings = obs.obs_source_get_settings(v)
                        if settings ~= nil then
                            if not obs.obs_data_get_bool(settings, "relative") then
                                zoom_info.source_crop_filter.x =
                                    zoom_info.source_crop_filter.x + obs.obs_data_get_int(settings, "left")
                                zoom_info.source_crop_filter.y =
                                    zoom_info.source_crop_filter.y + obs.obs_data_get_int(settings, "top")
                                zoom_info.source_crop_filter.w =
                                    zoom_info.source_crop_filter.w + obs.obs_data_get_int(settings, "cx")
                                zoom_info.source_crop_filter.h =
                                    zoom_info.source_crop_filter.h + obs.obs_data_get_int(settings, "cy")
                                log("Found existing non-relative crop/pad filter (" ..
                                    name ..
                                    "). Applying settings " .. format_table(zoom_info.source_crop_filter))
                            else
                                log("警告：检测到已存在的相对裁剪/填充滤镜 (" .. name .. ")。\n" ..
                                    "         这会导致缩放出现问题。请将其转换为非相对设置。")
                            end
                            obs.obs_data_release(settings)
                        end
                    end
                end
            end

            obs.source_list_release(filters)
        end

        -- If the user has a transform crop set, we need to convert it into a crop filter so that it works correctly with zooming
        -- Ideally the user does this manually and uses a crop filter instead of the transfrom crop because this might not work 100% of the time
        if not found_crop_filter and (sceneitem_crop_orig.left ~= 0 or sceneitem_crop_orig.top ~= 0 or sceneitem_crop_orig.right ~= 0 or sceneitem_crop_orig.bottom ~= 0) then
            log("Creating new crop filter")

            -- Update the source size
            source_width = source_width - (sceneitem_crop_orig.left + sceneitem_crop_orig.right)
            source_height = source_height - (sceneitem_crop_orig.top + sceneitem_crop_orig.bottom)

            -- Update the source crop filter now that we will be using one
            zoom_info.source_crop_filter.x = sceneitem_crop_orig.left
            zoom_info.source_crop_filter.y = sceneitem_crop_orig.top
            zoom_info.source_crop_filter.w = source_width
            zoom_info.source_crop_filter.h = source_height

            -- Add a new crop filter that emulates the existing transform crop
            local settings = obs.obs_data_create()
            obs.obs_data_set_bool(settings, "relative", false)
            obs.obs_data_set_int(settings, "left", zoom_info.source_crop_filter.x)
            obs.obs_data_set_int(settings, "top", zoom_info.source_crop_filter.y)
            obs.obs_data_set_int(settings, "cx", zoom_info.source_crop_filter.w)
            obs.obs_data_set_int(settings, "cy", zoom_info.source_crop_filter.h)
            crop_filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
            obs.obs_source_filter_add(source, crop_filter_temp)
            obs.obs_data_release(settings)

            -- Clear out the transform crop
            sceneitem_crop.left = 0
            sceneitem_crop.top = 0
            sceneitem_crop.right = 0
            sceneitem_crop.bottom = 0
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop)

            log("警告：检测到已存在的变换裁剪。这可能会导致缩放问题。\n" ..
                "         设置已自动转换为裁剪/填充滤镜。\n" ..
                "         如果您的布局出现问题，请考虑手动创建该滤镜。")
        elseif found_crop_filter then
            source_width = zoom_info.source_crop_filter.w
            source_height = zoom_info.source_crop_filter.h
        end

        -- Get the rest of the information needed to correctly zoom
        zoom_info.source_size = { width = source_width, height = source_height }
        zoom_info.source_crop = {
            l = sceneitem_crop_orig.left,
            t = sceneitem_crop_orig.top,
            r = sceneitem_crop_orig.right,
            b = sceneitem_crop_orig.bottom
        }
        --log("Transform updated. Using following values -\n" .. format_table(zoom_info))

        -- Set the initial the crop filter data to match the source
        crop_filter_info_orig = { x = 0, y = 0, w = zoom_info.source_size.width, h = zoom_info.source_size.height }
        crop_filter_info = {
            x = crop_filter_info_orig.x,
            y = crop_filter_info_orig.y,
            w = crop_filter_info_orig.w,
            h = crop_filter_info_orig.h
        }

        -- Get or create our crop filter that we change during zoom
        crop_filter = obs.obs_source_get_filter_by_name(source, CROP_FILTER_NAME)
        if crop_filter == nil then
            crop_filter_settings = obs.obs_data_create()
            obs.obs_data_set_bool(crop_filter_settings, "relative", false)
            crop_filter = obs.obs_source_create_private("crop_filter", CROP_FILTER_NAME, crop_filter_settings)
            obs.obs_source_filter_add(source, crop_filter)
        else
            crop_filter_settings = obs.obs_source_get_settings(crop_filter)
        end

        obs.obs_source_filter_set_order(source, crop_filter, obs.OBS_ORDER_MOVE_BOTTOM)
        set_crop_settings(crop_filter_info_orig)
    end
end

---
-- Get the target position that we will attempt to zoom towards
---@param zoom any
---@return table
function get_target_position(zoom)
    local mouse = get_mouse_pos()

    -- If we have monitor information then we can offset the mouse by the top-left of the monitor position
    -- This is because the display-capture source assumes top-left is 0,0 but the mouse uses the total desktop area,
    -- so a second monitor might start at x:1920, y:0 for example, so when we click at 1920,0 we want it to look like we clicked 0,0 on the source.
    if monitor_info then
        mouse.x = mouse.x - monitor_info.x
        mouse.y = mouse.y - monitor_info.y
    end

    -- Now offset the mouse by the crop top-left because if we cropped 100px off of the display clicking at 100,0 should really be the top-left 0,0
    mouse.x = mouse.x - zoom.source_crop_filter.x
    mouse.y = mouse.y - zoom.source_crop_filter.y

    -- If the source uses a different scale to the display, apply that now.
    -- This can happen with cloned sources, where it is cloning a scene that has a full screen display.
    -- The display will be the full desktop pixel size, but the cloned scene will be scaled down to the canvas,
    -- so we need to scale down the mouse movement to match
    if monitor_info and monitor_info.scale_x and monitor_info.scale_y then
        mouse.x = mouse.x * monitor_info.scale_x
        mouse.y = mouse.y * monitor_info.scale_y
    end

    -- Get the new size after we zoom
    -- Remember that because we are using a crop/pad filter making the size smaller (dividing by zoom) means that we see less of the image
    -- in the same amount of space making it look bigger (aka zoomed in)
    local new_size = {
        width = zoom.source_size.width / target_zoom_factor,
        height = zoom.source_size.height / target_zoom_factor
    }

    -- New offset for the crop/pad filter is whereever we clicked minus half the size, so that the clicked point because the new center
    local pos = {
        x = mouse.x - new_size.width * 0.5,
        y = mouse.y - new_size.height * 0.5
    }

    -- Create the full crop results
    local crop = {
        x = pos.x,
        y = pos.y,
        w = new_size.width,
        h = new_size.height,
    }

    -- Keep the zoom in bounds of the source so that we never show something outside that user is trying to hide with existing crop settings
    crop.x = math.floor(clamp(0, (zoom.source_size.width - new_size.width), crop.x))
    crop.y = math.floor(clamp(0, (zoom.source_size.height - new_size.height), crop.y))

    return { crop = crop, raw_center = mouse, clamped_center = { x = math.floor(crop.x + crop.w * 0.5), y = math.floor(crop.y + crop.h * 0.5) } }
end

function on_toggle_lock(pressed)
    if pressed then
        if zoom_state == ZoomState.ZoomedIn then
            is_zoom_locked = not is_zoom_locked
            log("Camera focus lock is " .. (is_zoom_locked and "on" or "off"))
            if is_zoom_locked then
                locked_crop_pos = { x = crop_filter_info.x, y = crop_filter_info.y }
                cam_vel_x = 0
                cam_vel_y = 0
            end
        end
    end
end

function update_zoom_value(new_zoom)
    if new_zoom < 1.0 then new_zoom = 1.0 end
    if new_zoom > 5.0 then new_zoom = 5.0 end
    if zoom_value ~= new_zoom then
        zoom_value = new_zoom
        log("Zoom factor adjusted to: " .. zoom_value)
        if script_settings ~= nil then
            obs.obs_data_set_double(script_settings, "zoom_value", zoom_value)
        end
        if zoom_state == ZoomState.ZoomedIn then
            zoom_info.zoom_to = zoom_value
            target_zoom_factor = zoom_value
            zoom_target = get_target_position(zoom_info)
        end
    end
end

function on_zoom_in(pressed)
    if pressed then
        update_zoom_value(zoom_value + zoom_step)
    end
end

function on_zoom_out(pressed)
    if pressed then
        update_zoom_value(zoom_value - zoom_step)
    end
end

function on_toggle_follow(pressed)
    if pressed then
        is_following_mouse = not is_following_mouse
        log("Tracking mouse is " .. (is_following_mouse and "on" or "off"))

        if is_following_mouse and zoom_state == ZoomState.ZoomedIn then
            -- Since we are zooming we need to start the timer for the animation and tracking
            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function on_toggle_zoom(pressed)
    if pressed then
        -- Check if we are in a safe state to zoom
        if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.None then
            if zoom_state == ZoomState.ZoomedIn then
                log("Zooming out")
                -- To zoom out, we set the target back to whatever it was originally
                zoom_state = ZoomState.ZoomingOut
                zoom_time = 0
                locked_center = nil
                locked_last_pos = nil
                zoom_target = { crop = crop_filter_info_orig, c = sceneitem_crop_orig }
                zoom_start_crop = { x = crop_filter_info.x, y = crop_filter_info.y, w = crop_filter_info.w, h = crop_filter_info.h }
                if is_following_mouse then
                    is_following_mouse = false
                    log("Tracking mouse is off (due to zoom out)")
                end
            else
                log("Zooming in")
                -- To zoom in, we get a new target based on where the mouse was when zoom was clicked
                zoom_state = ZoomState.ZoomingIn
                zoom_info.zoom_to = zoom_value
                target_zoom_factor = zoom_value
                zoom_time = 0
                locked_center = nil
                locked_last_pos = nil
                zoom_target = get_target_position(zoom_info)
                zoom_start_crop = { x = crop_filter_info.x, y = crop_filter_info.y, w = crop_filter_info.w, h = crop_filter_info.h }
                last_mouse_pos = get_mouse_pos()
            end

            -- Since we are zooming we need to start the timer for the animation and tracking
            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function on_timer()
    if crop_filter_info ~= nil and zoom_target ~= nil then
        -- Calculate accurate time delta (dt)
        local current_time = os.clock()
        local dt = 0.016
        if last_timer_time > 0 then
            dt = current_time - last_timer_time
        end
        last_timer_time = current_time

        -- Clamp dt to prevent teleportation during lag or scene switching
        if dt <= 0 or dt > 0.1 then
            dt = 0.016
        end

        -- Idle detection and auto zoom reset logic
        if use_auto_reset_zoom and zoom_state == ZoomState.ZoomedIn and not is_zoom_locked then
            local mouse = get_mouse_pos()
            local dist = math.sqrt((mouse.x - last_mouse_pos.x)^2 + (mouse.y - last_mouse_pos.y)^2)
            last_mouse_pos = { x = mouse.x, y = mouse.y }

            if dist < 2.0 then
                idle_time = idle_time + dt
                if idle_time >= auto_reset_zoom_delay then
                    target_zoom_factor = 1.0
                end
            else
                idle_time = 0.0
                target_zoom_factor = zoom_value
            end
        else
            idle_time = 0.0
            target_zoom_factor = zoom_value
        end

        -- Update our zoom time that we use for the animation
        if zoom_curve == "instant" then
            zoom_time = 1.0
        else
            zoom_time = zoom_time + zoom_speed
        end

        if zoom_state == ZoomState.ZoomingOut or zoom_state == ZoomState.ZoomingIn then
            -- When we are doing a zoom animation (in or out) we linear interpolate the crop to the target
            if zoom_time <= 1 then
                -- If we have auto-follow turned on, make sure to keep the mouse in the view while we zoom
                -- This is incase the user is moving the mouse a lot while the animation (which may be slow) is playing
                if zoom_state == ZoomState.ZoomingIn and use_auto_follow_mouse then
                    zoom_target = get_target_position(zoom_info)
                end
                local t_val = get_ease_value(zoom_curve, zoom_time)
                crop_filter_info.x = lerp(zoom_start_crop.x, zoom_target.crop.x, t_val)
                crop_filter_info.y = lerp(zoom_start_crop.y, zoom_target.crop.y, t_val)
                crop_filter_info.w = lerp(zoom_start_crop.w, zoom_target.crop.w, t_val)
                crop_filter_info.h = lerp(zoom_start_crop.h, zoom_target.crop.h, t_val)
                set_crop_settings(crop_filter_info)

                -- Reset velocity so physical movement starts smoothly from rest
                cam_vel_x = 0
                cam_vel_y = 0
            end
        else
            -- If we are not zooming we only move the x/y to follow the mouse (width/height stay constant)
            if is_following_mouse then
                -- Update target if camera zoom is not locked
                if not is_zoom_locked then
                    zoom_target = get_target_position(zoom_info)
                end

                local skip_frame = false
                if not use_follow_outside_bounds and not is_zoom_locked then
                    if zoom_target.raw_center.x < zoom_target.crop.x or
                        zoom_target.raw_center.x > zoom_target.crop.x + zoom_target.crop.w or
                        zoom_target.raw_center.y < zoom_target.crop.y or
                        zoom_target.raw_center.y > zoom_target.crop.y + zoom_target.crop.h then
                        -- Don't follow the mouse if we are outside the bounds of the source
                        skip_frame = true
                    end
                end

                if not skip_frame then
                    -- If we have a locked_center it means we are currently in a locked zone and
                    -- shouldn't track the mouse until it moves out of the area
                    if locked_center ~= nil and not is_zoom_locked then
                        local diff = {
                            x = zoom_target.raw_center.x - locked_center.x,
                            y = zoom_target.raw_center.y - locked_center.y
                        }

                        local track = {
                            x = zoom_target.crop.w * (0.5 - (follow_border * 0.01)),
                            y = zoom_target.crop.h * (0.5 - (follow_border * 0.01))
                        }

                        if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                            -- Cursor moved into the active border area, so resume tracking by clearing out the locked_center
                            locked_center = nil
                            locked_last_pos = {
                                x = zoom_target.raw_center.x,
                                y = zoom_target.raw_center.y,
                                diff_x = diff.x,
                                diff_y = diff.y
                            }
                            log("Locked area exited - resume tracking")
                        end
                    end

                    -- Determine target position
                    local target_x = zoom_target.crop.x
                    local target_y = zoom_target.crop.y

                    if is_zoom_locked then
                        target_x = locked_crop_pos.x
                        target_y = locked_crop_pos.y
                    elseif locked_center ~= nil then
                        target_x = locked_crop_pos.x
                        target_y = locked_crop_pos.y
                    end

                    -- Check if camera needs to move
                    local needs_update = false
                    if math.abs(target_x - crop_filter_info.x) > 0.01 or
                       math.abs(target_y - crop_filter_info.y) > 0.01 or
                       math.abs(cam_vel_x) > 0.1 or
                       math.abs(cam_vel_y) > 0.1 or
                       math.abs(crop_filter_info.w - zoom_target.crop.w) > 0.1 then
                        needs_update = true
                    end

                    if needs_update then
                        local next_x, next_y
                        if spring_strength <= 0 then
                            -- Traditional smooth lerp (no physical oscillations/shaking)
                            local smooth_factor = clamp(0.0, 1.0, 1.0 - math.exp(-15 * dt * follow_speed))
                            next_x = lerp(crop_filter_info.x, target_x, smooth_factor)
                            next_y = lerp(crop_filter_info.y, target_y, smooth_factor)
                            cam_vel_x = 0
                            cam_vel_y = 0
                        else
                            -- Spring-Damper Physics Integration
                            local k_s = spring_strength
                            local k_d = 2 * damping_ratio * math.sqrt(k_s)

                            local ax = k_s * (target_x - crop_filter_info.x) - k_d * cam_vel_x
                            local ay = k_s * (target_y - crop_filter_info.y) - k_d * cam_vel_y

                            cam_vel_x = cam_vel_x + ax * dt
                            cam_vel_y = cam_vel_y + ay * dt

                            next_x = crop_filter_info.x + cam_vel_x * dt
                            next_y = crop_filter_info.y + cam_vel_y * dt
                        end

                        local max_x = zoom_info.source_size.width - crop_filter_info.w
                        local max_y = zoom_info.source_size.height - crop_filter_info.h

                        -- Handle boundary collision and reset velocity
                        if next_x < 0 then
                            crop_filter_info.x = 0
                            cam_vel_x = 0
                        elseif next_x > max_x then
                            crop_filter_info.x = max_x
                            cam_vel_x = 0
                        else
                            crop_filter_info.x = next_x
                        end

                        if next_y < 0 then
                            crop_filter_info.y = 0
                            cam_vel_y = 0
                        elseif next_y > max_y then
                            crop_filter_info.y = max_y
                            cam_vel_y = 0
                        else
                            crop_filter_info.y = next_y
                        end

                        -- Smoothly transition width and height for dynamic zoom
                        local zoom_smooth_factor = 1.0 - math.exp(-15 * dt)
                        crop_filter_info.w = lerp(crop_filter_info.w, zoom_target.crop.w, zoom_smooth_factor)
                        crop_filter_info.h = lerp(crop_filter_info.h, zoom_target.crop.h, zoom_smooth_factor)

                        set_crop_settings(crop_filter_info)

                        -- Check to see if the mouse has stopped moving long enough to create a new safe zone
                        if is_following_mouse and locked_center == nil and locked_last_pos ~= nil and not is_zoom_locked then
                            local diff = {
                                x = math.abs(crop_filter_info.x - zoom_target.crop.x),
                                y = math.abs(crop_filter_info.y - zoom_target.crop.y),
                                auto_x = zoom_target.raw_center.x - locked_last_pos.x,
                                auto_y = zoom_target.raw_center.y - locked_last_pos.y
                            }

                            locked_last_pos.x = zoom_target.raw_center.x
                            locked_last_pos.y = zoom_target.raw_center.y

                            local lock = false
                            if math.abs(locked_last_pos.diff_x) > math.abs(locked_last_pos.diff_y) then
                                if (diff.auto_x < 0 and locked_last_pos.diff_x > 0) or (diff.auto_x > 0 and locked_last_pos.diff_x < 0) then
                                    lock = true
                                end
                            else
                                if (diff.auto_y < 0 and locked_last_pos.diff_y > 0) or (diff.auto_y > 0 and locked_last_pos.diff_y < 0) then
                                    lock = true
                                end
                            end

                            if (lock and use_follow_auto_lock) or (diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity) then
                                -- Make the new center the position of the current camera
                                locked_center = {
                                    x = math.floor(crop_filter_info.x + zoom_target.crop.w * 0.5),
                                    y = math.floor(crop_filter_info.y + zoom_target.crop.h * 0.5)
                                }
                                locked_crop_pos = {
                                    x = crop_filter_info.x,
                                    y = crop_filter_info.y
                                }
                                log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                            end
                        end
                    end
                end
            end
        end

        -- Check to see if the animation is over
        if zoom_time >= 1 then
            local should_stop_timer = false
            -- When we finished zooming out we remove the timer
            if zoom_state == ZoomState.ZoomingOut then
                log("Zoomed out")
                zoom_state = ZoomState.None
                should_stop_timer = true
            elseif zoom_state == ZoomState.ZoomingIn then
                log("Zoomed in")
                zoom_state = ZoomState.ZoomedIn
                -- If we finished zooming in and we arent tracking the mouse we can also remove the timer
                should_stop_timer = (not use_auto_follow_mouse) and (not is_following_mouse) and (not use_auto_reset_zoom)

                if use_auto_follow_mouse then
                    is_following_mouse = true
                    log("Tracking mouse is " .. (is_following_mouse and "on" or "off") .. " (due to auto follow)")
                end

                -- We set the current position as the center for the follow safezone
                if is_following_mouse and follow_border < 50 then
                    zoom_target = get_target_position(zoom_info)
                    locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                    locked_crop_pos = { x = zoom_target.crop.x, y = zoom_target.crop.y }
                    log("Cursor stopped. Tracking locked to " .. locked_center.x .. ", " .. locked_center.y)
                end
            end

            if should_stop_timer then
                is_timer_running = false
                obs.timer_remove(on_timer)
            end
        end
    end
end

function on_socket_timer()
    if not socket_server then
        return
    end

    repeat
        local data, status = socket_server:receive_from()
        if data then
            local sx, sy = data:match("(-?%d+) (-?%d+)")
            if sx and sy then
                local x = tonumber(sx, 10)
                local y = tonumber(sy, 10)
                if not socket_mouse then
                    log("Socket server client connected")
                    socket_mouse = { x = x, y = y }
                else
                    socket_mouse.x = x
                    socket_mouse.y = y
                end
            end
        elseif status ~= "timeout" then
            error(status)
        end
    until data == nil
end

function start_server()
    if socket_available then
        local address = socket.find_first_address("*", socket_port)

        socket_server = socket.create("inet", "dgram", "udp")
        if socket_server ~= nil then
            socket_server:set_option("reuseaddr", 1)
            socket_server:set_blocking(false)
            socket_server:bind(address, socket_port)
            obs.timer_add(on_socket_timer, socket_poll)
            log("Socket server listening on port " .. socket_port .. "...")
        end
    end
end

function stop_server()
    if socket_server ~= nil then
        log("Socket server stopped")
        obs.timer_remove(on_socket_timer)
        socket_server:close()
        socket_server = nil
        socket_mouse = nil
    end
end

function set_crop_settings(crop)
    if crop_filter ~= nil and crop_filter_settings ~= nil then
        -- Call into OBS to update our crop filter with the new settings
        -- I have no idea how slow/expensive this is, so we could potentially only do it if something changes
        obs.obs_data_set_int(crop_filter_settings, "left", math.floor(crop.x))
        obs.obs_data_set_int(crop_filter_settings, "top", math.floor(crop.y))
        obs.obs_data_set_int(crop_filter_settings, "cx", math.floor(crop.w))
        obs.obs_data_set_int(crop_filter_settings, "cy", math.floor(crop.h))
        obs.obs_source_update(crop_filter, crop_filter_settings)
    end
end

function on_transition_start(t)
    log("Transition started")
    -- We need to remove the crop from the sceneitem as the transition starts to avoid
    -- a delay with the rendering where you see the old crop and jump to the new one
    release_sceneitem()
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("OBS Scene changed")
        keystroke_sceneitem = nil
        -- If the scene changes we attempt to find a new source with the same name in this new scene
        -- TODO: There probably needs to be a way for users to specify what source they want to use in each scene
        -- Scene change can happen before OBS has completely loaded, so we check for that here
        if is_obs_loaded then
            refresh_sceneitem(true)
            if enable_keystroke and ensure_keystroke_item then
                ensure_keystroke_item()
            end
        end
    elseif event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        log("OBS Loaded")
        -- Once loaded we perform our initial lookup
        is_obs_loaded = true
        monitor_info = get_monitor_info(source)
        refresh_sceneitem(true)
        if enable_keystroke and ensure_keystroke_item then
            ensure_keystroke_item()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        log("OBS Shutting down")
        -- Add a fail-safe for unloading the script during shutdown
        if is_script_loaded then
            script_unload()
        end
    end
end

function on_update_transform()
    -- Update the crop/size settings based on whatever the source in the current scene looks like
    if is_obs_loaded then
        refresh_sceneitem(true)
    end

    return true
end

function on_settings_modified(props, prop, settings)
    local name = obs.obs_property_name(prop)

    -- Show/Hide the settings based on if the checkbox is checked or not
    if name == "use_monitor_override" then
        local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_x"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_y"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_w"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_h"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sx"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sy"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dw"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dh"), visible)
        return true
    elseif name == "use_socket" then
        local visible = obs.obs_data_get_bool(settings, "use_socket")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_port"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_poll"), visible)
        return true
    elseif name == "allow_all_sources" then
        local sources_list = obs.obs_properties_get(props, "source")
        populate_zoom_sources(sources_list)
        return true
    elseif name == "debug_logs" then
        if obs.obs_data_get_bool(settings, "debug_logs") then
            log_current_settings()
        end
    end

    return false
end

---
-- Write the current settings into the log for debugging and user issue reports
function log_current_settings()
    local settings = {
        zoom_value = zoom_value,
        zoom_speed = zoom_speed,
        use_auto_follow_mouse = use_auto_follow_mouse,
        use_follow_outside_bounds = use_follow_outside_bounds,
        follow_speed = follow_speed,
        follow_border = follow_border,
        follow_safezone_sensitivity = follow_safezone_sensitivity,
        use_follow_auto_lock = use_follow_auto_lock,
        use_monitor_override = use_monitor_override,
        monitor_override_x = monitor_override_x,
        monitor_override_y = monitor_override_y,
        monitor_override_w = monitor_override_w,
        monitor_override_h = monitor_override_h,
        monitor_override_sx = monitor_override_sx,
        monitor_override_sy = monitor_override_sy,
        monitor_override_dw = monitor_override_dw,
        monitor_override_dh = monitor_override_dh,
        use_socket = use_socket,
        socket_port = socket_port,
        socket_poll = socket_poll,
        debug_logs = debug_logs,
        spring_strength = spring_strength,
        damping_ratio = damping_ratio,
        zoom_step = zoom_step,
        is_zoom_locked = is_zoom_locked,
        zoom_curve = zoom_curve,
        version = VERSION
    }

    log("OBS Version: " .. string.format("%.1f", major) .. "." .. minor)
    log("Platform: " .. ffi.os)
    log("Current settings:")
    log(format_table(settings))
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "obs-auto-zoom 帮助信息 v" .. VERSION .. "\n" ..
        "https://github.com/LACS-Official/obs-auto-zoom\n" ..
        "----------------------------------------------------\n" ..
        "此脚本将缩放选定的显示器采集源以聚焦于鼠标。\n\n" ..
        "缩放源 (Zoom Source): 当前场景中用于缩放的显示器采集源\n" ..
        "缩放倍数 (Zoom Factor): 放大的倍数\n" ..
        "缩放速度 (Zoom Speed): 放大/缩小动画的速度\n" ..
        "自动跟随鼠标 (Auto follow mouse): 勾选时，在放大状态下自动跟踪光标\n" ..
        "越界跟随 (Follow outside bounds): 勾选时，即使光标超出源边界也会进行跟踪\n" ..
        "跟随速度 (Follow Speed): 跟踪时放大区域跟随鼠标移动的速度\n" ..
        "跟随边缘 (Follow Border): 距离源边缘的百分比距离，在此范围外移动时将重新触发鼠标跟踪\n" ..
        "锁定灵敏度 (Lock Sensitivity): 跟踪需要多接近才会锁定在当前位置，并停止跟踪直到您进入跟随边缘\n" ..
        "反向自动锁定 (Auto Lock on reverse direction): 如果您反转鼠标的方向，自动停止跟踪\n" ..
        "允许任何缩放源 (Show all sources): 勾选时，允许选择任意源作为缩放源。对于非显示器采集源，您必须手动设置源位置\n" ..
        "设置手动源位置 (Set manual source position): 勾选时，覆盖所选源自动计算的坐标 x/y（左上角位置）、宽度/高度（大小）以及 scaleX/scaleY（画布缩放比例）\n" ..
        "X: 源最左边像素的坐标\n" ..
        "Y: 源最上边像素的坐标\n" ..
        "宽度 (Width): 源的宽度（以像素为单位）\n" ..
        "高度 (Height): 源的高度（以像素为单位）\n" ..
        "Scale X: 如果源大小不是 1:1，应用于鼠标水平位置的缩放比例（适用于克隆源）\n" ..
        "Scale Y: 如果源大小不是 1:1，应用于鼠标垂直位置的缩放比例（适用于克隆源）\n" ..
        "显示器宽度 (Monitor Width): 显示该源的显示器宽度（像素）\n" ..
        "显示器高度 (Monitor Height): 显示该源的显示器高度（像素）\n"

    if socket_available then
        help = help ..
            "启用远程鼠标监听器 (Enable remote mouse listener): 勾选时，将启动一个 UDP 套接字服务器，监听来自远程客户端的鼠标位置消息，详见：https://github.com/BlankSourceCode/obs-zoom-to-mouse-remote\n" ..
            "端口 (Port): 套接字服务器使用的端口号\n" ..
            "轮询延迟 (Poll Delay): 更新鼠标位置的时间间隔（毫秒）\n"
    end

    help = help ..
        "更多信息 (More Info): 在脚本日志中显示此帮助文本\n" ..
        "启用调试日志 (Enable debug logging): 在脚本日志中显示额外的调试信息\n\n"

    obs.script_log(obs.OBS_LOG_INFO, help)
end



-- ============================================================================
-- Keystroke Visualizer Module (按键与鼠标可视化)
-- ============================================================================

local VKEY_LIST = {
    [0x41] = "A", [0x42] = "B", [0x43] = "C", [0x44] = "D", [0x45] = "E",
    [0x46] = "F", [0x47] = "G", [0x48] = "H", [0x49] = "I", [0x4A] = "J",
    [0x4B] = "K", [0x4C] = "L", [0x4D] = "M", [0x4E] = "N", [0x4F] = "O",
    [0x50] = "P", [0x51] = "Q", [0x52] = "R", [0x53] = "S", [0x54] = "T",
    [0x55] = "U", [0x56] = "V", [0x57] = "W", [0x58] = "X", [0x59] = "Y", [0x5A] = "Z",
    [0x30] = "0", [0x31] = "1", [0x32] = "2", [0x33] = "3", [0x34] = "4",
    [0x35] = "5", [0x36] = "6", [0x37] = "7", [0x38] = "8", [0x39] = "9",
    [0x60] = "Num 0", [0x61] = "Num 1", [0x62] = "Num 2", [0x63] = "Num 3", [0x64] = "Num 4",
    [0x65] = "Num 5", [0x66] = "Num 6", [0x67] = "Num 7", [0x68] = "Num 8", [0x69] = "Num 9",
    [0x6A] = "Num *", [0x6B] = "Num +", [0x6D] = "Num -", [0x6E] = "Num .", [0x6F] = "Num /",
    [0x70] = "F1", [0x71] = "F2", [0x72] = "F3", [0x73] = "F4", [0x74] = "F5", [0x75] = "F6",
    [0x76] = "F7", [0x77] = "F8", [0x78] = "F9", [0x79] = "F10", [0x7A] = "F11", [0x7B] = "F12",
    [0x20] = "Space", [0x0D] = "Enter", [0x1B] = "Esc", [0x08] = "Backspace", [0x09] = "Tab",
    [0x2E] = "Delete", [0x2D] = "Insert", [0x24] = "Home", [0x23] = "End",
    [0x21] = "PageUp", [0x22] = "PageDown",
    [0x26] = "↑", [0x28] = "↓", [0x25] = "←", [0x27] = "→",
    [0x14] = "CapsLock",
    [0xBA] = ";", [0xBB] = "=", [0xBC] = ",", [0xBD] = "-", [0xBE] = ".",
    [0xBF] = "/", [0xC0] = "`", [0xDB] = "[", [0xDC] = "\\", [0xDD] = "]", [0xDE] = "'"
}

local MOUSE_VKEYS = {
    [0x01] = "鼠标左键",
    [0x02] = "鼠标右键",
    [0x04] = "鼠标中键"
}

local function is_vkey_down(vkey)
    if not win_user32 then return false end
    local state = win_user32.GetAsyncKeyState(vkey)
    return bit.band(state, 0x8000) ~= 0
end

set_keystroke_text = function(text)
    if not keystroke_source then return end
    local s = obs.obs_data_create()
    obs.obs_data_set_string(s, "text", text)
    obs.obs_source_update(keystroke_source, s)
    obs.obs_data_release(s)
end

apply_keystroke_styling = function()
    if not keystroke_source then return end
    local s = obs.obs_source_get_settings(keystroke_source)
    if s then
        local font_obj = obs.obs_data_get_obj(s, "font")
        if not font_obj then font_obj = obs.obs_data_create() end
        obs.obs_data_set_string(font_obj, "face", "Microsoft YaHei UI")
        obs.obs_data_set_int(font_obj, "size", keystroke_font_size)
        obs.obs_data_set_int(font_obj, "flags", 1) -- Bold
        obs.obs_data_set_obj(s, "font", font_obj)
        obs.obs_data_release(font_obj)
        obs.obs_data_set_int(s, "color", 0xFFFFFFFF)
        obs.obs_data_set_bool(s, "outline", true)
        obs.obs_data_set_int(s, "outline_color", 0xFF141414)
        obs.obs_data_set_int(s, "outline_size", 4)
        obs.obs_data_set_int(s, "outline_opacity", 100)
        obs.obs_data_set_int(s, "bk_color", 0xCC1E1E1E)
        obs.obs_data_set_int(s, "bk_opacity", 85)
        obs.obs_source_update(keystroke_source, s)
        obs.obs_data_release(s)
    end
end

ensure_keystroke_item = function()
    if not keystroke_source then
        keystroke_source = obs.obs_get_source_by_name("[obs-auto-zoom] 按键显示")
        if not keystroke_source then
            local text_types = {"text_gdiplus_v2", "text_gdiplus", "text_ft2_source_v2", "text_ft2_source"}
            for _, t in ipairs(text_types) do
                local s = obs.obs_data_create()
                obs.obs_data_set_string(s, "text", "")
                local font_obj = obs.obs_data_create()
                obs.obs_data_set_string(font_obj, "face", "Microsoft YaHei UI")
                obs.obs_data_set_int(font_obj, "size", keystroke_font_size)
                obs.obs_data_set_int(font_obj, "flags", 1)
                obs.obs_data_set_obj(s, "font", font_obj)
                obs.obs_data_release(font_obj)
                obs.obs_data_set_int(s, "color", 0xFFFFFFFF)
                obs.obs_data_set_bool(s, "outline", true)
                obs.obs_data_set_int(s, "outline_color", 0xFF141414)
                obs.obs_data_set_int(s, "outline_size", 4)
                obs.obs_data_set_int(s, "outline_opacity", 100)
                obs.obs_data_set_int(s, "bk_color", 0xCC1E1E1E)
                obs.obs_data_set_int(s, "bk_opacity", 85)
                keystroke_source = obs.obs_source_create(t, "[obs-auto-zoom] 按键显示", s, nil)
                obs.obs_data_release(s)
                if keystroke_source ~= nil then break end
            end
        end
    end
    if not keystroke_source then return nil end

    if not keystroke_sceneitem then
        local cur_scene_source = obs.obs_frontend_get_current_scene()
        if cur_scene_source ~= nil then
            local cur_scene = obs.obs_scene_from_source(cur_scene_source)
            if cur_scene ~= nil then
                local item = obs.obs_scene_find_source(cur_scene, "[obs-auto-zoom] 按键显示")
                if not item then
                    item = obs.obs_scene_add(cur_scene, keystroke_source)
                end
                if item then
                    obs.obs_sceneitem_set_order(item, obs.OBS_ORDER_MOVE_TOP)
                    keystroke_sceneitem = item
                end
            end
            obs.obs_source_release(cur_scene_source)
        end
    end
    return keystroke_sceneitem
end

show_keystroke_sceneitem = function()
    local item = ensure_keystroke_item()
    if item then
        obs.obs_sceneitem_set_visible(item, true)
    end
end

hide_keystroke_sceneitem = function()
    if keystroke_sceneitem then
        obs.obs_sceneitem_set_visible(keystroke_sceneitem, false)
    end
end

update_keystroke_position = function()
    if not keystroke_sceneitem then return end

    local cw, ch = 1920, 1080
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        cw = ovi.base_width
        ch = ovi.base_height
    end

    local target_x = 0
    local target_y = 0

    if keystroke_pos == "follow_mouse" then
        local mouse = get_mouse_pos()
        if source ~= nil and sceneitem ~= nil and sceneitem_info ~= nil then
            local mon_x = (monitor_info and monitor_info.x) or 0
            local mon_y = (monitor_info and monitor_info.y) or 0
            local mon_w = (monitor_info and monitor_info.width and monitor_info.width > 0) and monitor_info.width or cw
            local mon_h = (monitor_info and monitor_info.height and monitor_info.height > 0) and monitor_info.height or ch
            local bounds_x = (sceneitem_info.bounds and sceneitem_info.bounds.x and sceneitem_info.bounds.x > 0) and sceneitem_info.bounds.x or mon_w
            local bounds_y = (sceneitem_info.bounds and sceneitem_info.bounds.y and sceneitem_info.bounds.y > 0) and sceneitem_info.bounds.y or mon_h
            local pos_x = (sceneitem_info.pos and sceneitem_info.pos.x) or 0
            local pos_y = (sceneitem_info.pos and sceneitem_info.pos.y) or 0

            local is_zoomed = (zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.ZoomingIn or zoom_state == ZoomState.ZoomingOut)
            if is_zoomed and crop_filter_info and crop_filter_info.w and crop_filter_info.w > 0 and crop_filter_info.h and crop_filter_info.h > 0 then
                local c_x = crop_filter_info.x or 0
                local c_y = crop_filter_info.y or 0
                local rel_x = (mouse.x - mon_x - c_x) / crop_filter_info.w
                local rel_y = (mouse.y - mon_y - c_y) / crop_filter_info.h
                target_x = pos_x + rel_x * bounds_x + keystroke_offset_x
                target_y = pos_y + rel_y * bounds_y + keystroke_offset_y
            else
                local rel_x = (mouse.x - mon_x) / mon_w
                local rel_y = (mouse.y - mon_y) / mon_h
                target_x = pos_x + rel_x * bounds_x + keystroke_offset_x
                target_y = pos_y + rel_y * bounds_y + keystroke_offset_y
            end
        else
            target_x = (mouse and mouse.x or 0) + keystroke_offset_x
            target_y = (mouse and mouse.y or 0) + keystroke_offset_y
        end
    elseif keystroke_pos == "bottom_center" then
        target_x = cw * 0.5 + keystroke_offset_x
        target_y = ch - 120 + keystroke_offset_y
    elseif keystroke_pos == "bottom_left" then
        target_x = 60 + keystroke_offset_x
        target_y = ch - 120 + keystroke_offset_y
    elseif keystroke_pos == "bottom_right" then
        target_x = cw - 320 + keystroke_offset_x
        target_y = ch - 120 + keystroke_offset_y
    elseif keystroke_pos == "top_center" then
        target_x = cw * 0.5 + keystroke_offset_x
        target_y = 60 + keystroke_offset_y
    elseif keystroke_pos == "top_left" then
        target_x = 60 + keystroke_offset_x
        target_y = 60 + keystroke_offset_y
    elseif keystroke_pos == "top_right" then
        target_x = cw - 320 + keystroke_offset_x
        target_y = 60 + keystroke_offset_y
    else
        target_x = cw * 0.5 + keystroke_offset_x
        target_y = ch - 120 + keystroke_offset_y
    end

    local pos = obs.vec2()
    pos.x = target_x
    pos.y = target_y
    obs.obs_sceneitem_set_pos(keystroke_sceneitem, pos)
end

function on_keystroke_timer()
    if not enable_keystroke then return end

    local now = os.clock()
    local dt = (keystroke_last_time > 0) and (now - keystroke_last_time) or 0.02
    keystroke_last_time = now
    if dt <= 0 or dt > 0.1 then dt = 0.02 end

    if keystroke_fade_timer > 0 then
        keystroke_fade_timer = keystroke_fade_timer - dt
        if keystroke_fade_timer <= 0 then
            set_keystroke_text("")
            hide_keystroke_sceneitem()
        else
            update_keystroke_position()
        end
    end

    if ffi.os ~= "Windows" or not win_user32 then return end

    local ctrl = is_vkey_down(0x11)
    local alt = is_vkey_down(0x12)
    local shift = is_vkey_down(0x10)
    local win = is_vkey_down(0x5B) or is_vkey_down(0x5C)

    local current_keys = {}
    local any_new_key = false

    -- Check keyboard keys
    for vkey, _ in pairs(VKEY_LIST) do
        if is_vkey_down(vkey) then
            current_keys[vkey] = true
            if not keystroke_prev_keys[vkey] then
                any_new_key = true
            end
        end
    end

    -- Check mouse buttons if enabled
    if keystroke_include_mouse then
        for vkey, _ in pairs(MOUSE_VKEYS) do
            if is_vkey_down(vkey) then
                current_keys[vkey] = true
                if not keystroke_prev_keys[vkey] then
                    any_new_key = true
                end
            end
        end
    end

    local mod_changed = (ctrl ~= keystroke_prev_modifiers.ctrl) or
                        (alt ~= keystroke_prev_modifiers.alt) or
                        (shift ~= keystroke_prev_modifiers.shift) or
                        (win ~= keystroke_prev_modifiers.win)

    local has_mod = ctrl or alt or shift or win
    local has_key = next(current_keys) ~= nil

    if any_new_key or (mod_changed and (has_key or (has_mod and keystroke_modifier_only))) then
        local parts = {}
        if ctrl then table.insert(parts, "Ctrl") end
        if alt then table.insert(parts, "Alt") end
        if shift then table.insert(parts, "Shift") end
        if win then table.insert(parts, "Win") end

        for vkey, _ in pairs(current_keys) do
            local name = VKEY_LIST[vkey] or (keystroke_include_mouse and MOUSE_VKEYS[vkey])
            if name then
                table.insert(parts, name)
            end
        end

        if #parts > 0 then
            local text = "[ " .. table.concat(parts, " + ") .. " ]"
            set_keystroke_text(text)
            keystroke_fade_timer = keystroke_duration
            show_keystroke_sceneitem()
            update_keystroke_position()
        end
    end

    keystroke_prev_keys = current_keys
    keystroke_prev_modifiers = { ctrl = ctrl, alt = alt, shift = shift, win = win }
end

-- ============================================================================
-- Config Backup & WebDAV Sync Module (配置备份与 WebDAV 云端同步)
-- ============================================================================

local function get_local_config_file()
    local dir = (script_path and script_path()) or (obs.script_path and obs.script_path()) or "./"
    return dir .. "obs-auto-zoom-config.json"
end

local function reload_hotkeys_from_settings(settings)
    if not settings then return end
    local hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom")
    if hotkey_save_array ~= nil then
        obs.obs_hotkey_load(hotkey_zoom_id, hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.follow")
    if hotkey_save_array ~= nil then
        obs.obs_hotkey_load(hotkey_follow_id, hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.lock")
    if hotkey_save_array ~= nil then
        obs.obs_hotkey_load(hotkey_lock_id, hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom_in")
    if hotkey_save_array ~= nil then
        obs.obs_hotkey_load(hotkey_zoom_in_id, hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom_out")
    if hotkey_save_array ~= nil then
        obs.obs_hotkey_load(hotkey_zoom_out_id, hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end

export_local_config = function()
    if not script_settings then
        backup_status_msg = "❌ 导出失败: 当前没有可导出的设置数据"
        obs.script_log(obs.OBS_LOG_WARNING, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
    script_save(script_settings)
    local json_str = obs.obs_data_get_json(script_settings)
    local path = get_local_config_file()
    local f = io.open(path, "w")
    local timestamp = os.date("%H:%M:%S")
    if not f then
        backup_status_msg = string.format("[%s] ❌ 导出失败: 无法写入文件 %s", timestamp, path)
        obs.script_log(obs.OBS_LOG_ERROR, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
    f:write(json_str)
    f:close()
    backup_status_msg = string.format("[%s] ✅ 配置已成功导出到本地文件: %s", timestamp, path)
    obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] " .. backup_status_msg)
    return true
end

import_local_config = function()
    local path = get_local_config_file()
    local f = io.open(path, "r")
    local timestamp = os.date("%H:%M:%S")
    if not f then
        backup_status_msg = string.format("[%s] ❌ 导入失败: 未找到本地配置文件 %s", timestamp, path)
        obs.script_log(obs.OBS_LOG_ERROR, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
    local content = f:read("*all")
    f:close()
    local loaded = obs.obs_data_create_from_json(content)
    if not loaded then
        backup_status_msg = string.format("[%s] ❌ 导入失败: 配置文件 JSON 格式错误", timestamp)
        obs.script_log(obs.OBS_LOG_ERROR, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
    obs.obs_data_apply(script_settings, loaded)
    reload_hotkeys_from_settings(script_settings)
    script_update(script_settings)
    obs.obs_data_release(loaded)
    backup_status_msg = string.format("[%s] ✅ 本地配置已成功导入并生效！", timestamp)
    obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] " .. backup_status_msg)
    return true
end

function get_webdav_paths()
    local url = webdav_url or ""
    url = url:gsub("^%s*(.-)%s*$", "%1")
    if url == "" then return nil, nil end

    local filename = webdav_file or "obs-auto-zoom-config.json"
    filename = filename:gsub("^%s*(.-)%s*$", "%1")
    if filename == "" then filename = "obs-auto-zoom-config.json" end

    local folder_name = webdav_folder or "obsautozoom"
    folder_name = folder_name:gsub("^%s*(.-)%s*$", "%1")
    folder_name = folder_name:gsub("^/+", ""):gsub("/+$", "")
    if folder_name == "" then folder_name = "obsautozoom" end

    -- 如果用户在 URL 末尾带了 .json 文件名，则分离出路径与文件名
    if url:match("%.json$") then
        local base, fname = url:match("^(.-)/([^/]+%.json)$")
        if base and fname then
            filename = fname
            url = base
        end
    end

    -- 移除 url 末尾所有斜杠
    url = url:gsub("/+$", "")

    -- 检查 url 末尾是否已经包含了 target folder（避免重复嵌套如 /obsautozoom/obsautozoom）
    local folder_url
    if folder_name == "." or folder_name == "/" then
        folder_url = url .. "/"
    else
        local escaped_folder = folder_name:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        if url:match("/" .. escaped_folder .. "$") then
            folder_url = url .. "/"
        else
            folder_url = url .. "/" .. folder_name .. "/"
        end
    end

    local file_url = folder_url .. filename
    return folder_url, file_url
end

function get_webdav_target_url()
    local _, file_url = get_webdav_paths()
    return file_url
end

function webdav_ensure_folder(folder_url, auth_opt)
    if not folder_url then return false, "" end
    -- 使用 WebDAV MKCOL 方法自动创建文件夹
    -- 根据 RFC 4918：目录已存在时返回 405 Method Not Allowed；新建成功返回 201 Created
    local cmd = string.format('curl.exe -k -s -w "%%{http_code}" -X MKCOL %s"%s" -o NUL', auth_opt, folder_url)
    local pipe = io.popen(cmd)
    local code = pipe and pipe:read("*all") or ""
    if pipe then pipe:close() end
    code = code:gsub("%s+", "")
    local num = tonumber(code)
    -- 201(新建成功), 405(目录已存在), 200/207(正常) 均代表目录就绪可用
    if num and (num == 201 or num == 405 or num == 200 or num == 207) then
        return true, code
    end
    return false, code
end

function webdav_backup_config()
    local folder_url, file_url = get_webdav_paths()
    local timestamp = os.date("%H:%M:%S")
    if not file_url or not folder_url then
        backup_status_msg = string.format("[%s] ❌ WebDAV 备份失败: 请先填写有效的 WebDAV URL", timestamp)
        obs.script_log(obs.OBS_LOG_WARNING, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
    if not script_settings then return false end

    local safe_user = (webdav_user or ""):gsub('"', '\\"')
    local safe_pass = (webdav_pass or ""):gsub('"', '\\"')
    local auth_opt = ""
    if safe_user ~= "" then
        auth_opt = string.format('-u "%s:%s" ', safe_user, safe_pass)
    end

    -- 1. 自动检查并创建远端子目录 (如 obsautozoom)
    obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] 正在检查/创建远端备份目录: " .. folder_url)
    local ok_folder, col_code = webdav_ensure_folder(folder_url, auth_opt)
    if not ok_folder and col_code ~= "" then
        obs.script_log(obs.OBS_LOG_WARNING, string.format("[obs-auto-zoom] MKCOL 创建目录返回 HTTP %s (将继续尝试写入)", col_code))
    end

    -- 2. 导出设置数据到临时文件
    script_save(script_settings)
    local json_str = obs.obs_data_get_json(script_settings)
    local base_dir = (script_path and script_path()) or (obs.script_path and obs.script_path()) or "./"
    local temp_path = base_dir .. "webdav_temp_upload.json"
    temp_path = temp_path:gsub("\\", "/")
    local f = io.open(temp_path, "w")
    if not f then
        backup_status_msg = string.format("[%s] ❌ WebDAV 备份失败: 无法创建临时上传文件", timestamp)
        obs.script_log(obs.OBS_LOG_ERROR, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
    f:write(json_str)
    f:close()

    obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] 正在上传配置至 WebDAV: " .. file_url)

    -- 3. 使用 curl -T 上传文件 (WebDAV 标准 PUT 上传方式，带精确 Content-Length 与 Content-Type)
    local cmd = string.format('curl.exe -k -s -w "%%{http_code}" -T "%s" %s-H "Content-Type: application/json" "%s" -o NUL',
        temp_path, auth_opt, file_url)

    local pipe = io.popen(cmd)
    local code = pipe and pipe:read("*all") or ""
    if pipe then pipe:close() end

    code = code:gsub("%s+", "")
    local num = tonumber(code)

    -- 如果 -T 返回非 2xx，尝试使用备用 -X PUT --data-binary 方式重试一次
    if not (num and num >= 200 and num < 300) then
        local cmd_alt = string.format('curl.exe -k -s -w "%%{http_code}" -X PUT %s-H "Content-Type: application/json" --data-binary @"%s" "%s" -o NUL',
            auth_opt, temp_path, file_url)
        local pipe_alt = io.popen(cmd_alt)
        local code_alt = pipe_alt and pipe_alt:read("*all") or ""
        if pipe_alt then pipe_alt:close() end
        code_alt = code_alt:gsub("%s+", "")
        local num_alt = tonumber(code_alt)
        if num_alt and num_alt >= 200 and num_alt < 300 then
            code = code_alt
            num = num_alt
        end
    end

    os.remove(temp_path)

    if num and (num >= 200 and num < 300) then
        backup_status_msg = string.format("[%s] ✅ WebDAV 备份成功！已保存至 %s (HTTP %s)", timestamp, file_url, code)
        obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] " .. backup_status_msg)
        return true
    else
        backup_status_msg = string.format("[%s] ❌ WebDAV 备份失败 (HTTP %s)。目标: %s", timestamp, code, file_url)
        obs.script_log(obs.OBS_LOG_ERROR, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
end

function webdav_restore_config()
    local folder_url, file_url = get_webdav_paths()
    local timestamp = os.date("%H:%M:%S")
    if not file_url then
        backup_status_msg = string.format("[%s] ❌ WebDAV 恢复失败: 请先填写有效的 WebDAV URL", timestamp)
        obs.script_log(obs.OBS_LOG_WARNING, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end

    obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] 正在从 WebDAV 下载配置: " .. file_url)

    local safe_user = (webdav_user or ""):gsub('"', '\\"')
    local safe_pass = (webdav_pass or ""):gsub('"', '\\"')
    local auth_opt = ""
    if safe_user ~= "" then
        auth_opt = string.format('-u "%s:%s" ', safe_user, safe_pass)
    end

    local cmd = string.format('curl.exe -k -s %s"%s"', auth_opt, file_url)
    local pipe = io.popen(cmd)
    local response = pipe and pipe:read("*all") or ""
    if pipe then pipe:close() end

    -- 如果在指定子目录中没有找到文件，回退检查一下旧根路径以兼容历史备份
    local used_url = file_url
    if (not response or response == "" or response:match("^<html") or response:match("^<!DOCTYPE")) and folder_url then
        local root_file_url = (webdav_url or ""):gsub("/+$", "") .. "/" .. (webdav_file or "obs-auto-zoom-config.json")
        if root_file_url ~= file_url then
            obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] 尝试从备用根路径读取: " .. root_file_url)
            local cmd_fb = string.format('curl.exe -k -s %s"%s"', auth_opt, root_file_url)
            local pipe_fb = io.popen(cmd_fb)
            local resp_fb = pipe_fb and pipe_fb:read("*all") or ""
            if pipe_fb then pipe_fb:close() end
            if resp_fb and resp_fb ~= "" and not resp_fb:match("^<html") and not resp_fb:match("^<!DOCTYPE") then
                response = resp_fb
                used_url = root_file_url
            end
        end
    end

    if not response or response == "" or response:match("^<html") or response:match("^<!DOCTYPE") then
        backup_status_msg = string.format("[%s] ❌ WebDAV 恢复失败: 目标文件不存在或返回非 JSON 内容 (URL: %s)", timestamp, used_url)
        obs.script_log(obs.OBS_LOG_ERROR, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end

    local loaded = obs.obs_data_create_from_json(response)
    if not loaded then
        backup_status_msg = string.format("[%s] ❌ WebDAV 恢复失败: 返回数据无法解析为有效 JSON (可能为 404 或认证失败页)", timestamp)
        obs.script_log(obs.OBS_LOG_ERROR, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end

    obs.obs_data_apply(script_settings, loaded)
    reload_hotkeys_from_settings(script_settings)
    script_update(script_settings)
    obs.obs_data_release(loaded)

    backup_status_msg = string.format("[%s] ✅ WebDAV 配置恢复成功并已应用！(来自 %s)", timestamp, used_url)
    obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] " .. backup_status_msg)
    return true
end

function webdav_test_connection()
    local folder_url, file_url = get_webdav_paths()
    local url = webdav_url or ""
    url = url:gsub("^%s*(.-)%s*$", "%1")
    local timestamp = os.date("%H:%M:%S")
    if url == "" then
        backup_status_msg = string.format("[%s] ❌ 请先填写 WebDAV 服务器 URL", timestamp)
        obs.script_log(obs.OBS_LOG_WARNING, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end

    local safe_user = (webdav_user or ""):gsub('"', '\\"')
    local safe_pass = (webdav_pass or ""):gsub('"', '\\"')
    local auth_opt = ""
    if safe_user ~= "" then
        auth_opt = string.format('-u "%s:%s" ', safe_user, safe_pass)
    end

    -- 1. 验证 WebDAV 基础连接与身份验证 (PROPFIND)
    local cmd = string.format('curl.exe -k -s -w "%%{http_code}" -X PROPFIND %s"%s" -o NUL', auth_opt, url)
    local pipe = io.popen(cmd)
    local code = pipe and pipe:read("*all") or ""
    if pipe then pipe:close() end

    code = code:gsub("%s+", "")
    local num = tonumber(code)
    if num and (num == 207 or (num >= 200 and num < 300)) then
        -- 2. 检查并尝试创建备份子目录 (如 obsautozoom)
        if folder_url then
            local folder_ok, col_code = webdav_ensure_folder(folder_url, auth_opt)
            if folder_ok then
                backup_status_msg = string.format("[%s] ✅ WebDAV 连接成功 (HTTP %s)！备份目录 [%s] 已就绪", timestamp, code, webdav_folder or "obsautozoom")
            else
                backup_status_msg = string.format("[%s] ✅ WebDAV 基础连接成功 (HTTP %s)，但备份子目录返回 HTTP %s", timestamp, code, col_code)
            end
        else
            backup_status_msg = string.format("[%s] ✅ WebDAV 连接成功 (HTTP %s)！", timestamp, code)
        end
        obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] " .. backup_status_msg)
        return true
    else
        backup_status_msg = string.format("[%s] ⚠️ WebDAV 连接返回 HTTP %s (请确认账号密码与 URL 路径)", timestamp, code)
        obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] " .. backup_status_msg)
        return false
    end
end

function script_description()
    return "缩放选定的显示器采集源以聚焦于鼠标"
end

function script_properties()
    local props = obs.obs_properties_create()

    -- Populate the sources list with the known display-capture sources (OBS calls them 'monitor_capture' internally even though the UI says 'Display Capture')
    local sources_list = obs.obs_properties_add_list(props, "source", "缩放源 (Zoom Source)", obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)

    populate_zoom_sources(sources_list)

    local refresh_sources = obs.obs_properties_add_button(props, "refresh", "刷新缩放源",
        function()
            populate_zoom_sources(sources_list)
            monitor_info = get_monitor_info(source)
            return true
        end)
    obs.obs_property_set_long_description(refresh_sources,
        "点击重新生成可用源的缩放源下拉列表")

    -- Add the rest of the settings UI
    local zoom = obs.obs_properties_add_float(props, "zoom_value", "缩放倍数 (Zoom Factor)", 1, 5, 0.5)
    local zoom_speed = obs.obs_properties_add_float_slider(props, "zoom_speed", "缩放速度 (Zoom Speed)", 0.01, 1, 0.01)

    local zoom_curve_list = obs.obs_properties_add_list(props, "zoom_curve", "缩放动画类型 (Easing)", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(zoom_curve_list, "平滑缓动 (Ease-In-Out)", "ease_in_out")
    obs.obs_property_list_add_string(zoom_curve_list, "线性匀速 (Linear)", "linear")
    obs.obs_property_list_add_string(zoom_curve_list, "加速拉近 (Ease-In)", "ease_in")
    obs.obs_property_list_add_string(zoom_curve_list, "减速停靠 (Ease-Out)", "ease_out")
    obs.obs_property_list_add_string(zoom_curve_list, "电影回弹 (Overshoot)", "overshoot")
    obs.obs_property_list_add_string(zoom_curve_list, "瞬间缩放 (Instant)", "instant")
    obs.obs_property_set_long_description(zoom_curve_list, "放大/缩小动画使用的过渡曲线类型")

    local follow = obs.obs_properties_add_bool(props, "follow", "自动跟随鼠标")
    obs.obs_property_set_long_description(follow,
        "启用时，放大后将自动开始鼠标跟踪，无需等待跟踪切换快捷键")

    local follow_outside_bounds = obs.obs_properties_add_bool(props, "follow_outside_bounds", "越界跟随")
    obs.obs_property_set_long_description(follow_outside_bounds,
        "启用时，即使光标超出缩放源的边界，也会跟踪鼠标")

    local follow_speed = obs.obs_properties_add_float_slider(props, "follow_speed", "跟随速度 (Follow Speed)", 0.01, 1, 0.01)
    local follow_border = obs.obs_properties_add_int_slider(props, "follow_border", "跟随边缘 (Follow Border)", 0, 50, 1)
    local safezone_sense = obs.obs_properties_add_int_slider(props,
        "follow_safezone_sensitivity", "锁定灵敏度 (Lock Sensitivity)", 1, 20, 1)

    local spring_str = obs.obs_properties_add_float_slider(props, "spring_strength", "跟随弹性强度 (Spring Strength)", 0.0, 50.0, 0.5)
    obs.obs_property_set_long_description(spring_str, "二阶跟随的弹性硬度，值越大镜头跟随鼠标越快越紧凑。设为 0 则关闭物理弹性，退化为无震荡的传统平滑跟随")

    local damp_ratio = obs.obs_properties_add_float_slider(props, "damping_ratio", "跟随阻尼比 (Damping Ratio)", 0.1, 2.0, 0.05)
    obs.obs_property_set_long_description(damp_ratio, "二阶跟随的阻尼，值越小回弹越明显，0.6~0.7 为临界舒适值")

    local zoom_step_prop = obs.obs_properties_add_float(props, "zoom_step", "快捷键变焦步长 (Zoom Step)", 0.1, 1.0, 0.1)
    obs.obs_property_set_long_description(zoom_step_prop, "每次按快捷键放大或缩小时，缩放倍数的增减量")

    local use_idle_reset = obs.obs_properties_add_bool(props, "use_auto_reset_zoom", "空闲自动复原1x")
    obs.obs_property_set_long_description(use_idle_reset, "启用时，如果鼠标静止不动达到设定时间，镜头将自动缩回到1x比例（不放大）")

    local idle_reset_delay = obs.obs_properties_add_float_slider(props, "auto_reset_zoom_delay", "空闲检测时间 (秒)", 1.0, 10.0, 0.5)
    obs.obs_property_set_long_description(idle_reset_delay, "鼠标静止多少秒后开始自动复原")

    local follow_auto_lock = obs.obs_properties_add_bool(props, "follow_auto_lock", "反向自动锁定")
    obs.obs_property_set_long_description(follow_auto_lock,
        "启用时，将鼠标移至缩放源边缘将开始跟踪，\n" ..
        "但向中心移回将停止跟踪，类似于在RTS游戏中平移摄像机")

    local allow_all = obs.obs_properties_add_bool(props, "allow_all_sources", "允许任何缩放源")
    obs.obs_property_set_long_description(allow_all, "启用以允许选择任何源作为缩放源\n" ..
        "对于非显示器采集源，您必须手动设置源位置")

    local override_props = obs.obs_properties_create();
    local override_label = obs.obs_properties_add_text(override_props, "monitor_override_label", "", obs.OBS_TEXT_INFO)
    local override_x = obs.obs_properties_add_int(override_props, "monitor_override_x", "X", -10000, 10000, 1)
    local override_y = obs.obs_properties_add_int(override_props, "monitor_override_y", "Y", -10000, 10000, 1)
    local override_w = obs.obs_properties_add_int(override_props, "monitor_override_w", "宽度 (Width)", 0, 10000, 1)
    local override_h = obs.obs_properties_add_int(override_props, "monitor_override_h", "高度 (Height)", 0, 10000, 1)
    local override_sx = obs.obs_properties_add_float(override_props, "monitor_override_sx", "水平缩放 (Scale X)", 0, 100, 0.01)
    local override_sy = obs.obs_properties_add_float(override_props, "monitor_override_sy", "垂直缩放 (Scale Y)", 0, 100, 0.01)
    local override_dw = obs.obs_properties_add_int(override_props, "monitor_override_dw", "显示器宽度", 0, 10000, 1)
    local override_dh = obs.obs_properties_add_int(override_props, "monitor_override_dh", "显示器高度", 0, 10000, 1)
    local override = obs.obs_properties_add_group(props, "use_monitor_override", "设置手动源位置",
        obs.OBS_GROUP_CHECKABLE, override_props)

    obs.obs_property_set_long_description(override_label,
        "启用时，将使用指定的尺寸/位置设置作为缩放源，而不是自动计算的设置")
    obs.obs_property_set_long_description(override_sx, "通常为 1 - 除非你正在使用缩放的源")
    obs.obs_property_set_long_description(override_sy, "通常为 1 - 除非你正在使用缩放的源")
    obs.obs_property_set_long_description(override_dw, "显示器的水平分辨率（像素）")
    obs.obs_property_set_long_description(override_dh, "显示器的垂直分辨率（像素）")

    if socket_available then
        local socket_props = obs.obs_properties_create();
        local r_label = obs.obs_properties_add_text(socket_props, "socket_label", "", obs.OBS_TEXT_INFO)
        local r_port = obs.obs_properties_add_int(socket_props, "socket_port", "端口 (Port)", 1024, 65535, 1)
        local r_poll = obs.obs_properties_add_int(socket_props, "socket_poll", "轮询延迟 (毫秒)", 0, 1000, 1)
        local socket = obs.obs_properties_add_group(props, "use_socket", "启用远程鼠标监听器",
            obs.OBS_GROUP_CHECKABLE, socket_props)

        obs.obs_property_set_long_description(r_label,
            "启用时，UDP套接字服务器将监听来自远程客户端的鼠标位置消息")
        obs.obs_property_set_long_description(r_port,
            "更改端口后必须重启服务器（先取消勾选，再重新勾选“启用远程鼠标监听器”）")
        obs.obs_property_set_long_description(r_poll,
            "更改轮询延迟后必须重启服务器（先取消勾选，再重新勾选“启用远程鼠标监听器”）")

        obs.obs_property_set_visible(r_label, not use_socket)
        obs.obs_property_set_visible(r_port, use_socket)
        obs.obs_property_set_visible(r_poll, use_socket)
        obs.obs_property_set_modified_callback(socket, on_settings_modified)
    end

    -- ========================================================================
    -- Keystroke Visualizer Properties
    -- ========================================================================
    local key_props = obs.obs_properties_create()
    local pos_list = obs.obs_properties_add_list(key_props, "keystroke_pos", "显示位置", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(pos_list, "跟随鼠标光标 (Follow Cursor)", "follow_mouse")
    obs.obs_property_list_add_string(pos_list, "固定: 屏幕底部居中", "bottom_center")
    obs.obs_property_list_add_string(pos_list, "固定: 屏幕左下角", "bottom_left")
    obs.obs_property_list_add_string(pos_list, "固定: 屏幕右下角", "bottom_right")
    obs.obs_property_list_add_string(pos_list, "固定: 屏幕顶部居中", "top_center")
    obs.obs_property_list_add_string(pos_list, "固定: 屏幕左上角", "top_left")
    obs.obs_property_list_add_string(pos_list, "固定: 屏幕右上角", "top_right")

    obs.obs_properties_add_int_slider(key_props, "keystroke_offset_x", "水平偏移微调 X (px)", -500, 500, 5)
    obs.obs_properties_add_int_slider(key_props, "keystroke_offset_y", "垂直偏移微调 Y (px)", -500, 500, 5)
    obs.obs_properties_add_float_slider(key_props, "keystroke_duration", "按键气泡停留时间 (秒)", 0.5, 5.0, 0.1)
    obs.obs_properties_add_int_slider(key_props, "keystroke_font_size", "字体大小 (pt)", 16, 72, 2)
    obs.obs_properties_add_bool(key_props, "keystroke_include_mouse", "同时显示鼠标点击 (左键/右键/中键)")
    obs.obs_properties_add_bool(key_props, "keystroke_modifier_only", "单独按下 Ctrl/Alt/Shift/Win 也显示")

    local key_group = obs.obs_properties_add_group(props, "enable_keystroke", "⌨️ 开启按键与鼠标可视化 (Keystroke OSD)", obs.OBS_GROUP_CHECKABLE, key_props)
    obs.obs_property_set_long_description(key_group, "勾选后将在 OBS 画面中实时显示键盘快捷键与鼠标点击动作，支持自定义显示位置与偏移")

    -- ========================================================================
    -- Config Backup & WebDAV Sync Properties
    -- ========================================================================
    local backup_props = obs.obs_properties_create()

    local btn_export = obs.obs_properties_add_button(backup_props, "btn_export_local", "📤 导出配置到本地文件 (obs-auto-zoom-config.json)", function()
        export_local_config()
        return true
    end)
    obs.obs_property_set_long_description(btn_export, "将当前所有参数设置导出保存到脚本目录的 obs-auto-zoom-config.json 文件")

    local btn_import = obs.obs_properties_add_button(backup_props, "btn_import_local", "📥 从本地文件导入配置", function()
        import_local_config()
        return true
    end)
    obs.obs_property_set_long_description(btn_import, "从脚本目录读取 obs-auto-zoom-config.json 并恢复所有参数设置")

    local dav_props = obs.obs_properties_create()
    obs.obs_properties_add_text(dav_props, "webdav_url", "WebDAV 服务器 URL", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(dav_props, "webdav_user", "WebDAV 用户名 / 账号", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(dav_props, "webdav_pass", "WebDAV 密码 / 授权应用密码", obs.OBS_TEXT_PASSWORD)
    local fld_prop = obs.obs_properties_add_text(dav_props, "webdav_folder", "远端备份文件夹", obs.OBS_TEXT_DEFAULT)
    obs.obs_property_set_long_description(fld_prop, "备份存放的子目录名称，默认为 obsautozoom（如果远端不存在将自动新建此文件夹）")
    obs.obs_properties_add_text(dav_props, "webdav_file", "远端存储文件名", obs.OBS_TEXT_DEFAULT)

    local btn_test_dav = obs.obs_properties_add_button(dav_props, "btn_test_dav", "🔍 测试 WebDAV 连接", function()
        webdav_test_connection()
        return true
    end)

    local btn_up_dav = obs.obs_properties_add_button(dav_props, "btn_up_dav", "☁️ 备份配置到 WebDAV (Upload)", function()
        webdav_backup_config()
        return true
    end)
    obs.obs_property_set_long_description(btn_up_dav, "将当前脚本设置打包并作为 JSON 文件上传至 WebDAV 服务器")

    local btn_down_dav = obs.obs_properties_add_button(dav_props, "btn_down_dav", "☁️ 从 WebDAV 恢复配置 (Download)", function()
        webdav_restore_config()
        return true
    end)
    obs.obs_property_set_long_description(btn_down_dav, "从 WebDAV 服务器下载配置文件并立即应用到当前脚本")

    obs.obs_properties_add_group(backup_props, "webdav_group", "WebDAV 云端同步设置 (支持坚果云/群晖/Nextcloud等)", obs.OBS_GROUP_NORMAL, dav_props)

    local backup_group = obs.obs_properties_add_group(props, "backup_root_group", "💾 配置导入导出与云端备份 (WebDAV)", obs.OBS_GROUP_NORMAL, backup_props)
    obs.obs_property_set_long_description(backup_group, "支持本地 JSON 文件配置导入导出，以及通过 WebDAV 协议进行云端备份与恢复")

    -- Add a button for more information
    local help = obs.obs_properties_add_button(props, "help_button", "更多信息", on_print_help)
    obs.obs_property_set_long_description(help,
        "点击在脚本日志中显示帮助信息")

    local debug = obs.obs_properties_add_bool(props, "debug_logs", "启用调试日志")
    obs.obs_property_set_long_description(debug,
        "启用时，脚本将输出诊断消息到脚本日志中（用于调试/Github issue反馈）")

    obs.obs_property_set_visible(override_label, not use_monitor_override)
    obs.obs_property_set_visible(override_x, use_monitor_override)
    obs.obs_property_set_visible(override_y, use_monitor_override)
    obs.obs_property_set_visible(override_w, use_monitor_override)
    obs.obs_property_set_visible(override_h, use_monitor_override)
    obs.obs_property_set_visible(override_sx, use_monitor_override)
    obs.obs_property_set_visible(override_sy, use_monitor_override)
    obs.obs_property_set_visible(override_dw, use_monitor_override)
    obs.obs_property_set_visible(override_dh, use_monitor_override)
    obs.obs_property_set_modified_callback(override, on_settings_modified)

    obs.obs_property_set_modified_callback(allow_all, on_settings_modified)
    obs.obs_property_set_modified_callback(debug, on_settings_modified)

    if has_update_available and latest_version then
        local notice_html = "<hr/><b style='color:#e74c3c;'>🚀 检测到新版本 v" .. latest_version .. "！(当前版本 v" .. VERSION .. ")</b><br>" ..
            "请点击下方按钮前往 GitHub 下载最新发布版本。<br/>"
        obs.obs_properties_add_text(props, "update_notice_text", notice_html, obs.OBS_TEXT_INFO)

        local download_btn = obs.obs_properties_add_button(props, "download_update_btn", "🚀 前往 GitHub 下载最新版本 (v" .. latest_version .. ")", function()
            open_url(latest_release_url)
            return false
        end)
        obs.obs_property_set_long_description(download_btn, "点击在默认浏览器中打开 GitHub Releases 页面下载最新版本")
    end

    local check_update_btn = obs.obs_properties_add_button(props, "check_update_btn", "🔍 检查版本更新 (当前 v" .. VERSION .. ")", function()
        obs.script_log(obs.OBS_LOG_INFO, "[obs-auto-zoom] 正在检查 GitHub 版本更新...")
        check_for_updates(true)
        return true
    end)
    obs.obs_property_set_long_description(check_update_btn, "手动连接 GitHub Releases 检测是否有新版本发布")

    local info_text = [[<hr/>
<b>项目信息</b><br>
项目名称：obs-auto-zoom<br>
说明：OBS自动缩放脚本-领创工作室<br>
本项目地址：<a href="https://github.com/LACS-Official/obs-auto-zoom">obs-auto-zoom</a><br>
工作室官网：<a href="https://www.lacs.cc">www.lacs.cc</a><br>
原项目地址：<a href="https://github.com/BlankSourceCode/obs-zoom-to-mouse">obs-zoom-to-mouse</a>]]
    obs.obs_properties_add_text(props, "about_text", info_text, obs.OBS_TEXT_INFO)
    return props
end

function script_load(settings)
    sceneitem_info_orig = nil

    -- Workaround for detecting if OBS is already loaded and we were reloaded using "Reload Scripts"
    local current_scene = obs.obs_frontend_get_current_scene()
    is_obs_loaded = current_scene ~= nil -- Current scene is nil on first OBS load
    obs.obs_source_release(current_scene)

    -- Save reference to settings
    script_settings = settings

    -- Add our hotkey
    hotkey_zoom_id = obs.obs_hotkey_register_frontend("toggle_zoom_hotkey", "[obs-auto-zoom] 切换缩放至鼠标",
        on_toggle_zoom)

    hotkey_follow_id = obs.obs_hotkey_register_frontend("toggle_follow_hotkey", "[obs-auto-zoom] 在缩放时切换跟随鼠标",
        on_toggle_follow)

    hotkey_lock_id = obs.obs_hotkey_register_frontend("toggle_lock_hotkey", "[obs-auto-zoom] 切换镜头焦点锁定",
        on_toggle_lock)

    hotkey_zoom_in_id = obs.obs_hotkey_register_frontend("zoom_in_hotkey", "[obs-auto-zoom] 增大缩放倍数",
        on_zoom_in)

    hotkey_zoom_out_id = obs.obs_hotkey_register_frontend("zoom_out_hotkey", "[obs-auto-zoom] 减小缩放倍数",
        on_zoom_out)

    -- Attempt to reload existing hotkey bindings if we can find any
    reload_hotkeys_from_settings(settings)

    -- Load any other settings
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    -- Load physics and zoom settings
    spring_strength = obs.obs_data_get_double(settings, "spring_strength")
    damping_ratio = obs.obs_data_get_double(settings, "damping_ratio")
    zoom_step = obs.obs_data_get_double(settings, "zoom_step")

    -- Load auto zoom reset settings
    use_auto_reset_zoom = obs.obs_data_get_bool(settings, "use_auto_reset_zoom")
    auto_reset_zoom_delay = obs.obs_data_get_double(settings, "auto_reset_zoom_delay")

    -- Load zoom curve setting
    zoom_curve = obs.obs_data_get_string(settings, "zoom_curve")

    -- Load keystroke visualizer settings
    enable_keystroke = obs.obs_data_get_bool(settings, "enable_keystroke")
    keystroke_pos = obs.obs_data_get_string(settings, "keystroke_pos")
    if keystroke_pos == "" then keystroke_pos = "follow_mouse" end
    keystroke_offset_x = obs.obs_data_get_int(settings, "keystroke_offset_x")
    keystroke_offset_y = obs.obs_data_get_int(settings, "keystroke_offset_y")
    keystroke_duration = obs.obs_data_get_double(settings, "keystroke_duration")
    if keystroke_duration <= 0 then keystroke_duration = 1.5 end
    keystroke_font_size = obs.obs_data_get_int(settings, "keystroke_font_size")
    if keystroke_font_size <= 0 then keystroke_font_size = 32 end
    keystroke_include_mouse = obs.obs_data_get_bool(settings, "keystroke_include_mouse")
    keystroke_modifier_only = obs.obs_data_get_bool(settings, "keystroke_modifier_only")

    -- Load WebDAV settings
    webdav_url = obs.obs_data_get_string(settings, "webdav_url")
    webdav_user = obs.obs_data_get_string(settings, "webdav_user")
    webdav_pass = obs.obs_data_get_string(settings, "webdav_pass")
    webdav_folder = obs.obs_data_get_string(settings, "webdav_folder")
    if webdav_folder == "" then webdav_folder = "obsautozoom" end
    webdav_file = obs.obs_data_get_string(settings, "webdav_file")
    if webdav_file == "" then webdav_file = "obs-auto-zoom-config.json" end

    if enable_keystroke then
        is_keystroke_timer_running = true
        obs.timer_add(on_keystroke_timer, 20)
    end

    obs.obs_frontend_add_event_callback(on_frontend_event)

    if debug_logs then
        log_current_settings()
    end

    -- Add the transition_start event handlers to each transition (the global source_transition_start event never fires)
    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for i, s in pairs(transitions) do
            local name = obs.obs_source_get_name(s)
            log("Adding transition_start listener to " .. name)
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        obs.source_list_release(transitions)
    end

    if ffi.os == "Linux" and not x11_display then
        log("错误：无法在 Linux 下获取 X11 Display\n鼠标位置将会不正确。")
    end

    source_name = ""
    use_socket = false
    target_zoom_factor = zoom_value
    is_script_loaded = true

    -- Schedule async update check 2 seconds after loading script
    obs.timer_add(on_initial_update_check_timer, 2000)
end

function script_unload()
    is_script_loaded = false

    if is_keystroke_timer_running then
        obs.timer_remove(on_keystroke_timer)
        is_keystroke_timer_running = false
    end
    if keystroke_source then
        obs.obs_source_release(keystroke_source)
        keystroke_source = nil
    end

    -- Clean up the memory usage
    if major > 29.1 or (major == 29.1 and minor > 2) then -- 29.1.2 and below seems to crash if you do this, so we ignore it as the script is closing anyway
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for i, s in pairs(transitions) do
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        obs.obs_hotkey_unregister(on_toggle_zoom)
        obs.obs_hotkey_unregister(on_toggle_follow)
        obs.obs_hotkey_unregister(on_toggle_lock)
        obs.obs_hotkey_unregister(on_zoom_in)
        obs.obs_hotkey_unregister(on_zoom_out)
        obs.obs_frontend_remove_event_callback(on_frontend_event)
        release_sceneitem()
    end

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
        x11_display = nil
        x11_lib = nil
    end

    if socket_server ~= nil then
        stop_server()
    end
end

function script_defaults(settings)
    -- Default values for the script
    obs.obs_data_set_default_string(settings, "source", "")
    obs.obs_data_set_default_double(settings, "zoom_value", 2)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.06)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.25)
    obs.obs_data_set_default_int(settings, "follow_border", 8)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    obs.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    obs.obs_data_set_default_bool(settings, "allow_all_sources", false)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    obs.obs_data_set_default_double(settings, "monitor_override_sx", 1)
    obs.obs_data_set_default_double(settings, "monitor_override_sy", 1)
    obs.obs_data_set_default_int(settings, "monitor_override_dw", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_dh", 1080)
    obs.obs_data_set_default_bool(settings, "use_socket", false)
    obs.obs_data_set_default_int(settings, "socket_port", 12345)
    obs.obs_data_set_default_int(settings, "socket_poll", 10)
    obs.obs_data_set_default_bool(settings, "debug_logs", false)

    -- Default values for physics and custom zoom step
    obs.obs_data_set_default_double(settings, "spring_strength", 0.0)
    obs.obs_data_set_default_double(settings, "damping_ratio", 0.6)
    obs.obs_data_set_default_double(settings, "zoom_step", 0.5)

    -- Default values for auto zoom reset on idle
    obs.obs_data_set_default_bool(settings, "use_auto_reset_zoom", false)
    obs.obs_data_set_default_double(settings, "auto_reset_zoom_delay", 3.0)

    -- Default values for zoom easing curve
    obs.obs_data_set_default_string(settings, "zoom_curve", "ease_in_out")

    -- Default values for keystroke visualizer
    obs.obs_data_set_default_bool(settings, "enable_keystroke", false)
    obs.obs_data_set_default_string(settings, "keystroke_pos", "follow_mouse")
    obs.obs_data_set_default_int(settings, "keystroke_offset_x", 30)
    obs.obs_data_set_default_int(settings, "keystroke_offset_y", 30)
    obs.obs_data_set_default_double(settings, "keystroke_duration", 1.5)
    obs.obs_data_set_default_int(settings, "keystroke_font_size", 32)
    obs.obs_data_set_default_bool(settings, "keystroke_include_mouse", true)
    obs.obs_data_set_default_bool(settings, "keystroke_modifier_only", true)

    -- Default values for WebDAV backup
    obs.obs_data_set_default_string(settings, "webdav_url", "https://dav.jianguoyun.com/dav/")
    obs.obs_data_set_default_string(settings, "webdav_user", "")
    obs.obs_data_set_default_string(settings, "webdav_pass", "")
    obs.obs_data_set_default_string(settings, "webdav_folder", "obsautozoom")
    obs.obs_data_set_default_string(settings, "webdav_file", "obs-auto-zoom-config.json")
end

function script_save(settings)
    -- Save the custom hotkey information
    if hotkey_zoom_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_follow_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_follow_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.follow", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_lock_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_lock_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.lock", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_zoom_in_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_in_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom_in", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_zoom_out_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_out_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom_out", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end

function script_update(settings)
    local old_source_name = source_name
    local old_override = use_monitor_override
    local old_x = monitor_override_x
    local old_y = monitor_override_y
    local old_w = monitor_override_w
    local old_h = monitor_override_h
    local old_sx = monitor_override_sx
    local old_sy = monitor_override_sy
    local old_dw = monitor_override_dw
    local old_dh = monitor_override_dh
    local old_socket = use_socket
    local old_port = socket_port
    local old_poll = socket_poll

    -- Update the settings
    source_name = obs.obs_data_get_string(settings, "source")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    -- Load physics and zoom settings
    spring_strength = obs.obs_data_get_double(settings, "spring_strength")
    damping_ratio = obs.obs_data_get_double(settings, "damping_ratio")
    zoom_step = obs.obs_data_get_double(settings, "zoom_step")
    use_auto_reset_zoom = obs.obs_data_get_bool(settings, "use_auto_reset_zoom")
    auto_reset_zoom_delay = obs.obs_data_get_double(settings, "auto_reset_zoom_delay")
    zoom_curve = obs.obs_data_get_string(settings, "zoom_curve")

    -- Load keystroke visualizer settings
    enable_keystroke = obs.obs_data_get_bool(settings, "enable_keystroke")
    keystroke_pos = obs.obs_data_get_string(settings, "keystroke_pos")
    if keystroke_pos == "" then keystroke_pos = "follow_mouse" end
    keystroke_offset_x = obs.obs_data_get_int(settings, "keystroke_offset_x")
    keystroke_offset_y = obs.obs_data_get_int(settings, "keystroke_offset_y")
    keystroke_duration = obs.obs_data_get_double(settings, "keystroke_duration")
    if keystroke_duration <= 0 then keystroke_duration = 1.5 end
    keystroke_font_size = obs.obs_data_get_int(settings, "keystroke_font_size")
    if keystroke_font_size <= 0 then keystroke_font_size = 32 end
    keystroke_include_mouse = obs.obs_data_get_bool(settings, "keystroke_include_mouse")
    keystroke_modifier_only = obs.obs_data_get_bool(settings, "keystroke_modifier_only")

    -- Load WebDAV settings
    webdav_url = obs.obs_data_get_string(settings, "webdav_url")
    webdav_user = obs.obs_data_get_string(settings, "webdav_user")
    webdav_pass = obs.obs_data_get_string(settings, "webdav_pass")
    webdav_folder = obs.obs_data_get_string(settings, "webdav_folder")
    if webdav_folder == "" then webdav_folder = "obsautozoom" end
    webdav_file = obs.obs_data_get_string(settings, "webdav_file")
    if webdav_file == "" then webdav_file = "obs-auto-zoom-config.json" end

    if enable_keystroke then
        if not is_keystroke_timer_running then
            is_keystroke_timer_running = true
            obs.timer_add(on_keystroke_timer, 20)
        end
        ensure_keystroke_item()
        apply_keystroke_styling()
    else
        if is_keystroke_timer_running then
            is_keystroke_timer_running = false
            obs.timer_remove(on_keystroke_timer)
        end
        set_keystroke_text("")
        hide_keystroke_sceneitem()
    end

    script_settings = settings

    -- Only do the expensive refresh if the user selected a new source
    if source_name ~= old_source_name and is_obs_loaded then
        refresh_sceneitem(true)
    end

    -- Update the monitor_info if the settings changed
    if source_name ~= old_source_name or
        use_monitor_override ~= old_override or
        monitor_override_x ~= old_x or
        monitor_override_y ~= old_y or
        monitor_override_w ~= old_w or
        monitor_override_h ~= old_h or
        monitor_override_sx ~= old_sx or
        monitor_override_sy ~= old_sy or
        monitor_override_dw ~= old_dw or
        monitor_override_dh ~= old_dh then
        if is_obs_loaded and source ~= nil then
            monitor_info = get_monitor_info(source)
        end
    end

    if old_socket ~= use_socket then
        if use_socket then
            start_server()
        else
            stop_server()
        end
    elseif use_socket and (old_poll ~= socket_poll or old_port ~= socket_port) then
        stop_server()
        start_server()
    end
    target_zoom_factor = zoom_value
end

function populate_zoom_sources(list)
    obs.obs_property_list_clear(list)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        obs.obs_property_list_add_string(list, "<无>", "obs-zoom-to-mouse-none")
        for _, source in ipairs(sources) do
            local source_type = obs.obs_source_get_id(source)
            if source_type == dc_info.source_id or allow_all_sources then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end

        obs.source_list_release(sources)
    end
end
