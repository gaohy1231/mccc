--[[ 综合探测系统 v3.1 (雷达 + 主动声纳)
     修正了 GPU/HUD 名称缺失和 table.size 未定义的问题
     双 GPU、双 HUD 同时运行，Tab 翻页配置
     硬件绑定通过 integrated_config.txt 设置
======================================================================]]

-- ==========================================
-- 全局常量
-- ==========================================
local SUBSYSTEM_RADAR = 1
local SUBSYSTEM_SONAR = 2

-- ==========================================
-- 配置文件管理
-- ==========================================
local CONFIG_FILE = "integrated_config.txt"

-- 默认配置
local config = {
    -- 雷达外设绑定名称（留空则自动匹配第一个）
    radar = {
        modem_name       = "",
        camera_name      = "",
        servo_name       = "",
        stressometer_name= "",
        gpu_names        = {},   -- 手动填写 GPU 名称
        hud_names        = {},   -- 手动填写 Monitor 名称
        -- 校准参数
        yawOffset        = 0,
        motorOffset      = 0,
        aimPrecision     = 5,
        broadcastPos     = "yes",   -- 是否广播自身位置
        -- 性能参数
        maxDistance      = 3700,
        stressRatio      = 4.0,     -- SU/m
        channel          = 8888,
        scanWidth        = 20,
    },
    sonar = {
        modem_name       = "",
        camera_name      = "",
        servo_name       = "",
        stressometer_name= "",
        gpu_names        = {},
        hud_names        = {},
        yawOffset        = 0,
        motorOffset      = 0,
        sonarCenterOffset= 0,
        aimPrecision     = 5,
        broadcastPos     = "yes",
        minDistance      = 100,
        maxDistance      = 600,
        stressThreshold  = 10000,
        channel_send     = 8889,   -- 广播自身位置（发射）
        channel_listen   = 8890,   -- 监听其他船只广播
        scanWidth        = 20,
        seaLevel         = -4,
    },
    -- UI 状态
    currentTab          = 1,       -- 1:参数 2:状态 3:外设
    editingSubsystem    = 1,       -- 当前编辑的子系统
    menuIndex           = 1,
    isEditing           = false,
    inputStr            = "",
}

-- 加载配置
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserialize(f.readAll())
        f.close()
        if type(data) == "table" then
            -- 浅合并子表
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
-- 基础工具
-- ==========================================
local math_sqrt, math_atan2, math_deg, math_rad, math_floor, math_abs, math_min, math_max, math_sin, math_cos =
    math.sqrt, math.atan2, math.deg, math.rad, math.floor, math.abs, math.min, math.max, math.sin, math.cos
local os_clock, os_pullEvent, os_startTimer = os.clock, os.pullEvent, os.startTimer

-- 辅助：获取表大小
local function tableSize(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- 角度差
local function getAngleDiff(a, b)
    local diff = (a - b) % 360
    if diff > 180 then diff = diff - 360
    elseif diff < -180 then diff = diff + 360 end
    return diff
end

-- 扇区判断
local function isInSector(angle, centerDeg, halfWidth)
    return math_abs(getAngleDiff(angle, centerDeg)) <= halfWidth
end

-- 四元数
local function quatInverse(qx, qy, qz, qw) return -qx, -qy, -qz, qw end
local function rotateVectorFast(vx, vy, vz, qx, qy, qz, qw)
    local cx = qy*vz - qz*vy; local cy = qz*vx - qx*vz; local cz = qx*vy - qy*vx
    local ccx = qy*cz - qz*cy; local ccy = qz*cx - qx*cz; local ccz = qx*cy - qy*cx
    return vx+2*qw*cx+2*ccx, vy+2*qw*cy+2*ccy, vz+2*qw*cz+2*ccz
end

-- 距离计算
local function calcRangingDist(p1, p2)
    if not p1 or not p2 then return nil end
    local dx, dy, dz = p2.x-p1.x, p2.y-p1.y, p2.z-p1.z
    return math_sqrt(dx*dx+dy*dy+dz*dz)
end

-- 视线角度
local function calculateLookAngles(sx, sy, sz, tx, ty, tz)
    local dx, dy, dz = tx-sx, ty-sy, tz-sz
    local distH = math_sqrt(dx*dx + dz*dz)
    return math_deg(math_atan2(-dy, distH)), math_deg(math_atan2(-dx, dz))
end

-- 颜色
local function colorUnpack(c)
    return math_floor(c / 0x10000) % 0x100,
           math_floor(c / 0x100)   % 0x100,
           c % 0x100
end
local function colorPack(r, g, b)
    return math_floor(r)*0x10000 + math_floor(g)*0x100 + math_floor(b)
end
local function colorLerp(ca, cb, t)
    t = math_max(0, math_min(1, t))
    local ar, ag, ab = colorUnpack(ca)
    local br, bg, bb = colorUnpack(cb)
    return colorPack(ar+(br-ar)*t, ag+(bg-ag)*t, ab+(bb-ab)*t)
end

-- 目标渐淡
local TARGET_FADE_DURATION = 3.0
local TARGET_HOT_DURATION  = 1.0
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
-- 子系统状态结构
-- ==========================================
local subsystems = {
    [SUBSYSTEM_RADAR] = {
        id = SUBSYSTEM_RADAR,
        name = "RADAR",
        targets = {},
        localPos = nil,
        currentQAbs = nil, currentQLoc = nil,
        currentServoAngle = 0,
        isServoConnected = false,
        currentStressCapacity = 0,
        currentRadarRange = 0,
        currentNorthYawDeg = 0,
        selectedTargetId = nil,
        selectedTargetDistStr = nil,
        trackedTargetId = nil,
        holdPitch, holdYaw = nil, nil,
        isTargetInRange = false,
        rwrEvents = {},
        iffMode = "enemy",
        targetPool = {}, targetPoolCount = 0,
        -- 外设对象
        modem = nil,
        camera = nil,
        servo = nil,
        stressometer = nil,
        gpuList = {},
        hudList = {},
    },
    [SUBSYSTEM_SONAR] = {
        id = SUBSYSTEM_SONAR,
        name = "SONAR",
        targets = {},
        localPos = nil,
        currentQAbs = nil, currentQLoc = nil,
        currentServoAngle = 0,
        isServoConnected = false,
        currentStressCapacity = 0,
        currentRadarRange = 0,
        currentNorthYawDeg = 0,
        selectedTargetId = nil,
        selectedTargetDistStr = nil,
        selectedTargetDepth = nil,
        trackedTargetId = nil,
        holdPitch, holdYaw = nil, nil,
        isTargetInRange = false,
        targetPool = {}, targetPoolCount = 0,
        modem = nil,
        camera = nil,
        servo = nil,
        stressometer = nil,
        gpuList = {},
        hudList = {},
    }
}

-- ==========================================
-- 外设绑定
-- ==========================================
-- 雷达
local r = subsystems[SUBSYSTEM_RADAR]
r.modem, _ = findByNameOrDefault(config.radar.modem_name, "modem")
if r.modem then r.modem.open(config.radar.channel) else error("Radar modem not found!", 0) end
r.camera, _ = findByNameOrDefault(config.radar.camera_name, "camera")
if not r.camera then error("Radar camera not found!", 0) end
r.servo, _ = findByNameOrDefault(config.radar.servo_name, "servo")  -- 可能为空
r.stressometer, _ = findByNameOrDefault(config.radar.stressometer_name, "Create_Stressometer")

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
        table.insert(r.gpuList, {
            gpu=g, name=gname, w=w, h=h, cx=cx, cy=cy, r=radius,
            bw=bw, bh=bh, dotSize=dotSize, lastSweepDeg=-999
        })
    end
end

-- 雷达HUD
for _, hname in ipairs(config.radar.hud_names) do
    if allPeripherals[hname] == "monitor" then
        local m = peripheral.wrap(hname)
        m.setTextScale(1)
        local cw, ch = m.getSize()
        table.insert(r.hudList, {
            mon=m, name=hname, w=cw, h=ch,
            lastLine1=nil, lastLine2=nil, lastLine3=nil, lastIff=nil
        })
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
s.servo, _ = findByNameOrDefault(config.sonar.servo_name, "servo")
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
        table.insert(s.gpuList, {
            gpu=g, name=gname, w=w, h=h, cx=cx, cy=cy, r=radius,
            bw=bw, bh=bh, dotSize=dotSize, lastSweepDeg=-999
        })
    end
end

-- 声纳HUD
for _, hname in ipairs(config.sonar.hud_names) do
    if allPeripherals[hname] == "monitor" then
        local m = peripheral.wrap(hname)
        m.setTextScale(1)
        local cw, ch = m.getSize()
        table.insert(s.hudList, {
            mon=m, name=hname, w=cw, h=ch,
            lastLine1=nil, lastLine2=nil, lastLine3=nil
        })
    end
end

-- ==========================================
-- 颜色常量
-- ==========================================
local RC = {
    BG=0x050A05, OUTER_RING=0x00CC44, INNER_RING=0x007722, GRID=0x005518,
    SWEEP=0x00FF66, YELLOW=0xFFFF00, ALLY_HOT=0x44FFAA, FOE_HOT=0xFF6600,
    UNK_HOT=0xEEEEEE, CORNER_FOE=0x660000, CORNER_ALLY=0x004400,
    BLACK=0, WHITE=0xFFFFFF, RWR_HOT=0xFFCC00,
}
local SC = {
    BG=0x050A05, OUTER_RING=0x00CC44, INNER_RING=0x007722, GRID=0x005518,
    SWEEP=0x00FF66, YELLOW=0xFFFF00, UNK_HOT=0xEEEEEE, BLACK=0, WHITE=0xFFFFFF,
}

-- ==========================================
-- 低级绘图函数
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
        if d<0 then d = d+2*y+1
        else x=x-1; d=d+2*(y-x)+1 end
    end
end

local function gpuDrawArc(g, cx, cy, r, startRad, endRad, col)
    local step = math_rad(0.5)
    for a = startRad, endRad, step do
        local px = cx + math_floor(r * math_cos(a) + 0.5)
        local py = cy - math_floor(r * math_sin(a) + 0.5)
        g.line(px, py, px, py, col)
    end
end

-- ==========================================
-- 雷达 GPU 绘制
-- ==========================================
local function drawRadarBase(entry, sub)
    local g = entry.gpu; local cx,cy,r = entry.cx, entry.cy, entry.r
    g.fill(RC.BG)
    gpuDrawCircle(g, cx, cy, r, RC.OUTER_RING)
    gpuDrawCircle(g, cx, cy, math_floor(r/2), RC.INNER_RING)
    g.line(cx, cy-r, cx, cy+r, RC.GRID)
    g.line(cx-r, cy, cx+r, cy, RC.GRID)
    for t=-r,r do
        if t%4<2 then
            if (t)^2+(t)^2 <= r*r then g.line(cx+t, cy+t, cx+t, cy+t, RC.GRID) end
            if (-t)^2+(t)^2 <= r*r then g.line(cx-t, cy+t, cx-t, cy+t, RC.GRID) end
        end
    end
    -- 北方 N
    local northRad = math_rad(sub.currentNorthYawDeg + config.radar.yawOffset)
    local nx = cx + math_floor(r * math_sin(northRad) + 0.5)
    local ny = cy - math_floor(r * math_cos(northRad) + 0.5)
    pcall(g.drawText, math_max(1, math_min(entry.w-6, nx-3)),
                       math_max(1, math_min(entry.h-8, ny-4)), "N", RC.YELLOW, RC.BG, 1)
end

local function drawRadarSweep(entry, sub)
    local g = entry.gpu; local cx,cy,r = entry.cx, entry.cy, entry.r
    local rad = math_rad(sub.currentServoAngle + config.radar.yawOffset)
    g.line(cx, cy, cx+math_floor(r*math_sin(rad)+0.5), cy-math_floor(r*math_cos(rad)+0.5), RC.SWEEP)
end

local function refreshRadarGPU(entry, sub, pool, count)
    local g = entry.gpu; local cx,cy,r = entry.cx, entry.cy, entry.r
    drawRadarBase(entry, sub)
    -- RWR弧线
    local now = os_clock()
    for i=#sub.rwrEvents,1,-1 do
        if now-sub.rwrEvents[i].time >= 1.0 then table.remove(sub.rwrEvents,i) end
    end
    for _, ev in ipairs(sub.rwrEvents) do
        local age = now-ev.time
        local col = colorLerp(RC.RWR_HOT, RC.BG, age/1.0)
        if col~=RC.BG then
            local cent = math_rad(ev.yawDeg + config.radar.yawOffset)
            for arcR = r+3, r+5 do
                for a = cent-0.4, cent+0.4, 0.05 do
                    local px, py = cx+math_floor(arcR*math_sin(a)+0.5), cy-math_floor(arcR*math_cos(a)+0.5)
                    if px>=1 and px<=entry.w and py>=1 and py<=entry.h then
                        g.line(px,py,px,py,col)
                    end
                end
            end
        end
    end
    -- 目标
    local ds, half = entry.dotSize, math_floor(entry.dotSize/2)
    for i=1, count do
        local t = pool[i]
        if t.col and t.col~=0 then
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
    drawRadarSweep(entry, sub)
    -- IFF角标
    local cornerCol = (sub.iffMode=="friendly") and RC.CORNER_ALLY or RC.CORNER_FOE
    local L, T = 14, 2
    for t=0,T-1 do
        g.line(1+t,1,1+t,1+L-1,cornerCol); g.line(1,1+t,1+L-1,1+t,cornerCol)
        g.line(entry.w-t,1,entry.w-t,1+L-1,cornerCol); g.line(entry.w-L+1,1+t,entry.w,1+t,cornerCol)
        g.line(1+t,entry.h-L+1,1+t,entry.h,cornerCol); g.line(1,entry.h-t,1+L-1,entry.h-t,cornerCol)
        g.line(entry.w-t,entry.h-L+1,entry.w-t,entry.h,cornerCol); g.line(entry.w-L+1,entry.h-t,entry.w,entry.h-t,cornerCol)
    end
    g.sync()
end

-- ==========================================
-- 声纳 GPU 绘制（扇形固定向上，N 随朝向转）
-- ==========================================
local function drawSonarBase(entry, sub)
    local g = entry.gpu; local cx,cy,r = entry.cx, entry.cy, entry.r
    g.fill(SC.BG)
    -- 扇形范围：0°（右侧）到 180°（左侧），让扇形开口向上
    local startRad, endRad = 0, math_rad(180)
    gpuDrawArc(g, cx, cy, r, startRad, endRad, SC.OUTER_RING)
    gpuDrawArc(g, cx, cy, math_floor(r/2), startRad, endRad, SC.INNER_RING)
    -- 两条边界
    local sx1 = cx + math_floor(r * math_cos(startRad) + 0.5)
    local sy1 = cy - math_floor(r * math_sin(startRad) + 0.5)
    g.line(cx, cy, sx1, sy1, SC.GRID)
    local sx2 = cx + math_floor(r * math_cos(endRad) + 0.5)
    local sy2 = cy - math_floor(r * math_sin(endRad) + 0.5)
    g.line(cx, cy, sx2, sy2, SC.GRID)
    -- 中心线（向上）
    local centerRad = math_rad(90)
    local cx1 = cx + math_floor(r * math_cos(centerRad) + 0.5)
    local cy1 = cy - math_floor(r * math_sin(centerRad) + 0.5)
    g.line(cx, cy, cx1, cy1, SC.GRID)
    -- 北方 N：位置由真实北偏航角决定，只绘制在扇形范围内
    local realNorthRad = math_rad(sub.currentNorthYawDeg + config.sonar.yawOffset)
    local norm = ((realNorthRad % (2*math.pi)) + 2*math.pi) % (2*math.pi)
    if norm >= 0 and norm <= math.pi then
        local nx = cx + math_floor((r+2) * math_cos(norm) + 0.5)
        local ny = cy - math_floor((r+2) * math_sin(norm) + 0.5)
        pcall(g.drawText, math_max(1, math_min(entry.w-6, nx-3)),
                           math_max(1, math_min(entry.h-8, ny-4)), "N", SC.YELLOW, SC.BG, 1)
    end
end

local function drawSonarSweep(entry, sub)
    local g = entry.gpu; local cx,cy,r = entry.cx, entry.cy, entry.r
    local angle = sub.currentServoAngle + config.sonar.yawOffset
    local rad = math_rad(angle)
    -- 只有角度在 0-180 才绘制
    local norm = ((rad % (2*math.pi)) + 2*math.pi) % (2*math.pi)
    if norm >= 0 and norm <= math.pi then
        g.line(cx, cy, cx+math_floor(r*math_sin(rad)+0.5), cy-math_floor(r*math_cos(rad)+0.5), SC.SWEEP)
    end
end

local function refreshSonarGPU(entry, sub, pool, count)
    local g = entry.gpu; local cx,cy,r = entry.cx, entry.cy, entry.r
    drawSonarBase(entry, sub)
    local ds, half = entry.dotSize, math_floor(entry.dotSize/2)
    for i=1, count do
        local t = pool[i]
        if t.col and t.col~=0 then
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
-- HUD 绘制
-- ==========================================
local function hudRadar(sub)
    while true do
        local isActive = (sub.currentRadarRange > 0) and sub.isServoConnected
        for _, info in ipairs(sub.hudList) do
            local line1, col1, line2, col2, line3, col3, line4, col4
            if not isActive then
                line1, col1 = "OFFLINE", colors.red
                line2, col2 = "---", colors.gray
                line3, col3 = "---", colors.gray
                line4, col4 = "---", colors.gray
            else
                line1, col1 = "ACTIVE", colors.green
                line2, col2 = string.format("%dm", math_floor(sub.currentRadarRange)), colors.lime
                if sub.selectedTargetId and sub.targets[sub.selectedTargetId] then
                    local t = sub.targets[sub.selectedTargetId]
                    if t.iff == "friendly" then
                        line3, col3 = "ALLY", colors.green
                        line4, col4 = sub.selectedTargetDistStr or "---", colors.green
                    elseif t.iff == "enemy" then
                        line3, col3 = "ENEMY", colors.red
                        line4, col4 = sub.selectedTargetDistStr or "---", colors.white
                    else
                        line3, col3 = "LOCKED", colors.yellow
                        line4, col4 = sub.selectedTargetDistStr or "---", colors.white
                    end
                else
                    line3, col3 = "SCAN", colors.lightGray
                    line4, col4 = "---", colors.gray
                end
            end
            -- 绘制
            info.mon.setBackgroundColor(colors.black); info.mon.clear()
            local dw, dh = info.w, info.h
            local function drawCL(txt,col,y)
                info.mon.setTextColor(col)
                info.mon.setCursorPos(math_max(1, math_floor((dw-#txt)/2)+1), y)
                info.mon.write(txt)
            end
            drawCL(line1, col1, math_floor(dh/2)-2)
            drawCL(line2, col2, math_floor(dh/2))
            drawCL(line3, col3, math_floor(dh/2)+2)
            drawCL(line4, col4, math_floor(dh/2)+4)
        end
        sleep(0.2)
    end
end

local function hudSonar(sub)
    while true do
        local isActive = (sub.currentRadarRange > 0) and sub.isServoConnected
        for _, info in ipairs(sub.hudList) do
            local line1, col1, line2, col2, line3, col3
            if not isActive then
                line1, col1 = "ASDIC offline", colors.red
            else
                line1, col1 = "ASDIC online", colors.green
            end
            line2, col2 = "100 - 600 m", colors.lime
            if sub.selectedTargetId and sub.targets[sub.selectedTargetId] then
                local t = sub.targets[sub.selectedTargetId]
                local depth = config.sonar.seaLevel - (t.realPos and t.realPos.y or 0)
                local dist = sub.selectedTargetDistStr or "---"
                line3 = string.format("D:%d m / R:%s", math_floor(depth), dist)
                col3 = colors.white
            else
                line3, col3 = "D:- - / R:- -", colors.gray
            end
            info.mon.setBackgroundColor(colors.black); info.mon.clear()
            local dw, dh = info.w, info.h
            local function drawCL(txt,col,y)
                info.mon.setTextColor(col)
                info.mon.setCursorPos(math_max(1, math_floor((dw-#txt)/2)+1), y)
                info.mon.write(txt)
            end
            drawCL(line1, col1, math_floor(dh/2)-1)
            drawCL(line2, col2, math_floor(dh/2)+1)
            drawCL(line3, col3, math_floor(dh/2)+3)
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 目标池构建辅助
-- ==========================================
local function buildRadarPool(sub)
    local pool = {}
    local count = 0
    local now = os_clock()
    if sub.localPos and sub.currentRadarRange > 0 and sub.isServoConnected then
        for _, data in pairs(sub.targets) do
            if data.lastPainted and not data.isBeacon then
                local age = now - data.lastPainted
                if age < TARGET_FADE_DURATION then
                    local hot = data.iff=="friendly" and RC.ALLY_HOT or data.iff=="enemy" and RC.FOE_HOT or RC.UNK_HOT
                    local col = calcFadeColor(age, hot)
                    if col then
                        local yawRad = math_rad(data.paintedYaw + config.radar.yawOffset)
                        local ratio = math_min(data.paintedDist / sub.currentRadarRange, 1.0)
                        count = count+1
                        pool[count] = {
                            col = col, r = ratio,
                            s = math_sin(yawRad), cs = math_cos(yawRad),
                            isBeacon = false
                        }
                    end
                end
            elseif data.isBeacon and data.lastSeen and (now-data.lastSeen<5.0) then
                local col = data.iff=="friendly" and RC.ALLY_HOT or RC.YELLOW
                local yawRad = math_rad((data.realPos and sub.localPos and calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, data.realPos.x,data.realPos.y,data.realPos.z)) or 0)
                local dist = data.realDist or 0
                local ratio = math_min(dist / sub.currentRadarRange, 1.0)
                count = count+1
                pool[count] = {col=col, r=ratio, s=math_sin(yawRad), cs=math_cos(yawRad), isBeacon=true}
            end
        end
    end
    return pool, count
end

local function buildSonarPool(sub)
    local pool = {}
    local count = 0
    local now = os_clock()
    local center = sub.currentNorthYawDeg + config.sonar.yawOffset + config.sonar.sonarCenterOffset
    if sub.localPos and sub.currentRadarRange > 0 and sub.isServoConnected then
        for _, data in pairs(sub.targets) do
            if data.lastPainted and not data.isBeacon then
                local age = now - data.lastPainted
                if age < TARGET_FADE_DURATION then
                    local col = calcFadeColor(age, SC.UNK_HOT)
                    if col and isInSector(data.paintedYaw, center, 90) then
                        local yawRad = math_rad(data.paintedYaw + config.sonar.yawOffset)
                        local ratio = math_min(data.paintedDist / config.sonar.maxDistance, 1.0)
                        count = count+1
                        pool[count] = {col=col, r=ratio, s=math_sin(yawRad), cs=math_cos(yawRad), isBeacon=false}
                    end
                end
            elseif data.isBeacon and data.lastSeen and (now-data.lastSeen<5.0) then
                local yaw = (sub.localPos and data.realPos) and select(2, calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, data.realPos.x,data.realPos.y,data.realPos.z)) or 0
                if isInSector(yaw, center, 90) then
                    local dist = data.realDist or 0
                    local ratio = math_min(dist / config.sonar.maxDistance, 1.0)
                    local yawRad = math_rad(yaw + config.sonar.yawOffset)
                    count = count+1
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
            pcall(refreshRadarGPU, entry, sub, pool, count)
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
-- 网络循环
-- ==========================================
local function radarPing(sub)
    while true do
        if sub.localPos and config.radar.broadcastPos == "yes" then
            sub.modem.transmit(config.radar.channel, config.radar.channel, {
                v=2, t=1, i=os.getComputerID(), n=os.getComputerLabel() or ("R-"..os.getComputerID()),
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

local function sonarPing(sub)
    while true do
        if sub.localPos and config.sonar.broadcastPos == "yes" then
            sub.modem.transmit(config.sonar.channel_send, config.sonar.channel_send, {
                v=2, t=1, i=os.getComputerID(), n=os.getComputerLabel() or ("S-"..os.getComputerID()),
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

-- 雷达监听（含RWR）
local function radarListen(sub)
    while true do
        local _, _, ch, _, msg, dist = os_pullEvent("modem_message")
        if ch == config.radar.channel and type(msg)=="table" and msg.v==2 then
            local myId = os.getComputerID()
            if msg.t==1 and msg.i~=myId then
                if not sub.targets[msg.i] then sub.targets[msg.i] = {} end
                local t = sub.targets[msg.i]
                t.name = msg.n; t.modemDist = dist; t.realPos = {x=msg.x, y=msg.y, z=msg.z}; t.range = msg.r
                t.lastSeen = os_clock(); t.isBeacon = false
                if sub.localPos then t.realDist = calcRangingDist(sub.localPos, t.realPos) or dist end
            elseif msg.t==2 and msg.ti==myId then
                local isFriendly = msg.si and sub.targets[msg.si] and sub.targets[msg.si].iff=="friendly"
                if not isFriendly then
                    local rwrYaw
                    if msg.si and sub.targets[msg.si] and sub.targets[msg.si].realPos and sub.localPos then
                        local sp = sub.targets[msg.si].realPos
                        if sub.currentQAbs and sub.currentQLoc then
                            local iqx,iqy,iqz,iqw = quatInverse(sub.currentQAbs.x,sub.currentQAbs.y,sub.currentQAbs.z,sub.currentQAbs.w)
                            local dx,dy,dz = sp.x-sub.localPos.x, sp.y-sub.localPos.y, sp.z-sub.localPos.z
                            local hx,hy,hz = rotateVectorFast(dx,dy,dz,iqx,iqy,iqz,iqw)
                            local sx,sy,sz = rotateVectorFast(hx,hy,hz, sub.currentQLoc.x,sub.currentQLoc.y,sub.currentQLoc.z,sub.currentQLoc.w)
                            rwrYaw = math_deg(math_atan2(-sx, sz))
                        else
                            _, rwrYaw = calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, sp.x,sp.y,sp.z)
                        end
                    end
                    if rwrYaw then
                        local norm = rwrYaw%360
                        local sector = math_floor((norm+22.5)/45)%8
                        local quant = sector*45
                        if quant>180 then quant=quant-360 end
                        table.insert(sub.rwrEvents, {yawDeg=quant, time=os_clock()})
                    end
                    redstone.setOutput("front", true)
                    os_startTimer(0.5)
                end
            elseif msg.t==3 then
                local key = tostring(msg.i).."_"..tostring(msg.uid or "0000")
                if not sub.targets[key] then sub.targets[key] = {} end
                local t = sub.targets[key]
                t.name = msg.n or ("Beacon-"..msg.i); t.modemDist = dist
                t.realPos = {x=msg.x, y=msg.y, z=msg.z}; t.lastSeen = os_clock(); t.isBeacon = true
                if sub.localPos then t.realDist = calcRangingDist(sub.localPos, t.realPos) or dist end
            end
        end
    end
end

-- 声纳监听（只收listen频道，无RWR）
local function sonarListen(sub)
    while true do
        local _, _, ch, _, msg, dist = os_pullEvent("modem_message")
        if ch == config.sonar.channel_listen and type(msg)=="table" and msg.v==2 then
            local myId = os.getComputerID()
            if (msg.t==1 or msg.t==3) and msg.i~=myId then
                -- 深度过滤
                if msg.y and msg.y > config.sonar.seaLevel then goto continue end
                if msg.t==1 then
                    if not sub.targets[msg.i] then sub.targets[msg.i] = {} end
                    local t = sub.targets[msg.i]
                    t.name = msg.n; t.modemDist = dist; t.realPos = {x=msg.x, y=msg.y, z=msg.z}; t.range = msg.r
                    t.lastSeen = os_clock(); t.isBeacon = false
                    if sub.localPos then t.realDist = calcRangingDist(sub.localPos, t.realPos) or dist end
                else -- t==3 信标
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

-- 雷达RWR红石恢复
local function radarRWRReset()
    while true do
        local _, p1 = os_pullEvent("timer")
        if p1 == 0.5 then
            redstone.setOutput("front", false)
        end
    end
end

-- ==========================================
-- 主扫描循环
-- ==========================================
local function radarCameraLoop(sub)
    local lastServoAngle = nil
    while true do
        -- 伺服角度
        if sub.servo then
            local ok, ang = pcall(sub.servo.getAngle)
            if ok and type(ang)=="number" then
                sub.isServoConnected = true
                sub.currentServoAngle = (math_deg(ang) + config.radar.motorOffset) % 360
                if lastServoAngle then
                    local delta = math_abs(getAngleDiff(sub.currentServoAngle, lastServoAngle))
                    if delta > 180 then delta = 0 end
                end
                lastServoAngle = sub.currentServoAngle
            else
                sub.isServoConnected = false
            end
        else
            sub.isServoConnected = false
        end

        -- 应力
        if sub.stressometer then
            local ok, cap = pcall(sub.stressometer.getStressCapacity)
            if ok then
                sub.currentStressCapacity = cap or 0
                sub.currentRadarRange = math_min(sub.currentStressCapacity / config.radar.stressRatio, config.radar.maxDistance)
            else
                sub.currentStressCapacity = 0
                sub.currentRadarRange = 0
            end
        else
            sub.currentRadarRange = 0
        end

        -- 摄像头
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
                    sub.currentNorthYawDeg = math_deg(math_atan2(-sx, sz))
                end
            end)
        end

        local now = os_clock()
        if sub.currentRadarRange > 0 and sub.isServoConnected and sub.localPos then
            -- 更新距离
            for _, data in pairs(sub.targets) do
                if data.realPos and not data.isBeacon and sub.localPos then
                    local d = calcRangingDist(sub.localPos, data.realPos)
                    if d then data.realDist = d end
                end
            end
            -- 清除无效
            for id, data in pairs(sub.targets) do
                if not data.isBeacon then
                    if (data.realDist and data.realDist > sub.currentRadarRange) or not data.lastSeen or (now-data.lastSeen > 3) then
                        sub.targets[id] = nil
                        if id == sub.selectedTargetId then sub.selectedTargetId = nil; sub.trackedTargetId = nil; sub.selectedTargetDistStr = nil end
                    end
                end
            end
            -- 扫描
            local effectiveSW = config.radar.scanWidth + (lastServoAngle and math_abs(getAngleDiff(sub.currentServoAngle, lastServoAngle)) or 0)
            for id, data in pairs(sub.targets) do
                if data.isBeacon then goto continue end
                data.isBeingScanned = false
                if data.realPos and data.realDist and data.realDist <= sub.currentRadarRange then
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
                    if math_abs(getAngleDiff(tYaw, sub.currentServoAngle)) <= effectiveSW/2 then
                        data.isBeingScanned = true
                        if not data.lastPainted or (now-data.lastPainted >= 1.0) then
                            data.paintedPos = data.realPos
                            data.paintedDist = data.realDist
                            data.paintedYaw = tYaw
                            data.lastPainted = now
                            sub.modem.transmit(config.radar.channel, config.radar.channel, {v=2, t=2, si=os.getComputerID(), ti=id})
                            if id == sub.selectedTargetId then
                                sub.selectedTargetDistStr = string.format("%dm", math_floor(data.realDist+0.5))
                            end
                        end
                    end
                end
                ::continue::
            end
            -- 锁定
            if sub.selectedTargetId and sub.targets[sub.selectedTargetId] and sub.targets[sub.selectedTargetId].isBeingScanned then
                sub.trackedTargetId = sub.selectedTargetId
                sub.isTargetInRange = true
                local t = sub.targets[sub.selectedTargetId]
                if t.paintedPos then
                    local tp, ty = calculateLookAngles(sub.localPos.x,sub.localPos.y,sub.localPos.z, t.paintedPos.x,t.paintedPos.y,t.paintedPos.z)
                    local grid = math_floor((ty%360)/config.radar.aimPrecision)*config.radar.aimPrecision + config.radar.aimPrecision/2
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

local function sonarCameraLoop(sub)
    local lastServoAngle = nil
    while true do
        -- 伺服
        if sub.servo then
            local ok, ang = pcall(sub.servo.getAngle)
            if ok and type(ang)=="number" then
                sub.isServoConnected = true
                sub.currentServoAngle = (math_deg(ang) + config.sonar.motorOffset) % 360
                if lastServoAngle then
                    local delta = math_abs(getAngleDiff(sub.currentServoAngle, lastServoAngle))
                    if delta > 180 then delta = 0 end
                end
                lastServoAngle = sub.currentServoAngle
            else
                sub.isServoConnected = false
            end
        else
            sub.isServoConnected = false
        end

        -- 应力阈值
        if sub.stressometer then
            local ok, cap = pcall(sub.stressometer.getStressCapacity)
            if ok then
                sub.currentStressCapacity = cap or 0
                sub.currentRadarRange = (sub.currentStressCapacity >= config.sonar.stressThreshold) and config.sonar.maxDistance or 0
            else
                sub.currentStressCapacity = 0
                sub.currentRadarRange = 0
            end
        else
            sub.currentRadarRange = 0
        end

        -- 摄像头
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
                    sub.currentNorthYawDeg = math_deg(math_atan2(-sx, sz))
                end
            end)
        end

        local now = os_clock()
        local center = sub.currentNorthYawDeg + config.sonar.yawOffset + config.sonar.sonarCenterOffset
        if sub.currentRadarRange > 0 and sub.isServoConnected and sub.localPos then
            -- 更新距离
            for _, data in pairs(sub.targets) do
                if data.realPos and not data.isBeacon and sub.localPos then
                    local d = calcRangingDist(sub.localPos, data.realPos)
                    if d then data.realDist = d end
                end
            end
            -- 清除（深度、扇区、距离）
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
                        if id == sub.selectedTargetId then sub.selectedTargetId = nil; sub.trackedTargetId = nil; sub.selectedTargetDistStr = nil; sub.selectedTargetDepth = nil end
                    end
                end
            end
            -- 扫描
            local effectiveSW = config.sonar.scanWidth + (lastServoAngle and math_abs(getAngleDiff(sub.currentServoAngle, lastServoAngle)) or 0)
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
                    if isInSector(tYaw, center, 90) and math_abs(getAngleDiff(tYaw, sub.currentServoAngle)) <= effectiveSW/2 then
                        data.isBeingScanned = true
                        if not data.lastPainted or (now-data.lastPainted >= 1.0) then
                            data.paintedPos = data.realPos
                            data.paintedDist = data.realDist
                            data.paintedYaw = tYaw
                            data.lastPainted = now
                            -- 发送照射（仍用send频道）
                            sub.modem.transmit(config.sonar.channel_send, config.sonar.channel_send, {v=2, t=2, si=os.getComputerID(), ti=id})
                            if id == sub.selectedTargetId then
                                sub.selectedTargetDistStr = string.format("%dm", math_floor(data.realDist+0.5))
                                sub.selectedTargetDepth = config.sonar.seaLevel - data.realPos.y
                            end
                        end
                    end
                end
                ::continue::
            end
            -- 锁定
            if sub.selectedTargetId and sub.targets[sub.selectedTargetId] and sub.targets[sub.selectedTargetId].isBeingScanned then
                sub.trackedTargetId = sub.selectedTargetId
                sub.isTargetInRange = true
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
-- 终端 UI
-- ==========================================
local function termUI()
    while true do
        term.setBackgroundColor(colors.black)
        term.clear()
        if config.currentTab == 1 then
            -- 参数页
            local subKey = config.editingSubsystem == SUBSYSTEM_RADAR and "radar" or "sonar"
            local sub = subsystems[config.editingSubsystem]
            term.setCursorPos(2,1); term.setTextColor(colors.yellow)
            term.write("=== "..sub.name.." PARAMETERS ===")
            local y = 3
            local items = {}
            if config.editingSubsystem == SUBSYSTEM_RADAR then
                items = {
                    {"Disp. Offset", config.radar.yawOffset},
                    {"Motor Offset", config.radar.motorOffset},
                    {"Aim Prec", config.radar.aimPrecision},
                    {"Broadcast", config.radar.broadcastPos},
                    {"Max Dist", config.radar.maxDistance},
                    {"Stress Ratio", config.radar.stressRatio},
                    {"Channel", config.radar.channel},
                    {"Scan Width", config.radar.scanWidth},
                }
            else
                items = {
                    {"Disp. Offset", config.sonar.yawOffset},
                    {"Motor Offset", config.sonar.motorOffset},
                    {"S Center Off", config.sonar.sonarCenterOffset},
                    {"Aim Prec", config.sonar.aimPrecision},
                    {"Broadcast", config.sonar.broadcastPos},
                    {"Min Dist", config.sonar.minDistance},
                    {"Max Dist", config.sonar.maxDistance},
                    {"Stress Thresh", config.sonar.stressThreshold},
                    {"Send Ch", config.sonar.channel_send},
                    {"Listen Ch", config.sonar.channel_listen},
                    {"Scan Width", config.sonar.scanWidth},
                    {"Sea Level", config.sonar.seaLevel},
                }
            end
            for i, item in ipairs(items) do
                term.setCursorPos(2, y); term.setTextColor(i == config.menuIndex and colors.yellow or colors.lightGray)
                term.write(item[1])
                term.setCursorPos(18, y)
                local val = i == config.menuIndex and config.isEditing and (config.inputStr.."_") or tostring(item[2])
                term.setTextColor(colors.white)
                term.write(val)
                y = y + 1
            end
            term.setCursorPos(2, y+1); term.setTextColor(colors.gray)
            term.write("[F1/F2] Switch Subsystem  [Tab] Next Page")
        elseif config.currentTab == 2 then
            -- 状态页
            term.setCursorPos(2,1); term.setTextColor(colors.yellow)
            term.write("=== SYSTEM STATUS ===")
            local function statusLine(y, label, sub, isSonar)
                term.setCursorPos(2,y); term.setTextColor(colors.white)
                term.write(label.." Range:")
                if sub.currentRadarRange > 0 and sub.isServoConnected then
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
                if isSonar then
                    term.write(" (need "..config.sonar.stressThreshold..")")
                end
            end
            statusLine(3, "Radar", subsystems[SUBSYSTEM_RADAR], false)
            statusLine(5, "Sonar", subsystems[SUBSYSTEM_SONAR], true)
            term.setCursorPos(2,8); term.setTextColor(colors.gray)
            term.write("Radar targets: "..tableSize(subsystems[SUBSYSTEM_RADAR].targets))
            term.setCursorPos(2,9)
            term.write("Sonar targets: "..tableSize(subsystems[SUBSYSTEM_SONAR].targets))
        elseif config.currentTab == 3 then
            -- 外设列表
            term.setCursorPos(2,1); term.setTextColor(colors.yellow)
            term.write("=== PERIPHERALS ===")
            local y = 3
            term.setCursorPos(2,y); term.setTextColor(colors.cyan)
            term.write("[Radar]")
            y=y+1
            for _, g in ipairs(r.gpuList) do
                term.setCursorPos(4,y); term.write("GPU: "..g.name)
                y=y+1
            end
            for _, h in ipairs(r.hudList) do
                term.setCursorPos(4,y); term.write("HUD: "..h.name)
                y=y+1
            end
            y=y+1
            term.setCursorPos(2,y); term.setTextColor(colors.cyan)
            term.write("[Sonar]")
            y=y+1
            for _, g in ipairs(s.gpuList) do
                term.setCursorPos(4,y); term.write("GPU: "..g.name)
                y=y+1
            end
            for _, h in ipairs(s.hudList) do
                term.setCursorPos(4,y); term.write("HUD: "..h.name)
                y=y+1
            end
        end
        sleep(0.2)
    end
end

-- ==========================================
-- 输入处理
-- ==========================================
local function inputLoop()
    while true do
        local ev, p1 = os_pullEvent()
        if ev == "key" then
            if p1 == keys.tab then
                config.currentTab = config.currentTab % 3 + 1
                config.isEditing = false
            elseif p1 == keys.f1 then
                config.editingSubsystem = SUBSYSTEM_RADAR
                config.menuIndex = 1
                config.isEditing = false
            elseif p1 == keys.f2 then
                config.editingSubsystem = SUBSYSTEM_SONAR
                config.menuIndex = 1
                config.isEditing = false
            elseif config.currentTab == 1 then
                local subCfg = config.editingSubsystem == SUBSYSTEM_RADAR and config.radar or config.sonar
                local maxItems = config.editingSubsystem == SUBSYSTEM_RADAR and 8 or 12
                if not config.isEditing then
                    if p1 == keys.up then config.menuIndex = math_max(1, config.menuIndex-1)
                    elseif p1 == keys.down then config.menuIndex = math_min(maxItems, config.menuIndex+1)
                    elseif p1 == keys.enter or p1 == keys.numPadEnter then
                        config.isEditing = true
                        -- 初始化输入串
                        local val
                        if config.editingSubsystem == SUBSYSTEM_RADAR then
                            local fields = {"yawOffset","motorOffset","aimPrecision","broadcastPos","maxDistance","stressRatio","channel","scanWidth"}
                            val = config.radar[fields[config.menuIndex]]
                        else
                            local fields = {"yawOffset","motorOffset","sonarCenterOffset","aimPrecision","broadcastPos","minDistance","maxDistance","stressThreshold","channel_send","channel_listen","scanWidth","seaLevel"}
                            val = config.sonar[fields[config.menuIndex]]
                        end
                        config.inputStr = tostring(val)
                    end
                else
                    if p1 == keys.enter or p1 == keys.numPadEnter then
                        -- 保存
                        local val = config.inputStr
                        local num = tonumber(val)
                        local field
                        if config.editingSubsystem == SUBSYSTEM_RADAR then
                            local fields = {"yawOffset","motorOffset","aimPrecision","broadcastPos","maxDistance","stressRatio","channel","scanWidth"}
                            field = fields[config.menuIndex]
                            if field == "broadcastPos" then config.radar.broadcastPos = (val=="yes" or val=="no") and val or config.radar.broadcastPos
                            elseif num then
                                config.radar[field] = num
                            end
                        else
                            local fields = {"yawOffset","motorOffset","sonarCenterOffset","aimPrecision","broadcastPos","minDistance","maxDistance","stressThreshold","channel_send","channel_listen","scanWidth","seaLevel"}
                            field = fields[config.menuIndex]
                            if field == "broadcastPos" then config.sonar.broadcastPos = (val=="yes" or val=="no") and val or config.sonar.broadcastPos
                            elseif num then
                                config.sonar[field] = num
                            end
                        end
                        saveConfig()
                        config.isEditing = false
                    elseif p1 == keys.backspace then
                        config.inputStr = config.inputStr:sub(1, -2)
                    end
                end
            end
        elseif ev == "char" and config.currentTab == 1 and config.isEditing then
            local char = p1
            if char >= ' ' then
                config.inputStr = config.inputStr .. char
            end
        end
    end
end

-- ==========================================
-- 启动
-- ==========================================
term.clear()
term.setCursorPos(1,1)
term.setTextColor(colors.green)
print("Integrated System v3.1")
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
    termUI,
    inputLoop
)
