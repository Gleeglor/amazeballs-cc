-- Craft pose helpers using CC:Sable sublevel + quaternion.
local pose = {}

local function requireSublevel()
    if not sublevel then
        error("CC:Sable sublevel API missing (is the computer on a Sable craft?)")
    end
    if not sublevel.isInPlotGrid or not sublevel.isInPlotGrid() then
        error("Computer is not on a Sable sub-level")
    end
end

--- @return table { position=vector, yaw=number(rad), forward=vector, right=vector, up=vector, orientation=quat }
function pose.get()
    requireSublevel()
    local p = sublevel.getLogicalPose()
    local q = p.orientation
    local _pitch, yaw, _roll = q:toEuler()
    yaw = yaw or 0

    -- Local axes in world space via quaternion * unit vectors
    local forward = q * vector.new(0, 0, 1)
    local right = q * vector.new(1, 0, 0)
    local up = q * vector.new(0, 1, 0)

    return {
        position = p.position,
        yaw = yaw,
        forward = forward,
        right = right,
        up = up,
        orientation = q,
        scale = p.scale,
    }
end

function pose.getVelocity()
    requireSublevel()
    return sublevel.getLinearVelocity()
end

function pose.getAngularVelocity()
    requireSublevel()
    return sublevel.getAngularVelocity()
end

--- Project a world-space vector into craft-local forward/right/up scalars.
function pose.worldToLocal(worldVec, craft)
    craft = craft or pose.get()
    local f = craft.forward
    local r = craft.right
    local u = craft.up
    return {
        forward = worldVec.x * f.x + worldVec.y * f.y + worldVec.z * f.z,
        right = worldVec.x * r.x + worldVec.y * r.y + worldVec.z * r.z,
        up = worldVec.x * u.x + worldVec.y * u.y + worldVec.z * u.z,
    }
end

--- Error from craft position/yaw to a target waypoint {x,y,z,yaw?} in craft frame.
function pose.errorToTarget(target, craft)
    craft = craft or pose.get()
    local dx = target.x - craft.position.x
    local dy = (target.y or craft.position.y) - craft.position.y
    local dz = target.z - craft.position.z
    local world = vector.new(dx, dy, dz)
    local localErr = pose.worldToLocal(world, craft)
    local yawErr = 0
    if target.yaw ~= nil then
        yawErr = target.yaw - craft.yaw
        -- wrap to [-pi, pi]
        while yawErr > math.pi do
            yawErr = yawErr - 2 * math.pi
        end
        while yawErr < -math.pi do
            yawErr = yawErr + 2 * math.pi
        end
    end
    local horiz = math.sqrt(dx * dx + dz * dz)
    return {
        forward = localErr.forward,
        right = localErr.right,
        up = localErr.up,
        yaw = yawErr,
        distance = horiz,
        distance3 = math.sqrt(dx * dx + dy * dy + dz * dz),
    }
end

function pose.yawDeg(yawRad)
    return yawRad * 180 / math.pi
end

return pose
