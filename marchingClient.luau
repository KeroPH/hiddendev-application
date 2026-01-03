--[[
	Marching Client Script
	Controls character formation, animation synchronization, and marching mechanics
	Features: Character recruitment (supports npc and players), formation positioning, animation capture, post-locking
]]

-- Services and dependencies
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local MouseModule = require(script:WaitForChild("MouseModule"))
local Trove = require(script:WaitForChild("Trove")) -- Memory management utility

-- Remote events for server communication
local MarchingEvent = ReplicatedStorage:WaitForChild("MarchingEvent") -- Reliable event for critical actions
local UnreliableMarchingEvent = ReplicatedStorage:WaitForChild("UnreliableMarchingEvent") -- For frequent updates like animation sync

-- UI references
local LocalPlayer = Players.LocalPlayer
local PlayerMouse = LocalPlayer:GetMouse()
local UI = script.marchUI
local Frame = UI:WaitForChild("Frame")

local AdvancedAccessFrame = Frame:WaitForChild("advancedFrame"):WaitForChild("advancedAccessFrame")
local AccessFrame = Frame:WaitForChild("mainFrame"):WaitForChild("accessFrame")
local animationsList = Frame:WaitForChild("animationsList")

local Tool = script.Parent

-- Visual indicator for hovering over characters during recruitment/post-locking
local Highlight = Instance.new("Highlight")
Highlight.FillTransparency = 1
Highlight.Parent = UI

-- Central table for state management (keeps track of character recruitment, post-locking, animation capture, etc.)
local MarchingFlags = {
	PostLockedCharacters = {}, -- Characters locked to specific positions relative to leader
	Characters = {}, -- Array of recruited characters following the leader
	CharacterTweens = {}, -- Active rotation tweens for character alignment
	CachedAnimationsData = {}, -- Previous animation states for delta detection
	CharacterTroves = {}, -- Cleanup handlers for each character
	LastMovingCharacterSpeed = {}, -- Tracks speed changes to sync movement with server
	IgnoredAnimations = {}, -- Animation IDs excluded from capture
	UIShown = true,
	HelpEnabled = false,
	MarchingEnabled = true, -- Whether characters actively follow in formation
	BetaEnabled = false, -- Alternative formation algorithm (follow-the-leader)
	RecruitingEnabled = false, -- Mode for recruiting/disbanding characters
	PostLockingEnabled = false, -- Mode for locking characters to specific positions
	TurningEnabled = false, -- Auto-rotate characters to match leader's facing
	CaptureAnimationEnabled = false -- Sync playing animations to recruited characters
}
local MarchingModule = {}
-- Updates all formation parameters from UI inputs and refreshes UI state
-- Called whenever settings change (such as button clicks on the UI) or mode toggles occur
function MarchingModule:Update()
	-- Read formation parameters from UI text inputs with fallback defaults
	MarchingFlags.horizontal = tonumber(AccessFrame.horizontal.Text) or 5 -- Distance between ranks (front-to-back)
	MarchingFlags.vertical = tonumber(AccessFrame.vertical.Text) or 5 -- Distance between files (side-to-side)
	MarchingFlags.ranks = tonumber(AccessFrame.ranks.Text) or 2 -- Number of characters per rank (row)
	MarchingFlags.delay = tonumber(AccessFrame.delay.Text) or 4 -- Initial offset from leader
	MarchingFlags.sideOffset = tonumber(AccessFrame.sideOffset.Text) or 0.5 -- Multiplier for file spacing
	MarchingFlags.walkspeed = tonumber(AccessFrame.walkspeed.Text) or 16 -- Base walk speed for formation
	MarchingFlags.middle = tonumber(AccessFrame.middle.Text) or 0 -- Center offset for left/right split

	-- Update UI value labels to reflect current settings
	AccessFrame.horizontal.valueLabel.Text = MarchingFlags.horizontal
	AccessFrame.vertical.valueLabel.Text = MarchingFlags.vertical
	AccessFrame.ranks.valueLabel.Text = MarchingFlags.ranks
	AccessFrame.delay.valueLabel.Text = MarchingFlags.delay
	AccessFrame.sideOffset.valueLabel.Text = MarchingFlags.sideOffset
	AccessFrame.walkspeed.valueLabel.Text = MarchingFlags.walkspeed
	AccessFrame.middle.valueLabel.Text = MarchingFlags.middle

	-- Update button text to reflect current mode states
	AccessFrame.march.Text = MarchingFlags.MarchingEnabled and "MARCHING" or "HALTED"
	AccessFrame.recruit.Text = MarchingFlags.RecruitingEnabled and "RECRUITING/DISBANDING" or "RECRUIT/DISBAND"
	AccessFrame.postLock.Text = MarchingFlags.PostLockingEnabled and "POST. LOCKING" or "POST. LOCK"
	AccessFrame.beta.Text = MarchingFlags.BetaEnabled and "BETA ENABLED" or "BETA DISABLED"
	AccessFrame.turning.Text = MarchingFlags.TurningEnabled and "TURNING" or "TURN"
	AccessFrame.turning.AutoButtonColor = MarchingFlags.TurningEnabled
	AdvancedAccessFrame.captureAnimation.Text = MarchingFlags.CaptureAnimationEnabled and "CAPTURING" or "CAPTURE DISABLED"
	AdvancedAccessFrame.positionCharacter.Text = MarchingFlags.PositioningCharacter and "POSITIONING CHARACTER" or "POSITION CHARACTER"
	AdvancedAccessFrame.resetPositionCharacter.Visible = MarchingFlags.PositioningCharacterOffset and true or false
	AdvancedAccessFrame.positionCharacter.Visible = not AdvancedAccessFrame.resetPositionCharacter.Visible
	AdvancedAccessFrame.aboutTurn.Visible = not AdvancedAccessFrame.resetPositionCharacter.Visible

	animationsList.Visible = MarchingFlags.CaptureAnimationEnabled
end
-- Button handlers mapped by button name
-- Each function is called when the corresponding GUI button is clicked, for easier management
MarchingModule.ButtonClicked = {
	-- Apply button: Refreshes UI and re-reads inputs
	apply = function()
		MarchingModule:Update()
	end,
	-- Show/hide main UI panel with slide animation
	showButton = function()
		MarchingFlags.UIShown = not MarchingFlags.UIShown
		TweenService:Create(
			Frame,
			TweenInfo.new(0.5),
			{Position = MarchingFlags.UIShown and UDim2.fromScale(0.157, 0.658) or UDim2.fromScale(0, 0.658)}
		):Play()
	end,
	-- Toggle contextual help tooltips on mouse hover
	help = function()
		MarchingFlags.HelpEnabled = not MarchingFlags.HelpEnabled

		-- Clean up existing help connections
		if MarchingFlags.HelpTrove then
			MarchingFlags.HelpTrove:Destroy()
			MarchingFlags.HelpTrove = nil
		end

		-- Set up help tooltip system
		if MarchingFlags.HelpEnabled then
			MarchingFlags.HelpTrove = Trove.new()
			MarchingFlags.HelpTrove:Add(
				function()
					UI.helpText.Visible = false
				end
			)
			-- Connect help tooltips to all UI elements with Help attribute
			for _, uiBase in pairs(UI:GetDescendants()) do
				local helpAttribute = uiBase:GetAttribute("Help")
				if helpAttribute then
					MarchingFlags.HelpTrove:Add(
						uiBase.MouseEnter:Connect(
							function()
								UI.helpText.Text = helpAttribute
								UI.helpText.Position = UDim2.fromOffset(PlayerMouse.X, PlayerMouse.Y)
								UI.helpText.Visible = true
							end
						)
					)
					MarchingFlags.HelpTrove:Add(
						uiBase.MouseLeave:Connect(
							function()
								UI.helpText.Visible = false
							end
						)
					)
				end
			end
		end
	end,
	-- Toggle recruiting mode (mutually exclusive with post-locking)
	recruit = function()
		MarchingFlags.RecruitingEnabled = not MarchingFlags.RecruitingEnabled
		MarchingFlags.PostLockingEnabled = false
		MarchingModule:Update()
	end,
	-- Remove all recruited characters from formation
	disbandAll = function()
		MarchingEvent:FireServer("DisbandAll")
		MarchingFlags.Characters = {}
		MarchingModule:Update()
	end,
	-- Toggle post-locking mode (mutually exclusive with recruiting)
	postLock = function()
		MarchingFlags.PostLockingEnabled = not MarchingFlags.PostLockingEnabled
		MarchingFlags.RecruitingEnabled = false
		MarchingModule:Update()
	end,
	-- Toggle beta formation algorithm (follow-the-leader vs grid formation)
	beta = function()
		MarchingFlags.BetaEnabled = not MarchingFlags.BetaEnabled
		MarchingModule:Update()
	end,
	-- Toggle marching on/off (halt/resume formation movement)
	march = function()
		MarchingFlags.MarchingEnabled = not MarchingFlags.MarchingEnabled
		MarchingModule:Update()
	end,
	-- Toggle automatic character rotation to match leader's facing
	turning = function()
		MarchingFlags.TurningEnabled = not MarchingFlags.TurningEnabled
		MarchingModule:Update()
	end,
	-- Toggle advanced options panel visibility
	advanced = function()
		Frame.advancedFrame.Visible = not Frame.advancedFrame.Visible
	end,
	-- Toggle animation capture mode (syncs leader's animations to followers)
	captureAnimation = function()
		MarchingFlags.CaptureAnimationEnabled = not MarchingFlags.CaptureAnimationEnabled
		MarchingModule:Update()
	end,
	-- Request server to clone leader's character appearance to followers
	cloneCharacter = function()
		MarchingEvent:FireServer("CloneCharacter")
	end,
	-- Request server to clone leader's currently equipped tool to followers
	cloneTool = function()
		MarchingEvent:FireServer("CloneTool")
	end,
	-- Request server to remove tools from all recruited characters
	removeTools = function()
		MarchingEvent:FireServer("RemoveTools")
	end,
	-- Allows leader to reposition themselves while maintaining formation relative offset
	positionCharacter = function()
		MarchingFlags.PositioningCharacter = not MarchingFlags.PositioningCharacter

		if MarchingFlags.PositioningCharacter then
			-- Save starting position and pause marching
			MarchingFlags.LastPositioningCFrame = LocalPlayer.Character.HumanoidRootPart:GetPivot()

			MarchingFlags.MarchingEnabled = false
		else
			-- Calculate offset and resume marching with new position
			MarchingFlags.PositioningCharacterOffset =
				LocalPlayer.Character.HumanoidRootPart:GetPivot():ToObjectSpace(MarchingFlags.LastPositioningCFrame)

			MarchingFlags.MarchingEnabled = true
		end
		MarchingModule:Update()
	end,
	-- Clear any position offset applied to the leader
	resetPositionCharacter = function()
		MarchingFlags.PositioningCharacter = false
		MarchingFlags.LastPositioningCFrame = nil
		MarchingFlags.PositioningCharacterOffset = nil
		MarchingModule:Update()
	end,
	-- Instantly rotate leader 180 degrees (military "about face")
	aboutTurn = function()
		local localCFrame = LocalPlayer.Character.HumanoidRootPart:GetPivot()
		local reverseCFrame = CFrame.lookAt(localCFrame.Position, (localCFrame.Position - localCFrame.LookVector))

		LocalPlayer.Character.HumanoidRootPart:PivotTo(reverseCFrame)

		MarchingFlags.PositioningCharacterOffset = reverseCFrame:ToObjectSpace(localCFrame)
		MarchingFlags.LastPositioningCFrame = nil

		MarchingModule:Update()
	end
}

-- This is for dynamic walkspeed adjustment based on distance from target, for smooother movement
-- Maps distance ratio to speed offset: closer = slower movement, farther = faster movement
local thisNumberSequence = NumberSequence.new({NumberSequenceKeypoint.new(0, -20), NumberSequenceKeypoint.new(1, 25)})
local function evalNumberSequence(time)
	local sequence = thisNumberSequence
	-- If time is 0 or 1, return the first or last value respectively
	if time == 0 then
		return sequence.Keypoints[1].Value
	elseif time == 1 then
		return sequence.Keypoints[#sequence.Keypoints].Value
	end

	-- Otherwise, step through each sequential pair of keypoints
	for i = 1, #sequence.Keypoints - 1 do
		local currKeypoint = sequence.Keypoints[i]
		local nextKeypoint = sequence.Keypoints[i + 1]
		if time >= currKeypoint.Time and time < nextKeypoint.Time then
			-- Calculate how far alpha lies between the points
			local alpha = (time - currKeypoint.Time) / (nextKeypoint.Time - currKeypoint.Time)
			-- Return the value between the points using alpha
			return currKeypoint.Value + (nextKeypoint.Value - currKeypoint.Value) * alpha
		end
	end
	-- Fallback return for edge cases
	return sequence.Keypoints[#sequence.Keypoints].Value
end

local lastUpdate = 0
-- Heartbeat-driven processing functions
-- These run every frame to handle real-time interactions and formation updates
MarchingModule.ProcessHeartbeat = {
	-- Handles visual highlighting (Highlight instances) during recruiting mode
	OnRecruitingEnabled = function()
		if not MarchingFlags.RecruitingEnabled then
			if MarchingFlags.RecruitingTrove then
				MarchingFlags.RecruitingTrove:Destroy()
				MarchingFlags.RecruitingTrove = nil
			end
			return
		end
		if not MarchingFlags.RecruitingTrove then
			MarchingFlags.RecruitingTrove = Trove.new()
			MarchingFlags.RecruitingTrove:Add(
				function()
					Highlight.Adornee = nil
				end
			)
		end

		-- Raycast to find humanoid character under mouse
		local character = MouseModule:RaycastHumanoidCharacter()
		local marchingOwner = character and character:GetAttribute("MarchingOwner")

		-- Don't highlight characters owned by others or the local player themselves
		if (marchingOwner and marchingOwner ~= LocalPlayer.UserId) or character == LocalPlayer.Character then
			Highlight.Adornee = nil
			return
		end

		-- Green = already recruited (can disband), Red = not recruited (can recruit)
		Highlight.OutlineColor = marchingOwner and Color3.fromRGB(132, 255, 55) or Color3.fromRGB(255, 74, 74)
		Highlight.Adornee = character
	end,
	-- Handles visual highlighting during post-locking mode
	OnPostLockingEnabled = function()
		if not MarchingFlags.PostLockingEnabled then
			if MarchingFlags.PostLockingTrove then
				MarchingFlags.PostLockingTrove:Destroy()
				MarchingFlags.PostLockingTrove = nil
			end
			return
		end
		if not MarchingFlags.PostLockingTrove then
			MarchingFlags.PostLockingTrove = Trove.new()
			MarchingFlags.PostLockingTrove:Add(
				function()
					Highlight.Adornee = nil
				end
			)
		end

		-- If currently positioning a post-lock, highlight it in yellow
		if MarchingFlags.CurrentPostLocking then
			Highlight.OutlineColor = Color3.fromRGB(255, 244, 84)
			Highlight.Adornee = MarchingFlags.CurrentPostLocking
			return
		end

		-- Otherwise highlight character under mouse: dark red if already locked, green if not
		local character = MouseModule:RaycastHumanoidCharacter()
		Highlight.Adornee = character
		Highlight.OutlineColor =
			character and MarchingFlags.PostLockedCharacters[character] and Color3.fromRGB(116, 24, 24) or
			Color3.fromRGB(62, 124, 40)
	end,
	-- Captures and synchronizes playing animations from leader to followers
	-- Detects new animations, tracks changes, and sends updates to server
	OnCaptureAnimationEnabled = function()
		if MarchingFlags.CaptureAnimationEnabled then
			local animator = LocalPlayer.Character.Humanoid.Animator
			local capturedAnimationsData = {}
			local sendToServer = false
			-- Loop through all currently playing animation tracks
			for _, playingTrack in pairs(animator:GetPlayingAnimationTracks()) do
				local animId = playingTrack.Animation.AnimationId
				-- Set up one-time event listener for when animation ends
				if not playingTrack:GetAttribute("AnimationEndConnected") then
					playingTrack:SetAttribute("AnimationEndConnected", true)
					playingTrack.Ended:Connect(
						function()
							local thisDat = {
								[animId] = {
									Ended = true
								}
							}
							UnreliableMarchingEvent:FireServer("AnimationCapture", thisDat)
						end
					)
				end

				-- Skip animations the user has marked to ignore
				if not MarchingFlags.IgnoredAnimations[animId] then
					-- Create UI button for this animation if it doesn't exist
					if not animationsList.ScrollingFrame:FindFirstChild(animId) then
						local newButton = animationsList.ScrollingFrame.sample:Clone()
						newButton.Name = animId
						newButton.Text = playingTrack.Animation.Name
						newButton.MouseButton1Click:Connect(
							function()
								local animIndex = table.find(MarchingFlags.IgnoredAnimations, animId)
								if MarchingFlags.IgnoredAnimations[animId] then
									--table.remove(MarchingFlags.IgnoredAnimations, animIndex)
									MarchingFlags.IgnoredAnimations[animId] = nil
									newButton.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
								else
									newButton.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
									MarchingFlags.IgnoredAnimations[animId] = true
									--table.insert(MarchingFlags.IgnoredAnimations, animId)

									UnreliableMarchingEvent:FireServer(
										"AnimationCapture",
										{
											[animId] = {
												Ignore = true
											}
										}
									)
								end
							end
						)
						newButton.Visible = true
						newButton.Parent = animationsList.ScrollingFrame
						-- Auto-ignore default character animations from Animate script
						if playingTrack.Animation:IsDescendantOf(LocalPlayer.Character.Animate) then
							newButton.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
							MarchingFlags.IgnoredAnimations[animId] = true
							--table.insert(MarchingFlags.IgnoredAnimations, animId)
						else
							capturedAnimationsData[animId] = {
								Speed = playingTrack.Speed,
								TimePosition = playingTrack.TimePosition
							}
							MarchingFlags.CachedAnimationsData[animId] = {
								Speed = playingTrack.Speed,
								TimePosition = playingTrack.TimePosition
							}
							sendToServer = true
						end
					else
						-- Compare with cached data to detect changes (delta detection)
						capturedAnimationsData[animId] = {
							Speed = playingTrack.Speed,
							TimePosition = playingTrack.TimePosition
						}
						if MarchingFlags.CachedAnimationsData and MarchingFlags.CachedAnimationsData[animId] then
							if
								MarchingFlags.CachedAnimationsData[animId].Speed == playingTrack.Speed and
								MarchingFlags.CachedAnimationsData[animId].TimePosition == playingTrack.TimePosition
							then
								capturedAnimationsData[animId] = nil
							else
							end
						end
						MarchingFlags.CachedAnimationsData[animId] = {
							Speed = playingTrack.Speed,
							TimePosition = playingTrack.TimePosition
						}

						if capturedAnimationsData[animId] then
							sendToServer = true
						end
					end
				end
			end

			-- Send animation updates to server (unreliable remoteevent for performance and ease server-client communcation)
			if sendToServer then
				UnreliableMarchingEvent:FireServer("AnimationCapture", capturedAnimationsData)
			end
		end
	end,
	-- Core formation movement logic - runs every frame to position recruited characters
	-- Supports both grid formation and beta (follow-the-leader) formation
	OnMarchingEnabled = function()
		local sideVector = Vector2.new(MarchingFlags.ranks, MarchingFlags.horizontal)
		local localCFrame = LocalPlayer.Character.HumanoidRootPart:GetPivot()
		-- Apply position offset if leader has been repositioned
		if MarchingFlags.PositioningCharacterOffset then
			localCFrame = localCFrame:ToWorldSpace(MarchingFlags.PositioningCharacterOffset)
		end
		local SequenceMarchCharacters = {}

		-- Sync character movement states to server (throttled to 0.1s intervals)
		if tick() - lastUpdate >= 0.1 then
			lastUpdate = tick()

			local movingCharacters = {}
			for _, character in pairs(MarchingFlags.Characters) do
				if character then
					local speedLog = character:GetAttribute("RunningSpeedLog", character) or 0

					if MarchingFlags.LastMovingCharacterSpeed[character] ~= speedLog then
						table.insert(movingCharacters, {character, speedLog})
					end
					MarchingFlags.LastMovingCharacterSpeed[character] = speedLog
				end
			end
			if #movingCharacters > 0 then
				UnreliableMarchingEvent:FireServer("Moving", movingCharacters)
			end
		end

		-- Position each recruited character
		local characterCount = 0
		for i, character in pairs(MarchingFlags.Characters) do
			local humanoid = character:IsDescendantOf(workspace) and character:FindFirstChild("Humanoid")
			if not humanoid then
				-- Clean up characters that have been removed
				local thisIndex = table.find(MarchingFlags.Characters, character)
				if thisIndex then
					table.remove(MarchingFlags.Characters, thisIndex)
				end
			else
				if MarchingFlags.MarchingEnabled then
					local targetCFrame

					-- Post-locked characters move to their locked position
					if MarchingFlags.PostLockedCharacters[character] then
						targetCFrame = localCFrame:ToWorldSpace(MarchingFlags.PostLockedCharacters[character])

						local cframe = character.PrimaryPart.CFrame:ToObjectSpace(targetCFrame)

						-- If close enough and facing forward, stop moving
						if cframe.Z > 0 and (character:GetPivot().Position - targetCFrame.Position).Magnitude <= 2 then
							targetCFrame = character:GetPivot()
						end
					else
						characterCount = characterCount + 1

						-- Beta formation: follow-the-leader (each character follows the one in front)
						if MarchingFlags.BetaEnabled and characterCount > MarchingFlags.ranks then
							local prevCharacterCFrame =
								SequenceMarchCharacters[characterCount - MarchingFlags.ranks].HumanoidRootPart.CFrame

							targetCFrame =
								prevCharacterCFrame + (prevCharacterCFrame.LookVector * -(MarchingFlags.horizontal))

							-- Align first few characters with leader's plane
							if characterCount <= 2 then
								local plane = {
									["a"] = localCFrame.Position,
									["n"] = -localCFrame.LookVector
								}

								local t =
									plane["n"]:Dot(plane["a"] - targetCFrame.Position) /
									plane["n"]:Dot(targetCFrame.LookVector)

								targetCFrame = CFrame.new(targetCFrame.Position + targetCFrame.LookVector * t)
							end
						else
							-- Grid formation: arrange characters in ranks and files
							targetCFrame =
								localCFrame +
								((localCFrame.RightVector * (MarchingFlags.vertical * MarchingFlags.sideOffset)) +
									(localCFrame.LookVector * -(MarchingFlags.delay)))

							targetCFrame =
								targetCFrame +
								(localCFrame.LookVector *
									(MarchingFlags.horizontal * (sideVector.Y - MarchingFlags.horizontal))) +
								(localCFrame.RightVector *
									(-MarchingFlags.vertical * (MarchingFlags.ranks - sideVector.X)))

							-- Apply center split offset for left/right sides
							if sideVector.X - 1 >= (MarchingFlags.ranks / 2) then
								targetCFrame = targetCFrame + (localCFrame.RightVector * (MarchingFlags.middle * 1))
							else
								targetCFrame = targetCFrame + (localCFrame.RightVector * (MarchingFlags.middle * -1))
							end

							local cframe = character.PrimaryPart.CFrame:ToObjectSpace(targetCFrame)
							if cframe.Z > 0 and (character:GetPivot().Position - targetCFrame.Position).Magnitude <= 2 then
								targetCFrame = character:GetPivot()
							end

							-- Update grid position for next character
							sideVector = sideVector + Vector2.new(-1, 0)

							if characterCount % MarchingFlags.ranks == 0 then
								sideVector = sideVector + Vector2.new(MarchingFlags.ranks, -1)
							end
						end

						table.insert(SequenceMarchCharacters, character)
					end
					local targetPosition = Vector3.new(targetCFrame.X, localCFrame.Position.Y, targetCFrame.Z)

					humanoid:MoveTo(targetPosition)

					-- Dynamic walkspeed based on distance (farther = faster, closer = slower)
					local distanceFromTarget = (character.HumanoidRootPart.Position - targetPosition).Magnitude

					local walkspeedAlpha = evalNumberSequence(math.clamp((distanceFromTarget / 5), 0, 0.8))
					local function Lerp(num, goal, i)
						return num + (goal - num) * i
					end

					character.Humanoid.WalkSpeed =
						Lerp(character.Humanoid.WalkSpeed, MarchingFlags.walkspeed + walkspeedAlpha, 0.5)

					-- Auto-rotate character to face leader's direction when stationary
					coroutine.resume(
						coroutine.create(
							function()
								task.wait(.1)
								if
									character.HumanoidRootPart.Velocity.Magnitude < .5 and
									(character.HumanoidRootPart.Position - targetPosition).Magnitude <= .5 and
									character.HumanoidRootPart.CFrame.LookVector:Dot(localCFrame.LookVector) < 1
								then
									local localPlayerCFrame = LocalPlayer.Character.HumanoidRootPart.CFrame
									--MarchingFlags.CharacterTweens[character] = TweenService:Create(character.HumanoidRootPart, TweenInfo.new(.5), {CFrame = CFrame.new(character.HumanoidRootPart.CFrame.Position, character.HumanoidRootPart.Position + localCFrame.LookVector)})
									MarchingFlags.CharacterTweens[character] =
										TweenService:Create(
											character.HumanoidRootPart,
											TweenInfo.new(.5),
											{
												CFrame = CFrame.new(character.HumanoidRootPart.CFrame.Position) *
												localPlayerCFrame.Rotation
											}
										)
									MarchingFlags.CharacterTweens[character]:Play()
								elseif MarchingFlags.CharacterTweens[character] then
									MarchingFlags.CharacterTweens[character]:Cancel()
									MarchingFlags.CharacterTweens[character] = nil
								end
							end
						)
					)
				elseif MarchingFlags.TurningEnabled then
					-- If marching disabled but turning enabled, just rotate to face leader
					TweenService:Create(
						character.HumanoidRootPart,
						TweenInfo.new(.5),
						{
							CFrame = CFrame.new(
								character.HumanoidRootPart.CFrame.Position,
								character.HumanoidRootPart.Position + localCFrame.LookVector
							)
						}
					):Play()
				end
			end
		end
	end
}
-- Mouse click handlers for recruiting and post-locking modes
MarchingModule.ProcessButton1Down = {
	-- Click handler for recruiting/disbanding characters
	ClickRecruitingEnabled = function()
		if not MarchingFlags.RecruitingEnabled then
			return
		end

		local character = Highlight.Adornee
		if not character then
			return
		end

		local marchingOwner = character:GetAttribute("MarchingOwner")
		if marchingOwner and marchingOwner ~= LocalPlayer.UserId then
			return
		end

		-- Determine action based on ownership state
		local action = marchingOwner == LocalPlayer.UserId and "Disband" or "Recruit"
		MarchingEvent:FireServer(action, character)

		-- Remove from local array if disbanding
		if action == "Disband" then
			local index = table.find(MarchingFlags.Characters, character)
			table.remove(MarchingFlags.Characters, index)
		end
	end,
	-- Click handler for post-locking characters to specific positions
	ClickPostLockingEnabled = function()
		if not MarchingFlags.PostLockingEnabled then
			return
		end
		-- If in positioning mode, finalize the post-lock position
		if MarchingFlags.CurrentPostLocking then
			local localCFrame = LocalPlayer.Character.HumanoidRootPart.CFrame
			if MarchingFlags.PositioningCharacterOffset then
				localCFrame = localCFrame:ToWorldSpace(MarchingFlags.PositioningCharacterOffset)
			end

			-- Store position relative to leader
			MarchingFlags.PostLockedCharacters[MarchingFlags.CurrentPostLocking] =
				localCFrame:ToObjectSpace(PlayerMouse.Hit)
			-- Move character to end of array for render order
			local characterIndex = table.find(MarchingFlags.Characters, MarchingFlags.CurrentPostLocking)
			table.remove(MarchingFlags.Characters, characterIndex)
			table.insert(MarchingFlags.Characters, MarchingFlags.CurrentPostLocking)
			MarchingFlags.CurrentPostLocking = nil
		else
			-- Start positioning or unlock existing post-lock
			local character = Highlight.Adornee
			if not character then
				return
			end
			if MarchingFlags.PostLockedCharacters[character] then
				MarchingFlags.PostLockedCharacters[character] = nil
			else
				MarchingFlags.CurrentPostLocking = character
			end
		end
	end
}

-- Handle server-to-client events (notifications and character recruitment)
MarchingEvent.OnClientEvent:Connect(
	function(action, arg1, arg2)
		if action == "Notification" then
			-- Display notification message with animation
			local newSample = UI.Notification.sample:Clone()
			newSample.Name = arg1
			newSample.Text = arg1
			newSample.Parent = UI.Notification

			TweenService:Create(newSample, TweenInfo.new(0.2), {Size = UDim2.fromScale(1, 0.025)}):Play()

			task.delay(
				1,
				function()
					TweenService:Create(newSample, TweenInfo.new(0.2), {Size = UDim2.fromScale(1, 0)}):Play()
					task.wait(0.2)
					newSample:Destroy()
					newSample = nil
				end
			)
		elseif action == "AddRecruit" then
			if table.find(MarchingFlags.Characters, arg1) then
				return
			end
			table.insert(MarchingFlags.Characters, arg1)
			MarchingFlags.CharacterTroves[arg1] = Trove.new()
			MarchingFlags.CharacterTroves[arg1]:Add(
				arg1:WaitForChild("Humanoid").Running:Connect(
					function(speed)
						if not table.find(MarchingFlags.Characters, arg1) then
							if MarchingFlags.CharacterTroves[arg1] then
								MarchingFlags.CharacterTroves[arg1]:Destroy()
								MarchingFlags.CharacterTroves[arg1] = nil
								return
							end
						end

						arg1:SetAttribute("RunningSpeedLog", speed)
					end
				)
			)
		end
	end
)

-- Connect mouse click events to process click handlers
PlayerMouse.Button1Down:Connect(function()
    if not LocalPlayer.Character or not LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
        return
    end
    for processName, processFunction in pairs(MarchingModule.ProcessButton1Down) do
        processFunction()
    end
end)

-- Main heartbeat loop - processes all per-frame updates
RunService.Heartbeat:Connect(function()
    if not LocalPlayer.Character or not LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
        return
    end
    for processName, processFunction in pairs(MarchingModule.ProcessHeartbeat) do
        processFunction()
    end
end)

-- Auto-connect all GUI buttons based on their names
for _, button in pairs(UI:GetDescendants()) do
	if button:IsA("GuiButton") then
		button.MouseButton1Click:Connect(
			function()
				if MarchingModule.ButtonClicked[button.Name] then
					MarchingModule.ButtonClicked[button.Name]()
				end
			end
		)
	end
end

-- Clicking while equipping tool toggles UI visibility
Tool.Activated:Connect(function()
    if UI:IsDescendantOf(LocalPlayer.PlayerGui) then
        UI.Parent = script
    else
        UI.Parent = LocalPlayer.PlayerGui
    end

    LocalPlayer.Character.Humanoid:UnequipTools()
end)

-- Initialize UI with current settings
MarchingModule:Update()
