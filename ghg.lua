-- ==========================================
--  全局配置 (GHG 被动水听器)
-- ==========================================
local PASSIVE_MAX_RANGE        = 2000.0   -- 最大被动探测距离 (米)
local CHANNEL                  = 8888
local TARGET_FADE_DURATION     = 8.0      -- 目标淡出时间 (秒)
local TARGET_HOT_DURATION      = 2.0      -- 目标高亮保持时间
local REG_QUERY_TIMEOUT        = 5.0

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
local selectedTargetId      = nil
local selectedTargetDistStr = nil
local currentQAbs, currentQLoc = nil, nil
local yawOffset    = 0
local myLabel      = os.getComputerLabel() or ("Hydro-" .. myId)
local monitorModes = {}
local currentScreenTab      = 1
local menuIndex             = 1
local isEditing             = false
local inputStr              = ""
local targetPool            = {}
local targetPoolCount       = 0
local iffMode               = "enemy"
local isPaused              = false    -- 主循环是否暂停 (配置界面用)

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
-- 接近/远离符号
local function radialSymbol(radial_speed)
    if not radial_speed then return "?" end
    if radial_speed > 0.5 then return "A"
    elseif radial_speed < -0.5 then return "C"
    else return "=" end
end

-- ==========================================
-- 颜色常量 (声纳绿风格)
-- ==========================================
local C = {
    BG          = 0x001A00,
    OUTER_RING  = 0x00FF66,
    INNER_RING  = 0x00AA44,
    GRID        = 0x003310,
    AMBIG       = 0x003300,   -- 左右模糊镜像点颜色
    SWEEP       = 0x000000,   -- 不再使用
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
            lastSText   = nil, lastRText   = nil,
            lastLText   = nil, lastDText   = nil,
            lastIffMode = nil,
        })
        mIndex = mIndex + 1
    end
end

-- ==========================================
-- 声纳 GPU 列表 (原 RDR GPU)
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
            local entry = {
                gpu=g, name=name, w=w, h=h, cx=cx, cy=cy, r=r,
                bw=bw, bh=bh, dotSize=dotSize,
            }
            table.insert(sonarGpuList, entry)
            gpuNameMap[name] = entry
        end
    end
end
initGpuList()

local isHeadless = (#hudMonitorList == 0 and #sonarGpuList == 0)

-- ==========================================
-- 注册检查 (与雷达相同，但名称改为水听器)
-- ==========================================
local function checkRegistration()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("GHG Sonar v1.0 - Registration Check")
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
                    myLabel            = tostring(d.n or myLabel)
                    PASSIVE_MAX_RANGE  = tonumber(d.r) or PASSIVE_MAX_RANGE
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

local isRegistered = checkRegistration()
if not isRegistered then
    showNotRegisteredAndHalt()
    return
end

term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.green)
print("Registration OK. Starting GHG sonar...")
sleep(0.5)

-- ==========================================
-- GPU 绘制辅助 (声纳方位圆盘)
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
local function gpuDrawTinyTriangle(g, cx, cy, color)
    g.line(cx, cy-1, cx, cy-1, color)
    g.line(cx-1, cy, cx+1, cy, color)
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
    -- 外圈、内圈
    gpuDrawCircle(g,cx,cy,r,C.OUTER_RING)
    gpuDrawCircle(g,cx,cy,math_floor(r/2),C.INNER_RING)
    -- 十字线
    g.line(cx,cy-r,cx,cy+r,C.GRID); g.line(cx-r,cy,cx+r,cy,C.GRID)
    -- 点状网格
    for t=-r,r do
        if t%4<2 then
            local py=cy+t
            local px1=cx+t
            if (px1-cx)^2+(py-cy)^2<=r*r then g.line(px1,py,px1,py,C.GRID) end
            local px2=cx-t
            if (px2-cx)^2+(py-cy)^2<=r*r then g.line(px2,py,px2,py,C.GRID) end
        end
    end
    -- 北标 (利用当前北向，注意 yawOffset)
    local northRad=math_rad(yawOffset)
    local circPx=cx+math_floor(r*math_sin(northRad)+0.5)
    local circPy=cy-math_floor(r*math_cos(northRad)+0.5)
    local tX=math_max(1,math_min(entry.w-6,circPx-3))
    local tY=math_max(1,math_min(entry.h-8,circPy-4))
    pcall(g.drawText,tX,tY,"N",C.YELLOW,C.BG,1)
end

-- 绘制一个目标（含左右模糊镜像）
local function gpuDrawTarget(entry, distRatio, yawRad, col, isAmbiguous)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy
    local r=entry.r; local ds=entry.dotSize
    local function plot(angleRad, color)
        local px = cx + math_floor(r * distRatio * math_sin(angleRad) + 0.5)
        local py = cy - math_floor(r * distRatio * math_cos(angleRad) + 0.5)
        for dy = -ds, ds do
            for dx = -ds, ds do
                if dx*dx + dy*dy <= ds*ds then
                    g.line(px+dx, py+dy, px+dx, py+dy, color)
                end
            end
        end
    end
    -- 真实方位
    plot(yawRad, col)
    -- 左右模糊镜像：360°-原方位 (即补角)
    if isAmbiguous then
        local mirrorRad = math_rad(360) - yawRad
        plot(mirrorRad, C.AMBIG)
    end
end

local function gpuRefreshSonar(entry)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy
    local r=entry.r; local ds=entry.dotSize
    gpuDrawSonarBase(entry)

    -- 绘制所有有效目标
    local now = os_clock()
    targetPoolCount = 0
    for _, data in pairs(targets) do
        if data.lastSeen and (now - data.lastSeen < TARGET_FADE_DURATION) then
            local hotColor
            if data.iff == "friendly" then hotColor = C.ALLY_HOT
            elseif data.iff == "enemy" then hotColor = C.FOE_HOT
            else hotColor = C.UNK_HOT end
            local age = now - data.lastSeen
            local col = calcFadeColor(age, hotColor)
            if col and col ~= C.BLACK then
                local distRatio = math_min((data.realDist or PASSIVE_MAX_RANGE) / PASSIVE_MAX_RANGE, 1.0)
                -- 方位需要基于绝对坐标计算相对本船的方向，已在 updateTargets 中存为 data.paintedYaw
                local yawRad = math_rad(data.paintedYaw + yawOffset)
                gpuDrawTarget(entry, distRatio, yawRad, col, true)  -- 总是左右模糊
            end
        end
    end

    gpuDrawIffCorners(entry)
    g.sync()
end

-- ==========================================
-- 声纳 GPU 主循环 (原 rdrGpuUI)
-- ==========================================
local function sonarGpuUI()
    if #sonarGpuList == 0 then return end
    while true do
        if currentScreenTab == 2 or isPaused then
            sleep(0.3)
        else
            for _, entry in ipairs(sonarGpuList) do
                pcall(gpuRefreshSonar, entry)
            end
            sleep(0.1)
        end
    end
end

-- ==========================================
-- HUD 主循环 (简化：移除扫描状态，改为距离/方位)
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
                sText = "PASSIVE"
                sColor = colors.green
                rText = string.format("%dm", math_floor(PASSIVE_MAX_RANGE))
                rColor = colors.lime
                if selectedTargetId and targets[selectedTargetId] then
                    local sel = targets[selectedTargetId]
                    local bearing = (sel.paintedYaw + 360) % 360
                    local dist = string.format("%.0fm", sel.realDist or 0)
                    local idStr = tostring(sel.name or "??")
                    if sel.iff == "friendly" then
                        lText = "ALLY"; lColor = colors.green
                        dText = dist .. " " .. idStr .. " " .. string.format("%03d", bearing) .. "°"
                        dColor = colors.green
                    elseif sel.iff == "enemy" then
                        lText = "ENEMY"; lColor = colors.red
                        dText = dist .. " " .. idStr .. " " .. string.format("%03d", bearing) .. "°"
                        dColor = colors.white
                    else
                        lText = "CONTACT"; lColor = colors.yellow
                        dText = dist .. " " .. idStr .. " " .. string.format("%03d", bearing) .. "°"
                        dColor = colors.white
                    end
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
-- 终端 UI (简化参数)
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

            drawInputBox(4,  "Hydro Offset:", yawOffset, menuIndex==1, isEditing)

            term.setCursorPos(2,10); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            term.setCursorPos(2,12); term.setTextColor(colors.lime)
            term.write(string.format("Registered : %s", myLabel))
            term.setCursorPos(2,13); term.setTextColor(colors.cyan)
            term.write(string.format("Max Range  : %.0f m", PASSIVE_MAX_RANGE))
            term.setCursorPos(2,14); term.setTextColor(colors.gray)
            term.write("Mode       : PASSIVE ONLY")
            term.setCursorPos(2,16); term.setTextColor(colors.gray)
            term.write("Camera     : ONLINE")
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
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 输入事件循环 (简化菜单只有一项)
-- ==========================================
local function inputLoop()
    local function applySave()
        if menuIndex == 1 then
            local p = tonumber(inputStr)
            if p then yawOffset = p end
        end
        saveConfig()
        isEditing = false
    end

    while true do
        local event, p1, p2, p3 = os_pullEvent()

        if event == "key" then
            if p1 == keys.tab then
                currentScreenTab = (currentScreenTab == 1) and 2 or 1
                isPaused = (currentScreenTab == 2)
            elseif isEditing and currentScreenTab == 1 then
                if p1 == keys.enter or p1 == keys.numPadEnter then
                    applySave()
                elseif p1 == keys.backspace then
                    inputStr = inputStr:sub(1,-2)
                end
            elseif currentScreenTab == 1 then
                if p1 == keys.up then menuIndex = math_max(1, menuIndex-1)
                elseif p1 == keys.down then menuIndex = math_min(1, menuIndex+1)
                elseif p1 == keys.enter or p1 == keys.numPadEnter then
                    isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset) end
                end
            end
        elseif event == "char" and isEditing and currentScreenTab == 1 then
            if menuIndex == 1 then
                if (p1 >= '0' and p1 <= '9') or p1 == '.' or (p1 == '-' and #inputStr == 0) then
                    if #inputStr < 8 then inputStr = inputStr .. p1 end
                end
            end
        elseif event == "mouse_click" then
            local touchY = p3
            if currentScreenTab == 1 then
                local ti = nil
                if touchY == 4 then ti = 1 end
                if ti then
                    if isEditing and menuIndex ~= ti then applySave() end
                    menuIndex = ti
                    isEditing = true
                    if menuIndex == 1 then inputStr = tostring(yawOffset) end
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
                local minSqDist = (math_max(entry.dotSize*3, entry.r*0.04))^2
                for id, data in pairs(targets) do
                    if data.lastSeen and (now - data.lastSeen < TARGET_FADE_DURATION) then
                        local distRatio = math_min((data.realDist or PASSIVE_MAX_RANGE) / PASSIVE_MAX_RANGE, 1.0)
                        local yawRad = math_rad(data.paintedYaw + yawOffset)
                        local px = entry.cx + math_floor(entry.r * distRatio * math_sin(yawRad) + 0.5)
                        local py = entry.cy - math_floor(entry.r * distRatio * math_cos(yawRad) + 0.5)
                        local dSq = (mx-px)^2 + (my-py)^2
                        if dSq <= minSqDist then
                            minSqDist = dSq
                            clickedId = id
                        end
                    end
                end
                if clickedId then
                    if iffMode == "friendly" then
                        targets[clickedId].iff = "friendly"
                    else
                        for id, data in pairs(targets) do
                            if id ~= clickedId and data.iff == "enemy" then data.iff = nil end
                        end
                        targets[clickedId].iff = "enemy"
                        selectedTargetId = clickedId
                        selectedTargetDistStr = string.format("%dm", math_floor((targets[clickedId].realDist or 0) + 0.5))
                    end
                end
            end
        end
    end
end

-- ==========================================
-- 网络协议 (只接收，不发送)
-- ==========================================
local function listenLoop()
    while true do
        local ev, p1, p2, p3, p4, p5 = os_pullEvent()
        if ev == "modem_message" then
            local ch = p2
            local msg = p5
            local dist = p4
            if ch == CHANNEL and type(msg) == "table" and msg.v == 2 then
                -- 接收其他船只的广播 (t=1)
                if msg.t == 1 and msg.i ~= myId then
                    if not targets[msg.i] then targets[msg.i] = {} end
                    local t = targets[msg.i]
                    t.name = msg.n
                    t.modemDist = dist
                    t.realPos = {x = msg.x, y = msg.y, z = msg.z}
                    t.realDist = calcRangingDist(localPos, t.realPos) or dist
                    t.lastSeen = os_clock()
                    t.isBeacon = false
                -- 不再处理 t=2, t=3 等主动照射或信标，水听只看 t=1
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
-- 主循环：更新所有目标方位 (被动持续监听)
-- ==========================================
local function passiveListenerLoop()
    while true do
        if currentScreenTab == 2 or isPaused then
            sleep(0.5)
        else
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

            -- 更新所有已有目标的方位
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
                            local iqx, iqy, iqz, iqw = quatInverse(currentQAbs.x, currentQAbs.y, currentQAbs.z, currentQAbs.w)
                            local hx, hy, hz = rotateVectorFast(dx, dy, dz, iqx, iqy, iqz, iqw)
                            local sx, sy, sz = rotateVectorFast(hx, hy, hz, currentQLoc.x, currentQLoc.y, currentQLoc.z, currentQLoc.w)
                            tYaw = math_deg(math_atan2(-sx, sz))
                        else
                            _, tYaw = calculateLookAngles(localPos.x, localPos.y, localPos.z,
                                                         data.realPos.x, data.realPos.y, data.realPos.z)
                        end
                        data.paintedYaw = tYaw
                    end
                end
            end

            -- 清除超时目标
            local now = os_clock()
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
print("GHG Sonar v1.0 - OK")
print(string.format("  Name      : %s  [fixed]", myLabel))
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
