--[[
雷达 + 主动声纳 二合一系统   v3.0.0
- 雷达：完全保留原始雷达 v2.0.0 的全部功能（圆点目标、绿色扫描线、IFF角标、RWR弧、后背红石切换IFF、摄像头跟踪锁定、参数编辑等）
- 主动声纳：固定扇形、软件扫描、外圈字母旋转、触摸锁定、频道隔离、淡出效果
- 终端 UI 三页：参数（可编辑雷达/声纳参数）、系统状态、设备（支持手动分配外设）
- 外设分配功能：可在设备页选择每个GPU和显示器的用途，自动保存
- 雷达和声纳独立运行，共享目标数据但按频道过滤
======================================================================]]

-- ==========================================
--  全局配置（雷达原版参数）
-- ==========================================
local MAX_DISTANCE_LIMIT       = 5000.0          -- 最大探测距离（可由注册机覆盖）
local STRESS_TO_DISTANCE_RATIO = 2.0
local CHANNEL                  = 8888            -- 雷达网络频道
local ACTIVE_SONAR_CHANNEL     = 8889            -- 主动声纳监听频道
local SCAN_SECTOR_WIDTH        = 20              -- 雷达扫描扇区宽度（度）
local SEA_LEVEL                = -4              -- 海平面 Y 坐标

local TARGET_FADE_DURATION = 3.0                -- 目标回波淡化时间（秒）
local TARGET_HOT_DURATION  = 1.0                -- 目标高亮持续时间（秒）
local RWR_ARC_DURATION     = 1.0                -- RWR告警弧持续时间（秒）
local SPEED_FILTER_MIN     = 4.0                -- 速度过滤阈值（km/h），目前未使用但保留

-- 主动声纳参数
local ASDIC_MIN_DISTANCE    = 100.0              -- 最小探测距离（米）
local ASDIC_MAX_DISTANCE    = 600.0              -- 最大探测距离（米）
local ASDIC_STRESS_THRESHOLD = 10000.0            -- 所需最小应力（SU）
local ASDIC_SCAN_SECTOR_HALF = 90                -- 扇形半角（度），总180度
local ASDIC_SCAN_BEAM_WIDTH  = 20                -- 扫描线波束宽度（度）
local ASDIC_DEPTH_FILTER     = -8                -- 深度过滤：Y坐标 <= -8 才显示
local ASDIC_SCAN_ANGULAR_SPEED = 30.0            -- 扫描线摆动角速度（度/秒）

local REG_QUERY_TIMEOUT = 5.0                    -- 注册超时（秒）

-- ==========================================
-- 外设初始化
-- ==========================================
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Wireless Modem not found!", 0) end
modem.open(CHANNEL)
modem.open(ACTIVE_SONAR_CHANNEL)

local camera, cameraName = nil, nil
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "camera" then
        camera     = peripheral.wrap(name)
        cameraName = name
        break
    end
end
if not camera then error("Camera not found!", 0) end

local HAS_FORCE_API = (camera.forcePitchYaw ~= nil)
local function applyCameraAngle(p, y)
    if HAS_FORCE_API then camera.forcePitchYaw(p, y)
    else camera.setPitch(p); camera.setYaw(y) end
end

redstone.setOutput("front", false)

local myId        = os.getComputerID()
local CONFIG_FILE = "radar_asdic_config.txt"

-- ==========================================
-- 全局 API 别名（性能优化）
-- ==========================================
local math_sqrt     = math.sqrt
local math_atan2    = math.atan2
local math_deg      = math.deg
local math_rad      = math.rad
local math_floor    = math.floor
local math_abs      = math.abs
local math_min      = math.min
local math_max      = math.max
local math_sin      = math.sin
local math_cos      = math.cos
local os_clock      = os.clock
local os_pullEvent  = os.pullEvent
local os_queueEvent = os.queueEvent

-- ==========================================
-- 颜色工具
-- ==========================================
local function colorUnpack(c)
    return math_floor(c / 0x10000) % 0x100,
           math_floor(c / 0x100)   % 0x100,
           c % 0x100
end
local function colorPack(r, g, b)
    return math_floor(r) * 0x10000 + math_floor(g) * 0x100 + math_floor(b)
end
local function colorLerp(ca, cb, t)
    t = math_max(0.0, math_min(1.0, t))
    local ar, ag, ab = colorUnpack(ca)
    local br, bg, bb = colorUnpack(cb)
    return colorPack(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
end
local function calcFadeColor(age, hotColor)
    if age >= TARGET_FADE_DURATION then return nil end
    if age <= TARGET_HOT_DURATION  then return hotColor end
    local t = (age - TARGET_HOT_DURATION) / (TARGET_FADE_DURATION - TARGET_HOT_DURATION)
    return colorLerp(hotColor, 0x000000, t)
end

-- ==========================================
-- 运行状态（雷达原版所需变量 + 声纳扩展）
-- ==========================================
local targets               = {}               -- 目标数据表
local localPos              = nil              -- 本机位置
local trackedTargetId       = nil              -- 摄像头跟踪目标ID
local isTargetInRange       = false
local holdPitch, holdYaw    = nil, nil         -- 摄像头保持角度
local selectedTargetId      = nil              -- 当前锁定目标ID
local selectedTargetDistStr = nil              -- 锁定目标距离字符串
local currentQAbs, currentQLoc = nil, nil      -- 摄像头四元数变换
local currentServoAngle        = 0             -- 伺服电机角度
local isServoConnected         = false         -- 伺服连接状态
local yawOffset    = 0                        -- 雷达显示偏移
local motorOffset  = 0                        -- 伺服机械零点偏移
local headingOffset = 0                       -- 声纳航向偏移（摄像头校准）
local myLabel      = os.getComputerLabel() or ("Entity-" .. myId)
local monitorModes = {}
local aimPrecision = 5                        -- 瞄准网格精度（度）
local currentStressCapacity = 0               -- 当前应力容量
local currentRadarRange     = 0               -- 雷达当前有效距离
local currentNorthYawDeg    = 0               -- 摄像头原始航向（0°北顺时针）
local currentScreenTab      = 1               -- 1=参数, 2=状态, 3=设备
local menuIndex             = 1               -- 参数编辑选中项
local isEditing             = false           -- 是否正在编辑参数
local inputStr              = ""              -- 编辑输入缓冲
local cachedStressometer    = peripheral.find("Create_Stressometer")
local cachedServo           = peripheral.find("servo")

local radarEnabled = true                    -- 雷达启用开关
local broadcastOwnPos = false                -- 声纳广播自身位置（暂未使用）

-- 雷达目标池（用于GPU渲染）
local radarPool      = {}
local radarPoolCount = 0

-- 主动声纳状态
local isAsdicActive  = false
local asdicScanAngle  = 0                    -- 声纳扫描线角度（相对船首）
local asdicTargetPool = {}
local asdicPoolCount  = 0

-- IFF 敌我识别
local iffMode   = "enemy"                   -- "enemy" 或 "friendly"
local rwrEvents = {}                        -- RWR事件列表

-- ==========================================
--  外设分配管理
-- ==========================================
local allGpus = {}          -- 所有 tm_gpu 名称列表
local allMons = {}          -- 所有 monitor 名称列表
local deviceMap = {}        -- 分配映射：外设名称 -> 角色字符串

-- 角色定义
local ROLES = {"none", "radarGpu", "asdicGpu", "radarHud", "asdicHud"}
local ROLE_LABELS = {
    none = "Unassigned",
    radarGpu = "Radar GPU",
    asdicGpu = "ASDIC GPU",
    radarHud = "Radar HUD",
    asdicHud = "ASDIC HUD"
}

-- 实际绑定的外设对象
local radarGpu = nil
local asdicGpu = nil
local radarHud = nil
local asdicHud = nil

-- 收集所有外设名称
for _, name in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(name)
    if ptype == "tm_gpu" then
        table.insert(allGpus, name)
    elseif ptype == "monitor" then
        table.insert(allMons, name)
    end
end
table.sort(allGpus)
table.sort(allMons)

-- 加载设备映射
local function loadDeviceMap()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" and type(data.deviceMap) == "table" then
            for k, v in pairs(data.deviceMap) do
                deviceMap[k] = v
            end
        end
    end
end
loadDeviceMap()

-- 保存设备映射
local function saveDeviceMap()
    local config = {}
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then config = data end
    end
    config.deviceMap = deviceMap
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize(config))
    f.close()
end

-- 应用设备映射，绑定实际外设
local function applyDeviceMap()
    radarGpu = nil; asdicGpu = nil; radarHud = nil; asdicHud = nil

    for _, name in ipairs(allGpus) do
        local role = deviceMap[name]
        if role == "radarGpu" then
            radarGpu = peripheral.wrap(name)
        elseif role == "asdicGpu" then
            asdicGpu = peripheral.wrap(name)
        end
    end
    for _, name in ipairs(allMons) do
        local role = deviceMap[name]
        if role == "radarHud" then
            radarHud = peripheral.wrap(name)
            radarHud.setTextScale(1)
        elseif role == "asdicHud" then
            asdicHud = peripheral.wrap(name)
            asdicHud.setTextScale(1)
        end
    end

    -- 自动分配未指定的外设（仅当没有手动分配时）
    if not radarGpu and #allGpus >= 1 and not deviceMap[allGpus[1]] then
        deviceMap[allGpus[1]] = "radarGpu"
        radarGpu = peripheral.wrap(allGpus[1])
    end
    if not asdicGpu and #allGpus >= 2 and not deviceMap[allGpus[2]] then
        deviceMap[allGpus[2]] = "asdicGpu"
        asdicGpu = peripheral.wrap(allGpus[2])
    end
    if not radarHud and #allMons >= 1 and not deviceMap[allMons[1]] then
        deviceMap[allMons[1]] = "radarHud"
        radarHud = peripheral.wrap(allMons[1])
        radarHud.setTextScale(1)
    end
    if not asdicHud and #allMons >= 2 and not deviceMap[allMons[2]] then
        deviceMap[allMons[2]] = "asdicHud"
        asdicHud = peripheral.wrap(allMons[2])
        asdicHud.setTextScale(1)
    end

    -- 保存自动分配的结果
    saveDeviceMap()
end
applyDeviceMap()

local isHeadless = (radarGpu == nil and asdicGpu == nil and radarHud == nil and asdicHud == nil)

-- ==========================================
-- 算法函数（雷达原版）
-- ==========================================
local function calculateLookAngles(sx, sy, sz, tx, ty, tz)
    local dx, dy, dz = tx - sx, ty - sy, tz - sz
    local distH = math_sqrt(dx*dx + dz*dz)
    return math_deg(math_atan2(-dy, distH)), math_deg(math_atan2(-dx, dz))
end
local function getAngleDiff(a, b)
    local diff = (a - b) % 360
    if diff >  180 then diff = diff - 360 end
    if diff < -180 then diff = diff + 360 end
    return diff
end
local function quatInverse(qx, qy, qz, qw) return -qx, -qy, -qz, qw end
local function rotateVectorFast(vx, vy, vz, qx, qy, qz, qw)
    local cx  = qy*vz - qz*vy;  local cy  = qz*vx - qx*vz;  local cz  = qx*vy - qy*vx
    local ccx = qy*cz - qz*cy;  local ccy = qz*cx - qx*cz;  local ccz = qx*cy - qy*cx
    return vx+2*qw*cx+2*ccx, vy+2*qw*cy+2*ccy, vz+2*qw*cz+2*ccz
end
local function calcRangingDist(refPos, targetPos)
    if not refPos or not targetPos then return nil end
    if not targetPos.x then return nil end
    local dx = targetPos.x - refPos.x
    local dy = targetPos.y - refPos.y
    local dz = targetPos.z - refPos.z
    return math_sqrt(dx*dx + dy*dy + dz*dz)
end

-- ==========================================
-- 配置文件（包含所有参数和设备映射）
-- ==========================================
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f    = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            if data.yawOffset    then yawOffset    = tonumber(data.yawOffset)   or 0 end
            if data.motorOffset  then motorOffset  = tonumber(data.motorOffset) or 0 end
            if data.headingOffset then headingOffset = tonumber(data.headingOffset) or 0 end
            if data.aimPrecision then
                local p = tonumber(data.aimPrecision)
                if p and p >= 1 and p <= 90 and (360 % math_floor(p) == 0) then
                    aimPrecision = math_floor(p)
                end
            end
            if type(data.monitorModes) == "table" then monitorModes = data.monitorModes end
            if data.radarEnabled ~= nil then radarEnabled = data.radarEnabled end
            if data.deviceMap then
                for k, v in pairs(data.deviceMap) do deviceMap[k] = v end
            end
        end
    end
end

local function saveConfig()
    local config = {}
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then config = data end
    end
    config.yawOffset    = yawOffset
    config.motorOffset  = motorOffset
    config.headingOffset = headingOffset
    config.aimPrecision = aimPrecision
    config.monitorModes = monitorModes
    config.radarEnabled = radarEnabled
    config.deviceMap    = deviceMap
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize(config))
    f.close()
end
loadConfig()

-- ==========================================
-- 注册检查（雷达原版逻辑）
-- ==========================================
local function checkRegistration()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("Radar+ASDIC v3.0.0 - Registration Check")
    term.setTextColor(colors.white)
    print(string.format("My ID: %d", myId))
    print("Querying scanner...")

    -- 在所有GPU上显示检查信息
    for _, name in ipairs(allGpus) do
        local g = peripheral.wrap(name)
        pcall(function()
            g.fill(0x050A05)
            local msg = "CHECKING..."
            local w, h = g.getSize()
            local cx = math_floor(w / 2)
            local ty = math_floor(h / 2) - 8
            pcall(g.drawText, math_max(1, cx - math_floor(#msg * 6)), ty, msg, 0xFFFF00, 0x050A05, 2)
            g.sync()
        end)
    end

    modem.transmit(CHANNEL, CHANNEL, { v=2, t=4, i=myId })

    local timer = os.startTimer(REG_QUERY_TIMEOUT)
    while true do
        local ev, a, b, c, d = os.pullEvent()

        if ev == "modem_message" then
            if b == CHANNEL and type(d) == "table" and d.v == 2 then
                if d.t == 5 and d.ti == myId then
                    os.cancelTimer(timer)
                    myLabel = tostring(d.n or myLabel)
                    MAX_DISTANCE_LIMIT = tonumber(d.r) or MAX_DISTANCE_LIMIT
                    term.setTextColor(colors.lime)
                    print(string.format("Registered!  Name: %s  MaxRange: %.0fm", myLabel, MAX_DISTANCE_LIMIT))
                    sleep(0.8)
                    return true
                elseif d.t == 6 and d.ti == myId then
                    os.cancelTimer(timer)
                    term.setTextColor(colors.red)
                    print("Not registered!")
                    sleep(0.5)
                    return false
                end
            end
        elseif ev == "timer" and a == timer then
            term.setTextColor(colors.orange)
            print("Timeout - scanner not responding.")
            sleep(0.5)
            return false
        end
    end
end

-- ==========================================
-- 未注册显示并停止（雷达原版）
-- ==========================================
local function showNotRegisteredAndHalt()
    -- 在所有GPU上显示未注册信息
    for _, name in ipairs(allGpus) do
        local g = peripheral.wrap(name)
        pcall(function()
            local w, h = g.getSize()
            local cx = math_floor(w / 2)
            local cy = math_floor(h / 2)
            g.fill(0x1A0000)
            local bx1, by1 = math_floor(cx * 0.3), math_floor(cy * 0.5)
            local bx2, by2 = w - bx1, h - by1
            g.line(bx1, by1, bx2, by1, 0xFF2200); g.line(bx1, by2, bx2, by2, 0xFF2200)
            g.line(bx1, by1, bx1, by2, 0xFF2200); g.line(bx2, by1, bx2, by2, 0xFF2200)
            local line1 = "NOT REGISTERED"
            local tx1 = math_max(bx1 + 4, cx - math_floor(#line1 * 6))
            pcall(g.drawText, tx1, cy - 14, line1, 0xFF2200, 0x1A0000, 2)
            local line2 = string.format("ID: %d", myId)
            local tx2 = math_max(bx1 + 4, cx - math_floor(#line2 * 3))
            pcall(g.drawText, tx2, cy + 6, line2, 0xAAAAAA, 0x1A0000, 1)
            local line3 = "Register in scanner"
            local tx3 = math_max(bx1 + 4, cx - math_floor(#line3 * 3))
            pcall(g.drawText, tx3, cy + 18, line3, 0x666666, 0x1A0000, 1)
            g.sync()
        end)
    end

    -- 在所有HUD上显示未注册
    for _, mon in ipairs(allMons) do
        local m = peripheral.wrap(mon)
        pcall(function()
            m.setBackgroundColor(colors.black)
            m.clear()
            local dw, dh = m.getSize()
            local msg1 = "NOT REGISTERED"
            local msg2 = "ID: " .. myId
            local msg3 = "Use scanner to register"
            m.setTextColor(colors.red)
            m.setCursorPos(math_max(1, math_floor((dw - #msg1) / 2) + 1),
                           math_max(1, math_floor(dh / 2) - 1))
            m.write(msg1)
            m.setTextColor(colors.gray)
            m.setCursorPos(math_max(1, math_floor((dw - #msg2) / 2) + 1),
                           math_floor(dh / 2) + 1)
            m.write(msg2)
            m.setTextColor(colors.lightGray)
            m.setCursorPos(math_max(1, math_floor((dw - #msg3) / 2) + 1),
                           math_floor(dh / 2) + 2)
            m.write(msg3)
        end)
    end

    term.setBackgroundColor(colors.black)
    term.clear()
    local tw, th = term.getSize()
    local lines = {
        { "",                         colors.red    },
        { "    NOT REGISTERED    ",   colors.red    },
        { "",                         colors.red    },
        { "",                         colors.white  },
        { "ID: " .. myId,             colors.white  },
        { "Register this unit in",    colors.gray   },
        { "scanner first.",           colors.gray   },
        { "",                         colors.white  },
        { "Program halted.",          colors.orange },
    }
    local startRow = math_max(1, math_floor((th - #lines) / 2))
    for i, line in ipairs(lines) do
        local col = math_max(1, math_floor((tw - #line[1]) / 2) + 1)
        term.setTextColor(line[2])
        term.setCursorPos(col, startRow + i - 1)
        term.write(line[1])
    end

    while true do sleep(60) end
end

-- ==========================================
-- 执行注册校验
-- ==========================================
local isRegistered = checkRegistration()
if not isRegistered then
    showNotRegisteredAndHalt()
    return
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.green)
print("Registration OK. Starting system...")
sleep(0.5)

-- ==========================================
-- 雷达 GPU 绘制函数（完全按照原始雷达 v2.0.0）
-- ==========================================
local function gpuDrawCircle(g, cx, cy, r, color)
    local x, y, d = r, 0, 1 - r
    while x >= y do
        g.line(cx+x,cy+y,cx+x,cy+y,color); g.line(cx-x,cy+y,cx-x,cy+y,color)
        g.line(cx+x,cy-y,cx+x,cy-y,color); g.line(cx-x,cy-y,cx-x,cy-y,color)
        g.line(cx+y,cy+x,cx+y,cy+x,color); g.line(cx-y,cy+x,cx-y,cy+x,color)
        g.line(cx+y,cy-x,cx+y,cy-x,color); g.line(cx-y,cy-x,cx-y,cy-x,color)
        y = y + 1
        if d < 0 then d = d + 2*y + 1
        else x = x - 1; d = d + 2*(y-x) + 1 end
    end
end
local function gpuFillRect(g, x, y, w, h, color)
    for dy = 0, h-1 do g.line(x, y+dy, x+w-1, y+dy, color) end
end
local function gpuDrawIffCorners(g, W, H)
    local col = (iffMode == "friendly") and 0x004400 or 0x660000
    local L_LEN = 14; local L_THICK = 2
    local function drawCornerL(ox, oy, hx, hy, vx, vy)
        for t = 0, L_THICK - 1 do
            local ax0 = ox + vx * t; local ay0 = oy + vy * t
            g.line(ax0, ay0, ax0 + hx * (L_LEN - 1), ay0 + hy * (L_LEN - 1), col)
            local bx0 = ox + hx * t; local by0 = oy + hy * t
            g.line(bx0, by0, bx0 + vx * (L_LEN - 1), by0 + vy * (L_LEN - 1), col)
        end
    end
    drawCornerL(1, 1, 1, 0, 0, 1); drawCornerL(W, 1, -1, 0, 0, 1)
    drawCornerL(1, H, 1, 0, 0, -1); drawCornerL(W, H, -1, 0, 0, -1)
end
local function drawRadarBase(entry)
    local g = entry.gpu; local cx = entry.cx; local cy = entry.cy; local r = entry.r
    g.fill(0x050A05)
    -- 外圈
    gpuDrawCircle(g, cx, cy, r, 0x00CC44)
    -- 内圈
    gpuDrawCircle(g, cx, cy, math_floor(r / 2), 0x007722)
    -- 十字线
    g.line(cx, cy - r, cx, cy + r, 0x005518); g.line(cx - r, cy, cx + r, cy, 0x005518)
    -- 网格点
    for t = -r, r do
        if t % 4 < 2 then
            local py = cy + t
            local px1 = cx + t
            if (px1 - cx)^2 + (py - cy)^2 <= r * r then g.line(px1, py, px1, py, 0x005518) end
            local px2 = cx - t
            if (px2 - cx)^2 + (py - cy)^2 <= r * r then g.line(px2, py, px2, py, 0x005518) end
        end
    end
    -- N 标记
    local northRad = math_rad(currentNorthYawDeg + yawOffset)
    local nx = cx + math_floor(r * math_sin(northRad) + 0.5)
    local ny = cy - math_floor(r * math_cos(northRad) + 0.5)
    local tX = math_max(1, math_min(entry.w - 6, nx - 3))
    local tY = math_max(1, math_min(entry.h - 8, ny - 4))
    pcall(g.drawText, tX, tY, "N", 0xFFFF00, 0x050A05, 1)
end
local function drawRadarSweep(entry, angleDeg)
    local g = entry.gpu; local cx = entry.cx; local cy = entry.cy; local r = entry.r
    local rad = math_rad(angleDeg + yawOffset)
    local ex = cx + math_floor(r * math_sin(rad) + 0.5)
    local ey = cy - math_floor(r * math_cos(rad) + 0.5)
    g.line(cx, cy, ex, ey, 0x00FF66)   -- 绿色，无箭头
end
local function drawRadarRWR(entry)
    local g = entry.gpu; local cx = entry.cx; local cy = entry.cy; local r = entry.r
    local now = os_clock()
    local ARC_R_INNER = r + 3; local ARC_R_OUTER = r + 5
    for i = #rwrEvents, 1, -1 do
        if now - rwrEvents[i].time >= RWR_ARC_DURATION then
            table.remove(rwrEvents, i)
        end
    end
    for _, ev in ipairs(rwrEvents) do
        local age = now - ev.time
        local col = colorLerp(0xFFCC00, 0x000000, age / RWR_ARC_DURATION)
        if col ~= 0x000000 then
            local centerRad = math_rad(ev.yawDeg + yawOffset)
            local halfSpan = math_rad(22.5); local ARC_STEP = math_rad(0.5)
            local steps = math_floor(math_rad(45) / ARC_STEP) + 1
            for arcR = ARC_R_INNER, ARC_R_OUTER do
                for s = 0, steps do
                    local a = centerRad - halfSpan + ARC_STEP * s
                    local px = cx + math_floor(arcR * math_sin(a) + 0.5)
                    local py = cy - math_floor(arcR * math_cos(a) + 0.5)
                    if px >= 1 and px <= entry.w and py >= 1 and py <= entry.h then
                        g.line(px, py, px, py, col)
                    end
                end
            end
        end
    end
end
local function refreshRadar(entry, isActive, poolCount, pool)
    local g = entry.gpu; local cx = entry.cx; local cy = entry.cy
    local r = entry.r; local ds = entry.dotSize; local half = math_floor(ds / 2)
    drawRadarBase(entry)
    drawRadarRWR(entry)
    if isActive and localPos then
        for i = 1, poolCount do
            local t = pool[i]
            if t.col and t.col ~= 0x000000 then
                local dr = r * t.r
                local px = cx + math_floor(dr * t.s + 0.5)
                local py = cy - math_floor(dr * t.cs + 0.5)
                if (px - cx)^2 + (py - cy)^2 <= r * r then
                    gpuFillRect(g, px - half, py - half, ds, ds, t.col)
                end
            end
        end
    end
    if isActive then drawRadarSweep(entry, currentServoAngle) end
    gpuDrawIffCorners(g, entry.w, entry.h)
    g.sync()
end

-- ==========================================
-- 声纳 GPU 绘制函数（固定扇形，圆点淡出）
-- ==========================================
local function drawAsdicSector(entry)
    local g = entry.gpu; local cx = entry.cx; local cy = entry.cy; local r = entry.r
    g.fill(0x050A05)

    local leftAngle = -ASDIC_SCAN_SECTOR_HALF
    local rightAngle = ASDIC_SCAN_SECTOR_HALF
    local lx = cx + math_floor(r * math_sin(math_rad(leftAngle)))
    local ly = cy - math_floor(r * math_cos(math_rad(leftAngle)))
    local rx = cx + math_floor(r * math_sin(math_rad(rightAngle)))
    local ry = cy - math_floor(r * math_cos(math_rad(rightAngle)))
    g.line(cx, cy, lx, ly, 0x00CC44)
    g.line(cx, cy, rx, ry, 0x00CC44)

    local step = 2
    for a = leftAngle, rightAngle, step do
        local x1 = cx + math_floor(r * math_sin(math_rad(a)))
        local y1 = cy - math_floor(r * math_cos(math_rad(a)))
        local x2 = cx + math_floor(r * math_sin(math_rad(a + step)))
        local y2 = cy - math_floor(r * math_cos(math_rad(a + step)))
        g.line(x1, y1, x2, y2, 0x00CC44)
    end

    local r2 = math_floor(r / 2)
    for a = leftAngle, rightAngle, step do
        local x1 = cx + math_floor(r2 * math_sin(math_rad(a)))
        local y1 = cy - math_floor(r2 * math_cos(math_rad(a)))
        local x2 = cx + math_floor(r2 * math_sin(math_rad(a + step)))
        local y2 = cy - math_floor(r2 * math_cos(math_rad(a + step)))
        g.line(x1, y1, x2, y2, 0x007722)
    end

    g.line(cx, cy, cx, cy - r, 0x005518)

    -- 45度虚线刻度
    for deg = -90, 90, 45 do
        local rad = math_rad(deg)
        local ex = cx + math_floor(r * math_sin(rad))
        local ey = cy - math_floor(r * math_cos(rad))
        local dx = ex - cx; local dy = ey - cy
        local steps = math_max(1, math_floor(math_sqrt(dx*dx + dy*dy) / 3))
        for i = 0, steps do
            if i % 2 == 0 then
                local px = cx + math_floor(dx * i / steps)
                local py = cy + math_floor(dy * i / steps)
                g.line(px, py, px, py, 0x004400)
            end
        end
    end

    -- 外圈字母（基于摄像头航向 + headingOffset）
    local effectiveHeading = (currentNorthYawDeg + headingOffset) % 360
    local dirs = {
        {angle=0,   label="N"},
        {angle=90,  label="E"},
        {angle=180, label="S"},
        {angle=270, label="W"},
    }
    for _, d in ipairs(dirs) do
        local screenAngle = math_rad(d.angle - effectiveHeading)
        local tx = cx + math_floor((r + 5) * math_sin(screenAngle)) - 3
        local ty = cy - math_floor((r + 5) * math_cos(screenAngle)) - 4
        tx = math_max(1, math_min(entry.w - 6, tx))
        ty = math_max(1, math_min(entry.h - 8, ty))
        pcall(g.drawText, tx, ty, d.label, 0xFFFFFF, 0x050A05, 1)
    end
end
local function refreshAsdic(entry, isActive, poolCount, pool)
    local g = entry.gpu
    if not isActive then
        g.fill(0x050A05)
        g.sync()
        return
    end
    drawAsdicSector(entry)
    local r = entry.r; local cx = entry.cx; local cy = entry.cy
    for i = 1, poolCount do
        local t = pool[i]
        if t and t.col and t.col ~= 0x000000 then
            local px = cx + math_floor(r * t.distRatio * t.s + 0.5)
            local py = cy - math_floor(r * t.distRatio * t.cs + 0.5)
            g.line(px, py, px, py, t.col)
        end
    end
    local rad = math_rad(asdicScanAngle)
    local ex = cx + math_floor(r * math_sin(rad))
    local ey = cy - math_floor(r * math_cos(rad))
    g.line(cx, cy, ex, ey, 0x00FF66)
    g.sync()
end

-- ==========================================
-- 雷达 HUD 绘制（完全原版风格）
-- ==========================================
local function drawRadarHUD()
    if not radarHud then return end
    local m = radarHud
    m.setTextScale(1)
    m.setBackgroundColor(colors.black)
    m.clear()
    local dw, dh = m.getSize()
    local isActive = (currentRadarRange > 0) and isServoConnected and radarEnabled
    local sText, sColor = "OFFLINE", colors.red
    if isActive then sText, sColor = "ACTIVE", colors.green end
    local rText = string.format("%dm", math_floor(currentRadarRange))
    local lText, lColor = "SCAN", colors.lightGray
    local dText = "---"
    if selectedTargetId and targets[selectedTargetId] then
        local sel = targets[selectedTargetId]
        if sel.iff == "friendly" then lText = "ALLY"; lColor = colors.green
        elseif sel.iff == "enemy" then lText = "ENEMY"; lColor = colors.red
        else lText = "LOCKED"; lColor = colors.yellow end
        dText = selectedTargetDistStr or "---"
    end
    local function cprint(y, text, col)
        m.setTextColor(col)
        m.setCursorPos(math_max(1, math_floor((dw - #text) / 2) + 1), y)
        m.write(text)
    end
    cprint(math_floor(dh/2) - 3, sText, sColor)
    cprint(math_floor(dh/2) - 1, rText, colors.lime)
    cprint(math_floor(dh/2) + 1, lText, lColor)
    cprint(math_floor(dh/2) + 3, dText, colors.white)
end

-- ==========================================
-- 声纳 HUD 绘制
-- ==========================================
local function drawAsdicHUD()
    if not asdicHud then return end
    local m = asdicHud
    m.setTextScale(1)
    m.setBackgroundColor(colors.black)
    m.clear()
    local dw, dh = m.getSize()
    local line1 = isAsdicActive and "ASDIC online" or "ASDIC offline"
    local col1 = isAsdicActive and colors.green or colors.red
    local line2 = string.format("Range: %d - %d m", ASDIC_MIN_DISTANCE, ASDIC_MAX_DISTANCE)
    local line3 = "Depth: --- m  /  Dist: --- m"
    if selectedTargetId and targets[selectedTargetId] then
        local t = targets[selectedTargetId]
        if t.realPos then
            line3 = string.format("Depth: %.0f m  /  Dist: %.0f m", SEA_LEVEL - t.realPos.y, t.realDist or 0)
        end
    end
    local function cprint(y, text, col)
        m.setTextColor(col)
        m.setCursorPos(math_max(1, math_floor((dw - #text) / 2) + 1), y)
        m.write(text)
    end
    cprint(math_floor(dh/2) - 2, line1, col1)
    cprint(math_floor(dh/2), line2, colors.yellow)
    cprint(math_floor(dh/2) + 2, line3, colors.white)
end

-- ==========================================
-- 终端 UI 三页（参数可编辑，设备可分配）
-- ==========================================
local function termUI()
    while true do
        term.setBackgroundColor(colors.black)
        term.clear()
        local w, h = term.getSize()
        local tabs = {"PARAMS", "STATUS", "DEVICES"}
        local tabStr = ""
        for i, t in ipairs(tabs) do
            tabStr = tabStr .. (i == currentScreenTab and ("["..t.."]") or " "..t.." ") .. "  "
        end
        term.setCursorPos(2, 1); term.setTextColor(colors.white)
        term.write("TAB " .. tabStr)

        if currentScreenTab == 1 then
            -- 参数页
            term.setCursorPos(2, 3); term.setTextColor(colors.yellow)
            term.write("=== PARAMETERS ===")
            local function drawInputBox(y, label, val, isSel, isEdit)
                term.setCursorPos(2, y); term.setBackgroundColor(colors.black)
                term.setTextColor(isSel and colors.yellow or colors.lightGray)
                term.write(label)
                term.setCursorPos(17, y); term.setBackgroundColor(colors.gray)
                local txt = (isSel and isEdit) and (inputStr .. "_") or tostring(val)
                term.setTextColor(isSel and colors.white or colors.lightGray)
                term.write(string.format(" %-12s ", txt))
                term.setBackgroundColor(colors.black)
            end
            drawInputBox(5,  "Radar Enable :", radarEnabled and "yes" or "no", menuIndex == 1, isEditing)
            drawInputBox(7,  "Disp. Offset :", yawOffset,    menuIndex == 2, isEditing)
            drawInputBox(9,  "Motor Offset :", motorOffset,  menuIndex == 3, isEditing)
            drawInputBox(11, "Aim Precis   :", aimPrecision, menuIndex == 4, isEditing)
            drawInputBox(13, "Heading Off  :", headingOffset, menuIndex == 5, isEditing)
            drawInputBox(15, "Scan Speed   :", string.format("%.1f deg/s", ASDIC_SCAN_ANGULAR_SPEED), menuIndex == 6, isEditing)
            drawInputBox(17, "Broadcast Pos:", broadcastOwnPos and "yes" or "no", menuIndex == 7, isEditing)

        elseif currentScreenTab == 2 then
            -- 状态页
            term.setCursorPos(2, 3); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            local row = 5
            term.setCursorPos(2, row); term.setTextColor(colors.lime)
            term.write("Registered : " .. myLabel); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.cyan)
            term.write(string.format("Max Range  : %.0f m", MAX_DISTANCE_LIMIT)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.lightGray)
            term.write(string.format("SU Ratio   : %g SU/m", STRESS_TO_DISTANCE_RATIO)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.green)
            term.write("Camera     : ONLINE"); row = row + 1
            row = row + 1
            if isServoConnected then
                term.setCursorPos(2, row); term.setTextColor(colors.white)
                term.write(string.format("Motor Angle: %6.1f deg", currentServoAngle)); row = row + 1
            else
                term.setCursorPos(2, row); term.setTextColor(colors.red)
                term.write("Motor Angle: OFFLINE"); row = row + 1
            end
            if currentRadarRange == 0 then
                term.setCursorPos(2, row); term.setTextColor(colors.red)
                term.write("Op. Range  : 0.0 (No Power!)"); row = row + 1
            elseif not isServoConnected then
                term.setCursorPos(2, row); term.setTextColor(colors.red)
                term.write("Op. Range  : 0.0 (No Motor!)"); row = row + 1
            else
                term.setCursorPos(2, row); term.setTextColor(colors.green)
                term.write(string.format("Op. Range  : %.1f m", currentRadarRange)); row = row + 1
            end
            term.setCursorPos(2, row); term.setTextColor(colors.gray)
            term.write(string.format("North Yaw  : %.1f deg", currentNorthYawDeg)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.gray)
            term.write(string.format("Heading Eff: %.1f deg", (currentNorthYawDeg + headingOffset) % 360)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.gray)
            term.write(string.format("Aim grid   : %d deg/step", aimPrecision)); row = row + 1
            local beaconCount = 0
            for _, d in pairs(targets) do if d.isBeacon then beaconCount = beaconCount + 1 end end
            term.setCursorPos(2, row); term.setTextColor(colors.yellow)
            term.write(string.format("Beacons    : %d online", beaconCount)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.white)
            term.write(string.format("IFF Mode   : %s", iffMode == "friendly" and "FRIENDLY" or "ENEMY")); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.white)
            term.write(string.format("ASDIC Active: %s", isAsdicActive and "YES" or "NO")); row = row + 1
            local tgtCount = 0
            for _ in pairs(targets) do tgtCount = tgtCount + 1 end
            term.setCursorPos(2, row); term.setTextColor(colors.lightGray)
            term.write(string.format("Targets     : %d", tgtCount))

        else
            -- 设备页：显示所有GPU和HUD，并允许修改分配
            term.setCursorPos(2, 3); term.setTextColor(colors.yellow)
            term.write("=== DEVICES (Enter to change role) ===")
            local row = 5
            term.setCursorPos(2, row); term.setTextColor(colors.cyan)
            term.write("-- GPUs --"); row = row + 1
            if #allGpus == 0 then
                term.setCursorPos(4, row); term.setTextColor(colors.red)
                term.write("None"); row = row + 1
            else
                for idx, name in ipairs(allGpus) do
                    local role = deviceMap[name] or "none"
                    local label = ROLE_LABELS[role] or role
                    local isSel = (menuIndex == 100 + idx) -- 设备页的菜单索引从101开始
                    term.setCursorPos(4, row); term.setTextColor(isSel and colors.yellow or colors.lightBlue)
                    term.write(string.format("%s  [%s]", name, label))
                    if isSel then
                        term.setCursorPos(4 + #name + 2, row)
                        term.write("<")  -- 选中指示
                    end
                    row = row + 1
                end
            end
            row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.cyan)
            term.write("-- Monitors --"); row = row + 1
            if #allMons == 0 then
                term.setCursorPos(4, row); term.setTextColor(colors.red)
                term.write("None"); row = row + 1
            else
                for idx, name in ipairs(allMons) do
                    local role = deviceMap[name] or "none"
                    local label = ROLE_LABELS[role] or role
                    local isSel = (menuIndex == 200 + idx)
                    term.setCursorPos(4, row); term.setTextColor(isSel and colors.yellow or colors.lightBlue)
                    term.write(string.format("%s  [%s]", name, label))
                    if isSel then
                        term.setCursorPos(4 + #name + 2, row)
                        term.write("<")
                    end
                    row = row + 1
                end
            end
            row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.gray)
            term.write("Use UP/DOWN to select, ENTER to cycle role")
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 输入事件循环（参数编辑、设备分配、触摸交互）
-- ==========================================
local function inputLoop()
    local function applySave()
        if currentScreenTab == 1 then
            if menuIndex == 1 then
                if inputStr == "yes" then radarEnabled = true
                elseif inputStr == "no" then radarEnabled = false end
            elseif menuIndex == 2 then
                local p = tonumber(inputStr); if p then yawOffset = p end
            elseif menuIndex == 3 then
                local p = tonumber(inputStr); if p then motorOffset = p end
            elseif menuIndex == 4 then
                local p = tonumber(inputStr)
                if p then
                    p = math_floor(math_abs(p))
                    if p >= 1 and p <= 90 and (360 % p == 0) then aimPrecision = p end
                end
            elseif menuIndex == 5 then
                local p = tonumber(inputStr); if p then headingOffset = p end
            elseif menuIndex == 6 then
                local p = tonumber(inputStr); if p and p > 0 then ASDIC_SCAN_ANGULAR_SPEED = p end
            elseif menuIndex == 7 then
                if inputStr == "yes" then broadcastOwnPos = true
                elseif inputStr == "no" then broadcastOwnPos = false end
            end
            saveConfig()
        end
        isEditing = false
    end

    -- 设备页菜单索引范围：100+GPU索引，200+Monitor索引
    local function cycleDeviceRole(devName, isGpu)
        local currentRole = deviceMap[devName] or "none"
        local roles = isGpu and {"none", "radarGpu", "asdicGpu"} or {"none", "radarHud", "asdicHud"}
        local currentIdx = 1
        for i, r in ipairs(roles) do
            if r == currentRole then currentIdx = i; break end
        end
        local newRole = roles[currentIdx % #roles + 1]
        deviceMap[devName] = newRole
        saveDeviceMap()
        applyDeviceMap()  -- 立即应用新分配
    end

    while true do
        local event, p1, p2, p3 = os_pullEvent()

        if event == "key" then
            if p1 == keys.tab then
                currentScreenTab = (currentScreenTab % 3) + 1
                menuIndex = 1  -- 切换页面时重置菜单索引
            elseif isEditing and currentScreenTab == 1 then
                if p1 == keys.enter or p1 == keys.numPadEnter then
                    applySave()
                elseif p1 == keys.backspace then
                    inputStr = inputStr:sub(1, -2)
                end
            elseif currentScreenTab == 1 then
                -- 参数页上下键
                if p1 == keys.up then menuIndex = math_max(1, menuIndex - 1)
                elseif p1 == keys.down then menuIndex = math_min(7, menuIndex + 1)
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    isEditing = true
                    if menuIndex == 1 then inputStr = radarEnabled and "yes" or "no"
                    elseif menuIndex == 2 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 3 then inputStr = tostring(motorOffset)
                    elseif menuIndex == 4 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 5 then inputStr = tostring(headingOffset)
                    elseif menuIndex == 6 then inputStr = tostring(ASDIC_SCAN_ANGULAR_SPEED)
                    elseif menuIndex == 7 then inputStr = broadcastOwnPos and "yes" or "no"
                    end
                end
            elseif currentScreenTab == 3 then
                -- 设备页上下键
                local totalItems = #allGpus + #allMons
                if p1 == keys.up then
                    menuIndex = math_max(101, menuIndex - 1)
                elseif p1 == keys.down then
                    menuIndex = math_min(200 + #allMons, menuIndex + 1)
                    -- 确保不会停在GPU和Monitor之间的空隙
                    if menuIndex > 100 + #allGpus and menuIndex < 200 then
                        menuIndex = 200
                    end
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    if menuIndex >= 101 and menuIndex <= 100 + #allGpus then
                        local gpuIdx = menuIndex - 100
                        local devName = allGpus[gpuIdx]
                        cycleDeviceRole(devName, true)
                    elseif menuIndex >= 200 and menuIndex <= 200 + #allMons then
                        local monIdx = menuIndex - 200
                        local devName = allMons[monIdx]
                        cycleDeviceRole(devName, false)
                    end
                end
                -- 初始化设备页的menuIndex
                if menuIndex < 101 then menuIndex = 101 end
                if menuIndex > 200 + #allMons then menuIndex = 200 + #allMons end
                if #allGpus == 0 and menuIndex < 200 then menuIndex = 200 end
                if #allMons == 0 and menuIndex > 100 + #allGpus then menuIndex = 100 + #allGpus end
            end
        elseif event == "char" and isEditing and currentScreenTab == 1 then
            if menuIndex == 1 or menuIndex == 7 then
                if #inputStr < 3 then inputStr = inputStr .. p1 end
            else
                if (p1 >= '0' and p1 <= '9') or p1 == '.' or (p1 == '-' and #inputStr == 0) then
                    if #inputStr < 8 then inputStr = inputStr .. p1 end
                end
            end
        elseif event == "mouse_click" then
            local touchY = p3
            if currentScreenTab == 1 then
                local ti = nil
                if touchY == 5 then ti = 1
                elseif touchY == 7 then ti = 2
                elseif touchY == 9 then ti = 3
                elseif touchY == 11 then ti = 4
                elseif touchY == 13 then ti = 5
                elseif touchY == 15 then ti = 6
                elseif touchY == 17 then ti = 7
                end
                if ti then
                    if isEditing and menuIndex ~= ti then applySave() end
                    menuIndex = ti
                    isEditing = true
                    if menuIndex == 1 then inputStr = radarEnabled and "yes" or "no"
                    elseif menuIndex == 2 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 3 then inputStr = tostring(motorOffset)
                    elseif menuIndex == 4 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 5 then inputStr = tostring(headingOffset)
                    elseif menuIndex == 6 then inputStr = tostring(ASDIC_SCAN_ANGULAR_SPEED)
                    elseif menuIndex == 7 then inputStr = broadcastOwnPos and "yes" or "no"
                    end
                else
                    if isEditing then applySave() end
                end
            elseif currentScreenTab == 3 then
                -- 设备页点击
                if touchY >= 6 and touchY < 6 + #allGpus then
                    local idx = touchY - 5
                    if idx > 0 and idx <= #allGpus then
                        menuIndex = 100 + idx
                        cycleDeviceRole(allGpus[idx], true)
                    end
                elseif touchY >= 6 + #allGpus + 2 and touchY < 6 + #allGpus + 2 + #allMons then
                    local idx = touchY - (6 + #allGpus + 1)
                    if idx > 0 and idx <= #allMons then
                        menuIndex = 200 + idx
                        cycleDeviceRole(allMons[idx], false)
                    end
                end
            end
        elseif (event == "tm_monitor_touch" or event == "tm_monitor_mouse_click") and currentScreenTab <= 2 then
            local touchedName = p1
            local mx, my = p2, p3
            -- 雷达触摸交互
            if radarGpu and peripheral.getName(radarGpu) == touchedName and localPos and currentRadarRange > 0 and radarEnabled and isServoConnected then
                local w, h = radarGpu.getSize()
                local cx, cy = math_floor(w / 2), math_floor(h / 2)
                local r = math_floor(math_min(cx, cy) * 0.88)
                local distFromCenter = math_sqrt((mx - cx)^2 + (my - cy)^2)
                if distFromCenter < 5 or distFromCenter > r + 10 then
                    selectedTargetId = nil
                else
                    local bestId = nil
                    local bestDist = 99999
                    for _, data in pairs(targets) do
                        if data.lastPaintedRadar and not data.isBeacon and data.source == 8888 then
                            local yawRad = math_rad(data.paintedYaw + yawOffset)
                            local ex = cx + math_floor(r * 0.75 * math_sin(yawRad) + 0.5)
                            local ey = cy - math_floor(r * 0.75 * math_cos(yawRad) + 0.5)
                            local angleToTarget = math_atan2(mx - cx, -(my - cy))
                            local targetAngle = math_atan2(ex - cx, -(ey - cy))
                            local angleDiff = math_abs(getAngleDiff(math_deg(angleToTarget), math_deg(targetAngle)))
                            if angleDiff < 5 then
                                local d2 = (mx - ex)^2 + (my - ey)^2
                                if d2 < bestDist then
                                    bestDist = d2
                                    bestId = data.id
                                end
                            end
                        end
                    end
                    if bestId then
                        if iffMode == "friendly" then
                            targets[bestId].iff = "friendly"
                        else
                            for id, data in pairs(targets) do
                                if id ~= bestId and data.iff == "enemy" then data.iff = nil end
                            end
                            targets[bestId].iff = "enemy"
                            selectedTargetId = bestId
                        end
                    else
                        selectedTargetId = nil
                    end
                end
            -- 声纳触摸交互
            elseif asdicGpu and peripheral.getName(asdicGpu) == touchedName and localPos and isAsdicActive then
                local w, h = asdicGpu.getSize()
                local cx, cy = math_floor(w / 2), math_floor(h / 2)
                local r = math_floor(math_min(cx, cy) * 0.88)
                local distFromCenter = math_sqrt((mx - cx)^2 + (my - cy)^2)
                if distFromCenter < 5 or distFromCenter > r + 10 then
                    selectedTargetId = nil
                else
                    local bestId = nil
                    local bestDist = 99999
                    for _, data in pairs(targets) do
                        if data.lastPaintedAsdic and not data.isBeacon and data.source == 8889 then
                            local relBearing = data.paintedYaw  -- 相对船首
                            local screenRad = math_rad(relBearing)
                            local distRatio = math_min(data.realDist / ASDIC_MAX_DISTANCE, 1.0)
                            local ex = cx + math_floor(r * distRatio * math_sin(screenRad) + 0.5)
                            local ey = cy - math_floor(r * distRatio * math_cos(screenRad) + 0.5)
                            local d2 = (mx - ex)^2 + (my - ey)^2
                            if d2 < bestDist then
                                bestDist = d2
                                bestId = data.id
                            end
                        end
                    end
                    if bestId then
                        selectedTargetId = bestId
                    else
                        selectedTargetId = nil
                    end
                end
            end
        elseif event == "redstone" then
            local back = redstone.getInput("back")
            if back then
                iffMode = (iffMode == "enemy") and "friendly" or "enemy"
            end
        end
    end
end

-- ==========================================
-- 网络循环（雷达 8888 + 主动声纳 8889）
-- ==========================================
local function pingLoop()
    while true do
        if currentScreenTab == 3 then sleep(0.5) else
            if localPos then
                modem.transmit(CHANNEL, CHANNEL, {
                    v = 2, t = 1, i = myId, n = myLabel, r = currentRadarRange,
                    x = math_floor(localPos.x * 10) / 10,
                    y = math_floor(localPos.y * 10) / 10,
                    z = math_floor(localPos.z * 10) / 10,
                })
            end
            local now = os_clock()
            for id, data in pairs(targets) do
                if not data.isBeacon and id ~= selectedTargetId and data.lastSeen and (now - data.lastSeen > 10) then
                    targets[id] = nil
                end
            end
            sleep(1.0)
        end
    end
end

local function listenLoop()
    while true do
        local _, _, ch, _, msg = os_pullEvent("modem_message")
        if ch == CHANNEL and type(msg) == "table" and msg.v == 2 and msg.i ~= myId then
            if msg.t == 1 then
                local id = msg.i
                if not targets[id] then targets[id] = {id = id, source = 8888} end
                local t = targets[id]
                t.source = 8888
                t.name = msg.n; t.modemDist = nil
                if msg.x then t.realPos = {x = msg.x, y = msg.y, z = msg.z} end
                t.range = msg.r; t.lastSeen = os_clock(); t.isBeacon = false
                if localPos and t.realPos then t.realDist = calcRangingDist(localPos, t.realPos) end
            elseif msg.t == 2 and msg.ti == myId then
                local rwrYaw = nil
                if msg.x and msg.y and msg.z and localPos then
                    local sp = {x = msg.x, y = msg.y, z = msg.z}
                    if currentQAbs and currentQLoc then
                        local iqx,iqy,iqz,iqw = quatInverse(currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                        local dx = sp.x - localPos.x
                        local dy = sp.y - localPos.y
                        local dz = sp.z - localPos.z
                        local hx,hy,hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                        local sx,sy,sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                        rwrYaw = math_deg(math_atan2(-sx, sz))
                    else
                        _, rwrYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z, sp.x, sp.y, sp.z)
                    end
                end
                if rwrYaw then
                    local normYaw = rwrYaw % 360
                    local sectorIdx = math_floor((normYaw + 22.5) / 45) % 8
                    local quantYaw = sectorIdx * 45
                    if quantYaw > 180 then quantYaw = quantYaw - 360 end
                    table.insert(rwrEvents, {yawDeg = quantYaw, time = os_clock()})
                    redstone.setOutput("front", true)
                    os.startTimer(0.5)
                end
            end
        elseif ch == ACTIVE_SONAR_CHANNEL and type(msg) == "table" and msg.v == 2 and msg.t == 1 then
            local id = msg.i
            if not targets[id] then targets[id] = {id = id, source = 8889} end
            local t = targets[id]
            t.source = 8889
            t.name = msg.n
            if msg.x then t.realPos = {x = msg.x, y = msg.y, z = msg.z} end
            t.lastSeen = os_clock(); t.isBeacon = false
            if localPos and t.realPos then t.realDist = calcRangingDist(localPos, t.realPos) end
        end
    end
end

-- ==========================================
-- 红石脉冲关闭
-- ==========================================
local function rwrRedstoneLoop()
    while true do
        local ev, id = os.pullEvent("timer")
        redstone.setOutput("front", false)
    end
end

-- ==========================================
-- 主传感器循环（雷达 + 主动声纳）
-- ==========================================
local function sensorLoop()
    local lastServoAngle = nil
    local asdicScanStart = os_clock()
    while true do
        if currentScreenTab == 3 then sleep(0.5) else
            -- 应力读取
            if cachedStressometer then
                local ok, cap = pcall(cachedStressometer.getStressCapacity)
                if ok then currentStressCapacity = cap or 0
                else cachedStressometer = nil; currentStressCapacity = 0 end
            end

            -- 伺服电机读取
            if cachedServo then
                local ok, ang = pcall(cachedServo.getAngle)
                if ok and type(ang) == "number" then
                    isServoConnected = true
                    currentServoAngle = (math_deg(ang) + motorOffset) % 360
                else
                    isServoConnected = false; cachedServo = nil
                end
            else isServoConnected = false end

            -- 雷达有效距离（动态深度限制）
            local depthDynamicMax = MAX_DISTANCE_LIMIT
            if localPos then
                if localPos.y >= SEA_LEVEL then depthDynamicMax = 1000
                elseif localPos.y <= -14 then depthDynamicMax = 5000
                else depthDynamicMax = 1000 + 400 * (-localPos.y - 4) end
            end
            currentRadarRange = math_min(currentStressCapacity / STRESS_TO_DISTANCE_RATIO, depthDynamicMax)

            -- 声纳激活条件
            isAsdicActive = (currentStressCapacity >= ASDIC_STRESS_THRESHOLD)

            -- 摄像头获取位置和航向
            if camera then
                local ok, pos = pcall(camera.getCameraPosition)
                if ok and pos then localPos = pos else localPos = nil end

                pcall(function()
                    currentQAbs = camera.getAbsViewTransform()
                    currentQLoc = camera.getLocViewTransform()
                end)
                if currentQAbs and currentQLoc then
                    local iqx,iqy,iqz,iqw = quatInverse(currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                    local hx,hy,hz = rotateVectorFast(0,0,-1,iqx,iqy,iqz,iqw)
                    local sx,sy,sz = rotateVectorFast(hx,hy,hz, currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                    currentNorthYawDeg = (math_deg(math_atan2(-sx,sz)) + 180) % 360
                end
            end

            local now = os_clock()
            -- 更新所有目标距离
            for _, t in pairs(targets) do
                if t.realPos and localPos then
                    t.realDist = calcRangingDist(localPos, t.realPos)
                end
            end

            -- 雷达目标池构建（仅8888频道，无速度过滤）
            radarPoolCount = 0
            if radarEnabled and currentRadarRange > 0 and isServoConnected and localPos then
                local deltaAngle = lastServoAngle and math_abs(getAngleDiff(currentServoAngle, lastServoAngle)) or 0
                local effectiveSW = SCAN_SECTOR_WIDTH + deltaAngle
                for id, t in pairs(targets) do
                    if t.source == 8888 and t.realPos and t.realDist and t.realDist <= currentRadarRange and not t.isBeacon and t.lastSeen and (now - t.lastSeen < 3.0) then
                        local tYaw
                        if currentQAbs and currentQLoc then
                            local iqx,iqy,iqz,iqw = quatInverse(currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                            local dx = t.realPos.x - localPos.x
                            local dz = t.realPos.z - localPos.z
                            local hx,hy,hz = rotateVectorFast(dx, 0, dz, iqx,iqy,iqz,iqw)
                            local sx,sy,sz = rotateVectorFast(hx,hy,hz, currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                            tYaw = math_deg(math_atan2(-sx,sz))
                        else
                            _,tYaw = calculateLookAngles(localPos.x,localPos.y,localPos.z, t.realPos.x,t.realPos.y,t.realPos.z)
                        end
                        if math_abs(getAngleDiff(tYaw, currentServoAngle)) <= effectiveSW / 2 then
                            if not t.lastPaintedRadar or (now - t.lastPaintedRadar >= 0.5) then
                                t.paintedYaw = tYaw
                                t.paintedDist = t.realDist
                                t.lastPaintedRadar = now
                                -- 雷达锁定告警（类型2）
                                if selectedTargetId == t.id and t.iff == "enemy" then
                                    modem.transmit(CHANNEL, CHANNEL, {v=2, t=2, si=myId, ti=id, x=localPos.x, y=localPos.y, z=localPos.z})
                                end
                            end
                            -- 计算颜色（IFF区分）
                            local hotColor
                            if t.iff == "friendly" then hotColor = 0x44FFAA
                            elseif t.iff == "enemy" then hotColor = 0xFF6600
                            else hotColor = 0xEEEEEE end
                            local age = now - t.lastPaintedRadar
                            local col = calcFadeColor(age, hotColor)
                            if col and col ~= 0x000000 then
                                local yawRad = math_rad(tYaw + yawOffset)
                                local distRatio = math_min(t.paintedDist / currentRadarRange, 1.0)
                                radarPoolCount = radarPoolCount + 1
                                local p = radarPool[radarPoolCount]
                                if not p then p = {}; radarPool[radarPoolCount] = p end
                                p.col = col
                                p.r = distRatio
                                p.s = math_sin(yawRad)
                                p.cs = math_cos(yawRad)
                            end
                        end
                    end
                end
            end
            lastServoAngle = currentServoAngle

            -- 摄像头跟踪（雷达锁定目标）
            if radarEnabled and selectedTargetId and targets[selectedTargetId] then
                local t = targets[selectedTargetId]
                if t.realDist and t.realDist <= currentRadarRange and t.lastSeen and (now - t.lastSeen < 3.0) then
                    local tPitch, tYaw
                    if currentQAbs and currentQLoc then
                        local iqx,iqy,iqz,iqw = quatInverse(currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                        local dx = t.realPos.x - localPos.x
                        local dy = t.realPos.y - localPos.y
                        local dz = t.realPos.z - localPos.z
                        local hx,hy,hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                        local sx,sy,sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                        tYaw = math_deg(math_atan2(-sx, sz))
                        tPitch = math_deg(math_atan2(-sy, math_sqrt(sx*sx + sz*sz)))
                    else
                        tPitch, tYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z, t.realPos.x, t.realPos.y, t.realPos.z)
                    end
                    local snappedYaw = math_floor((tYaw % 360) / aimPrecision) * aimPrecision + (aimPrecision / 2)
                    if snappedYaw > 180 then snappedYaw = snappedYaw - 360 end
                    holdPitch, holdYaw = tPitch, snappedYaw
                    pcall(applyCameraAngle, tPitch, snappedYaw)
                end
            elseif holdPitch and holdYaw then
                pcall(applyCameraAngle, holdPitch, holdYaw)
            end

            -- 声纳扫描线更新
            local asdicElapsed = now - asdicScanStart
            local period = 4 * ASDIC_SCAN_SECTOR_HALF / ASDIC_SCAN_ANGULAR_SPEED
            local phase = (asdicElapsed % period) / period
            if phase < 0.5 then
                asdicScanAngle = -ASDIC_SCAN_SECTOR_HALF + 4 * ASDIC_SCAN_SECTOR_HALF * phase
            else
                asdicScanAngle = ASDIC_SCAN_SECTOR_HALF - 4 * ASDIC_SCAN_SECTOR_HALF * (phase - 0.5)
            end

            -- 声纳目标池构建（仅8889频道，直接使用摄像头偏航角作为相对方位）
            asdicPoolCount = 0
            if isAsdicActive and localPos then
                for id, t in pairs(targets) do
                    if t.source == 8889 and t.realPos and t.realDist and t.realDist >= ASDIC_MIN_DISTANCE and t.realDist <= ASDIC_MAX_DISTANCE
                        and t.realPos.y <= ASDIC_DEPTH_FILTER and not t.isBeacon and t.lastSeen and (now - t.lastSeen < 3.0) then
                        local tYaw
                        if currentQAbs and currentQLoc then
                            local iqx,iqy,iqz,iqw = quatInverse(currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                            local dx = t.realPos.x - localPos.x
                            local dz = t.realPos.z - localPos.z
                            local hx,hy,hz = rotateVectorFast(dx, 0, dz, iqx,iqy,iqz,iqw)
                            local sx,sy,sz = rotateVectorFast(hx,hy,hz, currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                            tYaw = math_deg(math_atan2(-sx,sz))  -- 摄像头偏航角，直接作为相对方位
                        else
                            _,tYaw = calculateLookAngles(localPos.x,localPos.y,localPos.z, t.realPos.x,t.realPos.y,t.realPos.z)
                        end
                        local relBearing = tYaw
                        if math_abs(relBearing) <= ASDIC_SCAN_SECTOR_HALF then
                            local beamHalf = ASDIC_SCAN_BEAM_WIDTH / 2
                            if math_abs(getAngleDiff(relBearing, asdicScanAngle)) <= beamHalf then
                                if not t.lastPaintedAsdic or (now - t.lastPaintedAsdic >= 0.5) then
                                    t.paintedYaw = relBearing
                                    t.paintedDist = t.realDist
                                    t.lastPaintedAsdic = now
                                    -- 声纳锁定告警（类型3）
                                    modem.transmit(ACTIVE_SONAR_CHANNEL, ACTIVE_SONAR_CHANNEL, {v=2, t=3, si=myId, ti=id, x=localPos.x, y=localPos.y, z=localPos.z})
                                end
                                local age = now - t.lastPaintedAsdic
                                local col = calcFadeColor(age, 0xFF6600)
                                if col and col ~= 0x000000 then
                                    asdicPoolCount = asdicPoolCount + 1
                                    local p = asdicTargetPool[asdicPoolCount]
                                    if not p then p = {}; asdicTargetPool[asdicPoolCount] = p end
                                    p.col = col
                                    local screenRad = math_rad(relBearing)
                                    p.s = math_sin(screenRad); p.cs = math_cos(screenRad)
                                    p.distRatio = math_min(t.realDist / ASDIC_MAX_DISTANCE, 1.0)
                                end
                            end
                        end
                    end
                end
            end
        end
        sleep(0.02)
    end
end

-- ==========================================
-- 启动信息
-- ==========================================
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.green)
print("Radar+ASDIC v3.0.0 - OK")
print(string.format("  Name      : %s", myLabel))
print(string.format("  Radar Range: %.0f m", MAX_DISTANCE_LIMIT))
print(string.format("  ASDIC Range: %d-%d m", ASDIC_MIN_DISTANCE, ASDIC_MAX_DISTANCE))
print(string.format("  Radar GPU  : %s", radarGpu and peripheral.getName(radarGpu) or "NONE"))
print(string.format("  ASDIC GPU  : %s", asdicGpu and peripheral.getName(asdicGpu) or "NONE"))
print(string.format("  Radar HUD  : %s", radarHud and peripheral.getName(radarHud) or "NONE"))
print(string.format("  ASDIC HUD  : %s", asdicHud and peripheral.getName(asdicHud) or "NONE"))
sleep(1.0)

-- ==========================================
-- 并行启动所有协程
-- ==========================================
parallel.waitForAll(
    function() -- 雷达GPU渲染循环
        while true do
            if radarGpu then
                local w, h = radarGpu.getSize()
                local cx = math_floor(w / 2)
                local cy = math_floor(h / 2)
                local r = math_floor(math_min(cx, cy) * 0.88)
                local dotSize = 4
                if r < 80 then dotSize = 3 end
                if r < 50 then dotSize = 2 end
                local entry = {gpu = radarGpu, cx = cx, cy = cy, r = r, w = w, h = h, dotSize = dotSize}
                refreshRadar(entry, radarEnabled and (currentRadarRange > 0) and isServoConnected, radarPoolCount, radarPool)
            end
            sleep(0.05)
        end
    end,
    function() -- 声纳GPU渲染循环
        while true do
            if asdicGpu then
                local w, h = asdicGpu.getSize()
                local cx = math_floor(w / 2)
                local cy = math_floor(h / 2)
                local r = math_floor(math_min(cx, cy) * 0.88)
                local entry = {gpu = asdicGpu, cx = cx, cy = cy, r = r, w = w, h = h}
                refreshAsdic(entry, isAsdicActive, asdicPoolCount, asdicTargetPool)
            end
            sleep(0.05)
        end
    end,
    function() -- 雷达HUD刷新
        while true do drawRadarHUD() sleep(0.1) end
    end,
    function() -- 声纳HUD刷新
        while true do drawAsdicHUD() sleep(0.1) end
    end,
    termUI,
    inputLoop,
    pingLoop,
    listenLoop,
    rwrRedstoneLoop,
    sensorLoop
)
