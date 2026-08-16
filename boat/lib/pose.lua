-- CC:Sable pose / velocity helpers in craft body frame.
-- Orientation is CC: Advanced Math quaternion (q.v + q.a, :toEuler).
local pose = {}

local function vec3(x, y, z)
    if type(x) == "table" then
        return {
            x = tonumber(x.x or x[1]) or 0,
            y = tonumber(x.y or x[2]) or 0,
            z = tonumber(x.z or x[3]) or 0,
        }
    end
    return { x = tonumber(x) or 0, y = tonumber(y) or 0, z = tonumber(z) or 0 }
end

local function vdot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function vnorm(a)
    local m = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
    if m < 1e-9 then
        return { x = 0, y = 0, z = 0 }, 0
    end
    return { x = a.x / m, y = a.y / m, z = a.z / m }, m
end

local function vcross(a, b)
    return {
        x = a.y * b.z - a.z * b.y,
        y = a.z * b.x - a.x * b.z,
        z = a.x * b.y - a.y * b.x,
    }
end

--- Unpack quaternion components. Advanced Math uses .v (vector) + .a (real).
function pose.quatComponents(q)
    if q == nil then
        return 0, 0, 0, 1
    end
    if type(q.toEuler) == "function" or type(q.a) == "number" or (type(q) == "table" and q.v ~= nil) then
        local v = q.v
        if type(v) == "table" or type(v) == "userdata" then
            local x = tonumber(v.x or (v.getX and v:getX()) or v[1]) or 0
            local y = tonumber(v.y or (v.getY and v:getY()) or v[2]) or 0
            local z = tonumber(v.z or (v.getZ and v:getZ()) or v[3]) or 0
            local w = tonumber(q.a) or 1
            return x, y, z, w
        end
    end
    if q.w ~= nil or q.x ~= nil then
        return tonumber(q.x) or 0, tonumber(q.y) or 0, tonumber(q.z) or 0, tonumber(q.w) or 1
    end
    if type(q) == "table" then
        return tonumber(q[1]) or 0, tonumber(q[2]) or 0, tonumber(q[3]) or 0, tonumber(q[4]) or 1
    end
    return 0, 0, 0, 1
end

--- Pitch, yaw, roll (YXZ). Prefer :toEuler(); fallback from components.
function pose.toEuler(q)
    if q and type(q.toEuler) == "function" then
        local ok, result = pcall(function()
            local p, y, r = q:toEuler()
            if type(p) == "table" then
                return {
                    tonumber(p[1] or p.pitch) or 0,
                    tonumber(p[2] or p.yaw) or 0,
                    tonumber(p[3] or p.roll) or 0,
                }
            end
            return { tonumber(p) or 0, tonumber(y) or 0, tonumber(r) or 0 }
        end)
        if ok and type(result) == "table" then
            return result[1] or 0, result[2] or 0, result[3] or 0
        end
    end
    local x, y, z, w = pose.quatComponents(q)
    -- YXZ extraction
    local sinp = 2 * (w * x - y * z)
    if sinp > 1 then
        sinp = 1
    end
    if sinp < -1 then
        sinp = -1
    end
    local pitch = math.asin(sinp)
    local yaw = math.atan2(2 * (w * y + z * x), 1 - 2 * (x * x + y * y))
    local roll = math.atan2(2 * (w * z + x * y), 1 - 2 * (x * x + z * z))
    return pitch, yaw, roll
end

--- Body axes in world from orientation.
-- Minecraft/Sable horizontal: yaw 0 faces +Z (south); increasing yaw turns toward -X (west).
function pose.forwardRightUp(q)
    local pitch, yaw, _roll = pose.toEuler(q)
    local cp, sp = math.cos(pitch), math.sin(pitch)
    local cy, sy = math.cos(yaw), math.sin(yaw)
    -- forward includes pitch; right is horizontal
    local forward = { x = -sy * cp, y = sp, z = cy * cp }
    local right = { x = cy, y = 0, z = sy }
    local up = vcross(right, forward)
    forward = select(1, vnorm(forward))
    right = select(1, vnorm(right))
    up = select(1, vnorm(up))
    -- If up collapsed, rebuild
    if up.x == 0 and up.y == 0 and up.z == 0 then
        up = { x = 0, y = 1, z = 0 }
        right = select(1, vnorm(vcross(forward, up)))
        up = select(1, vnorm(vcross(right, forward)))
    end
    return forward, right, up, yaw, pitch
end

function pose.yawFromQuat(q)
    local _p, yaw = pose.toEuler(q)
    return yaw or 0
end

function pose.getRaw()
    if not sublevel then
        return nil, "no sublevel API"
    end
    local ok, p = pcall(sublevel.getLogicalPose)
    if not ok then
        return nil, tostring(p)
    end
    return p
end

function pose.get()
    local p, err = pose.getRaw()
    if not p then
        return nil, err
    end
    local q = p.orientation
    local forward, right, up, yaw, pitch = pose.forwardRightUp(q)
    local pos = vec3(p.position)
    return {
        x = pos.x,
        y = pos.y,
        z = pos.z,
        yaw = yaw or 0,
        pitch = pitch or 0,
        forward = forward,
        right = right,
        up = up,
        orientation = q,
        position = pos,
    }
end

function pose.getVelocity()
    if not sublevel then
        return { x = 0, y = 0, z = 0 }
    end
    local ok, v = pcall(sublevel.getLinearVelocity)
    if not ok or not v then
        ok, v = pcall(sublevel.getVelocity)
    end
    if not ok or not v then
        return { x = 0, y = 0, z = 0 }
    end
    return vec3(v)
end

function pose.getAngularVelocity()
    if not sublevel then
        return { x = 0, y = 0, z = 0 }
    end
    local ok, v = pcall(sublevel.getAngularVelocity)
    if not ok or not v then
        return { x = 0, y = 0, z = 0 }
    end
    return vec3(v)
end

function pose.getCenterOfMass()
    if not sublevel then
        return { x = 0, y = 0, z = 0 }
    end
    local ok, v = pcall(sublevel.getCenterOfMass)
    if not ok or not v then
        return { x = 0, y = 0, z = 0 }
    end
    return vec3(v)
end

function pose.worldToLocal(worldVel, craft)
    craft = craft or pose.get()
    if not craft then
        return { forward = 0, right = 0, up = 0 }
    end
    local v = vec3(worldVel)
    return {
        forward = vdot(v, craft.forward),
        right = vdot(v, craft.right),
        up = vdot(v, craft.up),
    }
end

function pose.yawRate(craft)
    craft = craft or pose.get()
    if not craft then
        return 0
    end
    local ang = pose.getAngularVelocity()
    return vdot(ang, craft.up)
end

function pose.speed(craft)
    local v = pose.getVelocity()
    if craft then
        local localV = pose.worldToLocal(v, craft)
        return localV.forward, localV
    end
    local _, m = vnorm(v)
    return m, nil
end

pose.vec3 = vec3
pose.vdot = vdot
pose.vnorm = vnorm
pose.vcross = vcross

return pose
