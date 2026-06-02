--[[ GHG 被动定向水听器 v3.3
     修复新目标因速度 nil 无法显示的问题
     心跳发送无害 t=1（坐标0）维持在线
     动态深度范围、速度过滤、目标线、HUD 优化、完整界面
--]]

-- ==========================================
--  全局配置
-- ==========================================
local CHANNEL                  = 8888
local TARGET_FADE_DURATION     = 8.0
local TARGET_HOT_DURATION      = 2.0
local SCAN_SECTOR_WIDTH        = 30.0    -- 监听扇区宽度
local REG_QUERY_TIMEOUT        = 5.0
local SPEED_INTERVAL           = 3.0     -- 测速间隔
local MIN_SPEED_KMH            = 4.0     -- 速度过滤阈值
local HEARTBEAT_INTERVAL       = 5.0     -- 心跳间隔

-- 深度映射 (请修改 SEA_LEVEL_Y 为实际海平面 Y，F3 查看)
local SEA_LEVEL_Y    = -4
local RANGE_SURFACE  = 1000
local RANGE_DEEP     = 5000
local DEEP_Y         = -14

-- ==========================================
-- 外设初始化
-- ==========================================
local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then error("Wireless modem not found!", 0) end
modem.open(CHANNEL)

local camera, cameraName = nil, nil
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "camera" then
        camera = peripheral.wrap(name)
        cameraName = name
        break
    end
end
if not camera then error("Camera not found!", 0) end

local cachedServo = peripheral.find("servo")
local isServoConnected = false

redstone.setOutput("front", false)

local myId        = os.getComputerID()
local CONFIG_FILE = "ghg_config.txt"

-- ==========================================
-- 全局 API 别名
-- ==========================================
local math_sqrt  = math.sqrt
local math_atan2 = math.atan2
local math_deg   = math.deg
local math_rad   = math.rad
local math_floor = math.floor
local math_abs   = math.abs
local math_min   = math.min
local math_max   = math.max
local math_sin   = math.sin
local math_cos   = math.cos
local os_clock   = os.clock
local os_pullEvent = os.pullEvent

-- ==========================================
-- 颜色工具
-- ==========================================
local function colorUnpack(c)
    return math_floor(c / 65536) % 256,
           math_floor(c / 256)   % 256,
           c % 256
end
local function colorPack(r, g, b)
    return math_floor(r) * 65536 + math_floor(g) * 256 + math_floor(b)
end
local function colorLerp(ca, cb, t)
    t = math_max(0.0, math_min(1.0, t))
    local ar, ag, ab = colorUnpack(ca)
    local br, bg, bb = colorUnpack(cb)
    return colorPack(ar + (br-ar)*t, ag + (bg-ag)*t, ab + (bb-ab)*t)
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
local currentServoAngle     = 0
local yawOffset             = 0
local motorOffset           = 0
local myLabel               = os.getComputerLabel() or ("Hydro-" .. myId)
local monitorModes          = {}
local aimPrecision          = 5
local currentRadarRange     = 0
local currentNorthYawDeg    = 0
local currentScreenTab      = 1
local menuIndex             = 1
local isEditing             = false
local inputStr              = ""
local iffMode               = "enemy"
local targetPool            = {}
local targetPoolCount       = 0
local speedTimer            = nil

-- ==========================================
--  配置文件
-- ==========================================
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            if data.yawOffset   then yawOffset   = tonumber(data.yawOffset)   or 0 end
            if data.motorOffset then motorOffset = tonumber(data.motorOffset) or 0 end
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
-- 数学/物理函数
-- ==========================================
local function calculateLookAngles(sx, sy, sz, tx, ty, tz)
    local dx, dy, dz = tx - sx, ty - sy, tz - sz
    local distH = math_sqrt(dx*dx + dz*dz)
    return math_deg(math_atan2(-dy, distH)), math_deg(math_atan2(-dx, dz))
end
local function getAngleDiff(a, b)
    local diff = (a - b) % 360
    if diff > 180 then diff = diff - 360 elseif diff < -180 then diff = diff + 360 end
    return diff
end
local function quatInverse(qx, qy, qz, qw) return -qx, -qy, -qz, qw end
local function rotateVectorFast(vx, vy, vz, qx, qy, qz, qw)
    local cx  = qy*vz - qz*vy; local cy  = qz*vx - qx*vz; local cz  = qx*vy - qy*vx
    local ccx = qy*cz - qz*cy; local ccy = qz*cx - qx*cz; local ccz = qx*cy - qy*cx
    return vx+2*qw*cx+2*ccx, vy+2*qw*cy+2*ccy, vz+2*qw*cz+2*ccz
end
local function calcRangingDist(refPos, targetPos)
    if not refPos or not targetPos then return nil end
    local dx = targetPos.x - refPos.x; local dy = targetPos.y - refPos.y; local dz = targetPos.z - refPos.z
    return math_sqrt(dx*dx + dy*dy + dz*dz)
end
local function radialSymbol(radial_speed)
    if not radial_speed then return "?" end
    if radial_speed > 0.5 then return "A" elseif radial_speed < -0.5 then return "C" else return "=" end
end
local function pointToSegmentSq(px, py, p1x, p1y, p2x, p2y)
    local dx, dy = p2x-p1x, p2y-p1y
    if dx==0 and dy==0 then return (px-p1x)^2 + (py-p1y)^2 end
    local t = ((px-p1x)*dx + (py-p1y)*dy) / (dx*dx + dy*dy)
    t = math_max(0, math_min(1, t))
    local nearX, nearY = p1x + t*dx, p1y + t*dy
    return (px-nearX)^2 + (py-nearY)^2
end

-- ==========================================
-- 颜色常量（黑底黄绿主题）
-- ==========================================
local C = {
    BG          = 0x000000,
    OUTER_RING  = 0xFFCC00,
    INNER_RING  = 0x997700,
    GRID        = 0x332200,
    LISTEN_LINE = 0xFFFFFF,
    TARGET_LINE = 0x0066FF,
    LOCKED_LINE = 0xFF0000,
    YELLOW      = 0xFFFF00,
    CORNER_FOE  = 0x440000,
    CORNER_ALLY = 0x002200,
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
        local bw = math.ceil(cw/9)
        local bh = math.ceil(ch/7)
        if bw >= 5 then bw = bw - 1 end
        table.insert(hudMonitorList, {
            m = m, name = name, displayName = "Monitor "..mIndex,
            bw = math.max(1, bw), bh = math.max(1, bh),
            mode = monitorModes[name] or "STATUS",
            lastSText=nil, lastRText=nil, lastLText=nil, lastDText=nil,
        })
        mIndex = mIndex + 1
    end
end

-- ==========================================
-- GPU 列表
-- ==========================================
local BLOCK_PX_W, BLOCK_PX_H = 85, 64
local rdrGpuList = {}
local gpuNameMap = {}

local function initGpuList()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "tm_gpu" then
            local g = peripheral.wrap(name)
            pcall(g.refreshSize); pcall(g.setSize, 64); pcall(g.fill, C.BG)
            local ok, w, h = pcall(g.getSize)
            if not ok then w, h = 256, 128 end
            w, h = w or 256, h or 128
            local cx, cy = math_floor(w/2), math_floor(h/2)
            local r = math_floor(math_min(cx, cy)*0.88)
            local bw = math_max(1, math_floor(w/BLOCK_PX_W))
            local bh = math_max(1, math_floor(h/BLOCK_PX_H))
            local dotSize
            if r>=110 then dotSize=4 elseif r>=80 then dotSize=3 elseif r>=50 then dotSize=2 else dotSize=1 end
            if bw>=3 and bh>=3 then dotSize = dotSize+1 end
            dotSize = math_max(2, dotSize)
            table.insert(rdrGpuList, {
                gpu=g, name=name, w=w, h=h, cx=cx, cy=cy, r=r,
                bw=bw, bh=bh, dotSize=dotSize,
            })
            gpuNameMap[name] = {gpu=g, cx=cx, cy=cy, r=r, w=w, h=h, dotSize=dotSize}
        end
    end
end
initGpuList()
local isHeadless = (#hudMonitorList==0 and #rdrGpuList==0)

-- ==========================================
-- 注册检查
-- ==========================================
local function checkRegistration()
    term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1,1)
    term.setTextColor(colors.cyan); print("GHG Sonar v3.3 - Registration")
    term.setTextColor(colors.white); print("My ID: " .. myId); print("Querying scanner...")

    for _, entry in ipairs(rdrGpuList) do
        pcall(function()
            entry.gpu.fill(C.BG)
            local msg = "CHECKING..."
            local tx = math_max(1, entry.cx - math_floor(#msg*6))
            local ty = entry.cy - 8
            pcall(entry.gpu.drawText, tx, ty, msg, C.YELLOW, C.BG, 2)
            entry.gpu.sync()
        end)
    end

    modem.transmit(CHANNEL, CHANNEL, { v=2, t=4, i=myId })
    local timer = os.startTimer(REG_QUERY_TIMEOUT)
    while true do
        local ev, a, b, c, d = os_pullEvent()
        if ev == "modem_message" then
            if b == CHANNEL and type(d)=="table" and d.v==2 then
                if d.t==5 and d.ti==myId then
                    os.cancelTimer(timer)
                    myLabel = tostring(d.n or myLabel)
                    term.setTextColor(colors.lime)
                    print("Registered: " .. myLabel)
                    sleep(0.8)
                    return true
                elseif d.t==6 and d.ti==myId then
                    os.cancelTimer(timer); term.setTextColor(colors.red); print("Denied!"); sleep(0.5); return false
                end
            end
        elseif ev=="timer" and a==timer then
            term.setTextColor(colors.orange); print("Timeout"); sleep(0.5); return false
        end
    end
end

local function showNotRegisteredAndHalt()
    for _, entry in ipairs(rdrGpuList) do
        pcall(function()
            local g = entry.gpu
            local cx, cy = entry.cx, entry.cy
            local w, h = entry.w, entry.h
            g.fill(C.UNREG_BG)
            local bx1, by1 = math_floor(cx * 0.3), math_floor(cy * 0.5)
            local bx2, by2 = w - bx1, h - by1
            g.line(bx1, by1, bx2, by1, C.UNREG_FG)
            g.line(bx1, by2, bx2, by2, C.UNREG_FG)
            g.line(bx1, by1, bx1, by2, C.UNREG_FG)
            g.line(bx2, by1, bx2, by2, C.UNREG_FG)
            local line1 = "NOT REGISTERED"
            local tx1 = math_max(bx1+4, cx - math_floor(#line1*6))
            pcall(g.drawText, tx1, cy-14, line1, C.UNREG_FG, C.UNREG_BG, 2)
            local line2 = string.format("ID: %d", myId)
            local tx2 = math_max(bx1+4, cx - math_floor(#line2*3))
            pcall(g.drawText, tx2, cy+6, line2, 0xAAAAAA, C.UNREG_BG, 1)
            local line3 = "Register in scanner"
            local tx3 = math_max(bx1+4, cx - math_floor(#line3*3))
            pcall(g.drawText, tx3, cy+18, line3, 0x666666, C.UNREG_BG, 1)
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
            m.setCursorPos(math_max(1, math_floor((dw-#msg1)/2)+1), math_max(1, math_floor(dh/2)-1))
            m.write(msg1)
            m.setTextColor(colors.gray)
            m.setCursorPos(math_max(1, math_floor((dw-#msg2)/2)+1), math_floor(dh/2)+1)
            m.write(msg2)
            m.setTextColor(colors.lightGray)
            m.setCursorPos(math_max(1, math_floor((dw-#msg3)/2)+1), math_floor(dh/2)+2)
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
    local startRow = math_max(1, math_floor((th - #lines)/2))
    for i, line in ipairs(lines) do
        local col = math_max(1, math_floor((tw - #line[1])/2) + 1)
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

term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1,1)
term.setTextColor(colors.green); print("Registration OK. Starting sonar...")
speedTimer = os.startTimer(SPEED_INTERVAL)
sleep(0.5)

-- ==========================================
-- GPU 绘制函数
-- ==========================================
local function gpuDrawCircle(g, cx, cy, r, color)
    local x, y, d = r, 0, 1-r
    while x >= y do
        g.line(cx+x,cy+y,cx+x,cy+y,color); g.line(cx-x,cy+y,cx-x,cy+y,color)
        g.line(cx+x,cy-y,cx+x,cy-y,color); g.line(cx-x,cy-y,cx-x,cy-y,color)
        g.line(cx+y,cy+x,cx+y,cy+x,color); g.line(cx-y,cy+x,cx-y,cy+x,color)
        g.line(cx+y,cy-x,cx+y,cy-x,color); g.line(cx-y,cy-x,cx-y,cy-x,color)
        y = y+1; if d<0 then d = d+2*y+1 else x = x-1; d = d+2*(y-x)+1 end
    end
end
local function gpuDrawIffCorners(entry)
    local g, W, H = entry.gpu, entry.w, entry.h
    local col = (iffMode=="friendly") and C.CORNER_ALLY or C.CORNER_FOE
    local L_LEN, L_THICK = 14, 2
    local function corner(ox,oy,hx,hy,vx,vy)
        for t=0,L_THICK-1 do
            g.line(ox+vx*t, oy+vy*t, ox+vx*t+hx*(L_LEN-1), oy+vy*t+hy*(L_LEN-1), col)
            g.line(ox+hx*t, oy+hy*t, ox+hx*t+vx*(L_LEN-1), oy+hy*t+vy*(L_LEN-1), col)
        end
    end
    corner(1,1,1,0,0,1); corner(W,1,-1,0,0,1); corner(1,H,1,0,0,-1); corner(W,H,-1,0,0,-1)
end
local function gpuDrawSonarBase(entry)
    local g, cx, cy, r = entry.gpu, entry.cx, entry.cy, entry.r
    g.fill(C.BG)
    gpuDrawCircle(g,cx,cy,r,C.OUTER_RING); gpuDrawCircle(g,cx,cy,math_floor(r/2),C.INNER_RING)
    g.line(cx,cy-r,cx,cy+r,C.GRID); g.line(cx-r,cy,cx+r,cy,C.GRID)
    for t=-r,r do
        if t%4<2 then
            local py = cy+t
            if (cx+t-cx)^2+(py-cy)^2 <= r*r then g.line(cx+t,py,cx+t,py,C.GRID) end
            if (cx-t-cx)^2+(py-cy)^2 <= r*r then g.line(cx-t,py,cx-t,py,C.GRID) end
        end
    end
    local labels = {[0]="N", [90]="E", [180]="S", [270]="W"}
    for deg=0,315,45 do
        local rad = math_rad(deg + currentNorthYawDeg + yawOffset)
        local sinA, cosA = math_sin(rad), math_cos(rad)
        local x0 = cx + math_floor((r-6)*sinA+0.5); local y0 = cy - math_floor((r-6)*cosA+0.5)
        local x1 = cx + math_floor(r*sinA+0.5); local y1 = cy - math_floor(r*cosA+0.5)
        g.line(x0,y0,x1,y1,C.OUTER_RING)
        local label = labels[deg]
        if label then
            local tx = cx + math_floor((r-12)*sinA+0.5) - 4
            local ty = cy - math_floor((r-12)*cosA+0.5) - 4
            tx = math_max(1, math_min(entry.w-8, tx)); ty = math_max(1, math_min(entry.h-8, ty))
            pcall(g.drawText, tx, ty, label, C.WHITE, C.BG, 1)
        end
    end
end
local function gpuDrawListeningLine(entry, angleDeg)
    local g, cx, cy, r = entry.gpu, entry.cx, entry.cy, entry.r
    local rad = math_rad(angleDeg + yawOffset)
    local ex = cx + math_floor(r*math_sin(rad)+0.5); local ey = cy - math_floor(r*math_cos(rad)+0.5)
    g.line(cx,cy,ex,ey,C.LISTEN_LINE)
    local arrLen = 4
    local rad1 = math_rad(angleDeg+yawOffset+150); local rad2 = math_rad(angleDeg+yawOffset-150)
    g.line(ex,ey, ex+math_floor(arrLen*math_sin(rad1)+0.5), ey-math_floor(arrLen*math_cos(rad1)+0.5), C.LISTEN_LINE)
    g.line(ex,ey, ex+math_floor(arrLen*math_sin(rad2)+0.5), ey-math_floor(arrLen*math_cos(rad2)+0.5), C.LISTEN_LINE)
end
local function gpuDrawTargetLine(entry, yawRad, color, targetData)
    local g, cx, cy, r = entry.gpu, entry.cx, entry.cy, entry.r
    local ex = cx + math_floor(r*math_sin(yawRad)+0.5); local ey = cy - math_floor(r*math_cos(yawRad)+0.5)
    g.line(cx,cy,ex,ey,color)
    if targetData then
        local relBearing = (targetData.paintedYaw + 360) % 360
        local absBearing = (relBearing + currentNorthYawDeg + yawOffset + 360) % 360
        local speedStr = "?km/h"
        if targetData.speed then speedStr = string.format("%.1fkm/h", targetData.speed * 3.6) end
        local radial = radialSymbol(targetData.radialSpeed)
        local text = string.format("%03d/%03d %s%s", relBearing, absBearing, speedStr, radial)
        local tx = math_max(1, math_min(entry.w-1, ex + 8*math_sin(yawRad)))
        local ty = math_max(1, math_min(entry.h-1, ey - 8*math_cos(yawRad)))
        pcall(g.drawText, tx, ty, text, 0xFFFFFF, C.BG, 0)
    end
end
local function gpuRefreshSonar(entry, isActive, poolCount, pool)
    gpuDrawSonarBase(entry)
    if isServoConnected then gpuDrawListeningLine(entry, currentServoAngle) end
    for i=1, poolCount do
        local t = pool[i]
        gpuDrawTargetLine(entry, t.rad, t.color, t.data)
    end
    gpuDrawIffCorners(entry)
    entry.gpu.sync()
end

-- ==========================================
-- GPU 主循环 (targetPool 构建)
-- ==========================================
local function rdrGpuUI()
    if #rdrGpuList==0 then return end
    local frames=0; local lastActive=false; local lastIff=nil
    while true do
        if currentScreenTab==2 then
            for _,entry in ipairs(rdrGpuList) do
                pcall(function()
                    entry.gpu.fill(C.BG)
                    pcall(entry.gpu.drawText, entry.cx-6, entry.cy-4, entry.name, C.WHITE, C.BG, 2)
                    entry.gpu.sync()
                end)
            end
            sleep(0.3)
        else
            frames=frames+1
            local isActive = (currentRadarRange>0)
            local forceRedraw = (isActive~=lastActive) or (iffMode~=lastIff)
            lastActive=isActive; lastIff=iffMode
            targetPoolCount=0
            local now=os_clock()
            if localPos and isActive then
                for _,data in pairs(targets) do
                    if data.lastPainted and (now - data.lastPainted < TARGET_FADE_DURATION) then
                        local col = calcFadeColor(now - data.lastPainted, C.ALLY_HOT)
                        if col then
                            targetPoolCount = targetPoolCount + 1
                            local t = targetPool[targetPoolCount]
                            if not t then t = {}; targetPool[targetPoolCount] = t end
                            t.rad = math_rad(data.paintedYaw + yawOffset)
                            t.color = C.TARGET_LINE
                            t.data = data
                        end
                    end
                end
                if selectedTargetId and targets[selectedTargetId] and targets[selectedTargetId].paintedYaw then
                    local data = targets[selectedTargetId]
                    targetPoolCount = targetPoolCount + 1
                    local t = targetPool[targetPoolCount]
                    if not t then t = {}; targetPool[targetPoolCount] = t end
                    t.rad = math_rad(data.paintedYaw + yawOffset)
                    t.color = C.LOCKED_LINE
                    t.data = data
                end
            end
            for _,entry in ipairs(rdrGpuList) do
                pcall(gpuRefreshSonar, entry, isActive, targetPoolCount, targetPool)
            end
            sleep(0.05)
        end
    end
end

-- ==========================================
-- HUD 主循环
-- ==========================================
local function hudMonitorUI()
    if #hudMonitorList==0 then return end
    local frames=0
    while true do
        frames=frames+1
        local isFirstFrame=(frames<=2)
        local isActive=(currentRadarRange>0)
        for _,info in ipairs(hudMonitorList) do
            if info.mode=="STATUS" then
                local sText,sColor,rText,rColor,lText,lColor,dText,dColor
                if not isActive then
                    sText="OFFLINE"; sColor=colors.red; rText="---"; rColor=colors.gray
                    lText="---"; lColor=colors.gray; dText="---"; dColor=colors.gray
                else
                    sText="PASSIVE"; sColor=colors.green
                    rText=string.format("%dm", math_floor(currentRadarRange)); rColor=colors.lime
                    if selectedTargetId and targets[selectedTargetId] then
                        local sel=targets[selectedTargetId]
                        local relB = (sel.paintedYaw + 360) % 360
                        local absB = (relB + currentNorthYawDeg + yawOffset + 360) % 360
                        local distStr = string.format("%.0fm", sel.paintedDist or 0)
                        local spdStr = sel.speed and string.format("%.1fkm/h", sel.speed*3.6) or "?km/h"
                        local idStr = tostring(sel.name or "??")
                        lText = idStr .. " " .. distStr
                        dText = string.format("%03d/%03d %s%s", relB, absB, spdStr, radialSymbol(sel.radialSpeed))
                        if sel.iff=="friendly" then lColor=colors.green; dColor=colors.green
                        elseif sel.iff=="enemy" then lColor=colors.red; dColor=colors.white
                        else lColor=colors.yellow; dColor=colors.white end
                    else
                        lText="LISTEN"; lColor=colors.lightGray; dText="---"; dColor=colors.gray
                    end
                end
                if isFirstFrame or sText~=info.lastSText or rText~=info.lastRText or lText~=info.lastLText or dText~=info.lastDText then
                    info.m.setBackgroundColor(colors.black); info.m.clear()
                    local dw,dh=info.m.getSize()
                    local function drawCL(txt,col,y) info.m.setTextColor(col); info.m.setCursorPos(math_max(1,(dw-#txt)/2+1),y); info.m.write(txt) end
                    drawCL(sText,sColor, math_floor(dh/2)-3)
                    drawCL(rText,rColor, math_floor(dh/2)-1)
                    drawCL(lText,lColor, math_floor(dh/2)+1)
                    drawCL(dText,colors.white, math_floor(dh/2)+3)
                    info.lastSText=sText; info.lastRText=rText; info.lastLText=lText; info.lastDText=dText
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
        term.setBackgroundColor(colors.black); term.clear()
        if currentScreenTab==2 then
            term.setCursorPos(2,2); term.setTextColor(colors.lightGray); term.write("=== CONNECTED DISPLAYS ===")
            local r=4
            term.setCursorPos(2,r); term.setTextColor(colors.cyan); term.write("[TOM'S GPU - SONAR]"); r=r+1
            if #rdrGpuList==0 then term.setCursorPos(4,r); term.setTextColor(colors.red); term.write("No tm_gpu"); r=r+1
            else for _,e in ipairs(rdrGpuList) do term.setCursorPos(4,r); term.setTextColor(colors.lightBlue); term.write("- "..e.name); r=r+1 end end
            r=r+1; term.setCursorPos(2,r); term.setTextColor(colors.cyan); term.write("[CC MONITOR - HUD]"); r=r+1
            if #hudMonitorList==0 then term.setCursorPos(4,r); term.setTextColor(colors.red); term.write("No monitors"); r=r+1
            else for _,info in ipairs(hudMonitorList) do term.setCursorPos(4,r); term.setTextColor(colors.lightBlue); term.write("- "..info.displayName); r=r+1 end end
            r=r+1; term.setCursorPos(2,r); term.setTextColor(colors.lightGray); term.write("Camera: "..cameraName.."  [ONLINE]")
            r=r+2; term.setCursorPos(2,r); term.setTextColor(colors.yellow); term.write("Press [TAB] to Resume")
        else
            term.setCursorPos(2,2); term.setTextColor(colors.yellow); term.write("=== SONAR CONFIG ===")
            local function drawInputBox(y,label,val,sel,edit)
                term.setCursorPos(2,y); term.setBackgroundColor(colors.black)
                term.setTextColor(sel and colors.yellow or colors.lightGray); term.write(label)
                term.setCursorPos(15,y); term.setBackgroundColor(colors.gray)
                local txt = (sel and edit) and (inputStr.."_") or tostring(val)
                term.setTextColor(sel and colors.white or colors.lightGray)
                term.write(string.format(" %-12s ", txt)); term.setBackgroundColor(colors.black)
            end
            drawInputBox(4, "Hydro Offset:", yawOffset, menuIndex==1, isEditing)
            drawInputBox(6, "Motor Offset:", motorOffset, menuIndex==2, isEditing)
            term.setCursorPos(2,10); term.setTextColor(colors.yellow); term.write("=== SYSTEM STATUS ===")
            term.setCursorPos(2,12); term.setTextColor(colors.lime); term.write("Registered: "..myLabel)
            term.setCursorPos(2,13); term.setTextColor(colors.cyan); term.write("Max Range: "..math_floor(currentRadarRange).." m (dynamic)")
            term.setCursorPos(2,16); if isServoConnected then term.setTextColor(colors.white); term.write("Listen Dir: "..string.format("%.1f", currentServoAngle).." deg") else term.setTextColor(colors.red); term.write("Listen Dir: OFFLINE") end
            term.setCursorPos(2,18); if iffMode=="friendly" then term.setTextColor(colors.lightBlue); term.write("IFF: ALLY") else term.setTextColor(colors.red); term.write("IFF: FOE") end
            term.setCursorPos(2,19); term.setTextColor(colors.gray); term.write("[TAB] Monitor  [Back RS] IFF")
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 输入事件（线段点选锁定/取消）
-- ==========================================
local function inputLoop()
    local function applySave()
        if menuIndex==1 then yawOffset = tonumber(inputStr) or yawOffset
        elseif menuIndex==2 then motorOffset = tonumber(inputStr) or motorOffset end
        saveConfig(); isEditing = false
    end
    while true do
        local event, p1, p2, p3 = os_pullEvent()
        if event=="key" then
            if p1==keys.tab then currentScreenTab = (currentScreenTab==1) and 2 or 1
            elseif isEditing and currentScreenTab==1 then
                if p1==keys.enter or p1==keys.numPadEnter then applySave()
                elseif p1==keys.backspace then inputStr = inputStr:sub(1,-2) end
            elseif currentScreenTab==1 then
                if p1==keys.up then menuIndex = math_max(1, menuIndex-1)
                elseif p1==keys.down then menuIndex = math_min(2, menuIndex+1)
                elseif p1==keys.enter or p1==keys.numPadEnter then
                    isEditing = true
                    inputStr = tostring(menuIndex==1 and yawOffset or motorOffset)
                end
            end
        elseif event=="char" and isEditing then
            if (p1>='0' and p1<='9') or p1=='.' or (p1=='-' and #inputStr==0) then
                if #inputStr<8 then inputStr = inputStr..p1 end
            end
        elseif (event=="tm_monitor_touch" or event=="tm_monitor_mouse_click") and currentScreenTab==1 then
            local entry = gpuNameMap[p1]
            if entry then
                local mx, my = p2, p3
                for id, data in pairs(targets) do
                    if data.paintedYaw then
                        local rad = math_rad(data.paintedYaw + yawOffset)
                        local ex = entry.cx + math_floor(entry.r*math_sin(rad)+0.5)
                        local ey = entry.cy - math_floor(entry.r*math_cos(rad)+0.5)
                        local dx, dy = ex-entry.cx, ey-entry.cy
                        local lenSq = dx*dx+dy*dy
                        local t = ((mx-entry.cx)*dx + (my-entry.cy)*dy) / lenSq
                        t = math_max(0, math_min(1, t))
                        local nearX, nearY = entry.cx + t*dx, entry.cy + t*dy
                        if (mx-nearX)^2 + (my-nearY)^2 <= 16 then
                            if id == selectedTargetId then selectedTargetId = nil
                            else selectedTargetId = id end
                            break
                        end
                    end
                end
            end
        end
    end
end

-- ==========================================
-- 心跳循环（发送无害 t=1，坐标0）
-- ==========================================
local function heartbeatLoop()
    while true do
        if currentScreenTab ~= 2 then
            modem.transmit(CHANNEL, CHANNEL, {
                v=2, t=1, i=myId, n=myLabel,
                x=0, y=0, z=0, r=0
            })
        end
        sleep(HEARTBEAT_INTERVAL)
    end
end

-- ==========================================
-- 网络（只收 t=1）
-- ==========================================
local function listenLoop()
    while true do
        local _,_,ch,_,msg,dist = os_pullEvent("modem_message")
        if ch==CHANNEL and type(msg)=="table" and msg.v==2 and msg.t==1 and msg.i~=myId then
            if not targets[msg.i] then targets[msg.i] = {name=msg.n} end
            local t = targets[msg.i]
            t.realPos = {x=msg.x, y=msg.y, z=msg.z}
            t.modemDist = dist
            t.realDist = calcRangingDist(localPos, t.realPos) or dist
            t.lastSeen = os_clock()
        end
    end
end

-- ==========================================
-- IFF 切换（后部红石）
-- ==========================================
local function iffToggleLoop()
    local lastBack = redstone.getInput("back")
    while true do
        os_pullEvent("redstone")
        local newBack = redstone.getInput("back")
        if newBack and not lastBack then iffMode = (iffMode=="enemy") and "friendly" or "enemy" end
        lastBack = newBack
    end
end

-- ==========================================
-- 主逻辑循环（动态范围、速度过滤修复、目标更新）
-- ==========================================
local function cameraLoop()
    local lastServoAngle=nil; local peripheralPollTick=0
    while true do
        if currentScreenTab==2 then sleep(0.5)
        else
            if peripheralPollTick<=0 then
                peripheralPollTick=20
                if not cachedServo then cachedServo = peripheral.find("servo") end
            else peripheralPollTick=peripheralPollTick-1 end

            if cachedServo then
                local ok,ang=pcall(cachedServo.getAngle)
                if ok and type(ang)=="number" then
                    isServoConnected=true
                    currentServoAngle=(math_deg(ang)+motorOffset)%360
                    if lastServoAngle then
                        local deltaAngle=math_abs(getAngleDiff(currentServoAngle,lastServoAngle))
                        if deltaAngle>180 then deltaAngle=0 end
                    end
                    lastServoAngle=currentServoAngle
                else isServoConnected=false; cachedServo=nil end
            else isServoConnected=false end

            if camera then
                local ok,pos=pcall(camera.getCameraPosition)
                if ok and pos then localPos=pos else localPos=nil end
                if localPos then
                    local depth = math_max(0, (SEA_LEVEL_Y - localPos.y))
                    currentRadarRange = math_min(RANGE_DEEP, math_max(RANGE_SURFACE,
                        RANGE_SURFACE + 400 * depth))
                end
                if not isHeadless then
                    pcall(function()
                        currentQAbs=camera.getAbsViewTransform()
                        currentQLoc=camera.getLocViewTransform()
                    end)
                    if currentQAbs and currentQLoc then
                        local iqx,iqy,iqz,iqw=quatInverse(currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                        local hx,hy,hz=rotateVectorFast(0,0,-1,iqx,iqy,iqz,iqw)
                        local sx,sy,sz=rotateVectorFast(hx,hy,hz,currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                        currentNorthYawDeg=math_deg(math_atan2(-sx,sz))
                    end

                    local now=os_clock()
                    for id,data in pairs(targets) do
                        if data.realPos then
                            local dx = data.realPos.x - localPos.x
                            local dy = data.realPos.y - localPos.y
                            local dz = data.realPos.z - localPos.z
                            local dist = math_sqrt(dx*dx + dy*dy + dz*dz)
                            data.realDist = dist

                            local tYaw
                            if currentQAbs and currentQLoc then
                                local iqx,iqy,iqz,iqw=quatInverse(currentQAbs.x,currentQAbs.y,currentQAbs.z,currentQAbs.w)
                                local hx,hy,hz=rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                                local sx,sy,sz=rotateVectorFast(hx,hy,hz,currentQLoc.x,currentQLoc.y,currentQLoc.z,currentQLoc.w)
                                tYaw=math_deg(math_atan2(-sx,sz))
                            else
                                _,tYaw=calculateLookAngles(localPos.x,localPos.y,localPos.z,data.realPos.x,data.realPos.y,data.realPos.z)
                            end
                            data.paintedYaw = tYaw
                            data.paintedDist = dist

                            -- 显示控制
                            if id == selectedTargetId then
                                data.lastPainted = now
                            else
                                local inSector = true
                                if isServoConnected then
                                    inSector = math_abs(getAngleDiff(tYaw, currentServoAngle)) <= SCAN_SECTOR_WIDTH/2
                                end
                                -- 关键修复：速度未知时允许显示，仅当已知且低于阈值时才隐藏
                                local speedOK = (data.speed == nil) or (data.speed > MIN_SPEED_KMH / 3.6)
                                if inSector and dist <= currentRadarRange and speedOK then
                                    data.lastPainted = now
                                end
                            end
                        end
                    end

                    for id,data in pairs(targets) do
                        if data.lastSeen and (now-data.lastSeen > 10.0) then
                            targets[id]=nil
                            if id == selectedTargetId then selectedTargetId=nil end
                        end
                    end
                end
            end
            sleep(isHeadless and 1.0 or 0.05)
        end
    end
end

-- ==========================================
-- 测速定时器
-- ==========================================
local function speedTimerLoop()
    while true do
        local event, timerId = os_pullEvent("timer")
        if event == "timer" and timerId == speedTimer then
            local now = os_clock()
            for id, data in pairs(targets) do
                if data.lastPos and data.lastTime then
                    local dt = now - data.lastTime
                    if dt > 0.5 then
                        local dx = data.realPos.x - data.lastPos.x
                        local dy = data.realPos.y - data.lastPos.y
                        local dz = data.realPos.z - data.lastPos.z
                        data.speed = math_sqrt(dx*dx + dy*dy + dz*dz) / dt
                        if data.realDist and data.realDist > 0.01 then
                            local relX = data.realPos.x - localPos.x
                            local relY = data.realPos.y - localPos.y
                            local relZ = data.realPos.z - localPos.z
                            data.radialSpeed = (dx*relX + dy*relY + dz*relZ) / (data.realDist * dt)
                        else
                            data.radialSpeed = 0
                        end
                    end
                end
                data.lastPos = {x=data.realPos.x, y=data.realPos.y, z=data.realPos.z}
                data.lastTime = now
            end
            speedTimer = os.startTimer(SPEED_INTERVAL)
        end
    end
end

-- ==========================================
-- 启动
-- ==========================================
term.clear()
term.setCursorPos(1,1)
term.setTextColor(colors.green)
print("GHG Sonar v3.3 - Fixed Speed Nil Bug")
print("  Name : " .. myLabel)
print("  Dynamic Range (y="..SEA_LEVEL_Y..": "..RANGE_SURFACE.."m, y="..DEEP_Y..": "..RANGE_DEEP.."m)")
print("  Speed filter: > " .. MIN_SPEED_KMH .. " km/h (shows unknown speed)")
print("  Heartbeat: t=1 with null coords every " .. HEARTBEAT_INTERVAL .. "s")
sleep(1.0)

parallel.waitForAll(
    rdrGpuUI,
    hudMonitorUI,
    termUI,
    inputLoop,
    heartbeatLoop,
    listenLoop,
    cameraLoop,
    speedTimerLoop,
    iffToggleLoop
)
