local Core = exports.vorp_core:GetCore()

local locations = {}
local pendingGames = {}
local activeGames = {}

local function sortAndAssignOrders(players, startingSeat)
    table.sort(players, function(a,b)
        local sa = a.seatIndex or a:getSeatIndex() or 999
        local sb = b.seatIndex or b:getSeatIndex() or 999
        if sa == sb then return (a:getNetId() or 0) < (b:getNetId() or 0) end
        return sa < sb
    end)
    local startIdx = 1
    for i,p in ipairs(players) do
        if (p.seatIndex or p:getSeatIndex()) == startingSeat then
            startIdx = i
            break
        end
    end
    for i=1, startIdx-1 do
        local x = table.remove(players, 1)
        table.insert(players, x)
    end
    for i,p in ipairs(players) do
        p:setOrder(i)
    end
end

local function nextStartingSeat(currentSeat, maxSeats, players)
    if not currentSeat then return nil end
    local occupied = {}
    for _,p in ipairs(players) do
        if p.seatIndex or p:getSeatIndex() then
            occupied[p.seatIndex or p:getSeatIndex()] = true
        end
    end
    if not maxSeats or maxSeats < 1 then maxSeats = 6 end
    local tries = 0
    local s = currentSeat
    while tries < maxSeats do
        s = s + 1
        if s > maxSeats then s = 1 end
        if occupied[s] then return s end
        tries = tries + 1
    end
    return currentSeat
end

-- Initial set up of locations
Citizen.CreateThread(function()
    for k,v in pairs(Config.Locations) do
        local location = Location:New({
            id = k,
            state = LOCATION_STATES.EMPTY,
            tableCoords = v.Table.Coords,
            maxPlayers = v.MaxPlayers,
        })
        location.waitingPlayers = {}
        table.insert(locations, location)
    end
end)

RegisterServerEvent("rainbow_poker:Server:RequestCharacterName", function()
    local _source = source

    local user = Core.getUser(_source)
    if not user then return end
    
    local character = user.getUsedCharacter
    local firstname = character.firstname or GetPlayerName(_source)
    TriggerClientEvent("rainbow_poker:Client:ReturnRequestCharacterName", _source, firstname)
end)

RegisterServerEvent("rainbow_poker:Server:RequestUpdatePokerTables", function()
    local _source = source
    TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", _source, locations)
end)

RegisterServerEvent("rainbow_poker:Server:StartNewPendingGame", function(player1sChosenName, anteAmount, tableLocationIndex)
    local _source = source

    if Config.DebugPrint then print("StartNewPendingGame", player1sChosenName, anteAmount, tableLocationIndex) end

    local loc = locations[tableLocationIndex]
    if not loc then
        if Config.DebugPrint then print("StartNewPendingGame: invalid location index", tableLocationIndex) end
        return
    end

    if loc:getState() ~= LOCATION_STATES.EMPTY then
        return
    end

    if findPendingGameByPlayerNetId(_source) ~= false then
        Core.NotifyTip(_source, 'Wciąż uczestniczysz w oczekującej grze w pokera.', 6000)

        return
    end

    if findActiveGameByPlayerNetId(_source) ~= false then
        Core.NotifyTip(_source, 'Wciąż uczestniczysz w aktywnej grze w pokera.', 6000)

        return
    end

    player1sChosenName = truncateString(player1sChosenName, 10)

    if not hasMoney(_source, anteAmount) then
        Core.NotifyTip(_source, "Nie masz wystarczająco, aby postawić ante.", 6000)

        return
    end

    math.randomseed(os.time())

    local player1NetId = _source

    local pendingPlayer1 = Player:New({
        netId = player1NetId,
        name = player1sChosenName,
        order = 1,
    })
    pendingPlayer1.seatIndex = math.random(1, loc:getMaxPlayers())
    
    local newPendingGame = PendingGame:New({
        initiatorNetId = _source,
        players = {
            pendingPlayer1,
        },
        ante = anteAmount,
    })

    locations[tableLocationIndex]:setPendingGame(newPendingGame)
    locations[tableLocationIndex]:setState(LOCATION_STATES.PENDING_GAME)

    if Config.DebugPrint then print("StartNewGame - newPendingGame", newPendingGame) end

    TriggerClientEvent("rainbow_poker:Client:ReturnStartNewPendingGame", _source, tableLocationIndex, pendingPlayer1, pendingPlayer1.seatIndex)
    TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", -1, locations)
end)

RegisterServerEvent("rainbow_poker:Server:JoinGame", function(playersChosenName, tableLocationIndex)
    local _source = source

    if Config.DebugPrint then print("JoinGame", playersChosenName, tableLocationIndex) end

    local loc = locations[tableLocationIndex]
    if not loc then
        if Config.DebugPrint then print("JoinGame: invalid location index", tableLocationIndex) end
        return
    end

    local pendingGame = loc:getPendingGame()
    if not pendingGame then
        if loc:getState() == LOCATION_STATES.GAME_IN_PROGRESS then
            local game = activeGames[tableLocationIndex]
            if not game then return end
            
            if loc.waitingPlayers then
                for _,wp in ipairs(loc.waitingPlayers) do
                    if wp.netId == _source then
                        Core.NotifyTip(_source, 'Już czekasz na następną rundę.', 6000)

                        return
                    end
                end
            else
                loc.waitingPlayers = {}
            end

            local taken = {}
            for _,p in pairs(game:getPlayers()) do
                local s = p.seatIndex or p:getOrder()
                taken[s] = true
            end
            for _,wp in ipairs(loc.waitingPlayers) do
                taken[wp.seatIndex] = true
            end

            local available = {}
            for i=1, loc:getMaxPlayers() do
                if not taken[i] then table.insert(available, i) end
            end

            if #available == 0 then
                Core.NotifyTip(_source, 'Brak dostępnych miejsc.', 6000)

                return
            end

            if not hasMoney(_source, game:getAnte()) then
                Core.NotifyTip(_source, "Nie masz wystarczająco pieniędzy na grę.", 6000)

                return
            end

            local seatIndex = available[math.random(1, #available)]
            table.insert(loc.waitingPlayers, { netId = _source, name = truncateString(playersChosenName, 12), seatIndex = seatIndex })
            TriggerClientEvent("rainbow_poker:Client:ReturnJoinGame", _source, tableLocationIndex, { order = seatIndex }, seatIndex)
            Core.NotifyTip(_source, 'You will join next hand.', 6000)
            TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", -1, locations)
            return
        else
            if Config.DebugPrint then print("Dołączenie do gry: brak oczekującej gry w lokalizacji", tableLocationIndex) end

            return
        end
    end

if #pendingGame:getPlayers() >= loc:getMaxPlayers() then
    Core.NotifyTip(_source, 'Ta gra w pokera jest pełna.', 6000)
    return
end

if findPendingGameByPlayerNetId(_source) ~= false then
    Core.NotifyTip(_source, 'Wciąż uczestniczysz w oczekującej grze w pokera.', 6000)
    return
end

if findActiveGameByPlayerNetId(_source) ~= false then
    Core.NotifyTip(_source, 'Wciąż uczestniczysz w aktywnej grze w pokera.', 6000)
    return
end


    playersChosenName = truncateString(playersChosenName, 12)

    local playerNetId = _source

    local taken = {}
    for k,v in pairs(pendingGame:getPlayers()) do
        if v.seatIndex then
            taken[v.seatIndex] = true
        end
    end

    local available = {}
    for i=1, loc:getMaxPlayers() do
        if not taken[i] then
            table.insert(available, i)
        end
    end

if not hasMoney(_source, pendingGame:getAnte()) then
    Core.NotifyTip(_source, "Nie masz wystarczająco pieniędzy na grę.", 6000)
    return
end


    local seatIndex = available[math.random(1, #available)]
    local pendingPlayer = Player:New({
        netId = playerNetId,
        name = playersChosenName,
        order = #pendingGame:getPlayers()+1,
    })
    pendingPlayer.seatIndex = seatIndex

    pendingGame:addPlayer(pendingPlayer)

    TriggerClientEvent("rainbow_poker:Client:ReturnJoinGame", _source, tableLocationIndex, pendingPlayer, pendingPlayer.seatIndex)
    TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", -1, locations)
end)

RegisterServerEvent("rainbow_poker:Server:FinalizePendingGameAndBegin", function(tableLocationIndex)
    local _source = source

    if Config.DebugPrint then print("FinalizePendingGameAndBegin", tableLocationIndex) end

local loc = locations[tableLocationIndex]
if not loc then
    if Config.DebugPrint then print("FinalizePendingGameAndBegin: nieprawidłowy indeks lokalizacji", tableLocationIndex) end
    return
end

local pendingGame = loc:getPendingGame()
if not pendingGame then
    if Config.DebugPrint then print("FinalizePendingGameAndBegin: brak oczekującej gry w lokalizacji", tableLocationIndex) end
    return
end

if #pendingGame:getPlayers() < 2 then
    Core.NotifyTip(_source, 'Do swojej gry w pokera potrzebujesz co najmniej 1 innego gracza.', 6000)
    return
elseif #pendingGame:getPlayers() > 12 then
    Core.NotifyTip(_source, 'W Twojej grze w pokera nie może być więcej niż 12 graczy.', 6000)
    return
end

for k,v in pairs(pendingGame:getPlayers()) do
    if not hasMoney(v:getNetId(), pendingGame:getAnte()) then
        TriggerEvent("rainbow_poker:Server:CancelPendingGame", tableLocationIndex)
        Core.NotifyTip(v:getNetId(), "Nie masz wystarczająco pieniędzy na ante.", 6000)
        return
    end
end


    local activeGamePlayers = {}
    for k,v in pairs(pendingGame:getPlayers()) do
        if takeMoney(v:getNetId(), pendingGame:getAnte()) then
            table.insert(activeGamePlayers, Player:New({
                netId = v:getNetId(),
                name = v:getName(),
                order = v:getOrder(),
                seatIndex = v.seatIndex,
                totalAmountBetInGame = pendingGame:getAnte(),
            }))
        else
            TriggerEvent("rainbow_poker:Server:CancelPendingGame", tableLocationIndex)
            return
        end
    end

    local hostNetId = pendingGame:getInitiatorNetId()
    local hostSeat = nil
    for _,p in pairs(pendingGame:getPlayers()) do
        if p:getNetId() == hostNetId then
            hostSeat = p.seatIndex or p:getSeatIndex()
            break
        end
    end

    if not hostSeat and #activeGamePlayers > 0 then
        hostSeat = activeGamePlayers[1].seatIndex or activeGamePlayers[1]:getSeatIndex()
    end

    if hostSeat then
        sortAndAssignOrders(activeGamePlayers, hostSeat)
    end

    local newActiveGame = Game:New({
        locationIndex = tableLocationIndex,
        players = activeGamePlayers,
        ante = pendingGame:getAnte(),
        bettingPool = pendingGame:getAnte() * #pendingGame:getPlayers(),
    })

    newActiveGame:init()
    newActiveGame:moveToNextRound()

    activeGames[tableLocationIndex] = newActiveGame

    locations[tableLocationIndex]:setPendingGame(nil)
    locations[tableLocationIndex]:setState(LOCATION_STATES.GAME_IN_PROGRESS)

    TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", -1, locations)

    for k,player in pairs(newActiveGame:getPlayers()) do
        local seatIndexToSend = player:getOrder()
        for _,p in pairs(pendingGame:getPlayers()) do
            if p:getNetId() == player:getNetId() and p.seatIndex then
                seatIndexToSend = p.seatIndex
                break
            end
        end
        TriggerClientEvent("rainbow_poker:Client:StartGame", player:getNetId(), newActiveGame, player.seatIndex or seatIndexToSend)
    end

    Wait(1000)
end)

RegisterServerEvent("rainbow_poker:Server:CancelPendingGame", function(tableLocationIndex)
    local _source = source

if Config.DebugPrint then print("Anulowanie oczekującej gry", tableLocationIndex) end

local loc = locations[tableLocationIndex]
if not loc then
    if Config.DebugPrint then print("CancelPendingGame: nieprawidłowy indeks lokalizacji", tableLocationIndex) end
    return
end

if not loc:getPendingGame() then
    if Config.DebugPrint then print("CancelPendingGame: brak oczekującej gry w lokalizacji", tableLocationIndex) end
    return
end

for k,v in pairs(loc:getPendingGame():getPlayers()) do
    TriggerClientEvent("rainbow_poker:Client:CancelPendingGame", v:getNetId(), tableLocationIndex)
    Core.NotifyTip(v:getNetId(), 'Oczekująca gra w pokera została anulowana.', 6000)
end


    locations[tableLocationIndex]:setPendingGame(nil)
    locations[tableLocationIndex]:setState(LOCATION_STATES.EMPTY)

    TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", -1, locations)
end)

RegisterServerEvent("rainbow_poker:Server:PlayerActionCheck", function(tableLocationIndex)
    local _source = source

    if Config.DebugPrint then print("rainbow_poker:Server:PlayerActionCheck", _source, tableLocationIndex) end

    local game = findActiveGameByPlayerNetId(_source)

    game:stopTurnTimer()
    game:onPlayerDidActionCheck(_source)

    if not game:advanceTurn() then
        checkForWinCondition(game)
    end

    TriggerUpdate(game)
end)

RegisterServerEvent("rainbow_poker:Server:PlayerActionRaise", function(amountToRaise)
    local _source = source

    if Config.DebugPrint then print("rainbow_poker:Server:PlayerActionRaise - _source, amountToRaise:", _source, amountToRaise) end

    local game = findActiveGameByPlayerNetId(_source)
    local player = game and game:findPlayerByNetId(_source) or nil
    if not game or not player or game:getCurrentTurn() ~= player:getOrder() or player:getIsAllIn() then
        return
    end

    game:stopTurnTimer()

    amountToRaise = tonumber(amountToRaise)
    if takeMoney(_source, amountToRaise) then
        game:onPlayerDidActionRaise(_source, amountToRaise)
    else
        local cash = getCash(_source)
        if cash <= 0 then
            fold(_source)
            return
        end
        local potBefore = game:getBettingPool()
        if takeMoney(_source, cash) then
            game:addSidePot(potBefore)
            game:onPlayerDidActionAllIn(_source, cash)
        end
    end

    if not game:advanceTurn() then
        checkForWinCondition(game)
    end

    TriggerUpdate(game)
end)

RegisterServerEvent("rainbow_poker:Server:PlayerActionCall", function()
    local _source = source

    if Config.DebugPrint then print("rainbow_poker:Server:PlayerActionCall", _source) end

    local game = findActiveGameByPlayerNetId(_source)

    if not game then return end
    local player = game:findPlayerByNetId(_source)
    if not player or game:getCurrentTurn() ~= player:getOrder() then
        Core.NotifyTip(_source, 'Not your turn.', 4000)
        return
    end
    if player:getIsAllIn() then
        return
    end

    game:stopTurnTimer()

    local player = game:findPlayerByNetId(_source)
    local amount = game:getRoundsHighestBet() - player:getAmountBetInRound()

    if takeMoney(_source, amount) then
        game:onPlayerDidActionCall(_source)
    else
        local cash = getCash(_source)
        if cash <= 0 then
            fold(_source)
            return
        end
        local potBefore = game:getBettingPool()
        if takeMoney(_source, cash) then
            game:addSidePot(potBefore)
            game:onPlayerDidActionAllIn(_source, cash)
        end
    end

    if not game:advanceTurn() then
        checkForWinCondition(game)
    end

    TriggerUpdate(game)
end)

RegisterServerEvent("rainbow_poker:Server:PlayerActionFold", function()
    local _source = source
    if Config.DebugPrint then print("rainbow_poker:Server:PlayerActionFold", _source) end
    fold(_source)
end)

RegisterServerEvent("rainbow_poker:Server:PlayerLeave", function()
    local _source = source
    if Config.DebugPrint then print("rainbow_poker:Server:PlayerLeave", _source) end

    local game = findActiveGameByPlayerNetId(_source)
    local player = game:findPlayerByNetId(_source)
    if Config.DebugPrint then print("rainbow_poker:Server:PlayerLeave - player", player) end
    if game:getStep() ~= ROUNDS.SHOWDOWN and player:getHasFolded() == false then
print("OSTRZEŻENIE: Gracz próbuje opuścić grę przed showdown, mimo że jeszcze nie spasował.", _source)
return

    end

    TriggerClientEvent("rainbow_poker:Client:ReturnPlayerLeave", _source)

    if game and player then
        player.hasLeftSession = true
    end
end)

function checkForWinCondition(game)
    if Config.DebugPrint then print("checkForWinCondition()") end

    local isWinCondition = false

    if game:getStep() == ROUNDS.RIVER then
        if Config.DebugPrint then print("checkForWinCondition() - prawda - z powodu River") end
        isWinCondition = true
        game:moveToNextRound()
    end

    local numPlayersFolded = 0
    for k,player in pairs(game:getPlayers()) do
        if player:getHasFolded() then
            numPlayersFolded = numPlayersFolded + 1
        end
    end

    if numPlayersFolded >= #game:getPlayers()-1 then
        if Config.DebugPrint then print("checkForWinCondition() - prawda - z powodu spasowania") end
        isWinCondition = true
    end

    if isWinCondition then
        game:stopTurnTimer()

        local winScenario = getWinScenarioFromSetOfPlayers(game:getPlayers(), game:getBoard(), game:getStep())
        if Config.DebugPrint then print("checkForWinCondition() - WYGRANA - winScenario:", winScenario) end

        if not winScenario:getIsTrueTie() then
            local winnerNetId
            if winScenario:getWinningHand() then
                winnerNetId = winScenario:getWinningHand():getPlayerNetId()
            else

                for k,player in pairs(game:getPlayers()) do
                    if not player:getHasFolded() then
                        winnerNetId = player:getNetId()
                        break
                    end
                end
            end
            if winnerNetId then
                giveMoney(winnerNetId, game:getBettingPool())
            end
        else
            local splitAmount = game:getBettingPool() / #winScenario:getTiedHands()
            for k,tiedHand in pairs(winScenario:getTiedHands()) do
                local pid = tiedHand:getPlayerNetId()
                giveMoney(pid, splitAmount)
            end
        end

for k,player in pairs(game:getPlayers()) do
    TriggerClientEvent("rainbow_poker:Client:AlertWin", player:getNetId(), winScenario)
end

for k,player in pairs(game:getPlayers()) do
    Core.NotifyTip(player:getNetId(), 'Następna runda za 10 sekund. Naciśnij STRZAŁKĘ W DÓŁ, aby opuścić grę.', 10000)
end


Citizen.SetTimeout(10 * 1000, function()
    local continuingPlayers = {}
    for k,player in pairs(game:getPlayers()) do
        if not player.hasLeftSession then
            table.insert(continuingPlayers, player)
        end
    end

    if #continuingPlayers < 2 then
        endAndCleanupGame(game)
        return
    end

    local activeGamePlayers = {}
    for k,player in ipairs(continuingPlayers) do
        if takeMoney(player:getNetId(), game:getAnte()) then
            table.insert(activeGamePlayers, Player:New({
                netId = player:getNetId(),
                name = player:getName(),
                order = #activeGamePlayers + 1,
                seatIndex = player.seatIndex,
                totalAmountBetInGame = game:getAnte(),
            }))
        else
            Core.NotifyTip(player:getNetId(), 'Niewystarczające środki na grę. Opuść stół.', 10000)
        end  -- <<< zamyka 'if'
    end  -- <<< zamyka 'for'

    local locationIndex = game:getLocationIndex()
    local ante = game:getAnte()
    local loc = locations[locationIndex]
    local hasWaiting = (loc and loc.waitingPlayers and #loc.waitingPlayers > 0)

    if hasWaiting then
        endAndCleanupGame(game)
    end

    if loc and loc.waitingPlayers then
        for _,wp in ipairs(loc.waitingPlayers) do
            if takeMoney(wp.netId, ante) then
                table.insert(activeGamePlayers, Player:New({
                    netId = wp.netId,
                    name = wp.name,
                    order = #activeGamePlayers + 1,
                    seatIndex = wp.seatIndex,
                    totalAmountBetInGame = ante,
                }))
            else
                Core.NotifyTip(wp.netId, 'Niewystarczające środki na grę. Opuść kolejkę.', 10000)
            end  -- <<< zamyka 'if'
        end  -- <<< zamyka 'for'
        loc.waitingPlayers = {}
    end


            if #activeGamePlayers < 2 then
                if not hasWaiting then
                    endAndCleanupGame(game)
                end
                return
            end

            local prevFirst = game:findPlayerByOrder(1)
            local prevSeat = nil
            if prevFirst then prevSeat = prevFirst.seatIndex or prevFirst:getSeatIndex() end
            local maxSeats = 6
            if loc and loc.getMaxPlayers then maxSeats = loc:getMaxPlayers() end
            local startSeat = prevSeat and nextStartingSeat(prevSeat, maxSeats, activeGamePlayers) or ((activeGamePlayers[1] and (activeGamePlayers[1].seatIndex or activeGamePlayers[1]:getSeatIndex())) or 1)
            sortAndAssignOrders(activeGamePlayers, startSeat)

            local newActiveGame = Game:New({
                locationIndex = locationIndex,
                players = activeGamePlayers,
                ante = ante,
                bettingPool = ante * #activeGamePlayers,
            })

            newActiveGame:init()
            newActiveGame:moveToNextRound()

            activeGames[locationIndex] = newActiveGame

            if hasWaiting and locations[locationIndex] then
                locations[locationIndex]:setState(LOCATION_STATES.GAME_IN_PROGRESS)
            end

            for k,player in pairs(newActiveGame:getPlayers()) do
                TriggerClientEvent("rainbow_poker:Client:StartGame", player:getNetId(), newActiveGame, player.seatIndex or player:getOrder())
            end

            TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", -1, locations)
        end)
    else
        game:moveToNextRound()
    end
end

function endAndCleanupGame(game)
    local locationIndex = game:getLocationIndex()

    if Config.DebugPrint then print("endAndCleanupGame - locationIndex:", locationIndex) end

    for k,player in pairs(game:getPlayers()) do
        TriggerClientEvent("rainbow_poker:Client:CleanupFinishedGame", player:getNetId())
    end

    locations[locationIndex]:setState(LOCATION_STATES.EMPTY)
    activeGames[locationIndex] = nil

if Config.DebugPrint then print("endAndCleanupGame - usunięto grę") end


    game = nil

    TriggerClientEvent("rainbow_poker:Client:UpdatePokerTables", -1, locations)
end

function fold(targetNetId)
    local game = findActiveGameByPlayerNetId(targetNetId)

    game:stopTurnTimer()
    game:onPlayerDidActionFold(targetNetId)

    local numNotFolded = 0
    for k,player in pairs(game:getPlayers()) do
        if not player:getHasFolded() then
            numNotFolded = numNotFolded + 1
        end
    end

    if numNotFolded > 1 then
        if not game:advanceTurn() then
            checkForWinCondition(game)
        end
        TriggerUpdate(game)
    else
        game:setStep(ROUNDS.SHOWDOWN)
        checkForWinCondition(game)
        TriggerUpdate(game)
    end
end

function getCash(targetNetId)
    local user = Core.getUser(targetNetId)
    if not user then return 0 end
    local character = user.getUsedCharacter
    return character.money or 0
end

function hasMoney(targetNetId, amount)
    amount = tonumber(amount)
    local cash = getCash(targetNetId)
    return cash >= amount
end

function takeMoney(targetNetId, amount)
    amount = tonumber(amount)
    local user = Core.getUser(targetNetId)
    if not user then return false end
    local character = user.getUsedCharacter
    local cash = character.money or 0
    
if cash < amount then
    Core.NotifyTip(targetNetId, string.format("Nie masz $%.2f!", amount), 20000)
    return false
end

character.removeCurrency(0, amount)
Core.NotifyTip(targetNetId, string.format("Postawiłeś $%.2f.", amount), 6000)
return true
end

function giveMoney(targetNetId, amount)
    amount = tonumber(amount)
    local user = Core.getUser(targetNetId)
    if not user then return false end
    local character = user.getUsedCharacter
    character.addCurrency(0, amount)
    Core.NotifyTip(targetNetId, string.format("Wygrałeś $%.2f.", amount), 6000)
    return true
end


function truncateString(str, max)
    if string.len(str) > max then
        return string.sub(str, 1, max) .. "…"
    else
        return str
    end
end

function TriggerUpdate(game)
    for k,player in pairs(game:getPlayers()) do
        TriggerClientEvent("rainbow_poker:Client:TriggerUpdate", player:getNetId(), game)
    end
end

function findActiveGameByPlayerNetId(playerNetId)
    for k,v in pairs(activeGames) do
        for k2,v2 in pairs(v:getPlayers()) do
            if v2:getNetId() == playerNetId then
                return v
            end
        end
    end
    return false
end

function findPendingGameByPlayerNetId(playerNetId)
    for k,v in pairs(pendingGames) do
        for k2,v2 in pairs(v:getPlayers()) do
            if v2:getNetId() == playerNetId then
                return v
            end
        end
    end
    return false
end

AddEventHandler("onResourceStop", function(resourceName)
    if GetCurrentResourceName() == resourceName then
        locations = {}
        pendingGames = {}
        activeGames = {}
    end
end)