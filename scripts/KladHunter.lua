-- Для иконок сайт 1: https://fontawesome.com/v4/cheatsheet/
--[[
Код для трансформации в "\239\138\185" на python:

def u2utf8(cp: int) -> str:
    b = chr(cp).encode('utf-8')
    return ''.join(f'\\{byte}' for byte in b)

if __name__ == '__main__':
    print(u2utf8(0xF2B9))  # \239\138\185  (fa-address-book)
    print(u2utf8(0xF129))  # \239\132\169  (fa-info)

]]

script_name('TreasureHunter')
script_author('xMercy')
script_version('1.0')
script_description('Treasure Hunter: клады, территории, доп. клады, чекер игроков. Открыть меню: /kh')

local imgui = require 'mimgui'
local ffi_ok, ffi = pcall(require, 'ffi')
local sampev = require 'lib.samp.events'
local arzev = require 'arizona-events'

local encoding = require 'encoding'
encoding.default = 'CP1251'
u8 = encoding.UTF8
-- Файл сохранён в Windows-1251, mimgui рисует текст как UTF-8:
-- перед каждой кириллической строкой для mimgui пишем u8:encode(...).

local resX, resY = getScreenResolution()

local function clamp(v, a, b)
    if v < a then return a elseif v > b then return b else return v end
end
local function easeOutCubic(t) return 1 - (1 - t) ^ 3 end

-------------------------------------------------------------------- DEBUG
-- DEBUG = true: служебная информация для разработчика пишется в print (moonloader.log / консоль),
-- и при каждой такой записи на экране на 0.35 с показывается printStringNow('[TreasureHunter] Print Debug').
-- DEBUG = false: ничего не пишется и ничего не показывается.
local DEBUG = false
local function dbg(fmt, ...)
    if not DEBUG then return end
    local ok, msg = pcall(string.format, fmt, ...)
    print('[TreasureHunter][DEBUG] ' .. (ok and msg or tostring(fmt)))
    pcall(printStringNow, '[TreasureHunter] Print Debug', 350)
end

-------------------------------------------------------------------- Config
-- Значения по умолчанию + загрузка/сохранение — всё внутри moonloader\config\KladHunter (п.7,8).
-- ВАЖНО: не используем библиотеку inicfg — она сама подставляет свой путь к moonloader\config\,
-- из-за чего при указании собственной подпапки путь задваивался (moonloader\config\config\...).
-- Вместо этого — свой минимальный .ini читатель/писатель на чистом io.open с полностью
-- предсказуемым путём.

-- Все пути собраны в одну таблицу — экономит локальные слоты (лимит Lua 200 шт. на чанк)
local PATHS = {}
PATHS.mlConfigDir  = 'moonloader\\config'
PATHS.xmercyDir = PATHS.mlConfigDir .. '\\xMercy' -- общая папка xMercy: тут лежат шрифты
PATHS.kladhunterDir = PATHS.xmercyDir .. '\\KladHunter' -- координаты, игроки, награды, настройки
PATHS.oldKladhunterDir = PATHS.mlConfigDir .. '\\KladHunter' -- прежнее место (для одноразового переноса)
PATHS.treasureCoords = PATHS.kladhunterDir .. '\\TreasureCoords.txt'
PATHS.rewardFile = PATHS.kladhunterDir .. '\\RewardLog.txt' -- награда с кладов по дням (п.7)
PATHS.iniFile = PATHS.kladhunterDir .. '\\KladHunter.ini'

local lfsOk, lfs = pcall(require, 'lfs')
local function ensureConfigDir()
    if lfsOk then
        pcall(lfs.mkdir, PATHS.mlConfigDir)
        pcall(lfs.mkdir, PATHS.xmercyDir)
        pcall(lfs.mkdir, PATHS.kladhunterDir)
    else
        pcall(os.execute, 'mkdir "' .. PATHS.mlConfigDir .. '" 2>nul')
        pcall(os.execute, 'mkdir "' .. PATHS.xmercyDir .. '" 2>nul')
        pcall(os.execute, 'mkdir "' .. PATHS.kladhunterDir .. '" 2>nul')
    end
end
ensureConfigDir()

-- Одноразовый перенос из старой папки (moonloader/config/KladHunter): копируем файлы, которых ещё нет
-- в новой папке. Старые файлы НЕ удаляются.
pcall(function()
    for _, nm in ipairs({ 'KladHunter.ini', 'TreasureCoords.txt', 'RewardLog.txt', 'PlayerWatchlist.txt' }) do
        local newP, oldP = PATHS.kladhunterDir .. '\\' .. nm, PATHS.oldKladhunterDir .. '\\' .. nm
        local fn = io.open(newP, 'rb')
        if fn then
            fn:close()
        else
            local fo = io.open(oldP, 'rb')
            if fo then
                local data = fo:read('*a')
                fo:close()
                local fw = io.open(newP, 'wb')
                if fw then fw:write(data) fw:close() end
            end
        end
    end
end)

local DEFAULTS = {
    main = {
        enabled   = true,
        option2   = false,
        lifetime  = 1.5,
        alpha     = 255,
        plate     = true,
        colorA    = 0xFFFFFFFF,
        colorCrit = 0xFFFFE04A,
        bg        = 'Переливы',
        extra1    = false,
        extra2    = 50,
    },
    zones = {
        autoRestore          = true,  -- авто-возврат территории клада при её исчезновении (п.27)
        closeRadius          = 10.0,  -- дистанция (м): ближе неё иконка/метка скрываются (п.10)
        markerRadius         = 100.0, -- дистанция (м): дальше неё метка/маркер вообще не появляются (п.11)
        hideServerMapIcon    = false, -- скрывать иконки сервера на карте (см. onSetMapIcon, п.18)
        hideServerMapIconOnlyInZone = false, -- если true — скрывать только внутри зоны клада (п.8)
        markersEnabled       = true,  -- общий вкл/выкл отрисовки маркеров и иконок (п.22)
        autoRemoveMarkers    = true,  -- автоматическое удаление меток/маркеров при отдалении (п.24)
        autoExcavate         = false, -- автоматическое выкапывание в мини-игре клада (п.5)
        autoExcavateDelayMs  = 1000,  -- задержка перед авто-кликом, 500-10000мс (п.5)
        playersOnlyOnline    = false, -- фильтр "только онлайн" во вкладке Игроки (п.26)
        detectorRenderEnabled = true, -- рисовать ли зону/след металлоискателя вообще (п.5)
    },
    prices = {}, -- стоимость за 1 шт. награды, ключ = название предмета (п.3); пусто по умолчанию,
                 -- но секция должна существовать, иначе loadIni ниже не подхватит её из файла
}

-- простейший .ini: секции [name], пары key=value (bool/number/string автоопределяются)
local function serializeIni(t)
    local lines = {}
    for section, kv in pairs(t) do
        table.insert(lines, '[' .. section .. ']')
        for k, v in pairs(kv) do
            table.insert(lines, tostring(k) .. '=' .. tostring(v))
        end
        table.insert(lines, '')
    end
    return table.concat(lines, '\n')
end

local function parseIniValue(s)
    if s == 'true' then return true end
    if s == 'false' then return false end
    local n = tonumber(s)
    if n ~= nil then return n end
    return s
end

local function loadIni(defaults, path)
    local result = {}
    for section, kv in pairs(defaults) do
        result[section] = {}
        for k, v in pairs(kv) do result[section][k] = v end
    end

    local f = io.open(path, 'r')
    if f then
        local section = nil
        for line in f:lines() do
            local trimmed = line:match('^%s*(.-)%s*$')
            local sec = trimmed:match('^%[(.+)%]$')
            if sec then
                section = sec
            elseif section and result[section] then
                -- ключ — всё до ПОСЛЕДНЕГО '=' (в названии предмета может быть '='), значение чисел/слов '=' не содержит
                local k, v = trimmed:match('^(.*)=%s*([^=]*)$')
                if k then k = k:match('^(.-)%s*$') end
                if k and k ~= '' then result[section][k] = parseIniValue(v) end
            end
        end
        f:close()
    end
    return result
end

local function saveIni(t, path)
    local f, err = io.open(path, 'w')
    if not f then return false, err end
    f:write(serializeIni(t))
    f:close()
    return true
end

local ini = loadIni(DEFAULTS, PATHS.iniFile)
local cfg = ini.main
local zcfg = ini.zones
local prices = ini.prices -- цена за 1 шт. награды, ключ = название предмета (п.3)

local function saveCfg()
    local ok, res, err = pcall(saveIni, ini, PATHS.iniFile)
    if not ok then
        dbg('saveCfg: ошибка при сохранении ini: %s', tostring(res))
    elseif res == false then
        dbg('saveCfg: не удалось записать %s: %s', tostring(PATHS.iniFile), tostring(err))
    end
end

--------------------------------------------------------------------- Клады: настройки (правь прямо тут)
-- Собрано в одну таблицу CFG (вместо кучи отдельных local) — так же легко править
-- (CFG.distCheckInterval = ...), но не упирается в лимит Lua на 200 локальных переменных
-- верхнего уровня, который этот файл уже дважды пробивал по мере роста функционала.
local CFG = {
    -- Как часто (в секундах) пересчитывать дистанции до кладов. Раз в 0.5с — не каждый кадр.
    distCheckInterval = 0.5,
    -- Внешний вид радарной метки основных кладов (см. список спрайтов SA-MP/GTA blip).
    blipColor = 5,
    blipIcon  = 56,
    -- Внешний вид радарной метки бонусных (секретных) кладов.
    bonusBlipColor = 2,
    bonusBlipIcon  = 43,
    -- Тип 3D-маркера на земле (см. createUser3dMarker в TreasureMAP.lua — тот же тип).
    marker3dType = 4,
    marker3dZOffset = 1.5,
    -- Фиксировано в коде (не настраивается в игре), см. п.23: если игрок подошёл к нашей метке
    -- ближе closeRadius — снимаем только иконку, маркер красим в зелёный и оставляем; полностью
    -- убираем маркер только когда игрок отойдёт от точки дальше этого радиуса.
    markerRetreatRadius = 20.0,
    -- Фиксировано в коде, см. п.20: если игрок выкопал клад, находясь в этом радиусе от
    -- бонусного клада — считаем бонусный клад тоже выкопанным и убираем из списка.
    bonusTreasureDigRadius = 15.0,
    -- Максимум одновременно хранимых восстановленных территорий (п.19): при превышении
    -- удаляется самая старая (первая созданная), последние maxSavedZones всегда остаются.
    maxSavedZones = 3,
    -- По этому радиусу чекпоинта опознаём именно бонусный (секретный) клад среди прочих
    -- race-чекпоинтов, которые ставит сервер (п.15).
    bonusCheckpointRadius = 10.0,
    -- Радиус метки/чекпоинта, которую сам ставишь на бонусный клад из "Доп. клады" (п.5).
    bonusMarkerRadius = 2.0,
    -- Как часто (в секундах) на всякий случай пересобирать список кладов внутри видимых зон
    -- заново с нуля — подстраховка от рассинхрона (клад дописался в разгар сессии, зона
    -- эвикнулась по лимиту maxSavedZones и т.п.), см. п.2.
    fullResyncInterval = 20.0, -- подстраховочный пересбор активных точек (основной — по событиям зон/точек)
    -- Сколько ждать после открытия мини-игры перед авто-кликом (п.5).
    autoExcavateDelayMs = 1000,
    -- Анти-дубликат награды: не добавлять повторно чаще чем раз в 30с (п.7).
    rewardAddCooldown = 30.0,
    -- Сколько строк наград показывать на одной странице внутри дня (п.1).
    rewardPageSize = 7,
    -- Ширина плашек суммы в списке наград (и "Итого за день") — чтобы влезали суммы вида 520.000.000$.
    rewardBoxW = 140,
    maxPrice = 999999999999, -- предел цены за 1 шт. (12 цифр): защита буфера ввода и отображения
    -- Сколько секунд после открытия мини-игры выкапывания пакет награды ещё считается наградой за клад.
    -- Флаг "мини-игра была" гасится после первой записанной награды (раньше жил вечно -> фантомные предметы).
    rewardWindowSec = 60.0,
    -- В GTA SA одновременно живёт ограниченное число 3D-маркеров (около 32, часть занимает сама игра),
    -- поэтому сами маркеры ставим только на ближайшие точки; радарные иконки лимит не затрагивает.
    max3dMarkers = 28,
    -- Запасная отрисовка: если точка ближе этого радиуса (м), рисуем свой зелёный круг и столб поверх
    -- нативного 3D-маркера (на малой дистанции игра может его не показывать). 0 — выключено.
    nearFallbackRadius = 8.0,
    -- Точка клада ближе этого расстояния (м) к уже известной считается дубликатом и в файл не пишется.
    duplicateRadius = 2.0,
}

for k, v in pairs(prices) do -- битые значения из .ini (не число, nan, минус, огромные) приводим к допустимым
    if type(v) ~= 'number' or v ~= v or v < 0 then prices[k] = 0
    elseif v > CFG.maxPrice then prices[k] = CFG.maxPrice end
end

--------------------------------------------------------------------- Зона металлоискателя (из KladLogger.lua)
-- CEF-событие event.detector-radar.setRadarLevel: 5=красный, 4=белый, 3=оранжевый, 2=жёлтый, 1=зелёный.
-- Обрабатываем 5 (красный), 2 (жёлтый), 1 (зелёный) и 4 (белый, самый узкий — радиус 8 м); 3 (оранжевый) игнорируется.
-- Используем именно уровень (не частоту моргания — она менее надёжный сигнал для порога).
-- Собрано в одну таблицу (вместо 9 отдельных local) — упираемся в лимит Lua на 200
-- локальных переменных верхнего уровня, а каждая строка "local X = ..." его приближает.
-- Править значения так же просто: DET.redRadius = 105.0 и т.п.
local DET = {
    redRadius      = 105.0,  -- радиус зоны при появлении красного уровня (5)
    yellowRadius   = 37.5,  -- радиус зоны при переходе на жёлтый уровень (2)
    greenRadius    = 20.0,  -- радиус зоны при переходе на зелёный уровень (1)
    whiteRadius    = 8.0,   -- радиус зоны при переходе на белый уровень (4) — самый точный
    colorRed       = 0xFFFF3333,
    colorYellow    = 0xFFFFD733,
    colorGreen     = 0xFF33CC33,
    colorWhite     = 0xFFFFFFFF,
    trailColor     = 0xFFFFFFFF, -- след за игроком — белая линия
    trailStep      = 3.0,   -- метры между точками следа
    trailMaxPoints = 2000,  -- предел длины следа (старые точки отбрасываются), чтобы список не рос бесконечно
    circlePolygons = 48,
    circleWidth    = 2.0,
    trailWidth     = 2.5,
}

-- Приоритет уровней зоны металлоискателя: чем БОЛЬШЕ rank, тем точнее (ближе к кладу).
-- Правило (п.3): зона может только СУЖАТЬСЯ (red->yellow->green), но никогда не расширяться
-- обратно и не пересоздаваться на новом месте, пока игрок не выкопает клад или не уедет далеко.
local DETECTOR_TIERS = {
    [5] = { radius = DET.redRadius,    color = DET.colorRed,    rank = 1 },
    [2] = { radius = DET.yellowRadius, color = DET.colorYellow, rank = 2 },
    [1] = { radius = DET.greenRadius,  color = DET.colorGreen,  rank = 3 },
    [4] = { radius = DET.whiteRadius,  color = DET.colorWhite,  rank = 4 }, -- белый: ещё уже зелёного
}

-- Координаты кладов НЕ хранятся в коде (п.7) — полностью загружаются из PATHS.treasureCoords
-- (см. loadTreasureCoordsFromFile ниже) и дополняются на лету, когда ты сам выкопал клад (см. п.5).
local treasurePoints = {}

local loadedFromFileCount = 0 -- для отображения в "Общее" (п.9)

local function loadTreasureCoordsFromFile()
    local f = io.open(PATHS.treasureCoords, 'r')
    if not f then return end
    for line in f:lines() do
        local x, y, z = line:match('{%s*(-?[%d%.]+),%s*(-?[%d%.]+),%s*(-?[%d%.]+)%s*}')
        local nx, ny, nz = tonumber(x), tonumber(y), tonumber(z)
        if nx and ny and nz then -- битая строка вроде "{ 1.2.3, ..}" даёт nil и раньше портила весь список
            table.insert(treasurePoints, { nx, ny, nz })
            loadedFromFileCount = loadedFromFileCount + 1
        end
    end
    f:close()
end
loadTreasureCoordsFromFile()
dbg('Загружено точек кладов из файла: %d (%s)', loadedFromFileCount, PATHS.treasureCoords)

--------------------------------------------------------------------- Клады: статистика за сессию (п.6)
local stats = {
    dugCount = 0,      -- сколько кладов сам выкопал за сессию
    bonusCount = 0,    -- сколько бонусных (секретных) кладов найдено за сессию (п.3)
    restoredCount = 0, -- сколько раз территория была авто-восстановлена за сессию
}

--------------------------------------------------------------------- Клады: свой ник (для сверки в чате)
local function getMyNickname()
    local ok, id = pcall(function() return select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)) end)
    if not ok or not id then return nil end
    local ok2, nick = pcall(sampGetPlayerNickname, id)
    if ok2 then return nick end
    return nil
end

--------------------------------------------------------------------- Клады: цвет зоны (п.3)
-- если новая территория географически пересекается с уже существующей — рисуем её
-- другим полупрозрачным цветом, чтобы было видно, что это отдельная территория
local function argbToInt32(a, r, g, b)
    local u = (a * 0x1000000) + (r * 0x10000) + (g * 0x100) + b
    if u >= 0x80000000 then u = u - 0x100000000 end
    return u
end

local ZONE_COLOR_PRIMARY   = argbToInt32(0x80, 0xFF, 0xFF, 0xFF) -- полупрозрачный белый (как раньше)
local ZONE_COLOR_SECONDARY = argbToInt32(0x70, 0xFF, 0xA5, 0x00) -- приглушённый полупрозрачный оранжевый

--------------------------------------------------------------------- Клады: радарные метки (из GraffitiChecker)
local mem = require 'memory'

if ffi_ok then
    pcall(function()
        ffi.cdef[[
            typedef struct{float x,y,z;} CVector;
            typedef int(__cdecl*SetCoordBlip_t)(int,CVector,unsigned int,int,const char*);
            typedef void(__cdecl*BlipColour_t)(int,unsigned int);
            typedef void(__cdecl*BlipScale_t)(int,int);
            typedef void(__cdecl*BlipSprite_t)(int,unsigned int);
            typedef void(__cdecl*ClearBlip_t)(int);
        ]]
    end)
end

local function resolveJmp(a)
    if mem.getuint8(a, true) == 0xE9 then
        local x = mem.getuint32(a + 1, true)
        if x >= 0x80000000 then x = x - 0x100000000 end
        return a + 5 + x
    end
    return a
end

local blipFunctionsOk, fnSetCoordBlip, fnBlipColour, fnBlipScale, fnBlipSprite, fnClearBlip = pcall(function()
    return
        ffi.cast('SetCoordBlip_t', resolveJmp(0x583820)),
        ffi.cast('BlipColour_t',   resolveJmp(0x583AB0)),
        ffi.cast('BlipScale_t',    resolveJmp(0x583CC0)),
        ffi.cast('BlipSprite_t',   resolveJmp(0x583D70)),
        ffi.cast('ClearBlip_t',    resolveJmp(0x587CE0))
end)

if not blipFunctionsOk then
    print('[TreasureHunter] Не удалось инициализировать функции блипов (см. смещения адресов).')
end

local activeTreasureBlips = {} -- список выданных handle, для аварийной зачистки при выходе/дисконнекте

-- создаёт радарную метку в указанной точке, возвращает handle (или nil при неудаче)
local function createTreasureBlip(x, y, z, color, icon)
    if not blipFunctionsOk then return nil end

    local ok, blip = pcall(function()
        local pos = ffi.new('CVector', x, y, z)
        local b = fnSetCoordBlip(4, pos, 0, 3, nil)
        if b and b >= 0 then
            fnBlipColour(b, color or CFG.blipColor)
            fnBlipScale(b, 4)
            fnBlipSprite(b, icon or CFG.blipIcon)
            return b
        end
        return nil
    end)

    if ok and blip then
        table.insert(activeTreasureBlips, blip)
        return blip
    end
    return nil
end

-- удаляет одну конкретную метку по handle
local function removeTreasureBlip(handle)
    if not handle or not blipFunctionsOk then return end
    pcall(fnClearBlip, handle)
    for i, h in ipairs(activeTreasureBlips) do
        if h == handle then table.remove(activeTreasureBlips, i) break end
    end
end

-- аварийная зачистка всех меток разом (дисконнект/выгрузка скрипта)
local function clearAllTreasureBlips()
    if blipFunctionsOk then
        for _, h in ipairs(activeTreasureBlips) do
            pcall(fnClearBlip, h)
        end
    end
    activeTreasureBlips = {}
end

--------------------------------------------------------------------- Клады: RPC для ганг-зон (из trmap 1.3)
local function rpcAddGangZone(id, left, up, right, down, color)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt16(bs, id)
    raknetBitStreamWriteFloat(bs, left)
    raknetBitStreamWriteFloat(bs, up)
    raknetBitStreamWriteFloat(bs, right)
    raknetBitStreamWriteFloat(bs, down)
    raknetBitStreamWriteInt32(bs, color)
    raknetEmulRpcReceiveBitStream(108, bs)
    raknetDeleteBitStream(bs)
end

local function rpcRemoveGangZone(id)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt16(bs, id)
    raknetEmulRpcReceiveBitStream(120, bs)
    raknetDeleteBitStream(bs)
end

--------------------------------------------------------------------- Клады: состояние
local KLAD_ZONE_COLOR = -16776961   -- цвет зоны клада, которую создаёт сервер

local nextLocalZoneId = 700          -- свои ID зон начинаем с 700, чтобы не пересекаться с игрой
local zoneCounter = 0                -- для человеко-читаемой нумерации "Территория #N"

local serverZoneId = nil             -- raw zoneId зоны, которую сейчас показал сервер
local serverZoneBounds = nil         -- {left, up, right, down} этой зоны, если она сейчас видна
local serverZoneVisible = false

local restoredZones = {}             -- { {id, left, up, right, down, num, createdAt}, ... }

local activeTreasurePoints = {}      -- подмножество treasurePoints, что сейчас внутри видимой зоны
local markerState = {}               -- markerState[индекс в treasurePoints] = true/false (метка стоит?)

-- п.13: переключатель НЕ сохраняется в настройках (обычная переменная, не часть ini).
-- По умолчанию false. Когда включён — метки/маркеры показываются для ВСЕХ кладов поблизости
-- (в радиусе markerRadius), а не только для тех, что внутри найденной/восстановленной территории.
local runtimeUI = { showAllNearby = false }

-- pcall с записью причины ошибки в консоль (только при DEBUG; не чаще раза в 5 с на один tag, чтобы не спамить).
-- Возвращает то же, что и pcall, поэтому подставляется вместо него без других правок.
runtimeUI.spcallAt = {}
function runtimeUI.logpcall(tag, ok, ...)
    if not ok and DEBUG then
        local now = os.clock()
        if now - (runtimeUI.spcallAt[tag] or -10) > 5 then
            runtimeUI.spcallAt[tag] = now
            dbg('Ошибка в %s: %s', tag, tostring((...)))
        end
    end
    return ok, ...
end
function runtimeUI.spcall(tag, fn, ...)
    return runtimeUI.logpcall(tag, pcall(fn, ...))
end
-- Цена хранится под ключом названия БЕЗ пробелов по краям (в .ini они всё равно теряются при чтении);
-- читаем с запасным вариантом по точному названию — на случай старых записей.
function runtimeUI.priceKey(name)
    return (tostring(name):match('^%s*(.-)%s*$'))
end
function runtimeUI.priceOf(name)
    local v = prices[runtimeUI.priceKey(name)]
    if v == nil then v = prices[name] end
    return tonumber(v) or 0
end
runtimeUI.visited = {} -- [idx]=true: точка посещена (меток уже нет) — не пересоздавать, пока игрок не уйдёт за markerRadius
runtimeUI.cap3d = CFG.max3dMarkers -- фактический лимит 3D-маркеров: подстраивается, если игра отказывает (-1) раньше CFG.max3dMarkers
-- прокси для переключателя в меню: читает/пишет локальную DEBUG (не сохраняется, стартовое значение — константа выше)
runtimeUI.debugProxy = setmetatable({}, {
    __index = function() return DEBUG end,
    __newindex = function(_, _, v) DEBUG = v and true or false end,
})
local lastDistCheck = 0

-- нормализация прямоугольника: left/right и up/down не всегда идут по возрастанию
local function pointInRect(x, y, rect)
    local minX, maxX = math.min(rect.left, rect.right), math.max(rect.left, rect.right)
    local minY, maxY = math.min(rect.up, rect.down), math.max(rect.up, rect.down)
    return x >= minX and x <= maxX and y >= minY and y <= maxY
end

-- пересекаются ли два прямоугольника (для выбора цвета новой территории, п.3)
local function rectsOverlap(a, b)
    local aMinX, aMaxX = math.min(a.left, a.right), math.max(a.left, a.right)
    local aMinY, aMaxY = math.min(a.up, a.down), math.max(a.up, a.down)
    local bMinX, bMaxX = math.min(b.left, b.right), math.max(b.left, b.right)
    local bMinY, bMaxY = math.min(b.up, b.down), math.max(b.up, b.down)
    return aMinX <= bMaxX and aMaxX >= bMinX and aMinY <= bMaxY and aMaxY >= bMinY
end

-- если новая территория пересекается с уже существующей на карте — берём отличающийся цвет
local function pickZoneColor(newRect)
    for _, z in ipairs(restoredZones) do
        if rectsOverlap(newRect, z) then return ZONE_COLOR_SECONDARY end
    end
    if serverZoneVisible and serverZoneBounds and rectsOverlap(newRect, serverZoneBounds) then
        return ZONE_COLOR_SECONDARY
    end
    return ZONE_COLOR_PRIMARY
end

local function distance2d(x1, y1, x2, y2)
    return math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
end

--------------------------------------------------------------------- Зона металлоискателя: рендер и состояние
local function drawLine3D(x1, y1, z1, x2, y2, z2, color, width)
    local _, sx1, sy1, sz1 = convert3DCoordsToScreenEx(x1, y1, z1)
    local _, sx2, sy2, sz2 = convert3DCoordsToScreenEx(x2, y2, z2)
    if sz1 and sz1 > 1 and sz2 and sz2 > 1 then
        pcall(renderDrawLine, sx1, sy1, sx2, sy2, width, color)
    end
end

local function drawCircleGround(x, y, z, radius, polygons, width, color)
    local step = math.floor(360 / polygons)
    local sX_old, sY_old
    for angle = 0, 360, step do
        local lX = radius * math.cos(math.rad(angle)) + x
        local lY = radius * math.sin(math.rad(angle)) + y
        local _, sX, sY, sZ = convert3DCoordsToScreenEx(lX, lY, z)
        if sZ and sZ > 1 then
            if sX_old and sY_old then
                pcall(renderDrawLine, sX, sY, sX_old, sY_old, width, color)
            end
            sX_old, sY_old = sX, sY
        else
            sX_old, sY_old = nil, nil -- точка за спиной камеры — разрываем линию, а не тянем через весь экран
        end
    end
end

local detectorZone = nil    -- { x, y, z, radius, color, rank } или nil, если сейчас неактивна
local detectorTrail = {}    -- { {x,y,z}, ... } — след пройденного пути внутри зоны
local lastTrailX, lastTrailY = nil, nil

local function clearDetectorZone()
    detectorZone = nil
    detectorTrail = {}
    lastTrailX, lastTrailY = nil, nil
end

-- вызывается при получении уровня 5/2/1 (красный/жёлтый/зелёный).
-- п.1: центр зоны переносится на текущую позицию игрока ТОЛЬКО когда цвет реально сужается
-- (rank растёт: red->yellow->green) — именно в этот момент новое показание детектора точнее
-- старого, поэтому имеет смысл обновить и место. Если же уровень вернулся к тому же или более
-- грубому рангу (жёлтый->красный, повторный заход в жёлтую/зелёную зону и т.п.) — центр, радиус
-- и цвет НЕ трогаем вообще, зона остаётся как была.
-- Убирает точки следа, оказавшиеся вне новой (суженной) зоны. Вызывается ТОЛЬКО при смене цвета
-- (раз в несколько секунд, один проход по списку), а не каждый кадр — оптимизацию не ухудшает,
-- наоборот, дальше рисуется меньше отрезков. Точка [4]=true означает "разрыв": к предыдущей не соединять.
function runtimeUI.pruneTrail()
    local z = detectorZone
    if not z or #detectorTrail == 0 then return end
    local limit = z.radius + DET.trailStep
    local kept, dropped = {}, false
    for _, p in ipairs(detectorTrail) do
        if distance2d(p[1], p[2], z.x, z.y) <= limit then
            if dropped and #kept > 0 then p[4] = true end -- были вырезаны точки — линию не тянем через разрыв
            kept[#kept + 1] = p
            dropped = false
        else
            dropped = true
        end
    end
    dbg('След металлоискателя: %d -> %d точек после сужения зоны (радиус %.1f)', #detectorTrail, #kept, z.radius)
    detectorTrail = kept
end

local function onDetectorLevel(level)
    local tier = DETECTOR_TIERS[level]
    dbg('Металлоискатель: уровень %s%s', tostring(level), tier and '' or ' (игнорируется)')
    if not tier then return end -- уровень 3 (оранжевый) ничего не делает

    if not detectorZone then
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        detectorZone = { x = px, y = py, z = pz, radius = tier.radius, color = tier.color, rank = tier.rank }
        if not lastTrailX then
            lastTrailX, lastTrailY = px, py
            table.insert(detectorTrail, { px, py, pz })
        end
    elseif tier.rank > detectorZone.rank then
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        detectorZone.x, detectorZone.y, detectorZone.z = px, py, pz -- п.1: сужение — переносим центр
        detectorZone.radius = tier.radius
        detectorZone.color = tier.color
        detectorZone.rank = tier.rank
        runtimeUI.pruneTrail() -- зона сузилась: след за её пределами уже не нужен
    end
    -- tier.rank <= detectorZone.rank — более грубый/такой же уровень, чем уже есть — игнорируем
end

local function recordDetectorTrailPoint()
    if not detectorZone then return end
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    if not lastTrailX or distance2d(px, py, lastTrailX, lastTrailY) >= DET.trailStep then
        table.insert(detectorTrail, { px, py, pz })
        lastTrailX, lastTrailY = px, py
        if #detectorTrail > DET.trailMaxPoints then -- отбрасываем самую старую четверть одним проходом
            local nt, from = {}, math.floor(DET.trailMaxPoints * 0.25)
            for i = from, #detectorTrail do nt[#nt + 1] = detectorTrail[i] end
            nt[1][4] = true
            detectorTrail = nt
        end
    end
end

-- запасной маркер для точек совсем рядом (см. CFG.nearFallbackRadius); рисуется каждый кадр
-- Не зависит от состояния меток (авто-удаление, лимит 3D-маркеров, "посещённые" и т.п.): рисуется для ЛЮБОЙ
-- проверяемой точки (в зоне клада, а при "Всегда показывать ближайшие" — для всех) ближе R метров,
-- пока включена настройка "Отрисовка меток и маркеров". Список близких точек (runtimeUI.nearList)
-- собирает updateTreasureDistances раз в 0.5 с с запасом по расстоянию, а здесь — точная проверка по кадру.
function runtimeUI.drawNearFallback()
    local R = CFG.nearFallbackRadius
    local nl = runtimeUI.nearList
    if not R or R <= 0 or not zcfg.markersEnabled or not nl or #nl == 0 then return end
    local px, py = getCharCoordinates(PLAYER_PED)
    for _, idx in ipairs(nl) do
        local pt = treasurePoints[idx]
        if pt and distance2d(px, py, pt[1], pt[2]) <= R then
            local gz = pt[3] - 0.9 -- координата сохранена на уровне пед'а, земля примерно на 1 м ниже
            drawCircleGround(pt[1], pt[2], gz, 0.7, 24, 2.0, DET.colorGreen)
            drawLine3D(pt[1], pt[2], gz, pt[1], pt[2], gz + 2.5, DET.colorGreen, 2.0)
        end
    end
end

local function drawDetectorVisuals()
    if not detectorZone or not zcfg.markersEnabled or not zcfg.detectorRenderEnabled then return end

    drawCircleGround(detectorZone.x, detectorZone.y, detectorZone.z, detectorZone.radius,
        DET.circlePolygons, DET.circleWidth, detectorZone.color)

    for i = 1, #detectorTrail - 1 do
        local a, b = detectorTrail[i], detectorTrail[i + 1]
        if not b[4] then
            drawLine3D(a[1], a[2], a[3], b[1], b[2], b[3], DET.trailColor, DET.trailWidth)
        end
    end
end

-- очистка по выезду за радиус рендера меток (zcfg.markerRadius) от центра зоны
local function checkDetectorRenderDistance()
    if not detectorZone then return end
    local px, py = getCharCoordinates(PLAYER_PED)
    if distance2d(px, py, detectorZone.x, detectorZone.y) > (zcfg.markerRadius or 100.0) then
        clearDetectorZone()
    end
end

-- разбор пакета уровня радара металлоискателя: window.executeEvent('event.detector-radar.setRadarLevel', `[[N]]`)
local function extractDetectorLevel(rawText)
    local eventName, payload = rawText:match("executeEvent%(%s*'(.-)'%s*,%s*`(.-)`%s*%)")
    if eventName ~= 'event.detector-radar.setRadarLevel' then return nil end
    local ok, data = runtimeUI.spcall('decodeJson', decodeJson, payload)
    if ok and type(data) == 'table' and type(data[1]) == 'table' then
        return tonumber(data[1][1])
    end
    return nil
end

-- пересобирает список кладов, которые сейчас лежат внутри ЛЮБОЙ видимой зоны
-- (текущая серверная зона + все восстановленные нами вручную)
-- список прямоугольников всех сейчас видимых зон (текущая серверная + все восстановленные нами)
local function getVisibleZoneRects()
    local rects = {}
    if serverZoneVisible and serverZoneBounds then
        table.insert(rects, serverZoneBounds)
    end
    for _, z in ipairs(restoredZones) do
        table.insert(rects, z)
    end
    return rects
end

-- "подпись" набора видимых зон и количества точек: если она не менялась, пересобирать активные точки незачем
function runtimeUI.zoneSig()
    local parts = { serverZoneVisible and 'S' or 's', tostring(#treasurePoints), tostring(#restoredZones) }
    if serverZoneVisible and serverZoneBounds then
        local b = serverZoneBounds
        parts[#parts + 1] = string.format('%.2f,%.2f,%.2f,%.2f', b.left, b.up, b.right, b.down)
    end
    for _, z in ipairs(restoredZones) do
        parts[#parts + 1] = string.format('%.2f,%.2f,%.2f,%.2f', z.left, z.up, z.right, z.down)
    end
    return table.concat(parts, '|')
end
runtimeUI.activeSet = {} -- [idx]=true для idx из activeTreasurePoints (быстрая проверка "точка активна?")

local function refreshActiveTreasurePoints()
    activeTreasurePoints = {}
    runtimeUI.activeSet = {}
    local rects = getVisibleZoneRects()

    for idx, pt in ipairs(treasurePoints) do
        for _, rect in ipairs(rects) do
            if pointInRect(pt[1], pt[2], rect) then
                table.insert(activeTreasurePoints, idx)
                runtimeUI.activeSet[idx] = true
                break
            end
        end
    end
    runtimeUI.lastSig = runtimeUI.zoneSig()
    runtimeUI.lastRefreshAt = os.clock()

    if DEBUG then -- пишем только при изменении, чтобы не спамить (функция вызывается каждые 5 с)
        local sig = #activeTreasurePoints .. '/' .. #rects .. '/' .. #treasurePoints
        if runtimeUI.dbgSig ~= sig then
            runtimeUI.dbgSig = sig
            dbg('Активные точки: %d из %d известных; видимых зон: %d (серверная: %s, сохранённых: %d)',
                #activeTreasurePoints, #treasurePoints, #rects, tostring(serverZoneVisible), #restoredZones)
        end
    end
end

-- сколько известных точек внутри прямоугольника и расстояние до ближайшей от игрока (для чата/DEBUG)
function runtimeUI.countInside(rect)
    local cnt, nearest, npt = 0, nil, nil
    local mx, my = getCharCoordinates(PLAYER_PED)
    for _, pt in ipairs(treasurePoints) do
        if pointInRect(pt[1], pt[2], rect) then
            cnt = cnt + 1
            local dd = distance2d(mx, my, pt[1], pt[2])
            if not nearest or dd < nearest then nearest, npt = dd, pt end
        end
    end
    return cnt, nearest, npt
end

-- "123.4 м (x=.. y=.. z=..)" для DEBUG
function runtimeUI.fmtNear(d, pt)
    if not d or not pt then return '-' end
    return string.format('%.1f м (x=%.2f y=%.2f z=%.2f)', d, pt[1], pt[2], pt[3])
end

--------------------------------------------------------------------- Клады: метка + 3D-маркер на найденном кладе
-- markerState[idx] = { blip = handle|nil, marker3d = handle|nil, mode = 'far'|'greened' }
--   'far'     — видны И иконка на карте, И 3D-маркер (closeRadius < d <= markerRadius)
--   'greened' — иконка снята, 3D-маркер остаётся (перекрасить не можем — см. tryGreenMarker3d)
--               (d <= closeRadius; либо тот же режим продолжается пока d <= CFG.markerRetreatRadius)
-- создаёт 3D-маркер; nil — если не получилось (тогда update повторит попытку на следующем проходе)
function runtimeUI.make3d(pt)
    local ok, m = pcall(createUser3dMarker, pt[1], pt[2], pt[3] + CFG.marker3dZOffset, CFG.marker3dType)
    -- createUser3dMarker при неудаче возвращает -1 (это НЕ nil/false!) — раньше такой handle принимался
    -- за успех, маркер навсегда оставался "созданным", и повторных попыток не было
    if ok and type(m) == 'number' and m >= 0 then return m end
    if DEBUG and os.clock() - (runtimeUI.dbgFailAt or 0) > 5 then -- не чаще раза в 5 с
        runtimeUI.dbgFailAt = os.clock()
        dbg('createUser3dMarker не создал маркер (ok=%s, ret=%s) в точке %.1f %.1f %.1f', tostring(ok), tostring(m), pt[1], pt[2], pt[3])
    end
    return nil
end

-- попытка создать маркер с учётом лимита: если игра вернула -1, когда уже стоит ctx.n наших маркеров,
-- значит пул 3D-маркеров упёрся в потолок — запоминаем его (runtimeUI.cap3d), и ближние точки
-- в следующий проход получат слоты за счёт самых дальних (см. updateTreasureDistances)
function runtimeUI.try3d(pt, ctx)
    local m = runtimeUI.make3d(pt)
    if m then ctx.n = ctx.n + 1 return m end
    if ctx.n > 0 and ctx.n < runtimeUI.cap3d then
        runtimeUI.cap3d = ctx.n
        runtimeUI.capAt = os.clock()
        dbg('Игра не даёт больше %d 3D-маркеров — фактический лимит снижен до %d (CFG.max3dMarkers=%d)', ctx.n, ctx.n, CFG.max3dMarkers)
    end
    return nil
end

local function placeTreasureMarkers(pt, allow3d, ctx)
    local blip = createTreasureBlip(pt[1], pt[2], pt[3])
    local marker3d = nil
    if allow3d ~= false then marker3d = ctx and runtimeUI.try3d(pt, ctx) or runtimeUI.make3d(pt) end
    return { blip = blip, marker3d = marker3d, mode = 'far' }
end

local function removeTreasureMarkers(handles)
    if not handles then return end
    if handles.blip then removeTreasureBlip(handles.blip) end
    if handles.marker3d then runtimeUI.spcall('removeUser3dMarker', removeUser3dMarker, handles.marker3d) end
end

-- п.14/23: "покрасить в зелёный, если возможно". Перепроверил TreasureMAP.lua ещё раз —
-- смена цвета там реализована ТОЛЬКО для блипов на карте, через changeBlipColour(pool[i], ...)
-- (см. функцию remove_all/основной цикл в этом файле). Функции смены цвета именно 3D-маркера
-- (createUser3dMarker) в этом файле нет — у него только (x, y, z, type) при создании, без
-- отдельного параметра цвета и без API на смену цвета уже созданного маркера.
-- Если у тебя есть другой пример/функция именно для 3D-маркеров — пришли, подключу быстро.
-- По правилу "если способа нет — не делаем" ниже оставлен no-op.
local function tryGreenMarker3d(marker3d)
    -- намеренно пусто, см. комментарий выше
end

-- есть ли хоть один включённый бонусный клад (его 3D-маркер тоже обслуживается здесь)
function runtimeUI.anyBonusActive()
    local bl = runtimeUI.bonusList
    if bl then for _, e in ipairs(bl) do if e.active then return true end end end
    return false
end

-- пересчитывает дистанции до кладов, решает видимость иконки+маркера.
-- вызывается не каждый кадр, а раз в CFG.distCheckInterval секунд.
local function updateTreasureDistances()
    if not zcfg.markersEnabled then return end -- п.22: общий выключатель

    local px, py = getCharCoordinates(PLAYER_PED)
    local closeRadius = zcfg.closeRadius or 10.0
    local markerRadius = zcfg.markerRadius or 100.0
    local autoRemove = zcfg.autoRemoveMarkers

    -- п.13: если включён "всегда показывать ближайшие" — проверяем ВСЕ известные клады,
    -- а не только те, что подтверждены внутри текущей найденной/восстановленной территории
    local showAll = runtimeUI.showAllNearby

    -- Кандидаты: сортируем и обрабатываем не ВСЕ точки, а только те, с которыми что-то может произойти:
    -- лежащие в пределах max(markerRadius, closeRadius) либо уже имеющие метки (их нужно обслужить/убрать).
    -- Остальные (далеко и без меток) раньше обходились впустую; расстояние сравниваем в квадрате (без sqrt).
    -- Идём от ближайших к дальним: при нехватке слотов 3D-маркеров они достанутся ближним точкам.
    local reach = math.max(markerRadius, closeRadius)
    local reach2 = reach * reach
    local order = {}
    local nearIdx, nearD2 -- ближайшая точка среди ВСЕХ проверяемых (для DEBUG)
    local nearList = {}   -- точки поблизости для запасного отображения (с запасом на движение за 0.5 с)
    local nearR2 = ((CFG.nearFallbackRadius or 0) + 25) ^ 2
    local total = showAll and #treasurePoints or #activeTreasurePoints
    for n = 1, total do
        local idx = showAll and n or activeTreasurePoints[n]
        local opt = treasurePoints[idx]
        local dx, dy = px - opt[1], py - opt[2]
        local d2 = dx * dx + dy * dy
        if not nearD2 or d2 < nearD2 then nearD2, nearIdx = d2, idx end
        if d2 <= nearR2 then nearList[#nearList + 1] = idx end
        if d2 <= reach2 or markerState[idx] then
            order[#order + 1] = { idx, math.sqrt(d2) }
        end
    end
    table.sort(order, function(a, b) return a[2] < b[2] end)
    runtimeUI.nearList = nearList

    -- "посещённые" точки далеко от игрока больше не в order — сбрасываем флаг здесь (как раньше в основном цикле)
    if not showAll then
        for vidx in pairs(runtimeUI.visited) do
            if runtimeUI.activeSet[vidx] and not markerState[vidx] then -- как раньше: только для точек без меток
                local vp = treasurePoints[vidx]
                if vp and distance2d(px, py, vp[1], vp[2]) > markerRadius then runtimeUI.visited[vidx] = nil end
            end
        end
    end

    -- 3D-маркеры положены только ближайшим CFG.max3dMarkers точкам (по текущей позиции игрока).
    -- Кандидаты: точки в "радиусе появления" + те, у кого маркер уже стоит (авто-удаление выключено).
    -- Если появилась более близкая точка, а слотов нет — у самой дальней маркер снимается (иконка остаётся).
    if runtimeUI.cap3d < CFG.max3dMarkers and os.clock() - (runtimeUI.capAt or 0) > 20 then
        runtimeUI.cap3d = runtimeUI.cap3d + 1 -- осторожно проверяем, не освободился ли ещё слот
        runtimeUI.capAt = os.clock()
    end
    -- бонусные клады участвуют в том же рейтинге по расстоянию (ключ в allowed3d — сама запись entry)
    local merged = order
    local bonusList = runtimeUI.bonusList
    if bonusList and runtimeUI.anyBonusActive() then
        merged = {}
        for _, o in ipairs(order) do merged[#merged + 1] = o end
        for _, e in ipairs(bonusList) do
            if e.active then merged[#merged + 1] = { e, distance2d(px, py, e.x, e.y) } end
        end
        table.sort(merged, function(a, b) return a[2] < b[2] end)
    end
    local allowed3d, nAllowed = {}, 0
    for _, o in ipairs(merged) do
        if nAllowed >= runtimeUI.cap3d then break end
        local isBonus = type(o[1]) == 'table'
        local st0 = isBonus and (not autoRemove and o[1].marker3d and o[1] or nil) or markerState[o[1]]
        -- FIX: "посещённая" точка (visited) маркер не получит, но раньше всё равно занимала слот
        local skipVisited = (not isBonus) and (not showAll) and (not st0) and runtimeUI.visited[o[1]]
        if not skipVisited and (o[2] <= markerRadius or (st0 and st0.marker3d)) then
            allowed3d[o[1]] = true
            nAllowed = nAllowed + 1
        end
    end
    -- Снятие "лишних" 3D-маркеров — это тоже авто-удаление: при выключенной настройке оно НЕ выполняется
    -- (новые маркеры при этом создаются только пока есть свободные слоты).
    do -- FIX: освобождение слотов теперь ВСЕГДА, независимо от "Авто-удаления меток"
        for midx, mst in pairs(markerState) do
            if mst.marker3d and not allowed3d[midx] then
                runtimeUI.spcall('removeUser3dMarker', removeUser3dMarker, mst.marker3d)
                mst.marker3d = nil
                dbg('3D-маркер снят у точки #%d (появились более близкие, лимит %d)', midx, runtimeUI.cap3d)
            end
        end
    end
    if bonusList then
        for _, e in ipairs(bonusList) do
            if e.marker3d and not (e.active and allowed3d[e]) then
                runtimeUI.spcall('removeUser3dMarker', removeUser3dMarker, e.marker3d)
                e.marker3d = nil
            end
        end
    end
    local ctx = { n = 0 } -- сколько наших 3D-маркеров стоит сейчас
    for _, st in pairs(markerState) do
        if st.marker3d then ctx.n = ctx.n + 1 end
    end
    if bonusList then
        for _, e in ipairs(bonusList) do
            if e.marker3d then ctx.n = ctx.n + 1 end
        end
    end

    for _, o in ipairs(order) do
        local idx, d = o[1], o[2]
        local pt = treasurePoints[idx]
        local state = markerState[idx]

        if runtimeUI.showAllNearby then
            -- п.3: в этом режиме "Радиус проверки метки" (closeRadius) не действует вообще —
            -- иконка и 3D-маркер показываются/скрываются ВМЕСТЕ, одним куском.
            -- п.2: видимость привязана к "Радиусу появления меток" (markerRadius), и удаление
            -- при отдалении из этого радиуса работает ВСЕГДА, вне зависимости от настройки
            -- "Авто-удаление меток на карте" — та настройка на этот режим не распространяется.
            if d <= markerRadius then
                if not state then
                    local st = placeTreasureMarkers(pt, allowed3d[idx] == true, ctx)
                    markerState[idx] = st
                elseif not state.marker3d and allowed3d[idx] then
                    state.marker3d = runtimeUI.try3d(pt, ctx) -- прошлая попытка не удалась — пробуем снова
                end
            elseif state then
                dbg('Метка #%d снята: режим "Всегда показывать", далеко (%.0f м > радиуса появления %.0f м)', idx, d, markerRadius)
                removeTreasureMarkers(state)
                markerState[idx] = nil
            end

        else
            -- При ВЫКЛЮЧЕННОМ авто-удалении иконка на карте живёт по правилу "есть, пока d <= markerRadius":
            --   • при подъезде (closeRadius) она НЕ снимается (3D-маркер и запасной рендер работают как обычно);
            --   • за пределами "Радиуса появления меток" иконка снимается ВСЕГДА; вернулся в радиус — ставится снова.
            -- 3D-маркер при этом живёт по своим правилам (слоты), состояние точки убираем, только когда не осталось ничего.
            if state and not autoRemove then
                if d > markerRadius then
                    if state.blip then
                        removeTreasureBlip(state.blip)
                        state.blip = nil
                    end
                    if not state.marker3d then
                        markerState[idx] = nil
                        state = nil
                    end
                elseif not state.blip then
                    state.blip = createTreasureBlip(pt[1], pt[2], pt[3])
                end
            end

            local mode = state and state.mode

            if mode == 'greened' then
                if d > CFG.markerRetreatRadius and autoRemove then
                    dbg('Метка #%d снята: посещённая точка, отошёл на %.0f м (> %.0f), авто-удаление включено', idx, d, CFG.markerRetreatRadius)
                    removeTreasureMarkers(state)
                    markerState[idx] = nil
                    -- раньше точка тут же пересоздавалась как 'far' (она всё ещё в markerRadius) —
                    -- авто-удаление выглядело сломанным; теперь она скрыта, пока не уйдёшь за markerRadius
                    runtimeUI.visited[idx] = true
                elseif not state.marker3d and allowed3d[idx] then
                    state.marker3d = runtimeUI.try3d(pt, ctx) -- маркер так и не появился — пробуем снова
                end
                -- иначе остаётся зелёным вплоть до CFG.markerRetreatRadius — ничего не меняем

            elseif mode == 'far' then
                if not state.marker3d and d <= markerRadius and allowed3d[idx] then
                    state.marker3d = runtimeUI.try3d(pt, ctx) -- маркер не создался с первого раза — повторяем
                end
                if d <= closeRadius then
                    -- п.23: снимаем ТОЛЬКО иконку, маркер остаётся (пытаемся перекрасить)
                    -- (при выключенном авто-удалении иконка при подъезде остаётся — см. блок выше)
                    if state.blip and autoRemove then
                        removeTreasureBlip(state.blip)
                        state.blip = nil
                    end
                    tryGreenMarker3d(state.marker3d)
                    state.mode = 'greened'
                elseif d > markerRadius and autoRemove then
                    dbg('Метка #%d снята: далеко (%.0f м > радиуса появления %.0f м), авто-удаление включено', idx, d, markerRadius)
                    removeTreasureMarkers(state)
                    markerState[idx] = nil
                end

            else -- ничего ещё не создано
                if runtimeUI.visited[idx] then
                    if d > markerRadius then runtimeUI.visited[idx] = nil end -- ушёл далеко — точка снова "новая"
                elseif d <= closeRadius then
                    local marker3d = nil
                    if allowed3d[idx] then marker3d = runtimeUI.try3d(pt, ctx) end
                    tryGreenMarker3d(marker3d)
                    -- при выключенном авто-удалении иконка на карте остаётся и вблизи closeRadius
                    local blip = (not autoRemove) and createTreasureBlip(pt[1], pt[2], pt[3]) or nil
                    markerState[idx] = { blip = blip, marker3d = marker3d, mode = 'greened' }
                elseif d <= markerRadius then
                    local st = placeTreasureMarkers(pt, allowed3d[idx] == true, ctx)
                    markerState[idx] = st
                end
            end
        end
    end

    if bonusList then
        for _, e in ipairs(bonusList) do
            if e.active and not e.marker3d and allowed3d[e] then
                e.marker3d = runtimeUI.try3d({ e.x, e.y, e.z }, ctx)
            end
        end
    end

    if DEBUG then
        local nb, n3 = 0, 0
        for _, st in pairs(markerState) do
            if st.blip then nb = nb + 1 end
            if st.marker3d then n3 = n3 + 1 end
        end
        local sig = #order .. '/' .. nb .. '/' .. n3
        if runtimeUI.dbgMarkSig ~= sig then
            runtimeUI.dbgMarkSig = sig
            dbg('Метки: кандидатов %d из %d проверяемых, иконок %d, 3D-маркеров %d (лимит %d), ближайшая точка: %s',
                #order, total, nb, n3, runtimeUI.cap3d,
                nearIdx and runtimeUI.fmtNear(math.sqrt(nearD2), treasurePoints[nearIdx]) or '-')
        end

        -- подробности про точку совсем рядом: создал ли скрипт 3D-маркер (если да, а на экране его нет —
        -- значит скрывает сама игра на малой дистанции, тогда работает запасная отрисовка CFG.nearFallbackRadius)
        local o1 = nearIdx and { nearIdx, math.sqrt(nearD2) } or nil
        if o1 and o1[2] <= 5.0 then
            local nidx = o1[1]
            local npt2 = treasurePoints[nidx]
            local nst = markerState[nidx]
            local sig2 = nidx .. '/' .. tostring(nst and nst.mode) .. '/' .. tostring(nst and nst.marker3d) .. '/' .. tostring(nst and nst.blip)
            if runtimeUI.dbgNearSig ~= sig2 then
                runtimeUI.dbgNearSig = sig2
                dbg('Рядом (<=5 м): точка #%d %s; состояние=%s, режим=%s, 3D-маркер(handle)=%s, иконка=%s, слот 3D=%s, closeRadius=%.1f, markerRadius=%.1f',
                    nidx, runtimeUI.fmtNear(o1[2], npt2), nst and 'есть' or 'НЕТ', tostring(nst and nst.mode),
                    tostring(nst and nst.marker3d), tostring(nst and nst.blip), tostring(allowed3d[nidx] == true),
                    closeRadius, markerRadius)
            end
        end
    end

    -- чистим состояние точек, которые перестали быть "активными" (вышли из видимых зон /
    -- вне области проверки — сверяемся с тем же набором точек, что использовался выше)
    -- (раньше — вложенный перебор marker x весь список; теперь проверка принадлежности за O(1))
    for idx in pairs(markerState) do
        local stillActive
        if showAll then stillActive = treasurePoints[idx] ~= nil else stillActive = runtimeUI.activeSet[idx] == true end
        if not stillActive then
            dbg('Метка #%d снята: точка больше не внутри видимой зоны (зона исчезла/сменилась или выключен "Всегда показывать")', idx)
            removeTreasureMarkers(markerState[idx])
            markerState[idx] = nil
        end
    end
end

--------------------------------------------------------------------- Клады: обнаружение и авто-возврат зоны
function sampev.onCreateGangZone(zoneId, squareStart, squareEnd, color)
    if color == KLAD_ZONE_COLOR then
        serverZoneId = zoneId
        serverZoneBounds = { left = squareStart.x, up = squareStart.y, right = squareEnd.x, down = squareEnd.y }
        serverZoneVisible = true
        refreshActiveTreasurePoints()
        if DEBUG then
            local cnt, nearest, npt = runtimeUI.countInside(serverZoneBounds)
            dbg('Серверная зона id=%s: l=%.2f u=%.2f r=%.2f d=%.2f; известных точек внутри: %d, ближайшая: %s',
                tostring(zoneId), serverZoneBounds.left, serverZoneBounds.up, serverZoneBounds.right, serverZoneBounds.down,
                cnt, runtimeUI.fmtNear(nearest, npt))
        end
        sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} Территория найдена! Координаты доступны в разделе меню.', -1)
    end
end

-- сохраняет серверную территорию как локальную (авто-возврат). deferRpc=true — только в таблицу,
-- на карту её выставит runtimeUI.replayZones() после переподключения.
function runtimeUI.restoreServerZone(deferRpc)
    if not serverZoneBounds then return end
    local id = nextLocalZoneId
    nextLocalZoneId = nextLocalZoneId + 1
    zoneCounter = zoneCounter + 1

    local color = pickZoneColor(serverZoneBounds)
    dbg('Серверная зона сохранена как Территория #%d (отложенный показ: %s)', zoneCounter, tostring(deferRpc))
    if not deferRpc then
        rpcAddGangZone(id, serverZoneBounds.left, serverZoneBounds.up, serverZoneBounds.right, serverZoneBounds.down, color)
    end
    table.insert(restoredZones, {
        id = id,
        left = serverZoneBounds.left, up = serverZoneBounds.up,
        right = serverZoneBounds.right, down = serverZoneBounds.down,
        num = zoneCounter,
        createdAt = os.date('%H:%M'),
        color = color,
    })

    -- п.19: не больше CFG.maxSavedZones одновременно — старейшая (первая) удаляется
    while #restoredZones > CFG.maxSavedZones do
        local oldest = table.remove(restoredZones, 1)
        rpcRemoveGangZone(oldest.id)
    end

    if not deferRpc then
        sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} Территория возвращена на карту (Территория #' .. zoneCounter .. ').', -1)
    end
end

-- после переподключения клиент сбрасывает все ганг-зоны — выставляем сохранённые территории заново
function runtimeUI.replayZones()
    dbg('Повторный показ сохранённых территорий после переподключения: %d', #restoredZones)
    for _, z in ipairs(restoredZones) do
        runtimeUI.spcall('rpcRemoveGangZone', rpcRemoveGangZone, z.id) -- на случай, если клиент зону не сбросил (чтобы не было дубля)
        z.id = nextLocalZoneId
        nextLocalZoneId = nextLocalZoneId + 1
        rpcAddGangZone(z.id, z.left, z.up, z.right, z.down, z.color or ZONE_COLOR_PRIMARY)
    end
    refreshActiveTreasurePoints()
    if #restoredZones > 0 then
        sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} После переподключения территории возвращены на карту (' .. #restoredZones .. ').', -1)
    end
end

function sampev.onGangZoneDestroy(zoneId)
    if zoneId == serverZoneId then
        dbg('Серверная зона id=%s уничтожена; авто-возврат: %s', tostring(zoneId), tostring(zcfg.autoRestore))
        serverZoneVisible = false

        if zcfg.autoRestore and serverZoneBounds then
            stats.restoredCount = stats.restoredCount + 1
            runtimeUI.restoreServerZone(false)
        end

        refreshActiveTreasurePoints()
    end
end

-- п.18: скрытие иконок сервера на карте (не путать с гангзоной клада) — блокируем сам показ.
-- п.8: если включена подстройка hideServerMapIconOnlyInZone — скрываем ТОЛЬКО те иконки,
-- что физически попадают внутрь текущей видимой зоны клада; всё, что за её пределами, остаётся.
function sampev.onSetMapIcon(iconId, position, type, color, style)
    if not zcfg.hideServerMapIcon then return end

    if not zcfg.hideServerMapIconOnlyInZone then
        return false -- скрываем вообще все серверные иконки
    end

    local rects = getVisibleZoneRects()
    if #rects == 0 then return end -- нет видимой зоны клада — ничего не трогаем

    local px, py = position.x, position.y
    for _, rect in ipairs(rects) do
        if pointInRect(px, py, rect) then
            return false -- эта иконка внутри зоны клада — скрываем
        end
    end
    -- иконка за пределами зоны — не трогаем, пусть показывается как обычно
end

-- удаление зоны из таблицы в меню (кнопка "удалить")
local function deleteRestoredZone(index)
    local z = restoredZones[index]
    if not z then return end
    rpcRemoveGangZone(z.id)
    table.remove(restoredZones, index)
    refreshActiveTreasurePoints()
end

--------------------------------------------------------------------- Клады: обмен зоной через буфер обмена
local function copyCurrentZoneToClipboard()
    if serverZoneVisible and serverZoneBounds then
        local text = string.format('l: %.2f; u: %.2f; r: %.2f; d: %.2f',
            serverZoneBounds.left, serverZoneBounds.up, serverZoneBounds.right, serverZoneBounds.down)
        setClipboardText(text)
        sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} Координаты скопированы в буфер обмена!', -1)
        return true
    else
        sampAddChatMessage('{FF0000}[TreasureHunter]{FFFFFF} Сейчас нет видимой территории, чтобы скопировать.', -1)
        return false
    end
end

local function bufToString(buf)
    if ffi_ok then return ffi.string(buf) end
    return tostring(buf)
end

local function pasteZoneFromText(text)
    local l, u, r, d = text:match('l:%s*(-?[%d%.]+);%s*u:%s*(-?[%d%.]+);%s*r:%s*(-?[%d%.]+);%s*d:%s*(-?[%d%.]+)')
    if not l then
        sampAddChatMessage('{FF0000}[TreasureHunter]{FFFFFF} Не удалось распознать координаты. Проверь формат.', -1)
        return false
    end

    l, u, r, d = tonumber(l), tonumber(u), tonumber(r), tonumber(d)

    local id = nextLocalZoneId
    nextLocalZoneId = nextLocalZoneId + 1
    zoneCounter = zoneCounter + 1

    local rect = { left = l, up = u, right = r, down = d }
    local color = pickZoneColor(rect)
    rpcAddGangZone(id, l, u, r, d, color)
    table.insert(restoredZones, {
        id = id, left = l, up = u, right = r, down = d,
        num = zoneCounter, createdAt = os.date('%H:%M'), color = color,
    })

    while #restoredZones > CFG.maxSavedZones do
        local oldest = table.remove(restoredZones, 1)
        rpcRemoveGangZone(oldest.id)
    end

    refreshActiveTreasurePoints()

    -- диагностика: сколько известных кладов попало в территорию и как далеко ближайший
    local inside, nearest, npt = runtimeUI.countInside(rect)
    dbg('Вставлена территория #%d: l=%.2f u=%.2f r=%.2f d=%.2f; точек внутри: %d, ближайшая: %s',
        zoneCounter, l, u, r, d, inside, runtimeUI.fmtNear(nearest, npt))
    sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} Территория из буфера добавлена на карту (Территория #' .. zoneCounter .. ').', -1)
    if inside == 0 then
        sampAddChatMessage('{FF0000}[TreasureHunter]{FFFFFF} Внутри этой территории нет ни одной точки из TreasureCoords.txt — рисовать нечего.', -1)
    else
        sampAddChatMessage(string.format('{6398c9}[TreasureHunter]{FFFFFF} Известных кладов внутри: %d, ближайший в %.0f м.', inside, nearest), -1)
    end
    return true
end

--------------------------------------------------------------------- Клады: бонусные (секретные) клады — состояние
-- (объявлено здесь, ДО обработчика выкапывания клада, т.к. тому нужно видеть этот список — см. п.20)
local bonusTreasures = {} -- { {x,y,z, foundAt, active, blip, marker3d, checkpoint}, ... }
runtimeUI.bonusList = bonusTreasures

-- расстояние до бонусных кладов считается ТОЛЬКО при открытии вкладки "Доп. клады" (или меню сразу на ней),
-- по тому же принципу, что и онлайн-статус в чекере игроков: единоразовый снимок, не каждый кадр/тик
function runtimeUI.refreshBonusDistances()
    local ok, px, py = runtimeUI.spcall('refreshBonusDistances', getCharCoordinates, PLAYER_PED)
    if not ok then return end
    for _, e in ipairs(bonusTreasures) do
        e.dist = distance2d(px, py, e.x, e.y)
    end
end

function runtimeUI.fmtBonusDist(d)
    if not d then return '' end
    if d >= 1000 then return string.format(' — %.1f км', d / 1000) end
    return string.format(' — %.0f м', d)
end

-- forward-declaration (тем же способом, что и bonusTreasures выше): тело функции присвоено
-- ниже по файлу, рядом с остальной логикой наград/дней, но вызывается уже в обработчике
-- выкапывания клада (п.4 этого сообщения — счётчик кладов по дням)
local incrementDigCountForToday

--------------------------------------------------------------------- Клады: выкопанный клад (п.5) + бонусный клад в чате (п.6)
-- Пример строки в чате (обычный клад):
-- "[TreasureHunter]{ffffff} Кладоискатель Hotline_Mayami[387] выкопал клад и забрал свой куш. Доступно 4 кладов!"
-- Пример строки в чате (бонусный клад, только уведомление — см. ниже почему не для детекта):
-- "[TreasureHunter]{ffffff} Кладоискатель Hotline_Mayami[387] попытал удачу и получил секретный дополнительный клад!"
--
-- п.6: раньше это были два отдельных sampev.onServerMessage через do/end-обёртку с "цепочкой" —
-- по просьбе объединено в одну функцию.
function sampev.onServerMessage(color, text)
    local myNick = getMyNickname()

    local nickDug = text:match('Кладоискатель%s+(%S-)%[%d+%]%s+выкопал клад')
    if nickDug and myNick and nickDug:lower() == myNick:lower() then
        local px, py, pz = getCharCoordinates(PLAYER_PED)

        -- проверка на дубликат: если уже есть известная точка ближе CFG.duplicateRadius — не сохраняем
        local dupD, dupPt
        for _, kp in ipairs(treasurePoints) do
            local dd = distance2d(px, py, kp[1], kp[2])
            if not dupD or dd < dupD then dupD, dupPt = dd, kp end
        end
        local isDup = dupD ~= nil and dupD <= CFG.duplicateRadius
        dbg('Клад выкопан в %.2f %.2f %.2f; известных точек %d, ближайшая: %s; дубликат: %s',
            px, py, pz, #treasurePoints, runtimeUI.fmtNear(dupD, dupPt), tostring(isDup))

        local ok, err = true, nil
        if isDup then
            print(string.format('[TreasureHunter] Точка клада НЕ сохранена (дубликат, порог %.1f м): x=%.2f y=%.2f z=%.2f; до уже известной точки %.2f м (x=%.2f y=%.2f z=%.2f)',
                CFG.duplicateRadius, px, py, pz, dupD, dupPt[1], dupPt[2], dupPt[3]))
        else
            ok, err = pcall(function()
                -- если файл не заканчивается переводом строки — добавим, чтобы новая точка не склеилась с последней
                local needNl = false
                local fr = io.open(PATHS.treasureCoords, 'rb')
                if fr then
                    local size = fr:seek('end')
                    if size and size > 0 then
                        fr:seek('set', size - 1)
                        needNl = fr:read(1) ~= '\n'
                    end
                    fr:close()
                end
                local f = io.open(PATHS.treasureCoords, 'a')
                if f then
                    -- формат: { x, y, z }, -- ДД.ММ.ГГГГ  (дата — просто комментарий, загрузчик его игнорирует)
                    f:write((needNl and '\n' or '') .. string.format('{ %.2f, %.2f, %.2f }, -- %s\n', px, py, pz, os.date('%d.%m.%Y')))
                    f:close()
                end
            end)
            if ok then table.insert(treasurePoints, { px, py, pz }) end
        end

        stats.dugCount = stats.dugCount + 1
        incrementDigCountForToday() -- п.4: счётчик кладов по дням для вкладки "Награда"
        clearDetectorZone() -- клад выкопан — зона и след металлоискателя больше не нужны
        refreshActiveTreasurePoints()

        -- п.20: если рядом (в фиксированном радиусе) был активный бонусный клад — считаем
        -- его тоже выкопанным и убираем из списка вместе с его меткой/маркером/чекпоинтом
        for i = #bonusTreasures, 1, -1 do
            local entry = bonusTreasures[i]
            if distance2d(px, py, entry.x, entry.y) <= CFG.bonusTreasureDigRadius then
                if entry.blip then removeTreasureBlip(entry.blip) end
                if entry.marker3d then runtimeUI.spcall('removeUser3dMarker', removeUser3dMarker, entry.marker3d) end
                if entry.checkpoint then runtimeUI.spcall('deleteCheckpoint', deleteCheckpoint, entry.checkpoint) end
                table.remove(bonusTreasures, i)
            end
        end

        if isDup then
            -- дубликат: молча, подробности — в консоли (print выше)
        elseif ok then
            sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} Координаты клада сохранены в ' .. PATHS.treasureCoords, -1)
        else
            sampAddChatMessage('{FF0000}[TreasureHunter]{FFFFFF} Не удалось записать координаты: ' .. tostring(err), -1)
        end
    end

    -- п.1: это сообщение НЕ используется для добавления в список бонусных кладов — сервер
    -- иногда ставит чекпоинт РАНЬШЕ, чем приходит это сообщение (гонка условий), поэтому
    -- единственный надёжный признак бонусного клада — сам размер чекпоинта (см. onSetRaceCheckpoint
    -- ниже). Здесь только уведомление в чат, чтобы было видно, что что-то произошло.
    local nickLucky = text:match('Кладоискатель%s+(%S-)%[%d+%]%s+попытал удачу')
    if nickLucky and myNick and nickLucky:lower() == myNick:lower() then
        sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} Бонусный клад! Ищу координаты...', -1)
    end
end

-- п.4: исправлена сигнатура — было (checkpointType, x, y, z, nextX, nextY, nextZ, size),
-- а по факту (type, position, nextPosition, size), координаты через position.x/y/z.
-- п.1: детект бонусного клада — ЛЮБОЙ чекпоинт с size == CFG.bonusCheckpointRadius (10),
-- без привязки к сообщению в чате (сервер может прислать чекпоинт раньше сообщения).
function sampev.onSetRaceCheckpoint(checkpointType, position, nextPosition, size)
    if math.abs(size - CFG.bonusCheckpointRadius) < 0.01 then
        stats.bonusCount = stats.bonusCount + 1 -- п.3, п.9 (считаем именно получение, не выкапывание)
        table.insert(bonusTreasures, {
            x = position.x, y = position.y, z = position.z,
            foundAt = os.date('%H:%M'),
            active = false,
            blip = nil, marker3d = nil, checkpoint = nil,
        })
        dbg('Бонусный клад (чекпоинт size=%.1f): %.2f %.2f %.2f; всего в списке %d', size, position.x, position.y, position.z, #bonusTreasures)
        sampAddChatMessage('{6398c9}[TreasureHunter]{FFFFFF} Координаты бонусного клада получены и добавлены в список.', -1)
    end
end

-- ставит чекпоинт, который сам себя удаляет по приближении (тем же принципом, что и в примере).
-- ВАЖНО (п.1): приближение к чекпоинту убирает только сам чекпоинт (обычное поведение SA-MP —
-- чекпоинт показывает, что ты на месте). Метка на карте и 3D-маркер НЕ снимаются здесь —
-- они пропадают только когда клад реально выкопан (см. обработчик "выкопал клад" выше, п.1).
local function setBonusCheckpoint(entry, radius)
    if entry.checkpoint then
        runtimeUI.spcall('deleteCheckpoint', deleteCheckpoint, entry.checkpoint)
        entry.checkpoint = nil
    end

    local marker = createCheckpoint(1, entry.x, entry.y, entry.z, 1, 1, 1, radius)
    entry.checkpoint = marker

    lua_thread.create(function()
        repeat
            wait(0)
            local pX, pY, pZ = getCharCoordinates(PLAYER_PED)
        until getDistanceBetweenCoords3d(entry.x, entry.y, entry.z, pX, pY, pZ) < radius
           or entry.checkpoint ~= marker -- чекпоинт был снят/пересоздан вручную извне — поток завершается

        if entry.checkpoint == marker then
            runtimeUI.spcall('deleteCheckpoint', deleteCheckpoint, marker)
            entry.checkpoint = nil
            -- блип и 3D-маркер намеренно НЕ трогаем здесь (п.1) — только по факту выкапывания
        end
    end)
end

-- создаёт метку+чекпоинт+3D-маркер бонусного клада (тем же способом, что и обычные клады)
local function placeBonusMarkers(entry)
    entry.blip = createTreasureBlip(entry.x, entry.y, entry.z, CFG.bonusBlipColor, CFG.bonusBlipIcon)

    -- 3D-маркер здесь не создаём: его ставит/снимает updateTreasureDistances по общему правилу
    -- (только у ближайших точек, в пределах радиуса появления, из общего пула слотов)
    entry.marker3d = nil

    setBonusCheckpoint(entry, CFG.bonusMarkerRadius) -- п.5: радиус метки/чекпоинта — 2м
    entry.active = true
end

local function removeBonusMarkers(entry)
    if entry.blip then removeTreasureBlip(entry.blip); entry.blip = nil end
    if entry.marker3d then runtimeUI.spcall('removeUser3dMarker', removeUser3dMarker, entry.marker3d); entry.marker3d = nil end
    if entry.checkpoint then runtimeUI.spcall('deleteCheckpoint', deleteCheckpoint, entry.checkpoint); entry.checkpoint = nil end
    entry.active = false
end

local function toggleBonusMarkers(entry)
    if entry.active then removeBonusMarkers(entry) else placeBonusMarkers(entry) end
end

-- п.1: раньше здесь была проверка "игрок подошёл ближе closeRadius — снять метки", но это
-- неверно приравнивало ПРИБЛИЖЕНИЕ к ВЫКАПЫВАНИЮ. Единственное настоящее подтверждение
-- выкапывания бонусного клада — сообщение в чате "выкопал клад" + проверка радиуса
-- (см. sampev.onServerMessage выше, блок п.20). Отдельная функция здесь больше не нужна.

--------------------------------------------------------------------- Клады: авто-выкапывание (п.5) + награда по дням (п.7)
-- п.8: "динамические" флаги детекта — сбрасываются в исходное состояние при дисконнекте
-- (см. resetRuntimeDetectionState ниже и sampev.onDisconnect в самом низу файла)
local miniGameActive = false  -- была ли реально открыта мини-игра выкапывания (п.7, последний абзац)
local lastRewardAddTime = 0

local rewardsByDay = {}     -- [ '2025-01-15' ] = { order = {name,...}, totals = {[name]=count} }
local rewardDayOrder = {}   -- даты в порядке первого появления (для навигации по дням в UI)
-- редактирование цены — отдельное окно, см. блок PE ниже (рядом с drawSection)

local function resetRuntimeDetectionState() -- п.8
    miniGameActive = false
    lastRewardAddTime = 0
end

local function loadRewardFile()
    local f = io.open(PATHS.rewardFile, 'r')
    if not f then return end
    for line in f:lines() do
        -- каждая строка разбирается изолированно: одна битая запись не должна ломать загрузку всего файла
        runtimeUI.spcall('RewardLog: разбор строки', function()
            local date, name, count = line:match('^(%d%d%d%d%-%d%d%-%d%d)\t(.-)\t(%d+)$')
            local n = tonumber(count)
            if date and name ~= '' and n then
                if not rewardsByDay[date] then
                    rewardsByDay[date] = { order = {}, totals = {} }
                    table.insert(rewardDayOrder, date)
                end
                local day = rewardsByDay[date]
                if not day.totals[name] then table.insert(day.order, name) end
                day.totals[name] = math.min(n, 1e12)
            end
        end)
    end
    f:close()
end

local function saveRewardFile()
    local f, err = io.open(PATHS.rewardFile, 'w')
    if not f then return false, err end
    for _, date in ipairs(rewardDayOrder) do
        local day = rewardsByDay[date]
        for _, name in ipairs(day.order) do
            f:write(date, '\t', name, '\t', day.totals[name], '\n')
        end
    end
    f:close()
    return true
end

-- общий для награды и счётчика выкопанных кладов: находит/создаёт запись дня
local function ensureRewardDay(date)
    if not rewardsByDay[date] then
        rewardsByDay[date] = { order = {}, totals = {} }
        table.insert(rewardDayOrder, date)
    end
    return rewardsByDay[date]
end

-- счётчик кладов по дням (п.4) — хранится в том же файле наград под псевдо-именем
-- '__DIGS__' (не показывается в списке предметов — фильтруется при отрисовке)
local DIG_COUNT_KEY = '__DIGS__'
function incrementDigCountForToday()
    local day = ensureRewardDay(os.date('%Y-%m-%d'))
    if not day.totals[DIG_COUNT_KEY] then table.insert(day.order, DIG_COUNT_KEY) end
    day.totals[DIG_COUNT_KEY] = (day.totals[DIG_COUNT_KEY] or 0) + 1
    saveRewardFile()
end

-- разбор пакета награды — тот же принцип, что и в cef_parser.lua (title вида "N шт. Название")
local function extractRewardItems(rawText)
    local eventName, payload = rawText:match("executeEvent%(%s*'(.-)'%s*,%s*`(.-)`%s*%)")
    if eventName ~= 'event.mountain.testDrive.addVehicles' then return nil end

    local ok, data = runtimeUI.spcall('decodeJson', decodeJson, payload)
    if not ok or type(data) ~= 'table' then return nil end
    local list = data[1]
    if not list then return nil end

    local result = {}
    for _, v in ipairs(list) do
        local title = v.title
        if title then
            local count, name = title:match('^(%d+)[%s\160]*шт%.[%s\160]*(.+)$')
            if count then count = tonumber(count) else name, count = title, 1 end
            table.insert(result, { name = name, count = count })
        end
    end
    return result
end

local function addRewardItems(items)
    if DEBUG then
        local parts = {}
        for _, it in ipairs(items) do parts[#parts + 1] = it.name .. ' x' .. it.count end
        dbg('Награда записана в список: %s', table.concat(parts, '; '))
    end
    local day = ensureRewardDay(os.date('%Y-%m-%d'))
    for _, it in ipairs(items) do
        if day.totals[it.name] then
            day.totals[it.name] = day.totals[it.name] + it.count
        else
            table.insert(day.order, it.name)
            day.totals[it.name] = it.count
        end
    end
    saveRewardFile()
end

-- п.5 + п.7: слушаем CEF-события клиента арizona. Используем arzev.decode как в KladLogger.lua.
function arzev.onArizonaDisplay(packet)
    if not arzev.decode(packet) then return end
    if not packet.text then return end

    -- открытие мини-игры выкапывания: window.executeEvent('event.setActiveView', `["Excavations"]`)
    if packet.event == 'event.setActiveView' and packet.text:find('Excavations', 1, true) then
        dbg('Открыта мини-игра выкапывания (Excavations); авто-клик: %s', tostring(zcfg.autoExcavate))
        miniGameActive = true -- п.7: фиксируем, что мини-игра реально была — иначе награда не считается
        runtimeUI.miniGameAt = os.clock()

        if zcfg.autoExcavate then -- п.5
            local delay = zcfg.autoExcavateDelayMs or CFG.autoExcavateDelayMs
            lua_thread.create(function()
                wait(delay)
                runtimeUI.spcall('arzev.send (авто-выкапывание)', arzev.send, 'onArizonaSend', { text = 'excavations.successfulSpaceClick', server_id = 0 })
            end)
        end
    end

    -- зона металлоискателя: window.executeEvent('event.detector-radar.setRadarLevel', `[[N]]`)
    if packet.event == 'event.detector-radar.setRadarLevel' then
        local level = extractDetectorLevel(packet.text)
        if level then onDetectorLevel(level) end
    end

    -- награда за клад: window.executeEvent('event.mountain.testDrive.addVehicles', `[[...]]`)
    if packet.event == 'event.mountain.testDrive.addVehicles' then
        -- п.7: считаем только если реально была мини-игра выкапывания, и не чаще чем раз в 30с
        -- (повторный приход того же пакета после того, как игрок забрал один из слотов)
        -- флаг мини-игры одноразовый и со сроком годности: иначе после первого же клада он оставался
        -- true навсегда, и тот же интерфейс награды из других источников попадал в список
        if miniGameActive and (os.clock() - (runtimeUI.miniGameAt or 0)) > CFG.rewardWindowSec then
            dbg('Пакет награды: флаг мини-игры протух (> %.0f с) — сбрасываю', CFG.rewardWindowSec)
            miniGameActive = false
        end
        if DEBUG then
            local age = runtimeUI.miniGameAt and (os.clock() - runtimeUI.miniGameAt) or -1
            local cd = os.clock() - lastRewardAddTime
            local preview = extractRewardItems(packet.text)
            local parts = {}
            for _, it in ipairs(preview or {}) do parts[#parts + 1] = it.name .. ' x' .. it.count end
            dbg('Пакет награды: мини-игра=%s (возраст %.1f с), с прошлой награды %.1f с (кулдаун %.0f), в пакете: %s -> %s',
                tostring(miniGameActive), age, cd, CFG.rewardAddCooldown, #parts > 0 and table.concat(parts, '; ') or 'пусто',
                (miniGameActive and cd >= CFG.rewardAddCooldown) and 'ПРИНИМАЕТСЯ' or 'ОТКЛОНЁН')
        end
        if miniGameActive and (os.clock() - lastRewardAddTime) >= CFG.rewardAddCooldown then
            local items = extractRewardItems(packet.text)
            if items and #items > 0 then
                lastRewardAddTime = os.clock()
                miniGameActive = false
                addRewardItems(items)
            end
        end
    end
end

loadRewardFile()

--------------------------------------------------------------------- Клады: список игроков (п.26)
PATHS.playersFile = PATHS.kladhunterDir .. '\\PlayerWatchlist.txt'
local PLAYERS_PAGE_SIZE = 7

local watchlist = {} -- { {nick=string, online=bool}, ... }

local function loadWatchlist()
    watchlist = {}
    local f = io.open(PATHS.playersFile, 'r')
    if not f then return end
    for line in f:lines() do
        local nick = line:match('^%s*(.-)%s*$')
        if nick and nick ~= '' then
            table.insert(watchlist, { nick = nick, online = false })
        end
    end
    f:close()
end

local function saveWatchlist()
    local f, err = io.open(PATHS.playersFile, 'w')
    if not f then
        sampAddChatMessage('{FF0000}[TreasureHunter]{FFFFFF} Не удалось сохранить список игроков: ' .. tostring(err), -1)
        return
    end
    for _, p in ipairs(watchlist) do
        f:write(p.nick .. '\n')
    end
    f:close()
end

local function findOnlinePlayerId(nick)
    local ok, maxId = pcall(sampGetMaxPlayerId, false)
    if not ok or not maxId then return nil end
    for id = 0, maxId do
        local okc, connected = pcall(sampIsPlayerConnected, id)
        if okc and connected then
            local okn, n = pcall(sampGetPlayerNickname, id)
            if okn and n and n:lower() == nick:lower() then
                return id
            end
        end
    end
    return nil
end

local function isPlayerOnline(nick)
    return findOnlinePlayerId(nick) ~= nil
end

local function refreshWatchlistOnlineStatus()
    for _, p in ipairs(watchlist) do
        p.id = findOnlinePlayerId(p.nick) -- п.9: запоминаем ID, чтобы показать "Ник [ID]"
        p.online = p.id ~= nil
    end
end

local function addToWatchlist(nick)
    nick = (nick or ''):match('^%s*(.-)%s*$')
    if nick == '' then return false end
    for _, p in ipairs(watchlist) do
        if p.nick:lower() == nick:lower() then
            sampAddChatMessage('{FF0000}[TreasureHunter]{FFFFFF} Этот игрок уже в списке.', -1)
            return false
        end
    end
    local id = findOnlinePlayerId(nick)
    table.insert(watchlist, { nick = nick, online = id ~= nil, id = id })
    saveWatchlist()
    return true
end

local function removeFromWatchlist(index)
    if watchlist[index] then
        table.remove(watchlist, index)
        saveWatchlist()
    end
end

loadWatchlist()

--------------------------------------------------------------------- Стили фона
-- (сравнение идёт напрямую по cfg.bg == 'Графит' и т.п. в drawAurora ниже — отдельная
-- таблица стилей и индекс комбобокса больше не нужны: вкладка "Вид" была удалена ранее)

------------------------------------------------------------- шрифт (только Montserrat) --
PATHS.mlDir  = getWorkingDirectory()
PATHS.resDir = PATHS.mlDir .. '\\config\\xMercy\\' -- шрифты лежат в moonloader/config/xMercy (не в KladHunter)

-- файл шрифта должен быть непустым и начинаться с сигнатуры TTF/OTF/TTC: иначе ImGui на нём падает (assert)
local function isValidFont(path)
    local ok, res = pcall(function()
        local f = io.open(path, 'rb')
        if not f then return false end
        local size = f:seek('end')
        f:seek('set', 0)
        local head = f:read(4)
        f:close()
        return size and size > 1024 and (head == '\0\1\0\0' or head == 'OTTO' or head == 'true' or head == 'ttcf')
    end)
    return ok and res == true
end

local function asset(name)
    if doesFileExist(PATHS.resDir .. name) and isValidFont(PATHS.resDir .. name) then return PATHS.resDir .. name end
    -- запасной вариант: шрифт ещё лежит в старой папке KladHunter
    local old = PATHS.mlDir .. '\\config\\KladHunter\\' .. name
    if doesFileExist(old) and isValidFont(old) then return old end
    return nil
end

local UI_RANGES = ffi_ok and ffi.new('unsigned short[7]', {
    0x0020, 0x00FF,
    0x0400, 0x045F,
    0x2010, 0x2027,
    0,
}) or nil

-- диапазон Private Use Area, где живут иконки FontAwesome (расширен — у FA5/6 коды доходят до 0xF8FF)
local ICON_RANGES = ffi_ok and ffi.new('unsigned short[3]', { 0xF000, 0xF8FF, 0 }) or nil

local fcfg = imgui.ImFontConfig()
local function fontCfg(mult)
    fcfg.RasterizerMultiply = mult
    return fcfg
end

local FONT = { body = nil, head = nil }

local function loadMenuFonts()
    local io_ = imgui.GetIO()
    local body = asset('Montserrat-Medium.ttf') or asset('Montserrat-Regular.ttf')
    local head = asset('Montserrat-SemiBold.ttf') or asset('Montserrat-Bold.ttf') or body
    if not body then return end -- нет файла — используется стандартный шрифт ImGui
    FONT.body = io_.Fonts:AddFontFromFileTTF(body, 15.0, fontCfg(1.30), UI_RANGES)

    -- п.15 + фикс п.10: иконки сайдбара должны подмешиваться (MergeMode) СРАЗУ после того
    -- шрифта, в который их нужно добавить (body) — ImGui домешивает глифы в ПОСЛЕДНИЙ
    -- добавленный в атлас шрифт. Раньше этот вызов стоял ПОСЛЕ AddFontFromFileTTF(head, ...),
    -- из-за чего иконки фактически подмешивались в head, а сайдбар рисуется через body —
    -- поэтому иконки не показывались, хотя файл лежал на месте.
    -- Файл кладём в ту же папку, где координаты/настройки: moonloader\config\KladHunter\
    -- (FontAwesome.ttf / fa-solid-900.ttf / fontawesome-webfont.ttf — любое из этих имён).
    if FONT.body and ICON_RANGES then
        local iconFile = asset('FontAwesome.ttf') or asset('fa-solid-900.ttf') or asset('fontawesome-webfont.ttf') or asset('fawesome6.ttf')
        if iconFile then
            local iconCfg = imgui.ImFontConfig()
            iconCfg.MergeMode = true
            iconCfg.RasterizerMultiply = 1.0
            io_.Fonts:AddFontFromFileTTF(iconFile, 15.0, iconCfg, ICON_RANGES)
        end
    end

    FONT.head = io_.Fonts:AddFontFromFileTTF(head, 19.0, fontCfg(1.12), UI_RANGES)
end

------------------------------------------------------------- цвет и текст --
local function u32(r, g, b, a) return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a or 1.0)) end
local function vec(x, y) return imgui.ImVec2(x, y) end

local COL = {
    bg       = { 0.043, 0.047, 0.059 },
    card     = { 1.000, 1.000, 1.000 },
    field    = { 1.000, 1.000, 1.000 },
    active   = { 1.000, 1.000, 1.000 },
    line     = { 1.000, 1.000, 1.000 },
    text     = { 0.937, 0.949, 0.965 },
    dim      = { 0.616, 0.647, 0.702 },
    knob     = { 0.965, 0.976, 0.988 },
    on       = { 0.290, 0.855, 0.502 },
    onTrack  = { 0.290, 0.855, 0.502 },
    shadow   = { 0.000, 0.000, 0.000 },
}

local A = {
    card = 0.07, cardLine = 0.10,
    field = 0.09, fieldLine = 0.08,
    active = 0.11, activeLine = 0.16,
    winLine = 0.12, sep = 0.10,
    track = 0.16, onTrack = 0.30, onLine = 0.38,
    shadow = 0.35,
}

local fade = 1.0

local function c(name, a)
    local t = COL[name]
    return u32(t[1], t[2], t[3], (a or 1) * fade)
end

local function argbToU32(argb, alphaMul)
    local a = bit.band(bit.rshift(argb, 24), 0xFF)
    if alphaMul then a = math.floor(a * alphaMul) end
    return bit.bor(bit.lshift(clamp(a, 0, 255), 24),
                   bit.lshift(bit.band(argb, 0xFF), 16),
                   bit.lshift(bit.band(bit.rshift(argb, 8), 0xFF), 8),
                   bit.band(bit.rshift(argb, 16), 0xFF))
end

-- font = nil -> используется стандартный шрифт ImGui (если Montserrat не найден на диске)
local function textAt(dl, font, size, x, y, text, col)
    if font then dl:AddTextFontPtr(font, size, vec(x, y), col, text)
    else dl:AddText(vec(x, y), col, text, nil) end
end

local function textW(font, size, text)
    if font then return font:CalcTextSizeA(size, math.huge, 0, text).x end
    return imgui.CalcTextSize(text).x
end

local function applyStyle()
    local s = imgui.GetStyle()
    s.WindowRounding = 12; s.ChildRounding = 10; s.FrameRounding = 8; s.PopupRounding = 10
    s.GrabRounding = 8; s.ScrollbarRounding = 8
    s.WindowBorderSize = 0; s.FrameBorderSize = 1; s.ChildBorderSize = 0; s.PopupBorderSize = 1
    s.WindowPadding = imgui.ImVec2(0, 0)
    s.FramePadding = imgui.ImVec2(10, 6)
    s.ItemSpacing = imgui.ImVec2(9, 8)
    s.ItemInnerSpacing = imgui.ImVec2(7, 5)
    s.ScrollbarSize = 8

    local col, C = s.Colors, imgui.Col
    local function v(name, a)
        local t = COL[name]
        return imgui.ImVec4(t[1], t[2], t[3], a or 1.0)
    end
    col[C.WindowBg]             = v('bg', 0.72)
    col[C.Text]                 = v('text')
    col[C.TextDisabled]         = v('dim')
    col[C.ChildBg]              = imgui.ImVec4(0, 0, 0, 0)
    col[C.PopupBg]              = v('bg', 0.96)
    col[C.Border]               = v('line', A.cardLine)
    col[C.FrameBg]              = v('field', A.field)
    col[C.FrameBgHovered]       = v('field', A.field + 0.05)
    col[C.FrameBgActive]        = v('field', A.field + 0.08)
    col[C.Button]               = v('field', A.field)
    col[C.ButtonHovered]        = v('field', A.field + 0.05)
    col[C.ButtonActive]         = v('field', A.field + 0.08)
    col[C.Header]               = v('field', A.field)
    col[C.HeaderHovered]        = v('field', A.field + 0.05)
    col[C.HeaderActive]         = v('field', A.field + 0.08)
    col[C.CheckMark]            = v('on')
    col[C.Separator]            = v('line', A.sep)
    col[C.ScrollbarBg]          = imgui.ImVec4(0, 0, 0, 0)
    col[C.ScrollbarGrab]        = v('line', 0.18)
    col[C.ScrollbarGrabHovered] = v('line', 0.26)
    col[C.ScrollbarGrabActive]  = v('line', 0.34)
end

local lastErr = nil
local function reportErr(err)
    err = tostring(err)
    if err ~= lastErr then
        lastErr = err
        print('[UI] ошибка в кадре: ' .. err)
    end
end

------------------------------------------------------------- анимированный фон --
local BLOBS = {
    color = {
        { col = { 0.243, 0.404, 0.878 }, r = 0.72, per = 17.0, pha = 0.0, px = 0.26, py = 0.34 },
        { col = { 0.612, 0.278, 0.816 }, r = 0.64, per = 23.0, pha = 2.1, px = 0.74, py = 0.62 },
        { col = { 0.157, 0.729, 0.647 }, r = 0.52, per = 31.0, pha = 4.2, px = 0.54, py = 0.20 },
    },
    grey = {
        { col = { 0.620, 0.647, 0.694 }, r = 0.78, per = 19.0, pha = 0.0, px = 0.24, py = 0.30 },
        { col = { 0.400, 0.420, 0.459 }, r = 0.66, per = 27.0, pha = 2.4, px = 0.76, py = 0.66 },
        { col = { 0.780, 0.800, 0.835 }, r = 0.44, per = 37.0, pha = 4.7, px = 0.58, py = 0.22 },
    },
}
local TAU = math.pi * 2

local function auroraBody(dl, wp, w, h, t, alpha)
    local grey = cfg.bg == 'Графит'
    if grey then
        local a = alpha * 0.16
        dl:AddRectFilledMultiColor(vec(wp.x, wp.y), vec(wp.x + w, wp.y + h),
            u32(0.42, 0.44, 0.48, a), u32(0.20, 0.21, 0.24, a * 0.7),
            u32(0.10, 0.11, 0.13, a * 0.5), u32(0.26, 0.28, 0.31, a * 0.8))
    end

    local steps = 13
    local peak = grey and 0.035 or 0.055
    for _, b in ipairs(grey and BLOBS.grey or BLOBS.color) do
        local cx = wp.x + w * (b.px + 0.17 * math.sin(t / b.per * TAU + b.pha))
        local cy = wp.y + h * (b.py + 0.24 * math.cos(t / (b.per * 1.37) * TAU + b.pha))
        local rmax = math.max(w, h) * b.r
        for i = steps, 1, -1 do
            local k = i / steps
            dl:AddCircleFilled(vec(cx, cy), rmax * k,
                u32(b.col[1], b.col[2], b.col[3], alpha * peak * (1 - k) ^ 1.4), 32)
        end
    end
end

local function drawAurora(dl, wp, w, h, t, alpha)
    if alpha <= 0.01 or cfg.bg == 'Нет' then return end
    dl:PushClipRect(vec(wp.x, wp.y), vec(wp.x + w, wp.y + h), true)
    local ok, err = pcall(auroraBody, dl, wp, w, h, t, alpha)
    dl:PopClipRect()
    if not ok then reportErr(err) end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local okF, errF = pcall(loadMenuFonts)
    if not okF then print('[TreasureHunter] Не удалось загрузить шрифты: ' .. tostring(errF)) end
    applyStyle()
end)

------------------------------------------------------------- текст с подложкой --
local function drawPlatedText(dl, font, size, x, y, text, argb, mul)
    local tw = textW(font, size, text)
    if cfg.plate then
        local padX, padY = size * 0.26, size * 0.14
        dl:AddRectFilled(vec(x - padX, y - padY), vec(x + tw + padX, y + size + padY),
            argbToU32(0xB4000000, mul), size * 0.22)
    end
    textAt(dl, font, size, x, y, text, argbToU32(argb, mul))
end

------------------------------------------------------------- виджеты меню --
local guard = { groups = 0, wrap = 0, split = false }
local colW, cardW, frameDt = 0, 0, 0
local CARD_PAD = 14

local function safeSection(fn)
    guard.groups, guard.wrap, guard.split = 0, 0, false
    local ok, err = pcall(fn)
    if ok then return end
    while guard.wrap > 0 do imgui.PopTextWrapPos(); guard.wrap = guard.wrap - 1 end
    if guard.split then imgui.GetWindowDrawList():ChannelsMerge(); guard.split = false end
    while guard.groups > 0 do imgui.EndGroup(); guard.groups = guard.groups - 1 end
    reportErr(err)
end

local ROW_H, VAL_W, TRACK_W = 34, 104, 164
local sectionT, rowIndex = 1, 0

local function rowStart(h)
    rowIndex = rowIndex + 1
    fade = clamp((sectionT - (rowIndex - 1) * 0.04) / 0.20, 0, 1)
    local p = imgui.GetCursorScreenPos()
    imgui.Dummy(vec(colW, h or ROW_H))
    return p, imgui.GetWindowDrawList()
end

local function rowLabel(dl, p, label)
    textAt(dl, FONT.body, 15, p.x, p.y + (ROW_H - 15) / 2 - 1, label, c('text'))
end

local function textClip(dl, x, y, w, text, col, center)
    local size = 14
    dl:PushClipRect(vec(x, y - 3), vec(x + w, y + size + 5), true)
    local tw = center and math.max(0, (w - textW(FONT.body, size, text)) / 2) or 0
    textAt(dl, FONT.body, size, x + tw, y, text, col)
    dl:PopClipRect()
end

-- та же "плашка-значение", что и valueBox, но с произвольными x/шириной —
-- нужно для строк, где одной плашки справа мало (напр. награда: кол-во + сумма)
local function miniValueBox(dl, x, y, w, text, col)
    dl:AddRectFilled(vec(x, y), vec(x + w, y + 28), c('field', A.field), 8)
    dl:AddRect(vec(x, y), vec(x + w, y + 28), c('line', A.fieldLine), 8, nil, 1.0)
    textClip(dl, x + 6, y + 7, w - 12, text, col or c('text'), true)
end

local function valueBox(dl, p, text, col)
    miniValueBox(dl, p.x + colW - VAL_W, p.y + (ROW_H - 28) / 2, VAL_W, text, col)
end

local toggleT = {}

local function toggleRow(label, key, onChange, targetCfg)
    local target = targetCfg or cfg
    local p, dl = rowStart()
    local on = target[key] and true or false
    local t = toggleT[key]
    if t == nil then t = on and 1 or 0 end
    t = clamp(t + (on and 1 or -1) * frameDt / 0.12, 0, 1)
    toggleT[key] = t

    local w, h = 44, 24
    local x = p.x + colW - w
    local y = p.y + (ROW_H - h) / 2

    imgui.SetCursorScreenPos(vec(p.x, p.y))
    if imgui.InvisibleButton('##tg' .. key .. label, vec(colW, ROW_H)) then
        target[key] = not target[key]
        if onChange then onChange(target[key]) end
    end

    rowLabel(dl, p, label)
    local hov = imgui.IsItemHovered()

    dl:AddRectFilled(vec(x, y), vec(x + w, y + h),
        c('field', A.track + (hov and 0.05 or 0)), h / 2)
    if t > 0 then
        dl:AddRectFilled(vec(x, y), vec(x + w, y + h),
            u32(COL.onTrack[1], COL.onTrack[2], COL.onTrack[3], A.onTrack * t * fade), h / 2)
    end
    dl:AddRect(vec(x, y), vec(x + w, y + h),
        t > 0.5 and u32(COL.on[1], COL.on[2], COL.on[3], A.onLine * fade)
                or c('line', A.fieldLine), h / 2, nil, 1.0)

    local kx, kr = x + h / 2 + (w - h) * t, h / 2 - 3
    dl:AddCircleFilled(vec(kx, y + h / 2 + 1.5), kr,
        u32(COL.shadow[1], COL.shadow[2], COL.shadow[3], A.shadow * fade), 20)
    dl:AddCircleFilled(vec(kx, y + h / 2), kr, c('knob', 0.55 + 0.45 * t), 20)
end

-- строка с кнопкой справа (используется для удаления зон и копирования/вставки)
local function buttonRow(label, btnLabel, btnId, btnW)
    local p, dl = rowStart()
    rowLabel(dl, p, label)
    btnW = btnW or 110
    imgui.SetCursorScreenPos(vec(p.x + colW - btnW, p.y + (ROW_H - 26) / 2))
    local clicked = imgui.Button(btnLabel .. '##' .. btnId, vec(btnW, 26))
    imgui.SetCursorScreenPos(vec(p.x, p.y + ROW_H))
    return clicked
end

-- кнопка с защитой от случайного нажатия: действие срабатывает, только если её УДЕРЖИВАТЬ holdSec секунд.
-- Пока кнопка зажата, поверх неё заполняется полоска прогресса; отпустил или увёл курсор раньше — отмена.
-- Возвращает true один раз в момент, когда удержание дошло до конца.
runtimeUI.holdState = {}
function runtimeUI.holdButton(label, id, w, h, holdSec, dl)
    local pos = imgui.GetCursorScreenPos()
    imgui.Button(label .. '##' .. id, vec(w, h))
    local held = imgui.IsItemActive() and imgui.IsItemHovered()
    if not held then
        runtimeUI.holdState[id] = nil
        return false
    end
    local now = os.clock()
    local t0 = runtimeUI.holdState[id]
    if not t0 then
        t0 = now
        runtimeUI.holdState[id] = t0
    end
    local frac = math.min((now - t0) / holdSec, 1)
    dl:AddRectFilled(vec(pos.x, pos.y), vec(pos.x + w * frac, pos.y + h), u32(1.0, 0.35, 0.35, 0.55), 4)
    if frac >= 1 then
        runtimeUI.holdState[id] = nil
        return true
    end
    return false
end

local dragging = {}

local function sliderRow(label, key, mn, mx, fmt, unit, isInt, onChange, targetCfg)
    local target = targetCfg or cfg
    local p, dl = rowStart()
    local v = clamp(target[key] or mn, mn, mx)

    local tx = p.x + colW - VAL_W - 18 - TRACK_W
    local cy = p.y + ROW_H / 2

    imgui.SetCursorScreenPos(vec(tx - 6, p.y))
    local id = '##sl' .. key .. label
    imgui.InvisibleButton(id, vec(TRACK_W + 12, ROW_H))
    if imgui.IsItemActive() then
        local t = clamp((imgui.GetIO().MousePos.x - tx) / TRACK_W, 0, 1)
        local nv = mn + (mx - mn) * t
        if isInt then nv = math.floor(nv + 0.5)
        else nv = math.floor(nv * 100 + 0.5) / 100 end
        if nv ~= v then v = nv; target[key] = nv end
        dragging[id] = true
    elseif dragging[id] then
        dragging[id] = nil
        if onChange then onChange(target[key]) end
    end

    rowLabel(dl, p, label)
    local t = clamp((v - mn) / (mx - mn), 0, 1)
    dl:AddRectFilled(vec(tx, cy - 2.5), vec(tx + TRACK_W, cy + 2.5), c('field', A.track), 3)
    dl:AddRectFilled(vec(tx, cy - 2.5), vec(tx + TRACK_W * t, cy + 2.5), c('knob', 0.9), 3)
    local kx, kr = tx + TRACK_W * t, imgui.IsItemHovered() and 9 or 8
    dl:AddCircleFilled(vec(kx, cy + 1.5), kr,
        u32(COL.shadow[1], COL.shadow[2], COL.shadow[3], A.shadow * fade), 24)
    dl:AddCircleFilled(vec(kx, cy), kr, c('knob'), 24)
    valueBox(dl, p, string.format(fmt, v) .. (unit or ''))
end

local function sliderF(label, key, mn, mx, unit, onChange, targetCfg) sliderRow(label, key, mn, mx, '%.2f', unit, false, onChange, targetCfg) end
local function sliderI(label, key, mn, mx, unit, onChange, targetCfg) sliderRow(label, key, mn, mx, '%.0f', unit, true, onChange, targetCfg) end

local function valueRow(label, value, colName)
    local p, dl = rowStart()
    rowLabel(dl, p, label)
    valueBox(dl, p, value, colName and c(colName))
end

local function card(fn)
    local dl = imgui.GetWindowDrawList()
    dl:ChannelsSplit(2); guard.split = true
    dl:ChannelsSetCurrent(1)
    imgui.Dummy(vec(cardW, CARD_PAD - 4))
    imgui.Indent(CARD_PAD)
    imgui.BeginGroup(); guard.groups = guard.groups + 1
    fn()
    guard.groups = guard.groups - 1; imgui.EndGroup()
    local mn, mx = imgui.GetItemRectMin(), imgui.GetItemRectMax()
    imgui.Unindent(CARD_PAD)
    imgui.Dummy(vec(cardW, CARD_PAD - 4))
    dl:ChannelsSetCurrent(0)
    local x1, y1 = mn.x - CARD_PAD, mn.y - CARD_PAD + 2
    local x2, y2 = mn.x - CARD_PAD + cardW, mx.y + CARD_PAD - 2
    dl:AddRectFilled(vec(x1, y1), vec(x2, y2), c('card', A.card), 12)
    dl:AddRect(vec(x1, y1), vec(x2, y2), c('line', A.cardLine), 12, nil, 1.0)
    dl:AddLine(vec(x1 + 12, y1 + 1), vec(x2 - 12, y1 + 1), c('line', 0.16), 1.0)
    dl:ChannelsMerge(); guard.split = false
    imgui.Dummy(vec(cardW, 10))
end

local C_DIM = imgui.ImVec4(0.616, 0.647, 0.702, 1.00)
local function note(text)
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + colW); guard.wrap = guard.wrap + 1
    imgui.TextColored(C_DIM, '%s', text)
    guard.wrap = guard.wrap - 1; imgui.PopTextWrapPos()
end

------------------------------------------------------------- структура меню --
local ANIM_OPEN, ANIM_CLOSE, ANIM_TAB = 0.28, 0.20, 0.16
local W = 820
local sectionH, winH = {}, 300
local TITLE_H, SIDE_W, PAD = 44, 184, 14
local CLOSE_X, CLOSE_Y, CLOSE_SZ = 36, 12, 20
local menuT, menuLast = 0.0, nil

local SECTIONS = {
    { id = 'main',    name = 'ОСНОВНОЕ',   icon = '\239\128\147' },
    { id = 'zones',   name = 'НАСТРОЙКИ',  icon = '\239\130\133' }, -- fa-cogs; было \239\137\184 (fa-windows, бренд-иконка — её нет в solid-900.ttf, п.3)
    { id = 'bonus',   name = 'ДОП. КЛАДЫ', icon = '\239\134\179' },
    { id = 'reward',  name = 'НАГРАДА',    icon = '\239\133\149' }, -- п.7
    { id = 'players', name = 'ИГРОКИ',     icon = '\239\128\135' },
    { id = 'info',    name = 'ОБЩЕЕ',      icon = '\239\131\170' },
}
local curTab, tabFrom, tabT = 1, 1, 1

local refs = {
    zonePaste  = imgui.new.char[256](),
    playerAdd  = imgui.new.char[64](),
    rewardDay  = imgui.new.int(0), -- индекс выбранного дня в комбобоксе наград (п.4)
}
local playersPage = 1
local rewardDayIndex = 0 -- 0 значит "последний известный день"; ставится при первом открытии вкладки
local rewardItemsPage = 1 -- страница списка наград внутри выбранного дня (п.1)


------------------------------------------------------------- деньги и окно цены --
-- 520000000 -> "520.000.000"
local function fmtMoney(n)
    local str = string.format('%.0f', tonumber(n) or 0)
    local neg = str:sub(1, 1) == '-'
    if neg then str = str:sub(2) end
    local out = str:reverse():gsub('(%d%d%d)', '%1.')
    out = out:reverse()
    if out:sub(1, 1) == '.' then out = out:sub(2) end
    return (neg and '-' or '') .. out
end

-- Отдельное окно для ввода цены за 1 шт. (вместо попапа внутри меню — тот падал на нехватке vec).
local PE = { item = nil, open = imgui.new.bool(false), buf = imgui.new.char[24](), focus = false, w = 400, h = 236 }
PE.enterFlag = (imgui.InputTextFlags and imgui.InputTextFlags.EnterReturnsTrue) or 0

-- затемнение всего экрана под модальным окном: полноэкранное окно-подложка; при первом кадре выходит
-- на передний план (SetNextWindowFocus), дальше не "всплывает" при кликах, чтобы не перекрыть окно цены/дней
function runtimeUI.dimScreen(first)
    -- без PushStyleVar/PushStyleColor (в части сборок mimgui их нет): окно без фона, затемнение рисуем сами
    if not (imgui.WindowFlags.NoBackground and imgui.WindowFlags.NoBringToFrontOnFocus and imgui.SetNextWindowFocus) then return end
    imgui.SetNextWindowPos(vec(0, 0), imgui.Cond.Always)
    imgui.SetNextWindowSize(vec(resX, resY), imgui.Cond.Always)
    local fl = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove
        + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoCollapse
        + imgui.WindowFlags.NoBackground
    if first then imgui.SetNextWindowFocus() else fl = fl + imgui.WindowFlags.NoBringToFrontOnFocus end
    imgui.Begin('##dimscreen', nil, fl)
    imgui.GetWindowDrawList():AddRectFilled(vec(0, 0), vec(resX, resY), argbToU32(0x73000000, 1))
    imgui.End()
end

-- красные кнопки (удаление): если PushStyleColor недоступен — кнопки просто остаются обычного цвета
function runtimeUI.pushDanger(alpha)
    if not (imgui.PushStyleColor and imgui.PopStyleColor and imgui.ImVec4 and imgui.Col and imgui.Col.Button) then return 0 end
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.72, 0.18, 0.18, alpha))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.85, 0.25, 0.25, math.min(1, alpha + 0.1)))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.85, 0.25, 0.25, math.min(1, alpha + 0.1)))
    return 3
end
function runtimeUI.popDanger(n)
    if n > 0 then imgui.PopStyleColor(n) end
end

function PE.show(name)
    PE.first = true
    PE.item = name
    if ffi_ok then
        ffi.fill(PE.buf, 24, 0)
        ffi.copy(PE.buf, string.format('%.0f', math.min(runtimeUI.priceOf(name), CFG.maxPrice))) -- <= 12 цифр, буфер 24 байта
    end
    PE.focus = true
    PE.open[0] = true
end

-- берём из поля только цифры: можно вводить и 1500000, и 1.500.000
function PE.parse()
    local digits = bufToString(PE.buf):gsub('[^%d]', ''):sub(1, 15)
    return math.min(tonumber(digits) or 0, CFG.maxPrice)
end

-- CallbackCharFilter: пропускаем только символы '0'..'9' (1 = отбросить символ)
function PE.digitsOnly(data)
    local ch = data.EventChar
    if ch < 48 or ch > 57 then return 1 end
    return 0
end

function PE.save()
    if PE.item then
        local key = runtimeUI.priceKey(PE.item)
        prices[key] = PE.parse()
        if key ~= PE.item then prices[PE.item] = nil end -- старый ключ с пробелами не оставляем (иначе при чтении перебьёт новый)
        saveCfg()
        dbg('Цена сохранена: [%s] = %s', key, tostring(prices[key]))
    end
    PE.open[0] = false
end

function PE.draw(dl, wp)
    local PW, PH = PE.w, PE.h
    drawAurora(dl, wp, PW, PH, os.clock(), 1)
    dl:AddRect(vec(wp.x, wp.y), vec(wp.x + PW, wp.y + PH), c('line', A.winLine), 12, nil, 1.0)

    -- в заголовке — название награды, а подпись "ЦЕНА ЗА 1 ШТ." — в теле окна
    local title = u8:encode(PE.item or '')
    local tw = textW(FONT.head, 19, title)
    if tw <= PW - 40 then
        textAt(dl, FONT.head, 19, wp.x + (PW - tw) / 2, wp.y + 11, title, c('text'))
    else
        textClip(dl, wp.x + 20, wp.y + 13, PW - 40, title, c('text'), true)
    end
    dl:AddLine(vec(wp.x, wp.y + TITLE_H), vec(wp.x + PW, wp.y + TITLE_H), c('line', A.sep), 1)

    textClip(dl, wp.x + 20, wp.y + TITLE_H + 16, PW - 40, u8:encode('ЦЕНА ЗА 1 ШТ.'), c('text'), true)
    textClip(dl, wp.x + 20, wp.y + TITLE_H + 42, PW - 40,
        u8:encode('Текущая цена: ' .. fmtMoney(runtimeUI.priceOf(PE.item)) .. '$'), c('dim'), true)

    imgui.SetCursorPos(vec(20, TITLE_H + 74))
    imgui.SetNextItemWidth(PW - 40)
    if PE.focus then
        pcall(imgui.SetKeyboardFocusHere, 0)
        PE.focus = false
    end
    -- только цифры: фильтр символов на лету (CallbackCharFilter) — буквы и знаки не вводятся, в том числе вставкой.
    -- Если эта сборка mimgui не принимает Lua-функцию как колбэк, откатываемся на встроенный CharsDecimal
    -- (буквы блокирует, а оставшиеся знаки .+-*/ всё равно отбрасывает PE.parse).
    local entered = false
    local cbFlag = imgui.InputTextFlags and imgui.InputTextFlags.CallbackCharFilter
    if cbFlag and PE.cbBroken ~= true then
        local okIn, res = pcall(imgui.InputText, '##priceinput', PE.buf, 24, PE.enterFlag + cbFlag, PE.digitsOnly)
        if okIn then
            entered = res
        else
            PE.cbBroken = true
            print('[TreasureHunter] Фильтр ввода цены недоступен, использую CharsDecimal: ' .. tostring(res))
        end
    end
    if PE.cbBroken == true or not cbFlag then
        local dec = (imgui.InputTextFlags and imgui.InputTextFlags.CharsDecimal) or 0
        entered = imgui.InputText('##priceinput', PE.buf, 24, PE.enterFlag + dec)
    end
    if entered then PE.save() end

    textClip(dl, wp.x + 20, wp.y + TITLE_H + 112, PW - 40,
        u8:encode('Будет: ' .. fmtMoney(PE.parse()) .. '$'), c('dim'), true)

    local bw = (PW - 40 - 10) / 2
    imgui.SetCursorPos(vec(20, PH - 52))
    if imgui.Button(u8:encode('Сохранить') .. '##pe_save', vec(bw, 32)) then PE.save() end
    imgui.SameLine(0, 10)
    if imgui.Button(u8:encode('Отмена') .. '##pe_cancel', vec(bw, 32)) then PE.open[0] = false end
end


------------------------------------------------------------- окно выбора дня --
-- Отдельное (затемняющее экран) окно: список дней, статистика выбранного дня и за 7 дней,
-- кнопки "Открыть день", "Сегодня", "Удалить день", "Удалить все дни" (удаление — с подтверждением).
local PD = { open = imgui.new.bool(false), sel = nil, first = false, confirm = nil, w = 700, h = 440 }

function PD.fmtDate(d) -- '2026-10-07' -> '07.10.2026'
    local y, m, dd = tostring(d):match('^(%d+)-(%d+)-(%d+)$')
    if not y then return tostring(d) end
    return dd .. '.' .. m .. '.' .. y
end

-- (выкопано кладов, прибыль) за конкретный день
function PD.stats(date)
    local day = rewardsByDay[date]
    if not day then return 0, 0 end
    local total = 0
    for name, cnt in pairs(day.totals) do
        if name ~= DIG_COUNT_KEY then total = total + runtimeUI.priceOf(name) * cnt end
    end
    return day.totals[DIG_COUNT_KEY] or 0, total
end

-- сумма за последние 7 дней, включая сегодня
function PD.last7()
    local t = os.date('*t')
    t.hour, t.min, t.sec = 12, 0, 0 -- полдень, чтобы переход на летнее время не сдвинул дату
    local base = os.time(t)
    local digs, total = 0, 0
    for i = 0, 6 do
        local dg, tt = PD.stats(os.date('%Y-%m-%d', base - i * 86400))
        digs, total = digs + dg, total + tt
    end
    return digs, total, os.date('%d.%m', base - 6 * 86400) .. ' - ' .. os.date('%d.%m', base)
end

function PD.show()
    PD.sel = rewardDayOrder[rewardDayIndex] or os.date('%Y-%m-%d')
    PD.confirm = nil
    PD.first = true
    PD.open[0] = true
end

-- копия RewardLog.txt перед любым удалением (RewardLog.txt.bak) — страховка от ошибки
function PD.backup()
    runtimeUI.spcall('RewardLog.txt.bak', function()
        local fi = io.open(PATHS.rewardFile, 'rb')
        if not fi then return end
        local data = fi:read('*a')
        fi:close()
        local fo = io.open(PATHS.rewardFile .. '.bak', 'wb')
        if fo then fo:write(data) fo:close() end
    end)
end

function PD.deleteDay(date)
    PD.backup()
    local cur = rewardDayOrder[rewardDayIndex]
    rewardsByDay[date] = nil
    for i = #rewardDayOrder, 1, -1 do
        if rewardDayOrder[i] == date then table.remove(rewardDayOrder, i) end
    end
    local okS, errS = saveRewardFile()
    if not okS then print('[TreasureHunter] Не удалось сохранить RewardLog.txt: ' .. tostring(errS)) end
    rewardDayIndex = #rewardDayOrder
    for i, d in ipairs(rewardDayOrder) do
        if d == cur then rewardDayIndex = i break end
    end
    rewardItemsPage = 1
    PD.sel = rewardDayOrder[#rewardDayOrder]
    dbg('Удалён день %s; осталось дней: %d', tostring(date), #rewardDayOrder)
end

function PD.deleteAll()
    PD.backup()
    for k in pairs(rewardsByDay) do rewardsByDay[k] = nil end
    for i = #rewardDayOrder, 1, -1 do table.remove(rewardDayOrder, i) end
    local okS, errS = saveRewardFile()
    if not okS then print('[TreasureHunter] Не удалось сохранить RewardLog.txt: ' .. tostring(errS)) end
    rewardDayIndex, rewardItemsPage, PD.sel = 0, 1, nil
    dbg('Удалены все дни награды')
end

function PD.draw(dl, wp)
    local PW, PH = PD.w, PD.h
    drawAurora(dl, wp, PW, PH, os.clock(), 1)
    dl:AddRect(vec(wp.x, wp.y), vec(wp.x + PW, wp.y + PH), c('line', A.winLine), 12, nil, 1.0)

    local title = u8:encode('ВЫБОР ДНЯ')
    textAt(dl, FONT.head, 19, wp.x + (PW - textW(FONT.head, 19, title)) / 2, wp.y + 11, title, c('text'))
    dl:AddLine(vec(wp.x, wp.y + TITLE_H), vec(wp.x + PW, wp.y + TITLE_H), c('line', A.sep), 1)

    -- крестик закрытия — такой же, как в главном меню
    imgui.SetCursorPos(vec(PW - CLOSE_X, CLOSE_Y))
    local closeHit = imgui.InvisibleButton('##pd_close', vec(CLOSE_SZ, CLOSE_SZ))
    local cpx = vec(wp.x + PW - CLOSE_X, wp.y + CLOSE_Y)
    local ccol = imgui.IsItemHovered() and c('text') or c('dim')
    dl:AddLine(vec(cpx.x + 6, cpx.y + 6), vec(cpx.x + 14, cpx.y + 14), ccol, 1.6)
    dl:AddLine(vec(cpx.x + 14, cpx.y + 6), vec(cpx.x + 6, cpx.y + 14), ccol, 1.6)
    if closeHit then PD.open[0] = false end

    local today = os.date('%Y-%m-%d')
    local y0 = TITLE_H + 16

    -- левая колонка: список дней (новые сверху)
    local listW, listH = 220, PH - y0 - 20
    imgui.SetCursorPos(vec(20, y0))
    imgui.BeginChild('##pdlist', vec(listW, listH), true)
    for i = #rewardDayOrder, 1, -1 do
        local d = rewardDayOrder[i]
        local label = PD.fmtDate(d) .. (d == today and '  (' .. 'сегодня' .. ')' or '')
        if imgui.Selectable(u8:encode(label) .. '##pdday' .. d, PD.sel == d) then
            PD.sel = d
            PD.confirm = nil
        end
    end
    imgui.EndChild()

    -- правая колонка
    local rx = 20 + listW + 20
    local rw = PW - rx - 20
    local boxW = 150
    local function statRow(y, label, value)
        textClip(dl, wp.x + rx, wp.y + y + 5, rw - boxW - 10, u8:encode(label), c('text'), false)
        miniValueBox(dl, wp.x + rx + rw - boxW, wp.y + y, boxW, value)
    end

    local sel = PD.sel
    local head = sel and (PD.fmtDate(sel) .. (sel == today and ' - сегодня' or '')) or 'День не выбран'
    textAt(dl, FONT.head, 19, wp.x + rx, wp.y + y0, u8:encode(head), c('text'))

    local dg, tot = PD.stats(sel or '')
    statRow(y0 + 34, 'Выкопано кладов:', tostring(dg))
    statRow(y0 + 70, 'Прибыль за день:', fmtMoney(tot) .. '$')

    dl:AddLine(vec(wp.x + rx, wp.y + y0 + 112), vec(wp.x + rx + rw, wp.y + y0 + 112), c('line', A.sep), 1)

    local dg7, tot7, range = PD.last7()
    textClip(dl, wp.x + rx, wp.y + y0 + 122, rw, u8:encode('За последние 7 дней (' .. range .. '):'), c('dim'), false)
    statRow(y0 + 148, 'Выкопано кладов:', tostring(dg7))
    statRow(y0 + 184, 'Прибыль за 7 дней:', fmtMoney(tot7) .. '$')

    dl:AddLine(vec(wp.x + rx, wp.y + y0 + 226), vec(wp.x + rx + rw, wp.y + y0 + 226), c('line', A.sep), 1)

    -- кнопки
    local by = y0 + 240
    local bw = (rw - 10) / 2
    local cf = PD.confirm
    if cf and os.clock() - cf.at > 10 then cf = nil PD.confirm = nil end -- подтверждение "протухает"

    if not cf then
        imgui.SetCursorPos(vec(rx, by))
        if imgui.Button(u8:encode('Открыть день') .. '##pd_open', vec(bw, 32)) and sel then
            ensureRewardDay(sel)
            for i, d in ipairs(rewardDayOrder) do
                if d == sel then rewardDayIndex = i break end
            end
            rewardItemsPage = 1
            PD.open[0] = false
        end
        imgui.SameLine(0, 10)
        if imgui.Button(u8:encode('Сегодня') .. '##pd_today', vec(bw, 32)) then
            ensureRewardDay(today) -- если записей за сегодня ещё нет — появится пустой день
            PD.sel = today
        end

        local nPush = runtimeUI.pushDanger(0.85)
        imgui.SetCursorPos(vec(rx, by + 42))
        if imgui.Button(u8:encode('Удалить день') .. '##pd_del', vec(bw, 32)) and sel and rewardsByDay[sel] then
            PD.confirm = { kind = 'day', date = sel, at = os.clock() }
        end
        imgui.SameLine(0, 10)
        if imgui.Button(u8:encode('Удалить все дни') .. '##pd_delall', vec(bw, 32)) and #rewardDayOrder > 0 then
            PD.confirm = { kind = 'all', at = os.clock() }
        end
        runtimeUI.popDanger(nPush)
    else
        local red = argbToU32(0xFFFF6B6B, 1)
        local l1, l2
        if cf.kind == 'day' then
            l1 = 'Удалить день ' .. PD.fmtDate(cf.date) .. '?'
            l2 = 'Будут стёрты награда и счётчик кладов за этот день.'
        else
            l1 = 'Удалить ВСЕ дни (' .. #rewardDayOrder .. ')?'
            l2 = 'Вся история наград будет стёрта.'
        end
        textClip(dl, wp.x + rx, wp.y + by, rw, u8:encode(l1), red, false)
        textClip(dl, wp.x + rx, wp.y + by + 22, rw, u8:encode(l2), c('dim'), false)
        textClip(dl, wp.x + rx, wp.y + by + 42, rw, u8:encode('Копия сохранится в RewardLog.txt.bak'), c('dim'), false)

        local wait_ = 1.5 - (os.clock() - cf.at) -- защита от случайного двойного клика
        local ready = wait_ <= 0
        local nPush = runtimeUI.pushDanger(ready and 0.95 or 0.4)
        imgui.SetCursorPos(vec(rx, by + 72))
        local yesLabel = ready and 'Да, удалить' or string.format('Подождите %.1f с', wait_)
        if imgui.Button(u8:encode(yesLabel) .. '##pd_yes', vec(bw, 32)) and ready then
            if cf.kind == 'day' then PD.deleteDay(cf.date) else PD.deleteAll() end
            PD.confirm = nil
        end
        runtimeUI.popDanger(nPush)
        imgui.SameLine(0, 10)
        if imgui.Button(u8:encode('Отмена') .. '##pd_no', vec(bw, 32)) then PD.confirm = nil end
    end

end

local function drawSection()
    local id = SECTIONS[curTab].id

    if id == 'main' then
        card(function()
            toggleRow(u8:encode('Авто-возврат территории'), 'autoRestore', saveCfg, zcfg)

            toggleRow(u8:encode('Отрисовка меток и маркеров'), 'markersEnabled', function(on)
                saveCfg()
                runtimeUI.onMarkersToggle(on) -- при выключении снимаем уже стоящие метки/маркеры
            end, zcfg) -- п.22

            toggleRow(u8:encode('Автоматическое выкапывание'), 'autoExcavate', saveCfg, zcfg) -- п.5
            if zcfg.autoExcavate then -- п.5: подстройка задержки видна только когда функция включена
                sliderF(u8:encode('  Задержка перед авто-кликом'), 'autoExcavateDelayMs', 500, 10000, u8:encode(' мс'), saveCfg, zcfg)
            end

            toggleRow(u8:encode('Авто-удаление меток на карте'), 'autoRemoveMarkers', saveCfg, zcfg) -- п.24, переименовано п.1
            note(u8:encode('При приближении к точке клада на "Радиус проверки метки", метка на карте будет удаляться.')) -- п.7

            toggleRow(u8:encode('Скрывать серверные иконки на карте'), 'hideServerMapIcon', saveCfg, zcfg) -- п.1,18
            if zcfg.hideServerMapIcon then -- п.8: саб-тоггл виден только когда основной включён
                toggleRow(u8:encode('  Только в зоне клада'), 'hideServerMapIconOnlyInZone', saveCfg, zcfg)
            end

            toggleRow(u8:encode('Всегда показывать ближайшие'), 'showAllNearby', nil, runtimeUI) -- п.13, не сохраняется
            note(u8:encode('Все клады рядом, не только из территории. Видимость только по "Радиусу появления меток". Не сохраняется.'))

            toggleRow(u8:encode('Рендер зоны металлоискателя'), 'detectorRenderEnabled', saveCfg, zcfg) -- п.5
            note(u8:encode('При появлении металлоискателя на экране будет появляться визуальный круг, в котором находится клад.')) -- п.7
        end)

    elseif id == 'zones' then
        card(function()
            sliderF(u8:encode('Радиус проверки метки'), 'closeRadius', 2.0, 45.0, u8:encode(' м'), saveCfg, zcfg) -- п.5,17
            sliderF(u8:encode('Радиус появления меток'), 'markerRadius', 20.0, 300.0, u8:encode(' м'), saveCfg, zcfg) -- п.11
            imgui.Dummy(vec(colW, 4))
            note(u8:encode('Иконка пропадает ближе "радиуса проверки метки" (маркер остаётся). Оба появляются в пределах "радиуса появления меток".')) -- п.2,5
        end)

        card(function()
            note(u8:encode('Обмен территорией с другим игроком:'))
            imgui.Dummy(vec(colW, 4))

            if buttonRow(u8:encode('Скопировать текущую территорию'), u8:encode('Копировать'), 'zonecopybtn', 140) then
                copyCurrentZoneToClipboard()
            end

            imgui.SetNextItemWidth(colW)
            imgui.InputText('##zonepastebuf', refs.zonePaste, 256)
            imgui.Dummy(vec(colW, 6))

            if buttonRow(u8:encode('Вставить территорию из поля выше'), u8:encode('Вставить'), 'zonepastebtn', 140) then
                pasteZoneFromText(bufToString(refs.zonePaste))
            end
        end)

        card(function()
            note(u8:encode(string.format('Восстановленные территории (максимум %d):', CFG.maxSavedZones)))
            imgui.Dummy(vec(colW, 4))

            if #restoredZones == 0 then
                note(u8:encode('Пока нет ни одной восстановленной территории.'))
            else
                for i = #restoredZones, 1, -1 do
                    local z = restoredZones[i]
                    local label = u8:encode(string.format('Территория #%d — создана в %s', z.num, z.createdAt))
                    if buttonRow(label, u8:encode('Удалить'), 'delzone' .. z.id, 100) then
                        deleteRestoredZone(i)
                    end
                end
            end
        end)

    elseif id == 'bonus' then -- п.2: отдельная страница для доп. кладов
        card(function()
            note(u8:encode('Дополнительные клады:'))
            imgui.Dummy(vec(colW, 4))

            if #bonusTreasures == 0 then
                note(u8:encode('Пока ни одного не найдено.'))
            else
                -- расстояние обновляется при открытии вкладки; кнопка — ручное обновление
                if buttonRow(u8:encode('Расстояние обновляется при открытии вкладки или по кнопке'), u8:encode('Обновить'), 'bonusdistrefresh', 110) then
                    runtimeUI.refreshBonusDistances()
                end
                note(u8:encode('Чтобы убрать клад из списка, удерживай кнопку «Убрать из списка» 0,5 сек.'))
                imgui.Dummy(vec(colW, 4))
                for i = #bonusTreasures, 1, -1 do
                    local entry = bonusTreasures[i]
                    local label = u8:encode(string.format('Клад #%d — найден в %s', i, entry.foundAt) .. runtimeUI.fmtBonusDist(entry.dist))
                    local btnLabel = entry.active and u8:encode('Удалить метку') or u8:encode('Поставить метку')
                    local btnW, delW = 150, 130
                    local p, dl = rowStart()
                    rowLabel(dl, p, label)
                    local by = p.y + (ROW_H - 26) / 2
                    imgui.SetCursorScreenPos(vec(p.x + colW - delW - 8 - btnW, by))
                    if imgui.Button(btnLabel .. '##bonustr' .. i, vec(btnW, 26)) then
                        toggleBonusMarkers(entry)
                    end
                    -- полное удаление из списка: справа, только по удержанию (защита от случайного нажатия)
                    imgui.SetCursorScreenPos(vec(p.x + colW - delW, by))
                    if runtimeUI.holdButton(u8:encode('Убрать из списка'), 'bonusdel' .. i, delW, 26, 0.5, dl) then
                        removeBonusMarkers(entry) -- блип, 3D-маркер и чекпоинт; поток слежения за чекпоинтом завершится сам
                        table.remove(bonusTreasures, i)
                    end
                    imgui.SetCursorScreenPos(vec(p.x, p.y + ROW_H))
                end
            end
        end)

    elseif id == 'reward' then -- п.7
        card(function()
            note(u8:encode('Награда с кладов по дням. Учитываются все слоты, а не только выбранные.')) -- п.2
        end)

        if #rewardDayOrder == 0 then
            card(function()
                note(u8:encode('Пока нет ни одной записи о награде.'))
            end)
        else
            if rewardDayIndex == 0 then rewardDayIndex = #rewardDayOrder end
            rewardDayIndex = clamp(rewardDayIndex, 1, #rewardDayOrder)

            local date = rewardDayOrder[rewardDayIndex]
            local day = rewardsByDay[date]
            local digsToday = day.totals[DIG_COUNT_KEY] or 0

            -- день выбирается в отдельном окне (PD): список дней, статистика, "Сегодня", удаление
            card(function()
                local p, dl = rowStart()
                rowLabel(dl, p, u8:encode('День:'))

                local boxW = VAL_W
                local btnW = 130
                miniValueBox(dl, p.x + colW - boxW, p.y + (ROW_H - 28) / 2, boxW, PD.fmtDate(date))
                imgui.SetCursorScreenPos(vec(p.x + colW - boxW - 8 - btnW, p.y + (ROW_H - 26) / 2))
                if imgui.Button(u8:encode('Выбрать день') .. '##pdopen', vec(btnW, 26)) then PD.show() end
                imgui.SetCursorScreenPos(vec(p.x, p.y + ROW_H))

                imgui.Dummy(vec(colW, 2))
                valueRow(u8:encode('Всего дней с кладами'), tostring(#rewardDayOrder))
                valueRow(u8:encode('Выкопано в этот день'), tostring(digsToday))
            end)

            card(function()
                -- считаем только реальные предметы (без служебного DIG_COUNT_KEY)
                local names = {}
                local dayTotal = 0
                for _, name in ipairs(day.order) do
                    if name ~= DIG_COUNT_KEY then
                        table.insert(names, name)
                        dayTotal = dayTotal + runtimeUI.priceOf(name) * day.totals[name]
                    end
                end

                do -- сумма с разделением точками, плашка той же ширины, что и у каждой награды ниже
                    local pT, dlT = rowStart()
                    rowLabel(dlT, pT, u8:encode('Итого за день'))
                    miniValueBox(dlT, pT.x + colW - CFG.rewardBoxW, pT.y + (ROW_H - 28) / 2,
                        CFG.rewardBoxW, fmtMoney(dayTotal))
                end
                imgui.Dummy(vec(colW, 4))

                if #names == 0 then
                    note(u8:encode('За этот день предметов нет.'))
                else
                    -- п.1: пагинация, чтобы меню не растягивалось на весь экран
                    local totalPages = math.max(1, math.ceil(#names / CFG.rewardPageSize))
                    rewardItemsPage = clamp(rewardItemsPage, 1, totalPages)
                    local from = (rewardItemsPage - 1) * CFG.rewardPageSize + 1
                    local to = math.min(from + CFG.rewardPageSize - 1, #names)

                    for i = from, to do
                        local name = names[i]
                        local count = day.totals[name]
                        local cost = runtimeUI.priceOf(name) * count

                        local p, dl = rowStart()
                        rowLabel(dl, p, u8:encode(name)) -- п.2: только название, количество — отдельным полем

                        -- справа налево: сумма (такой же ширины, как "Итого за день"), маленькая кнопка "$", кол-во
                        local countW, btnW, costW, gap = 64, 30, CFG.rewardBoxW, 8
                        local costX  = p.x + colW - costW
                        local btnX   = costX - gap - btnW
                        local countX = btnX - gap - countW
                        local boxY   = p.y + (ROW_H - 28) / 2

                        miniValueBox(dl, countX, boxY, countW, 'x' .. count)

                        imgui.SetCursorScreenPos(vec(btnX, boxY))
                        if imgui.Button(u8:encode('$') .. '##priceedit' .. name, vec(btnW, 28)) then
                            PE.show(name)
                        end

                        miniValueBox(dl, costX, boxY, costW, fmtMoney(cost) .. '$')
                        imgui.SetCursorScreenPos(vec(p.x, p.y + ROW_H))
                    end

                    if totalPages > 1 then
                        imgui.Dummy(vec(colW, 6))
                        if imgui.Button(u8:encode('< Назад') .. '##rewardpgprev', vec(100, 26)) then
                            rewardItemsPage = clamp(rewardItemsPage - 1, 1, totalPages)
                        end
                        imgui.SameLine()
                        if imgui.Button(u8:encode('Вперёд >') .. '##rewardpgnext', vec(100, 26)) then
                            rewardItemsPage = clamp(rewardItemsPage + 1, 1, totalPages)
                        end
                        imgui.SameLine()
                        imgui.Text(u8:encode(string.format('Стр. %d/%d', rewardItemsPage, totalPages)))
                    end
                end
            end)

        end

    elseif id == 'players' then -- п.26
        card(function()
            note(u8:encode('Введите ник игрока, которого вы хотите добавить в чекер:')) -- п.11
            imgui.Dummy(vec(colW, 4))
            imgui.SetNextItemWidth(colW)
            imgui.InputText('##playeraddbuf', refs.playerAdd, 64)
            imgui.Dummy(vec(colW, 6))
            if buttonRow(u8:encode('Добавить из поля выше'), u8:encode('Добавить'), 'playeraddbtn', 130) then
                if addToWatchlist(bufToString(refs.playerAdd)) then
                    refs.playerAdd[0] = 0 -- очищаем поле после успешного добавления
                end
            end
            toggleRow(u8:encode('Показывать только онлайн'), 'playersOnlyOnline', saveCfg, zcfg)
        end)

        card(function()
            -- п.12: сколько всего добавлено и сколько сейчас онлайн
            local onlineCount = 0
            for _, p in ipairs(watchlist) do
                if p.online then onlineCount = onlineCount + 1 end
            end
            valueRow(u8:encode('Всего в списке'), tostring(#watchlist))
            valueRow(u8:encode('Сейчас онлайн'), tostring(onlineCount))
        end)

        card(function()
            local list = {}
            for idx, p in ipairs(watchlist) do
                if not zcfg.playersOnlyOnline or p.online then
                    table.insert(list, idx)
                end
            end

            local totalPages = math.max(1, math.ceil(#list / PLAYERS_PAGE_SIZE))
            playersPage = clamp(playersPage or 1, 1, totalPages)

            note(u8:encode(string.format('Список (%d): страница %d из %d', #list, playersPage, totalPages)))
            imgui.Dummy(vec(colW, 4))

            if #list == 0 then
                note(u8:encode('Список пуст.'))
            else
                local from = (playersPage - 1) * PLAYERS_PAGE_SIZE + 1
                local to = math.min(from + PLAYERS_PAGE_SIZE - 1, #list)
                for i = from, to do
                    local wIdx = list[i]
                    local p = watchlist[wIdx]
                    -- п.9: для онлайн-игроков показываем ID рядом с ником, напр. "Force_Mercy [252]"
                    local label
                    if p.online and p.id then
                        label = u8:encode(string.format('%s [%d]  -  ', p.nick, p.id)) .. u8:encode('Онлайн')
                    else
                        label = u8:encode(p.nick) .. '  -  ' .. u8:encode('Не в сети')
                    end
                    if buttonRow(label, u8:encode('Удалить'), 'delplayer' .. wIdx, 100) then
                        removeFromWatchlist(wIdx)
                    end
                end
            end

            if totalPages > 1 then
                imgui.Dummy(vec(colW, 6))
                if imgui.Button(u8:encode('< Назад') .. '##ppgprev', vec(100, 26)) then
                    playersPage = clamp(playersPage - 1, 1, totalPages)
                end
                imgui.SameLine()
                if imgui.Button(u8:encode('Вперёд >') .. '##ppgnext', vec(100, 26)) then
                    playersPage = clamp(playersPage + 1, 1, totalPages)
                end
            end
        end)

    else -- 'info' (Общее)
        card(function()
            note(u8:encode('Статистика за сессию:'))
            imgui.Dummy(vec(colW, 4))
            valueRow(u8:encode('Координат кладов загружено'), tostring(loadedFromFileCount))
            valueRow(u8:encode('Кладов выкопано'), tostring(stats.dugCount))
            valueRow(u8:encode('Доп. кладов получено'), tostring(stats.bonusCount)) -- п.4
            valueRow(u8:encode('Территорий восстановлено'), tostring(stats.restoredCount))
        end)

        card(function()
            note(u8:encode('Управление скриптом:'))
            imgui.Dummy(vec(colW, 4))

            toggleRow(u8:encode('DEBUG (отладка в консоль)'), 'debug', function(on)
                if on then dbg('DEBUG включён из меню')
                else print('[TreasureHunter][DEBUG] выключен из меню') end
            end, runtimeUI.debugProxy)

            if buttonRow(u8:encode('Перезагрузить скрипт'), u8:encode('Перезагрузить'), 'reloadscript', 150) then
                pcall(function() thisScript():reload() end)
            end
            if buttonRow(u8:encode('Выгрузить скрипт'), u8:encode('Выгрузить'), 'unloadscript', 150) then
                pcall(function() thisScript():unload() end)
            end
        end)
    end
end

local function drawTitle(dl, wp)
    local title = 'TREASURE HUNTER'
    local tw = textW(FONT.head, 19, title)
    textAt(dl, FONT.head, 19, wp.x + (W - tw) / 2, wp.y + 11, title, c('text'))
    dl:AddLine(vec(wp.x, wp.y + TITLE_H), vec(wp.x + W, wp.y + TITLE_H), c('line', A.sep), 1)
end

local function drawSidebar(dl, wp)
    local x = wp.x + PAD
    local w = SIDE_W - PAD
    local y0 = TITLE_H + 12
    local h = 43

    for i, sec in ipairs(SECTIONS) do
        imgui.SetCursorPos(vec(PAD, y0 + (i - 1) * h))
        if imgui.InvisibleButton('##sec' .. sec.id, vec(w, h)) and curTab ~= i then
            tabFrom = tabFrom + (curTab - tabFrom) * easeOutCubic(tabT)
            tabT, sectionT = 0, 0
            curTab = i
            if sec.id == 'players' then refreshWatchlistOnlineStatus() end -- п.26
            if sec.id == 'bonus' then runtimeUI.refreshBonusDistances() end
        end
        sec.hovered = imgui.IsItemHovered()
    end

    local pos = tabFrom + (curTab - tabFrom) * easeOutCubic(tabT)
    local ay = wp.y + y0 + (pos - 1) * h
    for i = 3, 1, -1 do
        dl:AddRectFilled(vec(x - i * 2, ay + 2 - i * 2), vec(x + w + i * 2, ay + h - 2 + i * 2),
            c('line', 0.015 * (4 - i)), 10 + i * 2)
    end
    dl:AddRectFilled(vec(x, ay + 2), vec(x + w, ay + h - 2), c('active', A.active), 10)
    dl:AddRect(vec(x, ay + 2), vec(x + w, ay + h - 2), c('line', A.activeLine), 10, nil, 1.0)

    for i, sec in ipairs(SECTIONS) do
        local y = wp.y + y0 + (i - 1) * h
        local col
        if i == curTab then col = c('text')
        elseif sec.hovered then col = c('text', 0.8)
        else col = c('dim') end
        local label = (sec.icon or '') .. '  ' .. u8:encode(sec.name) -- п.15: иконка перед текстом
        textAt(dl, FONT.body, 16, x + 15, y + (h - 16) / 2 - 1, label, col)
    end

    -- п.7: подпись автора под последним пунктом меню
    local authorY = wp.y + y0 + #SECTIONS * h + 14
    local authorText = 'by xMercy'
    local aw = textW(FONT.body, 13, authorText)
    textAt(dl, FONT.body, 13, x + (w - aw) / 2, authorY, authorText, c('dim', 0.7))
end

local menu = imgui.new.bool(false)
local wasMenuOpen = false

local function safeDraw(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then reportErr(err) end
end

imgui.OnFrame(function() return menu[0] or menuT > 0 end, function(self)
    self.HideCursor = not menu[0]

    -- п.26: если меню открылось сразу на вкладке "Игроки" — освежаем онлайн-статус
    if menu[0] and not wasMenuOpen and SECTIONS[curTab].id == 'players' then
        refreshWatchlistOnlineStatus()
    end
    -- если меню открылось сразу на вкладке "Доп. клады" — считаем расстояния до них
    if menu[0] and not wasMenuOpen and SECTIONS[curTab].id == 'bonus' then
        runtimeUI.refreshBonusDistances()
    end
    wasMenuOpen = menu[0]

    local now = os.clock()
    local dt = now - (menuLast or now)
    if dt < 0 or dt > 0.1 then dt = 0 end
    menuLast = now
    frameDt = dt
    tabT = math.min(1.0, tabT + dt / ANIM_TAB)
    sectionT = math.min(1.4, sectionT + dt)

    local dir = menu[0] and 1 or -1
    local dur = (dir == 1) and ANIM_OPEN or ANIM_CLOSE
    menuT = clamp(menuT + dir * dt / dur, 0.0, 1.0)

    local e = easeOutCubic(menuT)
    local k = math.max(0.02, e)

    local sideH = TITLE_H + 12 + #SECTIONS * 43 + 34 -- +34 вместо +14: запас под подпись "by xMercy"
    local measured = sectionH[curTab]
    local target = measured and math.max(measured + TITLE_H + 24, sideH) or winH
    winH = math.floor(math.min(target, resY - 80) + 0.5)

    -- затемнение игры под меню (плавно вместе с открытием/закрытием); фоновый список рисуется ПОД окнами ImGui
    if imgui.GetBackgroundDrawList then
        imgui.GetBackgroundDrawList():AddRectFilled(vec(0, 0), vec(resX, resY), argbToU32(0x80000000, e))
    end

    imgui.SetNextWindowPos(vec(resX / 2, resY / 2 - 200), imgui.Cond.FirstUseEver, vec(0.5, 0.5))
    imgui.SetNextWindowSize(vec(W, math.floor(winH * k + 0.5)), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, e)
    imgui.Begin('Menu Template##menutemplate', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)

    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()
    local wh = imgui.GetWindowSize().y

    drawAurora(dl, wp, W, wh, now, e)
    dl:AddRect(vec(wp.x, wp.y), vec(wp.x + W, wp.y + wh), c('line', A.winLine), 12, nil, 1.0)
    safeDraw(drawTitle, dl, wp)

    imgui.SetCursorPos(vec(W - CLOSE_X, CLOSE_Y))
    local closeHit = imgui.InvisibleButton('##close', vec(CLOSE_SZ, CLOSE_SZ))
    local cpx = vec(wp.x + W - CLOSE_X, wp.y + CLOSE_Y)
    local ccol = imgui.IsItemHovered() and c('text') or c('dim')
    dl:AddLine(vec(cpx.x + 6, cpx.y + 6), vec(cpx.x + 14, cpx.y + 14), ccol, 1.6)
    dl:AddLine(vec(cpx.x + 14, cpx.y + 6), vec(cpx.x + 6, cpx.y + 14), ccol, 1.6)
    if closeHit then menu[0] = false end

    if wh >= TITLE_H + 60 then
        safeDraw(drawSidebar, dl, wp)

        imgui.SetCursorPos(vec(SIDE_W + 14, TITLE_H + 12))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, vec(0, 0))
        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, vec(0, 0))
        imgui.BeginChild('##content', vec(W - SIDE_W - PAD - 14, -12), false,
            imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
        cardW = imgui.GetContentRegionAvail().x
        colW = cardW - CARD_PAD * 2
        rowIndex, fade = 0, 1
        safeSection(drawSection)
        fade = 1
        sectionH[curTab] = math.ceil(imgui.GetCursorPos().y)
        imgui.EndChild()
        imgui.PopStyleVar()
        imgui.PopStyleVar()
    end

    imgui.End()
    imgui.PopStyleVar()
end)


-- отдельное окно редактирования цены (открывается кнопкой "$" во вкладке "Награда")
imgui.OnFrame(function() return PE.open[0] end, function(self)
    self.HideCursor = false
    fade = 1

    local first = PE.first
    PE.first = false
    runtimeUI.dimScreen(first)
    if first and imgui.SetNextWindowFocus then imgui.SetNextWindowFocus() end

    imgui.SetNextWindowPos(vec(resX / 2, resY / 2), imgui.Cond.Appearing, vec(0.5, 0.5))
    imgui.SetNextWindowSize(vec(PE.w, PE.h), imgui.Cond.Always)
    imgui.Begin('##priceeditwindow', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
    local ok, err = pcall(PE.draw, imgui.GetWindowDrawList(), imgui.GetWindowPos())
    imgui.End()
    if not ok then reportErr(err) end
end)


-- окно выбора дня (вкладка "Награда" -> "Выбрать день")
imgui.OnFrame(function() return PD.open[0] end, function(self)
    self.HideCursor = false
    fade = 1

    local first = PD.first
    PD.first = false
    runtimeUI.dimScreen(first)
    if first and imgui.SetNextWindowFocus then imgui.SetNextWindowFocus() end

    imgui.SetNextWindowPos(vec(resX / 2, resY / 2), imgui.Cond.Appearing, vec(0.5, 0.5))
    imgui.SetNextWindowSize(vec(PD.w, PD.h), imgui.Cond.Always)
    imgui.Begin('##daypickwindow', nil,
        imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoScrollbar
        + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse)
    local ok, err = pcall(PD.draw, imgui.GetWindowDrawList(), imgui.GetWindowPos())
    imgui.End()
    if not ok then reportErr(err) end
end)

------------------------------------------------------------- запуск --
local function cleanupAllTreasureVisuals()
    runtimeUI.visited = {}
    clearAllTreasureBlips()

    for idx, handles in pairs(markerState) do
        if handles.marker3d then runtimeUI.spcall('removeUser3dMarker', removeUser3dMarker, handles.marker3d) end
        markerState[idx] = nil
    end

    for _, entry in ipairs(bonusTreasures) do
        if entry.marker3d then runtimeUI.spcall('removeUser3dMarker', removeUser3dMarker, entry.marker3d) end
        if entry.checkpoint then runtimeUI.spcall('deleteCheckpoint', deleteCheckpoint, entry.checkpoint) end
        entry.blip, entry.marker3d, entry.checkpoint, entry.active = nil, nil, nil, false
    end
end

-- переключатель "Отрисовка меток и маркеров": при выключении убираем всё, что уже стоит
-- (раньше метки просто зависали на экране), при включении возвращаем бонусные клады, которые были включены.
-- Обычные клады вернутся сами — их ставит updateTreasureDistances.
function runtimeUI.onMarkersToggle(on)
    if on then
        for _, e in ipairs(bonusTreasures) do
            if e.wasActive then
                e.wasActive = nil
                placeBonusMarkers(e)
            end
        end
    else
        for _, e in ipairs(bonusTreasures) do e.wasActive = e.active or nil end
        runtimeUI.nearList = nil
        cleanupAllTreasureVisuals()
    end
end

function onScriptTerminate(scr)
    if scr == thisScript() then
        saveCfg()
        cleanupAllTreasureVisuals()
    end
end

-- ESC закрывает окно цены, а если его нет — главное меню. Само нажатие "съедаем" (consumeWindowMessage),
-- чтобы игра не открывала паузу; закрываем на отпускании клавиши (257). В паузе (isPauseMenuActive) не вмешиваемся.
function onWindowMessage(msg, wparam, lparam)
    if (msg == 256 or msg == 257) and wparam == 27 and (menu[0] or PE.open[0] or PD.open[0]) and not isPauseMenuActive() then
        consumeWindowMessage(true, false)
        if msg == 257 then
            if PE.open[0] then
                PE.open[0] = false
            elseif PD.open[0] then
                if PD.confirm then PD.confirm = nil else PD.open[0] = false end
            else
                menu[0] = false
            end
        end
    end
end

function sampev.onDisconnect()
    cleanupAllTreasureVisuals()
    resetRuntimeDetectionState() -- п.8
end

-- (пере)подключение к серверу: ганг-зоны и метки сбрасываются, а скрипт продолжает жить —
-- поэтому сами возвращаем сохранённые территории (с небольшой задержкой, пока игра прогрузится)
function sampev.onInitGame()
    dbg('onInitGame: серверная зона видна=%s, сохранённых территорий=%d, авто-возврат=%s',
        tostring(serverZoneVisible), #restoredZones, tostring(zcfg.autoRestore))
    cleanupAllTreasureVisuals()
    resetRuntimeDetectionState()
    if serverZoneVisible and serverZoneBounds and zcfg.autoRestore then
        runtimeUI.restoreServerZone(true)
    end
    serverZoneVisible, serverZoneId = false, nil
    refreshActiveTreasurePoints() -- набор видимых зон изменился (серверной уже нет)
    runtimeUI.replayAt = os.clock() + 2.0
end

function main()
    while not isSampAvailable() do wait(0) end
    sampRegisterChatCommand('kh', function() menu[0] = not menu[0] end)

    local prevMenu = menu[0]
    runtimeUI.lastRefreshAt = os.clock()
    while true do
        wait(0)
        if prevMenu and not menu[0] then saveCfg() end -- на всякий случай при закрытии меню
        prevMenu = menu[0]

        -- п.2: подстраховка от рассинхрона (новый клад появился в уже проверенном месте,
        -- зона эвикнулась по лимиту и т.п.) — периодически пересобираем с нуля
        -- основной пересбор вызывается из мест, где меняются зоны/точки (создание/уничтожение/вставка/удаление
        -- зоны, переподключение, выкопанный клад); здесь — только страховка раз в CFG.fullResyncInterval
        if os.clock() - (runtimeUI.lastRefreshAt or 0) >= CFG.fullResyncInterval then
            refreshActiveTreasurePoints()
        end

        if runtimeUI.replayAt and os.clock() >= runtimeUI.replayAt then
            runtimeUI.replayAt = nil
            runtimeUI.spcall('replayZones', runtimeUI.replayZones)
        end

        local now = os.clock()
        if now - lastDistCheck >= CFG.distCheckInterval then
            lastDistCheck = now
            -- если набор зон/точек изменился мимо явных вызовов — подхватываем в течение 0.5 с (дёшево: сравнение строк)
            if runtimeUI.zoneSig() ~= runtimeUI.lastSig then refreshActiveTreasurePoints() end
            -- п.6: раньше при пустом activeTreasurePoints функция не вызывалась вовсе —
            -- из-за этого "всегда показывать ближайшие" не работал, если игрок не стоял
            -- в найденной/восстановленной территории. Теперь запускаем ещё и при showAllNearby.
            -- п.8: раньше при выключении showAllNearby без активной зоны эта функция вообще
            -- переставала вызываться — метки, выставленные ТОЛЬКО благодаря showAllNearby
            -- (вне зоны клада), оставались висеть на карте навсегда. Теперь запускаем ещё и
            -- когда есть хоть одна отслеживаемая метка — чтобы чистка всегда могла отработать.
            if #activeTreasurePoints > 0 or runtimeUI.showAllNearby or next(markerState) ~= nil or runtimeUI.anyBonusActive() then
                updateTreasureDistances()
            else
                runtimeUI.nearList = nil -- проверять нечего (нет активных точек) — запасное отображение не рисуем
            end

            -- зона металлоискателя: были определены, но нигде не вызывались — чинил вместе
            -- с этим ответом. Дистанцию очистки достаточно сверять в этом же троттлинге.
            checkDetectorRenderDistance()
        end

        -- а вот это должно отрабатывать каждый кадр, а не раз в CFG.distCheckInterval:
        -- запись следа (сама функция внутри уже гасит частоту по DET.trailStep)
        -- и сама отрисовка (линия/круг должны быть видны непрерывно, без мерцания)
        recordDetectorTrailPoint()
        drawDetectorVisuals()
        runtimeUI.drawNearFallback()
    end
end
