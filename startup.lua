 --[[
GHG Hydrophone + 简单 TMA + 多频道通信   v2.4.0
======================================================================
改动：
- TMA 简化为 50s/10s 两点法，TMA 显示器新布局
- 修正相对方位角 (相对本船 = paintedYaw, 相对世界 = paintedYaw+航向)
- 多频道通信：8888 为原有频道，8889 用于主动声纳，广播真实坐标并响应类型3 RWR
======================================================================]]

-- ==========================================
--  全局配置
-- ==========================================
local MAX_DISTANCE_LIMIT       = 5000.0
local STRESS_TO_DISTANCE_RATIO = 2.0
local CHANNEL                  = 8888          -- 原有频道 (水听/雷达网络)
local ACTIVE_SONAR_CHANNEL     = 8889          -- 主动声纳频道
local SCAN_SECTOR_WIDTH        = 20
local SEA_LEVEL                = -4

local TARGET_FADE_DURATION = 3.0
local TARGET_HOT_DURATION  = 1.0
local RWR_ARC_DURATION     = 1.0
local SPEED_FILTER_MIN     = 4.0    -- km/h
local SPEED_INTERVAL       = 3.0    -- 测速定时器间隔 (秒)

local REG_QUERY_TIMEOUT = 5.0

-- 简单 TMA 配置
local TMA_FIRST_WAIT  = 50.0  -- 第一次记录等待时间 (秒)
local TMA_SECOND_WAIT = 10.0  -- 第二次记录等待时间 (秒)

-- ==========================================
-- 外设初始化
-- ==========================================
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Wireless or Ender Modem not found!", 0) end
modem.open(CHANNEL)
modem.open(ACTIVE_SONAR_CHANNEL)    -- 打开主动声纳频道

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
local CONFIG_FILE = "radar_config.txt"

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
local currentQAbs, currentQLoc = nil, nil
local currentServoAngle        = 0
local isServoConnected         = false
local yawOffset    = 0
local motorOffset  = 0
local myLabel      = os.getComputerLabel() or ("Entity-" .. myId)
local monitorModes = {}
local aimPrecision = 5
local currentStressCapacity = 0
local currentRadarRange     = 0
local currentNorthYawDeg    = 0      -- 船首真实航向 (摄像头指向)
local currentScreenTab      = 1      -- 1=配置, 2=状态, 3=设备
local menuIndex             = 1
local isEditing             = false
local inputStr              = ""
local cachedStressometer    = peripheral.find("Create_Stressometer")
local cachedServo           = peripheral.find("servo")
local targetPool            = {}
local targetPoolCount       = 0
local rwrEvents             = {}
local speedTimer            = nil

-- 简单 TMA 状态
local tmaMonitor = nil
local tmaData = nil
local tmaLastResult = nil

-- TPS 估算
local tpsEstimate = 20.0
local lastEpoch, lastClock = 0, 0

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
    if not targetPos.x then return nil end
    local dx = targetPos.x - refPos.x
    local dy = targetPos.y - refPos.y
    local dz = targetPos.z - refPos.z
    return math_sqrt(dx*dx + dy*dy + dz*dz)
end

-- ==========================================
-- 颜色常量
-- ==========================================
local C = {
    BG          = 0x050A05,
    OUTER_RING  = 0xFFCC00,
    INNER_RING  = 0x997700,
    GRID        = 0x332200,
    SWEEP       = 0xFFFFFF,
    YELLOW      = 0xFFFF00,
    WHITE       = 0xFFFFFF,
    BLACK       = 0x000000,
    RWR_HOT     = 0xFFCC00,
    TARGET_LINE_DEFAULT = 0x0000FF,
    TARGET_LINE_LOCKED  = 0xFF0000,
    BEACON_UNK  = 0xFFFF44,
    BEACON_ALLY = 0x44FF44,
    UNREG_FG    = 0xFF2200,
    UNREG_BG    = 0x1A0000,
}

-- ==========================================
-- HUD / TMA Monitor 分配
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
        local entry = {
            m           = m,
            name        = name,
            displayName = "Monitor " .. mIndex,
            bw          = math.max(1, bw),
            bh          = math.max(1, bh),
            mode        = monitorModes[name] or "STATUS",
            termRow     = 0,
            lastSText   = nil, lastRText   = nil,
            lastLText   = nil, lastSpeedText = nil,
        }
        table.insert(hudMonitorList, entry)
        if mIndex == 2 and not tmaMonitor then
            tmaMonitor = m
        end
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
            local dotSize = 1
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
    print("Hydrophone v2.4.0 - Registration Check")
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

    modem.transmit(CHANNEL, CHANNEL, { v=2, t=4, i=myId })

    local timer = os.startTimer(REG_QUERY_TIMEOUT)
    while true do
        local ev, a, b, c, d = os.pullEvent()

        if ev == "modem_message" then
            if b == CHANNEL and type(d) == "table" and d.v == 2 then
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
        { "Register this hydrophone", colors.gray   },
        { "in scanner first.",        colors.gray   },
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
print("Registration OK. Starting hydrophone...")
sleep(0.5)

-- ==========================================
-- 简单 TMA 两点解算逻辑
-- ==========================================
local function simpleTMA(pos1, pos2, ownPos2, ownCourse)
    local dx = pos2.x - pos1.x
    local dz = pos2.z - pos1.z
    local dist = math_sqrt(dx*dx + dz*dz)
    local heading = math_deg(math_atan2(dx, dz)) % 360
    local speed_ms = dist / TMA_SECOND_WAIT
    local speed_kph = speed_ms * 3.6

    local dx2 = pos2.x - ownPos2.x
    local dz2 = pos2.z - ownPos2.z
    local range = math_sqrt(dx2*dx2 + dz2*dz2)

    local aob = 0
    local ownHdg = ownCourse % 360
    local tgtHdg = heading % 360
    if ownHdg > tgtHdg then
        aob = ownHdg - tgtHdg - 180
    else
        aob = ownHdg - tgtHdg + 180
    end
    if aob > 180 then aob = aob - 360 end
    if aob < -180 then aob = aob + 360 end

    return { heading = heading, speed = speed_kph, range = range, aob = aob }
end

-- ==========================================
-- TMA 循环（两点法）
-- ==========================================
local function tmaLoop()
    while true do
        sleep(0.5)
        local now = os_clock()
        local selId = selectedTargetId
        local sel = targets[selId]

        if not sel then
            tmaData = nil
            goto continue
        end

        if not tmaData or tmaData.targetId ~= selId then
            tmaData = {
                targetId = selId,
                phase = "wait_first",
                firstPos = nil,
                secondPos = nil,
                firstTime = 0,
                secondTime = 0,
                startTime = os_clock(),
                measurementCount = (tmaData and tmaData.measurementCount) or 0
            }
        end

        if tmaData.phase == "wait_first" then
            if now - tmaData.startTime >= TMA_FIRST_WAIT then
                if sel.realPos then
                    tmaData.firstPos = {x=sel.realPos.x, y=sel.realPos.y, z=sel.realPos.z}
                    tmaData.firstTime = now
                    tmaData.phase = "wait_second"
                    tmaData.startTime = now
                else
                    tmaData = nil
                end
            end
        elseif tmaData.phase == "wait_second" then
            if now - tmaData.startTime >= TMA_SECOND_WAIT then
                if sel.realPos then
                    tmaData.secondPos = {x=sel.realPos.x, y=sel.realPos.y, z=sel.realPos.z}
                    tmaData.secondTime = now
                    if tmaData.firstPos and tmaData.secondPos and localPos then
                        local result = simpleTMA(
                            tmaData.firstPos, tmaData.secondPos,
                            localPos, currentNorthYawDeg
                        )
                        tmaLastResult = result
                        tmaData.measurementCount = tmaData.measurementCount + 1
                    end
                    tmaData.phase = "done"
                    tmaData.startTime = now
                else
                    tmaData = nil
                end
            end
        elseif tmaData.phase == "done" then
            if now - tmaData.startTime >= 1.0 then
                tmaData.phase = "wait_first"
                tmaData.startTime = now
                tmaData.firstPos = nil
                tmaData.secondPos = nil
            end
        end

        ::continue::
    end
end

-- ==========================================
-- TMA HUD 绘制协程 (新布局)
-- ==========================================
local function tmaHUDLoop()
    if not tmaMonitor then return end
    local lastRender = 0
    while true do
        sleep(0.2)
        local now = os_clock()
        if now - lastRender < 0.4 then goto continue end
        lastRender = now

        tmaMonitor.setBackgroundColor(colors.black)
        tmaMonitor.clear()
        local y = 1

        tmaMonitor.setTextColor(colors.cyan)
        tmaMonitor.setCursorPos(1, y); tmaMonitor.write("TMA Computer v1.0")
        y = y + 1

        local elapsed = 0
        local pts = 0
        if tmaData then
            elapsed = now - (tmaData.startTime or now)
            pts = tmaData.measurementCount or 0
        end
        tmaMonitor.setTextColor(colors.white)
        tmaMonitor.setCursorPos(1, y)
        tmaMonitor.write(string.format("Time: %d s  Meas: %d", math_floor(elapsed), pts))
        y = y + 1

        tmaMonitor.setTextColor(colors.green)
        tmaMonitor.setCursorPos(1, y)
        local displayRes = tmaLastResult
        if tmaData and tmaData.phase == "done" and tmaLastResult then
            displayRes = tmaLastResult
        end
        if displayRes then
            tmaMonitor.write(string.format("Rng: %.0f m  Spd: %.1f km/h  Hdg: %.0f",
                displayRes.range, displayRes.speed, displayRes.heading))
        else
            tmaMonitor.write("Rng: ---  Spd: ---  Hdg: ---")
        end
        y = y + 1

        tmaMonitor.setTextColor(colors.magenta)
        tmaMonitor.setCursorPos(1, y)
        if displayRes then
            local side = displayRes.aob >= 0 and "Stbd" or "Port"
            tmaMonitor.write(string.format("AOB: %+d deg (%s)", math_floor(displayRes.aob), side))
        else
            tmaMonitor.write("AOB: ---")
        end

        ::continue::
    end
end

-- ==========================================
-- GPU 绘制 (相对方位角使用 paintedYaw)
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
local function gpuDrawRadarBase(entry)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    g.fill(C.BG)
    gpuDrawCircle(g,cx,cy,r,C.OUTER_RING)
    gpuDrawCircle(g,cx,cy,math_floor(r/2),C.INNER_RING)
    g.line(cx,cy-r,cx,cy+r,C.GRID); g.line(cx-r,cy,cx+r,cy,C.GRID)
    for t=-r,r do
        if t%4<2 then
            local py=cy+t
            local px1=cx+t
            if (px1-cx)^2+(py-cy)^2<=r*r then g.line(px1,py,px1,py,C.GRID) end
            local px2=cx-t
            if (px2-cx)^2+(py-cy)^2<=r*r then g.line(px2,py,px2,py,C.GRID) end
        end
    end

    local dirs = {
        {angle=0,   label="N", isTick=false},
        {angle=45,  label="",  isTick=true},
        {angle=90,  label="E", isTick=false},
        {angle=135, label="",  isTick=true},
        {angle=180, label="S", isTick=false},
        {angle=225, label="",  isTick=true},
        {angle=270, label="W", isTick=false},
        {angle=315, label="",  isTick=true},
    }
    local northRad = math_rad(currentNorthYawDeg + yawOffset)
    for _, d in ipairs(dirs) do
        local dirRad = northRad + math_rad(d.angle)
        if d.isTick then
            local startX = cx + math_floor((r-4) * math_sin(dirRad) + 0.5)
            local startY = cy - math_floor((r-4) * math_cos(dirRad) + 0.5)
            local endX = cx + math_floor(r * math_sin(dirRad) + 0.5)
            local endY = cy - math_floor(r * math_cos(dirRad) + 0.5)
            g.line(startX, startY, endX, endY, C.OUTER_RING)
        else
            local txX = cx + math_floor((r-6) * math_sin(dirRad) - 3)
            local txY = cy - math_floor((r-6) * math_cos(dirRad) + 4)
            txX = math_max(1, math_min(entry.w-6, txX))
            txY = math_max(1, math_min(entry.h-8, txY))
            pcall(g.drawText, txX, txY, d.label, C.WHITE, C.BG, 1)
        end
    end
end

local function gpuDrawSweep(entry, angleDeg)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    local rad=math_rad(angleDeg+yawOffset)
    local ex=cx+math_floor(r*math_sin(rad)+0.5)
    local ey=cy-math_floor(r*math_cos(rad)+0.5)
    g.line(cx,cy,ex,ey,C.SWEEP)
    local arrowLen = 3
    local angle1 = rad + math_rad(150)
    local angle2 = rad - math_rad(150)
    local ax1 = ex + math_floor(arrowLen * math_sin(angle1))
    local ay1 = ey - math_floor(arrowLen * math_cos(angle1))
    local ax2 = ex + math_floor(arrowLen * math_sin(angle2))
    local ay2 = ey - math_floor(arrowLen * math_cos(angle2))
    g.line(ex, ey, ax1, ay1, C.SWEEP)
    g.line(ex, ey, ax2, ay2, C.SWEEP)
end

local function gpuDrawRwrArcs(entry)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    local now=os_clock()
    local ARC_R_INNER=r+3; local ARC_R_OUTER=r+5
    for i=#rwrEvents,1,-1 do
        if now-rwrEvents[i].time>=RWR_ARC_DURATION then table.remove(rwrEvents,i) end
    end
    for _,ev in ipairs(rwrEvents) do
        local age=now-ev.time
        local col=colorLerp(C.RWR_HOT,C.BG,age/RWR_ARC_DURATION)
        if col~=C.BG then
            local centerRad=math_rad(ev.yawDeg+yawOffset)
            local halfSpan=math_rad(22.5); local ARC_STEP=math_rad(0.5)
            local steps=math_floor(math_rad(45)/ARC_STEP)+1
            for arcR=ARC_R_INNER,ARC_R_OUTER do
                for s=0,steps do
                    local a=centerRad-halfSpan+ARC_STEP*s
                    local px=cx+math_floor(arcR*math_sin(a)+0.5)
                    local py=cy-math_floor(arcR*math_cos(a)+0.5)
                    if px>=1 and px<=entry.w and py>=1 and py<=entry.h then
                        g.line(px,py,px,py,col)
                    end
                end
            end
        end
    end
end

local function gpuRefreshRadar(entry, isActive, poolCount, pool)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy
    local r=entry.r; local lineLength = r * 0.75
    gpuDrawRadarBase(entry)
    gpuDrawRwrArcs(entry)
    if isActive and localPos then
        for i=1, poolCount do
            local t = pool[i]
            if t and t.col then
                local endX = cx + math_floor(lineLength * t.s + 0.5)
                local endY = cy - math_floor(lineLength * t.cs + 0.5)
                g.line(cx, cy, endX, endY, t.col)
                if t.relAngle then
                    local angleStr = tostring(t.relAngle) .. "°"
                    local textX = endX + math_floor(5 * t.s + 0.5)
                    local textY = endY - math_floor(5 * t.cs + 0.5) - 4
                    textX = math_max(2, math_min(entry.w - #angleStr * 3, textX))
                    textY = math_max(2, math_min(entry.h - 8, textY))
                    pcall(g.drawText, textX, textY, angleStr, t.col, C.BG, 0.5)
                end
            end
        end
    end
    if isActive then gpuDrawSweep(entry, currentServoAngle) end
    g.sync()
end

-- ==========================================
-- RDR GPU 主循环
-- ==========================================
local function rdrGpuUI()
    if #rdrGpuList==0 then return end
    local frames=0; local lastActive=false
    while true do
        if currentScreenTab==3 then
            for _,entry in ipairs(rdrGpuList) do
                pcall(function()
                    entry.gpu.fill(C.BG)
                    pcall(entry.gpu.drawText,entry.cx-6,entry.cy-4, entry.name,C.WHITE,C.BG,2)
                    entry.gpu.sync()
                end)
            end
            sleep(0.3)
        else
            frames=frames+1
            local isActive=(currentRadarRange>0) and isServoConnected
            local forceRedraw = (isActive~=lastActive)
            lastActive=isActive
            targetPoolCount=0
            local now=os_clock()
            if localPos and isActive then
                for _,data in pairs(targets) do
                    if data.lastPainted and not data.isBeacon then
                        local age=now-data.lastPainted
                        if age<TARGET_FADE_DURATION then
                            if data.speed and (data.speed * 3.6) >= SPEED_FILTER_MIN then
                                local col = data.isSelected and C.TARGET_LINE_LOCKED or C.TARGET_LINE_DEFAULT
                                local yawRad = math_rad(data.paintedYaw + yawOffset)
                                targetPoolCount=targetPoolCount+1
                                local t=targetPool[targetPoolCount]
                                if not t then t={}; targetPool[targetPoolCount]=t end
                                t.col = col
                                t.s = math_sin(yawRad)
                                t.cs = math_cos(yawRad)
                                local relAngle = math_floor((data.paintedYaw) % 360 + 0.5) % 360
                                t.relAngle = relAngle
                            end
                        end
                    end
                end
            end
            local hasRwr=(#rwrEvents>0)
            for _,entry in ipairs(rdrGpuList) do
                local angleDiff=math_abs(getAngleDiff(currentServoAngle,entry.lastSweepDeg))
                if forceRedraw or angleDiff>0.5 or frames<=2 or hasRwr or targetPoolCount>0 then
                    entry.lastSweepDeg=currentServoAngle
                    pcall(gpuRefreshRadar,entry,isActive,targetPoolCount,targetPool)
                end
            end
            sleep(0.05)
        end
    end
end

-- ==========================================
-- HUD 主循环 (相对方位 = paintedYaw)
-- ==========================================
local function hudMonitorUI()
    if #hudMonitorList==0 then return end
    local frames=0
    while true do
        frames=frames+1
        local isFirstFrame=(frames<=2)
        local isActive=(currentRadarRange>0) and isServoConnected
        for _,info in ipairs(hudMonitorList) do
            if info.m == tmaMonitor then goto continueHUD end
            if info.mode=="STATUS" then
                local sText,sColor = "GHG hydrophone", colors.green
                local rText,rColor = "", colors.lime
                local lText,lColor = "", colors.white
                local speedText,speedColor = "", colors.white

                if isActive then
                    rText = string.format("%dm", math_floor(currentRadarRange))
                    rColor = colors.lime
                    if selectedTargetId and targets[selectedTargetId] then
                        local sel = targets[selectedTargetId]
                        local relBoat = math_floor((sel.paintedYaw or 0) % 360 + 0.5) % 360
                        local absWorld = math_floor((sel.paintedYaw or 0) + currentNorthYawDeg + 0.5) % 360
                        lText = string.format("%.0f / %.0f", relBoat, absWorld)
                        lColor = colors.white
                        local radSpd = sel.radialSpeed or 0
                        local tendency = "="
                        if radSpd > 0.1 then tendency = "A"
                        elseif radSpd < -0.1 then tendency = "C" end
                        local spd = (sel.speed or 0) * 3.6
                        speedText = string.format("%.1f km/h %s", spd, tendency)
                        speedColor = colors.white
                    else
                        lText = "--- / ---"
                        speedText = "---"
                    end
                else
                    rText = "---"; rColor = colors.gray
                    lText = "--- / ---"; lColor = colors.gray
                    speedText = "---"; speedColor = colors.gray
                end

                if isFirstFrame or sText~=info.lastSText or rText~=info.lastRText
                    or lText~=info.lastLText or speedText~=info.lastSpeedText
                then
                    info.m.setTextScale(1)
                    info.m.setBackgroundColor(colors.black)
                    info.m.clear()
                    local dw,dh=info.m.getSize()
                    local y1 = math_max(1, math_floor(dh/2)-3)
                    local y2 = math_max(2, math_floor(dh/2)-1)
                    local y3 = math_max(3, math_floor(dh/2)+1)
                    local y4 = math_max(4, math_floor(dh/2)+3)
                    local function drawCL(txt,col,yPos)
                        info.m.setTextColor(col)
                        local sx=math_max(1, math_floor((dw-#txt)/2)+1)
                        info.m.setCursorPos(sx,yPos); info.m.write(txt)
                    end
                    drawCL(sText,sColor,y1)
                    drawCL(rText,rColor,y2)
                    drawCL(lText,lColor,y3)
                    drawCL(speedText,speedColor,y4)
                    info.lastSText=sText; info.lastRText=rText
                    info.lastLText=lText; info.lastSpeedText=speedText
                end
            end
            ::continueHUD::
        end
        sleep(0.1)
    end
end

-- ==========================================
-- 终端 UI (三页，去除 TMA 参数编辑)
-- ==========================================
local function termUI()
    while true do
        term.setBackgroundColor(colors.black)
        term.clear()
        local w, h = term.getSize()

        local tabs = {"CONFIG", "STATUS", "DEVICES"}
        local tabStr = ""
        for i, t in ipairs(tabs) do
            tabStr = tabStr .. (i == currentScreenTab and ("["..t.."]") or " "..t.." ") .. "  "
        end
        term.setCursorPos(2,1); term.setTextColor(colors.white)
        term.write("TAB " .. tabStr)

        if currentScreenTab == 1 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== PARAMETERS ===")
            local function drawInputBox(y, label, val, isSel, isEdit)
                term.setCursorPos(2,y); term.setBackgroundColor(colors.black)
                term.setTextColor(isSel and colors.yellow or colors.lightGray)
                term.write(label)
                term.setCursorPos(17,y); term.setBackgroundColor(colors.gray)
                local txt = (isSel and isEdit) and (inputStr.."_") or tostring(val)
                term.setTextColor(isSel and colors.white or colors.lightGray)
                term.write(string.format(" %-12s ", txt))
                term.setBackgroundColor(colors.black)
            end
            drawInputBox(5,  "Disp. Offset :", yawOffset,    menuIndex==1, isEditing)
            drawInputBox(7,  "Motor Offset :", motorOffset,  menuIndex==2, isEditing)
            drawInputBox(9,  "Aim Precis   :", aimPrecision, menuIndex==3, isEditing)

        elseif currentScreenTab == 2 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            local row = 5
            term.setCursorPos(2,row); term.setTextColor(colors.lime)
            term.write("Registered : " .. myLabel); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.cyan)
            term.write(string.format("Max Range  : %.0f m", MAX_DISTANCE_LIMIT)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.lightGray)
            term.write(string.format("SU Ratio   : %g SU/m", STRESS_TO_DISTANCE_RATIO)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.green)
            term.write("Camera     : ONLINE"); row = row+1
            row = row+1
            if isServoConnected then
                term.setCursorPos(2,row); term.setTextColor(colors.white)
                term.write(string.format("Motor Angle: %6.1f deg", currentServoAngle)); row = row+1
            else
                term.setCursorPos(2,row); term.setTextColor(colors.red)
                term.write("Motor Angle: OFFLINE"); row = row+1
            end
            if currentRadarRange==0 then
                term.setCursorPos(2,row); term.setTextColor(colors.red)
                term.write("Op. Range  : 0.0 (No Power!)"); row = row+1
            elseif not isServoConnected then
                term.setCursorPos(2,row); term.setTextColor(colors.red)
                term.write("Op. Range  : 0.0 (No Motor!)"); row = row+1
            else
                term.setCursorPos(2,row); term.setTextColor(colors.green)
                term.write(string.format("Op. Range  : %.1f m", currentRadarRange)); row = row+1
            end
            term.setCursorPos(2,row); term.setTextColor(colors.gray)
            term.write(string.format("North Yaw  : %.1f deg", currentNorthYawDeg)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.gray)
            term.write(string.format("Aim grid   : %d deg/step", aimPrecision)); row = row+1
            local beaconCount = 0
            for _, d in pairs(targets) do if d.isBeacon then beaconCount = beaconCount+1 end end
            term.setCursorPos(2,row); term.setTextColor(colors.yellow)
            term.write(string.format("Beacons    : %d online", beaconCount)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.lightGray)
            term.write(string.format("TPS (est.) : %.1f", tpsEstimate))

        else
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== DISPLAYS ===")
            local row = 5
            term.setCursorPos(2,row); term.setTextColor(colors.cyan)
            term.write("[RDR GPU]"); row = row+1
            if #rdrGpuList == 0 then
                term.setCursorPos(4,row); term.setTextColor(colors.red)
                term.write("None"); row = row+1
            else
                for _, e in ipairs(rdrGpuList) do
                    term.setCursorPos(4,row); term.setTextColor(colors.lightBlue)
                    term.write(e.name .. string.format("  [%dx%d]", e.w, e.h)); row = row+1
                end
            end
            row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.cyan)
            term.write("[HUD Monitors]"); row = row+1
            if #hudMonitorList == 0 then
                term.setCursorPos(4,row); term.setTextColor(colors.red)
                term.write("None"); row = row+1
            else
                for _, info in ipairs(hudMonitorList) do
                    local role = (info.m == tmaMonitor) and " [TMA]" or ""
                    term.setCursorPos(4,row); term.setTextColor(colors.lightBlue)
                    term.write(info.displayName .. " (" .. info.name .. ")" .. role); row = row+1
                end
            end
            if tmaMonitor then
                term.setCursorPos(4,row); term.setTextColor(colors.yellow)
                term.write("TMA display: attached")
            end
        end

        sleep(0.2)
    end
end

-- ==========================================
-- 输入事件循环
-- ==========================================
local function inputLoop()
    local function applySave()
        if menuIndex==1 then
            local p=tonumber(inputStr); if p then yawOffset=p end
        elseif menuIndex==2 then
            local p=tonumber(inputStr); if p then motorOffset=p end
        elseif menuIndex==3 then
            local p=tonumber(inputStr)
            if p then
                p=math_floor(math_abs(p))
                if p>=1 and p<=90 and (360%p==0) then aimPrecision=p end
            end
        end
        saveConfig(); isEditing=false
    end

    while true do
        local event,p1,p2,p3=os_pullEvent()

        if event=="key" then
            if p1==keys.tab then
                currentScreenTab = (currentScreenTab % 3) + 1
            elseif isEditing and currentScreenTab==1 then
                if p1==keys.enter or p1==keys.numPadEnter then
                    applySave()
                elseif p1==keys.backspace then
                    inputStr=inputStr:sub(1,-2)
                end
            elseif currentScreenTab==1 then
                if     p1==keys.up   then menuIndex=math_max(1,menuIndex-1)
                elseif p1==keys.down then menuIndex=math_min(3,menuIndex+1)
                elseif p1==keys.enter or p1==keys.numPadEnter then
                    isEditing=true
                    if     menuIndex==1 then inputStr=tostring(yawOffset)
                    elseif menuIndex==2 then inputStr=tostring(motorOffset)
                    elseif menuIndex==3 then inputStr=tostring(aimPrecision)
                    end
                end
            end
        elseif event=="char" and isEditing and currentScreenTab==1 then
            if (p1>='0' and p1<='9') or p1=='.' or (p1=='-' and #inputStr==0) then
                if #inputStr<8 then inputStr=inputStr..p1 end
            end
        elseif event=="mouse_click" then
            local touchY=p3
            if currentScreenTab==1 then
                local ti=nil
                if     touchY==5 then ti=1
                elseif touchY==7 then ti=2
                elseif touchY==9 then ti=3
                end
                if ti then
                    if isEditing and menuIndex~=ti then applySave() end
                    menuIndex=ti; isEditing=true
                    if     menuIndex==1 then inputStr=tostring(yawOffset)
                    elseif menuIndex==2 then inputStr=tostring(motorOffset)
                    elseif menuIndex==3 then inputStr=tostring(aimPrecision)
                    end
                else
                    if isEditing then applySave() end
                end
            end
        elseif (event=="tm_monitor_touch" or event=="tm_monitor_mouse_click") and currentScreenTab<=2 then
            local touchedName=p1; local mx,my=p2,p3
            local entry=gpuNameMap[touchedName]
            if entry and localPos and currentRadarRange>0 and isServoConnected then
                local cx, cy, r = entry.cx, entry.cy, entry.r
                local distFromCenter = math_sqrt((mx-cx)^2 + (my-cy)^2)
                if distFromCenter < 5 or distFromCenter > r+10 then
                    selectedTargetId = nil
                    selectedTargetDistStr = nil
                else
                    local bestId = nil
                    local bestDist = 99999
                    for _, data in pairs(targets) do
                        if data.lastPainted and not data.isBeacon and data.speed and (data.speed*3.6) >= SPEED_FILTER_MIN then
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
                        selectedTargetId = bestId
                        if targets[bestId] and targets[bestId].realDist then
                            selectedTargetDistStr = string.format("%dm", math_floor(targets[bestId].realDist+0.5))
                        end
                    else
                        selectedTargetId = nil
                        selectedTargetDistStr = nil
                    end
                end
            end
        end
    end
end

-- ==========================================
-- 网络 & 红石 & 测速 & 扫描 (多频道)
-- ==========================================
local function pingLoop()
    while true do
        if currentScreenTab==3 then sleep(0.5)
        else
            if localPos then
                local baseMsg = {
                    v=2, t=1, i=myId, n=myLabel,
                    r=currentRadarRange,
                }
                -- 8888 频道
                local msg8888 = {}
                for k,v in pairs(baseMsg) do msg8888[k]=v end
                if localPos.y > -8 then
                    msg8888.x = math_floor(localPos.x*10)/10
                    msg8888.y = math_floor(localPos.y*10)/10
                    msg8888.z = math_floor(localPos.z*10)/10
                else
                    msg8888.x = 0; msg8888.y = 0; msg8888.z = 0
                end
                modem.transmit(CHANNEL, CHANNEL, msg8888)

                -- 8889 频道 (永远真实坐标)
                local msg8889 = {}
                for k,v in pairs(baseMsg) do msg8889[k]=v end
                msg8889.x = math_floor(localPos.x*10)/10
                msg8889.y = math_floor(localPos.y*10)/10
                msg8889.z = math_floor(localPos.z*10)/10
                modem.transmit(ACTIVE_SONAR_CHANNEL, ACTIVE_SONAR_CHANNEL, msg8889)
            end
            local now=os_clock()
            for id,data in pairs(targets) do
                if not data.isBeacon and id~=selectedTargetId
                    and data.lastSeen and (now-data.lastSeen>10.0)
                then targets[id]=nil end
                if data.isBeacon and data.lastSeen and (now-data.lastSeen>10.0) then
                    targets[id]=nil
                end
            end
            sleep(1.0)
        end
    end
end
local function listenLoop()
    while true do
        local _,_,ch,_,msg,dist=os_pullEvent("modem_message")
        if type(msg)~="table" or msg.v~=2 then goto nextMsg end

        if ch == CHANNEL then
            -- 原有频道处理
            if msg.t==1 and msg.i~=myId then
                if not targets[msg.i] then targets[msg.i] = {id=msg.i} end
                local t = targets[msg.i]
                t.name=msg.n; t.modemDist=dist
                if msg.x then t.realPos={x=msg.x, y=msg.y, z=msg.z} end
                t.range=msg.r; t.lastSeen=os_clock(); t.isBeacon=false
                local cd = calcRangingDist(localPos, t.realPos)
                t.realDist = cd or dist
            elseif msg.t==3 and msg.ti == myId then
                -- RWR 处理
                local rwrYaw = nil
                if msg.x and msg.y and msg.z and localPos then
                    local sp = {x=msg.x, y=msg.y, z=msg.z}
                    if currentQAbs and currentQLoc then
                        local iqx,iqy,iqz,iqw=quatInverse(
                            currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                        local dx=sp.x-localPos.x
                        local dy=sp.y-localPos.y
                        local dz=sp.z-localPos.z
                        local hx,hy,hz=rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                        local sx,sy,sz=rotateVectorFast(hx,hy,hz,
                            currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                        rwrYaw=math_deg(math_atan2(-sx,sz))
                    else
                        _,rwrYaw=calculateLookAngles(
                            localPos.x,localPos.y,localPos.z,sp.x,sp.y,sp.z)
                    end
                end
                if rwrYaw then
                    local normYaw=rwrYaw%360
                    local sectorIdx=math_floor((normYaw+22.5)/45)%8
                    local quantYaw=sectorIdx*45
                    if quantYaw>180 then quantYaw=quantYaw-360 end
                    table.insert(rwrEvents,{yawDeg=quantYaw,time=os_clock()})
                end
                os_queueEvent("rwr_detected")
            end
        elseif ch == ACTIVE_SONAR_CHANNEL then
            -- 主动声纳频道：仅处理被锁定告警（类型3）
            if msg.t==3 and msg.ti == myId then
                local rwrYaw = nil
                if msg.x and msg.y and msg.z and localPos then
                    local sp = {x=msg.x, y=msg.y, z=msg.z}
                    if currentQAbs and currentQLoc then
                        local iqx,iqy,iqz,iqw=quatInverse(
                            currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                        local dx=sp.x-localPos.x
                        local dy=sp.y-localPos.y
                        local dz=sp.z-localPos.z
                        local hx,hy,hz=rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                        local sx,sy,sz=rotateVectorFast(hx,hy,hz,
                            currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                        rwrYaw=math_deg(math_atan2(-sx,sz))
                    else
                        _,rwrYaw=calculateLookAngles(
                            localPos.x,localPos.y,localPos.z,sp.x,sp.y,sp.z)
                    end
                end
                if rwrYaw then
                    local normYaw=rwrYaw%360
                    local sectorIdx=math_floor((normYaw+22.5)/45)%8
                    local quantYaw=sectorIdx*45
                    if quantYaw>180 then quantYaw=quantYaw-360 end
                    table.insert(rwrEvents,{yawDeg=quantYaw,time=os_clock()})
                end
                os_queueEvent("rwr_detected")
            end
        end
        ::nextMsg::
    end
end

local function rwrRedstoneLoop()
    local rwrTimer=nil
    while true do
        local event,p1=os_pullEvent()
        if event=="rwr_detected" then
            redstone.setOutput("front",true)
            if rwrTimer then os.cancelTimer(rwrTimer) end
            rwrTimer=os.startTimer(0.5)
        elseif event=="timer" and p1==rwrTimer then
            redstone.setOutput("front",false); rwrTimer=nil
        end
    end
end

local function speedTimerLoop()
    while true do
        local event, timerId = os_pullEvent("timer")
        if event == "timer" and timerId == speedTimer then
            local nowClock = os_clock()
            local nowEpoch = os.epoch("utc")
            if lastEpoch > 0 and lastClock > 0 then
                local gameDelta = nowClock - lastClock
                local realDelta = (nowEpoch - lastEpoch) / 1000.0
                if realDelta > 0.001 and gameDelta > 0 then
                    tpsEstimate = 20.0 * gameDelta / realDelta
                else
                    tpsEstimate = 20.0
                end
            end
            lastClock, lastEpoch = nowClock, nowEpoch
            local tpsFactor = tpsEstimate / 20.0

            for id, data in pairs(targets) do
                if data.realPos and data.lastPos and data.lastTime then
                    local dt = nowClock - data.lastTime
                    if dt > 0.5 then
                        local dx = data.realPos.x - data.lastPos.x
                        local dy = data.realPos.y - data.lastPos.y
                        local dz = data.realPos.z - data.lastPos.z
                        local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                        data.speed = (dist / dt) * tpsFactor

                        if data.realDist and data.realDist > 0.01 and localPos then
                            local relX = data.realPos.x - localPos.x
                            local relY = data.realPos.y - localPos.y
                            local relZ = data.realPos.z - localPos.z
                            data.radialSpeed = ((dx*relX + dy*relY + dz*relZ) / (data.realDist * dt)) * tpsFactor
                        else
                            data.radialSpeed = 0
                        end
                    end
                end
                if data.realPos then
                    data.lastPos = {x = data.realPos.x, y = data.realPos.y, z = data.realPos.z}
                    data.lastTime = nowClock
                end
            end
            speedTimer = os.startTimer(SPEED_INTERVAL)
        end
    end
end

local function cameraLoop()
    local lastServoAngle=nil; local peripheralPollTick=0
    while true do
        if currentScreenTab==3 then sleep(0.5)
        else
            if peripheralPollTick<=0 then
                peripheralPollTick=20
                if not cachedStressometer then
                    cachedStressometer=peripheral.find("Create_Stressometer")
                end
                if not cachedServo then cachedServo=peripheral.find("servo") end
            else peripheralPollTick=peripheralPollTick-1 end

            if cachedStressometer then
                local ok,cap=pcall(cachedStressometer.getStressCapacity)
                if ok then currentStressCapacity=cap or 0
                else cachedStressometer=nil; currentStressCapacity=0 end
            end

            local deltaAngle=0
            if cachedServo then
                local ok,ang=pcall(cachedServo.getAngle)
                if ok and type(ang)=="number" then
                    isServoConnected=true
                    currentServoAngle=(math_deg(ang)+motorOffset)%360
                    if lastServoAngle then
                        deltaAngle=math_abs(getAngleDiff(currentServoAngle,lastServoAngle))
                        if deltaAngle>180 then deltaAngle=0 end
                    end
                    lastServoAngle=currentServoAngle
                else isServoConnected=false; cachedServo=nil end
            else isServoConnected=false end

            local depthDynamicMax = MAX_DISTANCE_LIMIT
            if localPos then
                local depth = -localPos.y
                if localPos.y >= SEA_LEVEL then
                    depthDynamicMax = 1000
                elseif localPos.y <= -14 then
                    depthDynamicMax = 5000
                else
                    depthDynamicMax = 1000 + 400 * (depth - 4)
                end
            end
            local safeRatio=math_max(STRESS_TO_DISTANCE_RATIO,0.001)
            currentRadarRange=math_min(
                currentStressCapacity/safeRatio, depthDynamicMax)

            if camera then
                local ok,pos=pcall(camera.getCameraPosition)
                if ok and pos then localPos=pos else localPos=nil end
                if not isHeadless then
                    pcall(function()
                        currentQAbs=camera.getAbsViewTransform()
                        currentQLoc=camera.getLocViewTransform()
                    end)
                    if currentQAbs and currentQLoc then
                        local iqx,iqy,iqz,iqw=quatInverse(
                            currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                        local hx,hy,hz=rotateVectorFast(0,0,-1,iqx,iqy,iqz,iqw)
                        local sx,sy,sz=rotateVectorFast(hx,hy,hz,
                            currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                        currentNorthYawDeg=math_deg(math_atan2(-sx,sz))
                    end
                    local bestTarget=nil
                    local now=os_clock(); local refPos=localPos
                    if currentRadarRange>0 and isServoConnected then
                        local effectiveSW=SCAN_SECTOR_WIDTH+deltaAngle
                        if refPos then
                            for _,data in pairs(targets) do
                                if data.realPos and not data.isBeacon then
                                    local cd=calcRangingDist(refPos,data.realPos)
                                    if cd then data.realDist=cd end
                                end
                            end
                        end
                        for id,data in pairs(targets) do
                            if data.isBeacon then goto continue end
                            data.isBeingScanned=false
                            if data.realPos and data.realDist
                                and data.realDist<=currentRadarRange
                                and (now-data.lastSeen<3.0)
                            then
                                local tYaw=0
                                if currentQAbs and currentQLoc and refPos then
                                    local iqx,iqy,iqz,iqw=quatInverse(
                                        currentQAbs.x,currentQAbs.y,
                                        currentQAbs.z,currentQAbs.w)
                                    local dx=data.realPos.x-refPos.x
                                    local dy=data.realPos.y-refPos.y
                                    local dz=data.realPos.z-refPos.z
                                    local hx,hy,hz=rotateVectorFast(
                                        dx,dy,dz,iqx,iqy,iqz,iqw)
                                    local sx,sy,sz=rotateVectorFast(hx,hy,hz,
                                        currentQLoc.x,currentQLoc.y,
                                        currentQLoc.z,currentQLoc.w)
                                    tYaw=math_deg(math_atan2(-sx,sz))
                                elseif refPos then
                                    _,tYaw=calculateLookAngles(
                                        refPos.x,refPos.y,refPos.z,
                                        data.realPos.x,data.realPos.y,data.realPos.z)
                                end
                                if math_abs(getAngleDiff(tYaw,currentServoAngle))
                                    <=effectiveSW/2
                                then
                                    data.isBeingScanned=true
                                    if not data.lastPainted or
                                        (now-data.lastPainted>=1.0)
                                    then
                                        data.paintedPos=data.realPos
                                        data.paintedDist=data.realDist
                                        data.paintedYaw=tYaw
                                        data.lastPainted=now
                                        if id==selectedTargetId then
                                            selectedTargetDistStr=string.format(
                                                "%dm",math_floor(data.realDist+0.5))
                                        end
                                    end
                                end
                            end
                            ::continue::
                        end
                        if selectedTargetId and targets[selectedTargetId] then
                            local data=targets[selectedTargetId]
                            if data.realDist and data.realDist<=currentRadarRange
                                and (now-data.lastSeen<3.0)
                            then
                                bestTarget=data; trackedTargetId=selectedTargetId
                                data.isSelected = true
                            else
                                data.isSelected = false
                                selectedTargetId=nil; trackedTargetId=nil
                                selectedTargetDistStr=nil
                            end
                        else
                            if selectedTargetId then
                                if targets[selectedTargetId] then targets[selectedTargetId].isSelected = false end
                                selectedTargetId=nil
                                trackedTargetId=nil
                            end
                        end
                    end
                    if not bestTarget then
                        trackedTargetId=nil; isTargetInRange=false
                    else isTargetInRange=true end
                    if localPos and bestTarget and isTargetInRange then
                        if bestTarget.isBeingScanned then
                            local tPitch,tYaw=0,0
                            if currentQAbs and currentQLoc then
                                local iqx,iqy,iqz,iqw=quatInverse(
                                    currentQAbs.x,currentQAbs.y,
                                    currentQAbs.z,currentQAbs.w)
                                local dx=bestTarget.paintedPos.x-localPos.x
                                local dy=bestTarget.paintedPos.y-localPos.y
                                local dz=bestTarget.paintedPos.z-localPos.z
                                local hx,hy,hz=rotateVectorFast(
                                    dx,dy,dz,iqx,iqy,iqz,iqw)
                                local sx,sy,sz=rotateVectorFast(hx,hy,hz,
                                    currentQLoc.x,currentQLoc.y,
                                    currentQLoc.z,currentQLoc.w)
                                tYaw=math_deg(math_atan2(-sx,sz))
                                tPitch=math_deg(math_atan2(-sy,
                                    math_sqrt(sx*sx+sz*sz)))
                            else
                                tPitch,tYaw=calculateLookAngles(
                                    localPos.x,localPos.y,localPos.z,
                                    bestTarget.paintedPos.x,
                                    bestTarget.paintedPos.y,
                                    bestTarget.paintedPos.z)
                            end
                            local normYaw=tYaw%360
                            local gridIdx=math_floor(normYaw/aimPrecision)
                            local snappedYaw=gridIdx*aimPrecision+(aimPrecision/2)
                            if snappedYaw>180 then snappedYaw=snappedYaw-360 end
                            holdPitch=tPitch; holdYaw=snappedYaw
                            pcall(applyCameraAngle,tPitch,snappedYaw)
                        elseif holdPitch and holdYaw then
                            pcall(applyCameraAngle,holdPitch,holdYaw)
                        end
                    elseif holdPitch and holdYaw then
                        pcall(applyCameraAngle,holdPitch,holdYaw)
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
print("GHG Hydrophone v2.4.0 - OK")
print(string.format("  Name      : %s  [fixed]", myLabel))
print(string.format("  Max Range : %.0f m", MAX_DISTANCE_LIMIT))
print(string.format("  RDR GPU   : %d", #rdrGpuList))
print(string.format("  HUD Mon   : %d", #hudMonitorList))
if tmaMonitor then print("  TMA Monitor: attached") end
sleep(1.0)

speedTimer = os.startTimer(SPEED_INTERVAL)

parallel.waitForAll(
    rdrGpuUI,
    hudMonitorUI,
    tmaHUDLoop,
    termUI,
    inputLoop,
    pingLoop,
    listenLoop,
    cameraLoop,
    rwrRedstoneLoop,
    speedTimerLoop,
    tmaLoop
)
