-- ==========================================
--  全局配置 (GHG 被动定向水听器 v1.2)
-- ==========================================
local PASSIVE_MAX_RANGE        = 5000.0
local CHANNEL                  = 8888
local TARGET_FADE_DURATION     = 8.0
local TARGET_HOT_DURATION      = 2.0
local LISTEN_SECTOR_WIDTH      = 30.0
local REG_QUERY_TIMEOUT        = 5.0
local SPEED_CALC_INTERVAL      = 3.0    -- 测速间隔 3 秒
local LISTEN_HOLD_TIME         = 3.0    -- 方向停留 3 秒才显示目标

-- ==========================================
-- 外设初始化
-- ==========================================
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Error: Wireless or Ender Modem not found!", 0) end
modem.open(CHANNEL)

local camera, cameraName = nil, nil
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "camera" then
        camera     = peripheral.wrap(name)
        cameraName = name
        break
    end
end
if not camera then error("Error: Camera not found!", 0) end

local cachedServo = peripheral.find("servo")
local isServoConnected = false

local HAS_FORCE_API = (camera.forcePitchYaw ~= nil)
local function applyCameraAngle(p, y)
    if HAS_FORCE_API then camera.forcePitchYaw(p, y)
    else camera.setPitch(p); camera.setYaw(y) end
end

redstone.setOutput("front", false)

local myId        = os.getComputerID()
local CONFIG_FILE = "ghg_config.txt"

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
local holdPitch, holdYaw    = nil, nil
local selectedTargetId      = nil   -- 当前锁定的目标 ID (可取消)
local selectedTargetDistStr = nil
local currentQAbs, currentQLoc = nil, nil
local currentServoAngle     = 0
local yawOffset             = 0
local motorOffset           = 0
local myLabel               = os.getComputerLabel() or ("Hydro-" .. myId)
local monitorModes          = {}
local currentScreenTab      = 1
local menuIndex             = 1
local isEditing             = false
local inputStr              = ""
local iffMode               = "enemy"

-- ==========================================
--  配置文件
-- ==========================================
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f    = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            if data.yawOffset   then yawOffset    = tonumber(data.yawOffset)   or 0 end
            if data.motorOffset then motorOffset  = tonumber(data.motorOffset) or 0 end
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
local function radialSymbol(radial_speed)
    if not radial_speed then return "?" end
    if radial_speed > 0.5 then return "A"
    elseif radial_speed < -0.5 then return "C"
    else return "=" end
end

-- 点到线段最短距离平方 (线段端点 p1, p2, 点 p)
local function pointToSegmentSq(px, py, p1x, p1y, p2x, p2y)
    local dx, dy = p2x - p1x, p2y - p1y
    if dx == 0 and dy == 0 then return (px - p1x)^2 + (py - p1y)^2 end
    local t = ((px - p1x)*dx + (py - p1y)*dy) / (dx*dx + dy*dy)
    t = math_max(0, math_min(1, t))
    local nearX = p1x + t*dx
    local nearY = p1y + t*dy
    return (px - nearX)^2 + (py - nearY)^2
end

-- ==========================================
-- 颜色常量 (声纳绿风格)
-- ==========================================
local C = {
    BG          = 0x001A00,
    OUTER_RING  = 0x00FF66,
    INNER_RING  = 0x00AA44,
    GRID        = 0x003310,
    LISTEN_LINE = 0x222222,  -- 黑色监听线 (深灰在绿底上可见)
    TARGET_LINE = 0x0066FF,  -- 蓝色目标线
    LOCKED_LINE = 0xFF0000,  -- 红色锁定线
    YELLOW      = 0xFFFF00,
    ALLY_HOT    = 0x44FFAA,
    FOE_HOT     = 0xFF3300,
    UNK_HOT     = 0x66FF66,
    CORNER_FOE  = 0x440000,
    CORNER_ALLY = 0x002200,
    BLACK       = 0x000000,
    WHITE       = 0xFFFFFF,
    BEACON_UNK  = 0xFFFF44,
    BEACON_ALLY = 0x44FF44,
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
            lastSText   = nil, lastRText = nil,
            lastLText   = nil, lastDText = nil,
            lastIffMode = nil,
        })
        mIndex = mIndex + 1
    end
end

-- ==========================================
-- 声纳 GPU 列表
-- ==========================================
local BLOCK_PX_W = 85
local BLOCK_PX_H = 64

local sonarGpuList = {}
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
            table.insert(sonarGpuList, {
                gpu=g, name=name, w=w, h=h, cx=cx, cy=cy, r=r,
                bw=bw, bh=bh, dotSize=dotSize,
            })
            gpuNameMap[name] = {gpu=g, cx=cx, cy=cy, r=r, w=w, h=h, dotSize=dotSize}
        end
    end
end
initGpuList()

local isHeadless = (#hudMonitorList == 0 and #sonarGpuList == 0)


-- ==========================================
-- 注册检查
-- ==========================================
local function checkRegistration()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("GHG Sonar v1.2 - Registration Check")
    term.setTextColor(colors.white)
    print(string.format("My ID: %d", myId))
    print("Querying scanner...")

    for _, entry in ipairs(sonarGpuList) do
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
                    myLabel           = tostring(d.n or myLabel)
                    PASSIVE_MAX_RANGE = tonumber(d.r) or PASSIVE_MAX_RANGE
                    term.setTextColor(colors.lime)
                    print(string.format(
                        "Registered!  Name: %s  MaxRange: %.0fm",
                        myLabel, PASSIVE_MAX_RANGE))
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

local function showNotRegisteredAndHalt()
    for _, entry in ipairs(sonarGpuList) do
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
        { "Register this sonar in",   colors.gray   },
        { "ghg_scanner.lua first.",   colors.gray   },
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
-- GPU 绘制辅助
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

local function gpuDrawIffCorners(entry)
    local g=entry.gpu; local W=entry.w; local H=entry.h
    local col=(iffMode=="friendly") and C.CORNER_ALLY or C.CORNER_FOE
    local L_LEN=14; local L_THICK=2
    local function drawCornerL(ox,oy,hx,hy,vx,vy)
        for t=0,L_THICK-1 do
            local ax0=ox+vx*t; local ay0=oy+vy*t
            g.line(ax0,ay0,ax0+hx*(L_LEN-1),ay0+hy*(L_LEN-1),col)
            local bx0=ox+hx*t; local by0=oy+hy*t
            g.line(bx0,by0,bx0+vx*(L_LEN-1),by0+vy*(L_LEN-1),col)
        end
    end
    drawCornerL(1,1,1,0,0,1); drawCornerL(W,1,-1,0,0,1)
    drawCornerL(1,H,1,0,0,-1); drawCornerL(W,H,-1,0,0,-1)
end

local function gpuDrawSonarBase(entry)
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
    local northRad=math_rad(yawOffset)
    local circPx=cx+math_floor(r*math_sin(northRad)+0.5)
    local circPy=cy-math_floor(r*math_cos(northRad)+0.5)
    local tX=math_max(1,math_min(entry.w-6,circPx-3))
    local tY=math_max(1,math_min(entry.h-8,circPy-4))
    pcall(g.drawText,tX,tY,"N",C.YELLOW,C.BG,1)
end

-- 黑色监听线 (小箭头)
local function gpuDrawListeningLine(entry, angleDeg)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    local rad = math_rad(angleDeg + yawOffset)
    local ex = cx + math_floor(r * math_sin(rad) + 0.5)
    local ey = cy - math_floor(r * math_cos(rad) + 0.5)
    g.line(cx, cy, ex, ey, C.LISTEN_LINE)
    -- 小箭头 (黑色)
    local arrLen = 4
    local arrRad1 = math_rad(angleDeg + yawOffset + 150)
    local arrRad2 = math_rad(angleDeg + yawOffset - 150)
    g.line(ex, ey,
           ex + math_floor(arrLen * math_sin(arrRad1) + 0.5),
           ey - math_floor(arrLen * math_cos(arrRad1) + 0.5),
           C.LISTEN_LINE)
    g.line(ex, ey,
           ex + math_floor(arrLen * math_sin(arrRad2) + 0.5),
           ey - math_floor(arrLen * math_cos(arrRad2) + 0.5),
           C.LISTEN_LINE)
end

-- 绘制目标线 (从圆心到外圈)
local function gpuDrawTargetLine(entry, yawRad, color, targetData)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    local ex = cx + math_floor(r * math_sin(yawRad) + 0.5)
    local ey = cy - math_floor(r * math_cos(yawRad) + 0.5)
    g.line(cx, cy, ex, ey, color)

    -- 显示文字标签 (在射线外圈附近)
    if targetData then
        local absBearing = (targetData.paintedYaw + 360) % 360
        local relBearing = (absBearing - (yawOffset or 0) + 360) % 360
        local speedStr = "?"
        if targetData.speed then
            speedStr = string.format("%.1f", targetData.speed)
        end
        local radialSym = radialSymbol(targetData.radialSpeed)
        local text = string.format("%03d°/%03d° %s%s", relBearing, absBearing, speedStr, radialSym)
        local tx = ex + 8 * math_sin(yawRad)
        local ty = ey - 8 * math_cos(yawRad)
        tx = math_max(1, math_min(entry.w - 1, tx))
        ty = math_max(1, math_min(entry.h - 1, ty))
        pcall(g.drawText, tx, ty, text, 0xFFFFFF, C.BG, 0)
    end
end

local function gpuRefreshSonar(entry)
    local g = entry.gpu
    gpuDrawSonarBase(entry)

    if isServoConnected then
        gpuDrawListeningLine(entry, currentServoAngle)
    end

    local now = os_clock()
    for id, data in pairs(targets) do
        local isLocked = (id == selectedTargetId)
        local show = false
        if isLocked then
            -- 锁定目标始终显示 (速度为0可能仍隐藏？这里加一个保护：若速度为零且有锁定，可选择显示一条灰线或直接不画，根据设定我们仍画线但无速度文字)
            if data.paintedYaw then
                local yawRad = math_rad(data.paintedYaw + yawOffset)
                local lineColor = C.LOCKED_LINE
                -- 如果速度＝0，线变暗一些？ 也可不变
                gpuDrawTargetLine(entry, yawRad, lineColor, data)
            end
        else
            -- 普通目标：必须 lastPainted 有效且速度>0 才会显示
            if data.lastPainted and (now - data.lastPainted < TARGET_FADE_DURATION) and data.speed and data.speed > 0.1 then
                local age = now - data.lastPainted
                local hotColor = C.ALLY_HOT   -- 未使用敌我颜色，统一蓝色线
                local col = calcFadeColor(age, hotColor)
                if col and col ~= C.BLACK then
                    local yawRad = math_rad(data.paintedYaw + yawOffset)
                    gpuDrawTargetLine(entry, yawRad, C.TARGET_LINE, data)
                end
            end
        end
    end

    gpuDrawIffCorners(entry)
    g.sync()
end

-- ==========================================
-- 声纳 GPU 主循环
-- ==========================================
local function sonarGpuUI()
    if #sonarGpuList == 0 then return end
    while true do
        if currentScreenTab == 2 then
            sleep(0.3)
        else
            for _, entry in ipairs(sonarGpuList) do
                pcall(gpuRefreshSonar, entry)
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
        for _, info in ipairs(hudMonitorList) do
            if info.mode == "STATUS" then
                local sText, sColor, rText, rColor, lText, lColor, dText, dColor
                sText = "PASSIVE"; sColor = colors.green
                rText = string.format("%dm", math_floor(PASSIVE_MAX_RANGE)); rColor = colors.lime
                if selectedTargetId and targets[selectedTargetId] then
                    local sel = targets[selectedTargetId]
                    local absBearing = (sel.paintedYaw + 360) % 360
                    local relBearing = (absBearing - (yawOffset or 0) + 360) % 360
                    local distStr = string.format("%.0fm", sel.paintedDist or 0)  -- 距离仅供参考
                    local speedStr = sel.speed and string.format("%.1fm/s", sel.speed) or "?m/s"
                    local radialSym = radialSymbol(sel.radialSpeed)
                    local idStr = tostring(sel.name or "??")
                    lText = "TRACK"; lColor = colors.red
                    dText = string.format("%s %s %03d°/%03d° %s%s", distStr, idStr, relBearing, absBearing, speedStr, radialSym)
                    dColor = colors.white
                else
                    lText = "LISTEN"; lColor = colors.lightGray
                    dText = "---"; dColor = colors.gray
                end
                if isFirstFrame or sText ~= info.lastSText or rText ~= info.lastRText
                    or lText ~= info.lastLText or dText ~= info.lastDText
                    or iffMode ~= info.lastIffMode
                then
                    info.m.setTextScale(1)
                    info.m.setBackgroundColor(colors.black)
                    info.m.clear()
                    local dw, dh = info.m.getSize()
                    local y1 = math_max(1, math_floor(dh/2)-3)
                    local y2 = math_max(2, math_floor(dh/2)-1)
                    local y3 = math_max(3, math_floor(dh/2)+1)
                    local y4 = math_max(4, math_floor(dh/2)+3)
                    local function drawCL(txt, col, yPos)
                        info.m.setTextColor(col)
                        local sx = math_max(1, math_floor((dw-#txt)/2)+1)
                        info.m.setCursorPos(sx, yPos); info.m.write(txt)
                    end
                    drawCL(sText, sColor, y1)
                    drawCL(rText, rColor, y2)
                    drawCL(lText, lColor, y3)
                    drawCL(dText, dColor, y4)
                    info.lastSText = sText; info.lastRText = rText
                    info.lastLText = lText; info.lastDText = dText
                    info.lastIffMode = iffMode
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
            local r = 4
            term.setCursorPos(2,r); term.setTextColor(colors.cyan)
            term.write("[TOM'S GPU - SONAR]"); r = r+1
            if #sonarGpuList == 0 then
                term.setCursorPos(4,r); term.setTextColor(colors.red)
                term.write("No tm_gpu found."); r = r+1
            else
                for _,entry in ipairs(sonarGpuList) do
                    term.setCursorPos(4,r); term.setTextColor(colors.lightBlue)
                    term.write("- "..entry.name)
                    term.setCursorPos(22,r); term.setTextColor(colors.white)
                    term.write(string.format("[%dx%d]",entry.bw,entry.bh))
                    term.setCursorPos(30,r); term.setTextColor(colors.green)
                    term.write("[dot:"..entry.dotSize.."]"); r = r+1
                end
            end
            r = r+1
            term.setCursorPos(2,r); term.setTextColor(colors.cyan)
            term.write("[CC MONITOR - HUD]"); r = r+1
            if #hudMonitorList == 0 then
                term.setCursorPos(4,r); term.setTextColor(colors.red)
                term.write("No monitors found."); r = r+1
            else
                for _,info in ipairs(hudMonitorList) do
                    term.setCursorPos(4,r); term.setTextColor(colors.lightBlue)
                    term.write("- "..info.displayName)
                    term.setCursorPos(24,r); term.setTextColor(colors.yellow)
                    term.write("[HUD]"); info.termRow = r; r = r+1
                end
            end
            r = r+1
            term.setCursorPos(2,r); term.setTextColor(colors.lightGray)
            term.write("Camera: ")
            local shortN = cameraName
            if #shortN>12 then shortN = shortN:sub(1,12) end
            term.setTextColor(colors.white); term.write(shortN)
            term.setTextColor(colors.cyan);  term.write("  [ONLINE]")
            r = r+2
            term.setCursorPos(2,r); term.setTextColor(colors.yellow)
            term.write("Press [TAB] to Resume"); r = r+1
            term.setCursorPos(2,r); term.setTextColor(colors.red)
            term.write("[SYSTEM PAUSED FOR CONFIG]")
        else
            term.setCursorPos(2,2); term.setTextColor(colors.yellow)
            term.write("=== GHG SONAR CONFIG ===")

            local function drawInputBox(y, label, val, isSel, isEdit)
                term.setCursorPos(2,y); term.setBackgroundColor(colors.black)
                term.setTextColor(isSel and colors.yellow or colors.lightGray)
                term.write(label)
                term.setCursorPos(15,y); term.setBackgroundColor(colors.gray)
                local txt = (isSel and isEdit) and (inputStr.."_") or tostring(val)
                term.setTextColor(isSel and colors.white or colors.lightGray)
                term.write(string.format(" %-12s ", txt))
                term.setBackgroundColor(colors.black)
            end

            drawInputBox(4,  "Hydro Offset:", yawOffset,   menuIndex==1, isEditing)
            drawInputBox(6,  "Motor Offset:", motorOffset, menuIndex==2, isEditing)

            term.setCursorPos(2,10); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            term.setCursorPos(2,12); term.setTextColor(colors.lime)
            term.write(string.format("Registered : %s", myLabel))
            term.setCursorPos(2,13); term.setTextColor(colors.cyan)
            term.write(string.format("Max Range  : %.0f m", PASSIVE_MAX_RANGE))
            term.setCursorPos(2,14); term.setTextColor(colors.gray)
            term.write(string.format("Mode       : PASSIVE, Sector: %d°", LISTEN_SECTOR_WIDTH))
            term.setCursorPos(2,16)
            if isServoConnected then
                term.setTextColor(colors.white)
                term.write(string.format("Listen Dir : %6.1f deg", currentServoAngle))
            else
                term.setTextColor(colors.red)
                term.write("Listen Dir : OFFLINE (no servo)")
            end
            term.setCursorPos(2,18)
            if iffMode == "friendly" then
                term.setTextColor(colors.lightBlue); term.write("IFF Mode   : ")
                term.setBackgroundColor(colors.blue); term.setTextColor(colors.white)
                term.write(" ALLY "); term.setBackgroundColor(colors.black)
            else
                term.setTextColor(colors.red); term.write("IFF Mode   : ")
                term.setBackgroundColor(colors.red); term.setTextColor(colors.white)
                term.write(" FOE  "); term.setBackgroundColor(colors.black)
            end
            term.setCursorPos(2,19); term.setTextColor(colors.gray)
            term.write("[TAB] Monitor  [Back RS] IFF")
            term.setCursorPos(2,20); term.setTextColor(colors.cyan)
            term.write((#sonarGpuList>0) and ("SONAR GPU: "..(#sonarGpuList).." online") or "SONAR GPU: NONE")
            term.setCursorPos(2,21); term.setTextColor(colors.gray)
            term.write(string.format("Speed Int : %d s", SPEED_CALC_INTERVAL))
            term.setCursorPos(2,22); term.setTextColor(colors.gray)
            term.write(string.format("Hold Time : %d s", LISTEN_HOLD_TIME))
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 输入事件循环 (含线段点选)
-- ==========================================
local function inputLoop()
    local function applySave()
        if menuIndex == 1 then
            local p = tonumber(inputStr); if p then yawOffset = p end
        elseif menuIndex == 2 then
            local p = tonumber(inputStr); if p then motorOffset = p end
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
                    inputStr = inputStr:sub(1,-2)
                end
            elseif currentScreenTab == 1 then
                if p1 == keys.up then menuIndex = math_max(1, menuIndex-1)
                elseif p1 == keys.down then menuIndex = math_min(2, menuIndex+1)
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(motorOffset) end
                end
            end
        elseif event == "char" and isEditing and currentScreenTab == 1 then
            if menuIndex == 1 or menuIndex == 2 then
                if (p1 >= '0' and p1 <= '9') or p1 == '.' or (p1 == '-' and #inputStr == 0) then
                    if #inputStr < 8 then inputStr = inputStr .. p1 end
                end
            end
        elseif event == "mouse_click" then
            local touchY = p3
            if currentScreenTab == 1 then
                local ti = nil
                if touchY == 4 then ti = 1
                elseif touchY == 6 then ti = 2 end
                if ti then
                    if isEditing and menuIndex ~= ti then applySave() end
                    menuIndex = ti; isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset)
                    elseif menuIndex == 2 then inputStr = tostring(motorOffset) end
                else
                    if isEditing then applySave() end
                end
            end
        elseif (event == "tm_monitor_touch" or event == "tm_monitor_mouse_click")
            and currentScreenTab == 1
        then
            local touchedName = p1
            local mx, my = p2, p3
            local entry = gpuNameMap[touchedName]
            if entry and localPos then
                local now = os_clock()
                local clickedId = nil
                local minDist = 4  -- 线段点击距离阈值 (像素)
                -- 遍历所有可显示的目标 (包括锁定的)
                for id, data in pairs(targets) do
                    local isCandidate = (id == selectedTargetId) or
                        (data.lastPainted and (now - data.lastPainted < TARGET_FADE_DURATION) and data.speed and data.speed > 0.1)
                    if isCandidate and data.paintedYaw then
                        local yawRad = math_rad(data.paintedYaw + yawOffset)
                        local ex = entry.cx + math_floor(entry.r * math_sin(yawRad) + 0.5)
                        local ey = entry.cy - math_floor(entry.r * math_cos(yawRad) + 0.5)
                        local dSq = pointToSegmentSq(mx, my, entry.cx, entry.cy, ex, ey)
                        if dSq <= minDist*minDist then
                            clickedId = id
                            break
                        end
                    end
                end
                if clickedId then
                    if clickedId == selectedTargetId then
                        -- 取消锁定
                        selectedTargetId = nil
                        selectedTargetDistStr = nil
                        -- 如果目标仍在扇区内且速度>0，立即赋予 lastPainted 使其恢复普通显示
                        local data = targets[clickedId]
                        if data and data.speed and data.speed > 0.1 then
                            -- 检查扇区：粗略认为仍在扇区(因为点击操作通常发生在看到线时)
                            -- 这里简单恢复显示，不检查扇区，以避免闪烁
                            data.lastPainted = os_clock()
                        end
                    else
                        -- 锁定新目标，先清除旧锁定
                        selectedTargetId = clickedId
                        selectedTargetDistStr = string.format("%dm", math_floor((targets[clickedId].paintedDist or 0)+0.5))
                        -- 强制更新 lastPainted 保证持续显示
                        targets[clickedId].lastPainted = os_clock()
                    end
                end
            end
        end
    end
end

-- ==========================================
-- 网络协议 (只接收 t=1)
-- ==========================================
local function listenLoop()
    while true do
        local ev, p1, p2, p3, p4, p5 = os_pullEvent()
        if ev == "modem_message" then
            local ch = p2
            local msg = p5
            local dist = p4
            if ch == CHANNEL and type(msg) == "table" and msg.v == 2 then
                if msg.t == 1 and msg.i ~= myId then
                    if not targets[msg.i] then
                        targets[msg.i] = {name = msg.n}
                    end
                    local t = targets[msg.i]
                    -- 保存旧位置用于测速
                    if t.realPos then
                        t.speedLastPos = {x = t.realPos.x, y = t.realPos.y, z = t.realPos.z}
                        t.speedLastTime = os_clock()
                    end
                    t.realPos = {x = msg.x, y = msg.y, z = msg.z}
                    t.modemDist = dist
                    t.realDist = calcRangingDist(localPos, t.realPos) or dist
                    t.lastSeen = os_clock()
                    t.isBeacon = false
                    -- 重置扇区停留计时 (因为有新位置)
                    t.sectorEnterTime = nil
                end
            end
        end
    end
end

-- ==========================================
-- IFF 切换循环
-- ==========================================
local function iffToggleLoop()
    local lastBack = redstone.getInput("back")
    while true do
        os_pullEvent("redstone")
        local newBack = redstone.getInput("back")
        if newBack and not lastBack then
            iffMode = (iffMode == "enemy") and "friendly" or "enemy"
        end
        lastBack = newBack
    end
end

-- ==========================================
-- 主被动监听循环 (定向扇形、3秒停留、测速)
-- ==========================================
local function passiveListenerLoop()
    local peripheralPollTick = 0
    while true do
        if currentScreenTab == 2 then
            sleep(0.5)
        else
            if peripheralPollTick <= 0 then
                peripheralPollTick = 20
                if not cachedServo then cachedServo = peripheral.find("servo") end
            else
                peripheralPollTick = peripheralPollTick - 1
            end

            if cachedServo then
                local ok, ang = pcall(cachedServo.getAngle)
                if ok and type(ang) == "number" then
                    isServoConnected = true
                    currentServoAngle = (math_deg(ang) + motorOffset) % 360
                else
                    isServoConnected = false; cachedServo = nil
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
                end
            end

            local now = os_clock()
            if localPos then
                for id, data in pairs(targets) do
                    if data.realPos then
                        local dx = data.realPos.x - localPos.x
                        local dy = data.realPos.y - localPos.y
                        local dz = data.realPos.z - localPos.z
                        local dist = math_sqrt(dx*dx + dy*dy + dz*dz)
                        data.realDist = dist

                        local tYaw
                        if currentQAbs and currentQLoc then
                            local iqx, iqy, iqz, iqw = quatInverse(
                                currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                            local hx, hy, hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                            local sx, sy, sz = rotateVectorFast(hx, hy, hz,
                                currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                            tYaw = math_deg(math_atan2(-sx, sz))
                        else
                            _, tYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z,
                                                         data.realPos.x, data.realPos.y, data.realPos.z)
                        end
                        data.paintedYaw = tYaw
                        data.paintedDist = dist

                        -- 锁定目标：持续更新，跳过扇区与停留检测
                        if id == selectedTargetId then
                            data.lastPainted = now
                            -- 测速 (3秒间隔)
                            if not data.speedLastCalc or (now - data.speedLastCalc >= SPEED_CALC_INTERVAL) then
                                if data.speedLastPos and data.speedLastTime then
                                    local dt = now - data.speedLastTime
                                    if dt > 0.1 then
                                        local lx, ly, lz = data.speedLastPos.x, data.speedLastPos.y, data.speedLastPos.z
                                        local ddx = data.realPos.x - lx
                                        local ddy = data.realPos.y - ly
                                        local ddz = data.realPos.z - lz
                                        local spd = math.sqrt(ddx*ddx + ddy*ddy + ddz*ddz) / dt
                                        data.speed = spd
                                        if dist > 0.01 then
                                            local ux = dx / dist; local uy = dy / dist; local uz = dz / dist
                                            data.radialSpeed = (ddx*ux + ddy*uy + ddz*uz) / dt
                                        else
                                            data.radialSpeed = 0
                                        end
                                    end
                                end
                                data.speedLastPos = {x = data.realPos.x, y = data.realPos.y, z = data.realPos.z}
                                data.speedLastTime = now
                                data.speedLastCalc = now
                            end
                        else
                            -- 普通目标：检查扇区与3秒停留
                            local inSector = true
                            if isServoConnected then
                                local diff = math_abs(getAngleDiff(tYaw, currentServoAngle))
                                inSector = (diff <= LISTEN_SECTOR_WIDTH / 2)
                            end
                            if inSector then
                                if not data.sectorEnterTime then
                                    data.sectorEnterTime = now
                                    data.sectorEnterPos = {x = data.realPos.x, y = data.realPos.y, z = data.realPos.z}
                                end
                                local elapsed = now - data.sectorEnterTime
                                if elapsed >= LISTEN_HOLD_TIME then
                                    -- 3秒到了，计算这段时间的平均速度
                                    local dt = elapsed
                                    local lx, ly, lz = data.sectorEnterPos.x, data.sectorEnterPos.y, data.sectorEnterPos.z
                                    local ddx = data.realPos.x - lx
                                    local ddy = data.realPos.y - ly
                                    local ddz = data.realPos.z - lz
                                    local spd = math.sqrt(ddx*ddx + ddy*ddy + ddz*ddz) / dt
                                    data.speed = spd
                                    -- 计算径向速度
                                    if dist > 0.01 then
                                        local ux = dx / dist; local uy = dy / dist; local uz = dz / dist
                                        data.radialSpeed = (ddx*ux + ddy*uy + ddz*uz) / dt
                                    else
                                        data.radialSpeed = 0
                                    end
                                    -- 检查速度是否为0
                                    if spd > 0.1 then
                                        data.lastPainted = now
                                        -- 记录测速时间，用于后续每3秒更新
                                        data.speedLastPos = {x = data.realPos.x, y = data.realPos.y, z = data.realPos.z}
                                        data.speedLastTime = now
                                        data.speedLastCalc = now
                                    else
                                        -- 静止目标，不显示
                                        data.lastPainted = nil
                                    end
                                    -- 重置停留状态（下一轮3秒将再次检查）
                                    data.sectorEnterTime = nil
                                end
                            else
                                -- 离开扇区，重置停留计时
                                data.sectorEnterTime = nil
                                -- 如果之前已显示（有 lastPainted），让其自然淡出
                            end

                            -- 对于已显示的非锁定目标，每3秒更新一次速度
                            if data.lastPainted and (now - (data.speedLastCalc or 0) >= SPEED_CALC_INTERVAL) then
                                if data.speedLastPos and data.speedLastTime then
                                    local dt = now - data.speedLastTime
                                    if dt > 0.1 then
                                        local lx, ly, lz = data.speedLastPos.x, data.speedLastPos.y, data.speedLastPos.z
                                        local ddx = data.realPos.x - lx
                                        local ddy = data.realPos.y - ly
                                        local ddz = data.realPos.z - lz
                                        local spd = math.sqrt(ddx*ddx + ddy*ddy + ddz*ddz) / dt
                                        data.speed = spd
                                        if dist > 0.01 then
                                            local ux = dx / dist; local uy = dy / dist; local uz = dz / dist
                                            data.radialSpeed = (ddx*ux + ddy*uy + ddz*uz) / dt
                                        else
                                            data.radialSpeed = 0
                                        end
                                        -- 若速度降为0，取消显示（除非锁定）
                                        if spd <= 0.1 and id ~= selectedTargetId then
                                            data.lastPainted = nil
                                        end
                                    end
                                end
                                data.speedLastPos = {x = data.realPos.x, y = data.realPos.y, z = data.realPos.z}
                                data.speedLastTime = now
                                data.speedLastCalc = now
                            end
                        end
                    end
                end
            end

            -- 清除过期目标
            for id, data in pairs(targets) do
                if data.lastSeen and (now - data.lastSeen > TARGET_FADE_DURATION) then
                    targets[id] = nil
                    if id == selectedTargetId then
                        selectedTargetId = nil
                        selectedTargetDistStr = nil
                    end
                end
            end

            sleep(0.2)
        end
    end
end

-- ==========================================
-- 启动信息
-- ==========================================
term.clear()
term.setCursorPos(1,1)
term.setTextColor(colors.green)
print("GHG Sonar v1.2 - OK")
print(string.format("  Name      : %s", myLabel))
print(string.format("  Max Range : %.0f m", PASSIVE_MAX_RANGE))
print(string.format("  SONAR GPU : %d", #sonarGpuList))
print(string.format("  HUD Mon   : %d", #hudMonitorList))
sleep(1.0)

parallel.waitForAll(
    sonarGpuUI,
    hudMonitorUI,
    termUI,
    inputLoop,
    listenLoop,
    passiveListenerLoop,
    iffToggleLoop
)
