local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local GameConfig = require(ReplicatedStorage.Shared.Configs.GameConfig)
local AgentsConfig = require(ReplicatedStorage.Shared.Configs.AgentsConfig)
local ResearchService = require(script.Parent.ResearchService)

local OrderRequest = ReplicatedStorage.Remotes.Agents.OrderRequest
local FleetChanged = ReplicatedStorage.Remotes.Agents.FleetChanged
local CombatVFX = ReplicatedStorage.Remotes.Agents.CombatVFX

local AgentService = {}

local agents = {} -- [guid] = agent
-- facility = { Guid, Player, Model, Config, SpawnAgent (agentId), SpawnAgentCapacity, NextSpawnAt }
-- Each military facility auto-spawns its single SpawnAgent type for free every
-- TrainTime seconds, up to the facility spawn cap and player's fleet pop cap.
-- Dead ships free capacity, so the facility resumes spawning on the next tick.
local facilities = {} -- [buildingGuid] = facility
local globalTargets = {} -- [player] = Vector3 (the one zone all their ships flow to)
local damageMultipliers = {} -- [player] = mult (zone bonus)
local diedCallbacks = {}
local pvpCheck = nil -- set by ZoneService: fn(agentA, agentB) -> bool
local lastOrder = {} -- [player] = os.clock()

local SPAWN_TICK = 0.5 -- how often facilities check whether they can spawn
local DEFAULT_SPAWN_AGENT_CAPACITY = 2

local ACQUIRE_INTERVAL = 0.5
local ARRIVE_DISTANCE = 3
local LAND_RAY_HEIGHT = 80
local LAND_RAY_DEPTH = 180
local LAND_CLEARANCE = 1.2

local landRaycastParams = RaycastParams.new()
landRaycastParams.FilterType = Enum.RaycastFilterType.Include
landRaycastParams.IgnoreWater = true

local function addIslandMovementSurfaceParts(island, parts)
	local ground = island:WaitForChild("Ground")
	if ground:IsA("BasePart") then
		table.insert(parts, ground)
	end
	local decor = island:FindFirstChild("Decor")
	if not decor then
		return
	end
	for _, descendant in ipairs(decor:GetDescendants()) do
		if descendant:IsA("WedgePart") or descendant:IsA("CornerWedgePart") then
			table.insert(parts, descendant)
		end
	end
end

-- agent = {
--   Guid, Id, Config, Model, Owner (Player or nil = NPC), Health, MaxHealth,
--   Damage, Speed, Range, State ("Building"|"Idle"|"Moving"|"Attacking"|"Dead"),
--   TargetPos (Vector3?), TargetAgent (agent?), LastAttack, LastAcquire,
--   FacilityGuid (string?, source auto-spawning facility),
--   Building (bool?, true while the client assembly animation plays; unit is inert),
--   Home (Vector3?, NPC), LeashRadius (number?, NPC), ZoneId (string?, NPC),
-- }

local function altitudeFor(config)
	return config.Domain == "Air" and GameConfig.AirAltitudeY or GameConfig.SeaLevelY
end

local function landHeightAt(position)
	local result = workspace:Raycast(
		Vector3.new(position.X, LAND_RAY_HEIGHT, position.Z),
		Vector3.new(0, -LAND_RAY_DEPTH, 0),
		landRaycastParams
	)
	return result and result.Position.Y or nil
end

local function movementSurfaceFor(config, position)
	if config.Domain == "Air" then
		return GameConfig.AirAltitudeY, false
	end
	local landY = landHeightAt(position)
	if landY then
		return landY + LAND_CLEARANCE, true
	end
	return altitudeFor(config), false
end

local function setLandChassisVisible(agent, visible)
	if agent.OnLand == visible then
		return
	end
	agent.OnLand = visible
	local chassis = agent.Model:FindFirstChild("LandChassis")
	if not chassis then
		return
	end
	for _, part in ipairs(chassis:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = visible and 0 or 1
		end
	end
end

local function rootPartFor(model)
	local root = model.PrimaryPart or model:FindFirstChild("Hull", true)
	if root and root:IsA("BasePart") then
		return root
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function attachHealthBillboard(agent)
	local rootPart = rootPartFor(agent.Model)
	if not rootPart then
		return
	end
	local billboard = ReplicatedStorage.Shared.Assets.Agents.HealthBillboard:Clone()
	billboard.Name = "HealthBillboard"
	billboard.Adornee = rootPart
	billboard.Parent = rootPart
	agent.HealthBillboard = billboard
end

local function updateHealthBillboard(agent)
	local billboard = agent.HealthBillboard
	if not billboard then
		return
	end
	local back = billboard:FindFirstChild("Back")
	local ratio = if agent.MaxHealth > 0 then math.clamp(agent.Health / agent.MaxHealth, 0, 1) else 0
	if back then
		local fill = back:FindFirstChild("Fill")
		if fill then
			fill.Size = UDim2.fromScale(ratio, 1)
			if ratio > 0.55 then
				fill.BackgroundColor3 = Color3.fromRGB(75, 230, 110)
			elseif ratio > 0.25 then
				fill.BackgroundColor3 = Color3.fromRGB(245, 185, 65)
			else
				fill.BackgroundColor3 = Color3.fromRGB(235, 70, 60)
			end
		end
		local label = back:FindFirstChild("HealthLabel")
		if label then
			label.Text = ("%d/%d"):format(math.ceil(agent.Health), agent.MaxHealth)
		end
	end
end

local function applySurface(agent, position, lookDirection)
	local y, isOnLand = movementSurfaceFor(agent.Config, position)
	local surfacedPosition = Vector3.new(position.X, y, position.Z)
	setLandChassisVisible(agent, isOnLand)
	if (surfacedPosition - position).Magnitude > 0.05 then
		local flatLook = Vector3.new(lookDirection.X, 0, lookDirection.Z)
		if flatLook.Magnitude < 0.1 then
			flatLook = Vector3.new(0, 0, 1)
		end
		agent.Model:PivotTo(CFrame.lookAt(surfacedPosition, surfacedPosition + flatLook.Unit))
	end
	return surfacedPosition
end

function AgentService:GetFleetCap(player)
	return GameConfig.BaseFleetCap + ResearchService:GetSlotBonus(player, "FleetCap")
end

function AgentService:GetFleetPop(player)
	local pop = 0
	for _, agent in pairs(agents) do
		if agent.Owner == player and agent.State ~= "Dead" then
			pop += agent.Config.PopCost
		end
	end
	return pop
end

local function pushFleet(player)
	FleetChanged:FireClient(player, AgentService:GetFleetPop(player), AgentService:GetFleetCap(player))
end

local function spawnAgent(agentId, ownerPlayer, position, npcParams, facilityGuid, buildTime)
	local config = AgentsConfig.Agents[agentId]
	local model = ReplicatedStorage.Shared.Assets.Agents[agentId]:Clone()
	local guid = HttpService:GenerateGUID(false)

	local healthMult, damageMult, speedMult = 1, 1, 1
	if ownerPlayer then
		healthMult = ResearchService:GetUnitStatMultiplier(ownerPlayer, "Health", agentId)
		damageMult = ResearchService:GetUnitStatMultiplier(ownerPlayer, "Damage", agentId)
		speedMult = ResearchService:GetUnitStatMultiplier(ownerPlayer, "Speed", agentId)
	end

	local agent = {
		Guid = guid,
		Id = agentId,
		Config = config,
		Model = model,
		Owner = ownerPlayer,
		MaxHealth = math.floor(config.Health * healthMult),
		Damage = config.Damage * damageMult,
		Speed = config.Speed * speedMult,
		Range = config.Range,
		State = "Idle",
		LastAttack = 0,
		LastAcquire = 0,
		FacilityGuid = facilityGuid,
	}
	agent.Health = agent.MaxHealth
	if npcParams then
		agent.Home = npcParams.Home
		agent.LeashRadius = npcParams.LeashRadius
		agent.ZoneId = npcParams.ZoneId
	end

	model:SetAttribute("Owner", ownerPlayer and ownerPlayer.UserId or 0)
	model:SetAttribute("AgentId", agentId)
	model:SetAttribute("Guid", guid)
	if facilityGuid then
		model:SetAttribute("FacilityGuid", facilityGuid)
	end
	model:SetAttribute("Health", agent.Health)
	model:SetAttribute("MaxHealth", agent.MaxHealth)
	if buildTime and buildTime > 0 then
		-- Hold the unit inert while the client plays the part-by-part assembly
		-- animation. Set before parenting so Constructing/BuildFinishAt land in the
		-- model's initial replication (same Constructing/FinishAt convention as
		-- building construction); the client hides the real model behind its own
		-- tweened visual until BuildFinishAt, then reveals it with a spawn burst.
		agent.Building = true
		agent.State = "Building"
		model:SetAttribute("Constructing", true)
		model:SetAttribute("BuildFinishAt", os.time() + buildTime)
	end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
		end
	end
	local spawnY, isOnLand = movementSurfaceFor(config, position)
	model:PivotTo(CFrame.new(position.X, spawnY, position.Z))
	model.Parent = workspace.Agents
	agent.OnLand = not isOnLand
	setLandChassisVisible(agent, isOnLand)
	attachHealthBillboard(agent)
	updateHealthBillboard(agent)

	agents[guid] = agent
	if ownerPlayer then
		pushFleet(ownerPlayer)
	end
	return agent
end

-- Finish a unit's build: clear the inert state, drop the construction attributes
-- so the client reveals the real model, and run the deferred ready callback
-- (e.g. routing a facility spawn toward the global target).
local function finishBuilding(agent, onReady)
	if agent.State == "Dead" then
		return
	end
	agent.Building = nil
	agent.State = "Idle"
	local model = agent.Model
	if model.Parent then
		model:SetAttribute("Constructing", nil)
		model:SetAttribute("BuildFinishAt", nil)
	end
	if onReady then
		onReady(agent)
	end
end

local function killAgent(agent)
	if agent.State == "Dead" then
		return
	end
	agent.State = "Dead"
	agent.Model:SetAttribute("Health", 0)
	updateHealthBillboard(agent)
	for _, callback in ipairs(diedCallbacks) do
		task.spawn(callback, agent)
	end
	local owner = agent.Owner
	local model = agent.Model
	agents[agent.Guid] = nil
	if owner then
		pushFleet(owner)
	end
	task.delay(2, function()
		model:Destroy()
	end)
end

local function applyDamage(attacker, target)
	local damage = attacker.Damage
	if attacker.Owner then
		damage *= damageMultipliers[attacker.Owner] or 1
	end
	target.Health = math.max(0, target.Health - damage)
	target.Model:SetAttribute("Health", math.floor(target.Health))
	updateHealthBillboard(target)
	CombatVFX:FireAllClients(attacker.Model, target.Model)
	if target.Health <= 0 then
		killAgent(target)
	end
end

local function isHostile(agentA, agentB)
	if agentA == agentB or agentA.State == "Dead" or agentB.State == "Dead" then
		return false
	end
	local ownerA, ownerB = agentA.Owner, agentB.Owner
	if ownerA == ownerB then
		return false
	end
	if ownerA == nil or ownerB == nil then
		return true -- NPC vs any player
	end
	if GameConfig.OpenSeaPvP then
		return true
	end
	return pvpCheck ~= nil and pvpCheck(agentA, agentB)
end

local function horizontalDistance(a, b)
	return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
end

local function acquireTarget(agent)
	local myPos = agent.Model:GetPivot().Position
	local best, bestDistance = nil, agent.Range * 1.5
	for _, other in pairs(agents) do
		if isHostile(agent, other) then
			local distance = horizontalDistance(myPos, other.Model:GetPivot().Position)
			if distance < bestDistance then
				best, bestDistance = other, distance
			end
		end
	end
	return best
end

local function stepAgent(agent, dt, now)
	if agent.Building then
		return -- inert while the client assembly animation plays
	end
	local model = agent.Model
	local pivot = model:GetPivot()
	local position = applySurface(agent, pivot.Position, pivot.LookVector)

	-- NPC leash: snap back home and reset when too far
	if agent.Home and horizontalDistance(position, agent.Home) > agent.LeashRadius then
		agent.TargetAgent = nil
		agent.TargetPos = agent.Home
		agent.Health = agent.MaxHealth
		model:SetAttribute("Health", agent.Health)
		updateHealthBillboard(agent)
		agent.State = "Moving"
	end

	-- validate current combat target
	local target = agent.TargetAgent
	if target and (target.State == "Dead" or not agents[target.Guid]) then
		agent.TargetAgent = nil
		target = nil
		if agent.State == "Attacking" then
			agent.State = agent.TargetPos and "Moving" or "Idle"
		end
	end

	-- auto-acquire
	if not target and now - agent.LastAcquire >= ACQUIRE_INTERVAL then
		agent.LastAcquire = now
		target = acquireTarget(agent)
		if target then
			agent.TargetAgent = target
			agent.State = "Attacking"
		end
	end

	local destination = nil
	if target then
		local targetPos = target.Model:GetPivot().Position
		if horizontalDistance(position, targetPos) <= agent.Range then
			-- in range: face target and fire on cooldown
			local look = Vector3.new(targetPos.X, position.Y, targetPos.Z)
			if (look - position).Magnitude > 0.1 then
				model:PivotTo(CFrame.lookAt(position, look))
			end
			if now - agent.LastAttack >= agent.Config.AttackCooldown then
				agent.LastAttack = now
				applyDamage(agent, target)
			end
			return
		end
		destination = targetPos
	elseif agent.TargetPos then
		destination = agent.TargetPos
		if horizontalDistance(position, destination) <= ARRIVE_DISTANCE then
			agent.TargetPos = nil
			agent.State = "Idle"
			return
		end
	else
		return -- idle
	end

	local flat = Vector3.new(destination.X - position.X, 0, destination.Z - position.Z)
	if flat.Magnitude < 0.1 then
		return
	end
	local step = flat.Unit * math.min(agent.Speed * dt, flat.Magnitude)
	local rawNewPosition = position + step
	local newY, isOnLand = movementSurfaceFor(agent.Config, rawNewPosition)
	local newPosition = Vector3.new(rawNewPosition.X, newY, rawNewPosition.Z)
	setLandChassisVisible(agent, isOnLand)
	model:PivotTo(CFrame.lookAt(newPosition, newPosition + flat.Unit))
end

-- Public API ----------------------------------------------------------------

function AgentService:RegisterFacility(player, model, guid, config)
	facilities[guid] = {
		Guid = guid,
		Player = player,
		Model = model,
		Config = config,
		SpawnAgent = config.SpawnAgent,
		SpawnAgentCapacity = config.SpawnAgentCapacity or DEFAULT_SPAWN_AGENT_CAPACITY,
		-- Start the first build immediately: the unit assembles over its TrainTime
		-- right away rather than waiting a full TrainTime before it even appears.
		NextSpawnAt = config.SpawnAgent and os.clock() or nil,
	}
end

function AgentService:UnregisterFacility(guid)
	facilities[guid] = nil
end

-- Send a single agent toward the player's current global target, if one is set.
local function routeToTarget(agent)
	local target = agent.Owner and globalTargets[agent.Owner]
	if target then
		agent.TargetAgent = nil
		agent.TargetPos = target
		agent.State = "Moving"
	end
end

local function getFacilitySpawnedAgentCount(facilityGuid)
	local count = 0
	for _, agent in pairs(agents) do
		if agent.FacilityGuid == facilityGuid and agent.State ~= "Dead" then
			count += 1
		end
	end
	return count
end

-- Facility auto-spawn: each tick, any facility whose owner is under their pop cap
-- and facility spawn cap spawns its single unit for free and routes it to the
-- global target. Being at either cap simply defers the spawn (the timer is only
-- advanced once a unit is produced), so a death that frees capacity lets production
-- resume on the next eligible tick.
local function tickFacilities(now)
	for _, facility in pairs(facilities) do
		local agentId = facility.SpawnAgent
		if agentId and now >= facility.NextSpawnAt then
			local player = facility.Player
			local config = AgentsConfig.Agents[agentId]
			if player.Parent and facility.Model.Parent then
				local hasFacilityCapacity = getFacilitySpawnedAgentCount(facility.Guid) < facility.SpawnAgentCapacity
				if hasFacilityCapacity and AgentService:GetFleetPop(player) + config.PopCost <= AgentService:GetFleetCap(player) then
					-- The unit assembles for the whole TrainTime: it spawns inert and
					-- visibly builds across the cooldown, going active exactly when the
					-- next build begins (no separate build-time tuning).
					local buildTime = config.TrainTime
					local agent = spawnAgent(
						agentId,
						player,
						facility.Model.PrimaryPart.AgentSpawn.WorldPosition,
						nil,
						facility.Guid,
						buildTime
					)
					if buildTime and buildTime > 0 then
						task.delay(buildTime, finishBuilding, agent, routeToTarget)
					else
						routeToTarget(agent)
					end
					facility.NextSpawnAt = now + config.TrainTime
				end
				-- at cap: leave NextSpawnAt in the past so we retry next tick
			end
		end
	end
end

function AgentService:SetDamageMultiplier(player, mult)
	damageMultipliers[player] = mult ~= 1 and mult or nil
end

function AgentService:SetPvPCheck(fn)
	pvpCheck = fn
end

function AgentService:OnAgentDied(callback)
	table.insert(diedCallbacks, callback)
end

function AgentService:SpawnNpc(agentId, position, npcParams)
	return spawnAgent(agentId, nil, position, npcParams)
end

function AgentService:Despawn(agent)
	if agents[agent.Guid] then
		agents[agent.Guid] = nil
		agent.State = "Dead"
		agent.Model:Destroy()
	end
end

function AgentService:GetAgentsInRadius(position, radius)
	local found = {}
	for _, agent in pairs(agents) do
		if horizontalDistance(agent.Model:GetPivot().Position, position) <= radius then
			table.insert(found, agent)
		end
	end
	return found
end

local function getPlayerAgents(player)
	local list = {}
	for _, agent in pairs(agents) do
		if agent.Owner == player and agent.State ~= "Dead" then
			table.insert(list, agent)
		end
	end
	return list
end

function AgentService:SetGlobalTarget(player, position)
	globalTargets[player] = position
	local fleet = getPlayerAgents(player)

	-- loose formation grid around the target point
	local columns = math.ceil(math.sqrt(#fleet))
	local spacing = 6
	for index, agent in ipairs(fleet) do
		local row = math.floor((index - 1) / columns)
		local col = (index - 1) % columns
		local offset = Vector3.new(
			(col - (columns - 1) / 2) * spacing,
			0,
			row * spacing
		)
		agent.TargetAgent = nil
		agent.TargetPos = position + offset
		agent.State = "Moving"
	end
	return #fleet
end

-- Remote handlers -----------------------------------------------------------

local function onOrderRequest(player, orderType)
	local now = os.clock()
	if lastOrder[player] and now - lastOrder[player] < 0.2 then
		return
	end
	lastOrder[player] = now

	if orderType == "Stop" then
		globalTargets[player] = nil
		for _, agent in ipairs(getPlayerAgents(player)) do
			agent.TargetPos = nil
			if agent.TargetAgent then
				agent.State = "Attacking"
			else
				agent.State = "Idle"
			end
		end
	end
end

function AgentService:Init()
	local islandMovementSurfaceParts = {}
	for _, island in ipairs(workspace:WaitForChild("Map"):WaitForChild("Islands"):GetChildren()) do
		addIslandMovementSurfaceParts(island, islandMovementSurfaceParts)
	end
	landRaycastParams.FilterDescendantsInstances = islandMovementSurfaceParts

	OrderRequest.OnServerEvent:Connect(onOrderRequest)

	Players.PlayerRemoving:Connect(function(player)
		for _, agent in pairs(agents) do
			if agent.Owner == player then
				AgentService:Despawn(agent)
			end
		end
		damageMultipliers[player] = nil
		globalTargets[player] = nil
		lastOrder[player] = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		tickFacilities(now)
		for _, agent in pairs(agents) do
			stepAgent(agent, dt, now)
		end
	end)
end

return AgentService
