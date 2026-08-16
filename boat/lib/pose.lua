-- CC:Sable pose / velocity helpers in craft body frame.
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

--- Rotate world vector into body frame using quaternion (x,y,z,w) or Advanced Math quat.
function pose.quatRotateInverse(q, v)
    -- q* conjugates: rotate world->body is conjugate(q) * v * q for body-from-world
    local x, y, z, w
    if q.w ~= nil then
        x, y, z, w = q.x or 0, q.y or 0, q.z or 0, q.w or 1
    elseif type(q.get) == "function" then
        -- Advanced Math quaternion: use toEuler + rebuild axes instead if needed
        x, y, z, w = q.x or 0, q.y or 0, q.z or 0, q.w or 1
    else
        x, y, z, w = q[1] or 0, q[2] or 0, q[3] or 0, q[4] or 1
    end
    -- conjugate
    local cx, cy, cz, cw = -x, -y, -z, w
    -- q_conj * v (as pure quat)
    local ix = cw * v.x + cy * v.z - cz * v.y
    local iy = cw * v.y + cz * v.x - cx * v.z
    local iz = cw * v.z + cx * v.y - cy * v.x
    local iw = -cx * v.x - cy * v.y - cz * v.z
    -- * q
    return {
        x = ix * w + iw * x + iy * z - iz * y,
        y = iy * w + iw * y + iz * x - ix * z,
        z = iz * w + iw * z + ix * y - iy * x,
    }
end

function pose.forwardRightUp(q)
    -- Body axes in world: rotate body unit vectors by q
    local x, y, z, w
    if q.w ~= nil then
        x, y, z, w = q.x or 0, q.y or 0, q.z or 0, q.w or 1
    else
        x, y, z, w = q[1] or 0, q[2] or 0, q[3] or 0, q[4] or 1
    end
    local function rot(vx, vy, vz)
        local ix = w * vx + y * vz - z * vy
        local iy = w * vy + z * vx - x * vz
        local iz = w * vz + x * vy - y * vx
        local iw = -x * vx - y * vy - z * vz
        return {
            x = ix * w + iw * x + iy * z - iz * y,
            y = iy * w + iw * y + iz * x - ix * z,
            z = iz * w + iw * z + ix * y - iy * x,
        }
    end
    -- Minecraft/Sable: typically +Z forward or -Z; use +Z as forward, +X right, +Y up in body
    local forward = rot(0, 0, 1)
    local right = rot(1, 0, 0)
    local up = rot(0, 1, 0)
    forward = vnorm(forward)
    right = vnorm(right)
    up = vnorm(up)
    return forward, right, up
end

function pose.yawFromQuat(q)
    local forward = select(1, pose.forwardRightUp(q))
    return math.atan2(forward.x, forward.z)
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
    local forward, right, up = pose.forwardRightUp(q)
    local pos = vec3(p.position)
    local yaw = math.atan2(forward.x, forward.z)
    return {
        x = pos.x,
        y = pos.y,
        z = pos.z,
        yaw = yaw,
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
