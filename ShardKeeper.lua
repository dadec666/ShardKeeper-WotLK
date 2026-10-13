local ADDON, NS = ...
local VERSION = "1.0.5"
local SOUL_SHARD_ID = 6265

-- Cache frequent globals for 3.3.5a performance
local NUM_BAG_SLOTS = NUM_BAG_SLOTS or 4
local GetContainerNumSlots = GetContainerNumSlots
local GetContainerNumFreeSlots = GetContainerNumFreeSlots
local GetContainerItemID = GetContainerItemID
local GetContainerItemInfo = GetContainerItemInfo
local PickupContainerItem = PickupContainerItem
local SplitContainerItem = SplitContainerItem
local DeleteCursorItem = DeleteCursorItem
local ClearCursor = ClearCursor
local CursorHasItem = CursorHasItem
local UnitClass = UnitClass
local IsShiftKeyDown = IsShiftKeyDown
local GetCursorPosition = GetCursorPosition
local GetTime = GetTime
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

-- Server-confirmation lock state so we never chain-delete across BAG_UPDATEs
local awaitingServerSync = false
local expectedCountAfterAction = nil
local lastActionTime = 0
local ACTION_TIMEOUT = 1.5

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

local function PrintMsg(msg)
  if DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99ShardKeeper v" .. VERSION .. "|r: " .. msg)
  end
end

-- Count Soul Shards directly in player bags (0..NUM_BAG_SLOTS).
-- Also returns whether any shard slot is currently locked (being moved/split/deleted).
local function GetShardCount()
  local count = 0
  local hasLockedShard = false
  for bag = 0, NUM_BAG_SLOTS do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      for slot = 1, slots do
        if GetContainerItemID(bag, slot) == SOUL_SHARD_ID then
          local _, itemCount, locked = GetContainerItemInfo(bag, slot)
          if locked then
            hasLockedShard = true
          else
            count = count + (itemCount or 1)
          end
        end
      end
    end
  end
  return count, hasLockedShard
end

-- Find an empty slot in a compatible bag (used when Soul Shards stack on custom servers)
local function FindEmptySlotForShard(preferredBag)
  if preferredBag then
    local slots = GetContainerNumSlots(preferredBag)
    if slots and slots > 0 then
      for slot = 1, slots do
        if not GetContainerItemID(preferredBag, slot) and not GetContainerItemInfo(preferredBag, slot) then
          return preferredBag, slot
        end
      end
    end
  end

  for bag = 0, NUM_BAG_SLOTS do
    if bag ~= preferredBag then
      local freeSlots, bagFamily = GetContainerNumFreeSlots(bag)
      if freeSlots and freeSlots > 0 and (not bagFamily or bagFamily == 0 or bagFamily == 1) then
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
          if not GetContainerItemID(bag, slot) and not GetContainerItemInfo(bag, slot) then
            return bag, slot
          end
        end
      end
    end
  end
  return nil, nil
end

-- Delete extra shards safely (1 step at a time, with stack-split support)
local function DeleteExtraShards(isManual)
  if CursorHasItem() then return 0 end

  local cap = tonumber(ShardKeeperDB.cap)
  if cap == nil then cap = defaults.cap end

  local count, hasLockedShard = GetShardCount()

  -- If any shard is currently locked by the client/server, wait for it to settle
  if hasLockedShard and not isManual then
    return 0
  end

  -- Check if we are waiting for the server to confirm a previous deletion
  local now = GetTime()
  if awaitingServerSync and not isManual then
    if expectedCountAfterAction and count <= expectedCountAfterAction then
      awaitingServerSync = false
      expectedCountAfterAction = nil
    elseif (now - lastActionTime) < ACTION_TIMEOUT then
      return 0
    else
      awaitingServerSync = false
      expectedCountAfterAction = nil
    end
  end

  if count <= cap then
    awaitingServerSync = false
    expectedCountAfterAction = nil
    return 0
  end

  local need = count - cap

  -- Pass 1: Find a slot from the back whose stack size is <= need (always true on standard 1-per-slot servers,
  -- or after splitting off excess shards from a larger stack on custom servers).
  for bag = NUM_BAG_SLOTS, 0, -1 do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      for slot = slots, 1, -1 do
        if GetContainerItemID(bag, slot) == SOUL_SHARD_ID then
          local _, itemCount, locked = GetContainerItemInfo(bag, slot)
          itemCount = itemCount or 1
          if not locked and itemCount <= need then
            PickupContainerItem(bag, slot)
            DeleteCursorItem()
            awaitingServerSync = true
            expectedCountAfterAction = count - itemCount
            lastActionTime = now
            return itemCount
          end
        end
      end
    end
  end

  -- Pass 2: If Soul Shards are stacked in a single slot (itemCount > need),
  -- NEVER call PickupContainerItem + DeleteCursorItem on the main stack (which would delete the whole stack!).
  -- Instead, split off exactly `need` shards into an empty bag slot; the next BAG_UPDATE will delete only the split slot in Pass 1.
  for bag = NUM_BAG_SLOTS, 0, -1 do
    local slots = GetContainerNumSlots(bag)
    if slots and slots > 0 then
      for slot = slots, 1, -1 do
        if GetContainerItemID(bag, slot) == SOUL_SHARD_ID then
          local _, itemCount, locked = GetContainerItemInfo(bag, slot)
          itemCount = itemCount or 1
          if not locked and itemCount > need then
            local freeBag, freeSlot = FindEmptySlotForShard(bag)
            if freeBag and freeSlot then
              SplitContainerItem(bag, slot, need)
              PickupContainerItem(freeBag, freeSlot)
              awaitingServerSync = true
              expectedCountAfterAction = nil -- wait for split to finish
              lastActionTime = now
            end
            return 0
          end
        end
      end
    end
  end

  return 0
end

-- ========= GUI helpers =========
NS.GUI = {}

function NS.GUI:UpdateReadouts()
  if ShardKeeperOptions and ShardKeeperOptions:IsShown() then
    if ShardKeeperOptionsCurrentCount then
      local count = GetShardCount()
      ShardKeeperOptionsCurrentCount:SetText(tostring(count))
    end
  end
end

-- Called from XML OnShow
function ShardKeeper_OnShow()
  if ShardKeeperTitle and ShardKeeperTitle.SetText then ShardKeeperTitle:SetText("ShardKeeper v" .. VERSION) end
  if ShardKeeperOK and ShardKeeperOK.SetText then ShardKeeperOK:SetText("OK") end
  if ShardKeeperClose and ShardKeeperClose.SetText then ShardKeeperClose:SetText("Close") end
  if ShardKeeperCapLabel and ShardKeeperCapLabel.SetText then ShardKeeperCapLabel:SetText("Set soul shard cap:") end
  if ShardKeeperCurrentLabel and ShardKeeperCurrentLabel.SetText then ShardKeeperCurrentLabel:SetText("Current soul shards:") end

  if ShardKeeperCapInput and ShardKeeperDB then
    local cap = tonumber(ShardKeeperDB.cap)
    if cap == nil then cap = defaults.cap end
    ShardKeeperCapInput:SetText(tostring(cap))
  end
  NS.GUI:UpdateReadouts()
end

-- ========= Events & Step-by-Step Queue =========
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("BAG_UPDATE")
f:RegisterEvent("CHAT_MSG_LOOT")

local pendingUpdate = false
local throttleTimer = 0
local THROTTLE_DELAY = 0.25

local function ScheduleShardCheck()
  throttleTimer = 0
  if not pendingUpdate then
    pendingUpdate = true
    f:SetScript("OnUpdate", function(self, elapsed)
      throttleTimer = throttleTimer + elapsed
      if throttleTimer >= THROTTLE_DELAY then
        throttleTimer = 0
        local removed = DeleteExtraShards(false)
        NS.GUI:UpdateReadouts()
        local count = GetShardCount()
        local cap = tonumber(ShardKeeperDB.cap) or defaults.cap
        if count <= cap then
          pendingUpdate = false
          self:SetScript("OnUpdate", nil)
        end
      end
    end)
  end
end

-- Global OK handler (called by OK button)
function ShardKeeper_OK()
  local text  = ShardKeeperCapInput and ShardKeeperCapInput:GetText() or ""
  local value = tonumber(text)
  if value == nil then
    value = tonumber(ShardKeeperDB.cap)
    if value == nil then value = defaults.cap end
  end
  value = math_floor(math_max(0, math_min(64, value))) -- clamp 0-64
  ShardKeeperDB.cap = value

  if ShardKeeperCapInput then
    ShardKeeperCapInput:SetText(tostring(value))
    ShardKeeperCapInput:ClearFocus()
  end

  awaitingServerSync = false
  expectedCountAfterAction = nil

  local before = GetShardCount()
  local removed = DeleteExtraShards(true)
  ScheduleShardCheck()
  NS.GUI:UpdateReadouts()

  PrintMsg(string.format("Лимит установлен на %d (сейчас в сумках: %d).", value, math_max(before - removed, 0)))
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

f:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_LOGIN" then
    local _, class = UnitClass("player")
    if class ~= "WARLOCK" then
      if ShardKeeperMinimapButton then ShardKeeperMinimapButton:Hide() end
      self:UnregisterAllEvents()
      return
    end

    applyDefaults(ShardKeeperDB, defaults)
    -- Safety guard: if cap was accidentally set to 0, restore default 5 on login
    if tonumber(ShardKeeperDB.cap) == nil then
      ShardKeeperDB.cap = defaults.cap
    end

    PositionMinimapButton()

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
          -- Open options on right-click as well (removed accidental 0-cap wipe on right-click!)
          if ShardKeeperOptions:IsShown() then
            ShardKeeperOptions:Hide()
          else
            ShardKeeperOptions:Show()
          end
        end
      end
    end)

    ShardKeeperMinimapButton:SetScript("OnEnter", function(btn)
      GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
      GameTooltip:AddLine("ShardKeeper v" .. VERSION, 1, 1, 1)
      GameTooltip:AddLine("ЛКМ / ПКМ: Открыть настройки", 0.8, 0.8, 0.8)
      GameTooltip:AddLine("Shift + ЛКМ: Переместить иконку", 0.8, 0.8, 0.8)
      local cap = tonumber(ShardKeeperDB.cap)
      if cap == nil then cap = defaults.cap end
      local count = GetShardCount()
      GameTooltip:AddLine(("Кап: %d  |  Осколков: %d"):format(cap, count), 0.2, 1, 0.2)
      GameTooltip:Show()
    end)
    ShardKeeperMinimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    NS.GUI:UpdateReadouts()
    local count = GetShardCount()
    PrintMsg(string.format("загружен. Текущий лимит: %d, осколков в сумках: %d.", ShardKeeperDB.cap, count))

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
