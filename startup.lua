--[[
雷达 + 主动声纳 二合一系统   v1.0.0
- 两个 GPU 屏幕：雷达圆形 PPI + 声纳扇形 ASDIC
- 两个 HUD：雷达状态 + 声纳状态
- 终端 UI 三页：参数(雷达/声纳)、系统状态、设备列表
- 共享目标数据，雷达扫描伺服，声纳软件扫描
- 网络：雷达监听 8888，声纳监听 8889，可选向 8888 广播自身位置
======================================================================]]

-- ==========================================
--  全局配置（雷达部分）
-- ==========================================
local MAX_DISTANCE_LIMIT       = 5000.0
local STRESS_TO_DISTANCE_RATIO = 2.0
local CHANNEL                  = 8888          -- 雷达网络频道
local ACTIVE_SONAR_CHANNEL     = 8889          -- 声纳监听频道
local SCAN_SECTOR_WIDTH        = 20            -- 雷达扫描扇区宽度（度）
local SEA_LEVEL                = -4

local TARGET_FADE_DURATION = 3.0
local TARGET_HOT_DURATION  = 1.0
local SPEED_FILTER_MIN     = 4.0             -- km/h，雷达速度过滤

-- 主动声纳部分
local ASDIC_MIN_DISTANCE    = 100.0
local ASDIC_MAX_DISTANCE    = 600.0
local ASDIC_STRESS_THRESHOLD = 10000.0
local ASDIC_SCAN_SECTOR_HALF = 90
local ASDIC_SCAN_BEAM_WIDTH  = 20
local ASDIC_DEPTH_FILTER     = -8
local ASDIC_SCAN_ANGULAR_SPEED = 30.0

local REG_QUERY_TIMEOUT = 5.0

-- ==========================================
-- 外设初始化
-- ==========================================
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Wireless Modem not found!", 0) end
modem.open(CHANNEL)
modem.open(ACTIVE_SONAR_CHANNEL)

-- 摄像头
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
local selectedTargetId      = nil
local currentQAbs, currentQLoc = nil, nil
local currentServoAngle        = 0
local isServoConnected         = false
local yawOffset    = 0
local motorOffset  = 0
local headingOffset = 0           -- 声纳航向偏移
local myLabel      = os.getComputerLabel() or ("Entity-" .. myId)
local monitorModes = {}
local aimPrecision = 5
local currentStressCapacity = 0
local currentRadarRange     = 0
local currentNorthYawDeg    = 0      -- 船首航向（修正后0°=北）
local currentScreenTab      = 1      -- 1=参数, 2=状态, 3=设备
local menuIndex             = 1
local isEditing             = false
local inputStr              = ""
local cachedStressometer    = peripheral.find("Create_Stressometer")
local cachedServo           = peripheral.find("servo")
local broadcastOwnPos       = false   -- 是否向8888广播自身位置

-- 雷达目标池
local radarPool      = {}
local radarPoolCount = 0

-- 声纳状态
local isAsdicActive  = false
local asdicScanAngle  = 0
local asdicTargetPool = {}
local asdicPoolCount  = 0

-- ==========================================
--  GPU / HUD 分配（自动取前两个）
-- ==========================================
local radarGpu = nil
local asdicGpu = nil
local radarHud = nil
local asdicHud = nil

local rdrGpuList = {}
local gpuNameMap = {}
local hudMonitorList = {}

local function initPeripherals()
    -- 分配 GPU
    local gpuIdx = 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "tm_gpu" then
            local g = peripheral.wrap(name)
            pcall(g.refreshSize)
            pcall(g.setSize, 64)
            pcall(g.fill, 0x050A05)
            local ok, w, h = pcall(g.getSize)
            if not ok then w, h = 256, 128 end
            w = w or 256; h = h or 128
            local cx = math_floor(w / 2)
            local cy = math_floor(h / 2)
            local r  = math_floor(math_min(cx, cy) * 0.88)
            local bw = math_max(1, math_floor(w / 85))
            local bh = math_max(1, math_floor(h / 64))
            local entry = {
                gpu=g, name=name, w=w, h=h, cx=cx, cy=cy, r=r,
                bw=bw, bh=bh, dotSize=1,
            }
            table.insert(rdrGpuList, entry)
            gpuNameMap[name] = entry
            if gpuIdx == 0 then
                radarGpu = entry
            elseif gpuIdx == 1 then
                asdicGpu = entry
            end
            gpuIdx = gpuIdx + 1
        end
    end

    -- 分配 HUD
    local monIdx = 0
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local m = peripheral.wrap(name)
            m.setTextScale(1)
            local cw, ch = m.getSize()
            local bw = math.ceil(cw / 9)
            local bh = math.ceil(ch / 7)
            if bw >= 5 then bw = bw - 1 end
            local entry = {
                m=m, name=name,
                bw=math.max(1, bw), bh=math.max(1, bh),
                mode=monitorModes[name] or "STATUS",
                lastText={}
            }
            table.insert(hudMonitorList, entry)
            if monIdx == 0 then
                radarHud = entry
            elseif monIdx == 1 then
                asdicHud = entry
            end
            monIdx = monIdx + 1
        end
    end
end
initPeripherals()

local isHeadless = (#rdrGpuList == 0 and #hudMonitorList == 0)

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
-- 配置文件
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
            if data.broadcastOwnPos ~= nil then broadcastOwnPos = data.broadcastOwnPos end
        end
    end
end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize({
        yawOffset    = yawOffset,
        motorOffset  = motorOffset,
        headingOffset = headingOffset,
        aimPrecision = aimPrecision,
        monitorModes = monitorModes,
        broadcastOwnPos = broadcastOwnPos,
    }))
    f.close()
end
loadConfig()

-- ==========================================
-- 注册检查
-- ==========================================
local function checkRegistration()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("Radar+ASDIC v1.0.0 - Registration Check")
    term.setTextColor(colors.white)
    print(string.format("My ID: %d", myId))
    print("Querying scanner...")

    for _, entry in ipairs(rdrGpuList) do
        pcall(function()
            entry.gpu.fill(0x050A05)
            local msg = "CHECKING..."
            local tx  = math_max(1, entry.cx - math_floor(#msg * 6))
            local ty  = entry.cy - 8
            pcall(entry.gpu.drawText, tx, ty, msg, 0xFFFF00, 0x050A05, 2)
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
-- 未注册显示并停止
-- ==========================================
local function showNotRegisteredAndHalt()
    for _, entry in ipairs(rdrGpuList) do
        pcall(function()
            local g  = entry.gpu
            local cx = entry.cx; local cy = entry.cy; local w = entry.w; local h = entry.h
            g.fill(0x1A0000)
            local bx1, by1 = math_floor(cx * 0.3), math_floor(cy * 0.5)
            local bx2, by2 = w - bx1, h - by1
            g.line(bx1, by1, bx2, by1, 0xFF2200); g.line(bx1, by2, bx2, by2, 0xFF2200)
            g.line(bx1, by1, bx1, by2, 0xFF2200); g.line(bx2, by1, bx2, by2, 0xFF2200)
            local line1 = "NOT REGISTERED"
            local tx1   = math_max(bx1 + 4, cx - math_floor(#line1 * 6))
            pcall(g.drawText, tx1, cy - 14, line1, 0xFF2200, 0x1A0000, 2)
            local line2 = string.format("ID: %d", myId)
            local tx2   = math_max(bx1 + 4, cx - math_floor(#line2 * 3))
            pcall(g.drawText, tx2, cy + 6,  line2, 0xAAAAAA, 0x1A0000, 1)
            local line3 = "Register in scanner"
            local tx3   = math_max(bx1 + 4, cx - math_floor(#line3 * 3))
            pcall(g.drawText, tx3, cy + 18, line3, 0x666666, 0x1A0000, 1)
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
-- 雷达 GPU 绘制函数（圆形 PPI）
-- ==========================================
local function drawRadarBase(entry)
    local g = entry.gpu
    local cx, cy, r = entry.cx, entry.cy, entry.r
    g.fill(0x050A05)

    -- 外圈、内圈
    local function circle(cx, cy, r, col)
        local x, y, d = r, 0, 1 - r
        while x >= y do
            g.line(cx+x,cy+y,cx+x,cy+y,col); g.line(cx-x,cy+y,cx-x,cy+y,col)
            g.line(cx+x,cy-y,cx+x,cy-y,col); g.line(cx-x,cy-y,cx-x,cy-y,col)
            g.line(cx+y,cy+x,cx+y,cy+x,col); g.line(cx-y,cy+x,cx-y,cy+x,col)
            g.line(cx+y,cy-x,cx+y,cy-x,col); g.line(cx-y,cy-x,cx-y,cy-x,col)
            y = y + 1
            if d < 0 then d = d + 2*y + 1
            else x = x - 1; d = d + 2*(y-x) + 1 end
        end
    end
    circle(cx, cy, r, 0x00CC44)
    circle(cx, cy, math_floor(r/2), 0x007722)

    -- 十字线
    g.line(cx, cy-r, cx, cy+r, 0x005518)
    g.line(cx-r, cy, cx+r, cy, 0x005518)

    -- 网格点
    for t = -r, r do
        if t % 4 < 2 then
            local py = cy + t
            local px1 = cx + t
            if (px1-cx)^2 + (py-cy)^2 <= r*r then g.line(px1, py, px1, py, 0x005518) end
            local px2 = cx - t
            if (px2-cx)^2 + (py-cy)^2 <= r*r then g.line(px2, py, px2, py, 0x005518) end
        end
    end

    -- N 标记
    local northRad = math_rad(currentNorthYawDeg + yawOffset)
    local nx = cx + math_floor(r * math_sin(northRad) + 0.5)
    local ny = cy - math_floor(r * math_cos(northRad) + 0.5)
    local tX = math_max(1, math_min(entry.w-6, nx - 3))
    local tY = math_max(1, math_min(entry.h-8, ny - 4))
    pcall(g.drawText, tX, tY, "N", 0xFFFF00, 0x050A05, 1)
end

local function drawRadarSweep(entry, angleDeg)
    local g = entry.gpu
    local cx, cy, r = entry.cx, entry.cy, entry.r
    local rad = math_rad(angleDeg + yawOffset)
    local ex = cx + math_floor(r * math_sin(rad) + 0.5)
    local ey = cy - math_floor(r * math_cos(rad) + 0.5)
    g.line(cx, cy, ex, ey, 0xFFFFFF)
    -- 箭头
    local arrowLen = 3
    local a1 = rad + math_rad(150)
    local a2 = rad - math_rad(150)
    g.line(ex, ey, ex + math_floor(arrowLen * math_sin(a1)), ey - math_floor(arrowLen * math_cos(a1)), 0xFFFFFF)
    g.line(ex, ey, ex + math_floor(arrowLen * math_sin(a2)), ey - math_floor(arrowLen * math_cos(a2)), 0xFFFFFF)
end

local function refreshRadar(entry, isActive, poolCount, pool)
    local g = entry.gpu
    if not isActive then g.fill(0x050A05); g.sync(); return end
    drawRadarBase(entry)
    local lineLength = entry.r * 0.75
    for i = 1, poolCount do
        local t = pool[i]
        if t and t.col then
            local endX = entry.cx + math_floor(lineLength * t.s + 0.5)
            local endY = entry.cy - math_floor(lineLength * t.cs + 0.5)
            g.line(entry.cx, entry.cy, endX, endY, t.col)
            -- 标注相对方位
            if t.relAngle then
                local angleStr = tostring(t.relAngle) .. "°"
                local textX = endX + math_floor(5 * t.s + 0.5)
                local textY = endY - math_floor(5 * t.cs + 0.5) - 4
                textX = math_max(2, math_min(entry.w - #angleStr * 3, textX))
                textY = math_max(2, math_min(entry.h - 8, textY))
                pcall(g.drawText, textX, textY, angleStr, t.col, 0x050A05, 0.5)
            end
        end
    end
    drawRadarSweep(entry, currentServoAngle)
    g.sync()
end

-- ==========================================
-- 声纳 GPU 绘制函数（固定扇形）
-- ==========================================
local function drawAsdicSector(entry)
    local g = entry.gpu
    local cx, cy, r = entry.cx, entry.cy, entry.r
    g.fill(0x050A05)

    local leftAngle = -ASDIC_SCAN_SECTOR_HALF
    local rightAngle = ASDIC_SCAN_SECTOR_HALF

    -- 边界射线
    local lx = cx + math_floor(r * math_sin(math_rad(leftAngle)))
    local ly = cy - math_floor(r * math_cos(math_rad(leftAngle)))
    local rx = cx + math_floor(r * math_sin(math_rad(rightAngle)))
    local ry = cy - math_floor(r * math_cos(math_rad(rightAngle)))
    g.line(cx, cy, lx, ly, 0x00CC44)
    g.line(cx, cy, rx, ry, 0x00CC44)

    -- 外弧
    local step = 2
    for a = leftAngle, rightAngle, step do
        local x1 = cx + math_floor(r * math_sin(math_rad(a)))
        local y1 = cy - math_floor(r * math_cos(math_rad(a)))
        local x2 = cx + math_floor(r * math_sin(math_rad(a + step)))
        local y2 = cy - math_floor(r * math_cos(math_rad(a + step)))
        g.line(x1, y1, x2, y2, 0x00CC44)
    end

    -- 内弧
    local r2 = math_floor(r/2)
    for a = leftAngle, rightAngle, step do
        local x1 = cx + math_floor(r2 * math_sin(math_rad(a)))
        local y1 = cy - math_floor(r2 * math_cos(math_rad(a)))
        local x2 = cx + math_floor(r2 * math_sin(math_rad(a + step)))
        local y2 = cy - math_floor(r2 * math_cos(math_rad(a + step)))
        g.line(x1, y1, x2, y2, 0x007722)
    end

    -- 中心线（船首，屏幕正上方）
    local mx = cx
    local my = cy - r
    g.line(cx, cy, mx, my, 0x005518)

    -- 45度虚线刻度
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
                g.line(px, py, px, py, 0x004400)
            end
        end
    end

    -- 方向字母 N/E/S/W
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
        pcall(g.drawText, tx, ty, d.label, 0xFFFFFF, 0x050A05, 1)
    end
end

local function refreshAsdic(entry, isActive, poolCount, pool)
    local g = entry.gpu
    if not isActive then g.fill(0x050A05); g.sync(); return end
    drawAsdicSector(entry)
    for i = 1, poolCount do
        local t = pool[i]
        if t and t.col then
            local px = entry.cx + math_floor(entry.r * t.distRatio * t.s + 0.5)
            local py = entry.cy - math_floor(entry.r * t.distRatio * t.cs + 0.5)
            g.line(px, py, px, py, t.col)
        end
    end
    -- 扫描线
    local rad = math_rad(asdicScanAngle)
    local ex = entry.cx + math_floor(entry.r * math_sin(rad))
    local ey = entry.cy - math_floor(entry.r * math_cos(rad))
    g.line(entry.cx, entry.cy, ex, ey, 0x00FF66)
    g.sync()
end

-- ==========================================
-- 雷达 HUD 绘制
-- ==========================================
local function drawRadarHUD()
    if not radarHud then return end
    local m = radarHud.m
    m.setTextScale(1)
    m.setBackgroundColor(colors.black)
    m.clear()
    local dw, dh = m.getSize()
    local isActive = (currentRadarRange > 0) and isServoConnected
    local line1 = "RADAR " .. (isActive and "ONLINE" or "OFFLINE")
    local col1 = isActive and colors.green or colors.red
    local line2 = string.format("Range: %.0f m", currentRadarRange)
    local line3 = "--- / ---"
    local line4 = "---"
    if selectedTargetId and targets[selectedTargetId] then
        local t = targets[selectedTargetId]
        local rel = math_floor((t.paintedYaw or 0) - currentNorthYawDeg + 0.5) % 360
        local abs = math_floor((t.paintedYaw or 0) % 360 + 0.5) % 360
        line3 = string.format("%.0f / %.0f", rel, abs)
        local radSpd = t.radialSpeed or 0
        local trend = "="
        if radSpd > 0.1 then trend = "A" elseif radSpd < -0.1 then trend = "C" end
        local spd = (t.speed or 0) * 3.6
        line4 = string.format("%.1f km/h %s", spd, trend)
    end
    local function cprint(y, text, col)
        m.setTextColor(col)
        m.setCursorPos(math_max(1, math_floor((dw - #text)/2) + 1), y)
        m.write(text)
    end
    cprint(math_floor(dh/2)-3, line1, col1)
    cprint(math_floor(dh/2)-1, line2, colors.yellow)
    cprint(math_floor(dh/2)+1, line3, colors.white)
    cprint(math_floor(dh/2)+3, line4, colors.white)
end

-- ==========================================
-- 声纳 HUD 绘制
-- ==========================================
local function drawAsdicHUD()
    if not asdicHud then return end
    local m = asdicHud.m
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
        m.setCursorPos(math_max(1, math_floor((dw - #text)/2) + 1), y)
        m.write(text)
    end
    cprint(math_floor(dh/2)-2, line1, col1)
    cprint(math_floor(dh/2), line2, colors.yellow)
    cprint(math_floor(dh/2)+2, line3, colors.white)
end

-- ==========================================
-- 终端 UI 三页
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
        term.setCursorPos(2,1); term.setTextColor(colors.white)
        term.write("TAB " .. tabStr)

        if currentScreenTab == 1 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== PARAMETERS ===")
            local function drawInputBox(y, label, val, isSel, isEdit)
                term.setCursorPos(2,y); term.setBackgroundColor(colors.black)
                term.setTextColor(isSel and colors.yellow or colors.lightGray)
                term.write(label)
                term.setCursorPos(22,y); term.setBackgroundColor(colors.gray)
                local txt = (isSel and isEdit) and (inputStr.."_") or tostring(val)
                term.setTextColor(isSel and colors.white or colors.lightGray)
                term.write(string.format(" %-12s ", txt))
                term.setBackgroundColor(colors.black)
            end
            drawInputBox(5,  "Radar DispOff :", yawOffset, menuIndex==1, isEditing)
            drawInputBox(7,  "Radar MotorOff:", motorOffset, menuIndex==2, isEditing)
            drawInputBox(9,  "Radar AimPrec :", aimPrecision, menuIndex==3, isEditing)
            drawInputBox(11, "ASDIC HeadOff :", headingOffset, menuIndex==4, isEditing)
            drawInputBox(13, "ASDIC ScnSpeed:", string.format("%.1f deg/s", ASDIC_SCAN_ANGULAR_SPEED), menuIndex==5, isEditing)
            drawInputBox(15, "Broadcast Pos :", broadcastOwnPos and "yes" or "no", menuIndex==6, isEditing)

        elseif currentScreenTab == 2 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            local row = 5
            term.setCursorPos(2,row); term.setTextColor(colors.lime)
            term.write("Registered : " .. myLabel); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.cyan)
            term.write(string.format("Stress     : %.0f SU", currentStressCapacity)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.green)
            term.write(string.format("Radar Range: %.0f m", currentRadarRange)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.white)
            term.write(string.format("Servo Angle: %.1f deg", currentServoAngle)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.yellow)
            term.write(string.format("Heading Raw: %.1f deg", currentNorthYawDeg)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.yellow)
            term.write(string.format("Heading Eff: %.1f deg", (currentNorthYawDeg + headingOffset) % 360)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.white)
            term.write(string.format("ASDIC Scan : %.1f deg", asdicScanAngle)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.lightGray)
            term.write(string.format("ASDIC Active: %s", isAsdicActive and "YES" or "NO")); row = row+1
            local tgtCount = 0
            for _ in pairs(targets) do tgtCount = tgtCount + 1 end
            term.setCursorPos(2,row); term.setTextColor(colors.lightGray)
            term.write(string.format("Targets     : %d", tgtCount)); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.white)
            term.write(string.format("Broadcast   : %s", broadcastOwnPos and "YES" or "NO"))

        else
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== DISPLAYS ===")
            local row = 5
            term.setCursorPos(2,row); term.setTextColor(colors.cyan)
            term.write("Radar GPU: " .. (radarGpu and radarGpu.name or "NONE")); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.cyan)
            term.write("ASDIC GPU: " .. (asdicGpu and asdicGpu.name or "NONE")); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.lightBlue)
            term.write("Radar HUD: " .. (radarHud and radarHud.name or "NONE")); row = row+1
            term.setCursorPos(2,row); term.setTextColor(colors.lightBlue)
            term.write("ASDIC HUD: " .. (asdicHud and asdicHud.name or "NONE")); row = row+1
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
            local p = tonumber(inputStr)
            if p then
                p = math_floor(math_abs(p))
                if p >= 1 and p <= 90 and (360 % p == 0) then aimPrecision = p end
            end
        elseif menuIndex == 4 then
            local p = tonumber(inputStr); if p then headingOffset = p end
        elseif menuIndex == 5 then
            local p = tonumber(inputStr); if p and p > 0 then ASDIC_SCAN_ANGULAR_SPEED = p end
        elseif menuIndex == 6 then
            if inputStr == "yes" then broadcastOwnPos = true
            elseif inputStr == "no" then broadcastOwnPos = false end
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
                elseif p1 == keys.down then menuIndex = math_min(6, menuIndex + 1)
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(motorOffset)
                    elseif menuIndex == 3 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 4 then inputStr = tostring(headingOffset)
                    elseif menuIndex == 5 then inputStr = tostring(ASDIC_SCAN_ANGULAR_SPEED)
                    elseif menuIndex == 6 then inputStr = broadcastOwnPos and "yes" or "no"
                    end
                end
            end
        elseif event == "char" and isEditing and currentScreenTab == 1 then
            if menuIndex == 6 then
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
                end
                if ti then
                    if isEditing and menuIndex ~= ti then applySave() end
                    menuIndex = ti
                    isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(motorOffset)
                    elseif menuIndex == 3 then inputStr = tostring(aimPrecision)
                    elseif menuIndex == 4 then inputStr = tostring(headingOffset)
                    elseif menuIndex == 5 then inputStr = tostring(ASDIC_SCAN_ANGULAR_SPEED)
                    elseif menuIndex == 6 then inputStr = broadcastOwnPos and "yes" or "no"
                    end
                else
                    if isEditing then applySave() end
                end
            end
        elseif (event == "tm_monitor_touch" or event == "tm_monitor_mouse_click") then
            -- 触摸锁定：仅在雷达 GPU 上有效
            local touchedName = p1
            local mx, my = p2, p3
            if radarGpu and gpuNameMap[touchedName] == radarGpu and localPos and currentRadarRange > 0 then
                local cx, cy, r = radarGpu.cx, radarGpu.cy, radarGpu.r
                local distFromCenter = math_sqrt((mx-cx)^2 + (my-cy)^2)
                if distFromCenter < 5 or distFromCenter > r+10 then
                    selectedTargetId = nil
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
                    else
                        selectedTargetId = nil
                    end
                end
            end
        end
    end
end

-- ==========================================
-- 网络循环
-- ==========================================
local function pingLoop()
    while true do
        if currentScreenTab == 3 then sleep(0.5) else
            if localPos and broadcastOwnPos then
                modem.transmit(CHANNEL, CHANNEL, {
                    v = 2, t = 1, i = myId, n = myLabel,
                    x = math_floor(localPos.x*10)/10,
                    y = math_floor(localPos.y*10)/10,
                    z = math_floor(localPos.z*10)/10,
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
        -- 雷达频道（8888）
        if ch == CHANNEL and type(msg) == "table" and msg.v == 2 and msg.t == 1 and msg.i ~= myId then
            if not targets[msg.i] then targets[msg.i] = {id = msg.i} end
            local t = targets[msg.i]
            t.name = msg.n; t.modemDist = nil
            if msg.x then t.realPos = {x = msg.x, y = msg.y, z = msg.z} end
            t.lastSeen = os_clock(); t.isBeacon = false
            if localPos and t.realPos then t.realDist = calcRangingDist(localPos, t.realPos) end
        -- 声纳频道（8889）
        elseif ch == ACTIVE_SONAR_CHANNEL and type(msg) == "table" and msg.v == 2 and msg.t == 1 then
            local id = msg.i
            if not targets[id] then targets[id] = {id = id} end
            local t = targets[id]
            t.name = msg.n
            if msg.x then t.realPos = {x = msg.x, y = msg.y, z = msg.z} end
            t.lastSeen = os_clock(); t.isBeacon = false
            if localPos and t.realPos then t.realDist = calcRangingDist(localPos, t.realPos) end
        end
    end
end

-- ==========================================
-- 主传感器循环
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

            -- 雷达伺服电机
            if cachedServo then
                local ok, ang = pcall(cachedServo.getAngle)
                if ok and type(ang) == "number" then
                    isServoConnected = true
                    currentServoAngle = (math_deg(ang) + motorOffset) % 360
                else
                    isServoConnected = false; cachedServo = nil
                end
            else isServoConnected = false end

            -- 雷达动态距离
            local depthDynamicMax = MAX_DISTANCE_LIMIT
            if localPos then
                if localPos.y >= SEA_LEVEL then depthDynamicMax = 1000
                elseif localPos.y <= -14 then depthDynamicMax = 5000
                else depthDynamicMax = 1000 + 400 * (-localPos.y - 4) end
            end
            currentRadarRange = math_min(currentStressCapacity / STRESS_TO_DISTANCE_RATIO, depthDynamicMax)

            -- 声纳激活
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
                    local iqx, iqy, iqz, iqw = quatInverse(currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                    local hx, hy, hz = rotateVectorFast(0, 0, -1, iqx, iqy, iqz, iqw)
                    local sx, sy, sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                    currentNorthYawDeg = (math_deg(math_atan2(-sx, sz)) + 180) % 360
                end
            end

            local now = os_clock()
            -- 更新所有目标距离
            for _, t in pairs(targets) do
                if t.realPos and localPos then
                    t.realDist = calcRangingDist(localPos, t.realPos)
                end
            end

            -- 构建雷达目标池
            radarPoolCount = 0
            if currentRadarRange > 0 and isServoConnected and localPos then
                local deltaAngle = lastServoAngle and math_abs(getAngleDiff(currentServoAngle, lastServoAngle)) or 0
                local effectiveSW = SCAN_SECTOR_WIDTH + deltaAngle
                for id, t in pairs(targets) do
                    if t.realPos and t.realDist and t.realDist <= currentRadarRange and not t.isBeacon and t.lastSeen and (now - t.lastSeen < 3.0) then
                        local tYaw
                        if currentQAbs and currentQLoc then
                            local iqx, iqy, iqz, iqw = quatInverse(currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                            local dx = t.realPos.x - localPos.x
                            local dz = t.realPos.z - localPos.z
                            local hx, hy, hz = rotateVectorFast(dx, 0, dz, iqx, iqy, iqz, iqw)
                            local sx, sy, sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                            tYaw = math_deg(math_atan2(-sx, sz))
                        else
                            _, tYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z, t.realPos.x, t.realPos.y, t.realPos.z)
                        end
                        if math_abs(getAngleDiff(tYaw, currentServoAngle)) <= effectiveSW/2 then
                            if not t.lastPaintedRadar or (now - t.lastPaintedRadar >= 0.5) then
                                t.paintedYaw = tYaw
                                t.paintedDist = t.realDist
                                t.lastPaintedRadar = now
                            end
                            -- 加入雷达池
                            radarPoolCount = radarPoolCount + 1
                            local p = radarPool[radarPoolCount]
                            if not p then p = {}; radarPool[radarPoolCount] = p end
                            p.col = (selectedTargetId == t.id) and 0xFF0000 or 0x0000FF
                            local rad = math_rad(tYaw + yawOffset)
                            p.s = math_sin(rad); p.cs = math_cos(rad)
                            p.relAngle = math_floor((tYaw - currentNorthYawDeg) % 360 + 0.5) % 360
                        end
                    end
                end
            end
            lastServoAngle = currentServoAngle

            -- 声纳扫描线
            local asdicElapsed = now - asdicScanStart
            local period = 4 * ASDIC_SCAN_SECTOR_HALF / ASDIC_SCAN_ANGULAR_SPEED
            local phase = (asdicElapsed % period) / period
            if phase < 0.5 then
                asdicScanAngle = -ASDIC_SCAN_SECTOR_HALF + 4 * ASDIC_SCAN_SECTOR_HALF * phase
            else
                asdicScanAngle = ASDIC_SCAN_SECTOR_HALF - 4 * ASDIC_SCAN_SECTOR_HALF * (phase - 0.5)
            end

            -- 构建声纳目标池
            asdicPoolCount = 0
            if isAsdicActive and localPos then
                local effectiveHeading = (currentNorthYawDeg + headingOffset) % 360
                for id, t in pairs(targets) do
                    if t.realPos and t.realDist and t.realDist >= ASDIC_MIN_DISTANCE and t.realDist <= ASDIC_MAX_DISTANCE
                        and t.realPos.y <= ASDIC_DEPTH_FILTER and not t.isBeacon and t.lastSeen and (now - t.lastSeen < 3.0) then
                        local tYaw
                        if currentQAbs and currentQLoc then
                            local iqx, iqy, iqz, iqw = quatInverse(currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                            local dx = t.realPos.x - localPos.x
                            local dz = t.realPos.z - localPos.z
                            local hx, hy, hz = rotateVectorFast(dx, 0, dz, iqx, iqy, iqz, iqw)
                            local sx, sy, sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                            tYaw = math_deg(math_atan2(-sx, sz))
                        else
                            _, tYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z, t.realPos.x, t.realPos.y, t.realPos.z)
                        end
                        local relBearing = getAngleDiff(tYaw, effectiveHeading)
                        if math_abs(relBearing) <= ASDIC_SCAN_SECTOR_HALF then
                            local beamHalf = ASDIC_SCAN_BEAM_WIDTH / 2
                            if math_abs(getAngleDiff(relBearing, asdicScanAngle)) <= beamHalf then
                                if not t.lastPaintedAsdic or (now - t.lastPaintedAsdic >= 0.5) then
                                    t.paintedYaw = tYaw
                                    t.paintedDist = t.realDist
                                    t.lastPaintedAsdic = now
                                end
                                asdicPoolCount = asdicPoolCount + 1
                                local p = asdicTargetPool[asdicPoolCount]
                                if not p then p = {}; asdicTargetPool[asdicPoolCount] = p end
                                p.col = 0xFF6600
                                local screenRad = math_rad(relBearing)
                                p.s = math_sin(screenRad); p.cs = math_cos(screenRad)
                                p.distRatio = math_min(t.realDist / ASDIC_MAX_DISTANCE, 1.0)
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
term.setCursorPos(1,1)
term.setTextColor(colors.green)
print("Radar+ASDIC v1.0.0 - OK")
print(string.format("  Name      : %s", myLabel))
print(string.format("  Radar Range: %.0f m", MAX_DISTANCE_LIMIT))
print(string.format("  ASDIC Range: %d-%d m", ASDIC_MIN_DISTANCE, ASDIC_MAX_DISTANCE))
print(string.format("  Radar GPU  : %s", radarGpu and radarGpu.name or "NONE"))
print(string.format("  ASDIC GPU  : %s", asdicGpu and asdicGpu.name or "NONE"))
print(string.format("  Radar HUD  : %s", radarHud and radarHud.name or "NONE"))
print(string.format("  ASDIC HUD  : %s", asdicHud and asdicHud.name or "NONE"))
sleep(1.0)

-- ==========================================
-- 并行启动所有协程
-- ==========================================
parallel.waitForAll(
    function() while true do if radarGpu then refreshRadar(radarGpu, (currentRadarRange>0) and isServoConnected, radarPoolCount, radarPool) end sleep(0.05) end end,
    function() while true do if asdicGpu then refreshAsdic(asdicGpu, isAsdicActive, asdicPoolCount, asdicTargetPool) end sleep(0.05) end end,
    function() while true do drawRadarHUD() sleep(0.1) end end,
    function() while true do drawAsdicHUD() sleep(0.1) end end,
    termUI,
    inputLoop,
    pingLoop,
    listenLoop,
    sensorLoop
)
