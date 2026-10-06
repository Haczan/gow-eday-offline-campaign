-- OfflineCampaign: play the local campaign (Continue / New / Load) without
-- online services. Active only when the game is started through the offline
-- launcher (GOWEDAY_OFFLINE=1); a normal Steam launch is left untouched.
if os.getenv("GOWEDAY_OFFLINE") ~= "1" then
    return
end

-- The whole campaign is one World Partition world. The campaign game mode
-- reads what to play from the travel URL:
--   LoadLastCheckpoint=<slot>  last checkpoint of a local campaign slot
--   mission=<MissionId>        start a mission from the beginning
local CAMPAIGN_MAP = "/Game/Fairlight/Maps/Fairlight_World/Fairlight_World_WP"
local CONTINUE_NODE = "/Game/Fairlight/Interface/FrontendNavigation/FlowNode_UIScene_FrontendNavigation_ContinueCampaign.FlowNode_UIScene_FrontendNavigation_ContinueCampaign_C:OnNodeFirstUpdate"
local BUTTON_INPUT_FN = "/Game/Fairlight/Interface/Common/Buttons/BP_UtilWidget_GenericButton.BP_UtilWidget_GenericButton_C:OnInputEvent"
local ENTRY_EVENT_FN = "/Game/Fairlight/Interface/FrontendNavigation/BP_UIWidget_FrontendNavigationListEntry.BP_UIWidget_FrontendNavigationListEntry_C:OnWidgetFlowEventReceived"
local SYNC_STATUS_FN = "/Script/TCGUI.TCUserWidget:GetOverallStatusForKeys"
local METAGAME_LIB = "/Script/FairlightGameFramework.Default__FLMetagameBlueprintLibrary"

local NAV_ENTRY_CLASS = "BP_UIWidget_FrontendNavigationListEntry_C"
local CAMPAIGN_GAME_MODE = "GameMode_Campaign"  -- BP_GameMode_Campaign_C
local CAMPAIGN_SUBMENU = "SecondaryNavigationList"
local CONFIRM_INPUT = "UI.Input.Action.Confirm"
local FIRST_MISSION = "A1C0110"  -- opening cinematics, used if the game cannot tell

local WELCOME_LOGIN = 7        -- EFLGUIWelcomeState::Login
local LOGIN_SUCCESS = 2        -- EFLGUILoginResult passed to OnLoginEnded
local BUCKET_IN_SYNC = 2       -- ETCOGame_AvailabilitySubsystem_BucketStatus::InSync
local LOGIN_GRACE_TICKS = 3    -- seconds spent waiting for sign-in before skipping it
local CAMPAIGN_SLOTS = 5       -- local campaign slots 0..4
local CHECKPOINT_LOAD_WAIT_MS = 3000
local SLOT_DELETE_WAIT_MS = 5000
local DIFFICULTY_CHECK_TICKS = 60

local DIFFICULTIES = {
    {key = "Difficulty.Presets.Campaign.01Casual", name = "CASUAL"},
    {key = "Difficulty.Presets.Campaign.02Normal", name = "NORMAL"},
    {key = "Difficulty.Presets.Campaign.03Hardcore", name = "HARDCORE"},
    {key = "Difficulty.Presets.Campaign.04Insane", name = "INSANE"},
    {key = "Difficulty.Presets.Campaign.05Inconceivable", name = "INCONCEIVABLE"},
}
local DEFAULT_DIFFICULTY = 2

-- Texts shown in the campaign menu by this mod.
local TEXT = {
    difficulty = "DIFFICULTY",
    free = "EMPTY",
    overwrite = "OVERWRITE",
    startNew = "START NEW CAMPAIGN",
    overwriteAndStart = "OVERWRITE AND START",
    loadCheckpoint = "LOAD CHECKPOINT",
    back = "BACK",
    starting = "STARTING...",
    loading = "LOADING...",
    lobbyOffline = "LOBBY BROWSER: ONLINE ONLY",
    noSaveSystem = "ERROR: NO SAVE SYSTEM",
    slotNotDeleted = "ERROR: SLOT %d NOT DELETED",
    cannotStart = "ERROR: CANNOT START",
    cannotLoad = "ERROR: CANNOT LOAD",
    dateFormat = "%Y-%m-%d %H:%M",
}

-- Availability buckets the local campaign depends on; anything else (store,
-- social, multiplayer) keeps its real, offline status.
local LOCAL_BUCKETS = {
    ["TCOGame.AvailabilitySubsystem.Buckets.Campaign"] = true,
    ["TCOGame.AvailabilitySubsystem.Buckets.Core"] = true,
    ["TCOGame.AvailabilitySubsystem.Buckets.Progression"] = true,
}

local function log(fmt, ...)
    print("[OfflineCampaign] " .. string.format(fmt, ...) .. "\n")
end

local function valid(obj)
    return obj ~= nil and obj:IsValid()
end

log("Offline launch requested.")

-- 1. "Unable to Sync": report the local campaign buckets as in sync.
local function onlyLocalBuckets(keysParam)
    local count, local_only = 0, true
    pcall(function()
        local keys = keysParam:get()
        for i = 1, #keys do
            count = count + 1
            if not LOCAL_BUCKETS[keys[i]:get().KeyName:ToString()] then
                local_only = false
            end
        end
    end)
    return count > 0 and local_only
end

RegisterHook(SYNC_STATUS_FN, function(_, keys)
    if onlyLocalBuckets(keys) then
        return BUCKET_IN_SYNC
    end
end)

-- 2. Local save data.
local function savepoints()
    local sp = FindFirstOf("FLSavepointSubSystem")
    if valid(sp) then return sp end
end

local function difficultyIndex(key)
    for i, d in ipairs(DIFFICULTIES) do
        if d.key == key then return i end
    end
end

local function difficultyName(key)
    local i = difficultyIndex(key)
    if i then return DIFFICULTIES[i].name end
    return (key or "?"):match("([^%.]+)$") or "?"
end

local function slotDifficulty(sp, slot)
    local key
    pcall(function()
        key = sp:GetCampaignDetailsFromCampaignSlot(slot).CampaignDifficultySettings.BaseDifficultyKey.KeyName:ToString()
    end)
    if key and key ~= "" and key ~= "None" then return key end
end

local function missionName(missionId)
    local name = missionId:ToString()
    pcall(function()
        local lib = StaticFindObject(METAGAME_LIB)
        local pc = FindFirstOf("PlayerController")
        local text = lib:GetMissionDisplayNameFromMissionId(pc, missionId):ToString()
        if text ~= "" then
            -- strip internal suffixes such as " - (V2/D2)"
            name = text:gsub("%s*%-%s*%(.*$", "")
        end
    end)
    return name
end

local function formatSaveTime(ticks)
    if type(ticks) ~= "number" or ticks <= 0 then return "?" end
    -- FDateTime ticks (100 ns since 0001-01-01, UTC) -> local time
    return os.date(TEXT.dateFormat, math.floor(ticks / 10000000) - 62135596800)
end

-- Checkpoints of a slot in the game's own order (oldest first); `index` is
-- what LoadCheckpointFromCurrentCampaignSlot expects.
local function slotCheckpoints(sp, slot)
    local list = {}
    local ok, err = pcall(function()
        for i, p in ipairs(sp:GetCheckpointsFromCampaignSlot(slot)) do
            local cp = p:get()
            local details = cp.CheckpointDetails
            local ticks = 0
            pcall(function() ticks = details.SaveTime.Ticks end)
            table.insert(list, {
                index = i - 1,
                file = cp.CheckpointSlotName:ToString(),
                mission = missionName(details.MissionCheckpointId.MissionId),
                time = formatSaveTime(ticks),
            })
        end
    end)
    if not ok then log("Checkpoints of slot %d: %s", slot, tostring(err)) end
    return list
end

local function mostRecentCampaignSlot(sp)
    local slot = 0
    pcall(function()
        local s = sp:GetMostRecentCampaignSlot()
        if type(s) == "number" and s >= 0 then slot = s end
    end)
    return slot
end

-- 3. Travel into the campaign world.
local travelling = false
local campaignStarted = false  -- a campaign was started by this mod in this session
local newCampaignDifficulty = nil  -- chosen for a new campaign, stored in its slot once in game
local watchedPlayer = {address = nil, ticks = 0}
local picker = nil             -- New/Load picker shown in the campaign menu (section 5)

local function travel(options, newDifficulty)
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local pc = FindFirstOf("PlayerController")
    if not (valid(statics) and valid(pc)) then
        log("Travel: no player controller")
        return false
    end
    travelling = true
    picker = nil  -- the frontend menu goes away with the travel
    ExecuteWithDelay(10000, function() travelling = false end)
    campaignStarted = true
    newCampaignDifficulty = newDifficulty
    log("Travel -> %s?%s", CAMPAIGN_MAP, options)
    statics:OpenLevel(pc, FName(CAMPAIGN_MAP), true, options)
    return true
end

-- The game takes the campaign difficulty from the online lobby, which does not
-- exist offline (it falls back to a default). Each time a campaign world gets
-- a new player controller, apply the difficulty stored in the active slot; a
-- new campaign first stores the difficulty chosen in the menu.
local function enforceDifficulty()
    if not campaignStarted then return end
    local pc = FindFirstOf("PlayerController")
    if not (valid(pc) and valid(pc.Pawn)) then return end
    local address = pc:GetAddress()
    if address ~= watchedPlayer.address then
        watchedPlayer = {address = address, ticks = 0}
    end
    if watchedPlayer.ticks >= DIFFICULTY_CHECK_TICKS then return end
    watchedPlayer.ticks = watchedPlayer.ticks + 1
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local gm = statics:GetGameMode(pc)
    if not (valid(gm) and gm:GetClass():GetFName():ToString():find(CAMPAIGN_GAME_MODE, 1, true)) then return end
    local sp = savepoints()
    if not sp then return end
    if newCampaignDifficulty then
        sp:UpdateCurrentCampaignDifficultySettings({KeyName = FName(newCampaignDifficulty)}, {}, true)
        log("Difficulty %s saved to slot %s", newCampaignDifficulty, tostring(sp:GetCampaignSlotNumber()))
        newCampaignDifficulty = nil
    end
    local want = slotDifficulty(sp, sp:GetCampaignSlotNumber())
    if not want then return end
    local have = gm:GetPlayerDifficulty(pc, false).KeyName:ToString()
    if have ~= want then
        log("Difficulty in game: %s -> %s", have, want)
        gm:SetPlayerDifficulty(pc, {KeyName = FName(want)})
    elseif watchedPlayer.ticks == 1 then
        log("Difficulty in game: %s", have)
    end
end

-- Run `done(ok)` in the game thread once `cond()` holds or `timeoutMs` passes.
local function waitUntil(cond, timeoutMs, done)
    ExecuteInGameThread(function()
        local ok, met = pcall(cond)
        met = ok and met
        if met or timeoutMs <= 0 then
            done(met)
            return
        end
        ExecuteWithDelay(200, function() waitUntil(cond, timeoutMs - 200, done) end)
    end)
end

-- 4. "Continue": the last checkpoint of the most recent local campaign slot.
local function continueCampaign()
    local sp = savepoints()
    local slot = sp and mostRecentCampaignSlot(sp) or 0
    travel("LoadLastCheckpoint=" .. slot)
end

local continueHooked = false

local function hookContinue()
    if continueHooked or not valid(StaticFindObject(CONTINUE_NODE)) then
        return
    end
    RegisterHook(CONTINUE_NODE, function()
        if travelling then return end
        ExecuteWithDelay(100, function()
            ExecuteInGameThread(continueCampaign)
        end)
    end)
    continueHooked = true
end

-- 5. "New" / "Load": the original entries open online lobby screens that never
-- appear offline (the menu stays hidden). Their presses are intercepted and the
-- four campaign menu entries are reused as a small picker instead.
local function entryLabel(entry)
    local text = ""
    pcall(function() text = entry.ContentWidget.LabelRichText:GetText():ToString() end)
    return text
end

local function setEntryLabel(entry, text)
    if entryLabel(entry) ~= text then
        pcall(function() entry.ContentWidget.LabelRichText:SetText(FText(text)) end)
    end
end

local function campaignMenuList(entry)
    local vm = entry.DataContext
    if not valid(vm) then return end
    local list = vm:GetOuter()
    if valid(list) and list:GetFName():ToString() == CAMPAIGN_SUBMENU then
        return list
    end
end

local function campaignMenuOf(button)
    local tree = button:GetOuter()
    if not valid(tree) then return end
    local entry = tree:GetOuter()
    if not (valid(entry) and entry:GetClass():GetFName():ToString() == NAV_ENTRY_CLASS) then return end
    local list = campaignMenuList(entry)
    if list then return entry, list end
end

-- Campaign menu entries whose original action needs the online services.
local INTERCEPTED = {["NEW"] = true, ["LOAD"] = true, ["LOBBY BROWSER"] = true}

local function interceptedKind(entry)
    local kind = entryLabel(entry):upper():gsub("^%s+", ""):gsub("%s+$", "")
    if INTERCEPTED[kind] then return kind end
end

-- The button checks IsWidgetInteractable before any hook on its input runs,
-- so these entries are switched off as soon as they are shown or focused.
local function guardEntry(entry)
    if picker or not campaignMenuList(entry) then return end
    if interceptedKind(entry) then
        local button = entry.NavigationButton
        if valid(button) and button.IsWidgetInteractable then
            button.IsWidgetInteractable = false
        end
    end
end

local function menuEntries(list)
    local entries = {}
    local view = list.NavigationList
    for _, w in ipairs(view:GetDisplayedEntryWidgets()) do
        local e = w:get()
        if valid(e) and valid(e.DataContext) then
            table.insert(entries, {widget = e, order = view:GetIndexForItem(e.DataContext)})
        end
    end
    table.sort(entries, function(a, b) return a.order < b.order end)
    for i, e in ipairs(entries) do entries[i] = e.widget end
    return entries
end

local function renderPicker()
    for i, entry in ipairs(picker.entries) do
        local row = picker.rows[i]
        if valid(entry) then
            setEntryLabel(entry, row and row.label() or " ")
        end
    end
end

local function closePicker(restore)
    if not picker then return end
    if restore then
        for i, entry in ipairs(picker.entries) do
            if valid(entry) then
                setEntryLabel(entry, picker.saved[i].label)
                pcall(function() entry.NavigationButton.IsWidgetInteractable = picker.saved[i].interactable end)
            end
        end
    end
    picker = nil
end

local function busy(text)
    if not picker then return end
    picker.busy = true
    picker.rows = {{label = function() return text end}}
    renderPicker()
end

local function fail(text)
    log("%s", text)
    busy(text)
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function() closePicker(true) end)
    end)
end

local function cycle(i, n) return i % n + 1 end

-- Fit the rows to the number of entries the menu shows; optional rows go first.
local function fitRows(rows, count)
    local order = {}
    for _, r in ipairs(rows) do table.insert(order, r) end
    for _, drop in ipairs({"back", "slot"}) do
        if #order <= count then break end
        for i, r in ipairs(order) do
            if r.id == drop then table.remove(order, i) break end
        end
    end
    return order
end

-- New campaign: difficulty, slot (free slots first), start. Starts at the
-- beginning of the story, opening cinematics included.
local function newCampaignMission()
    local mission = FIRST_MISSION
    pcall(function()
        local manager = FindFirstOf("CampaignManagerSubsystem")
        local id = manager:GetNewCampaignMissionId().MissionId:ToString()
        if id ~= "" and id ~= "None" then mission = id end
    end)
    return mission
end

local function startNewCampaign(slot, difficultyKey, overwrite)
    local sp = savepoints()
    if not sp then return fail(TEXT.noSaveSystem) end
    busy(TEXT.starting)
    if overwrite then
        log("New campaign: deleting slot %d", slot)
        sp:DeleteCampaignSlot(slot)
    end
    waitUntil(function() return not sp:DoesCampaignSlotExist(slot) end, overwrite and SLOT_DELETE_WAIT_MS or 0, function(free)
        if not free then
            return fail(string.format(TEXT.slotNotDeleted, slot + 1))
        end
        sp:SetCampaignSlotNumber(slot)
        local mission = newCampaignMission()
        log("New campaign: slot %d, %s, mission %s", slot, difficultyKey, mission)
        if not travel("mission=" .. mission, difficultyKey) then
            fail(TEXT.cannotStart)
        end
    end)
end

local function newCampaignRows(sp)
    local slots, used = {}, {}
    for slot = 0, CAMPAIGN_SLOTS - 1 do
        if sp:DoesCampaignSlotExist(slot) then
            local cps = slotCheckpoints(sp, slot)
            used[slot] = cps[#cps] and cps[#cps].mission or "?"
        else
            table.insert(slots, slot)
        end
    end
    for slot = 0, CAMPAIGN_SLOTS - 1 do
        if used[slot] then table.insert(slots, slot) end
    end
    local state = {
        difficulty = difficultyIndex(slotDifficulty(sp, mostRecentCampaignSlot(sp)) or "") or DEFAULT_DIFFICULTY,
        slot = 1,
    }
    local function chosenSlot() return slots[state.slot] end
    return {
        {id = "difficulty",
         label = function() return "‹ " .. TEXT.difficulty .. ": " .. DIFFICULTIES[state.difficulty].name .. " ›" end,
         press = function() state.difficulty = cycle(state.difficulty, #DIFFICULTIES) end},
        {id = "slot",
         label = function()
             local slot = chosenSlot()
             if used[slot] then
                 return "‹ SLOT " .. (slot + 1) .. ": " .. TEXT.overwrite .. " (" .. used[slot] .. ") ›"
             end
             return "‹ SLOT " .. (slot + 1) .. ": " .. TEXT.free .. " ›"
         end,
         press = function() state.slot = cycle(state.slot, #slots) end},
        {id = "start",
         label = function()
             if used[chosenSlot()] then return TEXT.overwriteAndStart end
             return TEXT.startNew
         end,
         press = function()
             local slot = chosenSlot()
             startNewCampaign(slot, DIFFICULTIES[state.difficulty].key, used[slot] ~= nil)
         end},
        {id = "back", label = function() return TEXT.back end,
         press = function() closePicker(true) end},
    }
end

-- Load: slot, checkpoint (newest first), load.
local function loadCheckpoint(slot, checkpoint, count)
    local sp = savepoints()
    if not sp then return fail(TEXT.noSaveSystem) end
    busy(TEXT.loading)
    sp:SetCampaignSlotNumber(slot)
    log("Load: slot %d, checkpoint %s (index %d of %d)", slot, checkpoint.file, checkpoint.index, count)
    if checkpoint.index == count - 1 then
        if not travel("LoadLastCheckpoint=" .. slot) then fail(TEXT.cannotLoad) end
        return
    end
    -- Selecting an older checkpoint makes it the slot's latest one, which
    -- LoadLastCheckpoint then opens.
    sp:LoadCheckpointFromCurrentCampaignSlot(checkpoint.index)
    waitUntil(function()
        local cps = slotCheckpoints(sp, slot)
        return cps[#cps] and cps[#cps].file == checkpoint.file
    end, CHECKPOINT_LOAD_WAIT_MS, function()
        if not travel("LoadLastCheckpoint=" .. slot) then fail(TEXT.cannotLoad) end
    end)
end

local function loadRows(sp)
    local slots = {}
    local recent = mostRecentCampaignSlot(sp)
    local state = {slot = 1, checkpoint = 1}
    for slot = 0, CAMPAIGN_SLOTS - 1 do
        if sp:DoesCampaignSlotExist(slot) then
            local cps = slotCheckpoints(sp, slot)
            if #cps > 0 then
                table.insert(slots, {slot = slot, checkpoints = cps, difficulty = slotDifficulty(sp, slot)})
                if slot == recent then state.slot = #slots end
            end
        end
    end
    if #slots == 0 then return nil end
    local function current() return slots[state.slot] end
    local function checkpoint()
        local cps = current().checkpoints
        return cps[#cps - state.checkpoint + 1], #cps
    end
    return {
        {id = "slot",
         label = function()
             return "‹ SLOT " .. (current().slot + 1) .. " · " .. difficultyName(current().difficulty) .. " ›"
         end,
         press = function()
             state.slot = cycle(state.slot, #slots)
             state.checkpoint = 1
         end},
        {id = "checkpoint",
         label = function()
             local cp, count = checkpoint()
             return "‹ " .. cp.mission .. " · " .. cp.time .. " (" .. state.checkpoint .. "/" .. count .. ") ›"
         end,
         press = function() state.checkpoint = cycle(state.checkpoint, #current().checkpoints) end},
        {id = "load", label = function() return TEXT.loadCheckpoint end,
         press = function()
             local cp, count = checkpoint()
             loadCheckpoint(current().slot, cp, count)
         end},
        {id = "back", label = function() return TEXT.back end,
         press = function() closePicker(true) end},
    }
end

local function openPicker(kind, list)
    local sp = savepoints()
    if not sp then return end
    local entries = menuEntries(list)
    if #entries < 2 then
        log("Picker: campaign menu has %d entries", #entries)
        return
    end
    local rows = kind == "NEW" and newCampaignRows(sp) or loadRows(sp)
    if not rows then
        log("Picker: no local campaign to load")
        return
    end
    picker = {entries = entries, saved = {}, rowOf = {}, rows = fitRows(rows, #entries), unfocused = 0}
    for i, entry in ipairs(entries) do
        local label = entryLabel(entry)
        if label == TEXT.lobbyOffline then label = "LOBBY BROWSER" end
        picker.saved[i] = {label = label, interactable = entry.NavigationButton.IsWidgetInteractable}
        picker.rowOf[entry:GetAddress()] = i
        entry.NavigationButton.IsWidgetInteractable = false
    end
    log("Picker %s opened (%d entries)", kind, #entries)
    renderPicker()
    pcall(function() entries[1]:SetFocus() end)
end

local function onConfirm(button)
    local entry, list = campaignMenuOf(button)
    if not entry then return end
    if picker and not picker.rowOf[entry:GetAddress()] then
        picker = nil  -- left over from an earlier menu instance
    end
    if picker then
        -- every row is ours while the picker is open
        button.IsWidgetInteractable = false
        local i = picker.rowOf[entry:GetAddress()]
        ExecuteInGameThread(function()
            if not picker or picker.busy then return end
            local row = picker.rows[i]
            if row and row.press then
                row.press()
                if picker and not picker.busy then renderPicker() end
            end
        end)
        return
    end
    local kind = interceptedKind(entry)
    if not kind then return end
    if button.IsWidgetInteractable then
        -- too late: the original (online) action runs with this press
        button.IsWidgetInteractable = false
        log("%s pressed before it was intercepted", kind)
        return
    end
    ExecuteInGameThread(function()
        if picker or travelling then return end
        if kind == "LOBBY BROWSER" then
            local original = entryLabel(entry)
            setEntryLabel(entry, TEXT.lobbyOffline)
            ExecuteWithDelay(2500, function()
                ExecuteInGameThread(function()
                    if valid(entry) and not picker then setEntryLabel(entry, original) end
                end)
            end)
            return
        end
        openPicker(kind, list)
    end)
end

local buttonHooked, entryHooked = false, false

local function hookMenuButtons()
    if not buttonHooked and valid(StaticFindObject(BUTTON_INPUT_FN)) then
        RegisterHook(BUTTON_INPUT_FN, function(self, event)
            local ok, err = pcall(function()
                if event:get().TagName:ToString() == CONFIRM_INPUT then
                    onConfirm(self:get())
                end
            end)
            if not ok then log("Menu input: %s", tostring(err)) end
        end)
        buttonHooked = true
    end
    if not entryHooked and valid(StaticFindObject(ENTRY_EVENT_FN)) then
        -- focus changes and other flow events reach every menu entry
        RegisterHook(ENTRY_EVENT_FN, function(self)
            pcall(guardEntry, self:get())
        end)
        entryHooked = true
    end
end

-- Backstop for entries that appear without a flow event.
local mainMenu = nil
local menuSearchTicks = 0

local function guardCampaignMenu()
    if picker then return end
    if not valid(mainMenu) then
        mainMenu = nil
        menuSearchTicks = menuSearchTicks - 1
        if menuSearchTicks > 0 then return end
        menuSearchTicks = 10
        local menu = FindFirstOf("BP_UIWidget_MainMenuContent_C")
        if not valid(menu) then return end
        mainMenu = menu
    end
    local list = mainMenu.SecondaryNavigationList
    if not valid(list) then return end
    for _, entry in ipairs(menuEntries(list)) do
        guardEntry(entry)
    end
end

-- Leaving the campaign menu (Back, travel) restores the original entries.
local function watchPicker()
    if not picker then return end
    local focused = false
    for _, entry in ipairs(picker.entries) do
        if not valid(entry) then
            picker = nil
            return
        end
        if entry.IsFocused then focused = true end
    end
    if picker.busy then return end
    picker.unfocused = focused and 0 or picker.unfocused + 1
    if picker.unfocused >= 2 then
        closePicker(true)
    else
        renderPicker()
    end
end

-- 6. Title screen: platform sign-in never completes offline, so end it as a
-- success and close the "Waiting for Platform Sign In" scene that holds focus.
local loginTicks = 0

local function skipSignIn()
    local welcome = FindFirstOf("FLGUIScene_Welcome")
    if not valid(welcome) then
        loginTicks = 0
        return
    end
    if welcome.CurrentState ~= WELCOME_LOGIN then
        loginTicks = 0
        return
    end
    loginTicks = loginTicks + 1
    if loginTicks < LOGIN_GRACE_TICKS then
        return
    end
    loginTicks = 0
    log("Skipping platform sign-in")
    welcome:OnLoginEnded(LOGIN_SUCCESS, 0)
    for _, scene in ipairs(FindAllOf("FLGUIScene_LoginSequence") or {}) do
        if valid(scene) and not scene:IsMarkedForClose() then
            scene:CloseScene(true)
        end
    end
end

LoopAsync(1000, function()
    ExecuteInGameThread(function()
        pcall(hookContinue)
        pcall(hookMenuButtons)
        pcall(skipSignIn)
        local ok, err = pcall(enforceDifficulty)
        if not ok then
            log("Difficulty: %s", tostring(err))
            watchedPlayer.ticks = DIFFICULTY_CHECK_TICKS
        end
    end)
    return false
end)

LoopAsync(300, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(watchPicker)
        if not ok then
            log("Picker: %s", tostring(err))
            picker = nil
        end
        pcall(guardCampaignMenu)
    end)
    return false
end)
