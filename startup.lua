--[[声纳系统(船只端)   v2.0.0  ASDIC 改装
======================================================================
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠀⠈⠀⠀⠈⠁⠀⠙⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⠁⠀⠀⠀⠀⠀⠀ ⠀⠀⠀⠈⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⡔⠀⠀⠀⠀⠀⠀⠀ ⠀⠀⠀⠀⠈⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⠁⠀⠀⠀⠀⠀⠀⠀⠀⢀⣧⠀⠀ ⠸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠃⠀⢰⠀⠀⠀⠀⠀⠠⣶⣿⣿⡄⠀ ⠀⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠃⠀⠀⠚⠛⠛⠁⠀⠀⢷⣶⣿⣿⣇⠀⠀⠈⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠟⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⢹⣿⣿⠀⠀⠀⠸⣿⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠟⠁⠀⠀⡠⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⡆⠀⠀⠀⠻⣿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⡿⠿⠿⠿⠟⠛⠛⠛⠉⠉⠁⠀⠀⠀⢀⣠⡾⠀⠀⠀⠀⠀⠀⠀⣠⠀⠀⢸⣿⣿⣷⠀⠀⠀⠀⠙⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⡿⠋⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⢀⣴⣿⡿⠁⠀⠀⠀⠀⠀⠀⣴⣿⡇⠀⠀⣿⣿⣿⡆⠀⠀⠀⠀⠈⢿⣿⣿⣿⣿⣿
⣿⣿⡿⠋⠀⠀⣀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣐⣮⣵⡿⠟⠉⠀⠀⠀⠀⠀⠀⠀⣼⣿⣿⡇⠀⠀⣿⣿⣿⣿⠀⠀⠀⠀⠑⡀⠙⢿⣿⣿⣿
⣿⡿⠀⣠⠾⠋⠀⠀⠀⢀⣠⣴⣾⣿⣿⣿⠛⠉⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⣿⣿⠀⠀⠀⣿⣿⣿⣿⡀⡀⠀⠀⠀⠈⠀⠀⠙⢿⣿
⡟⠀⠀⠁⠀⠀⠀⢠⣶⣿⣿⣿⣿⣿⣿⣯⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⣿⣿⠀⠀⠀⢙⣛⡻⣿⣷⢸⡄⠀⠀⠀⠀⠀⠀⠀⠙
⠁⠀⠀⠀⠀⠀⣰⣿⣿⣿⣿⣿⣿⣿⣿⣯⠀⠀⠀⠈⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠀⠀⠀⠈⣿⣿⢸⣿⣷⡳⠀⠀⠀⠀⠀⠀⠀⠀
⡀⠀⠀⠀⠀⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣯⠀⠀⠀⠀⠀⠰⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⠀⠀⠹⢋⣾⣿⣿⣿⣦⡀⠀⠀⠀⠀⠀⠀
⡗⠀⠀⠀⠀⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣆⡀⠀⠀⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⢠⣈⡁⠀⠀⠀⠀⢙⣻⣿⣿⣿⣿⣿⡄⢧⡀⠀⠀⠀
⡇⠀⠀⠀⠀⠙⠿⣿⣿⣿⣿⡿⣿⣿⣿⣿⣿⣿⣶⣤⣀⣀⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⣧⡀⠀⠀⢀⡐⣬⣿⣿⣿⣿⣿⣿⡘⣿⡄⠀⠀
⡇⢠⠀⠀⠀⠀⣄⣀⣉⣭⣵⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡄⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⣾⣿⣧⣽⣿⣿⣿⣿⣿⣿⣿⣿⣿⡘⢿⠀⠀
⣿⡌⠀⠀⠀⠀⠹⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⠀⠃⠀⠀⠀⠀⠀⢸⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⡀⠀
⣿⣿⣄⠀⠀⠀⠀⠈⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⠐⠀⠀⢰⠀⠀⠨⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀
⣿⣿⣿⣿⣦⠀⠀⠀⠀⠈⠛⠿⣿⣿⣿⣿⣿⡿⣫⣿⣿⣿⣿⣿⣧⠀⠀⠀⡀⠀⠀⠈⠛⠀⠈⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡀
⣿⣿⣿⣿⣿⣧⡀⠈⢶⣤⣤⣀⣀⣤⣀⣤⣶⣾⣿⣿⣿⣿⣿⣿⣿⣆⣀⡀⢀⠀⠀⢤⣄⠀⠀⢺⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇
⣿⣿⣿⣿⣿⣿⣿⣶⣤⣉⠻⠿⠿⠿⢛⣵⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡀⠀⠀⠀⠉⠆⠀⠀⢻⣿⣿⣿⣿⠏⣴⣿⣿⣿⣿⣿⣿⠁
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⡀⠀⠀⠀⢄⣠⣿⣿⣿⣿⣿⡀⠻⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⠀⠀⠘⣿⣿⣿⣿⣟⣿⣷⣤⣬⣉⣉
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⠀⠀⢹⣿⣿⣿⣿⣦⣍⣉⠉⠉⠀
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⠀⠀⠻⠛⠿⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⠀⠀⠀⠀⣸⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣆⠀⠀⠀⣿⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀⢹⣿⣿⣿⣿⣿⣿
⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀⣀⣾⣿⣿⣿⣿⣿⣿
======================================================================]]

-- ==========================================
--  全局配置
-- ==========================================
local MIN_DISTANCE_LIMIT       = 100.0    -- 声纳最小探测距离
local MAX_DISTANCE_LIMIT       = 600.0    -- 声纳最大探测距离
local STRESS_THRESHOLD        = 10000    -- 应力阈值，达到后工作
local CHANNEL_SEND            = 8888     -- 广播自身位置的频道
local CHANNEL_LISTEN          = 8889     -- 监听其他船只广播的频道
local SCAN_SECTOR_WIDTH        = 20
local SEA_LEVEL               = -4       -- 海平面Y坐标

local TARGET_FADE_DURATION = 3.0
local TARGET_HOT_DURATION  = 1.0
local RWR_ARC_DURATION     = 1.0    -- 保留，但不再使用

local REG_QUERY_TIMEOUT = 5.0

-- ==========================================
-- 外设初始化
-- ==========================================
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Error: Wireless or Ender Modem not found!", 0) end
modem.open(CHANNEL_SEND)    -- 发送频道
modem.open(CHANNEL_LISTEN)  -- 监听频道

local camera, cameraName = nil, nil
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "camera" then
        camera     = peripheral.wrap(name)
        cameraName = name
        break
    end
end
if not camera then error("Error: Camera not found!", 0) end

local HAS_FORCE_API = (camera.forcePitchYaw ~= nil)
local function applyCameraAngle(p, y)
    if HAS_FORCE_API then camera.forcePitchYaw(p, y)
    else camera.setPitch(p); camera.setYaw(y) end
end

redstone.setOutput("front", false)

local myId        = os.getComputerID()
local CONFIG_FILE = "asdic_config.txt"

-- ==========================================
-- 全局 API 别名
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
    return math_floor(r) * 0x10000
         + math_floor(g) * 0x100
         + math_floor(b)
end
local function colorLerp(ca, cb, t)
    t = math_max(0.0, math_min(1.0, t))
    local ar, ag, ab = colorUnpack(ca)
    local br, bg, bb = colorUnpack(cb)
    return colorPack(
        ar + (br - ar) * t,
        ag + (bg - ag) * t,
        ab + (bb - ab) * t
    )
end
local function calcFadeColor(age, hotColor)
    if age >= TARGET_FADE_DURATION then return nil end
    if age <= TARGET_HOT_DURATION  then return hotColor end
    local t = (age - TARGET_HOT_DURATION)
            / (TARGET_FADE_DURATION - TARGET_HOT_DURATION)
    return colorLerp(hotColor, 0x000000, t)
end

-- ==========================================
-- 运行状态
-- ==========================================
local targets               = {}
local localPos              = nil
local trackedTargetId       = nil
local isTargetInRange       = false
local holdPitch, holdYaw    = nil, nil
local selectedTargetId      = nil
local selectedTargetDistStr = nil
local selectedTargetDepth   = nil   -- 新增，存储锁定目标深度
local currentQAbs, currentQLoc = nil, nil
local currentServoAngle        = 0
local isServoConnected         = false
local yawOffset    = 0
local motorOffset  = 0
local sonarCenterOffset = 0       -- 扇形中心偏移
local broadcastPos = "yes"        -- 是否广播自身位置，默认 yes
local myLabel      = os.getComputerLabel() or ("Entity-" .. myId)
local monitorModes = {}
local aimPrecision = 5
local currentStressCapacity = 0
local currentRadarRange     = 0
local currentNorthYawDeg    = 0
local currentScreenTab      = 1
local menuIndex             = 1
local isEditing             = false
local inputStr              = ""
local cachedStressometer    = peripheral.find("Create_Stressometer")
local cachedServo           = peripheral.find("servo")
local targetPool            = {}
local targetPoolCount       = 0
-- 移除 rwrEvents

-- ==========================================
--  配置文件
-- ==========================================
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f    = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            if data.yawOffset    then yawOffset    = tonumber(data.yawOffset)   or 0 end
            if data.motorOffset  then motorOffset  = tonumber(data.motorOffset) or 0 end
            if data.sonarCenterOffset then sonarCenterOffset = tonumber(data.sonarCenterOffset) or 0 end
            if data.broadcastPos then broadcastPos = data.broadcastPos end
            if data.aimPrecision then
                local p = tonumber(data.aimPrecision)
                if p and p >= 1 and p <= 90 and (360 % math_floor(p) == 0) then
                    aimPrecision = math_floor(p)
                end
            end
            if type(data.monitorModes) == "table" then
                monitorModes = data.monitorModes
            end
        end
    end
end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize({
        yawOffset    = yawOffset,
        motorOffset  = motorOffset,
        sonarCenterOffset = sonarCenterOffset,
        broadcastPos = broadcastPos,
        aimPrecision = aimPrecision,
        monitorModes = monitorModes,
    }))
    f.close()
end
loadConfig()

-- ==========================================
-- 算法函数
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
    local dx = targetPos.x - refPos.x
    local dy = targetPos.y - refPos.y
    local dz = targetPos.z - refPos.z
    return math_sqrt(dx*dx + dy*dy + dz*dz)
end
-- 计算目标是否在扇区内
local function isInSector(tYaw, sectorCenter, halfWidth)
    local diff = math_abs(getAngleDiff(tYaw, sectorCenter))
    return diff <= halfWidth
end

-- ==========================================
-- 颜色常量
-- ==========================================
local C = {
    BG          = 0x050A05,
    OUTER_RING  = 0x00CC44,
    INNER_RING  = 0x007722,
    GRID        = 0x005518,
    SWEEP       = 0x00FF66,
    YELLOW      = 0xFFFF00,
    UNK_HOT     = 0xEEEEEE,   -- 统一目标颜色
    BLACK       = 0x000000,
    WHITE       = 0xFFFFFF,
    UNREG_FG    = 0xFF2200,
    UNREG_BG    = 0x1A0000,
}

-- ==========================================
-- HUD 监视器列表
-- ==========================================
local hudMonitorList = {}
local mIndex = 1
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
        local m = peripheral.wrap(name)
        m.setTextScale(1)
        local cw, ch = m.getSize()
        local bw = math.ceil(cw / 9)
        local bh = math.ceil(ch / 7)
        if bw >= 5 then bw = bw - 1 end
        table.insert(hudMonitorList, {
            m           = m,
            name        = name,
            displayName = "Monitor " .. mIndex,
            bw          = math.max(1, bw),
            bh          = math.max(1, bh),
            mode        = monitorModes[name] or "STATUS",
            termRow     = 0,
            lastLine1   = nil,
            lastLine2   = nil,
            lastLine3   = nil,
        })
        mIndex = mIndex + 1
    end
end

-- ==========================================
-- RDR GPU 列表
-- ==========================================
local BLOCK_PX_W = 85
local BLOCK_PX_H = 64

local rdrGpuList = {}
local gpuNameMap = {}

local function initGpuList()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "tm_gpu" then
            local g = peripheral.wrap(name)
            pcall(g.refreshSize)
            pcall(g.setSize, 64)
            pcall(g.fill, C.BG)
            local ok, w, h = pcall(g.getSize)
            if not ok then w, h = 256, 128 end
            w = w or 256; h = h or 128
            local cx = math_floor(w / 2)
            local cy = math_floor(h / 2)
            local r  = math_floor(math_min(cx, cy) * 0.88)
            local bw = math_max(1, math_floor(w / BLOCK_PX_W))
            local bh = math_max(1, math_floor(h / BLOCK_PX_H))
            local dotSize
            if r >= 110 then dotSize = 4
            elseif r >= 80 then dotSize = 3
            elseif r >= 50 then dotSize = 2
            else dotSize = 1 end
            if bw >= 3 and bh >= 3 then dotSize = dotSize + 1 end
            dotSize = math_max(2, dotSize)
            local entry = {
                gpu=g, name=name, w=w, h=h, cx=cx, cy=cy, r=r,
                bw=bw, bh=bh, dotSize=dotSize,
                lastSweepDeg=-9999,
            }
            table.insert(rdrGpuList, entry)
            gpuNameMap[name] = entry
        end
    end
end
initGpuList()

local isHeadless = (#hudMonitorList == 0 and #rdrGpuList == 0)

-- ==========================================
-- 注册检查
-- ==========================================
local function checkRegistration()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("ASDIC v2.0 - Registration Check")
    term.setTextColor(colors.white)
    print(string.format("My ID: %d", myId))
    print("Querying scanner...")

    for _, entry in ipairs(rdrGpuList) do
        pcall(function()
            entry.gpu.fill(C.BG)
            local msg = "CHECKING..."
            local tx  = math_max(1, entry.cx - math_floor(#msg * 6))
            local ty  = entry.cy - 8
            pcall(entry.gpu.drawText, tx, ty, msg, C.YELLOW, C.BG, 2)
            entry.gpu.sync()
        end)
    end

    modem.transmit(CHANNEL_SEND, CHANNEL_SEND, { v=2, t=4, i=myId })

    local timer = os.startTimer(REG_QUERY_TIMEOUT)
    while true do
        local ev, a, b, c, d = os.pullEvent()

        if ev == "modem_message" then
            if b == CHANNEL_SEND and type(d) == "table" and d.v == 2 then
                if d.t == 5 and d.ti == myId then
                    os.cancelTimer(timer)
                    myLabel            = tostring(d.n or myLabel)
                    MAX_DISTANCE_LIMIT = tonumber(d.r) or MAX_DISTANCE_LIMIT
                    term.setTextColor(colors.lime)
                    print(string.format(
                        "Registered!  Name: %s  MaxRange: %.0fm",
                        myLabel, MAX_DISTANCE_LIMIT))
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
-- 未注册显示并停止
-- ==========================================
local function showNotRegisteredAndHalt()
    for _, entry in ipairs(rdrGpuList) do
        pcall(function()
            local g  = entry.gpu
            local cx = entry.cx
            local cy = entry.cy
            local w  = entry.w
            local h  = entry.h
            g.fill(C.UNREG_BG)
            local bx1, by1 = math_floor(cx * 0.3), math_floor(cy * 0.5)
            local bx2, by2 = w - bx1, h - by1
            g.line(bx1, by1, bx2, by1, C.UNREG_FG)
            g.line(bx1, by2, bx2, by2, C.UNREG_FG)
            g.line(bx1, by1, bx1, by2, C.UNREG_FG)
            g.line(bx2, by1, bx2, by2, C.UNREG_FG)
            local line1 = "NOT REGISTERED"
            local tx1   = math_max(bx1 + 4, cx - math_floor(#line1 * 6))
            pcall(g.drawText, tx1, cy - 14, line1, C.UNREG_FG, C.UNREG_BG, 2)
            local line2 = string.format("ID: %d", myId)
            local tx2   = math_max(bx1 + 4, cx - math_floor(#line2 * 3))
            pcall(g.drawText, tx2, cy + 6,  line2, 0xAAAAAA, C.UNREG_BG, 1)
            local line3 = "Register in scanner"
            local tx3   = math_max(bx1 + 4, cx - math_floor(#line3 * 3))
            pcall(g.drawText, tx3, cy + 18, line3, 0x666666, C.UNREG_BG, 1)
            g.sync()
        end)
    end

    for _, info in ipairs(hudMonitorList) do
        pcall(function()
            local m = info.m
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
        { "Register this ASDIC in",   colors.gray   },
        { "asdic_scanner.lua first.", colors.gray   },
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
print("Registration OK. Starting ASDIC...")
sleep(0.5)

-- ==========================================
-- GPU 绘制辅助
-- ==========================================
local function gpuDrawArc(g, cx, cy, r, startAngle, endAngle, color)
    -- 简单绘制圆弧（点画）
    local step = math_rad(0.5)
    local a = startAngle
    while a <= endAngle do
        local px = cx + math_floor(r * math_cos(a) + 0.5)
        local py = cy - math_floor(r * math_sin(a) + 0.5)
        g.line(px, py, px, py, color)
        a = a + step
    end
end

local function gpuDrawSectorBase(entry, sectorCenterDeg)
    local g   = entry.gpu
    local cx  = entry.cx
    local cy  = entry.cy
    local r   = entry.r
    g.fill(C.BG)
    -- 扇形边界（外弧线）
    local startRad = math_rad(sectorCenterDeg - 90)
    local endRad   = math_rad(sectorCenterDeg + 90)
    gpuDrawArc(g, cx, cy, r, startRad, endRad, C.OUTER_RING)
    -- 内弧线
    local r2 = math_floor(r / 2)
    gpuDrawArc(g, cx, cy, r2, startRad, endRad, C.INNER_RING)
    -- 两条半径
    local sx1 = cx + math_floor(r * math_cos(startRad) + 0.5)
    local sy1 = cy - math_floor(r * math_sin(startRad) + 0.5)
    g.line(cx, cy, sx1, sy1, C.GRID)
    local sx2 = cx + math_floor(r * math_cos(endRad) + 0.5)
    local sy2 = cy - math_floor(r * math_sin(endRad) + 0.5)
    g.line(cx, cy, sx2, sy2, C.GRID)
    -- 中心十字线（在扇形中心方向）
    local centerRad = math_rad(sectorCenterDeg)
    local cx1 = cx + math_floor(r * math_cos(centerRad) + 0.5)
    local cy1 = cy - math_floor(r * math_sin(centerRad) + 0.5)
    g.line(cx, cy, cx1, cy1, C.GRID)
    -- 标记 N（用扇形中心表示船头方向）
    local tX = math_max(1, math_min(entry.w-6, cx1-3))
    local tY = math_max(1, math_min(entry.h-8, cy1-4))
    pcall(g.drawText, tX, tY, "N", C.YELLOW, C.BG, 1)
end

local function gpuDrawSweep(entry, angleDeg, sectorCenterDeg)
    -- 仅当角度在扇区内绘制
    if not isInSector(angleDeg, sectorCenterDeg, 90) then return end
    local g   = entry.gpu
    local cx  = entry.cx
    local cy  = entry.cy
    local r   = entry.r
    local rad = math_rad(angleDeg)
    local ex  = cx + math_floor(r * math_sin(rad) + 0.5)
    local ey  = cy - math_floor(r * math_cos(rad) + 0.5)
    g.line(cx, cy, ex, ey, C.SWEEP)
end

local function gpuRefreshRadar(entry, isActive, poolCount, pool, sectorCenterDeg)
    local g   = entry.gpu
    local cx  = entry.cx
    local cy  = entry.cy
    local r   = entry.r
    local ds  = entry.dotSize
    local half = math_floor(ds / 2)

    gpuDrawSectorBase(entry, sectorCenterDeg)
    -- 绘制目标
    if isActive and localPos then
        for i = 1, poolCount do
            local t = pool[i]
            if t.col and t.col ~= C.BLACK then
                local dr = r * t.r
                local px = cx + math_floor(dr * t.s + 0.5)
                local py = cy - math_floor(dr * t.cs + 0.5)
                -- 必须同时在扇区内（由外部确保）且不超出绘制范围
                if (px-cx)^2 + (py-cy)^2 <= r*r then
                    if t.isBeacon then
                        -- 三角形信标
                        g.line(px, py-1, px, py-1, t.col)
                        g.line(px-1, py, px+1, py, t.col)
                    else
                        gpuFillRect(g, px-half, py-half, ds, ds, t.col)
                    end
                end
            end
        end
    end
    if isActive then
        gpuDrawSweep(entry, currentServoAngle + yawOffset, sectorCenterDeg)
    end
    -- 不再绘制敌我四角色带
    g.sync()
end

-- ==========================================
-- RDR GPU 主循环
-- ==========================================
local function rdrGpuUI()
    if #rdrGpuList == 0 then return end
    local frames = 0
    local lastActive = false
    while true do
        if currentScreenTab == 2 then
            for _, entry in ipairs(rdrGpuList) do
                pcall(function()
                    entry.gpu.fill(C.BG)
                    pcall(entry.gpu.drawText, entry.cx-6, entry.cy-4,
                        entry.name, C.WHITE, C.BG, 2)
                    entry.gpu.sync()
                end)
            end
            sleep(0.3)
        else
            frames = frames + 1
            local isActive = (currentRadarRange > 0) and isServoConnected
            local forceRedraw = (isActive ~= lastActive)
            lastActive = isActive

            -- 计算扇形中心方向
            local sectorCenter = currentNorthYawDeg + yawOffset + sonarCenterOffset

            targetPoolCount = 0
            local now = os_clock()
            if localPos and isActive then
                for _, data in pairs(targets) do
                    if data.lastPainted and not data.isBeacon then
                        local age = now - data.lastPainted
                        if age < TARGET_FADE_DURATION then
                            local col = calcFadeColor(age, C.UNK_HOT)
                            if col and col ~= C.BLACK then
                                local yawRad = math_rad(data.paintedYaw + yawOffset)
                                local distRatio = math_min(data.paintedDist / MAX_DISTANCE_LIMIT, 1.0)
                                -- 检查是否在扇形内
                                if isInSector(data.paintedYaw, sectorCenter, 90) then
                                    targetPoolCount = targetPoolCount + 1
                                    local t = targetPool[targetPoolCount]
                                    if not t then t = {}; targetPool[targetPoolCount] = t end
                                    t.col = col
                                    t.r = distRatio
                                    t.s = math_sin(yawRad)
                                    t.cs = math_cos(yawRad)
                                    t.isBeacon = false
                                end
                            end
                        end
                    end
                end
            end

            -- 信标
            if localPos then
                for _, data in pairs(targets) do
                    if data.isBeacon and data.lastSeen and (now - data.lastSeen < 5.0) then
                        local col = C.YELLOW   -- 统一颜色
                        local tYaw, tDist = 0, 0
                        if data.realPos then
                            tDist = calcRangingDist(localPos, data.realPos) or 0
                            if currentQAbs and currentQLoc then
                                local iqx, iqy, iqz, iqw = quatInverse(
                                    currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                                local dx = data.realPos.x - localPos.x
                                local dy = data.realPos.y - localPos.y
                                local dz = data.realPos.z - localPos.z
                                local hx, hy, hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                                local sx, sy, sz = rotateVectorFast(hx, hy, hz,
                                    currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                                tYaw = math_deg(math_atan2(-sx, sz))
                            else
                                _, tYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z,
                                    data.realPos.x, data.realPos.y, data.realPos.z)
                            end
                        end
                        local distRatio = math_min(tDist / MAX_DISTANCE_LIMIT, 1.0)
                        local yawRad = math_rad(tYaw + yawOffset)
                        if isInSector(tYaw, sectorCenter, 90) then
                            targetPoolCount = targetPoolCount + 1
                            local t = targetPool[targetPoolCount]
                            if not t then t = {}; targetPool[targetPoolCount] = t end
                            t.col = col
                            t.r = distRatio
                            t.s = math_sin(yawRad)
                            t.cs = math_cos(yawRad)
                            t.isBeacon = true
                        end
                    end
                end
            end

            local hasTargets = (targetPoolCount > 0)
            for _, entry in ipairs(rdrGpuList) do
                local angleDiff = math_abs(getAngleDiff(currentServoAngle, entry.lastSweepDeg))
                if forceRedraw or angleDiff > 0.5 or frames <= 2 or hasTargets then
                    entry.lastSweepDeg = currentServoAngle
                    pcall(gpuRefreshRadar, entry, isActive, targetPoolCount, targetPool, sectorCenter)
                end
            end
            sleep(0.05)
        end
    end
end

-- ==========================================
-- HUD 主循环
-- ==========================================
local function hudMonitorUI()
    if #hudMonitorList == 0 then return end
    local frames = 0
    while true do
        frames = frames + 1
        local isFirstFrame = (frames <= 2)
        local isActive = (currentRadarRange > 0) and isServoConnected
        for _, info in ipairs(hudMonitorList) do
            if info.mode == "STATUS" then
                local line1, color1, line2, color2, line3, color3
                -- 第一行：状态
                if not isActive then
                    line1 = "ASDIC offline"
                    color1 = colors.red
                else
                    line1 = "ASDIC online"
                    color1 = colors.green
                end
                -- 第二行：探测范围
                line2 = string.format("100 - 600 m")
                color2 = colors.lime
                -- 第三行：目标深度 / 距离
                if selectedTargetId and targets[selectedTargetId] then
                    local sel = targets[selectedTargetId]
                    local depth = SEA_LEVEL - (sel.realPos and sel.realPos.y or 0)
                    local dist  = selectedTargetDistStr or "---"
                    line3 = string.format("D:%d m / R:%s", math_floor(depth), dist)
                    color3 = colors.white
                else
                    line3 = "D:- - / R:- -"
                    color3 = colors.gray
                end

                if isFirstFrame or line1 ~= info.lastLine1 or line2 ~= info.lastLine2 or line3 ~= info.lastLine3 then
                    info.m.setTextScale(1)
                    info.m.setBackgroundColor(colors.black)
                    info.m.clear()
                    local dw, dh = info.m.getSize()
                    local function drawCL(txt, col, yPos)
                        info.m.setTextColor(col)
                        local sx = math_max(1, math_floor((dw - #txt) / 2) + 1)
                        info.m.setCursorPos(sx, yPos)
                        info.m.write(txt)
                    end
                    local y1 = math_max(1, math_floor(dh / 2) - 2)
                    local y2 = math_max(2, math_floor(dh / 2))
                    local y3 = math_max(3, math_floor(dh / 2) + 2)
                    drawCL(line1, color1, y1)
                    drawCL(line2, color2, y2)
                    drawCL(line3, color3, y3)
                    info.lastLine1 = line1
                    info.lastLine2 = line2
                    info.lastLine3 = line3
                end
            end
        end
        sleep(0.1)
    end
end

-- ==========================================
-- 终端 UI
-- ==========================================
local function termUI()
    while true do
        term.setBackgroundColor(colors.black)
        term.clear()
        if currentScreenTab == 2 then
            term.setCursorPos(2,2); term.setTextColor(colors.lightGray)
            term.write("=== CONNECTED DISPLAYS ===")
            local r=4
            term.setCursorPos(2,r); term.setTextColor(colors.cyan)
            term.write("[TOM'S GPU - RDR]"); r=r+1
            if #rdrGpuList==0 then
                term.setCursorPos(4,r); term.setTextColor(colors.red)
                term.write("No tm_gpu found."); r=r+1
            else
                for _,entry in ipairs(rdrGpuList) do
                    term.setCursorPos(4,r); term.setTextColor(colors.lightBlue)
                    term.write("- "..entry.name)
                    term.setCursorPos(22,r); term.setTextColor(colors.white)
                    term.write(string.format("[%dx%d]",entry.bw,entry.bh))
                    term.setCursorPos(30,r); term.setTextColor(colors.green)
                    term.write("[dot:"..entry.dotSize.."]"); r=r+1
                end
            end
            r=r+1
            term.setCursorPos(2,r); term.setTextColor(colors.cyan)
            term.write("[CC MONITOR - HUD]"); r=r+1
            if #hudMonitorList==0 then
                term.setCursorPos(4,r); term.setTextColor(colors.red)
                term.write("No monitors found."); r=r+1
            else
                for _,info in ipairs(hudMonitorList) do
                    term.setCursorPos(4,r); term.setTextColor(colors.lightBlue)
                    term.write("- "..info.displayName)
                    term.setCursorPos(24,r); term.setTextColor(colors.yellow)
                    term.write("[HUD]"); info.termRow=r; r=r+1
                end
            end
            r=r+1
            term.setCursorPos(2,r); term.setTextColor(colors.lightGray)
            term.write("Camera: ")
            local shortN=cameraName
            if #shortN>12 then shortN=shortN:sub(1,12) end
            term.setTextColor(colors.white); term.write(shortN)
            term.setTextColor(colors.cyan);  term.write("  [ONLINE]")
            r=r+2
            term.setCursorPos(2,r); term.setTextColor(colors.yellow)
            term.write("Press [TAB] to Resume"); r=r+1
            term.setCursorPos(2,r); term.setTextColor(colors.red)
            term.write("[SYSTEM PAUSED FOR CONFIG]")
        else
            -- 标题
            term.setCursorPos(2,2); term.setTextColor(colors.yellow)
            term.write("=== ASDIC CONFIG ===")

            -- 输入框绘制辅助
            local function drawInputBox(y, label, val, isSel, isEdit)
                term.setCursorPos(2,y); term.setBackgroundColor(colors.black)
                term.setTextColor(isSel and colors.yellow or colors.lightGray)
                term.write(label)
                term.setCursorPos(20,y); term.setBackgroundColor(colors.gray)
                local txt = (isSel and isEdit) and (inputStr.."_") or tostring(val)
                term.setTextColor(isSel and colors.white or colors.lightGray)
                term.write(string.format(" %-8s ", txt))
                term.setBackgroundColor(colors.black)
            end

            -- 可编辑项（5项）
            drawInputBox(4,  "Disp. Offset:", yawOffset,         menuIndex==1, isEditing)
            drawInputBox(6,  "Motor Offset:", motorOffset,       menuIndex==2, isEditing)
            drawInputBox(8,  "Sonar Center:", sonarCenterOffset, menuIndex==3, isEditing)
            drawInputBox(10, "Aim Precis  :", aimPrecision,      menuIndex==4, isEditing)
            drawInputBox(12, "Broadcast Pos:", broadcastPos,     menuIndex==5, isEditing)

            -- 系统状态
            term.setCursorPos(2,14); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")

            term.setCursorPos(2,16); term.setTextColor(colors.lime)
            term.write(string.format("Registered : %s", myLabel))

            term.setCursorPos(2,17); term.setTextColor(colors.cyan)
            term.write(string.format("Range      : %d - %d m", MIN_DISTANCE_LIMIT, MAX_DISTANCE_LIMIT))

            term.setCursorPos(2,18); term.setTextColor(colors.green)
            term.write("Camera     : ONLINE")

            term.setCursorPos(2,19)
            if isServoConnected then
                term.setTextColor(colors.white)
                term.write(string.format("Motor Angle: %6.1f deg", currentServoAngle))
            else
                term.setTextColor(colors.red); term.write("Motor Angle: OFFLINE")
            end

            term.setCursorPos(2,20)
            if currentStressCapacity >= STRESS_THRESHOLD then
                term.setTextColor(colors.green)
                term.write(string.format("Stress     : %d SU (OK)", currentStressCapacity))
            else
                term.setTextColor(colors.red)
                term.write(string.format("Stress     : %d SU (Need %d)", currentStressCapacity, STRESS_THRESHOLD))
            end

            term.setCursorPos(2,21)
            if currentRadarRange == 0 then
                term.setTextColor(colors.red); term.write("Status     : OFFLINE (No stress)")
            elseif not isServoConnected then
                term.setTextColor(colors.red); term.write("Status     : OFFLINE (No motor)")
            else
                term.setTextColor(colors.green); term.write("Status     : ACTIVE")
            end

            term.setCursorPos(2,22); term.setTextColor(colors.gray)
            term.write(string.format("North Yaw  : %.1f deg", currentNorthYawDeg))

            term.setCursorPos(2,23); term.setTextColor(colors.gray)
            term.write(string.format("Aim grid   : %d deg/step", aimPrecision))

            local beaconCount = 0
            for _, d in pairs(targets) do if d.isBeacon then beaconCount = beaconCount + 1 end end
            term.setCursorPos(2,24); term.setTextColor(colors.yellow)
            term.write(string.format("Beacons    : %d online", beaconCount))

            term.setCursorPos(2,25); term.setTextColor(colors.cyan)
            term.write((#rdrGpuList > 0) and ("RDR GPU: "..(#rdrGpuList).." online") or "RDR GPU: NONE")
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 输入事件循环
-- ==========================================
local function inputLoop()
    local function applySave()
        if menuIndex == 1 then
            local p = tonumber(inputStr); if p then yawOffset = p end
        elseif menuIndex == 2 then
            local p = tonumber(inputStr); if p then motorOffset = p end
        elseif menuIndex == 3 then
            local p = tonumber(inputStr); if p then sonarCenterOffset = p end
        elseif menuIndex == 4 then
            local p = tonumber(inputStr)
            if p then
                p = math_floor(math_abs(p))
                if p >= 1 and p <= 90 and (360 % p == 0) then aimPrecision = p end
            end
        elseif menuIndex == 5 then
            broadcastPos = (inputStr == "yes") and "yes" or "no"
        end
        saveConfig()
        isEditing = false
    end

    while true do
        local event, p1, p2, p3 = os_pullEvent()

        if event == "key" then
            if p1 == keys.tab then
                currentScreenTab = (currentScreenTab == 1) and 2 or 1

            elseif isEditing and currentScreenTab == 1 then
                if p1 == keys.enter or p1 == keys.numPadEnter then
                    applySave()
                elseif p1 == keys.backspace then
                    inputStr = inputStr:sub(1, -2)
                end

            elseif currentScreenTab == 1 then
                if     p1 == keys.up   then menuIndex = math_max(1, menuIndex - 1)
                elseif p1 == keys.down then menuIndex = math_min(5, menuIndex + 1)   -- 共5项
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    isEditing = true
                    if     menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(motorOffset)
                    elseif menuIndex == 3 then inputStr = tostring(sonarCenterOffset)
                    elseif menuIndex == 4 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 5 then inputStr = broadcastPos
                    end
                end
            end

        elseif event == "char" and isEditing and currentScreenTab == 1 then
            if menuIndex >= 1 and menuIndex <= 4 then
                if (p1 >= '0' and p1 <= '9') or p1 == '.'
                    or (p1 == '-' and #inputStr == 0)
                then
                    if #inputStr < 8 then inputStr = inputStr .. p1 end
                end
            elseif menuIndex == 5 then
                -- 只接受字母，转为小写后判断 yes/no
                if (p1 >= 'a' and p1 <= 'z') or (p1 >= 'A' and p1 <= 'Z') then
                    local temp = inputStr .. p1:lower()
                    if temp == "y" or temp == "ye" or temp == "yes" or
                       temp == "n" or temp == "no" then
                        inputStr = temp
                    end
                end
            end

        elseif event == "mouse_click" then
            local touchY = p3
            if currentScreenTab == 1 then
                local ti = nil
                if     touchY == 4  then ti = 1
                elseif touchY == 6  then ti = 2
                elseif touchY == 8  then ti = 3
                elseif touchY == 10 then ti = 4
                elseif touchY == 12 then ti = 5
                end
                if ti then
                    if isEditing and menuIndex ~= ti then applySave() end
                    menuIndex = ti
                    isEditing = true
                    if     menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(motorOffset)
                    elseif menuIndex == 3 then inputStr = tostring(sonarCenterOffset)
                    elseif menuIndex == 4 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 5 then inputStr = broadcastPos
                    end
                else
                    if isEditing then applySave() end
                end
            end

        elseif (event == "tm_monitor_touch" or event == "tm_monitor_mouse_click")
            and currentScreenTab == 1 then
            local touchedName = p1
            local mx, my = p2, p3
            local entry = gpuNameMap[touchedName]
            if entry and localPos then
                local sectorCenter = currentNorthYawDeg + yawOffset + sonarCenterOffset
                local now = os_clock()
                local clickedId = nil
                local minSqDist = (math_max(entry.dotSize * 3, entry.r * 0.04)) ^ 2
                local bestDist = nil
                if currentRadarRange > 0 and isServoConnected then
                    for id, data in pairs(targets) do
                        if not data.isBeacon and data.lastPainted
                            and (now - data.lastPainted < TARGET_FADE_DURATION)
                            and isInSector(data.paintedYaw, sectorCenter, 90)
                        then
                            local yawRad = math_rad(data.paintedYaw + yawOffset)
                            local distRatio = math_min(data.paintedDist / MAX_DISTANCE_LIMIT, 1.0)
                            local px = entry.cx + math_floor(entry.r * distRatio * math_sin(yawRad) + 0.5)
                            local py = entry.cy - math_floor(entry.r * distRatio * math_cos(yawRad) + 0.5)
                            local dSq = (mx - px)^2 + (my - py)^2
                            if dSq <= minSqDist then
                                minSqDist = dSq
                                bestDist = data.paintedDist
                                clickedId = id
                            end
                        end
                    end
                end
                -- 点击信标
                local clickedBeaconId = nil
                local beaconSqDist = 16
                for id, data in pairs(targets) do
                    if data.isBeacon and data.lastSeen and (now - data.lastSeen < 5.0)
                        and data.realPos
                    then
                        local tYaw = 0
                        if currentQAbs and currentQLoc then
                            local iqx, iqy, iqz, iqw = quatInverse(
                                currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                            local dx = data.realPos.x - localPos.x
                            local dy = data.realPos.y - localPos.y
                            local dz = data.realPos.z - localPos.z
                            local hx, hy, hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                            local sx, sy, sz = rotateVectorFast(hx, hy, hz,
                                currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                            tYaw = math_deg(math_atan2(-sx, sz))
                        else
                            _, tYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z,
                                data.realPos.x, data.realPos.y, data.realPos.z)
                        end
                        if isInSector(tYaw, sectorCenter, 90) then
                            local dist = calcRangingDist(localPos, data.realPos) or 0
                            local ratio = math_min(dist / MAX_DISTANCE_LIMIT, 1.0)
                            local yawRad = math_rad(tYaw + yawOffset)
                            local px = entry.cx + math_floor(entry.r * ratio * math_sin(yawRad) + 0.5)
                            local py = entry.cy - math_floor(entry.r * ratio * math_cos(yawRad) + 0.5)
                            local dSq = (mx - px)^2 + (my - py)^2
                            if dSq <= beaconSqDist then
                                beaconSqDist = dSq
                                clickedBeaconId = id
                            end
                        end
                    end
                end
                if clickedId then
                    -- 锁定目标
                    selectedTargetId = clickedId
                    selectedTargetDistStr = string.format("%dm", math_floor(bestDist + 0.5))
                end
                if clickedBeaconId then
                    -- 选中信标（仅显示信息）
                    selectedTargetId = clickedBeaconId
                    local bd = targets[clickedBeaconId]
                    local dist = bd.realDist or 0
                    selectedTargetDistStr = string.format("%dm", math_floor(dist + 0.5))
                end
            end
        end
    end
end

-- ==========================================
-- 网络协议
-- ==========================================
local function pingLoop()
    while true do
        if currentScreenTab == 2 then
            sleep(0.5)
        else
            if localPos and broadcastPos == "yes" then
                modem.transmit(CHANNEL_SEND, CHANNEL_SEND, {
                    v = 2, t = 1, i = myId, n = myLabel,
                    x = math_floor(localPos.x * 10) / 10,
                    y = math_floor(localPos.y * 10) / 10,
                    z = math_floor(localPos.z * 10) / 10,
                    r = currentRadarRange,
                })
            end
            local now = os_clock()
            for id, data in pairs(targets) do
                if not data.isBeacon and id ~= selectedTargetId
                    and data.lastSeen and (now - data.lastSeen > 10.0)
                then
                    targets[id] = nil
                end
                if data.isBeacon and data.lastSeen and (now - data.lastSeen > 10.0) then
                    targets[id] = nil
                end
            end
            sleep(1.0)
        end
    end
end

local function listenLoop()
    while true do
        local _, _, ch, _, msg, dist = os_pullEvent("modem_message")
        if ch == CHANNEL_LISTEN and type(msg) == "table" and msg.v == 2 then
            if msg.t == 1 and msg.i ~= myId then
                -- 检查深度和距离
                if msg.y and msg.y > -8 then goto continue end   -- 深度不足
                if not targets[msg.i] then targets[msg.i] = {} end
                local t = targets[msg.i]
                t.name = msg.n
                t.modemDist = dist
                t.realPos = { x = msg.x, y = msg.y, z = msg.z }
                t.range = msg.r
                t.lastSeen = os_clock()
                t.isBeacon = false
                local cd = calcRangingDist(localPos, t.realPos)
                t.realDist = cd or dist
                -- 距离检查在 cameraLoop 中进一步过滤
            elseif msg.t == 3 then
                -- 信标同样过滤深度
                if msg.y and msg.y > -8 then goto continue end
                local beaconId = msg.i
                local beaconUid = tostring(msg.uid or "0000")
                local key = tostring(beaconId) .. "_" .. beaconUid
                if not targets[key] then targets[key] = {} end
                local t = targets[key]
                t.name = tostring(msg.n or ("Beacon-" .. beaconId))
                t.modemDist = dist
                t.realPos = { x = msg.x, y = msg.y, z = msg.z }
                t.lastSeen = os_clock()
                t.isBeacon = true
                t.beaconId = beaconId
                t.beaconUid = beaconUid
                local cd = calcRangingDist(localPos, t.realPos)
                t.realDist = cd or dist
            end
        end
        ::continue::
    end
end

-- ==========================================
-- 红石事件（移除RWR，仅保留可能的外部控制，不再需要）
-- ==========================================
-- 无

-- ==========================================
-- 扫描解算
-- ==========================================
local function cameraLoop()
    local lastServoAngle = nil
    local peripheralPollTick = 0
    while true do
        if currentScreenTab == 2 then
            sleep(0.5)
        else
            if peripheralPollTick <= 0 then
                peripheralPollTick = 20
                if not cachedStressometer then
                    cachedStressometer = peripheral.find("Create_Stressometer")
                end
                if not cachedServo then
                    cachedServo = peripheral.find("servo")
                end
            else
                peripheralPollTick = peripheralPollTick - 1
            end

            if cachedStressometer then
                local ok, cap = pcall(cachedStressometer.getStressCapacity)
                if ok then
                    currentStressCapacity = cap or 0
                    -- 阈值判定
                    currentRadarRange = (currentStressCapacity >= STRESS_THRESHOLD) and MAX_DISTANCE_LIMIT or 0
                else
                    cachedStressometer = nil
                    currentStressCapacity = 0
                    currentRadarRange = 0
                end
            end

            local deltaAngle = 0
            if cachedServo then
                local ok, ang = pcall(cachedServo.getAngle)
                if ok and type(ang) == "number" then
                    isServoConnected = true
                    currentServoAngle = (math_deg(ang) + motorOffset) % 360
                    if lastServoAngle then
                        deltaAngle = math_abs(getAngleDiff(currentServoAngle, lastServoAngle))
                        if deltaAngle > 180 then deltaAngle = 0 end
                    end
                    lastServoAngle = currentServoAngle
                else
                    isServoConnected = false
                    cachedServo = nil
                end
            else
                isServoConnected = false
            end

            if camera then
                local ok, pos = pcall(camera.getCameraPosition)
                if ok and pos then localPos = pos else localPos = nil end
                if not isHeadless then
                    pcall(function()
                        currentQAbs = camera.getAbsViewTransform()
                        currentQLoc = camera.getLocViewTransform()
                    end)
                    if currentQAbs and currentQLoc then
                        local iqx, iqy, iqz, iqw = quatInverse(
                            currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                        local hx, hy, hz = rotateVectorFast(0, 0, -1, iqx, iqy, iqz, iqw)
                        local sx, sy, sz = rotateVectorFast(hx, hy, hz,
                            currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                        currentNorthYawDeg = math_deg(math_atan2(-sx, sz))
                    end

                    -- 扫描目标
                    local bestTarget = nil
                    local now = os_clock()
                    local refPos = localPos
                    local sectorCenter = currentNorthYawDeg + yawOffset + sonarCenterOffset

                    if currentRadarRange > 0 and isServoConnected then
                        -- 更新真实距离
                        if refPos then
                            for _, data in pairs(targets) do
                                if data.realPos and not data.isBeacon then
                                    local cd = calcRangingDist(refPos, data.realPos)
                                    if cd then data.realDist = cd end
                                end
                            end
                        end

                        -- 剔除无效目标
                        for id, data in pairs(targets) do
                            if not data.isBeacon then
                                -- 深度检查
                                if data.realPos and data.realPos.y > -8 then
                                    targets[id] = nil
                                    if id == selectedTargetId then
                                        selectedTargetId = nil
                                        trackedTargetId = nil
                                        selectedTargetDistStr = nil
                                    end
                                    goto nextTarget
                                end
                                -- 距离检查
                                local oor = (not data.realDist) or
                                    (data.realDist < MIN_DISTANCE_LIMIT or data.realDist > MAX_DISTANCE_LIMIT)
                                local to = (not data.lastSeen) or (now - data.lastSeen > 3.0)
                                if oor or to then
                                    targets[id] = nil
                                    if id == selectedTargetId then
                                        selectedTargetId = nil
                                        trackedTargetId = nil
                                        selectedTargetDistStr = nil
                                    end
                                end
                            end
                            ::nextTarget::
                        end

                        -- 扫描
                        for id, data in pairs(targets) do
                            if data.isBeacon then goto continue end
                            data.isBeingScanned = false
                            if data.realPos and data.realDist
                                and data.realDist >= MIN_DISTANCE_LIMIT
                                and data.realDist <= MAX_DISTANCE_LIMIT
                                and (now - data.lastSeen < 3.0)
                            then
                                local tYaw = 0
                                if currentQAbs and currentQLoc and refPos then
                                    local iqx, iqy, iqz, iqw = quatInverse(
                                        currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                                    local dx = data.realPos.x - refPos.x
                                    local dy = data.realPos.y - refPos.y
                                    local dz = data.realPos.z - refPos.z
                                    local hx, hy, hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                                    local sx, sy, sz = rotateVectorFast(hx, hy, hz,
                                        currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                                    tYaw = math_deg(math_atan2(-sx, sz))
                                elseif refPos then
                                    _, tYaw = calculateLookAngles(
                                        refPos.x, refPos.y, refPos.z,
                                        data.realPos.x, data.realPos.y, data.realPos.z)
                                end
                                -- 必须在扇区及扫描扇区内
                                if isInSector(tYaw, sectorCenter, 90) and
                                    math_abs(getAngleDiff(tYaw, currentServoAngle)) <= (SCAN_SECTOR_WIDTH + deltaAngle) / 2 then
                                    data.isBeingScanned = true
                                    if not data.lastPainted or (now - data.lastPainted >= 1.0) then
                                        data.paintedPos = data.realPos
                                        data.paintedDist = data.realDist
                                        data.paintedYaw = tYaw
                                        data.lastPainted = now
                                        -- 发送照射消息（仍用原来的频道）
                                        pcall(function()
                                            modem.transmit(CHANNEL_SEND, CHANNEL_SEND,
                                                { v = 2, t = 2, si = myId, ti = id })
                                        end)
                                        if id == selectedTargetId then
                                            selectedTargetDistStr = string.format("%dm", math_floor(data.realDist + 0.5))
                                            selectedTargetDepth = SEA_LEVEL - data.realPos.y
                                        end
                                    end
                                end
                            end
                            ::continue::
                        end

                        -- 锁定目标
                        if selectedTargetId and targets[selectedTargetId] then
                            local data = targets[selectedTargetId]
                            if data.realDist and data.realDist >= MIN_DISTANCE_LIMIT
                                and data.realDist <= MAX_DISTANCE_LIMIT
                                and (now - data.lastSeen < 3.0) then
                                bestTarget = data
                                trackedTargetId = selectedTargetId
                            else
                                selectedTargetId = nil
                                trackedTargetId = nil
                                selectedTargetDistStr = nil
                                selectedTargetDepth = nil
                            end
                        else
                            selectedTargetId = nil
                            trackedTargetId = nil
                        end
                    end

                    if not bestTarget then
                        trackedTargetId = nil
                        isTargetInRange = false
                    else
                        isTargetInRange = true
                    end

                    if localPos and bestTarget and isTargetInRange then
                        if bestTarget.isBeingScanned then
                            local tPitch, tYaw = 0, 0
                            if currentQAbs and currentQLoc then
                                local iqx, iqy, iqz, iqw = quatInverse(
                                    currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                                local dx = bestTarget.paintedPos.x - localPos.x
                                local dy = bestTarget.paintedPos.y - localPos.y
                                local dz = bestTarget.paintedPos.z - localPos.z
                                local hx, hy, hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                                local sx, sy, sz = rotateVectorFast(hx, hy, hz,
                                    currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                                tYaw = math_deg(math_atan2(-sx, sz))
                                tPitch = math_deg(math_atan2(-sy, math_sqrt(sx*sx + sz*sz)))
                            else
                                tPitch, tYaw = calculateLookAngles(
                                    localPos.x, localPos.y, localPos.z,
                                    bestTarget.paintedPos.x, bestTarget.paintedPos.y, bestTarget.paintedPos.z)
                            end
                            local normYaw = tYaw % 360
                            local gridIdx = math_floor(normYaw / aimPrecision)
                            local snappedYaw = gridIdx * aimPrecision + (aimPrecision / 2)
                            if snappedYaw > 180 then snappedYaw = snappedYaw - 360 end
                            holdPitch = tPitch
                            holdYaw = snappedYaw
                            pcall(applyCameraAngle, tPitch, snappedYaw)
                        elseif holdPitch and holdYaw then
                            pcall(applyCameraAngle, holdPitch, holdYaw)
                        end
                    elseif holdPitch and holdYaw then
                        pcall(applyCameraAngle, holdPitch, holdYaw)
                    end
                end
            end
            sleep(isHeadless and 1.0 or 0.05)
        end
    end
end

-- ==========================================
-- 启动信息
-- ==========================================
term.clear()
term.setCursorPos(1,1)
term.setTextColor(colors.green)
print("ASDIC v2.0 - OK")
print(string.format("  Name      : %s  [fixed]", myLabel))
print(string.format("  Range     : %d - %d m", MIN_DISTANCE_LIMIT, MAX_DISTANCE_LIMIT))
print(string.format("  RDR GPU   : %d", #rdrGpuList))
print(string.format("  HUD Mon   : %d", #hudMonitorList))
sleep(1.0)

parallel.waitForAll(
    rdrGpuUI,
    hudMonitorUI,
    termUI,
    inputLoop,
    pingLoop,
    listenLoop,
    cameraLoop
    -- 移除 rwrRedstoneLoop 和 iffToggleLoop
)
