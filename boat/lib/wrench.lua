-- Reassembly-style thruster wrench allocation (pure math).
-- Command (Fx, Fy, Tz) in craft frame → per-thruster duties in [-1, 1].
local util = require("util")

local wrench = {}

wrench.DEADBAND = 0.08
wrench.YAW_WEIGHT = 2.5
wrench.SURGE_YAW_PENALTY = 8.0 -- heavy when commanding pure surge

local function thrusterColumns(thrusters, usePos)
    -- Each thruster contributes fx, fy, tz for +duty (pos gains) or -duty uses neg gains via signed u
    -- Model: force = u * (u>=0 and pos or neg) — nonlinear. Linearize around sign of previous or use pos for + and neg for -.
    -- For LS we use: contribution of u: if we allow signed u, column = pos gains for positive side.
    -- Better: dual columns aren't needed if we store effective gain as function of u sign iteratively.
    -- Single-pass: use average of pos/neg magnitudes with sign from fx preference.
    local cols = {}
    for i, t in ipairs(thrusters) do
        local fx = (tonumber(t.fx_pos) or 0)
        local fy = (tonumber(t.fy_pos) or 0)
        local tz = (tonumber(t.tz_pos) or 0)
        -- If neg gains dominate reverse, still use pos as +duty column; applyReassembly maps signed u through correct gains when applying.
        -- For allocation, use the stronger of |pos| and |neg| in each axis with consistent sign from pos.
        local fxn = tonumber(t.fx_neg) or 0
        local fyn = tonumber(t.fy_neg) or 0
        local tzn = tonumber(t.tz_neg) or 0
        -- Effective +1 duty uses pos; for LS column use pos. For -1 the force is -neg components in our calib convention:
        -- calib stores measured velocity under +rpm and -rpm separately as fx_pos etc.
        -- When u>0: F = u * pos; when u<0: F = |u| * neg (neg already signed from measurement).
        -- Linear approx around 0: F ≈ u * 0.5*(pos - neg) if neg is force under negative rpm...
        -- Convention: fx_pos = delta under +rpm probe; fx_neg = delta under -rpm probe (often opposite).
        -- For u in [-1,1]: F(u) = u>0 and u*pos or -u*neg ... wait if fx_neg is the measured forward under -rpm (usually negative),
        -- then F = u>=0 and u*fx_pos or (-u)*fx_neg. At u=-1, F=fx_neg.
        -- Linearization F≈u*g with g = (fx_pos - fx_neg)/2 is wrong.
        -- Use iterative: assume sign of u from previous, or solve with pos columns then remap.
        -- Simple Reassembly approach: column = (fx_pos, fy_pos, tz_pos) for motors that thrust mainly forward on +rpm,
        -- and allow u negative meaning reverse using fx_neg as the force at u=-1.
        -- Weighted LS with column_i = 0.5 * (pos - neg_as_force_at_minus1).
        -- Define force_at_plus1 = pos, force_at_minus1 = neg (as measured).
        -- Linear: F(u) = 0.5*(pos+neg) + 0.5*(pos-neg)*u ... at u=1 → pos, u=-1 → neg. Good.
        local fx0 = 0.5 * (fx + fxn)
        local fy0 = 0.5 * (fy + fyn)
        local tz0 = 0.5 * (tz + tzn)
        local fxs = 0.5 * (fx - fxn)
        local fys = 0.5 * (fy - fyn)
        local tzs = 0.5 * (tz - tzn)
        -- Affine term ignored in velocity control LS (bias); use slope columns only.
        cols[i] = { fx = fxs, fy = fys, tz = tzs, bias = { fx = fx0, fy = fy0, tz = tz0 }, t = t }
    end
    return cols
end

--- Solve min ||A u - b|| with soft bounds |u|<=1 via projected iterations.
function wrench.allocate(thrusters, Fx, Fy, Tz, opts)
    opts = opts or {}
    Fx = tonumber(Fx) or 0
    Fy = tonumber(Fy) or 0
    Tz = tonumber(Tz) or 0
    local n = #thrusters
    local duties = {}
    for i = 1, n do
        duties[i] = 0
    end
    if n == 0 then
        return duties
    end

    local pureSurge = math.abs(Fx) >= 0.5 and (math.abs(Fy) + math.abs(Tz)) < 0.25
    local wFx = opts.wFx or 1.0
    local wFy = opts.wFy or 1.0
    local wTz = opts.wTz or (pureSurge and wrench.SURGE_YAW_PENALTY or wrench.YAW_WEIGHT)

    local cols = thrusterColumns(thrusters)

    -- Weighted normal equations: (A^T W A) u = A^T W b
    -- 3 outputs; build Gram matrix n×n
    -- For small n (typical ≤12), use iterative coordinate descent / gradient projection.
    local u = {}
    for i = 1, n do
        u[i] = 0
    end

    local function residual()
        local rx, ry, rz = Fx, Fy, Tz
        for i = 1, n do
            local c = cols[i]
            rx = rx - c.fx * u[i]
            ry = ry - c.fy * u[i]
            rz = rz - c.tz * u[i]
        end
        return rx, ry, rz
    end

    for _ = 1, 40 do
        local rx, ry, rz = residual()
        for i = 1, n do
            local c = cols[i]
            local denom = (wFx * c.fx * c.fx + wFy * c.fy * c.fy + wTz * c.tz * c.tz)
            if denom > 1e-8 then
                local grad = wFx * c.fx * rx + wFy * c.fy * ry + wTz * c.tz * rz
                local step = grad / denom
                u[i] = util.clamp(u[i] + step, -1, 1)
                -- update residual after each coordinate
                rx, ry, rz = residual()
            end
        end
    end

    local dead = opts.deadband or wrench.DEADBAND
    if pureSurge then
        dead = math.max(dead, 0.1)
    end

    for i = 1, n do
        local d = u[i]
        if math.abs(d) < dead then
            d = 0
        end
        -- Extra: on pure surge, zero thrusters with weak |fx| relative to |tz|
        if pureSurge then
            local c = cols[i]
            local mag = math.sqrt(c.fx * c.fx + c.fy * c.fy + c.tz * c.tz)
            if mag > 1e-6 and math.abs(c.fx) / mag < 0.25 and math.abs(d) < 0.35 then
                d = 0
            end
        end
        duties[i] = d
    end
    return duties
end

function wrench.dutiesByName(thrusters, duties)
    local map = {}
    for i, t in ipairs(thrusters) do
        map[t.name] = duties[i] or 0
    end
    return map
end

--- Command from teleop axes: surge, strafe, yaw in [-1,1]
function wrench.fromAxes(thrusters, surge, strafe, yaw, opts)
    return wrench.allocate(thrusters, surge, strafe, yaw, opts)
end

return wrench
