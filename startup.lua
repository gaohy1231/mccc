--[[ 综合探测系统 v4.0 (原版雷达 + 主动声纳)
     雷达部分完全保留原始逻辑，声纳部分为改进版主动声纳
     四页终端 UI：雷达参数 / 声纳参数 / 状态 / 设备
     配置文件: integrated_config.txt
======================================================================]]

-- ==========================================
-- 全局常量
-- ==========================================
local SUBSYSTEM_RADAR = 1
local SUBSYSTEM_SONAR = 2

-- ==========================================
-- 配置文件管理（整合雷达/声纳独立配置）
-- ==========================================
local CONFIG_FILE = "integrated_config.txt"

local config = {
    -- 雷达配置完全沿用原始雷达的参数
    radar = {
        modem_name       = "",
        camera_name      = "",
        servo_name       = "",
        stressometer_name= "",
        gpu_names        = {},
        hud_names        = {},
        yawOffset        = 0,
        motorOffset      = 0,
        aimPrecision     = 5,
        broadcastPos     = "yes",
        maxDistance      = 3700,
        stressRatio      = 4.0,
        channel          = 8888,
        scanWidth        = 20,
    },
    -- 声纳配置沿用声纳改进的参数
    sonar = {
        modem_name       = "",
        camera_name      = "",
        stressometer_name= "",
        gpu_names        = {},
        hud_names        = {},
        yawOffset        = 0,
        headingOffset    = 0,   -- 摄像头航向修正
        sonarCenterOffset= 0,
        aimPrecision     = 5,
        broadcastPos     = "yes",
        minDistance      = 100,
        maxDistance      = 600,
        stressThreshold  = 10000,
        channel_send     = 8889,
        channel_listen   = 8890,
        scanWidth        = 20,
        seaLevel         = -4,
        scanSpeed        = 30,
    },
    currentTab       = 1,
    menuIndex        = 1,
    isEditing        = false,
    inputStr         = "",
}

local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            for k, v in pairs(data) do
                if type(v) == "table" and config[k] then
                    for k2, v2 in pairs(v) do config[k][k2] = v2 end
                else
                    config[k] = v
                end
            end
        end
    end
end
loadConfig()

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serialize(config))
    f.close()
end

-- ==========================================
-- 基础工具 (完全沿用原始雷达的工具函数)
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

local function tableSize(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end

local function getAngleDiff(a, b)
    local diff = (a - b) % 360
    if diff > 180 then diff = diff - 360
    elseif diff < -180 then diff = diff + 360 end
    return diff
end

local function isInSector(angle, centerDeg, halfWidth)
    return math_abs(getAngleDiff(angle, centerDeg)) <= halfWidth
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

local function calculateLookAngles(sx, sy, sz, tx, ty, tz)
    local dx, dy, dz = tx - sx, ty - sy, tz - sz
    local distH = math_sqrt(dx*dx + dz*dz)
    return math_deg(math_atan2(-dy, distH)), math_deg(math_atan2(-dx, dz))
end

-- 颜色工具（原始雷达的）
local function colorUnpack(c) return math_floor(c/0x10000)%0x100, math_floor(c/0x100)%0x100, c%0x100 end
local function colorPack(r,g,b) return math_floor(r)*0x10000 + math_floor(g)*0x100 + math_floor(b) end
local function colorLerp(ca, cb, t)
    t = math_max(0, math_min(1, t))
    local ar,ag,ab = colorUnpack(ca); local br,bg,bb = colorUnpack(cb)
    return colorPack(ar+(br-ar)*t, ag+(bg-ag)*t, ab+(bb-ab)*t)
end
local TARGET_FADE_DURATION = 3.0; local TARGET_HOT_DURATION = 1.0
local function calcFadeColor(age, hotColor)
    if age >= TARGET_FADE_DURATION then return nil end
    if age <= TARGET_HOT_DURATION then return hotColor end
    local t = (age - TARGET_HOT_DURATION) / (TARGET_FADE_DURATION - TARGET_HOT_DURATION)
    return colorLerp(hotColor, 0x000000, t)
end

-- ==========================================
-- 外设查找
-- ==========================================
local allPeripherals = {}
for _, name in ipairs(peripheral.getNames()) do
    allPeripherals[name] = peripheral.getType(name)
end

local function findByNameOrDefault(name, ptype)
    if name ~= "" and allPeripherals[name] == ptype then
        return peripheral.wrap(name), name
    end
    for n, t in pairs(allPeripherals) do
        if t == ptype then
            return peripheral.wrap(n), n
        end
    end
    return nil, nil
end

-- ==========================================
-- 子系统状态结构（雷达状态完全保留原始变量）
-- ==========================================
local subsystems = {
    [SUBSYSTEM_RADAR] = {
        id=SUBSYSTEM_RADAR, name="RADAR",
        targets={}, localPos=nil,
        trackedTargetId=nil, isTargetInRange=false,
        holdPitch=nil, holdYaw=nil,
        selectedTargetId=nil, selectedTargetDistStr=nil,
        currentQAbs=nil, currentQLoc=nil,
        currentServoAngle=0, isServoConnected=false,
        yawOffset=0, motorOffset=0,
        myLabel=nil,
        monitorModes={},
        aimPrecision=5,
        currentStressCapacity=0, currentRadarRange=0,
        currentNorthYawDeg=0,
        currentScreenTab=1, menuIndex=1, isEditing=false, inputStr="",
        cachedStressometer=nil, cachedServo=nil,
        targetPool={}, targetPoolCount=0,
        iffMode="enemy",
        rwrEvents={},
        modem=nil, camera=nil, servo=nil, stressometer=nil,
        gpuList={}, hudList={},
    },
    [SUBSYSTEM_SONAR] = {
        id=SUBSYSTEM_SONAR, name="SONAR",
        targets={}, localPos=nil,
        currentQAbs=nil, currentQLoc=nil,
        currentStressCapacity=0, currentRadarRange=0,
        currentNorthYawDeg=0, sonarScanAngle=0,
        selectedTargetId=nil, selectedTargetDistStr=nil, selectedTargetDepth=nil,
        trackedTargetId=nil, holdPitch=nil, holdYaw=nil, isTargetInRange=false,
        targetPool={}, targetPoolCount=0,
        modem=nil, camera=nil, stressometer=nil,
        gpuList={}, hudList={},
    }
}

-- ==========================================
-- 外设绑定 (雷达部分严格参照原始雷达)
-- ==========================================
local r = subsystems[SUBSYSTEM_RADAR]
-- 雷达 modem
r.modem, _ = findByNameOrDefault(config.radar.modem_name, "modem")
if r.modem then r.modem.open(config.radar.channel) else error("Radar modem not found!", 0) end
-- 雷达 camera
r.camera, _ = findByNameOrDefault(config.radar.camera_name, "camera")
if not r.camera then error("Radar camera not found!", 0) end
-- 雷达 servo / stressometer
r.servo, _ = findByNameOrDefault(config.radar.servo_name, "servo")
r.stressometer, _ = findByNameOrDefault(config.radar.stressometer_name, "Create_Stressometer")
r.cachedStressometer = r.stressometer
r.cachedServo = r.servo
r.myLabel = os.getComputerLabel() or ("Entity-" .. os.getComputerID())

-- 雷达GPU
for _, gname in ipairs(config.radar.gpu_names) do
    if allPeripherals[gname] == "tm_gpu" then
        local g = peripheral.wrap(gname)
        pcall(g.refreshSize); pcall(g.setSize, 64); pcall(g.fill, 0x050A05)
        local ok, w, h = pcall(g.getSize)
        if not ok then w, h = 256, 128 end
        local cx, cy = math_floor(w/2), math_floor(h/2)
        local radius = math_floor(math_min(cx,cy)*0.88)
        local bw = math_max(1, math_floor(w/85))
        local bh = math_max(1, math_floor(h/64))
        local dotSize = (radius>=110) and 4 or (radius>=80) and 3 or (radius>=50) and 2 or 1
        if bw>=3 and bh>=3 then dotSize = dotSize+1 end
        dotSize = math_max(2, dotSize)
        table.insert(r.gpuList, {gpu=g, name=gname, w=w, h=h, cx=cx, cy=cy, r=radius, bw=bw, bh=bh, dotSize=dotSize, lastSweepDeg=-999})
    end
end
-- 雷达HUD
for _, hname in ipairs(config.radar.hud_names) do
    if allPeripherals[hname] == "monitor" then
        local m = peripheral.wrap(hname)
        m.setTextScale(1)
        local cw, ch = m.getSize()
        table.insert(r.hudList, {mon=m, name=hname, w=cw, h=ch, lastLine1=nil, lastLine2=nil, lastLine3=nil, lastIff=nil})
    end
end

-- 声纳
local s = subsystems[SUBSYSTEM_SONAR]
s.modem, _ = findByNameOrDefault(config.sonar.modem_name, "modem")
if s.modem then
    s.modem.open(config.sonar.channel_send)
    s.modem.open(config.sonar.channel_listen)
else
    error("Sonar modem not found!", 0)
end
s.camera, _ = findByNameOrDefault(config.sonar.camera_name, "camera")
if not s.camera then error("Sonar camera not found!", 0) end
s.stressometer, _ = findByNameOrDefault(config.sonar.stressometer_name, "Create_Stressometer")

-- 声纳GPU
for _, gname in ipairs(config.sonar.gpu_names) do
    if allPeripherals[gname] == "tm_gpu" then
        local g = peripheral.wrap(gname)
        pcall(g.refreshSize); pcall(g.setSize, 64); pcall(g.fill, 0x050A05)
        local ok, w, h = pcall(g.getSize)
        if not ok then w, h = 256, 128 end
        local cx, cy = math_floor(w/2), math_floor(h/2)
        local radius = math_floor(math_min(cx,cy)*0.88)
        local bw = math_max(1, math_floor(w/85))
        local bh = math_max(1, math_floor(h/64))
        local dotSize = (radius>=110) and 4 or (radius>=80) and 3 or (radius>=50) and 2 or 1
        if bw>=3 and bh>=3 then dotSize = dotSize+1 end
        dotSize = math_max(2, dotSize)
        table.insert(s.gpuList, {gpu=g, name=gname, w=w, h=h, cx=cx, cy=cy, r=radius, bw=bw, bh=bh, dotSize=dotSize, lastSweepDeg=-999})
    end
end
-- 声纳HUD
for _, hname in ipairs(config.sonar.hud_names) do
    if allPeripherals[hname] == "monitor" then
        local m = peripheral.wrap(hname)
        m.setTextScale(1)
        local cw, ch = m.getSize()
        table.insert(s.hudList, {mon=m, name=hname, w=cw, h=ch, lastLine1=nil, lastLine2=nil, lastLine3=nil})
    end
end

-- ==========================================
-- 颜色常量（雷达用原始RC，声纳用SC）
-- ==========================================
local RC = {
    BG=0x050A05, OUTER_RING=0x00CC44, INNER_RING=0x007722, GRID=0x005518,
    SWEEP=0x00FF66, YELLOW=0xFFFF00, ALLY_HOT=0x44FFAA, FOE_HOT=0xFF6600,
    UNK_HOT=0xEEEEEE, CORNER_FOE=0x660000, CORNER_ALLY=0x004400,
    BLACK=0, WHITE=0xFFFFFF, RWR_HOT=0xFFCC00,
}
local SC = {
    BG=0x050A05, OUTER_RING=0x44FF44, INNER_RING=0x005500, GRID=0x003300,
    SWEEP=0x00FF66, YELLOW=0xFFFF00, UNK_HOT=0xEEEEEE, BLACK=0, WHITE=0xFFFFFF,
}

-- ==========================================
-- 绘图底层函数
-- ==========================================
local function gpuFillRect(g, x, y, w, h, col)
    for dy=0,h-1 do g.line(x, y+dy, x+w-1, y+dy, col) end
end
local function gpuDrawCircle(g, cx, cy, r, col)
    local x, y, d = r, 0, 1-r
    while x >= y do
        for _, dx in ipairs({x, -x}) do for _, dy in ipairs({y, -y}) do
            g.line(cx+dx, cy+dy, cx+dx, cy+dy, col)
            g.line(cx+dy, cy+dx, cx+dy, cy+dx, col)
        end end
        y = y+1
        if d<0 then d = d+2*y+1 else x=x-1; d=d+2*(y-x)+1 end
    end
end
local function gpuDrawArc(g, cx, cy, r, startRad, endRad, col)
    local step = math_rad(0.5)
    for a=startRad, endRad, step do
        local px = cx + math_floor(r * math_cos(a) + 0.5)
        local py = cy - math_floor(r * math_sin(a) + 0.5)
        g.line(px, py, px, py, col)
    end
end

-- ==========================================
-- 雷达 GPU 绘制全套 (完全复制原始雷达代码)
-- ==========================================
local function gpuDrawRadarBase(entry, sub)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    g.fill(RC.BG)
    gpuDrawCircle(g,cx,cy,r,RC.OUTER_RING)
    gpuDrawCircle(g,cx,cy,math_floor(r/2),RC.INNER_RING)
    g.line(cx,cy-r,cx,cy+r,RC.GRID); g.line(cx-r,cy,cx+r,cy,RC.GRID)
    for t=-r,r do
        if t%4<2 then
            local py=cy+t
            local px1=cx+t
            if (px1-cx)^2+(py-cy)^2<=r*r then g.line(px1,py,px1,py,RC.GRID) end
            local px2=cx-t
            if (px2-cx)^2+(py-cy)^2<=r*r then g.line(px2,py,px2,py,RC.GRID) end
        end
    end
    local northRad=math_rad(sub.currentNorthYawDeg+config.radar.yawOffset)
    local circPx=cx+math_floor(r*math_sin(northRad)+0.5)
    local circPy=cy-math_floor(r*math_cos(northRad)+0.5)
    local tX=math_max(1,math_min(entry.w-6,circPx-3))
    local tY=math_max(1,math_min(entry.h-8,circPy-4))
    pcall(g.drawText,tX,tY,"N",RC.YELLOW,RC.BG,1)
end

local function gpuDrawSweepRadar(entry, sub)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    local rad=math_rad(sub.currentServoAngle+config.radar.yawOffset)
    local ex=cx+math_floor(r*math_sin(rad)+0.5)
    local ey=cy-math_floor(r*math_cos(rad)+0.5)
    g.line(cx,cy,ex,ey,RC.SWEEP)
end

local function gpuDrawRwrArcs(entry, sub)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy; local r=entry.r
    local now=os_clock()
    local ARC_R_INNER=r+3; local ARC_R_OUTER=r+5
    for i=#sub.rwrEvents,1,-1 do
        if now-sub.rwrEvents[i].time>=1.0 then table.remove(sub.rwrEvents,i) end
    end
    for _,ev in ipairs(sub.rwrEvents) do
        local age=now-ev.time
        local col=colorLerp(RC.RWR_HOT,RC.BG,age/1.0)
        if col~=RC.BG then
            local centerRad=math_rad(ev.yawDeg+config.radar.yawOffset)
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

local function gpuDrawIffCorners(entry, sub)
    local g=entry.gpu; local W=entry.w; local H=entry.h
    local col=(sub.iffMode=="friendly") and RC.CORNER_ALLY or RC.CORNER_FOE
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

local function gpuRefreshRadar(entry, isActive, poolCount, pool, sub)
    local g=entry.gpu; local cx=entry.cx; local cy=entry.cy
    local r=entry.r; local ds=entry.dotSize; local half=math_floor(ds/2)
    gpuDrawRadarBase(entry, sub)
    gpuDrawRwrArcs(entry, sub)
    if isActive and sub.localPos then
        for i=1, poolCount do
            local t=pool[i]
            if t.col and t.col~=RC.BLACK then
                local dr=r*t.r
                local px=cx+math_floor(dr*t.s+0.5)
                local py=cy-math_floor(dr*t.cs+0.5)
                if (px-cx)^2+(py-cy)^2<=r*r then
                    if t.isBeacon then
                        -- 三角形信标（原始雷达使用小十字）
                        g.line(px, py-1, px, py-1, t.col)
                        g.line(px-1, py, px+1, py, t.col)
                    else
                        gpuFillRect(g, px-half, py-half, ds, ds, t.col)
                    end
                end
            end
        end
    end
    if isActive then gpuDrawSweepRadar(entry, sub) end
    gpuDrawIffCorners(entry, sub)
    g.sync()
end

-- ==========================================
-- 声纳 GPU 绘制（新扇形、虚线刻度、软件扫描）
-- ==========================================
local function drawSonarBase(entry, sub)
    local g = entry.gpu; local cx, cy, r = entry.cx, entry.cy, entry.r
    g.fill(SC.BG)
    local startRad, endRad = 0, math_rad(180)
    gpuDrawArc(g, cx, cy, r, startRad, endRad, SC.OUTER_RING)
    gpuDrawArc(g, cx, cy, math_floor(r/2), startRad, endRad, SC.INNER_RING)

    local sx1 = cx + math_floor(r * math_cos(startRad) + 0.5)
    local sy1 = cy - math_floor(r * math_sin(startRad) + 0.5)
    g.line(cx, cy, sx1, sy1, SC.GRID)
    local sx2 = cx + math_floor(r * math_cos(endRad) + 0.5)
    local sy2 = cy - math_floor(r * math_sin(endRad) + 0.5)
    g.line(cx, cy, sx2, sy2, SC.GRID)

    local centerRad = math_rad(90)
    local cx1 = cx + math_floor(r * math_cos(centerRad) + 0.5)
    local cy1 = cy - math_floor(r * math_sin(centerRad) + 0.5)
    g.line(cx, cy, cx1, cy1, SC.GRID)

    for deg = 45, 135, 45 do
        local angleRad = math_rad(deg)
        local innerX = cx + math_floor((r/2) * math_cos(angleRad) + 0.5)
        local innerY = cy - math_floor((r/2) * math_sin(angleRad) + 0.5)
        local outerX = cx + math_floor(r * math_cos(angleRad) + 0.5)
        local outerY = cy - math_floor(r * math_sin(angleRad) + 0.5)
        local steps = math_floor((r - r/2) / 3)
        for i = 0, steps do
            if i % 2 == 0 then
                local t = i / steps
                local px = math_floor(innerX + (outerX - innerX) * t + 0.5)
                local py = math_floor(innerY + (outerY - innerY) * t + 0.5)
                g.line(px, py, px, py, SC.GRID)
            end
        end
    end

    local northRad = math_rad(sub.currentNorthYawDeg + config.sonar.yawOffset)
    local norm = ((northRad % (2*math.pi)) + 2*math.pi) % (2*math.pi)
    if norm >= 0 and norm <= math.pi then
        local nx = cx + math_floor((r+2) * math_cos(norm) + 0.5)
        local ny = cy - math_floor((r+2) * math_sin(norm) + 0.5)
        pcall(g.drawText, math_max(1, math_min(entry.w-6, nx-3)),
                           math_max(1, math_min(entry.h-8, ny-4)), "N", SC.YELLOW, SC.BG, 1)
    end
end

local function drawSonarSweep(entry, sub)
    local g = entry.gpu; local cx, cy, r = entry.cx, entry.cy, entry.r
    local scanAngle = sub.sonarScanAngle + config.sonar.yawOffset
    local rad = math_rad(scanAngle)
    local norm = ((rad % (2*math.pi)) + 2*math.pi) % (2*math.pi)
    if norm >= 0 and norm <= math.pi then
        g.line(cx, cy, cx+math_floor(r*math_sin(rad)+0.5), cy-math_floor(r*math_cos(rad)+0.5), SC.SWEEP)
    end
end

local function refreshSonarGPU(entry, sub, pool, count)
    local g = entry.gpu; local cx, cy, r = entry.cx, entry.cy, entry.r
    drawSonarBase(entry, sub)
    local ds, half = entry.dotSize, math_floor(entry.dotSize/2)
    for i = 1, count do
        local t = pool[i]
        if t.col and t.col ~= 0 then
            local dr = r * t.r
            local px = cx + math_floor(dr * t.s + 0.5)
            local py = cy - math_floor(dr * t.cs + 0.5)
            if (px-cx)^2 + (py-cy)^2 <= r*r then
                if t.isBeacon then
                    g.line(px, py-1, px, py-1, t.col)
                    g.line(px-1, py, px+1, py, t.col)
                else
                    gpuFillRect(g, px-half, py-half, ds, ds, t.col)
                end
            end
        end
    end
    drawSonarSweep(entry, sub)
    g.sync()
end

-- ==========================================
-- 雷达 HUD (完全复制原始雷达 HUD 逻辑)
-- ==========================================
local function hudRadar(sub)
    while true do
        local isActive = (sub.currentRadarRange > 0) and sub.isServoConnected
        for _, info in ipairs(sub.hudList) do
            local sText, sColor, rText, rColor, lText, lColor, dText, dColor
            if not isActive then
                sText="OFFLINE"; sColor=colors.red
                rText="---";     rColor=colors.gray
                lText="---";     lColor=colors.gray
                dText="---";     dColor=colors.gray
            else
                sText="ACTIVE"; sColor=colors.green
                rText=string.format("%dm",math_floor(sub.currentRadarRange))
                rColor=colors.lime
                if sub.selectedTargetId and sub.targets[sub.selectedTargetId] then
                    local sel=sub.targets[sub.selectedTargetId]
                    if sel.iff=="friendly" then
                        lText="ALLY"; lColor=colors.green
                        dText=sub.selectedTargetDistStr or "---"; dColor=colors.green
                    elseif sel.iff=="enemy" then
                        lText="ENEMY"; lColor=colors.red
                        dText=sub.selectedTargetDistStr or "---"; dColor=colors.white
                    else
                        lText="LOCKED"; lColor=colors.yellow
                        dText=sub.selectedTargetDistStr or "---"; dColor=colors.white
                    end
                else
                    lText="SCAN"; lColor=colors.lightGray
                    dText="---";  dColor=colors.gray
                end
            end
            info.mon.setBackgroundColor(colors.black); info.mon.clear()
            local dw,dh=info.w, info.h
            local y1=math_max(1,math_floor(dh/2)-3)
            local y2=math_max(2,math_floor(dh/2)-1)
            local y3=math_max(3,math_floor(dh/2)+1)
            local y4=math_max(4,math_floor(dh/2)+3)
            local function drawCL(txt,col,yPos)
                info.mon.setTextColor(col)
                local sx=math_max(1,math_floor((dw-#txt)/2)+1)
                info.mon.setCursorPos(sx,yPos); info.mon.write(txt)
            end
            drawCL(sText,sColor,y1); drawCL(rText,rColor,y2)
            drawCL(lText,lColor,y3); drawCL(dText,dColor,y4)
        end
        sleep(0.2)
    end
end

-- 声纳 HUD (简洁三行)
local function hudSonar(sub)
    while true do
        local isActive = sub.currentRadarRange > 0
        for _, info in ipairs(sub.hudList) do
            local l1, c1, l2, c2, l3, c3
            if not isActive then
                l1, c1 = "ASDIC offline", colors.red
            else
                l1, c1 = "ASDIC online", colors.green
            end
            l2, c2 = "100 - 600 m", colors.lime
            if sub.selectedTargetId and sub.targets[sub.selectedTargetId] then
                local t = sub.targets[sub.selectedTargetId]
                local depth = config.sonar.seaLevel - (t.realPos and t.realPos.y or 0)
                l3 = string.format("D:%d m / R:%s", math_floor(depth), sub.selectedTargetDistStr or "---")
                c3 = colors.white
            else
                l3, c3 = "D:- - / R:- -", colors.gray
            end
            info.mon.setBackgroundColor(colors.black); info.mon.clear()
            local dw, dh = info.w, info.h
            local function drawCL(txt, col, y)
                info.mon.setTextColor(col)
                info.mon.setCursorPos(math_max(1, math_floor((dw-#txt)/2)+1), y)
                info.mon.write(txt)
            end
            drawCL(l1, c1, math_floor(dh/2)-1)
            drawCL(l2, c2, math_floor(dh/2)+1)
            drawCL(l3, c3, math_floor(dh/2)+3)
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 目标池构建（雷达用原始逻辑，声纳用扇形过滤）
-- ==========================================
local function buildRadarPool(sub)
    local pool, count = {}, 0
    local now = os_clock()
    if sub.localPos and sub.currentRadarRange > 0 and sub.isServoConnected then
        for _, data in pairs(sub.targets) do
            if data.lastPainted and not data.isBeacon then
                local age = now - data.lastPainted
                if age < TARGET_FADE_DURATION then
                    local hotColor
                    if data.iff=="friendly" then hotColor=RC.ALLY_HOT
                    elseif data.iff=="enemy" then hotColor=RC.FOE_HOT
                    else hotColor=RC.UNK_HOT end
                    local col = calcFadeColor(age, hotColor)
                    if col then
                        local yawRad = math_rad(data.paintedYaw + config.radar.yawOffset)
                        local distRatio = math_min(data.paintedDist / sub.currentRadarRange, 1.0)
                        count = count + 1
                        pool[count] = {col=col, r=distRatio, s=math_sin(yawRad), cs=math_cos(yawRad), isBeacon=false}
                    end
                end
            elseif data.isBeacon and data.lastSeen and (now-data.lastSeen < 5.0) then
                local col = data.iff=="friendly" and RC.ALLY_HOT or RC.YELLOW
                local yaw = (sub.localPos and data.realPos) and select(2, calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, data.realPos.x,data.realPos.y,data.realPos.z)) or 0
                local dist = data.realDist or 0
                local ratio = math_min(dist / sub.currentRadarRange, 1.0)
                local yawRad = math_rad(yaw + config.radar.yawOffset)
                count = count + 1
                pool[count] = {col=col, r=ratio, s=math_sin(yawRad), cs=math_cos(yawRad), isBeacon=true}
            end
        end
    end
    return pool, count
end

local function buildSonarPool(sub)
    local pool, count = {}, 0
    local now = os_clock()
    local center = sub.currentNorthYawDeg + config.sonar.yawOffset + config.sonar.sonarCenterOffset
    if sub.localPos and sub.currentRadarRange > 0 then
        for _, data in pairs(sub.targets) do
            if data.lastPainted and not data.isBeacon then
                local age = now - data.lastPainted
                if age < TARGET_FADE_DURATION then
                    local col = calcFadeColor(age, SC.UNK_HOT)
                    if col and isInSector(data.paintedYaw, center, 90) then
                        local yawRad = math_rad(data.paintedYaw + config.sonar.yawOffset)
                        local ratio = math_min(data.paintedDist / config.sonar.maxDistance, 1.0)
                        count = count + 1
                        pool[count] = {col=col, r=ratio, s=math_sin(yawRad), cs=math_cos(yawRad), isBeacon=false}
                    end
                end
            elseif data.isBeacon and data.lastSeen and (now-data.lastSeen < 5.0) then
                local yaw = (sub.localPos and data.realPos) and select(2, calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, data.realPos.x,data.realPos.y,data.realPos.z)) or 0
                if isInSector(yaw, center, 90) then
                    local dist = data.realDist or 0
                    local ratio = math_min(dist / config.sonar.maxDistance, 1.0)
                    local yawRad = math_rad(yaw + config.sonar.yawOffset)
                    count = count + 1
                    pool[count] = {col=SC.YELLOW, r=ratio, s=math_sin(yawRad), cs=math_cos(yawRad), isBeacon=true}
                end
            end
        end
    end
    return pool, count
end

-- ==========================================
-- GPU 主循环
-- ==========================================
local function gpuRadarLoop(sub)
    if #sub.gpuList == 0 then return end
    while true do
        local pool, count = buildRadarPool(sub)
        for _, entry in ipairs(sub.gpuList) do
            pcall(gpuRefreshRadar, entry, (sub.currentRadarRange>0 and sub.isServoConnected), count, pool, sub)
        end
        sleep(0.05)
    end
end

local function gpuSonarLoop(sub)
    if #sub.gpuList == 0 then return end
    while true do
        local pool, count = buildSonarPool(sub)
        for _, entry in ipairs(sub.gpuList) do
            pcall(refreshSonarGPU, entry, sub, pool, count)
        end
        sleep(0.05)
    end
end

-- ==========================================
-- 网络循环 (雷达和声纳各自独立)
-- ==========================================
-- 雷达 ping (原始雷达逻辑)
local function radarPing(sub)
    while true do
        if sub.localPos and config.radar.broadcastPos == "yes" then
            sub.modem.transmit(config.radar.channel, config.radar.channel, {
                v=2, t=1, i=os.getComputerID(), n=sub.myLabel,
                x=math_floor(sub.localPos.x*10)/10,
                y=math_floor(sub.localPos.y*10)/10,
                z=math_floor(sub.localPos.z*10)/10,
                r=sub.currentRadarRange,
            })
        end
        local now = os_clock()
        for id, data in pairs(sub.targets) do
            if not data.isBeacon and id~=sub.selectedTargetId and data.lastSeen and (now-data.lastSeen>10) then
                sub.targets[id] = nil
            end
            if data.isBeacon and data.lastSeen and (now-data.lastSeen>10) then
                sub.targets[id] = nil
            end
        end
        sleep(1.0)
    end
end

-- 雷达监听 (完全复制原始雷达监听，包含 RWR 和 IFF 红石切换)
local function radarListen(sub)
    while true do
        local _,_,ch,_,msg,dist = os_pullEvent("modem_message")
        if ch == config.radar.channel and type(msg)=="table" and msg.v==2 then
            local myId = os.getComputerID()
            if msg.t==1 and msg.i~=myId then
                if not sub.targets[msg.i] then sub.targets[msg.i] = {} end
                local t = sub.targets[msg.i]
                t.name=msg.n; t.modemDist=dist
                t.realPos={x=msg.x,y=msg.y,z=msg.z}
                t.range=msg.r; t.lastSeen=os_clock(); t.isBeacon=false
                local cd = calcRangingDist(sub.localPos, t.realPos)
                t.realDist = cd or dist
            elseif msg.t==2 and msg.ti==myId then
                local isFriendly = msg.si and sub.targets[msg.si] and sub.targets[msg.si].iff=="friendly"
                if not isFriendly then
                    local rwrYaw = nil
                    if msg.si and sub.targets[msg.si] and sub.targets[msg.si].realPos and sub.localPos then
                        local sp = sub.targets[msg.si].realPos
                        if sub.currentQAbs and sub.currentQLoc then
                            local iqx,iqy,iqz,iqw = quatInverse(sub.currentQAbs.x,sub.currentQAbs.y,sub.currentQAbs.z,sub.currentQAbs.w)
                            local dx=sp.x-sub.localPos.x
                            local dy=sp.y-sub.localPos.y
                            local dz=sp.z-sub.localPos.z
                            local hx,hy,hz=rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                            local sx,sy,sz=rotateVectorFast(hx,hy,hz, sub.currentQLoc.x,sub.currentQLoc.y,sub.currentQLoc.z,sub.currentQLoc.w)
                            rwrYaw = math_deg(math_atan2(-sx,sz))
                        else
                            _,rwrYaw = calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, sp.x,sp.y,sp.z)
                        end
                    end
                    if rwrYaw then
                        local normYaw=rwrYaw%360
                        local sectorIdx=math_floor((normYaw+22.5)/45)%8
                        local quantYaw=sectorIdx*45
                        if quantYaw>180 then quantYaw=quantYaw-360 end
                        table.insert(sub.rwrEvents,{yawDeg=quantYaw,time=os_clock()})
                    end
                    os_queueEvent("rwr_detected")
                end
            elseif msg.t==3 then
                local beaconId=msg.i
                local beaconUid=tostring(msg.uid or "0000")
                local key=tostring(beaconId).."_"..beaconUid
                if not sub.targets[key] then sub.targets[key] = {} end
                local t = sub.targets[key]
                t.name=tostring(msg.n or ("Beacon-"..beaconId))
                t.modemDist=dist
                t.realPos={x=msg.x,y=msg.y,z=msg.z}
                t.lastSeen=os_clock(); t.isBeacon=true
                t.beaconId=beaconId; t.beaconUid=beaconUid
                local cd=calcRangingDist(sub.localPos,t.realPos)
                t.realDist=cd or dist
            end
        end
    end
end

-- 声纳 ping (使用 channel_send)
local function sonarPing(sub)
    while true do
        if sub.localPos and config.sonar.broadcastPos == "yes" then
            sub.modem.transmit(config.sonar.channel_send, config.sonar.channel_send, {
                v=2, t=1, i=os.getComputerID(), n=os.getComputerLabel() or ("S-"..os.getComputerID()),
                x=math_floor(sub.localPos.x*10)/10, y=math_floor(sub.localPos.y*10)/10,
                z=math_floor(sub.localPos.z*10)/10, r=sub.currentRadarRange,
            })
        end
        local now = os_clock()
        for id, data in pairs(sub.targets) do
            if not data.isBeacon and id~=sub.selectedTargetId and data.lastSeen and (now-data.lastSeen>10) then
                sub.targets[id] = nil
            end
            if data.isBeacon and data.lastSeen and (now-data.lastSeen>10) then
                sub.targets[id] = nil
            end
        end
        sleep(1.0)
    end
end

-- 声纳监听 (只收 channel_listen, 无RWR)
local function sonarListen(sub)
    while true do
        local _,_,ch,_,msg,dist = os_pullEvent("modem_message")
        if ch == config.sonar.channel_listen and type(msg)=="table" and msg.v==2 then
            local myId = os.getComputerID()
            if (msg.t==1 or msg.t==3) and msg.i~=myId then
                if msg.y and msg.y > config.sonar.seaLevel then goto continue end
                if msg.t==1 then
                    if not sub.targets[msg.i] then sub.targets[msg.i] = {} end
                    local t = sub.targets[msg.i]
                    t.name = msg.n; t.modemDist = dist
                    t.realPos = {x=msg.x, y=msg.y, z=msg.z}; t.range = msg.r
                    t.lastSeen = os_clock(); t.isBeacon = false
                    if sub.localPos then t.realDist = calcRangingDist(sub.localPos, t.realPos) or dist end
                else
                    local key = tostring(msg.i).."_"..tostring(msg.uid or "0000")
                    if not sub.targets[key] then sub.targets[key] = {} end
                    local t = sub.targets[key]
                    t.name = msg.n or ("Beacon-"..msg.i); t.modemDist = dist
                    t.realPos = {x=msg.x, y=msg.y, z=msg.z}; t.lastSeen = os_clock(); t.isBeacon = true
                    if sub.localPos then t.realDist = calcRangingDist(sub.localPos, t.realPos) or dist end
                end
            end
        end
        ::continue::
    end
end

-- 雷达 RWR 红石输出
local function radarRWRReset()
    while true do
        local _, p1 = os_pullEvent("timer")
        if p1 == 0.5 then redstone.setOutput("front", false) end
    end
end

-- 雷达 IFF 切换 (背面红石)
local function iffToggleLoop(sub)
    local lastBack = redstone.getInput("back")
    while true do
        os_pullEvent("redstone")
        local newBack = redstone.getInput("back")
        if newBack and not lastBack then
            sub.iffMode = (sub.iffMode=="enemy") and "friendly" or "enemy"
        end
        lastBack = newBack
    end
end

-- ==========================================
-- 雷达摄像头循环 (完全复制原始雷达逻辑)
-- ==========================================
local function radarCameraLoop(sub)
    local lastServoAngle=nil; local peripheralPollTick=0
    while true do
        if peripheralPollTick<=0 then
            peripheralPollTick=20
            if not sub.cachedStressometer then sub.cachedStressometer=peripheral.find("Create_Stressometer") end
            if not sub.cachedServo then sub.cachedServo=peripheral.find("servo") end
        else peripheralPollTick=peripheralPollTick-1 end

        if sub.cachedStressometer then
            local ok,cap=pcall(sub.cachedStressometer.getStressCapacity)
            if ok then sub.currentStressCapacity=cap or 0
            else sub.cachedStressometer=nil; sub.currentStressCapacity=0 end
        end

        local deltaAngle=0
        if sub.cachedServo then
            local ok,ang=pcall(sub.cachedServo.getAngle)
            if ok and type(ang)=="number" then
                sub.isServoConnected=true
                sub.currentServoAngle=(math_deg(ang)+config.radar.motorOffset)%360
                if lastServoAngle then
                    deltaAngle=math_abs(getAngleDiff(sub.currentServoAngle,lastServoAngle))
                    if deltaAngle>180 then deltaAngle=0 end
                end
                lastServoAngle=sub.currentServoAngle
            else sub.isServoConnected=false; sub.cachedServo=nil end
        else sub.isServoConnected=false end

        local safeRatio=math_max(config.radar.stressRatio,0.001)
        sub.currentRadarRange=math_min(sub.currentStressCapacity/safeRatio, config.radar.maxDistance)

        if sub.camera then
            local ok,pos=pcall(sub.camera.getCameraPosition)
            if ok and pos then sub.localPos=pos else sub.localPos=nil end
            pcall(function()
                sub.currentQAbs=sub.camera.getAbsViewTransform()
                sub.currentQLoc=sub.camera.getLocViewTransform()
            end)
            if sub.currentQAbs and sub.currentQLoc then
                local iqx,iqy,iqz,iqw=quatInverse(sub.currentQAbs.x,sub.currentQAbs.y,sub.currentQAbs.z,sub.currentQAbs.w)
                local hx,hy,hz=rotateVectorFast(0,0,-1,iqx,iqy,iqz,iqw)
                local sx,sy,sz=rotateVectorFast(hx,hy,hz, sub.currentQLoc.x,sub.currentQLoc.y,sub.currentQLoc.z,sub.currentQLoc.w)
                sub.currentNorthYawDeg = (math_deg(math_atan2(-sx,sz)) + config.radar.headingOffset) % 360
            end
            -- 以下为原始雷达的扫描逻辑，保持不变
            local now=os_clock(); local refPos=sub.localPos
            if sub.currentRadarRange>0 and sub.isServoConnected then
                local effectiveSW=config.radar.scanWidth+deltaAngle
                if refPos then
                    for _,data in pairs(sub.targets) do
                        if data.realPos and not data.isBeacon then
                            local cd=calcRangingDist(refPos,data.realPos)
                            if cd then data.realDist=cd end
                        end
                    end
                end
                for id,data in pairs(sub.targets) do
                    if data.isBeacon then goto continue end
                    data.isBeingScanned=false
                    if data.realPos and data.realDist and data.realDist<=sub.currentRadarRange and (now-data.lastSeen<3.0) then
                        local tYaw=0
                        if sub.currentQAbs and sub.currentQLoc and refPos then
                            local iqx,iqy,iqz,iqw=quatInverse(sub.currentQAbs.x,sub.currentQAbs.y,sub.currentQAbs.z,sub.currentQAbs.w)
                            local dx=data.realPos.x-refPos.x
                            local dy=data.realPos.y-refPos.y
                            local dz=data.realPos.z-refPos.z
                            local hx,hy,hz=rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                            local sx,sy,sz=rotateVectorFast(hx,hy,hz, sub.currentQLoc.x,sub.currentQLoc.y,sub.currentQLoc.z,sub.currentQLoc.w)
                            tYaw=math_deg(math_atan2(-sx,sz))
                        elseif refPos then
                            _,tYaw=calculateLookAngles(refPos.x,refPos.y,refPos.z, data.realPos.x,data.realPos.y,data.realPos.z)
                        end
                        if math_abs(getAngleDiff(tYaw,sub.currentServoAngle))<=effectiveSW/2 then
                            data.isBeingScanned=true
                            if not data.lastPainted or (now-data.lastPainted>=1.0) then
                                data.paintedPos=data.realPos
                                data.paintedDist=data.realDist
                                data.paintedYaw=tYaw
                                data.lastPainted=now
                                pcall(function()
                                    sub.modem.transmit(config.radar.channel, config.radar.channel, {v=2,t=2,si=os.getComputerID(),ti=id})
                                end)
                                if id==sub.selectedTargetId then
                                    sub.selectedTargetDistStr=string.format("%dm",math_floor(data.realDist+0.5))
                                end
                            end
                        end
                    end
                    ::continue::
                end
                if sub.selectedTargetId and sub.targets[sub.selectedTargetId] then
                    local data=sub.targets[sub.selectedTargetId]
                    if data.realDist and data.realDist<=sub.currentRadarRange and (now-data.lastSeen<3.0) then
                        sub.trackedTargetId=sub.selectedTargetId
                        if data.isBeingScanned then
                            local tPitch,tYaw=0,0
                            if sub.currentQAbs and sub.currentQLoc then
                                local iqx,iqy,iqz,iqw=quatInverse(sub.currentQAbs.x,sub.currentQAbs.y,sub.currentQAbs.z,sub.currentQAbs.w)
                                local dx=data.paintedPos.x-sub.localPos.x
                                local dy=data.paintedPos.y-sub.localPos.y
                                local dz=data.paintedPos.z-sub.localPos.z
                                local hx,hy,hz=rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                                local sx,sy,sz=rotateVectorFast(hx,hy,hz, sub.currentQLoc.x,sub.currentQLoc.y,sub.currentQLoc.z,sub.currentQLoc.w)
                                tYaw=math_deg(math_atan2(-sx,sz))
                                tPitch=math_deg(math_atan2(-sy, math_sqrt(sx*sx+sz*sz)))
                            else
                                tPitch,tYaw=calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, data.paintedPos.x,data.paintedPos.y,data.paintedPos.z)
                            end
                            local normYaw=tYaw%360
                            local gridIdx=math_floor(normYaw/config.radar.aimPrecision)
                            local snappedYaw=gridIdx*config.radar.aimPrecision+(config.radar.aimPrecision/2)
                            if snappedYaw>180 then snappedYaw=snappedYaw-360 end
                            sub.holdPitch=tPitch; sub.holdYaw=snappedYaw
                            if sub.camera.forcePitchYaw then sub.camera.forcePitchYaw(tPitch,snappedYaw)
                            else sub.camera.setPitch(tPitch); sub.camera.setYaw(snappedYaw) end
                        elseif sub.holdPitch and sub.holdYaw then
                            if sub.camera.forcePitchYaw then sub.camera.forcePitchYaw(sub.holdPitch,sub.holdYaw)
                            else sub.camera.setPitch(sub.holdPitch); sub.camera.setYaw(sub.holdYaw) end
                        end
                    else
                        sub.selectedTargetId=nil; sub.trackedTargetId=nil; sub.selectedTargetDistStr=nil
                    end
                else
                    sub.trackedTargetId=nil
                    if sub.holdPitch and sub.holdYaw then
                        if sub.camera.forcePitchYaw then sub.camera.forcePitchYaw(sub.holdPitch,sub.holdYaw)
                        else sub.camera.setPitch(sub.holdPitch); sub.camera.setYaw(sub.holdYaw) end
                    end
                end
            end
        end
        sleep(0.05)
    end
end

-- ==========================================
-- 声纳摄像头循环 (软件扫描，无伺服)
-- ==========================================
local function sonarCameraLoop(sub)
    local lastTime = os_clock()
    while true do
        if sub.stressometer then
            local ok, cap = pcall(sub.stressometer.getStressCapacity)
            if ok then
                sub.currentStressCapacity = cap or 0
                sub.currentRadarRange = (sub.currentStressCapacity >= config.sonar.stressThreshold) and config.sonar.maxDistance or 0
            else
                sub.currentStressCapacity = 0; sub.currentRadarRange = 0
            end
        else
            sub.currentRadarRange = 0
        end

        if sub.camera then
            local ok, pos = pcall(sub.camera.getCameraPosition)
            if ok and pos then sub.localPos = pos else sub.localPos = nil end
            pcall(function()
                sub.currentQAbs = sub.camera.getAbsViewTransform()
                sub.currentQLoc = sub.camera.getLocViewTransform()
                if sub.currentQAbs and sub.currentQLoc then
                    local iqx,iqy,iqz,iqw = quatInverse(sub.currentQAbs.x,sub.currentQAbs.y,sub.currentQAbs.z,sub.currentQAbs.w)
                    local hx,hy,hz = rotateVectorFast(0,0,-1,iqx,iqy,iqz,iqw)
                    local sx,sy,sz = rotateVectorFast(hx,hy,hz, sub.currentQLoc.x,sub.currentQLoc.y,sub.currentQLoc.z,sub.currentQLoc.w)
                    sub.currentNorthYawDeg = (math_deg(math_atan2(-sx, sz)) + config.sonar.headingOffset) % 360
                end
            end)
        end

        local now = os_clock()
        local dt = now - lastTime
        lastTime = now
        sub.sonarScanAngle = (sub.sonarScanAngle + config.sonar.scanSpeed * dt) % 360

        local center = sub.currentNorthYawDeg + config.sonar.yawOffset + config.sonar.sonarCenterOffset
        if sub.currentRadarRange > 0 and sub.localPos then
            for _, data in pairs(sub.targets) do
                if data.realPos and not data.isBeacon and sub.localPos then
                    local d = calcRangingDist(sub.localPos, data.realPos)
                    if d then data.realDist = d end
                end
            end
            for id, data in pairs(sub.targets) do
                if not data.isBeacon then
                    local invalid = false
                    if data.realDist then
                        if data.realDist < config.sonar.minDistance or data.realDist > config.sonar.maxDistance then invalid = true end
                    end
                    if data.realPos and data.realPos.y > config.sonar.seaLevel then invalid = true end
                    if not data.lastSeen or (now-data.lastSeen > 3) then invalid = true end
                    if invalid then
                        sub.targets[id] = nil
                        if id == sub.selectedTargetId then sub.selectedTargetId = nil; sub.selectedTargetDistStr = nil; sub.selectedTargetDepth = nil end
                    end
                end
            end
            local effectiveSW = config.sonar.scanWidth
            for id, data in pairs(sub.targets) do
                if data.isBeacon then goto continue end
                data.isBeingScanned = false
                if data.realPos and data.realDist and data.realDist >= config.sonar.minDistance and data.realDist <= config.sonar.maxDistance then
                    local tYaw
                    if sub.currentQAbs and sub.currentQLoc then
                        local iqx,iqy,iqz,iqw = quatInverse(sub.currentQAbs.x,sub.currentQAbs.y,sub.currentQAbs.z,sub.currentQAbs.w)
                        local dx,dy,dz = data.realPos.x-sub.localPos.x, data.realPos.y-sub.localPos.y, data.realPos.z-sub.localPos.z
                        local hx,hy,hz = rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                        local sx,sy,sz = rotateVectorFast(hx,hy,hz, sub.currentQLoc.x,sub.currentQLoc.y,sub.currentQLoc.z,sub.currentQLoc.w)
                        tYaw = math_deg(math_atan2(-sx, sz))
                    else
                        _, tYaw = calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, data.realPos.x,data.realPos.y,data.realPos.z)
                    end
                    if isInSector(tYaw, center, 90) and math_abs(getAngleDiff(tYaw, sub.sonarScanAngle)) <= effectiveSW/2 then
                        data.isBeingScanned = true
                        if not data.lastPainted or (now-data.lastPainted >= 1.0) then
                            data.paintedPos = data.realPos
                            data.paintedDist = data.realDist
                            data.paintedYaw = tYaw
                            data.lastPainted = now
                            if config.sonar.broadcastPos == "yes" then
                                sub.modem.transmit(config.sonar.channel_send, config.sonar.channel_send, {v=2, t=2, si=os.getComputerID(), ti=id})
                            end
                            if id == sub.selectedTargetId then
                                sub.selectedTargetDistStr = string.format("%dm", math_floor(data.realDist+0.5))
                                sub.selectedTargetDepth = config.sonar.seaLevel - data.realPos.y
                            end
                        end
                    end
                end
                ::continue::
            end
            if sub.selectedTargetId and sub.targets[sub.selectedTargetId] and sub.targets[sub.selectedTargetId].isBeingScanned then
                sub.trackedTargetId = sub.selectedTargetId; sub.isTargetInRange = true
                local t = sub.targets[sub.selectedTargetId]
                if t.paintedPos then
                    local tp, ty = calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, t.paintedPos.x,t.paintedPos.y,t.paintedPos.z)
                    local grid = math_floor((ty%360)/config.sonar.aimPrecision)*config.sonar.aimPrecision + config.sonar.aimPrecision/2
                    if grid>180 then grid=grid-360 end
                    sub.holdPitch, sub.holdYaw = tp, grid
                    if sub.camera.forcePitchYaw then sub.camera.forcePitchYaw(tp, grid)
                    else sub.camera.setPitch(tp); sub.camera.setYaw(grid) end
                end
            else
                sub.trackedTargetId = nil; sub.isTargetInRange = false
                if sub.holdPitch and sub.holdYaw then
                    if sub.camera.forcePitchYaw then sub.camera.forcePitchYaw(sub.holdPitch, sub.holdYaw)
                    else sub.camera.setPitch(sub.holdPitch); sub.camera.setYaw(sub.holdYaw) end
                end
            end
        end
        sleep(0.05)
    end
end

-- ==========================================
-- 终端 UI (四页)
-- ==========================================
local function termUI()
    while true do
        term.setBackgroundColor(colors.black)
        term.clear()
        local tabs = {"RADAR PARAMS", "SONAR PARAMS", "STATUS", "DEVICES"}
        local tabStr = ""
        for i, t in ipairs(tabs) do
            tabStr = tabStr .. (i == config.currentTab and ("["..t.."]") or " "..t.." ") .. "  "
        end
        term.setCursorPos(2,1); term.setTextColor(colors.white)
        term.write(tabStr)

        if config.currentTab == 1 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== RADAR PARAMETERS ===")
            local items = {
                {"Disp. Offset", config.radar.yawOffset},
                {"Heading Off",  config.radar.headingOffset},
                {"Motor Offset", config.radar.motorOffset},
                {"Aim Prec",     config.radar.aimPrecision},
                {"Broadcast",    config.radar.broadcastPos},
                {"Max Dist",     config.radar.maxDistance},
                {"Stress Ratio", config.radar.stressRatio},
                {"Channel",      config.radar.channel},
                {"Scan Width",   config.radar.scanWidth},
            }
            local y = 5
            for i, item in ipairs(items) do
                term.setCursorPos(2,y); term.setTextColor(i == config.menuIndex and colors.yellow or colors.lightGray)
                term.write(item[1])
                term.setCursorPos(20,y)
                local val = (i == config.menuIndex and config.isEditing) and (config.inputStr.."_") or tostring(item[2])
                term.setTextColor(colors.white)
                term.write(val)
                y = y+1
            end
        elseif config.currentTab == 2 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== SONAR PARAMETERS ===")
            local items = {
                {"Disp. Offset",   config.sonar.yawOffset},
                {"Heading Off",    config.sonar.headingOffset},
                {"S Center Off",   config.sonar.sonarCenterOffset},
                {"Aim Prec",       config.sonar.aimPrecision},
                {"Broadcast",      config.sonar.broadcastPos},
                {"Min Dist",       config.sonar.minDistance},
                {"Max Dist",       config.sonar.maxDistance},
                {"Stress Thresh",  config.sonar.stressThreshold},
                {"Send Ch",        config.sonar.channel_send},
                {"Listen Ch",      config.sonar.channel_listen},
                {"Scan Width",     config.sonar.scanWidth},
                {"Sea Level",      config.sonar.seaLevel},
                {"Scan Speed",     config.sonar.scanSpeed},
            }
            local y = 5
            for i, item in ipairs(items) do
                term.setCursorPos(2,y); term.setTextColor(i == config.menuIndex and colors.yellow or colors.lightGray)
                term.write(item[1])
                term.setCursorPos(20,y)
                local val = (i == config.menuIndex and config.isEditing) and (config.inputStr.."_") or tostring(item[2])
                term.setTextColor(colors.white)
                term.write(val)
                y = y+1
            end
        elseif config.currentTab == 3 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            local function statusLine(y, label, sub, isSonar)
                term.setCursorPos(2,y); term.setTextColor(colors.white)
                term.write(label.." Range:")
                if sub.currentRadarRange > 0 and (isSonar or sub.isServoConnected) then
                    term.setTextColor(colors.green)
                    if isSonar then
                        term.write(string.format(" %d-%d m", config.sonar.minDistance, config.sonar.maxDistance))
                    else
                        term.write(string.format(" %.0f m", sub.currentRadarRange))
                    end
                else
                    term.setTextColor(colors.red)
                    term.write(" OFFLINE")
                end
                term.setCursorPos(40,y)
                term.write("Stress:"..sub.currentStressCapacity)
                if isSonar then term.write(" (need "..config.sonar.stressThreshold..")") end
            end
            statusLine(5, "Radar", r, false)
            statusLine(7, "Sonar", s, true)
            term.setCursorPos(2,10); term.setTextColor(colors.gray)
            term.write("Radar targets: "..tableSize(r.targets))
            term.setCursorPos(2,11)
            term.write("Sonar targets: "..tableSize(s.targets))
        elseif config.currentTab == 4 then
            term.setCursorPos(2,3); term.setTextColor(colors.yellow)
            term.write("=== PERIPHERALS ===")
            local y = 5
            term.setCursorPos(2,y); term.setTextColor(colors.cyan)
            term.write("[Radar]")
            y = y+1
            term.setCursorPos(4,y); term.write("Modem: "..(config.radar.modem_name~="" and config.radar.modem_name or "auto"))
            y = y+1
            term.setCursorPos(4,y); term.write("Camera: "..(config.radar.camera_name~="" and config.radar.camera_name or "auto"))
            y = y+1
            term.setCursorPos(4,y); term.write("Servo: "..(config.radar.servo_name~="" and config.radar.servo_name or "auto"))
            y = y+1
            term.setCursorPos(4,y); term.write("Stress: "..(config.radar.stressometer_name~="" and config.radar.stressometer_name or "auto"))
            y = y+2
            term.setCursorPos(2,y); term.setTextColor(colors.cyan)
            term.write("[Sonar]")
            y = y+1
            term.setCursorPos(4,y); term.write("Modem: "..(config.sonar.modem_name~="" and config.sonar.modem_name or "auto"))
            y = y+1
            term.setCursorPos(4,y); term.write("Camera: "..(config.sonar.camera_name~="" and config.sonar.camera_name or "auto"))
            y = y+1
            term.setCursorPos(4,y); term.write("Stress: "..(config.sonar.stressometer_name~="" and config.sonar.stressometer_name or "auto"))
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 输入处理 (支持四页)
-- ==========================================
local function inputLoop()
    while true do
        local ev, p1 = os_pullEvent()
        if ev == "key" then
            if p1 == keys.tab then
                config.currentTab = config.currentTab % 4 + 1
                config.isEditing = false
            elseif config.currentTab == 1 or config.currentTab == 2 then
                local maxItems = config.currentTab == 1 and 9 or 13
                if not config.isEditing then
                    if p1 == keys.up then config.menuIndex = math_max(1, config.menuIndex - 1)
                    elseif p1 == keys.down then config.menuIndex = math_min(maxItems, config.menuIndex + 1)
                    elseif p1 == keys.enter or p1 == keys.numPadEnter then
                        config.isEditing = true
                        local subCfg = config.currentTab == 1 and config.radar or config.sonar
                        local fields = config.currentTab == 1 and
                            {"yawOffset","headingOffset","motorOffset","aimPrecision","broadcastPos","maxDistance","stressRatio","channel","scanWidth"} or
                            {"yawOffset","headingOffset","sonarCenterOffset","aimPrecision","broadcastPos","minDistance","maxDistance","stressThreshold","channel_send","channel_listen","scanWidth","seaLevel","scanSpeed"}
                        config.inputStr = tostring(subCfg[fields[config.menuIndex]])
                    end
                else
                    if p1 == keys.enter or p1 == keys.numPadEnter then
                        local subCfg = config.currentTab == 1 and config.radar or config.sonar
                        local fields = config.currentTab == 1 and
                            {"yawOffset","headingOffset","motorOffset","aimPrecision","broadcastPos","maxDistance","stressRatio","channel","scanWidth"} or
                            {"yawOffset","headingOffset","sonarCenterOffset","aimPrecision","broadcastPos","minDistance","maxDistance","stressThreshold","channel_send","channel_listen","scanWidth","seaLevel","scanSpeed"}
                        local field = fields[config.menuIndex]
                        local val = config.inputStr
                        if field == "broadcastPos" then
                            subCfg.broadcastPos = (val == "yes" or val == "no") and val or subCfg.broadcastPos
                        else
                            local num = tonumber(val)
                            if num then subCfg[field] = num end
                        end
                        saveConfig()
                        config.isEditing = false
                    elseif p1 == keys.backspace then
                        config.inputStr = config.inputStr:sub(1, -2)
                    end
                end
            end
        elseif ev == "char" and config.isEditing then
            config.inputStr = config.inputStr .. p1
        end
    end
end

-- ==========================================
-- 启动
-- ==========================================
term.clear()
term.setCursorPos(1,1)
term.setTextColor(colors.green)
print("Integrated System v4.0 (Radar + Sonar)")
print("Radar GPU: "..#r.gpuList.."  HUD: "..#r.hudList)
print("Sonar GPU: "..#s.gpuList.."  HUD: "..#s.hudList)
sleep(1)

parallel.waitForAll(
    function() radarCameraLoop(r) end,
    function() sonarCameraLoop(s) end,
    function() radarPing(r) end,
    function() sonarPing(s) end,
    function() radarListen(r) end,
    function() sonarListen(s) end,
    function() gpuRadarLoop(r) end,
    function() gpuSonarLoop(s) end,
    function() hudRadar(r) end,
    function() hudSonar(s) end,
    function() radarRWRReset() end,
    function() iffToggleLoop(r) end,
    termUI,
    inputLoop
)
