local ADDON, NS = ...
local SOUL_SHARD_ID = 6265

-- Cache frequent globals for 3.3.5a performance
local NUM_BAG_SLOTS = NUM_BAG_SLOTS or 4
local GetContainerNumSlots = GetContainerNumSlots
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local PickupContainerItem = PickupContainerItem
local DeleteCursorItem = DeleteCursorItem
local CursorHasItem = CursorHasItem
local UnitClass = UnitClass
local IsShiftKeyDown = IsShiftKeyDown
local GetCursorPosition = GetCursorPosition
local tonumber, tostring, pairs, type = tonumber, tostring, pairs, type
local math_floor, math_max, math_min, math_rad, math_deg, math_cos, math_sin, math_atan2 =
  math.floor, math.max, math.min, math.rad, math.deg, math.cos, math.sin, math.atan2

-- SavedVariables declared in TOC
ShardKeeperDB = ShardKeeperDB or {}

-- Defaults
local defaults = {
  cap = 5,
  minimap = { angle = 220 }, -- degrees (around the Minimap)
}

-- ========= Utils =========
local function applyDefaults(db, defs)
  for k, v in pairs(defs) do
    if type(v) == "table" then
      db[k] = db[k] or {}
      applyDefaults(db[k], v)
    else
      if db[k] == nil then db[k] = v end
    end
  end
end

-- Count only unlocked Soul Shards directly in player bags (0..NUM_BAG_SLOTS).
-- Using GetItemCount() during BAG_UPDATE causes a chain-deletion bug in 3.3.5a
-- because GetItemCount() lags behind DeleteCursorItem() across cascading BAG_UPDATE events.
local function GetShardCount()
  local count = 0
  for bag = 0, NUM_BAG_SLOTS do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      for slot = 1, slots do
        if GetContainerItemID(bag, slot) == SOUL_SHARD_ID then
          local _, itemCount, locked = GetContainerItemInfo(bag, slot)
          if not locked then
            count = count + (itemCount or 1)
          end
        end
      end
    end
  end
  return count
end

-- Delete extras in a single backward pass; returns how many removed
local function DeleteExtraShards()
  if CursorHasItem() then return 0 end

  local cap = ShardKeeperDB.cap
  if cap == nil then cap = defaults.cap end

  local count = GetShardCount()
  if count <= cap then return 0 end

  local need    = count - cap
  local removed = 0

  -- Single pass from last bag/slot so we never re-pick the same slot
  for bag = NUM_BAG_SLOTS, 0, -1 do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      for slot = slots, 1, -1 do
        if GetContainerItemID(bag, slot) == SOUL_SHARD_ID then
          local _, _, locked = GetContainerItemInfo(bag, slot)
          if not locked then
            PickupContainerItem(bag, slot)
            DeleteCursorItem()
            removed = removed + 1
            if removed >= need then
              return removed
            end
          end
        end
      end
    end
  end

  return removed
end

-- ========= GUI helpers =========
NS.GUI = {}

function NS.GUI:UpdateReadouts()
  if ShardKeeperOptions and ShardKeeperOptions:IsShown() then
    if ShardKeeperOptionsCurrentCount then
      ShardKeeperOptionsCurrentCount:SetText(tostring(GetShardCount()))
    end
  end
end

-- Called from XML OnShow
function ShardKeeper_OnShow()
  -- Ensure texts (3.3.5-safe)
  if ShardKeeperOK and ShardKeeperOK.SetText then ShardKeeperOK:SetText("OK") end
  if ShardKeeperClose and ShardKeeperClose.SetText then ShardKeeperClose:SetText("Close") end
  if ShardKeeperCapLabel and ShardKeeperCapLabel.SetText then ShardKeeperCapLabel:SetText("Set soul shard cap:") end
  if ShardKeeperCurrentLabel and ShardKeeperCurrentLabel.SetText then ShardKeeperCurrentLabel:SetText("Current soul shards:") end

  if ShardKeeperCapInput and ShardKeeperDB then
    local cap = ShardKeeperDB.cap
    if cap == nil then cap = defaults.cap end
    ShardKeeperCapInput:SetText(tostring(cap))
  end
  NS.GUI:UpdateReadouts()
end

-- Global OK handler (called by OK button)
function ShardKeeper_OK()
  local text  = ShardKeeperCapInput and ShardKeeperCapInput:GetText() or ""
  local value = tonumber(text)
  if value == nil then
    value = ShardKeeperDB.cap
    if value == nil then value = defaults.cap end
  end
  value = math_floor(math_max(0, math_min(64, value))) -- clamp 0-64
  ShardKeeperDB.cap = value

  if ShardKeeperCapInput then
    ShardKeeperCapInput:SetText(tostring(value))
    ShardKeeperCapInput:ClearFocus()
  end

  -- Take an initial count before cleaning
  local before = GetShardCount()
  local removed = DeleteExtraShards()
  local after = math_max(before - removed, 0)

  NS.GUI:UpdateReadouts()

  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
      "|cff33ff99ShardKeeper|r: Cap set to %d. Removed %d extra shard(s). Now at %d.",
      value, removed, after
    ))
  end
end

-- ========= Minimap Button =========
local dragging = false

local function PositionMinimapButton()
  local angle = (ShardKeeperDB.minimap and ShardKeeperDB.minimap.angle) or defaults.minimap.angle
  local radius = 80
  local rad = math_rad(angle)
  local x = math_cos(rad) * radius
  local y = math_sin(rad) * radius
  ShardKeeperMinimapButton:ClearAllPoints()
  ShardKeeperMinimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function OnUpdate_MinimapButton(self)
  if dragging then
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    local angle = math_deg(math_atan2(cy - my, cx - mx))
    if angle < 0 then angle = angle + 360 end
    ShardKeeperDB.minimap.angle = angle
    PositionMinimapButton()
  end
end

-- ========= Events & Debounced Bag Check =========
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("CHAT_MSG_LOOT")

local pendingUpdate = false
local throttleTimer = 0
local THROTTLE_DELAY = 0.15

local function OnUpdate_Throttle(self, elapsed)
  throttleTimer = throttleTimer + elapsed
  if throttleTimer >= THROTTLE_DELAY then
    throttleTimer = 0
    pendingUpdate = false
    self:SetScript("OnUpdate", nil)
    DeleteExtraShards()
    NS.GUI:UpdateReadouts()
  end
end

local function ScheduleShardCheck()
  throttleTimer = 0
  if not pendingUpdate then
    pendingUpdate = true
    f:SetScript("OnUpdate", OnUpdate_Throttle)
  end
end

f:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_LOGIN" then
    -- Only activate if player is a Warlock
    local _, class = UnitClass("player")
    if class ~= "WARLOCK" then
      if ShardKeeperMinimapButton then ShardKeeperMinimapButton:Hide() end
      self:UnregisterAllEvents()
      return
    end

    applyDefaults(ShardKeeperDB, defaults)
    PositionMinimapButton()

    -- Minimap button handlers
    ShardKeeperMinimapButton:SetScript("OnMouseDown", function(btn, button)
      if button == "LeftButton" and IsShiftKeyDown() then
        dragging = true
        btn:SetScript("OnUpdate", OnUpdate_MinimapButton)
      end
    end)

    ShardKeeperMinimapButton:SetScript("OnMouseUp", function(btn, button)
      if dragging then
        dragging = false
        btn:SetScript("OnUpdate", nil)
      else
        if button == "LeftButton" then
          if ShardKeeperOptions:IsShown() then
            ShardKeeperOptions:Hide()
          else
            ShardKeeperOptions:Show()
          end
        elseif button == "RightButton" then
          -- Quick toggle 0 <-> default
          if (ShardKeeperDB.cap or 0) == 0 then
            ShardKeeperDB.cap = defaults.cap
          else
            ShardKeeperDB.cap = 0
          end
          local before = GetShardCount()
          local removed = DeleteExtraShards()
          local after = math_max(before - removed, 0)
          NS.GUI:UpdateReadouts()
          if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
              "|cff33ff99ShardKeeper|r: Cap now %d (quick toggle). Removed %d. Now at %d.",
              ShardKeeperDB.cap, removed, after
            ))
          end
        end
      end
    end)

    ShardKeeperMinimapButton:SetScript("OnEnter", function(btn)
      GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
      GameTooltip:AddLine("ShardKeeper", 1, 1, 1)
      GameTooltip:AddLine("Left Click: Open settings", 0.8, 0.8, 0.8)
      GameTooltip:AddLine("Right Click: Quick-toggle cap (0/Default)", 0.8, 0.8, 0.8)
      GameTooltip:AddLine("Shift + Drag: Move", 0.8, 0.8, 0.8)
      local cap = ShardKeeperDB.cap
      if cap == nil then cap = defaults.cap end
      GameTooltip:AddLine(("Cap: %d  |  Shards: %d"):format(cap, GetShardCount()), 0.2, 1, 0.2)
      GameTooltip:Show()
    end)
    ShardKeeperMinimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    NS.GUI:UpdateReadouts()

  elseif event == "CHAT_MSG_LOOT" then
    local msg = ...
    local item = string.match(msg or "", "|Hitem:(%d+):")
    if tonumber(item) == SOUL_SHARD_ID then
      ScheduleShardCheck()
    end

  elseif event == "BAG_UPDATE" then
    ScheduleShardCheck()
  end
end)

-- Slash
SLASH_SHARDKEEPER1 = "/shardkeeper"
SLASH_SHARDKEEPER2 = "/sk"
SlashCmdList.SHARDKEEPER = function()
  if ShardKeeperOptions:IsShown() then
    ShardKeeperOptions:Hide()
  else
    ShardKeeperOptions:Show()
  end
end
