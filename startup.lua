--[[
ASDIC 主动声纳 v1.5.0-debug (通信调试版)
- 终端实时打印所有 8889 频道消息
- 放宽目标过滤，只要消息含 x 和 i 就处理
- 状态页显示最后收到消息的原始内容
- 其余功能保留：扇形、扫描线、航向偏移等
使用方法：保存为 .lua 运行，观察终端输出。
======================================================================]]

-- ==========================================
--  全局配置
-- ==========================================
local MIN_DISTANCE = 100.0
local MAX_DISTANCE = 600.0
local STRESS_THRESHOLD = 10000.0
local CHANNEL = 8888
local LISTEN_CHANNEL = 8889
local SCAN_SECTOR_HALF = 90
local SCAN_BEAM_WIDTH = 20          -- 恢复为正常波束宽度，便于测试真实扫描
local SEA_LEVEL = -4
local DEPTH_FILTER = -8

local TARGET_FADE_DURATION = 3.0
local TARGET_HOT_DURATION  = 1.0
local REG_QUERY_TIMEOUT = 5.0

local SCAN_ANGULAR_SPEED = 30.0

-- ==========================================
-- 外设初始化
-- ==========================================
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Wireless or Ender Modem not found!", 0) end
modem.open(CHANNEL)
modem.open(LISTEN_CHANNEL)

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
local yawOffset    = 0
local headingOffset = 0
local myLabel      = os.getComputerLabel() or ("Entity-" .. myId)
local monitorModes = {}
local aimPrecision = 5
local currentStressCapacity = 0
local currentNorthYawDeg    = 0
local currentScreenTab      = 1
local menuIndex             = 1
local isEditing             = false
local inputStr              = ""
local cachedStressometer    = peripheral.find("Create_Stressometer")
local targetPool            = {}
local targetPoolCount       = 0
local isAsdicActive         = false
local broadcastOwnPos       = false

local scanTimeStart = 0
local scanAngle = 0

-- 调试用：记录最后收到的原始消息
local lastRawMsg = "None"

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
            if data.headingOffset then headingOffset = tonumber(data.headingOffset) or 0 end
            if data.aimPrecision then
                local p = tonumber(data.aimPrecision)
                if p and p >= 1 and p <= 90 and (360 % math_floor(p) == 0) then
                    aimPrecision = math_floor(p)
                end
            end
            if type(data.monitorModes) == "table" then monitorModes = data.monitorModes end
            if data.broadcastOwnPos ~= nil then broadcastOwnPos = data.broadcastOwnPos end
            if data.scanAngularSpeed then SCAN_ANGULAR_SPEED = tonumber(data.scanAngularSpeed) or SCAN_ANGULAR_SPEED end
        end
    end
end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize({
        yawOffset        = yawOffset,
        headingOffset    = headingOffset,
        aimPrecision     = aimPrecision,
        monitorModes     = monitorModes,
        broadcastOwnPos  = broadcastOwnPos,
        scanAngularSpeed = SCAN_ANGULAR_SPEED,
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
    OUTER_RING  = 0x00CC44,
    INNER_RING  = 0x007722,
    GRID        = 0x005518,
    SWEEP       = 0x00FF66,
    DASH_LINE   = 0x004400,
    YELLOW      = 0xFFFF00,
    WHITE       = 0xFFFFFF,
    BLACK       = 0x000000,
    TARGET_HOT  = 0xFF6600,
    BEACON_UNK  = 0xFFFF44,
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
            lastSText   = nil, lastLText = nil,
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
            local dotSize = 1
            local entry = {
                gpu=g, name=name, w=w, h=h, cx=cx, cy=cy, r=r,
                bw=bw, bh=bh, dotSize=dotSize,
            }
            table.insert(rdrGpuList, entry)
            gpuNameMap[name] = entry
        end
    end
end
initGpuList()

local isHeadless = (#hudMonitorList == 0 and #rdrGpuList == 0)

-- ==========================================
-- 注册检查 (完整)
-- ==========================================
local function checkRegistration()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("ASDIC v1.5.0-debug - Registration Check")
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
                    myLabel = tostring(d.n or myLabel)
                    term.setTextColor(colors.lime)
                    print(string.format("Registered!  Name: %s", myLabel))
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
-- 未注册显示并停止 (完整)
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
        { "Register this ASDIC",      colors.gray   },
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
print("Registration OK. Starting ASDIC...")
sleep(0.5)

-- ==========================================
-- GPU 绘制辅助 (固定扇形)
-- ==========================================
local function gpuDrawFixedSector(entry)
    local g = entry.gpu
    local cx, cy, r = entry.cx, entry.cy, entry.r
    g.fill(C.BG)

    local leftAngle = -SCAN_SECTOR_HALF
    local rightAngle = SCAN_SECTOR_HALF
    local lx = cx + math_floor(r * math_sin(math_rad(leftAngle)))
    local ly = cy - math_floor(r * math_cos(math_rad(leftAngle)))
    local rx = cx + math_floor(r * math_sin(math_rad(rightAngle)))
    local ry = cy - math_floor(r * math_cos(math_rad(rightAngle)))
    g.line(cx, cy, lx, ly, C.OUTER_RING)
    g.line(cx, cy, rx, ry, C.OUTER_RING)

    local step = 2
    for a = leftAngle, rightAngle, step do
        local x1 = cx + math_floor(r * math_sin(math_rad(a)))
        local y1 = cy - math_floor(r * math_cos(math_rad(a)))
        local x2 = cx + math_floor(r * math_sin(math_rad(a + step)))
        local y2 = cy - math_floor(r * math_cos(math_rad(a + step)))
        g.line(x1, y1, x2, y2, C.OUTER_RING)
    end

    local r2 = math_floor(r/2)
    for a = leftAngle, rightAngle, step do
        local x1 = cx + math_floor(r2 * math_sin(math_rad(a)))
        local y1 = cy - math_floor(r2 * math_cos(math_rad(a)))
        local x2 = cx + math_floor(r2 * math_sin(math_rad(a + step)))
        local y2 = cy - math_floor(r2 * math_cos(math_rad(a + step)))
        g.line(x1, y1, x2, y2, C.INNER_RING)
    end

    local mx = cx
    local my = cy - r
    g.line(cx, cy, mx, my, C.GRID)

    for deg = -90, 90, 45 do
        local rad = math_rad(deg)
        local ex = cx + math_floor(r * math_sin(rad))
        local ey = cy - math_floor(r * math_cos(rad))
        local dx = ex - cx
        local dy = ey - cy
        local steps = math_max(1, math_floor(math_sqrt(dx*dx + dy*dy) / 3))
        for i = 0, steps do
            if i % 2 == 0 then
                local px = cx + math_floor(dx * i / steps)
                local py = cy + math_floor(dy * i / steps)
                g.line(px, py, px, py, C.DASH_LINE)
            end
        end
    end

    local trueHeading = (currentNorthYawDeg + headingOffset) % 360
    local dirs = {
        {angle=0,   label="N"},
        {angle=90,  label="E"},
        {angle=180, label="S"},
        {angle=270, label="W"},
    }
    for _, d in ipairs(dirs) do
        local screenAngle = math_rad(d.angle - trueHeading)
        local tx = cx + math_floor((r + 5) * math_sin(screenAngle)) - 3
        local ty = cy - math_floor((r + 5) * math_cos(screenAngle)) - 4
        tx = math_max(1, math_min(entry.w - 6, tx))
        ty = math_max(1, math_min(entry.h - 8, ty))
        pcall(g.drawText, tx, ty, d.label, C.WHITE, C.BG, 1)
    end
end

local function gpuRefreshASDIC(entry, isActive, poolCount, pool)
    local g = entry.gpu
    if not isActive then
        g.fill(C.BG)
        g.sync()
        return
    end

    gpuDrawFixedSector(entry)
    local r = entry.r
    local cx, cy = entry.cx, entry.cy

    for i = 1, poolCount do
        local t = pool[i]
        if t and t.col then
            local px = cx + math_floor(r * t.distRatio * t.s + 0.5)
            local py = cy - math_floor(r * t.distRatio * t.cs + 0.5)
            g.line(px, py, px, py, t.col)
        end
    end

    local sweepRad = math_rad(scanAngle)
    local ex = cx + math_floor(r * math_sin(sweepRad))
    local ey = cy - math_floor(r * math_cos(sweepRad))
    g.line(cx, cy, ex, ey, C.SWEEP)

    g.sync()
end

-- ==========================================
-- RDR GPU 主循环
-- ==========================================
local function rdrGpuUI()
    if #rdrGpuList == 0 then return end
    local frames = 0
    while true do
        if currentScreenTab == 3 then
            for _, entry in ipairs(rdrGpuList) do
                pcall(function()
                    entry.gpu.fill(C.BG)
                    pcall(entry.gpu.drawText, entry.cx - 6, entry.cy - 4, entry.name, C.WHITE, C.BG, 2)
                    entry.gpu.sync()
                end)
            end
            sleep(0.3)
        else
            frames = frames + 1
            local isActive = isAsdicActive
            targetPoolCount = 0
            local now = os_clock()
            local effectiveHeading = (currentNorthYawDeg + headingOffset) % 360

            if localPos and isActive then
                for _, data in pairs(targets) do
                    if data.lastPainted and not data.isBeacon then
                        local age = now - data.lastPainted
                        if age < TARGET_FADE_DURATION then
                            local dist = data.realDist
                            if dist and dist >= MIN_DISTANCE and dist <= MAX_DISTANCE and data.realPos.y <= DEPTH_FILTER then
                                local relBearing = getAngleDiff(data.paintedYaw, effectiveHeading)
                                if math_abs(relBearing) <= SCAN_SECTOR_HALF then
                                    local col = calcFadeColor(age, C.TARGET_HOT) or C.TARGET_HOT
                                    local distRatio = math_min(dist / MAX_DISTANCE, 1.0)
                                    targetPoolCount = targetPoolCount + 1
                                    local t = targetPool[targetPoolCount]
                                    if not t then t = {}; targetPool[targetPoolCount] = t end
                                    t.col = col
                                    t.distRatio = distRatio
                                    local screenRad = math_rad(relBearing)
                                    t.s = math_sin(screenRad)
                                    t.cs = math_cos(screenRad)
                                end
                            end
                        end
                    end
                end
            end

            for _, entry in ipairs(rdrGpuList) do
                pcall(gpuRefreshASDIC, entry, isActive, targetPoolCount, targetPool)
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
        local isActive = isAsdicActive

        for _, info in ipairs(hudMonitorList) do
            if info.mode == "STATUS" then
                local line1, color1 = "ASDIC online", colors.green
                if not isActive then
                    line1, color1 = "ASDIC offline", colors.red
                end
                local line2 = "Range: 100 - 600 m"
                local line3 = "Depth: --- m  /  Dist: --- m"
                local color3 = colors.white

                if selectedTargetId and targets[selectedTargetId] then
                    local sel = targets[selectedTargetId]
                    if sel.realPos then
                        local depth = SEA_LEVEL - sel.realPos.y
                        local dist = sel.realDist or 0
                        line3 = string.format("Depth: %.0f m  /  Dist: %.0f m", depth, dist)
                    end
                end

                if isFirstFrame or line1 ~= info.lastSText or line3 ~= info.lastLText then
                    local m = info.m
                    m.setTextScale(1)
                    m.setBackgroundColor(colors.black)
                    m.clear()
                    local dw, dh = m.getSize()
                    local function drawCL(txt, col, yPos)
                        m.setTextColor(col)
                        local sx = math_max(1, math_floor((dw - #txt) / 2) + 1)
                        m.setCursorPos(sx, yPos)
                        m.write(txt)
                    end
                    drawCL(line1, color1, math_floor(dh / 2) - 2)
                    drawCL(line2, colors.yellow, math_floor(dh / 2))
                    drawCL(line3, color3, math_floor(dh / 2) + 2)
                    info.lastSText = line1
                    info.lastLText = line3
                end
            end
        end
        sleep(0.1)
    end
end

-- ==========================================
-- 终端 UI (显示最后消息)
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
        term.setCursorPos(2, 1); term.setTextColor(colors.white)
        term.write("TAB " .. tabStr)

        if currentScreenTab == 1 then
            term.setCursorPos(2, 3); term.setTextColor(colors.yellow)
            term.write("=== PARAMETERS ===")
            local function drawInputBox(y, label, val, isSel, isEdit)
                term.setCursorPos(2, y); term.setBackgroundColor(colors.black)
                term.setTextColor(isSel and colors.yellow or colors.lightGray)
                term.write(label)
                term.setCursorPos(22, y); term.setBackgroundColor(colors.gray)
                local txt = (isSel and isEdit) and (inputStr .. "_") or tostring(val)
                term.setTextColor(isSel and colors.white or colors.lightGray)
                term.write(string.format(" %-12s ", txt))
                term.setBackgroundColor(colors.black)
            end
            drawInputBox(5,  "Disp. Offset  :", yawOffset, menuIndex == 1, isEditing)
            drawInputBox(7,  "Heading Offset:", headingOffset, menuIndex == 2, isEditing)
            drawInputBox(9,  "Aim Precis    :", aimPrecision, menuIndex == 3, isEditing)
            drawInputBox(11, "Scan Speed    :", string.format("%.1f deg/s", SCAN_ANGULAR_SPEED), menuIndex == 4, isEditing)
            drawInputBox(13, "Broadcast Pos :", broadcastOwnPos and "yes" or "no", menuIndex == 5, isEditing)

        elseif currentScreenTab == 2 then
            term.setCursorPos(2, 3); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            local row = 5
            term.setCursorPos(2, row); term.setTextColor(colors.lime)
            term.write("Registered : " .. myLabel); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.cyan)
            term.write(string.format("Stress     : %.0f / %.0f SU", currentStressCapacity, STRESS_THRESHOLD)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.green)
            term.write("Camera     : ONLINE"); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.yellow)
            term.write(string.format("Heading (raw): %.1f deg", currentNorthYawDeg)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.yellow)
            term.write(string.format("Heading (eff): %.1f deg", (currentNorthYawDeg + headingOffset) % 360)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.white)
            term.write(string.format("Scan Angle  : %.1f deg", scanAngle)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.white)
            term.write(string.format("Broadcast   : %s", broadcastOwnPos and "YES" or "NO")); row = row + 1
            local targetCount = 0
            for _ in pairs(targets) do targetCount = targetCount + 1 end
            term.setCursorPos(2, row); term.setTextColor(colors.lightGray)
            term.write(string.format("Targets     : %d", targetCount)); row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.pink)
            term.write("Last Msg: " .. lastRawMsg)

        else
            term.setCursorPos(2, 3); term.setTextColor(colors.yellow)
            term.write("=== DISPLAYS ===")
            local row = 5
            term.setCursorPos(2, row); term.setTextColor(colors.cyan)
            term.write("[RDR GPU]"); row = row + 1
            if #rdrGpuList == 0 then
                term.setCursorPos(4, row); term.setTextColor(colors.red)
                term.write("None"); row = row + 1
            else
                for _, e in ipairs(rdrGpuList) do
                    term.setCursorPos(4, row); term.setTextColor(colors.lightBlue)
                    term.write(e.name .. string.format("  [%dx%d]", e.w, e.h)); row = row + 1
                end
            end
            row = row + 1
            term.setCursorPos(2, row); term.setTextColor(colors.cyan)
            term.write("[HUD Monitors]"); row = row + 1
            if #hudMonitorList == 0 then
                term.setCursorPos(4, row); term.setTextColor(colors.red)
                term.write("None"); row = row + 1
            else
                for _, info in ipairs(hudMonitorList) do
                    term.setCursorPos(4, row); term.setTextColor(colors.lightBlue)
                    term.write(info.displayName .. " (" .. info.name .. ")"); row = row + 1
                end
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
        if menuIndex == 1 then
            local p = tonumber(inputStr); if p then yawOffset = p end
        elseif menuIndex == 2 then
            local p = tonumber(inputStr); if p then headingOffset = p end
        elseif menuIndex == 3 then
            local p = tonumber(inputStr)
            if p then
                p = math_floor(math_abs(p))
                if p >= 1 and p <= 90 and (360 % p == 0) then aimPrecision = p end
            end
        elseif menuIndex == 4 then
            local p = tonumber(inputStr); if p and p > 0 then SCAN_ANGULAR_SPEED = p end
        elseif menuIndex == 5 then
            if inputStr == "yes" then
                broadcastOwnPos = true
            elseif inputStr == "no" then
                broadcastOwnPos = false
            end
        end
        saveConfig()
        isEditing = false
    end

    while true do
        local event, p1, p2, p3 = os_pullEvent()

        if event == "key" then
            if p1 == keys.tab then
                currentScreenTab = (currentScreenTab % 3) + 1
            elseif isEditing and currentScreenTab == 1 then
                if p1 == keys.enter or p1 == keys.numPadEnter then
                    applySave()
                elseif p1 == keys.backspace then
                    inputStr = inputStr:sub(1, -2)
                end
            elseif currentScreenTab == 1 then
                if p1 == keys.up then menuIndex = math_max(1, menuIndex - 1)
                elseif p1 == keys.down then menuIndex = math_min(5, menuIndex + 1)
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(headingOffset)
                    elseif menuIndex == 3 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 4 then inputStr = tostring(SCAN_ANGULAR_SPEED)
                    elseif menuIndex == 5 then inputStr = broadcastOwnPos and "yes" or "no"
                    end
                end
            end
        elseif event == "char" and isEditing and currentScreenTab == 1 then
            if menuIndex == 5 then
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
                end
                if ti then
                    if isEditing and menuIndex ~= ti then applySave() end
                    menuIndex = ti
                    isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(headingOffset)
                    elseif menuIndex == 3 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 4 then inputStr = tostring(SCAN_ANGULAR_SPEED)
                    elseif menuIndex == 5 then inputStr = broadcastOwnPos and "yes" or "no"
                    end
                else
                    if isEditing then applySave() end
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
        if currentScreenTab == 3 then sleep(0.5)
        else
            if localPos and broadcastOwnPos then
                modem.transmit(CHANNEL, CHANNEL, {
                    v = 2, t = 1, i = myId, n = myLabel,
                    x = math_floor(localPos.x * 10) / 10,
                    y = math_floor(localPos.y * 10) / 10,
                    z = math_floor(localPos.z * 10) / 10,
                })
            end
            local now = os_clock()
            for id, data in pairs(targets) do
                if not data.isBeacon and id ~= selectedTargetId and data.lastSeen and (now - data.lastSeen > 10.0) then
                    targets[id] = nil
                end
            end
            sleep(1.0)
        end
    end
end

-- 监听循环：记录并显示所有消息
local function listenLoop()
    while true do
        local _, _, ch, _, msg, dist = os_pullEvent("modem_message")
        if ch == LISTEN_CHANNEL then
            -- 记录原始消息内容
            if type(msg) == "table" then
                lastRawMsg = string.format("t=%s i=%s x=%s z=%s", tostring(msg.t), tostring(msg.i), tostring(msg.x), tostring(msg.z))
            else
                lastRawMsg = tostring(msg)
            end

            -- 放宽条件：只要消息含 x 和 i 就尝试处理
            if type(msg) == "table" and msg.x and msg.i then
                local id = msg.i
                if not targets[id] then targets[id] = {} end
                local t = targets[id]
                t.id = id
                t.name = msg.n
                t.realPos = { x = msg.x, y = msg.y or 0, z = msg.z or 0 }
                t.lastSeen = os_clock()
                t.isBeacon = false
                if localPos then
                    local cd = calcRangingDist(localPos, t.realPos)
                    t.realDist = cd
                end
            end
        end
    end
end

-- ==========================================
-- 扫描解算
-- ==========================================
local function cameraLoop()
    scanTimeStart = os_clock()
    while true do
        if currentScreenTab == 3 then sleep(0.5)
        else
            -- 应力检查
            if cachedStressometer then
                local ok, cap = pcall(cachedStressometer.getStressCapacity)
                if ok then currentStressCapacity = cap or 0
                else cachedStressometer = nil; currentStressCapacity = 0 end
            end
            isAsdicActive = (currentStressCapacity >= STRESS_THRESHOLD)

            -- 更新扫描线角度
            local now = os_clock()
            local elapsed = now - scanTimeStart
            local period = 4 * SCAN_SECTOR_HALF / SCAN_ANGULAR_SPEED
            local phase = (elapsed % period) / period
            if phase < 0.5 then
                scanAngle = -SCAN_SECTOR_HALF + 4 * SCAN_SECTOR_HALF * phase
            else
                scanAngle = SCAN_SECTOR_HALF - 4 * SCAN_SECTOR_HALF * (phase - 0.5)
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
                        local iqx, iqy, iqz, iqw = quatInverse(currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                        local hx, hy, hz = rotateVectorFast(0, 0, -1, iqx, iqy, iqz, iqw)
                        local sx, sy, sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                        currentNorthYawDeg = math_deg(math_atan2(-sx, sz))
                    end
                end

                local effectiveHeading = (currentNorthYawDeg + headingOffset) % 360
                local refPos = localPos
                if isAsdicActive and refPos then
                    for _, data in pairs(targets) do
                        if data.realPos and not data.isBeacon then
                            local cd = calcRangingDist(refPos, data.realPos)
                            if cd then data.realDist = cd end
                        end
                    end

                    local beamHalf = SCAN_BEAM_WIDTH / 2
                    for id, data in pairs(targets) do
                        if data.isBeacon then goto continue end
                        if data.realPos and data.realDist and
                           data.realDist >= MIN_DISTANCE and data.realDist <= MAX_DISTANCE and
                           data.realPos.y <= DEPTH_FILTER and
                           (now - data.lastSeen < 3.0) then

                            local tYaw
                            if currentQAbs and currentQLoc and refPos then
                                local iqx, iqy, iqz, iqw = quatInverse(currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                                local dx = data.realPos.x - refPos.x
                                local dy = data.realPos.y - refPos.y
                                local dz = data.realPos.z - refPos.z
                                local hx, hy, hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                                local sx, sy, sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                                tYaw = math_deg(math_atan2(-sx, sz))
                            elseif refPos then
                                _, tYaw = calculateLookAngles(refPos.x, refPos.y, refPos.z, data.realPos.x, data.realPos.y, data.realPos.z)
                            end

                            local relBearing = getAngleDiff(tYaw, effectiveHeading)
                            local angleDiff = math_abs(getAngleDiff(relBearing, scanAngle))
                            if angleDiff <= beamHalf then
                                data.isBeingScanned = true
                                if not data.lastPainted or (now - data.lastPainted >= 0.5) then
                                    data.paintedPos = data.realPos
                                    data.paintedDist = data.realDist
                                    data.paintedYaw = tYaw
                                    data.lastPainted = now
                                    -- 发送类型3告警
                                    modem.transmit(LISTEN_CHANNEL, LISTEN_CHANNEL, {
                                        v = 2, t = 3, si = myId, ti = id,
                                        x = math_floor(localPos.x * 10) / 10,
                                        y = math_floor(localPos.y * 10) / 10,
                                        z = math_floor(localPos.z * 10) / 10,
                                    })
                                    if id == selectedTargetId then
                                        local depth = SEA_LEVEL - data.realPos.y
                                        selectedTargetDistStr = string.format("%.0f m / %.0f m", depth, data.realDist)
                                    end
                                end
                            end
                        end
                        ::continue::
                    end
                end
            end
            sleep(0.02)
        end
    end
end

-- ==========================================
-- 启动信息
-- ==========================================
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.green)
print("ASDIC v1.5.0-debug - OK")
print(string.format("  Name      : %s", myLabel))
print(string.format("  Range     : %.0f - %.0f m", MIN_DISTANCE, MAX_DISTANCE))
print(string.format("  Stress    : %.0f SU required", STRESS_THRESHOLD))
print(string.format("  Beam Width: %d deg", SCAN_BEAM_WIDTH))
print(string.format("  HeadingOff: %.0f deg", headingOffset))
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
)
