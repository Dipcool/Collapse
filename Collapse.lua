script_name('COLLAPSE')
script_author('xMercy')
script_version('1.0')

-- ============================================================================
--  COLLAPSE  |  mimgui  |  MoonLoader
--  Файл в кодировке Windows-1251.
--  Открыть/закрыть меню: INSERT (меняется в Settings -> Interface) или /collapse
--  Язык (English / Русский): выпадающий список с флагами в правом верхнем углу окна, хранится в конфиге.
-- ============================================================================

local imgui    = require 'mimgui'
local encoding = require 'encoding'
local vkeys    = require 'vkeys'
local ffi      = require 'ffi'
local inicfg   = require 'inicfg'
local bit      = require 'bit'
local okMem, memory = pcall(require, 'memory')               -- может отсутствовать: тогда функции с памятью выдают ошибку
pcall(require, 'sampfuncs')                                  -- константы GAMESTATE_* (если библиотека установлена)
local okEv, sampev  = pcall(require, 'lib.samp.events')      -- может отсутствовать: тогда хуки ивентов не ставятся

-- ----------------------------------------------------------------------------
--  Группы переменных верхнего уровня.
--  У Lua лимит - 200 локальных переменных на файл (и 60 upvalue на функцию), поэтому связанные
--  переменные и константы собраны в таблицы: LAY.W вместо W, gfx.galpha вместо galpha и т.д.
-- ----------------------------------------------------------------------------
local LAY   = {}  -- размеры окна и сетка контента
local me    = {}  -- игрок: ник и ID на сервере
local gfx   = {}  -- состояние отрисовки: анимации, ripple, уведомления, FPS, удержание кнопок
local i18n  = {}  -- языки и переводы
local FNT   = {}  -- шрифты: наборы, список, диапазоны, кэш
local CMD   = {}  -- команда активации меню
local ctl   = {}  -- значения виджетов и данные загруженного конфига
local CFG   = {}  -- конфиги: функции, имя, список, состояние автосохранения
local SRCH  = {}  -- поиск и сбор списка функций
local LUI   = {}  -- выбор языка: флаги, размеры, периметр
local SOFT  = {}  -- вкладка Software: список программ и Блокнот
local CONST = {}  -- константы: цвета и размеры уведомлений, подсказок, кнопок, разрешение экрана

ctl.main = {}   -- вкладка Main: функции из arztools (см. блок "Main tab")
ctl.far  = {}   -- Дальний чат: история, правила, оверлей

encoding.default = 'CP1251'
local u8raw = encoding.UTF8
-- u8(s) вызывается сотни раз за кадр с одними и теми же подписями: результат запоминается (короткие строки, до 4000 штук)
local u8cache, u8n = {}, 0
local u8 = setmetatable({}, {
    __call = function(_, s)
        if type(s) ~= 'string' or #s > 200 then return u8raw(s) end
        local v = u8cache[s]
        if v == nil then
            v = u8raw(s)
            if u8n >= 4000 then u8cache, u8n = {}, 0 end
            u8cache[s], u8n = v, u8n + 1
        end
        return v
    end,
    __index = function(_, k)                                  -- u8:decode(...) и остальные методы идут в исходную библиотеку
        local f = u8raw[k]
        if type(f) == 'function' then return function(_, ...) return f(u8raw, ...) end end
        return f
    end,
})

-- ----------------------------------------------------------------------------
--  Размеры окна
-- ----------------------------------------------------------------------------
LAY.W, LAY.H, LAY.SIDE = 860, 590, 190
-- сетка области контента: две колонки панелей
LAY.CW   = LAY.W - LAY.SIDE - 24 - 18          -- ширина области контента
LAY.COLW = math.floor((LAY.CW - 14) / 2)   -- ширина одной колонки
LAY.CH   = LAY.H - 98 - 16                 -- высота области контента
LAY.TAB_Y, LAY.TAB_H = 130, 44     -- вкладки сдвинуты вниз: под логотипом ряд иконок (SIDE.BTN)

-- ----------------------------------------------------------------------------
--  Палитра
-- ----------------------------------------------------------------------------
local pal = {
    bg     = {0.051, 0.055, 0.071},
    side   = {0.039, 0.043, 0.055},
    panel  = {0.071, 0.075, 0.094},
    field  = {0.094, 0.102, 0.129},
    fieldH = {0.129, 0.141, 0.180},
    track  = {0.137, 0.149, 0.188},
    border = {0.118, 0.129, 0.165},
    text   = {0.90, 0.92, 0.96},
    dim    = {0.50, 0.54, 0.62},
    white  = {1, 1, 1},
}

-- ----------------------------------------------------------------------------
--  Темы: пресеты цветов меню (Settings -> Interface -> Preset)
--  Шесть базовых цветов взяты из arztools (theme.list, формат ARGB). Пресет задаёт основной цвет меню
--  (кнопки, переключатели, полоски, подсветка) и оттенок тёмных поверхностей: THEME.set(i) подставляет
--  цвета прямо в таблицу pal (на неё ссылается вся отрисовка), поэтому меняется всё меню сразу.
--  Номер пресета хранится в конфиге: секция [interface], ключ theme.
-- ----------------------------------------------------------------------------
local THEME = {
    LIST    = {4294918208, 4294947584, 4281859840, 4278249215, 4278206719, 4288807167},
    NAMES   = {'Red', 'Orange', 'Green', 'Cyan', 'Blue', 'Purple'},
    DEFAULT = 4,                      -- синий (как выглядело меню до появления пресетов)
    cur     = 4,                      -- номер выбранного пресета
    main    = {0.27, 0.55, 1.00},     -- основной цвет выбранного пресета
    onMain  = {1, 1, 1},              -- цвет текста на заливке основным цветом (белый или тёмный)
    swatch  = {},                     -- цвета кружков выбора пресета: swatch[i] = {r, g, b}
    dirty   = true,                   -- цвета стиля imgui надо поставить заново (см. THEME.applyStyle)
}

-- ARGB -> оттенок (0..360) и насыщенность (0..1)
function THEME.hueSat(argb)
    local r = bit.band(bit.rshift(argb, 16), 255) / 255
    local g = bit.band(bit.rshift(argb, 8), 255) / 255
    local b = bit.band(argb, 255) / 255
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d, h = mx - mn, 0
    if d > 0 then
        if mx == r then h = ((g - b) / d) % 6
        elseif mx == g then h = (b - r) / d + 2
        else h = (r - g) / d + 4 end
        h = h * 60
    end
    return h, (mx > 0) and d / mx or 0
end

-- HSV -> {r, g, b} (0..1)
function THEME.fromHsv(h, sat, v)
    local c = v * sat
    local hp = (h % 360) / 60
    local x = c * (1 - math.abs(hp % 2 - 1))
    local r, g, b
    if hp < 1 then r, g, b = c, x, 0
    elseif hp < 2 then r, g, b = x, c, 0
    elseif hp < 3 then r, g, b = 0, c, x
    elseif hp < 4 then r, g, b = 0, x, c
    elseif hp < 5 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    local m = v - c
    return {r + m, g + m, b + m}
end

-- основной цвет пресета: насыщенный, как в arztools (раньше был приглушён, из-за этого тема выглядела бледнее)
function THEME.mainOf(i)
    local h, sat = THEME.hueSat(THEME.LIST[i])
    return THEME.fromHsv(h, sat, 1.0)                    -- цвет пресета как есть (V = 1)
end

for i = 1, #THEME.LIST do THEME.swatch[i] = THEME.mainOf(i) end

-- яркость поверхностей (значение V в HSV) - как у исходной тёмной палитры меню
THEME.SURF_SAT = 0.5                 -- насыщенность тёмных поверхностей (больше - ярче оттенок фона)
THEME.SURFACE = {bg = 0.071, side = 0.055, panel = 0.094, field = 0.129, fieldH = 0.180, track = 0.188, border = 0.165}

-- включает пресет i (1..#LIST); неверный номер - пресет по умолчанию. Только меняет цвета: imgui не трогает,
-- поэтому можно вызывать и до создания окна (при загрузке конфига).
function THEME.set(i)
    i = math.floor(tonumber(i) or THEME.DEFAULT)
    if i < 1 or i > #THEME.LIST then i = THEME.DEFAULT end
    THEME.cur = i
    local h = THEME.hueSat(THEME.LIST[i])
    local m = THEME.swatch[i]
    THEME.main[1], THEME.main[2], THEME.main[3] = m[1], m[2], m[3]
    for k, v in pairs(THEME.SURFACE) do
        local c = THEME.fromHsv(h, THEME.SURF_SAT, math.min(v * 1.2, 1))
        pal[k][1], pal[k][2], pal[k][3] = c[1], c[2], c[3]
    end
    local t = THEME.fromHsv(h, 0.10, 0.96)
    pal.text[1], pal.text[2], pal.text[3] = t[1], t[2], t[3]
    local d = THEME.fromHsv(h, 0.30, 0.66)
    pal.dim[1], pal.dim[2], pal.dim[3] = d[1], d[2], d[3]
    local lum = 0.299 * m[1] + 0.587 * m[2] + 0.114 * m[3]       -- на светлой заливке текст тёмный
    if lum > 0.62 then THEME.onMain[1], THEME.onMain[2], THEME.onMain[3] = 0.05, 0.055, 0.07
    else THEME.onMain[1], THEME.onMain[2], THEME.onMain[3] = 1, 1, 1 end
    THEME.dirty = true
end

-- цвета стиля imgui из текущей палитры (при старте и после смены пресета; вызывать только внутри кадра/OnInitialize)
function THEME.applyStyle()
    local c = imgui.GetStyle().Colors
    local function v4(t, a) return imgui.ImVec4(t[1], t[2], t[3], a or 1) end
    c[imgui.Col.Text]           = v4(pal.text)
    c[imgui.Col.WindowBg]       = v4(pal.bg)
    c[imgui.Col.ChildBg]        = imgui.ImVec4(0, 0, 0, 0)
    c[imgui.Col.PopupBg]        = v4(pal.field)
    c[imgui.Col.Border]         = v4(pal.border)
    c[imgui.Col.FrameBg]        = v4(pal.field)
    c[imgui.Col.FrameBgHovered] = v4(pal.fieldH)
    c[imgui.Col.FrameBgActive]  = v4(pal.fieldH)
    c[imgui.Col.TextDisabled]   = v4(pal.dim, 0.8)
    c[imgui.Col.ScrollbarBg]    = imgui.ImVec4(0, 0, 0, 0)
    c[imgui.Col.ScrollbarGrab]  = v4(pal.track)
    c[imgui.Col.ScrollbarGrabHovered] = v4(pal.fieldH)
    c[imgui.Col.ScrollbarGrabActive]  = v4(pal.dim, 0.6)
    THEME.dirty = false
end

THEME.set(THEME.DEFAULT)

-- ----------------------------------------------------------------------------
--  Состояние
-- ----------------------------------------------------------------------------
local ui = {
    open      = nil,           -- imgui.new.bool (создаётся в main)
    alpha     = 0,
    wasOpen   = false,
    tab       = 1,
    sub       = {1, 1, 1, 1},
    contentT  = 1,
    offY      = 0,
    cpos      = nil,
    animSpeed = nil,
    showFps   = nil,
    lang      = nil,           -- imgui.new.int: индекс языка (0 = English, 1 = Русский)
    langOpen  = false,         -- раскрыт ли выпадающий список языков
    langT     = 0,             -- анимация списка (0..1)
    cmd       = nil,           -- imgui char[32]: поле ввода команды активации
    fieldActive = false,       -- true, пока в кадре активно текстовое поле настроек (не переключать меню клавишей)
    cfg       = 1,
    cfgInput  = nil,
    runD      = 0,             -- позиция бегущей линии по периметру
    search    = nil,           -- буфер строки поиска (imgui.new.char)
    query     = '',            -- текущий запрос (cp1251, нижний регистр)
    results   = nil,
    hl        = nil,           -- подсветка найденной функции
    focusSearch = false,
    searchActive = false,
    menuKeyBlock = false,
    popLabel = nil,            -- функция, у которой открыто окно доп. настроек (шестерёнка)
    popOpen = false, popReq = nil, popAx = 0, popAy = 0, popH = {},
    gearHit = false, popBusy = false,
}

local binds = {
    menu   = {key = 0x2D},     -- INSERT
    toggle = {key = 0},
    hold   = {key = 0},
}
local listening = nil          -- ссылка на bind, который сейчас назначается
me.nick = 'Player'
me.id = nil              -- ID игрока на сервере (nil, пока не подключены)

-- Ник и ID нужны только карточке игрока в меню, поэтому читаем их по требованию:
-- при запуске скрипта и при каждом открытии меню (а не опрашиваем в бесконечном цикле).
local function refreshNick()
    local ok, name, id = pcall(function()
        local res, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if not res then return nil end
        return sampGetPlayerNickname(pid), pid
    end)
    if ok and name and #name > 0 then me.nick, me.id = name, id else me.id = nil end
end

local tabs = {
    {name = 'Main',     icon = 'home', subs = {'Misc', 'Character', 'For car'}},
    {name = 'Tools',    icon = 'bolt', subs = {'Character', 'Server', 'Script', 'Debug', 'Console', 'Inspector'}},
    {name = 'Software', icon = 'apps', subs = {'Programs'}},
    {name = 'Settings', icon = 'gear', subs = {'Interface', 'Config', 'Updates'}},
}

local fonts = {}
-- Шрифты Windows на выбор (Settings -> Interface -> Fonts). Заполняются в OnInitialize:
-- FONTSETS[i] = {name, regular, bold, title, small, toast, toastb}, FONT_NAMES[i] = name.
FNT.FONTSETS, FNT.FONT_NAMES = {}, {}
FNT.DEFAULT_FONT = 'Comic Sans MS'   -- шрифт по умолчанию и для интерфейса, и для уведомлений
FNT.FONT_RANGES = nil   -- диапазоны символов (латиница + кириллица + знаки препинания); хранить, пока строится атлас
gfx.galpha = 1
gfx.anim, gfx.ripples, gfx.toasts = {}, {}, {}
gfx.fpsHist = {}
gfx.hist, gfx.histUnread = {}, 0     -- история (колокольчик): только лог обновлений и критические ошибки, см. SIDE.addHist
for i = 1, 64 do gfx.fpsHist[i] = 0 end

-- ----------------------------------------------------------------------------
--  Локализация (English / Русский)
--  Весь код использует английские названия как идентификаторы (id виджетов,
--  ключи конфига, подсказки, SETTINGS, поиск). Перевод применяется только в момент
--  отрисовки: tr('Text') вернёт перевод для выбранного языка, а если перевода нет -
--  сам текст. Язык выбирается в выпадающем списке в правом верхнем углу окна, меняется
--  сразу, без перезагрузки скрипта, и сохраняется в конфиг
--  (секция [interface], ключ language).
--  Добавить язык: допишите его в LANGS, создайте таблицу TR.<id> = {['English'] = 'Перевод'}
--  и функцию флага FLAGS.<id> (см. раздел "Переключатель языка").
--  Новый текст в меню: напишите его по-английски и добавьте строку в TR.ru.
-- ----------------------------------------------------------------------------
i18n.LANGS = {
    {id = 'en', name = 'English'},
    {id = 'ru', name = 'Русский'},
}
i18n.curLang = 'en'

i18n.TR = {}
i18n.TR.ru = {
    -- вкладки, подвкладки, панели
    ['Misc'] = 'Разное', ['Settings'] = 'Настройки',
    ['For car'] = 'Для авто',
    ['Vehicle'] = 'Транспорт',
    ['Utility'] = 'Утилиты', ['Chat'] = 'Чат',
    ['Interface'] = 'Интерфейс', ['Config'] = 'Конфиг',
    ['Actions'] = 'Действия', ['Filters'] = 'Фильтры',
    ['Theme'] = 'Тема', ['Menu'] = 'Меню', ['Configs'] = 'Конфиги',

    -- Settings -> Interface
    ['Preset'] = 'Пресет', ['Animation speed'] = 'Скорость анимации',
    ['Software'] = 'Софт', ['Programs'] = 'Программы', ['Notepad'] = 'Блокнот', ['Back'] = 'Назад',
    ['Your notes'] = 'Ваши заметки', ['and reminders'] = 'и напоминания',
    ['Type your notes here...'] = 'Пишите заметки здесь...', ['Saved automatically'] = 'Сохраняется автоматически',
    ['Copy'] = 'Копировать', ['Clear'] = 'Очистить', ['Undo'] = 'Вернуть', ['Nothing to copy'] = 'Нечего копировать',
    ['Simple notepad. Everything you type is saved automatically.'] = 'Простой блокнот. Всё, что вы напишете, сохраняется автоматически.',
    ['Color preset of the menu: sets the main color and the tint of the surfaces. Applies instantly and is saved to the config.'] =
        'Цветовой пресет меню: задаёт основной цвет и оттенок поверхностей. Меняется сразу и сохраняется в конфиг.',
    ['FPS in sidebar'] = 'FPS в боковой панели', ['Menu key'] = 'Клавиша меню', ['Menu command'] = 'Команда меню',
    ['Language'] = 'Язык',
    ['This is a test notification'] = 'Это тестовое уведомление',
    ['This is a success notification'] = 'Это уведомление об успехе',
    ['This is an error notification'] = 'Это уведомление об ошибке',
    ['This is a long test notification. It wraps onto several lines, so you can check how the icon and the text look together.'] =
        'Это длинное тестовое уведомление. Оно переносится на несколько строк, чтобы можно было проверить, как выглядят иконка и текст вместе.',
    ['Fonts'] = 'Шрифты', ['Interface font'] = 'Шрифт интерфейса', ['Notification font'] = 'Шрифт уведомлений',
    ['Show info'] = 'Показать обычное', ['Show success'] = 'Показать успех',
    ['Show error'] = 'Показать ошибку', ['Show long text'] = 'Показать длинный текст',

    -- Settings -> Config
    ['New config'] = 'Новый конфиг', ['Saved configs'] = 'Сохранённые конфиги',
    ['active'] = 'активный',
    ['Create'] = 'Создать', ['Delete'] = 'Удалить',

    -- шапка, поиск, сайдбар
    ['NAVIGATION'] = 'НАВИГАЦИЯ', ['Online'] = 'Онлайн', ['None'] = 'Нет',
    ['Search'] = 'Поиск', ['Search results'] = 'Результаты поиска',
    ['Search functions...'] = 'Поиск функций...',
    ['%d found'] = 'Найдено: %d',
    ['Nothing found. Try another word.'] = 'Ничего не найдено. Попробуйте другое слово.',

    -- подсказки
    ['Speed of all menu animations.'] = 'Скорость всех анимаций меню.',
    ['Show FPS in the player card.'] = 'Показывать FPS в карточке игрока.',
    ['Interface language. Applies instantly and is saved to the config.'] = 'Язык интерфейса. Меняется сразу и сохраняется в конфиг.',
    ['Fonts for notifications and for all script text.'] = 'Шрифты уведомлений и всего текста скрипта.',
    ['Add a config to the list with default settings. It will not become active.'] = 'Добавить конфиг в список со стандартными настройками. Он не станет активным.',
    ['Hold the button for 2 seconds.'] = 'Удерживайте кнопку 2 секунды.',
    ['Additional function settings.'] = 'Дополнительные настройки функции.',

    -- уведомления
    ['COLLAPSE loaded. Press %s'] = 'COLLAPSE загружен. Нажмите %s',
    ['Error'] = 'Ошибка',
    ['Invalid command: use latin letters, digits and _'] = 'Неверная команда: только латинские буквы, цифры и _',
    ['Command changed: /%s'] = 'Команда изменена: /%s',
    ['Config saved: %s'] = 'Конфиг сохранён: %s',
    ['Config save failed'] = 'Не удалось сохранить конфиг',
    ['Config loaded: %s'] = 'Конфиг загружен: %s',
    ['Config not found: %s'] = 'Конфиг не найден: %s',
    ['Config deleted: %s'] = 'Конфиг удалён: %s',
    ['Config deleted: %s. Loaded: %s'] = 'Конфиг удалён: %s. Загружен: %s',
    ['All configs deleted. Created new: default'] = 'Все конфиги удалены. Создан новый: default',
    ['Enter config name'] = 'Введите название конфига',
    ['Config already exists: %s'] = 'Конфиг уже существует: %s',
    ['Config created: %s'] = 'Конфиг создан: %s',

    -- окна доп. настроек (шестерёнка): названия функций
    ['Enable module'] = 'Включить модуль', ['Speed'] = 'Скорость', ['Show overlay'] = 'Показывать оверлей',
    ['Glow'] = 'Свечение', ['Time override'] = 'Подмена времени', ['Vehicle boost'] = 'Ускорение транспорта',
    ['Auto sprint'] = 'Авто-спринт', ['Auto reconnect'] = 'Авто-реконнект',
    -- заголовки окон
    ['Module settings'] = 'Настройки модуля', ['Speed settings'] = 'Настройки скорости',
    ['Overlay settings'] = 'Настройки оверлея', ['Glow settings'] = 'Настройки свечения',
    ['Time settings'] = 'Настройки времени', ['Boost settings'] = 'Настройки ускорения',
    ['Sprint settings'] = 'Настройки спринта', ['Reconnect settings'] = 'Настройки реконнекта',
    -- элементы окон
    ['Auto start'] = 'Автозапуск', ['Update rate'] = 'Частота обновления', ['Priority'] = 'Приоритет',
    ['Quick toggle'] = 'Быстрое включение', ['Ramp up smoothly'] = 'Плавный разгон', ['Ramp time'] = 'Время разгона',
    ['Lock position'] = 'Закрепить позицию', ['Overlay scale'] = 'Масштаб оверлея', ['Anchor'] = 'Привязка',
    ['Background tint'] = 'Цвет фона', ['Glow intensity'] = 'Яркость свечения', ['Pulse animation'] = 'Пульсация',
    ['Blend mode'] = 'Режим наложения', ['Inner color'] = 'Внутренний цвет', ['Time flow speed'] = 'Скорость течения времени',
    ['Freeze time'] = 'Заморозить время', ['Boost duration'] = 'Длительность ускорения', ['Boost cooldown'] = 'Перезарядка ускорения',
    ['Only on ground'] = 'Только на земле', ['Boost key'] = 'Клавиша ускорения', ['Only forward'] = 'Только вперёд',
    ['Stamina limit'] = 'Предел выносливости', ['Max attempts'] = 'Макс. попыток', ['Notify on reconnect'] = 'Уведомлять о реконнекте',
    -- варианты списков
    ['Low'] = 'Низкий', ['Normal'] = 'Обычный', ['High'] = 'Высокий',
    ['Top left'] = 'Сверху слева', ['Top right'] = 'Сверху справа',
    ['Bottom left'] = 'Снизу слева', ['Bottom right'] = 'Снизу справа',
    ['Additive'] = 'Сложение', ['Alpha'] = 'Альфа', ['Multiply'] = 'Умножение',
    -- единицы измерения в форматах слайдеров
    ['%d Hz'] = '%d Гц', ['%d ms'] = '%d мс', ['%d s'] = '%d с',

    -- Tools: вкладка, подвкладки, панели
    ['Tools'] = 'Инструменты', ['Character'] = 'Персонаж', ['Server'] = 'Сервер', ['Script'] = 'Скрипт',
    ['Teleport'] = 'Телепорт', ['Repair'] = 'Ремонт', ['Connection'] = 'Соединение',
    ['Chat and dialogs'] = 'Чат и диалоги', ['Control'] = 'Управление', ['Script files'] = 'Файлы скрипта',
    ['Danger zone'] = 'Опасная зона',
    -- Tools: кнопки
    ['Teleport to marker'] = 'Телепорт по метке', ['Teleport to checkpoint'] = 'Телепорт по чекпоинту',
    ['Slap up'] = 'Слап вверх', ['Slap down'] = 'Слап вниз', ['Unfreeze'] = 'Разморозить',
    ['Respawn'] = 'Заспавниться', ['Die'] = 'Умереть', ['Fix wheels'] = 'Починить колёса', ['Fix car'] = 'Починить машину',
    ['Connect'] = 'Подключиться', ['Disconnect'] = 'Отключиться', ['Close connection'] = 'Закрыть соединение',
    ['Clear chat'] = 'Очистить чат', ['Hide dialog'] = 'Скрыть диалог', ['Show dialog'] = 'Показать диалог',
    ['Reload script'] = 'Перезагрузить скрипт', ['Unload script'] = 'Выгрузить скрипт',
    ['Hide script files'] = 'Скрыть файлы скрипта', ['Show script files'] = 'Показать файлы скрипта',
    ['Delete script'] = 'Удалить скрипт', ['Crash game'] = 'Крашнуть игру',
    -- Tools: подсказки
    -- Misc -> Debug / Console: подвкладки, панели, строки
    ['Debug'] = 'Отладка', ['Console'] = 'Консоль',
    ['Info'] = 'Данные', ['Clipboard'] = 'Буфер обмена', ['Overlay'] = 'Оверлей', ['Runtime'] = 'Выполнение',
    ['Log'] = 'Журнал', ['Lua console'] = 'Консоль Lua',
    ['Position'] = 'Позиция', ['Heading'] = 'Курс', ['Interior'] = 'Интерьер', ['Player ID'] = 'ID игрока',
    ['Ping'] = 'Пинг', ['Lua memory'] = 'Память Lua', ['Uptime'] = 'Время работы', ['On foot'] = 'Пешком',
    ['ms'] = 'мс', ['MB'] = 'МБ',
    ['Copy position'] = 'Копировать позицию', ['Copy position and heading'] = 'Копировать позицию и курс',
    ['Copy as Lua code'] = 'Копировать как код Lua', ['Collect garbage'] = 'Собрать мусор', ['Skin ID'] = 'ID скина', ['Last cleanup'] = 'Последняя очистка',
    ['Run'] = 'Выполнить', ['Copy log'] = 'Копировать лог', ['Clear log'] = 'Очистить лог',
    ['Debug overlay'] = 'Отладочный оверлей', ['Show performance'] = 'Показывать производительность',
    ['Show position'] = 'Показывать позицию', ['Show vehicle'] = 'Показывать транспорт',
    ['Text size'] = 'Размер текста',
    ['Edit overlay position'] = 'Изменить положение оверлея', ['Click LMB to place the overlay'] = 'Нажмите ЛКМ, чтобы разместить оверлей',
    ['Code (Enter to run)'] = 'Код (Enter - выполнить)',
    ['Log is empty. Notifications and console output appear here.'] = 'Журнал пуст. Здесь появляются уведомления и вывод консоли.',
    -- Misc -> Debug / Console: подсказки
    ['Copies the x, y, z coordinates of your character to the clipboard.'] = 'Копирует координаты x, y, z вашего персонажа в буфер обмена.',
    ['Copies x, y, z and the heading angle to the clipboard.'] = 'Копирует x, y, z и угол курса в буфер обмена.',
    ['Copies a ready setCharCoordinates(PLAYER_PED, x, y, z) call to the clipboard.'] = 'Копирует готовый вызов setCharCoordinates(PLAYER_PED, x, y, z) в буфер обмена.',
    ['Shows a small panel on the screen with FPS, coordinates and vehicle info. Saved to the config.'] = 'Показывает на экране небольшую панель с FPS, координатами и данными о транспорте. Сохраняется в конфиг.',
    ['Size of the text in the debug overlay. The panel grows with it.'] = 'Размер текста в отладочном оверлее. Панель увеличивается вместе с ним.',
    ['Runs a full Lua garbage collection of this script (twice) and shows how much memory was freed. Does not affect the game memory.'] = 'Дважды запускает полную сборку мусора Lua этого скрипта и показывает, сколько памяти освободилось. На память игры не влияет.',
    -- Misc -> Inspector
    ['Inspector'] = 'Инспектор', ['Dialogs'] = 'Диалоги', ['Chat colors'] = 'Цвета чата', ['TextDraws'] = 'Текстдравы',
    ['Click history'] = 'История нажатий',
    ['Dialog ID in title'] = 'ID диалога в заголовке', ['Log dialogs'] = 'Логировать диалоги',
    ['Last dialog ID'] = 'ID посл. диалога', ['Dialog style'] = 'Стиль диалога', ['Dialog title'] = 'Заголовок диалога',
    ['Copy dialog ID'] = 'Копировать ID диалога',
    ['Color in chat messages'] = 'Цвет в сообщениях чата', ['Color format'] = 'Формат цвета',
    ['Number'] = 'Число', ['Hex RRGGBB'] = 'Hex RRGGBB', ['Number and hex'] = 'Число и hex',
    ['Last chat color'] = 'Посл. цвет чата', ['Copy last color'] = 'Копировать посл. цвет',
    ['Show textdraw IDs'] = 'Показывать ID текстдравов', ['Show textdraw text'] = 'Показывать текст текстдравов',
    ['Track textdraw clicks'] = 'Отслеживать нажатия на текстдравы', ['Textdraws on screen'] = 'Текстдравов на экране',
    ['Last clicked ID'] = 'Посл. нажатый ID', ['Copy clicked ID'] = 'Копировать нажатый ID',
    ['No clicks yet.'] = 'Нажатий пока нет.', ['No data yet'] = 'Данных пока нет',
    ['Adds the dialog ID to the dialog title, for example [ID 25] Bank.'] = 'Добавляет ID диалога в его заголовок, например [ID 25] Банк.',
    ['Writes every shown dialog and your answer to it to the log (Tools -> Console). Passwords are hidden.'] = 'Пишет в журнал (Tools -> Console) каждый показанный диалог и ваш ответ на него. Пароли скрываются.',
    ['Adds the message color to the end of every chat message, for example | -12346237.'] = 'Добавляет цвет сообщения в конец каждой строки чата, например | -12346237.',
    ['How the chat message color is written: signed number, hex RRGGBB or both.'] = 'Как записывается цвет сообщения: число со знаком, hex RRGGBB или оба.',
    ['Draws the ID of every textdraw on the screen at its position.'] = 'Рисует ID каждого текстдрава на экране в его позиции.',
    ['Adds the text of the textdraw to its ID label.'] = 'Добавляет текст текстдрава к его метке с ID.',
    ['Remembers the IDs of the textdraws you click, shows them on the screen and writes them to the log.'] = 'Запоминает ID текстдравов, на которые вы нажимаете, показывает их на экране и пишет в журнал.',
    ['Textdraw clicks'] = 'Нажатия на текстдравы',
    ['Textdraw click: ID %d'] = 'Нажатие на текстдрав: ID %d',
    ['%.2f MB freed'] = 'освобождено %.2f МБ',
    ['Event and animation log'] = 'Лог ивентов и анимаций', ['Log events'] = 'Логировать ивенты', ['Log arguments'] = 'Логировать аргументы', ['Log animations'] = 'Логировать анимации',
    ['Frequent after'] = 'Частые от', ['%d per 10 s'] = '%d за 10 с', ['CEF logger'] = 'CEF-логгер', ['Records the CEF events of the server (<) and the events your client sends to the server (>) in the CEF list. Only works while it is on.'] = 'Записывает CEF-события сервера (<) и события, которые клиент отправляет серверу (>), в список CEF. Работает только пока включен.',
    ['All CEF'] = 'Все', ['From server'] = 'От сервера', ['To server'] = 'От вас',
    ['Pause list'] = 'Заморозить список', ['Pause'] = 'Пауза', ['Resume'] = 'Продолжить',
    ['Freezes the list so that new records do not move the lines. The records are still collected and appear after you turn the pause off. Not saved.'] = 'Список замирает, и новые записи не сдвигают строки. Записи продолжают собираться и появятся после выключения паузы. Не сохраняется.',
    ['Main switch of the logging. When it is off nothing is recorded (events, animations and CEF), whatever the switches below say.'] = 'Главный переключатель записи. Когда он выключен, ничего не записывается (события, анимации и CEF), независимо от переключателей ниже.',
    ['Log view'] = 'Показывать',
    ['Events'] = 'Ивенты', ['Frequent events'] = 'Частые ивенты', ['Animations'] = 'Анимации',
    ['Open full log'] = 'Открыть весь лог', ['Copy list'] = 'Копировать список', ['%d entries'] = '%d записей',
    ['Clear lists'] = 'Очистить списки', ['Nothing logged yet.'] = 'Пока ничего не записано.', ['Lists cleared'] = 'Списки очищены',
    ['Adds the arguments of the event to its log line: name(arg=value, ...). Long values are shortened.'] = 'Добавляет в строку лога аргументы ивента: название(аргумент=значение, ...). Длинные значения сокращаются.',
    ['Records the RPC events of samp.events into a list. Frequent events are only counted, not written line by line, so memory does not grow.'] = 'Записывает RPC-ивенты samp.events в список. Частые ивенты только считаются, а не пишутся построчно, поэтому память не растёт.',
    ['Records every change of your animation and the animations applied by the server.'] = 'Записывает каждую смену анимации персонажа и анимации, которые применил сервер.',
    ['An event that happens this many times within 10 seconds goes to the "Frequent events" list: only a counter is kept for it.'] = 'Ивент, который происходит столько раз за 10 секунд, уходит в список "Частые ивенты": для него хранится только счётчик.',
    ['Which list is shown on the right.'] = 'Какой список показывать справа.',
    ['Show last animation'] = 'Показывать последнюю анимацию', ['Show server IP'] = 'Показывать IP сервера', ['Show last event'] = 'Показывать последний ивент',
    ['Shows the last animation of your character: name, file and ID. Also shows the animation applied by the server.'] = 'Показывает последнюю анимацию персонажа: название, файл и ID. Также показывает анимацию, которую применил сервер.',
    ['Shows the last incoming (<, from the server) and the last outgoing (>, to the server) RPC event of samp.events. While enabled, the script listens to all RPC events. Sync packets are not tracked.'] = 'Показывает последний входящий (<, от сервера) и последний исходящий (>, на сервер) RPC-ивент samp.events. Пока включено, скрипт слушает все RPC-ивенты. Sync-пакеты не отслеживаются.',
    -- Misc -> Debug / Console: уведомления
    ['Copied to the clipboard'] = 'Скопировано в буфер обмена',
    ['Position is not available'] = 'Позиция недоступна',
    ['Garbage collected: %.2f MB freed'] = 'Мусор собран: освобождено %.2f МБ',
    -- Tools: уведомления
    ['SA-MP is not available'] = 'SA-MP недоступен',
    ['Action failed: %s'] = 'Действие не выполнено: %s',
    ['Chat cleared'] = 'Чат очищен', ['Connecting...'] = 'Подключение...', ['Disconnected'] = 'Отключено',
    ['Connection closed'] = 'Соединение закрыто',
    ['Set a marker on the map first'] = 'Сначала поставьте метку на карте',
    ['No checkpoint to teleport to'] = 'Нет чекпоинта для телепорта',
    ['Teleported to the marker'] = 'Телепорт на метку выполнен',
    ['Teleported to the checkpoint'] = 'Телепорт на чекпоинт выполнен',
    ['You are not in a vehicle!'] = 'Вы не в машине!',
    ['Wheel repair does not work on bikes!'] = 'На байке починка колёс не работает!',
    ['Wheels repaired'] = 'Колёса починены', ['Vehicle repaired'] = 'Машина починена',
    ['Dialog hidden'] = 'Диалог скрыт', ['Dialog shown'] = 'Диалог показан',
    ['Script file hidden'] = 'Файл скрипта скрыт', ['Script file is not hidden'] = 'Файл скрипта не скрыт',
    ['Could not change file attributes'] = 'Не удалось изменить атрибуты файла',
    ['Script deleted'] = 'Скрипт удалён', ['Could not delete the script file: %s'] = 'Не удалось удалить файл скрипта: %s',
}

-- переводы новых элементов (боковые иконки, списки слов, свои шрифты)
for k, v in pairs({
    ['Notification history'] = 'История уведомлений', ['Script info'] = 'Информация о скрипте',
    ['Update log and critical errors of the script.'] = 'Лог обновлений и критические ошибки скрипта.',
    ['Update to version %s'] = 'Обновление до версии %s', ['Back'] = 'Назад', ['Changelog'] = 'Список изменений',
    ['Paused: scroll [to the top] for new entries'] = 'Пауза: вернитесь [в начало], чтобы видеть новые записи',
    ['Update'] = 'Обновление', ['Critical error'] = 'Критическая ошибка',
    ['Added the notification history and script info icons'] = 'Добавлены иконки истории уведомлений и информации о скрипте',
    ['Added the phrase list editor (base for the anti-flood)'] = 'Добавлен редактор списков фраз (основа для анти-флуда)',
    ['Added custom fonts from the files folder'] = 'Добавлена загрузка своих шрифтов из папки files',
    ['Version, keys, folders and the state of script files.'] = 'Версия, клавиши, папки и состояние файлов скрипта.',
    ['No notifications yet'] = 'Записей пока нет',
    ['Version'] = 'Версия', ['Author'] = 'Автор', ['Menu command'] = 'Команда меню', ['Active config'] = 'Активный конфиг',
    ['Files folder'] = 'Папка файлов', ['Custom fonts'] = 'Свои шрифты', ['Icon font'] = 'Шрифт иконок',
    ['Loaded'] = 'Загружен', ['Missing'] = 'Не найден', ['Uptime'] = 'Время работы',
    ['Key binds'] = 'Бинды', ['Fly Car: flight key'] = 'Fly Car: клавиша полёта', ['Chat calculator: copy key'] = 'Чат-калькулятор: копирование',
    ['CamHack: activation'] = 'Свободная камера: включение', ['CamHack: deactivation'] = 'Свободная камера: выключение',
    ['CamHack: speed up'] = 'Свободная камера: скорость +', ['CamHack: speed down'] = 'Свободная камера: скорость -', ['Commands'] = 'Команды', ['Far chat: toggle key'] = 'Дальний чат: клавиша включения',
    ['Anti-flood phrases'] = 'Фразы анти-флуда', ['Ignored phrases'] = 'Игнорируемые фразы',
    ['No phrases added'] = 'Не добавлена ни одна фраза', ['Type a phrase here to add it'] = 'Введите сюда фразу, чтобы добавить её',
    ['No nicknames added'] = 'Ни одного ника не добавлено', ['Type a nickname here to add it'] = 'Введите сюда ник, чтобы его добавить',
    ['Such a nickname already exists!'] = 'Такой ник уже есть!',
    ['Add'] = 'Добавить', ['Such a phrase already exists!'] = 'Такая фраза уже есть!', ['phrases'] = 'фраз',
    ['Open fonts folder'] = 'Открыть папку шрифтов', ['Rescan fonts'] = 'Обновить список шрифтов',
    ['Put .ttf / .otf files into this folder - the list updates by itself: %s'] = 'Положите .ttf / .otf файлы в эту папку - список обновится сам: %s',
    ['Custom fonts found: %d'] = 'Найдено своих шрифтов: %d', ['Fonts updated: %d custom'] = 'Список шрифтов обновлён (своих: %d)',
    ['Font file not found, the default font is used'] = 'Файл шрифта не найден, включён шрифт по умолчанию',
    ['Could not load the custom fonts, the default font is used'] = 'Не удалось загрузить свои шрифты, включён шрифт по умолчанию',
}) do i18n.TR.ru[k] = v end

local function tr(s)
    if i18n.curLang == 'en' or s == nil then return s end
    local t = i18n.TR[i18n.curLang]
    return (t and t[s]) or s
end
local function trf(s, ...) return string.format(tr(s), ...) end
local function trl(lang, s)                       -- перевод на конкретный язык, независимо от выбранного
    if s == nil then return s end
    local t = i18n.TR[lang]
    return (t and t[s]) or s
end

local function langIndex(id)                     -- id языка -> индекс для combo (с нуля) или nil
    for i, l in ipairs(i18n.LANGS) do
        if l.id == id then return i - 1 end
    end
    return nil
end
local function currentLangId()
    local i = ui.lang and math.max(0, math.min(#i18n.LANGS - 1, ui.lang[0])) or 0
    return i18n.LANGS[i + 1].id
end
local function syncLang() i18n.curLang = currentLangId() end

-- ----------------------------------------------------------------------------
--  Утилиты
-- ----------------------------------------------------------------------------
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function mix(a, b, t) return {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t} end
local function easeOut(t) return 1 - (1 - t) ^ 3 end

-- цвет -> u32 с учётом глобальной прозрачности
local function C(t, a)
    local v = gfx.cv                                       -- один ImVec4 на все вызовы: цвет задаётся каждый кадр сотни раз
    if not v then v = imgui.ImVec4(0, 0, 0, 0); gfx.cv = v end
    v.x, v.y, v.z, v.w = t[1], t[2], t[3], (a or 1) * gfx.galpha
    return imgui.ColorConvertFloat4ToU32(v)
end

-- плавная анимация значения по id
local function animTo(id, target, speed)
    local dt = imgui.GetIO().DeltaTime
    local v = gfx.anim[id]
    if v == nil then v = target end
    v = v + (target - v) * math.min(1, dt * (speed or 12) * ui.animSpeed[0])
    if math.abs(target - v) < 0.002 then v = target end
    gfx.anim[id] = v
    return v
end

local function keyName(k)
    if k == 0 then return tr('None') end
    return vkeys.id_to_name(k) or tostring(k)
end

local function searchConsumesMenuKey(k)
    if k == 0 then return false end
    return k == 0x20 or
        (k >= 0x30 and k <= 0x5A) or (k >= 0x60 and k <= 0x6F) or
        (k >= 0xBA and k <= 0xDF)
end

-- нижний регистр для Windows-1251 (string.lower не понимает кириллицу)
local function lower(s)
    s = s:lower()
    s = s:gsub('[\192-\223]', function(c) return string.char(c:byte() + 32) end)
    s = s:gsub('\168', '\184')
    return s
end
local function trim(s) return s:match('^%s*(.-)%s*$') end

-- ----------------------------------------------------------------------------
--  Инструменты разработчика: журнал (реализация остального - в разделе "Инструменты разработчика" ниже)
--  В журнал попадают все уведомления меню и вывод консоли Lua (Tools -> Console).
-- ----------------------------------------------------------------------------
local Dev = {
    log = {},                 -- {t = 'ЧЧ:ММ:СС', kind = 'info' | 'success' | 'error' | 'cmd', text = '...'}
    scroll = false,           -- прокрутить журнал вниз в ближайшем кадре
    tdClicks = {},            -- история нажатий на текстдравы: {id, t, str}
    evIn = {n = 0},           -- последний входящий ивент samp.events (от сервера): {name, dir, clock, n}
    evOut = {n = 0},          -- последний исходящий ивент (на сервер)
    tdCount = 0,              -- сколько текстдравов найдено на экране (считает оверлей Inspector)
    start = os.clock(),       -- момент загрузки скрипта (для Uptime)
}
CONST.DEV_LOG_MAX = 300       -- сколько строк журнала хранить

function Dev.add(kind, text)
    local log = Dev.log
    log[#log + 1] = {t = os.date('%H:%M:%S'), kind = kind, text = tostring(text)}
    if #log > CONST.DEV_LOG_MAX then table.remove(log, 1) end
    Dev.scroll = true
end

-- Уведомления бывают трёх видов (цвет полоски, точки и индикатора времени):
--   Notify(...)     - обычное, синее (не зависит от пресета меню);
--   NotifyOk(...)   - успех, зелёный;
--   NotifyErr(...)  - ошибка, красный; в заголовке появляется "COLLAPSE | Ошибка" (слово "Ошибка" красным).
CONST.TOAST_COL = {
    info    = {0.27, 0.55, 1.00},
    success = {0.30, 0.80, 0.50},
    error   = {0.95, 0.32, 0.32},
}
CONST.OVL_BASE, CONST.OVL_SIZE = 12, 32   -- размер шрифта оверлея по умолчанию и размер его крупной версии (для увеличения без мыла)
CONST.TOAST_WRAP = 420                   -- ширина (px), по которой переносится текст уведомления

local function pushToast(kind, key, ...)
    local text = tr(key)
    if select('#', ...) > 0 then text = string.format(text, ...) end
    -- чем длиннее текст, тем дольше он висит: минимум 4.0 с, +0.04 с на символ, максимум 7 с
    local life = clamp(2.5 + #text * 0.04, 4.0, 7)
    gfx.toasts[#gfx.toasts + 1] = {kind = kind, text = text, t0 = os.clock(), life = life}
    Dev.add(kind, text)
end
local function Notify(key, ...)    pushToast('info', key, ...) end
local function NotifyOk(key, ...)  pushToast('success', key, ...) end
local function NotifyErr(key, ...) pushToast('error', key, ...) end

-- ----------------------------------------------------------------------------
--  Команда активации меню (по умолчанию /collapse; меняется в Settings -> Interface -> Menu)
--  Хранится в конфиге: секция [interface], ключ command.
-- ----------------------------------------------------------------------------
CMD.DEFAULT_CMD = 'collapse'
CMD.cmdName = CMD.DEFAULT_CMD        -- текущая команда
CMD.cmdRegistered = nil          -- что реально зарегистрировано в чате
CMD.cmdReady = false             -- true, когда SA-MP доступен и команды можно регистрировать

-- допустимо: латинские буквы, цифры и _ (1-24 символа); слэш в начале убирается, регистр приводится к нижнему
local function sanitizeCmd(s)
    s = trim(tostring(s or ''))
    s = s:gsub('^/+', '')
    s = s:lower()
    if #s < 1 or #s > 24 or not s:match('^[a-z0-9_]+$') then return nil end
    return s
end

local function registerCmd()
    if not CMD.cmdReady or CMD.cmdRegistered == CMD.cmdName then return end
    if CMD.cmdRegistered then pcall(sampUnregisterChatCommand, CMD.cmdRegistered) end     -- прежняя команда снимается
    sampRegisterChatCommand(CMD.cmdName, function() ui.open[0] = not ui.open[0] end)
    CMD.cmdRegistered = CMD.cmdName
end

local function setCommand(name, notify)
    local n = sanitizeCmd(name)
    if not n then
        if ui.cmd then ffi.copy(ui.cmd, CMD.cmdName) end              -- в поле возвращается прежняя команда
        if notify then NotifyErr('Invalid command: use latin letters, digits and _') end
        return false
    end
    if ui.cmd then ffi.copy(ui.cmd, n) end
    if n ~= CMD.cmdName then
        CMD.cmdName = n
        registerCmd()
        if notify then NotifyOk('Command changed: /%s', n) end
    end
    return true
end

-- lazy-хранилище значений виджетов
ctl.st, ctl.stType = {}, {}
ctl.loadedControls = {bool = {}, float = {}, int = {}, color = {}}
function ctl.modOk(b) return (b.mod or 0) == 0 or isKeyDown(b.mod) end                 -- вторая клавиша сочетания зажата
function ctl.bindFire(b) return b.key ~= 0 and wasKeyPressed(b.key) and ctl.modOk(b) end
function ctl.bindName(b)
    if (b.mod or 0) ~= 0 and b.key ~= 0 then return keyName(b.mod) .. ' + ' .. keyName(b.key) end
    return keyName(b.key)
end
ctl.loadedBinds = {}      -- клавиши из конфига (в т.ч. для ещё не созданных биндов)
ctl.stDef = {}            -- значения по умолчанию (чтобы загрузка конфига сбрасывала недостающие ключи)
local function B(k, d)
    if not ctl.st[k] then
        local v = ctl.loadedControls.bool[k]
        if v == nil then v = d or false end
        ctl.st[k], ctl.stType[k], ctl.stDef[k] = imgui.new.bool(v), 'bool', d or false
    end
    return ctl.st[k]
end
local function F(k, d)
    if not ctl.st[k] then
        ctl.st[k], ctl.stType[k], ctl.stDef[k] = imgui.new.float(ctl.loadedControls.float[k] ~= nil and ctl.loadedControls.float[k] or (d or 0)), 'float', d or 0
    end
    return ctl.st[k]
end
local function I(k, d)
    if not ctl.st[k] then
        ctl.st[k], ctl.stType[k], ctl.stDef[k] = imgui.new.int(ctl.loadedControls.int[k] ~= nil and ctl.loadedControls.int[k] or (d or 0)), 'int', d or 0
    end
    return ctl.st[k]
end

-- индекс шрифта по названию (0, если такого нет)
local function fontIndex(name)
    for i, n in ipairs(FNT.FONT_NAMES) do
        if n == name then return i - 1 end
    end
    return 0
end

-- выбранный индекс шрифта из конфига; defName - шрифт по умолчанию
local function selFontIdx(key, defName)
    local p = I(key, fontIndex(defName))
    if p[0] < 0 or p[0] >= #FNT.FONT_NAMES then p[0] = fontIndex(defName) end   -- индекс из чужого конфига мог выйти за список
    return p[0]
end

-- применяет шрифт интерфейса: подменяет fonts.* и шрифт по умолчанию imgui (меняется сразу, без перезапуска)
-- Шрифты оверлеев (Render, Debug overlay). Любое масштабирование растра шрифта даёт мыло, поэтому для оверлеев
-- заранее растрируются отдельные чёткие шрифты (OversampleH = 1, привязка к пикселям) в размерах CONST.OVL_SIZES,
-- и под нужный размер берётся ближайший из них БЕЗ масштабирования (размер меняется ступенями).
-- Масштаб применяется только за краями набора (меньше 8 px и больше 32 px).
CONST.OVL_SIZES = {8, 10, 12, 14, 17, 20, 24, 32}
FNT.ovl, FNT.ovlExact = {}, false
function FNT.setOverlaySet(fs)
    if fs.ov and #fs.ov > 0 then
        FNT.ovl, FNT.ovlExact = fs.ov, true
        return
    end
    local t = {}                   -- запасной вариант: обычные шрифты интерфейса с масштабом
    for _, e in ipairs({{12, fs.small}, {15, fs.regular}, {18, fs.toast}, {CONST.OVL_SIZE, fs.overlay}}) do
        if e[2] then t[#t + 1] = e end
    end
    FNT.ovl, FNT.ovlExact = t, false
end
-- k - множитель размера (1.0 = CONST.OVL_BASE px); возвращает шрифт и масштаб для font.Scale
function FNT.pickOverlay(k)
    local target = CONST.OVL_BASE * k
    local best, bd
    for _, e in ipairs(FNT.ovl) do
        local d = math.abs(math.log(target / e[1]))
        if not bd or d < bd then best, bd = e, d end
    end
    if not best then return fonts.small, k end
    local scale = 1
    if not FNT.ovlExact or (best == FNT.ovl[1] and target < best[1]) or (best == FNT.ovl[#FNT.ovl] and target > best[1]) then
        scale = target / best[1]
    end
    return best[2], scale
end
-- ----------------------------------------------------------------------------
--  Иконки FontAwesome (Font Awesome 6 Free Solid, v6.2.0). Файл шрифта берётся из moonloader\config\xMercy\fa-solid-900.ttf.
--  FNT.fa['HOUSE'] -> строка UTF-8 с иконкой (имена из шрифта: заглавные, дефисы -> '_', имя с цифры получает
--  префикс N: '500px' -> 'N500PX'). Шрифты иконок грузятся отдельно от текстовых (без MergeMode: так
--  атлас не раздувается в 14 раз) размерами FNT.FA_SIZES; рисовать иконку - FNT.drawIcon(...).
--  Имена -> коды символов: FNT.faCodes (в конце файла); после загрузки в атлас таблица освобождается.
-- ----------------------------------------------------------------------------
FNT.FA_SIZES = {14, 18, 24}
FNT.FA_FILE = 'config\\xMercy\\fa-solid-900.ttf'      -- прежнее место файла иконок (от папки moonloader): читается, только если в files его нет
FNT.FA_NAME = 'fa-solid-900.ttf'                      -- имя файла шрифта иконок в папке files
FNT.fa, FNT.faFont = {}, {}

-- ----------------------------------------------------------------------------
--  Папка файлов скрипта: moonloader\config\xMercy\Collapse\files
--  Сюда кладутся шрифт иконок (fa-solid-900.ttf), свои шрифты (*.ttf / *.otf) и списки слов (words_*.txt).
--  Список шрифтов в Settings -> Interface -> Fonts обновляется сам: пока окно \"Fonts\" открыто, папка
--  опрашивается раз в 1.5 с. Нашёлся новый/пропал старый файл - атлас шрифтов пересобирается на лету.
--  Выбранный шрифт хранится в конфиге ПО НАЗВАНИЮ ([str] font_interface / font_toast): если файла уже нет,
--  включается шрифт по умолчанию (FNT.DEFAULT_FONT).
-- ----------------------------------------------------------------------------
FNT.MAX_FONT_BYTES = 24 * 1024 * 1024    -- файлы больше не берём (CJK-шрифты на десятки МБ раздувают атлас)
FNT.custom, FNT.customSig, FNT.badSig = {}, nil, nil     -- свои шрифты: {name, file, path, size}
FNT.lastSizes = {}                       -- размеры файлов при прошлом опросе: файл берём, только когда размер перестал меняться
FNT.pollAt, FNT.rebuildReq, FNT.built = 0, false, false
FNT.need, FNT.tried, FNT.quiet = {}, {}, false      -- need: семейства, которые надо загрузить; tried: что загружалось при последней сборке
FNT.SEL_KEYS = {'font_interface', 'font_toast'}          -- ключи выбора шрифта в конфиге
FNT.want = {}                            -- ключ -> название шрифта, которое надо выбрать (из конфига / до пересборки)

function FNT.filesDir() return getWorkingDirectory() .. '\\config\\xMercy\\Collapse\\files' end

function FNT.ensureFilesDir()
    local wd = getWorkingDirectory()
    for _, rel in ipairs({'\\config', '\\config\\xMercy', '\\config\\xMercy\\Collapse', '\\config\\xMercy\\Collapse\\files'}) do
        local d = wd .. rel
        if not doesDirectoryExist(d) then createDirectory(d) end
    end
end

-- путь к файлу шрифта иконок: сначала files, потом прежнее место; если нет нигде - nil и путь, куда его положить
function FNT.faPath()
    local a = FNT.filesDir() .. '\\' .. FNT.FA_NAME
    if doesFileExist(a) then return a end
    local b = getWorkingDirectory() .. '\\' .. FNT.FA_FILE
    if doesFileExist(b) then return b end
    return nil, a
end

-- файл похож на шрифт? (заголовок TTF/OTF, разумный размер) -> размер или nil. Битые файлы в атлас не пускаем.
local function ttfSize(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local head = f:read(4)
    local size = f:seek('end')
    f:close()
    if not head or #head < 4 or not size then return nil end
    if size < 2048 or size > FNT.MAX_FONT_BYTES then return nil end
    if head == '\0\1\0\0' or head == 'true' or head == 'OTTO' then return size end
    return nil
end

function FNT.scan()
    local list, dir = {}, FNT.filesDir()
    for _, mask in ipairs({'*.ttf', '*.otf'}) do
        local h, f = findFirstFile(dir .. '\\' .. mask)
        while h and f do
            local low = f:lower()
            if low ~= FNT.FA_NAME and not low:find('^fa[-_]') and not low:find('fontawesome', 1, true) then
                local path = dir .. '\\' .. f
                local size = ttfSize(path)
                if size then list[#list + 1] = {name = (f:gsub('%.[^.]+$', '')), file = f, path = path, size = size} end
            end
            f = findNextFile(h)
        end
        if h then findClose(h) end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

function FNT.signature(list)
    local t = {}
    for _, e in ipairs(list) do t[#t + 1] = e.file .. ':' .. e.size end
    t[#t + 1] = 'fa:' .. (FNT.faPath() and '1' or '0')      -- появился/пропал файл иконок тоже считается изменением
    return table.concat(t, '|')
end

-- опрос папки: force = true - сразу и без проверки стабильности размера (кнопка Rescan)
function FNT.poll(force)
    local now = os.clock()
    if not force and now < FNT.pollAt then return end
    FNT.pollAt = now + 1.5
    local ok, list = pcall(FNT.scan)
    if not ok then return end
    local stable, sizes = {}, {}
    for _, e in ipairs(list) do
        sizes[e.file] = e.size
        if force or FNT.lastSizes[e.file] == e.size then stable[#stable + 1] = e end    -- файл ещё копируется - ждём
    end
    FNT.lastSizes = sizes
    local sig = FNT.signature(stable)
    if sig == FNT.customSig or sig == FNT.badSig then return end
    FNT.customSig, FNT.custom = sig, stable
    FNT.rebuildReq = true
end

function FNT.uniqueName(name)                 -- название шрифта в списке не должно повторять уже занятое
    local function taken(n)
        for _, x in ipairs(FNT.FONT_NAMES) do
            if x:lower() == n:lower() then return true end
        end
        return false
    end
    if not taken(name) then return name end
    local i = 2
    while taken(name .. ' (' .. i .. ')') do i = i + 1 end
    return name .. ' (' .. i .. ')'
end

function FNT.openFolder()
    FNT.ensureFilesDir()
    local dir = FNT.filesDir()
    local ok = pcall(function()
        if not FNT.shell then
            pcall(ffi.cdef, 'void* ShellExecuteA(void* hwnd, const char* op, const char* file, const char* params, const char* dir, int show);')
            FNT.shell = ffi.load('shell32')
        end
        local r = tonumber(ffi.cast('intptr_t', FNT.shell.ShellExecuteA(nil, 'open', dir, nil, nil, 1)))
        if r <= 32 then error('ShellExecute failed') end
    end)
    if not ok then pcall(os.execute, 'start \"\" \"' .. dir .. '\"') end
end

function FNT.utf8char(cp)                 -- кодовая точка (BMP, >= 0x800) -> UTF-8
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- ближайший по размеру загруженный шрифт иконок (nil, если иконки не загрузились)
function FNT.iconFont(size)
    local best, bd
    for _, sz in ipairs(FNT.FA_SIZES) do
        local f = FNT.faFont[sz]
        if f and (not bd or math.abs(sz - size) < bd) then best, bd = f, math.abs(sz - size) end
    end
    return best
end

-- рисует иконку по имени с центром в (cx, cy); col - ImU32 (как у C(...)); возвращает true, если нарисована
function FNT.drawIcon(dl, name, size, cx, cy, col)
    local f, s = FNT.iconFont(size), FNT.fa[name]
    if not (f and s) then return false end
    imgui.PushFont(f)
    local sz = imgui.CalcTextSize(s)
    dl:AddText(imgui.ImVec2(cx - sz.x / 2, cy - sz.y / 2), col, s)
    imgui.PopFont()
    return true
end

-- Выбор шрифта хранится в конфиге по названию, а в виджете - индексом в FNT.FONT_NAMES.
-- resolve ставит индексы по желаемым названиям (FNT.want); нет такого шрифта - шрифт по умолчанию.
function FNT.resolve()
    if #FNT.FONT_NAMES == 0 then return end
    local missing = false
    for _, key in ipairs(FNT.SEL_KEYS) do
        local name = FNT.want[key]
        if name then
            local idx
            for i, n in ipairs(FNT.FONT_NAMES) do
                if n == name then idx = i - 1 break end
            end
            if not idx then idx, missing = fontIndex(FNT.DEFAULT_FONT), true end
            local ptr = ctl.st[key]
            if ptr then ptr[0] = idx else ctl.loadedControls.int[key] = idx end
            FNT.want[key] = nil
        end
    end
    if missing and FNT.built then NotifyErr('Font file not found, the default font is used') end
end

FNT.curUiFont = nil
local function applyUiFont()
    if #FNT.FONT_NAMES == 0 then return end
    local idx = selFontIdx('font_interface', FNT.DEFAULT_FONT)
    if idx == FNT.curUiFont then return end
    local fs = FNT.FONTSETS[idx + 1]
    if not fs then return end
    if fs.lazy then                                  -- семейство ещё не загружено в атлас: собираем атлас с ним
        if FNT.tried[fs.name] then                   -- уже пробовали и не вышло: остаётся шрифт по умолчанию
            fs = FNT.FONTSETS[fontIndex(FNT.DEFAULT_FONT) + 1]
            if not fs or fs.lazy then return end
        else
            FNT.rebuildReq, FNT.quiet = true, true
            return
        end
    end
    fonts.regular, fonts.bold, fonts.title, fonts.small = fs.regular, fs.bold, fs.title, fs.small
    fonts.overlay = fs.overlay
    imgui.GetIO().FontDefault = fs.regular
    FNT.setOverlaySet(fs)
    FNT.curUiFont = idx
end
local function Col(k, r, g, b, a)
    if not ctl.st[k] then
        local c = ctl.loadedControls.color[k] or {r, g, b, a or 1}
        ctl.st[k], ctl.stType[k], ctl.stDef[k] = imgui.new.float[4](c[1], c[2], c[3], c[4] or 1), 'color', {r, g, b, a or 1}
    end
    return ctl.st[k]
end

-- ----------------------------------------------------------------------------
--  Иконки (векторные, без шрифта иконок)
-- ----------------------------------------------------------------------------
local function Icon(name, cx, cy, col)
    local dl = imgui.GetWindowDrawList()
    local P = imgui.ImVec2
    if name == 'aim' then
        dl:AddCircle(P(cx, cy), 7, col, 24, 1.6)
        dl:AddCircleFilled(P(cx, cy), 1.8, col, 12)
        dl:AddLine(P(cx - 10, cy), P(cx - 4, cy), col, 1.6)
        dl:AddLine(P(cx + 4, cy), P(cx + 10, cy), col, 1.6)
        dl:AddLine(P(cx, cy - 10), P(cx, cy - 4), col, 1.6)
        dl:AddLine(P(cx, cy + 4), P(cx, cy + 10), col, 1.6)
    elseif name == 'eye' then
        for s = -1, 1, 2 do
            local prev
            for i = 0, 20 do
                local t = i / 20
                local pt = P(cx - 10 + 20 * t, cy + s * 5.5 * math.sin(t * math.pi))
                if prev then dl:AddLine(prev, pt, col, 1.6) end
                prev = pt
            end
        end
        dl:AddCircleFilled(P(cx, cy), 3, col, 14)
    elseif name == 'home' then
        local pts = {{-10, 0}, {0, -9}, {10, 0}}
        for _, q in ipairs(pts) do dl:PathLineTo(P(cx + q[1], cy + q[2])) end
        dl:PathStroke(col, false, 1.6)
        dl:AddRect(P(cx - 7, cy - 1), P(cx + 7, cy + 9), col, 2, nil, 1.6)
        dl:AddRectFilled(P(cx - 2, cy + 3), P(cx + 2, cy + 9), col, 1)
    elseif name == 'misc' then
        local ys = {-6, 0, 6}
        local ks = {-3, 4, -1}
        for i = 1, 3 do
            dl:AddLine(P(cx - 9, cy + ys[i]), P(cx + 9, cy + ys[i]), col, 1.6)
            dl:AddCircleFilled(P(cx + ks[i], cy + ys[i]), 2.6, col, 12)
        end
    elseif name == 'bolt' then
        local pts = {{2.5, -10}, {-5.5, 1.5}, {-0.5, 1.5}, {-2.5, 10}, {5.5, -2}, {0.5, -2}}
        for _, q in ipairs(pts) do dl:PathLineTo(P(cx + q[1], cy + q[2])) end
        dl:PathStroke(col, true, 1.7)
    elseif name == 'apps' then
        for ix = 0, 1 do
            for iy = 0, 1 do
                local x0, y0 = cx - 9 + ix * 10.5, cy - 9 + iy * 10.5
                dl:AddRectFilled(P(x0, y0), P(x0 + 7.5, y0 + 7.5), col, 2)
            end
        end
    elseif name == 'gear' then
        if FNT.drawIcon(dl, 'GEAR', 18, cx, cy, col) then return end      -- шестерёнка FontAwesome (fa.GEAR в arztools); без шрифта - рисованная
        dl:AddCircle(P(cx, cy), 3.2, col, 14, 1.6)
        dl:AddCircle(P(cx, cy), 6.5, col, 20, 1.6)
        for i = 0, 7 do
            local a = i * math.pi / 4
            dl:AddLine(P(cx + math.cos(a) * 7, cy + math.sin(a) * 7),
                       P(cx + math.cos(a) * 10, cy + math.sin(a) * 10), col, 2)
        end
    end
end

-- ----------------------------------------------------------------------------
--  Виджеты
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
--  Подсказки (tooltip) для функций
--  Текст берётся из таблицы HINTS по названию функции, либо передаётся
--  последним аргументом виджета: Checkbox('Name', ptr, 'Свой текст подсказки')
--  Если у функции есть подсказка, рядом с её названием рисуется значок "?" (gfx.hintIcon),
--  а сама подсказка появляется при наведении на этот значок (галочка Settings -> Interface -> Hints выключает всё).
--  Кнопки-иконки в Config и кнопка языка названия не имеют, поэтому у них подсказка по-прежнему
--  появляется при наведении на саму кнопку (Hint). У Create и Delete подсказка есть, у Load и Refresh нет.
--  Тексты подсказок пишутся по-английски, русский вариант лежит в TR.ru (раздел Локализация).
-- ----------------------------------------------------------------------------
local HINTS = {
    -- Settings -> Interface
    ['Animation speed']   = 'Speed of all menu animations.',
    ['FPS in sidebar']    = 'Show FPS in the player card.',
    ['Language']          = 'Interface language. Applies instantly and is saved to the config.',
    ['Preset']            = 'Color preset of the menu: sets the main color and the tint of the surfaces. Applies instantly and is saved to the config.',
    ['Notepad']           = 'Simple notepad. Everything you type is saved automatically.',
    ['Fonts']             = 'Fonts for notifications and for all script text.',
    -- Settings -> Config (кнопки с иконками)
    ['Create']            = 'Add a config to the list with default settings. It will not become active.',
    ['Delete']            = 'Hold the button for 2 seconds.',
    -- Tools
    -- Misc -> Debug / Console
    ['Copy position']              = 'Copies the x, y, z coordinates of your character to the clipboard.',
    ['Copy position and heading']  = 'Copies x, y, z and the heading angle to the clipboard.',
    ['Copy as Lua code']           = 'Copies a ready setCharCoordinates(PLAYER_PED, x, y, z) call to the clipboard.',
    ['Debug overlay']              = 'Shows a small panel on the screen with FPS, coordinates and vehicle info. Saved to the config.',
    ['Text size']                  = 'Size of the text in the debug overlay. The panel grows with it.',
    ['Collect garbage']            = 'Runs a full Lua garbage collection of this script (twice) and shows how much memory was freed. Does not affect the game memory.',
    ['Log events']                 = 'Records the RPC events of samp.events into a list. Frequent events are only counted, not written line by line, so memory does not grow.',
    ['Log arguments']              = 'Adds the arguments of the event to its log line: name(arg=value, ...). Long values are shortened.',
    ['Log animations']             = 'Records every change of your animation and the animations applied by the server.',
    ['Frequent after']             = 'An event that happens this many times within 10 seconds goes to the "Frequent events" list: only a counter is kept for it.',
    ['Log view']                   = 'Which list is shown on the right.',
    ['Logging']                    = 'Main switch of the logging. When it is off nothing is recorded (events, animations and CEF), whatever the switches below say.',
    ['Pause list']                 = 'Freezes the list so that new records do not move the lines. The records are still collected and appear after you turn the pause off. Not saved.',
    ['CEF logger']                 = 'Records the CEF events of the server (<) and the events your client sends to the server (>) in the CEF list. Only works while it is on.',
    ['Show last animation']        = 'Shows the last animation of your character: name, file and ID. Also shows the animation applied by the server.',
    ['Show last event']            = 'Shows the last incoming (<, from the server) and the last outgoing (>, to the server) RPC event of samp.events. While enabled, the script listens to all RPC events. Sync packets are not tracked.',
    -- Misc -> Inspector
    ['Dialog ID in title']         = 'Adds the dialog ID to the dialog title, for example [ID 25] Bank.',
    ['Log dialogs']                = 'Writes every shown dialog and your answer to it to the log (Tools -> Console). Passwords are hidden.',
    ['Color in chat messages']     = 'Adds the message color to the end of every chat message, for example | -12346237.',
    ['Color format']               = 'How the chat message color is written: signed number, hex RRGGBB or both.',
    ['Show textdraw IDs']          = 'Draws the ID of every textdraw on the screen at its position.',
    ['Show textdraw text']         = 'Adds the text of the textdraw to its ID label.',
    ['Track textdraw clicks']      = 'Remembers the IDs of the textdraws you click, shows them on the screen and writes them to the log.',
}

-- ----------------------------------------------------------------------------
--  Дополнительные настройки функций (окно выходит из шестерёнки у названия)
--  Если у функции есть запись в SETTINGS, то рядом с её названием автоматически
--  появляется шестерёнка. Элементы окна:
--    {'check',  'Название', 'ключ', по_умолчанию}
--    {'slider', 'Название', 'ключ', по_умолчанию, мин, макс, 'формат', целое?}
--    {'combo',  'Название', 'ключ', индекс, {'вариант 1', 'вариант 2'}}   (вместо индекса можно написать название варианта)
--    {'color',  'Название', 'ключ', {r, g, b, a}}
--    {'key',    'Название', 'ключ'}
--    {'button', 'Название', 'действие'}   - кнопка, действие берётся из SETTING_ACTIONS
--  Шестерёнка поддерживается у Checkbox, Slider и Button.
--  Названия элементов должны быть уникальными. Они тоже находятся через поиск.
-- ----------------------------------------------------------------------------

CONST.scrW, CONST.scrH = 1920, 1080
pcall(function()
    local w, h = getScreenResolution()
    if w and h and w >= 640 and h >= 480 then CONST.scrW, CONST.scrH = w, h end
end)

local SETTINGS = {
    ['Enable module'] = {title = 'Module settings', items = {
        {'check',  'Auto start',    's_mod_auto', true},
        {'slider', 'Update rate',   's_mod_rate', 60, 10, 144, '%d Hz', true},
        {'combo',  'Priority',      's_mod_prio', 1, {'Low', 'Normal', 'High'}},
        {'key',    'Quick toggle',  's_mod_key'},
    }},
    ['Speed'] = {title = 'Speed settings', items = {
        {'check',  'Ramp up smoothly', 's_spd_ramp', true},
        {'slider', 'Ramp time',        's_spd_time', 400, 0, 2000, '%d ms', true},
    }},
    ['Show overlay'] = {title = 'Overlay settings', items = {
        {'check',  'Lock position',   's_ov_lock', false},
        {'slider', 'Overlay scale',   's_ov_scale', 1.0, 0.5, 2.0, '%.1fx', false},
        {'combo',  'Anchor',          's_ov_anchor', 0, {'Top left', 'Top right', 'Bottom left', 'Bottom right'}},
        {'color',  'Background tint', 's_ov_tint', {0.05, 0.06, 0.08, 0.80}},
    }},
    ['Glow'] = {title = 'Glow settings', items = {
        {'slider', 'Glow intensity',  's_gl_int', 60, 0, 100, '%d%%', true},
        {'check',  'Pulse animation', 's_gl_pulse', true},
        {'combo',  'Blend mode',      's_gl_blend', 0, {'Additive', 'Alpha', 'Multiply'}},
        {'color',  'Inner color',     's_gl_col', {1.0, 1.0, 1.0, 1.0}},
    }},
    ['Time override'] = {title = 'Time settings', items = {
        {'slider', 'Time flow speed', 's_tm_speed', 1.0, 0, 10, '%.1fx', false},
        {'check',  'Freeze time',     's_tm_freeze', false},
    }},
    ['Vehicle boost'] = {title = 'Boost settings', items = {
        {'slider', 'Boost duration',  's_vb_dur', 3, 1, 10, '%d s', true},
        {'slider', 'Boost cooldown',  's_vb_cd', 5, 0, 30, '%d s', true},
        {'check',  'Only on ground',  's_vb_ground', false},
        {'key',    'Boost key',       's_vb_key'},
    }},
    ['Auto sprint'] = {title = 'Sprint settings', items = {
        {'check',  'Only forward',    's_sp_fwd', true},
        {'slider', 'Stamina limit',   's_sp_stam', 20, 0, 100, '%d%%', true},
    }},
    ['Auto reconnect'] = {title = 'Reconnect settings', items = {
        {'slider', 'Max attempts',        's_rc_max', 5, 1, 20, '%d', true},
        {'check',  'Notify on reconnect', 's_rc_notify', true},
    }},
    -- лог ивентов samp.events и анимаций (шестерёнка у Debug overlay); {'logview'} - встроенный список
    ['Debug overlay'] = {title = 'Debug overlay settings', items = {
        {'slider', 'Text size',      'dev_ov_scale', 1.0, 0.5, 3.0, '%.2fx', false},
        {'button', 'Edit overlay position', 'ov_pos_edit'},
    }},
    -- шрифты: отдельно для уведомлений и для всего остального текста скрипта (хранятся в каждом конфиге)
    ['Fonts'] = {title = 'Fonts', fonts = true, items = {
        {'combo',  'Interface font',    'font_interface', FNT.DEFAULT_FONT, FNT.FONT_NAMES},
        {'combo',  'Notification font', 'font_toast',     FNT.DEFAULT_FONT, FNT.FONT_NAMES},
        {'note',   nil, function() return FNT.noteText() end},
        {'button', 'Open fonts folder', 'font_folder'},
        {'button', 'Rescan fonts',      'font_rescan'},
        {'button', 'Show info',         'toast_info'},
        {'button', 'Show success',      'toast_ok'},
        {'button', 'Show error',        'toast_err'},
        {'button', 'Show long text',    'toast_long'},
    }},
}

CONST.HINT_DELAY, CONST.HINT_LINGER = 0.3, 0.05     -- задержка появления / сколько подсказка остаётся после ухода курсора
CONST.HINT_WRAP = 340                          -- ширина (px), по которой переносится текст подсказки

gfx.hintState = {text = nil, title = nil, id = nil, t0 = 0, lastText = nil, lastTitle = nil}

-- вызывать сразу после виджета: если на него наведён курсор, запоминаем подсказку
local function Hint(label, text, force)
    text = text or HINTS[label]
    if text and (force or imgui.IsItemHovered()) then
        gfx.hintState.text, gfx.hintState.title = text, label
    end
end

-- значок "?" рядом с названием функции: подсказка показывается при наведении именно на него.
-- Вызывать ДО основного элемента строки (как Gear): из перекрывающихся элементов ImGui отдаёт наведение
-- тому, кто отправлен раньше. late = true: значок только регистрируется, а рисует его функция, которую
-- вернул вызов (для кнопок: иначе заливка кнопки закрыла бы значок). limitX - правая граница значка.
gfx.hintIcon = function(label, text, x, y, late, limitX)
    if SRCH.collecting then return nil end
    text = text or HINTS[label]
    if not text or not B('m_hints', true)[0] then return nil end
    if limitX and x + 18 > limitX then x = limitX - 18 end
    local P = imgui.ImVec2
    local dl = imgui.GetWindowDrawList()
    local cur = imgui.GetCursorScreenPos()
    local id = '##hi' .. label
    imgui.SetCursorScreenPos(P(x, y))
    imgui.InvisibleButton(id, P(18, 18))
    local hov = imgui.IsItemHovered()
    imgui.SetCursorScreenPos(cur)
    if hov then gfx.hintState.text, gfx.hintState.title = text, label end
    local function draw()
        local h = animTo(id, hov and 1 or 0, 14)
        local tmain = THEME.main
        local cx, cy = x + 9, y + 9
        local col = C(mix(pal.dim, tmain, h))
        if not FNT.drawIcon(dl, 'CIRCLE_QUESTION', 14, cx, cy, col) then    -- иконка FontAwesome (как fa.CIRCLE_QUESTION в arztools); запасной вариант - рисованный
            dl:AddCircle(P(cx, cy), 7.5, col, 20, 1.2)
            imgui.PushFont(fonts.small)
            local sz = imgui.CalcTextSize('?')
            dl:AddText(P(cx - sz.x / 2, cy - sz.y / 2), col, '?')
            imgui.PopFont()
        end
    end
    if late then return draw end
    draw()
end

-- разбивает слишком длинное слово (без пробелов) на куски не шире maxw
local function splitLongWord(word, maxw)
    local parts, cur = {}, ''
    for ch in word:gmatch('.') do
        if cur ~= '' and imgui.CalcTextSize(u8(cur .. ch)).x > maxw then
            parts[#parts + 1] = cur
            cur = ch
        else
            cur = cur .. ch
        end
    end
    parts[#parts + 1] = cur
    return parts
end

-- перенос длинного текста на несколько строк по ширине maxw (текст в cp1251, шрифт - текущий)
local function wrapLines(text, maxw)
    local lines = {}
    for para in (text .. '\n'):gmatch('(.-)\n') do
        local cur = ''
        for word in para:gmatch('%S+') do
            local pieces = (imgui.CalcTextSize(u8(word)).x > maxw) and splitLongWord(word, maxw) or {word}
            for _, piece in ipairs(pieces) do
                local try = (cur == '') and piece or (cur .. ' ' .. piece)
                if cur ~= '' and imgui.CalcTextSize(u8(try)).x > maxw then
                    lines[#lines + 1] = cur
                    cur = piece
                else
                    cur = try
                end
            end
        end
        lines[#lines + 1] = cur
    end
    return lines
end

local function DrawHint(a)
    local tmain = THEME.main
    local al = ui.alpha * a
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16, 11))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 3))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 8)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1)
    imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(pal.panel[1], pal.panel[2], pal.panel[3], 1))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(pal.border[1], pal.border[2], pal.border[3], 1))
    imgui.BeginTooltip()

    imgui.PushFont(fonts.bold)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(tmain[1], tmain[2], tmain[3], 1))
    imgui.TextUnformatted(u8(tr(gfx.hintState.lastTitle)))
    imgui.PopStyleColor()
    imgui.PopFont()

    -- длинное описание переносится на несколько строк
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(pal.dim[1], pal.dim[2], pal.dim[3], 1))
    for _, ln in ipairs(wrapLines(tr(gfx.hintState.lastText), CONST.HINT_WRAP)) do
        if ln == '' then
            imgui.Dummy(imgui.ImVec2(1, 6))
        else
            imgui.TextUnformatted(u8(ln))
        end
    end
    imgui.PopStyleColor()

    local wp, ws = imgui.GetWindowPos(), imgui.GetWindowSize()
    gfx.galpha = al
    imgui.GetWindowDrawList():AddRectFilled(imgui.ImVec2(wp.x, wp.y + 9),
        imgui.ImVec2(wp.x + 3, wp.y + ws.y - 9), C(tmain), 2)
    gfx.galpha = 1

    imgui.EndTooltip()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(5)
end

-- ----------------------------------------------------------------------------
--  Реестр функций для поиска и подсветка найденной функции
--  Реестр строится автоматически: содержимое вкладок один раз "прогоняется"
--  в режиме collecting, где виджеты ничего не рисуют, а только регистрируются.
-- ----------------------------------------------------------------------------
SRCH.collecting = nil
SRCH.index = {}

local function Reg(label, kind, parent)
    local c = SRCH.collecting
    SRCH.index[#SRCH.index + 1] = {label = label, kind = kind, tab = c.tab, sub = c.sub, panel = c.panel, parent = parent,
        prog = c.prog, progTitle = c.progTitle, rpage = c.rpage}     -- prog: элемент лежит на странице программы вкладки Software
end

-- элементы окна доп. настроек тоже попадают в поиск (с указанием родительской функции)
local function RegSettings(label)
    local spec = SETTINGS[label]
    if not spec then return end
    for _, it in ipairs(spec.items) do
        if it[2] then Reg(it[2], 'Setting', label) end          -- {'logview'} в поиск не попадает
    end
end

local function Highlight(label, p, w, h)
    local hl = ui.hl
    if not hl or hl.label ~= label then return end
    local age = os.clock() - hl.t0
    local HL_TIME = 6.0                      -- сколько секунд держится подсветка
    if age > HL_TIME then ui.hl = nil return end
    local fade = clamp((HL_TIME - age) / 0.9, 0, 1)
    local pulse = 0.5 + 0.5 * math.sin(age * 8)
    local tmain = THEME.main
    local dl = imgui.GetWindowDrawList()
    -- рисуем чуть левее края панели (в её внутреннем отступе), поэтому снимаем обрезку по краю child
    dl:PushClipRect(imgui.ImVec2(p.x - 16, p.y - 4), imgui.ImVec2(p.x + w + 4, p.y + h + 4), false)
    dl:AddRectFilled(imgui.ImVec2(p.x - 8, p.y - 1), imgui.ImVec2(p.x + w, p.y + h), C(tmain, (0.10 + 0.14 * pulse) * fade), 7)
    dl:AddRectFilled(imgui.ImVec2(p.x - 8, p.y + 2), imgui.ImVec2(p.x - 5, p.y + h - 3), C(tmain, fade), 2)
    dl:PopClipRect()
end

-- маленькая вращающаяся шестерёнка
local function DrawGear(dl, cx, cy, r, ang, col)
    dl:AddCircle(imgui.ImVec2(cx, cy), r * 0.62, col, 18, 1.5)
    dl:AddCircleFilled(imgui.ImVec2(cx, cy), r * 0.22, col, 10)
    for i = 0, 7 do
        local a = ang + i * math.pi / 4
        dl:AddLine(imgui.ImVec2(cx + math.cos(a) * r * 0.72, cy + math.sin(a) * r * 0.72),
                   imgui.ImVec2(cx + math.cos(a) * r, cy + math.sin(a) * r), col, 2)
    end
end

-- шестерёнка справа от названия функции; клик открывает/закрывает окно доп. настроек.
-- Вызывать ДО основной кнопки строки (кнопка шестерёнки должна быть первой в этой области).
local function Gear(label, px, py)
    local id = '##gear' .. label
    local dl = imgui.GetWindowDrawList()
    imgui.SetCursorScreenPos(imgui.ImVec2(px, py))
    local pressed = imgui.InvisibleButton(id, imgui.ImVec2(20, 20))
    local hov = imgui.IsItemHovered()
    local cx, cy = px + 10, py + 10
    if pressed then
        ui.gearHit = true
        if ui.popOpen and ui.popLabel == label then
            ui.popOpen = false
        else
            ui.popLabel, ui.popOpen = label, true
        end
    end
    if ui.popReq == label then                  -- переход из поиска: открыть окно сразу
        ui.popLabel, ui.popOpen, ui.popReq = label, true, nil
    end
    local isOpen = ui.popOpen and ui.popLabel == label
    if ui.popLabel == label then ui.popAx, ui.popAy = cx, cy end
    local h = animTo(id .. 'h', (hov or isOpen) and 1 or 0, 14)
    local r = animTo(id .. 'r', isOpen and 1 or 0, 9)
    local tmain = THEME.main
    dl:AddCircleFilled(imgui.ImVec2(cx, cy), 10, C(tmain, 0.14 * h), 20)
    DrawGear(dl, cx, cy, 6.5, h * 0.5 + r * 0.8, C(mix(pal.dim, tmain, math.max(h, r))))
    return hov
end

local function Checkbox(label, ptr, hint, rightPad)
    if SRCH.collecting then Reg(label, 'Checkbox'); RegSettings(label) return end
    local id = '##cb' .. label
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local gearHov = false
    if SETTINGS[label] then
        gearHov = Gear(label, p.x + w - 38 - 26, p.y + 3)       -- сразу слева от переключателя
        imgui.SetCursorScreenPos(p)
    end
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 8, p.y + 4, false,
        p.x + w - 38 - (SETTINGS[label] and 26 or 0) - (rightPad or 0) - 4)
    if imgui.InvisibleButton(id, imgui.ImVec2(w, 26)) then ptr[0] = not ptr[0] end
    if gearHov then Hint('Settings', 'Additional function settings.', true) end
    Highlight(label, p, w, 26)
    local t = animTo(id, ptr[0] and 1 or 0, 14)
    local h = animTo(id .. 'h', imgui.IsItemHovered() and 1 or 0, 14)
    local tmain = THEME.main
    local tx, ty = p.x + w - 38, p.y + 4
    dl:AddText(imgui.ImVec2(p.x, p.y + 4), C(mix(pal.dim, pal.text, math.max(t, h * 0.7))), u8(tr(label)))
    if t > 0.01 then
        dl:AddRectFilled(imgui.ImVec2(tx - 3, ty - 3), imgui.ImVec2(tx + 37, ty + 21), C(tmain, 0.14 * t), 12)
    end
    dl:AddRectFilled(imgui.ImVec2(tx, ty), imgui.ImVec2(tx + 34, ty + 18), C(mix(pal.track, tmain, t)), 9)
    dl:AddCircleFilled(imgui.ImVec2(tx + 9 + 16 * t, ty + 9), 6.5, C(mix(pal.dim, pal.white, t)), 20)
end

local function Slider(label, ptr, mn, mx, fmt, isInt, hint)
    if SRCH.collecting then Reg(label, 'Slider'); RegSettings(label) return end
    local id = '##sl' .. label
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local R = 9                                   -- запас по краям под ползунок, чтобы круг не обрезался
    local gearHov = false
    if SETTINGS[label] then
        gearHov = Gear(label, p.x + imgui.CalcTextSize(u8(tr(label))).x + 6, p.y - 1)
        imgui.SetCursorScreenPos(p)
    end
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 6 + (SETTINGS[label] and 24 or 0), p.y, false, p.x + w - 56)
    imgui.InvisibleButton(id, imgui.ImVec2(w, 38))
    if gearHov then Hint('Settings', 'Additional function settings.', true) end
    Highlight(label, p, w, 38)
    local active, hov = imgui.IsItemActive(), imgui.IsItemHovered()
    if active then
        local t = clamp((imgui.GetIO().MousePos.x - p.x - R) / (w - 2 * R), 0, 1)
        local v = mn + (mx - mn) * t
        if isInt then v = math.floor(v + 0.5) end
        ptr[0] = v
    end
    local fill = animTo(id, (ptr[0] - mn) / (mx - mn), 22)
    local h = animTo(id .. 'h', (hov or active) and 1 or 0, 14)
    local tmain = THEME.main
    dl:AddText(imgui.ImVec2(p.x, p.y + 1), C(mix(pal.dim, pal.text, h)), u8(tr(label)))
    local s = u8(string.format(tr(fmt), ptr[0]))
    local sw = imgui.CalcTextSize(s).x
    dl:AddText(imgui.ImVec2(p.x + w - sw, p.y + 1), C(tmain), s)
    local by = p.y + 28
    dl:AddRectFilled(imgui.ImVec2(p.x, by), imgui.ImVec2(p.x + w, by + 4), C(pal.track), 2)
    local kx = p.x + R + (w - 2 * R) * fill
    dl:AddRectFilled(imgui.ImVec2(p.x, by), imgui.ImVec2(kx, by + 4), C(tmain), 2)
    dl:AddCircleFilled(imgui.ImVec2(kx, by + 2), 7 + 2 * h, C(tmain, 0.18 * h), 24)
    dl:AddCircleFilled(imgui.ImVec2(kx, by + 2), 4.5 + 1.5 * h, C(pal.white), 20)
end

local function Combo(label, ptr, items, hint)
    if SRCH.collecting then Reg(label, 'Combo') return end
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    Highlight(label, p, imgui.GetContentRegionAvail().x, 48)
    dl:AddText(p, C(pal.dim), u8(tr(label)))
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 6, p.y - 1)
    imgui.Dummy(imgui.ImVec2(1, 20))
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    local opened = imgui.BeginCombo('##cmb' .. label, u8(tr(items[ptr[0] + 1])))
    if opened then ui.popBusy = true end
    if opened then
        for i, name in ipairs(items) do
            if imgui.Selectable(u8(tr(name)), ptr[0] == i - 1) then ptr[0] = i - 1 end
        end
        imgui.EndCombo()
    end
    imgui.Dummy(imgui.ImVec2(1, 2))
end

local function ColorRow(label, ptr, hint)
    if SRCH.collecting then Reg(label, 'Color') return end
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    Highlight(label, p, w, 26)
    dl:AddText(imgui.ImVec2(p.x, p.y + 4), C(pal.dim), u8(tr(label)))
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 8, p.y + 4, false, p.x + w - imgui.GetFrameHeight() - 6)
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + w - imgui.GetFrameHeight(), p.y))   -- квадрат цвета строго у правого края строки
    imgui.ColorEdit4('##col' .. label, ptr, imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoLabel)
    -- над квадратом цвета ImGui сам показывает подсказку со значениями цвета: наша подсказка строки
    -- в этот момент не показывается, иначе они накладываются друг на друга
    if imgui.IsItemHovered() then gfx.hintBlock = true end
    -- открытый пикер цвета считаем "занятым" (клик внутри него не должен закрывать окно настроек)
    if pcall(imgui.PushIDStr, '##col' .. label) then
        local okp, isOpen = pcall(imgui.IsPopupOpen, 'picker')
        imgui.PopID()
        if okp and isOpen then ui.popBusy = true; gfx.hintBlock = true end
    end
end

-- Строка выбора пресета темы: подпись слева, справа ряд цветных кружков (как выбор стиля в arztools).
function THEME.row(label, hint)
    if SRCH.collecting then Reg(label, 'Preset') return end
    local P = imgui.ImVec2
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local SLOT, R = 24, 9                                  -- сторона области клика и радиус кружка
    local n = #THEME.LIST
    local x0 = p.x + w - n * SLOT
    Highlight(label, p, w, 26)
    dl:AddText(P(p.x, p.y + 4), C(pal.dim), u8(tr(label)))
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 8, p.y + 4, false, x0 - 24)
    for i = 1, n do
        local id = '##preset' .. i
        imgui.SetCursorScreenPos(P(x0 + (i - 1) * SLOT, p.y + 1))
        if imgui.InvisibleButton(id, P(SLOT, SLOT)) and THEME.cur ~= i then THEME.set(i) end
        local h = animTo(id, imgui.IsItemHovered() and 1 or 0, 14)
        local sel = animTo(id .. 's', THEME.cur == i and 1 or 0, 14)
        local cx, cy = x0 + (i - 1) * SLOT + SLOT / 2, p.y + 13
        local c = THEME.swatch[i]
        dl:AddCircleFilled(P(cx, cy), R + 3.5, C(c, 0.22 * math.max(sel, h * 0.6)), 24)       -- мягкое свечение
        dl:AddCircleFilled(P(cx, cy), R + h * 1.2 - sel * 0.8, C(c), 24)
        if sel > 0.01 then dl:AddCircle(P(cx, cy), R + 3.5, C(pal.text, sel), 24, 1.8) end    -- кольцо у выбранного
    end
    imgui.SetCursorScreenPos(p)
    imgui.Dummy(P(w, 26))
end

local function Keybind(label, b, hint)
    if SRCH.collecting then Reg(label, 'Keybind') return end
    local id = '##kb' .. label
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 8, p.y + 4, false, p.x + w - 116 - 6)
    if imgui.InvisibleButton(id, imgui.ImVec2(w, 26)) then
        listening = (listening == b) and nil or b
    end
    Highlight(label, p, w, 26)
    local isL = (listening == b)
    local t = animTo(id, (imgui.IsItemHovered() or isL) and 1 or 0, 14)
    local tmain = THEME.main
    local bw, bh = 116, 22
    local bx, by = p.x + w - bw, p.y + 2
    dl:AddText(imgui.ImVec2(p.x, p.y + 4), C(mix(pal.dim, pal.text, t)), u8(tr(label)))
    if isL then
        dl:AddRectFilled(imgui.ImVec2(bx - 1, by - 1), imgui.ImVec2(bx + bw + 1, by + bh + 1), C(tmain), 6)
    end
    dl:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + bw, by + bh), C(mix(pal.field, pal.fieldH, t)), 5)
    local txt = isL and '...' or ctl.bindName(b)
    local tw = imgui.CalcTextSize(u8(txt)).x
    dl:AddText(imgui.ImVec2(bx + (bw - tw) / 2, by + 2), C(isL and tmain or pal.dim), u8(txt))
end

-- Поле ввода текста в стиле остальных строк (подпись слева, поле справа).
-- onApply вызывается по Enter или когда поле теряет фокус после правки. prefix - серый символ внутри поля ('/').
gfx.txtFocus = {}
gfx.txtPass = {}       -- подписи полей, содержимое которых скрывается точками (токен, ключ доступа)
local function TextRow(label, buf, onApply, prefix, hint, width)
    if SRCH.collecting then Reg(label, 'Input') return end
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local tmain = THEME.main
    local iw = width or 130
    local bx, by = p.x + w - iw, p.y + 2
    Highlight(label, p, w, 26)
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 8, p.y + 4, false, p.x + w - iw - 6)
    local f = animTo('txtf' .. label, gfx.txtFocus[label] and 1 or 0, 14)
    dl:AddText(imgui.ImVec2(p.x, p.y + 4), C(mix(pal.dim, pal.text, f)), u8(tr(label)))
    if f > 0.01 then
        dl:AddRectFilled(imgui.ImVec2(bx - 1, by - 1), imgui.ImVec2(bx + iw + 1, by + 23), C(tmain, f), 6)
    end
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(prefix and 18 or 8, 3.5))
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 5)
    imgui.SetCursorScreenPos(imgui.ImVec2(bx, by))
    imgui.SetNextItemWidth(iw)
    local entered = imgui.InputText('##txt' .. label, buf, ffi.sizeof(buf), imgui.InputTextFlags.EnterReturnsTrue + (gfx.txtPass[label] and (imgui.InputTextFlags.Password or 0) or 0))
    imgui.PopStyleVar(2)
    local active = imgui.IsItemActive()
    gfx.txtFocus[label] = active
    if active and ui.open[0] then ui.fieldActive = true end
    if prefix then dl:AddText(imgui.ImVec2(bx + 8, by + 3), C(pal.dim), prefix) end
    if entered or imgui.IsItemDeactivatedAfterEdit() then onApply() end
    imgui.SetCursorScreenPos(p)
    imgui.Dummy(imgui.ImVec2(w, 26))
end

-- Текст-заголовок вида "Шрифты:" с шестерёнкой справа от него (окно берётся из SETTINGS[label]).
local function TextGear(label)
    if SRCH.collecting then Reg(label, 'Text'); RegSettings(label) return end
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local s = u8(tr(label) .. ':')
    imgui.PushFont(fonts.bold)
    local sz = imgui.CalcTextSize(s)
    imgui.PopFont()
    local gearHov = false
    if SETTINGS[label] then
        gearHov = Gear(label, p.x + sz.x + 6, p.y + 2)
        imgui.SetCursorScreenPos(p)
    end
    imgui.Dummy(imgui.ImVec2(w, 26))
    Highlight(label, p, w, 26)
    if gearHov then Hint('Settings', 'Additional function settings.', true) end
    imgui.PushFont(fonts.bold)
    dl:AddText(imgui.ImVec2(p.x, p.y + 4), C(pal.text), s)
    imgui.PopFont()
end

gfx.btnHold = {}
CONST.BTN_DANGER = {0.93, 0.36, 0.40}

-- hold (секунды, необязательно): кнопку нужно удерживать, пока она закрашивается красным;
-- Button вернёт true только когда удержание завершено (для опасных действий)
local function Button(label, h, filled, hint, hold, icon)
    if SRCH.collecting then Reg(label, 'Button'); RegSettings(label) return false end
    local id = '##bt' .. label
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    h = h or 30
    local gearHov = false
    if SETTINGS[label] then
        gearHov = Gear(label, p.x + w - 20, p.y + (h - 20) / 2)   -- шестерёнка справа от кнопки
        imgui.SetCursorScreenPos(p)
        w = w - 26
    end
    local hiDraw = gfx.hintIcon(label, hint, p.x + w - 24, p.y + (h - 18) / 2, true)
    local pressed = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    if gearHov then Hint('Settings', 'Additional function settings.', true) end
    Highlight(label, p, w, h)
    local hov = imgui.IsItemHovered()
    local t = animTo(id, hov and 1 or 0, 14)
    local tmain = THEME.main
    local fired, hp = false, 0
    if hold then
        -- прогресс удержания растёт, пока кнопка зажата; при отпускании плавно откатывается
        local hs = gfx.btnHold[id]
        if not hs then hs = {p = 0, t0 = nil, done = false}; gfx.btnHold[id] = hs end
        local active = imgui.IsItemActive()
        if active and hov then
            local now = os.clock()
            if not hs.t0 then hs.t0 = now end
            hs.p = math.min(1, (now - hs.t0) / hold)
            if hs.p >= 1 and not hs.done then hs.done = true; fired = true end
        else
            hs.t0 = nil
            if not active then hs.done = false end
            hs.p = math.max(0, hs.p - imgui.GetIO().DeltaTime * 3)
        end
        hp = hs.p
    end
    if pressed and not hold then
        local m = imgui.GetIO().MousePos
        gfx.ripples[id] = {t = os.clock(), x = m.x, y = m.y}
    end
    local fill = filled and mix(tmain, pal.white, t * 0.18) or mix(pal.field, hold and CONST.BTN_DANGER or tmain, t * 0.30)
    local pmax = imgui.ImVec2(p.x + w, p.y + h)
    dl:AddRectFilled(p, pmax, C(fill), 6)
    if hp > 0.001 then                                       -- заливка слева направо
        dl:PushClipRect(p, imgui.ImVec2(p.x + w * hp, p.y + h), true)
        dl:AddRectFilled(p, pmax, C(CONST.BTN_DANGER, 0.85), 6)
        dl:PopClipRect()
    end
    local r = gfx.ripples[id]
    if r then
        local age = os.clock() - r.t
        if age < 0.55 then
            dl:PushClipRect(p, pmax, true)
            dl:AddCircleFilled(imgui.ImVec2(r.x, r.y), (age / 0.55) * w * 0.9, C(pal.white, 0.22 * (1 - age / 0.55)), 40)
            dl:PopClipRect()
        else
            gfx.ripples[id] = nil
        end
    end
    local s = u8(tr(label))
    local sz = imgui.CalcTextSize(s)
    local tc = filled and THEME.onMain or mix(pal.dim, pal.text, math.max(t, 0.35))
    if hp > 0 then tc = mix(tc, pal.white, clamp(hp * 1.5, 0, 1)) end
    local tw = hiDraw and (w - 24) or w                       -- место под значок подсказки справа
    local tx = p.x + (tw - sz.x) / 2
    if icon and FNT.fa[icon] and FNT.iconFont(14) then                  -- иконка + текст по центру вместе
        tx = p.x + (tw - (sz.x + 24)) / 2 + 24
        FNT.drawIcon(dl, icon, 14, tx - 12, p.y + h / 2, C(tc))
    end
    dl:AddText(imgui.ImVec2(tx, p.y + (h - sz.y) / 2), C(tc), s)
    if hiDraw then hiDraw() end
    if hold then return fired end
    return pressed
end

local function MiniButton(label, w, h, filled, hint)
    if SRCH.collecting then Reg(label, 'Button') return false end
    local id = '##mb' .. label
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    w, h = w or 72, h or 26
    local hiDraw = gfx.hintIcon(label, hint, p.x + w - 22, p.y + (h - 18) / 2, true)
    local pressed = imgui.InvisibleButton(id, imgui.ImVec2(w, h))
    local hov = imgui.IsItemHovered()
    local t = animTo(id, hov and 1 or 0, 14)
    local tmain = THEME.main
    local fill = filled and mix(tmain, pal.white, t * 0.16) or mix(pal.field, tmain, t * 0.24)
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), C(fill, filled and 0.92 or 1), 5)
    dl:AddRect(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + w, p.y + h), C(mix(pal.border, tmain, t * 0.65), 0.9), 5)
    local s = u8(tr(label))
    local sz = imgui.CalcTextSize(s)
    local tw = hiDraw and (w - 22) or w
    dl:AddText(imgui.ImVec2(p.x + (tw - sz.x) / 2, p.y + (h - sz.y) / 2), C(filled and THEME.onMain or mix(pal.dim, pal.text, math.max(t, 0.45))), s)
    if hiDraw then hiDraw() end
    return pressed
end
gfx.iconSpin = {}
gfx.iconHold = {}
CONST.DANGER = {0.93, 0.36, 0.40}

-- Кнопка (по умолчанию 26x26, size - сторона квадрата) с векторной иконкой. kind: 'plus' | 'load' | 'delete' | 'refresh'
-- hold (секунды): кнопку нужно удерживать, пока она плавно закрашивается; true вернётся по завершении.
-- Подсказка берётся из HINTS[label], как у остальных функций; label = nil - без подсказки.
local function IconButton(kind, id, label, hold, size)
    if SRCH.collecting then return false end
    local dl = imgui.GetWindowDrawList()
    local P = imgui.ImVec2
    local p = imgui.GetCursorScreenPos()
    local w, h = size or 26, size or 26
    local pressed = imgui.InvisibleButton('##ib' .. id, P(w, h))
    if label and label ~= '' then Hint(label) end
    local hov = imgui.IsItemHovered()
    local t  = animTo('ib' .. id, hov and 1 or 0, 14)
    local ap = animTo('ibp' .. id, imgui.IsItemActive() and 1 or 0, 22)

    -- прогресс удержания: растёт, пока кнопка зажата; при отпускании плавно откатывается
    local fired, hp = false, 0
    if hold then
        local hs = gfx.iconHold[id]
        if not hs then hs = {p = 0, t0 = nil, done = false}; gfx.iconHold[id] = hs end
        local active = imgui.IsItemActive()
        if active and hov then
            local now = os.clock()
            if not hs.t0 then hs.t0 = now end
            hs.p = math.min(1, (now - hs.t0) / hold)
            if hs.p >= 1 and not hs.done then hs.done = true; fired = true end
        else
            hs.t0 = nil
            if not active then hs.done = false end
            hs.p = math.max(0, hs.p - imgui.GetIO().DeltaTime * 3)
        end
        hp = hs.p
    end

    local tmain = (kind == 'delete') and CONST.DANGER or THEME.main
    local col = C(mix(pal.dim, tmain, math.max(t, kind == 'delete' and 0.2 or 0.35)))
    local x, y = p.x, p.y
    local cx, cy = x + w / 2, y + h / 2
    local s = (1 - 0.12 * ap) * (w / 26)                     -- при нажатии иконка чуть сжимается
    local function q(px, py) return P(cx + px * s, cy + py * s) end

    dl:AddRectFilled(p, P(x + w, y + h), C(mix(pal.field, pal.fieldH, t), 0.95), 6)
    dl:AddRectFilled(p, P(x + w, y + h), C(tmain, 0.10 * t), 6)
    if hp > 0.001 then                                       -- заливка снизу вверх
        dl:PushClipRect(P(x, y + h * (1 - hp)), P(x + w, y + h), true)
        dl:AddRectFilled(p, P(x + w, y + h), C(tmain, 0.85), 6)
        dl:PopClipRect()
        col = C(mix(mix(pal.dim, tmain, math.max(t, 0.2)), pal.white, clamp(hp * 1.5, 0, 1)))
    end
    dl:AddRect(p, P(x + w, y + h), C(mix(pal.border, tmain, math.max(t * 0.7, hp)), 0.9), 6)

    local th = 1.7
    if kind == 'plus' then
        -- листок с загнутым уголком и плюсом; при наведении плюс слегка увеличивается
        dl:PathLineTo(q(-5, -7)); dl:PathLineTo(q(1.5, -7)); dl:PathLineTo(q(5.5, -3))
        dl:PathLineTo(q(5.5, 7)); dl:PathLineTo(q(-5, 7))
        dl:PathStroke(col, true, 1.6)
        dl:PathLineTo(q(1.5, -7)); dl:PathLineTo(q(1.5, -3)); dl:PathLineTo(q(5.5, -3))
        dl:PathStroke(col, false, 1.4)
        local k = 2.6 + 0.6 * t
        dl:AddLine(q(-k + 0.25, 2.2), q(k + 0.25, 2.2), col, 1.7)
        dl:AddLine(q(0.25, 2.2 - k), q(0.25, 2.2 + k), col, 1.7)
    elseif kind == 'load' then
        -- стрелка вниз в лоток; при наведении стрелка опускается
        local d = 1.4 * t
        dl:AddLine(q(0, -7 + d), q(0, 2.2 + d), col, 1.8)
        dl:PathLineTo(q(-4, -1.6 + d)); dl:PathLineTo(q(0, 2.6 + d)); dl:PathLineTo(q(4, -1.6 + d))
        dl:PathStroke(col, false, 1.8)
        dl:PathLineTo(q(-6.5, 2.5)); dl:PathLineTo(q(-6.5, 6.8)); dl:PathLineTo(q(6.5, 6.8)); dl:PathLineTo(q(6.5, 2.5))
        dl:PathStroke(col, false, th)
    elseif kind == 'delete' then
        -- корзина; при наведении крышка приоткрывается
        local l = -1.8 * math.max(t, hp)
        dl:AddLine(q(-6.5, -3.4 + l), q(6.5, -3.4 + l), col, 1.8)
        dl:PathLineTo(q(-2.3, -3.4 + l)); dl:PathLineTo(q(-2.3, -6.2 + l)); dl:PathLineTo(q(2.3, -6.2 + l)); dl:PathLineTo(q(2.3, -3.4 + l))
        dl:PathStroke(col, false, 1.6)
        dl:PathLineTo(q(-4.7, -0.8)); dl:PathLineTo(q(-3.9, 6.8)); dl:PathLineTo(q(3.9, 6.8)); dl:PathLineTo(q(4.7, -0.8))
        dl:PathStroke(col, false, th)
        dl:AddLine(q(-1.5, 1.8), q(-1.5, 4.8), col, 1.5)
        dl:AddLine(q(1.5, 1.8), q(1.5, 4.8), col, 1.5)
    elseif kind == 'refresh' then
        -- круговая стрелка: делает один плавный оборот только в момент нажатия
        local spin = 0
        local t0 = gfx.iconSpin[id]
        if pressed and not t0 then t0 = os.clock(); gfx.iconSpin[id] = t0 end
        if t0 then
            local age = os.clock() - t0
            if age < 0.7 then spin = easeOut(age / 0.7) * 2 * math.pi else gfx.iconSpin[id] = nil end
        end
        local r = 6.2
        local a0, a1 = math.rad(-40) + spin, math.rad(240) + spin
        dl:PathArcTo(q(0, 0), r * s, a0, a1, 26)
        dl:PathStroke(col, false, 1.8)
        local nx, ny = math.cos(a1), math.sin(a1)            -- радиус в конце дуги
        local tx, ty = -ny, nx                               -- касательная
        local ex, ey = nx * r, ny * r
        dl:AddTriangleFilled(
            q(ex + tx * 3.8, ey + ty * 3.8),
            q(ex + nx * 3.4 - tx * 0.6, ey + ny * 3.4 - ty * 0.6),
            q(ex - nx * 3.4 - tx * 0.6, ey - ny * 3.4 - ty * 0.6), col)
    end
    if hold then return fired end
    return pressed
end

-- Строка конфига: название слева, справа метка active и кнопки Load / Delete именно для этого конфига.
-- Кнопки отправляются раньше всего остального, а подсветка строки считается по IsMouseHoveringRect:
-- так ничего не перекрывает кнопки и они получают клики сами.
-- Возвращает: нажат ли Load, завершено ли удержание Delete.
local function ConfigRow(name, active)
    if SRCH.collecting then return false, false end
    local id = '##cr' .. name
    local P = imgui.ImVec2
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local RH, BH, BTN = 32, 30, 24                       -- слот строки, высота плашки, сторона кнопок
    local hov = imgui.IsMouseHoveringRect(p, P(p.x + w, p.y + BH))
    local h = animTo(id .. 'h', hov and 1 or 0, 14)
    local s = animTo(id, active and 1 or 0, 14)
    local tmain = THEME.main

    dl:AddRectFilled(p, P(p.x + w, p.y + BH), C(mix(pal.field, pal.fieldH, h)), 6)
    if s > 0.01 then
        dl:AddRectFilled(p, P(p.x + w, p.y + BH), C(tmain, 0.16 * s), 6)
        dl:AddRectFilled(P(p.x, p.y + 7), P(p.x + 3, p.y + BH - 7), C(tmain, s), 2)
    end

    local by = p.y + (BH - BTN) / 2
    local delX = p.x + w - 6 - BTN
    local loadX = delX - 6 - BTN
    local textRight = loadX - 8

    if active then                                       -- метка активного конфига (в него идёт автосохранение)
        imgui.PushFont(fonts.small)
        local at = u8(tr('active'))
        local bw = imgui.CalcTextSize(at).x
        dl:AddText(P(loadX - 10 - bw, p.y + (BH - 12) / 2), C(tmain, 0.9), at)
        imgui.PopFont()
        textRight = loadX - 10 - bw - 8
    end

    dl:PushClipRect(P(p.x, p.y), P(textRight, p.y + BH), true)
    dl:AddText(P(p.x + 14, p.y + (BH - 15) / 2), C(mix(pal.dim, pal.text, math.max(s, h * 0.6))), u8(name))
    dl:PopClipRect()

    imgui.SetCursorScreenPos(P(loadX, by))
    local load = IconButton('load', 'cfg_load_' .. name, nil, nil, BTN)
    imgui.SetCursorScreenPos(P(delX, by))
    local del = IconButton('delete', 'cfg_del_' .. name, 'Delete', 2.0, BTN)

    imgui.SetCursorScreenPos(p)
    imgui.Dummy(P(w, RH))
    return load, del
end

local function Text(s, col)
    if SRCH.collecting then return end
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(col[1], col[2], col[3], gfx.galpha))
    imgui.TextWrapped(u8(tr(s)))
    imgui.PopStyleColor()
end

-- Строка только для чтения: название слева, значение справа (вкладка Misc -> Debug)
local function InfoRow(label, value)
    if SRCH.collecting then return end
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local s = u8(tostring(value))
    dl:AddText(imgui.ImVec2(p.x, p.y + 2), C(pal.dim), u8(tr(label)))
    dl:AddText(imgui.ImVec2(p.x + w - imgui.CalcTextSize(s).x, p.y + 2), C(pal.text), s)
    imgui.Dummy(imgui.ImVec2(w, 22))
end

-- Журнал (Tools -> Console): строки по цветам: ошибка - красный, успех - зелёный, ввод в консоли - цвет темы.
-- Сам журнал прокручивается вниз, когда появляется новая строка.
local function LogView()
    if SRCH.collecting then return end
    local log = Dev.log
    if #log == 0 then
        Text('Log is empty. Notifications and console output appear here.', pal.dim)
        return
    end
    local tmain = THEME.main
    for _, e in ipairs(log) do
        local col = (e.kind == 'error' and CONST.TOAST_COL.error) or (e.kind == 'success' and CONST.TOAST_COL.success)
            or (e.kind == 'cmd' and tmain) or pal.text
        e.u = e.u or u8(e.t .. '  ' .. e.text)                -- UTF-8 считаем один раз, а не каждый кадр
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(col[1], col[2], col[3], gfx.galpha))
        imgui.TextWrapped(e.u)
        imgui.PopStyleColor()
    end
    if Dev.scroll then
        imgui.SetScrollHereY(1.0)
        Dev.scroll = false
    end
end

-- ----------------------------------------------------------------------------
--  Окно дополнительных настроек: "облачко", которое выезжает из шестерёнки
-- ----------------------------------------------------------------------------
-- действия кнопок окна доп. настроек ({'button', 'Название', 'действие'})
local SETTING_ACTIONS = {
    ev_clear   = function() if Dev.evClear then Dev.evClear() end end,
    ev_window  = function() ui.logOpen = true; ui.popOpen = false end,         -- большое окно лога поверх меню
    ov_pos_edit = function() ui.popOpen = false; if Dev.startPosEdit then Dev.startPosEdit() end end,
    act_pos_edit = function() ui.popOpen = false; if ctl.al then ctl.al.startPosEdit() end end,
    font_folder = function() FNT.openFolder() end,
    font_rescan = function() FNT.poll(true); NotifyOk('Custom fonts found: %d', #FNT.custom) end,
    toast_info = function() Notify('This is a test notification') end,
    toast_ok   = function() NotifyOk('This is a success notification') end,
    toast_err  = function() NotifyErr('This is an error notification') end,
    toast_long = function() Notify('This is a long test notification. It wraps onto several lines, so you can check how the icon and the text look together.') end,
}

function FNT.noteText()
    return trf('Put .ttf / .otf files into this folder - the list updates by itself: %s', FNT.filesDir()) ..
        '\n' .. trf('Custom fonts found: %d', #FNT.custom)
end

local function SettingsBody(spec)
    if spec.fonts and not SRCH.collecting then FNT.poll() end      -- пока окно Fonts открыто, следим за папкой
    for _, it in ipairs(spec.items) do
        local kind = it[1]
        if kind == 'note' then
            if not SRCH.collecting then
                imgui.PushFont(fonts.small)
                imgui.PushTextWrapPos(0)
                imgui.TextColored(imgui.ImVec4(pal.dim[1], pal.dim[2], pal.dim[3], gfx.galpha), u8(type(it[3]) == 'function' and it[3]() or tr(it[3])))
                imgui.PopTextWrapPos()
                imgui.PopFont()
                imgui.Dummy(imgui.ImVec2(1, 4))
            end
        elseif kind == 'check' then
            Checkbox(it[2], B(it[3], it[4]))
        elseif kind == 'slider' then
            Slider(it[2], F(it[3], it[4]), it[5], it[6], it[7], it[8])
        elseif kind == 'combo' then
            local d = it[4]
            if type(d) == 'string' then                  -- по умолчанию выбран вариант с таким названием
                local di = 0
                for i, n in ipairs(it[5]) do
                    if n == d then di = i - 1 break end
                end
                d = di
            end
            local cp = I(it[3], d)
            if #it[5] > 0 and (cp[0] < 0 or cp[0] >= #it[5]) then cp[0] = 0 end   -- сохранённый индекс мог выйти за список
            Combo(it[2], cp, it[5])
        elseif kind == 'words' then
            if ctl.wordsRow then ctl.wordsRow(it[2], it[3]) end
        elseif kind == 'logview' then
            if Dev.drawLogView then Dev.drawLogView() end
        elseif kind == 'button' then
            if Button(it[2], 28) and SETTING_ACTIONS[it[3]] then SETTING_ACTIONS[it[3]]() end
        elseif kind == 'color' then
            local c = it[4]
            ColorRow(it[2], Col(it[3], c[1], c[2], c[3], c[4]))
        elseif kind == 'key' then
            binds[it[3]] = binds[it[3]] or {key = tonumber(ctl.loadedBinds[it[3]]) or 0}
            Keybind(it[2], binds[it[3]])
        end
    end
end

local function DrawPopup(wp)
    local label = ui.popLabel
    local spec = label and SETTINGS[label]
    local t = animTo('pop', (ui.popOpen and spec) and 1 or 0, 14)
    if not spec or t < 0.01 then return end

    local P = imgui.ImVec2
    local TAIL, BW = 8, spec.width or 270                         -- высота хвостика, ширина окна
    local ax, ay = ui.popAx, ui.popAy               -- центр шестерёнки (экранные координаты)
    local ch = ui.popH[label] or 120                -- высота содержимого (замеряется по кадру)
    local fullBH = 50 + ch + 8
    local minX, maxX = wp.x + LAY.SIDE + 8, wp.x + LAY.W - 12
    local bx = clamp(ax - 34, minX, maxX - BW)
    -- место под шестерёнкой и над ней (окно не должно выходить за границы основного окна)
    local spaceDown = (wp.y + LAY.H - 10) - (ay + 12 + TAIL)
    local spaceUp = (ay - 12 - TAIL) - (wp.y + 10)
    local up = fullBH > spaceDown and spaceUp > spaceDown   -- не влезает вниз - открываем вверх, если там места больше
    local BH = math.max(math.min(fullBH, up and spaceUp or spaceDown), 110)
    local scrollable = BH < fullBH - 1                      -- всё равно не влезло - содержимое прокручивается колесом мыши
    local by = up and (ay - 12 - TAIL - BH) or (ay + 12 + TAIL)
    local tx = clamp(ax, bx + 20, bx + BW - 20)
    local e = up and 1 or easeOut(t)                -- вниз окно "вырастает" из шестерёнки
    local bh = BH * e
    local oy = up and by or (by - TAIL)
    local oh = (up and BH or bh) + TAIL

    local tmain = THEME.main
    local al = ui.alpha * t
    gfx.galpha = al
    imgui.SetCursorScreenPos(P(bx, oy))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
    local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    if not ui.popOpen then flags = flags + imgui.WindowFlags.NoInputs end
    imgui.BeginChild('##collapse_pop', P(BW, oh), false, flags)

    local dl = imgui.GetWindowDrawList()
    local bt = up and oy or (oy + TAIL)
    local bb = bt + bh
    local bg = {0.082, 0.088, 0.112}
    dl:AddRectFilled(P(bx, bt), P(bx + BW, bb), C(pal.border), 11)
    dl:AddRectFilled(P(bx + 1, bt + 1), P(bx + BW - 1, bb - 1), C(bg), 10)
    -- хвостик, указывающий на шестерёнку
    if up then
        dl:AddTriangleFilled(P(tx - 8.5, bb - 1), P(tx + 8.5, bb - 1), P(tx, bb + TAIL), C(pal.border))
        dl:AddTriangleFilled(P(tx - 7, bb - 1), P(tx + 7, bb - 1), P(tx, bb + TAIL - 1.2), C(bg))
    else
        dl:AddTriangleFilled(P(tx - 8.5, bt + 1), P(tx + 8.5, bt + 1), P(tx, oy), C(pal.border))
        dl:AddTriangleFilled(P(tx - 7, bt + 1), P(tx + 7, bt + 1), P(tx, oy + 1.2), C(bg))
    end
    -- заголовок
    dl:AddRectFilled(P(bx, bt + 14), P(bx + 3, bt + 30), C(tmain), 2)
    imgui.PushFont(fonts.bold)
    dl:AddText(P(bx + 18, bt + 12), C(pal.text), u8(tr(spec.title)))
    imgui.PopFont()
    dl:AddRectFilled(P(bx + 18, bt + 38), P(bx + BW - 18, bt + 39), C(pal.border))

    -- содержимое
    local innerH = clamp(bb - (bt + 48) - 8, 0, ch)
    if innerH > 2 then
        imgui.SetCursorScreenPos(P(bx + 18, bt + 48))
        local inFlags = flags
        if scrollable then inFlags = ui.popOpen and 0 or imgui.WindowFlags.NoInputs end
        imgui.BeginChild('##collapse_popin', P(BW - 36, innerH), false, inFlags)
        SettingsBody(spec)
        ui.popH[label] = imgui.GetCursorPosY()
        imgui.EndChild()
    end
    imgui.EndChild()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor()
    gfx.galpha = ui.alpha

    -- клик вне окна закрывает его (кроме кликов по самой шестерёнке и по открытым спискам/пикеру)
    if ui.popOpen and imgui.IsMouseClicked(0) and not ui.gearHit and not ui.popBusy then
        local m = imgui.GetIO().MousePos
        local inside = m.x >= bx and m.x <= bx + BW and m.y >= oy and m.y <= oy + oh
        -- клик по самой шестерёнке не считаем "вне окна": её закроет повторное нажатие (иначе окно
        -- закрывалось бы при нажатии кнопки мыши и тут же открывалось снова при отпускании)
        local onGear = math.abs(m.x - ax) <= 11 and math.abs(m.y - ay) <= 11
        if not inside and not onGear then
            ui.popOpen = false
        end
    end
end

-- ----------------------------------------------------------------------------
--  Большое окно с полным логом: открывается кнопкой "Open full log" в окне шестерёнки Debug overlay,
--  рисуется поверх основного окна на затемнённом фоне. Закрывается крестиком или кликом мимо окна.
-- ----------------------------------------------------------------------------
local function DrawLogWindow(wp)
    local t = animTo('logwin', ui.logOpen and 1 or 0, 14)
    if t < 0.01 then return end
    local P = imgui.ImVec2
    local tmain = THEME.main
    local e = easeOut(t)
    local al = ui.alpha * t
    gfx.galpha = al
    local view = I('dev_log_view', 0)[0]

    imgui.SetCursorScreenPos(P(wp.x, wp.y))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
    local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    if not ui.logOpen then flags = flags + imgui.WindowFlags.NoInputs end      -- пока гаснет, окно не ловит мышь
    imgui.BeginChild('##collapse_logwin', P(LAY.W, LAY.H), false, flags)       -- перекрывает весь размер окна: клики не проходят вниз
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(P(wp.x, wp.y), P(wp.x + LAY.W, wp.y + LAY.H), C({0, 0, 0}, 0.6), 11)

    local PW, PH = LAY.W - 80, LAY.H - 72
    local px, py = wp.x + 40, wp.y + 36 + (1 - e) * 16
    local bg = {0.082, 0.088, 0.112}
    dl:AddRectFilled(P(px, py), P(px + PW, py + PH), C(pal.border), 11)
    dl:AddRectFilled(P(px + 1, py + 1), P(px + PW - 1, py + PH - 1), C(bg), 10)

    -- заголовок, количество записей, крестик
    dl:AddRectFilled(P(px, py + 16), P(px + 3, py + 34), C(tmain), 2)
    imgui.PushFont(fonts.bold)
    dl:AddText(P(px + 18, py + 14), C(pal.text), u8(tr('Event and animation log')))
    imgui.PopFont()
    local n = (view == 0 and Dev.evCount()) or (view == 1 and #(Dev.freqSorted())) or (view == 3 and Dev.cefCount()) or #Dev.animLog
    local cnt = u8(string.format(tr('%d entries'), n))
    dl:AddText(P(px + PW - 52 - imgui.CalcTextSize(cnt).x, py + 16), C(pal.dim), cnt)
    imgui.SetCursorScreenPos(P(px + PW - 40, py + 10))
    if imgui.InvisibleButton('##logwin_x', P(28, 28)) then ui.logOpen = false end
    local xh = animTo('logwin_x', imgui.IsItemHovered() and 1 or 0, 14)
    dl:AddRectFilled(P(px + PW - 40, py + 10), P(px + PW - 12, py + 38), C(pal.white, 0.06 * xh), 7)
    local cx, cy = px + PW - 26, py + 24
    local xc = C(mix(pal.dim, pal.text, xh))
    dl:AddLine(P(cx - 5, cy - 5), P(cx + 5, cy + 5), xc, 1.8)
    dl:AddLine(P(cx + 5, cy - 5), P(cx - 5, cy + 5), xc, 1.8)
    dl:AddRectFilled(P(px + 18, py + 48), P(px + PW - 18, py + 49), C(pal.border))

    -- вкладки: ивенты / частые ивенты / анимации (тот же выбор, что и "Log view" в окне шестерёнки)
    local x, cefMid = px + 18, px + 18
    for i, name in ipairs({'Events', 'Frequent events', 'Animations', 'CEF'}) do
        local label = u8(tr(name))
        local sz = imgui.CalcTextSize(label)
        local w = sz.x + 28
        if i == (view == 0 and 1 or 4) then cefMid = x + w / 2 end
        imgui.SetCursorScreenPos(P(x, py + 60))
        if imgui.InvisibleButton('##logwin_tab' .. i, P(w, 28)) then I('dev_log_view', 0)[0] = i - 1 end
        local h = animTo('lwt' .. i, imgui.IsItemHovered() and 1 or 0, 14)
        local sel = animTo('lwts' .. i, (view == i - 1) and 1 or 0, 16)
        dl:AddRectFilled(P(x, py + 60), P(x + w, py + 88), C(mix(pal.field, tmain, sel * 0.22 + h * 0.10)), 6)
        dl:AddRect(P(x, py + 60), P(x + w, py + 88), C(mix(pal.border, tmain, sel * 0.7)), 6)
        dl:AddText(P(x + 14, py + 60 + (28 - sz.y) / 2), C(mix(mix(pal.dim, pal.text, h * 0.7), tmain, sel)), label)
        x = x + w + 8
    end
    if view == 3 or view == 0 then                                                -- CEF: все / от сервера / серверу
        local names, ws = {'All CEF', 'From server', 'To server'}, {}
        for i, name in ipairs(names) do ws[i] = imgui.CalcTextSize(u8(tr(name))).x + 24 end
        x = math.max(px + 18, cefMid - (ws[1] + 6 + ws[2] / 2))        -- центр средней кнопки под вкладкой CEF
        local dkey = view == 3 and 'dev_cef_dir' or 'dev_ev_dir'
        local cur = I(dkey, 0)[0]
        local centers = {}
        for i, name in ipairs(names) do
            local label = u8(tr(name))
            local sz = imgui.CalcTextSize(label)
            local w = sz.x + 24
            imgui.SetCursorScreenPos(P(x, py + 104))
            if imgui.InvisibleButton('##logwin_cef' .. view .. i, P(w, 28)) then I(dkey, 0)[0] = i - 1 end
            local h = animTo('lwcf' .. view .. i, imgui.IsItemHovered() and 1 or 0, 14)
            local sel = animTo('lwcfs' .. view .. i, (cur == i - 1) and 1 or 0, 16)
            dl:AddRectFilled(P(x, py + 104), P(x + w, py + 132), C(mix(pal.field, tmain, sel * 0.22 + h * 0.10)), 14)
            dl:AddRect(P(x, py + 104), P(x + w, py + 132), C(mix(pal.border, tmain, sel * 0.7)), 14)
            dl:AddText(P(x + 12, py + 104 + (28 - sz.y) / 2), C(mix(mix(pal.dim, pal.text, h * 0.7), tmain, sel)), label)
            centers[i] = x + w / 2
            x = x + w + 6
        end
        -- линии от вкладки CEF к каждому пункту: ствол вниз, шина вдоль ряда, отводы к кнопкам
        local busY, lc, hc = py + 96, C(pal.border), C(tmain)
        local x0, x1 = math.min(cefMid, centers[1]), math.max(cefMid, centers[#centers])
        dl:AddLine(P(cefMid, py + 88), P(cefMid, busY), lc, 1.4)
        dl:AddLine(P(x0, busY), P(x1, busY), lc, 1.4)
        for _, cx in ipairs(centers) do dl:AddLine(P(cx, busY), P(cx, py + 104), lc, 1.4) end
        local sx = centers[cur + 1]                                      -- подсветка пути от CEF до выбранного пункта
        if sx then
            dl:AddLine(P(cefMid, py + 88), P(cefMid, busY), hc, 1.8)
            dl:AddLine(P(cefMid, busY), P(sx, busY), hc, 1.8)
            dl:AddLine(P(sx, busY), P(sx, py + 104), hc, 1.8)
        end
    end

    -- кнопки справа от вкладок
    local bwCopy, bwClear = 136, 120
    imgui.SetCursorScreenPos(P(px + PW - 18 - bwClear, py + 60))
    if MiniButton('Clear lists', bwClear, 28) and Dev.evClear then Dev.evClear() end
    imgui.SetCursorScreenPos(P(px + PW - 18 - bwClear - 8 - bwCopy, py + 60))
    if MiniButton('Copy list', bwCopy, 28, true) then Dev.logCopy() end
    imgui.SetCursorScreenPos(P(px + PW - 18 - bwClear - 8 - bwCopy - 8 - 110, py + 60))
    if MiniButton(Dev.pausePtr[0] and 'Resume' or 'Pause', 110, 28, Dev.pausePtr[0]) then Dev.pausePtr[0] = not Dev.pausePtr[0] end

    -- сам список
    local top = (view == 3 or view == 0) and 144 or 100                             -- у вкладки CEF есть второй ряд с фильтром
    imgui.SetCursorScreenPos(P(px + 18, py + top))
    Dev.drawLogView(P(PW - 36, PH - top - 16), not ui.logOpen, 'w')

    imgui.EndChild()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor()
    gfx.galpha = ui.alpha

    -- клик по затемнённому фону (мимо окна лога) закрывает его
    if ui.logOpen and imgui.IsMouseClicked(0) then
        local m = imgui.GetIO().MousePos
        local inWin = m.x >= wp.x and m.x <= wp.x + LAY.W and m.y >= wp.y and m.y <= wp.y + LAY.H
        local inPanel = m.x >= px and m.x <= px + PW and m.y >= py and m.y <= py + PH
        if inWin and not inPanel then ui.logOpen = false end
    end
end

-- ----------------------------------------------------------------------------
--  Иконки под логотипом (как в arztools: история уведомлений, информация о скрипте).
--  Добавить ещё одну: строка в SIDE.BTN + ветка в SIDE.body (панель выезжает справа в области контента).
-- ----------------------------------------------------------------------------
local SIDE, WORDS = {panel = nil, last = 'ntf'}, {lists = {}, order = {}, openId = nil, lastId = nil, hl = nil, refocus = false, buf = nil}
SIDE.BTN = {
    {id = 'ntf',   icon = 'BELL',            fallback = '!', tip = 'Notification history', desc = 'Update log and critical errors of the script.'},
    {id = 'about', icon = 'CIRCLE_QUESTION', fallback = '?', tip = 'Script info',          desc = 'Version, keys, folders and the state of script files.'},
}

-- Запись в историю уведомлений. Туда НЕ попадают обычные тосты, только:
--   SIDE.addHist('update', 'ключ', false, {'строка', ...}, arg) - обновление; по клику открывается список изменений (detail), arg подставляется в %s заголовка
--   SIDE.addHist('error',  'ключ перевода')  - критическая ошибка (на колокольчике загорается красная точка)
function SIDE.addHist(kind, key, silent, detail, arg)
    table.insert(gfx.hist, 1, {kind = kind, text = key, arg = arg, detail = detail, t = os.date('%d.%m %H:%M')})
    if #gfx.hist > 100 then table.remove(gfx.hist) end
    if kind == 'error' and not silent then gfx.histUnread = math.min(gfx.histUnread + 1, 99) end
end

SIDE.RELEASES = {       -- лог обновлений: новые версии дописывайте в конец (в панели новые сверху)
    {version = '1.0', lines = {
        'Added the notification history and script info icons',
        'Added the phrase list editor (base for the anti-flood)',
        'Added custom fonts from the files folder',
    }},
}
for _, r in ipairs(SIDE.RELEASES) do SIDE.addHist('update', 'Update to version %s', true, r.lines, r.version) end

function SIDE.c4(t, a) return imgui.ImVec4(t[1], t[2], t[3], (a or 1) * gfx.galpha) end

function SIDE.title(n) return n.arg and trf(n.text, n.arg) or tr(n.text) end

-- подробности записи (changelog): кнопка Назад, заголовок, строки списком
function SIDE.drawDetail(dl, P, w)
    local n = SIDE.detail
    if MiniButton('Back', 80, 26) then SIDE.detail = nil return end
    imgui.Dummy(P(1, 6))
    imgui.PushTextWrapPos(0)
    imgui.PushFont(fonts.bold)
    imgui.TextColored(SIDE.c4(pal.text), u8(SIDE.title(n)))
    imgui.PopFont()
    imgui.PushFont(fonts.small)
    imgui.TextColored(SIDE.c4(pal.dim), n.t .. '  -  ' .. u8(tr('Changelog')))
    imgui.PopFont()
    imgui.Dummy(P(1, 8))
    for _, line in ipairs(n.detail or {}) do
        local p = imgui.GetCursorScreenPos()
        dl:AddCircleFilled(P(p.x + 6, p.y + 9), 2.5, C(THEME.main), 10)
        imgui.SetCursorScreenPos(P(p.x + 18, p.y))
        imgui.TextColored(SIDE.c4(pal.text), u8(tr(line)))
        imgui.Dummy(P(1, 5))
    end
    imgui.PopTextWrapPos()
end

function SIDE.drawButtons(dl, wp, V, tmain)
    local P = imgui.ImVec2
    local bs, gap, x0, y0 = 26, 6, 20, 62
    for i, b in ipairs(SIDE.BTN) do
        local x = x0 + (i - 1) * (bs + gap)
        imgui.SetCursorScreenPos(V(x, y0))
        if imgui.InvisibleButton('##sidebtn' .. b.id, P(bs, bs)) then
            SIDE.panel = (SIDE.panel ~= b.id) and b.id or nil
            if SIDE.panel then SIDE.last = b.id; WORDS.openId = nil; ui.popOpen = false; if SOFT.adm then SOFT.adm.open = false end end
        end
        Hint(b.tip, b.desc)
        local h = animTo('sideh' .. b.id, imgui.IsItemHovered() and 1 or 0, 14)
        local sel = animTo('sides' .. b.id, SIDE.panel == b.id and 1 or 0, 14)
        dl:AddRectFilled(V(x, y0), V(x + bs, y0 + bs), C(mix(pal.panel, tmain, sel * 0.25), 0.55 + 0.45 * math.max(h, sel)), 7)
        local col = C(mix(mix(pal.dim, pal.text, h * 0.8), tmain, sel))
        if not FNT.drawIcon(dl, b.icon, 14, wp.x + x + bs / 2, wp.y + y0 + bs / 2, col) then
            local s = b.fallback
            local sz = imgui.CalcTextSize(s)
            dl:AddText(V(x + (bs - sz.x) / 2, y0 + (bs - sz.y) / 2), col, s)
        end
        if b.id == 'ntf' and gfx.histUnread > 0 then           -- красная точка: есть непрочитанные
            dl:AddCircleFilled(V(x + bs - 5, y0 + 5), 3.5, C({0.95, 0.32, 0.32}), 10)
        end
    end
end

function SIDE.uptime()
    local s = math.floor(os.clock() - Dev.start)
    return string.format('%d:%02d:%02d', math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
end

function SIDE.aboutRows()
    local scr, author = thisScript(), 'Claude'
    pcall(function() author = (scr.authors and scr.authors[1]) or author end)
    return {
        {'Version', tostring(scr.version or '1.0')},
        {'Author', tostring(author)},
        {'Menu key', ctl.bindName(binds.menu)},
        {'Menu command', '/' .. tostring(CMD.cmdName)},
        {'Active config', tostring(CFG.activeCfg or 'default')},
        {'Custom fonts', tostring(#FNT.custom)},
        {'Icon font', FNT.faPath() and tr('Loaded') or tr('Missing')},
        {'Uptime', SIDE.uptime()},
    }
end

-- все клавиши скрипта: {название, клавиша}; новые бинды добавлять сюда
function SIDE.bindRows()
    local function row(label, b, tabName, sub, hl, pop, prog)
        return {label, b and ctl.bindName(b) or tr('None'), tabName = tabName, sub = sub, hl = hl, pop = pop, prog = prog}
    end
    return {
        row('Menu key', binds.menu, 'Settings', 1, 'Menu key'),
        row('Far chat: toggle key', binds.far_toggle, 'Software', 1, 'Toggle key', nil, 'farchat'),
        row('Fly Car: flight key', binds.flycar_key, 'Main', 3, 'Fly Car', 'Fly Car'),
        row('Car flip upright', binds.uf_k_flip, 'Main', 3, 'Car flip upright', 'Car flip upright'),
        row('Car jump', binds.uf_k_jump, 'Main', 3, 'Car jump', 'Car jump'),
        row('Fast Exit Vehicle', binds.uf_k_exit, 'Main', 3, 'Fast Exit Vehicle', 'Fast Exit Vehicle'),
        row('Quick braking (ARZ)', binds.mm_limit_key, 'Main', 3, 'Quick braking (ARZ)', 'Quick braking (ARZ)'),
        row('Auto balloon collection', binds.mm_balloon_key, 'Main', 1, 'Auto balloon collection', 'Auto balloon collection'),
        row('Captcha trainer: start key', binds.cap_key, 'Software', 1, 'Start key', nil, 'captcha'),
        row('180 degree turn', binds.uf_k_turn, 'Main', 3, '180 degree turn', '180 degree turn'),
        row('GM Car', binds.uf_gmcar_key, 'Main', 3, 'GM Car', 'GM Car'),
        row('Auto run: bike key', binds.ut_bike_key, 'Main', 1, 'Auto run and ride keys', 'Auto run and ride keys'),
        row('Auto run: run key', binds.ut_run_key, 'Main', 1, 'Auto run and ride keys', 'Auto run and ride keys'),
        row('Radar IDs', binds.rdr_key, 'Main', 1, 'Radar IDs', 'Radar IDs'),
        row('Godmode', binds.uf_gm_key, 'Main', 2, 'Godmode', 'Godmode'),
        row('Vehicle WH', binds.uf_vwh_key, 'Main', 3, 'Vehicle WH', 'Vehicle WH'),
        row('Chat calculator: copy key', binds.calc_copy, 'Main', 1, 'Chat calculator', 'Chat calculator'),
        row('Reset animations by key', binds.ut_sbivx, 'Main', 2, 'Reset animations by key', 'Reset animations by key'),
        row('Wallhack', binds.ut_wh, 'Main', 2, 'Wallhack', 'Wallhack'),
        row('AirBrake', binds.ut_air, 'Main', 2, 'AirBrake', 'AirBrake'),
        row('CamHack: activation', binds.ut_cam_start, 'Main', 2, 'CamHack', 'CamHack'),
        row('CamHack: deactivation', binds.ut_cam_stop, 'Main', 2, 'CamHack', 'CamHack'),
        row('CamHack: speed up', binds.ut_cam_up, 'Main', 2, 'CamHack', 'CamHack'),
        row('CamHack: speed down', binds.ut_cam_dn, 'Main', 2, 'CamHack', 'CamHack'),
    }
end

-- переход к настройке бинда: нужная вкладка и подвкладка, подсветка пункта и открытие его меню шестерёнки
function SIDE.gotoBind(r)
    local tab
    for i, t in ipairs(tabs) do if t.name == r.tabName then tab = i end end
    if not tab then return end
    ffi.fill(ui.search, ffi.sizeof(ui.search))                  -- выйти из поиска, если он был открыт
    ui.tab = tab
    ui.sub[tab] = r.sub
    ui.contentT = 0
    ui.hl = {label = r.hl, t0 = os.clock(), prog = r.prog}
    ui.popReq = r.pop
    SIDE.panel, SIDE.showBinds = nil, false
end

-- все команды чата, которые регистрирует скрипт: {название, команда}; пустые (отключённые) не показываются
function SIDE.cmdRows()
    local rows = {{'Menu command', '/' .. tostring(CMD.cmdName)}}
    local cm = ctl.cm
    if cm then
        local labels = {cm_cmd_mark = 'Marker command', cm_cmd_chp = 'Checkpoint command', cm_cmd_stop = 'Cancel command'}
        local lines = {}                                  -- команды телепорта - одним блоком под одним заголовком
        for _, key in ipairs(cm.KEYS) do
            if cm.cmds[key] ~= '' then lines[#lines + 1] = '/' .. cm.cmds[key] .. '  (' .. tr(labels[key]) .. ')' end
        end
        if #lines > 0 then rows[#rows + 1] = {'Coord Master', table.concat(lines, '\n')} end
    end
    rows[#rows + 1] = {'Reconnect after N seconds, or with a new nickname', '/rec [sec]  |  /rec [Nick_Name]'}
    rows[#rows + 1] = {'Get into a vehicle as the driver', '/seat [ID]'}
    rows[#rows + 1] = {'Get into a vehicle as a passenger', '/pseat [ID]'}
    rows[#rows + 1] = {'Set a checkpoint and a map marker', '/setmarker X, Y, Z'}
    return rows
end

function SIDE.body(dl, P, id, w, h)
    local tmain = THEME.main
    if id == 'ntf' then
        if SIDE.detail then SIDE.drawDetail(dl, P, w) return end
        local list = gfx.hist
        if #list == 0 then
            local s = u8(tr('No notifications yet'))
            local sz = imgui.CalcTextSize(s)
            local p = imgui.GetCursorScreenPos()
            dl:AddText(P(p.x + (w - sz.x) / 2, p.y + h / 2 - sz.y), C(pal.dim), s)
            return
        end
        imgui.PushTextWrapPos(0)
        for i, n in ipairs(list) do
            local col = CONST.TOAST_COL[n.kind == 'update' and 'success' or 'error'] or CONST.TOAST_COL.info
            local p0 = imgui.GetCursorScreenPos()
            local aw = imgui.GetContentRegionAvail().x          -- вся ширина области списка
            dl:AddCircleFilled(P(p0.x + 6, p0.y + 9), 3.5, C(col), 10)
            imgui.SetCursorScreenPos(P(p0.x + 18, p0.y))
            imgui.PushFont(fonts.small)
            imgui.TextColored(SIDE.c4(pal.dim), n.t .. '  ' .. u8(tr(n.kind == 'update' and 'Update' or 'Critical error')))
            imgui.PopFont()
            imgui.SetCursorScreenPos(P(p0.x + 18, imgui.GetCursorScreenPos().y))
            imgui.TextColored(SIDE.c4(pal.text), u8(SIDE.title(n)))
            local endY = imgui.GetCursorScreenPos().y
            if n.detail then                                    -- есть changelog: вся запись кликабельна
                imgui.SetCursorScreenPos(p0)
                local clicked = imgui.InvisibleButton('##hist' .. i, P(aw, endY - p0.y + 2))
                local hh = animTo('hist' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                dl:AddRectFilled(P(p0.x - 4, p0.y - 3), P(p0.x + aw, endY + 3), C(pal.white, 0.05 * hh), 6)
                local cx, cy = p0.x + aw - 14, p0.y + (endY - p0.y) / 2
                local cc = C(mix(pal.dim, tmain, hh))
                dl:AddLine(P(cx - 2, cy - 4), P(cx + 2, cy), cc, 1.6)
                dl:AddLine(P(cx + 2, cy), P(cx - 2, cy + 4), cc, 1.6)
                if clicked then SIDE.detail = n end
                imgui.SetCursorScreenPos(P(p0.x, endY))
            end
            imgui.Dummy(P(1, 8))
        end
        imgui.PopTextWrapPos()
    elseif SIDE.showCmds then
        if MiniButton('Back', 80, 26) then SIDE.showCmds = false return end
        imgui.Dummy(P(1, 8))
        imgui.PushTextWrapPos(0)
        for _, r in ipairs(SIDE.cmdRows()) do
            imgui.PushFont(fonts.small)
            imgui.TextColored(SIDE.c4(pal.dim), u8(tr(r[1])))
            imgui.PopFont()
            imgui.TextColored(SIDE.c4(pal.text), u8(r[2]))
            imgui.Dummy(P(1, 7))
        end
        imgui.PopTextWrapPos()
    elseif SIDE.showBinds then
        if MiniButton('Back', 80, 26) then SIDE.showBinds = false return end
        imgui.Dummy(P(1, 8))
        for i, r in ipairs(SIDE.bindRows()) do                   -- строка = кнопка: клик ведёт к настройке этого бинда
            local p = imgui.GetCursorScreenPos()
            local rw = imgui.GetContentRegionAvail().x
            local pressed = imgui.InvisibleButton('##bindrow' .. i, P(rw, 42))
            local hv = animTo('bindrow' .. i, imgui.IsItemHovered() and 1 or 0, 14)
            dl:AddRectFilled(p, P(p.x + rw, p.y + 38), C(mix(pal.field, pal.fieldH, hv)), 7)
            dl:AddRectFilled(P(p.x, p.y + 9), P(p.x + 3, p.y + 29), C(tmain, hv), 2)
            imgui.PushFont(fonts.small)
            dl:AddText(P(p.x + 12, p.y + 4), C(pal.dim), u8(tr(r[1])))
            imgui.PopFont()
            dl:AddText(P(p.x + 12, p.y + 19), C(pal.text), u8(r[2]))
            dl:AddLine(P(p.x + rw - 20, p.y + 14), P(p.x + rw - 15, p.y + 19), C(mix(pal.dim, tmain, hv)), 1.6)
            dl:AddLine(P(p.x + rw - 15, p.y + 19), P(p.x + rw - 20, p.y + 24), C(mix(pal.dim, tmain, hv)), 1.6)
            if pressed then SIDE.gotoBind(r) return end
        end
    else
        imgui.PushTextWrapPos(0)
        for _, r in ipairs(SIDE.aboutRows()) do
            imgui.PushFont(fonts.small)
            imgui.TextColored(SIDE.c4(pal.dim), u8(tr(r[1])))
            imgui.PopFont()
            imgui.TextColored(SIDE.c4(pal.text), u8(r[2]))
            imgui.Dummy(P(1, 7))
        end
        if MiniButton('Key binds', w, 30) then SIDE.showBinds = true end
        imgui.Dummy(P(1, 4))
        if MiniButton('Commands', w, 30) then SIDE.showCmds = true end
        imgui.PopTextWrapPos()
    end
end

function SIDE.draw(wp)
    local P = imgui.ImVec2
    local t = animTo('sidepanel', SIDE.panel and 1 or 0, 14)
    if not SIDE.panel and t < 0.05 then SIDE.detail, SIDE.showBinds, SIDE.showCmds = nil, false, false end
    if t < 0.01 then return end
    local id = SIDE.panel or SIDE.last
    local tmain, e = THEME.main, easeOut(t)
    local al = ui.alpha * t
    gfx.galpha = al
    if id == 'ntf' then gfx.histUnread = 0 end                 -- панель открыта - всё прочитано

    local cx0 = wp.x + LAY.SIDE + 1                            -- прозрачный экран на всю область контента: клики не проходят вниз
    imgui.SetCursorScreenPos(P(cx0, wp.y))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
    local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    if not SIDE.panel then flags = flags + imgui.WindowFlags.NoInputs end
    imgui.BeginChild('##collapse_sidepanel', P(LAY.W - LAY.SIDE - 1, LAY.H), false, flags)
    local dl = imgui.GetWindowDrawList()

    local PW, PH = 360, LAY.H - 24
    local px, py = wp.x + LAY.W - PW - 12 + (1 - e) * 40, wp.y + 12
    dl:AddRectFilled(P(px - 6, py - 6), P(px + PW + 6, py + PH + 6), C({0, 0, 0}, 0.28), 14)       -- мягкая тень
    dl:AddRectFilled(P(px, py), P(px + PW, py + PH), C(pal.border), 11)
    dl:AddRectFilled(P(px + 1, py + 1), P(px + PW - 1, py + PH - 1), C({0.082, 0.088, 0.112}), 10)

    local title
    for _, b in ipairs(SIDE.BTN) do if b.id == id then title = b.tip end end
    dl:AddRectFilled(P(px + 16, py + 16), P(px + 19, py + 34), C(tmain), 2)
    imgui.PushFont(fonts.bold)
    dl:AddText(P(px + 30, py + 14), C(pal.text), u8(tr(title or '')))
    imgui.PopFont()
    imgui.SetCursorScreenPos(P(px + PW - 40, py + 10))
    if imgui.InvisibleButton('##sidepanel_x', P(28, 28)) then SIDE.panel = nil end
    local xh = animTo('sidepanel_x', imgui.IsItemHovered() and 1 or 0, 14)
    dl:AddRectFilled(P(px + PW - 40, py + 10), P(px + PW - 12, py + 38), C(pal.white, 0.06 * xh), 7)
    local xc, cy2 = C(mix(pal.dim, pal.text, xh)), py + 24
    local cx2 = px + PW - 26
    dl:AddLine(P(cx2 - 5, cy2 - 5), P(cx2 + 5, cy2 + 5), xc, 1.8)
    dl:AddLine(P(cx2 + 5, cy2 - 5), P(cx2 - 5, cy2 + 5), xc, 1.8)
    dl:AddRectFilled(P(px + 16, py + 48), P(px + PW - 16, py + 49), C(pal.border))

    imgui.SetCursorScreenPos(P(px + 16, py + 58))
    local bw, bh = PW - 32, PH - 58 - 14
    imgui.BeginChild('##sidepanel_body', P(bw, bh), false, id == 'about' and imgui.WindowFlags.NoScrollbar or 0)
    SIDE.body(imgui.GetWindowDrawList(), P, id, bw, bh)
    imgui.EndChild()

    imgui.EndChild()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor()
    gfx.galpha = ui.alpha

    -- клик мимо панели закрывает её (клик по самим иконкам сайдбара обрабатывают они)
    if SIDE.panel and imgui.IsMouseClicked(0) then
        local m = imgui.GetIO().MousePos
        local inContent = m.x >= cx0 and m.x <= wp.x + LAY.W and m.y >= wp.y and m.y <= wp.y + LAY.H
        local inPanel = m.x >= px and m.x <= px + PW and m.y >= py and m.y <= py + PH
        if inContent and not inPanel then SIDE.panel = nil end
    end
end

-- ----------------------------------------------------------------------------
--  Редактор списков слов (как \"Нецензурные выражения - N фраз\" в arztools).
--  WORDS.register(id, заголовок, иконка) - новый список, он сразу получает вкладку в редакторе.
--  WORDS.row('Название', id) - строка в панели: подпись и справа ссылка \"N фраз\", по клику открывается редактор.
--  WORDS.get(id) - сохранённые фразы (cp1251, нижний регистр) для логики; WORDS.has(id, текст) - есть ли такая.
--  Хранится в moonloader\config\xMercy\Collapse\files\words_<id>.txt, по фразе на строку.
-- ----------------------------------------------------------------------------
WORDS.MAX_LEN = 80

function WORDS.register(id, title, icon)
    if not WORDS.lists[id] then
        WORDS.lists[id] = {id = id, title = title, icon = icon, items = {}, loaded = false}
        WORDS.order[#WORDS.order + 1] = id
    end
end

function WORDS.path(id) return FNT.filesDir() .. '\\words_' .. id .. '.txt' end

function WORDS.get(id)
    local L = WORDS.lists[id]
    if not L then return {} end
    if not L.loaded then
        L.loaded, L.items = true, {}
        local f = io.open(WORDS.path(id), 'rb')
        if f then
            for line in f:lines() do
                line = trim((line:gsub('\r', '')))
                if line ~= '' then L.items[#L.items + 1] = line end
            end
            f:close()
        end
    end
    return L.items
end

function WORDS.save(id)
    local L = WORDS.lists[id]
    if not L then return end
    pcall(FNT.ensureFilesDir)
    local f = io.open(WORDS.path(id), 'wb')
    if f then f:write(table.concat(L.items, '\n')); f:close() end
end

function WORDS.has(id, text)
    text = lower(trim(text or ''))
    for i, s in ipairs(WORDS.get(id)) do
        if s == text then return i end
    end
    return nil
end

function WORDS.add(id)
    if not WORDS.buf then return end
    local ok, raw = pcall(function() return u8:decode(ffi.string(WORDS.buf)) end)
    local text = ok and lower(trim(raw)) or ''
    if text == '' then return end
    text = text:sub(1, WORDS.MAX_LEN)
    local at = WORDS.has(id, text)
    if at then
        WORDS.hl = {id = id, idx = at, t0 = os.clock()}
        Notify(WORDS.lists[id].solo and 'Such a nickname already exists!' or 'Such a phrase already exists!')
    else
        table.insert(WORDS.get(id), 1, text)
        WORDS.save(id)
        WORDS.hl = {id = id, idx = 1, t0 = os.clock()}
        ffi.copy(WORDS.buf, '')
    end
end

function WORDS.countText(n, id)
    local Lt = id and WORDS.lists[id]
    if Lt and Lt.toggle then                      -- список-переключатель: сколько пунктов включено
        local on = 0
        for _, d in ipairs(Lt.toggle) do
            if B(d.key, d.default)[0] then on = on + 1 end
        end
        return string.format(tr('%d of %d'), on, #Lt.toggle)
    end
    local nick = id and WORDS.lists[id] and WORDS.lists[id].solo
    if i18n.curLang == 'ru' then
        local m10, m100 = n % 10, n % 100
        local w = nick and 'ников' or 'фраз'
        if m10 == 1 and m100 ~= 11 then w = nick and 'ник' or 'фраза'
        elseif m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then w = nick and 'ника' or 'фразы' end
        return n .. ' ' .. w
    end
    if nick then return n .. (n == 1 and ' nickname' or ' nicknames') end
    return n .. (n == 1 and ' phrase' or ' phrases')
end

function WORDS.show(id)
    if not WORDS.buf then WORDS.buf = imgui.new.char[256]() end
    ffi.copy(WORDS.buf, '')
    WORDS.openId, WORDS.lastId, WORDS.hl, WORDS.refocus = id, id, nil, true
    SIDE.panel, ui.popOpen = nil, false
end

-- строка в панели: подпись слева, справа плашка \"N фраз\"
function WORDS.row(label, id, hint)
    if SRCH.collecting then Reg(label, 'Words') return end
    WORDS.register(id, label, 'LIST_UL')
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    Highlight(label, p, w, 26)
    local txt = u8(WORDS.countText(#WORDS.get(id), id))
    local tw = imgui.CalcTextSize(txt).x
    local bw = tw + 22
    gfx.hintIcon(label, hint, p.x + imgui.CalcTextSize(u8(tr(label))).x + 8, p.y + 4, false, p.x + w - bw - 6)
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + w - bw, p.y + 2))
    local clicked = imgui.InvisibleButton('##wordsrow' .. id, imgui.ImVec2(bw, 22))
    local h = animTo('wordsrow' .. id, imgui.IsItemHovered() and 1 or 0, 14)
    local tmain = THEME.main
    dl:AddRectFilled(imgui.ImVec2(p.x + w - bw, p.y + 2), imgui.ImVec2(p.x + w, p.y + 24), C(mix(pal.field, tmain, h * 0.25)), 6)
    dl:AddText(imgui.ImVec2(p.x + w - bw + 11, p.y + 4), C(mix(pal.dim, tmain, 0.4 + 0.6 * h)), txt)
    dl:AddText(imgui.ImVec2(p.x, p.y + 4), C(mix(pal.dim, pal.text, h)), u8(tr(label)))
    imgui.SetCursorScreenPos(p)
    imgui.Dummy(imgui.ImVec2(w, 28))
    if clicked then WORDS.show(id) end
end

-- вкладки окна: у обычных списков общий набор, "solo"-список (игнор упоминаний) показывается один
function WORDS.tabs(cur)
    local out, solo = {}, WORDS.lists[cur] and WORDS.lists[cur].solo
    for _, id in ipairs(WORDS.order) do
        if id == cur or (not solo and not WORDS.lists[id].solo) then out[#out + 1] = id end
    end
    return out
end

function WORDS.draw(wp)
    local P = imgui.ImVec2
    local t = animTo('wordswin', WORDS.openId and 1 or 0, 14)
    if t < 0.01 then return end
    local cur = WORDS.openId or WORDS.lastId
    local L = WORDS.lists[cur]
    if not L then return end
    local tmain, e = THEME.main, easeOut(t)
    local al = ui.alpha * t
    gfx.galpha = al

    imgui.SetCursorScreenPos(P(wp.x, wp.y))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
    local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    if not WORDS.openId then flags = flags + imgui.WindowFlags.NoInputs end
    imgui.BeginChild('##collapse_wordswin', P(LAY.W, LAY.H), false, flags)
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(P(wp.x, wp.y), P(wp.x + LAY.W, wp.y + LAY.H), C({0, 0, 0}, 0.6), 11)

    local PW, PH = 560, 400
    local px, py = wp.x + (LAY.W - PW) / 2, wp.y + (LAY.H - PH) / 2 + (1 - e) * 16
    dl:AddRectFilled(P(px, py), P(px + PW, py + PH), C(pal.border), 11)
    dl:AddRectFilled(P(px + 1, py + 1), P(px + PW - 1, py + PH - 1), C({0.082, 0.088, 0.112}), 10)

    -- заголовок, счётчик, крестик
    local items = WORDS.get(cur)
    dl:AddRectFilled(P(px + 16, py + 16), P(px + 19, py + 34), C(tmain), 2)
    imgui.PushFont(fonts.bold)
    dl:AddText(P(px + 30, py + 14), C(pal.text), u8(tr(L.title)))
    imgui.PopFont()
    local cnt = u8(WORDS.countText(#items, cur))
    dl:AddText(P(px + PW - 52 - imgui.CalcTextSize(cnt).x, py + 16), C(pal.dim), cnt)
    imgui.SetCursorScreenPos(P(px + PW - 40, py + 10))
    if imgui.InvisibleButton('##wordswin_x', P(28, 28)) then WORDS.openId = nil end
    local xh = animTo('wordswin_x', imgui.IsItemHovered() and 1 or 0, 14)
    dl:AddRectFilled(P(px + PW - 40, py + 10), P(px + PW - 12, py + 38), C(pal.white, 0.06 * xh), 7)
    local xc, cy2, cx2 = C(mix(pal.dim, pal.text, xh)), py + 24, px + PW - 26
    dl:AddLine(P(cx2 - 5, cy2 - 5), P(cx2 + 5, cy2 + 5), xc, 1.8)
    dl:AddLine(P(cx2 + 5, cy2 - 5), P(cx2 - 5, cy2 + 5), xc, 1.8)
    dl:AddRectFilled(P(px + 16, py + 48), P(px + PW - 16, py + 49), C(pal.border))

    -- вкладки: по одной на каждый список
    local x = px + 16
    for _, lid in ipairs(WORDS.tabs(cur)) do
        local l = WORDS.lists[lid]
        local label = u8(tr(l.title))
        local sz = imgui.CalcTextSize(label)
        local tw = sz.x + 42
        imgui.SetCursorScreenPos(P(x, py + 58))
        if imgui.InvisibleButton('##wordstab' .. lid, P(tw, 28)) and WORDS.openId ~= lid then
            WORDS.openId, WORDS.lastId, WORDS.hl = lid, lid, nil
            ffi.copy(WORDS.buf, '')
        end
        local h = animTo('wtabh' .. lid, imgui.IsItemHovered() and 1 or 0, 14)
        local sel = animTo('wtabs' .. lid, (cur == lid) and 1 or 0, 16)
        dl:AddRectFilled(P(x, py + 58), P(x + tw, py + 86), C(mix(pal.field, tmain, sel * 0.22 + h * 0.10)), 6)
        dl:AddRect(P(x, py + 58), P(x + tw, py + 86), C(mix(pal.border, tmain, sel * 0.7)), 6)
        local col = C(mix(mix(pal.dim, pal.text, h * 0.7), tmain, sel))
        FNT.drawIcon(dl, l.icon or 'LIST_UL', 14, x + 18, py + 72, col)
        dl:AddText(P(x + 32, py + 58 + (28 - sz.y) / 2), col, label)
        x = x + tw + 8
    end

    -- список фраз
    local lx, ly, lw, lh = px + 16, py + 96, PW - 32, PH - 96 - 64
    dl:AddRectFilled(P(lx, ly), P(lx + lw, ly + lh), C(pal.field, 0.55), 8)
    imgui.SetCursorScreenPos(P(lx + 8, ly + 8))
    imgui.BeginChild('##words_list', P(lw - 16, lh - 16), false)
    local ldl = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()
    local availW = imgui.GetContentRegionAvail().x
    local remove
    if L.toggle then                                                     -- пункты-переключатели: клик включает / выключает
        local cx, cy, rowH, gap = 0, 0, 30, 8
        local th = imgui.GetTextLineHeight()
        for i, d in ipairs(L.toggle) do
            local txt = u8(tr(d.label))
            local cw = imgui.CalcTextSize(txt).x + 46
            if cx > 0 and cx + cw > availW then cx, cy = 0, cy + rowH + gap end
            local x0, y0 = origin.x + cx, origin.y + cy
            local p = B(d.key, d.default)
            imgui.SetCursorScreenPos(P(x0, y0))
            if imgui.InvisibleButton('##wt' .. cur .. i, P(cw, rowH)) then p[0] = not p[0] end
            local hh = animTo('wt' .. cur .. i, imgui.IsItemHovered() and 1 or 0, 14)
            local on = animTo('wton' .. cur .. i, p[0] and 1 or 0, 14)
            ldl:AddRectFilled(P(x0, y0), P(x0 + cw, y0 + rowH), C(mix(pal.field, tmain, on * 0.30 + hh * 0.10)), 7)
            ldl:AddRect(P(x0, y0), P(x0 + cw, y0 + rowH), C(mix(pal.border, tmain, on * 0.8)), 7)
            ldl:AddCircleFilled(P(x0 + 16, y0 + rowH / 2), 6, C(mix(pal.track, tmain, on)), 16)
            ldl:AddText(P(x0 + 32, y0 + (rowH - th) / 2), C(mix(pal.dim, pal.text, on)), txt)
            cx = cx + cw + gap
        end
        imgui.SetCursorScreenPos(P(origin.x, origin.y + cy + rowH))
        imgui.Dummy(P(1, 1))
    elseif #items == 0 then
        local s = u8(tr(L.solo and 'No nicknames added' or 'No phrases added'))
        local sz = imgui.CalcTextSize(s)
        ldl:AddText(P(origin.x + (availW - sz.x) / 2, origin.y + (lh - 16) / 2 - sz.y), C(pal.dim), s)
    else
        local cx, cy, rowH, gap = 0, 0, 28, 6
        local th = imgui.GetTextLineHeight()
        for i, s in ipairs(items) do
            local txt = u8(s)
            local tw = imgui.CalcTextSize(txt).x
            local maxW = availW - 44
            if tw > maxW then                                            -- длинную фразу сокращаем многоточием
                local cut = s
                while #cut > 1 and imgui.CalcTextSize(u8(cut .. '..')).x > maxW do cut = cut:sub(1, -2) end
                txt = u8(cut .. '..')
                tw = imgui.CalcTextSize(txt).x
            end
            local cw = tw + 40
            if cx > 0 and cx + cw > availW then cx, cy = 0, cy + rowH + gap end
            local x0, y0 = origin.x + cx, origin.y + cy
            local hlA = 0
            if WORDS.hl and WORDS.hl.id == cur and WORDS.hl.idx == i then      -- новая / уже существующая фраза мигает
                local age = os.clock() - WORDS.hl.t0
                if age < 1.4 then hlA = (1 - age / 1.4) * (0.5 + 0.5 * math.sin(age * 14)) else WORDS.hl = nil end
            end
            ldl:AddRectFilled(P(x0, y0), P(x0 + cw, y0 + rowH), C(mix(pal.field, tmain, hlA * 0.6)), 7)
            imgui.SetCursorScreenPos(P(x0 + 4, y0 + 3))
            if imgui.InvisibleButton('##wx' .. i, P(22, 22)) then remove = i end
            local hh = animTo('wx' .. cur .. i, imgui.IsItemHovered() and 1 or 0, 14)
            local xcol = C(mix(pal.dim, CONST.BTN_DANGER, hh))
            ldl:AddLine(P(x0 + 11, y0 + 10), P(x0 + 19, y0 + 18), xcol, 1.6)
            ldl:AddLine(P(x0 + 19, y0 + 10), P(x0 + 11, y0 + 18), xcol, 1.6)
            ldl:AddText(P(x0 + 30, y0 + (rowH - th) / 2), C(pal.text), txt)
            cx = cx + cw + gap
        end
        imgui.SetCursorScreenPos(P(origin.x, origin.y + cy + rowH))
        imgui.Dummy(P(1, 1))
    end
    imgui.EndChild()
    if remove then
        table.remove(items, remove)
        WORDS.save(cur)
    end

    -- ввод новой фразы
    if not L.toggle then                                                 -- у списков-переключателей поля ввода нет
    local iy = py + PH - 50
    imgui.SetCursorScreenPos(P(px + 16, iy))
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(10, 7))
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 7)
    imgui.SetNextItemWidth(PW - 32 - 108)
    if WORDS.refocus and WORDS.openId then imgui.SetKeyboardFocusHere(); WORDS.refocus = false end
    local entered = imgui.InputText('##words_input', WORDS.buf, ffi.sizeof(WORDS.buf), imgui.InputTextFlags.EnterReturnsTrue)
    imgui.PopStyleVar(2)
    if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
    if ffi.string(WORDS.buf) == '' then
        dl:AddText(P(px + 26, iy + 8), C(pal.dim, 0.75), u8(tr(L.solo and 'Type a nickname here to add it' or 'Type a phrase here to add it')))
    end
    imgui.SetCursorScreenPos(P(px + PW - 16 - 100, iy))
    if MiniButton('Add', 100, 34, true) then entered = true end
    if entered and WORDS.openId then
        WORDS.add(cur)
        WORDS.refocus = true
    end
    end

    imgui.EndChild()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor()
    gfx.galpha = ui.alpha

    if WORDS.openId and imgui.IsMouseClicked(0) then                    -- клик по затемнению закрывает редактор
        local m = imgui.GetIO().MousePos
        local inWin = m.x >= wp.x and m.x <= wp.x + LAY.W and m.y >= wp.y and m.y <= wp.y + LAY.H
        local inPanel = m.x >= px and m.x <= px + PW and m.y >= py and m.y <= py + PH
        if inWin and not inPanel then WORDS.openId = nil end
    end
end

WORDS.register('ar_situations', 'Auto reconnect situations', 'ARROWS_ROTATE')
WORDS.lists.ar_situations.solo = true
WORDS.lists.ar_situations.toggle = {
    {key = 'ar_closed',   default = true,  label = 'Server closed the connection'},
    {key = 'ar_lost',     default = true,  label = 'Connection lost'},
    {key = 'ar_rejected', default = true,  label = 'Connection rejected (server full)'},
    {key = 'ar_failed',   default = false, label = 'Connection attempt failed'},
    {key = 'ar_password', default = false, label = 'Wrong password'},
}
ctl.wordsRow = function(label, id) WORDS.row(label, id) end        -- для строк "words" в окне доп. настроек (оно определено раньше WORDS)
WORDS.register('antiflood', 'Anti-flood phrases', 'FILTER')
WORDS.register('ignore', 'Ignored phrases', 'BAN')
WORDS.register('mention_ign', 'Mention ignore', 'BAN'); WORDS.lists.mention_ign.solo = true      -- ники, чьи упоминания не показывать

-- ----------------------------------------------------------------------------
--  Панель (карточка с заголовком)
-- ----------------------------------------------------------------------------
local function Panel(title, x, y, w, h, body, skipCollect, scroll, headerAction, titleShift)
    if SRCH.collecting then
        if not skipCollect then SRCH.collecting.panel = title; body() end
        return
    end
    local sp = imgui.ImVec2(ui.cpos.x + x, ui.cpos.y + y + ui.offY)
    local dl = imgui.GetWindowDrawList()
    local tmain = THEME.main
    dl:AddRectFilled(sp, imgui.ImVec2(sp.x + w, sp.y + h), C(pal.border), 9)
    dl:AddRectFilled(imgui.ImVec2(sp.x + 1, sp.y + 1), imgui.ImVec2(sp.x + w - 1, sp.y + h - 1), C(pal.panel), 8)
    dl:AddRectFilled(imgui.ImVec2(sp.x, sp.y + 12), imgui.ImVec2(sp.x + 3, sp.y + 28), C(tmain), 2)
    imgui.PushFont(fonts.bold)
    dl:AddText(imgui.ImVec2(sp.x + 16 + (titleShift or 0), sp.y + 11), C(pal.text), u8(tr(title)))   -- titleShift: место под кнопку слева от названия
    imgui.PopFont()
    if headerAction then
        imgui.SetCursorScreenPos(imgui.ImVec2(sp.x + w - 42, sp.y + 7))
        headerAction()
    end
    dl:AddRectFilled(imgui.ImVec2(sp.x + 16, sp.y + 38), imgui.ImVec2(sp.x + w - 16, sp.y + 39), C(pal.border))

    imgui.SetCursorScreenPos(imgui.ImVec2(sp.x + 16, sp.y + 46))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.BeginChild('##pn' .. title, imgui.ImVec2(w - 32, h - 56), false,
        scroll and 0 or (imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse))
    body()
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor()
end

-- ----------------------------------------------------------------------------
--  Содержимое вкладок
-- ----------------------------------------------------------------------------
-- (объявлены в таблице группы: SaveConfig, LoadConfig, DeleteConfig, CreateConfig, RefreshConfigs, configName)
CFG.activeCfg = 'default'      -- конфиг, в который идёт автосохранение (последний загруженный/созданный)
local Tools = {}                 -- действия кнопок вкладки Tools (реализация ниже, в разделе "Инструменты")
local content = {}

-- ---------- 1. MAIN ----------
-- Функции перенесены из arztools: Anti speed limit, FOV, Anti GZ, Anti slap, Mentions, Quit notification, CEF priority.
-- Логика (память, хуки, оверлей) - в блоке "Main tab" ниже (ctl.main); здесь только интерфейс.
SETTINGS['Anti speed limit'] = {title = 'Anti speed limit settings', items = {
    {'check', 'On foot',    'main_asl_foot', true},
    {'check', 'In vehicle', 'main_asl_car',  true},
}}
SETTINGS['Field of view (FOV)'] = {title = 'FOV settings', items = {
    {'slider', 'FOV value', 'main_fov_val', 70, 20, 125, '%d', true},
}}
SETTINGS['Quit notification'] = {title = 'Quit notification settings', items = {
    {'slider', 'Notification radius', 'main_quit_dist', 50, 10, 100, '%d m', true},
    {'slider', 'Display time',        'main_quit_time', 15, 5, 60, '%d s', true},
}}
SETTINGS['Change time'] = {title = 'Time change settings', items = {
    {'slider', 'Hour', 'main_time_val', 12, 0, 23, '%d', true},
}}
SETTINGS['Change weather'] = {title = 'Weather change settings', items = {
    {'slider', 'Weather ID', 'main_weather_val', 1, 0, 45, '%d', true},
}}
SETTINGS['Chat calculator'] = {title = 'Chat calculator settings', items = {
    {'check', 'Clear chat after copying', 'calc_clear',   true},
    {'check', 'Copy without spaces',      'calc_nospace', false},
    {'check', 'Integer only',             'calc_intonly', false},
    {'key',   'Copy key',                 'calc_copy'},
}}
SETTINGS['Auto reconnect'] = {title = 'Auto reconnect settings', items = {
    {'note',   nil, 'Choose in which situations the game reconnects by itself.'},
    {'words',  'Reconnect situations', 'ar_situations'},
    {'slider', 'Reconnect delay',              'ar_delay',  15, 15, 600, '%d s', true},
    {'slider', 'Attempts in a row',            'ar_max',    5, 1, 20, '%d', true},
    {'combo',  'After the attempts run out',   'ar_after',  'Stop', {'Stop', 'Keep trying', 'Exit the game', 'Shut down the PC'}},
}}
SETTINGS['Reset animations by key'] = {title = 'Knock down settings', items = {
    {'key', 'Key', 'ut_sbivx'},
}}
SETTINGS['Wallhack'] = {title = 'Wallhack settings', items = {
    {'key', 'Key', 'ut_wh'},
}}
SETTINGS['FastWalk'] = {title = 'FastWalk settings', items = {
    {'slider', 'Walk anim speed', 'ut_fw_val', 1.0, 0, 10, '%.1f', false},
}}
SETTINGS['FastAnim'] = {title = 'FastAnim settings', items = {
    {'slider', 'All anim speed', 'ut_fa_val', 1.0, 0, 10, '%.1f', false},
}}
SETTINGS['RapidFire'] = {title = 'RapidFire settings', items = {
    {'slider', 'Fire anim speed', 'ut_rf_val', 1.0, 0, 10, '%.1f', false},
}}
SETTINGS['CamHack'] = {title = 'CamHack settings', items = {
    {'key', 'Activation', 'ut_cam_start'},
    {'key', 'Deactivation', 'ut_cam_stop'},
    {'key', 'Speed up', 'ut_cam_up'},
    {'key', 'Speed down', 'ut_cam_dn'},
}}
SETTINGS['Car flip upright'] = {title = 'Car flip settings', items = {
    {'key', 'Key', 'uf_k_flip'},
}}
SETTINGS['Car jump'] = {title = 'Car jump settings', items = {
    {'key', 'Key', 'uf_k_jump'},
}}
SETTINGS['Quick braking (ARZ)'] = {title = 'Quick braking settings', items = {
    {'key', 'Key', 'mm_limit_key'},
}}
SETTINGS['Auto balloon collection'] = {title = 'Auto balloon settings', items = {
    {'key', 'Key', 'mm_balloon_key'},
}}
SETTINGS['Fast Exit Vehicle'] = {title = 'Fast exit settings', items = {
    {'key', 'Key', 'uf_k_exit'},
}}
SETTINGS['180 degree turn'] = {title = 'Turn settings', items = {
    {'key', 'Key', 'uf_k_turn'},
}}
SETTINGS['Vehicle WH'] = {title = 'Vehicle WH settings', items = {
    {'slider', 'WH font size', 'uf_vwh_size', 7, 6, 25, '%d px', true},
    {'slider', 'WH distance', 'uf_vwh_dist', 100, 1, 250, '%d m', true},
    {'slider', 'WH update interval', 'uf_vwh_ms', 250, 50, 2000, '%d ms', true},
    {'key', 'Key', 'uf_vwh_key'},
}}
SETTINGS['Godmode'] = {title = 'Godmode settings', items = {
    {'check', 'Toggle with a key', 'uf_gm_keymode', false},
    {'key', 'Key', 'uf_gm_key'},
}}
SETTINGS['Active functions list'] = {title = 'Active functions settings', items = {
    {'check', 'Show binds', 'act_binds', false},
    {'slider', 'List size', 'act_scale', 1.0, 0.5, 2.0, '%.1fx', false},
    {'button', 'Edit list position', 'act_pos_edit'},
}}
SETTINGS['GM Car'] = {title = 'GM Car settings', items = {
    {'check', 'Toggle with a key', 'uf_gmcar_keymode', false},
    {'key', 'Key', 'uf_gmcar_key'},
    {'note', nil, 'With a key, GM Car is switched only while you are in a vehicle. Enabling it from the menu works at any time.'},
}}
SETTINGS['Radar IDs'] = {title = 'Radar IDs settings', items = {
    {'check', 'Player IDs', 'rdr_players', true},
    {'check', 'Vehicle IDs', 'rdr_vehicles', false},
    {'check', 'Color by nickname', 'rdr_clist', true},
    {'slider', 'Radar font size', 'rdr_size', 9, 6, 25, '%d px', true},
    {'key', 'Key', 'rdr_key'},
}}
SETTINGS['Fly Car'] = {title = 'Fly Car settings', items = {
    {'key', 'Flight key', 'flycar_key'},
}}
SETTINGS['Auto run and ride keys'] = {title = 'Auto run and ride settings', items = {
    {'key', 'Bike key', 'ut_bike_key'},
    {'key', 'Run key', 'ut_run_key'},
}}
SETTINGS['AirBrake'] = {title = 'AirBrake settings', items = {
    {'key', 'Activation key', 'ut_air'},
    {'slider', 'AirBrake speed', 'ut_ab_val', 0.2, 0, 2, '%.2f', false},
}}
content[1] = {
    function() -- Misc
        Panel('Game', 0, 0, LAY.COLW, 286, function()
            Checkbox('CEF interface priority', B('main_cefprio', true))
            Checkbox('Chat calculator', B('main_calc', false))
            Checkbox('Change time', B('main_time', false))
            Checkbox('Change weather', B('main_weather', false))
            Checkbox('Auto run and ride keys', B('ut_bikerun', false))
            Checkbox('Auto reconnect', B('ar_enable', false))
            Checkbox('Auto balloon collection', B('mm_balloon_on', false))
        end)
        Panel('Dialogs', 0, 300, LAY.COLW, 176, function()
            Checkbox('NoDialog', B('ut_nodialog', false))
            Checkbox('NoDialogRestore', B('ut_nodialogrestore', false))
            Checkbox('Chat on T', B('ut_chatT', false))
            Checkbox('Dots in numbers', B('ut_dots', false))
        end)
        Panel('Notifications', LAY.COLW + 14, 0, LAY.COLW, 168, function()
            Checkbox('Mentions of you', B('main_mention', true))
            WORDS.row('Mention ignore list', 'mention_ign')
            Checkbox('Quit notification', B('main_quit', true))
        end)
        Panel('World', LAY.COLW + 14, 182, LAY.COLW, 216, function()
            Checkbox('Anti camera shake', B('ut_antilomka', false))
            Checkbox('Disable stream zone loading', B('ut_offstream', false))
            Checkbox('AntiMask', B('ut_antimask', false))
            Checkbox('Remove barrier collision', B('ut_barrier', false))
            Checkbox('Radar IDs', B('rdr_on', false))
        end)
    end,
    function() -- Character
        Panel('Character', 0, 0, LAY.COLW, 440, function()
            Checkbox('Anti speed limit', B('main_asl', false))
            Checkbox('Field of view (FOV)', B('main_fov', false))
            Checkbox('Anti GZ', B('main_antigz', false))
            Checkbox('Infinite run', B('ut_infrun', false))
            Checkbox('Run while hungry', B('ut_hungryrun', false))
            Checkbox('AntiStun', B('ut_antistun', false))
            Checkbox('NoFallAnimation', B('ut_nofall', false))
            Checkbox('NoAnim', B('ut_noanim', false))
            Checkbox('AutoBunnyHop', B('ut_bhop', false))
            Checkbox('Reset animations by key', B('ut_sbivx', false))
            Checkbox('Anti spread', B('ut_nospread', false))
            Checkbox('No reload', B('ut_noreload', false))
        end)
        Panel('Abilities', LAY.COLW + 14, 0, LAY.COLW, 376, function()
            Checkbox('FastWalk', B('ut_fastwalk', false))
            Checkbox('FastAnim', B('ut_fastanim', false))
            Checkbox('RapidFire', B('ut_rapidfire', false))
            Checkbox('AirBrake', B('ut_airbrake', false))
            Checkbox('ClickWarp', B('ut_clickwarp', false))
            Checkbox('CamHack', B('ut_camhack', false))
            Checkbox('Wallhack', B('ut_wallhack', false))
            Checkbox('Godmode', B('uf_gm', false))
            Checkbox('FullSkillGun', B('uf_skill', false))
            Checkbox('Infinite oxygen', B('uf_oxygen', false))
        end)
    end,
    function() -- For car
        Panel('Vehicle', 0, 0, LAY.COLW, 344, function()
            Checkbox('Anti slap from vehicle roof', B('main_antislap', false))
            Checkbox('Fly Car', B('flycar_enable', false))
            Checkbox('GM Car', B('uf_gmcar', false))
            Checkbox('GM Wheel', B('uf_gmwheel', false))
            Checkbox('NoBike', B('uf_nobike', false))
            Checkbox('Stealth NoBike', B('uf_nobike2', false))
            Checkbox('Drive on water', B('uf_water', false))
            Checkbox('Infinity Fuel', B('uf_infuel', false))
        end)
        Panel('Vehicle actions', LAY.COLW + 14, 0, LAY.COLW, 344, function()
            Checkbox('Anti bucket', B('ut_antibucket', false))
            Checkbox('Car flip upright', B('uf_flip', false))
            Checkbox('Car jump', B('uf_jump', false))
            Checkbox('Fast Exit Vehicle', B('uf_fastexit', false))
            Checkbox('180 degree turn', B('uf_turn180', false))
            Checkbox('Instant heli blades', B('uf_heli', false))
            Checkbox('Heli blade collision', B('uf_bladecol', false))
            Checkbox('Vehicle WH', B('uf_vwh', false))
            Checkbox('Quick braking (ARZ)', B('mm_limit_on', false))
        end)
    end,
}

-- ----------------------------------------------------------------------------
--  Tools -> Render
--  Подсветка ресурсов, объектов, оленей и граффити прямо на экране: линия от персонажа
--  до цели + название + дистанция. ID объектов и тексты 3D-меток взяты из MRender 1.9.6,
--  сама отрисовка переписана: 3D-тексты, объекты и олени сканируются с настраиваемой частотой
--  (шестерёнка у "Render settings"), в кадре остаётся только проекция в экранные координаты -
--  поэтому функции с пометкой * больше не просаживают FPS. Рисуется через фоновый список mimgui.
--  У каждой функции свой цвет (квадрат слева от переключателя).
--  Настройки (галочки, цвета, частоты, толщина) сохраняются в конфиг как обычные виджеты,
--  тексты из блока Custom text - в секцию [render_text] (см. ctl.rnd.section / apply).
-- ----------------------------------------------------------------------------
do
    local R = {}
    ctl.rnd = R
    R.SLOTS = 3                       -- сколько своих текстовых триггеров
    R.OBJSLOTS = 3                    -- сколько своих объектов (поля с ID модели)
    R.onames, R.obufs = {}, {}        -- ID объектов: из конфига / буферы полей ввода
    R.names = {}                      -- сохранённые тексты (cp1251): из конфига, пока поле ввода не создано
    R.bufs  = {}                      -- буферы полей ввода (UTF-8 для imgui)
    R.cacheT, R.cacheO, R.cacheD = {}, {}, {}      -- тексты / объекты / олени
    R.scanT, R.scanO, R.scanD = -10, -10, -10      -- время последнего скана каждого источника
    R.bgq, R.shq, R.txq = {}, {}, {}               -- очереди отрисовки за кадр (подложки, тени, текст), массивы переиспользуются

    -- ---------- тексты своих триггеров <-> конфиг ----------
    function R.buf(i)
        if not R.bufs[i] then
            R.bufs[i] = imgui.new.char[128]()
            ffi.copy(R.bufs[i], u8((R.names[i] or ''):sub(1, 60)))
        end
        return R.bufs[i]
    end
    function R.getText(i)             -- текущий текст в cp1251
        local b = R.bufs[i]
        if not b then return R.names[i] or '' end
        local ok, s = pcall(function() return u8:decode(ffi.string(b)) end)
        return ok and s or ''
    end
    function R.objBuf(i)
        if not R.obufs[i] then
            R.obufs[i] = imgui.new.char[64]()
            ffi.copy(R.obufs[i], (R.onames[i] or ''):sub(1, 60))
        end
        return R.obufs[i]
    end
    function R.getObj(i)              -- текст поля: один или несколько ID моделей через запятую/пробел
        local b = R.obufs[i]
        if not b then return R.onames[i] or '' end
        return ffi.string(b)
    end
    function R.section()              -- для makeConfigData
        local t = {}
        for i = 1, R.SLOTS do t['text' .. i] = R.getText(i) end
        for i = 1, R.OBJSLOTS do t['obj' .. i] = R.getObj(i) end
        return t
    end
    function R.apply(sec)             -- для applyConfigData (нет в файле = пусто, как у остальных виджетов)
        sec = sec or {}
        for i = 1, R.SLOTS do
            local v = sec['text' .. i]
            R.names[i] = (v ~= nil) and tostring(v):sub(1, 60) or ''
            if R.bufs[i] then
                ffi.fill(R.bufs[i], 128, 0)
                ffi.copy(R.bufs[i], u8(R.names[i]))
            end
        end
        for i = 1, R.OBJSLOTS do
            local v = sec['obj' .. i]
            R.onames[i] = (v ~= nil) and tostring(v):gsub('[^%d, ]', ''):sub(1, 60) or ''
            if R.obufs[i] then
                ffi.fill(R.obufs[i], 64, 0)
                ffi.copy(R.obufs[i], R.onames[i])
            end
        end
    end

    -- ---------- что искать ----------
    -- Объекты по ID модели (getAllObjects)
    R.OBJ = {
        {key = 'rnd_seeds',   box = 'Seeds*',        ids = {859},
         names = {en = 'Seeds', ru = 'Семена'}},
        {key = 'rnd_clothes', box = 'Torn clothes*', ids = {18893, 2844, 2819, 18919, 18974, 18946, 2705, 2706},
         names = {en = 'Torn clothes', ru = 'Рваная одежда'}},
        {key = 'rnd_gift',    box = 'Gifts (map)*',  ids = {19054, 19055, 19056, 19057, 19058},
         names = {en = 'Gift', ru = 'Подарок'}},
    }
    -- 3D-тексты: any = любая из подстрок (без шаблонов), no = исключающая подстрока,
    -- raw = показывать исходный текст метки, иначе - своё название (names)
    local GANG_NO = 'Повторно закрасить'     -- есть в тексте граффити на перезарядке: закрасить пока нельзя
    R.TEXT = {
        {key = 'rnd_flax',     box = 'Flax',               raw = true, any = {'Лён'}},
        {key = 'rnd_cotton',   box = 'Cotton',             raw = true, any = {'Хлопок'}},
        {key = 'rnd_ore',      box = 'Ore',                any = {'Месторождение ресурсов'},
         names = {en = 'Ore', ru = 'Руда'}},
        {key = 'rnd_ore_ug',   box = 'Underground ore',    any = {'Место добычи ресурсов'},
         names = {en = 'Ore (underground)', ru = 'Руда (подземная)'}},
        {key = 'rnd_mushroom', box = 'Mushrooms',          any = {'Срезать гриб'},
         names = {en = 'Mushroom', ru = 'Гриб'}},
        {key = 'rnd_tree',     box = 'Fruit trees',        raw = true,
         any = {'Кокосовое дерево', 'Сливовое дерево', 'Яблочное дерево'}},
        {key = 'rnd_wood',     box = 'High-quality trees', any = {'Дерево высшего качества'},
         names = {en = 'High-quality tree', ru = 'Дерево выс.качества'}},
        {key = 'rnd_bookmark', box = 'Bookmarks',          raw = true, any = {'Закладка'}},
        -- граффити банд
        {key = 'rnd_grove',   box = 'Grove Street', raw = true, any = {'Банда: {90EE90}{009327}Grove Street'}},
        {key = 'rnd_ballas',  box = 'Ballas',       raw = true, any = {'Банда: {90EE90}{CC00CC}East Side Ballas'}},
        {key = 'rnd_rifa',    box = 'Rifa',         raw = true, any = {'Банда: {90EE90}{6666FF}The Rifa'}},
        {key = 'rnd_aztec',   box = 'Aztecas',      raw = true, any = {'Банда: {90EE90}{00FFE2}Varrios Los Aztecas'}},
        {key = 'rnd_wolves',  box = 'Night Wolves', raw = true, any = {'Банда: {90EE90}{A87878}Night Wolves'}},
        {key = 'rnd_vagos',   box = 'Vagos',        raw = true, any = {'Банда: {90EE90}{D1DB1C}Los Santos Vagos'}},
    }
    -- чужое граффити, которое можно закрасить: у каждой банды свой текст с красным тегом {ff6666}.
    -- Нужен режиму "Только доступные к закраске": тогда галочки банд показывают именно такие граффити
    local GANG_RED = {
        rnd_grove  = 'Банда: {ff6666}{009327}Grove Street',
        rnd_ballas = 'Банда: {ff6666}{CC00CC}East Side Ballas',
        rnd_rifa   = 'Банда: {ff6666}{6666FF}The Rifa',
        rnd_aztec  = 'Банда: {ff6666}{00FFE2}Varrios Los Aztecas',
        rnd_wolves = 'Банда: {ff6666}{A87878}Night Wolves',
        rnd_vagos  = 'Банда: {ff6666}{D1DB1C}Los Santos Vagos',
    }
    for _, r in ipairs(R.TEXT) do
        r.red = GANG_RED[r.key]
        if r.red then r.anyPaint = {r.any[1], r.red} end      -- в режиме "только доступные к закраске" подходят оба варианта текста
    end
    R.DEER_MODEL = 3150
    R.DEER = {key = 'rnd_deer', box = 'Deer', names = {en = 'Deer', ru = 'Олень'}}
    R.ALL3D = {key = 'rnd_all3d', box = 'All 3D texts', raw = true, orig = true}   -- все 3D-тексты подряд, в их цветах
    R.ALLOBJ = {key = 'rnd_allobj', box = 'All objects', grp = 'obj'}   -- все серверные объекты вокруг (с ID модели)
    R.OBJCUSTOMS = {}                 -- по одному правилу (и цвету) на каждое поле своих объектов
    for i = 1, R.OBJSLOTS do
        R.OBJCUSTOMS[i] = {key = 'rnd_objcustom', box = 'Object ' .. i, grp = 'obj', colKey = 'rnd_col_objcustom' .. i}
    end
    R.CUSTOMS = {}                    -- по одному правилу (и цвету) на каждый свой текст
    for i = 1, R.SLOTS do
        R.CUSTOMS[i] = {key = 'rnd_custom', box = 'Text ' .. i, raw = true, orig = true, colKey = 'rnd_col_custom' .. i}
    end

    -- цвет каждой функции: ключ rnd_col_<имя>, по умолчанию белый, у банд - цвет банды
    local DEF_COL = {
        rnd_grove = {0.000, 0.576, 0.153}, rnd_ballas = {0.800, 0.000, 0.800}, rnd_rifa  = {0.400, 0.400, 1.000},
        rnd_aztec = {0.000, 1.000, 0.886}, rnd_wolves = {0.659, 0.471, 0.471}, rnd_vagos = {0.820, 0.859, 0.110},
    }
    R.ALL = {R.DEER, R.ALL3D, R.ALLOBJ}
    for _, r in ipairs(R.OBJ) do R.ALL[#R.ALL + 1] = r end
    for _, r in ipairs(R.TEXT) do R.ALL[#R.ALL + 1] = r end
    for _, r in ipairs(R.ALL) do r.colKey = 'rnd_col_' .. r.key:sub(5) end
    for _, r in ipairs(R.CUSTOMS) do R.ALL[#R.ALL + 1] = r end
    for _, r in ipairs(R.OBJCUSTOMS) do R.ALL[#R.ALL + 1] = r end
    for _, r in ipairs(R.ALL) do
        local d = DEF_COL[r.key] or {1, 1, 1}
        r.col = {d[1], d[2], d[3], 1}
    end
    function R.colPtr(r) return Col(r.colKey, r.col[1], r.col[2], r.col[3], r.col[4]) end
    function R.colU32(r)
        local c = R.colPtr(r)
        return imgui.ColorConvertFloat4ToU32(imgui.ImVec4(c[0], c[1], c[2], c[3]))
    end
    function R.resetColors()
        for _, r in ipairs(R.ALL) do
            local c = R.colPtr(r)
            for i = 0, 3 do c[i] = r.col[i + 1] end
        end
    end

    -- все ключи включателей: render работает, только пока хоть один включён
    R.KEYS = {'rnd_deer', 'rnd_custom', 'rnd_all3d', 'rnd_allobj', 'rnd_objcustom'}
    for _, r in ipairs(R.OBJ) do R.KEYS[#R.KEYS + 1] = r.key end
    for _, r in ipairs(R.TEXT) do R.KEYS[#R.KEYS + 1] = r.key end
    function R.active()
        local now = os.clock()
        if now < (R.activeAt or 0) then return R.activeVal end      -- вызывается каждый кадр: перебор ключей не чаще 5 раз в секунду
        R.activeAt, R.activeVal = now + 0.2, false
        for _, k in ipairs(R.KEYS) do
            if B(k, false)[0] then R.activeVal = true break end
        end
        return R.activeVal
    end

    -- ---------- сканирование мира (интервал в мс, настраивается) ----------
    local function stripTags(s)       -- {RRGGBB} / {RRGGBBAA} в imgui отобразились бы текстом
        return (s:gsub('{%x%x%x%x%x%x%x%x}', ''):gsub('{%x%x%x%x%x%x}', ''))
    end

    -- ---------- цветные подписи ----------
    -- Разбирает текст метки (cp1251) с тегами {RRGGBB} / {RRGGBBAA} на строки и куски одного цвета, как это
    -- показывает сама игра. argb - цвет самой 3D-метки: им рисуется текст до первого тега.
    -- Возвращает {{ {s = текст в UTF-8, c = цвет ImU32}, ... }, ...} - по списку кусков на каждую строку.
    local function parseColored(text, argb)
        local cr, cg, cb, ca = 255, 255, 255, 255
        if argb then
            argb = argb % 4294967296                 -- sampfuncs может отдать цвет отрицательным числом
            cr, cg, cb = math.floor(argb / 65536) % 256, math.floor(argb / 256) % 256, argb % 256
        end
        local lines, cur = {}, {}
        local function emit(s)
            local i = 1
            while true do
                local nl = s:find('\n', i, true)
                local part = s:sub(i, (nl or (#s + 1)) - 1):gsub('\r', '')
                if part ~= '' then
                    cur[#cur + 1] = {s = u8(part), c = ca * 16777216 + cb * 65536 + cg * 256 + cr}   -- ImU32 = 0xAABBGGRR
                end
                if not nl then break end
                lines[#lines + 1] = cur
                cur = {}
                i = nl + 1
            end
        end
        local pos = 1
        while true do
            local a, b, hex = text:find('{(%x+)}', pos)
            if not a then break end
            if #hex == 6 or #hex == 8 then
                emit(text:sub(pos, a - 1))
                cr, cg, cb = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
                ca = (#hex == 8) and tonumber(hex:sub(7, 8), 16) or 255
            else
                emit(text:sub(pos, b))               -- не цветовой тег: остаётся обычным текстом
            end
            pos = b + 1
        end
        emit(text:sub(pos))
        lines[#lines + 1] = cur
        return lines
    end
    -- метки почти не меняются от скана к скану, поэтому разобранный текст кэшируется
    local pcache, pcount = {}, 0
    local function parseCached(text, argb)
        local key = tostring(argb) .. '|' .. text
        local v = pcache[key]
        if not v then
            if pcount > 800 then pcache, pcount = {}, 0 end
            v = parseColored(text, argb)
            pcache[key] = v
            pcount = pcount + 1
        end
        return v
    end

    -- 3D-тексты (ресурсы, граффити, свои тексты, все тексты)
    -- UTF-8 подпись без цветовых тегов: считается один раз для текста, а не при каждом проходе (раз в 100 мс)
    R.labels, R.labelsN = {}, 0
    function R.labelOf(text)
        local s = R.labels[text]
        if not s then
            if R.labelsN > 600 then R.labels, R.labelsN = {}, 0 end
            s = u8(stripTags(text))
            R.labels[text] = s
            R.labelsN = R.labelsN + 1
        end
        return s
    end

    function R.rescanTexts()
        local out = {}
        R.cacheT = out
        local rules = {}
        local graffitiOn = B('rnd_graffiti', true)[0]          -- главный переключатель панели "Graffiti" (в шапке)
        for _, r in ipairs(R.TEXT) do
            if B(r.key, false)[0] and (graffitiOn or not r.red) then rules[#rules + 1] = r end    -- r.red есть только у банд
        end
        local customs = {}
        if B('rnd_custom', false)[0] then
            for i = 1, R.SLOTS do
                local s = R.getText(i)
                if s ~= '' then customs[#customs + 1] = {s, R.CUSTOMS[i]} end
            end
        end
        local all3d = B('rnd_all3d', false)[0]
        if #rules == 0 and #customs == 0 and not all3d then return end
        local onlyPaint = B('rnd_only_paint', false)[0]     -- "Только доступные к закраске"
        local keepCol = B('rnd_origcol', true)[0]           -- исходные цвета текста (для "All 3D texts" и своих текстов)
        for id = 0, 2048 do
            if sampIs3dTextDefined(id) then
                local text, tcol, x, y, z, _, _, pid, vid = sampGet3dTextInfoById(id)
                if text and text ~= '' then
                    local matched = false
                    for _, r in ipairs(rules) do
                        local hit = false
                        local any, no = r.any, r.no
                        -- режим "только доступные к закраске": граффити доступно, если в его тексте НЕТ строки
                        -- "Повторно закрасить..."; если она есть - граффити на перезарядке и не показывается
                        if onlyPaint and r.anyPaint then any, no = r.anyPaint, GANG_NO end
                        for _, s in ipairs(any) do
                            if text:find(s, 1, true) then hit = true break end
                        end
                        if hit and no and text:find(no, 1, true) then hit = false end
                        if hit then
                            out[#out + 1] = {x = x, y = y, z = z, rule = r, label = r.raw and R.labelOf(text) or nil}
                            matched = true
                            break
                        end
                    end
                    for _, cu in ipairs(customs) do
                        if text:find(cu[1], 1, true) then
                            out[#out + 1] = {x = x, y = y, z = z, rule = cu[2], label = R.labelOf(text),
                                             lines = keepCol and parseCached(text, tcol) or nil}
                            matched = true
                            break
                        end
                    end
                    -- все остальные метки; прикреплённые к игроку или машине пропускаем: у них координаты - смещение
                    if all3d and not matched and (not pid or pid >= 65535 or pid < 0) and (not vid or vid >= 65535 or vid < 0) then
                        out[#out + 1] = {x = x, y = y, z = z, rule = R.ALL3D, label = R.labelOf(text),
                                         lines = keepCol and parseCached(text, tcol) or nil, limited = true}
                    end
                end
            end
        end
    end

    -- объекты: по ID модели (семена, одежда, подарки), свои ID из полей и все серверные объекты подряд
    local objLabels = {}                  -- подпись "Объект <ID>" (UTF-8) кэшируется: объектов бывает сотни
    local function objLabel(model)
        local key = tostring(i18n.curLang) .. ':' .. model          -- язык мог смениться: кэш по языку
        local s = objLabels[key]
        if not s then s = u8(tr('Object') .. ' ' .. model); objLabels[key] = s end
        return s
    end
    -- Объекты запоминаются по хэндлу. Если getAllObjects в этот раз не вернул уже известный объект, но он ещё жив
    -- (doesObjectExist, та же модель), он остаётся в списке, а его координаты обновляются напрямую - так список
    -- не мигает, даже если getAllObjects отдаёт объекты не каждый раз. Исчезнувший объект убирается сразу.
    R.objSeen = {}                        -- хэндл -> запись {x, y, z, rule, label, limited, model, t}
    local OBJ_GRACE = 1.5                 -- если doesObjectExist недоступна: столько секунд держим пропавший объект

    local function objPos(h)              -- getObjectCoordinates: с ведущим флагом результата или без него
        local a, b, c, d = getObjectCoordinates(h)
        if type(a) == 'boolean' then
            if a then return b, c, d end
            return nil
        end
        return a, b, c
    end

    local function objRule(model, models, customs, all)    -- какое правило рисует эту модель (nil - никакое)
        local r = models[model]
        if r then return r, true end
        r = customs[model]
        if r then return r, false end
        if all then return R.ALLOBJ, false end
        return nil
    end

    local function setObj(e, r, own, model)
        e.rule, e.model = r, model
        e.label = (not own) and objLabel(model) or nil
        e.limited = (r == R.ALLOBJ) and 'obj' or nil                 -- лимит дистанции только у "All objects"
    end

    local function scanObj(h, now, models, customs, all)             -- объект из списка getAllObjects
        local model = getObjectModel(h)
        if not model then return end
        local r, own = objRule(model, models, customs, all)
        if not r then return end
        local x, y, z = objPos(h)
        if not x or not y or not z then return end
        local e = R.objSeen[h]
        if not e then e = {}; R.objSeen[h] = e end
        e.x, e.y, e.z, e.t = x, y, z, now
        setObj(e, r, own, model)
    end

    local function recheckObj(h, e, models, customs, all)           -- известный объект, которого нет в списке: жив ли он
        if not doesObjectExist(h) then return false end
        local model = getObjectModel(h)
        if model ~= e.model then return false end                    -- хэндл успели отдать другому объекту
        local r, own = objRule(model, models, customs, all)
        if not r then return false end
        local x, y, z = objPos(h)
        if not x or not y or not z then return false end
        e.x, e.y, e.z = x, y, z
        setObj(e, r, own, model)
        return true
    end

    function R.rescanObjects()
        local models, nm = {}, 0
        for _, r in ipairs(R.OBJ) do
            if B(r.key, false)[0] then
                for _, m in ipairs(r.ids) do models[m] = r; nm = nm + 1 end
            end
        end
        local customs = {}                -- ID модели -> правило поля (у фиксированных наборов приоритет выше)
        if B('rnd_objcustom', false)[0] then
            for i = 1, R.OBJSLOTS do
                local n = 0
                for num in R.getObj(i):gmatch('%d+') do
                    n = n + 1
                    if n > 16 then break end
                    local m = tonumber(num)
                    if m and not customs[m] then customs[m] = R.OBJCUSTOMS[i]; nm = nm + 1 end
                end
            end
        end
        local all = B('rnd_allobj', false)[0]
        if nm == 0 and not all then
            R.cacheO, R.objSeen = {}, {}
            return
        end
        local okList, list = pcall(getAllObjects)
        if not okList or type(list) ~= 'table' then return end        -- не вышло: оставляем прошлый список
        local now = os.clock()
        for _, h in ipairs(list) do
            pcall(scanObj, h, now, models, customs, all)
        end
        local out = {}
        for h, e in pairs(R.objSeen) do
            local keep = (e.t == now)
            if not keep then
                local ok, alive = pcall(recheckObj, h, e, models, customs, all)
                if ok then keep = alive else keep = (now - e.t <= OBJ_GRACE) end
            end
            if keep then out[#out + 1] = e else R.objSeen[h] = nil end
        end
        R.cacheO = out
    end

    -- олени (двигаются, поэтому частота по умолчанию выше)
    function R.rescanDeer()
        local out = {}
        R.cacheD = out
        if not B('rnd_deer', false)[0] then return end
        for _, ch in ipairs(getAllChars()) do
            if ch ~= PLAYER_PED and getCharModel(ch) == R.DEER_MODEL and not sampGetPlayerIdByCharHandle(ch) then
                local x, y, z = getCharCoordinates(ch)
                out[#out + 1] = {x = x, y = y, z = z, rule = R.DEER}
            end
        end
    end

    -- интервал между сканами задаётся в миллисекундах (100..3000) -> секунды для os.clock()
    local function interval(key, def)
        local ms = math.floor(F(key, def)[0] + 0.5)
        ms = math.max(100, math.min(3000, ms))   -- на случай кривого значения из конфига
        return ms / 1000
    end

    -- ---------- отрисовка ----------
    local function worldName(names)
        return names[i18n.curLang] or names.en
    end

    -- название правила в UTF-8 на текущем языке: кэшируется в самом правиле, а не строится каждый кадр
    function R.ruleName(r)
        if not r.nameU or r.nameLang ~= i18n.curLang then r.nameU, r.nameLang = u8(worldName(r.names)), i18n.curLang end
        return r.nameU
    end

    function R.draw()
        local P = imgui.ImVec2
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        local width = F('rnd_width', 3)[0]
        local tracers, noDist = B('rnd_lines', true)[0], B('rnd_hidedist', false)[0]
        local bg3d = B('rnd_3d_bg', false)[0]                  -- фон под текстом из панели "3D texts"
        local tracers3d = B('rnd_lines_3d', true)[0]        -- линии к тексту из панели "3D texts" (отдельно от "Tracer lines" у объектов)
        local limOn, limD = B('rnd_all_lim', true)[0], F('rnd_all_dist', 100)[0]   -- лимит дистанции для "All 3D texts"
        local tracersObj = B('rnd_lines_obj', true)[0]      -- линии к объектам из панели "Server objects"
        local limOnO, limDO = B('rnd_obj_lim', true)[0], F('rnd_obj_dist', 100)[0]   -- лимит дистанции для "All objects"

        local now = os.clock()
        if now - R.scanT >= interval('rnd_ms', 100) then R.scanT = now; pcall(R.rescanTexts) end
        if now - R.scanO >= interval('rnd_ms', 100) then R.scanO = now; pcall(R.rescanObjects) end
        if now - R.scanD >= interval('rnd_ms', 100) then R.scanD = now; pcall(R.rescanDeer) end

        local dl = imgui.GetBackgroundDrawList()
        -- размер текста: масштаб шрифта на время отрисовки (в конце возвращаем как было)
        local k = clamp(F('rnd_text_size', 1.0)[0], 0.5, 3.0)
        -- берём растр шрифта, ближайший по размеру к нужному: масштаб остаётся около 1, и текст не мылится
        local font, fk = FNT.pickOverlay(k)
        local oldScale
        if font and (pcall(function() oldScale = font.Scale; font.Scale = oldScale * fk end) == false or not oldScale) then
            font, oldScale = fonts.small, nil            -- масштаб шрифта недоступен: рисуем обычным размером
        end
        if font then imgui.PushFont(font) end
        local sx, sy = convert3DCoordsToScreen(px, py, pz)       -- персонаж на экране: начало линий
        local distWord, unit = u8(tr('Distance')), u8(tr('m'))
        local dkey = distWord .. '|' .. unit
        if R.distKey ~= dkey then R.distKey, R.distCache, R.distN = dkey, {}, 0 end
        local dcache = R.distCache
        local function distStr(d)                                   -- строка расстояния по целым метрам: не форматируется каждый кадр
            local k = math.floor(d + 0.5)
            local s = dcache[k]
            if not s then
                if R.distN > 3000 then R.distCache, R.distN = {}, 0; dcache = R.distCache end
                s = string.format('%s: %d %s', distWord, k, unit)
                dcache[k] = s
                R.distN = R.distN + 1
            end
            return s
        end
        local lh = imgui.GetTextLineHeight()

        -- lines: цветные куски текста (см. parseColored); без них вся подпись рисуется одним цветом colU.
        -- limited: метка из "All 3D texts", для неё действует лимит дистанции.
        -- Подложки, тени и текст не рисуются сразу, а складываются в очереди и выводятся в конце кадра слоями:
        -- сначала ВСЕ подложки, потом ВСЕ тени, потом весь текст. Иначе подложка одной метки перекрывала бы
        -- текст соседней, нарисованной раньше (метки на экране часто налезают друг на друга).
        local bgq, shq, txq = R.bgq, R.shq, R.txq
        local nb, ns, nt = 0, 0, 0
        local function addBg(x1, y1, x2, y2)
            bgq[nb + 1], bgq[nb + 2], bgq[nb + 3], bgq[nb + 4] = x1, y1, x2, y2
            nb = nb + 4
        end
        local function addTx(x, y, col, s)
            shq[ns + 1], shq[ns + 2], shq[ns + 3] = x + 1, y + 1, s                -- тень, чтобы читалось на любом фоне
            ns = ns + 3
            txq[nt + 1], txq[nt + 2], txq[nt + 3], txq[nt + 4] = x, y, col, s
            nt = nt + 4
        end
        local function put(x, y, z, label, colU, lines, limited, is3d, isText)
            local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
            if limited == 'obj' then
                if limOnO and d > limDO then return end
            elseif limited and limOn and d > limD then return end
            if not isPointOnScreen(x, y, z, 1) then return end
            local wx, wy = convert3DCoordsToScreen(x, y, z)
            if not wx or not wy then return end
            local tOn = tracers
            if is3d == 'obj' then tOn = tracersObj elseif is3d then tOn = tracers3d end
            if tOn and sx and sy then dl:AddLine(P(sx, sy), P(wx, wy), colU, width) end
            local distLine = (not noDist) and distStr(d) or nil
            if lines then
                local x0, y0 = math.floor(wx), math.floor(wy)
                if bg3d and isText then                       -- полупрозрачная подложка по самой широкой строке
                    local nL, maxW = #lines + (distLine and 1 or 0), 0
                    for li = 1, nL do
                        local lw = 0
                        if lines[li] then
                            for _, sg in ipairs(lines[li]) do lw = lw + imgui.CalcTextSize(sg.s).x end
                        else
                            lw = imgui.CalcTextSize(distLine).x
                        end
                        if lw > maxW then maxW = lw end
                    end
                    addBg(x0 - 3, y0 - 1, x0 + maxW + 3, y0 + nL * lh + 1)
                end
                for li = 1, #lines + (distLine and 1 or 0) do
                    local cx, cy = x0, y0 + (li - 1) * lh
                    if lines[li] then
                        for _, sg in ipairs(lines[li]) do
                            addTx(cx, cy, sg.c, sg.s)
                            cx = cx + imgui.CalcTextSize(sg.s).x
                        end
                    else                                                           -- последняя строка: дистанция
                        addTx(cx, cy, colU, distLine)
                    end
                end
            else
                if distLine then label = label .. '\n' .. distLine end
                if bg3d and isText then
                    local sz = imgui.CalcTextSize(label)
                    addBg(wx - 3, wy - 1, wx + sz.x + 3, wy + sz.y + 1)
                end
                addTx(wx, wy, colU, label)
            end
        end

        local colors = {}                                       -- цвет каждого правила считаем один раз за кадр
        local okDraw, errDraw = pcall(function()
            R.caches = R.caches or {}
            R.caches[1], R.caches[2], R.caches[3] = R.cacheT, R.cacheO, R.cacheD
            for ci, cache in ipairs(R.caches) do
                for _, e in ipairs(cache) do
                    local r = e.rule
                    local colU = colors[r]
                    if not colU then colU = R.colU32(r); colors[r] = colU end
                    put(e.x, e.y, e.z, e.label or R.ruleName(r), colU, e.lines, e.limited, r.grp or r.orig, ci == 1)
                end
            end
        end)
        for i = 1, nb, 4 do dl:AddRectFilled(P(bgq[i], bgq[i + 1]), P(bgq[i + 2], bgq[i + 3]), 0xB0000000, 3) end
        for i = 1, ns, 3 do dl:AddText(P(shq[i], shq[i + 1]), 0xFF000000, shq[i + 2]) end
        for i = 1, nt, 4 do dl:AddText(P(txq[i], txq[i + 1]), txq[i + 2], txq[i + 3]) end
        if font then imgui.PopFont() end
        if oldScale then pcall(function() font.Scale = oldScale end) end     -- масштаб возвращаем даже после ошибки
        if not okDraw then error(errDraw, 0) end
    end

    imgui.OnFrame(
        function() return R.active() end,
        function(self)
            self.HideCursor = not (ui.open and ui.open[0])
            gfx.galpha = 1
            local ok, err = pcall(R.draw)
            if not ok and not R.errShown then
                R.errShown = true
                print('[COLLAPSE] Render error: ' .. tostring(err))
            end
        end
    )

    -- Исправление от XRLM из MRender: дублируем создание/удаление 3D-текстов в sampfuncs, чтобы
    -- sampGet3dTextInfoById видел актуальный список меток. Работает только пока включён рендер.
    if okEv and sampev then
        local oldCreate, oldRemove = sampev.onCreate3DText, sampev.onRemove3DTextLabel
        sampev.onCreate3DText = function(id, color, position, distance, testLOS, attachedPlayerId, attachedVehicleId, text)
            if R.active() then
                pcall(sampCreate3dTextEx, id, text, color, position.x, position.y, position.z, distance, testLOS, attachedPlayerId, attachedVehicleId)
            end
            if oldCreate then return oldCreate(id, color, position, distance, testLOS, attachedPlayerId, attachedVehicleId, text) end
        end
        sampev.onRemove3DTextLabel = function(textLabelId)
            if R.active() then pcall(sampDestroy3dText, textLabelId) end
            if oldRemove then return oldRemove(textLabelId) end
        end
    end

    -- ---------- настройки (шестерёнка у "Render settings") ----------
    SETTINGS['Render settings'] = {title = 'Render settings', items = {
        {'slider', 'Render update rate', 'rnd_ms',        100, 100, 3000, '%d ms', true},
        {'slider', 'Render text size',   'rnd_text_size', 1.0, 0.5, 3.0, '%.2fx', false},
        {'slider', 'Line width',         'rnd_width',     3.0, 1.0, 5.0, '%.1f', false},
        {'check',  'Tracer lines',       'rnd_lines',     true},
        {'check',  'Hide distance',      'rnd_hidedist',  false},
        {'check',  'Text background',    'rnd_3d_bg',     false},
        {'check',  'Original text colors', 'rnd_origcol', true},
        {'button', 'Reset colors',       'rnd_reset_colors'},
    }}
    SETTINGS['3D texts'] = {title = '3D texts', items = {
        {'check',  '3D text lines',  'rnd_lines_3d', true},
        {'check',  'Limit distance', 'rnd_all_lim',  true},
        {'slider', 'Max distance',   'rnd_all_dist', 100, 10, 500, '%d m', true},
    }}
    SETTINGS['Object render settings'] = {title = 'Object render settings', items = {
        {'check',  'Object lines',   'rnd_lines_obj', true},
        {'check',  'Limit distance', 'rnd_obj_lim',   true},
        {'slider', 'Max distance',   'rnd_obj_dist',  100, 10, 500, '%d m', true},
    }}
    SETTING_ACTIONS['rnd_reset_colors'] = function() R.resetColors() end

    -- ---------- подсказки и перевод ----------
    local H = {
        ['Render settings'] = 'Update rates, line width and distance display for all render functions. The color of each function is the square next to its switch.',
        ['Render update rate'] = 'How often 3D texts, objects and deer are rescanned, in milliseconds. Lower reacts faster but uses more CPU.',
        ['Render text size'] = 'Size of the labels and distance text drawn by the render functions.',
        ['Reset colors'] = 'Returns the color of every render function to its default.',
        ['Line width'] = 'Thickness of the lines from your character to the targets.',
        ['Tracer lines'] = 'Draw a line from your character to each target.',
        ['Hide distance'] = 'Show only the name, without the distance.',
        ['Graffiti'] = 'Master switch for gang graffiti. When it is off, no graffiti is drawn, whatever the switches below are set to.',
        ['Original text colors'] = 'Draws All 3D texts and Custom text labels in the colors they have in the game. When off, the whole label uses the color of its square.',
    }
    for k, v in pairs(H) do HINTS[k] = v end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Render'] = 'Рендер', ['Resources, 3D texts'] = 'Ресурсы, 3D-тексты', ['and server objects'] = 'и объекты', ['Resources'] = 'Ресурсы',
        ['Server objects'] = 'Серверные объекты', ['Text background'] = 'Фон текста', ['Object render settings'] = 'Настройки рендера объектов', ['All objects'] = 'Все объекты', ['Enable custom objects'] = 'Свои объекты', ['Object'] = 'Объект',
        ['Object 1'] = 'Объект 1', ['Object 2'] = 'Объект 2', ['Object 3'] = 'Объект 3', ['Object lines'] = 'Линии к объектам', ['Objects'] = 'Объекты', ['Graffiti'] = 'Граффити', ['Custom text'] = 'Свой текст', ['3D texts'] = '3D-тексты',
        ['Render settings'] = 'Настройки рендера',
        ['Flax'] = 'Лён', ['Cotton'] = 'Хлопок', ['Ore'] = 'Руда', ['Underground ore'] = 'Руда (подземная шахта)',
        ['Mushrooms'] = 'Грибы', ['Fruit trees'] = 'Деревья с плодами', ['High-quality trees'] = 'Деревья высшего качества',
        ['Bookmarks'] = 'Закладки', ['Seeds*'] = 'Семена*', ['Torn clothes*'] = 'Рваная одежда*',
        ['Gifts (map)*'] = 'Подарки (по карте)*', ['Deer'] = 'Олени',
        ['Grove Street'] = 'Грув', ['Ballas'] = 'Баллас', ['Rifa'] = 'Рифа', ['Aztecas'] = 'Ацтеки',
        ['Night Wolves'] = 'Ночные волки', ['Vagos'] = 'Вагос', ['Only available to paint over'] = 'Только доступные к закраске',
        ['Enable custom text'] = 'Свои тексты', ['Text 1'] = 'Текст 1', ['Text 2'] = 'Текст 2', ['Text 3'] = 'Текст 3',
        ['Render update rate'] = 'Частота обновления рендера', ['Render text size'] = 'Размер текста рендера', ['Reset colors'] = 'Сбросить цвета', ['Line width'] = 'Толщина линий', ['Tracer lines'] = 'Линии к целям',
        ['Hide distance'] = 'Скрыть дистанцию', ['Distance'] = 'Дистанция', ['m'] = 'м',

        ['Update rates, line width and distance display for all render functions. The color of each function is the square next to its switch.'] =
            'Частоты обновления, толщина линий и показ дистанции для всех функций рендера. Цвет каждой функции - квадрат рядом с её переключателем.',
        ['How often 3D texts, objects and deer are rescanned, in milliseconds. Lower reacts faster but uses more CPU.'] =
            'Как часто пересканируются 3D-тексты, объекты и олени, в миллисекундах. Чем меньше, тем быстрее реакция, но больше нагрузка на процессор.',
        ['Size of the labels and distance text drawn by the render functions.'] =
            'Размер названий и текста с дистанцией, которые рисуют функции рендера.',
        ['Returns the color of every render function to its default.'] = 'Возвращает цвет каждой функции рендера к стандартному.',
        ['Thickness of the lines from your character to the targets.'] = 'Толщина линий от персонажа до целей.',
        ['Draw a line from your character to each target.'] = 'Рисовать линию от персонажа до каждой цели.',
        ['Show only the name, without the distance.'] = 'Показывать только название, без дистанции.',
        ['Master switch for gang graffiti. When it is off, no graffiti is drawn, whatever the switches below are set to.'] =
            'Главный переключатель граффити банд. Если выключен, граффити не рисуются, что бы ни было включено ниже.',
        ['All 3D texts'] = 'Все 3D-тексты', ['Limit distance'] = 'Лимит дистанции', ['Max distance'] = 'Макс. дистанция', ['3D text lines'] = 'Линии к 3D-текстам',
        ['Original text colors'] = 'Исходные цвета текста', ['%d m'] = '%d м',
        ['Draws All 3D texts and Custom text labels in the colors they have in the game. When off, the whole label uses the color of its square.'] =
            'Рисует "Все 3D-тексты" и "Свой текст" в тех цветах, что у них в игре. Если выключено, вся надпись рисуется цветом своего квадрата.',
    }) do ru[k] = v end

    -- ---------- вкладка ----------
    -- Порядок галочек в левой панели
    local BOXES = {}
    for _, key in ipairs({'rnd_flax', 'rnd_cotton', 'rnd_ore', 'rnd_ore_ug', 'rnd_mushroom', 'rnd_tree', 'rnd_wood', 'rnd_bookmark'}) do
        for _, r in ipairs(R.TEXT) do if r.key == key then BOXES[#BOXES + 1] = r end end
    end
    for _, r in ipairs(R.OBJ) do BOXES[#BOXES + 1] = r end
    BOXES[#BOXES + 1] = R.DEER

    local GANGS = {}
    for _, r in ipairs(R.TEXT) do
        if r.key:find('^rnd_grove') or r.key:find('^rnd_ballas') or r.key:find('^rnd_rifa') or r.key:find('^rnd_aztec')
            or r.key:find('^rnd_wolves') or r.key:find('^rnd_vagos') then
            GANGS[#GANGS + 1] = r
        end
    end

    -- Квадрат цвета рисуем ДО строки: из пересекающихся элементов ImGui отдаёт клик тому, кто отправлен раньше.
    local function Swatch(r, x, y)
        local P = imgui.ImVec2
        imgui.SetCursorScreenPos(P(x, y + (26 - imgui.GetFrameHeight()) / 2))
        imgui.ColorEdit4('##rnc' .. r.colKey, R.colPtr(r), imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoLabel)
        -- подсказка ImGui со значениями цвета не должна накладываться на подсказку строки (см. Hint)
        if imgui.IsItemHovered() then gfx.hintBlock = true end
        -- открытый пикер цвета считаем "занятым" (клик в нём не должен закрывать окно настроек)
        if pcall(imgui.PushIDStr, '##rnc' .. r.colKey) then
            local okp, isOpen = pcall(imgui.IsPopupOpen, 'picker')
            imgui.PopID()
            if okp and isOpen then ui.popBusy = true; gfx.hintBlock = true end
        end
    end
    local function ColorCheckbox(r)
        if SRCH.collecting then Checkbox(r.box, B(r.key, false)) return end
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        Swatch(r, p.x + w - 38 - 10 - imgui.GetFrameHeight() - (SETTINGS[r.box] and 26 or 0), p.y)   -- слева от переключателя (и шестерёнки, если она есть)
        imgui.SetCursorScreenPos(p)
        Checkbox(r.box, B(r.key, false), nil, 10 + imgui.GetFrameHeight())
    end
    local function ColorText(i)
        local buf = R.buf(i)
        if SRCH.collecting then TextRow('Text ' .. i, buf, function() end) return end
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        Swatch(R.CUSTOMS[i], p.x + w - 130 - 8 - imgui.GetFrameHeight(), p.y)   -- слева от поля ввода (130 px)
        imgui.SetCursorScreenPos(p)
        TextRow('Text ' .. i, buf, function() end)
    end

    -- Render - плитка во вкладке Software (SOFT.list, id 'render'); страница рисуется без внешней панели.
    -- Две страницы (SOFT.rpage): 1 - ресурсы, граффити и 3D-тексты; 2 - серверные объекты. В шапке первой панели:
    -- слева от названия стрелка назад (с 1-й страницы - к плиткам, со 2-й - на 1-ю), у правого края 1-й страницы - кнопка "Объекты".
    SOFT.rpage = 1

    local function ColorObj(i)            -- поле с ID модели (несколько - через запятую) и квадрат цвета
        local r = R.OBJCUSTOMS[i]
        local buf = R.objBuf(i)
        local function clean()            -- оставляем только цифры, запятые и пробелы
            local s = ffi.string(buf):gsub('[^%d, ]', ''):sub(1, 60)
            ffi.fill(buf, 64, 0)
            ffi.copy(buf, s)
        end
        if SRCH.collecting then TextRow(r.box, buf, clean) return end
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        Swatch(r, p.x + w - 130 - 8 - imgui.GetFrameHeight(), p.y)   -- слева от поля ввода (130 px)
        imgui.SetCursorScreenPos(p)
        TextRow(r.box, buf, clean)
    end

    -- шапка первой панели страницы: [стрелка назад] Название [шестерёнка] ............ [переключатель страниц]
    local NAV_SHIFT = 30                                          -- на столько название панели сдвинуто вправо (место под стрелку)
    local function HeaderNav(pg, gearLabel)
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local c0 = imgui.GetCursorScreenPos()                     -- Panel ставит курсор в (правый край - 42, верх + 7)
        local c = P(c0.x - (LAY.COLW - 42) + 10, c0.y)            -- левый край панели + 10: здесь стрелка назад
        if gearLabel then
            imgui.PushFont(fonts.bold)
            local tw = imgui.CalcTextSize(u8(tr(gearLabel))).x
            imgui.PopFont()
            Gear(gearLabel, c.x + 6 + NAV_SHIFT + tw + 6, c.y + 2)
        end
        if pg == 1 then                                           -- кнопка перехода на страницу объектов (только на первой странице)
            imgui.SetCursorScreenPos(P(c0.x + 26 - 84, c0.y))
            if MiniButton('Objects', 84, 26) then
                SOFT.rpage = 2
                SOFT.t0 = os.clock()                              -- страница появляется с той же анимацией
            end
        end
        imgui.SetCursorScreenPos(c)
        local pressed = imgui.InvisibleButton('##rnd_back', P(26, 26))
        Hint('Back')
        local h = animTo('rnd_back', imgui.IsItemHovered() and 1 or 0, 14)
        dl:AddRectFilled(c, P(c.x + 26, c.y + 26), C(mix(pal.field, pal.fieldH, h), 0.95), 6)
        dl:AddRectFilled(c, P(c.x + 26, c.y + 26), C(THEME.main, 0.10 * h), 6)
        local col = C(mix(pal.dim, THEME.main, math.max(h, 0.35)))
        if not FNT.drawIcon(dl, 'ARROW_LEFT', 14, c.x + 13, c.y + 13, col) then      -- без шрифта иконок - нарисованная стрелка
            dl:AddLine(P(c.x + 17, c.y + 13), P(c.x + 9, c.y + 13), col, 2)
            dl:AddLine(P(c.x + 9, c.y + 13), P(c.x + 13, c.y + 9), col, 2)
            dl:AddLine(P(c.x + 9, c.y + 13), P(c.x + 13, c.y + 17), col, 2)
        end
        if pressed then
            if pg == 2 then                                       -- со страницы объектов - на первую страницу Render, не к плиткам
                SOFT.rpage = 1
                SOFT.t0 = os.clock()
            else
                SOFT.setPage(nil)
            end
        end
    end

    -- переключатель в шапке панели (у правого края), того же вида, что и в строках
    local function HeaderToggle(id, label, ptr)
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local c = imgui.GetCursorScreenPos()                      -- Panel ставит курсор в (правый край - 42, верх + 7)
        local tx, ty = c.x - 8, c.y + 4                           -- правый край переключателя = правый край шапки - 16
        imgui.SetCursorScreenPos(P(tx - 3, c.y))
        if imgui.InvisibleButton('##ht' .. id, P(40, 26)) then ptr[0] = not ptr[0] end
        Hint(label)
        Highlight(label, P(tx - 3, c.y), 40, 26)
        local t = animTo('ht' .. id, ptr[0] and 1 or 0, 14)
        local tmain = THEME.main
        if t > 0.01 then
            dl:AddRectFilled(P(tx - 3, ty - 3), P(tx + 37, ty + 21), C(tmain, 0.14 * t), 12)
        end
        dl:AddRectFilled(P(tx, ty), P(tx + 34, ty + 18), C(mix(pal.track, tmain, t)), 9)
        dl:AddCircleFilled(P(tx + 9 + 16 * t, ty + 9), 6.5, C(mix(pal.dim, pal.white, t)), 20)
    end

    local function RenderPage(pg)
        if pg == 2 then
            Panel('Server objects', 0, 0, LAY.COLW, 240, function()
                TextGear('Object render settings')                -- шестерёнка: линии, лимит и макс. дистанция для объектов
                imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 3))
                ColorCheckbox(R.ALLOBJ)
                Checkbox('Enable custom objects', B('rnd_objcustom', false))
                for i = 1, R.OBJSLOTS do ColorObj(i) end
                imgui.PopStyleVar()
            end, nil, nil, function() HeaderNav(2) end, NAV_SHIFT)
            return
        end
        Panel('Resources', 0, 0, LAY.COLW, LAY.CH, function()
            TextGear('Render settings')
            for _, e in ipairs(BOXES) do ColorCheckbox(e) end
        end, nil, nil, function() HeaderNav(1) end, NAV_SHIFT)
        -- у правых панелей строки теснее (отступ 3 px), чтобы в "3D texts" влезли все пять строк
        Panel('Graffiti', LAY.COLW + 14, 0, LAY.COLW, 264, function()
            if SRCH.collecting then Reg('Graffiti', 'Checkbox') end        -- главный переключатель (в шапке панели)
            local dim = not B('rnd_graffiti', true)[0] and not SRCH.collecting     -- выключено: пункты приглушены
            local ga = gfx.galpha
            if dim then
                gfx.galpha = ga * 0.45
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.45)
            end
            imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 3))
            Checkbox('Only available to paint over', B('rnd_only_paint', false))
            for _, e in ipairs(GANGS) do ColorCheckbox(e) end
            imgui.PopStyleVar()
            if dim then
                imgui.PopStyleVar()
                gfx.galpha = ga
            end
        end, nil, nil, function() HeaderToggle('graffiti', 'Graffiti', B('rnd_graffiti', true)) end)
        Panel('3D texts', LAY.COLW + 14, 278, LAY.COLW, LAY.CH - 278, function()
            if SRCH.collecting then RegSettings('3D texts') end
            imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 3))
            ColorCheckbox(R.ALL3D)
            Checkbox('Enable custom text', B('rnd_custom', false))
            for i = 1, R.SLOTS do ColorText(i) end
            imgui.PopStyleVar()
        end, nil, nil, function()
            -- шестерёнка сразу справа от названия панели (настройки лимита дистанции)
            local c = imgui.GetCursorScreenPos()                  -- Panel ставит курсор в (правый край - 42, верх + 7)
            imgui.PushFont(fonts.bold)
            local tw = imgui.CalcTextSize(u8(tr('3D texts'))).x
            imgui.PopFont()
            Gear('3D texts', c.x - (LAY.COLW - 42) + 16 + tw + 6, c.y + 2)
        end)
    end

    SOFT.drawRender = function()
        if SRCH.collecting then                                   -- в поиск попадают обе страницы
            for pg = 1, 2 do
                SRCH.collecting.rpage = pg
                RenderPage(pg)
            end
            SRCH.collecting.rpage = nil
            return
        end
        RenderPage(SOFT.rpage)
    end
end

-- ---------- 2. TOOLS ----------
-- Подвкладки Debug и Console - инструменты разработчика (реализация в разделе "Инструменты разработчика" ниже).
-- Кнопки из UltraTool, переделанные под это меню. Действия лежат в таблице Tools (раздел "Инструменты" ниже);
-- Tools.run(...) выполняет действие с защитой от ошибок и показывает ошибку уведомлением.
-- Button(..., hold): 5-й аргумент - секунды удержания для опасных действий.
content[2] = {
    function() -- Character
        Panel('Teleport', 0, 0, LAY.COLW, 216, function()
            if Button('Teleport to marker', 34, false, nil, nil, 'LOCATION_DOT') then Tools.run(Tools.teleportMarker) end
            if Button('Teleport to checkpoint', 34, false, nil, nil, 'FLAG_CHECKERED') then Tools.run(Tools.teleportCheckpoint) end
            if Button('Slap up', 34, false, nil, nil, 'ARROW_UP') then Tools.run(Tools.slapUp) end
            if Button('Slap down', 34, false, nil, nil, 'ARROW_DOWN') then Tools.run(Tools.slapDown) end
        end)
        Panel('Character', LAY.COLW + 14, 0, LAY.COLW, 176, function()
            if Button('Unfreeze', 34, false, nil, nil, 'UNLOCK') then Tools.run(Tools.unfreeze) end
            if Button('Respawn', 34, false, nil, nil, 'ROTATE_RIGHT') then Tools.run(Tools.respawn) end
            if Button('Die', 34, false, nil, nil, 'SKULL') then Tools.run(Tools.die) end
        end)
        Panel('Repair', 0, 230, LAY.COLW, 136, function()
            if Button('Fix wheels', 34, false, nil, nil, 'TRUCK_MONSTER') then Tools.run(Tools.fixWheels) end
            if Button('Fix car', 34, false, nil, nil, 'WRENCH') then Tools.run(Tools.fixCar) end
        end)
    end,
    function() -- Server
        Panel('Connection', 0, 0, LAY.COLW, 176, function()
            if Button('Connect', 34, false, nil, nil, 'PLUG') then Tools.run(Tools.connect) end
            if Button('Disconnect', 34, false, nil, nil, 'LINK_SLASH') then Tools.run(Tools.disconnect) end
            if Button('Close connection', 34, false, nil, nil, 'CIRCLE_XMARK') then Tools.run(Tools.closeConnection) end
        end)
        Panel('Chat and dialogs', LAY.COLW + 14, 0, LAY.COLW, 176, function()
            if Button('Clear chat', 34, false, nil, nil, 'BROOM') then Tools.run(Tools.clearChat) end
            if Button('Hide dialog', 34, false, nil, nil, 'EYE_SLASH') then Tools.run(Tools.hideDialog) end
            if Button('Show dialog', 34, false, nil, nil, 'EYE') then Tools.run(Tools.showDialog) end
        end)
    end,
    function() -- Script
        Panel('Control', 0, 0, LAY.COLW, 136, function()
            if Button('Reload script', 34, false, nil, nil, 'ARROWS_ROTATE') then Tools.run(Tools.reloadScript) end
            if Button('Unload script', 34, false, nil, nil, 'POWER_OFF') then Tools.run(Tools.unloadScript) end
        end)
        Panel('Script files', LAY.COLW + 14, 0, LAY.COLW, 136, function()
            if Button('Hide script files', 34, false, nil, nil, 'FOLDER_MINUS') then Tools.run(Tools.hideFiles) end
            if Button('Show script files', 34, false, nil, nil, 'FOLDER_OPEN') then Tools.run(Tools.showFiles) end
        end)
        Panel('Danger zone', 0, 150, LAY.COLW, 136, function()
            if Button('Delete script', 34, false, nil, 2, 'TRASH') then Tools.run(Tools.deleteScript) end
            if Button('Crash game', 34, false, nil, 2, 'BOMB') then Tools.run(Tools.crashGame) end
        end)
    end,
    function() -- Debug
        -- 10 строк по 28 px (22 + отступ) не помещались в старую панель, поэтому всё, что ниже FPS, было обрезано
        Panel('Info', 0, 0, LAY.COLW, 342, function()
            if SRCH.collecting then return end
            local s = Dev.snapshot()
            InfoRow('Position', s.x and string.format('%.2f, %.2f, %.2f', s.x, s.y, s.z) or '-')
            InfoRow('Heading', s.heading and string.format('%.1f', s.heading) or '-')
            InfoRow('Interior', s.interior and tostring(s.interior) or '-')
            InfoRow('Vehicle', s.model and string.format('%s [%d]  #%s', s.carName or '?', s.model, s.vehId and tostring(s.vehId) or '-') or tr('On foot'))
            InfoRow('Player ID', s.id and tostring(s.id) or '-')
            InfoRow('Skin ID', s.skin and tostring(s.skin) or '-')
            InfoRow('Ping', s.ping and string.format('%d %s', s.ping, tr('ms')) or '-')
            InfoRow('FPS', string.format('%d  (%.1f %s)', math.floor(s.fps + 0.5), 1000 / math.max(s.fps, 1), tr('ms')))
            InfoRow('Lua memory', string.format('%.2f %s', s.mem / 1024, tr('MB')))
            InfoRow('Uptime', Dev.uptime())
        end)
        Panel('Runtime', 0, 356, LAY.COLW, 120, function()
            if Button('Collect garbage', 34) then Tools.run(Dev.collect) end
            if SRCH.collecting then return end
            local g = Dev.lastGc
            InfoRow('Last cleanup', g and string.format('%s  %.2f %s', g.t, g.mb, tr('MB')) or '-')
        end)
        Panel('Overlay', LAY.COLW + 14, 0, LAY.COLW, 300, function()
            Checkbox('Debug overlay', B('dev_overlay', false))
            Checkbox('Show performance', B('dev_ov_perf', true))
            Checkbox('Show server IP', B('dev_ov_ip', true))
            Checkbox('Show position', B('dev_ov_pos', true))
            Checkbox('Show vehicle', B('dev_ov_veh', true))
            Checkbox('Show last animation', B('dev_ov_anim', true))
            Checkbox('Show last event', B('dev_ov_event', true))
        end)
        Panel('Clipboard', LAY.COLW + 14, 314, LAY.COLW, 154, function()
            if Button('Copy position', 28) then Tools.run(Dev.copyXYZ) end
            if Button('Copy position and heading', 28) then Tools.run(Dev.copyXYZH) end
            if Button('Copy as Lua code', 28) then Tools.run(Dev.copyLuaCode) end
        end)
    end,
    function() -- Console
        Panel('Log', 0, 0, LAY.CW, 300, LogView, true, true)
        Panel('Lua console', 0, 314, LAY.CW, 158, function()
            if SRCH.collecting then                                 -- для поиска по функциям: только регистрация кнопок
                MiniButton('Run'); MiniButton('Copy log'); MiniButton('Clear log')
                return
            end
            Dev.input = Dev.input or imgui.new.char[512]()
            imgui.PushFont(fonts.small)
            imgui.TextColored(imgui.ImVec4(pal.dim[1], pal.dim[2], pal.dim[3], gfx.galpha), u8(tr('Code (Enter to run)')))
            imgui.PopFont()
            imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
            local entered = imgui.InputText('##dev_lua', Dev.input, ffi.sizeof(Dev.input), imgui.InputTextFlags.EnterReturnsTrue)
            if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
            if entered then
                Dev.runInput()
                imgui.SetKeyboardFocusHere(-1)                 -- после Enter курсор остаётся в поле
            end
            imgui.Dummy(imgui.ImVec2(1, 6))
            if MiniButton('Run', 80, 28, true) then Dev.runInput() end
            imgui.SameLine(nil, 8)
            if MiniButton('Copy log', 100, 28) then Tools.run(Dev.copyLog) end
            imgui.SameLine(nil, 8)
            if MiniButton('Clear log', 100, 28) then Dev.clear() end
        end)
    end,
    function() -- Inspector
        Panel('Dialogs', 0, 0, LAY.COLW, 244, function()
            Checkbox('Dialog ID in title', B('dev_dlg_title', false))
            Checkbox('Log dialogs', B('dev_dlg_log', false))
            if SRCH.collecting then Button('Copy dialog ID', 34) return end
            local d = Dev.dlg
            InfoRow('Last dialog ID', d and tostring(d.id) or '-')
            InfoRow('Dialog style', d and (Dev.DLG_STYLES[d.style] or tostring(d.style)) or '-')
            InfoRow('Dialog title', d and Dev.short(d.title, 24) or '-')
            if Button('Copy dialog ID', 34) then Tools.run(Dev.copyDialogId) end
        end)
        Panel('Chat colors', 0, 256, LAY.COLW, 220, function()
            Checkbox('Color in chat messages', B('dev_chat_color', false))
            Combo('Color format', I('dev_chat_fmt', 0), {'Number', 'Hex RRGGBB', 'Number and hex'})
            if SRCH.collecting then Button('Copy last color', 34) return end
            InfoRow('Last chat color', Dev.chatColorStr or '-')
            if Button('Copy last color', 34) then Tools.run(Dev.copyChatColor) end
        end)
        Panel('TextDraws', LAY.COLW + 14, 0, LAY.COLW, 250, function()
            Checkbox('Show textdraw IDs', B('dev_td_show', false))
            Checkbox('Show textdraw text', B('dev_td_text', false))
            Checkbox('Track textdraw clicks', B('dev_td_click', false))
            if SRCH.collecting then Button('Copy clicked ID', 34) return end
            InfoRow('Textdraws on screen', B('dev_td_show', false)[0] and tostring(Dev.tdCount) or '-')
            local c = Dev.tdClicks[1]
            InfoRow('Last clicked ID', c and (c.id == 65535 and 'cancel' or tostring(c.id)) or '-')
            if Button('Copy clicked ID', 34) then Tools.run(Dev.copyTdId) end
        end)
        Panel('Click history', LAY.COLW + 14, 264, LAY.COLW, 212, function()
            if SRCH.collecting then return end
            local cl = Dev.tdClicks
            if #cl == 0 then Text('No clicks yet.', pal.dim) return end
            for i = 1, math.min(5, #cl) do
                local c = cl[i]
                InfoRow(c.t, c.id == 65535 and 'cancel' or ('ID ' .. c.id .. (c.str ~= '' and ('  ' .. c.str) or '')))
            end
        end)
    end,
}

-- ---------- 3. SOFTWARE ----------
-- Вкладка с большими плитками-программами (как "Админ ПО" в arztools): сетка 4 в ряд, у плитки иконка,
-- название и описание в две строки. Клик открывает страницу программы внутри вкладки (кнопка "Back" - назад).
-- Добавить новую: запись в SOFT.list и функция отрисовки страницы SOFT.draw[id].
SOFT.list = {
    {id = 'notepad', icon = 'NOTE_STICKY', title = 'Notepad', desc = {'Your notes', 'and reminders'}, full = true},
    -- full: страница рисует свои панели сама (без внешней панели и кнопки Back); index: её элементы попадают в поиск
    {id = 'render', icon = 'EYE', title = 'Render', desc = {'Resources, 3D texts', 'and server objects'}, full = true, index = true},
    {id = 'admins', icon = 'USER_SHIELD', title = 'Admin checker', desc = {'Online admins', 'and the admin list'}, full = true, index = true},
    {id = 'farchat', icon = 'COMMENTS', title = 'Far chat', desc = {'Nearby player chat', 'with word rules'}, full = true, index = true},
    {id = 'skins', icon = 'USER', title = 'Skin changer', desc = {'Visual skin', 'from the full list'}, full = true, index = true},
    {id = 'connector', icon = 'SERVER', title = 'Server connector', desc = {'Join any', 'Arizona server'}, full = true, index = true},
    {id = 'telegram', icon = 'PAPER_PLANE', title = 'Telegram', desc = {'Notifications and', 'messages via bot'}, full = true, index = true},
    {id = 'evlog', icon = 'LIST_UL', title = 'Event logger', desc = {'Events, animations', 'and CEF log'}, full = true, index = true},
    {id = 'captcha', icon = 'ROBOT', title = 'Captcha trainer', desc = {'Check practice', 'with a stopwatch'}, full = true, index = true},
    {id = 'income', icon = 'COINS', title = 'Income tracker', desc = {'Rent, payday, oil rigs', 'and taxi per server'}, full = true, index = true},
    {id = 'autoad', icon = 'BULLHORN', title = 'Auto PR', desc = {'Auto messages to chat', 'with game items'}, full = true, index = true},
    {id = 'scripts', icon = 'CLOUD_ARROW_DOWN', title = 'Script store', desc = {'Download scripts', 'from GitHub'}, full = true, index = true},
    {id = 'reminder', icon = 'BELL', title = 'Reminder', desc = {'Alerts at a set time', 'with a comment'}, full = true, index = true},
    {id = 'vcar', icon = 'CAR_SIDE', title = 'Visual vehicle', desc = {'Drive any vehicle', 'from the full list'}, full = true, index = true},
    {id = 'jobs', icon = 'BRIEFCASE', title = 'Jobs Helper', desc = {'Helpers for different', 'jobs in one place'}, full = true, index = true},
    {id = 'speedx', icon = 'GAUGE_HIGH', title = 'Speed Boost', desc = {'Vehicle acceleration', 'on a key'}, full = true, index = true},
    {id = 'coordmaster', icon = 'ROUTE', title = 'Coord Master', desc = {'Teleport to the marker'}, full = true, index = true},
}
SOFT.page = nil          -- id открытой программы; nil - показана сетка плиток
SOFT.draw = {render = SOFT.drawRender}      -- страницы программ; Render определён выше (в разделе Render)
SOFT.t0 = os.clock() - 10   -- момент последней смены страницы (для анимации появления)
SOFT.TILE_H, SOFT.TILE_GAP, SOFT.COLS = 79, 8, 4

-- открыть программу (id) или вернуться к сетке (nil) и запустить анимацию появления
function SOFT.setPage(id)
    if SOFT.page == id then return end
    SOFT.page, SOFT.t0 = id, os.clock()
    if ctl.jobs then ctl.jobs.sub = nil end
end

-- прогресс появления 0..1 с задержкой delay (сек); учитывает "Animation speed" из настроек
function SOFT.k(delay)
    local dur = 0.30 / math.max(ui.animSpeed[0], 0.05)
    local t = clamp((os.clock() - SOFT.t0 - (delay or 0)) / dur, 0, 1)
    return 1 - (1 - t) ^ 3
end

-- плитка в ячейке (col, row) сетки; возвращает true по клику
-- строка (перевод) по ширине maxW: если не помещается, обрезается с «..»
function SOFT.fit(s, maxW)
    s = tr(s)
    if imgui.CalcTextSize(u8(s)).x <= maxW then return u8(s) end
    while #s > 1 and imgui.CalcTextSize(u8(s .. '..')).x > maxW do s = s:sub(1, -2) end
    return u8(s .. '..')
end

function SOFT.tile(item, col, row, x0, y0, tw)
    if SRCH.collecting then Reg(item.title, 'Program') return false end
    local P = imgui.ImVec2
    local id = '##tile' .. item.id
    local dl = imgui.GetWindowDrawList()
    local TH = SOFT.TILE_H
    local x, y = x0 + col * (tw + SOFT.TILE_GAP), y0 + row * (TH + SOFT.TILE_GAP)
    imgui.SetCursorScreenPos(P(x, y))
    local pressed = imgui.InvisibleButton(id, P(tw, TH))
    Highlight(item.title, P(x, y), tw, TH)
    local h = animTo(id, imgui.IsItemHovered() and 1 or 0, 14)
    local dn = animTo(id .. 'dn', imgui.IsItemActive() and 1 or 0, 22)         -- тактильное "вдавливание"
    if pressed then
        local m = imgui.GetIO().MousePos
        gfx.ripples[id] = {t = os.clock(), x = m.x, y = m.y}
    end
    local k = SOFT.k((row * SOFT.COLS + col) * 0.05)                              -- плитки появляются по очереди
    local ga = gfx.galpha
    gfx.galpha = ga * k
    y = y + (1 - k) * 12
    local pmax = P(x + tw, y + TH)
    local ins = dn * 2.5
    x, y, pmax = x + ins, y + ins, P(pmax.x - ins, pmax.y - ins)
    dl:AddRectFilled(P(x, y), pmax, C(mix(pal.field, pal.fieldH, h)), 6)
    local r = gfx.ripples[id]
    if r then                                                                      -- круг от места клика
        local age = os.clock() - r.t
        if age < 0.55 then
            dl:PushClipRect(P(x, y), pmax, true)
            dl:AddCircleFilled(P(r.x, r.y), (age / 0.55) * tw * 0.9, C(THEME.main, 0.30 * (1 - age / 0.55)), 40)
            dl:PopClipRect()
        else
            gfx.ripples[id] = nil
        end
    end
    dl:AddRect(P(x, y), pmax, C(mix(pal.border, THEME.main, math.max(h, dn))), 6)
    -- большая иконка справа, как водяной знак (у arztools - картинка на всю плитку)
    local ic = C(THEME.main, 0.28 + 0.4 * h)
    if not FNT.drawIcon(dl, item.icon, 24, x + tw - 26, y + TH - 26, ic) then
        dl:AddCircleFilled(P(x + tw - 26, y + TH - 26), 8, ic, 16)
    end
    imgui.PushFont(fonts.bold)
    dl:AddText(P(x + 10, y + 9), C(mix(pal.text, THEME.main, h * 0.35)), SOFT.fit(item.title, tw - 20))
    imgui.PopFont()
    imgui.PushFont(fonts.small)
    for n, line in ipairs(item.desc) do
        dl:AddText(P(x + 10, y + 33 + (n - 1) * 15), C(pal.dim), SOFT.fit(line, tw - 20))
    end
    imgui.PopFont()
    gfx.galpha = ga
    return pressed
end

-- Шапка полноэкранной страницы: стрелка "Назад" слева (та же, что у Render и Admin checker) и, если нужно,
-- переключатель справа. Вызывается как headerAction панели: курсор там - правый край шапки (x панели + w - 42, y + 7).
-- w - ширина панели, label/ptr - необязательный переключатель.
function SOFT.pageHeader(id, w, label, ptr)
    local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
    local c0 = imgui.GetCursorScreenPos()
    if ptr then
        local tx, ty = c0.x - 8, c0.y + 4
        imgui.SetCursorScreenPos(P(tx - 3, c0.y))
        if imgui.InvisibleButton('##pht' .. id, P(40, 26)) then ptr[0] = not ptr[0] end
        Hint(label)
        Highlight(label, P(tx - 3, c0.y), 40, 26)
        local t = animTo('pht' .. id, ptr[0] and 1 or 0, 14)
        local tmain = THEME.main
        if t > 0.01 then
            dl:AddRectFilled(P(tx - 3, ty - 3), P(tx + 37, ty + 21), C(tmain, 0.14 * t), 12)
        end
        dl:AddRectFilled(P(tx, ty), P(tx + 34, ty + 18), C(mix(pal.track, tmain, t)), 9)
        dl:AddCircleFilled(P(tx + 9 + 16 * t, ty + 9), 6.5, C(mix(pal.dim, pal.white, t)), 20)
    end
    local c = P(c0.x - (w - 42) + 10, c0.y)
    imgui.SetCursorScreenPos(c)
    local pressed = imgui.InvisibleButton('##phb' .. id, P(26, 26))
    Hint('Back')
    local h = animTo('phb' .. id, imgui.IsItemHovered() and 1 or 0, 14)
    dl:AddRectFilled(c, P(c.x + 26, c.y + 26), C(mix(pal.field, pal.fieldH, h), 0.95), 6)
    dl:AddRectFilled(c, P(c.x + 26, c.y + 26), C(THEME.main, 0.10 * h), 6)
    local col = C(mix(pal.dim, THEME.main, math.max(h, 0.35)))
    if not FNT.drawIcon(dl, 'ARROW_LEFT', 14, c.x + 13, c.y + 13, col) then
        dl:AddLine(P(c.x + 17, c.y + 13), P(c.x + 9, c.y + 13), col, 2)
        dl:AddLine(P(c.x + 9, c.y + 13), P(c.x + 13, c.y + 9), col, 2)
        dl:AddLine(P(c.x + 9, c.y + 13), P(c.x + 13, c.y + 17), col, 2)
    end
    if pressed then
        if SOFT.back then SOFT.back() else SOFT.setPage(nil) end              -- внутри Jobs Helper «Назад» ведёт к списку работ
    end
end

-- ----- Блокнот -----
-- Текст хранится в moonloader\\config\\xMercy\\Collapse\\files\\notepad.txt (UTF-8) и сохраняется сам:
-- через секунду после последней правки, при потере фокуса поля, при выгрузке скрипта.
SOFT.NOTE_MAX = 32768
SOFT.note = {buf = nil, loaded = false, dirty = false, saveAt = 0, focus = false, undo = nil}

function SOFT.notePath() return FNT.filesDir() .. '\\notepad.txt' end

function SOFT.noteInit()
    local n = SOFT.note
    if not n.buf then n.buf = imgui.new.char[SOFT.NOTE_MAX]() end
    if not n.loaded then
        n.loaded = true
        local f = io.open(SOFT.notePath(), 'rb')
        if f then
            local text = f:read('*a') or ''
            f:close()
            ffi.copy(n.buf, text:sub(1, SOFT.NOTE_MAX - 1))
        end
    end
    return n
end

function SOFT.noteSave()
    local n = SOFT.note
    if not (n.buf and n.loaded) then return end
    pcall(FNT.ensureFilesDir)
    local f = io.open(SOFT.notePath(), 'wb')
    if f then
        f:write(ffi.string(n.buf))
        f:close()
        n.dirty = false
    end
end

-- вызывается из главного цикла: отложенное сохранение после правки
function SOFT.tick()
    local n = SOFT.note
    if n.dirty and os.clock() >= n.saveAt then SOFT.noteSave() end
end

SOFT.noteBody = function()
    if SRCH.collecting then return end
    local P = imgui.ImVec2
    local n = SOFT.noteInit()
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local avail = imgui.GetContentRegionAvail()
    local w, fh = avail.x, avail.y - 44

    -- рамка цвета темы вокруг активного поля
    local f = animTo('notefocus', n.focus and 1 or 0, 14)
    if f > 0.01 then
        dl:AddRectFilled(P(p.x - 1, p.y - 1), P(p.x + w + 1, p.y + fh + 1), C(THEME.main, f), 7)
    end
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(10, 8))
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
    local edited = imgui.InputTextMultiline('##notepad_text', n.buf, SOFT.NOTE_MAX, P(w, fh),
        imgui.InputTextFlags.AllowTabInput)
    imgui.PopStyleVar(2)
    local active = imgui.IsItemActive()
    n.focus = active
    if active and ui.open[0] then ui.fieldActive = true end
    if edited then n.dirty, n.saveAt, n.undo = true, os.clock() + 1.0, nil end
    if imgui.IsItemDeactivatedAfterEdit() then SOFT.noteSave() end
    if ffi.string(n.buf) == '' and not active then       -- подсказка в пустом поле
        dl:AddText(P(p.x + 10, p.y + 8), C(pal.dim, 0.7), u8(tr('Type your notes here...')))
    end

    -- нижняя строка: слева состояние, справа кнопки
    local q = imgui.GetCursorScreenPos()
    local len = #ffi.string(n.buf)
    imgui.PushFont(fonts.small)
    dl:AddText(P(q.x, q.y + 11), C(pal.dim, 0.8), u8(tr('Saved automatically') .. '  |  ' .. len .. ' / ' .. (SOFT.NOTE_MAX - 1)))
    imgui.PopFont()
    imgui.SetCursorScreenPos(P(q.x + w - 184, q.y + 4))
    if MiniButton('Copy', 88, 28) then
        local ok, raw = pcall(function() return u8:decode(ffi.string(n.buf)) end)
        if ok and raw ~= '' then
            setClipboardText(raw)
            NotifyOk('Copied to the clipboard')
        else
            NotifyErr('Nothing to copy')
        end
    end
    imgui.SameLine(nil, 8)
    if n.undo then
        if MiniButton('Undo', 88, 28) then                -- вернуть стёртое
            ffi.copy(n.buf, n.undo)
            n.undo, n.dirty, n.saveAt = nil, true, os.clock() + 1.0
        end
    elseif MiniButton('Clear', 88, 28) and len > 0 then
        n.undo = ffi.string(n.buf)
        ffi.fill(n.buf, SOFT.NOTE_MAX)
        n.dirty, n.saveAt = true, os.clock() + 1.0
    end
end

-- Блокнот - полноэкранная страница: кнопка Back в шапке панели, как у Render и Admin checker
SOFT.draw.notepad = function()
    Panel('Notepad', 0, 0, LAY.CW, LAY.CH, SOFT.noteBody, nil, nil, function()
        SOFT.pageHeader('note', LAY.CW)
    end, 30)
end

-- ----- Админ-чекер -----
-- Список админов лежит в moonloader\config\xMercy\Collapse\files\admins.txt и ОБЩИЙ для всех конфигов
-- (в самих конфигах хранятся только настройки: включение, интервал, оверлей). Строка файла: ник|ip:порт|название сервера (cp1251).
-- Админ считается онлайн, только если ник совпал на том же сервере (ip:порт), где он был добавлен:
-- такой же ник на другом сервере игнорируется. Добавление - по ID игрока на текущем сервере (ник берётся у сервера).
-- Редактор списка (просмотр, добавление, удаление) открывается кнопкой "Admin list" и устроен так же, как редактор фраз в Chat.
do
    local A = {}
    SOFT.adm = A
    A.list, A.labels, A.loaded = {}, {}, false     -- записи {nick, server, label}; server -> название; список прочитан из файла
    A.server, A.serverName = nil, ''               -- текущий сервер (ip:порт) и его название
    A.online, A.onSet = {}, {}                     -- админы онлайн {id, nick}; они же по нику в нижнем регистре
    A.lookup, A.dirty = {}, true                   -- ники текущего сервера -> запись; dirty: пересобрать lookup и проверить сразу
    A.lastScan, A.firstScan = -100, true           -- время последней проверки; первая проверка на сервере идёт без уведомлений
    A.open, A.tab, A.hl, A.refocus = false, 1, nil, false   -- редактор: открыт; вкладка (1 - этот сервер, 2 - все); мигающая запись
    -- адреса серверов Arizona -> номер сервера (из #ArzMarket): домен и IP одного сервера дают один номер
    A.HOSTS = {
        ["yava.arizona-rp.com"] = 25,
        ["chandler.arizona-rp.com"] = 4,
        ["mesa.arizona-rp.com"] = 7,
        ["185.169.134.173"] = 14,
        ["saintrose.arizona-rp.com"] = 6,
        ["80.66.82.39"] = 29,
        ["redrock.arizona-rp.com"] = 8,
        ["payson.arizona-rp.com"] = 15,
        ["80.66.82.33"] = 30,
        ["185.169.134.61"] = 8,
        ["glendale.arizona-rp.com"] = 12,
        ["80.66.82.168"] = 19,
        ["80.66.82.200"] = 21,
        ["80.66.82.132"] = 23,
        ["queencreek.arizona-rp.com"] = 21,
        ["80.66.82.82"] = 26,
        ["80.66.82.199"] = 32,
        ["185.169.134.172"] = 13,
        ["winslow.arizona-rp.com"] = 14,
        ["185.169.134.4"] = 2,
        ["80.66.82.87"] = 27,
        ["space.arizona-rp.com"] = 32,
        ["185.169.134.5"] = 6,
        ["drake.arizona-rp.com"] = 31,
        ["bumblebee.arizona-rp.com"] = 27,
        ["mirage.arizona-rp.com"] = 29,
        ["185.169.134.174"] = 15,
        ["page.arizona-rp.com"] = 19,
        ["185.169.134.166"] = 11,
        ["80.66.82.128"] = 24,
        ["scottdale.arizona-rp.com"] = 3,
        ["185.169.134.171"] = 12,
        ["casagrande.arizona-rp.com"] = 18,
        ["80.66.82.113"] = 25,
        ["yuma.arizona-rp.com"] = 9,
        ["tucson.arizona-rp.com"] = 2,
        ["christmas.arizona-rp.com"] = 28,
        ["80.66.82.190"] = 17,
        ["holiday.arizona-rp.com"] = 23,
        ["80.66.82.191"] = 16,
        ["gilbert.arizona-rp.com"] = 16,
        ["brainburg.arizona-rp.com"] = 5,
        ["185.169.134.44"] = 4,
        ["185.169.134.107"] = 9,
        ["80.66.82.147"] = 0,
        ["showlow.arizona-rp.com"] = 17,
        ["185.169.134.43"] = 3,
        ["80.66.82.188"] = 18,
        ["surprise.arizona-rp.com"] = 10,
        ["prescott.arizona-rp.com"] = 11,
        ["80.66.82.159"] = 20,
        ["80.66.82.144"] = 22,
        ["suncity.arizona-rp.com"] = 20,
        ["185.169.134.109"] = 10,
        ["vicecity.arizona-rp.com"] = 0,
        ["185.169.134.59"] = 7,
        ["kingman.arizona-rp.com"] = 13,
        ["80.66.82.22"] = 31,
        ["185.169.134.45"] = 5,
        ["185.169.134.3"] = 1,
        ["80.66.82.54"] = 28,
        ["phoenix.arizona-rp.com"] = 1,
        ["faraway.arizona-rp.com"] = 26,
        ["sedona.arizona-rp.com"] = 22,
        ["wednesday.arizona-rp.com"] = 24,
        ["love.arizona-rp.com"] = 30,
    }
    A.keyMap = {}                                  -- старый ключ сервера -> общий ключ (после объединения серверов с одним именем)
    A.sel = nil                                    -- вкладка "Все серверы": выбранный сервер (ip:порт); nil - показан список серверов
    A.posEdit, A.posT0 = false, 0                  -- режим выбора места панели на экране (меню при этом скрыто)
    A.demo = {                                     -- примерные строки панели в режиме выбора места (по возрастанию ID)
        {id = 3, nick = 'Alex_Morgan'}, {id = 7, nick = 'Daniel_Frost'}, {id = 12, nick = 'Maksim_Volkov'},
        {id = 18, nick = 'Viktor_Sokolov'}, {id = 25, nick = 'Artem_Kovalev'}, {id = 31, nick = 'Nikita_Belov'},
        {id = 44, nick = 'Roman_Orlov'}, {id = 58, nick = 'Denis_Smirnov'}, {id = 73, nick = 'Ilya_Zaytsev'},
        {id = 96, nick = 'Sergey_Lebedev'},
    }
    A.MAX_ADMINS = 500
    A.q, A.edit, A.editT0, A.editFocus = '', nil, 0, false   -- поиск по нику; карточка уровня (запись / время открытия / фокус)

    -- положение левого верхнего угла панели в процентах экрана (в старых конфигах adm_x / adm_y были процентами свободного места)
    function A.px() return F('adm_px', ctl.loadedControls.int.adm_x or 0.5) end
    function A.py() return F('adm_py', ctl.loadedControls.int.adm_y or 30) end

    -- буферы ввода создаются по требованию (imgui.new нужен уже после запуска mimgui)
    function A.buf(name, size)
        if not A[name] then A[name] = imgui.new.char[size]() end
        return A[name]
    end

    -- ---------- файл ----------
    function A.path() return FNT.filesDir() .. '\\admins.txt' end

    -- Уровни админов лежат отдельным файлом (формат admins.txt не меняется): сервер|ник|уровень
    function A.levelsPath() return FNT.filesDir() .. '\\admin_levels.txt' end

    function A.loadLevels()
        local map = {}
        local f = io.open(A.levelsPath(), 'rb')
        if f then
            for line in f:lines() do
                local srv, nick, lvl = (line:gsub('\r', '')):match('^([^|]+)|([^|]+)|(%d+)$')
                if srv then map[srv .. '|' .. lower(nick)] = lvl end
            end
            f:close()
        end
        for k, v in pairs(map) do                                   -- ключи серверов, объединённых по имени
            local srv, ln = k:match('^([^|]+)|(.+)$')
            local nk = srv and A.keyMap[srv]
            if nk and map[nk .. '|' .. ln] == nil then map[nk .. '|' .. ln] = v end
        end
        for _, e in ipairs(A.list) do e.level = map[e.server .. '|' .. lower(e.nick)] end
    end

    function A.saveLevels()
        pcall(FNT.ensureFilesDir)
        local out = {}
        for _, e in ipairs(A.list) do
            if e.level then out[#out + 1] = e.server .. '|' .. e.nick .. '|' .. e.level end
        end
        local f = io.open(A.levelsPath(), 'wb')
        if not f then NotifyErr('Could not save the admin list') return false end
        f:write(table.concat(out, '\n'))
        f:close()
        return true
    end

    -- raw - текст из поля: оставляем только цифры (до 3 знаков), пусто / 0 = уровень не задан
    function A.setLevel(e, raw)
        local s = trim(tostring(raw or '')):gsub('[^%d]', ''):sub(1, 3)
        s = (s:gsub('^0+', ''))
        e.level = (s ~= '') and s or nil
        if A.saveLevels() then
            if e.level then NotifyOk('Admin level saved: %s', e.nick) else Notify('Admin level cleared: %s', e.nick) end
        end
    end

    function A.hasEntry(entry)
        for _, e in ipairs(A.list) do
            if e == entry then return true end
        end
        return false
    end

    function A.cleanLabel(s)
        s = tostring(s or ''):gsub('%c', ' ')            -- '|' в названии допустимо: название - последнее поле строки
        s = trim((s:gsub('%s+', ' ')))
        return s:sub(1, 48)
    end

    -- Ключ сервера: у известных серверов Arizona это "arz<номер>" (домен и IP одного сервера совпадают),
    -- у остальных - ip:порт. Старые записи с адресами переносятся под новый ключ, потом объединяются серверы с одним именем.
    function A.keyFor(ip, port)
        local n = A.HOSTS[ip]
        if n and n >= 0 then return 'arz' .. n end
        return ip .. ':' .. tostring(port or 0)
    end

    function A.mergeByLabel()
        local remap = {}
        for _, e in ipairs(A.list) do                                -- 1) по таблице адресов
            if not remap[e.server] and not e.server:match('^arz%d+$') then
                local host = e.server:match('^(.-):%d+$') or e.server
                local n = A.HOSTS[host]
                if n and n >= 0 then
                    remap[e.server] = 'arz' .. n
                    if A.labels[e.server] and not A.labels['arz' .. n] then A.labels['arz' .. n] = A.labels[e.server] end
                end
            end
        end
        local function key(k) return remap[k] or k end
        local canon = {}
        for _, e in ipairs(A.list) do                                -- 2) по имени (серверы вне таблицы)
            local k = key(e.server)
            local lbl = A.labels[k] or A.labels[e.server]
            if lbl and lbl ~= e.server and lbl ~= k then
                local lk = lower(lbl)
                if not canon[lk] then canon[lk] = k end
                if canon[lk] ~= k then remap[e.server] = canon[lk] end
            end
        end
        if next(remap) == nil then return false end
        local seen, out = {}, {}
        for _, e in ipairs(A.list) do
            e.server = key(e.server)
            local id = e.server .. '|' .. lower(e.nick)
            if not seen[id] then seen[id] = true; out[#out + 1] = e end
        end
        A.list = out
        for old, new in pairs(remap) do
            A.keyMap[old] = new
            if old ~= new then A.labels[old] = nil end
        end
        return true
    end

    function A.load()
        if A.loaded then return end
        A.loaded, A.list, A.labels, A.dirty = true, {}, {}, true
        local f = io.open(A.path(), 'rb')
        if not f then return end
        for line in f:lines() do
            local nick, srv, lbl = (line:gsub('\r', '')):match('^%s*([^|]+)|([^|]+)|?(.*)$')
            if nick then
                nick, srv, lbl = trim(nick), trim(srv), A.cleanLabel(lbl)
                if nick ~= '' and srv ~= '' and #A.list < A.MAX_ADMINS then
                    A.list[#A.list + 1] = {nick = nick, server = srv, label = lbl ~= '' and lbl or srv}
                    if lbl ~= '' and not A.labels[srv] then A.labels[srv] = lbl end
                end
            end
        end
        f:close()
        local merged = A.mergeByLabel()
        A.loadLevels()
        if merged then A.save(); A.saveLevels() end                 -- сохраняем уже объединённый список
    end

    function A.save()
        pcall(FNT.ensureFilesDir)
        local out = {}
        for _, e in ipairs(A.list) do
            out[#out + 1] = e.nick .. '|' .. e.server .. '|' .. (A.labels[e.server] or e.label or '')
        end
        local f = io.open(A.path(), 'wb')
        if not f then NotifyErr('Could not save the admin list') return false end
        f:write(table.concat(out, '\n'))
        f:close()
        return true
    end

    -- ---------- сервер и игроки ----------
    -- сервер = ip:порт (у каждого сервера Arizona свой адрес), название берётся только для показа
    function A.curServer()
        local ok, ip, port = pcall(sampGetCurrentServerAddress)
        if not ok or not ip or ip == '' then return nil end
        local key = A.keyFor(ip, port)
        local label = key:match('^arz(%d+)$') and ('Arizona #' .. key:match('^arz(%d+)$')) or key      -- пока нет имени
        local ok2, nm = pcall(sampGetCurrentServerName)
        if ok2 and nm then
            nm = A.cleanLabel(nm)
            if nm ~= '' then label = nm end
        end
        if label ~= key then                                    -- то же имя под другим адресом - тот же сервер
            A.load()
            local ll = lower(label)
            for k, lbl in pairs(A.labels) do
                if k ~= key and lower(lbl) == ll then key = k break end
            end
        end
        return key, label
    end

    function A.nickById(id)
        local ok, nick = pcall(function()
            local r, mid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if (r and mid == id) or sampIsPlayerConnected(id) then return sampGetPlayerNickname(id) end
        end)
        if ok and nick and nick ~= '' then return nick end
        return nil
    end

    function A.find(nick, server)
        local ln = lower(nick)
        for i, e in ipairs(A.list) do
            if e.server == server and lower(e.nick) == ln then return i, e end
        end
        return nil
    end

    function A.countServer(server)
        if not server then return 0 end
        local n = 0
        for _, e in ipairs(A.list) do
            if e.server == server then n = n + 1 end
        end
        return n
    end

    function A.countText(n)
        if i18n.curLang == 'ru' then
            local m10, m100 = n % 10, n % 100
            local w = 'админов'
            if m10 == 1 and m100 ~= 11 then w = 'админ'
            elseif m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then w = 'админа' end
            return n .. ' ' .. w
        end
        return n .. (n == 1 and ' admin' or ' admins')
    end

    -- текст (cp1251), обрезанный многоточием до maxW пикселей; возвращает UTF-8 строку и её ширину
    function A.fit(s, maxW)
        local txt = u8(s)
        local w = imgui.CalcTextSize(txt).x
        if w > maxW then
            local cut = s
            while #cut > 1 and imgui.CalcTextSize(u8(cut .. '..')).x > maxW do cut = cut:sub(1, -2) end
            txt = u8(cut .. '..')
            w = imgui.CalcTextSize(txt).x
        end
        return txt, w
    end

    -- ---------- добавление / удаление ----------
    -- ник: буквы, цифры и _ [ ] ( ) $ @ = . ; длина 3..24
    function A.validNick(s)
        s = trim(tostring(s or ''))
        if #s < 3 or #s > 24 or s:find('[^%w_%[%]%(%)%$@=%.]') then return nil end
        return s
    end

    -- если игрок с таким ником (без учёта регистра) сейчас на сервере - берём написание сервера
    function A.exactNick(nick)
        local ln = lower(nick)
        local ok, res = pcall(function()
            local r, localId = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if not r then localId = nil end
            for id = 0, sampGetMaxPlayerId(false) do
                if id == localId or sampIsPlayerConnected(id) then
                    local n = sampGetPlayerNickname(id)
                    if n and lower(n) == ln then return n end
                end
            end
        end)
        return ok and res or nil
    end

    -- raw: ID игрока (только цифры) или ник; server: ключ сервера (nil - текущий).
    -- По ID ник берётся у сервера, поэтому ID работает только на текущем сервере; по нику можно добавить и того, кого нет в сети.
    function A.add(raw, server)
        A.load()
        raw = trim(tostring(raw or ''))
        if raw == '' then NotifyErr('Enter an ID or a nickname') return false end
        local cur, curLabel = A.curServer()
        local key = server or cur
        if not key then NotifyErr('Not connected to a server') return false end
        local nick
        if raw:find('^%d+$') then
            if key ~= cur then NotifyErr('ID works only for the current server') return false end
            local id = tonumber(raw)
            if not id or id > 1004 then NotifyErr('Enter a valid player ID') return false end
            nick = A.nickById(id)
            if not nick then NotifyErr('Player with ID %d is not online', id) return false end
        else
            nick = A.validNick(raw)
            if not nick then NotifyErr('Enter a valid nickname') return false end
            if key == cur then nick = A.exactNick(nick) or nick end
        end
        local _, old = A.find(nick, key)
        if old then
            A.hl = {e = old, t0 = os.clock()}
            Notify('This admin is already in the list: %s', nick)
            return false
        end
        if #A.list >= A.MAX_ADMINS then NotifyErr('Could not save the admin list') return false end
        local label = (key == cur) and curLabel or A.labels[key] or key
        A.labels[key] = label
        local e = {nick = nick, server = key, label = label}
        table.insert(A.list, 1, e)
        if not A.save() then table.remove(A.list, 1) return false end
        A.hl = {e = e, t0 = os.clock()}
        A.dirty = true                               -- пересобрать список и проверить сразу
        NotifyOk('Admin added: %s', nick)
        return true
    end

    function A.remove(entry)
        for i, e in ipairs(A.list) do
            if e == entry then table.remove(A.list, i) break end
        end
        A.save()
        if entry.level then entry.level = nil; A.saveLevels() end
        A.dirty = true
        if A.sel and A.countServer(A.sel) == 0 then A.sel = nil end     -- на сервере никого не осталось: назад к списку серверов
        Notify('Admin removed: %s', entry.nick)
    end

    -- серверы из списка: {key, label, n}; текущий сервер первым, остальные по названию
    function A.servers()
        local seen, out = {}, {}
        for _, e in ipairs(A.list) do
            local s = seen[e.server]
            if not s then
                s = {key = e.server, label = A.labels[e.server] or e.label or e.server, n = 0}
                seen[e.server] = s
                out[#out + 1] = s
            end
            s.n = s.n + 1
        end
        table.sort(out, function(a, b)
            local ca, cb = a.key == A.server, b.key == A.server
            if ca ~= cb then return ca end
            local la, lb = lower(a.label), lower(b.label)
            if la ~= lb then return la < lb end
            return a.key < b.key
        end)
        return out
    end

    -- админы онлайн сверху по возрастанию ID, остальные ниже в порядке списка (новые сверху)
    function A.sortItems(items)
        local ord = {}
        for i, a in ipairs(items) do ord[a] = i end
        table.sort(items, function(a, b)
            local oa = (A.server ~= nil and a.server == A.server) and A.onSet[lower(a.nick)] or nil
            local ob = (A.server ~= nil and b.server == A.server) and A.onSet[lower(b.nick)] or nil
            if oa and ob then return oa.id < ob.id end
            if oa then return true end
            if ob then return false end
            return ord[a] < ord[b]
        end)
    end

    -- ---------- автодобавление ----------
    -- Сообщения админов в чате (ник берётся только у отправителя, перед ним может стоять время [чч:мм:сс]):
    --   цвет -10270721: "A: Ник[ID] заблокировал репорт игроку ..." и "Администратор Ник(ID) отправил игрока ..."
    --   цвет -2686721:  "Администратор Ник: текст"
    -- Ник может начинаться с [число], например [31]Force_Mercy. Ник добавляется в список текущего сервера.
    function A.onMessage(color, text)
        if type(color) ~= 'number' or type(text) ~= 'string' then return end
        if color >= 2147483648 then color = color - 4294967296 end
        if color ~= -10270721 and color ~= -2686721 then return end
        if not (B('adm_enable', false)[0] and B('adm_auto', false)[0]) then return end
        local s = text:gsub('{%x%x%x%x%x%x}', ''):gsub('^%s*%[%d+:%d+:%d+%]', ''):gsub('^%s+', '')
        local nick
        if color == -10270721 then
            nick = s:match('^A: (%S+)%[%d+%]') or s:match('^Администратор (%S+)%(%d+%)')
        else
            nick = s:match('^Администратор ([^%s:]+):')
        end
        nick = nick and A.validNick(nick)
        if not nick then return end
        local key, label = A.curServer()
        if not key then return end
        A.load()
        if A.find(nick, key) or #A.list >= A.MAX_ADMINS then return end
        nick = A.exactNick(nick) or nick
        A.labels[key] = label
        local e = {nick = nick, server = key, label = label}
        table.insert(A.list, 1, e)
        if not A.save() then table.remove(A.list, 1) return end
        A.dirty = true
        NotifyOk('Admin added automatically: %s', nick)
    end

    -- ---------- проверка ----------
    function A.rebuild()
        A.lookup = {}
        if A.server then
            for _, e in ipairs(A.list) do
                if e.server == A.server then A.lookup[lower(e.nick)] = e end
            end
        end
        A.dirty = false
    end

    -- Поиск идёт порциями по кадрам: проход по всем ID (до ~1000) за один кадр давал микро-фриз
    A.SCAN_CHUNK = 100

    function A.scanFinish(found, set)
        if not A.firstScan and B('adm_notify', true)[0] then
            local ev = {}
            for ln, a in pairs(set) do
                if not A.onSet[ln] then ev[#ev + 1] = {true, a} end
            end
            for ln, a in pairs(A.onSet) do
                if not set[ln] then ev[#ev + 1] = {false, a} end
            end
            if #ev > 4 then
                Notify('Admins online changed, now: %d', #found)
            else
                for _, v in ipairs(ev) do
                    if v[1] then NotifyOk('Admin %s [%d] is online', v[2].nick, v[2].id)
                    else Notify('Admin %s left the server', v[2].nick) end
                end
            end
        end
        A.online, A.onSet, A.firstScan = found, set, false
    end

    -- Начало прохода: проверка сервера и списка, дальше A.step обрабатывает ID порциями
    function A.scan()
        if not isSampAvailable() then return end
        local key, label = A.curServer()
        if key ~= A.server then                      -- сменился сервер: старый список не нужен
            A.server, A.online, A.onSet, A.firstScan, A.dirty = key, {}, {}, true, true
            A.sc = nil
        end
        if not key then A.serverName, A.dirty, A.sc = '', false, nil return end
        if label ~= key then A.labels[key] = label end
        A.serverName = A.labels[key] or label
        if A.dirty then A.rebuild() end
        if not next(A.lookup) then A.sc = nil; A.scanFinish({}, {}) return end
        local r, localId = sampGetPlayerIdByCharHandle(PLAYER_PED)
        A.sc = {id = 0, max = sampGetMaxPlayerId(false), localId = r and localId or nil, found = {}, set = {}}
    end

    function A.scanRange(sc, last)
        local lookup = A.lookup
        for id = sc.id, last do
            if id == sc.localId or sampIsPlayerConnected(id) then
                local nick = sampGetPlayerNickname(id)
                local ln = nick and lower(nick)
                if ln and lookup[ln] and not sc.set[ln] then     -- каждый ник только при первом совпадении
                    local a = {id = id, nick = lookup[ln].nick}
                    sc.found[#sc.found + 1] = a
                    sc.set[ln] = a
                end
            end
        end
    end

    function A.step()
        local sc = A.sc
        if not sc then return end
        if not isSampAvailable() or (sampGetGamestate and sampGetGamestate() ~= 3) then A.sc = nil return end
        local last = math.min(sc.id + A.SCAN_CHUNK - 1, sc.max)
        if not pcall(A.scanRange, sc, last) then A.sc = nil return end       -- сбой запроса: прошлый список остаётся
        sc.id = last + 1
        if sc.id > sc.max then
            A.sc = nil
            table.sort(sc.found, function(a, b) return a.id < b.id end)       -- список должен быть по возрастанию ID
            A.scanFinish(sc.found, sc.set)
        end
    end

    -- Вызывается из главного цикла
    function A.tick()
        if not B('adm_enable', false)[0] then
            if #A.online > 0 then A.online, A.onSet = {}, {} end
            A.lastScan, A.firstScan, A.sc = -100, true, nil
            return
        end
        if not A.loaded then A.load() end
        if A.sc then pcall(A.step) return end                    -- проход по ID идёт порциями
        local now = os.clock()
        local interval = clamp(I('adm_interval', 5)[0], 1, 60)
        if not A.dirty and now - A.lastScan < interval then return end
        A.lastScan = now
        pcall(A.scan)
    end

    -- ---------- страница в Software ----------
    local NAV_SHIFT = 30                              -- на столько название панели сдвинуто вправо (место под стрелку)

    -- шапка первой панели: стрелка назад слева, главный переключатель справа
    local function LeftHeader()
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local c0 = imgui.GetCursorScreenPos()         -- Panel ставит курсор в (правый край - 42, верх + 7)
        local label, ptr = 'Enable admin checker', B('adm_enable', false)
        local tx, ty = c0.x - 8, c0.y + 4
        imgui.SetCursorScreenPos(P(tx - 3, c0.y))
        if imgui.InvisibleButton('##adm_toggle', P(40, 26)) then ptr[0] = not ptr[0] end
        Hint(label)
        Highlight(label, P(tx - 3, c0.y), 40, 26)
        local t = animTo('adm_toggle', ptr[0] and 1 or 0, 14)
        local tmain = THEME.main
        if t > 0.01 then
            dl:AddRectFilled(P(tx - 3, ty - 3), P(tx + 37, ty + 21), C(tmain, 0.14 * t), 12)
        end
        dl:AddRectFilled(P(tx, ty), P(tx + 34, ty + 18), C(mix(pal.track, tmain, t)), 9)
        dl:AddCircleFilled(P(tx + 9 + 16 * t, ty + 9), 6.5, C(mix(pal.dim, pal.white, t)), 20)

        local c = P(c0.x - (LAY.COLW - 42) + 10, c0.y)   -- левый край панели + 10
        imgui.SetCursorScreenPos(c)
        local pressed = imgui.InvisibleButton('##adm_back', P(26, 26))
        Hint('Back')
        local h = animTo('adm_back', imgui.IsItemHovered() and 1 or 0, 14)
        dl:AddRectFilled(c, P(c.x + 26, c.y + 26), C(mix(pal.field, pal.fieldH, h), 0.95), 6)
        dl:AddRectFilled(c, P(c.x + 26, c.y + 26), C(THEME.main, 0.10 * h), 6)
        local col = C(mix(pal.dim, THEME.main, math.max(h, 0.35)))
        if not FNT.drawIcon(dl, 'ARROW_LEFT', 14, c.x + 13, c.y + 13, col) then
            dl:AddLine(P(c.x + 17, c.y + 13), P(c.x + 9, c.y + 13), col, 2)
            dl:AddLine(P(c.x + 9, c.y + 13), P(c.x + 13, c.y + 9), col, 2)
            dl:AddLine(P(c.x + 9, c.y + 13), P(c.x + 13, c.y + 17), col, 2)
        end
        if pressed then SOFT.setPage(nil) end
    end

    local function SubTitle(text)
        if SRCH.collecting then return end
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        imgui.PushFont(fonts.small)
        imgui.GetWindowDrawList():AddText(imgui.ImVec2(p.x, p.y + 1), C(pal.dim), u8(tr(text)))
        imgui.PopFont()
        imgui.Dummy(imgui.ImVec2(w, 20))
    end

    local function LeftBody()
        if SRCH.collecting then Reg('Enable admin checker', 'Checkbox') end    -- главный переключатель (в шапке панели)
        local dim = not B('adm_enable', false)[0] and not SRCH.collecting      -- выключено: пункты приглушены
        local ga = gfx.galpha
        if dim then
            gfx.galpha = ga * 0.45
            imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.45)
        end
        SubTitle('Checker')
        Slider('Update interval', I('adm_interval', 5), 1, 60, '%d s', true)
        Checkbox('Notify about admins', B('adm_notify', true))
        Checkbox('Auto-add admins', B('adm_auto', false))
        SubTitle('Overlay')
        Checkbox('Show on screen', B('adm_overlay', true))
        Checkbox('Show admin ID', B('adm_show_id', true))
        Checkbox('Show admin level', B('adm_show_level', false))
        Slider('Panel scale', F('adm_scale', 1.0), 0.5, 2.0, '%.1fx', false)
        if Button('Edit position', 34) then A.startPosEdit() end
        if dim then
            imgui.PopStyleVar()
            gfx.galpha = ga
        end
    end

    -- сервер, счётчик и список админов, которые сейчас онлайн
    local function DrawStatus()
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        local on = B('adm_enable', false)[0]

        local sl = u8(tr('Server') .. ':')
        local sx = imgui.CalcTextSize(sl).x + 8
        dl:AddText(P(p.x, p.y + 2), C(pal.dim), sl)
        local sname = A.server and (A.serverName ~= '' and A.serverName or A.server) or tr('Not connected to a server')
        local stxt = A.fit(sname, w - sx)
        dl:AddText(P(p.x + sx, p.y + 2), C(A.server and pal.text or pal.dim), stxt)
        imgui.Dummy(P(w, 24))

        local nList = A.countServer(A.server)
        local hp = imgui.GetCursorScreenPos()
        imgui.PushFont(fonts.small)
        dl:AddText(P(hp.x, hp.y + 1), C(pal.dim), u8(tr('Online now')))
        local cnt = u8(#A.online .. ' / ' .. nList)
        dl:AddText(P(hp.x + w - imgui.CalcTextSize(cnt).x, hp.y + 1), C(THEME.main), cnt)
        imgui.PopFont()
        imgui.Dummy(P(w, 20))

        local lh = 190
        local q = imgui.GetCursorScreenPos()
        dl:AddRectFilled(q, P(q.x + w, q.y + lh), C(pal.field, 0.55), 8)
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(6, 6))
        imgui.BeginChild('##adm_online', P(w, lh), false)
        local cdl = imgui.GetWindowDrawList()
        local o = imgui.GetCursorScreenPos()
        local aw = imgui.GetContentRegionAvail().x
        local th = imgui.GetTextLineHeight()
        local n = #A.online
        if n == 0 then
            local msg = (not on) and 'Checker is off'
                or (not A.server) and 'Not connected to a server'
                or (nList == 0) and 'No admins added for this server'
                or 'No admins online'
            local s = u8(tr(msg))
            local sz = imgui.CalcTextSize(s)
            cdl:AddText(P(o.x + (aw - sz.x) / 2, o.y + (lh - 12 - sz.y) / 2), C(pal.dim), s)
        else
            for i, a in ipairs(A.online) do
                local y0 = o.y + (i - 1) * 30
                cdl:AddRectFilled(P(o.x, y0), P(o.x + aw, y0 + 26), C(pal.field), 6)
                -- клик по нику: открывает список админов с карточкой уровня этого админа
                imgui.SetCursorScreenPos(P(o.x, y0))
                if imgui.InvisibleButton('##admon' .. i, P(aw, 26)) then
                    A.show(1)
                    local _, ent = A.find(a.nick, A.server)
                    if ent then
                        A.edit, A.editT0, A.editFocus = ent, os.clock(), true
                        ffi.copy(A.buf('lvlBuf', 8), ent.level or '')
                    end
                end
                local hov = animTo('admon' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                if hov > 0.01 then cdl:AddRectFilled(P(o.x, y0), P(o.x + aw, y0 + 26), C(THEME.main, 0.10 * hov), 6) end
                cdl:AddCircleFilled(P(o.x + 12, y0 + 13), 3.5, C(CONST.TOAST_COL.success), 12)
                local idS = u8('ID ' .. a.id)
                local iw = imgui.CalcTextSize(idS).x
                cdl:AddText(P(o.x + aw - iw - 10, y0 + (26 - th) / 2), C(THEME.main), idS)
                local ent = A.lookup[lower(a.nick)]
                local lvS = ent and ent.level and u8('  ' .. tr('lvl') .. ' ' .. ent.level) or nil
                local lw = lvS and imgui.CalcTextSize(lvS).x or 0
                local nS, nw = A.fit(a.nick, aw - 24 - iw - 22 - lw)
                cdl:AddText(P(o.x + 24, y0 + (26 - th) / 2), C(pal.text), nS)
                if lvS then cdl:AddText(P(o.x + 24 + nw, y0 + (26 - th) / 2), C(pal.dim), lvS) end
            end
            imgui.SetCursorScreenPos(P(o.x, o.y + n * 30))
            imgui.Dummy(P(1, 1))
        end
        imgui.EndChild()
        imgui.PopStyleVar()
        imgui.PopStyleColor()
        imgui.Dummy(P(1, 4))
    end

    local function cleanInput(buf)                    -- в поле остаются только символы ника / ID (не больше 24)
        local s = ffi.string(buf):gsub('[^%w_%[%]%(%)%$@=%.]', ''):sub(1, 24)
        ffi.fill(buf, ffi.sizeof(buf), 0)
        ffi.copy(buf, s)
    end

    local function RightBody()
        if not SRCH.collecting then DrawStatus() end
        local idBuf = A.buf('idBuf', 32)
        TextRow('ID or nickname', idBuf, function() cleanInput(idBuf) end)
        if Button('Add admin', 34, true) then
            cleanInput(idBuf)
            if A.add(ffi.string(idBuf)) then ffi.fill(idBuf, ffi.sizeof(idBuf), 0) end
        end
        if Button('Admin list', 34) then A.show() end
    end

    SOFT.draw.admins = function()
        A.load()
        Panel('Admin checker', 0, 0, LAY.COLW, LAY.CH, LeftBody, nil, nil, LeftHeader, NAV_SHIFT)
        Panel('Admins', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, RightBody)
    end

    -- ---------- редактор списка (окно поверх меню, как редактор фраз) ----------
    function A.show(tab)
        A.loaded = false                              -- перечитываем файл: он мог измениться
        A.load()
        A.open, A.tab, A.hl, A.refocus, A.sel = true, tab or A.tab, nil, true, nil
        ffi.fill(A.buf('addBuf', 32), 32, 0)
        A.q, A.edit = '', nil
        ffi.fill(A.buf('qBuf', 32), 32, 0)
        ctl.far.rulesOpen = false
        WORDS.openId, SIDE.panel, ui.popOpen = nil, nil, false
    end

    function A.draw(wp)
        local P = imgui.ImVec2
        local t = animTo('admwin', A.open and 1 or 0, 14)
        if t < 0.01 then return end
        local tmain, e = THEME.main, easeOut(t)
        local al = ui.alpha * t
        gfx.galpha = al

        imgui.SetCursorScreenPos(P(wp.x, wp.y))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(0, 0))
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
        local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
        if not A.open then flags = flags + imgui.WindowFlags.NoInputs end
        imgui.BeginChild('##collapse_admwin', P(LAY.W, LAY.H), false, flags)
        local dl = imgui.GetWindowDrawList()
        dl:AddRectFilled(P(wp.x, wp.y), P(wp.x + LAY.W, wp.y + LAY.H), C({0, 0, 0}, 0.6), 11)

        local PW, PH = 560, 420
        local px, py = wp.x + (LAY.W - PW) / 2, wp.y + (LAY.H - PH) / 2 + (1 - e) * 16
        dl:AddRectFilled(P(px, py), P(px + PW, py + PH), C(pal.border), 11)
        dl:AddRectFilled(P(px + 1, py + 1), P(px + PW - 1, py + PH - 1), C({0.082, 0.088, 0.112}), 10)

        -- заголовок, счётчик, крестик
        dl:AddRectFilled(P(px + 16, py + 16), P(px + 19, py + 34), C(tmain), 2)
        imgui.PushFont(fonts.bold)
        dl:AddText(P(px + 30, py + 14), C(pal.text), u8(tr('Admin list')))
        imgui.PopFont()
        local total = #A.list                                  -- в счётчике: админы этого сервера / выбранного сервера / всех серверов
        if A.tab == 1 then total = A.countServer(A.server) elseif A.sel then total = A.countServer(A.sel) end
        local cnt = u8(A.countText(total))
        dl:AddText(P(px + PW - 52 - imgui.CalcTextSize(cnt).x, py + 16), C(pal.dim), cnt)
        imgui.SetCursorScreenPos(P(px + PW - 40, py + 10))
        if imgui.InvisibleButton('##admwin_x', P(28, 28)) then A.open = false end
        local xh = animTo('admwin_x', imgui.IsItemHovered() and 1 or 0, 14)
        dl:AddRectFilled(P(px + PW - 40, py + 10), P(px + PW - 12, py + 38), C(pal.white, 0.06 * xh), 7)
        local xc, cy2, cx2 = C(mix(pal.dim, pal.text, xh)), py + 24, px + PW - 26
        dl:AddLine(P(cx2 - 5, cy2 - 5), P(cx2 + 5, cy2 + 5), xc, 1.8)
        dl:AddLine(P(cx2 + 5, cy2 - 5), P(cx2 - 5, cy2 + 5), xc, 1.8)
        dl:AddRectFilled(P(px + 16, py + 48), P(px + PW - 16, py + 49), C(pal.border))

        -- вкладки: этот сервер / все серверы
        if A.sel and A.countServer(A.sel) == 0 then A.sel = nil end
        local srvList = A.servers()
        local tbs = {
            {id = 1, label = tr('This server') .. ' (' .. A.countServer(A.server) .. ')', icon = 'SERVER'},
            {id = 2, label = tr('All servers') .. ' (' .. #srvList .. ')', icon = 'LIST_UL'},
        }
        local x = px + 16
        for _, tb in ipairs(tbs) do
            local label = u8(tb.label)
            local sz = imgui.CalcTextSize(label)
            local tw = sz.x + 42
            imgui.SetCursorScreenPos(P(x, py + 58))
            if imgui.InvisibleButton('##admtab' .. tb.id, P(tw, 28)) then
                if A.tab ~= tb.id then A.tab, A.hl = tb.id, nil
                elseif tb.id == 2 then A.sel, A.hl = nil, nil end      -- повторный клик по "Все серверы" - назад к списку серверов
            end
            local h = animTo('admtabh' .. tb.id, imgui.IsItemHovered() and 1 or 0, 14)
            local sel = animTo('admtabs' .. tb.id, (A.tab == tb.id) and 1 or 0, 16)
            dl:AddRectFilled(P(x, py + 58), P(x + tw, py + 86), C(mix(pal.field, tmain, sel * 0.22 + h * 0.10)), 6)
            dl:AddRect(P(x, py + 58), P(x + tw, py + 86), C(mix(pal.border, tmain, sel * 0.7)), 6)
            local col = C(mix(mix(pal.dim, pal.text, h * 0.7), tmain, sel))
            FNT.drawIcon(dl, tb.icon, 14, x + 18, py + 72, col)
            dl:AddText(P(x + 32, py + 58 + (28 - sz.y) / 2), col, label)
            x = x + tw + 8
        end

        -- Поиск по нику: поле справа от вкладок (фильтрует список ниже; на вкладке "All servers" ищет по всем серверам)
        do
            local sbuf = A.buf('qBuf', 32)
            local sw = 190
            local sx, sy = px + PW - 16 - sw, py + 58
            imgui.SetCursorScreenPos(P(sx, sy))
            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(28, 6))
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 7)
            imgui.SetNextItemWidth(sw)
            imgui.InputText('##adm_search', sbuf, ffi.sizeof(sbuf), imgui.InputTextFlags.CharsNoBlank)
            imgui.PopStyleVar(2)
            if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
            local sq = ffi.string(sbuf)
            if sq == '' then dl:AddText(P(sx + 28, sy + 6), C(pal.dim, 0.75), u8(tr('Search by nickname'))) end
            local mc = C(pal.dim)
            if not FNT.drawIcon(dl, 'MAGNIFYING_GLASS', 12, sx + 14, sy + 14, mc) then
                dl:AddCircle(P(sx + 13, sy + 13), 4.5, mc, 14, 1.5)
                dl:AddLine(P(sx + 16.5, sy + 16.5), P(sx + 20, sy + 20), mc, 1.6)
            end
            A.q = lower(sq)
        end
        local searchAll = (A.tab == 2 and not A.sel and A.q ~= '')
        local inServers = (A.tab == 2 and not A.sel and A.q == '')             -- вкладка "Все серверы": пока сервер не выбран, показываем список серверов
        local lx, ly, lw, lh = px + 16, py + 96, PW - 32, PH - 96 - 64
        dl:AddRectFilled(P(lx, ly), P(lx + lw, ly + lh), C(pal.field, 0.55), 8)

        -- шапка выбранного сервера: стрелка назад и название
        local hdr = 0
        if A.tab == 2 and A.sel then
            hdr = 36
            local selKey = A.sel
            local bx, by = lx + 8, ly + 6
            imgui.SetCursorScreenPos(P(bx, by))
            local back = imgui.InvisibleButton('##admback', P(26, 26))
            local bh = animTo('admback', imgui.IsItemHovered() and 1 or 0, 14)
            dl:AddRectFilled(P(bx, by), P(bx + 26, by + 26), C(mix(pal.field, pal.fieldH, bh), 0.95), 6)
            dl:AddRectFilled(P(bx, by), P(bx + 26, by + 26), C(tmain, 0.10 * bh), 6)
            local bc = C(mix(pal.dim, tmain, math.max(bh, 0.35)))
            if not FNT.drawIcon(dl, 'ARROW_LEFT', 14, bx + 13, by + 13, bc) then
                dl:AddLine(P(bx + 17, by + 13), P(bx + 9, by + 13), bc, 2)
                dl:AddLine(P(bx + 9, by + 13), P(bx + 13, by + 9), bc, 2)
                dl:AddLine(P(bx + 9, by + 13), P(bx + 13, by + 17), bc, 2)
            end
            local hth = imgui.GetTextLineHeight()
            local hname = A.fit(A.labels[selKey] or selKey, lw - 16 - 26 - 18)
            dl:AddText(P(bx + 36, by + (26 - hth) / 2), C(selKey == A.server and tmain or pal.text), hname)
            dl:AddRectFilled(P(lx + 8, ly + hdr - 1), P(lx + lw - 8, ly + hdr), C(pal.border))
            if back then A.sel, A.hl = nil, nil end
        end

        local cy0 = ly + (hdr > 0 and hdr + 4 or 8)
        local chh = lh - (cy0 - ly) - 8
        imgui.SetCursorScreenPos(P(lx + 8, cy0))
        imgui.BeginChild('##adm_list', P(lw - 16, chh), false)
        local ldl = imgui.GetWindowDrawList()
        local origin = imgui.GetCursorScreenPos()
        local availW = imgui.GetContentRegionAvail().x
        local th = imgui.GetTextLineHeight()
        local remove, pickSrv
        if inServers then
            -- список серверов: название, количество админов, клик - открыть админов сервера
            if #srvList == 0 then
                local s = u8(tr('No admins added'))
                local sz = imgui.CalcTextSize(s)
                ldl:AddText(P(origin.x + (availW - sz.x) / 2, origin.y + (chh - 16) / 2 - sz.y), C(pal.dim), s)
            else
                local rowH, gap = 34, 4
                for i, s in ipairs(srvList) do
                    local y0 = origin.y + (i - 1) * (rowH + gap)
                    local isCur = A.server ~= nil and s.key == A.server
                    imgui.SetCursorScreenPos(P(origin.x, y0))
                    if imgui.InvisibleButton('##admsrv' .. i, P(availW, rowH)) then pickSrv = s.key end
                    local hh = animTo('admsrv' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                    ldl:AddRectFilled(P(origin.x, y0), P(origin.x + availW, y0 + rowH),
                        C(mix(pal.field, tmain, hh * 0.16 + (isCur and 0.06 or 0))), 7)
                    if isCur then ldl:AddRectFilled(P(origin.x, y0 + 7), P(origin.x + 3, y0 + rowH - 7), C(tmain), 2) end
                    FNT.drawIcon(ldl, 'SERVER', 14, origin.x + 20, y0 + rowH / 2, C(mix(pal.dim, tmain, math.max(hh, isCur and 1 or 0.25))))
                    local cx, cyv = origin.x + availW - 16, y0 + rowH / 2          -- шеврон справа
                    local ccol = C(mix(pal.dim, tmain, hh))
                    ldl:AddLine(P(cx - 3, cyv - 5), P(cx + 2, cyv), ccol, 1.8)
                    ldl:AddLine(P(cx + 2, cyv), P(cx - 3, cyv + 5), ccol, 1.8)
                    local cntTxt = u8(A.countText(s.n))
                    local rx = cx - 14 - imgui.CalcTextSize(cntTxt).x
                    ldl:AddText(P(rx, y0 + (rowH - th) / 2), C(pal.dim), cntTxt)
                    if isCur then
                        local tag = u8(tr('This server'))
                        rx = rx - 12 - imgui.CalcTextSize(tag).x
                        ldl:AddText(P(rx, y0 + (rowH - th) / 2), C(tmain), tag)
                    end
                    local ntxt = A.fit(s.label, rx - (origin.x + 40) - 10)
                    ldl:AddText(P(origin.x + 40, y0 + (rowH - th) / 2), C(isCur and tmain or pal.text), ntxt)
                end
                imgui.SetCursorScreenPos(P(origin.x, origin.y + #srvList * (rowH + gap)))
                imgui.Dummy(P(1, 1))
            end
        else
            -- админы: вкладка "Этот сервер" или выбранный сервер; онлайн сверху по ID
            local items = {}
            for _, a in ipairs(A.list) do
                local inScope = (A.tab == 1 and A.server ~= nil and a.server == A.server)
                    or (A.tab == 2 and ((A.sel ~= nil and a.server == A.sel) or searchAll))
                if inScope and (A.q == '' or lower(a.nick):find(A.q, 1, true)) then items[#items + 1] = a end
            end
            A.sortItems(items)
            if #items == 0 then
                local s = u8(tr(A.q ~= '' and 'No admins found' or ((A.tab == 1 and not A.server) and 'Not connected to a server' or 'No admins added')))
                local sz = imgui.CalcTextSize(s)
                ldl:AddText(P(origin.x + (availW - sz.x) / 2, origin.y + (chh - 16) / 2 - sz.y), C(pal.dim), s)
            else
                local rowH, gap = 30, 4
                for i, a in ipairs(items) do
                    local y0 = origin.y + (i - 1) * (rowH + gap)
                    local isCur = A.server ~= nil and a.server == A.server
                    local on = isCur and A.onSet[lower(a.nick)] or nil
                    local hlA = 0
                    if A.hl and A.hl.e == a then                  -- подсветка добавленной / уже существующей записи
                        local age = os.clock() - A.hl.t0
                        if age < 1.4 then hlA = (1 - age / 1.4) * (0.5 + 0.5 * math.sin(age * 14)) else A.hl = nil end
                    end
                    ldl:AddRectFilled(P(origin.x, y0), P(origin.x + availW, y0 + rowH), C(mix(pal.field, tmain, hlA * 0.6)), 7)
                    imgui.SetCursorScreenPos(P(origin.x + 4, y0 + 4))
                    if imgui.InvisibleButton('##admx' .. i, P(22, 22)) then remove = a end
                    local hh = animTo('admx' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                    local xcol = C(mix(pal.dim, CONST.BTN_DANGER, hh))
                    ldl:AddLine(P(origin.x + 11, y0 + 11), P(origin.x + 19, y0 + 19), xcol, 1.6)
                    ldl:AddLine(P(origin.x + 19, y0 + 11), P(origin.x + 11, y0 + 19), xcol, 1.6)
                    -- клик по нику (остальная часть строки) открывает карточку с уровнем админа
                    imgui.SetCursorScreenPos(P(origin.x + 30, y0))
                    if imgui.InvisibleButton('##admn' .. i, P(availW - 30, rowH)) then
                        A.edit, A.editT0, A.editFocus = a, os.clock(), true
                        ffi.copy(A.buf('lvlBuf', 8), a.level or '')
                    end
                    local hn = animTo('admn' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                    if hn > 0.01 then
                        ldl:AddRectFilled(P(origin.x + 30, y0), P(origin.x + availW, y0 + rowH), C(tmain, 0.10 * hn), 7)
                    end
                    ldl:AddCircleFilled(P(origin.x + 38, y0 + rowH / 2), 3.5,
                        C(on and CONST.TOAST_COL.success or pal.dim, on and 1 or 0.45), 12)

                    -- справа: ID (если игрок онлайн) или "не в сети"; в общем поиске по всем серверам - название сервера
                    local rtxt, rcol
                    if on then rtxt, rcol = u8('ID ' .. on.id), CONST.TOAST_COL.success
                    elseif isCur then rtxt, rcol = u8(tr('Offline')), pal.dim
                    elseif searchAll then rtxt, rcol = (A.fit(A.labels[a.server] or a.server, 150)), pal.dim end
                    local rw = rtxt and imgui.CalcTextSize(rtxt).x or 0
                    if rtxt then ldl:AddText(P(origin.x + availW - rw - 12, y0 + (rowH - th) / 2), C(rcol), rtxt) end
                    local lvl = a.level and u8('  ' .. tr('lvl') .. ' ' .. a.level) or nil
                    local lw = lvl and imgui.CalcTextSize(lvl).x or 0
                    local ntxt, nw = A.fit(a.nick, availW - 52 - rw - 24 - lw)
                    ldl:AddText(P(origin.x + 50, y0 + (rowH - th) / 2), C(pal.text), ntxt)
                    if lvl then ldl:AddText(P(origin.x + 50 + nw, y0 + (rowH - th) / 2), C(tmain, 0.9), lvl) end
                end
                imgui.SetCursorScreenPos(P(origin.x, origin.y + #items * (rowH + gap)))
                imgui.Dummy(P(1, 1))
            end
        end
        imgui.EndChild()
        if remove then A.remove(remove) end
        if pickSrv then A.sel, A.hl, A.refocus = pickSrv, nil, true end

        -- ввод ID или ника (для выбранного сервера - ник этого сервера); пока выбор сервера - подсказка
        local iy = py + PH - 50
        local buf = A.buf('addBuf', 32)
        if inServers then
            local s = u8(tr('Select a server to see its admins'))
            local sz = imgui.CalcTextSize(s)
            dl:AddText(P(px + (PW - sz.x) / 2, iy + (34 - sz.y) / 2), C(pal.dim), s)
        else
            imgui.SetCursorScreenPos(P(px + 16, iy))
            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(10, 7))
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 7)
            imgui.SetNextItemWidth(PW - 32 - 108)
            if A.refocus and A.open then imgui.SetKeyboardFocusHere(); A.refocus = false end
            local entered = imgui.InputText('##adm_input', buf, ffi.sizeof(buf),
                imgui.InputTextFlags.EnterReturnsTrue + imgui.InputTextFlags.CharsNoBlank)
            imgui.PopStyleVar(2)
            if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
            if ffi.string(buf) == '' then
                local ph = (A.tab == 2 and A.sel and A.sel ~= A.server) and 'Nickname' or 'ID or nickname on this server'
                dl:AddText(P(px + 26, iy + 8), C(pal.dim, 0.75), u8(tr(ph)))
            end
            imgui.SetCursorScreenPos(P(px + PW - 16 - 100, iy))
            if MiniButton('Add', 100, 34, true) then entered = true end
            if entered and A.open then
                if A.add(ffi.string(buf), A.tab == 2 and A.sel or nil) then ffi.fill(buf, ffi.sizeof(buf), 0) end
                A.refocus = true
            end
        end

        -- Карточка уровня админа: ник и поле ввода (открывается кликом по нику в списке)
        if A.edit and (not A.hasEntry(A.edit) or not A.open) then A.edit = nil end
        if A.edit then
            local E = A.edit
            imgui.SetCursorScreenPos(P(px, py))
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
            imgui.BeginChild('##adm_lvl', P(PW, PH), false, imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse)
            local cdl = imgui.GetWindowDrawList()
            cdl:AddRectFilled(P(px, py), P(px + PW, py + PH), C({0, 0, 0}, 0.55), 11)
            local CW, CH = 300, 164
            local cx0, cy0 = px + (PW - CW) / 2, py + (PH - CH) / 2
            cdl:AddRectFilled(P(cx0, cy0), P(cx0 + CW, cy0 + CH), C(pal.border), 10)
            cdl:AddRectFilled(P(cx0 + 1, cy0 + 1), P(cx0 + CW - 1, cy0 + CH - 1), C({0.082, 0.088, 0.112}), 9)
            cdl:AddRectFilled(P(cx0 + 14, cy0 + 14), P(cx0 + 17, cy0 + 32), C(tmain), 2)
            imgui.PushFont(fonts.bold)
            cdl:AddText(P(cx0 + 26, cy0 + 12), C(pal.text), (A.fit(E.nick, CW - 44)))
            imgui.PopFont()
            imgui.PushFont(fonts.small)
            cdl:AddText(P(cx0 + 16, cy0 + 42), C(pal.dim), u8(tr('Admin level')))
            imgui.PopFont()
            local lb = A.buf('lvlBuf', 8)
            imgui.SetCursorScreenPos(P(cx0 + 16, cy0 + 60))
            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(10, 7))
            imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 7)
            imgui.SetNextItemWidth(CW - 32)
            if A.editFocus then imgui.SetKeyboardFocusHere(); A.editFocus = false end
            local entered = imgui.InputText('##adm_lvl_input', lb, ffi.sizeof(lb),
                imgui.InputTextFlags.EnterReturnsTrue + imgui.InputTextFlags.CharsDecimal + imgui.InputTextFlags.CharsNoBlank)
            imgui.PopStyleVar(2)
            if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
            if ffi.string(lb) == '' then
                cdl:AddText(P(cx0 + 26, cy0 + 68), C(pal.dim, 0.75), u8(tr('Level not set')))
            end
            imgui.PushFont(fonts.small)
            cdl:AddText(P(cx0 + 16, cy0 + 100), C(pal.dim, 0.8), u8(tr('Leave empty to hide the level.')))
            imgui.PopFont()
            imgui.SetCursorScreenPos(P(cx0 + CW - 16 - 96 - 8 - 96, cy0 + CH - 16 - 30))
            local cancel = MiniButton('Cancel', 96, 30)
            imgui.SetCursorScreenPos(P(cx0 + CW - 16 - 96, cy0 + CH - 16 - 30))
            local save = MiniButton('Save', 96, 30, true)
            if save or entered then A.setLevel(E, ffi.string(lb)); A.edit = nil
            elseif cancel then A.edit = nil end
            if A.edit and imgui.IsMouseClicked(0) and os.clock() - A.editT0 > 0.15 then      -- клик мимо карточки закрывает её
                local m = imgui.GetIO().MousePos
                if not (m.x >= cx0 and m.x <= cx0 + CW and m.y >= cy0 and m.y <= cy0 + CH) then A.edit = nil end
            end
            imgui.EndChild()
            imgui.PopStyleColor()
        end

        imgui.EndChild()
        imgui.PopStyleVar(2)
        imgui.PopStyleColor()
        gfx.galpha = ui.alpha

        if A.open and imgui.IsMouseClicked(0) then              -- клик по затемнению закрывает редактор
            local m = imgui.GetIO().MousePos
            local inWin = m.x >= wp.x and m.x <= wp.x + LAY.W and m.y >= wp.y and m.y <= wp.y + LAY.H
            local inPanel = m.x >= px and m.x <= px + PW and m.y >= py and m.y <= py + PH
            if inWin and not inPanel then A.open = false end
        end
    end

    -- ---------- панель на экране ----------
    -- Рисуется поверх игры (как оверлей Debug). Пока меню открыто, панель видна всегда - чтобы настроить положение.
    -- Положение - левый верхний угол панели в процентах экрана (adm_px / adm_py); панель всегда остаётся в пределах экрана.
    -- Кнопка "Edit position": меню скрывается, панель с 10 примерными строками идёт за курсором, ЛКМ - поставить, ПКМ - отмена.
    function A.startPosEdit()
        A.posEdit, A.posT0 = true, os.clock()
        A.open = false
        ui.open[0] = false                           -- меню плавно скрывается, курсор остаётся для выбора места
    end

    function A.finishPos(xPct, yPct)
        A.px()[0] = clamp(math.floor(xPct * 10 + 0.5) / 10, 0, 100)
        A.py()[0] = clamp(math.floor(yPct * 10 + 0.5) / 10, 0, 100)
        A.posEdit = false
        ui.open[0] = true                            -- возвращаем меню
        NotifyOk('Overlay position saved')
    end

    -- из главного цикла: ПКМ отменяет выбор; если меню открыли командой / клавишей - просто выходим из режима
    function A.posTick()
        if not A.posEdit or os.clock() - A.posT0 < 0.3 then return end
        if ui.open[0] then A.posEdit = false return end
        if wasKeyPressed(0x02) then
            A.posEdit = false
            ui.open[0] = true
            Notify('Position change cancelled')
        end
    end

    imgui.OnFrame(
        function()
            if not ui.open then return false end
            if A.posEdit then return true end
            if not (B('adm_enable', false)[0] and B('adm_overlay', true)[0] and isSampAvailable()) then return false end
            return (#A.online > 0 and not ctl.main.overlayBlocked()) or ui.open[0]
        end,
        function(self)
            local editing = A.posEdit
            self.HideCursor = not (ui.open[0] or editing)
            gfx.galpha = 1
            local P = imgui.ImVec2
            local dl = imgui.GetBackgroundDrawList()
            local io = imgui.GetIO()
            local ds = io.DisplaySize
            local k = clamp(F('adm_scale', 1.0)[0], 0.5, 2.0)
            local font, fk = FNT.pickOverlay(k)           -- растр шрифта, ближайший по размеру (чтобы текст не мылился)
            local oldScale
            if pcall(function() oldScale = font.Scale; font.Scale = oldScale * fk end) == false or not oldScale then
                font, k, oldScale = fonts.small, 1, nil
            end
            imgui.PushFont(font)
            local lh = imgui.GetTextLineHeight()
            local showId = B('adm_show_id', true)[0]
            local data = editing and A.demo or A.online
            local head = u8(tr('Admins online') .. ': ' .. #data)
            local rows, tw = {}, imgui.CalcTextSize(head).x
            local showLvl = B('adm_show_level', false)[0]
            for i, a in ipairs(data) do
                rows[i] = {nick = u8(a.nick), id = showId and u8(' [' .. a.id .. ']') or nil}
                if showLvl then                              -- уровень не задан - ничего не пишем (в режиме позиции показываем образец)
                    local e = (not editing) and A.lookup[lower(a.nick)] or nil
                    local lv = editing and tostring(a.id % 7 + 1) or (e and e.level)
                    if lv then rows[i].lvl = u8('  ' .. tr('lvl') .. ' ' .. lv) end
                end
                local w = imgui.CalcTextSize(rows[i].nick).x + (rows[i].id and imgui.CalcTextSize(rows[i].id).x or 0)
                    + (rows[i].lvl and imgui.CalcTextSize(rows[i].lvl).x or 0)
                tw = math.max(tw, w)
            end
            local pad, gap = 9 * k, 3 * k
            local bw = tw + pad * 2 + 4 * k
            local bh = (#rows + 1) * lh + #rows * gap + pad * 2
            local x, y
            if editing then
                local m = io.MousePos                       -- левый верхний угол панели - под курсором
                x, y = m.x, m.y
            else
                x, y = A.px()[0] / 100 * ds.x, A.py()[0] / 100 * ds.y
            end
            x = clamp(x, 0, math.max(0, ds.x - bw))
            y = clamp(y, 0, math.max(0, ds.y - bh))
            dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.80), 7)
            dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 7)
            dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main), 2)
            if editing then                                -- рамка цвета темы: видно, что идёт выбор места
                dl:AddRect(P(x - 1, y - 1), P(x + bw + 1, y + bh + 1), C(THEME.main), 8)
                dl:AddRect(P(x - 2, y - 2), P(x + bw + 2, y + bh + 2), C(THEME.main, 0.5), 9)
            end
            local tx = x + pad + 4 * k
            dl:AddText(P(tx, y + pad), C(pal.dim), head)
            for i, r in ipairs(rows) do
                local ry = y + pad + i * (lh + gap)
                dl:AddText(P(tx, ry), C(pal.text), r.nick)
                local ex = tx + imgui.CalcTextSize(r.nick).x
                if r.id then
                    dl:AddText(P(ex, ry), C(THEME.main), r.id)
                    ex = ex + imgui.CalcTextSize(r.id).x
                end
                if r.lvl then dl:AddText(P(ex, ry), C(pal.dim), r.lvl) end
            end
            imgui.PopFont()
            if oldScale then pcall(function() font.Scale = oldScale end) end

            if editing then
                -- подсказка сверху по центру экрана
                imgui.PushFont(fonts.bold)
                local lines = {u8(tr('Click LMB to place the list')), u8(tr('RMB - cancel')),
                    string.format('X %.1f%%   Y %.1f%%', x / ds.x * 100, y / ds.y * 100)}
                local lw, lth = 0, imgui.GetTextLineHeight()
                for _, s in ipairs(lines) do lw = math.max(lw, imgui.CalcTextSize(s).x) end
                local bx2, by2 = (ds.x - lw - 36) / 2, 24
                local bh2 = lth * #lines + 8 * (#lines - 1) + 24
                dl:AddRectFilled(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.bg, 0.88), 8)
                dl:AddRect(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.border), 8)
                dl:AddRectFilled(P(bx2 + 8, by2 + 8), P(bx2 + 11, by2 + bh2 - 8), C(THEME.main), 2)
                for i, s in ipairs(lines) do
                    local col = (i == 1) and pal.text or pal.dim
                    dl:AddText(P(bx2 + 18 + (lw - imgui.CalcTextSize(s).x) / 2, by2 + 12 + (i - 1) * (lth + 8)), C(col), s)
                end
                imgui.PopFont()
                -- ЛКМ ставит панель (после того как меню полностью скрылось, чтобы не засчитать клик по кнопке)
                if ui.alpha < 0.02 and os.clock() - A.posT0 > 0.3 and imgui.IsMouseClicked(0) then
                    A.finishPos(x / ds.x * 100, y / ds.y * 100)
                end
            end
        end
    )

    -- ---------- подсказки и перевод ----------
    local H = {
        ['Enable admin checker'] = 'Checks the player list of the current server and finds the admins from your list. The admin list is shared by all configs, the checker settings are saved in the config.',
        ['Update interval'] = 'How often the player list is checked, in seconds. Lower reacts faster but uses a bit more CPU.',
        ['Notify about admins'] = 'Shows a notification when an admin from the list comes online or leaves the server.',
        ['Auto-add admins'] = 'Automatically adds an admin to the list of the current server when he appears in admin chat messages or announcements. Works only while the admin checker is on.',
    }
    for k, v in pairs(H) do HINTS[k] = v end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Admin checker'] = 'Админ-чекер', ['Online admins'] = 'Админы онлайн', ['and the admin list'] = 'и список админов',
        ['Admins'] = 'Админы', ['Admins online'] = 'Админов онлайн', ['Checker'] = 'Чекер', ['Overlay'] = 'Оверлей',
        ['Enable admin checker'] = 'Включить админ-чекер', ['Update interval'] = 'Интервал обновления',
        ['Notify about admins'] = 'Уведомлять об админах', ['Show on screen'] = 'Показывать на экране',
        ['Show admin ID'] = 'Показывать ID админа', ['Panel scale'] = 'Размер панели',
        ['Online now'] = 'Сейчас онлайн', ['Checker is off'] = 'Чекер выключен',
        ['Not connected to a server'] = 'Нет подключения к серверу',
        ['No admins added for this server'] = 'На этом сервере админы не добавлены', ['No admins online'] = 'Админов онлайн нет',
        ['Player ID'] = 'ID игрока', ['Add admin'] = 'Добавить админа', ['Admin list'] = 'Список админов',
        ['This server'] = 'Этот сервер', ['All servers'] = 'Все серверы', ['No admins added'] = 'Админы не добавлены',
        ['Player ID on this server'] = 'ID игрока на этом сервере', ['Offline'] = 'Не в сети',
        ['ID or nickname'] = 'ID или ник', ['ID or nickname on this server'] = 'ID или ник на этом сервере', ['Nickname'] = 'Ник админа',
        ['Select a server to see its admins'] = 'Выберите сервер, чтобы увидеть его админов',
        ['Enter an ID or a nickname'] = 'Введите ID или ник', ['Enter a valid nickname'] = 'Введите корректный ник',
        ['ID works only for the current server'] = 'ID работает только для текущего сервера',
        ['Auto-add admins'] = 'Автодобавление админов', ['Admin added automatically: %s'] = 'Админ добавлен автоматически: %s',
        ['Edit position'] = 'Изменить позицию', ['Click LMB to place the list'] = 'Нажмите ЛКМ, чтобы поставить список',
        ['RMB - cancel'] = 'ПКМ - отмена', ['Overlay position saved'] = 'Позиция списка сохранена',
        ['Position change cancelled'] = 'Изменение позиции отменено',
        ['Enter a valid player ID'] = 'Введите корректный ID игрока',
        ['Player with ID %d is not online'] = 'Игрока с ID %d нет на сервере',
        ['This admin is already in the list: %s'] = 'Этот админ уже в списке: %s',
        ['Admin added: %s'] = 'Админ добавлен: %s', ['Admin removed: %s'] = 'Админ удалён: %s',
        ['Admin %s [%d] is online'] = 'Админ %s [%d] в сети', ['Admin %s left the server'] = 'Админ %s вышел с сервера',
        ['Admins online changed, now: %d'] = 'Список админов онлайн изменился, сейчас: %d',
        ['Could not save the admin list'] = 'Не удалось сохранить список админов',
        -- подсказки
        [H['Enable admin checker']] = 'Проверяет список игроков текущего сервера и находит админов из вашего списка. Список админов общий для всех конфигов, а настройки чекера сохраняются в конфиге.',
        [H['Update interval']] = 'Как часто проверяется список игроков, в секундах. Чем меньше, тем быстрее реакция, но чуть выше нагрузка на процессор.',
        [H['Notify about admins']] = 'Показывает уведомление, когда админ из списка заходит на сервер или выходит с него.',
        [H['Auto-add admins']] = 'Автоматически добавляет админа в список текущего сервера, когда он появляется в сообщениях админ-чата или объявлениях. Работает только при включённом админ-чекере.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----- Дальний чат -----
-- Реплики игроков вокруг (чат-пузыри /say, /me, /s, телефон) собираются в историю и показываются панелью на экране.
-- Логика и оверлей - в блоке "Far chat" ниже (ctl.far); здесь страница настроек и вход в редактор правил.
do
    local FC = ctl.far

    local function LeftBody()
        if SRCH.collecting then Reg('Enable far chat', 'Checkbox') end         -- главный переключатель в шапке (в поиске)
        local dim = not B('far_enable', false)[0] and not SRCH.collecting       -- выключено: правая часть затемнена
        local ga = gfx.galpha
        if dim then
            gfx.galpha = ga * 0.45
            imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.45)
        end
        Keybind('Toggle key', binds.far_toggle)
        Checkbox('Show time', B('far_time', false))
        Checkbox('Log actions (/me)', B('far_logrp', true))
        Slider('Number of lines', F('far_lines', 5), 5, 50, '%d', true)
        Slider('Chat scale', F('far_scale', 1.0), 0.5, 2.0, '%.1fx', false)
        Slider('Chat opacity', F('far_alpha', 1.0), 0.1, 1.0, '%.1f', false)
        if Button('Edit chat position', 34) then FC.startPosEdit() end
        if dim then
            imgui.PopStyleVar()
            gfx.galpha = ga
        end
    end

    local function RightBody()
        Text('A word or phrase found in a message either hides it or paints its line. Case does not matter.', pal.dim)
        if not SRCH.collecting then
            imgui.Dummy(imgui.ImVec2(1, 6))
            FC.loadRules()
            InfoRow('Rules', tostring(#FC.rules))
            InfoRow('Messages in history', tostring(#FC.list))
            imgui.Dummy(imgui.ImVec2(1, 4))
        end
        if Button('Edit rules', 34, true) then FC.showRules() end
        if Button('Show full log', 34) then FC.showLog() end
        if Button('Clear chat history', 34) then
            FC.list, FC.scroll = {}, 0
            Notify('Chat history cleared')
        end
    end

    SOFT.draw.farchat = function()
        Panel('Far chat', 0, 0, LAY.COLW, LAY.CH, LeftBody, nil, nil, function()
            SOFT.pageHeader('far', LAY.COLW, 'Enable far chat', B('far_enable', false))
        end, 30)
        Panel('Chat rules', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, RightBody)
    end
end

content[3] = {
    function() -- Programs
        if SRCH.collecting then                              -- элементы страниц программ (Render) - в поиск
            for _, it in ipairs(SOFT.list) do
                local draw = it.index and SOFT.draw[it.id]
                if draw then
                    SRCH.collecting.prog, SRCH.collecting.progTitle = it.id, it.title
                    pcall(draw)
                    SRCH.collecting.prog, SRCH.collecting.progTitle = nil, nil
                end
            end
        end
        local page
        for _, it in ipairs(SOFT.list) do
            if it.id == SOFT.page and not SRCH.collecting then page = it end
        end
        if not SRCH.collecting and ui.hl then               -- переход из поиска: открываем найденную программу
            for _, it in ipairs(SOFT.list) do
                if ui.hl.label == it.title then page = it SOFT.setPage(it.id)
                elseif ui.hl.prog == it.id then
                    page = it SOFT.setPage(it.id)
                    if ui.hl.rpage then SOFT.rpage = ui.hl.rpage end      -- страница внутри Render (1 - ресурсы, 2 - объекты)
                    ui.hl.prog = nil
                end   -- элемент страницы программы
            end
        end
        if page and page.full then                           -- страница со своими панелями: появление как у остальных, без обёртки
            local k = SOFT.k()
            local ga, oy = gfx.galpha, ui.offY
            gfx.galpha = ga * k
            imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * k)
            ui.offY = oy + (1 - k) * 14
            local draw = SOFT.draw[page.id]
            if draw then draw() end
            ui.offY = oy
            imgui.PopStyleVar()
            gfx.galpha = ga
            return
        end
        Panel(page and page.title or 'Programs', 0, 0, LAY.CW, LAY.CH, function()
            if page then
                local k = SOFT.k()                                   -- появление: fade + сдвиг снизу вверх
                local ga = gfx.galpha
                gfx.galpha = ga * k
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * k)
                imgui.SetCursorPosY(imgui.GetCursorPosY() + (1 - k) * 14)
                if MiniButton('Back', 90, 28) then SOFT.setPage(nil) end
                imgui.Spacing()
                local draw = SOFT.draw[page.id]
                if draw then draw() end
                imgui.PopStyleVar()
                gfx.galpha = ga
                return
            end
            local p = imgui.GetCursorScreenPos()
            local w = imgui.GetContentRegionAvail().x
            local tw = math.floor((w - (SOFT.COLS - 1) * SOFT.TILE_GAP) / SOFT.COLS)
            local rows = 0
            for i, it in ipairs(SOFT.list) do
                local col, row = (i - 1) % SOFT.COLS, math.floor((i - 1) / SOFT.COLS)
                rows = math.max(rows, row + 1)
                if SOFT.tile(it, col, row, p.x, p.y, tw) then SOFT.setPage(it.id) end
            end
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + rows * (SOFT.TILE_H + SOFT.TILE_GAP)))
            imgui.Dummy(imgui.ImVec2(1, 1))
        end)
    end,
}

-- ---------- 4. SETTINGS ----------
CFG.cfgNames = {'default'}
content[4] = {
    function() -- Interface
        Panel('Theme', 0, 0, LAY.COLW, 250, function()
            THEME.row('Preset')
            Slider('Animation speed', ui.animSpeed, 0.3, 2.5, '%.1fx', false)
            Checkbox('FPS in sidebar', ui.showFps)
        end)
        Panel('Menu', LAY.COLW + 14, 0, LAY.COLW, 250, function()
            Keybind('Menu key', binds.menu)
            TextRow('Menu command', ui.cmd, function() setCommand(ffi.string(ui.cmd), true) end, '/')
            imgui.Dummy(imgui.ImVec2(1, 4))
            Checkbox('Active functions list', B('act_show', true))
            imgui.Dummy(imgui.ImVec2(1, 4))
            TextGear('Fonts')
        end)
    end,
    function() -- Config
        Panel('Configs', 0, 0, LAY.COLW, 300, function()
            local fullW = imgui.GetContentRegionAvail().x
            imgui.PushFont(fonts.small)
            imgui.TextColored(imgui.ImVec4(pal.dim[1], pal.dim[2], pal.dim[3], gfx.galpha), u8(tr('New config')))
            imgui.PopFont()
            imgui.SetNextItemWidth(fullW - 34)
            local created = imgui.InputText('##cfg_new_name', ui.cfgInput, ffi.sizeof(ui.cfgInput), imgui.InputTextFlags.EnterReturnsTrue)
            if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
            if created then CFG.CreateConfig() end
            imgui.SameLine(nil, 8)
            if IconButton('plus', 'cfg_create', 'Create') then CFG.CreateConfig() end
            imgui.Dummy(imgui.ImVec2(1, 8))

            imgui.PushFont(fonts.small)
            imgui.TextColored(imgui.ImVec4(pal.dim[1], pal.dim[2], pal.dim[3], gfx.galpha), u8(tr('Saved configs')))
            imgui.PopFont()
            imgui.Dummy(imgui.ImVec2(1, 2))

            for _, name in ipairs(CFG.cfgNames) do
                local load, del = ConfigRow(name, name == CFG.activeCfg)
                if load then CFG.LoadConfig(true, name) end
                if del then CFG.DeleteConfig(name) break end   -- список изменился - дорисуем остальное в следующем кадре
            end
        end, true, true, function()
            if IconButton('refresh', 'cfg_refresh') then CFG.RefreshConfigs(CFG.activeCfg) end
        end)
    end,
}

-- ----------------------------------------------------------------------------
--  Поиск по всем элементам
-- ----------------------------------------------------------------------------
SRCH.indexBuilt = false

local function buildIndex()
    SRCH.indexBuilt = true
    for i = #SRCH.index, 1, -1 do SRCH.index[i] = nil end
    for i, tb in ipairs(tabs) do
        for j = 1, #tb.subs do
            SRCH.collecting = {tab = i, sub = j, panel = ''}
            pcall(content[i][j])
            SRCH.collecting = nil
        end
    end
    for _, e in ipairs(SRCH.index) do
        e.hint = HINTS[e.label] or ''
        -- ищем по названию, описанию и названию панели сразу на ВСЕХ языках (из LANGS):
        -- не важно, какой язык выбран, запрос можно писать и по-русски, и по-английски.
        -- Названия вкладок и подвкладок не учитываются.
        e.names, e.parts = {}, {}
        for _, l in ipairs(i18n.LANGS) do
            e.names[#e.names + 1] = lower(trl(l.id, e.label))
            e.parts[#e.parts + 1] = trl(l.id, e.label) .. ' ' .. trl(l.id, e.panel) .. ' ' ..
                trl(l.id, e.hint) .. ' ' .. trl(l.id, e.parent or '')
        end
        e.low = lower(table.concat(e.parts, ' '))
    end
end

-- ищет по названию функции, её описанию и названию панели; слова через пробел = И
local function runSearch(q)
    if not SRCH.indexBuilt then buildIndex() end
    local terms = {}
    for word in q:gmatch('%S+') do terms[#terms + 1] = word end
    local res = {}
    for n, e in ipairs(SRCH.index) do
        local ok = true
        for _, t in ipairs(terms) do
            if not e.low:find(t, 1, true) then ok = false break end
        end
        if ok then
            local score = 2
            local pos                                   -- где запрос встретился в названии (на любом языке)
            for _, nm in ipairs(e.names) do
                local p1 = nm:find(terms[1], 1, true)
                if p1 and (not pos or p1 < pos) then pos = p1 end
            end
            if pos == 1 then score = 0
            elseif pos then score = 1 end
            res[#res + 1] = {e = e, score = score, n = n}
        end
    end
    table.sort(res, function(a, b)
        if a.score ~= b.score then return a.score < b.score end
        return a.n < b.n
    end)
    for i, r in ipairs(res) do res[i] = r.e end
    return res
end

local function clearSearch()
    ffi.fill(ui.search, ffi.sizeof(ui.search))
end

local function ResultRow(e)
    local id = '##sr' .. e.tab .. '_' .. e.sub .. '_' .. e.label .. (e.parent or '')
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local pressed = imgui.InvisibleButton(id, imgui.ImVec2(w, 46))
    local h = animTo(id, imgui.IsItemHovered() and 1 or 0, 14)
    local tmain = THEME.main
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + 42), C(mix(pal.field, pal.fieldH, h)), 7)
    dl:AddRectFilled(imgui.ImVec2(p.x, p.y + 9), imgui.ImVec2(p.x + 3, p.y + 33), C(tmain, h), 2)
    imgui.PushFont(fonts.bold)
    dl:AddText(imgui.ImVec2(p.x + 14, p.y + 4), C(mix(pal.text, tmain, h * 0.4)), u8(tr(e.label)))
    imgui.PopFont()
    imgui.PushFont(fonts.small)
    local ps = u8(tr(tabs[e.tab].name) .. '  >  ' .. tr(e.progTitle or tabs[e.tab].subs[e.sub]) .. '  >  ' .. tr(e.panel) ..
        (e.parent and ('  >  ' .. tr(e.parent)) or ''))
    local pw = imgui.CalcTextSize(ps).x
    dl:AddText(imgui.ImVec2(p.x + w - pw - 16, p.y + 7), C(tmain, 0.85), ps)
    dl:PushClipRect(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + w - 12, p.y + 42), true)
    dl:AddText(imgui.ImVec2(p.x + 14, p.y + 24), C(pal.dim), u8(tr(e.hint)))
    dl:PopClipRect()
    imgui.PopFont()
    return pressed
end

local function drawSearchResults()
    local res = ui.results or {}
    Panel('Search results', 0, 0, LAY.CW, LAY.CH, function()
        if #res == 0 then
            Text('Nothing found. Try another word.', pal.dim)
            return
        end
        for _, e in ipairs(res) do
            if ResultRow(e) then
                -- переходим к функции и подсвечиваем её
                ui.tab = e.tab
                ui.sub[e.tab] = e.sub
                ui.contentT = 0
                ui.hl = {label = e.parent or e.label, t0 = os.clock(), prog = e.prog, rpage = e.rpage}
                ui.popReq = e.parent            -- у настройки из окна шестерёнки сразу откроем это окно
                clearSearch()
            end
        end
    end, true, true)
end

-- ----------------------------------------------------------------------------
--  Инициализация mimgui (шрифты + стиль)
-- ----------------------------------------------------------------------------
CFG.configDirty, CFG.configSaveAt, CFG.configSnapshot = false, 0, nil
CFG.cfgHasFiles = false       -- есть ли на диске хотя бы один конфиг
CFG.CONFIG_ROOT = 'xMercy\\Collapse'

local function ensureConfigDir()
    local root = getWorkingDirectory() .. '\\config'
    if not doesDirectoryExist(root) then createDirectory(root) end
    local xmercy = root .. '\\xMercy'
    if not doesDirectoryExist(xmercy) then createDirectory(xmercy) end
    local cdir = xmercy .. '\\Collapse'
    if not doesDirectoryExist(cdir) then createDirectory(cdir) end
    FNT.ensureFilesDir()
end

local function configDir()
    return getWorkingDirectory() .. '\\config\\xMercy\\Collapse'
end

local function safeConfigName(name)
    name = trim(name or ''):gsub('%.ini$', '')
    name = trim(name:gsub('[\\/:*?"<>|]', '_'))
    name = name:gsub('^%.+', '')
    name = name:gsub('[%. ]+$', '')
    if name == '' then return nil end
    return name
end

CFG.RefreshConfigs = function(selectName)
    ensureConfigDir()
    local names, seen = {}, {}
    local h, file = findFirstFile(configDir() .. '\\*.ini')
    while file do
        local name = file:gsub('%.[iI][nN][iI]$', '')
        if name ~= '' and not seen[name] then
            names[#names + 1], seen[name] = name, true
        end
        file = findNextFile(h)
    end
    if h then findClose(h) end
    CFG.cfgHasFiles = #names > 0
    if #names == 0 then names[1] = 'default' end
    table.sort(names, function(a, b) return lower(a) < lower(b) end)
    CFG.cfgNames = names
    selectName = selectName or CFG.cfgNames[ui.cfg] or 'default'
    ui.cfg = 1
    for i, name in ipairs(CFG.cfgNames) do
        if name == selectName then ui.cfg = i break end
    end
end
CFG.configName = function()
    return CFG.cfgNames[ui.cfg] or CFG.cfgNames[1] or 'default'
end

local function configFileName(name)
    return CFG.CONFIG_ROOT .. '\\' .. (name or CFG.configName())
end

local function configPath(name)
    return configDir() .. '\\' .. (name or CFG.configName()) .. '.ini'
end

local function lastConfigPath()
    return configDir() .. '\\_last.txt'
end

-- имя активного конфига запоминается, чтобы при следующем запуске загрузить его
local function writeLastConfig()
    ensureConfigDir()
    local f = io.open(lastConfigPath(), 'w')
    if f then f:write(CFG.activeCfg); f:close() end
end

local function readLastConfig()
    local f = io.open(lastConfigPath(), 'r')
    if not f then return nil end
    local s = f:read('*l')
    f:close()
    s = s and trim(s) or ''
    return s ~= '' and s or nil
end

local function sortedKeys(t)
    local r = {}
    for k in pairs(t or {}) do r[#r + 1] = k end
    table.sort(r, function(a, b) return tostring(a) < tostring(b) end)
    return r
end

local function boolStr(v) return v and '1' or '0' end
local function toBool(v, d)
    if v == nil then return d end
    if v == true or v == 1 or v == '1' or v == 'true' then return true end
    if v == false or v == 0 or v == '0' or v == 'false' then return false end
    return d
end

local function colorStr(c)
    return string.format('%.6f,%.6f,%.6f,%.6f', c[0], c[1], c[2], c[3])
end

local function parseColor(s)
    if type(s) ~= 'string' then return nil end
    local r, g, b, a = s:match('^([^,]+),([^,]+),([^,]+),([^,]+)$')
    r, g, b, a = tonumber(r), tonumber(g), tonumber(b), tonumber(a)
    if r and g and b and a then return {r, g, b, a} end
    return nil
end

local function makeConfigData()
    local data = {
        interface = {
            theme = THEME.cur,
            anim_speed = ui.animSpeed[0],
            show_fps = boolStr(ui.showFps[0]),
            language = currentLangId(),
            command = CMD.cmdName,
        },
        binds = {}, bool = {}, float = {}, int = {}, color = {}, str = {},
        render_text = ctl.rnd.section(),
    }
    for k, v in pairs(ctl.loadedBinds) do data.binds[k] = v end
    for k, v in pairs(binds) do data.binds[k] = v.key or 0; data.binds[k .. '_mod'] = v.mod or 0 end
    -- значения виджетов, которые ещё не создавались (вкладка не открывалась), не должны пропадать из файла
    for k, v in pairs(ctl.loadedControls.bool) do if not ctl.st[k] then data.bool[k] = boolStr(v) end end
    for k, v in pairs(ctl.loadedControls.float) do if not ctl.st[k] then data.float[k] = v end end
    for k, v in pairs(ctl.loadedControls.int) do if not ctl.st[k] then data.int[k] = v end end
    for k, c in pairs(ctl.loadedControls.color) do
        if not ctl.st[k] then data.color[k] = string.format('%.6f,%.6f,%.6f,%.6f', c[1], c[2], c[3], c[4] or 1) end
    end
    for k, ptr in pairs(ctl.st) do
        local tp = ctl.stType[k]
        if tp == 'bool' then data.bool[k] = boolStr(ptr[0])
        elseif tp == 'float' then data.float[k] = ptr[0]
        elseif tp == 'int' then data.int[k] = ptr[0]
        elseif tp == 'color' then data.color[k] = colorStr(ptr) end
    end
    for _, key in ipairs(FNT.SEL_KEYS) do               -- шрифты - по названию (индекс зависит от файлов в папке)
        local ptr = ctl.st[key]
        local nm = (ptr and FNT.FONT_NAMES[ptr[0] + 1]) or FNT.want[key]
        if nm then data.str[key] = nm end
    end
    if ctl.cm then for k, v in pairs(ctl.cm.cmds) do data.str[k] = v end end        -- Coord Master: имена команд
    return data
end

local function configSignature()
    local data = makeConfigData()
    local out = {}
    for _, sec in ipairs({'interface', 'binds', 'bool', 'float', 'int', 'color', 'str', 'render_text'}) do
        out[#out + 1] = '[' .. sec .. ']'
        for _, k in ipairs(sortedKeys(data[sec])) do
            out[#out + 1] = tostring(k) .. '=' .. tostring(data[sec][k])
        end
    end
    return table.concat(out, '\n')
end

local function applyConfigData(data)
    data = data or {}
    local interface, cb, cf, ci, cc = data.interface or {}, data.bool or {}, data.float or {}, data.int or {}, data.color or {}
    local cs = data.str or {}
    if ctl.cm then ctl.cm.applyCmds(cs) end
    -- интерфейс: значение из файла, а если его нет - по умолчанию
    THEME.set(interface.theme)                   -- нет в файле (старый конфиг) - пресет по умолчанию
    ui.animSpeed[0] = tonumber(interface.anim_speed) or 1.0
    ui.showFps[0] = toBool(interface.show_fps, true)
    -- язык: если в конфиге его нет (старый конфиг), остаётся текущий, чтобы язык не "прыгал" при загрузке
    local li = langIndex(interface.language)
    if li then ui.lang[0] = li end
    syncLang()
    -- команда активации: если в конфиге её нет (старый конфиг), остаётся текущая
    local cn = sanitizeCmd(interface.command)
    if cn then
        CMD.cmdName = cn
        if ui.cmd then ffi.copy(ui.cmd, cn) end
        registerCmd()
    end
    -- клавиши
    ctl.loadedBinds = {}
    for k, v in pairs(data.binds or {}) do
        if tonumber(v) and k ~= 'rem_close' and k ~= 'rem_close_mod' then ctl.loadedBinds[k] = tonumber(v) end      -- старая клавиша напоминаний удалена
    end
    for k, b in pairs(binds) do b.key = ctl.loadedBinds[k] or b.key or 0; b.mod = ctl.loadedBinds[k .. '_mod'] or b.mod or 0 end
    -- значения виджетов
    ctl.loadedControls = {bool = {}, float = {}, int = {}, color = {}}
    for k, v in pairs(cb) do ctl.loadedControls.bool[k] = toBool(v, false) end
    for k, v in pairs(cf) do ctl.loadedControls.float[k] = tonumber(v) or 0 end
    for k, v in pairs(ci) do ctl.loadedControls.int[k] = tonumber(v) or 0 end
    ctl.loadedControls.int.s_toast_font = nil              -- старые ключи шрифтов: сейчас это font_toast и font_interface;
    ctl.loadedControls.int.font_ui = nil                   -- font_ui отброшен, чтобы шрифт интерфейса стал DEFAULT_FONT во всех конфигах
    for k, v in pairs(cc) do
        local c = parseColor(v)
        if c then ctl.loadedControls.color[k] = c end
    end
    ctl.rnd.apply(data.render_text)                         -- тексты Tools -> Render -> Custom text
    -- уже созданные виджеты: значение из файла или по умолчанию (чтобы конфиги не "смешивались")
    for k, ptr in pairs(ctl.st) do
        local tp = ctl.stType[k]
        if tp == 'bool' then
            local v = ctl.loadedControls.bool[k]
            if v == nil then v = ctl.stDef[k] end
            ptr[0] = v
        elseif tp == 'float' or tp == 'int' then
            local v = ctl.loadedControls[tp][k]
            if v == nil then v = ctl.stDef[k] end
            ptr[0] = v
        elseif tp == 'color' then
            local c = ctl.loadedControls.color[k] or ctl.stDef[k]
            for i = 0, 3 do ptr[i] = c[i + 1] or 1 end
        end
    end
    -- шрифты: выбор по названию из [str]; в старых конфигах [str] нет - остаётся индекс из [int]
    for _, key in ipairs(FNT.SEL_KEYS) do
        local nm = cs[key]
        FNT.want[key] = (type(nm) == 'string' and nm ~= '') and nm or nil
    end
    FNT.resolve()
end

-- Автосохранение и кнопка Create пишут в активный конфиг (activeCfg), а не в тот,
-- на который просто навели выделение в списке: иначе клик по списку + любое изменение
-- настроек перезаписали бы чужой конфиг.
CFG.SaveConfig = function(manual)
    ensureConfigDir()
    local ok = inicfg.save(makeConfigData(), configFileName(CFG.activeCfg))
    if ok then
        CFG.configSnapshot = configSignature()
        CFG.configDirty = false
        if manual then
            CFG.RefreshConfigs(CFG.activeCfg)
            NotifyOk('Config saved: %s', CFG.activeCfg)
        end
    elseif manual then
        NotifyErr('Config save failed')
    end
    return ok
end

CFG.LoadConfig = function(manual, name)
    ensureConfigDir()
    name = name or CFG.configName()
    if CFG.configDirty then CFG.SaveConfig(false) end         -- не теряем свежие правки прежнего конфига
    local data = inicfg.load(nil, configFileName(name))
    if data then
        applyConfigData(data)
        CFG.activeCfg = name
        for i, n in ipairs(CFG.cfgNames) do                  -- выделение в списке всегда совпадает с активным конфигом
            if n == name then ui.cfg = i break end
        end
        writeLastConfig()
        CFG.configSnapshot = configSignature()
        CFG.configDirty = false
        if manual then NotifyOk('Config loaded: %s', name) end
        return true
    end
    if manual then NotifyErr('Config not found: %s', name) end
    return false
end

-- Удаление (вызывается после удержания кнопки). Что происходит дальше:
--  * удалён не активный конфиг - просто пропадает из списка;
--  * удалён активный - загружается default, а если его нет, то первый по списку;
--  * не осталось ни одного конфига - настройки сбрасываются к стандартным,
--    и создаётся новый чистый default, чтобы автосохранению всегда было куда писать.
CFG.DeleteConfig = function(name)
    name = name or CFG.configName()
    if CFG.configDirty then CFG.SaveConfig(false) end
    local ok = os.remove(configPath(name))
    local wasActive = lower(name) == lower(CFG.activeCfg)
    CFG.RefreshConfigs(wasActive and 'default' or CFG.activeCfg)

    if not wasActive then
        if ok then NotifyOk('Config deleted: %s', name) else NotifyErr('Config not found: %s', name) end
    else
        local loaded = false
        if CFG.cfgHasFiles then
            local nextName = CFG.cfgNames[1]
            for _, n in ipairs(CFG.cfgNames) do
                if lower(n) == 'default' then nextName = n break end
            end
            loaded = CFG.LoadConfig(false, nextName)
            if loaded then
                CFG.RefreshConfigs(nextName)
                NotifyOk('Config deleted: %s. Loaded: %s', name, nextName)
            end
        end
        if not loaded then
            applyConfigData({})                      -- чистый лист: всё по умолчанию
            CFG.activeCfg = 'default'
            CFG.SaveConfig(false)
            writeLastConfig()
            CFG.RefreshConfigs('default')
            NotifyOk('All configs deleted. Created new: default')
        end
    end
    CFG.configSnapshot = configSignature()
    CFG.configDirty = false
end

-- Данные "чистого" конфига: все значения по умолчанию (текущие настройки в меню не затрагиваются).
-- Для ещё не созданных виджетов ключей нет - при загрузке они получат свои значения по умолчанию.
local function makeDefaultConfigData()
    local data = {
        interface = {theme = THEME.DEFAULT, anim_speed = 1.0, show_fps = boolStr(true), language = currentLangId(), command = CMD.cmdName},
        binds = {}, bool = {}, float = {}, int = {}, color = {},
        render_text = {text1 = '', text2 = '', text3 = ''},
    }
    for k in pairs(binds) do data.binds[k] = (k == 'menu') and 0x2D or 0 end
    for k in pairs(ctl.loadedBinds) do
        if data.binds[k] == nil then data.binds[k] = 0 end
    end
    for k in pairs(ctl.st) do
        local tp, d = ctl.stType[k], ctl.stDef[k]
        if tp == 'bool' then data.bool[k] = boolStr(d)
        elseif tp == 'float' then data.float[k] = d
        elseif tp == 'int' then data.int[k] = d
        elseif tp == 'color' then data.color[k] = string.format('%.6f,%.6f,%.6f,%.6f', d[1], d[2], d[3], d[4] or 1) end
    end
    return data
end

-- Создаёт конфиг со стандартными значениями и просто добавляет его в список:
-- активный конфиг и выделение в списке не меняются, автосохранение продолжает писать в прежний.
CFG.CreateConfig = function()
    local raw = ffi.string(ui.cfgInput)
    local okd, dec = pcall(function() return u8:decode(raw) end)   -- imgui отдаёт UTF-8, файлы у нас в CP1251
    local name = safeConfigName(okd and dec or raw)
    if not name then
        NotifyErr('Enter config name')
        return false
    end
    local keep = CFG.configName()
    CFG.RefreshConfigs(keep)
    for i, n in ipairs(CFG.cfgNames) do
        if lower(n) == lower(name) then               -- Windows не различает регистр в именах файлов
            NotifyErr('Config already exists: %s', n)
            return false
        end
    end
    ensureConfigDir()
    if not inicfg.save(makeDefaultConfigData(), configFileName(name)) then
        NotifyErr('Config save failed')
        return false
    end
    ffi.fill(ui.cfgInput, ffi.sizeof(ui.cfgInput), 0)
    CFG.RefreshConfigs(keep)
    NotifyOk('Config created: %s', name)
    return true
end

-- при запуске: последний использованный конфиг -> default -> любой существующий -> новый default
local function StartupConfig()
    CFG.RefreshConfigs()
    local order, seen = {}, {}
    local function add(n)
        if n and not seen[lower(n)] then seen[lower(n)] = true; order[#order + 1] = n end
    end
    add(readLastConfig())
    add('default')
    for _, n in ipairs(CFG.cfgNames) do add(n) end
    for _, n in ipairs(order) do
        if doesFileExist(configPath(n)) and CFG.LoadConfig(false, n) then
            CFG.RefreshConfigs(n)
            return
        end
    end
    CFG.activeCfg = 'default'                            -- конфигов нет вообще (первый запуск или всё удалено)
    CFG.SaveConfig(false)
    writeLastConfig()
    CFG.RefreshConfigs('default')
end

local function TickConfigSave()
    if not ui.open or not (ui.open[0] or ui.alpha > 0.003 or CFG.configDirty) then return end
    local now = os.clock()
    if not CFG.configSnapshot or now >= (CFG.sigAt or 0) then      -- подпись конфига дорогая: собираем её не чаще раза в 0.4 с, а не каждый кадр
        CFG.sigAt = now + 0.4
        local sig = configSignature()
        if not CFG.configSnapshot then CFG.configSnapshot = sig end
        if sig ~= CFG.configSnapshot then
            CFG.configDirty = true
            CFG.configSaveAt = now + 1.0
            CFG.configSnapshot = sig
        end
    end
    if CFG.configDirty and os.clock() >= CFG.configSaveAt then
        if not CFG.SaveConfig(false) then CFG.configSaveAt = os.clock() + 5 end   -- при ошибке не долбим диск каждый кадр
    end
end

-- при выгрузке скрипта / выходе из игры дописываем несохранённые правки
function onScriptTerminate(scr, quitGame)
    if scr ~= thisScript() then return end
    if ctl.restoreAll then pcall(ctl.restoreAll) end         -- выключить все функции, влияющие на игру
    if ctl.main.restore then pcall(ctl.main.restore) end     -- вернуть память игры (анти-лимит скорости, FOV)
    pcall(SOFT.noteSave)                              -- блокнот: не потерять последние правки
    pcall(function()
        if CFG.configSnapshot and (CFG.configDirty or configSignature() ~= CFG.configSnapshot) then CFG.SaveConfig(false) end
    end)
end

-- ----------------------------------------------------------------------------
--  Инструменты: действия кнопок вкладки Tools
--  Tools.run(fn) запускает действие с защитой от ошибок. Названия тех же функций в UltraTool:
--  clearChat, CloseConnect, TeleportMetka, TeleportCheckpoint, Smert, enableDialog, hideFiles ...
--  (их тела в присланном куске не было, поэтому они написаны заново - при желании подставьте свои).
-- ----------------------------------------------------------------------------
do
    local lastCheckpoint = nil                        -- {x, y, z} последнего чекпоинта от сервера

    if okEv and sampev then
        -- запоминаем координаты чекпоинтов: по ним работает "Teleport to checkpoint"
        local function remember(pos) if pos then lastCheckpoint = {pos.x, pos.y, pos.z} end end
        function sampev.onSetCheckpoint(position, radius) remember(position) end
        function sampev.onDisableCheckpoint() lastCheckpoint = nil end
        function sampev.onSetRaceCheckpoint(cpType, position, nextPosition, size) remember(position) end
        function sampev.onDisableRaceCheckpoint() lastCheckpoint = nil end
    end

    pcall(ffi.cdef, [[
        unsigned long GetFileAttributesA(const char* lpFileName);
        int SetFileAttributesA(const char* lpFileName, unsigned long dwFileAttributes);
    ]])

    local function needSamp()
        if not isSampAvailable() then NotifyErr('SA-MP is not available') return false end
        return true
    end

    function Tools.run(fn)
        local ok, err = pcall(fn)
        if not ok then
            local msg = tostring(err):gsub('^.-:%d+:%s*', '')
            NotifyErr('Action failed: %s', msg)
        end
    end

    -- ---------- персонаж ----------
    function Tools.slapUp()
        local x, y, z = getCharCoordinates(PLAYER_PED)
        setCharCoordinates(PLAYER_PED, x, y, z + 3)
    end

    function Tools.slapDown()
        local x, y, z = getCharCoordinates(PLAYER_PED)
        setCharCoordinates(PLAYER_PED, x, y, z - 3)
    end

    function Tools.unfreeze()
        freezeCharPosition(PLAYER_PED, true)
        freezeCharPosition(PLAYER_PED, false)
        setPlayerControl(PLAYER_HANDLE, true)
        restoreCameraJumpcut()
        clearCharTasksImmediately(PLAYER_PED)
    end

    function Tools.respawn()
        if not needSamp() then return end
        sampSpawnPlayer()
        restoreCameraJumpcut()
    end

    function Tools.die()
        setCharHealth(PLAYER_PED, 0)
    end

    -- ---------- телепорт ----------
    local function teleportTo(x, y, z)
        if isCharInAnyCar(PLAYER_PED) then
            setCarCoordinates(storeCarCharIsInNoSave(PLAYER_PED), x, y, z)
        else
            setCharCoordinates(PLAYER_PED, x, y, z)
        end
    end

    function Tools.teleportMarker()
        local ok, x, y, z = getTargetBlipCoordinates()
        if not ok then NotifyErr('Set a marker on the map first') return end
        lua_thread.create(function()
            pcall(function()
                -- у метки высота обычно 0: подгружаем коллизию вокруг цели и ищем землю
                requestCollision(x, y)
                loadScene(x, y, 100)
                wait(200)
                local found, gz = getGroundZFor3dCoord(x, y, 1000.0)
                local tz = (found and gz and gz > -50) and (gz + 1.0) or ((z and z > 0) and z or 60)
                teleportTo(x, y, tz)
                NotifyOk('Teleported to the marker')
            end)
        end)
    end

    function Tools.teleportCheckpoint()
        if not lastCheckpoint then NotifyErr('No checkpoint to teleport to') return end
        teleportTo(lastCheckpoint[1], lastCheckpoint[2], lastCheckpoint[3] + 1.0)
        NotifyOk('Teleported to the checkpoint')
    end

    -- ---------- транспорт ----------
    function Tools.fixWheels()
        if isCharInAnyCar(PLAYER_PED) and not isCharOnAnyBike(PLAYER_PED) then
            local car = storeCarCharIsInNoSave(PLAYER_PED)
            for i = 0, 3 do fixCarTire(car, i) end
            NotifyOk('Wheels repaired')
        else
            if not isCharInAnyCar(PLAYER_PED) then NotifyErr('You are not in a vehicle!') end
            if isCharOnAnyBike(PLAYER_PED) then NotifyErr('Wheel repair does not work on bikes!') end
        end
    end

    function Tools.fixCar()
        if isCharInAnyCar(PLAYER_PED) then
            setCarHealth(storeCarCharIsInNoSave(PLAYER_PED), 1000)
            NotifyOk('Vehicle repaired')
        else
            NotifyErr('You are not in a vehicle!')
        end
    end

    -- ---------- сервер ----------
    function Tools.connect()
        if not needSamp() then return end
        assert(GAMESTATE_WAIT_CONNECT, 'GAMESTATE_WAIT_CONNECT not found (sampfuncs)')
        sampDisconnectWithReason(0)
        sampSetGamestate(GAMESTATE_WAIT_CONNECT)
        Notify('Connecting...')
    end

    function Tools.disconnect()
        if not needSamp() then return end
        assert(GAMESTATE_DISCONNECTED, 'GAMESTATE_DISCONNECTED not found (sampfuncs)')
        sampSetGamestate(GAMESTATE_DISCONNECTED)
        sampDisconnectWithReason(0)
        Notify('Disconnected')
    end

    function Tools.closeConnection()
        if not needSamp() then return end
        sampDisconnectWithReason(true)
        Notify('Connection closed')
    end

    function Tools.clearChat()
        if not needSamp() then return end
        -- без правки памяти (смещения структуры чата зависят от версии SAMP, R3 их ломает): история чата хранит
        -- 100 строк, пустые сообщения вытесняют все старые
        do
            for _ = 1, 110 do sampAddChatMessage('', -1) end   -- запасной вариант: выталкиваем строки пустыми
        end
        Notify('Chat cleared')
    end

    local function setDialogShown(show)
        if not needSamp() then return false end
        assert(okMem, 'memory library not found')
        memory.setint32(sampGetDialogInfoPtr() + 40, show and 1 or 0, true)
        sampToggleCursor(show)
        return true
    end
    function Tools.hideDialog() if setDialogShown(false) then Notify('Dialog hidden') end end
    function Tools.showDialog() if setDialogShown(true) then Notify('Dialog shown') end end

    -- ---------- скрипт ----------
    function Tools.reloadScript() thisScript():reload() end
    function Tools.unloadScript() thisScript():unload() end

    local function setHidden(path, hidden)
        local a = ffi.C.GetFileAttributesA(path)
        if a == 0xFFFFFFFF then return false end
        local na = hidden and bit.bor(a, 2) or bit.band(a, bit.bnot(2))     -- 2 = FILE_ATTRIBUTE_HIDDEN
        return ffi.C.SetFileAttributesA(path, na) ~= 0
    end
    local function hideFiles(hidden)
        local ok = setHidden(thisScript().path, hidden)
        pcall(setHidden, configDir(), hidden)                                -- папка конфигов тоже (если есть)
        if ok then
            if hidden then NotifyOk('Script file hidden') else Notify('Script file is not hidden') end
        else
            NotifyErr('Could not change file attributes')
        end
    end
    function Tools.hideFiles() hideFiles(true) end
    function Tools.showFiles() hideFiles(false) end

    function Tools.deleteScript()
        local ok, err = os.remove(thisScript().path)
        if not ok then NotifyErr('Could not delete the script file: %s', tostring(err)) return end
        NotifyOk('Script deleted')
        lua_thread.create(function() wait(1200); thisScript():unload() end)   -- даём уведомлению показаться
    end

    function Tools.crashGame()
        readMemory(0, 1)
    end
end

-- ----------------------------------------------------------------------------
--  Инструменты разработчика (Misc -> Debug и Console)
--   Debug:   срез состояния (координаты, транспорт, пинг, FPS, память Lua), копирование координат в буфер обмена,
--            оверлей с теми же данными прямо на экране (включение и угол хранятся в конфиге)
--            и принудительная сборка мусора Lua.
--   Inspector: ID диалога в заголовке диалога, цвет сообщений чата, ID текстдравов на экране и ID текстдравов,
--            на которые нажимали (хуки lib.samp.events).
--   Console: журнал (все уведомления меню и вывод консоли) и консоль Lua. Код выполняется в игре, результат и
--            ошибки попадают в журнал. Сначала код пробуется как выражение (return ...), потом как набор
--            команд. Внутри доступны ui, imgui, binds, tabs, Tools, Dev, Notify / NotifyOk / NotifyErr,
--            а print() пишет в журнал. Для задержек: lua_thread.create(function() wait(500) ... end).
-- ----------------------------------------------------------------------------
do
    local lastSnap = 0

    -- срез состояния игры; обновляется не чаще 20 раз в секунду (force - принудительно)
    function Dev.snapshot(force)
        local now = os.clock()
        if Dev.snap and not force and now - lastSnap < 0.05 then return Dev.snap end
        local s = {}
        pcall(function()
            s.x, s.y, s.z = getCharCoordinates(PLAYER_PED)
            s.heading = getCharHeading(PLAYER_PED)
            s.interior = getActiveInterior()
            s.skin = getCharModel(PLAYER_PED)
        end)
        pcall(function()
            if isCharInAnyCar(PLAYER_PED) then
                local car = storeCarCharIsInNoSave(PLAYER_PED)
                s.model, s.carHp, s.speed = getCarModel(car), getCarHealth(car), getCarSpeed(car)
                pcall(function() s.carName = (ctl.vn and ctl.vn.name(s.model)) or getNameOfVehicleModel(s.model) end)
                pcall(function()
                    local okv, vid = sampGetVehicleIdByCarHandle(car)
                    if okv then s.vehId = vid end
                end)
            end
        end)
        pcall(function()
            if isSampAvailable() then
                local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                if ok then
                    s.id, s.ping = id, sampGetPlayerPing(id)
                    -- последняя анимация: запоминаем, когда её ID меняется (имя и файл - из таблицы анимаций SA)
                    local aid = sampGetPlayerAnimationId(id)
                    if aid and aid ~= Dev.animId then
                        Dev.animId = aid
                        local okn, an, af = pcall(sampGetAnimationNameAndFile, aid)
                        Dev.anim = {id = aid, name = okn and an or nil, file = okn and af or nil}
                        if Dev.logAnim and Dev.animPush then Dev.animPush('own', aid, Dev.anim.name, Dev.anim.file) end
                    end
                end
            end
        end)
        s.fps = Dev.fps or 0                                  -- кэш: imgui.GetIO() нельзя вызывать вне кадра (snapshot зовут и из Condition)
        s.mem = collectgarbage('count')                       -- КБ
        Dev.snap, lastSnap = s, now
        return s
    end

    function Dev.uptime()
        local t = math.floor(os.clock() - Dev.start)
        return string.format('%02d:%02d:%02d', math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
    end

    -- ---------- буфер обмена ----------
    local function copyPos(fmt)
        local s = Dev.snapshot(true)
        if not s.x then NotifyErr('Position is not available') return end
        setClipboardText(string.format(fmt, s.x, s.y, s.z, s.heading or 0))
        NotifyOk('Copied to the clipboard')
    end
    function Dev.copyXYZ()      copyPos('%.2f, %.2f, %.2f') end
    function Dev.copyXYZH()     copyPos('%.2f, %.2f, %.2f, %.1f') end
    function Dev.copyLuaCode()  copyPos('setCharCoordinates(PLAYER_PED, %.2f, %.2f, %.2f)') end

    function Dev.copyLog()
        local out = {}
        for i, e in ipairs(Dev.log) do out[i] = '[' .. e.t .. '] ' .. e.text end
        setClipboardText(table.concat(out, '\n'))
        NotifyOk('Copied to the clipboard')
    end
    function Dev.clear() Dev.log = {}; Dev.scroll = false end

    -- ---------- Lua ----------
    function Dev.collect()
        -- collectgarbage() = полный цикл сборки мусора Lua этого скрипта. Вызываем дважды: первый проход помечает объекты
        -- с финализаторами (ffi.gc / __gc), второй - реально освобождает их память.
        local before = collectgarbage('count')
        collectgarbage(); collectgarbage()
        local freed = math.max(0, (before - collectgarbage('count')) / 1024)
        Dev.lastGc = {t = os.date('%H:%M:%S'), mb = freed}
        NotifyOk('Garbage collected: %.2f MB freed', freed)
    end

    -- значения для вывода в журнал: строки в кавычках, таблицы - первые 12 полей
    function Dev.fmt(v)
        local function one(x) return type(x) == 'string' and ('"' .. x .. '"') or tostring(x) end
        if type(v) ~= 'table' then return one(v) end
        local parts, n = {}, 0
        for k, x in pairs(v) do
            n = n + 1
            if n > 12 then parts[#parts + 1] = '...' break end
            parts[#parts + 1] = (type(k) == 'string' and k or '[' .. tostring(k) .. ']') .. '=' .. one(x)
        end
        return '{' .. table.concat(parts, ', ') .. '}'
    end

    -- окружение консоли: все глобальные функции игры и MoonLoader + внутренности меню
    local function consoleEnv()
        if not Dev.env then
            Dev.env = setmetatable({
                print = function(...)
                    local t = {}
                    for i = 1, select('#', ...) do
                        local v = select(i, ...)
                        t[i] = type(v) == 'string' and v or Dev.fmt(v)
                    end
                    Dev.add('info', table.concat(t, '\t'))
                end,
                ui = ui, imgui = imgui, binds = binds, tabs = tabs, Tools = Tools, Dev = Dev,
                Notify = Notify, NotifyOk = NotifyOk, NotifyErr = NotifyErr,
            }, {__index = _G, __newindex = _G})
        end
        return Dev.env
    end

    function Dev.run(code)
        code = trim(code or '')
        if code == '' then return end
        Dev.add('cmd', '> ' .. code)
        local loadstr = loadstring or load
        local f, err = loadstr('return ' .. code, '=console')
        if not f then f, err = loadstr(code, '=console') end
        if not f then
            Dev.add('error', (tostring(err):gsub('^console:%d+:%s*', '')))
            return
        end
        if setfenv then setfenv(f, consoleEnv()) end
        local res = {pcall(f)}
        if not res[1] then
            Dev.add('error', (tostring(res[2]):gsub('^console:%d+:%s*', '')))
            return
        end
        local last = 0
        for k in pairs(res) do if k > last then last = k end end
        if last >= 2 then
            local parts = {}
            for i = 2, last do parts[#parts + 1] = Dev.fmt(res[i]) end
            Dev.add('info', '= ' .. table.concat(parts, ',  '))
        end
    end

    -- берёт текст из поля ввода (imgui отдаёт UTF-8, а код у нас в CP1251), очищает поле и выполняет
    function Dev.runInput()
        Dev.input = Dev.input or imgui.new.char[512]()
        local okd, code = pcall(function() return u8:decode(ffi.string(Dev.input)) end)
        ffi.fill(Dev.input, ffi.sizeof(Dev.input), 0)
        if okd then Dev.run(code) end
    end

    -- ---------- оверлей ----------
    Dev.posEdit, Dev.posT0 = false, 0
    function Dev.startPosEdit()
        Dev.posEdit, Dev.posT0 = true, os.clock()
        ui.open[0] = false                                     -- меню скрывается, панель следует за мышью
    end

    imgui.OnFrame(
        function()
            local on = B('dev_overlay', false)[0] or Dev.posEdit
            if Dev.evSync then Dev.evSync() end                 -- слушаем ивенты только пока они нужны (оверлей или лог)
            return on
        end,
        function(self)
            local editing = Dev.posEdit
            self.HideCursor = not (ui.open[0] or editing)
            gfx.galpha = 1
            Dev.fps = imgui.GetIO().Framerate
            local s = Dev.snapshot()
            local lines = {}
            if B('dev_ov_perf', true)[0] then
                lines[#lines + 1] = string.format('FPS %d (%.1f ms)   Lua %.1f MB',
                    math.floor(s.fps + 0.5), 1000 / math.max(s.fps, 1), s.mem / 1024)
                if s.ping then lines[#lines + 1] = string.format('Ping %d   ID %s', s.ping, tostring(s.id)) end
            end
            if B('dev_ov_ip', true)[0] then
                local ok, ip, port = pcall(sampGetCurrentServerAddress)
                if ok and ip and ip ~= '' then lines[#lines + 1] = string.format('Server %s:%s', ip, tostring(port or '?')) end
            end
            if B('dev_ov_pos', true)[0] and s.x then
                lines[#lines + 1] = string.format('XYZ %.2f  %.2f  %.2f', s.x, s.y, s.z)
                lines[#lines + 1] = string.format('Heading %.1f   Interior %d', s.heading or 0, s.interior or 0)
            end
            if B('dev_ov_veh', true)[0] then
                if s.model then
                    lines[#lines + 1] = string.format('%s [%d] #%s  HP %d  Speed %.1f',
                        s.carName or 'Vehicle', s.model, s.vehId and tostring(s.vehId) or '-', s.carHp or 0, s.speed or 0)
                else
                    lines[#lines + 1] = tr('On foot')
                end
            end
            if B('dev_ov_anim', true)[0] then
                local a = Dev.anim
                if a then
                    lines[#lines + 1] = string.format('Anim %s #%d', a.name and (a.name .. (a.file and (' (' .. a.file .. ')') or '')) or '?', a.id)
                end
                local ap = Dev.applied
                if ap then lines[#lines + 1] = string.format('Server anim %s / %s', ap.lib, ap.name) end
            end
            if B('dev_ov_event', true)[0] then
                for _, e in ipairs({Dev.evIn, Dev.evOut}) do
                    local label = e == Dev.evIn and 'In  <' or 'Out >'
                    lines[#lines + 1] = e.name and string.format('%s %s  %ds', label, e.name, math.floor(os.clock() - e.clock)) or (label .. ' -')
                end
            end
            if #lines == 0 then
                if editing then lines[1] = 'Debug overlay' else return end
            end

            local dl = imgui.GetBackgroundDrawList()
            local ds = imgui.GetIO().DisplaySize
            local P = imgui.ImVec2
            -- размер текста: масштаб шрифта на время отрисовки оверлея (в конце возвращаем как было)
            local k = clamp(F('dev_ov_scale', 1.0)[0], 0.5, 3.0)
            -- берём растр шрифта, ближайший по размеру к нужному: масштаб остаётся около 1, и текст не мылится
            local font, fk = FNT.pickOverlay(k)
            local oldScale
            if pcall(function() oldScale = font.Scale; font.Scale = oldScale * fk end) == false or not oldScale then
                font, k, oldScale = fonts.small, 1, nil      -- масштаб шрифта недоступен: рисуем обычным размером
            end
            imgui.PushFont(font)
            local lh, tw, texts = imgui.GetTextLineHeight(), 0, {}
            for i, ln in ipairs(lines) do
                texts[i] = u8(ln)
                tw = math.max(tw, imgui.CalcTextSize(texts[i]).x)
            end
            local pad, gap = 9 * k, 3 * k
            local bw, bh = tw + pad * 2 + 4 * k, #lines * lh + (#lines - 1) * gap + pad * 2
            -- позиция: отступ от левого и верхнего края экрана; панель не уезжает за экран
            local x = clamp(F('dev_ov_x', 12)[0], 0, math.max(ds.x - bw, 0))
            local y = clamp(F('dev_ov_y', 12)[0], 0, math.max(ds.y - bh, 0))
            if editing then                                    -- левый верхний угол панели следует за курсором
                local m = imgui.GetIO().MousePos
                x, y = clamp(m.x, 0, math.max(ds.x - bw, 0)), clamp(m.y, 0, math.max(ds.y - bh, 0))
            end
            dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.80), 7)
            dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 7)
            dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main), 2)
            for i, t in ipairs(texts) do
                dl:AddText(P(x + pad + 4 * k, y + pad + (i - 1) * (lh + gap)), C(pal.text), t)
            end
            imgui.PopFont()
            if oldScale then pcall(function() font.Scale = oldScale end) end
            if editing then
                dl:AddRect(P(x - 1, y - 1), P(x + bw + 1, y + bh + 1), C(THEME.main), 8)
                dl:AddRect(P(x - 2, y - 2), P(x + bw + 2, y + bh + 2), C(THEME.main, 0.5), 9)
                imgui.PushFont(fonts.bold)
                local hl = {u8(tr('Click LMB to place the overlay')), u8(tr('RMB - cancel')),
                    string.format('X %d   Y %d', x, y)}
                local lw, lth = 0, imgui.GetTextLineHeight()
                for _, s in ipairs(hl) do lw = math.max(lw, imgui.CalcTextSize(s).x) end
                local bx2, by2 = (ds.x - lw - 36) / 2, 24
                local bh2 = lth * #hl + 8 * (#hl - 1) + 24
                dl:AddRectFilled(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.bg, 0.88), 8)
                dl:AddRect(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.border), 8)
                dl:AddRectFilled(P(bx2 + 8, by2 + 8), P(bx2 + 11, by2 + bh2 - 8), C(THEME.main), 2)
                for i, s in ipairs(hl) do
                    dl:AddText(P(bx2 + 18 + (lw - imgui.CalcTextSize(s).x) / 2, by2 + 12 + (i - 1) * (lth + 8)), C(i == 1 and pal.text or pal.dim), s)
                end
                imgui.PopFont()
                if ui.alpha < 0.02 and os.clock() - Dev.posT0 > 0.3 then
                    if imgui.IsMouseClicked(0) then                -- ЛКМ: сохранить
                        F('dev_ov_x', 12)[0], F('dev_ov_y', 12)[0] = math.floor(x), math.floor(y)
                        Dev.posEdit = false
                        ui.open[0] = true
                        NotifyOk('Overlay position saved')
                    elseif imgui.IsMouseClicked(1) then            -- ПКМ: отмена
                        Dev.posEdit = false
                        ui.open[0] = true
                        Notify('Position change cancelled')
                    end
                end
            end
        end
    )

    -- ---------- Inspector: диалоги, цвета чата, текстдравы ----------
    -- Хуки lib.samp.events. Каждый обработчик завёрнут в pcall: ошибка здесь не должна ломать диалоги и чат игры.
    -- Все функции включаются галочками (вкладка Misc -> Inspector); пока галочка выключена, обработчик ничего не делает.
    Dev.DLG_STYLES = {[0] = 'MSGBOX', 'INPUT', 'LIST', 'PASSWORD', 'TABLIST', 'TABLIST_HEADERS'}

    local function stripColors(t) return (tostring(t or ''):gsub('{%x%x%x%x%x%x}', ''):gsub('~%a~', ' ')) end
    function Dev.short(t, n)
        t = stripColors(t)
        return #t > n and (t:sub(1, n - 1) .. '...') or t
    end

    local function copyValue(v)
        if v == nil then NotifyErr('No data yet') return end
        setClipboardText(tostring(v))
        NotifyOk('Copied to the clipboard')
    end
    function Dev.copyDialogId()  copyValue(Dev.dlg and Dev.dlg.id) end
    function Dev.copyChatColor() copyValue(Dev.chatColorRaw) end
    function Dev.copyTdId()      copyValue(Dev.tdClicks[1] and Dev.tdClicks[1].id) end

    local function guard(fn)
        return function(...)
            local r = {pcall(fn, ...)}
            if r[1] then return unpack(r, 2) end
        end
    end

    -- списки лога: события (кольцо), статистика по названиям (для частых), анимации (кольцо)
    Dev.evLog, Dev.evStats, Dev.animLog, Dev.cefLog = {}, {}, {}, {}
    Dev.pausePtr = imgui.new.bool(false)                      -- ручная пауза списка: новые записи не двигают строки
    function Dev.pushLimited(list, e, max)
        list[#list + 1] = e
        if #list > max then table.remove(list, 1) end
    end
    function Dev.animPush(kind, id, name, file, lib)
        Dev.pushLimited(Dev.animLog, {w = os.time(), kind = kind, id = id, name = name, file = file, lib = lib}, 300)
    end
    -- CEF-логгер: пакет 220. Входящий: [17][server_id u32][len u16][enc u8][текст]; исходящий: [18][len u16][текст][server_id u32]
    -- (первый байт id пакета может быть, а может и не быть в потоке - определяем по значению). Текст - UTF-8.
    function Dev.cefRead(bs, dir)
        local off = raknetBitStreamGetReadOffset and raknetBitStreamGetReadOffset(bs) or 0
        local ok, text = pcall(function()
            if raknetBitStreamGetNumberOfUnreadBits(bs) < 16 then return nil end
            local function u8b() local b = raknetBitStreamReadInt8(bs); return b < 0 and b + 256 or b end
            local sub = u8b()
            if sub == 220 then sub = u8b() end
            local want = dir == '<' and 17 or 18
            if sub ~= want then return nil end
            local function u16() local v = raknetBitStreamReadInt16(bs); return v < 0 and v + 65536 or v end
            if dir == '<' then
                raknetBitStreamReadInt32(bs)                                  -- server_id
                local len = u16()
                local enc = u8b()
                local left = math.floor(raknetBitStreamGetNumberOfUnreadBits(bs) / 8)
                if len <= 0 or len > 16384 or left < 1 then return nil end
                if enc == 0 then
                    if len > left then return nil end
                    return raknetBitStreamReadString(bs, len)
                end
                return raknetBitStreamDecodeString(bs, len + 1)
            end
            local len = u16()
            local left = math.floor(raknetBitStreamGetNumberOfUnreadBits(bs) / 8)
            if len <= 0 or len > left then return nil end
            return raknetBitStreamReadString(bs, len)
        end)
        pcall(function()
            if raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, off) else raknetBitStreamResetReadPointer(bs) end
        end)
        return (ok and type(text) == 'string') and text or nil
    end
    function Dev.cefPush(text, dir)
        text = text:gsub('[%z\1-\8\11\12\14-\31]', '?')
        if #text > 700 then text = text:sub(1, 700) .. '..' end
        local valid, i, n = true, 1, #text                        -- текст не UTF-8 (как правило, CP1251) - перекодируем, иначе в imgui будут знаки ???
        while i <= n do
            local c = text:byte(i)
            local k = (c < 128 and 0) or (c >= 194 and c <= 223 and 1) or (c >= 224 and c <= 239 and 2) or (c >= 240 and c <= 244 and 3)
            if not k then valid = false break end
            for j = 1, k do
                local d = text:byte(i + j)
                if not d or d < 128 or d > 191 then valid = false break end
            end
            if not valid then break end
            i = i + k + 1
        end
        if not valid then text = u8(text) end
        Dev.pushLimited(Dev.cefLog, {w = os.time(), dir = dir, text = text}, 500)
    end
    function Dev.cefPacket(bs, dir)
        local text = Dev.cefRead(bs, dir)
        if text then Dev.cefPush(text, dir) end
    end
    function ctl.cefIn(bs)                                      -- входящий пакет 220: журнал CEF и кликер шара используют один разобранный текст
        local log = B('dev_log_cef', false)[0] and B('dev_log_master', true)[0]
        local bal = B('mm_balloon_on', false)[0]
        if not (log or bal) then return end
        local text = Dev.cefRead(bs, '<')
        if not text then return end
        if log then Dev.cefPush(text, '<') end
        if bal and ctl.mm then ctl.mm.onCef(text) end
    end
    function Dev.cefShow(e) return Dev.dirShow('dev_cef_dir', e) end
    function Dev.evShow(e) return Dev.dirShow('dev_ev_dir', e) end
    function Dev.dirShow(key, e)
        local f = I(key, 0)[0]
        return f == 0 or (f == 1 and e.dir == '<') or (f == 2 and e.dir == '>')
    end
    function Dev.evCount()
        local n = 0
        for _, e in ipairs(Dev.evLog) do if Dev.evShow(e) then n = n + 1 end end
        return n
    end
    function Dev.cefCount()
        local n = 0
        for _, e in ipairs(Dev.cefLog) do if Dev.cefShow(e) then n = n + 1 end end
        return n
    end
    function Dev.cefRaw(e)                                   -- для буфера обмена: CP1251
        if not e.r then
            local ok, dec = pcall(function() return u8:decode(e.text) end)
            e.r = os.date('%H:%M:%S', e.w) .. '  ' .. e.dir .. ' ' .. (ok and dec or e.text)
        end
        return e.r
    end
    function Dev.evClear()
        Dev.evLog, Dev.evStats, Dev.animLog, Dev.cefLog, Dev.freqList, Dev.logSnap = {}, {}, {}, {}, nil, {}
        NotifyOk('Lists cleared')
    end

    -- список внутри окна шестерёнки "Debug overlay": события / частые события / анимации (новые сверху)
    -- строки в исходной кодировке (CP1251): для копирования в буфер обмена; в UTF-8 для показа переводятся один раз
    function Dev.evRaw(e)
        e.r = e.r or (os.date('%H:%M:%S', e.w) .. '  ' .. e.dir .. ' ' .. e.name .. (e.a and (' (' .. e.a .. ')') or ''))
        return e.r
    end
    function Dev.animRaw(e)
        if not e.r then
            local t = os.date('%H:%M:%S', e.w)
            e.r = e.kind == 'srv' and string.format('%s  srv %s / %s', t, tostring(e.lib), tostring(e.name))
                or string.format('%s  %s #%s', t, e.name and (e.name .. (e.file and (' (' .. e.file .. ')') or '')) or '?', tostring(e.id))
        end
        return e.r
    end
    function Dev.freqRaw(st, now)
        return string.format('%s %s  x%d  %.1f/s', st.dir, st.name, st.n, st.n / math.max(now - st.first, 1))
    end
    function Dev.freqSorted()
        local now = os.clock()
        if not Dev.freqList or now - (Dev.freqT or 0) > 0.5 then          -- сортировка не чаще 2 раз в секунду
            local l = {}
            for _, st in pairs(Dev.evStats) do if st.freq then l[#l + 1] = st end end
            table.sort(l, function(a, b) return a.n > b.n end)
            Dev.freqList, Dev.freqT = l, now
        end
        return Dev.freqList, now
    end

    -- копирует текущий список (тот, что выбран в "Log view") в буфер обмена, новые записи сверху
    function Dev.logCopy()
        local view = I('dev_log_view', 0)[0]
        local lines = {}
        if view == 0 then
            for i = #Dev.evLog, 1, -1 do
                if Dev.evShow(Dev.evLog[i]) then lines[#lines + 1] = Dev.evRaw(Dev.evLog[i]) end
            end
        elseif view == 1 then
            local list, now = Dev.freqSorted()
            for _, st in ipairs(list) do lines[#lines + 1] = Dev.freqRaw(st, now) end
        elseif view == 3 then
            for i = #Dev.cefLog, 1, -1 do
                if Dev.cefShow(Dev.cefLog[i]) then lines[#lines + 1] = Dev.cefRaw(Dev.cefLog[i]) end
            end
        else
            for i = #Dev.animLog, 1, -1 do lines[#lines + 1] = Dev.animRaw(Dev.animLog[i]) end
        end
        if #lines == 0 then Notify('Nothing logged yet.') return end
        setClipboardText(table.concat(lines, '\r\n'))
        NotifyOk('Copied to the clipboard')
    end

    -- копирование одной строки лога (raw - в исходной кодировке CP1251)
    function Dev.copyLine(raw)
        setClipboardText(raw)
        NotifyOk('Copied to the clipboard')
    end

    -- список лога: события / частые события / анимации (новые сверху).
    -- Без аргументов - маленький список в окне шестерёнки; size (ImVec2) - большой список в окне лога (строки переносятся).
    function Dev.drawLogView(size, noInput, tag)
        local big = size ~= nil
        local view = I('dev_log_view', 0)[0]
        local fkey = (tag or (big and 'b' or 's')) .. view                 -- свой снимок и своя плашка у каждого экземпляра списка
        Dev.badges = Dev.badges or {}
        local P = imgui.ImVec2
        -- строка под курсором подсвечивается, клик по ней копирует её в буфер обмена (raw - текст строки)
        local function badgeGeom()
            local w0, ww = imgui.GetWindowPos(), imgui.GetWindowWidth()
            local sb = imgui.GetStyle().ScrollbarSize
            local full = tr('Paused: scroll [to the top] for new entries')
            local pre, link, post = full:match('^(.-)%[(.-)%](.*)$')
            if not link then pre, link, post = full, '', '' end
            local words = {}
            local function add(str, isLink)
                for word in u8(str):gmatch('%S+%s*') do words[#words + 1] = {t = word, l = isLink} end
            end
            add(pre, false)
            add(link .. (post:match('^%s') and ' ' or ''), true)
            add(post, false)
            local maxW = math.max(120, ww - sb - 44)                     -- ширина текста внутри плашки
            local lines = {{segs = {}, w = 0}}
            for _, wd in ipairs(words) do
                local ln = lines[#lines]
                local trimmed = imgui.CalcTextSize((wd.t:gsub('%s+$', ''))).x
                if ln.w > 0 and ln.w + trimmed > maxW then
                    ln = {segs = {}, w = 0}
                    lines[#lines + 1] = ln
                end
                local last = ln.segs[#ln.segs]
                if last and last.l == wd.l then last.t = last.t .. wd.t
                else ln.segs[#ln.segs + 1] = {t = wd.t, l = wd.l} end
                local tot = 0
                for _, sg in ipairs(ln.segs) do
                    sg.w = imgui.CalcTextSize(sg.t).x
                    tot = tot + sg.w
                end
                ln.w = tot
            end
            local bw = 0
            for _, ln in ipairs(lines) do bw = math.max(bw, ln.w) end
            local th = imgui.GetTextLineHeight()
            local x1 = w0.x + ww - sb - 10
            return {lines = lines, th = th, x1 = x1, px0 = x1 - (bw + 16), y0 = w0.y + 6, y1 = w0.y + 6 + #lines * (th + 2) + 8}
        end
        local function rowClick(p0, raw)
            if not raw or not imgui.IsWindowHovered() then return end
            local bd, mp = Dev.badges[fkey], imgui.GetIO().MousePos
            if bd and mp.x >= bd[1] and mp.x <= bd[3] and mp.y >= bd[2] and mp.y <= bd[4] then return end      -- плашка "В начало"
            local p1 = imgui.GetCursorScreenPos()
            local wpos = imgui.GetWindowPos()
            local x0 = wpos.x + 2
            local x1 = wpos.x + imgui.GetWindowWidth() - imgui.GetStyle().ScrollbarSize - 2     -- без полосы прокрутки
            local y0, y1 = p0.y - 1, p1.y - imgui.GetStyle().ItemSpacing.y + 1
            if imgui.IsMouseHoveringRect(P(x0, y0), P(x1, y1)) then
                imgui.GetWindowDrawList():AddRectFilled(P(x0, y0), P(x1, y1), C(THEME.main, 0.16), 4)
                if imgui.IsMouseClicked(0) then Dev.copyLine(raw) end
            end
        end
        local function line(txt, col, raw)
            local p0 = imgui.GetCursorScreenPos()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(col[1], col[2], col[3], gfx.galpha))
            if big then imgui.TextWrapped(txt) else imgui.TextUnformatted(txt) end
            imgui.PopStyleColor()
            rowClick(p0, raw)
        end
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(pal.field[1], pal.field[2], pal.field[3], gfx.galpha))
        local cflags = big and (noInput and imgui.WindowFlags.NoInputs or 0) or imgui.WindowFlags.HorizontalScrollbar
        imgui.BeginChild(big and '##evlogbig' or '##evlogview', big and size or P(imgui.GetContentRegionAvail().x, 80), false, cflags)
        imgui.Dummy(P(1, 2))
        imgui.Indent(8)
        local tmain = THEME.main
        local empty = true
        -- Новые строки добавляются сверху и сдвигают всё вниз. Пока список прокручен от начала, показываем
        -- снимок на момент ухода от начала: строки стоят на месте, а лог при этом продолжает записываться.
        Dev.logSnap = Dev.logSnap or {}
        Dev.snapT = Dev.snapT or {}
        local now = os.clock()
        if Dev.logSnap[fkey] and now - (Dev.snapT[fkey] or 0) > 0.5 then Dev.logSnap[fkey] = nil end      -- список не рисовался (окно было закрыто): снимок устарел
        Dev.snapT[fkey] = now
        local snap
        local autoPause = imgui.GetScrollY() > 6
        if autoPause or Dev.pausePtr[0] then
            if not Dev.logSnap[fkey] then
                local src = (view == 0 and Dev.evLog) or (view == 1 and Dev.freqSorted()) or (view == 3 and Dev.cefLog) or Dev.animLog
                local copy = {}
                for i = 1, #src do copy[i] = src[i] end
                Dev.logSnap[fkey] = copy
            end
            snap = Dev.logSnap[fkey]
        else
            Dev.logSnap[fkey] = nil                 -- вернулись к началу: снова показываем живой список
        end
        if snap and autoPause and big then                          -- плашка "В начало": границы считаем до строк, чтобы клик по ней не копировал строку под ней в этом же кадре
            local g = badgeGeom()
            Dev.badges[fkey] = {g.px0, g.y0, g.x1, g.y1}
        else
            Dev.badges[fkey] = nil
        end
        if view == 0 then
            local log = snap or Dev.evLog
            for i = #log, 1, -1 do
                local e = log[i]
                if not Dev.evShow(e) then goto evskip end
                e.s = e.s or u8(Dev.evRaw(e))                -- строку строим один раз
                line(e.s, e.dir == '<' and pal.text or tmain, Dev.evRaw(e))
                empty = false
                ::evskip::
            end
        elseif view == 1 then
            local list, now = Dev.freqSorted()
            list = snap or list
            for _, st in ipairs(list) do
                local p0 = imgui.GetCursorScreenPos()
                InfoRow(st.dir .. ' ' .. st.name, string.format('x%d   %.1f/s', st.n, st.n / math.max(now - st.first, 1)))
                rowClick(p0, Dev.freqRaw(st, now))
                empty = false
            end
        elseif view == 3 then
            local log = snap or Dev.cefLog
            for i = #log, 1, -1 do
                local e = log[i]
                if not Dev.cefShow(e) then goto cefskip end
                e.s = e.s or (os.date('%H:%M:%S', e.w) .. '  ' .. e.dir .. ' ' .. e.text)         -- текст CEF уже в UTF-8
                line(e.s, e.dir == '<' and pal.text or tmain, Dev.cefRaw(e))
                empty = false
                ::cefskip::
            end
        else
            local log = snap or Dev.animLog
            for i = #log, 1, -1 do
                local e = log[i]
                e.s = e.s or u8(Dev.animRaw(e))
                line(e.s, e.kind == 'srv' and tmain or pal.text, Dev.animRaw(e))
                empty = false
            end
        end
        if empty then line(u8(tr('Nothing logged yet.')), pal.dim) end
        imgui.Unindent(8)
        if snap and autoPause and big then                        -- плашка поверх списка: почему строки стоят
            local g = badgeGeom()
            local wdl = imgui.GetWindowDrawList()
            local th = g.th
            wdl:AddRectFilled(P(g.px0, g.y0), P(g.x1, g.y1), C(pal.panel, 0.92), 6)
            for li, ln in ipairs(g.lines) do
                local ty = g.y0 + 4 + (li - 1) * (th + 2)
                local lx = g.px0 + 8
                for si, sg in ipairs(ln.segs) do
                    if sg.l then                                         -- "в начало" прямо в тексте - это и есть кнопка
                        local tw = imgui.CalcTextSize((sg.t:gsub('%s+$', ''))).x
                        imgui.SetCursorScreenPos(P(lx - 2, ty - 1))
                        if imgui.InvisibleButton('##logtop' .. fkey .. li .. '_' .. si, P(tw + 4, th + 2)) then imgui.SetScrollY(0) end
                        local bh = animTo('logtop' .. fkey .. li .. '_' .. si, imgui.IsItemHovered() and 1 or 0, 14)
                        local col = C(mix(tmain, pal.white, bh * 0.5))
                        wdl:AddText(P(lx, ty), col, sg.t)
                        wdl:AddLine(P(lx, ty + th), P(lx + tw, ty + th), col, 1.2)
                    else
                        wdl:AddText(P(lx, ty), C(pal.dim), sg.t)
                    end
                    lx = lx + sg.w
                end
            end
            Dev.badges[fkey] = {g.px0, g.y0, g.x1, g.y1}
        end
        if not (snap and autoPause and big) then Dev.badges[fkey] = nil end
        imgui.EndChild()
        imgui.PopStyleColor()
    end

    -- Software -> Event logger: все настройки журнала событий, анимаций и CEF (в шестерёнке оверлея остались размер текста и положение)
    SOFT.draw.evlog = function()
        Panel('Logging', 0, 0, LAY.COLW, LAY.CH, function()
            local dim = not B('dev_log_master', true)[0] and not SRCH.collecting      -- запись выключена: пункты затемнены
            local ga = gfx.galpha
            if dim then
                gfx.galpha = ga * 0.45
                imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.45)
            end
            Checkbox('Log events', B('dev_log_ev', false))
            Checkbox('Log arguments', B('dev_log_args', true))
            Checkbox('Log animations', B('dev_log_anim', false))
            Checkbox('CEF logger', B('dev_log_cef', false))
            Checkbox('Pause list', Dev.pausePtr)
            Slider('Frequent after', F('dev_ev_freq', 5), 2, 50, '%d per 10 s', true)
            Combo('Log view', I('dev_log_view', 0), {'Events', 'Frequent events', 'Animations', 'CEF'})
            imgui.Dummy(imgui.ImVec2(1, 6))
            if Button('Open full log', 34, true) then ui.logOpen = true end
            if Button('Clear lists', 34) then Dev.evClear() end
            if dim then
                imgui.PopStyleVar()
                gfx.galpha = ga
            end
        end, nil, nil, function()
            SOFT.pageHeader('evlog', LAY.COLW, 'Logging', B('dev_log_master', true))
        end, 30)
        Panel('Log', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, function()
            Dev.drawLogView(imgui.GetContentRegionAvail(), nil, 't')
        end, true, true)
    end

    do
        local ru = i18n.TR.ru
        for k, v in pairs({
            ['Event logger'] = 'Логгер событий', ['Events, animations'] = 'События, анимации', ['and CEF log'] = 'и лог CEF',
            ['Logging'] = 'Запись', ['Debug overlay settings'] = 'Настройки оверлея',
        }) do if ru[k] == nil then ru[k] = v end end
    end

    if okEv and sampev then
        -- ID диалога: запоминаем всегда (для вкладки), в заголовок дописываем по галочке
        sampev.onShowDialog = guard(function(id, style, title, b1, b2, text)
            if ctl.main.onDialog then                          -- Anti GZ: закрывает диалог про запрет драк в зелёной зоне
                local okm, blk = pcall(ctl.main.onDialog, id, text)
                if okm and blk then return false end
            end
            if ctl.taxi then                                   -- Taxi Helper: автоприём заказа
                local okt, blk = pcall(ctl.taxi.onDialog, id)
                if okt and blk then return false end
            end
            if ctl.ap then                                     -- автопиар: автоответы на диалоги /vr и /ad
                local oka, hid = pcall(ctl.ap.onDialog, id, style, title, b1, b2, text)
                if oka and hid then return false end
            end
            local changed = false
            if ctl.ut then                                     -- порт UltraTool: NoDialog / NoDialogRestore / точки в числах
                local oku, r = pcall(ctl.ut.onDialog, id, title, text)
                if oku and r == false then return false end
                if oku and type(r) == 'table' then title, text, changed = r[1], r[2], true end
            end
            if ctl.tg then
                local okg, hide = pcall(ctl.tg.onDialog, id, style, title, b1, b2, text)
                if okg and hide then return false end
            end        -- Telegram: диалоги
            Dev.dlg = {id = id, style = style, title = title}
            if B('dev_dlg_log', false)[0] then
                Dev.add('info', string.format('Dialog ID %d  style %s  "%s"', id, Dev.DLG_STYLES[style] or tostring(style), Dev.short(title, 60)))
            end
            if B('dev_dlg_title', false)[0] then
                return {id, style, string.format('[ID %d] %s', id, title), b1, b2, text}   -- изменённые аргументы: таблицей
            end
            if changed then return {id, style, title, b1, b2, text} end
        end)

        sampev.onSendDialogResponse = guard(function(id, button, listitem, input)
            if id == 8813 and ctl.mm and ctl.mm.cap.active then ctl.mm.cap.finish(button, input) return false end      -- тренер капчи
            if ctl.ut then ctl.ut.onDialogResponse(id, listitem, input) end    -- NoDialogRestore запоминает позицию списка и текст
            if not B('dev_dlg_log', false)[0] then return end
            local hidden = Dev.dlg and Dev.dlg.id == id and Dev.dlg.style == 3      -- PASSWORD: ввод не пишем
            Dev.add('info', string.format('Dialog response: ID %d  button %d  item %d  input "%s"',
                id, button, listitem, hidden and '***' or tostring(input or '')))
        end)

        -- анимация, которую сервер применил к нашему персонажу
        sampev.onApplyPlayerAnimation = guard(function(playerId, lib, name)
            if ctl.main.onAnim then                            -- Anti GZ: гасит анимацию удара в зелёной зоне
                local okm, blk = pcall(ctl.main.onAnim, playerId, lib, name)
                if okm and blk then return false end
            end
            local _, okId, mine = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
            if okId and mine == playerId then
                Dev.applied = {lib = lib, name = name}
                if Dev.logAnim then Dev.animPush('srv', nil, name, nil, lib) end
            end
        end)

        -- Ивенты samp.events (последний входящий/исходящий для оверлея + лог). Библиотека разбирает пакет, только если для него
        -- есть обработчик, поэтому обёртки ставятся на ВСЕ RPC лишь пока нужны (оверлей с "Show last event" или "Log events")
        -- и снимаются после. Sync-пакеты не отслеживаются: они идут десятки раз в секунду.
        -- Память не растёт: лог - кольцо на 500 строк; частые ивенты (>= N раз за 10 с) вообще не пишутся построчно,
        -- для них хранится один счётчик на название (всего несколько сотен чисел за всё время работы).
        local evOrig, evOn = {}, false
        local logOn, argsOn, freqThr = false, true, 5
        local argNames = {}                                  -- название ивента -> имена аргументов из описания samp.events

        -- аргументы ивента одной строкой: arg=значение, ... (строки и таблицы сокращаются, максимум 12 аргументов)
        local function evValue(v)
            local tv = type(v)
            if tv == 'string' then
                local s = #v > 48 and (v:sub(1, 48) .. '..') or v
                return '"' .. s:gsub('%c', ' ') .. '"'
            elseif tv == 'number' then
                return v == math.floor(v) and tostring(v) or string.format('%.3f', v)
            elseif tv == 'table' then
                local s = Dev.fmt(v)
                return #s > 90 and (s:sub(1, 90) .. '..}') or s
            end
            return tostring(v)
        end
        local function evArgs(names, ...)
            local n, parts = select('#', ...), {}
            for i = 1, math.min(n, 12) do
                parts[#parts + 1] = ((names and names[i]) or ('arg' .. i)) .. '=' .. evValue((select(i, ...)))
            end
            if n > 12 then parts[#parts + 1] = '...' end
            local out = table.concat(parts, ', ')
            return #out > 320 and (out:sub(1, 320) .. '..') or out
        end
        local function record(name, dir, now)
            local st = Dev.evStats[name]
            if not st then
                st = {name = name, dir = dir, n = 0, first = now, win0 = now, winN = 0, freq = false}
                Dev.evStats[name] = st
            end
            st.n = st.n + 1
            if now - st.win0 > 10 then                       -- окно 10 с закончилось: если стало реже порога - снова обычный
                if st.freq and st.winN < freqThr then st.freq = false end
                st.win0, st.winN = now, 0
            end
            st.winN = st.winN + 1
            if st.winN >= freqThr then st.freq = true end
            if not st.freq then
                local e = {w = os.time(), dir = dir, name = name}
                Dev.pushLimited(Dev.evLog, e, 500)
                return e                                     -- в неё дописываем аргументы
            end
        end

        function Dev.evSync()
            local master = B('dev_log_master', true)[0]
            logOn = master and B('dev_log_ev', false)[0]
            argsOn = B('dev_log_args', true)[0]
            freqThr = math.floor(F('dev_ev_freq', 5)[0] + 0.5)
            Dev.logAnim = master and B('dev_log_anim', false)[0]
            if Dev.logAnim then Dev.snapshot() end            -- анимации отслеживаются в snapshot (не чаще 20 раз в секунду)
            local want = logOn or (B('dev_overlay', false)[0] and B('dev_ov_event', true)[0]) or false
            if want == evOn or not sampev.INTERFACE then return end
            evOn = want
            if want then
                for _, tname in ipairs({'INCOMING_RPCS', 'OUTCOMING_RPCS'}) do
                    local dir = tname == 'INCOMING_RPCS' and '<' or '>'
                    local ev = dir == '<' and Dev.evIn or Dev.evOut
                    for _, entry in pairs(sampev.INTERFACE[tname] or {}) do
                        local key = entry[1]
                        local names = {}                      -- имена аргументов: entry[2..] = {имя = 'тип'}
                        for i = 2, #entry do
                            if type(entry[i]) == 'table' then
                                local k = next(entry[i])
                                names[#names + 1] = type(k) == 'string' and k or ('arg' .. (#names + 1))
                            end
                        end
                        for _, name in ipairs(type(key) == 'table' and key or {key}) do
                            if type(name) == 'string' and not evOrig[name] then
                                local orig = rawget(sampev, name)
                                evOrig[name] = {orig = orig}
                                argNames[name] = names
                                sampev[name] = function(...)
                                    local now = os.clock()
                                    ev.name, ev.clock, ev.n = name, now, ev.n + 1
                                    if logOn then
                                        local e = record(name, dir, now)
                                        if e and argsOn then
                                            local ok, a = pcall(evArgs, argNames[name], ...)
                                            if ok then e.a = a end
                                        end
                                    end
                                    if orig then return orig(...) end
                                end
                            end
                        end
                    end
                end
            else
                for name, rec in pairs(evOrig) do sampev[name] = rec.orig end
                evOrig = {}
            end
        end

        -- цвет сообщения чата (RGBA, как его присылает сервер): "текст | -12346237"
        sampev.onServerMessage = guard(function(color, text)
            if ctl.main.onMessage then pcall(ctl.main.onMessage, color, text) end     -- Mentions of you
            if ctl.ir then pcall(ctl.ir.onMessage, color, text) end                    -- учёт дохода
            if ctl.taxi then pcall(ctl.taxi.onMessage, color, text) end               -- Taxi Helper: статистика
            local changed = false
            if ctl.ut then                                                              -- точки в числах
                local oks, nt = pcall(ctl.ut.onMessage, text)
                if oks and nt and nt ~= text then text, changed = nt, true end
            end
            if ctl.tg then pcall(ctl.tg.onChat, text) end                     -- Telegram: пересылка чата
            if SOFT.adm then pcall(SOFT.adm.onMessage, color, text) end     -- админ-чекер: автодобавление админов из чата
            if not B('dev_chat_color', false)[0] then
                if changed then return {color, text} end
                return
            end
            if color >= 2147483648 then color = color - 4294967296 end               -- в знаковое число
            local rgb = bit.band(bit.rshift(color, 8), 0xFFFFFF)
            local hex = string.format('%06X', rgb)
            local fmt = I('dev_chat_fmt', 0)[0]
            local suffix
            if fmt == 1 then suffix = string.format(' {A0A0A0}| {%s}%s', hex, hex)
            elseif fmt == 2 then suffix = string.format(' {A0A0A0}| %d | {%s}%s', color, hex, hex)
            else suffix = string.format(' {A0A0A0}| %d', color) end
            Dev.chatColorRaw = color
            Dev.chatColorStr = fmt == 1 and hex or (fmt == 2 and (color .. '  ' .. hex) or tostring(color))
            return {color, text .. suffix}
        end)

        -- нажатия на текстдравы (65535 = выход из режима выбора)
        sampev.onSendClickTextDraw = guard(function(id)
            if not B('dev_td_click', false)[0] then return end
            local str = ''
            if id ~= 65535 then
                local ok, v = pcall(sampTextdrawGetString, id)
                if ok and v then str = Dev.short(v, 18) end
            end
            table.insert(Dev.tdClicks, 1, {id = id, t = os.date('%H:%M:%S'), str = str})
            while #Dev.tdClicks > 30 do table.remove(Dev.tdClicks) end
            Dev.add('info', id == 65535 and 'Textdraw click: cancel'
                or (string.format(tr('Textdraw click: ID %d'), id) .. (str ~= '' and ('  "' .. str .. '"') or '')))
        end)
    end

    -- ID текстдравов на экране и список последних нажатий рисуются прямо поверх игры.
    -- Список существующих текстдравов обновляется 3 раза в секунду (перебор 0..2303), позиции берутся каждый кадр.
    local tdList, tdScan = {}, 0
    imgui.OnFrame(
        function() return (B('dev_td_show', false)[0] or B('dev_td_click', false)[0]) and isSampAvailable() end,
        function(self)
            self.HideCursor = not ui.open[0]
            gfx.galpha = 1
            local P = imgui.ImVec2
            local dl = imgui.GetBackgroundDrawList()
            local ds = imgui.GetIO().DisplaySize
            local now = os.clock()
            imgui.PushFont(fonts.small)
            local lh = imgui.GetTextLineHeight()

            if B('dev_td_show', false)[0] then
                if now - tdScan > 0.3 then
                    tdScan = now
                    local list = {}
                    pcall(function()
                        for id = 0, 2303 do
                            if sampTextdrawIsExists(id) then list[#list + 1] = id end
                        end
                    end)
                    tdList = list
                    Dev.tdCount = #list
                end
                local withText = B('dev_td_text', false)[0]
                local tmain = THEME.main
                for _, id in ipairs(tdList) do
                    local ok, x, y = pcall(sampTextdrawGetPos, id)
                    if ok and x and y and x > -20 and x < 660 and y > -20 and y < 470 then      -- координаты игры 640x448
                        local label = '#' .. id
                        if withText then
                            local ok2, str = pcall(sampTextdrawGetString, id)
                            str = ok2 and Dev.short(str, 22) or ''
                            if str ~= '' then label = label .. '  ' .. str end
                        end
                        local t = u8(label)
                        local tw = imgui.CalcTextSize(t).x
                        local sx, sy = x * ds.x / 640, y * ds.y / 448
                        dl:AddRectFilled(P(sx, sy), P(sx + tw + 8, sy + lh + 4), C(pal.bg, 0.80), 4)
                        dl:AddRect(P(sx, sy), P(sx + tw + 8, sy + lh + 4), C(tmain), 4)
                        dl:AddText(P(sx + 4, sy + 2), C(pal.text), t)
                    end
                end
            end

            -- последние нажатия (только при включённом отслеживании)
            local cl = Dev.tdClicks
            if B('dev_td_click', false)[0] and #cl > 0 then
                local texts, tw = {u8(tr('Textdraw clicks'))}, 0
                for i = 1, math.min(5, #cl) do
                    local c = cl[i]
                    texts[#texts + 1] = u8(c.t .. '  ' .. (c.id == 65535 and 'cancel' or ('ID ' .. c.id .. (c.str ~= '' and ('  ' .. c.str) or ''))))
                end
                for _, t in ipairs(texts) do tw = math.max(tw, imgui.CalcTextSize(t).x) end
                local pad, gap = 9, 3
                local bw, bh = tw + pad * 2 + 4, #texts * lh + (#texts - 1) * gap + pad * 2
                local x, y = ds.x - bw - 12, ds.y * 0.35
                dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.80), 7)
                dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 7)
                dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main), 2)
                for i, t in ipairs(texts) do
                    dl:AddText(P(x + pad + 4, y + pad + (i - 1) * (lh + gap)), C(i == 1 and pal.dim or pal.text), t)
                end
            end
            imgui.PopFont()
        end
    )
end

-- ----------------------------------------------------------------------------
--  Main tab (вкладка "Основное"): Anti speed limit, FOV, Anti GZ, Anti slap, Mentions of you,
--  Quit notification, CEF interface priority. Логика перенесена из arztools.lua.
--  Переключатели - B / F в content[1] (сохраняются в конфиге); здесь память игры, хуки samp.events и оверлей.
-- ----------------------------------------------------------------------------
do
    local M = ctl.main
    M.cef = {mm = false, sb = false, view = nil}     -- состояние CEF-интерфейсов (по пакетам клиента, как в arztools)
    M.applied = {}                                   -- что сейчас записано в память игры
    M.gzAt, M.mentionAt = -100, -100
    M.quits = {}                                     -- метки "игрок вышел" в мире
    M.REASONS = {[0] = 'Timeout / Crash', 'Quit', 'Kick / Ban'}

    -- true, пока открыто меню паузы или (при включённом приоритете CEF) любой CEF-интерфейс / таблица игроков:
    -- в это время панели на экране (админ-чекер, дальний чат, метки выхода) скрываются
    function M.overlayBlocked()
        local c = M.cef
        if c.mm then return true end
        return (B('main_cefprio', true)[0] and (c.view ~= nil or c.sb)) and true or false
    end

    -- пакет 220 от клиента (CEF): onActiveViewChanged|<вид>, mainMenu.status|1, tabMenu.status|1
    function M.onPacket(bs)
        local n = raknetBitStreamGetNumberOfBytesUsed(bs)
        if n <= 0 or n > 4096 then return end
        local t = {}
        for i = 1, n do
            local b = raknetBitStreamReadInt8(bs)
            if b < 0 then b = b + 256 end
            if b >= 32 and b <= 126 then t[#t + 1] = string.char(b) end
        end
        raknetBitStreamResetReadPointer(bs)
        local s = table.concat(t)
        local mm = s:match('^mainMenu%.status|(%d)$')
        if mm then M.cef.mm = (mm == '1') end
        local sb = s:match('^tabMenu%.status|(%d)$')
        if sb then M.cef.sb = (sb == '1') end
        local v = s:match('onActiveViewChanged|(.+)$')
        if v then M.cef.view = (v ~= 'null') and v or nil end
    end

    -- ---------- память игры ----------
    local function patchFoot(on) memory.hex2bin(on and 'B800000000C20400' or '8B4424048D04408B', 5630064, 8) end
    local function patchCar(on)
        memory.setuint8(7527888, on and 51 or 161, true)
        memory.setuint8(7527889, on and 192 or 184, true)
        memory.setuint8(7527890, on and 195 or 122, true)
        memory.setfloat(9254060, on and 0 or 0.003, true)
    end

    -- каждый кадр главного цикла: применяет изменения переключателей
    function M.tick()
        if okMem then
            local asl = B('main_asl', false)[0]
            local foot = asl and B('main_asl_foot', true)[0] or false
            local car = asl and B('main_asl_car', true)[0] or false
            if foot ~= M.applied.foot then M.applied.foot = foot; pcall(patchFoot, foot) end
            if car ~= M.applied.car then M.applied.car = car; pcall(patchCar, car) end
        end
        if B('main_fov', false)[0] then
            local val = math.floor(F('main_fov_val', 70)[0] + 0.5)
            local scoped = false
            local okw, wp = pcall(isCurrentCharWeapon, PLAYER_PED, 34); scoped = okw and wp and isKeyDown(2)   -- снайперка + прицел: штатный угол
            local target = scoped and 70 or val
            local nowF = os.clock()
            if target ~= M.fovT or nowF >= (M.fovAt or 0) then      -- переход FOV длится 250 мс: повторять достаточно раз в 100 мс
                M.fovT, M.fovAt = target, nowF + 0.1
                pcall(cameraSetLerpFov, target, target, 250, true)
            end
            M.applied.fov = true
        elseif M.applied.fov then
            M.applied.fov = nil
            pcall(cameraSetLerpFov, 70, 70, 250, true)
        end
    end

    -- при выгрузке скрипта возвращаем игре её значения
    function M.restore()
        if okMem then
            if M.applied.foot then pcall(patchFoot, false) end
            if M.applied.car then pcall(patchCar, false) end
        end
        if M.applied.fov then pcall(cameraSetLerpFov, 70, 70, 250, true) end
    end

    -- ---------- Anti GZ ----------
    local GZ_TEXT = 'В этом месте запрещено {FC7979}драться/стрелять'
    function M.onAnim(playerId, lib, name)
        if not B('main_antigz', false)[0] then return false end
        if lib ~= 'MISC' or name ~= 'plyr_shkhead' then return false end
        local ok, res, mine = pcall(sampGetPlayerIdByCharHandle, PLAYER_PED)
        if not (ok and res and mine == playerId) then return false end
        if os.clock() - M.gzAt > 3 then
            M.gzAt = os.clock()
            Notify('You are in a green zone!')
        end
        return true
    end
    function M.onDialog(id, text)
        if B('main_antigz', false)[0] and type(text) == 'string' and text:find(GZ_TEXT, 1, true) then
            pcall(sampSendDialogResponse, id, 0, 0, '')
            return true
        end
        return false
    end

    -- ---------- Mentions of you: @ник или @ID в сообщении чата ----------
    function M.onMessage(color, text)
        if not B('main_mention', true)[0] or type(text) ~= 'string' or not text:find('@', 1, true) then return end
        local ok, nick, id = pcall(function()
            local r, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if not r then return nil end
            return sampGetPlayerNickname(pid), pid
        end)
        if not (ok and nick and id) then return end
        local plain = (text:gsub('{%x%x%x%x%x%x}', ''))
        local esc = (nick:gsub('%p', '%%%0'))
        if plain:sub(1, 70):find(esc .. '%[' .. id .. '%]') then return end      -- своё сообщение
        local sender = plain:sub(1, 80):match('([%w_%.%[%]]+)%[%d+%]')              -- Nick[ID] автора строки
        if sender and #WORDS.get('mention_ign') > 0 then
            local ls = lower(sender)
            if WORDS.has('mention_ign', ls) or WORDS.has('mention_ign', (ls:gsub('^%b[]', '', 1))) then return end
        end
        local mine1 = '@' .. lower((nick:gsub('^%b[]', '', 1)))
        local mine2 = '@' .. tostring(id)
        for word in plain:gmatch('%S+') do
            local w = lower(word):gsub('[%.,!%?:;]+$', '')
            if w == mine1 or w == mine2 then
                if os.clock() - M.mentionAt > 10 then
                    M.mentionAt = os.clock()
                    Notify('You were mentioned in the chat!')
                end
                return
            end
        end
    end

    -- ---------- Quit notification: метка на месте, где вышел игрок рядом ----------
    function M.onQuit(playerId, reason)
        if not B('main_quit', true)[0] then return end
        if not sampIsPlayerConnected(playerId) then return end
        local found, ped = sampGetCharHandleBySampPlayerId(playerId)
        if not found then return end
        local nick = sampGetPlayerNickname(playerId)
        local x1, y1, z1 = getCharCoordinates(ped)
        local x2, y2, z2 = getCharCoordinates(PLAYER_PED)
        if getDistanceBetweenCoords3d(x1, y1, z1, x2, y2, z2) > F('main_quit_dist', 50)[0] then return end
        M.quits[#M.quits + 1] = {x = x1, y = y1, z = z1, nick = nick, id = playerId, reason = M.REASONS[reason] or 'Unknown reason',
            time = os.date('%H:%M:%S'), untilT = os.clock() + F('main_quit_time', 15)[0]}
        while #M.quits > 20 do table.remove(M.quits, 1) end
    end

    imgui.OnFrame(
        function() return #M.quits > 0 and ui.open ~= nil and not M.overlayBlocked() end,
        function(self)
            self.HideCursor = not ui.open[0]
            local now = os.clock()
            for i = #M.quits, 1, -1 do
                if now > M.quits[i].untilT then table.remove(M.quits, i) end
            end
            local P = imgui.ImVec2
            local dl = imgui.GetBackgroundDrawList()
            imgui.PushFont(fonts.small)
            local lh = imgui.GetTextLineHeight()
            for _, q in ipairs(M.quits) do
                local _, sx, sy, sz = convert3DCoordsToScreenEx(q.x, q.y, q.z + 1.0)
                if sz and sz > 1 then
                    gfx.galpha = clamp(q.untilT - now, 0, 1)             -- плавно гаснет в последнюю секунду
                    local lines = {
                        u8(string.format(tr('Player %s(%d) left the game'), q.nick, q.id)),
                        u8(tr(q.reason)),
                        u8(tr('Time') .. ': ' .. q.time),
                    }
                    local tw = 0
                    for _, s in ipairs(lines) do tw = math.max(tw, imgui.CalcTextSize(s).x) end
                    local pad = 8
                    local bw, bh = tw + pad * 2 + 4, #lines * lh + (#lines - 1) * 2 + pad * 2
                    local x, y = sx - bw / 2, sy - bh
                    dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.82), 7)
                    dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 7)
                    dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main), 2)
                    for i, s in ipairs(lines) do
                        dl:AddText(P(x + pad + 4, y + pad + (i - 1) * (lh + 2)), C(i == 1 and pal.text or pal.dim), s)
                    end
                end
            end
            imgui.PopFont()
            gfx.galpha = 1
        end
    )
end

-- SAMPFUNCS: исходящие пакеты (CEF-состояние для приоритета интерфейсов)
function onSendPacket(packetId, bitStream)
    if packetId == 220 and ctl.main.onPacket then pcall(ctl.main.onPacket, bitStream) end
    if packetId == 220 and B('dev_log_cef', false)[0] and B('dev_log_master', true)[0] then pcall(Dev.cefPacket, bitStream, '>') end
    if ctl.cm and ctl.cm.hooked then return false end          -- Coord Master: игра не шлёт свои пакеты, пока идёт телепорт и остановка
end

function onReceiveRpc(id, bs)
    if id == 86 and ctl.ut and ctl.ut.noAnim() then return false end                        -- NoAnim: анимации от сервера не применяются
    if ctl.cm and ctl.cm.hooked and (id == 159 or id == 160 or id == 12) then return false end     -- сервер не должен вернуть на место
end

-- ESC закрывает верхнее открытое окно меню (карточка уровня, списки слов, правила, панели), а затем само меню.
-- Нажатие "съедаем" (consumeWindowMessage), чтобы игра не открывала паузу; закрываем на отпускании клавиши (257).
-- В паузе и при назначении клавиши (там ESC очищает бинд) не вмешиваемся.
function onWindowMessage(msg, wparam, lparam)
    if (msg == 256 or msg == 257) and wparam == 27 and ui.open and ui.open[0] then
        if listening and msg == 256 then                       -- ESC при записи клавиши: сбрасываем бинд, меню и паузу игры не трогаем
            listening.key, listening.mod, ctl.lsFirst, listening = 0, 0, nil, nil
            ctl.escSwallow = true
            consumeWindowMessage(true, false)
            return
        elseif ctl.escSwallow then                             -- отпускание этой же клавиши тоже съедаем
            if msg == 257 then ctl.escSwallow = false end
            consumeWindowMessage(true, false)
            return
        end
    end
    if (msg == 256 or msg == 257) and wparam == 27 and ui.open and ui.open[0] and not listening and not isPauseMenuActive() then
        consumeWindowMessage(true, false)
        if msg == 257 then
            local A, FC = SOFT.adm, ctl.far
            if A and A.edit then A.edit = nil
            elseif WORDS.openId then WORDS.openId = nil
            elseif FC.logOpen then FC.logOpen = false
            elseif FC.rulesOpen then FC.rulesOpen = false
            elseif A and A.open then A.open = false
            elseif SIDE.panel then SIDE.panel = nil
            else ui.open[0] = false end
        end
    end
end

-- ----------------------------------------------------------------------------
--  Far chat (Software -> Far chat): реплики игроков вокруг (чат-пузыри) собираются в историю и показываются
--  панелью на экране. Правила: слово / фраза в сообщении либо скрывает строку (Ignore), либо красит её (Color).
--  Правила лежат в moonloader\config\xMercy\Collapse\files\farchat_rules.txt (общие для всех конфигов):
--  строка = режим(i/c)|RRGGBB|слово (cp1251). Логика взята из arztools (bubbleChat).
-- ----------------------------------------------------------------------------
do
    local FC, M = ctl.far, ctl.main
    FC.list, FC.scroll = {}, 0                   -- история (новые в начале) и сдвиг прокрутки
    FC.rules, FC.rulesLoaded = {}, false
    FC.rulesOpen, FC.rulesSaveAt, FC.hl = false, nil, nil
    FC.newMode = 0                               -- 2 - Ignore color; режим нового правила: 0 - Ignore, 1 - Color
    FC.posEdit, FC.posT0 = false, 0
    binds.far_toggle = binds.far_toggle or {key = 0}          -- клавиша включения (сохраняется в [binds] конфига)
    FC.MAX_LIST, FC.MAX_RULES, FC.MAX_WORD = 500, 200, 60
    FC.demo = {                                  -- образец для режима выбора позиции
        {message = 'Alex_Morgan[3] говорит:{B7AFAF} Привет всем', color = 16777215, time = os.time()},
        {message = 'Daniel_Frost[7] ударил Alex_Morgan', color = 13399774, time = os.time()},
        {message = 'Maksim_Volkov[12] кричит: Помогите!', color = 16772208, time = os.time()},
    }

    local function rgbToInt(c)
        return math.floor(c[1] * 255 + 0.5) * 65536 + math.floor(c[2] * 255 + 0.5) * 256 + math.floor(c[3] * 255 + 0.5)
    end
    local function intToRgb(n) return {math.floor(n / 65536) % 256 / 255, math.floor(n / 256) % 256 / 255, n % 256 / 255} end

    function FC.px() return F('far_px', 1.0) end
    function FC.py() return F('far_py', 45.0) end
    function FC.buf(name, size)
        if not FC[name] then FC[name] = imgui.new.char[size]() end
        return FC[name]
    end
    function FC.newCol()
        if not FC.ncol then FC.ncol = imgui.new.float[4](1.0, 0.82, 0.25, 1.0) end
        return FC.ncol
    end

    -- ---------- правила ----------
    function FC.path() return FNT.filesDir() .. '\\farchat_rules.txt' end

    function FC.makeRule(word, mode, rgb)
        rgb = rgb or 0xFFFFFF
        local c = intToRgb(rgb)
        local num = mode == 'icol' and ((tonumber(word) or 0) % 4294967296) or nil      -- icol: номер цвета строки (RGBA, без знака)
        return {word = word, low = lower(word), mode = mode, rgb = rgb, num = num, cbuf = imgui.new.float[4](c[1], c[2], c[3], 1.0)}
    end

    function FC.loadRules()
        if FC.rulesLoaded then return end
        FC.rulesLoaded, FC.rules = true, {}
        local f = io.open(FC.path(), 'rb')
        if not f then return end
        for line in f:lines() do
            local m, hex, word = (line:gsub('\r', '')):match('^([ick])|(%x%x%x%x%x%x)|(.+)$')
            if m and #FC.rules < FC.MAX_RULES and (m ~= 'k' or tonumber(word)) then
                FC.rules[#FC.rules + 1] = FC.makeRule(word, m == 'i' and 'ignore' or m == 'k' and 'icol' or 'color', tonumber(hex, 16))
            end
        end
        f:close()
    end

    function FC.saveRules()
        pcall(FNT.ensureFilesDir)
        local out = {}
        for _, r in ipairs(FC.rules) do
            out[#out + 1] = (r.mode == 'ignore' and 'i' or r.mode == 'icol' and 'k' or 'c') .. '|' .. string.format('%06X', r.rgb) .. '|' .. r.word
        end
        local f = io.open(FC.path(), 'wb')
        if not f then NotifyErr('Could not save the rules') return false end
        f:write(table.concat(out, '\n'))
        f:close()
        return true
    end

    function FC.addRule()
        local buf = FC.buf('wordBuf', 128)
        local ok, raw = pcall(function() return u8:decode(ffi.string(buf)) end)
        local word = ok and trim((raw:gsub('%c', ' '))) or ''
        word = word:sub(1, FC.MAX_WORD)
        if word == '' then return false end
        FC.loadRules()
        local icol = FC.newMode == 2
        if icol then                                 -- номер цвета: -12024824, 4282942472 или 0xFF488408
            local n = tonumber(word)
            if not n or n ~= math.floor(n) or n < -2147483648 or n > 4294967295 then
                NotifyErr('Enter a color number, e.g. -12024824')
                return false
            end
            word = string.format('%d', n >= 2147483648 and n - 4294967296 or n)
        end
        local low = lower(word)
        for i, r in ipairs(FC.rules) do
            if r.low == low and (r.mode == 'icol') == icol then
                FC.hl = {idx = i, t0 = os.clock()}
                Notify('Such a rule already exists!')
                return false
            end
        end
        if #FC.rules >= FC.MAX_RULES then NotifyErr('Could not save the rules') return false end
        local c = FC.newCol()
        table.insert(FC.rules, 1, FC.makeRule(word, icol and 'icol' or FC.newMode == 0 and 'ignore' or 'color', rgbToInt({c[0], c[1], c[2]})))
        if FC.saveRules() then
            FC.hl = {idx = 1, t0 = os.clock()}
            ffi.fill(buf, ffi.sizeof(buf), 0)
            return true
        end
        table.remove(FC.rules, 1)
        return false
    end

    -- ignore побеждает всегда; иначе берётся цвет первого подошедшего правила Color
    function FC.match(plain, raw)
        if not FC.rulesLoaded then FC.loadRules() end
        local low, rgb = lower(plain), nil
        local rawU = type(raw) == 'number' and raw % 4294967296 or nil
        for _, r in ipairs(FC.rules) do
            if r.mode == 'icol' then
                if rawU and r.num == rawU then return 'ignore' end      -- строка нужного цвета
            elseif r.low ~= '' and low:find(r.low, 1, true) then
                if r.mode == 'ignore' then return 'ignore' end
                rgb = rgb or r.rgb
            end
        end
        if rgb then return 'color', rgb end
    end

    function FC.showRules()
        FC.loadRules()
        FC.rulesOpen, FC.hl, FC.logOpen = true, nil, false
        FC.buf('wordBuf', 128)
        FC.refocus = true
        WORDS.openId, SIDE.panel, ui.popOpen = nil, nil, false
        SOFT.adm.open = false
    end

    -- ---------- чат-пузыри ----------
    local function uncap(s) return (s:gsub('^([%u\192-\223])', function(c) return lower(c) end)) end

    function FC.onBubble(playerId, value, value2, value3, text)
        if type(text) ~= 'string' then return end
        local ok, player = pcall(sampGetPlayerNickname, playerId)
        if not ok or not player then return end
        local message, color
        if value == -1 and value2 == 15 and value3 == 10000 then                    -- обычная речь
            message = ('%s[%s] говорит:{B7AFAF} %s'):format(player, playerId, text)
            color = 16777215
        end
        if B('far_logrp', true)[0] and value == -1029514497 and value2 == 10 and value3 == 5000 then    -- /me и системные отыгровки
            local skip = {'Смотрит на {%x%x%x%x%x%x}.+', 'Заглянул%(а%) в карман', 'Просит деньги'}
            local skipped = false
            for _, it in ipairs(skip) do
                if text:match('^' .. it .. '$') then skipped = true break end
            end
            if not skipped then
                local t2 = text:gsub('^(%S+)%s', function(w)
                    if w == player then return '' end
                    return uncap(w) .. ' '
                end, 1)
                message = ('%s[%s] %s'):format(player, playerId, t2)
                color = 13399774
            end
        end
        if value == -253326081 and value2 == 25 and value3 == 5000 then            -- крик
            message = ('%s[%s] кричит: %s'):format(player, playerId, text)
            color = 16772208
        end
        if value == -1 and value2 == 10 and value3 == 10000 then                    -- телефон
            local m = text:match('^{%x%x%x%x%x%x}%[Тел%]:{%x%x%x%x%x%x} %S+ %- (.*)')
            if m then
                message = ('[По телефону]{FFFFFF} %s[%s]: %s'):format(player, playerId, m)
                color = 7582817
            end
        end
        if not message then return end
        local mode, rgb = FC.match((message:gsub('{%x%x%x%x%x%x}', '')), value)
        if mode == 'ignore' then return end
        if mode == 'color' then color = rgb end
        table.insert(FC.list, 1, {message = message, color = color, time = os.time()})
        while #FC.list > FC.MAX_LIST do table.remove(FC.list) end
        if FC.scroll > 0 then FC.scroll = FC.scroll + 1 end                          -- не сбиваем чтение истории
    end

    -- ---------- позиция панели ----------
    function FC.startPosEdit()
        FC.posEdit, FC.posT0 = true, os.clock()
        FC.rulesOpen = false
        ui.open[0] = false                           -- меню скрывается, панель следует за курсором
    end

    function FC.finishPos(xPct, yPct)
        FC.px()[0] = clamp(math.floor(xPct * 10 + 0.5) / 10, 0, 100)
        FC.py()[0] = clamp(math.floor(yPct * 10 + 0.5) / 10, 0, 100)
        FC.posEdit = false
        ui.open[0] = true
        NotifyOk('Overlay position saved')
    end

    -- из главного цикла: ПКМ отменяет выбор позиции; отложенное сохранение правил после смены цвета
    function FC.tick()
        local tk = binds.far_toggle
        if tk and not listening and ctl.bindFire(tk) and not sampIsChatInputActive()
            and not sampIsDialogActive() and not ui.open[0] and not FC.posEdit then
            local ptr = B('far_enable', false)
            ptr[0] = not ptr[0]
            Notify(ptr[0] and 'Far chat enabled' or 'Far chat disabled')      -- только по клавише, из меню без уведомления
        end
        if FC.rulesSaveAt and os.clock() >= FC.rulesSaveAt then
            FC.rulesSaveAt = nil
            FC.saveRules()
        end
        if not FC.posEdit or os.clock() - FC.posT0 < 0.3 then return end
        if ui.open[0] then FC.posEdit = false return end
        if wasKeyPressed(0x02) then
            FC.posEdit = false
            ui.open[0] = true
            Notify('Position change cancelled')
        end
    end

    -- ---------- панель на экране ----------
    -- строка с цветовыми кодами {RRGGBB} -> сегменты {текст, цвет}
    local function segs(text, rgb)
        local out, pos, cur = {}, 1, rgb
        while true do
            local a, b, hex = text:find('{(%x%x%x%x%x%x)}', pos)
            if not a then break end
            if a > pos then out[#out + 1] = {text:sub(pos, a - 1), cur} end
            cur = tonumber(hex, 16)
            pos = b + 1
        end
        if pos <= #text then out[#out + 1] = {text:sub(pos), cur} end
        return out
    end

    imgui.OnFrame(
        function()
            if not ui.open then return false end
            if FC.posEdit then return true end
            if not (B('far_enable', false)[0] and isSampAvailable()) then return false end
            return (#FC.list > 0 and not M.overlayBlocked()) or ui.open[0]      -- пустой лог: панель видна только при открытом меню (как у админ-чекера)
        end,
        function(self)
            local editing = FC.posEdit
            self.HideCursor = not (ui.open[0] or editing)
            gfx.galpha = 1
            local P = imgui.ImVec2
            local dl = imgui.GetBackgroundDrawList()
            local io = imgui.GetIO()
            local ds = io.DisplaySize
            local k = clamp(F('far_scale', 1.0)[0], 0.5, 2.0)
            local font, fk = FNT.pickOverlay(k)             -- шрифт ближайшего размера (текст остаётся чётким)
            local oldScale
            if pcall(function() oldScale = font.Scale; font.Scale = oldScale * fk end) == false or not oldScale then
                font, k, oldScale = fonts.small, 1, nil
            end
            imgui.PushFont(font)
            local lh = imgui.GetTextLineHeight()
            local alpha = clamp(F('far_alpha', 1.0)[0], 0.1, 1.0)
            local nLines = clamp(math.floor(F('far_lines', 5)[0] + 0.5), 1, 50)
            local showTime = B('far_time', false)[0]
            local title = u8(tr('Far chat') .. ':')
            local src = (editing and #FC.list == 0) and FC.demo or FC.list
            FC.scroll = clamp(FC.scroll, 0, math.max(0, #src - nLines))
            local rows, tw = {}, imgui.CalcTextSize(title).x
            for i = FC.scroll + 1, math.min(#src, FC.scroll + nLines) do
                local it = src[i]
                local text = it.message
                if showTime then text = os.date('[%H:%M:%S] ', it.time) .. text end
                local parts, w = segs(text, it.color), 0
                for _, p in ipairs(parts) do
                    p.u = u8(p[1])
                    p.w = imgui.CalcTextSize(p.u).x
                    w = w + p.w
                end
                rows[#rows + 1] = parts
                tw = math.max(tw, w)
            end
            local rev = {}                                          -- в списке новые первыми: переворачиваем, новые - внизу
            for ri = #rows, 1, -1 do rev[#rev + 1] = rows[ri] end
            rows = rev
            local pad, gap = 9 * k, 3 * k
            local bw = tw + pad * 2 + 4 * k
            local bh = (#rows + 1) * lh + #rows * gap + pad * 2
            local x, y
            if editing then
                local m = io.MousePos                       -- левый верхний угол панели - под курсором
                x, y = m.x, m.y
            else
                x, y = FC.px()[0] / 100 * ds.x, FC.py()[0] / 100 * ds.y
            end
            x = clamp(x, 0, math.max(0, ds.x - bw))
            y = clamp(y, 0, math.max(0, ds.y - bh))
            dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.80 * alpha), 7)
            dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border, alpha), 7)
            dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main, alpha), 2)
            if editing then
                dl:AddRect(P(x - 1, y - 1), P(x + bw + 1, y + bh + 1), C(THEME.main), 8)
                dl:AddRect(P(x - 2, y - 2), P(x + bw + 2, y + bh + 2), C(THEME.main, 0.5), 9)
            end
            local tx = x + pad + 4 * k
            dl:AddText(P(tx, y + pad), C(pal.dim, alpha), title)
            for i, parts in ipairs(rows) do
                local ry, cx = y + pad + i * (lh + gap), tx
                for _, p in ipairs(parts) do
                    dl:AddText(P(cx, ry), C(intToRgb(p[2]), alpha), p.u)
                    cx = cx + p.w
                end
            end
            imgui.PopFont()
            if oldScale then pcall(function() font.Scale = oldScale end) end

            -- колесо мыши над панелью (при открытом меню) листает историю: вниз - к старым сообщениям
            if ui.open[0] and not editing then
                local m, wh = io.MousePos, io.MouseWheel
                if wh ~= 0 and not io.WantCaptureMouse and m.x >= x and m.x <= x + bw and m.y >= y and m.y <= y + bh then
                    FC.scroll = clamp(FC.scroll + (wh > 0 and 1 or -1), 0, math.max(0, #src - nLines))
                end
            end

            if editing then
                imgui.PushFont(fonts.bold)
                local lines = {u8(tr('Click LMB to place the chat')), u8(tr('RMB - cancel')),
                    string.format('X %.1f%%   Y %.1f%%', x / ds.x * 100, y / ds.y * 100)}
                local lw, lth = 0, imgui.GetTextLineHeight()
                for _, s in ipairs(lines) do lw = math.max(lw, imgui.CalcTextSize(s).x) end
                local bx2, by2 = (ds.x - lw - 36) / 2, 24
                local bh2 = lth * #lines + 8 * (#lines - 1) + 24
                dl:AddRectFilled(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.bg, 0.88), 8)
                dl:AddRect(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.border), 8)
                dl:AddRectFilled(P(bx2 + 8, by2 + 8), P(bx2 + 11, by2 + bh2 - 8), C(THEME.main), 2)
                for i, s in ipairs(lines) do
                    local col = (i == 1) and pal.text or pal.dim
                    dl:AddText(P(bx2 + 18 + (lw - imgui.CalcTextSize(s).x) / 2, by2 + 12 + (i - 1) * (lth + 8)), C(col), s)
                end
                imgui.PopFont()
                if ui.alpha < 0.02 and os.clock() - FC.posT0 > 0.3 and imgui.IsMouseClicked(0) then
                    FC.finishPos(x / ds.x * 100, y / ds.y * 100)
                end
            end
        end
    )

    -- ---------- окно правил (список слов: игнор / цвет строки) ----------
    function FC.countText(n)
        if i18n.curLang == 'ru' then
            local m10, m100 = n % 10, n % 100
            local w = 'правил'
            if m10 == 1 and m100 ~= 11 then w = 'правило'
            elseif m10 >= 2 and m10 <= 4 and (m100 < 12 or m100 > 14) then w = 'правила' end
            return n .. ' ' .. w
        end
        return n .. (n == 1 and ' rule' or ' rules')
    end

    -- кнопка-переключатель режима: Ignore (красноватая) / Color (цвет темы)
    local function ModePill(id, x, y, w, h, mode, dl)
        local P = imgui.ImVec2
        imgui.SetCursorScreenPos(P(x, y))
        local pressed = imgui.InvisibleButton(id, P(w, h))
        local hv = animTo(id, imgui.IsItemHovered() and 1 or 0, 14)
        local base = (mode == 'ignore' or mode == 'icol') and CONST.BTN_DANGER or THEME.main
        dl:AddRectFilled(P(x, y), P(x + w, y + h), C(mix(pal.field, base, 0.20 + 0.15 * hv)), 6)
        dl:AddRect(P(x, y), P(x + w, y + h), C(mix(pal.border, base, 0.6 + 0.3 * hv)), 6)
        local s = u8(tr(mode == 'ignore' and 'Ignore' or mode == 'icol' and 'Ignore color' or 'Color'))
        local sz = imgui.CalcTextSize(s)
        dl:AddText(P(x + (w - sz.x) / 2, y + (h - sz.y) / 2), C(mix(pal.text, base, 0.5)), s)
        return pressed
    end

    function FC.draw(wp)
        local P = imgui.ImVec2
        local t = animTo('farrules', FC.rulesOpen and 1 or 0, 14)
        if t < 0.01 then return end
        local tmain, e = THEME.main, easeOut(t)
        local al = ui.alpha * t
        gfx.galpha = al

        imgui.SetCursorScreenPos(P(wp.x, wp.y))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(0, 0))
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
        local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
        if not FC.rulesOpen then flags = flags + imgui.WindowFlags.NoInputs end
        imgui.BeginChild('##collapse_farrules', P(LAY.W, LAY.H), false, flags)
        local dl = imgui.GetWindowDrawList()
        dl:AddRectFilled(P(wp.x, wp.y), P(wp.x + LAY.W, wp.y + LAY.H), C({0, 0, 0}, 0.6), 11)

        local PW, PH = 560, 420
        local px, py = wp.x + (LAY.W - PW) / 2, wp.y + (LAY.H - PH) / 2 + (1 - e) * 16
        dl:AddRectFilled(P(px, py), P(px + PW, py + PH), C(pal.border), 11)
        dl:AddRectFilled(P(px + 1, py + 1), P(px + PW - 1, py + PH - 1), C({0.082, 0.088, 0.112}), 10)

        -- заголовок, счётчик, закрыть
        dl:AddRectFilled(P(px + 16, py + 16), P(px + 19, py + 34), C(tmain), 2)
        imgui.PushFont(fonts.bold)
        dl:AddText(P(px + 30, py + 14), C(pal.text), u8(tr('Far chat rules')))
        imgui.PopFont()
        local cnt = u8(FC.countText(#FC.rules))
        dl:AddText(P(px + PW - 52 - imgui.CalcTextSize(cnt).x, py + 16), C(pal.dim), cnt)
        imgui.SetCursorScreenPos(P(px + PW - 40, py + 10))
        if imgui.InvisibleButton('##farrules_x', P(28, 28)) then FC.rulesOpen = false end
        local xh = animTo('farrules_x', imgui.IsItemHovered() and 1 or 0, 14)
        dl:AddRectFilled(P(px + PW - 40, py + 10), P(px + PW - 12, py + 38), C(pal.white, 0.06 * xh), 7)
        local xc, cy2, cx2 = C(mix(pal.dim, pal.text, xh)), py + 24, px + PW - 26
        dl:AddLine(P(cx2 - 5, cy2 - 5), P(cx2 + 5, cy2 + 5), xc, 1.8)
        dl:AddLine(P(cx2 + 5, cy2 - 5), P(cx2 - 5, cy2 + 5), xc, 1.8)
        dl:AddRectFilled(P(px + 16, py + 48), P(px + PW - 16, py + 49), C(pal.border))
        imgui.PushFont(fonts.small)
        dl:AddText(P(px + 16, py + 56), C(pal.dim), u8(tr('Click the mode to switch Ignore / Color.')))
        imgui.PopFont()

        -- список правил
        local lx, ly, lw, lh = px + 16, py + 80, PW - 32, PH - 80 - 64
        dl:AddRectFilled(P(lx, ly), P(lx + lw, ly + lh), C(pal.field, 0.55), 8)
        imgui.SetCursorScreenPos(P(lx + 8, ly + 8))
        imgui.BeginChild('##farrules_list', P(lw - 16, lh - 16), false)
        local ldl = imgui.GetWindowDrawList()
        local origin = imgui.GetCursorScreenPos()
        local availW = imgui.GetContentRegionAvail().x
        local th = imgui.GetTextLineHeight()
        local remove
        if #FC.rules == 0 then
            local s = u8(tr('No rules added'))
            local sz = imgui.CalcTextSize(s)
            ldl:AddText(P(origin.x + (availW - sz.x) / 2, origin.y + (lh - 16) / 2 - sz.y), C(pal.dim), s)
        else
            local rowH, gap = 32, 4
            for i, r in ipairs(FC.rules) do
                local y0 = origin.y + (i - 1) * (rowH + gap)
                local hlA = 0
                if FC.hl and FC.hl.idx == i then
                    local age = os.clock() - FC.hl.t0
                    if age < 1.4 then hlA = (1 - age / 1.4) * (0.5 + 0.5 * math.sin(age * 14)) else FC.hl = nil end
                end
                ldl:AddRectFilled(P(origin.x, y0), P(origin.x + availW, y0 + rowH), C(mix(pal.field, tmain, hlA * 0.6)), 7)
                imgui.SetCursorScreenPos(P(origin.x + 4, y0 + 5))
                if imgui.InvisibleButton('##frx' .. i, P(22, 22)) then remove = i end
                local hh = animTo('frx' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                local xcol = C(mix(pal.dim, CONST.BTN_DANGER, hh))
                ldl:AddLine(P(origin.x + 11, y0 + 12), P(origin.x + 19, y0 + 20), xcol, 1.6)
                ldl:AddLine(P(origin.x + 19, y0 + 12), P(origin.x + 11, y0 + 20), xcol, 1.6)

                -- справа: цвет (только для Color) и переключатель режима
                local fh = imgui.GetFrameHeight()
                local rx = origin.x + availW - 8
                if r.mode == 'color' then
                    rx = rx - fh
                    imgui.SetCursorScreenPos(P(rx, y0 + (rowH - fh) / 2))
                    if imgui.ColorEdit4('##frc' .. i, r.cbuf, imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoLabel) then
                        r.rgb = rgbToInt({r.cbuf[0], r.cbuf[1], r.cbuf[2]})
                        FC.rulesSaveAt = os.clock() + 0.6
                    end
                    if imgui.IsItemHovered() then gfx.hintBlock = true end
                    rx = rx - 6
                end
                local pw = r.mode == 'icol' and 104 or 76
                rx = rx - pw
                if ModePill('##frm' .. i, rx, y0 + 4, pw, rowH - 8, r.mode, ldl) and r.mode ~= 'icol' then
                    r.mode = (r.mode == 'ignore') and 'color' or 'ignore'
                    FC.saveRules()
                end
                local maxW = rx - (origin.x + 36) - 8
                local s = u8(r.word)
                if imgui.CalcTextSize(s).x > maxW then
                    local cut = r.word
                    while #cut > 1 and imgui.CalcTextSize(u8(cut .. '..')).x > maxW do cut = cut:sub(1, -2) end
                    s = u8(cut .. '..')
                end
                ldl:AddText(P(origin.x + 36, y0 + (rowH - th) / 2), C(pal.text), s)
            end
            imgui.SetCursorScreenPos(P(origin.x, origin.y + #FC.rules * (rowH + gap)))
            imgui.Dummy(P(1, 1))
        end
        imgui.EndChild()
        if remove then
            table.remove(FC.rules, remove)
            FC.saveRules()
        end

        -- добавление: слово, режим, цвет, кнопка
        local iy = py + PH - 50
        local mode = FC.newMode == 0 and 'ignore' or FC.newMode == 1 and 'color' or 'icol'
        local right = px + PW - 16
        right = right - 100
        imgui.SetCursorScreenPos(P(right, iy))
        local addBtn = MiniButton('Add', 100, 34, true)
        local sw = 0
        if mode == 'color' then
            local fh = imgui.GetFrameHeight()
            sw = fh + 8
            imgui.SetCursorScreenPos(P(right - 8 - fh, iy + (34 - fh) / 2))
            imgui.ColorEdit4('##frnew', FC.newCol(), imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoLabel)
            if imgui.IsItemHovered() then gfx.hintBlock = true end
        end
        local pillX = right - 8 - sw - 104
        if ModePill('##frnewmode', pillX, iy + 3, 104, 28, mode, dl) then FC.newMode = (FC.newMode + 1) % 3 end
        imgui.SetCursorScreenPos(P(px + 16, iy))
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(10, 7))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 7)
        imgui.SetNextItemWidth(pillX - 8 - (px + 16))
        if FC.refocus and FC.rulesOpen then imgui.SetKeyboardFocusHere(); FC.refocus = false end
        local wb = FC.buf('wordBuf', 128)
        local entered = imgui.InputText('##farrules_input', wb, ffi.sizeof(wb), imgui.InputTextFlags.EnterReturnsTrue)
        imgui.PopStyleVar(2)
        if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
        if ffi.string(wb) == '' then
            dl:AddText(P(px + 26, iy + 8), C(pal.dim, 0.75), u8(tr(mode == 'icol' and 'Color number, e.g. -12024824' or 'Word or phrase')))
        end
        if (addBtn or entered) and FC.rulesOpen then
            FC.addRule()
            FC.refocus = true
        end

        imgui.EndChild()
        imgui.PopStyleVar(2)
        imgui.PopStyleColor()
        gfx.galpha = ui.alpha
    end


    -- ---------- полный лог дальнего чата (кнопка "Show full log") ----------
    FC.logOpen = false
    function FC.showLog()
        FC.logOpen, FC.rulesOpen, FC.logStick = true, false, true         -- лог открывается внизу, у новых сообщений
        WORDS.openId, SIDE.panel, ui.popOpen = nil, nil, false
        SOFT.adm.open = false
    end

    function FC.logPlain()                                       -- от старых к новым, без цветовых кодов
        local out = {}
        for i = #FC.list, 1, -1 do
            local it = FC.list[i]
            out[#out + 1] = os.date('[%H:%M:%S] ', it.time) .. it.message:gsub('{%x%x%x%x%x%x}', '')
        end
        return table.concat(out, '\n')
    end

    local drawRules = FC.draw
    function FC.draw(wp)
        drawRules(wp)
        FC.drawLog(wp)
    end

    function FC.drawLog(wp)
        local P = imgui.ImVec2
        local t = animTo('farlog', FC.logOpen and 1 or 0, 14)
        if t < 0.01 then return end
        local tmain, e = THEME.main, easeOut(t)
        local al = ui.alpha * t
        gfx.galpha = al

        imgui.SetCursorScreenPos(P(wp.x, wp.y))
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, P(0, 0))
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, al)
        local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
        if not FC.logOpen then flags = flags + imgui.WindowFlags.NoInputs end
        imgui.BeginChild('##collapse_farlog', P(LAY.W, LAY.H), false, flags)
        local dl = imgui.GetWindowDrawList()
        dl:AddRectFilled(P(wp.x, wp.y), P(wp.x + LAY.W, wp.y + LAY.H), C({0, 0, 0}, 0.6), 11)

        local PW, PH = 660, 440
        local px, py = wp.x + (LAY.W - PW) / 2, wp.y + (LAY.H - PH) / 2 + (1 - e) * 16
        dl:AddRectFilled(P(px, py), P(px + PW, py + PH), C(pal.border), 11)
        dl:AddRectFilled(P(px + 1, py + 1), P(px + PW - 1, py + PH - 1), C({0.082, 0.088, 0.112}), 10)

        dl:AddRectFilled(P(px + 16, py + 16), P(px + 19, py + 34), C(tmain), 2)
        imgui.PushFont(fonts.bold)
        dl:AddText(P(px + 30, py + 14), C(pal.text), u8(tr('Far chat log')))
        imgui.PopFont()
        local cnt = u8(tr('Messages in history') .. ': ' .. #FC.list)
        dl:AddText(P(px + PW - 52 - imgui.CalcTextSize(cnt).x, py + 16), C(pal.dim), cnt)
        imgui.SetCursorScreenPos(P(px + PW - 40, py + 10))
        if imgui.InvisibleButton('##farlog_x', P(28, 28)) then FC.logOpen = false end
        local xh = animTo('farlog_x', imgui.IsItemHovered() and 1 or 0, 14)
        dl:AddRectFilled(P(px + PW - 40, py + 10), P(px + PW - 12, py + 38), C(pal.white, 0.06 * xh), 7)
        local xc, cy2, cx2 = C(mix(pal.dim, pal.text, xh)), py + 24, px + PW - 26
        dl:AddLine(P(cx2 - 5, cy2 - 5), P(cx2 + 5, cy2 + 5), xc, 1.8)
        dl:AddLine(P(cx2 + 5, cy2 - 5), P(cx2 - 5, cy2 + 5), xc, 1.8)
        dl:AddRectFilled(P(px + 16, py + 48), P(px + PW - 16, py + 49), C(pal.border))

        -- список сообщений: новые сверху, прокрутка колесом
        local lx, ly, lw, lh = px + 16, py + 60, PW - 32, PH - 60 - 64
        dl:AddRectFilled(P(lx, ly), P(lx + lw, ly + lh), C(pal.field, 0.55), 8)
        imgui.SetCursorScreenPos(P(lx + 8, ly + 8))
        imgui.BeginChild('##farlog_list', P(lw - 16, lh - 16), false)
        local ldl = imgui.GetWindowDrawList()
        local origin = imgui.GetCursorScreenPos()
        local th = imgui.GetTextLineHeight()
        local rowH = th + 6
        if #FC.list == 0 then
            local s = u8(tr('Nothing logged yet.'))
            local sz = imgui.CalcTextSize(s)
            ldl:AddText(P(origin.x + (lw - 16 - sz.x) / 2, origin.y + (lh - 16) / 2 - sz.y), C(pal.dim), s)
        else
            imgui.Dummy(P(1, #FC.list * rowH))                    -- высота прокрутки
            local visTop, visBot = ly, ly + lh
            local n = #FC.list
            for k = 1, n do                                       -- сверху старые, внизу новые
                local it = FC.list[n - k + 1]
                local y0 = origin.y + (k - 1) * rowH
                if y0 + rowH >= visTop and y0 <= visBot then
                    local stamp = u8(os.date('[%H:%M:%S] ', it.time))
                    ldl:AddText(P(origin.x, y0), C(pal.dim), stamp)
                    local cx = origin.x + imgui.CalcTextSize(stamp).x
                    for _, part in ipairs(segs(it.message, it.color)) do
                        local s = u8(part[1])
                        ldl:AddText(P(cx, y0), C(intToRgb(part[2])), s)
                        cx = cx + imgui.CalcTextSize(s).x
                    end
                end
            end
            -- прокрутка следует за новыми сообщениями, пока вы не листаете вверх; вернулись вниз - снова следует
            if imgui.IsWindowHovered() and imgui.GetIO().MouseWheel > 0 then FC.logStick = false end
            if FC.logStick then
                imgui.SetScrollY(imgui.GetScrollMaxY())
            elseif imgui.GetScrollY() >= imgui.GetScrollMaxY() - 2 then
                FC.logStick = true
            end
        end
        imgui.EndChild()

        -- кнопка внизу
        imgui.SetCursorScreenPos(P(px + 16, py + PH - 50))
        if MiniButton('Copy log', 110, 34) then
            if #FC.list == 0 then NotifyErr('Nothing to copy')
            else
                setClipboardText(FC.logPlain())
                NotifyOk('Copied to the clipboard')
            end
        end

        imgui.EndChild()
        imgui.PopStyleVar(2)
        imgui.PopStyleColor()
        gfx.galpha = ui.alpha
    end

    if okEv and sampev then
        local oldQuit, oldSync, oldBubble = sampev.onPlayerQuit, sampev.onSendPlayerSync, sampev.onPlayerChatBubble
        sampev.onPlayerQuit = function(playerId, reason)
            pcall(M.onQuit, playerId, reason)
            if oldQuit then return oldQuit(playerId, reason) end
        end
        sampev.onSendPlayerSync = function(data)   
            if ctl.ut and ctl.ut.air and ctl.ut.air.on then
                data.moveSpeed.x = math.sin(-math.rad(getCharHeading(PLAYER_PED))) * 0.39
                data.moveSpeed.y = math.cos(-math.rad(getCharHeading(PLAYER_PED))) * 0.39
                if pZspeed == 1 then
                    data.moveSpeed.z = 0.3
                elseif pZspeed == 2 then
                    data.moveSpeed.z = -0.3
                elseif pZspeed == 0 then
                    data.moveSpeed.z = 0.0
                end
            end                    -- Anti slap from vehicle roof
            if B('main_antislap', false)[0] and data.surfingVehicleId ~= 0 then data.surfingVehicleId = 0 end
            if ctl.ut then pcall(ctl.ut.onPlayerSync, data) end            -- AutoBunnyHop
            if oldSync then return oldSync(data) end
            return data
        end
        sampev.onPlayerChatBubble = function(playerId, color, distance, duration, text)
            pcall(FC.onBubble, playerId, color, distance, duration, text)
            if oldBubble then return oldBubble(playerId, color, distance, duration, text) end
        end
    end
end

-- ----------------------------------------------------------------------------
--  Подсказки и переводы вкладки Main, Far chat и новых пунктов админ-чекера
-- ----------------------------------------------------------------------------
do
    local H = {
        ['Anti speed limit'] = 'The game will not limit your running speed or vehicle speed in restricted places (interiors, railway tracks, some bridges). Choose where it works in the gear menu.',
        ['Field of view (FOV)'] = 'Sets your own camera field of view (standard is 70). The value is changed in the gear menu. While aiming with a sniper rifle the standard value is used.',
        ['Anti GZ'] = 'Ignores the green zone fight ban: blocks the hit animation you get for fighting or shooting and closes the "fighting is forbidden" dialog.',
        ['Anti slap from vehicle roof'] = 'Does not tell the server that you stand on a vehicle roof, so the server cannot slap you off it.',
        ['Mentions of you'] = 'Shows a notification when someone writes @YourNick or @YourID in the chat. Repeats no more than once per 10 seconds.',
        ['Quit notification'] = 'Shows a label at the place where a nearby player left the game: nickname, ID, reason and time. Radius and display time are in the gear menu.',
        ['CEF interface priority'] = 'Hides the on-screen panels of this menu (admin checker, far chat, quit labels) while a game interface is open: pause menu, scoreboard or any CEF window.',
        ['Show admin level'] = 'Shows the admin level next to the nickname in the on-screen list. To set a level, open "Admin list" and click the admin nickname. Admins without a level show nothing.',
        ['Enable far chat'] = 'Shows the replies of players around you (say, /me, shout, phone) in a panel on the screen. History keeps the last 500 messages.',
        ['Log actions (/me)'] = 'Also logs /me actions and other server system actions of players around you.',
        ['Number of lines'] = 'How many chat lines are visible at once. Scroll the mouse wheel over the panel (menu open) to read older messages.',
        ['Mention ignore list'] = 'Nicknames of players whose mentions of you will not trigger a notification. Case does not matter; the clan tag may be omitted.',
        ['Edit rules'] = 'Opens the word list.\n\nIgnore: messages with the word are hidden.\nColor: messages with the word are painted in the color shown next to the rule.\nIgnore color: hides all lines of the given color number, for example -12024824.',
    }
    for k, v in pairs(H) do HINTS[k] = v end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Main'] = 'Основное', ['Functions'] = 'Функции', ['Game'] = 'Игра', ['Notifications'] = 'Уведомления',
        ['Anti speed limit'] = 'Анти-лимит скорости', ['Anti speed limit settings'] = 'Настройки анти-лимита скорости',
        ['In vehicle'] = 'На транспорте',
        ['Field of view (FOV)'] = 'Угол обзора (FOV)', ['FOV settings'] = 'Настройки угла обзора', ['FOV value'] = 'Значение FOV',
        ['Anti GZ'] = 'Анти GZ', ['Anti slap from vehicle roof'] = 'Анти-слап с крыши ТС',
        ['CEF interface priority'] = 'Приоритет CEF интерфейсов',
        ['Mentions of you'] = 'Упоминания Вас', ['Quit notification'] = 'Уведомление о выходе',
        ['Quit notification settings'] = 'Настройки уведомления о выходе',
        ['Notification radius'] = 'Радиус уведомления', ['Display time'] = 'Время показа', ['%d m'] = '%d м',
        ['You are in a green zone!'] = 'Вы в зелёной зоне!', ['You were mentioned in the chat!'] = 'Вас упомянули в чате!',
        ['Player %s(%d) left the game'] = 'Игрок %s(%d) покинул игру', ['Time'] = 'Время',
        ['Timeout / Crash'] = 'Тайм-аут / Краш', ['Quit'] = 'Выход', ['Kick / Ban'] = 'Кик / Бан',
        ['Unknown reason'] = 'Неизвестная причина',
        -- Far chat
        ['Far chat'] = 'Дальний чат', ['Nearby player chat'] = 'Реплики игроков вокруг', ['with word rules'] = 'и правила по словам',
        ['Enable far chat'] = 'Включить дальний чат', ['Chat rules'] = 'Правила чата', ['Show time'] = 'Показывать время',
        ['Log actions (/me)'] = 'Логировать отыгровки (/me)', ['Number of lines'] = 'Количество строк',
        ['Chat scale'] = 'Размер чата', ['Chat opacity'] = 'Прозрачность чата', ['Edit chat position'] = 'Изменить позицию чата',
        ['Edit rules'] = 'Редактировать правила', ['Clear chat history'] = 'Очистить историю чата',
        ['Chat history cleared'] = 'История чата очищена', ['Rules'] = 'Правила', ['Messages in history'] = 'Сообщений в истории',
        ['A word or phrase found in a message either hides it or paints its line. Case does not matter.'] =
            'Слово или фраза в сообщении либо скрывает его, либо красит строку. Регистр не важен.',
        ['Toggle key'] = 'Клавиша включения', ['Far chat enabled'] = 'Дальний чат включён', ['Far chat disabled'] = 'Дальний чат выключен',
        ['Far chat rules'] = 'Правила дальнего чата', ['Show full log'] = 'Показать весь лог', ['Far chat log'] = 'Лог дальнего чата', ['Ignore'] = 'Игнор', ['Color'] = 'Цвет',
        ['Click the mode to switch Ignore / Color.'] = 'Нажмите на режим, чтобы переключить Игнор / Цвет.',
        ['No rules added'] = 'Правил нет', ['Word or phrase'] = 'Слово или фраза',
        ['Such a rule already exists!'] = 'Такое правило уже есть!', ['Could not save the rules'] = 'Не удалось сохранить правила',
        ['Click LMB to place the chat'] = 'Нажмите ЛКМ, чтобы поставить чат',
        -- Admin checker: поиск и уровни
        ['Search by nickname'] = 'Поиск по нику', ['No admins found'] = 'Админы не найдены',
        ['Show admin level'] = 'Показывать уровень админа', ['Admin level'] = 'Уровень админа', ['Level not set'] = 'Уровень не задан',
        ['Leave empty to hide the level.'] = 'Оставьте пустым, чтобы скрыть уровень.',
        ['Cancel'] = 'Отмена', ['Save'] = 'Сохранить', ['lvl'] = 'ур.',
        ['Admin level saved: %s'] = 'Уровень админа сохранён: %s', ['Admin level cleared: %s'] = 'Уровень админа сброшен: %s',
        -- подсказки
        [H['Anti speed limit']] = 'Игра не будет ограничивать скорость бега и скорость транспорта в запрещённых местах (интерьеры, ж/д пути, некоторые мосты). Где именно работает - в настройках (шестерёнка).',
        [H['Field of view (FOV)']] = 'Выставляет свой угол обзора камеры (стандартный - 70). Значение меняется в настройках (шестерёнка). При прицеле со снайперской винтовкой используется стандартный.',
        [H['Anti GZ']] = 'Игнорирует запрет драк в зелёной зоне: блокирует анимацию удара за драку или стрельбу и закрывает диалог о запрете драться.',
        [H['Anti slap from vehicle roof']] = 'Не сообщает серверу, что вы стоите на крыше транспорта, поэтому сервер не сможет слапнуть вас с неё.',
        [H['Mentions of you']] = 'Показывает уведомление, когда в чате пишут @ВашНик или @ВашID. Повторяется не чаще раза в 10 секунд.',
        [H['Quit notification']] = 'Показывает метку на месте, где рядом вышел игрок: ник, ID, причина и время. Радиус и время показа - в настройках (шестерёнка).',
        [H['CEF interface priority']] = 'Скрывает панели этого меню на экране (админ-чекер, дальний чат, метки выхода), пока открыт интерфейс игры: меню паузы, таблица игроков или любое CEF-окно.',
        [H['Show admin level']] = 'Показывает уровень админа рядом с ником в списке на экране. Чтобы задать уровень, откройте "Список админов" и нажмите на ник админа. Если уровень не задан, ничего не пишется.',
        [H['Enable far chat']] = 'Показывает реплики игроков вокруг вас (say, /me, крик, телефон) панелью на экране. В истории хранятся последние 500 сообщений.',
        [H['Log actions (/me)']] = 'Дополнительно записывает отыгровки /me и другие серверные системные отыгровки игроков вокруг.',
        [H['Number of lines']] = 'Сколько строк чата видно одновременно. Колесо мыши над панелью (при открытом меню) листает старые сообщения.',
        [H['Mention ignore list']] = 'Ники игроков, чьи упоминания вас не будут вызывать уведомление. Регистр не важен, клан-тег можно не указывать.',
        ['Mention ignore list'] = 'Игнор-лист упоминаний', ['Mention ignore'] = 'Игнор упоминаний',
        ['Ignore color'] = 'Игнор цвета', ['Color number, e.g. -12024824'] = 'Номер цвета, напр. -12024824',
        ['Enter a color number, e.g. -12024824'] = 'Введите номер цвета, например -12024824',
        [H['Edit rules']] = 'Открывает список слов.\n\nИгнор: сообщения со словом скрываются.\nЦвет: сообщения со словом рисуются цветом, который показан у правила.\nИгнор цвета: скрывает все строки с указанным номером цвета, например -12024824.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Coord Master (Software -> Coord Master): телепорт к метке на карте или к чекпоинту через синхронизацию
--  свободного транспорта рядом с игроком. Механика взята из SpaceWare/ETeleport.lua, оформление своё.
--  Параметры (Step, Pause distance, Pause time) настраиваются на странице и хранятся в конфиге.
--  Команды: /etp - к метке, /etp chp - к чекпоинту, /etp stop - прервать.
-- ----------------------------------------------------------------------------
do
    local CM = {}
    ctl.cm = CM
    CM.active, CM.percent, CM.packet, CM.cancel = false, 0, 0, false
    CM.MAXDIST, CM.SEARCH = 10000, 200
    CM.DEF = {step = 7.5, dist = 350, time = 75}
    CM.avail, CM.availT = false, -10
    CM.t0 = 0

    function CM.step() return F('cm_step', CM.DEF.step) end
    function CM.pdist() return F('cm_dist', CM.DEF.dist) end
    function CM.ptime() return F('cm_time', CM.DEF.time) end

    local function dist3(x1, y1, z1, x2, y2, z2) return getDistanceBetweenCoords3d(x1, y1, z1, x2, y2, z2) end

    -- точка в len метрах от (mx,my,mz) в сторону (cx,cy,cz)
    local function moveTo(mx, my, mz, cx, cy, cz, len)
        local dx, dy, dz = cx - mx, cy - my, cz - mz
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < 0.0001 then return mx, my, mz end
        return mx + dx / d * len, my + dy / d * len, mz + dz / d * len
    end

    function CM.libs()
        if CM.L ~= nil then return CM.L end
        local ok, res = pcall(function()
            require('samp.synchronization')
            pcall(ffi.cdef, 'struct ArizonaPassengerSyncData { PassengerSyncData parent; uint8_t cWeapon; };')
            return {raknet = require('samp.raknet'), sampfuncs = require('sampfuncs')}
        end)
        CM.L = ok and res or false
        return CM.L
    end

    -- ---------- пакеты синхронизации ----------
    function CM.createSync(kind)
        local L = CM.libs()
        local traits = {
            player = {'PlayerSyncData', L.raknet.PACKET.PLAYER_SYNC, sampStorePlayerOnfootData},
            passenger = {'ArizonaPassengerSyncData', L.raknet.PACKET.PASSENGER_SYNC, sampStorePlayerPassengerData},
            unoccupied = {'UnoccupiedSyncData', L.raknet.PACKET.UNOCCUPIED_SYNC, nil},
        }
        local info = traits[kind]
        local ctype = 'struct ' .. info[1]
        local data = ffi.new(ctype, {})
        local ptr = tonumber(ffi.cast('uintptr_t', ffi.new(ctype .. '*', data)))
        if info[3] then
            local _, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
            info[3](pid, ptr)
        end
        local obj = {}
        function obj.send()
            local bs = raknetNewBitStream()
            raknetBitStreamWriteInt8(bs, info[2])
            raknetBitStreamWriteBuffer(bs, ptr, ffi.sizeof(data))
            raknetSendBitStreamEx(bs, L.sampfuncs.HIGH_PRIORITY, L.sampfuncs.UNRELIABLE_SEQUENCED, 1)
            raknetDeleteBitStream(bs)
        end
        return setmetatable(obj, {
            __index = function(_, k) return data[k] end,
            __newindex = function(_, k, v) data[k] = v end,
        })
    end

    function CM.carMatrix(handle)
        if not memory then return 0, 0, 0, 0, 0, 0 end
        local entity = getCarPointer(handle)
        if entity ~= 0 then
            local m = memory.getuint32(entity + 20, true)
            if m ~= 0 then
                return memory.getfloat(m, true), memory.getfloat(m + 4, true), memory.getfloat(m + 8, true),
                       memory.getfloat(m + 16, true), memory.getfloat(m + 20, true), memory.getfloat(m + 24, true)
            end
        end
        return 0, 0, 0, 0, 0, 0
    end

    function CM.sendUnoccupied(x, y, z, vehicleId)
        local handle = select(2, sampGetCarHandleBySampVehicleId(tonumber(vehicleId)))
        local rx, ry, rz, dx, dy, dz = CM.carMatrix(handle)
        local s = CM.createSync('unoccupied')
        s.vehicleId = tonumber(vehicleId)
        s.seatId = 0
        s.roll = {rx, ry, rz}
        s.direction = {dx, dy, dz}
        s.vehicleHealth = 1500
        s.position = {x, y, z}
        s.send()
    end

    function CM.sendPlayer(x, y, z, up, surfingVehicleId)
        local s = CM.createSync('player')
        if surfingVehicleId then
            s.surfingOffsets = {1, 1, 1}
            s.surfingVehicleId = surfingVehicleId
        end
        s.moveSpeed = {0.7, 0.7, up and 0.7 or -0.7}
        s.position = {x, y, z}
        s.send()
    end

    function CM.sendPassenger(x, y, z, vehicleId)
        local s = CM.createSync('passenger')
        s.parent.vehicleId = tonumber(vehicleId)
        s.parent.seatId = 1
        s.parent.health = getCharHealth(PLAYER_PED)
        s.parent.armor = getCharArmour(PLAYER_PED)
        s.parent.position = {x, y, z}
        s.send()
    end

    -- ---------- цели и транспорт ----------
    function CM.getMark()
        local ok, x, y, z = getTargetBlipCoordinates()
        if not ok then return false end
        requestCollision(x, y); loadScene(x, y, z)
        return getTargetBlipCoordinates()
    end

    function CM.getCheckPoint()
        local fx, fy, fz, found = 0.0, 0.0, 0.0, false
        if not memory then return false end
        for id = 0, 31 do
            local base = 0xC7F168 + id * 56
            local mx = representIntAsFloat(readMemory(base, 4, false))
            local my = representIntAsFloat(readMemory(base + 4, 4, false))
            local mz = representIntAsFloat(readMemory(base + 8, 4, false))
            if mx ~= 0.0 or my ~= 0.0 or mz ~= 0.0 then fx, fy, fz, found = mx, my, mz, true end
        end
        return found, fx, fy, fz
    end

    -- ближайший свободный (без водителя) транспорт с пассажирскими местами в радиусе maxDist
    function CM.findVehicle(maxDist)
        local best, bestD = nil, 9999
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        for _, veh in pairs(getAllVehicles()) do
            local okId, vid = sampGetVehicleIdByCarHandle(veh)
            if okId and getDriverOfCar(veh) == -1 and getCarModel(veh) ~= -1 and getMaximumNumberOfPassengers(veh) > 0 then
                local cx, cy, cz = getCarCoordinates(veh)
                local d = dist3(cx, cy, cz, px, py, pz)
                if d < maxDist and d < bestD then best, bestD = vid, d end
            end
        end
        return best
    end

    -- доступность для статуса на странице (не чаще раза в 0.5 с)
    function CM.refreshAvail()
        if os.clock() - CM.availT < 0.5 then return CM.avail end
        CM.availT = os.clock()
        local ok, res = pcall(function()
            return isSampAvailable() and isCharOnFoot(PLAYER_PED) and CM.findVehicle(CM.SEARCH) ~= nil
        end)
        CM.avail = ok and res or false
        return CM.avail
    end

    -- ---------- телепорт ----------
    -- true, пока телепорт идёт и мы подключены к серверу; при выходе с сервера телепорт сразу завершается
    function CM.check()
        if not CM.active then return false end
        local ok, alive = pcall(function() return isSampAvailable() and sampGetGamestate() == 3 end)
        if ok and alive then
            if ctl.alive() then return true end
            CM.active = false                                      -- смерть или нет спавна: телепорт прекращается
            Notify('Teleport stopped: you died or are not spawned')
            return false
        end
        CM.active, CM.lost = false, true
        return false
    end

    function CM.toCar(mx, my, mz, cx, cy, cz)
        local up = cz > mz
        local total = dist3(mx, my, mz, cx, cy, cz)
        while dist3(mx, my, mz, cx, cy, cz) >= 3 and CM.check() do
            wait(0)
            CM.percent = math.floor(100 - dist3(mx, my, mz, cx, cy, cz) / total * 100)          -- этап 1: путь до машины, 0-100%
            mx, my, mz = moveTo(mx, my, mz, cx, cy, cz, 3)
            CM.last, CM.phase = {mx, my, mz}, 'car'
            CM.sendPlayer(mx, my, mz, up)
            wait(50)
        end
        if CM.active then CM.sendPlayer(cx, cy, cz, up) end
    end

    function CM.toTarget(vehicleId, mx, my, mz, cx, cy, cz, step, pauseDistance, pauseTime)
        local handle = select(2, sampGetCarHandleBySampVehicleId(tonumber(vehicleId)))
        local passed = 0
        CM.percent = 0
        local total = dist3(mx, my, mz, cx, cy, cz)
        local t0 = os.time()
        while dist3(mx, my, mz, cx, cy, cz) >= step and CM.check() do
            CM.percent = math.floor(100 - dist3(mx, my, mz, cx, cy, cz) / total * 100)          -- этап 2: путь до точки, снова 0-100%
            mx, my, mz = moveTo(mx, my, mz, cx, cy, cz, step)
            CM.last, CM.phase = {mx, my, mz}, 'target'
            passed = passed + step
            CM.sendUnoccupied(mx, my, mz, vehicleId)
            CM.packet = CM.packet + 1
            if CM.packet % 10 == 0 then
                CM.sendPassenger(mx, my, mz, vehicleId)
                wait(60)
            end
            CM.sendPlayer(mx, my, mz, true, vehicleId)
            wait(60)
            if passed >= pauseDistance then
                wait(pauseTime)
                passed = 0
            end
        end
        if not CM.active then return false end
        wait(400)
        CM.sendUnoccupied(cx, cy, cz, vehicleId)
        setCharCoordinates(PLAYER_PED, cx, cy, cz)
        setCarCoordinates(handle, cx + 1, cy - 1, cz)
        NotifyOk('Teleported in %d s', os.time() - t0)
        return true
    end

    function CM.start(mode)
        if CM.active or CM.hooked then NotifyErr('Teleport is already running') return end
        if not CM.libs() then NotifyErr('Sync libraries not found') return end
        if not isSampAvailable() then return end
        if not ctl.alive() then NotifyErr('You must be alive and spawned') return end
        local ok, x, y, z
        if mode == 'chp' then ok, x, y, z = CM.getCheckPoint() else ok, x, y, z = CM.getMark() end
        if not ok then NotifyErr(mode == 'chp' and 'Checkpoint not found' or 'Set a marker on the map first') return end
        if not isCharOnFoot(PLAYER_PED) then NotifyErr('You must be on foot') return end
        local vehicleId = CM.findVehicle(CM.SEARCH)
        if not vehicleId then NotifyErr('No free vehicle nearby') return end
        local handle = select(2, sampGetCarHandleBySampVehicleId(vehicleId))
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        local cx, cy, cz = getCarCoordinates(handle)
        if dist3(cx, cy, cz, x, y, z) >= CM.MAXDIST then NotifyErr('Maximum distance is %d m', CM.MAXDIST) return end
        local step = clamp(CM.step()[0], 1, 15)
        local pdist = CM.pdist()[0]
        local ptime = CM.ptime()[0]
        CM.carPhase = dist3(px, py, pz, cx, cy, cz) > 49          -- сначала подходим к машине (первая половина шкалы)
        CM.active, CM.hooked, CM.percent, CM.packet, CM.t0 = true, true, 0, 0, os.clock()
        CM.last, CM.phase, CM.userStop, CM.handle = nil, nil, false, handle
        Notify('Teleporting: %d m', math.floor(dist3(px, py, pz, x, y, z)))
        lua_thread.create(function()
            local okRun = pcall(function()
                if CM.carPhase then CM.toCar(px, py, pz, cx, cy, cz) end
                if CM.active then
                    wait(500)
                    CM.toTarget(vehicleId, cx, cy, cz, x, y, z, step, pdist, ptime)
                end
            end)
            if CM.userStop and CM.last then                 -- отмена: игрок и машина оказываются там, где их видит сервер
                -- 1) передача позиции уже прекращена, игрок стоит на месте (хуки ещё держатся - серверу ничего не уходит)
                -- 2) переносим игрока туда, где он сейчас для сервера; 3) ниже хуки снимаются и идёт обычная синхронизация
                pcall(function()
                    wait(100)
                    setCharCoordinates(PLAYER_PED, CM.last[1], CM.last[2], CM.last[3])
                    if CM.phase == 'target' then setCarCoordinates(CM.handle, CM.last[1] + 1, CM.last[2] - 1, CM.last[3]) end
                    wait(100)
                end)
            end
            local lost = CM.lost
            if not okRun and not lost then
                local okG, alive = pcall(function() return isSampAvailable() and sampGetGamestate() == 3 end)
                lost = not (okG and alive)
            end
            CM.active, CM.hooked, CM.packet, CM.percent, CM.lost = false, false, 0, 0, false
            if lost then NotifyErr('Teleport stopped: connection to the server lost')
            elseif not okRun then NotifyErr('Teleport failed') end
        end)
    end

    function CM.stop()
        if CM.active then
            CM.active, CM.userStop = false, true
            Notify('Teleport cancelled')
        end
    end

    -- ---------- команды (строка команды настраивается на странице, пустая - команда отключена) ----------
    -- строка: имя команды и необязательный аргумент, например "ctp" или "ctp stop"
    CM.KEYS = {'cm_cmd_mark', 'cm_cmd_chp', 'cm_cmd_stop'}
    CM.DEFCMD = {cm_cmd_mark = 'ctp', cm_cmd_chp = 'ctp cpm', cm_cmd_stop = 'ctp stop'}
    CM.cmds, CM.registered, CM.bufs = {}, {}, {}
    for k, v in pairs(CM.DEFCMD) do CM.cmds[k] = v end

    function CM.parse(s)
        s = lower(trim(s or '')):gsub('^/+', '')
        local name, arg, rest = s:match('^(%S+)%s*(%S*)%s*(.*)$')
        if not name or rest ~= '' or not sanitizeCmd(name) then return nil end
        if arg ~= '' and not arg:match('^[a-z0-9_]+$') then return nil end
        return name, arg
    end

    function CM.norm(s)
        local name, arg = CM.parse(s)
        if not name then return nil end
        return arg ~= '' and (name .. ' ' .. arg) or name
    end

    -- кик, обрыв или отключение сервером: телепорт прекращается сразу, не дожидаясь следующего шага потока
    function CM.onDisconnect()
        if CM.active or CM.hooked then
            CM.active, CM.hooked, CM.lost = false, false, true
        end
    end

    function CM.restore()
        CM.active, CM.hooked = false, false
    end

    function CM.runCmd(key)
        if key == 'cm_cmd_mark' then CM.start('mark')
        elseif key == 'cm_cmd_chp' then CM.start('chp')
        else CM.stop() end
    end

    function CM.dispatch(name, arg)
        arg = lower(trim(arg or ''))
        local full = arg ~= '' and (name .. ' ' .. arg) or name
        for _, key in ipairs(CM.KEYS) do
            if CM.cmds[key] == full then CM.runCmd(key) return end
        end
    end

    function CM.registerCmd()
        if not CMD.cmdReady then return end
        local want = {}
        for _, key in ipairs(CM.KEYS) do
            local name = CM.parse(CM.cmds[key])
            if name then want[name] = true end
        end
        for name in pairs(CM.registered) do
            if not want[name] then
                pcall(sampUnregisterChatCommand, name)
                CM.registered[name] = nil
            end
        end
        for name in pairs(want) do
            if not CM.registered[name] then
                pcall(sampRegisterChatCommand, name, function(arg) CM.dispatch(name, arg) end)
                CM.registered[name] = true
            end
        end
    end

    -- из конфига ([str]); отсутствующая или неверная запись - значение по умолчанию
    function CM.applyCmds(cs)
        for _, key in ipairs(CM.KEYS) do
            local v = cs and cs[key]
            if v == nil then v = CM.DEFCMD[key]
            elseif trim(tostring(v)) == '' then v = ''
            else v = CM.norm(tostring(v)) or CM.DEFCMD[key] end
            CM.cmds[key] = v
            if CM.bufs[key] then ffi.copy(CM.bufs[key], v) end
        end
        CM.registerCmd()
    end

    function CM.cmdBuf(key)
        if not CM.bufs[key] then
            CM.bufs[key] = imgui.new.char[32]()
            ffi.copy(CM.bufs[key], CM.cmds[key])
        end
        return CM.bufs[key]
    end

    function CM.applyCmd(key)
        local buf = CM.cmdBuf(key)
        local s = trim(ffi.string(buf))
        local n = ''
        if s ~= '' then
            n = CM.norm(s)
            if not n then
                ffi.copy(buf, CM.cmds[key])
                NotifyErr('Invalid command: use latin letters, digits and _')
                return
            end
            local used = CM.parse(n) == CMD.cmdName
            for _, k2 in ipairs(CM.KEYS) do if k2 ~= key and CM.cmds[k2] == n then used = true end end
            if used then
                ffi.copy(buf, CM.cmds[key])
                NotifyErr('This command is already used')
                return
            end
        end
        ffi.copy(buf, n)
        if n == CM.cmds[key] then return end
        CM.cmds[key] = n
        CM.registerCmd()
        if n == '' then Notify('Command disabled') else NotifyOk('Command changed: /%s', n) end
    end

    -- ---------- страница ----------
    local function LeftBody()
        Slider('Step', CM.step(), 1.0, 15.0, '%.1f', false)
        Slider('Pause distance', CM.pdist(), 50, 1000, '%d m', true)
        Slider('Pause time', CM.ptime(), 0, 500, '%d ms', true)
        imgui.Dummy(imgui.ImVec2(1, 4))
        if Button('Reset to defaults', 34) then
            CM.step()[0], CM.pdist()[0], CM.ptime()[0] = CM.DEF.step, CM.DEF.dist, CM.DEF.time
            Notify('Parameters reset')
        end
        imgui.Dummy(imgui.ImVec2(1, 6))
        TextRow('Marker command', CM.cmdBuf('cm_cmd_mark'), function() CM.applyCmd('cm_cmd_mark') end, '/', nil, 112)
        TextRow('Checkpoint command', CM.cmdBuf('cm_cmd_chp'), function() CM.applyCmd('cm_cmd_chp') end, '/', nil, 112)
        TextRow('Cancel command', CM.cmdBuf('cm_cmd_stop'), function() CM.applyCmd('cm_cmd_stop') end, '/', nil, 112)
    end

    local function RightBody()
        Text('A free vehicle must be in the stream zone. Set a marker on the map and press the button. The parameters are applied at the start of each teleport.', pal.dim)
        if SRCH.collecting then return end
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        imgui.Dummy(P(1, 6))
        local st
        if CM.active then st = tr('Teleporting') .. ' ' .. math.floor(CM.percent) .. '%'
        elseif CM.refreshAvail() then st = tr('Available')
        else st = tr('Not available') end
        InfoRow('Status', st)
        InfoRow('Max distance', CM.MAXDIST .. ' ' .. tr('m'))
        imgui.Dummy(P(1, 4))
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        local k = animTo('cmbar', CM.active and CM.percent / 100 or 0, 10)
        dl:AddRectFilled(p, P(p.x + w, p.y + 8), C(pal.field), 4)
        if k > 0.005 then dl:AddRectFilled(p, P(p.x + w * k, p.y + 8), C(THEME.main), 4) end
        imgui.Dummy(P(w, 14))
        if CM.active then
            if Button('Cancel', 34) then CM.stop() end
        else
            if Button('Teleport to marker', 34, true) then CM.start('mark') end
            if Button('Teleport to checkpoint', 34) then CM.start('chp') end
        end
    end

    SOFT.draw.coordmaster = function()
        Panel('Coord Master', 0, 0, LAY.COLW, LAY.CH, LeftBody, nil, nil, function()
            SOFT.pageHeader('cm', LAY.COLW)
        end, 30)
        Panel('Teleport', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, RightBody)
    end

    -- ---------- индикатор на экране ----------
    imgui.OnFrame(
        function() return ui.open ~= nil and CM.active and isSampAvailable() end,
        function(self)
            self.HideCursor = not ui.open[0]
            gfx.galpha = 1
            local P, dl, ds = imgui.ImVec2, imgui.GetBackgroundDrawList(), imgui.GetIO().DisplaySize
            imgui.PushFont(fonts.bold)
            local s = u8(tr('Coord Master') .. ': ' .. math.floor(CM.percent) .. '%')
            local tw, lh = imgui.CalcTextSize(s).x, imgui.GetTextLineHeight()
            local bw, bh = math.max(tw + 48, 320), lh + 46
            local x, y = (ds.x - bw) / 2, ds.y - bh - 40
            dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.88), 10)
            dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 10)
            dl:AddText(P(x + (bw - tw) / 2, y + 10), C(pal.text), s)
            imgui.PopFont()
            dl:AddRectFilled(P(x + 16, y + bh - 20), P(x + bw - 16, y + bh - 10), C(pal.field), 5)
            dl:AddRectFilled(P(x + 16, y + bh - 20), P(x + 16 + (bw - 32) * clamp(CM.percent / 100, 0, 1), y + bh - 10), C(THEME.main), 5)
        end
    )

    -- ---------- подсказки и переводы ----------
    local H = {
        ['Step'] = 'Distance in meters between two sync packets. A bigger step is faster but looks less natural to the server.',
        ['Pause distance'] = 'After this many meters of travel the teleport makes a short pause (see Pause time).',
        ['Pause time'] = 'Length of that pause in milliseconds. Set 0 to disable the pauses.',
    }
    for k, v in pairs(H) do HINTS[k] = v end
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Coord Master'] = 'Coord Master', ['Teleport to the marker'] = 'Телепорт к метке',
        ['Teleport'] = 'Телепорт', ['Step'] = 'Шаг', ['Pause distance'] = 'Дистанция паузы', ['Pause time'] = 'Время паузы',
        ['%d ms'] = '%d мс', ['Reset to defaults'] = 'Сбросить по умолчанию', ['Parameters reset'] = 'Параметры сброшены',
        ['A free vehicle must be in the stream zone. Set a marker on the map and press the button. The parameters are applied at the start of each teleport.'] =
            'В зоне стрима должен быть свободный автомобиль. Поставьте метку на карте и нажмите кнопку. Параметры применяются в начале каждого телепорта.',
        ['Status'] = 'Статус', ['Teleporting'] = 'Телепортация', ['Available'] = 'Доступно', ['Not available'] = 'Недоступно',
        ['Max distance'] = 'Макс. дистанция', ['Cancel'] = 'Отмена',
        ['Teleport to marker'] = 'Телепорт к метке', ['Teleport to checkpoint'] = 'Телепорт к чекпоинту',
        ['Teleporting: %d m'] = 'Телепортация: %d м', ['Teleported in %d s'] = 'Телепортирован за %d сек',
        ['Teleport is already running'] = 'Телепорт уже идёт', ['Teleport cancelled'] = 'Телепорт отменён', ['Teleport stopped: connection to the server lost'] = 'Телепорт прерван: соединение с сервером потеряно', ['Teleport failed'] = 'Ошибка телепорта',
        ['Sync libraries not found'] = 'Не найдены библиотеки синхронизации', ['Set a marker on the map first'] = 'Сначала поставьте метку на карте',
        ['Checkpoint not found'] = 'Чекпоинт не найден', ['You must be on foot'] = 'Вы должны быть пешком',
        ['No free vehicle nearby'] = 'Рядом нет свободного транспорта', ['Maximum distance is %d m'] = 'Максимальная дистанция: %d м',
        [H['Step']] = 'Расстояние в метрах между двумя пакетами синхронизации. Больше шаг - быстрее, но менее естественно для сервера.',
        [H['Pause distance']] = 'Через столько метров пути телепорт делает короткую паузу (см. "Время паузы").',
        ['Marker command'] = 'Телепорт к метке', ['Checkpoint command'] = 'Телепорт к чекпоинту', ['Cancel command'] = 'Отменить телепорт',
        ['This command is already used'] = 'Эта команда уже используется', ['Command disabled'] = 'Команда отключена',
        [H['Pause time']] = 'Длительность этой паузы в миллисекундах. 0 - паузы отключены.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Speed Boost (Software -> Speed Boost): ускорение транспорта по клавише. Механика и параметры взяты из SpeedX.lua:
--  пока зажата клавиша активации (или при автоускорении - W), скорость машины умножается на множитель
--  каждый кадр, пока она ниже максимальной; ABS - гасит скорость при нажатии S на большой скорости.
--  Включение, клавиша и параметры настраиваются на странице и хранятся в конфиге.
-- ----------------------------------------------------------------------------
do
    local SX = {}
    ctl.sx = SX
    SX.DEF = {max = 100, boost = 1.01}
    SX.lastDelay = 0
    SX.speed = nil
    binds.speedx_key = binds.speedx_key or {key = 0x10, mod = 0}      -- по умолчанию Shift (как в SpeedX.lua)

    function SX.max() return F('sx_max', SX.DEF.max) end
    function SX.boost() return F('sx_boost', SX.DEF.boost) end

    -- вызывается каждый кадр из основного цикла
    function SX.tick()
        SX.speed, SX.active = nil, false
        if not memory or not B('sx_enable', false)[0] or listening then return end
        if not isSampAvailable() or sampIsCursorActive() or not sampIsLocalPlayerSpawned() then return end
        local vehicle = getCarCharIsUsing(1)
        if vehicle == -1 or getDriverOfCar(vehicle) ~= PLAYER_PED then return end
        local speed = getCarSpeed(vehicle) * 3.6
        SX.speed = speed
        local kb = binds.speedx_key
        local keyDown = kb.key ~= 0 and isKeyDown(kb.key) and ctl.modOk(kb)
        local auto = B('sx_auto', false)[0] and SX.lastDelay < os.clock() and isKeyDown(0x57)        -- W
        if keyDown or auto then
            SX.active = true
            SX.lastDelay = os.clock() + 0.1
            if speed < SX.max()[0] then
                local base, k = getCarPointer(vehicle) + 0x44, SX.boost()[0]
                for i = 0, 8, 4 do memory.setfloat(base + i, memory.getfloat(base + i, true) * k, true) end
            end
        end
        if B('sx_abs', true)[0] and isKeyJustPressed(0x53) and speed > 30 then                       -- S
            local base = getCarPointer(vehicle) + 0x44
            for i = 0, 8, 4 do memory.setfloat(base + i, memory.getfloat(base + i, true) / 1.2, true) end
        end
    end

    -- ---------- страница ----------
    local function LeftBody()
        if SRCH.collecting then Reg('Enable Speed Boost', 'Checkbox') end
        local dim = not B('sx_enable', false)[0] and not SRCH.collecting
        local ga = gfx.galpha
        if dim then
            gfx.galpha = ga * 0.45
            imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.45)
        end
        Keybind('Activation key', binds.speedx_key)
        Slider('Max speed', SX.max(), 50, 500, '%d km/h', true)
        Slider('Boost multiplier', SX.boost(), 1.001, 1.1, '%.3f', false)
        Checkbox('Auto boost', B('sx_auto', false))
        Checkbox('Brake assist (ABS)', B('sx_abs', true))
        if dim then
            imgui.PopStyleVar()
            gfx.galpha = ga
        end
    end

    local function RightBody()
        Text('Hold the activation key while driving to speed up the vehicle until the maximum speed is reached. With auto boost the W key accelerates by itself.', pal.dim)
        if SRCH.collecting then return end
        imgui.Dummy(imgui.ImVec2(1, 6))
        InfoRow('Current speed', SX.speed and (math.floor(SX.speed + 0.5) .. ' ' .. tr('km/h')) or '-')
        imgui.Dummy(imgui.ImVec2(1, 4))
        if Button('Reset to defaults', 34) then
            SX.max()[0], SX.boost()[0] = SX.DEF.max, SX.DEF.boost
            B('sx_auto', false)[0], B('sx_abs', true)[0] = false, true
            binds.speedx_key.key, binds.speedx_key.mod = 0x10, 0
            Notify('Parameters reset')
        end
    end

    SOFT.draw.speedx = function()
        Panel('Speed Boost', 0, 0, LAY.COLW, LAY.CH, LeftBody, nil, nil, function()
            SOFT.pageHeader('sx', LAY.COLW, 'Enable Speed Boost', B('sx_enable', false))
        end, 30)
        Panel('Information', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, RightBody)
    end

    -- ---------- подсказки и переводы ----------
    local H = {
        ['Auto boost'] = 'Accelerates while the W key is held, without pressing the activation key.',
        ['Brake assist (ABS)'] = 'Pressing S above 30 km/h also reduces the speed, so the vehicle brakes harder.',
    }
    for k, v in pairs(H) do HINTS[k] = v end
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Speed Boost'] = 'Speed Boost', ['Vehicle acceleration'] = 'Ускорение транспорта', ['on a key'] = 'по клавише',
        ['Enable Speed Boost'] = 'Включить Speed Boost', ['Activation key'] = 'Клавиша активации', ['Max speed'] = 'Максимальная скорость',
        ['Boost multiplier'] = 'Множитель ускорения', ['Auto boost'] = 'Автоускорение', ['Brake assist (ABS)'] = 'Помощь торможения (ABS)',
        ['%d km/h'] = '%d км/ч', ['km/h'] = 'км/ч', ['Current speed'] = 'Текущая скорость', ['Information'] = 'Информация',
        ['Hold the activation key while driving to speed up the vehicle until the maximum speed is reached. With auto boost the W key accelerates by itself.'] =
            'Зажмите клавишу активации за рулём, чтобы разгонять транспорт до максимальной скорости. При автоускорении разгон идёт сам при зажатой W.',
        [H['Auto boost']] = 'Разгон при зажатой W, без нажатия клавиши активации.',
        [H['Brake assist (ABS)']] = 'Нажатие S на скорости выше 30 км/ч дополнительно гасит скорость, транспорт тормозит сильнее.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Chat calculator (Основное -> Chat calculator): пока открыт ввод чата, выражение вроде 250/100*30 считается
--  на лету, результат показывается под строкой ввода; клавиша копирования кладёт его в буфер обмена.
--  Логика взята из Chat-Calculator v4.lua (blast.hk, Adrian G.), оформление своё.
-- ----------------------------------------------------------------------------
do
    local CC = {}
    ctl.calc = CC
    CC.ok, CC.value, CC.text = false, 0, ''
    binds.calc_copy = binds.calc_copy or {key = 0x12, mod = 0}          -- по умолчанию Alt

    -- 1234567 -> 1 234 567
    local function sep(s)
        local left, num, right = s:match('^([^%d]*%d)(%d*)(.-)$')
        if not left then return s end
        return left .. (num:reverse():gsub('(%d%d%d)', '%1 '):reverse()) .. right
    end

    function CC.format(n)
        if B('calc_intonly', false)[0] then n = (math.modf(n)) end
        if n == 0 then n = 0 end
        if n == math.floor(n) and math.abs(n) < 1e15 then return string.format('%.0f', n) end
        local s = string.format('%.10f', n)
        s = s:gsub('0+$', '')
        s = s:gsub('%.$', '')
        return s
    end

    function CC.copy()
        local s = CC.format(CC.value)
        if not B('calc_nospace', false)[0] then s = sep(s) end
        setClipboardText(s)
        if B('calc_clear', true)[0] then sampSetChatInputText('') end
        NotifyOk('Result copied')
    end

    -- проценты считает скрипт: 100-10% -> 90, 200+50% -> 300, 250*30% -> 75, 50/10% -> 500, 50% -> 0.5.
    -- Процент после + и - берётся от всего выражения слева; "%" перед числом или скобкой остаётся остатком от деления.
    function CC.percent(expr)
        for _ = 1, 8 do
            local a, b, num
            local pos, found = 1, false
            while true do
                a, b, num = expr:find('(%d+%.?%d*)%s*%%', pos)
                if not a then break end
                local nxt = expr:sub(b + 1):match('^%s*(.?)')
                if nxt == '' or nxt:find('^[%+%-%*/%^%)]') then found = true break end
                pos = b + 1
            end
            if not found then break end
            local before, tail = expr:sub(1, a - 1), expr:sub(b + 1)
            local pre, op = before:match('^(.-)%s*([%+%-%*/])%s*$')
            if op == '+' or op == '-' then
                expr = pre .. op .. '((' .. (pre ~= '' and pre or '0') .. ')*' .. num .. '/100)' .. tail
            elseif op then
                expr = pre .. op .. '(' .. num .. '/100)' .. tail
            else
                expr = before .. '(' .. num .. '/100)' .. tail
            end
        end
        return expr
    end

    -- каждый кадр из основного цикла
    function CC.tick()
        CC.ok = false
        if not B('main_calc', false)[0] or not isSampAvailable() or not sampIsChatInputActive() then return end
        local text = sampGetChatInputText() or ''
        if text == '' or not text:find('%d+') or not text:find('[-+/*^%%]') or text:find('[%a]+') then return end
        local intOnly = B('calc_intonly', false)[0]
        if text ~= CC.lastIn or CC.lastLang ~= i18n.curLang or CC.lastInt ~= intOnly then      -- считаем заново, только если изменился текст или формат
            CC.lastIn, CC.lastLang, CC.lastInt, CC.lastOk, CC.lastVal, CC.lastText = text, i18n.curLang, intOnly, false, nil, nil
            local f = load('return ' .. CC.percent(text))
            if f then
                setfenv(f, {})
                local ok, res = pcall(f)
                if ok and type(res) == 'number' and res == res and res ~= math.huge and res ~= -math.huge then
                    CC.lastOk, CC.lastVal = true, res
                    CC.lastText = tr('Result') .. ': ' .. sep(CC.format(res))
                end
            end
        end
        if not CC.lastOk then return end
        CC.ok, CC.value, CC.text = true, CC.lastVal, CC.lastText
        if not listening and ctl.bindFire(binds.calc_copy) then CC.copy() end
    end

    imgui.OnFrame(
        function() return ui.open ~= nil and CC.ok and isSampAvailable() and sampIsChatInputActive() end,
        function(self)
            self.HideCursor = true
            gfx.galpha = 1
            local P, dl, ds = imgui.ImVec2, imgui.GetBackgroundDrawList(), imgui.GetIO().DisplaySize
            local x, y
            pcall(function()                              -- положение строки ввода чата
                local cc = getStructElement(sampGetInputInfoPtr(), 0x8, 4)
                x, y = getStructElement(cc, 0x8, 4), getStructElement(cc, 0xC, 4)
            end)
            if not x then x, y = 20, ds.y * 0.4 end
            imgui.PushFont(fonts.bold)
            local s1 = u8(CC.text)
            local w1, h1 = imgui.CalcTextSize(s1).x, imgui.GetTextLineHeight()
            imgui.PopFont()
            imgui.PushFont(fonts.small)
            local s2 = u8(tr('Copy') .. ': ' .. ctl.bindName(binds.calc_copy))
            local w2, h2 = imgui.CalcTextSize(s2).x, imgui.GetTextLineHeight()
            imgui.PopFont()
            local bw, bh = math.max(w1, w2) + 28, h1 + h2 + 22
            y = y + 34
            x = clamp(x, 0, math.max(0, ds.x - bw))
            y = clamp(y, 0, math.max(0, ds.y - bh))
            dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.85), 7)
            dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 7)
            dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main), 2)
            imgui.PushFont(fonts.bold)
            dl:AddText(P(x + 14, y + 8), C(pal.text), s1)
            imgui.PopFont()
            imgui.PushFont(fonts.small)
            dl:AddText(P(x + 14, y + 12 + h1), C(pal.dim), s2)
            imgui.PopFont()
        end
    )

    -- ---------- подсказки и переводы ----------
    local H = {
        ['Chat calculator'] = 'Calculates an expression typed in the chat input and shows the result under the input line.',
    }
    for k, v in pairs(H) do HINTS[k] = v end
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Chat'] = 'Чат', ['Chat calculator'] = 'Чат-калькулятор', ['Chat calculator settings'] = 'Настройки чат-калькулятора',
        ['Clear chat after copying'] = 'Очищать чат после копирования', ['Copy without spaces'] = 'Копировать без пробелов',
        ['Integer only'] = 'Только целое число', ['Copy key'] = 'Копирование', ['Copy'] = 'Копировать',
        ['Result'] = 'Результат', ['Result copied'] = 'Результат скопирован',
        [H['Chat calculator']] = 'Считает выражение, введённое в строку чата, и показывает результат под строкой ввода.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Смена времени и погоды (Основное -> Игра): выбранное значение ставится через эмуляцию RPC (94 - время,
--  152 - погода) и удерживается: сервер больше не может его менять (обработчики samp.events возвращают false).
--  При выключении возвращаются последние значения, присланные сервером. Механика взята из Climate.lua.
-- ----------------------------------------------------------------------------
do
    local CL = {}
    ctl.cl = CL
    CL.actual = {time = 12, weather = 1}
    pcall(function()
        if memory then
            CL.actual.time = memory.getint8(0xB70153)
            CL.actual.weather = memory.getint16(0xC81320)
        end
    end)
    CL.emul = false                                 -- true, пока мы сами эмулируем RPC (хуки его не блокируют)
    CL.applied = {time = nil, weather = nil}        -- что мы сейчас удерживаем (nil - ничего)

    function CL.emulate(rpc, value)
        CL.emul = true
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt8(bs, value)
        raknetEmulRpcReceiveBitStream(rpc, bs)
        raknetDeleteBitStream(bs)
        CL.emul = false
    end

    function CL.hour() return clamp(math.floor(F('main_time_val', 12)[0] + 0.5), 0, 23) end
    function CL.weatherId() return clamp(math.floor(F('main_weather_val', 1)[0] + 0.5), 0, 45) end

    -- в Vice City (Arizona) мир - интерьер 20, на остальных серверах - 0
    function CL.inWorld(interior)
        local ok, ip, port = pcall(sampGetCurrentServerAddress)
        if ok and ip and ('%s:%s'):format(ip, port) == '80.66.82.147:7777' then return interior == 20 end
        return interior == 0
    end

    function CL.on(kind) return B(kind == 'time' and 'main_time' or 'main_weather', false)[0] end

    -- каждый кадр: применить новое значение или вернуть серверное после выключения
    function CL.tick()
        if not isSampAvailable() then return end
        for _, kind in ipairs({'time', 'weather'}) do
            local want = nil
            if CL.on(kind) then want = (kind == 'time') and CL.hour() or CL.weatherId() end
            if want ~= CL.applied[kind] then
                local rpc = (kind == 'time') and 94 or 152
                CL.emulate(rpc, want or CL.actual[kind])
                CL.applied[kind] = want
            end
        end
    end

    if okEv and sampev then
        local oW, oPT, oWT, oI = sampev.onSetWeather, sampev.onSetPlayerTime, sampev.onSetWorldTime, sampev.onSetInterior
        sampev.onSetWeather = function(id, ...)
            if not CL.emul then
                CL.actual.weather = id
                if CL.on('weather') then return false end
            end
            if oW then return oW(id, ...) end
        end
        sampev.onSetPlayerTime = function(hour, min, ...)
            if not CL.emul then
                CL.actual.time = hour
                if CL.on('time') then return false end
            end
            if oPT then return oPT(hour, min, ...) end
        end
        sampev.onSetWorldTime = function(hour, ...)
            if not CL.emul then
                CL.actual.time = hour
                if CL.on('time') then return false end
            end
            if oWT then return oWT(hour, ...) end
        end
        sampev.onSetInterior = function(id, ...)
            local inWorld = CL.inWorld(id)
            if CL.on('time') then CL.emulate(94, inWorld and CL.hour() or CL.actual.time) end
            if CL.on('weather') then CL.emulate(152, inWorld and CL.weatherId() or CL.actual.weather) end
            if oI then return oI(id, ...) end
        end
    end

    -- ---------- переводы ----------
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Change time'] = 'Смена времени', ['Change weather'] = 'Смена погоды',
        ['Time change settings'] = 'Настройки смены времени', ['Weather change settings'] = 'Настройки смены погоды',
        ['Hour'] = 'Час', ['Weather ID'] = 'ID погоды',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Taxi Helper (Software -> Taxi Helper): автоматически выбирает ближайший заказ таксиста и принимает диалог.
--  Логика взята из TaxiHelper.lua (xMercy); библиотека arizona-events не нужна: CEF-пакеты Arizona (220)
--  читаются и отправляются напрямую через raknet. Входящий пакет: [220][17][server_id u32][len u16][enc u8][текст],
--  исходящий: [220][18][len u16][текст][server_id u32].
-- ----------------------------------------------------------------------------
do
    local TH = {}
    ctl.taxi = TH
    TH.stat = {chests = 0, bots = 0, money = 0, jobTime = 0}
    TH.orders, TH.pending, TH.carry, TH.bonus = {}, 0, false, 0
    TH.wasOn = false

    function TH.on() return B('taxi_enable', false)[0] end
    function TH.px() return F('taxi_px', 2.5) end                 -- положение панели, % экрана
    function TH.py() return F('taxi_py', 55.0) end
    TH.posEdit, TH.posT0 = false, 0

    function TH.startPosEdit()
        TH.posEdit, TH.posT0 = true, os.clock()
        ui.open[0] = false                                        -- меню скрывается, панель следует за мышью
    end

    function TH.finishPos(xPct, yPct)
        TH.px()[0] = clamp(math.floor(xPct * 10 + 0.5) / 10, 0, 100)
        TH.py()[0] = clamp(math.floor(yPct * 10 + 0.5) / 10, 0, 100)
        TH.posEdit = false
        ui.open[0] = true
        NotifyOk('Overlay position saved')
    end
    function TH.dist() return I('taxi_dist', 5000) end

    function TH.reset()
        TH.orders, TH.pending, TH.carry = {}, 0, false
    end

    function TH.clock()
        local s = math.max(0, os.time() - TH.stat.jobTime)
        return string.format('%02d:%02d:%02d', math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
    end

    -- каждый кадр: старт сессии при включении, сброс состояния при потере соединения
    function TH.tick()
        if TH.posEdit and os.clock() - TH.posT0 >= 0.3 then           -- ПКМ отменяет изменение положения
            if ui.open[0] then TH.posEdit = false
            elseif wasKeyPressed(0x02) then
                TH.posEdit = false
                ui.open[0] = true
                Notify('Position change cancelled')
            end
        end
        local on = TH.on()
        if on and not TH.wasOn then TH.stat.jobTime = os.time(); TH.reset() end
        TH.wasOn = on
        if on and sampGetGamestate and sampGetGamestate() ~= 3 then TH.reset() end
    end

    function TH.closest()
        local best
        for _, o in ipairs(TH.orders) do
            if not best or o.distance < best.distance then best = o end
        end
        return best
    end

    -- ---------- защита ----------
    -- Любая ошибка в обработчиках перехватывается (pcall) и не доходит до игры/MoonLoader. Если ошибки идут подряд
    -- (формат пакетов изменился или пришёл битый пакет), помощник сам отключается один раз вместо спама исключений.
    TH.errs, TH.broken = 0, false
    function TH.fail(err)
        TH.errs = TH.errs + 1
        if TH.errs >= 20 and not TH.broken then
            TH.broken = true
            B('taxi_enable', false)[0] = false
            NotifyErr('Taxi Helper stopped: too many packet errors')
            print('[COLLAPSE] Taxi Helper: ' .. tostring(err))
        end
    end

    -- отправка в CEF: пакет 220, под-тип 18 (текст + server_id)
    function TH.send(text)
        local bs = raknetNewBitStream()
        local ok, err = pcall(function()
            raknetBitStreamWriteInt8(bs, 220)
            raknetBitStreamWriteInt8(bs, 18)
            raknetBitStreamWriteInt16(bs, #text)
            raknetBitStreamWriteString(bs, text)
            raknetBitStreamWriteInt32(bs, 0)
            raknetSendBitStream(bs)
        end)
        raknetDeleteBitStream(bs)                        -- освобождаем в любом случае
        if not ok then TH.fail(err) end
        return ok
    end

    function TH.pickClosest()
        if TH.pending ~= 1 or TH.carry then return end
        lua_thread.create(function()
            local ok, err = pcall(function()
                wait(35)                                  -- ждём остальные заказы из этой пачки
                local best = TH.closest()
                TH.orders, TH.pending = {}, 0
                if not best or not TH.on() then return end
                if best.distance > TH.dist()[0] then
                    Notify('Order is too far: %d m (limit %d m)', best.distance, TH.dist()[0])
                elseif TH.send('pickOrderWorker|' .. best.id) then
                    Notify('Order picked: %d m', best.distance)
                end
            end)
            if not ok then
                TH.orders, TH.pending = {}, 0
                TH.fail(err)
            end
        end)
    end

    -- входящий CEF-пакет Arizona: ищем список заказов. Перед каждым чтением проверяем, что в пакете хватает данных
    function TH.onPacket(bs)
        if TH.broken or not TH.on() then return end
        local off = 0
        local ok, text = pcall(function()
            off = raknetBitStreamGetReadOffset and raknetBitStreamGetReadOffset(bs) or 0
            if raknetBitStreamGetNumberOfUnreadBits(bs) < 8 * 9 then return nil end     -- id + под-тип + server_id + длина + флаг
            raknetBitStreamIgnoreBits(bs, 8)                              -- id пакета
            if raknetBitStreamReadInt8(bs) ~= 17 then return nil end      -- не "display"
            raknetBitStreamReadInt32(bs)                                  -- server_id
            local len = raknetBitStreamReadInt16(bs)
            if len < 0 then len = len + 65536 end
            local enc = raknetBitStreamReadInt8(bs)
            local left = math.floor(raknetBitStreamGetNumberOfUnreadBits(bs) / 8)
            if len <= 0 or len > 8192 or left < 1 then return nil end
            if enc == 0 then
                if len > left then return nil end                         -- строка длиннее остатка пакета - не читаем
                return raknetBitStreamReadString(bs, len)
            end
            return raknetBitStreamDecodeString(bs, len + 1)
        end)
        pcall(function()                                                  -- вернуть позицию чтения игре
            if raknetBitStreamSetReadOffset then raknetBitStreamSetReadOffset(bs, off) else raknetBitStreamResetReadPointer(bs) end
        end)
        if not ok then TH.fail(text) return end
        if type(text) ~= 'string' then return end
        if not (text:find('event.arizonaDriver.initializeOrders', 1, true) and text:find('distance', 1, true)) then
            TH.errs = 0
            return
        end
        TH.errs = 0
        local id = tonumber(text:match('"id"%s*:%s*(%d+)'))
        local distance = tonumber(text:match('"distance"%s*:%s*(%d+)'))
        if id and distance and not TH.carry then
            TH.pending = TH.pending + 1
            TH.pickClosest()
            TH.orders[#TH.orders + 1] = {id = id, distance = distance}
        end
    end

    function TH.onMessage(color, text)
        if type(text) ~= 'string' or not TH.on() then return end
        if text:find('Такси') and text:find('Клиент оплатил') and color == -65281 then
            local money = text:match('Клиент оплатил:%D*(%d[%d%p]*)')
            money = money and tonumber((money:gsub('%D', '')))
            if money then TH.stat.money = TH.stat.money + money end
            TH.stat.bots = TH.stat.bots + 1
            TH.carry = false
            TH.stat.chests = TH.stat.chests + TH.bonus
        end
        if text:find('Заказ уже принят или отменён') and color == -10270721 then
            TH.reset()
        end
        if text:find('проц получить Монету Таксиста и') then
            TH.bonus = tonumber(text:match('%+(%d+){FFFFFF}%s+Ларцов')) or 0
        end
    end

    -- диалог автоприёма заказа: подтверждаем и скрываем
    function TH.onDialog(id)
        if id == 15324 and TH.on() then
            local ok = pcall(sampSendDialogResponse, id, 1, -1, '')
            if not ok then return false end
            TH.carry = true
            return true
        end
        return false
    end

    function onReceivePacket(packetId, bitStream)
        if (packetId == 32 or packetId == 33 or packetId == 37) and ctl.cm then pcall(ctl.cm.onDisconnect) end    -- отключение/кик/обрыв
        if packetId == 220 and ctl.taxi then pcall(ctl.taxi.onPacket, bitStream) end
        if packetId == 220 then pcall(ctl.cefIn, bitStream) end
        if (packetId == 29 or packetId == 31 or packetId == 32 or packetId == 33 or packetId == 34 or packetId == 37) and ctl.uc then pcall(ctl.uc.onPacket, packetId) end         -- автореконнект
        if (packetId == 32 or packetId == 33 or packetId == 34 or packetId == 36) and ctl.tg then pcall(ctl.tg.onPacket, packetId) end     -- Telegram: подключение / отключение
    end

    -- ---------- страница ----------
    local function LeftBody()
        if SRCH.collecting then Reg('Enable Taxi Helper', 'Checkbox') end
        local dim = not TH.on() and not SRCH.collecting
        local ga = gfx.galpha
        if dim then
            gfx.galpha = ga * 0.45
            imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, imgui.GetStyle().Alpha * 0.45)
        end
        Slider('Max distance to the client', TH.dist(), 1000, 10000, '%d m', true)
        Checkbox('Statistics on screen', B('taxi_stats', false))
        if Button('Edit statistics position', 34) then TH.startPosEdit() end
        if Button('Reset statistics', 34) then
            TH.stat.chests, TH.stat.bots, TH.stat.money = 0, 0, 0
            TH.stat.jobTime = os.time()
            Notify('Statistics reset')
        end
        if dim then
            imgui.PopStyleVar()
            gfx.galpha = ga
        end
    end

    local function RightBody()
        Text('When the helper is on, it takes the closest taxi order within the maximum distance and confirms the order dialog by itself.', pal.dim)
        if SRCH.collecting then return end
        imgui.Dummy(imgui.ImVec2(1, 6))
        InfoRow('Clients delivered', tostring(TH.stat.bots))
        InfoRow('Money earned', TH.stat.money .. '$')
        InfoRow('Chests received', tostring(TH.stat.chests))
        InfoRow('Helper time', TH.on() and TH.clock() or tr('Disabled'))
    end

    SOFT.draw.taxihelper = function()
        Panel('Taxi', 0, 0, LAY.COLW, LAY.CH, LeftBody, nil, nil, function()
            SOFT.pageHeader('taxi', LAY.COLW, 'Enable Taxi Helper', B('taxi_enable', false))
        end, 30)
        Panel('Statistics', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, RightBody)
    end

    -- ---------- статистика на экране ----------
    -- editing: панель следует за курсором, ЛКМ сохраняет положение, ПКМ отменяет
    function TH.drawStats(editing)
        local P, dl, io = imgui.ImVec2, imgui.GetBackgroundDrawList(), imgui.GetIO()
        local ds = io.DisplaySize
        local rows = {
            {'USER', tr('Clients delivered') .. ': ' .. TH.stat.bots},
            {'MONEY_BILL_WAVE', tr('Money earned') .. ': ' .. TH.stat.money .. '$'},
            {'BOXES_STACKED', tr('Chests received') .. ': ' .. TH.stat.chests},
            {'USER_CLOCK', tr('Helper time') .. ': ' .. (TH.on() and TH.clock() or '00:00:00')},
        }
        local lh, tw = imgui.GetTextLineHeight(), 0
        for _, r in ipairs(rows) do r[3] = u8(r[2]); tw = math.max(tw, imgui.CalcTextSize(r[3]).x) end
        local pad, gap = 10, 5
        local bw, bh = tw + pad * 2 + 26, #rows * lh + (#rows - 1) * gap + pad * 2
        local x, y
        if editing then
            x, y = io.MousePos.x, io.MousePos.y
        else
            x, y = TH.px()[0] / 100 * ds.x, TH.py()[0] / 100 * ds.y
        end
        x = clamp(x, 0, math.max(0, ds.x - bw))
        y = clamp(y, 0, math.max(0, ds.y - bh))
        dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.85), 7)
        dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 7)
        dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main), 2)
        if editing then
            dl:AddRect(P(x - 1, y - 1), P(x + bw + 1, y + bh + 1), C(THEME.main), 8)
            dl:AddRect(P(x - 2, y - 2), P(x + bw + 2, y + bh + 2), C(THEME.main, 0.5), 9)
        end
        for i, r in ipairs(rows) do
            local ry = y + pad + (i - 1) * (lh + gap)
            FNT.drawIcon(dl, r[1], 12, x + pad + 9, ry + lh / 2, C(THEME.main))
            dl:AddText(P(x + pad + 24, ry), C(pal.text), r[3])
        end
        return x, y
    end

    imgui.OnFrame(
        function()
            if ui.open == nil then return false end
            if TH.posEdit then return true end
            return B('taxi_stats', false)[0] and TH.on() and isSampAvailable() and not ctl.main.overlayBlocked()
        end,
        function(self)
            local editing = TH.posEdit
            self.HideCursor = not (ui.open[0] or editing)
            gfx.galpha = 1
            imgui.PushFont(fonts.small)
            local x, y = TH.drawStats(editing)
            imgui.PopFont()
            if editing then                                          -- подсказка сверху экрана и сохранение по ЛКМ
                local P, dl, ds = imgui.ImVec2, imgui.GetBackgroundDrawList(), imgui.GetIO().DisplaySize
                imgui.PushFont(fonts.bold)
                local lines = {u8(tr('Click LMB to place the statistics')), u8(tr('RMB - cancel')),
                    string.format('X %.1f%%   Y %.1f%%', x / ds.x * 100, y / ds.y * 100)}
                local lw, lth = 0, imgui.GetTextLineHeight()
                for _, s in ipairs(lines) do lw = math.max(lw, imgui.CalcTextSize(s).x) end
                local bx2, by2 = (ds.x - lw - 36) / 2, 24
                local bh2 = lth * #lines + 8 * (#lines - 1) + 24
                dl:AddRectFilled(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.bg, 0.88), 8)
                dl:AddRect(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.border), 8)
                dl:AddRectFilled(P(bx2 + 8, by2 + 8), P(bx2 + 11, by2 + bh2 - 8), C(THEME.main), 2)
                for i, s in ipairs(lines) do
                    local col = (i == 1) and pal.text or pal.dim
                    dl:AddText(P(bx2 + 18 + (lw - imgui.CalcTextSize(s).x) / 2, by2 + 12 + (i - 1) * (lth + 8)), C(col), s)
                end
                imgui.PopFont()
                if ui.alpha < 0.02 and os.clock() - TH.posT0 > 0.3 and imgui.IsMouseClicked(0) then
                    TH.finishPos(x / ds.x * 100, y / ds.y * 100)
                end
            end
        end
    )

    -- ---------- переводы ----------
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Taxi Helper'] = 'Taxi Helper', ['Auto order pick'] = 'Автовыбор заказов', ['for the taxi job'] = 'для работы таксиста',
        ['Enable Taxi Helper'] = 'Включить Taxi Helper', ['Max distance to the client'] = 'Макс. дистанция до клиента',
        ['Statistics on screen'] = 'Статистика на экране', ['Edit statistics position'] = 'Изменить положение статистики',
        ['Click LMB to place the statistics'] = 'Нажмите ЛКМ, чтобы разместить статистику', ['Reset statistics'] = 'Сбросить статистику', ['Statistics reset'] = 'Статистика сброшена',
        ['Statistics'] = 'Статистика', ['Clients delivered'] = 'Клиентов отвезено', ['Money earned'] = 'Денег заработано',
        ['Chests received'] = 'Получено ларцов', ['Helper time'] = 'Время помощника', ['Disabled'] = 'Отключён',
        ['When the helper is on, it takes the closest taxi order within the maximum distance and confirms the order dialog by itself.'] =
            'Когда помощник включён, он сам берёт ближайший заказ в пределах максимальной дистанции и подтверждает диалог заказа.',
        ['Order picked: %d m'] = 'Заказ принят: %d м', ['Order is too far: %d m (limit %d m)'] = 'Заказ слишком далеко: %d м (лимит %d м)',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Fly Car (Software -> Fly Car): полёт на транспорте. Перенос FlyCarV2.lua без изменений в логике:
--  клавиша включает полёт в машине, W - разгон, S - торможение, ПРОБЕЛ - быстрая остановка, руление вращает машину.
-- ----------------------------------------------------------------------------
do
    local FA = {}
    ctl.fly = FA
    FA.on, FA.speed = false, 0
    binds.flycar_key = binds.flycar_key or {key = 0x33, mod = 0}          -- по умолчанию клавиша 3, как в оригинале

    local function keyFree() return not sampIsChatInputActive() and not sampIsDialogActive() end

    function FA.stop()
        if FA.on then
            pcall(function()
                if isCharInAnyCar(PLAYER_PED) then setCarProofs(getCarCharIsUsing(PLAYER_PED), false, false, false, false, false) end
            end)
            Notify('Fly Car disabled')
        end
        FA.on, FA.speed = false, 0
    end

    -- каждый кадр из основного цикла
    function FA.tick()
        if not B('flycar_enable', false)[0] then FA.stop() return end
        if not isSampAvailable() or (sampGetGamestate and sampGetGamestate() ~= 3) or not ctl.alive() then FA.stop() return end      -- вышли с сервера - полёт выключается
        local inCar = isCharInAnyCar(PLAYER_PED)
        if inCar and not listening and not ui.open[0] and keyFree() and ctl.bindFire(binds.flycar_key) then
            FA.speed = 0
            setCarForwardSpeed(getCarCharIsUsing(PLAYER_PED), 0)
            if FA.on then FA.stop() else FA.on = true; Notify('Fly Car enabled') end
        end
        if not FA.on then return end
        if not inCar then FA.stop() return end
        local veh = getCarCharIsUsing(PLAYER_PED)
        local speed = getCarSpeed(veh)
        setCarHeavy(veh, false)
        setCarProofs(veh, true, true, true, true, true)
        local sx, sy = getPositionOfAnalogueSticks(0)
        setCarRotationVelocity(veh, sy / 64.0, 0.0, sx / -64.0)
        if isKeyDown(0x57) and keyFree() then                                   -- W
            if speed <= 230.0 then FA.speed = FA.speed + 0.5 end
        elseif isKeyDown(0x53) and keyFree() then                               -- S
            if FA.speed >= 0.0 then FA.speed = FA.speed - 0.7 else FA.speed = 0.0 end
        end
        if isKeyDown(0x20) and keyFree() then                                   -- ПРОБЕЛ: быстрая остановка
            FA.speed = 0
            setCarRotationVelocity(veh, 0.0, 0.0, 0.0)
            setCarRoll(veh, 0.0)
        end
        setCarForwardSpeed(veh, FA.speed)
        printStringNow('~R~SPACE ~G~= ~R~FAST STOP', 50)
    end

    HINTS['Fly Car'] = 'Press the flight key while in a vehicle to start or stop flying. W - accelerate, S - brake, SPACE - fast stop. Steering rotates the vehicle.'

    -- ---------- переводы ----------
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Fly Car'] = 'Fly Car', ['Flying vehicle'] = 'Полёт на транспорте', ['on a key'] = 'по клавише',
        ['Fly Car settings'] = 'Настройки Fly Car', ['Flight key'] = 'Клавиша полёта',
        ['Flying'] = 'Полёт', ['Off'] = 'Выключен', ['Fly Car enabled'] = 'Fly Car включён', ['Fly Car disabled'] = 'Fly Car выключен',
        ['Press the flight key while in a vehicle to start or stop flying. W - accelerate, S - brake, SPACE - fast stop. Steering rotates the vehicle.'] =
            'Нажмите клавишу полёта в транспорте, чтобы начать или закончить полёт. W - разгон, S - торможение, ПРОБЕЛ - быстрая остановка. Руление вращает транспорт.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Порт функций UltraTool (xMercy): AutoBunnyHop, сбив на клавишу, бесконечный бег, чат на T, Auto run and ride keys, NoDialog,
--  NoDialogRestore, NoAnim, CamHack, точки в числах, анти-тряска камеры, анти-ковш, отключение прогрузки зоны стрима,
--  NoFallAnimation, AntiStun, анти-разброс, стрельба без перезарядки, ClickWarp, AntiMask, Wallhack, удаление шлагбаумов,
--  FastWalk, FastAnim, RapidFire, AirBrake. Включаются в Основное -> Разное / Персонаж / Для авто; клавиши сбива и
--  Wallhack настраиваются в шестерёнке пункта. Подмена полей синхронизации (moveSpeed у AirBrake) не переносилась.
-- ----------------------------------------------------------------------------
do
    local UT = {}
    ctl.ut = UT
    binds.ut_sbivx = binds.ut_sbivx or {key = 0x58, mod = 0}      -- X
    binds.ut_wh = binds.ut_wh or {key = 0x78, mod = 0}            -- F9
    binds.ut_air = binds.ut_air or {key = 0xA1, mod = 0}          -- правый Shift
    binds.ut_bike_key = binds.ut_bike_key or {key = 0xA0, mod = 0}   -- левый Shift: езда на байке/велосипеде
    binds.ut_run_key = binds.ut_run_key or {key = 0x31, mod = 0}     -- 1: бег и плавание
    binds.ut_cam_start = binds.ut_cam_start or {key = 0x31, mod = 0x43}      -- C + 1
    binds.ut_cam_stop = binds.ut_cam_stop or {key = 0x32, mod = 0x43}    -- C + 2
    binds.ut_cam_up = binds.ut_cam_up or {key = 187, mod = 0}          -- +
    binds.ut_cam_dn = binds.ut_cam_dn or {key = 189, mod = 0}          -- -
    UT.fps, UT.last = 60, os.clock()
    UT.dialogs, UT.noCol, UT.noColN = {}, {}, 0
    UT.objT, UT.cwCursor = 0, false
    UT.air = {on = false, x = 0, y = 0, z = 0}
    UT.cam = {mode = 0, speed = 0.2}
    pcall(function() if memory then UT.spreadDef = memory.getfloat(9252452) end end)

    local function on(k) return B(k, false)[0] end
    local function keyOk() return not sampIsChatInputActive() and not sampIsDialogActive() and not isSampfuncsConsoleActive() and not sampIsScoreboardOpen() end
    UT.keyOk = keyOk
    -- Run while hungry (arizona-hungry-run.lua): указатели на камеру и данные игрока в памяти игры
    local lookAtPlayer = ffi.cast('uint8_t*', 0xB6F028 + 0x2B)
    local playerPedPtr = ffi.cast('uintptr_t*', 0xB6F5F0)
    function UT.noAnim() return on('ut_noanim') end

    local FASTWALK = {'SPRINT_CIVI', 'SPRINT_PANIC', 'SWAT_RUN', 'WOMAN_RUNPANIC', 'FATSPRINT'}
    local FASTANIM = {
        'abseil', 'arrestgun', 'atm', 'bike_elbowl', 'bike_elbowr', 'bike_fallr', 'bike_fall_off', 'bike_pickupl',
        'bike_pickupr', 'bike_pullupl', 'bike_pullupr', 'bomber', 'car_alignhi_lhs', 'car_alignhi_rhs', 'car_align_lhs', 'car_align_rhs',
        'car_closedoorl_lhs', 'car_closedoorl_rhs', 'car_closedoor_lhs', 'car_closedoor_rhs', 'car_close_lhs', 'car_close_rhs', 'car_crawloutrhs', 'car_dead_lhs',
        'car_dead_rhs', 'car_doorlocked_lhs', 'car_doorlocked_rhs', 'car_fallout_lhs', 'car_fallout_rhs', 'car_getinl_lhs', 'car_getinl_rhs', 'car_getin_lhs',
        'car_getin_rhs', 'car_getoutl_lhs', 'car_getoutl_rhs', 'car_getout_lhs', 'car_getout_rhs', 'car_hookertalk', 'car_jackedlhs', 'car_jackedrhs',
        'car_jumpin_lhs', 'car_lb', 'car_lb_pro', 'car_lb_weak', 'car_ljackedlhs', 'car_ljackedrhs', 'car_lshuffle_rhs', 'car_lsit',
        'car_open_lhs', 'car_open_rhs', 'car_pulloutl_lhs', 'car_pulloutl_rhs', 'car_pullout_lhs', 'car_pullout_rhs', 'car_qjacked', 'car_rolldoor',
        'car_rolldoorlo', 'car_rollout_lhs', 'car_rollout_rhs', 'car_shuffle_rhs', 'car_sit', 'car_sitp', 'car_sitplo', 'car_sit_pro',
        'car_sit_weak', 'car_tune_radio', 'climb_idle', 'climb_jump', 'climb_jump2fall', 'climb_jump_b', 'climb_pull', 'climb_stand',
        'climb_stand_finish', 'cower', 'crouch_roll_l', 'crouch_roll_r', 'dam_arml_frmbk', 'dam_arml_frmft', 'dam_arml_frmlt', 'dam_armr_frmbk',
        'dam_armr_frmft', 'dam_armr_frmrt', 'dam_legl_frmbk', 'dam_legl_frmft', 'dam_legl_frmlt', 'dam_legr_frmbk', 'dam_legr_frmft', 'dam_legr_frmrt',
        'dam_stomach_frmbk', 'dam_stomach_frmft', 'dam_stomach_frmlt', 'dam_stomach_frmrt', 'door_lhinge_o', 'door_rhinge_o', 'drivebyl_l', 'drivebyl_r',
        'driveby_l', 'driveby_r', 'drive_boat', 'drive_boat_back', 'drive_boat_l', 'drive_boat_r', 'drive_l', 'drive_lo_l',
        'drive_lo_r', 'drive_l_pro', 'drive_l_pro_slow', 'drive_l_slow', 'drive_l_weak', 'drive_l_weak_slow', 'drive_r', 'drive_r_pro',
        'drive_r_pro_slow', 'drive_r_slow', 'drive_r_weak', 'drive_r_weak_slow', 'drive_truck', 'drive_truck_back', 'drive_truck_l', 'drive_truck_r',
        'drown', 'duck_cower', 'endchat_01', 'endchat_02', 'endchat_03', 'ev_dive', 'ev_step', 'facanger',
        'facgum', 'facsurp', 'facsurpm', 'factalk', 'facurios', 'fall_back', 'fall_collapse', 'fall_fall',
        'fall_front', 'fall_glide', 'fall_land', 'fall_skydive', 'fight2idle', 'fighta_1', 'fighta_2', 'fighta_3',
        'fighta_block', 'fighta_g', 'fighta_m', 'fightidle', 'fightshb', 'fightshf', 'fightsh_bwd', 'fightsh_fwd',
        'fightsh_left', 'fightsh_right', 'flee_lkaround_01', 'floor_hit', 'floor_hit_f', 'fucku', 'gang_gunstand', 'gas_cwr',
        'getup', 'getup_front', 'gum_eat', 'guncrouchbwd', 'guncrouchfwd', 'gunmove_bwd', 'gunmove_fwd', 'gunmove_l',
        'gunmove_r', 'gun_2_idle', 'gun_butt', 'gun_butt_crouch', 'gun_stand', 'handscower', 'handsup', 'hita_1',
        'hita_2', 'hita_3', 'hit_back', 'hit_behind', 'hit_front', 'hit_gun_butt', 'hit_l', 'hit_r',
        'hit_walk', 'hit_wall', 'idlestance_fat', 'idlestance_old', 'idle_armed', 'idle_chat', 'idle_csaw', 'idle_gang1',
        'idle_hbhb', 'idle_rocket', 'idle_stance', 'idle_taxi', 'idle_tired', 'jog_femalea', 'jog_malea',
        'jump_glide', 'jump_land', 'jump_launch', 'jump_launch_r', 'kart_drive', 'kart_l', 'kart_lb', 'kart_r',
        'kd_left', 'kd_right', 'ko_shot_face', 'ko_shot_front', 'ko_shot_stom', 'ko_skid_back', 'ko_skid_front', 'ko_spin_l',
        'ko_spin_r', 'pass_smoke_in_car', 'phone_in', 'phone_out', 'phone_talk', 'player_sneak', 'player_sneak_walkstart', 'roadcross',
        'roadcross_female', 'roadcross_gang', 'roadcross_old', 'run_1armed', 'run_armed', 'run_civi', 'run_csaw', 'run_fat',
        'run_fatold', 'run_gang1', 'run_left', 'run_old', 'run_player', 'run_right', 'run_rocket', 'run_stop',
        'run_stopr', 'run_wuzi', 'seat_down', 'seat_idle', 'seat_up', 'shot_leftp', 'shot_partial', 'shot_partial_b',
        'shot_rightp', 'shove_partial', 'smoke_in_car', 'sprint_civi', 'sprint_panic', 'sprint_wuzi', 'swat_run', 'swim_tread',
        'tap_hand', 'tap_handp', 'turn_180', 'turn_l', 'turn_r', 'walk_armed', 'walk_civi', 'walk_csaw',
        'walk_doorpartial', 'walk_drunk', 'walk_fat', 'walk_fatold', 'walk_gang1', 'walk_gang2', 'walk_old', 'walk_player',
        'walk_rocket', 'walk_shuffle', 'walk_start', 'walk_start_armed', 'walk_start_csaw', 'walk_start_rocket', 'walk_wuzi', 'weapon_crouch',
        'woman_idlestance', 'woman_run', 'woman_runbusy', 'woman_runfatold', 'woman_runpanic', 'woman_runsexy', 'woman_walkbusy', 'woman_walkfatold',
        'woman_walknorm', 'woman_walkold', 'woman_walkpro', 'woman_walksexy', 'woman_walkshop', 'xpressscratch'
    }
    local RAPID = {'PYTHON_CROUCHFIRE', 'PYTHON_FIRE', 'PYTHON_FIRE_POOR', 'PYTHON_CROCUCHRELOAD', 'RIFLE_CROUCHFIRE', 'RIFLE_CROUCHLOAD',
        'RIFLE_FIRE', 'RIFLE_FIRE_POOR', 'RIFLE_LOAD', 'SHOTGUN_CROUCHFIRE', 'SHOTGUN_FIRE', 'SHOTGUN_FIRE_POOR', 'SILENCED_CROUCH_RELOAD',
        'SILENCED_CROUCH_FIRE', 'SILENCED_FIRE', 'SILENCED_RELOAD', 'TEC_crouchfire', 'TEC_crouchreload', 'TEC_fire', 'TEC_reload',
        'UZI_crouchfire', 'UZI_crouchreload', 'UZI_fire', 'UZI_fire_poor', 'UZI_reload', 'idle_rocket', 'Rocket_Fire', 'run_rocket',
        'walk_rocket', 'WALK_start_rocket', 'WEAPON_sniper'}
    local STUN = {'DAM_armL_frmBK', 'DAM_armL_frmFT', 'DAM_armL_frmLT', 'DAM_armR_frmBK', 'DAM_armR_frmFT', 'DAM_armR_frmRT',
        'DAM_LegL_frmBK', 'DAM_LegL_frmFT', 'DAM_LegL_frmLT', 'DAM_LegR_frmBK', 'DAM_LegR_frmFT', 'DAM_LegR_frmRT',
        'DAM_stomach_frmBK', 'DAM_stomach_frmFT', 'DAM_stomach_frmLT', 'DAM_stomach_frmRT'}

    local function setSpeeds(list, v) for _, n in ipairs(list) do setCharAnimSpeed(PLAYER_PED, n, v) end end

    -- ---------- точки в числах: $1234567 -> $1.234.567 (и VC) ----------
    local function dots(n)
        if #n <= 3 then return n end
        local r = n:reverse():gsub('(%d%d%d)', '%1.'):reverse()
        return (r:gsub('^%.', ''))
    end
    function UT.separator(text)
        if type(text) ~= 'string' then return text end
        text = text:gsub('%$(%d+)', function(n) return '$' .. dots(n) end)
        text = text:gsub('(%d+)%$', function(n) return dots(n) .. '$' end)
        text = text:gsub('VC(%d+)', function(n) return 'VC' .. dots(n) end)
        text = text:gsub('(%d+)VC', function(n) return dots(n) .. 'VC' end)
        return text
    end

    -- ---------- хуки событий ----------
    function UT.onMessage(text)
        if on('ut_dots') then return UT.separator(text) end
    end

    function UT.onDialogResponse(id, list, input) UT.dialogs[id] = {list, input} end

    -- false - скрыть диалог, таблица {заголовок, текст} - заменить
    function UT.onDialog(id, title, text)
        if on('ut_nodialog') then return false end
        if on('ut_nodialogrestore') and UT.dialogs[id] then
            local saved = UT.dialogs[id]
            lua_thread.create(function()
                repeat wait(0) until sampIsDialogActive() and sampGetCurrentDialogId() == id
                sampSetCurrentDialogListItem(saved[1] or 0)
                sampSetCurrentDialogEditboxText(saved[2] or '')
            end)
        end
        if on('ut_dots') then return {UT.separator(title), UT.separator(text)} end
    end

    function UT.onPlayerSync(data)
        if on('ut_bhop') and data.keysData == 40 then data.keysData = 32 end
    end

    local function explode(c) return bit.band(bit.rshift(c, 24), 255), bit.band(bit.rshift(c, 16), 255), bit.band(bit.rshift(c, 8), 255), bit.band(c, 255) end
    local function join(r, g, b, a) return bit.bor(bit.bor(bit.bor(a, bit.lshift(b, 8)), bit.lshift(g, 16)), bit.lshift(r, 24)) end

    if okEv and sampev then
        local function chain(name, fn)
            local old = sampev[name]
            sampev[name] = function(...)
                local ok, r = pcall(fn, ...)
                if ok and r ~= nil then return r end
                if old then return old(...) end
            end
        end
        chain('onSetMapIcon', function() if on('ut_offstream') then return false end end)
        chain('onVehicleStreamIn', function() if on('ut_offstream') then return false end end)
        chain('onCreateObject', function() if on('ut_offstream') then return false end end)
        chain('onCreateActor', function() if on('ut_offstream') then return false end end)
        chain('onPlayerStreamIn', function(playerId, team, model, position, rotation, color, fightingStyle)
            if on('ut_offstream') then return false end
            if on('ut_antimask') then                          -- игроки в маске (прозрачный ник) снова видны на радаре
                local r, g, b, a = explode(color)
                if a >= 0 and a <= 4 then return {playerId, team, model, position, rotation, join(r, g, b, 170), fightingStyle} end
            end
        end)
        chain('onSetPlayerColor', function(playerId, color)
            if on('ut_antimask') then
                local r, g, b, a = explode(color)
                if a >= 0 and a <= 4 then
                    local bs = raknetNewBitStream()
                    raknetBitStreamWriteInt16(bs, playerId)
                    raknetBitStreamWriteInt32(bs, join(r, g, b, 170))
                    raknetEmulRpcReceiveBitStream(72, bs)
                    raknetDeleteBitStream(bs)
                    return false
                end
            end
        end)
        chain('onSetObjectMaterialText', function(id, data)    -- ценники машин на табличках
            if not on('ut_dots') then return nil end
            local object = sampGetObjectHandleBySampId(id)
            if object and doesObjectExist(object) and getObjectModel(object) == 18663 then
                local vehicle, color, price = string.match(data.text, '([^\n]+)\n({%x+})%$(%d+)')
                if vehicle and color and price then
                    data.text = string.format('%s\n%s$%s\n\n\n\n', vehicle, color, dots(price))
                    return {id, data}
                end
            end
        end)
    end

    -- ---------- Wallhack: ники игроков сквозь стены ----------
    function UT.nameTag(state)
        if not memory then return end
        local p = sampGetServerSettingsPtr()
        if state and not UT.nameTagOn then
            UT.ntDist, UT.ntWalls, UT.ntShow = memory.getfloat(p + 39), memory.getint8(p + 47), memory.getint8(p + 56)
            memory.setfloat(p + 39, 1488.0)
            memory.setint8(p + 47, 0)
            memory.setint8(p + 56, 1)
            UT.nameTagOn = true
        elseif not state and UT.nameTagOn then
            memory.setfloat(p + 39, UT.ntDist)
            memory.setint8(p + 47, UT.ntWalls)
            memory.setint8(p + 56, UT.ntShow)
            UT.nameTagOn = false
        end
    end

    -- ---------- AirBrake ----------
    function UT.airStep(step)
        local A = UT.air
        local inCar = isCharInAnyCar(PLAYER_PED)
        local car = inCar and storeCarCharIsInNoSave(PLAYER_PED) or nil
        local heading = inCar and getCarHeading(car) or getCharHeading(PLAYER_PED)
        local cX, cY = getActiveCameraCoordinates()
        local pX, pY = getActiveCameraPointAt()
        local hv = getHeadingFromVector2d(pX - cX, pY - cY)
        local diff = inCar and 0.79 or 0
        if inCar then
            setCharCoordinates(PLAYER_PED, A.x, A.y, A.z - diff)
        else
            local ped = getCharPointer(PLAYER_PED)
            local mp = readMemory(ped + 0x14, 4, false)
            if mp ~= 0 then
                writeMemory(mp + 0x30, 4, representFloatAsInt(A.x), false)
                writeMemory(mp + 0x34, 4, representFloatAsInt(A.y), false)
                writeMemory(mp + 0x38, 4, representFloatAsInt(A.z - diff), false)
            end
            memory.setuint8(ped + 0x46C, 3, true)
            setCharVelocity(PLAYER_PED, 0, 0, 0)
        end
        if sampIsChatInputActive() then return end
        if isKeyDown(0x57) then                                                  -- W: вперёд по взгляду камеры
            A.x = A.x + step * math.sin(-math.rad(hv))
            A.y = A.y + step * math.cos(-math.rad(hv))
            if inCar then setCarHeading(car, hv) else setCharHeading(PLAYER_PED, hv) end
        elseif isKeyDown(0x53) then                                              -- S
            A.x = A.x - step * math.sin(-math.rad(heading))
            A.y = A.y - step * math.cos(-math.rad(heading))
        end
        if isKeyDown(0x41) then                                                  -- A
            A.x = A.x - step * math.sin(-math.rad(heading - 90))
            A.y = A.y - step * math.cos(-math.rad(heading - 90))
        elseif isKeyDown(0x44) then                                              -- D
            A.x = A.x - step * math.sin(-math.rad(heading + 90))
            A.y = A.y - step * math.cos(-math.rad(heading + 90))
        end
        if isKeyDown(0x26) or isKeyDown(0x20) then 
            A.z = A.z + step / 2 
            pZspeed = 1 
        elseif pZspeed == 1 then 
            pZspeed = 0
        end      -- стрелка вверх / пробел
        if (isKeyDown(0x28) or isKeyDown(0xA0)) and A.z > -95 then 
            A.z = A.z - step / 2 
            pZspeed = 2 
        elseif pZspeed == 2 then 
            pZspeed = 0
        end   -- стрелка вниз / левый Shift
    end

    -- ---------- основной покадровый цикл ----------
    function UT.tick()
        local now = os.clock()
        local dt = now - UT.last
        UT.last = now
        if dt > 0 then UT.fps = UT.fps * 0.9 + (1 / dt) * 0.1 end
        if not isSampAvailable() then return end
        local ped = PLAYER_PED
        -- кик, обрыв или выход с сервера: AirBrake выключается и до повторного входа не включается
        local connected = not sampGetGamestate or sampGetGamestate() == 3
        local alive = ctl.alive()                                  -- смерть или ещё не заспавнены - то же, что отключение
        if (not connected or not alive) and UT.air.on then
            UT.air.on = false
            Notify('AirBrake disabled')
        end

        if on('ut_infrun') then                                                  -- бесконечный бег
            setPlayerNeverGetsTired(PLAYER_HANDLE, true)
            UT.tired = true
        elseif UT.tired then
            setPlayerNeverGetsTired(PLAYER_HANDLE, false)
            UT.tired = false
        end

        -- Run while hungry: при голоде запас спринта падает до нуля; пока зажат спринт, держим его не ниже 1
        if on('ut_hungryrun') and lookAtPlayer[0] == 1 and not isCharSittingInAnyCar(ped) and isButtonPressed(PLAYER_HANDLE, 16) then
            local pedAddr = playerPedPtr[0]
            if pedAddr ~= 0 then
                local data = ffi.cast('uintptr_t*', pedAddr + 0x480)
                if data[0] ~= 0 then
                    local energy = ffi.cast('float*', data[0] + 0x1C)
                    if energy[0] < 1 then energy[0] = 1 end
                end
            end
        end

        local free = not ui.open[0] and not listening
        if free and on('ut_sbivx') and ctl.bindFire(binds.ut_sbivx) and not sampIsCursorActive() and not isCharInAnyCar(ped) then
            clearCharTasksImmediately(ped)                                       -- сбив анимации и снятие фриза
            setPlayerControl(PLAYER_HANDLE, 1)
            freezeCharPosition(ped, false)
        end
        if free and on('ut_chatT') and wasKeyPressed(0x54) and keyOk() then sampSetChatInputEnabled(true) end

        if on('ut_antilomka') and (isCharPlayingAnim(ped, 'CRCKIDLE4') or isCharPlayingAnim(ped, 'CRCKIDLE2') or isCharPlayingAnim(ped, 'CRCKDETH2')) then
            clearCharTasksImmediately(ped)
        end
        if on('ut_nofall') and (isCharPlayingAnim(ped, 'KO_SKID_BACK') or isCharPlayingAnim(ped, 'FALL_COLLAPSE')) then
            clearCharTasksImmediately(ped)
        end
        if on('ut_antistun') and not isCharDead(ped) then
            for _, a in ipairs(STUN) do
                if isCharPlayingAnim(ped, a) then setCharAnimSpeed(ped, a, 999) end
            end
        end

        -- скорость анимаций: при включении ставим значение, при выключении возвращаем 1.0
        if on('ut_fastwalk') then setSpeeds(FASTWALK, F('ut_fw_val', 1.0)[0]); UT.fw = true
        elseif UT.fw then setSpeeds(FASTWALK, 1.0); UT.fw = false end
        if on('ut_fastanim') then setSpeeds(FASTANIM, F('ut_fa_val', 1.0)[0]); UT.fa = true
        elseif UT.fa then setSpeeds(FASTANIM, 1.0); UT.fa = false end
        if on('ut_rapidfire') then setSpeeds(RAPID, F('ut_rf_val', 1.0)[0]); UT.rf = true
        elseif UT.rf then setSpeeds(RAPID, 1.0); UT.rf = false end

        -- анти-разброс (запись в память только при смене)
        local spread = on('ut_nospread')
        if spread ~= (UT.spread or false) and memory then
            if spread then memory.setfloat(9252452, 0, true)
            elseif UT.spreadDef then memory.setfloat(9252452, UT.spreadDef, true) end
            UT.spread = spread
        end

        if on('ut_noreload') and now >= (UT.nrAt or 0) then
            UT.nrAt = now + 0.05                                                 -- не чаще 20 раз в секунду                                                -- стрельба без перезарядки
            local weap = getCurrentCharWeapon(ped)
            if weap and weap > 0 then
                local bs = raknetNewBitStream()
                raknetBitStreamWriteInt32(bs, weap)
                raknetBitStreamWriteInt32(bs, 0)
                raknetEmulRpcReceiveBitStream(22, bs)
                raknetDeleteBitStream(bs)
            end
        end

        if now - UT.objT > 0.5 then                                              -- объекты: анти-ковш и шлагбаумы
            UT.objT = now
            local antiBucket, barrier = on('ut_antibucket'), on('ut_barrier')
            if antiBucket or barrier then
                for _, o in ipairs(getAllObjects()) do
                    if doesObjectExist(o) then
                        if antiBucket and isObjectAttached(o) and not UT.noCol[o] then
                            setObjectCollision(o, false)
                            UT.noCol[o] = true
                            UT.noColN = UT.noColN + 1
                        end
                        if barrier and sampGetObjectSampIdByHandle(o) ~= -1 then
                            local m = getObjectModel(o)
                            if m == 968 or m == 966 or m == 11419 then setObjectCollision(o, false) end
                        end
                    end
                end
                if UT.noColN > 5000 then UT.noCol, UT.noColN = {}, 0 end
            end
        end

        -- AirBrake: включение правым Shift
        local A = UT.air
        if on('ut_airbrake') then
            if free and connected and alive and ctl.bindFire(binds.ut_air) and keyOk() then
                A.on = not A.on
                Notify(A.on and 'AirBrake enabled' or 'AirBrake disabled')
                A.x, A.y, A.z = getCharCoordinates(ped)
            end
            if A.on then
                local k = F('ut_ab_val', 0.2)[0]
                UT.airStep(k * (UT.fps > 100 and 100 / UT.fps or 1))
            end
        elseif A.on then
            A.on = false
        end

        -- Wallhack: включается/выключается клавишей (по умолчанию F9)
        if on('ut_wallhack') then
            if free and ctl.bindFire(binds.ut_wh) then
                UT.nameTag(not UT.nameTagOn)
                Notify(UT.nameTagOn and 'Wallhack enabled' or 'Wallhack disabled')
            end
        elseif UT.nameTagOn then
            UT.nameTag(false)
        end
    end

    -- ---------- Auto run and ride keys: поток (нужны wait) ----------
    local isBike = ffi.cast('bool (__cdecl *)(int)', 0x4C5B60)
    local isBmx = ffi.cast('bool (__cdecl *)(int)', 0x4C5C20)
    function UT.bikeStep()
        if isCharOnAnyBike(PLAYER_PED) and UT.down(binds.ut_bike_key) then
            local model = getCarModel(storeCarCharIsInNoSave(PLAYER_PED))
            local key = isBike(model) and 1 or (isBmx(model) and 16)
            if key then
                local v = key == 1 and -256 or 256
                setGameKeyState(key, v)
                wait(100)
                setGameKeyState(key, v)
            end
        end
        if (isCharOnFoot(PLAYER_PED) or isCharInWater(PLAYER_PED)) and UT.down(binds.ut_run_key) then
            setGameKeyState(16, 256)
            wait(10)
            setGameKeyState(16, 0)
        end
    end
    lua_thread.create(function()
        repeat wait(200) until isSampAvailable()
        while true do
            wait(0)
            if on('ut_bikerun') then pcall(UT.bikeStep) end        -- при выключенной функции ничего не создаётся и не вызывается
        end
    end)

    -- CamHack: положение камеры (C+1 включить, C+2 выключить, +/- скорость, F10 кадр)
    function UT.down(b)
        return b.key ~= 0 and isKeyDown(b.key) and ((b.mod or 0) == 0 or isKeyDown(b.mod))
    end

    function UT.camExit()
        local c = UT.cam
        displayRadar(true)
        displayHud(true)
        lockPlayerControl(false)
        restoreCameraJumpcut()
        setCameraBehindPlayer()
        c.mode = 0
    end

    function UT.camStep()
        local c = UT.cam
        if c.mode == 0 then
            if on('ut_camhack') and ctl.alive() and not ui.open[0] and not listening and keyOk() and UT.down(binds.ut_cam_start) then
                displayRadar(false)
                displayHud(false)
                c.x, c.y, c.z = getCharCoordinates(PLAYER_PED)
                c.az, c.ay = getCharHeading(PLAYER_PED), 0
                setFixedCameraPosition(c.x, c.y, c.z, 0, 0, 0)
                lockPlayerControl(true)
                c.mode = 1
            end
            return
        end
        if not on('ut_camhack') or not ctl.alive() then UT.camExit() return end
        if not keyOk() then return end
        local mx, my = getPcMouseMovement()
        c.az = (c.az + mx / 4) % 360
        c.ay = math.max(-89, math.min(89, c.ay + my / 4))
        local rz, ry = math.rad(c.az), math.rad(c.ay)
        local fx, fy, fz = math.sin(rz) * math.cos(ry), math.cos(rz) * math.cos(ry), math.sin(ry)
        local sp = c.speed
        if isKeyDown(0x57) then c.x, c.y, c.z = c.x + fx * sp, c.y + fy * sp, c.z + fz * sp end      -- W
        if isKeyDown(0x53) then c.x, c.y, c.z = c.x - fx * sp, c.y - fy * sp, c.z - fz * sp end      -- S
        if isKeyDown(0x41) then c.x, c.y = c.x + math.sin(rz - math.pi / 2) * sp, c.y + math.cos(rz - math.pi / 2) * sp end   -- A
        if isKeyDown(0x44) then c.x, c.y = c.x + math.sin(rz + math.pi / 2) * sp, c.y + math.cos(rz + math.pi / 2) * sp end   -- D
        if isKeyDown(0x20) then c.z = c.z + sp end                               -- пробел: вверх
        if isKeyDown(0x10) then c.z = c.z - sp end                               -- Shift: вниз
        setFixedCameraPosition(c.x, c.y, c.z, 0, 0, 0)
        pointCameraAtPoint(c.x + fx, c.y + fy, c.z + fz, 2)
        if UT.down(binds.ut_cam_up) then c.speed = c.speed + 0.01; printStringNow(string.format('%.2f', c.speed), 1000) end
        if UT.down(binds.ut_cam_dn) then c.speed = math.max(0.01, c.speed - 0.01); printStringNow(string.format('%.2f', c.speed), 1000) end
        if not listening and UT.down(binds.ut_cam_stop) then UT.camExit() end
    end

    lua_thread.create(function()
        repeat wait(200) until isSampAvailable()
        while true do
            wait(0)
            local ok, err = true, nil
            if UT.cam.mode ~= 0 or on('ut_camhack') then ok, err = pcall(UT.camStep) end
            if not ok then
                UT.cam.mode = 0
                pcall(UT.camExit)
                print('[COLLAPSE] CamHack: ' .. tostring(err))
                wait(2000)
            end
        end
    end)

    -- ---------- ClickWarp: СКМ включает курсор, ЛКМ - телепорт в точку, ПКМ у машины - сесть в неё ----------
    local function setPosKeepAnim(x, y, z)
        local ptr = getCharPointer(PLAYER_PED)
        if ptr == 0 then return end
        local mp = readMemory(ptr + 0x14, 4, false)
        if mp ~= 0 then
            writeMemory(mp + 0x30, 4, representFloatAsInt(x), false)
            writeMemory(mp + 0x34, 4, representFloatAsInt(y), false)
            writeMemory(mp + 0x38, 4, representFloatAsInt(z), false)
        end
    end
    local function cwCursor(state)
        UT.cwCursor = state
        if state then sampSetCursorMode(CMODE_LOCKCAM or 2) else sampToggleCursor(false) end
    end
    local function jumpIntoCar(car)
        local res, carid = sampGetVehicleIdByCarHandle(car)
        if res then
            local x, y, z = getCarCoordinates(car)
            lua_thread.create(function()
                setCharCoordinates(PLAYER_PED, x, y, z)
                sampSendEnterVehicle(carid, 0)
                wait(950)
                warpCharIntoCar(PLAYER_PED, car, 0)
            end)
        end
        return res
    end

    function UT.clickStep()
        if not on('ut_clickwarp') or isPauseMenuActive() or not ctl.alive() then
            if UT.cwCursor then cwCursor(false) end
            return
        end
        if isKeyDown(0x04) and not ui.open[0] then                               -- СКМ: курсор вкл/выкл
            cwCursor(not UT.cwCursor)
            while isKeyDown(0x04) do wait(80) end
        end
        if not UT.cwCursor or ui.open[0] then return end
        if sampGetCursorMode() == 0 then sampSetCursorMode(CMODE_LOCKCAM or 2) end
        local sx, sy = getCursorPos()
        local sw, sh = getScreenResolution()
        if sx < 0 or sy < 0 or sx >= sw or sy >= sh then return end
        local tx, ty, tz = convertScreenCoordsToWorld3D(sx, sy, 700.0)
        local camX, camY, camZ = getActiveCameraCoordinates()
        local result, hit = processLineOfSight(camX, camY, camZ, tx, ty, tz, true, true, false, true, false, false, false)
        if not (result and hit.entity ~= 0) then return end
        local n = hit.normal
        local px, py, pz = hit.pos[1] - n[1] * 0.1, hit.pos[2] - n[2] * 0.1, hit.pos[3] - n[3] * 0.1
        local zOff = (n[3] >= 0.5) and 1 or 300
        local ok2, hit2 = processLineOfSight(px, py, pz + zOff, px, py, pz - 0.3, true, true, false, true, false, false, false)
        if not ok2 then return end
        px, py, pz = hit2.pos[1], hit2.pos[2], hit2.pos[3] + 1
        UT.cwFont = UT.cwFont or renderCreateFont('Arial', 9, 5)
        UT.cwFont2 = UT.cwFont2 or renderCreateFont('Arial', 7, 6)
        local cx, cy, cz = getCharCoordinates(PLAYER_PED)
        local hoff = renderGetFontDrawHeight(UT.cwFont)
        sx, sy = sx - 2, sy - 2
        renderFontDrawText(UT.cwFont, string.format('%0.2fm', getDistanceBetweenCoords3d(cx, cy, cz, px, py, pz)), sx, sy - hoff, 0xEEEEEEEE)
        local intoCar
        if hit.entityType == 2 then
            local car = getVehiclePointerHandle(hit.entity)
            if doesVehicleExist(car) and (not isCharInAnyCar(PLAYER_PED) or storeCarCharIsInNoSave(PLAYER_PED) ~= car) then
                local color = 0xAAFFFFFF
                if isKeyDown(0x02) then intoCar, color = car, 0xFFFFFFFF end
                renderFontDrawText(UT.cwFont2, 'Hold right mouse button to teleport into the car', sx, sy - hoff * 3, color)
            end
        end
        UT.marker = createUser3dMarker(px, py, pz + 0.3, 4)
        if isKeyDown(0x01) then
            if intoCar then
                if not jumpIntoCar(intoCar) then setPosKeepAnim(px, py, pz) end
            else
                if isCharInAnyCar(PLAYER_PED) then
                    px, py, pz = px - n[1] * 1.8, py - n[2] * 1.8, pz - 0.8      -- машину ставим чуть в стороне от стены
                    setCharCoordinates(PLAYER_PED, px, py, pz)
                end
                setPosKeepAnim(px, py, pz)
            end
            while isKeyDown(0x01) do wait(0) end
            cwCursor(false)
        end
    end

    lua_thread.create(function()
        repeat wait(200) until isSampAvailable()
        while true do
            local ok, err = true, nil
            if on('ut_clickwarp') or UT.cwCursor then ok, err = pcall(UT.clickStep) end
            wait(0)                                          -- маркер живёт один кадр: создаётся в шаге, снимается после кадра
            if UT.marker then pcall(removeUser3dMarker, UT.marker); UT.marker = nil end
            if not ok then
                UT.cwCursor = false
                print('[COLLAPSE] ClickWarp: ' .. tostring(err))
                wait(2000)
            end
        end
    end)

    -- при выгрузке скрипта: всё, что включено и влияет на игру, возвращается в обычное состояние
    function UT.restore()
        pcall(function()
            setPlayerNeverGetsTired(PLAYER_HANDLE, false)
            if UT.fw then setSpeeds(FASTWALK, 1.0) end
            if UT.fa then setSpeeds(FASTANIM, 1.0) end
            if UT.rf then setSpeeds(RAPID, 1.0) end
            if UT.spread and memory and UT.spreadDef then memory.setfloat(9252452, UT.spreadDef, true) end
            UT.nameTag(false)
            UT.air.on = false
            if UT.cam.mode == 1 then UT.camExit() end
            if UT.cwCursor then cwCursor(false) end
        end)
        UT.tired, UT.fw, UT.fa, UT.rf, UT.spread = false, false, false, false, false
    end

    -- ---------- переводы ----------
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Dialogs'] = 'Диалоги', ['World'] = 'Мир', ['Abilities'] = 'Возможности', ['Weapon'] = 'Оружие',
        ['NoDialog'] = 'NoDialog', ['NoDialogRestore'] = 'NoDialogRestore', ['Chat on T'] = 'Чат на T', ['Dots in numbers'] = 'Точки в числах',
        ['Anti camera shake'] = 'Анти-тряска камеры', ['Disable stream zone loading'] = 'Отключить прогрузку зоны стрима',
        ['AntiMask'] = 'AntiMask', ['Remove barrier collision'] = 'Удаление коллизии шлагбаумов',
        ['Infinite run'] = 'Бесконечный бег', ['Run while hungry'] = 'Бег при голоде', ['AntiStun'] = 'AntiStun', ['NoFallAnimation'] = 'NoFallAnimation', ['NoAnim'] = 'NoAnim',
        ['AutoBunnyHop'] = 'AutoBunnyHop', ['Reset animations by key'] = 'Сбив анимаций кнопкой', ['Knock down settings'] = 'Настройки сбива',
        ['FastWalk'] = 'FastWalk', ['FastAnim'] = 'FastAnim', ['AirBrake'] = 'AirBrake', ['ClickWarp'] = 'ClickWarp', ['CamHack'] = 'CamHack',
        ['Wallhack'] = 'WallHack', ['Wallhack settings'] = 'Настройки WallHack', ['Key'] = 'Клавиша',
        ['FastWalk settings'] = 'Настройки FastWalk', ['FastAnim settings'] = 'Настройки FastAnim', ['RapidFire settings'] = 'Настройки RapidFire',
        ['AirBrake settings'] = 'Настройки AirBrake', ['Walk anim speed'] = 'Скорость анимации бега', ['All anim speed'] = 'Скорость всех анимаций',
        ['Fire anim speed'] = 'Скорость стрельбы', ['AirBrake speed'] = 'Скорость AirBrake',
        ['Anti spread'] = 'Анти-разброс', ['No reload'] = 'Стрельба без перезарядки', ['RapidFire'] = 'RapidFire',
        ['Anti bucket'] = 'Анти-ковш', ['Auto run and ride keys'] = 'Auto run and ride keys',
        ['AirBrake enabled'] = 'AirBrake включён', ['AirBrake disabled'] = 'AirBrake выключен',
        ['Wallhack enabled'] = 'WallHack включён', ['Wallhack disabled'] = 'WallHack выключен',
        ['Hold right mouse button to teleport into the car'] = 'Hold right mouse button to teleport into the car',
    }) do if ru[k] == nil then ru[k] = v end end

    for k, v in pairs({
        ['CamHack settings'] = 'Настройки свободной камеры', ['Activation'] = 'Включение', ['Deactivation'] = 'Выключение',
        ['Activation key'] = 'Клавиша включения', ['Bike key'] = 'Клавиша байка', ['Run key'] = 'Клавиша бега',
        ['Auto run and ride settings'] = 'Настройки авто-нажатия', ['Auto run: bike key'] = 'Авто-нажатие: байк', ['Auto run: run key'] = 'Авто-нажатие: бег',
        ['Speed up'] = 'Скорость +', ['Speed down'] = 'Скорость -',
    }) do if ru[k] == nil then ru[k] = v end end
    -- ---------- русские названия и подсказки ----------
    local H = {
        ['NoDialogRestore'] = 'Remembers the list position and the entered text in dialogs.',
        ['Chat on T'] = 'Opens the chat with the T key even when the Russian keyboard layout is on.',
        ['Dots in numbers'] = 'Separates money amounts with dots in the chat, dialogs and signs, for example 10000000$ becomes 10.000.000$.',
        ['Anti camera shake'] = 'Blocks the camera shake and the animation of drug withdrawal.',
        ['Disable stream zone loading'] = 'Mapping, vehicles, players and so on will not be loaded in the stream zone.',
        ['AntiMask'] = 'Shows masked players on the radar.',
        ['AutoBunnyHop'] = 'Lets you jump with the run key held without falling.',
        ['Reset animations by key'] = 'Resets your animation and removes the server freeze.',
        ['ClickWarp'] = 'Teleports you to the point under the cursor. Middle mouse button turns the cursor on, left button teleports, right button on a vehicle gets you into it.',
        ['CamHack'] = 'Free camera. The keys are set in the gear menu.',
        ['Anti bucket'] = 'Objects attached to vehicles will have no collision.',
    }
    for k, v in pairs(H) do HINTS[k] = v end
    for k, v in pairs({
        ['NoDialog'] = 'Без диалогов',
        ['NoDialogRestore'] = 'Память диалогов',
        ['AntiMask'] = 'Анти-маска',
        ['AntiStun'] = 'Анти-стан',
        ['NoFallAnimation'] = 'Отключение анимации падения',
        ['NoAnim'] = 'Отключение всех анимаций',
        ['AutoBunnyHop'] = 'Авто банни-хоп',
        ['FastWalk'] = 'Ускоренный бег',
        ['FastAnim'] = 'Ускоренные анимации',
        ['RapidFire'] = 'Ускоренная стрельба',
        ['CamHack'] = 'Свободная камера',
        ['Auto run and ride keys'] = 'Авто-нажатие клавиш бега и езды',
        ['FastWalk settings'] = 'Настройки ускоренного бега',
        ['FastAnim settings'] = 'Настройки ускоренных анимаций',
        ['RapidFire settings'] = 'Настройки ускоренной стрельбы',
    }) do ru[k] = v end
    for k, v in pairs({
        [H['NoDialogRestore']] = 'Запоминает позицию в списках и введённый текст в игровых диалогах.',
        [H['Chat on T']] = 'Чат будет открываться клавишей T и на русской раскладке.',
        [H['Dots in numbers']] = 'Разделяет денежные суммы точками в чате, диалогах и на табличках, например 10000000 станет 10.000.000.',
        [H['Anti camera shake']] = 'Блокирует тряску камеры и анимацию ломки.',
        [H['Disable stream zone loading']] = 'Маппинг, машины, игроки и прочее в зоне стрима прогружаться не будут.',
        [H['AntiMask']] = 'Показывает на радаре игроков, которые в маске.',
        [H['AutoBunnyHop']] = 'Позволяет прыгать с зажатой клавишей бега и не падать.',
        [H['Reset animations by key']] = 'Сбивает анимацию и снимает с вас фриз сервера.',
        [H['ClickWarp']] = 'Телепортирует в точку под курсором. Средняя кнопка мыши включает курсор, левая телепортирует, правая на машине сажает в неё.',
        [H['CamHack']] = 'Режим свободной камеры. Клавиши задаются в меню шестерёнки.',
        [H['Anti bucket']] = 'Прикреплённые к машинам объекты не будут иметь коллизию.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Порт функций UltraFuck (SpaceWare): GM Авто, GM Колеса, NoBike (и вариант, работающий только при зажатых W или Shift),
--  езда по воде, Infinity Fuel, переворот автомобиля [DEL], прыжок авто [B], Fast Exit Vehicle [U + J],
--  разворот на 180 градусов [Backspace], мгновенные лопасти вертолёта. Block Overdose Animation в Collapse уже есть:
--  это "Анти-тряска камеры" (те же анимации CRCKIDLE4 / CRCKIDLE2 / CRCKDETH2). Включаются в Основное -> Для авто.
-- ----------------------------------------------------------------------------
do
    local UF = {}
    ctl.uf = UF
    UF.heliT = 0
    binds.uf_gmcar_key = binds.uf_gmcar_key or {key = 0x58, mod = 0}  -- X (как у Godmode)
    binds.uf_k_flip = binds.uf_k_flip or {key = 0x2E, mod = 0}       -- DEL
    binds.uf_k_jump = binds.uf_k_jump or {key = 0x42, mod = 0}       -- B
    binds.uf_k_exit = binds.uf_k_exit or {key = 0x4A, mod = 0x55}    -- U + J
    binds.uf_k_turn = binds.uf_k_turn or {key = 0x08, mod = 0}       -- Backspace

    local function on(k) return B(k, false)[0] end

    -- клавиши действий работают, когда меню и ввод закрыты
    local function keysFree()
        return not ui.open[0] and not listening and not sampIsChatInputActive() and not sampIsDialogActive()
            and not isSampfuncsConsoleActive() and not sampIsScoreboardOpen() and not sampIsCursorActive()
    end
    ctl.keysFree = keysFree

    -- GM Авто работает, если включён пункт; в режиме "клавишей" - только пока включено клавишей
    function UF.gmCarActive()
        if not on('uf_gmcar') then return false end
        if on('uf_gmcar_keymode') then return UF.gmCarOn == true end
        return true
    end

    function UF.restore()
        pcall(function()
            if UF.gmCar and isCharInAnyCar(PLAYER_PED) then
                setCarProofs(storeCarCharIsInNoSave(PLAYER_PED), false, false, false, false, false)
            end
            if UF.bikeSet then setCharCanBeKnockedOffBike(PLAYER_PED, false) end
            if UF.water and memory then memory.write(9867602, 0, 4, true) end
        end)
    end

    function UF.tick()
        if not isSampAvailable() then return end
        local ped = PLAYER_PED
        local inCar = isCharInAnyCar(ped)
        local car = inCar and storeCarCharIsInNoSave(ped) or nil

        if on('uf_gmcar') and on('uf_gmcar_keymode') and inCar and keysFree() and ctl.bindFire(binds.uf_gmcar_key) then
            UF.gmCarOn = not UF.gmCarOn
            Notify(UF.gmCarOn and 'GM Car enabled' or 'GM Car disabled')
        end
        if not on('uf_gmcar') or not on('uf_gmcar_keymode') then UF.gmCarOn = false end

        if inCar then
            if on('uf_gmwheel') then setCanBurstCarTires(car, false) end                 -- колёса не пробиваются
            if UF.gmCarActive() then setCarProofs(car, true, true, true, true, true); UF.gmCar = true end
            if on('uf_infuel') then setCarEngineOn(car, true) end                        -- двигатель не глохнет
        end
        if UF.gmCar and not UF.gmCarActive() then                                          -- выключили: снять неуязвимость
            if inCar then setCarProofs(car, false, false, false, false, false) end
            UF.gmCar = false
        end

        -- NoBike: не падать с байка/велосипеда; вариант "беспалевный" - только пока зажата W или Shift
        local onBike = isCharOnAnyBike(ped)
        local want = on('uf_nobike') or (on('uf_nobike2') and onBike and (isKeyDown(0x57) or isKeyDown(0x10)))
        if want and onBike and isCarInWater(storeCarCharIsInNoSave(ped)) then want = false end      -- в воде слетаем как обычно
        if want or UF.bikeSet then
            setCharCanBeKnockedOffBike(ped, want and true or false)
            UF.bikeSet = want and true or false
        end

        -- езда по воде
        if memory then
            if on('uf_water') and inCar then
                memory.write(9867602, 1, 4, true)
                UF.water = true
            elseif UF.water then
                memory.write(9867602, 0, 4, true)
                UF.water = false
            end
        end

        if inCar and keysFree() then
            if on('uf_flip') and ctl.bindFire(binds.uf_k_flip) then                      -- поставить автомобиль на колёса
                local x, y, z = getOffsetFromCarInWorldCoords(car, 0, 0, 0)
                setCarCoordinates(car, x, y, z)
            end
            if on('uf_jump') and ctl.bindFire(binds.uf_k_jump) then                      -- подбросить автомобиль
                local _, _, vz = getCarSpeedVector(car)
                if vz < 7 then applyForceToCar(car, 0, 0, 0.2, 0, 0, 0) end
            end
            if on('uf_fastexit') and ctl.bindFire(binds.uf_k_exit) then                  -- быстрый выход
                local x, y, z = getCarCoordinates(car)
                warpCharFromCarToCoord(ped, x, y, z)
            end
            if on('uf_turn180') and ctl.bindFire(binds.uf_k_turn) then                   -- разворот на 180 градусов
                local vx, vy, vz = getCarSpeedVector(car)
                applyForceToCar(car, -vx / 25, -vy / 25, -vz / 25, 0, 0, 0)
                local qx, qy, qz, qw = getVehicleQuaternion(car)
                local m = {convertQuaternionToMatrix(qw, qx, qy, qz)}
                m[1], m[2], m[4], m[5], m[7], m[8] = -m[1], -m[2], -m[4], -m[5], -m[7], -m[8]
                local nw, nx, ny, nz = convertMatrixToQuaternion(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
                setVehicleQuaternion(car, nx, ny, nz, nw)
                setCarForwardSpeed(car, 0)
            end
        end

        -- лопасти вертолёта сразу на полной скорости (не чаще 10 раз в секунду)
        if on('uf_heli') and inCar and isCharInAnyHeli(ped) and isCarEngineOn(car) then
            local now = os.clock()
            if now - UF.heliT > 0.1 then
                UF.heliT = now
                setHeliBladesFullSpeed(car)
            end
        end
    end

    -- ---------- русские названия и подсказки ----------
    local ru = i18n.TR.ru
    local H = {
        ['NoBike'] = 'Does not let you fall off a bicycle or a bike. If you fall into the water, you get thrown off anyway.',
        ['Stealth NoBike'] = 'Does not let you fall off a bike only while W or SHIFT is held. If you fall into the water, you get thrown off anyway.',
        ['Infinity Fuel'] = 'The engine does not stop, so you can keep driving.',
        ['Car flip upright'] = 'Puts your vehicle back on its wheels. The key is set in the gear menu.',
        ['Car jump'] = 'Throws your vehicle up. The key is set in the gear menu.',
        ['Fast Exit Vehicle'] = 'Instant exit from the vehicle. The key is set in the gear menu.',
        ['180 degree turn'] = 'Turns your vehicle by 180 degrees. The key is set in the gear menu.',
        ['Instant heli blades'] = 'Removes the blade spin-up time on helicopters.',
    }
    for k, v in pairs(H) do HINTS[k] = v end
    for k, v in pairs({
        ['Vehicle actions'] = 'Действия с авто', ['With a key, GM Car is switched only while you are in a vehicle. Enabling it from the menu works at any time.'] = 'Бинд включает и выключает GM Car, только пока вы сидите в машине. Из меню GM Car включается в любой момент.', ['GM Car settings'] = 'Настройки GM Авто', ['GM Car enabled'] = 'GM Авто включён', ['GM Car disabled'] = 'GM Авто выключен', ['Infinity Fuel'] = 'Бесконечное топливо', ['Fast Exit Vehicle'] = 'Мгновенный выход из авто',
        ['180 degree turn'] = 'Разворот на 180 градусов', ['Instant heli blades'] = 'Мгновенные лопасти вертолёта', ['Car flip settings'] = 'Настройки переворота', ['Car jump settings'] = 'Настройки прыжка',
        ['Fast exit settings'] = 'Настройки выхода из авто', ['Turn settings'] = 'Настройки разворота', ['GM Car'] = 'GM Авто', ['GM Wheel'] = 'GM Колеса', ['Stealth NoBike'] = 'Беспалевный NoBike',
        ['Drive on water'] = 'Езда по воде', ['Car flip upright'] = 'Переворот автомобиля', ['Car jump'] = 'Прыжок авто',
        [H['NoBike']] = 'Не даёт вам упасть с велосипеда или байка. Если вы упадёте в воду, вы всё равно слетите с байка.',
        [H['Stealth NoBike']] = 'Не даёт упасть с байка только пока зажата клавиша W или SHIFT. Если вы упадёте в воду, вы всё равно слетите с байка.',
        [H['Infinity Fuel']] = 'Двигатель не глохнет, поэтому можно ехать без остановки.',
        [H['Car flip upright']] = 'Ставит ваш автомобиль на колёса. Клавиша задаётся в меню шестерёнки.',
        [H['Car jump']] = 'Подбрасывает ваш автомобиль вверх. Клавиша задаётся в меню шестерёнки.',
        [H['Fast Exit Vehicle']] = 'Мгновенный выход из автомобиля. Клавиша задаётся в меню шестерёнки.',
        [H['180 degree turn']] = 'Разворачивает автомобиль на 180 градусов. Клавиша задаётся в меню шестерёнки.',
        [H['Instant heli blades']] = 'Убирает время раскрутки лопастей на вертолёте.',
    }) do ru[k] = v end
end

-- ----------------------------------------------------------------------------
--  Ещё функции из UltraTool / UltraFuck / arztools:
--   - Heli blade collision (UltraTool): лопасти вертолёта без коллизии (правка памяти с возвратом исходных байт);
--   - команды /seat [ID], /pseat [ID], /setmarker [X], [Y], [Z] (UltraTool);
--   - Godmode с настраиваемой клавишей, FullSkillGun, бесконечный кислород (UltraFuck);
--   - Vehicle WH (arztools): ID, HP, модель, двигатель и замки транспорта сквозь стены; дистанция, размер текста, клавиша.
-- ----------------------------------------------------------------------------
do
    local UC = {}
    ctl.uc = UC
    UC.fonts = {}
    binds.uf_gm_key = binds.uf_gm_key or {key = 0x58, mod = 0}      -- X, как в UltraFuck
    binds.uf_vwh_key = binds.uf_vwh_key or {key = 0, mod = 0}       -- клавиша WH на транспорт: по желанию

    local function on(k) return B(k, false)[0] end
    local function free()
        return not ui.open[0] and not listening and not sampIsChatInputActive() and not sampIsDialogActive()
            and not isSampfuncsConsoleActive() and not sampIsScoreboardOpen()
    end

    -- ---------- команды ----------
    function UC.seat(arg, asPassenger)
        local id = tonumber((arg or ''):match('%d+'))
        if not id then NotifyErr('Enter the vehicle ID') return end
        local ok, car = sampGetCarHandleBySampVehicleId(id)
        if not ok then NotifyErr('The vehicle is not in the stream zone') return end
        local x, y, z = getCarCoordinates(car)
        lua_thread.create(function()
            pcall(function()
                setCharCoordinates(PLAYER_PED, x, y, z)
                if asPassenger then
                    wait(100)
                    sampSendEnterVehicle(id, 1)
                    wait(1000)
                    warpCharIntoCarAsPassenger(PLAYER_PED, car, 0)
                else
                    sampSendEnterVehicle(id, 0)
                    wait(1450)
                    warpCharIntoCar(PLAYER_PED, car, 0)
                    restoreCameraJumpcut()
                end
            end)
        end)
    end

    -- метка-чекпоинт и маркер на карте в заданной точке; чекпоинт снимается, когда вы подошли
    function UC.setMarker(arg)
        local x, y, z = (arg or ''):match('(-?[%d%.]+)[,%s]+(-?[%d%.]+)[,%s]+(-?[%d%.]+)')
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if not (x and y and z) then NotifyErr('Use: /setmarker X, Y, Z') return end
        if UC.marker then pcall(deleteCheckpoint, UC.marker) end
        local marker = createCheckpoint(1, x, y, z, 1, 1, 1, 2)
        UC.marker = marker
        pcall(placeWaypoint, x, y, z)
        Notify('Marker set')
        lua_thread.create(function()
            pcall(function()
                repeat
                    wait(0)
                    local px, py, pz = getCharCoordinates(PLAYER_PED)
                until getDistanceBetweenCoords3d(x, y, z, px, py, pz) < 2 or UC.marker ~= marker
                pcall(deleteCheckpoint, marker)
            end)
        end)
    end

    -- переподключение через seconds секунд
    -- пока идёт отсчёт, внизу экрана показывается окно с оставшимися секундами и убывающей полосой
    function UC.reconnect(seconds)
        UC.reconId = (UC.reconId or 0) + 1                       -- новый /rec отменяет предыдущий отсчёт
        local myId = UC.reconId
        changeGPCI(true)
        lua_thread.create(function()
            pcall(function()
                if sampIsDialogActive() then sampCloseCurrentDialogWithButton(0) end
                local gs = sampGetGamestate()
                if gs == GAMESTATE_CONNECTED or gs == GAMESTATE_AWAIT_JOIN then      -- разрываем только живое соединение: повторное отключение уже разорванного роняет игру
                    sampSetGamestate(GAMESTATE_DISCONNECTED)
                    sampDisconnectWithReason(0)
                end
                if seconds > 0 then
                    local R = {t0 = os.clock(), total = seconds}
                    UC.recon = R
                    while os.clock() - R.t0 < seconds and UC.reconId == myId and not R.skip do wait(0) end
                end
                if UC.reconId == myId then
                    UC.recon = nil
                    sampSetGamestate(GAMESTATE_WAIT_CONNECT)
                    UC.startGrace(30)
                end
            end)
            if UC.reconId == myId then UC.recon = nil end
        end)
    end

    function changeGPCI(bool)
        if bool then
            math.randomseed(os.time())
            math.random()
            math.random()
            math.random()

            local vev = {}
            for i = 13181804, 13181842 do
                local wew = math.random(10, 99)
                writeMemory("0x" .. bit.tohex(i), 1, wew, true)
                table.insert(vev, wew)
            end
            local eww = table.concat(vev, ",")
        end
    end

    -- Окно ожидания ответа сервера: пока идёт попытка подключения (после /rec, автореконнекта или запуска игры) сбои только
    -- запоминаются; если по истечении времени подключения так и нет - обрабатываем запомненный сбой
    function UC.startGrace(secs)
        UC.graceUntil, UC.pendingFail = os.clock() + secs, nil
    end

    -- один постоянный поток: по истечении ожидания обрабатываем запомненный сбой, если подключения так и нет
    lua_thread.create(function()
        while true do
            wait(250)
            local pend = UC.pendingFail
            if pend and os.clock() >= (UC.graceUntil or 0) then
                UC.pendingFail, UC.graceUntil = nil, 0
                local ok, st = pcall(sampGetGamestate)
                if ok and st ~= GAMESTATE_CONNECTED and st ~= GAMESTATE_AWAIT_JOIN then pcall(UC.onPacket, pend) end
            end
        end
    end)

    imgui.OnFrame(
        function() return ui.open ~= nil and UC.recon ~= nil end,
        function(self)
            self.HideCursor = false                                  -- для кнопок нужен курсор
            gfx.galpha = 1
            local R = UC.recon
            if not R then return end
            local left = math.max(0, R.total - (os.clock() - R.t0))
            local P, dl, io = imgui.ImVec2, imgui.GetBackgroundDrawList(), imgui.GetIO()
            local ds = io.DisplaySize
            imgui.PushFont(fonts.bold)
            local s1 = u8(tr(R.title or 'Reconnect') .. ': ' .. string.format('%.1f', left) .. ' ' .. tr('s'))
            local w1, h1 = imgui.CalcTextSize(s1).x, imgui.GetTextLineHeight()
            imgui.PopFont()
            local bw, bh = math.max(w1 + 48, 340), h1 + 46 + 44
            local x, y = (ds.x - bw) / 2, ds.y - bh - 40
            dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.88), 10)
            dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 10)
            imgui.PushFont(fonts.bold)
            dl:AddText(P(x + (bw - w1) / 2, y + 10), C(pal.text), s1)
            imgui.PopFont()
            local by = y + h1 + 26
            dl:AddRectFilled(P(x + 16, by), P(x + bw - 16, by + 10), C(pal.field), 5)
            dl:AddRectFilled(P(x + 16, by), P(x + 16 + (bw - 32) * clamp(left / R.total, 0, 1), by + 10), C(THEME.main), 5)

            -- кнопки "Отмена" и "Подключиться сейчас"
            local bwid, bhei, gap = (bw - 32 - 10) / 2, 28, 10
            local btnY = by + 20
            local m = io.MousePos
            local clicked = imgui.IsMouseClicked(0)
            imgui.PushFont(fonts.small)
            for i, def in ipairs({{'Cancel', false}, {R.skipLabel or 'Connect now', true}}) do
                local bx = x + 16 + (i - 1) * (bwid + gap)
                local hov = m.x >= bx and m.x <= bx + bwid and m.y >= btnY and m.y <= btnY + bhei
                local fill = def[2] and mix(THEME.main, pal.white, hov and 0.16 or 0) or mix(pal.field, THEME.main, hov and 0.24 or 0)
                dl:AddRectFilled(P(bx, btnY), P(bx + bwid, btnY + bhei), C(fill), 6)
                dl:AddRect(P(bx, btnY), P(bx + bwid, btnY + bhei), C(mix(pal.border, THEME.main, hov and 0.65 or 0)), 6)
                local label = u8(tr(def[1]))
                local lw, lth = imgui.CalcTextSize(label).x, imgui.GetTextLineHeight()
                dl:AddText(P(bx + (bwid - lw) / 2, btnY + (bhei - lth) / 2), C(def[2] and THEME.onMain or pal.text), label)
                if hov and clicked then
                    if def[2] then
                        R.skip = true                                 -- подключиться немедленно
                    else
                        UC.reconId = (UC.reconId or 0) + 1            -- отмена: остаёмся отключёнными
                        UC.recon = nil
                        Notify(R.cancelMsg or 'Reconnect cancelled')
                    end
                end
            end
            imgui.PopFont()
        end
    )

    -- /rec [секунды] - переподключиться через N секунд; /rec [Nick_Name] - переподключиться с другим ником
    function UC.recCmd(arg)
        arg = trim(arg or '')
        if arg:match('^%d+$') then
            UC.reconnect(tonumber(arg))
        elseif arg ~= '' and arg:match('^[%w_%.%[%]%$@=%(%)]+$') then
            sampSetLocalPlayerName(arg)
            Notify('New nickname: %s', arg)
            UC.reconnect(0)
        else
            NotifyErr('Enter the delay in seconds or a nickname')
        end
    end

    -- ---------- Автореконнект ----------
    -- Перезаход идёт через UC.reconnect (окно с обратным отсчётом: можно отменить или зайти сразу). Подряд идущие неудачи
    -- считаются; когда соединение принято (пакет 34), счётчик обнуляется.
    UC.arFails = 0
    UC.startGrace(30)   -- запуск игры: ждём ответа сервера
    pcall(ffi.cdef, 'void ExitProcess(unsigned int code); unsigned int WinExec(const char* cmd, unsigned int show);')

    -- сообщение в Telegram (если он настроен) - чтобы было видно, чем закончился автореконнект, даже если вы не у компьютера
    function UC.arTell(text)
        if ctl.tg and ctl.tg.ready and ctl.tg.ready() then pcall(ctl.tg.say, text, {important = true}) end
    end

    -- закрыть игру: обычное закрытие окна (WM_CLOSE), а если не закрылась за 5 секунд - завершение процесса
    function UC.closeGame()
        pcall(function()
            local hwnd = ffi.cast('void*', readMemory(13160328, 4, false))
            ffi.C.PostMessageA(hwnd, 0x10, 0, 0)
        end)
        lua_thread.create(function()
            wait(5000)
            pcall(ffi.C.ExitProcess, 0)
        end)
    end

    -- действие после исчерпания попыток: окно с отсчётом (отмена / выполнить сразу), потом закрытие игры или выключение компьютера
    function UC.arAction(kind)
        local shutdown = kind == 'shutdown'
        local secs = shutdown and 60 or 15
        UC.reconId = (UC.reconId or 0) + 1
        local R = {t0 = os.clock(), total = secs, title = shutdown and 'Shutting down the PC' or 'Closing the game',
                   skipLabel = shutdown and 'Shut down now' or 'Close now', cancelMsg = 'Cancelled'}
        UC.recon = R
        UC.arTell(string.format(tr(shutdown and 'Auto reconnect failed: the PC will shut down in %d s' or 'Auto reconnect failed: the game will close in %d s'), secs))
        lua_thread.create(function()
            while os.clock() - R.t0 < secs and UC.recon == R and not R.skip do wait(0) end
            if UC.recon ~= R then return end                         -- отменено
            UC.recon = nil
            if shutdown then
                pcall(ffi.C.WinExec, 'shutdown /s /t 10 /c "Collapse: auto reconnect failed"', 0)       -- отмена: shutdown /a
            else
                UC.closeGame()
            end
        end)
    end

    function UC.onPacket(id)
        if id == 34 then UC.arFails, UC.pendingFail, UC.graceUntil, UC.live = 0, nil, 0, true return end
        if not on('ar_enable') then return end
        local AR = {[32] = {'ar_closed', true}, [33] = {'ar_lost', true}, [31] = {'ar_rejected', true}, [29] = {'ar_failed', false}, [37] = {'ar_password', false}}
        local rule = AR[id]
        if not rule or not B(rule[1], rule[2])[0] then return end
        if UC.live == nil then                                       -- скрипт загрузили уже в игре: смотрим на состояние клиента
            local okS, st = pcall(sampGetGamestate)
            UC.live = okS and st == GAMESTATE_CONNECTED
        end
        if (id == 32 or id == 33) and not UC.live then return end     -- не были подключены: это неудачная попытка входа, клиент повторит её сам
        if UC.live then UC.live, UC.graceUntil = false, 0       -- были подключены и теперь слетели: реагируем сразу
        elseif os.clock() < (UC.graceUntil or 0) then UC.pendingFail = id return end      -- попытка подключения ещё идёт: не обрываем её, вернёмся к сбою позже
        if UC.recon then return end                                   -- перезаход уже идёт (/rec или прошлый автореконнект) или идёт отсчёт действия
        local maxTries = clamp(math.floor(I('ar_max', 5)[0] + 0.5), 1, 20)
        local after = I('ar_after', 0)[0]                             -- 0 - остановиться, 1 - пробовать дальше, 2 - выйти из игры, 3 - выключить компьютер
        UC.arFails = UC.arFails + 1
        if after ~= 1 and UC.arFails > maxTries then
            UC.arFails = 0
            if after == 2 then UC.arAction('exit')
            elseif after == 3 then UC.arAction('shutdown')
            else
                NotifyErr('Auto reconnect stopped: too many attempts')
                UC.arTell(tr('Auto reconnect stopped: too many attempts'))
            end
            return
        end
        local delay = clamp(math.floor(I('ar_delay', 15)[0] + 0.5), 15, 600)
        if after == 1 then Notify('Auto reconnect in %d s (attempt %d)', delay, UC.arFails)
        else Notify('Auto reconnect in %d s (attempt %d of %d)', delay, UC.arFails, maxTries) end
        UC.reconnect(delay)
    end

    function UC.register()
        pcall(sampRegisterChatCommand, 'rec', UC.recCmd)
        pcall(sampRegisterChatCommand, 'seat', function(a) UC.seat(a, false) end)
        pcall(sampRegisterChatCommand, 'pseat', function(a) UC.seat(a, true) end)
        pcall(sampRegisterChatCommand, 'setmarker', UC.setMarker)
    end

    -- ---------- Godmode ----------
    function UC.gmActive()
        if not on('uf_gm') then return false end
        if on('uf_gm_keymode') then return UC.gmOn == true end
        return true
    end

    if okEv and sampev then
        local function block(name)
            local old = sampev[name]
            sampev[name] = function(...)
                if UC.gmActive() then return false end
                if old then return old(...) end
            end
        end
        block('onResetPlayerWeapons')
        block('onSetCameraBehind')
        block('onTogglePlayerControllable')
        block('onSetPlayerHealth')
        block('onBulletSync')
    end

    -- ---------- Vehicle WH ----------
    local function whFont(size)
        if not UC.fonts[size] then UC.fonts[size] = renderCreateFont('Arial', size, 5) end
        return UC.fonts[size]
    end

    -- Текст над машиной (ID, HP, модель, двигатель, замки) пересобирается раз в uf_vwh_ms миллисекунд (по умолчанию 250),
    -- а позиция на экране считается каждый кадр. Название модели запоминается.
    UC.vwh, UC.vname, UC.vwhPrune = {}, {}, 0
    function UC.drawVehicles()
        local size = clamp(math.floor(F('uf_vwh_size', 7)[0] + 0.5), 6, 25)
        local rad = clamp(F('uf_vwh_dist', 100)[0], 1, 250)
        local interval = clamp(F('uf_vwh_ms', 250)[0], 50, 2000) / 1000
        local font = whFont(size)
        local now = os.clock()
        local cache = UC.vwh
        local cx, cy, cz = getActiveCameraCoordinates()
        for _, veh in ipairs(getAllVehicles()) do
            if doesVehicleExist(veh) and isCarOnScreen(veh) then
                local x, y, z = getCarCoordinates(veh)
                if getDistanceBetweenCoords3d(x, y, z, cx, cy, cz) <= rad then
                    local e = cache[veh]
                    if not e then e = {t = -100}; cache[veh] = e end
                    if now - e.t >= interval then
                        local _, vid = sampGetVehicleIdByCarHandle(veh)
                        local model = getCarModel(veh)
                        local name = UC.vname[model]
                        if not name then
                            name = (ctl.vn and ctl.vn.name(model)) or getGxtText(getNameOfVehicleModel(model)) or '?'
                            UC.vname[model] = name
                        end
                        local engine = isCarEngineOn(veh) and '{A7F14D}ON{FFFFFF}' or '{FFAAAA}OFF{FFFFFF}'
                        local lock = getCarDoorLockStatus(veh) == 0 and '{A7F14D}OPEN{FFFFFF}' or '{FFAAAA}LOCK{FFFFFF}'
                        e.text = string.format('ID: {A7F14D}%s{FFFFFF} HP: {A7F14D}%d\n{FFFFFF}%s [%s / %s]',
                            tostring(vid or '?'), getCarHealth(veh), name, engine, lock)
                        e.t = now
                    end
                    local sx, sy = convert3DCoordsToScreen(x, y, z)
                    if sx and sy then renderFontDrawText(font, e.text, sx, sy, 0xFFFFFFFF) end
                end
            end
        end
        if now > UC.vwhPrune then                             -- записи о давно не виденных машинах удаляются
            UC.vwhPrune = now + 10
            for h, e in pairs(cache) do
                if now - e.t > 10 then cache[h] = nil end
            end
        end
    end

    -- Основной цикл: Godmode, WH на машинах и др.
    function UC.tick()
        if not isSampAvailable() then return end
        local ped = PLAYER_PED

        -- лопасти вертолёта без коллизии: исходные байты сохраняем и возвращаем при выключении
        if memory then
            local want = on('uf_bladecol')
            if want and not UC.blade then
                UC.bladeOrig = memory.tohex(0x6C5107, 59, true)
                memory.fill(0x6C5107, 0x90, 59, true)
                UC.blade = true
            elseif not want and UC.blade then
                if UC.bladeOrig then memory.hex2bin(UC.bladeOrig, 0x6C5107, 59) end
                UC.blade = false
            end
        end

        -- Godmode: включение клавишей (если выбран такой режим) и применение
        if on('uf_gm') and on('uf_gm_keymode') and free() and ctl.bindFire(binds.uf_gm_key) then
            UC.gmOn = not UC.gmOn
            Notify(UC.gmOn and 'Godmode enabled' or 'Godmode disabled')
        end
        if not on('uf_gm') or not on('uf_gm_keymode') then UC.gmOn = false end
        if UC.gmActive() then
            local nowG = os.clock()
            if nowG >= (UC.gmAt or 0) then                         -- защита выставляется каждые 50 мс, а не в каждом кадре
                UC.gmAt = nowG + 0.05
                setCharProofs(ped, true, true, true, true, true)
                writeMemory(9867629, 1, 1, true)
                writeMemory(12046054, 1, 1, true)
                makePlayerFireProof(PLAYER_HANDLE, true)
                writeMemory(getCharPointer(ped) + 66, 1, 204, false)
            end
            UC.gmApplied = true
        elseif UC.gmApplied then
            setCharProofs(ped, false, false, false, false, false)
            writeMemory(9867629, 1, 0, true)
            writeMemory(12046054, 1, 0, true)
            makePlayerFireProof(PLAYER_HANDLE, false)
            writeMemory(getCharPointer(ped) + 66, 1, 0, false)
            UC.gmApplied = false
        end

        -- FullSkillGun: максимальные навыки оружия (70-79)
        if on('uf_skill') then
            local nowS = os.clock()
            if nowS >= (UC.skillAt or 0) then                      -- статы достаточно выставлять дважды в секунду
                UC.skillAt = nowS + 0.5
                for i = 70, 79 do registerIntStat(i, 1000) end
            end
            UC.skill = true
        elseif UC.skill then
            for i = 70, 79 do registerIntStat(i, 0) end
            UC.skill = false
        end

        -- бесконечный кислород (в воде)
        if memory then
            if on('uf_oxygen') and isCharInWater(ped) then
                memory.setint8(9867630, 1)
                UC.oxy = true
            elseif UC.oxy then
                memory.setint8(9867630, 0)
                UC.oxy = false
            end
        end

        -- Vehicle WH: переключение клавишей и отрисовка
        if free() and binds.uf_vwh_key.key ~= 0 and ctl.bindFire(binds.uf_vwh_key) then
            local p = B('uf_vwh', false)
            p[0] = not p[0]
            Notify(p[0] and 'Vehicle WH enabled' or 'Vehicle WH disabled')
        end
        if on('uf_vwh') then UC.drawVehicles() end
    end

    function UC.restore()
        pcall(function()
            local ped = PLAYER_PED
            if UC.blade and memory and UC.bladeOrig then memory.hex2bin(UC.bladeOrig, 0x6C5107, 59) end
            if UC.gmApplied then
                setCharProofs(ped, false, false, false, false, false)
                writeMemory(9867629, 1, 0, true)
                writeMemory(12046054, 1, 0, true)
                makePlayerFireProof(PLAYER_HANDLE, false)
                writeMemory(getCharPointer(ped) + 66, 1, 0, false)
            end
            if UC.skill then for i = 70, 79 do registerIntStat(i, 0) end end
            if UC.oxy and memory then memory.setint8(9867630, 0) end
        end)
        UC.blade, UC.gmApplied, UC.skill, UC.oxy = false, false, false, false
    end

    -- ---------- русские названия и подсказки ----------
    local ru = i18n.TR.ru
    local H = {
        ['Heli blade collision'] = 'Helicopter blades will have no collision.',
        ['Vehicle WH'] = 'Shows ID, health, model, engine and door lock of vehicles through walls. The distance, text size and key are set in the gear menu.',
        ['Godmode'] = 'Makes you immortal: damage, fire and explosions do not hurt, and the server cannot change your health. In the gear menu you can switch it with a key.',
    }
    for k, v in pairs(H) do HINTS[k] = v end
    HINTS['Auto reconnect'] = 'Reconnects to the server by itself after the server closed the connection (kick, restart) or the connection was lost. Situations, delay and number of attempts are set in the gear menu. While the countdown window is shown you can cancel or reconnect at once.'
    for k, v in pairs({
        [HINTS['Auto reconnect']] = 'Сам перезаходит на сервер, если сервер закрыл соединение (кик, перезапуск) или пропала связь. Ситуации, задержка и число попыток задаются в меню шестерёнки. Пока показано окно с отсчётом, можно отменить или зайти сразу.',
        ['Auto reconnect settings'] = 'Настройки автореконнекта', ['Choose in which situations the game reconnects by itself.'] = 'Выберите, в каких ситуациях игра перезаходит сама.',
        ['Connection attempt failed'] = 'Не удалось подключиться', ['Wrong password'] = 'Неверный пароль',
        ['Reconnect situations'] = 'Ситуации перезахода', ['Auto reconnect situations'] = 'Ситуации автореконнекта', ['%d of %d'] = '%d из %d',
        ['After the attempts run out'] = 'Когда попытки закончатся', ['Stop'] = 'Остановиться', ['Keep trying'] = 'Пробовать, пока не получится',
        ['Exit the game'] = 'Выйти из игры', ['Shut down the PC'] = 'Выключить компьютер', ['Auto reconnect in %d s (attempt %d)'] = 'Автореконнект через %d с (попытка %d)',
        ['Shutting down the PC'] = 'Выключение компьютера', ['Closing the game'] = 'Закрытие игры', ['Shut down now'] = 'Выключить сейчас', ['Close now'] = 'Закрыть сейчас',
        ['Cancelled'] = 'Отменено', ['Auto reconnect failed: the PC will shut down in %d s'] = 'Автореконнект не удался: компьютер выключится через %d с',
        ['Auto reconnect failed: the game will close in %d s'] = 'Автореконнект не удался: игра закроется через %d с',
        ['Server closed the connection'] = 'Сервер закрыл соединение', ['Connection lost'] = 'Потеряна связь с сервером', ['Reconnect delay'] = 'Задержка перед перезаходом',
        ['Attempts in a row'] = 'Попыток подряд', ['Auto reconnect in %d s (attempt %d of %d)'] = 'Автореконнект через %d с (попытка %d из %d)',
        ['Auto reconnect stopped: too many attempts'] = 'Автореконнект остановлен: слишком много попыток',
        ['Heli blade collision'] = 'Коллизия лопастей вертолёта', ['Vehicle WH'] = 'WH на транспорт', ['Vehicle WH settings'] = 'Настройки WH на транспорт',
        ['WH font size'] = 'Размер текста', ['WH update interval'] = 'Интервал обновления текста', ['WH distance'] = 'Дистанция прорисовки',
        ['Godmode'] = 'Godmode', ['Godmode settings'] = 'Настройки Godmode', ['Toggle with a key'] = 'Включать клавишей',
        ['FullSkillGun'] = 'FullSkillGun', ['Infinite oxygen'] = 'Бесконечный кислород',
        ['Reconnect'] = 'Переподключение', ['s'] = 'с', ['Connect now'] = 'Подключиться сейчас', ['Reconnect cancelled'] = 'Переподключение отменено', ['New nickname: %s'] = 'Новый ник: %s',
        ['Enter the delay in seconds or a nickname'] = 'Введите задержку в секундах или ник',
        ['Enter the vehicle ID'] = 'Введите ID транспорта', ['The vehicle is not in the stream zone'] = 'Транспорта нет в зоне стрима',
        ['Use: /setmarker X, Y, Z'] = 'Используйте: /setmarker X, Y, Z', ['Marker set'] = 'Метка установлена',
        ['Godmode enabled'] = 'Godmode включён', ['Godmode disabled'] = 'Godmode выключен',
        ['Vehicle WH enabled'] = 'WH на транспорт включён', ['Vehicle WH disabled'] = 'WH на транспорт выключен',
        ['Reconnect after N seconds, or with a new nickname'] = 'Переподключиться через N секунд или с новым ником',
        ['Get into a vehicle as the driver'] = 'Сесть в транспорт водителем', ['Get into a vehicle as a passenger'] = 'Сесть в транспорт пассажиром',
        ['Set a checkpoint and a map marker'] = 'Поставить чекпоинт и метку на карте',
        [H['Heli blade collision']] = 'Лопасти вертолёта не будут иметь коллизию.',
        [H['Vehicle WH']] = 'Показывает ID, HP, модель, двигатель и замки транспорта сквозь стены. Дистанция, размер текста и клавиша задаются в меню шестерёнки.',
        [H['Godmode']] = 'Делает вас бессмертным: урон, огонь и взрывы не вредят, а сервер не может менять ваше здоровье. В меню шестерёнки можно включать его клавишей.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Остров "Активные функции": маленькая панель на экране со списком функций, которые работают прямо сейчас
--  (включаются клавишей или действием: Wallhack, AirBrake, CamHack, ClickWarp, Godmode, WH на транспорт, Fly Car,
--  Speed Boost, телепорт Coord Master, дальний чат). Включение, размер и положение - в Настройки -> Меню.
-- ----------------------------------------------------------------------------
do
    local AL = {}
    ctl.al = AL
    AL.posEdit, AL.posT0 = false, 0

    function AL.px() return F('act_px', 1.0) end              -- положение панели, % экрана
    function AL.py() return F('act_py', 30.0) end

    -- функции, которые включаются клавишей или действием и работают прямо сейчас
    -- Список собирается не чаще 10 раз в секунду (его вызывают условие показа и отрисовка на каждый кадр)
    function AL.list()
        local now = os.clock()
        if not AL.cache or now - AL.cacheAt >= 0.1 then AL.cache, AL.cacheAt = AL.build(), now end
        return AL.cache
    end

    function AL.build()
        local out = {}
        local UT, UC, FA, CM, SX = ctl.ut, ctl.uc, ctl.fly, ctl.cm, ctl.sx
        -- bind: таблица бинда или готовый текст клавиши; показывается, если включено "Показывать бинды"
        local function add(label, cond, bind)
            if not cond then return end
            local text
            if type(bind) == 'string' then text = bind
            elseif bind and bind.key ~= 0 then text = ctl.bindName(bind) end
            out[#out + 1] = {label, text}
        end
        add('Wallhack', UT and UT.nameTagOn, binds.ut_wh)
        add('AirBrake', UT and UT.air and UT.air.on, binds.ut_air)
        add('CamHack', UT and UT.cam and UT.cam.mode == 1, binds.ut_cam_start)
        add('ClickWarp', UT and UT.cwCursor, 'MMB')
        add('Godmode', UC and UC.gmActive(), B('uf_gm_keymode', false)[0] and binds.uf_gm_key or nil)
        add('Vehicle WH', B('uf_vwh', false)[0], binds.uf_vwh_key)
        add('Fly Car', FA and FA.on, binds.flycar_key)
        add('Speed Boost', SX and SX.active, binds.speedx_key)
        add('Coord Master', CM and CM.active)
        add('Far chat', B('far_enable', false)[0], binds.far_toggle)
        add('NoAnim', B('ut_noanim', false)[0])
        add('NoDialog', B('ut_nodialog', false)[0])
        add('Infinity Fuel', B('uf_infuel', false)[0])
        add('NoBike', B('uf_nobike', false)[0])
        add('Disable stream zone loading', B('ut_offstream', false)[0])
        add('GM Car', B('uf_gmcar_keymode', false)[0] and ctl.uf and ctl.uf.gmCarActive(), binds.uf_gmcar_key)
        if B('ut_bikerun', false)[0] then                        -- пока зажаты клавиши бега/езды
            local okb, held = pcall(function()
                return (isCharOnAnyBike(PLAYER_PED) and ctl.ut.down(binds.ut_bike_key))
                    or ((isCharOnFoot(PLAYER_PED) or isCharInWater(PLAYER_PED)) and ctl.ut.down(binds.ut_run_key))
            end)
            add('Auto run and ride keys', okb and held)
        end
        return out
    end

    function AL.startPosEdit()
        AL.posEdit, AL.posT0 = true, os.clock()
        ui.open[0] = false                                       -- меню скрывается, панель следует за мышью
    end

    imgui.OnFrame(
        function()
            if ui.open == nil then return false end
            if AL.posEdit then return true end
            if not (B('act_show', true)[0] and isSampAvailable()) then return false end
            return ui.open[0] or (#AL.list() > 0 and not ctl.main.overlayBlocked())
        end,
        function(self)
            local editing = AL.posEdit
            self.HideCursor = not (ui.open[0] or editing)
            gfx.galpha = 1
            local P = imgui.ImVec2
            local dl = imgui.GetBackgroundDrawList()
            local io = imgui.GetIO()
            local ds = io.DisplaySize
            local k = clamp(F('act_scale', 1.0)[0], 0.5, 2.0)
            local font, fk = FNT.pickOverlay(k)
            local oldScale
            if pcall(function() oldScale = font.Scale; font.Scale = oldScale * fk end) == false or not oldScale then
                font, k, oldScale = fonts.small, 1, nil
            end
            imgui.PushFont(font)
            local lh = imgui.GetTextLineHeight()
            local list = AL.list()
            local title = u8(tr('Active functions') .. ': ' .. #list)
            local rows, binds2, tw = {}, {}, imgui.CalcTextSize(title).x
            local showBinds = B('act_binds', false)[0]
            for i, f in ipairs(list) do
                rows[i] = u8(tr(f[1]))
                local w = imgui.CalcTextSize(rows[i]).x
                if showBinds and f[2] then
                    binds2[i] = u8('[' .. f[2] .. ']')
                    w = w + 8 * k + imgui.CalcTextSize(binds2[i]).x
                end
                tw = math.max(tw, w)
            end
            local pad, gap = 9 * k, 3 * k
            local bw = tw + pad * 2 + 4 * k
            local bh = (#rows + 1) * lh + #rows * gap + pad * 2
            local x, y
            if editing then
                x, y = io.MousePos.x, io.MousePos.y
            else
                x, y = AL.px()[0] / 100 * ds.x, AL.py()[0] / 100 * ds.y
            end
            x = clamp(x, 0, math.max(0, ds.x - bw))
            y = clamp(y, 0, math.max(0, ds.y - bh))
            dl:AddRectFilled(P(x, y), P(x + bw, y + bh), C(pal.bg, 0.80), 7)
            dl:AddRect(P(x, y), P(x + bw, y + bh), C(pal.border), 7)
            dl:AddRectFilled(P(x, y + 6), P(x + 3, y + bh - 6), C(THEME.main), 2)
            if editing then
                dl:AddRect(P(x - 1, y - 1), P(x + bw + 1, y + bh + 1), C(THEME.main), 8)
                dl:AddRect(P(x - 2, y - 2), P(x + bw + 2, y + bh + 2), C(THEME.main, 0.5), 9)
            end
            local tx = x + pad + 4 * k
            dl:AddText(P(tx, y + pad), C(pal.dim), title)
            for i, s in ipairs(rows) do
                local ry = y + pad + i * (lh + gap)
                dl:AddText(P(tx, ry), C(pal.text), s)
                if binds2[i] then dl:AddText(P(tx + imgui.CalcTextSize(s).x + 8 * k, ry), C(THEME.main), binds2[i]) end
            end
            imgui.PopFont()
            if oldScale then pcall(function() font.Scale = oldScale end) end

            if editing then                                      -- подсказка сверху экрана, ЛКМ сохраняет, ПКМ отменяет
                imgui.PushFont(fonts.bold)
                local lines = {u8(tr('Click LMB to place the list')), u8(tr('RMB - cancel')),
                    string.format('X %.1f%%   Y %.1f%%', x / ds.x * 100, y / ds.y * 100)}
                local lw, lth = 0, imgui.GetTextLineHeight()
                for _, s in ipairs(lines) do lw = math.max(lw, imgui.CalcTextSize(s).x) end
                local bx2, by2 = (ds.x - lw - 36) / 2, 24
                local bh2 = lth * #lines + 8 * (#lines - 1) + 24
                dl:AddRectFilled(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.bg, 0.88), 8)
                dl:AddRect(P(bx2, by2), P(bx2 + lw + 36, by2 + bh2), C(pal.border), 8)
                dl:AddRectFilled(P(bx2 + 8, by2 + 8), P(bx2 + 11, by2 + bh2 - 8), C(THEME.main), 2)
                for i, s in ipairs(lines) do
                    dl:AddText(P(bx2 + 18 + (lw - imgui.CalcTextSize(s).x) / 2, by2 + 12 + (i - 1) * (lth + 8)), C(i == 1 and pal.text or pal.dim), s)
                end
                imgui.PopFont()
                if ui.alpha < 0.02 and os.clock() - AL.posT0 > 0.3 then
                    if imgui.IsMouseClicked(0) then
                        AL.px()[0] = clamp(math.floor(x / ds.x * 1000 + 0.5) / 10, 0, 100)
                        AL.py()[0] = clamp(math.floor(y / ds.y * 1000 + 0.5) / 10, 0, 100)
                        AL.posEdit = false
                        ui.open[0] = true
                        NotifyOk('Overlay position saved')
                    elseif imgui.IsMouseClicked(1) then
                        AL.posEdit = false
                        ui.open[0] = true
                        Notify('Position change cancelled')
                    end
                end
            end
        end
    )

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Active functions'] = 'Активные функции', ['Active functions settings'] = 'Настройки активных функций', ['Active functions list'] = 'Список активных функций',
        ['List size'] = 'Размер списка', ['Show binds'] = 'Показывать бинды', ['Edit list position'] = 'Изменить положение списка',
        ['Click LMB to place the list'] = 'Нажмите ЛКМ, чтобы разместить список',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- Игрок заспавнен и жив: режимы с состоянием (AirBrake, CamHack, Fly Car, ClickWarp, телепорт) в другом состоянии не работают
function ctl.alive()
    local now = os.clock()
    if now - (ctl.aliveAt or -1) < 0.03 then return ctl.aliveVal end      -- вызывается много раз за кадр: считаем не чаще раза в 30 мс
    local ok, spawned = pcall(sampIsLocalPlayerSpawned)
    local alive = false
    if ok and spawned then
        local ok2, dead = pcall(isCharDead, PLAYER_PED)
        alive = ok2 and dead == false
    end
    ctl.aliveAt, ctl.aliveVal = now, alive
    return alive
end

-- Выключение всех функций при выгрузке скрипта (вызывается из onScriptTerminate)
function ctl.restoreAll()
    if ctl.fly then pcall(ctl.fly.stop) end
    for _, name in ipairs({'ut', 'uc', 'uf', 'cm', 'sk', 'wk', 'tg', 'rem', 'vc'}) do
        local m = ctl[name]
        if m and m.restore then pcall(m.restore) end
    end
end

-- ----------------------------------------------------------------------------
--  ID на радаре (arztools, "Информация на радаре"): рядом с метками игроков и транспорта на радаре рисуются их ID.
--  Позиция метки считается встроенными функциями радара GTA (CRadar), текст рисуется поверх интерфейса игры.
--  Что показывать, размер текста и клавиша включения задаются в шестерёнке.
-- ----------------------------------------------------------------------------
do
    local RD = {}
    ctl.rd = RD
    pcall(ffi.cdef, 'struct CVector2D {float x, y;}')
    binds.rdr_key = binds.rdr_key or {key = 0, mod = 0}          -- клавиша включения: по желанию
    RD.fonts = {}

    local toRadar = ffi.cast('void (__cdecl*)(struct CVector2D*, struct CVector2D*)', 0x583530)
    local toScreen = ffi.cast('void (__cdecl*)(struct CVector2D*, struct CVector2D*)', 0x583480)
    local inside = ffi.cast('bool (__cdecl*)(struct CVector2D*)', 0x584D40)
    local vWorld, vRadar, vScreen = ffi.new('struct CVector2D'), ffi.new('struct CVector2D'), ffi.new('struct CVector2D')

    local function on(k, d) return B(k, d or false)[0] end

    -- координаты метки на экране или nil, если точка вне радара
    function RD.point(x, y)
        vWorld.x, vWorld.y = x, y
        vRadar.x, vRadar.y = 0, 0
        toRadar(vRadar, vWorld)
        if not inside(vRadar) then return nil end
        vScreen.x, vScreen.y = 0, 0
        toScreen(vScreen, vRadar)
        return vScreen.x, vScreen.y
    end

    local function font(size)
        if not RD.fonts[size] then RD.fonts[size] = renderCreateFont('Arial', size, 5) end
        return RD.fonts[size]
    end

    -- текст ID и его ширина для шрифта данного размера считаются один раз
    function RD.label(f, size, id)
        if RD.lblSize ~= size then RD.lbl, RD.lblSize = {}, size end
        local e = RD.lbl[id]
        if not e then
            local text = tostring(id)
            e = {text, renderGetFontDrawTextLength(f, text)}
            RD.lbl[id] = e
        end
        return e[1], e[2]
    end

    function RD.tick()
        if not isSampAvailable() then return end
        if binds.rdr_key.key ~= 0 and not ui.open[0] and not listening and not sampIsChatInputActive() and not sampIsDialogActive()
            and ctl.bindFire(binds.rdr_key) then
            local p = B('rdr_on', false)
            p[0] = not p[0]
            Notify(p[0] and 'Radar IDs enabled' or 'Radar IDs disabled')
        end
        if not on('rdr_on') then return end
        if isPauseMenuActive() or ctl.main.overlayBlocked() or (ctl.ut and ctl.ut.cam and ctl.ut.cam.mode == 1) then return end
        local okh, visible = pcall(isHudVisible)
        if okh and visible == false then return end

        local size = clamp(math.floor(F('rdr_size', 9)[0] + 0.5), 6, 25)
        local f = font(size)
        if on('rdr_players', true) then
            local byNick = on('rdr_clist', true)
            for _, ped in ipairs(getAllChars()) do
                if ped ~= PLAYER_PED then
                    local found, id = sampGetPlayerIdByCharHandle(ped)
                    if found then
                        local x, y = getCharCoordinates(ped)
                        local sx, sy = RD.point(x, y)
                        if sx then
                            local text, tw = RD.label(f, size, id)
                            local color = -1
                            if byNick then color = bit.bor(0xFF000000, bit.band(sampGetPlayerColor(id), 0xFFFFFF)) end
                            renderFontDrawText(f, text, sx - tw / 2, sy, color)
                        end
                    end
                end
            end
        end
        if on('rdr_vehicles') then
            local h = renderGetFontDrawHeight(f)
            for _, veh in ipairs(getAllVehicles()) do
                local found, id = sampGetVehicleIdByCarHandle(veh)
                if found and getDriverOfCar(veh) ~= PLAYER_PED then
                    local x, y = getCarCoordinates(veh)
                    local sx, sy = RD.point(x, y)
                    if sx then
                        local text, tw = RD.label(f, size, id)
                        renderFontDrawText(f, text, sx - tw / 2, sy - h - 3, 0xFF8F8F90)
                    end
                end
            end
        end
    end

    local ru = i18n.TR.ru
    HINTS['Radar IDs'] = 'Shows player or vehicle IDs next to their markers on the radar. What to show, the text size and the key are set in the gear menu.'
    for k, v in pairs({
        ['Radar IDs'] = 'ID на радаре', ['Radar IDs settings'] = 'Настройки ID на радаре', ['Player IDs'] = 'ID игроков',
        ['Vehicle IDs'] = 'ID транспорта', ['Color by nickname'] = 'Цвет ника', ['Radar font size'] = 'Размер текста',
        ['Radar IDs enabled'] = 'ID на радаре включены', ['Radar IDs disabled'] = 'ID на радаре выключены',
        [HINTS['Radar IDs']] = 'Показывает ID игроков или транспорта рядом с их метками на радаре. Что показывать, размер текста и клавиша задаются в меню шестерёнки.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Подключение к серверам (Software -> Server connector). Из ultra-connector.lua перенесён только опрос серверов:
--  UDP-запрос SA-MP (пакет "SAMP" + адрес + порт + 'i') возвращает онлайн и максимум игроков; время ответа
--  показывается как пинг. Опрос идёт, только пока страница открыта. Подключение - sampConnectToServer,
--  перед ним при желании меняется ник (sampSetLocalPlayerName).
-- ----------------------------------------------------------------------------
do
    local CN = {}
    ctl.cn = CN
    local okSock, socket = pcall(require, 'socket')

    local NAMES = {
        {'Phoenix', 'phoenix'}, {'Tucson', 'tucson'}, {'Scottdale', 'scottdale'}, {'Chandler', 'chandler'}, {'Brainburg', 'brainburg'},
        {'Saint-Rose', 'saintrose'}, {'Mesa', 'mesa'}, {'Red-Rock', 'redrock'}, {'Yuma', 'yuma'}, {'Surprise', 'surprise'},
        {'Prescott', 'prescott'}, {'Glendale', 'glendale'}, {'Kingman', 'kingman'}, {'Winslow', 'winslow'}, {'Payson', 'payson'},
        {'Gilbert', 'gilbert'}, {'Show-Low', 'showlow'}, {'Casa Grande', 'casagrande'}, {'Page', 'page'}, {'Sun City', 'suncity'},
        {'Queen Creek', 'queencreek'}, {'Sedona', 'sedona'}, {'Holiday', 'holiday'}, {'Wednesday', 'wednesday'}, {'Yava', 'yava'},
        {'Faraway', 'faraway'}, {'Bumble Bee', 'bumblebee'}, {'Christmas', 'christmas'}, {'Mirage', 'mirage'}, {'Love', 'love'},
        {'Drake', 'drake'}, {'Space', 'space'}, {'Home', 'home'},
    }
    CN.list = {}
    for i, v in ipairs(NAMES) do
        CN.list[i] = {name = v[1], host = v[2] .. '.arizona-rp.com', port = 7777, online = nil, max = nil, ping = nil}
    end
    CN.list[#CN.list + 1] = {name = 'Vice City', host = '80.66.82.147', port = 7777, vc = true}      -- онлайн и очередь - из API лаунчера
    CN.sel, CN.seen, CN.nextAt, CN.ips = nil, -100, 0, {}
    CN.ipFail, CN.ipErr, CN.stat, CN.cycleErr = {}, {}, nil, nil     -- причины ошибок: DNS (по хосту), итог последнего цикла, сбой цикла
    CN.API_URL = 'https://api.arizona-five.com/launcher/servers'
    CN.apiAt = 0

    -- ---------- опрос ----------
    -- возвращает адрес (или nil) и признак, что был настоящий DNS-запрос; неудача запоминается на 20 секунд, текст ошибки - в CN.ipErr
    local function resolve(host)
        if host:match('^%d+%.%d+%.%d+%.%d+$') then return host, false end
        local c = CN.ips[host]
        if c == nil or (c == false and os.clock() - (CN.ipFail[host] or 0) > 20) then
            local ok, ip, err = pcall(function() return socket.dns.toip(host) end)
            if ok and ip then
                CN.ips[host], CN.ipFail[host], CN.ipErr[host] = ip, nil, nil
            else
                CN.ips[host], CN.ipFail[host], CN.ipErr[host] = false, os.clock(), tostring(ok and err or ip)
            end
            return CN.ips[host] or nil, true
        end
        return c or nil, false
    end

    local function request(ip, port, real)
        local a, b, c, d = 0, 0, 0, 0                             -- по умолчанию нулевой IP: так запрос строит ultra-connector.lua
        if real then
            local x1, x2, x3, x4 = ip:match('(%d+)%.(%d+)%.(%d+)%.(%d+)')
            a, b, c, d = tonumber(x1) or 0, tonumber(x2) or 0, tonumber(x3) or 0, tonumber(x4) or 0
        end
        return 'SAMP' .. string.char(a, b, c, d, port % 256, math.floor(port / 256)) .. 'i'
    end

    local function u16(s, off) local lo, hi = s:byte(off + 1, off + 2); return lo + hi * 256 end

    -- один цикл: запросы всем серверам сразу, затем ждём ответы до 0.8 с
    -- Один SA-MP-запрос серверу без ожидания ответа (отправляется перед входом, как в ultra-connector)
    function CN.sendQuery(sv)
        if not okSock then return end
        local ip = resolve(sv.host)
        if not ip then return end
        local s = socket.udp()
        if not s then return end
        pcall(function()
            s:setpeername(ip, sv.port)
            s:settimeout(0)
            s:send(request(ip, sv.port))
        end)
        s:close()
    end

    function CN.cycle()
        local pend, got = {}, {}
        local st = {ok = 0, total = #CN.list, dns = 0, noreply = 0, sock = 0, at = os.time()}
        local function poll()
            local now = socket.gettime()
            for i = #pend, 1, -1 do
                local p = pend[i]
                local resp = p.s:receive()
                if resp and #resp > 14 and resp:sub(1, 4) == 'SAMP' then
                    if not p.sv.api then p.sv.online, p.sv.max = u16(resp, 12), u16(resp, 14) end      -- у серверов из API онлайн берётся оттуда
                    got[p.sv] = math.max(1, math.floor((now - p.t) * 1000 + 0.5))
                    p.sv.ping, p.sv.err = got[p.sv], nil
                    p.s:close()
                    table.remove(pend, i)
                elseif not p.retried and now - p.t > 1.1 then          -- на запрос с нулевым IP не ответили: один повтор с настоящим IP
                    p.retried = true
                    pcall(p.s.send, p.s, request(p.ip, p.sv.port, true))
                elseif now - p.t > 2.2 then                         -- не ответил за 2.2 с
                    p.s:close()
                    table.remove(pend, i)
                end
            end
        end
        for _, sv in ipairs(CN.list) do
            sv.err = nil
            local ip, looked = resolve(sv.host)
            if looked then wait(0) end                           -- DNS блокирующий: не больше одного запроса за кадр
            if not ip then
                sv.ping, sv.err = nil, 'DNS error'
                st.dns = st.dns + 1
            else
                local s = socket.udp()
                local ok = s and pcall(function()
                    s:setpeername(ip, sv.port)
                    s:settimeout(0)
                    s:send(request(ip, sv.port))
                end)
                if ok then
                    pend[#pend + 1] = {sv = sv, s = s, t = socket.gettime(), ip = ip}
                else
                    if s then s:close() end
                    sv.ping, sv.err = nil, 'Socket error'
                    st.sock = st.sock + 1
                end
                local t0 = socket.gettime()                       -- запросы идут по одному (25 в секунду), ответы собираются по ходу
                while socket.gettime() - t0 < 0.04 do
                    wait(0)
                    poll()
                end
            end
        end
        local t1 = socket.gettime()
        while #pend > 0 and socket.gettime() - t1 < 2.4 do
            wait(0)
            poll()
        end
        for _, p in ipairs(pend) do p.s:close() end
        for _, sv in ipairs(CN.list) do
            if sv.err ~= 'DNS error' and sv.err ~= 'Socket error' then
                local ms = got[sv]
                sv.hist = sv.hist or {}
                sv.hist[#sv.hist + 1] = ms and 1 or 0                 -- доля ответов за последние 10 циклов
                if #sv.hist > 10 then table.remove(sv.hist, 1) end
                sv.dUdp = ms
                if ms then sv.lastUdp, sv.lastUdpAt = ms, os.clock() end
                local ping = ms or ((sv.lastUdp and os.clock() - (sv.lastUdpAt or -1000) < 90) and sv.lastUdp) or nil      -- ответ был недавно
                if ping then
                    sv.ping, sv.err = ping, nil
                    st.ok = st.ok + 1
                else
                    sv.ping, sv.err = nil, 'No reply'
                    st.noreply = st.noreply + 1
                end
            end
        end
        CN.stat = st
    end

    -- Онлайн и очередь Vice City из API лаунчера    -- Онлайн и очередь Vice City из API лаунчера: {"vc":[{"ip":..,"online":738,"queue":0,"maxplayers":750,...}]}
    function CN.fetchApi()
        local okM, ml = pcall(require, 'moonloader')
        if not okM or not ml.download_status then CN.apiErr = 'Launcher API is unavailable' return end
        local path = FNT.filesDir() .. '\\launcher_servers.json'
        pcall(FNT.ensureFilesDir)
        pcall(downloadUrlToFile, CN.API_URL, path, function(id, status)
            if status ~= ml.download_status.STATUSEX_ENDDOWNLOAD then return end
            local f = io.open(path, 'rb')
            if not f then CN.apiErr = 'No response' return end
            local txt = f:read('*a')
            f:close()
            local ok, data = pcall(decodeJson, txt)
            if not (ok and type(data) == 'table') then CN.apiErr = 'Bad response' return end
            local byHost, n = {}, 0
            for _, sv in ipairs(CN.list) do byHost[sv.host] = sv end
            for _, group in ipairs({'arizona', 'vc'}) do
                for _, it in ipairs(type(data[group]) == 'table' and data[group] or {}) do
                    if type(it) == 'table' and type(it.ip) == 'string' then
                        local sv = byHost[it.ip]
                        if not sv and group == 'arizona' and tonumber(it.port) then          -- сервер, которого ещё нет в списке
                            sv = {name = tostring(it.name or it.ip), host = it.ip, port = tonumber(it.port)}
                            table.insert(CN.list, #CN.list, sv)                              -- перед Vice City (он последний)
                            byHost[it.ip] = sv
                        end
                        if sv then
                            sv.online, sv.max, sv.queue = tonumber(it.online), tonumber(it.maxplayers), tonumber(it.queue) or 0
                            sv.api = true
                            n = n + 1
                        end
                    end
                end
            end
            CN.apiErr, CN.apiTime, CN.apiCount = nil, os.time(), n
        end)
    end

    -- прогрев кэша DNS: по одному адресу раз в 150 мс сразу после загрузки, окно коннектора потом открывается без задержек
    if okSock then
        lua_thread.create(function()
            repeat wait(1000) until isSampAvailable()
            wait(3000)
            for _, sv in ipairs(CN.list) do
                if CN.ips[sv.host] == nil then
                    pcall(resolve, sv.host)
                    wait(150)
                end
            end
        end)
    end

    function CN.ensureThread()
        if CN.thread or not okSock then return end
        CN.thread = true
        lua_thread.create(function()
            while true do
                wait(0)
                if os.clock() - CN.seen < 60 and os.clock() >= CN.nextAt then      -- опрос только пока открыта страница
                    CN.nextAt = os.clock() + 10                                     -- запросы серверам: раз в 10 секунд
                    if os.clock() >= CN.apiAt then                                  -- API лаунчера: раз в 30 секунд
                        CN.apiAt = os.clock() + 30
                        pcall(CN.fetchApi)
                    end
                    local ok, err = pcall(CN.cycle)
                    CN.cycleErr = (not ok) and tostring(err) or nil
                    if not ok then print('[COLLAPSE] Server connector: ' .. tostring(err)) end
                end
            end
        end)
    end

    -- ---------- никнейм и подключение ----------
    function CN.nickBuf()
        if not CN.buf then
            CN.buf = imgui.new.char[32]()
            ffi.copy(CN.buf, me.nick or '')
        end
        return CN.buf
    end

    -- валидный ник (до 24 символов) или nil
    function CN.nick()
        local n = trim(ffi.string(CN.nickBuf()))
        if n == '' then return '' end
        if #n <= 24 and n:match('^[%w_%.%[%]%$@=%(%)]+$') then return n end
        return nil
    end

    function CN.applyNick(silent)
        local n = CN.nick()
        if n == nil then NotifyErr('Invalid nickname') return false end
        if n == '' then return true end
        pcall(sampSetLocalPlayerName, n)
        if not silent then NotifyOk('Nickname changed: %s', n) end
        return true
    end

    -- сообщение в чат и консоль (чтобы по каждому шагу входа было видно, что происходит)
    local function cnSay(text)
        pcall(sampAddChatMessage, '{FFB84D}[Collapse] {FFFFFF}' .. text, -1)
        print('[COLLAPSE] ' .. text)
    end

    -- название состояния игры по числу из sampGetGamestate
    local function gamestateName(v)
        for _, name in ipairs({'GAMESTATE_WAIT_CONNECT', 'GAMESTATE_CONNECTING', 'GAMESTATE_AWAIT_JOIN', 'GAMESTATE_CONNECTED',
                               'GAMESTATE_RESTARTING', 'GAMESTATE_DISCONNECTED'}) do
            if _G[name] == v then return name:gsub('^GAMESTATE_', '') end
        end
        return tostring(v)
    end

    function CN.connect(sv)
        if not sv then
            NotifyErr('Select a server first')
            cnSay(tr('Select a server first'))
            return
        end
        if not CN.applyNick(true) then return end
        Notify('Connecting to %s', sv.name)
        cnSay(string.format(tr('Connecting to %s'), sv.name) .. ' (' .. sv.host .. ':' .. tostring(sv.port) .. ')')
        pcall(CN.sendQuery, sv)                                   -- SA-MP-запрос серверу прямо перед входом (без ожидания ответа)
        lua_thread.create(function()
            local okS, gs = pcall(sampGetGamestate)
            if okS and gs == 3 then                               -- уже подключены к серверу: сначала отключаемся, иначе вход может не начаться
                cnSay(tr('Disconnecting from the current server...'))
                pcall(function()
                    sampSetGamestate(GAMESTATE_DISCONNECTED)
                    sampDisconnectWithReason(0)
                end)
                wait(700)
            end
            local ok, err = pcall(sampConnectToServer, sv.host, tostring(sv.port))        -- порт строкой, как в ultra-connector.lua
            if not ok then
                NotifyErr('Could not connect')
                cnSay(tr('Could not connect') .. ': ' .. tostring(err))
                return
            end
            wait(300)
            local okG, gNow = pcall(sampGetGamestate)
            if okG and gNow == GAMESTATE_DISCONNECTED then        -- адрес записан, но подключение не началось: запускаем его, как это делает /rec
                cnSay(tr('Starting the connection...'))
                pcall(sampSetGamestate, GAMESTATE_WAIT_CONNECT)
            end
            wait(2700)
            local ok2, gs2 = pcall(sampGetGamestate)
            cnSay(string.format(tr('Connection state: %s'), ok2 and gamestateName(gs2) or '?'))
        end)
    end

    -- ---------- страница ----------
    local function pingColor(ms)
        if not ms then return pal.dim end
        if ms < 80 then return CONST.TOAST_COL.success end
        if ms < 160 then return {0.95, 0.78, 0.30} end
        return CONST.TOAST_COL.error
    end

    local function currentHost()
        local ok, ip = pcall(sampGetCurrentServerAddress)
        return ok and ip or nil
    end

    local function ListBody()
        if SRCH.collecting then return end
        CN.seen = os.clock()
        CN.ensureThread()
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local cur = currentHost()
        for i, sv in ipairs(CN.list) do
            local p = imgui.GetCursorScreenPos()
            local w = imgui.GetContentRegionAvail().x
            local pressed = imgui.InvisibleButton('##srv' .. i, P(w, 30))
            local hv = animTo('srv' .. i, imgui.IsItemHovered() and 1 or 0, 14)
            if pressed then CN.sel = i end
            if imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0) then CN.connect(sv) end
            local sel = animTo('srvs' .. i, (CN.sel == i) and 1 or 0, 14)
            dl:AddRectFilled(p, P(p.x + w, p.y + 28), C(mix(pal.field, THEME.main, sel * 0.22 + hv * 0.08)), 7)
            dl:AddRectFilled(P(p.x, p.y + 6), P(p.x + 3, p.y + 22), C(THEME.main, math.max(sel, hv * 0.6)), 2)
            local isCur = cur and (cur == sv.host or cur == CN.ips[sv.host])      -- без DNS-запросов в кадре отрисовки
            dl:AddText(P(p.x + 12, p.y + 6), C(mix(pal.text, THEME.main, sel * 0.5)), u8(sv.name .. (isCur and '  *' or '')))
            local players = sv.online and (sv.online .. ' / ' .. (sv.max or '?')) or '-'
            if sv.queue and sv.queue > 0 then players = players .. '   ' .. tr('queue') .. ' ' .. sv.queue end
            local ps = u8(players)
            local pw = imgui.CalcTextSize(ps).x
            local pingS = u8(sv.ping and (sv.ping .. ' ' .. tr('ms')) or (sv.err and not sv.api and tr(sv.err)) or '-')
            local ppw = imgui.CalcTextSize(pingS).x
            dl:AddText(P(p.x + w - 14 - ppw, p.y + 6), C(sv.ping and pingColor(sv.ping) or ((sv.err and not sv.api) and CONST.TOAST_COL.error or pal.dim)), pingS)
            dl:AddText(P(p.x + w - 14 - 70 - pw - ppw, p.y + 6), C(pal.dim), ps)
            imgui.Dummy(P(1, 2))
        end
    end

    local function RightBody()
        if SRCH.collecting then return end
        local sv = CN.sel and CN.list[CN.sel]
        InfoRow('Selected server', sv and sv.name or '-')
        InfoRow('Players', (sv and sv.online) and (sv.online .. ' / ' .. (sv.max or '?')) or '-')
        if sv and sv.queue and sv.queue > 0 then InfoRow('Queue', tostring(sv.queue)) end
        InfoRow('Ping', (sv and sv.ping) and (sv.ping .. ' ' .. tr('ms')) or (sv and sv.err and not sv.api and tr(sv.err)) or '-')
        if sv then
            InfoRow('UDP', sv.dUdp and (sv.dUdp .. ' ' .. tr('ms')) or tr('No reply'))
            if sv.hist and #sv.hist > 0 then
                local hits = 0
                for _, v in ipairs(sv.hist) do hits = hits + v end
                InfoRow('UDP replies', string.format('%d / %d', hits, #sv.hist))
            end
        end
        local st = CN.stat
        if st then
            InfoRow('Last update', string.format('%s  (%d/%d)', os.date('%H:%M:%S', st.at), st.ok, st.total))
            Text(string.format(tr('Answered the UDP query: %d of %d'), st.ok, st.total), pal.dim)
            if st.ok < st.total then
                Text(string.format(tr('No answer: DNS %d, timeout %d, socket %d'), st.dns, st.noreply, st.sock), CONST.TOAST_COL.error)
            end
        end
        if CN.apiErr then
            Text(tr('Launcher API') .. ': ' .. tr(CN.apiErr), CONST.TOAST_COL.error)
        elseif CN.apiTime then
            InfoRow('Launcher API', string.format('%s  (%d)', os.date('%H:%M:%S', CN.apiTime), CN.apiCount or 0))
        end
        if sv and not sv.ping and sv.err == 'DNS error' and CN.ipErr[sv.host] then Text(CN.ipErr[sv.host], pal.dim) end
        if CN.cycleErr then Text(tr('Error') .. ': ' .. CN.cycleErr, CONST.TOAST_COL.error) end
        imgui.Dummy(imgui.ImVec2(1, 6))
        TextRow('Your nickname:', CN.nickBuf(), function() end, nil, nil, 150)
        if Button('Change nickname', 34) then CN.applyNick(false) end
        if Button('Connect', 34, true) then CN.connect(sv) end
        if Button('Refresh', 34) then CN.nextAt = 0 end
        if not okSock then Text('The socket library was not found: pings are unavailable.', pal.dim) end
    end

    SOFT.draw.connector = function()
        local lw = LAY.COLW + 50
        Panel('Servers', 0, 0, lw, LAY.CH, ListBody, nil, true, function()
            SOFT.pageHeader('cn', lw)
        end, 30)
        Panel('Connection', lw + 14, 0, LAY.CW - lw - 14, LAY.CH, RightBody)
    end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Server connector'] = 'Коннектор', ['Join any'] = 'Вход на любой', ['Arizona server'] = 'сервер Arizona',
        ['Servers'] = 'Серверы', ['Connection'] = 'Подключение', ['Selected server'] = 'Выбранный сервер', ['Players'] = 'Игроков',
        ['Ping'] = 'Пинг', ['queue'] = 'очередь', ['Queue'] = 'Очередь', ['Your nickname:'] = 'Ваш ник:', ['Change nickname'] = 'Сменить никнейм', ['Connect'] = 'Подключиться',
        ['Launcher API'] = 'API лаунчера', ['Launcher API is unavailable'] = 'API лаунчера недоступен', ['Bad response'] = 'Неверный ответ',
        ['UDP replies'] = 'Ответов по UDP', ['Starting the connection...'] = 'Запуск подключения...',
        ['Disconnecting from the current server...'] = 'Отключение от текущего сервера...', ['Connection state: %s'] = 'Состояние подключения: %s',
        ['Answered the UDP query: %d of %d'] = 'Ответили на UDP-запрос: %d из %d',
        ['DNS error'] = 'Ошибка DNS', ['Socket error'] = 'Ошибка сокета', ['No reply'] = 'Нет ответа', ['Last update'] = 'Последнее обновление',
        ['No answer: DNS %d, timeout %d, socket %d'] = 'Нет ответа: DNS %d, таймаут %d, сокет %d',
        ['Refresh'] = 'Обновить', ['Invalid nickname'] = 'Неверный никнейм', ['Nickname changed: %s'] = 'Никнейм изменён: %s',
        ['Select a server first'] = 'Сначала выберите сервер', ['Connecting to %s'] = 'Подключение к %s', ['Could not connect'] = 'Не удалось подключиться',
        ['The socket library was not found: pings are unavailable.'] = 'Библиотека socket не найдена: пинг недоступен.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Telegram (Software -> Telegram): связь с ботом и управление игрой из Telegram.
--  Два способа связи (переключаются в плитке, приоритетный - Cloudflare Worker):
--   0. Cloudflare Worker: игра обращается ТОЛЬКО к вашему Worker'у (/poll и /call), а он сам ходит в API Telegram.
--      Токен бота хранится в секретах Cloudflare и в игру не попадает. Код Worker'а - TG.WORKER_JS (кнопка "Copy Worker code").
--   1. Telegram API напрямую: игра сама обращается к api.telegram.org (нужны токен бота и ID чата).
--  Запросы идут через curl.exe (скрытый процесс, без ожидания): получение - длинный опрос getUpdates (ответ приходит сразу,
--  как только есть сообщение), отправка - POST с JSON. Запасной путь для получения - downloadUrlToFile.
--  Управление (идея и часть команд из TelegramControl.lua): клавиатура с кнопками в Telegram, команды /status /pos /chat /say
--  /key /keys /dialog /d /reconnect /exit, пересылка упоминаний, диалогов и уведомлений о подключении.
--  Настройки доступа (адрес Worker'а, ключ, токен, чат, ключевые слова) лежат в files\telegram.json, а не в общем конфиге.
-- ----------------------------------------------------------------------------
do
    local TG = {}
    ctl.tg = TG
    TG.cfg = {url = '', key = '', token = '', chat = '', keywords = ''}
    TG.msgs, TG.received = {}, 0
    TG.status, TG.err = 'off', nil            -- off | wait | ok | err
    TG.busy, TG.busyAt, TG.nextAt, TG.seq = false, 0, 0, 0
    TG.offset = nil                           -- nil - ещё не определили, с какого сообщения начинать (старые не показываются)
    TG.API = 'https://api.telegram.org'
    TG.WORKER_VER = 2                         -- версия кода Worker'а: старая версия не умеет кнопки и /call
    TG.outQ, TG.outBusy, TG.sendAt = {}, false, 0
    TG.chatBuf, TG.held, TG.fwdTimes, TG.suppressed = {}, {}, {}, 0
    TG.KB = {}
    gfx.txtPass['Access key'], gfx.txtPass['Bot token'] = true, true

    TG.WORKER_JS = [==[
// Collapse -> Telegram: Cloudflare Worker (version 2).
// Secrets (Settings -> Variables and Secrets): BOT_TOKEN, CHAT_ID, ACCESS_KEY.
const CALL_METHODS = ['sendMessage', 'editMessageText', 'editMessageReplyMarkup', 'deleteMessage', 'answerCallbackQuery', 'sendChatAction'];
const WITH_CHAT = ['sendMessage', 'editMessageText', 'editMessageReplyMarkup', 'deleteMessage', 'sendChatAction'];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const reply = (obj) => new Response(JSON.stringify(obj), {
      headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
    });
    if (url.searchParams.get('key') !== env.ACCESS_KEY) return reply({ ok: false, error: 'access denied' });
    const tg = async (method, params) => {
      const r = await fetch('https://api.telegram.org/bot' + env.BOT_TOKEN + '/' + method, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(params),
      });
      return r.json();
    };
    try {
      // The game sends a Telegram method and its parameters; the chat is always your CHAT_ID.
      if (url.pathname === '/call' && request.method === 'POST') {
        const body = await request.json();
        if (!CALL_METHODS.includes(body.method)) return reply({ ok: false, error: 'method not allowed' });
        const params = Object.assign({}, body.params || {});
        if (WITH_CHAT.includes(body.method)) params.chat_id = env.CHAT_ID;
        return reply(await tg(body.method, params));
      }
      // Long polling: waits up to 25 s and answers as soon as there is something new.
      if (url.pathname === '/poll') {
        const offset = parseInt(url.searchParams.get('offset') || '0', 10) || 0;
        const wait = Math.min(Math.max(parseInt(url.searchParams.get('wait') || '0', 10) || 0, 0), 25);
        const r = await tg('getUpdates', { offset: offset, timeout: wait, allowed_updates: ['message', 'callback_query'] });
        if (!r.ok) return reply({ ok: false, error: r.description });
        let next = offset > 0 ? offset : 0;
        const updates = [];
        for (const u of r.result) {
          next = Math.max(next, u.update_id + 1);
          const m = u.message;
          if (m && m.text && String(m.chat.id) === String(env.CHAT_ID)) {
            updates.push({
              type: 'message',
              id: u.update_id,
              from: (m.from && (m.from.username || m.from.first_name)) || '',
              text: m.text,
              date: m.date,
            });
          }
          const q = u.callback_query;
          if (q && q.message && String(q.message.chat.id) === String(env.CHAT_ID)) {
            updates.push({
              type: 'callback',
              id: u.update_id,
              from: (q.from && (q.from.username || q.from.first_name)) || '',
              cb_id: q.id,
              data: q.data || '',
              message_id: q.message.message_id,
              date: Math.floor(Date.now() / 1000),
            });
          }
        }
        return reply({ ok: true, v: 2, updates: updates, next: next });
      }
      return reply({ ok: true, v: 2, service: 'collapse-telegram' });
    } catch (e) {
      return reply({ ok: false, error: String(e) });
    }
  },
};
]==]

    -- ---------- вспомогательное ----------
    local EM = {                                  -- эмодзи в UTF-8
        ok = '\226\156\133', err = '\226\157\140', warn = '\226\154\160\239\184\143', chat = '\240\159\146\172',
        bell = '\240\159\148\148', dlg = '\240\159\147\139', game = '\240\159\142\174', plug = '\240\159\148\140',
        info = '\226\132\185\239\184\143', pin = '\240\159\147\141', help = '\226\157\147', key = '\226\140\168\239\184\143',
        re = '\240\159\148\132', gear = '\226\154\153\239\184\143', money = '\240\159\146\176',
    }

    local function D(s) return u8:decode(tostring(s)) end        -- UTF-8 -> CP1251
    local function T(key, ...)
        local s = tr(key)
        if select('#', ...) > 0 then return string.format(s, ...) end
        return s
    end
    local function stripColors(s) return (tostring(s):gsub('{%x%x%x%x%x%x%x?%x?}', ''):gsub('\r', '')) end
    local function clip(s, n)
        s = tostring(s)
        if #s > n then return s:sub(1, n - 1) .. '~' end
        return s
    end

    -- ---------- настройки доступа ----------
    function TG.path() return FNT.filesDir() .. '\\telegram.json' end

    function TG.load()
        local f = io.open(TG.path(), 'rb')
        if not f then return end
        local txt = f:read('*a')
        f:close()
        local ok, d = pcall(decodeJson, txt)
        if ok and type(d) == 'table' then
            for k in pairs(TG.cfg) do
                if type(d[k]) == 'string' then TG.cfg[k] = d[k] end
            end
        end
    end
    TG.load()

    function TG.save()
        pcall(FNT.ensureFilesDir)
        local f = io.open(TG.path(), 'wb')
        if not f then NotifyErr('Could not save the Telegram settings') return end
        f:write(encodeJson(TG.cfg))
        f:close()
    end

    -- ключевые слова пересылки - обычный список фраз (как "Игнор упоминаний"): окно списка, файл words_tg_keywords.txt
    WORDS.register('tg_keywords', 'Keywords', 'LIST_UL')
    if TG.cfg.keywords ~= '' then                 -- перенос старой строки "через запятую" в список
        local items = WORDS.get('tg_keywords')
        if #items == 0 then
            for kw in D(TG.cfg.keywords):gmatch('[^,]+') do
                kw = lower(trim(kw))
                if kw ~= '' then items[#items + 1] = kw end
            end
            WORDS.save('tg_keywords')
        end
        TG.cfg.keywords = ''
        TG.save()
    end

    TG.bufs = {}
    function TG.buf(name)
        local b = TG.bufs[name]
        if not b then
            b = imgui.new.char[256]()
            ffi.copy(b, (TG.cfg[name] or ''):sub(1, 255))
            TG.bufs[name] = b
        end
        return b
    end

    -- поля ввода -> TG.cfg; возвращает: что-то изменилось, изменились данные подключения
    function TG.sync()
        local changed, conn = false, false
        for name in pairs(TG.cfg) do
            if TG.bufs[name] then
                local v = trim(ffi.string(TG.bufs[name]))
                if v ~= TG.cfg[name] then
                    TG.cfg[name], changed = v, true
                    if name ~= 'keywords' then conn = true end
                end
            end
        end
        return changed, conn
    end

    function TG.apply()
        local changed, conn = TG.sync()
        if changed then TG.save() end
        if conn then TG.offset, TG.nextAt, TG.err = nil, 0, nil end        -- новые данные подключения: начинаем с самых свежих сообщений
    end

    function TG.mode() return I('tg_mode', 0)[0] end

    function TG.ready()
        local c = TG.cfg
        if TG.mode() == 0 then return c.url ~= '' and c.key ~= '' end
        return c.token ~= '' and c.chat ~= ''
    end

    local function enc(s)
        return (tostring(s):gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', c:byte()) end))
    end

    local function numstr(v)
        if type(v) == 'number' then return string.format('%.0f', v) end
        return tostring(v)
    end

    function TG.base()
        local u = TG.cfg.url:gsub('/+$', '')
        if not u:find('^https?://') then u = 'https://' .. u end
        return u
    end

    -- ---------- HTTP ----------
    -- Основной способ: curl.exe из Windows (есть в Windows 10/11), запускается скрытым процессом без ожидания. Так отправка
    -- и длинный запрос получения идут одновременно. Запасной способ для GET - downloadUrlToFile: он выполняет запросы
    -- по одному, поэтому отправка ждала бы окончания длинного запроса. POST (отправка) работает только через curl.
    pcall(ffi.cdef, [[
        typedef struct { unsigned long cb; char* lpReserved; char* lpDesktop; char* lpTitle;
            unsigned long dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            unsigned short wShowWindow, cbReserved2; unsigned char* lpReserved2;
            void* hStdInput; void* hStdOutput; void* hStdError; } COLTG_SI;
        typedef struct { void* hProcess; void* hThread; unsigned long dwProcessId, dwThreadId; } COLTG_PI;
        int CreateProcessA(const char* app, char* cmd, void* pa, void* ta, int inherit, unsigned long flags,
            void* env, const char* dir, COLTG_SI* si, COLTG_PI* pi);
        unsigned long WaitForSingleObject(void* h, unsigned long ms);
        int CloseHandle(void* h);
        int GetExitCodeProcess(void* h, unsigned long* code);
    ]])
    TG.procs = {}

    function TG.curlPath()
        if TG.curl == nil then
            local root = os.getenv('SystemRoot') or 'C:\\Windows'
            local p = root .. '\\System32\\curl.exe'
            TG.curl = doesFileExist(p) and p or false
        end
        return TG.curl
    end

    -- запускает curl без окна; bodyPath - файл с телом POST; возвращает handle процесса или nil
    function TG.curlStart(url, path, bodyPath)
        local exe = TG.curlPath()
        if not exe then return nil end
        local ok, h = pcall(function()
            local cmd = '"' .. exe .. '" -s --ssl-no-revoke -m 30'
            if bodyPath then cmd = cmd .. ' -X POST -H "Content-Type: application/json" --data-binary "@' .. bodyPath .. '"' end
            cmd = cmd .. ' -o "' .. path .. '" "' .. url .. '"'
            local si, pi = ffi.new('COLTG_SI'), ffi.new('COLTG_PI')
            si.cb = ffi.sizeof(si)
            si.dwFlags, si.wShowWindow = 1, 0                    -- STARTF_USESHOWWINDOW + SW_HIDE
            local buf = ffi.new('char[?]', #cmd + 1)
            ffi.copy(buf, cmd)
            if ffi.C.CreateProcessA(nil, buf, nil, nil, 0, 0x08000000, nil, nil, si, pi) == 0 then return nil end     -- CREATE_NO_WINDOW
            ffi.C.CloseHandle(pi.hThread)
            return pi.hProcess
        end)
        return ok and h or nil
    end

    lua_thread.create(function()
        while true do
            wait(40)
            local procs = TG.procs
            for i = #procs, 1, -1 do
                local p = procs[i]
                local finished = ffi.C.WaitForSingleObject(p.h, 0) == 0
                if finished or os.clock() - p.t0 > 45 then
                    local code = ffi.new('unsigned long[1]', 259)         -- 259 - процесс не завершился (таймаут)
                    if finished then ffi.C.GetExitCodeProcess(p.h, code) end
                    ffi.C.CloseHandle(p.h)
                    table.remove(procs, i)
                    local f = io.open(p.path, 'rb')
                    local txt
                    if f then
                        txt = f:read('*a')
                        f:close()
                    end
                    pcall(os.remove, p.path)
                    if p.body then pcall(os.remove, p.body) end
                    pcall(p.cb, txt ~= nil and txt ~= '', txt, tonumber(code[0]))
                end
            end
        end
    end)

    -- запасной путь для GET
    pcall(function()
        local dir = FNT.filesDir()
        local h, name = findFirstFile(dir .. '\\tg_*.tmp')
        local old = {}
        while name do
            old[#old + 1] = name
            name = findNextFile(h)
        end
        if h then findClose(h) end
        for _, n in ipairs(old) do os.remove(dir .. '\\' .. n) end
    end)

    function TG.getDownload(url, path, cb)
        local okM, ml = pcall(require, 'moonloader')
        if not okM or not ml.download_status then cb(false) return end
        local okD = pcall(downloadUrlToFile, url, path, function(id, status)
            if status ~= ml.download_status.STATUSEX_ENDDOWNLOAD then return end
            local f = io.open(path, 'rb')
            local txt
            if f then
                txt = f:read('*a')
                f:close()
                pcall(os.remove, path)
            end
            cb(txt ~= nil and txt ~= '', txt)
        end)
        if not okD then cb(false) end
    end

    function TG.get(url, cb)
        TG.seq = TG.seq + 1
        pcall(FNT.ensureFilesDir)
        local sep = url:find('?', 1, true) and '&' or '?'
        local full = url .. sep .. '_=' .. os.time() .. TG.seq
        local path = FNT.filesDir() .. '\\tg_resp_' .. os.time() .. '_' .. TG.seq .. '.tmp'
        local h = TG.curlStart(full, path)
        if h then
            TG.procs[#TG.procs + 1] = {h = h, path = path, cb = cb, t0 = os.clock()}
        else
            TG.getDownload(full, path, cb)
        end
    end

    -- POST с JSON-телом (тело передаётся через временный файл, чтобы не упираться в длину командной строки)
    function TG.post(url, body, cb)
        TG.seq = TG.seq + 1
        pcall(FNT.ensureFilesDir)
        local stamp = os.time() .. '_' .. TG.seq
        local bodyPath = FNT.filesDir() .. '\\tg_body_' .. stamp .. '.tmp'
        local f = io.open(bodyPath, 'wb')
        if not f then cb(false) return end
        f:write(body)
        f:close()
        local path = FNT.filesDir() .. '\\tg_resp_' .. stamp .. '.tmp'
        local h = TG.curlStart(url, path, bodyPath)
        if h then
            TG.procs[#TG.procs + 1] = {h = h, path = path, cb = cb, t0 = os.clock(), body = bodyPath}
        else
            pcall(os.remove, bodyPath)
            cb(false)
        end
    end

    local function decode(txt)
        if not txt then return nil end
        local ok, d = pcall(decodeJson, txt)
        return (ok and type(d) == 'table') and d or nil
    end

    -- ---------- вызов метода Bot API (через Worker или напрямую) ----------
    TG.WITH_CHAT = {sendMessage = true, editMessageText = true, editMessageReplyMarkup = true, deleteMessage = true, sendChatAction = true}

    -- cb(ok, ответ Telegram или nil, текст ошибки)
    function TG.call(method, params, cb)
        local url, body
        params = params or {}
        if TG.mode() == 0 then
            url = TG.base() .. '/call?key=' .. enc(TG.cfg.key)
            body = encodeJson({method = method, params = params})
        else
            if TG.WITH_CHAT[method] then params.chat_id = TG.cfg.chat end
            url = TG.API .. '/bot' .. TG.cfg.token .. '/' .. method
            body = encodeJson(params)
        end
        TG.post(url, body, function(ok, txt)
            local d = ok and decode(txt) or nil
            if not d then cb(false, nil, 'No response') return end
            if d.ok == true then cb(true, d) return end
            cb(false, d, tostring(d.error or d.description or 'Error'))
        end)
    end

    -- ---------- очередь исходящих сообщений ----------
    function TG.enqueue(item, important)
        if not important and #TG.outQ >= 80 then return end
        TG.outQ[#TG.outQ + 1] = item
    end

    local function chunks(s, max)                 -- разбиение длинного текста (UTF-8) на части для Telegram
        local out = {}
        while #s > max do
            local cut = s:sub(1, max):match('^.*()\n')
            if not cut or cut < max * 0.5 then
                cut = max
                while cut > 1 do
                    local b = s:byte(cut + 1)
                    if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
                end
            end
            out[#out + 1] = s:sub(1, cut)
            s = s:sub(cut + 1):gsub('^\n', '')
        end
        if #s > 0 then out[#out + 1] = s end
        return out
    end

    -- text - строка CP1251; o = {emoji, markup, important}
    function TG.say(text, o)
        o = o or {}
        text = tostring(text)
        if text == '' or not TG.ready() then return end
        if not o.force and not B('tg_recv', false)[0] then return end      -- Telegram выключен переключателем: ничего не отправляем
        local parts = chunks((o.emoji and (o.emoji .. ' ') or '') .. u8(text), 3500)
        for i, part in ipairs(parts) do
            local p = {text = part, disable_web_page_preview = true}
            if o.markup and i == #parts then p.reply_markup = o.markup end
            TG.enqueue({method = 'sendMessage', params = p, force = o.force}, o.important)
        end
    end

    lua_thread.create(function()
        while true do
            wait(100)
            if #TG.outQ > 0 and not TG.outBusy and os.clock() >= TG.sendAt and TG.ready() then
                local item = table.remove(TG.outQ, 1)
                if not item.force and not B('tg_recv', false)[0] then item = nil end       -- выключили Telegram, пока сообщение стояло в очереди
                if item then
                TG.outBusy = true
                TG.call(item.method, item.params, function(ok, d, err)
                    TG.outBusy = false
                    TG.sendAt = os.clock() + 0.35
                    if not ok and d and tonumber(d.error_code) == 429 then          -- слишком часто: пауза и повтор
                        local ra = tonumber(d.parameters and d.parameters.retry_after) or 3
                        TG.sendAt = os.clock() + ra + 0.5
                        table.insert(TG.outQ, 1, item)
                    elseif not ok and item.method == 'sendMessage' and os.clock() > (TG.errAt or 0) then
                        TG.errAt = os.clock() + 30
                        NotifyErr('Telegram: %s', tr(err))
                    end
                end)
                end
            end
        end
    end)

    -- ---------- клавиатура ----------
    TG.BUTTONS = {            -- {эмодзи, английская подпись, русская подпись, команда, право}
        {'info', 'Status', 'Статус', '/status'}, {'pin', 'Position', 'Позиция', '/pos'}, {'chat', 'Chat', 'Чат', '/chat'},
        {'dlg', 'Dialog', 'Диалог', '/dialog', 'tg_allow_dialog'}, {'dlg', 'All dialogs', 'Все диалоги', '/dialogs', 'tg_allow_dialog'},
        {'key', 'Keys', 'Клавиши', '/keys', 'tg_allow_keys'},
        {'gear', 'Settings', 'Настройки', '/settings'}, {'money', 'Taxes', 'Налоги', '/taxpay', 'tg_allow_taxpay'},
        {'help', 'Help', 'Помощь', '/help'}, {'re', 'Reconnect', 'Перезаход', '/reconnect', 'tg_allow_power'},
    }
    TG.ALLOW_DEF = {tg_allow_say = true, tg_allow_keys = true, tg_allow_dialog = true, tg_allow_power = false, tg_allow_taxpay = true}

    function TG.allowed(key) return B(key, TG.ALLOW_DEF[key])[0] end

    -- обычная клавиатура Telegram (остаётся под полем ввода); подписи на текущем языке, команды понимаются на обоих
    function TG.keyboard()
        TG.KB = {}
        local ru = i18n.curLang == 'ru'
        local rows, row = {}, {}
        for _, b in ipairs(TG.BUTTONS) do
            local en, rus = EM[b[1]] .. ' ' .. b[2], EM[b[1]] .. ' ' .. u8(b[3])
            TG.KB[en], TG.KB[rus] = b[4], b[4]
            if not b[5] or TG.allowed(b[5]) then
                row[#row + 1] = {text = ru and rus or en}
                if #row == 3 then rows[#rows + 1], row = row, {} end
            end
        end
        if #row > 0 then rows[#rows + 1] = row end
        return {keyboard = rows, resize_keyboard = true, is_persistent = true}
    end

    function TG.sendKeyboard()
        if not TG.ready() then NotifyErr('Fill in the Telegram settings first') return end
        TG.say(T('Collapse Telegram control is ready. Use the buttons below.'), {emoji = EM.game, markup = TG.keyboard(), important = true, force = true})
        Notify('Keyboard sent to Telegram')
    end

    -- ---------- команды ----------
    local H = {}
    TG.H = H
    TG.HELP_EN = 'Commands:\n/status - character and server state\n/pos - coordinates\n/chat [N] - last N chat lines\n/say text - write to the chat (/say /command - run a command)\n/key KEY [ms] - press a key: Y, N, F, ALT, ENTER, F6...\n/keys - key panel\n/dialog - show the active dialog\n/d 1|0 [number or text] - answer a dialog (1 - left button, 0 - right button)\n/chaton, /chatoff - forward the whole chat\n/dialogs, /dialogson, /dialogsoff - forward all dialogs\n/reconnect - reconnect to the server\n/settings - forwarding settings (switches)\n/taxpay - pay all taxes through the phone\n/exit yes - close the game'

    local VK = {ENTER = 0x0D, ESC = 0x1B, SPACE = 0x20, TAB = 0x09, SHIFT = 0x10, CTRL = 0x11, ALT = 0x12, BACK = 0x08,
                UP = 0x26, DOWN = 0x28, LEFT = 0x25, RIGHT = 0x27, DEL = 0x2E, INSERT = 0x2D, HOME = 0x24, END = 0x23,
                PGUP = 0x21, PGDN = 0x22}
    for i = 0, 9 do VK[tostring(i)] = 0x30 + i end
    for i = 0, 25 do VK[string.char(65 + i)] = 0x41 + i end
    for i = 1, 12 do VK['F' .. i] = 0x6F + i end

    -- Нажатие клавиши двумя путями: setVirtualKeyDown (для скриптов и опроса клавиш) и сообщения WM_KEYDOWN / WM_KEYUP окну игры
    -- (так клавиши получают интерфейсы Arizona и SA-MP; работает и тогда, когда окно игры не в фокусе).
    pcall(ffi.cdef, [[
        int PostMessageA(void* hWnd, unsigned int Msg, size_t wParam, size_t lParam);
        unsigned int MapVirtualKeyA(unsigned int code, unsigned int mapType);
    ]])
    TG.EXT = {[0x26] = true, [0x28] = true, [0x25] = true, [0x27] = true, [0x2D] = true, [0x2E] = true,
              [0x24] = true, [0x23] = true, [0x21] = true, [0x22] = true}

    function TG.postKey(vk, down)
        pcall(function()
            local hwnd = ffi.cast('void**', 0xC97C1C)[0]               -- окно GTA SA
            if hwnd == nil then return end
            local lp = 1 + ffi.C.MapVirtualKeyA(vk, 0) * 65536 + (TG.EXT[vk] and 16777216 or 0)
            local sys = (vk == 0x12)                                   -- ALT идёт сообщениями WM_SYSKEY*
            if down then
                ffi.C.PostMessageA(hwnd, sys and 0x104 or 0x100, vk, lp + (sys and 536870912 or 0))
            else
                ffi.C.PostMessageA(hwnd, sys and 0x105 or 0x101, vk, lp + 3221225472 + (sys and 536870912 or 0))
            end
        end)
    end

    function TG.pressKey(vk, ms)                  -- ms - миллисекунды
        pcall(setVirtualKeyDown, vk, true)
        TG.postKey(vk, true)
        TG.held[vk] = true
        lua_thread.create(function()
            wait(ms)
            pcall(setVirtualKeyDown, vk, false)
            TG.postKey(vk, false)
            TG.held[vk] = nil
        end)
    end

    function TG.denied(what) TG.say(T('Disabled in the Telegram settings: %s', what), {emoji = EM.warn}) end

    local function myInfo()
        local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if ok then return id, sampGetPlayerNickname(id) end
    end

    function TG.statusText()
        local L = {}
        local id, nick = myInfo()
        if id then
            L[#L + 1] = T('Nickname: %s [%d]', nick, id)
            L[#L + 1] = T('Ping: %d, score: %d', sampGetPlayerPing(id), sampGetPlayerScore(id))
            L[#L + 1] = T('HP: %d, armor: %d', getCharHealth(PLAYER_PED), getCharArmour(PLAYER_PED))
            local x, y, z = getCharCoordinates(PLAYER_PED)
            L[#L + 1] = T('Position: %.1f, %.1f, %.1f (interior %d)', x, y, z, getActiveInterior())
            if isCharInAnyCar(PLAYER_PED) then
                local car = storeCarCharIsInNoSave(PLAYER_PED)
                L[#L + 1] = T('Vehicle: model %d, HP %d', getCarModel(car), getCarHealth(car))
            else
                L[#L + 1] = T('Vehicle: none')
            end
            local ip, port = sampGetCurrentServerAddress()
            L[#L + 1] = T('Server: %s (%s:%s)', sampGetCurrentServerName(), ip, tostring(port))
        else
            L[#L + 1] = T('Not in the game (not connected or not spawned yet)')
        end
        local okf, fps = pcall(getFramerate)
        if okf and fps then L[#L + 1] = T('FPS: %d', math.floor(fps + 0.5)) end
        if id then
            local alive = ctl.alive and ctl.alive()
            L[#L + 1] = T('State: %s', alive and T('alive') or (sampIsLocalPlayerSpawned() and T('dead') or T('not spawned')))
        end
        if sampIsDialogActive() then
            local did, cap = sampGetCurrentDialogId(), ''
            local d = TG.lastDialog
            if d and d.id == did then
                cap = d.title
            else
                local okc, c = pcall(sampGetDialogCaption)
                cap = okc and stripColors(c) or ''
            end
            L[#L + 1] = T('Dialog: #%d "%s" (open)', did, clip(cap, 60))
        else
            L[#L + 1] = T('Dialog: none open')
        end
        local function onoff(v) return v and T('on') or T('off') end
        L[#L + 1] = T('Forwarding: chat %s, dialogs %s', onoff(B('tg_fwd_chat', false)[0]), onoff(B('tg_fwd_dialog', false)[0]))
        return table.concat(L, '\n')
    end

    H.start = function() TG.say(T('Collapse Telegram control is ready. Use the buttons below.'), {emoji = EM.game, markup = TG.keyboard()}) end
    H.help = function() TG.say(T(TG.HELP_EN), {markup = TG.keyboard()}) end

    H.status = function()
        local ok, s = pcall(TG.statusText)
        TG.say(ok and s or tostring(s), {emoji = EM.info})
    end

    H.pos = function()
        local x, y, z = getCharCoordinates(PLAYER_PED)
        TG.say(T('x=%.2f  y=%.2f  z=%.2f\nInterior: %d, heading: %.0f', x, y, z, getActiveInterior(), getCharHeading(PLAYER_PED)), {emoji = EM.pin})
    end

    H.chat = function(arg)
        local n = clamp(tonumber(arg:match('%d+')) or 15, 1, 40)
        local buf = TG.chatBuf
        if #buf == 0 then return TG.say(T('No chat lines yet'), {emoji = EM.chat}) end
        local out = {}
        for i = math.max(1, #buf - n + 1), #buf do out[#out + 1] = buf[i] end
        TG.say(table.concat(out, '\n'), {emoji = EM.chat})
    end

    H.say = function(arg)
        if not TG.allowed('tg_allow_say') then return TG.denied('/say') end
        arg = trim(arg)
        if arg == '' then return TG.say(T('Use: /say text or /say /command')) end
        if #arg > 140 then arg = arg:sub(1, 140) end
        sampSendChat(arg)
        TG.say(T('Sent: %s', arg), {emoji = EM.ok})
    end

    H.cmd = function(arg)
        arg = trim(arg):gsub('^/', '')
        H.say('/' .. arg)
    end

    H.key = function(arg)
        if not TG.allowed('tg_allow_keys') then return TG.denied('/key') end
        local name, ms = arg:match('^(%S+)%s*(%d*)')
        local vk = name and VK[name:upper()]
        if not vk then return TG.say(T('Use: /key KEY [ms]. Examples: /key Y, /key ALT 300, /key F6')) end
        ms = clamp(tonumber(ms) or 120, 30, 5000)
        TG.pressKey(vk, ms)
        TG.say(T('Key %s pressed for %d ms', name:upper(), ms), {emoji = EM.ok})
    end

    H.keys = function()
        if not TG.allowed('tg_allow_keys') then return TG.denied('/keys') end
        local function k(n) return {text = n, callback_data = 'k:' .. n} end
        TG.say(T('Press a key:'), {emoji = EM.key, markup = {inline_keyboard = {
            {k('Y'), k('N'), k('F'), k('H')},
            {k('ALT'), k('ENTER'), k('ESC'), k('SPACE')},
            {k('UP'), k('DOWN'), k('LEFT'), k('RIGHT')},
            {k('1'), k('2'), k('3'), k('4')},
            {k('F6'), k('F7'), k('TAB'), k('SHIFT')},
        }}})
    end

    -- диалоги
    local function isList(st) return st == 2 or st == 4 or st == 5 end

    local function splitLines(s)
        s = tostring(s):gsub('\r', '')
        local out, pos = {}, 1
        while true do
            local nl = s:find('\n', pos, true)
            if not nl then out[#out + 1] = s:sub(pos) break end
            out[#out + 1] = s:sub(pos, nl - 1)
            pos = nl + 1
        end
        if out[#out] == '' then table.remove(out) end
        return out
    end

    function TG.makeDialog(id, style, title, b1, b2, text)
        local d = {id = id, style = style, title = stripColors(title or ''), b1 = stripColors(b1 or ''),
                   b2 = stripColors(b2 or ''), text = text or '', items = {}}
        if isList(style) then
            local lines = splitLines(d.text)
            if style == 5 and #lines > 0 then d.header = (stripColors(table.remove(lines, 1)):gsub('\t', ' | ')) end
            for _, ln in ipairs(lines) do
                d.items[#d.items + 1] = trim((stripColors(ln):gsub('\t', ' | ')))
            end
        end
        return d
    end

    function TG.dialogText(d)
        local L = {T('Dialog #%d: %s', d.id, d.title)}
        if isList(d.style) then
            if d.header then L[#L + 1] = d.header end
            L[#L + 1] = T('Items: %d. Press an item below (or /d 1 number).', #d.items)
            if #d.items > 40 then L[#L + 1] = T('Only the first 40 items are shown, the rest: /d 1 number') end
        else
            L[#L + 1] = stripColors(d.text)
            if d.style == 1 or d.style == 3 then L[#L + 1] = T('Enter text: /d 1 text') end
        end
        return table.concat(L, '\n')
    end

    function TG.dialogMarkup(d)
        local rows = {}
        if isList(d.style) then
            for i, it in ipairs(d.items) do
                if i > 40 then break end
                rows[#rows + 1] = {{text = u8(string.format('%d. %s', i - 1, clip(it, 48))), callback_data = string.format('d:%d:i%d', d.id, i - 1)}}
            end
        end
        local last = {}
        if d.b1 ~= '' then last[#last + 1] = {text = u8(clip(d.b1, 24)), callback_data = string.format('d:%d:b1', d.id)} end
        if d.b2 ~= '' then last[#last + 1] = {text = u8(clip(d.b2, 24)), callback_data = string.format('d:%d:b0', d.id)} end
        if #last > 0 then rows[#rows + 1] = last end
        if #rows == 0 then return nil end
        return {inline_keyboard = rows}
    end

    function TG.respondDialog(button, item, input)
        if not sampIsDialogActive() then return false, T('No active dialog.') end
        local id, style = sampGetCurrentDialogId(), sampGetCurrentDialogType()
        local list = isList(style)
        if item and list then pcall(sampSetCurrentDialogListItem, item) end
        if input and (style == 1 or style == 3) then pcall(sampSetCurrentDialogEditboxText, input) end
        pcall(sampCloseCurrentDialogWithButton, button)
        TG.followUntil = os.clock() + 8                       -- ответили из Telegram: следующий диалог придёт в Telegram сразу
        lua_thread.create(function()
            wait(300)
            if sampIsDialogActive() and sampGetCurrentDialogId() == id then      -- окно не закрылось: отвечаем серверу напрямую
                local d = TG.lastDialog
                local text = input or ''
                if list and item and d and d.id == id and d.items[item + 1] then text = d.items[item + 1] end
                pcall(sampSendDialogResponse, id, button, (list and item) or -1, text)
                pcall(sampCloseCurrentDialogWithButton, button)
            end
        end)
        return true
    end

    H.dialog = function()
        local d = TG.lastDialog
        if not sampIsDialogActive() or not d or d.id ~= sampGetCurrentDialogId() then
            return TG.say(T('No active dialog.'), {emoji = EM.dlg})
        end
        TG.say(TG.dialogText(d), {emoji = EM.dlg, markup = TG.dialogMarkup(d)})
    end

    H.d = function(arg)
        if not TG.allowed('tg_allow_dialog') then return TG.denied('/d') end
        local b, rest = arg:match('^([01])%s*(.*)$')
        if not b then return TG.say(T('Use: /d 1 [item number or text]  or  /d 0')) end
        local style = sampIsDialogActive() and sampGetCurrentDialogType() or -1
        local item, input
        if isList(style) then item = tonumber(rest:match('^(%d+)'))
        elseif rest ~= '' then input = rest end
        local ok, err = TG.respondDialog(tonumber(b), item, input)
        TG.say(ok and T('Reply sent') or err, {emoji = ok and EM.ok or EM.err})
    end

    H.chaton = function() B('tg_fwd_chat', false)[0] = true; TG.say(T('Chat forwarding enabled'), {emoji = EM.ok}) end
    H.chatoff = function() B('tg_fwd_chat', false)[0] = false; TG.say(T('Chat forwarding disabled'), {emoji = EM.ok}) end
    H.dialogson = function() B('tg_fwd_dialog', false)[0] = true; TG.say(T('Forwarding of all dialogs enabled'), {emoji = EM.ok}) end
    H.dialogsoff = function() B('tg_fwd_dialog', false)[0] = false; TG.say(T('Forwarding of all dialogs disabled'), {emoji = EM.ok}) end
    H.dialogs = function() if B('tg_fwd_dialog', false)[0] then H.dialogsoff() else H.dialogson() end end

    -- /settings: состояние и переключение первых четырёх настроек пересылки (кнопки под сообщением)
    TG.SETS = {
        {'tg_fwd_mention', true, 'Mentions of you', 'mention'},
        {'tg_fwd_chat', false, 'All chat lines', 'chat'},
        {'tg_fwd_dialog', false, 'All dialogs', 'dialogs'},
        {'tg_notify_conn', true, 'Connection and spawn notifications', 'conn'},
    }

    function TG.settingsText()
        local L = {T('Telegram settings:')}
        for _, s in ipairs(TG.SETS) do L[#L + 1] = (B(s[1], s[2])[0] and '[+] ' or '[-] ') .. T(s[3]) end
        L[#L + 1] = T('Keywords: %d', #WORDS.get('tg_keywords'))
        L[#L + 1] = T('Tap a button to switch.')
        return table.concat(L, '\n')
    end

    function TG.settingsMarkup()
        local rows = {}
        for _, s in ipairs(TG.SETS) do
            rows[#rows + 1] = {{text = (B(s[1], s[2])[0] and EM.ok or EM.err) .. ' ' .. u8(T(s[3])), callback_data = 's:' .. s[4]}}
        end
        return {inline_keyboard = rows}
    end

    H.settings = function() TG.say(TG.settingsText(), {emoji = EM.gear, markup = TG.settingsMarkup()}) end

    -- /taxpay: телефон -> банк (CEF) -> диалог со списком (пункт "оплатить все налоги") -> диалог подтверждения -> закрыть телефон.
    -- Последовательность и диалоги взяты из autopay.lua (только оплата налогов). Диалоги оплаты скрываются и отвечаются автоматически.
    TG.TAX = {BANK = 6565, CONFIRM = 15252, ITEM = 4}

    local function cefSend(msg)                                -- пакет CEF: [220][18][длина][0][текст][int32 0]
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt8(bs, 220)
        raknetBitStreamWriteInt8(bs, 18)
        raknetBitStreamWriteInt8(bs, #msg)
        raknetBitStreamWriteInt8(bs, 0)
        raknetBitStreamWriteString(bs, msg)
        raknetBitStreamWriteInt32(bs, 0)
        raknetSendBitStreamEx(bs, 1, 7, 1)
        raknetDeleteBitStream(bs)
    end

    local function openPhone()
        local bs = raknetNewBitStream()
        for _, b in ipairs({220, 0, 80, 64}) do raknetBitStreamWriteInt8(bs, b) end
        raknetSendBitStreamEx(bs, 1, 7, 1)
        raknetDeleteBitStream(bs)
    end

    function TG.money(n)                                         -- 1234567 -> 1.234.567
        local s = string.format('%.0f', n)
        return (s:reverse():gsub('(%d%d%d)', '%1.'):reverse():gsub('^%.', ''))
    end

    -- сообщение сервера об оплате (формат из autopay.lua): "Вы оплатили все налоги на сумму: $1.234.567"
    function TG.taxMessage(text)
        local run = TG.tax
        if not run or (run.state ~= 'pay' and run.state ~= 'wait_result') then return end
        local clear = (stripColors(text):gsub(':u%x+:', ''):gsub(':CASH:', ''))
        if clear:match('^Вы оплатили все налоги на сумму:') then
            local amount = clear:match('на сумму:%s*[^%d]*(%d[%d%. ,]*)')
            run.paid = true
            run.amount = amount and tonumber((amount:gsub('[^%d]', ''))) or nil
        end
    end

    function TG.taxFinish(run, ok, msg)
        if TG.tax ~= run then return end
        TG.tax = nil
        if run.owned and not sampIsDialogActive() then pcall(sampSendChat, '/phone') end        -- закрываем телефон, только если банк открывали мы
        TG.say(msg, {emoji = ok and EM.ok or EM.err, important = true})
    end

    -- возвращает true, если диалог относится к оплате (его надо скрыть)
    function TG.taxDialog(id, text)
        local run = TG.tax
        if not run then return false end
        if id == TG.TAX.BANK and run.state == 'bank' then
            run.state, run.owned = 'select', true
            lua_thread.create(function()
                wait(400)
                if TG.tax ~= run then return end
                run.state = 'confirm'
                sampSendDialogResponse(TG.TAX.BANK, 1, TG.TAX.ITEM, '')          -- клик 1: оплатить все налоги
            end)
            return true
        end
        if id == TG.TAX.CONFIRM and run.state == 'confirm' then
            run.state = 'pay'
            lua_thread.create(function()
                wait(400)
                if TG.tax ~= run then return end
                sampSendDialogResponse(TG.TAX.CONFIRM, 1, -1, '')                -- клик 2: подтвердить
                run.state = 'wait_result'
                local t0 = os.clock()                                            -- ждём сообщение сервера "Вы оплатили все налоги на сумму: ..."
                while TG.tax == run and not run.paid and os.clock() - t0 < 6 do wait(100) end
                if run.paid then
                    TG.taxFinish(run, true, T('Taxes paid: %s', run.amount and ('$' .. TG.money(run.amount)) or T('amount not recognized')))
                else
                    TG.taxFinish(run, false, T('The request was sent, but the server did not confirm the payment. Check in the game.'))
                end
            end)
            return true
        end
        if id == 0 and run.state == 'confirm' and stripColors(text):find('У Вас нет налогов', 1, true) then
            run.state = 'none'
            lua_thread.create(function()
                wait(300)
                if TG.tax ~= run then return end
                sampSendDialogResponse(0, 1, -1, '')
                wait(700)
                TG.taxFinish(run, true, T('You have no taxes to pay'))
            end)
            return true
        end
        return false
    end

    H.taxpay = function()
        if not TG.allowed('tg_allow_taxpay') then return TG.denied('/taxpay') end
        if TG.tax then return TG.say(T('Tax payment is already running'), {emoji = EM.warn}) end
        if not (ctl.alive and ctl.alive()) then return TG.say(T('You must be alive and spawned'), {emoji = EM.warn}) end
        if sampIsDialogActive() or sampIsChatInputActive() then return TG.say(T('Close the dialog or the chat input first'), {emoji = EM.warn}) end
        local run = {state = 'bank'}
        TG.tax = run
        TG.say(T('Paying taxes: opening the phone...'), {emoji = EM.info})
        lua_thread.create(function()
            local ok, err = pcall(function()
                openPhone()
                wait(500)
                for _ = 1, 3 do                                                    -- запрос на открытие банка повторяется, пока не придёт диалог
                    if TG.tax ~= run or run.state ~= 'bank' then break end
                    cefSend('launchedApp|24')
                    wait(1000)
                end
                if TG.tax == run and run.state == 'bank' then
                    TG.taxFinish(run, false, T('The bank did not open (the phone may stay open)'))
                    return
                end
                local t0 = os.clock()
                while TG.tax == run and os.clock() - t0 < 20 do wait(100) end      -- дальше идут диалоги (TG.taxDialog)
                if TG.tax == run then TG.taxFinish(run, false, T('Tax payment timed out')) end
            end)
            if not ok then
                print('[COLLAPSE] Telegram /taxpay: ' .. tostring(err))
                TG.taxFinish(run, false, T('Command failed: %s', tostring(err)))
            end
        end)
    end

    -- спавн: уведомление входит в "Уведомления о подключении"
    lua_thread.create(function()
        repeat wait(1000) until isSampAvailable()
        local okS, was = pcall(sampIsLocalPlayerSpawned)
        was = okS and was == true
        while true do
            wait(500)
            local ok, sp = pcall(sampIsLocalPlayerSpawned)
            sp = ok and sp == true
            if sp and not was and TG.ready() and B('tg_notify_conn', true)[0] and os.clock() > (TG.spawnAt or 0) then
                TG.spawnAt = os.clock() + 5
                local id, nick = myInfo()
                TG.say(T('Spawned in the game: %s [%d]', nick or '?', id or -1), {emoji = EM.game, important = true})
            end
            was = sp
        end
    end)

    H.reconnect = function()
        if not TG.allowed('tg_allow_power') then return TG.denied('/reconnect') end
        local ip, port = sampGetCurrentServerAddress()
        TG.say(T('Reconnecting to %s:%s', ip, tostring(port)), {emoji = EM.re, important = true})
        if ctl.uc and ctl.uc.reconnect then ctl.uc.reconnect(2) end
    end

    H.exit = function(arg)
        if not TG.allowed('tg_allow_power') then return TG.denied('/exit') end
        if trim(arg):lower() ~= 'yes' then return TG.say(T('Exit the game? Confirm: /exit yes'), {emoji = EM.warn}) end
        TG.say(T('Closing the game...'), {emoji = EM.ok, important = true})
        lua_thread.create(function()
            wait(4000)
            sampProcessChatInput('/q')
        end)
    end

    function TG.runCommand(text)                  -- text - CP1251, начинается с '/'
        local cmd, arg = text:match('^/([%w_]+)[@%w_]*%s*(.*)$')
        if not cmd then return end
        cmd = cmd:lower()
        local h = H[cmd]
        if not h then return TG.say(T('Unknown command /%s. List: /help', cmd)) end
        local ok, err = pcall(h, arg)
        if not ok then
            print('[COLLAPSE] Telegram /' .. cmd .. ': ' .. tostring(err))
            TG.say(T('Command failed: %s', tostring(err)), {emoji = EM.err})
        end
    end

    -- нажатие inline-кнопки
    function TG.onCallback(m)
        local function answer(text)
            TG.enqueue({method = 'answerCallbackQuery', params = {callback_query_id = m.id, text = u8(text)}}, true)
        end
        local key = m.data:match('^k:(%w+)$')
        if key then
            if not TG.allowed('tg_allow_keys') then return answer(T('Disabled in the Telegram settings: %s', '/key')) end
            local vk = VK[key]
            if not vk then return answer('?') end
            TG.pressKey(vk, 150)
            return answer(T('Pressed: %s', key))
        end
        local sk = m.data:match('^s:(%a+)$')
        if sk then                                                          -- переключатель настройки из /settings
            for _, s in ipairs(TG.SETS) do
                if s[4] == sk then
                    local p = B(s[1], s[2])
                    p[0] = not p[0]
                    if m.mid then
                        TG.enqueue({method = 'editMessageText', params = {message_id = m.mid, text = EM.gear .. ' ' .. u8(TG.settingsText()),
                            reply_markup = TG.settingsMarkup()}}, true)
                    end
                    return answer(T('Switched: %s - %s', T(s[3]), p[0] and T('on') or T('off')))
                end
            end
            return answer('?')
        end
        local id, kind, n = m.data:match('^d:(%d+):(%a)(%d*)$')
        if not id then return answer('?') end
        if not TG.allowed('tg_allow_dialog') then return answer(T('Disabled in the Telegram settings: %s', '/d')) end
        if not sampIsDialogActive() or sampGetCurrentDialogId() ~= tonumber(id) then return answer(T('No active dialog.')) end
        local ok, err
        if kind == 'i' then ok, err = TG.respondDialog(1, tonumber(n)) else ok, err = TG.respondDialog(tonumber(n)) end
        answer(ok and T('Done') or tostring(err))
        if ok and m.mid then
            TG.enqueue({method = 'editMessageReplyMarkup', params = {message_id = m.mid}}, true)      -- убираем кнопки у отвеченного диалога
        end
    end

    -- ---------- пересылка из игры в Telegram ----------
    function TG.fwdAllowed()
        local now, t = os.clock(), TG.fwdTimes
        while t[1] and now - t[1] > 60 do table.remove(t, 1) end
        if #t >= clamp(F('tg_maxpm', 20)[0], 5, 60) then
            TG.suppressed = TG.suppressed + 1
            return false
        end
        if TG.suppressed > 0 then
            local n = TG.suppressed
            TG.suppressed = 0
            TG.say(T('Skipped %d messages because of the limit', n), {emoji = EM.warn})
        end
        t[#t + 1] = now
        return true
    end

    function TG.shouldForward(line)
        local hot = false
        if B('tg_fwd_mention', true)[0] then
            local _, nick = myInfo()
            if nick and nick ~= '' and lower(line):find(lower(nick), 1, true) then hot = true end
        end
        if not hot then
            local kws = WORDS.get('tg_keywords')                  -- фразы уже в нижнем регистре (CP1251)
            if #kws > 0 then
                local low = lower(line)
                for _, kw in ipairs(kws) do
                    if low:find(kw, 1, true) then hot = true break end
                end
            end
        end
        return B('tg_fwd_chat', false)[0] or hot, hot
    end

    function TG.onChat(line)
        if not TG.ready() then return end
        if TG.tax then TG.taxMessage(line) end
        line = trim(stripColors(line))
        if line == '' then return end
        local buf = TG.chatBuf
        buf[#buf + 1] = os.date('%H:%M ') .. line
        if #buf > 80 then table.remove(buf, 1) end
        if not (B('tg_fwd_chat', false)[0] or B('tg_fwd_mention', true)[0] or #WORDS.get('tg_keywords') > 0) then return end
        local want, hot = TG.shouldForward(line)
        if want and TG.fwdAllowed() then TG.say(line, {emoji = hot and EM.bell or nil}) end
    end

    function TG.onDialog(id, style, title, b1, b2, text)
        if not TG.ready() then return end
        if TG.tax and TG.taxDialog(id, text) then return true end          -- диалоги оплаты налогов: скрываются и в Telegram не уходят
        local d = TG.makeDialog(id, style, title, b1, b2, text)
        TG.lastDialog = d
        local follow = os.clock() < (TG.followUntil or 0)      -- цепочка диалогов после ответа из Telegram
        if B('tg_fwd_dialog', false)[0] or follow then
            if follow then TG.followUntil = os.clock() + 8 end
            TG.say(TG.dialogText(d), {emoji = EM.dlg, markup = TG.dialogMarkup(d), important = true})
        end
    end

    -- пакеты: 34 - подключились к серверу; 32 - сервер закрыл соединение, 33 - потеря связи, 36 - бан
    function TG.onPacket(id)
        if not TG.ready() or not B('tg_notify_conn', true)[0] then return end
        if id == 34 then
            TG.say(T('Connected to the server'), {emoji = EM.ok, important = true})
            return
        end
        local why = (id == 32 and T('server closed the connection')) or (id == 33 and T('connection lost (timeout)')) or T('you are banned')
        local msg = T('Disconnected from the server: %s', why)
        local buf, tail = TG.chatBuf, {}
        for i = math.max(1, #buf - 4), #buf do tail[#tail + 1] = buf[i] end
        if #tail > 0 then msg = msg .. '\n' .. T('Last chat lines:') .. '\n' .. table.concat(tail, '\n') end
        TG.say(msg, {emoji = EM.plug, important = true})
    end

    -- при выгрузке скрипта отпускаем удерживаемые клавиши
    function TG.restore()
        for vk in pairs(TG.held) do pcall(setVirtualKeyDown, vk, false) end
        TG.held = {}
    end

    -- ---------- получение ----------
    -- ответ Worker'а / Telegram -> список обновлений и следующий offset
    function TG.normalize(mode, d)
        local list, nextOff = {}, nil
        if mode == 0 then
            for _, u in ipairs(d.updates or {}) do
                if u.type == 'callback' then
                    list[#list + 1] = {kind = 'cb', id = tostring(u.cb_id or ''), data = tostring(u.data or ''), mid = u.message_id,
                                       from = tostring(u.from or ''), date = u.date}
                else
                    list[#list + 1] = {kind = 'msg', from = tostring(u.from or ''), text = tostring(u.text or ''), date = u.date}
                end
            end
            nextOff = tonumber(d.next)
            if nextOff and nextOff <= 0 then nextOff = nil end
        else
            for _, u in ipairs(d.result or {}) do
                local id = tonumber(u.update_id)
                if id and (not nextOff or id + 1 > nextOff) then nextOff = id + 1 end
                local m, q = u.message, u.callback_query
                if type(m) == 'table' and m.text and type(m.chat) == 'table' and numstr(m.chat.id) == TG.cfg.chat then
                    local fr = type(m.from) == 'table' and m.from or {}
                    list[#list + 1] = {kind = 'msg', from = tostring(fr.username or fr.first_name or ''), text = tostring(m.text), date = m.date}
                end
                if type(q) == 'table' and type(q.message) == 'table' and type(q.message.chat) == 'table'
                    and numstr(q.message.chat.id) == TG.cfg.chat then
                    local fr = type(q.from) == 'table' and q.from or {}
                    list[#list + 1] = {kind = 'cb', id = tostring(q.id), data = tostring(q.data or ''), mid = q.message.message_id,
                                       from = tostring(fr.username or fr.first_name or ''), date = os.time()}
                end
            end
        end
        return list, nextOff
    end

    -- запись в список плитки; toast - ещё и всплывающее уведомление в игре
    function TG.push(m, toast)
        local lag = tonumber(m.date) and math.max(os.time() - m.date, 0) or nil
        table.insert(TG.msgs, 1, {head = '[' .. os.date('%H:%M:%S') .. ']  ' .. m.from .. (lag and ('  (+' .. lag .. ' s)') or ''), text = m.text})
        while #TG.msgs > 100 do table.remove(TG.msgs) end
        TG.received = TG.received + 1
        if not toast then return end
        local okd, shown = pcall(D, m.text)                     -- в тост текст идёт в CP1251
        shown = okd and shown or m.text
        if #shown > 200 then shown = shown:sub(1, 200) .. '...' end
        local okf, who = pcall(D, m.from)
        who = okf and who or m.from
        Notify('Telegram: %s', (who ~= '' and (who .. ': ') or '') .. shown)
    end

    function TG.handle(m)
        if m.kind == 'cb' then
            TG.push({from = m.from, text = '[button] ' .. m.data, date = m.date}, false)
            local ok, err = pcall(TG.onCallback, m)
            if not ok then
                print('[COLLAPSE] Telegram button ' .. m.data .. ': ' .. tostring(err))
                NotifyErr('Telegram: %s', tostring(err))
            end
            return
        end
        TG.keyboard()                                           -- обновляет TG.KB (подписи кнопок -> команды)
        local raw = trim(m.text)
        local cmdText = TG.KB[raw] or raw                       -- нажатая кнопка клавиатуры равна своей команде
        local isCmd = cmdText:sub(1, 1) == '/'
        TG.push(m, not isCmd)
        if isCmd then TG.runCommand(D(cmdText)) end
    end

    function TG.poll()
        TG.busy, TG.busyAt = true, os.clock()
        local mode = TG.mode()
        local off = TG.offset or -1                       -- -1: берём только самое свежее, чтобы определить точку старта
        local wait = (TG.offset == nil) and 0 or 20       -- первый запрос быстрый; дальше длинный опрос: ответ приходит сразу, как только есть сообщение
        local url
        if mode == 0 then
            url = TG.base() .. '/poll?key=' .. enc(TG.cfg.key) .. '&offset=' .. off .. '&wait=' .. wait
        else
            url = TG.API .. '/bot' .. TG.cfg.token .. '/getUpdates?timeout=' .. wait .. '&offset=' .. off
                .. '&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D'
        end
        TG.get(url, function(ok, txt, code)
            TG.busy = false
            if not B('tg_recv', false)[0] then return end                 -- приём выключили, пока шёл запрос
            local d = ok and decode(txt) or nil
            if not d then                                                  -- при ошибке пауза 5 с; в статусе - код curl или начало ответа
                TG.status, TG.nextAt = 'err', os.clock() + 5
                if txt and txt ~= '' then TG.err = 'Bad response: ' .. (txt:sub(1, 60):gsub('%s+', ' '))
                else TG.err = 'No response (curl ' .. tostring(code or '?') .. ')' end
                return
            end
            if d.ok ~= true then TG.status, TG.err, TG.nextAt = 'err', tostring(d.error or d.description or 'Error'), os.clock() + 5 return end
            if mode == 0 and (tonumber(d.v) or 0) < TG.WORKER_VER then
                TG.status, TG.err, TG.nextAt = 'err', 'Update the Worker code', os.clock() + 10
                return
            end
            TG.nextAt = os.clock() + 0.2                                   -- следующий длинный запрос сразу
            local list, nextOff = TG.normalize(mode, d)
            TG.status, TG.err = 'ok', nil
            if TG.offset == nil then TG.offset = nextOff or 0 return end      -- старые сообщения не показываем
            if nextOff then TG.offset = nextOff end
            for _, m in ipairs(list) do TG.handle(m) end
        end)
    end

    lua_thread.create(function()
        repeat wait(1000) until isSampAvailable()
        while true do
            wait(250)
            local on = B('tg_recv', false)[0]
            local mode = TG.mode()
            if mode ~= TG.lastMode then TG.lastMode, TG.offset, TG.nextAt = mode, nil, 0 end
            if on and not TG.wasOn then TG.offset, TG.nextAt = nil, 0 end        -- после включения - только новые сообщения
            TG.wasOn = on
            if not on then
                TG.status = 'off'
            elseif not TG.ready() then
                TG.status, TG.err = 'err', 'Not configured'
            else
                if TG.status == 'off' or TG.err == 'Not configured' then TG.status, TG.err = 'wait', nil end
                local now = os.clock()
                if (not TG.busy or now - TG.busyAt > 45) and now >= TG.nextAt then
                    pcall(TG.poll)                                        -- следующий запуск назначает ответ на запрос
                end
            end
        end
    end)

    -- ---------- тестовое сообщение ----------
    function TG.sendTest()
        if TG.sync() then TG.save() end
        if not TG.ready() then NotifyErr('Fill in the Telegram settings first') return end
        local nick = (me.nick and me.nick ~= '') and me.nick or 'player'
        local t0 = os.clock()
        TG.call('sendMessage', {text = EM.ok .. ' ' .. u8('Collapse: test message from ' .. nick), reply_markup = TG.keyboard()}, function(ok, d, err)
            local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
            if ok then NotifyOk('Test message sent: %d ms', ms) else NotifyErr('Telegram: %s', tr(err)) end
        end)
    end

    -- ---------- страница ----------
    local function ConnBody()
        Combo('Connection method', I('tg_mode', 0), {'Cloudflare Worker', 'Telegram API (direct)'})
        local mode = TG.mode()
        if mode == 0 then
            TextRow('Worker URL', TG.buf('url'), TG.apply, nil, nil, 170)
            TextRow('Access key', TG.buf('key'), TG.apply, nil, nil, 170)
        else
            TextRow('Bot token', TG.buf('token'), TG.apply, nil, nil, 170)
            TextRow('Chat ID', TG.buf('chat'), TG.apply, nil, nil, 170)
        end
        imgui.Dummy(imgui.ImVec2(1, 4))
        if Button('Send test message', 34, true) then TG.sendTest() end
        if mode == 0 and Button('Copy Worker code', 34) then
            setClipboardText(TG.WORKER_JS)
            NotifyOk('Worker code copied to the clipboard')
        end
    end

    local function MsgBody()
        if SRCH.collecting then return end
        local st = TG.status
        local label
        if st == 'off' then label = tr('Off')
        elseif st == 'wait' then label = tr('Connecting...')
        elseif st == 'ok' then label = tr('Connected')
        else label = tr('Error') .. ': ' .. tr(TG.err or '?') end
        InfoRow('Status', label)
        InfoRow('Received', tostring(TG.received))
        imgui.Dummy(imgui.ImVec2(1, 4))
        local avail = imgui.GetContentRegionAvail()
        imgui.BeginChild('##tg_list', imgui.ImVec2(avail.x, avail.y), false)
        if #TG.msgs == 0 then
            Text('No messages yet. Write to your bot in Telegram.', pal.dim)
        else
            for _, m in ipairs(TG.msgs) do
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(pal.dim[1], pal.dim[2], pal.dim[3], gfx.galpha))
                imgui.TextWrapped(m.head)
                imgui.PopStyleColor()
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(pal.text[1], pal.text[2], pal.text[3], gfx.galpha))
                imgui.TextWrapped(m.text)
                imgui.PopStyleColor()
                imgui.Dummy(imgui.ImVec2(1, 4))
            end
        end
        imgui.EndChild()
    end

    local function ControlBody()
        Checkbox('Forward mentions of you', B('tg_fwd_mention', true))
        Checkbox('Forward all chat lines', B('tg_fwd_chat', false))
        WORDS.row('Keywords', 'tg_keywords')
        Checkbox('Forward dialogs', B('tg_fwd_dialog', false))
        Checkbox('Connection notifications', B('tg_notify_conn', true))
        Slider('Messages per minute', F('tg_maxpm', 20), 5, 60, '%d', true)
        imgui.Dummy(imgui.ImVec2(1, 4))
        Checkbox('Allow /say and commands', B('tg_allow_say', true))
        Checkbox('Allow key presses', B('tg_allow_keys', true))
        Checkbox('Allow dialog answers', B('tg_allow_dialog', true))
        Checkbox('Allow tax payment', B('tg_allow_taxpay', true))
        Checkbox('Allow reconnect and exit', B('tg_allow_power', false))
        imgui.Dummy(imgui.ImVec2(1, 6))
        if Button('Show keyboard in Telegram', 34, true) then TG.sendKeyboard() end
    end

    SOFT.draw.telegram = function()
        Panel('Telegram', 0, 0, LAY.COLW, 262, ConnBody, nil, nil, function()
            SOFT.pageHeader('tg', LAY.COLW, 'Receive messages', B('tg_recv', false))
        end, 30)
        Panel('Messages', 0, 276, LAY.COLW, LAY.CH - 276, MsgBody)
        Panel('Telegram control', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, ControlBody)
    end

    -- ---------- переводы и подсказки ----------
    HINTS['Receive messages'] = 'Shows messages that you write to your bot in Telegram as notifications and in the list, and lets the bot buttons and commands control the game. Only new messages are shown.'
    HINTS['Connection method'] = 'Cloudflare Worker: the game talks only to your Worker, and the Worker talks to Telegram, the bot token stays in Cloudflare. Direct: the game talks to api.telegram.org with the bot token.'
    HINTS['Keywords'] = 'Chat lines that contain any of these phrases are sent to Telegram. Click to open the list.'
    HINTS['Messages per minute'] = 'Limit of chat lines forwarded to Telegram per minute, so that the bot is not blocked for flooding.'
    HINTS['Allow key presses'] = 'Telegram buttons and /key can press keys in the game.'
    HINTS['Connection notifications'] = 'Sends a message to Telegram when you connect to the server, spawn in the game or lose the connection.'
    HINTS['Allow tax payment'] = 'The Telegram command /taxpay opens the phone, pays all taxes in the bank app and closes the phone.'
    HINTS['Allow reconnect and exit'] = 'Telegram can reconnect you to the server (/reconnect) or close the game (/exit yes).'
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Telegram'] = 'Telegram', ['Notifications and'] = 'Уведомления и', ['messages via bot'] = 'сообщения через бота',
        ['Connection method'] = 'Способ связи', ['Cloudflare Worker'] = 'Cloudflare Worker', ['Telegram API (direct)'] = 'Telegram API напрямую',
        ['Worker URL'] = 'Адрес Worker', ['Access key'] = 'Ключ доступа', ['Bot token'] = 'Токен бота', ['Chat ID'] = 'ID чата',
        ['Send test message'] = 'Отправить тест', ['Copy Worker code'] = 'Копировать код Worker',
        ['Receive messages'] = 'Получать сообщения', ['Messages'] = 'Сообщения', ['Status'] = 'Статус', ['Received'] = 'Получено',
        ['Connecting...'] = 'Подключение...', ['Connected'] = 'Подключено', ['Error'] = 'Ошибка', ['Not configured'] = 'Не настроено',
        ['No response'] = 'Нет ответа', ['access denied'] = 'неверный ключ доступа', ['Update the Worker code'] = 'Обновите код Worker',
        ['No messages yet. Write to your bot in Telegram.'] = 'Сообщений пока нет. Напишите вашему боту в Telegram.',
        ['Fill in the Telegram settings first'] = 'Сначала заполните настройки Telegram', ['Test message sent'] = 'Тестовое сообщение отправлено',
        ['Test message sent: %d ms'] = 'Тестовое сообщение отправлено: %d мс',
        ['Telegram: %s'] = 'Telegram: %s', ['Worker code copied to the clipboard'] = 'Код Worker скопирован в буфер обмена',
        ['Could not save the Telegram settings'] = 'Не удалось сохранить настройки Telegram',
        ['Telegram control'] = 'Управление через Telegram', ['Forward mentions of you'] = 'Пересылать упоминания вас',
        ['Forward all chat lines'] = 'Пересылать весь чат', ['Keywords'] = 'Ключевые слова', ['Forward dialogs'] = 'Пересылать диалоги',
        ['Connection notifications'] = 'Уведомления о подключении', ['Messages per minute'] = 'Сообщений в минуту',
        ['Allow /say and commands'] = 'Разрешить /say и команды', ['Allow key presses'] = 'Разрешить нажатие клавиш',
        ['Allow dialog answers'] = 'Разрешить ответы в диалогах', ['Allow reconnect and exit'] = 'Разрешить перезаход и выход',
        ['Show keyboard in Telegram'] = 'Показать клавиатуру в Telegram', ['Keyboard sent to Telegram'] = 'Клавиатура отправлена в Telegram',
        [HINTS['Receive messages']] = 'Показывает сообщения, которые вы пишете своему боту в Telegram, уведомлением и в списке, а кнопки и команды бота позволяют управлять игрой. Показываются только новые сообщения.',
        [HINTS['Connection method']] = 'Cloudflare Worker: игра обращается только к вашему Worker, а он уже обращается к Telegram, токен бота остаётся в Cloudflare. Напрямую: игра обращается к api.telegram.org с токеном бота.',
        [HINTS['Keywords']] = 'Строки чата, в которых есть любая из этих фраз, отправляются в Telegram. Список открывается по нажатию.',
        [HINTS['Messages per minute']] = 'Ограничение на число строк чата, пересылаемых в Telegram за минуту, чтобы бота не заблокировали за флуд.',
        [HINTS['Allow key presses']] = 'Кнопки Telegram и команда /key могут нажимать клавиши в игре.',
        [HINTS['Connection notifications']] = 'Отправляет сообщение в Telegram, когда вы подключились к серверу, заспавнились в игре или потеряли соединение.',
        [HINTS['Allow tax payment']] = 'Команда Telegram /taxpay открывает телефон, оплачивает все налоги в приложении банка и закрывает телефон.',
        [HINTS['Allow reconnect and exit']] = 'Telegram может перезаходить на сервер (/reconnect) или закрывать игру (/exit yes).',
        -- сообщения бота
        ['Nickname: %s [%d]'] = 'Ник: %s [%d]', ['Ping: %d, score: %d'] = 'Пинг: %d, счёт: %d', ['HP: %d, armor: %d'] = 'HP: %d, броня: %d',
        ['Position: %.1f, %.1f, %.1f (interior %d)'] = 'Позиция: %.1f, %.1f, %.1f (интерьер %d)',
        ['Vehicle: model %d, HP %d'] = 'Транспорт: модель %d, HP %d', ['Vehicle: none'] = 'Транспорт: нет',
        ['Server: %s (%s:%s)'] = 'Сервер: %s (%s:%s)',
        ['Not in the game (not connected or not spawned yet)'] = 'Вы не в игре (нет подключения или ещё не заспавнились)',
        ['x=%.2f  y=%.2f  z=%.2f\nInterior: %d, heading: %.0f'] = 'x=%.2f  y=%.2f  z=%.2f\nИнтерьер: %d, угол: %.0f',
        ['No chat lines yet'] = 'Строк чата пока нет', ['Use: /say text or /say /command'] = 'Использование: /say текст или /say /команда',
        ['Sent: %s'] = 'Отправлено: %s', ['Disabled in the Telegram settings: %s'] = 'Отключено в настройках Telegram: %s',
        ['Use: /key KEY [ms]. Examples: /key Y, /key ALT 300, /key F6'] = 'Использование: /key КЛАВИША [мс]. Примеры: /key Y, /key ALT 300, /key F6',
        ['Key %s pressed for %d ms'] = 'Клавиша %s нажата на %d мс', ['Press a key:'] = 'Нажмите клавишу:', ['Pressed: %s'] = 'Нажато: %s',
        ['No active dialog.'] = 'Активного диалога нет.', ['Dialog #%d: %s'] = 'Диалог #%d: %s',
        ['Items: %d. Press an item below (or /d 1 number).'] = 'Пунктов: %d. Нажмите пункт ниже (или /d 1 номер).',
        ['Only the first 40 items are shown, the rest: /d 1 number'] = 'Показаны первые 40 пунктов, остальные: /d 1 номер',
        ['Enter text: /d 1 text'] = 'Ввести текст: /d 1 текст', ['Use: /d 1 [item number or text]  or  /d 0'] = 'Использование: /d 1 [номер пункта или текст]  или  /d 0',
        ['Reply sent'] = 'Ответ отправлен', ['Done'] = 'Готово', ['Reconnecting to %s:%s'] = 'Перезаход на %s:%s',
        ['Exit the game? Confirm: /exit yes'] = 'Закрыть игру? Подтвердите: /exit yes', ['Closing the game...'] = 'Закрываю игру...',
        ['Chat forwarding enabled'] = 'Пересылка чата включена', ['Chat forwarding disabled'] = 'Пересылка чата выключена',
        ['Unknown command /%s. List: /help'] = 'Неизвестная команда /%s. Список: /help', ['Command failed: %s'] = 'Ошибка команды: %s',
        ['Collapse Telegram control is ready. Use the buttons below.'] = 'Управление через Collapse готово. Используйте кнопки ниже.',
        ['Connected to the server'] = 'Подключение к серверу', ['Disconnected from the server: %s'] = 'Отключение от сервера: %s',
        ['server closed the connection'] = 'сервер закрыл соединение', ['connection lost (timeout)'] = 'связь потеряна (таймаут)',
        ['you are banned'] = 'вы забанены', ['Last chat lines:'] = 'Последние строки чата:',
        ['Spawned in the game: %s [%d]'] = 'Вы заспавнились: %s [%d]', ['Telegram settings:'] = 'Настройки Telegram:',
        ['Mentions of you'] = 'Упоминания вас', ['All chat lines'] = 'Весь чат', ['All dialogs'] = 'Все диалоги',
        ['Connection and spawn notifications'] = 'Уведомления о подключении и спавне', ['Keywords: %d'] = 'Ключевых фраз: %d',
        ['Tap a button to switch.'] = 'Нажмите кнопку, чтобы переключить.', ['Switched: %s - %s'] = 'Переключено: %s - %s',
        ['Allow tax payment'] = 'Разрешить оплату налогов', ['Tax payment is already running'] = 'Оплата налогов уже выполняется',
        ['Close the dialog or the chat input first'] = 'Сначала закройте диалог или ввод в чат',
        ['Paying taxes: opening the phone...'] = 'Оплата налогов: открываю телефон...',
        ['The bank did not open (the phone may stay open)'] = 'Банк в телефоне не открылся (телефон мог остаться открытым)',
        ['Taxes paid: %s'] = 'Налоги оплачены: %s', ['amount not recognized'] = 'сумма не распознана',
        ['The request was sent, but the server did not confirm the payment. Check in the game.'] = 'Запрос отправлен, но сервер не подтвердил оплату. Проверьте в игре.',
        ['You have no taxes to pay'] = 'Налогов к оплате нет', ['Tax payment timed out'] = 'Время оплаты налогов вышло',
        ['FPS: %d'] = 'FPS: %d', ['State: %s'] = 'Состояние: %s', ['alive'] = 'жив', ['dead'] = 'мёртв', ['not spawned'] = 'не заспавнен',
        ['Dialog: #%d "%s" (open)'] = 'Диалог: #%d "%s" (открыт)', ['Dialog: none open'] = 'Диалог: открытого нет',
        ['Forwarding: chat %s, dialogs %s'] = 'Пересылка: чат %s, диалоги %s', ['on'] = 'вкл', ['off'] = 'выкл',
        ['Forwarding of all dialogs enabled'] = 'Пересылка всех диалогов включена', ['Forwarding of all dialogs disabled'] = 'Пересылка всех диалогов выключена',
        ['Skipped %d messages because of the limit'] = 'Пропущено сообщений из-за лимита: %d',
        [TG.HELP_EN] = 'Команды:\n/status - состояние персонажа и сервера\n/pos - координаты\n/chat [N] - последние N строк чата\n/say текст - написать в чат (/say /команда - выполнить команду)\n/key КЛАВИША [мс] - нажать клавишу: Y, N, F, ALT, ENTER, F6...\n/keys - панель клавиш\n/dialog - показать активный диалог\n/d 1|0 [номер или текст] - ответить в диалоге (1 - левая кнопка, 0 - правая)\n/chaton, /chatoff - пересылка всего чата\n/dialogs, /dialogson, /dialogsoff - пересылка всех диалогов\n/reconnect - перезаход на сервер\n/settings - настройки пересылки (переключатели)\n/taxpay - оплатить все налоги через телефон\n/exit yes - закрыть игру',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Напоминание (Software -> Reminder): напоминания на выбранное время с комментарием. Два уведомления: за 5 минут и в момент
--  наступления времени (всплывающее уведомление + строка в чате). Список хранится в files\reminders.json и переживает перезапуск;
--  если время прошло, пока скрипт не работал, при запуске придёт уведомление "пропущенное напоминание".
-- ----------------------------------------------------------------------------
do
    local REM = {}
    ctl.rem = REM
    REM.list = {}
    REM.TXT_MAX = 160

    function REM.path() return FNT.filesDir() .. '\\reminders.json' end

    function REM.load()
        local f = io.open(REM.path(), 'rb')
        if not f then return end
        local txt = f:read('*a')
        f:close()
        local ok, d = pcall(decodeJson, txt)
        if not (ok and type(d) == 'table') then return end
        for _, r in ipairs(d) do
            if type(r) == 'table' and tonumber(r.at) and type(r.text) == 'string' and r.done ~= true then
                REM.list[#REM.list + 1] = {at = tonumber(r.at), text = r.text:sub(1, REM.TXT_MAX), warned = r.warned == true}
            end
        end
        table.sort(REM.list, function(a, b) return a.at < b.at end)
    end
    REM.load()

    function REM.save()
        pcall(FNT.ensureFilesDir)
        local f = io.open(REM.path(), 'wb')
        if not f then NotifyErr('Could not save the reminders') return end
        f:write(encodeJson(REM.list))
        f:close()
    end

    function REM.textBuf()
        if not REM.buf then REM.buf = imgui.new.char[REM.TXT_MAX + 1]() end
        return REM.buf
    end

    -- подписи для выбора дня: сегодня, завтра и 12 дней вперёд (с датой); обновляются при смене даты или языка
    function REM.dayItems()
        local key = os.date('%Y%m%d') .. tostring(i18n.curLang)
        if REM.dayKey ~= key then
            REM.dayKey, REM.dayList = key, {}
            for d = 0, 13 do
                local name = (d == 0 and tr('Today')) or (d == 1 and tr('Tomorrow')) or string.format(tr('In %d days'), d)
                REM.dayList[#REM.dayList + 1] = name .. ' (' .. os.date('%d.%m', os.time() + d * 86400) .. ')'
            end
        end
        return REM.dayList
    end

    -- выбранные день, час и минута -> время в секундах
    function REM.target()
        local t = os.date('*t')
        t.day = t.day + I('rem_day', 0)[0]
        t.hour = clamp(math.floor(F('rem_h', 12)[0] + 0.5), 0, 23)
        t.min = clamp(math.floor(F('rem_m', 0)[0] + 0.5), 0, 59)
        t.sec = 0
        return os.time(t)
    end

    function REM.add()
        local raw = trim(ffi.string(REM.textBuf()))
        if raw == '' then NotifyErr('Enter a comment first') return end
        local at, now = REM.target(), os.time()
        if at <= now then NotifyErr('This time has already passed') return end
        REM.list[#REM.list + 1] = {at = at, text = raw, warned = (at - now) <= 300}     -- ближе 5 минут: раннего уведомления не будет
        table.sort(REM.list, function(a, b) return a.at < b.at end)
        REM.save()
        ffi.fill(REM.textBuf(), REM.TXT_MAX + 1, 0)
        NotifyOk('Reminder set for %s', os.date('%d.%m %H:%M', at))
    end

    -- ---------- подсветка экрана и баннер ----------
    REM.flash = nil
    REM.COL = {soon = {1.0, 0.72, 0.30}, now = {0.30, 0.80, 0.50}, late = {1.0, 0.62, 0.25}}

    imgui.OnFrame(
        function() return REM.flash ~= nil end,
        function(self)
            self.HideCursor = not ui.open[0]
            gfx.galpha = 1
            local f = REM.flash
            if not f then return end
            local age = os.clock() - f.t0
            if age > f.banner then REM.flash = nil return end
            local P, dl, ds = imgui.ImVec2, imgui.GetBackgroundDrawList(), imgui.GetIO().DisplaySize
            if age < f.edge then                                      -- пульсирующая подсветка краёв экрана
                local fade = math.min(1, age / 0.15, (f.edge - age) / 0.8)
                local a = (0.22 + 0.30 * (0.5 + 0.5 * math.sin(age * 7))) * fade
                local th = math.max(ds.x, ds.y) * 0.07
                local c0 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(f.col[1], f.col[2], f.col[3], a))
                local c1 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(f.col[1], f.col[2], f.col[3], 0))
                dl:AddRectFilledMultiColor(P(0, 0), P(ds.x, th), c0, c0, c1, c1)
                dl:AddRectFilledMultiColor(P(0, ds.y - th), P(ds.x, ds.y), c1, c1, c0, c0)
                dl:AddRectFilledMultiColor(P(0, 0), P(th, ds.y), c0, c1, c1, c0)
                dl:AddRectFilledMultiColor(P(ds.x - th, 0), P(ds.x, ds.y), c1, c0, c0, c1)
            end

            -- большое окно внизу по центру: заголовок, комментарий в несколько строк, подсказка и крестик
            gfx.galpha = math.min(1, age / 0.25)
            local maxw = math.min(ds.x * 0.62, 760)
            imgui.PushFont(fonts.bold)
            if not f.lines or f.lw ~= maxw then f.lines, f.lw = wrapLines(f.raw, maxw - 110), maxw end
            local lh, widest = imgui.GetTextLineHeight(), 0
            for _, ln in ipairs(f.lines) do widest = math.max(widest, imgui.CalcTextSize(u8(ln)).x) end
            imgui.PopFont()
            imgui.PushFont(fonts.title)
            local th2, hw = imgui.GetTextLineHeight(), imgui.CalcTextSize(f.head).x
            imgui.PopFont()
            local w = clamp(math.max(widest, hw) + 110, 380, maxw)
            local h = 18 + th2 + 10 + #f.lines * (lh + 3) + 14 + 18 + 14
            local x, y = (ds.x - w) / 2, ds.y - h - 70
            dl:AddRectFilled(P(x, y), P(x + w, y + h), C(pal.bg, 0.95), 12)
            dl:AddRect(P(x, y), P(x + w, y + h), C(f.col), 12)
            dl:AddRect(P(x + 1, y + 1), P(x + w - 1, y + h - 1), C(f.col, 0.55), 11)
            dl:AddRectFilled(P(x, y + 14), P(x + 5, y + h - 14), C(f.col), 2)
            imgui.PushFont(fonts.title)
            dl:AddText(P(x + 24, y + 16), C(f.col), f.head)
            imgui.PopFont()
            imgui.PushFont(fonts.bold)
            for i, ln in ipairs(f.lines) do
                dl:AddText(P(x + 24, y + 16 + th2 + 10 + (i - 1) * (lh + 3)), C(pal.text), u8(ln))
            end
            imgui.PopFont()
            imgui.PushFont(fonts.small)
            dl:AddText(P(x + 24, y + h - 28), C(pal.dim), u8(tr('Close: click the cross')))
            imgui.PopFont()
            local cx, cy, r = x + w - 28, y + 28, 14                -- крестик закрытия (нажимается, когда виден курсор: меню или курсор SA-MP)
            local m = imgui.GetIO().MousePos
            local okc, curActive = pcall(sampIsCursorActive)
            local hot = ((m.x - cx) ^ 2 + (m.y - cy) ^ 2 <= r * r) and (ui.open[0] or (okc and curActive))
            dl:AddCircleFilled(P(cx, cy), r, C(hot and f.col or pal.field), 24)
            local xc = C(hot and pal.bg or pal.text)
            dl:AddLine(P(cx - 5, cy - 5), P(cx + 5, cy + 5), xc, 2)
            dl:AddLine(P(cx + 5, cy - 5), P(cx - 5, cy + 5), xc, 2)
            if hot and imgui.IsMouseClicked(0) then REM.flash = nil end
            gfx.galpha = 1
        end
    )

    function REM.startFlash(kind, head, raw)              -- head и raw: строки CP1251 (заголовок и комментарий)
        REM.flash = {t0 = os.clock(), col = REM.COL[kind] or REM.COL.now, head = u8(head), raw = raw,
                     edge = 6, banner = (kind == 'soon') and 30 or 600}      -- окно "в момент времени" остаётся, пока его не закроют
    end

    -- ---------- уведомление Windows, если окно игры свёрнуто или не в фокусе (идея из arztools.lua: значок в трее + всплывающее сообщение) ----------
    pcall(ffi.cdef, [[
        typedef struct { unsigned long cbSize; void* hWnd; unsigned int uID; unsigned int uFlags; unsigned int uCallbackMessage;
            void* hIcon; char szTip[128]; unsigned long dwState; unsigned long dwStateMask; char szInfo[256];
            union { unsigned int uTimeout; unsigned int uVersion; }; char szInfoTitle[64]; unsigned long dwInfoFlags;
            struct { int d[4]; } guidItem; void* hBalloonIcon; } COLRM_NID;
        int Shell_NotifyIconA(unsigned long msg, COLRM_NID* data);
        void* LoadIconA(void* inst, intptr_t code);
        void* GetForegroundWindow(void);
        int IsIconic(void* hwnd);
    ]])

    function REM.gameWnd()
        local ok, h = pcall(readMemory, 13160328, 4, false)
        return ok and h and h ~= 0 and ffi.cast('void*', h) or nil
    end

    function REM.gameInBackground()
        local ok, res = pcall(function()
            local hwnd = REM.gameWnd()
            if hwnd == nil then return false end
            return ffi.C.GetForegroundWindow() ~= hwnd or ffi.C.IsIconic(hwnd) ~= 0
        end)
        return ok and res == true
    end

    function REM.trayAdd()
        if REM.tray then return true end
        return (pcall(function()
            REM.shell = REM.shell or ffi.load('shell32')
            local d = ffi.new('COLRM_NID')
            d.cbSize = ffi.sizeof(d)
            d.hWnd = REM.gameWnd()
            d.uID = 7
            d.hIcon = ffi.C.LoadIconA(nil, 32516)
            d.uFlags = 22                                           -- NIF_ICON + NIF_TIP + NIF_INFO
            ffi.copy(d.szTip, 'Collapse')
            if REM.shell.Shell_NotifyIconA(0, d) == 0 then error('Shell_NotifyIcon failed') end
            REM.tray = d
        end))
    end

    function REM.trayPush(title, text, warn)               -- title и text: CP1251
        if not REM.trayAdd() then return end
        pcall(function()
            local d = REM.tray
            d.dwInfoFlags = warn and 2 or 1                       -- NIIF_WARNING / NIIF_INFO
            ffi.fill(d.szInfoTitle, ffi.sizeof(d.szInfoTitle), 0)
            ffi.fill(d.szInfo, ffi.sizeof(d.szInfo), 0)
            ffi.copy(d.szInfoTitle, title:sub(1, 63))
            ffi.copy(d.szInfo, text:sub(1, 255))
            REM.shell.Shell_NotifyIconA(1, d)
        end)
    end

    function REM.trayDelete()
        if REM.tray then
            pcall(function() REM.shell.Shell_NotifyIconA(2, REM.tray) end)
            REM.tray = nil
        end
    end
    REM.restore = REM.trayDelete                               -- при выгрузке скрипта значок убирается

    function REM.alert(r, kind)
        local okd, txt = pcall(function() return u8:decode(r.text) end)         -- в уведомление и чат текст идёт в CP1251
        txt = okd and txt or r.text
        local when = os.date('%H:%M', r.at)
        local key, fn
        if kind == 'soon' then key, fn = 'Reminder in 5 minutes (%s): %s', Notify
        elseif kind == 'late' then key, fn = 'Missed reminder (%s): %s', NotifyErr
        else key, fn = 'Reminder (%s): %s', NotifyOk end
        fn(key, when, txt)
        local msg = string.format(tr(key), when, txt)
        pcall(sampAddChatMessage, '{FFB84D}[Reminder] {FFFFFF}' .. msg, -1)      -- строка в чате остаётся, когда уведомление исчезло
        REM.startFlash(kind, string.format(tr(kind == 'soon' and 'Reminder in 5 minutes (%s)' or 'Reminder (%s)'), when), txt)
        if REM.gameInBackground() then REM.trayPush(tr('Reminder'), msg, kind ~= 'soon') end
    end

    -- Проверка времени: за 5 минут - раннее уведомление; когда время пришло - основное (или "пропущенное", если опоздали больше
    -- чем на 2 минуты) и напоминание сразу удаляется из списка. Вызывается раз в секунду и при открытии вкладки.
    function REM.process()
        local now, changed, due = os.time(), false, {}
        for _, r in ipairs(REM.list) do
            if not r.warned and now >= r.at - 300 then
                r.warned, changed = true, true
                if now < r.at then REM.alert(r, 'soon') end
            end
            if now >= r.at then due[#due + 1] = r end
        end
        for _, r in ipairs(due) do
            REM.alert(r, (now - r.at > 120) and 'late' or 'now')
            for i = #REM.list, 1, -1 do
                if REM.list[i] == r then table.remove(REM.list, i) break end
            end
            changed = true
        end
        if changed then REM.save() end
    end

    lua_thread.create(function()
        repeat wait(2000) until isSampAvailable()
        while true do
            REM.process()
            if REM.tray and not REM.gameInBackground() then REM.trayDelete() end        -- игра снова в фокусе: значок в трее не нужен
            wait(1000)
        end
    end)

    -- ---------- страница ----------
    -- поле комментария на всю ширину панели, подпись над ним (в узком TextRow длинная подпись обрезалась)
    function REM.commentField()
        if SRCH.collecting then Reg('Comment', 'Input') return end
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetContentRegionAvail().x
        Highlight('Comment', p, w, 54)
        dl:AddText(P(p.x, p.y + 1), C(pal.dim), u8(tr('Comment')))
        imgui.SetCursorScreenPos(P(p.x, p.y + 24))
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(8, 3.5))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 5)
        imgui.SetNextItemWidth(w)
        imgui.InputText('##rem_comment', REM.textBuf(), REM.TXT_MAX + 1)
        imgui.PopStyleVar(2)
        if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
        imgui.SetCursorScreenPos(p)
        imgui.Dummy(P(w, 54))
    end

    local function LeftBody()
        if not SRCH.collecting then
            local now = os.clock()
            if now - (REM.lastDraw or -100) > 0.5 then REM.process() end        -- вкладку только что открыли: прошедшие напоминания удаляются с уведомлением
            REM.lastDraw = now
        end
        if not REM.init and not SRCH.collecting then                   -- при первом открытии время = сейчас + 10 минут
            REM.init = true
            local t = os.date('*t', os.time() + 600)
            F('rem_h', 12)[0], F('rem_m', 0)[0] = t.hour, t.min
        end
        Combo('Day', I('rem_day', 0), REM.dayItems())
        Slider('Hour', F('rem_h', 12), 0, 23, '%d', true)
        Slider('Minute', F('rem_m', 0), 0, 59, '%d', true)
        REM.commentField()
        if not SRCH.collecting then InfoRow('Will fire at', os.date('%d.%m.%Y  %H:%M', REM.target())) end
        imgui.Dummy(imgui.ImVec2(1, 4))
        if Button('Add reminder', 34, true) then REM.add() end
        Text('You get two alerts: 5 minutes before the time and at the time itself.', pal.dim)
    end

    local function RightBody()
        if SRCH.collecting then return end
        local P = imgui.ImVec2
        local avail = imgui.GetContentRegionAvail()
        imgui.BeginChild('##rem_list', P(avail.x, avail.y), false)
        local dl = imgui.GetWindowDrawList()
        if #REM.list == 0 then Text('No reminders yet.', pal.dim) end
        local del
        for i, r in ipairs(REM.list) do
            local p = imgui.GetCursorScreenPos()
            local w = imgui.GetContentRegionAvail().x
            local status = r.warned and tr('Soon') or tr('Waiting')
            dl:AddText(p, C(THEME.main), u8(os.date('%d.%m  %H:%M', r.at) .. '  -  ' .. status))
            imgui.SetCursorScreenPos(P(p.x + w - 22, p.y - 3))
            if imgui.InvisibleButton('##remdel' .. i, P(20, 20)) then del = i end
            local col = C(imgui.IsItemHovered() and CONST.TOAST_COL.error or pal.dim)
            dl:AddLine(P(p.x + w - 17, p.y + 2), P(p.x + w - 7, p.y + 12), col, 1.6)
            dl:AddLine(P(p.x + w - 7, p.y + 2), P(p.x + w - 17, p.y + 12), col, 1.6)
            imgui.SetCursorScreenPos(P(p.x, p.y + 20))
            local tc = pal.text
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(tc[1], tc[2], tc[3], gfx.galpha))
            imgui.TextWrapped(r.text)
            imgui.PopStyleColor()
            imgui.Dummy(P(1, 8))
        end
        if del then
            table.remove(REM.list, del)
            REM.save()
        end
        imgui.EndChild()
    end

    SOFT.draw.reminder = function()
        Panel('New reminder', 0, 0, LAY.COLW, LAY.CH, LeftBody, nil, nil, function()
            SOFT.pageHeader('rem', LAY.COLW)
        end, 30)
        Panel('Reminders', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, RightBody)
    end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Reminder'] = 'Напоминание', ['Close: click the cross'] = 'Закрыть: нажмите на крестик', ['Reminder in 5 minutes (%s)'] = 'Напоминание через 5 минут (%s)', ['Reminder (%s)'] = 'Напоминание (%s)', ['Alerts at a set time'] = 'Уведомления в нужное', ['with a comment'] = 'время с комментарием',
        ['New reminder'] = 'Новое напоминание', ['Reminders'] = 'Напоминания', ['Day'] = 'День', ['Minute'] = 'Минута',
        ['Comment'] = 'Комментарий', ['Will fire at'] = 'Сработает', ['Add reminder'] = 'Добавить напоминание',
        ['No reminders yet.'] = 'Напоминаний пока нет.',
        ['Today'] = 'Сегодня', ['Tomorrow'] = 'Завтра', ['In %d days'] = 'Через %d дн.',
        ['Soon'] = 'Скоро', ['Waiting'] = 'Ожидает',
        ['You get two alerts: 5 minutes before the time and at the time itself.'] = 'Приходит два уведомления: за 5 минут до времени и в само время.',
        ['Enter a comment first'] = 'Сначала напишите комментарий', ['This time has already passed'] = 'Это время уже прошло',
        ['Reminder set for %s'] = 'Напоминание установлено на %s', ['Could not save the reminders'] = 'Не удалось сохранить напоминания',
        ['Reminder in 5 minutes (%s): %s'] = 'Напоминание через 5 минут (%s): %s', ['Reminder (%s): %s'] = 'Напоминание (%s): %s',
        ['Missed reminder (%s): %s'] = 'Пропущенное напоминание (%s): %s',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Смена скина (Software -> Skin changer): визуальный скин из полного списка Arizona (arztools). Скин применяется
--  эмуляцией RPC SetPlayerSkin (153), сервер о нём не знает. Если сервер потом сам меняет скин или выдаёт спавн,
--  подставляется выбранный; настоящий скин запоминается и возвращается при отключении. Список скинов лежит в
--  config\xMercy\Collapse\files\skins.json (перенесён из Arizona Tools\files\json\skins.json).
-- ----------------------------------------------------------------------------
do
    local SK = {}
    ctl.sk = SK
    SK.list, SK.filtered, SK.loaded, SK.sel, SK.lastQuery = {}, {}, false, nil, nil
    SK.real, SK.emul = nil, false

    function SK.path() return FNT.filesDir() .. '\\skins.json' end
    function SK.visual() return I('sk_visual', -1) end             -- id модели визуального скина, -1 - выключен

    function SK.load()
        if SK.loaded then return end
        SK.loaded = true
        local f = io.open(SK.path(), 'rb')
        if not f then SK.missing = true return end
        local txt = f:read('*a') or ''
        f:close()
        local ok, data = pcall(decodeJson, txt)
        local arr = ok and type(data) == 'table' and (type(data.data) == 'table' and data.data or data) or {}
        for _, e in ipairs(arr) do
            local model = type(e) == 'table' and tonumber(e.model_id)
            if model then
                local raw = tostring(e.name or '')
                local okd, name = pcall(function() return u8:decode(raw) end)
                name = okd and name or raw
                local id = tonumber(e.server_id) or model
                SK.list[#SK.list + 1] = {name = name, low = lower(name), model = model, id = id, idS = tostring(id)}
            end
        end
        SK.missing = #SK.list == 0
    end

    function SK.searchBuf()
        if not SK.sbuf then SK.sbuf = imgui.new.char[64]() end
        return SK.sbuf
    end

    -- список под текущий запрос: по названию (часть слова) или по ID
    function SK.refilter()
        local ok, q = pcall(function() return u8:decode(ffi.string(SK.searchBuf())) end)
        q = lower(trim(ok and q or ''))
        if q == SK.lastQuery then return end
        SK.lastQuery = q
        SK.filtered = {}
        for _, s in ipairs(SK.list) do
            if q == '' or s.low:find(q, 1, true) or s.idS == q then SK.filtered[#SK.filtered + 1] = s end
        end
    end

    -- эмуляция RPC SetPlayerSkin для себя
    function SK.apply(model)
        local ok, myId = pcall(function()
            local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
            return r and id or nil
        end)
        if not (ok and myId) then NotifyErr('Not connected to a server') return false end
        SK.emul = true
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt32(bs, myId)
        raknetBitStreamWriteInt32(bs, model)
        raknetEmulRpcReceiveBitStream(153, bs)
        raknetDeleteBitStream(bs)
        SK.emul = false
        return true
    end

    function SK.set(s, silent)
        if not s then NotifyErr('Select a skin first') return end
        if SK.visual()[0] < 0 and not SK.real then
            pcall(function() SK.real = getCharModel(PLAYER_PED) end)       -- настоящий скин запоминаем до первой подмены
        end
        if SK.apply(s.model) then
            SK.visual()[0] = s.model
            SK.name = s.name
            if not silent then NotifyOk('Visual skin set: %s', s.name) end
        end
    end

    function SK.reset()
        if SK.visual()[0] < 0 then return end
        SK.visual()[0] = -1
        SK.name = nil
        if SK.real then SK.apply(SK.real) end
        Notify('Visual skin disabled')
    end

    function SK.restore()                                            -- при выгрузке скрипта возвращаем настоящий скин
        if SK.visual()[0] >= 0 and SK.real then pcall(SK.apply, SK.real) end
    end

    if okEv and sampev then
        local oldSkin, oldSpawn = sampev.onSetPlayerSkin, sampev.onSetSpawnInfo
        sampev.onSetPlayerSkin = function(playerId, skinId)
            local ok, mine = pcall(function()
                local r, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
                return r and id == playerId
            end)
            if ok and mine and not SK.emul then
                SK.real = skinId                                      -- настоящий скин от сервера
                if SK.visual()[0] >= 0 then return {playerId, SK.visual()[0]} end
            end
            if oldSkin then return oldSkin(playerId, skinId) end
        end
        sampev.onSetSpawnInfo = function(team, skin, unused, position, rotation, weapons, ammo)
            SK.real = skin
            if SK.visual()[0] >= 0 then return {team, SK.visual()[0], unused, position, rotation, weapons, ammo} end
            if oldSpawn then return oldSpawn(team, skin, unused, position, rotation, weapons, ammo) end
        end
    end

    -- ---------- Удержание скина ----------
    -- пока включено: выбранный визуальный скин всегда на игроке (после спавна, сброса сервером, перезагрузки скрипта)
    lua_thread.create(function()
        repeat wait(1000) until isSampAvailable()
        while true do
            wait(500)
            if B('sk_keep', false)[0] and SK.visual()[0] >= 0 and ctl.alive() then
                pcall(function()
                    if sampGetGamestate and sampGetGamestate() ~= 3 then return end
                    if getCharModel(PLAYER_PED) ~= SK.visual()[0] then
                        SK.apply(SK.visual()[0])
                    end
                end)
            end
        end
    end)

    -- ---------- Походка ----------
    -- локальная смена группы анимаций ходьбы (setAnimGroupForChar); группы Arizona лежат в её ped.ifp
    local WK = {last = 0, wasAlive = false, t = 0}
    ctl.wk = WK
    WK.list = {
        {'Default'},
        {'Man', 'man'},
        {'Shuffle', 'shuffle'},
        {'Old man', 'oldman'},
        {'Gang walk 1', 'gang1'},
        {'Gang walk 2', 'gang2'},
        {'Old fat man', 'oldfatman'},
        {'Fat man', 'fatman'},
        {'Jogger', 'jogger'},
        {'Drunk', 'drunkman'},
        {'Blind man', 'blindman'},
        {'S.W.A.T.', 'swat'},
        {'Woman', 'woman'},
        {'Shopping woman', 'shopping'},
        {'Busy woman', 'busywoman'},
        {'Sexy woman', 'sexywoman'},
        {'Pro', 'pro'},
        {'Old woman', 'oldwoman'},
        {'Fat woman', 'fatwoman'},
        {'Jogging woman', 'jogwoman'},
        {'Old fat woman', 'oldfatwoman'},
        {'Arizona: Chubrik', 'chubrik'},
        {'Arizona: Stray', 'stray'},
        {'Arizona: Goose', 'goose'},
        {'Arizona: Police', 'police1'},
        {'Arizona: Military', 'military1'},
        {'Arizona: Magician', 'magican1'},
        {'Arizona: Jock', 'kachok1'},
        {'Arizona: Gangster', 'gangster1'},
        {'Arizona: Ilum', 'ilum1'},
    }
    WK.names = {}
    for i, e in ipairs(WK.list) do WK.names[i] = e[1] end

    function WK.apply(idx)
        local e = WK.list[idx + 1]
        if not e then return end
        if e[2] then
            pcall(setAnimGroupForChar, PLAYER_PED, e[2])
        else                                                          -- по умолчанию: переприменение модели пересоздаёт группу анимаций
            pcall(function() SK.apply(getCharModel(PLAYER_PED)) end)
        end
    end

    function WK.restore()
        if WK.last ~= 0 and ctl.alive() then WK.last = 0; WK.apply(0) end
    end

    lua_thread.create(function()
        repeat wait(1000) until isSampAvailable()
        while true do
            wait(300)
            pcall(function()
                local idx = B('sk_walk', false)[0] and I('main_walk', 0)[0] or 0
                local alive = ctl.alive()
                local model = alive and getCharModel(PLAYER_PED) or nil
                if idx ~= WK.last then
                    if alive then WK.apply(idx); WK.last = idx; WK.t = os.clock() end    -- ждём, пока игрок жив
                elseif idx ~= 0 and alive and (not WK.wasAlive or model ~= WK.model or os.clock() - WK.t > 5) then
                    WK.apply(idx)                                     -- после спавна, смены скина или сброса сервером
                    WK.t = os.clock()
                end
                WK.wasAlive, WK.model = alive, model
            end)
        end
    end)

    local function ListBody()
        if SRCH.collecting then return end
        SK.load()
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local w = imgui.GetContentRegionAvail().x
        local buf = SK.searchBuf()
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(10, 6))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 7)
        imgui.SetNextItemWidth(w)
        local p0 = imgui.GetCursorScreenPos()
        imgui.InputText('##sk_search', buf, ffi.sizeof(buf))
        imgui.PopStyleVar(2)
        if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
        if ffi.string(buf) == '' then dl:AddText(P(p0.x + 12, p0.y + 7), C(pal.dim, 0.75), u8(tr('Name or ID of a skin'))) end
        imgui.Dummy(P(1, 6))
        if SK.missing then Text('The skin list (skins.json) was not found in the files folder.', pal.dim) return end
        SK.refilter()
        local rowH = 28
        local avail = imgui.GetContentRegionAvail()
        imgui.BeginChild('##sk_list', P(avail.x, avail.y), false)
        local ldl = imgui.GetWindowDrawList()
        local origin = imgui.GetCursorScreenPos()
        local n = #SK.filtered
        if n == 0 then
            ldl:AddText(P(origin.x + 4, origin.y + 4), C(pal.dim), u8(tr('Nothing found')))
        else
            imgui.Dummy(P(1, n * rowH))                              -- высота прокрутки; рисуем только видимые строки
            local first = math.max(1, math.floor(imgui.GetScrollY() / rowH))
            local last = math.min(n, first + math.ceil(avail.y / rowH) + 1)
            local rw = imgui.GetContentRegionAvail().x
            for i = first, last do
                local s = SK.filtered[i]
                local y0 = origin.y + (i - 1) * rowH
                imgui.SetCursorScreenPos(P(origin.x, y0))
                local pressed = imgui.InvisibleButton('##skrow' .. i, P(rw, rowH - 2))
                local hv = animTo('skrow' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                if pressed then SK.sel = s end
                if imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0) then SK.set(s) end
                local sel = (SK.sel == s) and 1 or 0
                local active = SK.visual()[0] == s.model
                ldl:AddRectFilled(P(origin.x, y0), P(origin.x + rw, y0 + rowH - 2), C(mix(pal.field, THEME.main, sel * 0.22 + hv * 0.08)), 6)
                ldl:AddRectFilled(P(origin.x, y0 + 6), P(origin.x + 3, y0 + rowH - 8), C(THEME.main, math.max(sel, hv * 0.6)), 2)
                ldl:AddText(P(origin.x + 12, y0 + 5), C(active and THEME.main or pal.text), u8(s.name))
                local ids = u8(s.idS)
                ldl:AddText(P(origin.x + rw - 12 - imgui.CalcTextSize(ids).x, y0 + 5), C(pal.dim), ids)
            end
            imgui.SetCursorScreenPos(P(origin.x, origin.y + n * rowH))
        end
        imgui.EndChild()
    end

    local function RightBody()
        if SRCH.collecting then return end
        SK.load()
        local s = SK.sel
        InfoRow('Selected skin', s and s.name or '-')
        InfoRow('Skin ID', s and s.idS or '-')
        InfoRow('Model', s and tostring(s.model) or '-')
        InfoRow('Visual skin', SK.visual()[0] >= 0 and (SK.name or tostring(SK.visual()[0])) or tr('Off'))
        imgui.Dummy(imgui.ImVec2(1, 6))
        Checkbox('Keep skin', B('sk_keep', false))
        Checkbox('Change walk style', B('sk_walk', false))
        Combo('Walk style', I('main_walk', 0), WK.names)
        imgui.Dummy(imgui.ImVec2(1, 6))
        if Button('Set visual skin', 34, true) then SK.set(s) end
        if Button('Reset skin', 34) then SK.reset() end
        Text('The skin is visual: only you see it, the server does not know about it. Double click on a skin applies it.', pal.dim)
    end

    SOFT.draw.skins = function()
        local lw = LAY.COLW + 50
        Panel('Skins', 0, 0, lw, LAY.CH, ListBody, nil, nil, function()
            SOFT.pageHeader('skins', lw)
        end, 30)
        Panel('Selected skin', lw + 14, 0, LAY.CW - lw - 14, LAY.CH, RightBody)
    end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Skin changer'] = 'Смена скина', ['Visual skin'] = 'Визуальный скин', ['from the full list'] = 'из полного списка',
        ['Skins'] = 'Скины', ['Selected skin'] = 'Выбранный скин', ['Skin ID'] = 'ID скина', ['Model'] = 'Модель',
        ['Set visual skin'] = 'Установить визуально', ['Walk style'] = 'Походка', ['Change walk style'] = 'Изменить походку', ['Default'] = 'По умолчанию', ['Man'] = 'Мужская', ['Shuffle'] = 'Шаркающая', ['Old man'] = 'Старик', ['Gang walk 1'] = 'Гангстерская 1', ['Gang walk 2'] = 'Гангстерская 2', ['Old fat man'] = 'Старый толстяк', ['Fat man'] = 'Толстяк', ['Jogger'] = 'Бегун', ['Drunk'] = 'Пьяная', ['Blind man'] = 'Слепой', ['Woman'] = 'Женская', ['Shopping woman'] = 'С покупками', ['Busy woman'] = 'Деловая', ['Sexy woman'] = 'Соблазнительная', ['Old woman'] = 'Старушка', ['Fat woman'] = 'Полная женщина', ['Jogging woman'] = 'Бегунья', ['Old fat woman'] = 'Старая полная', ['Arizona: Chubrik'] = 'Arizona: Чубрик', ['Arizona: Stray'] = 'Arizona: Бродяга', ['Arizona: Goose'] = 'Arizona: Гусь', ['Arizona: Police'] = 'Arizona: Полицейский', ['Arizona: Military'] = 'Arizona: Военный', ['Arizona: Magician'] = 'Arizona: Маг', ['Arizona: Jock'] = 'Arizona: Качок', ['Arizona: Gangster'] = 'Arizona: Бандит', ['Arizona: Ilum'] = 'Arizona: Илюм', ['Keep skin'] = 'Удерживать скин', ['Teleport stopped: you died or are not spawned'] = 'Телепорт остановлен: вы мертвы или не заспавнены',
        ['You must be alive and spawned'] = 'Вы должны быть живы и заспавнены', ['Reset skin'] = 'Сбросить скин',
        ['Name or ID of a skin'] = 'Название или ID скина', ['Nothing found'] = 'Ничего не найдено',
        ['Select a skin first'] = 'Сначала выберите скин', ['Not connected to a server'] = 'Нет подключения к серверу',
        ['Visual skin set: %s'] = 'Визуальный скин установлен: %s', ['Visual skin disabled'] = 'Визуальный скин отключён',
        ['The skin list (skins.json) was not found in the files folder.'] = 'Список скинов (skins.json) не найден в папке файлов.',
        ['The skin is visual: only you see it, the server does not know about it. Double click on a skin applies it.'] =
            'Скин визуальный: его видите только вы, сервер о нём не знает. Двойной клик по скину применяет его.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Названия транспорта по номеру модели: список из arztools (vehicles.json), лежит в
--  config\xMercy\Collapse\files\vehicles.json. Используется в WH на транспорт и в отладочной информации.
-- ----------------------------------------------------------------------------
do
    local VN = {}
    ctl.vn = VN
    VN.names, VN.loaded = {}, false

    function VN.load()
        if VN.loaded then return end
        VN.loaded = true
        local f = io.open(FNT.filesDir() .. '\\vehicles.json', 'rb')
        if not f then return end
        local txt = f:read('*a') or ''
        f:close()
        local ok, data = pcall(decodeJson, txt)
        local arr = ok and type(data) == 'table' and (type(data.data) == 'table' and data.data or data) or {}
        for _, e in ipairs(arr) do
            local model = type(e) == 'table' and tonumber(e.model_id)
            if model and not VN.names[model] then
                local raw = tostring(e.name or '')
                local okd, name = pcall(function() return u8:decode(raw) end)
                VN.names[model] = okd and name or raw
            end
        end
    end

    -- название модели (cp1251) или nil, если в списке такой модели нет
    function VN.name(model)
        VN.load()
        return VN.names[model]
    end
end

-- ----------------------------------------------------------------------------
--  Визуальная машина (Software -> Visual vehicle): создаёт машину из списка (vehicles.json, в том
--  числе кастомные модели Arizona) только на вашем клиенте и сажает вас за руль. Сервер о ней не знает, другие игроки её не видят.
--  Список - тот же vehicles.json, что используется для названий в WH на машинах.
-- ----------------------------------------------------------------------------
do
    local VC = {}
    ctl.vc = VC
    VC.list, VC.filtered, VC.loaded, VC.sel, VC.lastQuery = {}, {}, false, nil, nil
    VC.car, VC.name, VC.busy = nil, nil, false

    function VC.load()
        if VC.loaded then return end
        VC.loaded = true
        local f = io.open(FNT.filesDir() .. '\\vehicles.json', 'rb')
        if not f then VC.missing = true return end
        local txt = f:read('*a') or ''
        f:close()
        local ok, data = pcall(decodeJson, txt)
        local arr = ok and type(data) == 'table' and (type(data.data) == 'table' and data.data or data) or {}
        local seen = {}
        for _, e in ipairs(arr) do
            local model = type(e) == 'table' and tonumber(e.model_id)
            if model and not seen[model] then
                seen[model] = true
                local raw = tostring(e.name or '')
                local okd, name = pcall(function() return u8:decode(raw) end)
                name = okd and name or raw
                VC.list[#VC.list + 1] = {name = name, low = lower(name), model = model, idS = tostring(model)}
            end
        end
        VC.missing = #VC.list == 0
    end

    function VC.searchBuf()
        if not VC.sbuf then VC.sbuf = imgui.new.char[64]() end
        return VC.sbuf
    end

    -- список для текущего запроса: по названию (часть слова) или по ID модели
    function VC.refilter()
        local ok, q = pcall(function() return u8:decode(ffi.string(VC.searchBuf())) end)
        q = lower(trim(ok and q or ''))
        if q == VC.lastQuery then return end
        VC.lastQuery = q
        VC.filtered = {}
        for _, s in ipairs(VC.list) do
            if q == '' or s.low:find(q, 1, true) or s.idS == q then VC.filtered[#VC.filtered + 1] = s end
        end
    end

    function VC.remove(notify)
        local had = VC.car ~= nil
        if VC.car then pcall(function() if doesVehicleExist(VC.car) then deleteCar(VC.car) end end) end
        VC.car, VC.name, VC.exitKey = nil, nil, nil
        if notify and had then Notify('Visual vehicle removed') end
    end

    -- создаёт машину перед персонажем и сажает за руль
    function VC.give(s)
        if not s then NotifyErr('Select a vehicle first') return end
        if VC.busy then return end
        if not (ctl.alive and ctl.alive()) then NotifyErr('You must be alive and spawned') return end
        if isCharInAnyCar(PLAYER_PED) and not (VC.car and isCharInCar(PLAYER_PED, VC.car)) then
            NotifyErr('Get out of the vehicle first')
            return
        end
        VC.busy = true
        lua_thread.create(function()
            local ok, err = pcall(function()
                local model = s.model
                local available = true
                if isModelAvailable then
                    local okm, r = pcall(isModelAvailable, model)
                    if okm then available = r end
                end
                if not available then NotifyErr('This vehicle model is not available in the game') return end
                requestModel(model)
                local t0 = os.clock()
                while not hasModelLoaded(model) and os.clock() - t0 < 3 do wait(0) end
                if not hasModelLoaded(model) then
                    markModelAsNoLongerNeeded(model)
                    NotifyErr('Could not load the vehicle model')
                    return
                end
                VC.remove()
                local sx, sy, sz = getCharCoordinates(PLAYER_PED)
                VC.start = {x = sx, y = sy, z = sz, h = getCharHeading(PLAYER_PED)}        -- точка начала тест-драйва
                local x, y, z = getOffsetFromCharInWorldCoords(PLAYER_PED, 0, 4, 0)
                local car = createCar(model, x, y, z)
                setCarHeading(car, getCharHeading(PLAYER_PED))
                pcall(fixCar, car)                                   -- сброс повреждений деталей (капот, бампера, двери)
                warpCharIntoCar(PLAYER_PED, car)
                markModelAsNoLongerNeeded(model)
                VC.car, VC.name, VC.sat, VC.givenAt = car, s.name, false, os.clock()
                NotifyOk('Visual vehicle given: %s', s.name)
            end)
            VC.busy = false
            if not ok then
                print('[COLLAPSE] Visual vehicle: ' .. tostring(err))
                NotifyErr('Could not create the vehicle')
            end
        end)
    end

    -- вышли из машины: она удаляется, а персонаж возвращается в точку, где начался тест-драйв
    function VC.finish()
        local st, car = VC.start, VC.car
        local back = st ~= nil and ctl.alive and ctl.alive()
        if back and car then
            pcall(function()
                if isCharInCar(PLAYER_PED, car) then
                    warpCharFromCarToCoord(PLAYER_PED, st.x, st.y, st.z)            -- выход из машины сразу в точку начала, без падения
                else
                    setCharCoordinates(PLAYER_PED, st.x, st.y, st.z)
                end
                setCharHeading(PLAYER_PED, st.h)
                setCharVelocity(PLAYER_PED, 0, 0, 0)                                -- скорость машины не переносится на персонажа
                clearCharTasksImmediately(PLAYER_PED)
            end)
        end
        VC.remove(true)                                                             -- машина удаляется, когда персонажа в ней уже нет
        if back then Notify('Returned to the start point') end
    end

    -- кнопка "Убрать машину": если вы внутри - как выход из машины, иначе просто удалить
    function VC.manualRemove()
        local inside = false
        if VC.car then pcall(function() inside = isCharInCar(PLAYER_PED, VC.car) end) end
        if inside then VC.finish() else VC.remove(true) end
    end

    -- машина пропадает, когда вы из неё вышли (или умерли): пока не села - ждём до 3 секунд
    lua_thread.create(function()
        while true do
            wait(VC.car and 0 or 200)                              -- пока машина есть, клавиша проверяется каждый кадр
            if VC.car then
                pcall(function()
                    if not doesVehicleExist(VC.car) then
                        VC.car, VC.name, VC.exitKey = nil, nil, nil
                    elseif isCharInCar(PLAYER_PED, VC.car) then
                        VC.sat = true
                        local okk, ks = pcall(getGameKeyState, 15)       -- 15 - игровая клавиша "выйти из машины"
                        local down = okk and ks ~= 0
                        local pressed = (down and not VC.exitKey) or wasKeyPressed(0x46) or wasKeyPressed(0x0D)         -- F, Enter
                        if VC.exitKey ~= nil and pressed and not sampIsChatInputActive() and not sampIsDialogActive() then
                            VC.finish()                                  -- начали выходить: машина удаляется, вы сразу в точке начала
                            return
                        end
                        VC.exitKey = down
                    elseif VC.sat then
                        VC.finish()                                      -- запасной путь: вышли другим способом
                    elseif os.clock() - (VC.givenAt or 0) > 3 then
                        VC.remove(true)
                    end
                end)
            end
        end
    end)

    -- при выгрузке скрипта визуальная машина удаляется
    function VC.restore() VC.remove() end

    local function ListBody()
        if SRCH.collecting then return end
        VC.load()
        local P, dl = imgui.ImVec2, imgui.GetWindowDrawList()
        local w = imgui.GetContentRegionAvail().x
        local buf = VC.searchBuf()
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, P(10, 6))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 7)
        imgui.SetNextItemWidth(w)
        local p0 = imgui.GetCursorScreenPos()
        imgui.InputText('##vc_search', buf, ffi.sizeof(buf))
        imgui.PopStyleVar(2)
        if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
        if ffi.string(buf) == '' then dl:AddText(P(p0.x + 12, p0.y + 7), C(pal.dim, 0.75), u8(tr('Name or ID of a vehicle'))) end
        imgui.Dummy(P(1, 6))
        if VC.missing then Text('The vehicle list (vehicles.json) was not found in the files folder.', pal.dim) return end
        VC.refilter()
        local rowH = 28
        local avail = imgui.GetContentRegionAvail()
        imgui.BeginChild('##vc_list', P(avail.x, avail.y), false)
        local ldl = imgui.GetWindowDrawList()
        local origin = imgui.GetCursorScreenPos()
        local n = #VC.filtered
        if n == 0 then
            ldl:AddText(P(origin.x + 4, origin.y + 4), C(pal.dim), u8(tr('Nothing found')))
        else
            imgui.Dummy(P(1, n * rowH))                              -- высота всего списка; рисуются только видимые строки
            local first = math.max(1, math.floor(imgui.GetScrollY() / rowH))
            local last = math.min(n, first + math.ceil(avail.y / rowH) + 1)
            local rw = imgui.GetContentRegionAvail().x
            for i = first, last do
                local s = VC.filtered[i]
                local y0 = origin.y + (i - 1) * rowH
                imgui.SetCursorScreenPos(P(origin.x, y0))
                local pressed = imgui.InvisibleButton('##vcrow' .. i, P(rw, rowH - 2))
                local hv = animTo('vcrow' .. i, imgui.IsItemHovered() and 1 or 0, 14)
                if pressed then VC.sel = s end
                if imgui.IsItemHovered() and imgui.IsMouseDoubleClicked(0) then VC.give(s) end
                local sel = (VC.sel == s) and 1 or 0
                ldl:AddRectFilled(P(origin.x, y0), P(origin.x + rw, y0 + rowH - 2), C(mix(pal.field, THEME.main, sel * 0.22 + hv * 0.08)), 6)
                ldl:AddRectFilled(P(origin.x, y0 + 6), P(origin.x + 3, y0 + rowH - 8), C(THEME.main, math.max(sel, hv * 0.6)), 2)
                ldl:AddText(P(origin.x + 12, y0 + 5), C(pal.text), u8(s.name))
                local ids = u8(s.idS)
                ldl:AddText(P(origin.x + rw - 12 - imgui.CalcTextSize(ids).x, y0 + 5), C(pal.dim), ids)
            end
            imgui.SetCursorScreenPos(P(origin.x, origin.y + n * rowH))
        end
        imgui.EndChild()
    end

    local function RightBody()
        if SRCH.collecting then return end
        VC.load()
        local s = VC.sel
        InfoRow('Selected vehicle', s and s.name or '-')
        InfoRow('Model', s and s.idS or '-')
        InfoRow('Visual vehicle', VC.name or tr('Off'))
        imgui.Dummy(imgui.ImVec2(1, 6))
        if Button('Give vehicle', 34, true) then VC.give(s) end
        if Button('Remove vehicle', 34) then VC.manualRemove() end
        Text('The vehicle is visual: it exists only on your client. For the server you stand AFK. Double click on a vehicle gives it.', pal.dim)
    end

    SOFT.draw.vcar = function()
        local lw = LAY.COLW + 50
        Panel('Vehicles', 0, 0, lw, LAY.CH, ListBody, nil, nil, function()
            SOFT.pageHeader('vcar', lw)
        end, 30)
        Panel('Selected vehicle', lw + 14, 0, LAY.CW - lw - 14, LAY.CH, RightBody)
    end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Visual vehicle'] = 'Визуальная машина', ['Drive any vehicle'] = 'Любая машина из списка,', ['from the full list'] = 'можно кататься',
        ['Vehicles'] = 'Машины', ['Selected vehicle'] = 'Выбранная машина', ['Give vehicle'] = 'Выдать машину', ['Remove vehicle'] = 'Убрать машину',
        ['Name or ID of a vehicle'] = 'Название или ID машины', ['Select a vehicle first'] = 'Сначала выберите машину',
        ['Get out of the vehicle first'] = 'Сначала выйдите из транспорта', ['This vehicle model is not available in the game'] = 'Эта модель машины недоступна в игре',
        ['Could not load the vehicle model'] = 'Не удалось загрузить модель машины', ['Could not create the vehicle'] = 'Не удалось создать машину',
        ['Visual vehicle given: %s'] = 'Визуальная машина выдана: %s', ['Visual vehicle removed'] = 'Визуальная машина убрана',
        ['Returned to the start point'] = 'Вы возвращены в точку начала',
        ['The vehicle list (vehicles.json) was not found in the files folder.'] = 'Список машин (vehicles.json) не найден в папке файлов.',
        ['The vehicle is visual: it exists only on your client. For the server you stand AFK. Double click on a vehicle gives it.'] =
            'Машина визуальная: она есть только у вас. Бесплатный аналог тест-драйва в любом месте. Для сервера вы стоите АФК. Двойной клик по машине выдаёт её.',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- запасной вариант, если ни одного шрифта из списка нет: один шрифт указанного размера (или встроенный в imgui)
local function loadFont(names, size)
    local io = imgui.GetIO()
    local dir = getFolderPath(0x14) .. '\\'
    for _, n in ipairs(names) do
        if doesFileExist(dir .. n) then
            return io.Fonts:AddFontFromFileTTF(dir .. n, size, nil, FNT.FONT_RANGES or io.Fonts:GetGlyphRangesCyrillic())
        end
    end
    return io.Fonts:AddFontDefault()
end

-- ----------------------------------------------------------------------------
--  Загрузка шрифтов. Что сделано ради экономии памяти и текстуры:
--   1) каждый .ttf читается с диска ОДИН раз, и все размеры берут данные из этого буфера
--      (обычный AddFontFromFileTTF копирует файл в память заново для каждого размера - это десятки МБ ОЗУ);
--   2) OversampleH = 2 вместо 3 по умолчанию: текстура шрифтов меньше примерно на треть;
--   3) узкий набор символов (FONT_RANGES) и никаких лишних "базовых" шрифтов.
--  Если что-то из этого не поддерживается (другая версия mimgui), всё автоматически грузится по-старому.
-- ----------------------------------------------------------------------------
FNT.ttfCache = {}                 -- путь -> {buf, len}; буферы должны жить, пока жив атлас
FNT.fontCfgs = {}                 -- конфиги шрифтов (держим ссылки, пока строится атлас)

local function newFontCfg(sharedData)
    local ok, cfg = pcall(function()
        local c = imgui.ImFontConfig()
        c.OversampleH, c.OversampleV = 2, 1
        if sharedData then c.FontDataOwnedByAtlas = false end   -- данные принадлежат нам, а не атласу
        return c
    end)
    if ok and cfg then FNT.fontCfgs[#FNT.fontCfgs + 1] = cfg return cfg end
    return nil
end

-- чёткие шрифты для оверлеев: без горизонтальной передискретизации и с привязкой глифов к пикселям
local function newCrispCfg(sharedData)
    local ok, cfg = pcall(function()
        local c = imgui.ImFontConfig()
        c.OversampleH, c.OversampleV = 1, 1
        c.PixelSnapH = true
        if sharedData then c.FontDataOwnedByAtlas = false end
        return c
    end)
    if ok and cfg then FNT.fontCfgs[#FNT.fontCfgs + 1] = cfg return cfg end
    return nil
end

local function readTTF(path)
    local d = FNT.ttfCache[path]
    if d then return d end
    local f = io.open(path, 'rb')
    if not f then error('cannot open ' .. path) end
    local data = f:read('*a')
    f:close()
    d = {buf = ffi.new('uint8_t[?]', #data), len = #data}
    ffi.copy(d.buf, data, #data)
    FNT.ttfCache[path] = d
    return d
end

-- Строит атлас шрифтов: системные шрифты Windows + свои из папки files + шрифт иконок.
-- Вызывается из OnInitialize и из FNT.rebuild (пересборка на лету). FONTSETS / FONT_NAMES очищаются на месте:
-- на них ссылается окно настроек.
function FNT.build()
    local io = imgui.GetIO()
    for i = #FNT.FONTSETS, 1, -1 do FNT.FONTSETS[i] = nil end
    for i = #FNT.FONT_NAMES, 1, -1 do FNT.FONT_NAMES[i] = nil end
    FNT.faFont, FNT.fontCfgs = {}, {}

    local atlas = io.Fonts
    local cfgFile = newFontCfg(false)       -- обычная загрузка из файла
    local cfgShared = newFontCfg(true)      -- загрузка из общего буфера
    local crispFile, crispShared = newCrispCfg(false), newCrispCfg(true)   -- для шрифтов оверлеев
    local shared = cfgShared ~= nil
    local fdir = getFolderPath(0x14) .. '\\'

    local function addTTF(file, size, ranges, crisp)
        if not file then return nil end
        local path = file:find('^%a:[\\/]') and file or (fdir .. file)      -- абсолютный путь (свои шрифты) или файл из папки Fonts
        if not doesFileExist(path) then return nil end
        ranges = ranges or FNT.FONT_RANGES
        if shared then
            local ok, font = pcall(function()
                local d = readTTF(path)
                return atlas:AddFontFromMemoryTTF(d.buf, d.len, size, (crisp and crispShared) or cfgShared, ranges)
            end)
            if ok and font then return font end
            shared = false                  -- дальше грузим из файла как обычно
        end
        return atlas:AddFontFromFileTTF(path, size, (crisp and crispFile) or cfgFile, ranges)
    end

    -- Набор шрифтов Windows на выбор (берутся только существующие файлы). Для каждого грузятся все размеры,
    -- потому что переключение идёт без перезапуска: интерфейс (15/16/22/12) и уведомления (18).
    -- {название, обычный файл, жирный файл}; если жирного файла нет, везде используется обычный.
    local fontSets = {
        {'Segoe UI',           'segoeui.ttf',     'segoeuib.ttf'},
        {'Segoe UI Semibold',  'seguisb.ttf',     nil},
        {'Arial',              'arial.ttf',       'arialbd.ttf'},
        {'Tahoma',             'tahoma.ttf',      'tahomabd.ttf'},
        {'Verdana',            'verdana.ttf',     'verdanab.ttf'},
        {'Calibri',            'calibri.ttf',     'calibrib.ttf'},
        {'Consolas',           'consola.ttf',     'consolab.ttf'},
        {'Bahnschrift',        'bahnschrift.ttf', nil},
        {'Trebuchet MS',       'trebuc.ttf',      'trebucbd.ttf'},
        {'Georgia',            'georgia.ttf',     'georgiab.ttf'},
        {'Times New Roman',    'times.ttf',       'timesbd.ttf'},
        {'Courier New',        'cour.ttf',        'courbd.ttf'},
        {'Comic Sans MS',      'comic.ttf',       'comicbd.ttf'},
        {'Impact',             'impact.ttf',      nil},
    }
    for _, e in ipairs(FNT.custom) do          -- свои шрифты из moonloader\config\xMercy\Collapse\files
        fontSets[#fontSets + 1] = {e.name, e.path}
    end
    -- Список семейств собирается по наличию файлов, но в атлас грузятся только выбранные (интерфейс / уведомления)
    -- и шрифт по умолчанию. Остальные - заглушки {lazy = true}: при выборе FNT.rebuild загрузит их.
    local avail = {}
    for _, c in ipairs(fontSets) do
        local file = c[2]
        if file then
            local path = file:find('^%a:[\\/]') and file or (fdir .. file)
            if doesFileExist(path) then
                local nm = FNT.uniqueName(c[1])
                avail[#avail + 1] = {c = c, nm = nm}
                FNT.FONT_NAMES[#FNT.FONT_NAMES + 1] = nm
            end
        end
    end
    local keep, anyLoaded = {}, false
    for _, e in ipairs(avail) do
        if e.nm == FNT.DEFAULT_FONT or FNT.need[e.nm] then keep[e.nm] = true end
    end
    if not keep[FNT.DEFAULT_FONT] and avail[1] then keep[avail[1].nm] = true end      -- шрифта по умолчанию нет: берём первый доступный
    FNT.tried = keep
    for _, e in ipairs(avail) do
        local c, nm = e.c, e.nm
        local regular = keep[nm] and addTTF(c[2], 15) or nil
        if regular then
            local function bold(size) return addTTF(c[3], size) or addTTF(c[2], size) end
            local ov = {}
            for _, sz in ipairs(CONST.OVL_SIZES) do
                local f = addTTF(c[2], sz, FNT.OVL_RANGES, true)
                if f then ov[#ov + 1] = {sz, f} end
            end
            FNT.FONTSETS[#FNT.FONTSETS + 1] = {
                name = nm, regular = regular, bold = bold(16), title = bold(22), small = addTTF(c[2], 12),
                toast = addTTF(c[2], 18), toastb = bold(18),
                overlay = ov[#ov] and ov[#ov][2] or addTTF(c[2], CONST.OVL_SIZE, FNT.OVL_RANGES),
                ov = ov,
            }
            anyLoaded = true
        else
            FNT.FONTSETS[#FNT.FONTSETS + 1] = {name = nm, lazy = true}
        end
    end
    if not anyLoaded then                    -- ни одно семейство не загрузилось: ниже включится запасной шрифт
        for i = #FNT.FONTSETS, 1, -1 do FNT.FONTSETS[i] = nil end
        for i = #FNT.FONT_NAMES, 1, -1 do FNT.FONT_NAMES[i] = nil end
    end

    if #FNT.FONTSETS == 0 then             -- ни одного файла не нашли: берём запасные шрифты
        FNT.FONTSETS[1] = {
            name = 'Default',
            regular = loadFont({'segoeui.ttf', 'arial.ttf'}, 15),
            bold    = loadFont({'segoeuib.ttf', 'arialbd.ttf'}, 16),
            title   = loadFont({'segoeuib.ttf', 'arialbd.ttf'}, 22),
            small   = loadFont({'segoeui.ttf', 'arial.ttf'}, 12),
            toast   = loadFont({'segoeui.ttf', 'arial.ttf'}, 18),
            toastb  = loadFont({'segoeuib.ttf', 'arialbd.ttf'}, 18),
            overlay = loadFont({'segoeui.ttf', 'arial.ttf'}, CONST.OVL_SIZE),
        }
        FNT.FONT_NAMES[1] = 'Default'
    end

    -- иконки FontAwesome: отдельные шрифты, только символы из таблицы FNT.faCodes
    local okFa, errFa = pcall(function()
        local path, wanted = FNT.faPath()
        if not path then error('file not found: ' .. tostring(wanted)) end
        if not (crispShared and (FNT.faCodes or FNT.faRanges)) then error('no icon table or font config') end
        local d = readTTF(path)                           -- буфер хранится в FNT.ttfCache, пока жив атлас
        local buf, len = d.buf, d.len
        if FNT.faCodes then      -- таблица кодов и диапазоны считаются один раз (при пересборке берутся готовые)
        local codes = {}
        for name, cp in pairs(FNT.faCodes) do
            codes[#codes + 1] = cp
            FNT.fa[name] = FNT.utf8char(cp)
        end
        table.sort(codes)
        local r, i = {}, 1                                -- подряд идущие коды сворачиваем в диапазоны
        while i <= #codes do
            local j = i
            while j < #codes and codes[j + 1] == codes[j] + 1 do j = j + 1 end
            r[#r + 1], r[#r + 2] = codes[i], codes[j]
            i = j + 1
        end
        FNT.faRanges = imgui.new.ImWchar[#r + 1]()
        for k = 1, #r do FNT.faRanges[k - 1] = r[k] end
        FNT.faCodes = nil
        end
        for _, sz in ipairs(FNT.FA_SIZES) do
            FNT.faFont[sz] = atlas:AddFontFromMemoryTTF(buf, len, sz, crispShared, FNT.faRanges)
        end
    end)
    if not okFa then print('[COLLAPSE] Icon font was not loaded (put ' .. FNT.FA_NAME .. ' into ' .. FNT.filesDir() .. '): ' .. tostring(errFa)) end

    -- стартовый набор (дальше applyUiFont подставит выбранный в конфиге)
    local fs = FNT.FONTSETS[fontIndex(FNT.DEFAULT_FONT) + 1] or FNT.FONTSETS[1]
    fonts.regular, fonts.bold, fonts.title, fonts.small = fs.regular, fs.bold, fs.title, fs.small
    fonts.toast, fonts.toastb = fs.toast, fs.toastb
    fonts.overlay = fs.overlay
    io.FontDefault = fs.regular
    FNT.setOverlaySet(fs)
end

-- Пересборка атласа на лету (вызывается в before-кадре главного окна, вне NewFrame). Все ImFont после Clear()
-- недействительны, поэтому заново выставляются fonts.*, шрифт по умолчанию и шрифты живых уведомлений.
function FNT.emergency()                      -- ничего не вышло: один встроенный шрифт imgui, чтобы не упасть
    pcall(function()
        local io = imgui.GetIO()
        io.FontDefault = nil
        io.Fonts:Clear()
        local f = io.Fonts:AddFontDefault()
        for i = #FNT.FONTSETS, 1, -1 do FNT.FONTSETS[i] = nil end
        for i = #FNT.FONT_NAMES, 1, -1 do FNT.FONT_NAMES[i] = nil end
        FNT.faFont = {}
        FNT.FONTSETS[1] = {name = 'Default', regular = f, bold = f, title = f, small = f, toast = f, toastb = f, overlay = f, ov = {}}
        FNT.FONT_NAMES[1] = 'Default'
        fonts.regular, fonts.bold, fonts.title, fonts.small = f, f, f, f
        fonts.toast, fonts.toastb, fonts.overlay = f, f, f
        io.FontDefault = f
        FNT.setOverlaySet(FNT.FONTSETS[1])
        imgui.InvalidateFontsTexture()
    end)
end

function FNT.rebuild()
    FNT.rebuildReq = false
    local want = {}
    for _, key in ipairs(FNT.SEL_KEYS) do         -- выбор запоминаем по названию: индексы после пересборки сдвинутся
        local ptr = ctl.st[key]
        want[key] = (ptr and FNT.FONT_NAMES[ptr[0] + 1]) or FNT.want[key]
    end
    FNT.need = {}                                 -- в атлас идут только выбранные семейства (и шрифт по умолчанию)
    for _, nm in pairs(want) do FNT.need[nm] = true end
    local function attempt()
        local io = imgui.GetIO()
        io.FontDefault = nil
        io.Fonts:Clear()
        FNT.ttfCache = {}                         -- файлы могли измениться: читаем заново
        FNT.build()
        imgui.InvalidateFontsTexture()            -- текстура шрифтов пересоздаётся
    end
    local ok, err = pcall(attempt)
    local failed = false
    if not ok then
        failed = true
        print('[COLLAPSE] Font rebuild failed: ' .. tostring(err))
        FNT.badSig = FNT.customSig                -- этот набор файлов больше не пробуем
        FNT.custom, FNT.customSig = {}, FNT.signature({})
        local ok2, err2 = pcall(attempt)
        if not ok2 then
            print('[COLLAPSE] Font rebuild failed again: ' .. tostring(err2))
            FNT.emergency()
        end
    end
    for _, t in ipairs(gfx.toasts) do t.lines, t.font = nil, nil end      -- у живых уведомлений шрифты пересчитаются
    FNT.curUiFont = nil                           -- applyUiFont подставит выбранный шрифт заново
    for k, v in pairs(want) do FNT.want[k] = v end
    FNT.resolve()
    if failed then SIDE.addHist('error', 'Could not load the custom fonts, the default font is used'); NotifyErr('Could not load the custom fonts, the default font is used')
    elseif not FNT.quiet then NotifyOk('Fonts updated: %d custom', #FNT.custom) end
    FNT.quiet = false
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil

    -- символы: латиница + Latin-1, кириллица, знаки препинания (тире, кавычки, многоточие), №
    FNT.FONT_RANGES = imgui.new.ImWchar[9](0x0020, 0x00FF, 0x0400, 0x045F, 0x2010, 0x2027, 0x2116, 0x2116, 0)
    -- крупная версия шрифта для оверлея: только ASCII и кириллица, чтобы не раздувать текстуру
    FNT.OVL_RANGES = imgui.new.ImWchar[5](0x0020, 0x007E, 0x0400, 0x045F, 0)

    FNT.ensureFilesDir()
    FNT.custom = FNT.scan()                  -- свои шрифты, которые уже лежат в папке на старте
    for _, e in ipairs(FNT.custom) do FNT.lastSizes[e.file] = e.size end
    FNT.customSig = FNT.signature(FNT.custom)
    FNT.need = {}
    for _, nm in pairs(FNT.want) do FNT.need[nm] = true end        -- выбор из конфига, если он уже загружен
    FNT.build()
    FNT.built = true
    FNT.resolve()                            -- выбор из конфига (если он уже загружен) по названию

    local s = imgui.GetStyle()
    s.WindowPadding    = imgui.ImVec2(8, 8)
    s.WindowRounding   = 10
    s.WindowBorderSize = 0
    s.ChildBorderSize  = 0
    s.FramePadding     = imgui.ImVec2(10, 5)
    s.FrameRounding    = 6
    s.ItemSpacing      = imgui.ImVec2(8, 6)
    s.PopupRounding    = 8
    s.PopupBorderSize  = 1
    s.ScrollbarSize    = 6
    s.ScrollbarRounding = 3

    THEME.applyStyle()
end)

-- ----------------------------------------------------------------------------
--  Бегущая линия по периметру окна
-- ----------------------------------------------------------------------------
LUI.perim = nil

local function buildPerimeter()
    local r, m = 10, 1                         -- радиус скругления, отступ от края
    local x0, y0, x1, y1 = m, m, LAY.W - m, LAY.H - m
    local pts = {}
    local function add(x, y) pts[#pts + 1] = {x, y} end
    local function arc(cx, cy, a0, a1)
        for i = 0, 8 do
            local a = a0 + (a1 - a0) * i / 8
            add(cx + math.cos(a) * r, cy + math.sin(a) * r)
        end
    end
    local function edge(ax, ay, bx, by)
        local n = math.max(1, math.floor(math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / 8))
        for i = 0, n do add(ax + (bx - ax) * i / n, ay + (by - ay) * i / n) end
    end
    edge(x0 + r, y0, x1 - r, y0)                       -- верх
    arc(x1 - r, y0 + r, -math.pi / 2, 0)               -- правый верхний угол
    edge(x1, y0 + r, x1, y1 - r)                       -- право
    arc(x1 - r, y1 - r, 0, math.pi / 2)                -- правый нижний угол
    edge(x1 - r, y1, x0 + r, y1)                       -- низ
    arc(x0 + r, y1 - r, math.pi / 2, math.pi)          -- левый нижний угол
    edge(x0, y1 - r, x0, y0 + r)                       -- лево
    arc(x0 + r, y0 + r, math.pi, math.pi * 1.5)        -- левый верхний угол
    pts[#pts + 1] = pts[1]

    local cum, total = {0}, 0
    for i = 2, #pts do
        total = total + math.sqrt((pts[i][1] - pts[i - 1][1]) ^ 2 + (pts[i][2] - pts[i - 1][2]) ^ 2)
        cum[i] = total
    end
    return {pts = pts, cum = cum, total = total}
end

-- точка на периметре по пройденному расстоянию (с зацикливанием)
local function perimPoint(d)
    local P = LUI.perim
    d = d % P.total
    local lo, hi = 1, #P.cum
    while hi - lo > 1 do
        local mid = math.floor((lo + hi) / 2)
        if P.cum[mid] <= d then lo = mid else hi = mid end
    end
    local seg = P.cum[hi] - P.cum[lo]
    local t = seg > 0 and (d - P.cum[lo]) / seg or 0
    local a, b = P.pts[lo], P.pts[hi]
    return a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t
end

-- ----------------------------------------------------------------------------
--  Переключатель языка: выпадающий список с флагами в правом верхнем углу окна
--  (кнопка всегда на виду, список раскрывается под ней)
--  Флаги рисуются векторно: шрифт imgui не умеет эмодзи-флаги, а картинки не нужны.
--  Свой флаг: FLAGS.<id> = function(dl, x, y, w, h) ... end
-- ----------------------------------------------------------------------------
LUI.FLAG_W, LUI.FLAG_H = 24, 16
LUI.FLAGS = {}

LUI.FLAGS.en = function(dl, x, y, w, h)               -- Великобритания
    local P = imgui.ImVec2
    local blue, white, red = {0.00, 0.14, 0.49}, {1, 1, 1}, {0.80, 0.07, 0.15}
    dl:AddRectFilled(P(x, y), P(x + w, y + h), C(blue))
    dl:PushClipRect(P(x, y), P(x + w, y + h), true)
    dl:AddLine(P(x, y), P(x + w, y + h), C(white), 3.4)
    dl:AddLine(P(x + w, y), P(x, y + h), C(white), 3.4)
    dl:AddLine(P(x, y), P(x + w, y + h), C(red), 1.4)
    dl:AddLine(P(x + w, y), P(x, y + h), C(red), 1.4)
    dl:AddRectFilled(P(x, y + h / 2 - 3), P(x + w, y + h / 2 + 3), C(white))
    dl:AddRectFilled(P(x + w / 2 - 3, y), P(x + w / 2 + 3, y + h), C(white))
    dl:AddRectFilled(P(x, y + h / 2 - 1.7), P(x + w, y + h / 2 + 1.7), C(red))
    dl:AddRectFilled(P(x + w / 2 - 1.7, y), P(x + w / 2 + 1.7, y + h), C(red))
    dl:PopClipRect()
end

LUI.FLAGS.ru = function(dl, x, y, w, h)               -- Россия
    local P = imgui.ImVec2
    local s = h / 3
    dl:AddRectFilled(P(x, y), P(x + w, y + s), C({1, 1, 1}))
    dl:AddRectFilled(P(x, y + s), P(x + w, y + 2 * s), C({0.00, 0.22, 0.65}))
    dl:AddRectFilled(P(x, y + 2 * s), P(x + w, y + h), C({0.84, 0.17, 0.13}))
end

LUI.FLAGS.none = function(dl, x, y, w, h)             -- запасной вариант для языка без флага
    dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), C(pal.track))
end

LUI.LANG_BTN_H, LUI.LANG_ROW_H, LUI.LANG_PAD = 30, 30, 4

local function langEntry()
    return i18n.LANGS[math.max(0, math.min(#i18n.LANGS - 1, ui.lang[0])) + 1]
end

local function DrawLangFlag(dl, id, x, y)
    local draw = LUI.FLAGS[id] or LUI.FLAGS.none
    draw(dl, x, y, LUI.FLAG_W, LUI.FLAG_H)
    dl:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + LUI.FLAG_W, y + LUI.FLAG_H), C(pal.border, 0.9), 2)
end

-- ширина кнопки (по самому длинному названию языка) и её положение: прижата к правому краю окна
local function LangGeom()
    imgui.PushFont(fonts.bold)
    local mw = 0
    for _, l in ipairs(i18n.LANGS) do mw = math.max(mw, imgui.CalcTextSize(u8(l.name)).x) end
    imgui.PopFont()
    local bw = 10 + LUI.FLAG_W + 8 + mw + 10 + 12 + 10
    return bw, LAY.W - 24 - bw, 14
end

-- кнопка: флаг + название текущего языка + стрелка; клик раскрывает / закрывает список
local function LangButton(wp)
    local P = imgui.ImVec2
    local dl = imgui.GetWindowDrawList()
    local bw, x0, y0 = LangGeom()
    local bh = LUI.LANG_BTN_H
    local tmain = THEME.main
    local p = P(wp.x + x0, wp.y + y0)
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton('##langbtn', P(bw, bh)) then ui.langOpen = not ui.langOpen end
    if not ui.langOpen then Hint('Language') end
    local o = animTo('langdd', ui.langOpen and 1 or 0, 16)
    local h = animTo('langbtnh', imgui.IsItemHovered() and 1 or 0, 14)
    ui.langT = o

    dl:AddRectFilled(P(p.x - 1, p.y - 1), P(p.x + bw + 1, p.y + bh + 1), C(mix(pal.border, tmain, o)), 9)
    dl:AddRectFilled(p, P(p.x + bw, p.y + bh), C(mix(pal.field, pal.fieldH, h)), 8)
    local cur = langEntry()
    local fx, fy = p.x + 10, p.y + (bh - LUI.FLAG_H) / 2
    DrawLangFlag(dl, cur.id, fx, fy)
    imgui.PushFont(fonts.bold)
    local name = u8(cur.name)
    local ts = imgui.CalcTextSize(name)
    dl:AddText(P(fx + LUI.FLAG_W + 8, p.y + (bh - ts.y) / 2), C(pal.text), name)
    imgui.PopFont()
    -- стрелка: при открытии плавно переворачивается
    local cx, cy, k = p.x + bw - 16, p.y + bh / 2, 1 - 2 * o
    local cc = C(mix(pal.dim, tmain, math.max(h, o)))
    dl:AddLine(P(cx - 4.5, cy - 2 * k), P(cx, cy + 2 * k), cc, 1.8)
    dl:AddLine(P(cx, cy + 2 * k), P(cx + 4.5, cy - 2 * k), cc, 1.8)
end

-- список языков: рисуется ПОСЛЕ содержимого вкладок, чтобы лежать поверх панелей
local function LangList(wp)
    if not ui.open[0] then ui.langOpen = false end
    if ui.langT < 0.01 and not ui.langOpen then return end
    local P = imgui.ImVec2
    local dl = imgui.GetWindowDrawList()
    local bw, x0, y0 = LangGeom()
    local tmain = THEME.main
    local lh = #i18n.LANGS * LUI.LANG_ROW_H + LUI.LANG_PAD * 2
    local lx, ly = wp.x + x0, wp.y + y0 + LUI.LANG_BTN_H + 4
    local e = easeOut(ui.langT)

    local ga = gfx.galpha
    gfx.galpha = ga * math.min(1, ui.langT * 1.6)
    dl:PushClipRect(P(lx - 2, ly - 2), P(lx + bw + 2, ly + lh * e + 2), true)       -- список "выезжает" сверху вниз
    dl:AddRectFilled(P(lx - 1, ly - 1), P(lx + bw + 1, ly + lh + 1), C(pal.border), 10)
    dl:AddRectFilled(P(lx, ly), P(lx + bw, ly + lh), C({0.082, 0.088, 0.112}), 9)
    for i, l in ipairs(i18n.LANGS) do
        local rx, ry = lx + LUI.LANG_PAD, ly + LUI.LANG_PAD + (i - 1) * LUI.LANG_ROW_H
        local rw, rh = bw - LUI.LANG_PAD * 2, LUI.LANG_ROW_H - 2
        local rmin, rmax = P(rx, ry), P(rx + rw, ry + rh)
        imgui.SetCursorScreenPos(rmin)
        local pressed = false
        if ui.langOpen then pressed = imgui.InvisibleButton('##langrow' .. l.id, P(rw, rh)) end
        local hov = ui.langOpen and imgui.IsItemHovered()
        local h = animTo('langrowh' .. l.id, hov and 1 or 0, 14)
        local s = animTo('langrows' .. l.id, (ui.lang[0] == i - 1) and 1 or 0, 14)
        dl:AddRectFilled(rmin, rmax, C(pal.fieldH, h), 6)
        if s > 0.01 then
            dl:AddRectFilled(rmin, rmax, C(tmain, 0.16 * s), 6)
            dl:AddRectFilled(P(rx, ry + 6), P(rx + 3, ry + rh - 6), C(tmain, s), 2)
        end
        DrawLangFlag(dl, l.id, rx + 10, ry + (rh - LUI.FLAG_H) / 2)
        imgui.PushFont(fonts.bold)
        local name = u8(l.name)
        local ts = imgui.CalcTextSize(name)
        dl:AddText(P(rx + 10 + LUI.FLAG_W + 8, ry + (rh - ts.y) / 2), C(mix(pal.dim, pal.text, math.max(s, h * 0.7))), name)
        imgui.PopFont()
        if pressed then ui.lang[0] = i - 1; ui.langOpen = false end
    end
    dl:PopClipRect()
    gfx.galpha = ga

    -- клик мимо кнопки и списка закрывает список
    if ui.langOpen and imgui.IsMouseClicked(0) then
        local m = imgui.GetIO().MousePos
        local inBtn = m.x >= wp.x + x0 and m.x <= wp.x + x0 + bw and m.y >= wp.y + y0 and m.y <= wp.y + y0 + LUI.LANG_BTN_H
        local inList = m.x >= lx and m.x <= lx + bw and m.y >= ly and m.y <= ly + lh
        if not inBtn and not inList then ui.langOpen = false end
    end
end

-- ----------------------------------------------------------------------------
--  Главное окно
-- ----------------------------------------------------------------------------
imgui.OnFrame(
    function() return ui.open ~= nil and (ui.open[0] or ui.alpha > 0.003) end,
    function()
        -- before-кадр: шрифты меняются только здесь, вне NewFrame / Render
        if FNT.rebuildReq then FNT.rebuild() end
    end,
    function(self)
        local io = imgui.GetIO()
        local dt = io.DeltaTime
        syncLang()                                  -- язык из combo (или из загруженного конфига)
        applyUiFont()                               -- шрифт интерфейса из конфига

        -- как только меню закрывается, курсор и управление сразу возвращаются игре,
        -- а окно просто плавно гаснет
        self.HideCursor = not ui.open[0]

        -- открытие / закрытие
        local target = ui.open[0] and 1 or 0
        ui.alpha = ui.alpha + (target - ui.alpha) * math.min(1, dt * 11 * ui.animSpeed[0])
        if math.abs(target - ui.alpha) < 0.004 then ui.alpha = target end
        if ui.open[0] and not ui.wasOpen then ui.contentT = 0; refreshNick(); FNT.poll(true) end
        ui.wasOpen = ui.open[0]

        -- история FPS
        table.remove(gfx.fpsHist, 1)
        gfx.fpsHist[#gfx.fpsHist + 1] = io.Framerate
        Dev.fps = io.Framerate

        -- цвет темы в стиле imgui (после смены пресета заново ставим и остальные цвета стиля)
        if THEME.dirty then THEME.applyStyle() end
        local tmain = THEME.main
        local sc = imgui.GetStyle().Colors
        sc[imgui.Col.Header]        = imgui.ImVec4(tmain[1], tmain[2], tmain[3], 0.25)
        sc[imgui.Col.HeaderHovered] = imgui.ImVec4(tmain[1], tmain[2], tmain[3], 0.35)
        sc[imgui.Col.HeaderActive]  = imgui.ImVec4(tmain[1], tmain[2], tmain[3], 0.45)
        sc[imgui.Col.TextSelectedBg] = imgui.ImVec4(tmain[1], tmain[2], tmain[3], 0.35)

        -- поисковый запрос
        local okq, rawq = pcall(function() return u8:decode(ffi.string(ui.search)) end)
        ui.query = okq and trim(lower(rawq)) or ''
        local searching = ui.query ~= ''
        ui.results = searching and runSearch(ui.query) or nil
        ui.gearHit, ui.popBusy = false, false
        ui.fieldActive = false
        if searching or not ui.open[0] then ui.popOpen = false end
        if not ui.open[0] then SIDE.panel = nil; WORDS.openId = nil; SOFT.adm.open = false; SOFT.adm.edit = nil; ctl.far.rulesOpen = false; ctl.far.logOpen = false end

        gfx.galpha = ui.alpha
        imgui.SetNextWindowSize(imgui.ImVec2(LAY.W, LAY.H), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2),
            imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, ui.alpha)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoScrollbar +
            imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoBackground + imgui.WindowFlags.NoSavedSettings
        if not ui.open[0] then flags = flags + imgui.WindowFlags.NoInputs end   -- пока гаснет, окно не ловит мышь
        imgui.Begin('##collapse_main', nil, flags)

        local wp = imgui.GetWindowPos()
        local dl = imgui.GetWindowDrawList()
        local function V(x, y) return imgui.ImVec2(wp.x + x, wp.y + y) end

        -- ===== фон =====
        dl:AddRectFilled(V(0, 0), V(LAY.W, LAY.H), C(pal.border), 11)
        dl:AddRectFilled(V(1, 1), V(LAY.W - 1, LAY.H - 1), C(pal.bg), 10)
        dl:AddRectFilled(V(1, 1), V(LAY.SIDE + 20, LAY.H - 1), C(pal.side), 10)
        dl:AddRectFilled(V(LAY.SIDE, 1), V(LAY.SIDE + 20, LAY.H - 1), C(pal.bg), 0)
        dl:AddRectFilled(V(LAY.SIDE - 1, 1), V(LAY.SIDE, LAY.H - 1), C(pal.border))

        -- ===== логотип: орбиты, схлопывающиеся в точку (COLLAPSE) =====
        do
            local lt, gx, gy = os.clock() * ui.animSpeed[0], 37, 35
            local pulse = 0.5 + 0.5 * math.sin(lt * 3.0)
            dl:AddRectFilled(V(20, 18), V(54, 52), C(tmain, 0.16), 9)
            dl:AddCircleFilled(V(gx, gy), 7 + 2 * pulse, C(tmain, 0.10), 20)                 -- мягкое свечение в центре
            dl:PathArcTo(V(gx, gy), 12.5, lt * 0.9, lt * 0.9 + math.pi * 1.55, 28)         -- внешняя орбита, по часовой
            dl:PathStroke(C(tmain), false, 2.4)
            dl:PathArcTo(V(gx, gy), 8.0, 1.0 - lt * 1.5, 1.0 - lt * 1.5 + math.pi * 1.15, 24)   -- внутренняя, против часовой
            dl:PathStroke(C(tmain, 0.7), false, 2.0)
            dl:AddCircleFilled(V(gx, gy), 2.0 + 0.7 * pulse, C(tmain), 12)                   -- ядро пульсирует
        end
        imgui.PushFont(fonts.title)
        dl:AddText(V(64, 14), C(pal.text), 'COLLAPSE')
        imgui.PopFont()
        imgui.PushFont(fonts.small)
        dl:AddText(V(65, 40), C(pal.dim), 'xMercy  |  v1.0')
        imgui.PopFont()

        -- ряд иконок под логотипом (история уведомлений, информация о скрипте)
        SIDE.drawButtons(dl, wp, V, tmain)
        dl:AddRectFilled(V(20, 94), V(LAY.SIDE - 20, 95), C(pal.border))

        imgui.PushFont(fonts.small)
        dl:AddText(V(22, 104), C(pal.dim, 0.7), u8(tr('NAVIGATION')))
        imgui.PopFont()

        -- ===== вкладки (сайдбар) =====
        local ind = animTo('tabind', ui.tab, 14)
        local iy = LAY.TAB_Y + (ind - 1) * LAY.TAB_H
        dl:AddRectFilledMultiColor(V(12, iy), V(LAY.SIDE - 12, iy + 40),
            C(tmain, 0.22), C(tmain, 0.0), C(tmain, 0.0), C(tmain, 0.22))
        dl:AddRectFilled(V(12, iy + 8), V(15, iy + 32), C(tmain), 2)

        for i, tb in ipairs(tabs) do
            local y = LAY.TAB_Y + (i - 1) * LAY.TAB_H
            imgui.SetCursorScreenPos(V(12, y))
            if imgui.InvisibleButton('##tab' .. i, imgui.ImVec2(LAY.SIDE - 24, 40)) and (ui.tab ~= i or searching) then
                ui.tab = i
                ui.contentT = 0
                ui.popOpen = false
                SIDE.panel = nil
                clearSearch()
            end
            local ha = animTo('tabh' .. i, imgui.IsItemHovered() and 1 or 0, 14)
            local sel = clamp(1 - math.abs(ind - i), 0, 1)
            dl:AddRectFilled(V(12, y), V(LAY.SIDE - 12, y + 40), C(pal.white, 0.035 * ha), 7)
            Icon(tb.icon, wp.x + 34, wp.y + y + 20, C(mix(mix(pal.dim, pal.text, ha * 0.7), tmain, sel)))
            imgui.PushFont(fonts.bold)
            dl:AddText(V(56, y + 10), C(mix(pal.dim, pal.text, math.max(sel, ha * 0.7))), u8(tr(tb.name)))
            imgui.PopFont()
        end

        -- ===== карточка игрока =====
        dl:AddRectFilled(V(12, LAY.H - 76), V(LAY.SIDE - 12, LAY.H - 16), C(pal.panel), 9)
        dl:AddCircleFilled(V(38, LAY.H - 46), 15, C(tmain, 0.22), 24)
        imgui.PushFont(fonts.bold)
        local initial = u8(me.nick:sub(1, 1):upper())
        local isz = imgui.CalcTextSize(initial)
        dl:AddText(V(38 - isz.x / 2, LAY.H - 46 - isz.y / 2), C(tmain), initial)
        imgui.PopFont()
        dl:PushClipRect(V(58, LAY.H - 76), V(LAY.SIDE - 14, LAY.H - 16), true)
        -- ник и ID одним текстом: Kratos_Core [312].
        -- Если не помещается, сокращается только ник (с ".."), ID всегда остаётся виден.
        -- (раньше ID рисовался отдельным текстом другим шрифтом, а его позиция считалась по ширине ника,
        --  измеренной шрифтом ID, поэтому ID "уезжал" относительно ника)
        local availW = (LAY.SIDE - 14) - 58
        local idStr = me.id and (' [' .. me.id .. ']') or ''
        local shown, cut = me.nick, false
        while #shown > 1 and imgui.CalcTextSize(u8(shown .. (cut and '..' or '') .. idStr)).x > availW do
            shown, cut = shown:sub(1, -2), true
        end
        if cut then shown = shown .. '..' end
        dl:AddText(V(58, LAY.H - 62), C(pal.text), u8(shown .. idStr))
        -- вторая строка: "59 FPS | 07:22" (FPS отключены в настройках - "Online | 07:22")
        imgui.PushFont(fonts.small)
        local sub = (ui.showFps[0] and (math.floor(io.Framerate + 0.5) .. ' FPS') or u8(tr('Online'))) ..
            ' | ' .. os.date('%H:%M')
        dl:AddText(V(58, LAY.H - 42), C(pal.dim), sub)
        imgui.PopFont()
        dl:PopClipRect()

        -- ===== шапка =====
        local tb = tabs[ui.tab]
        imgui.PushFont(fonts.title)
        dl:AddText(V(LAY.SIDE + 24, 14), C(pal.text), u8(tr(searching and 'Search' or tb.name)))
        imgui.PopFont()

        -- подвкладки
        local sx = LAY.SIDE + 24
        local pos = {}
        if searching then
            imgui.PushFont(fonts.bold)
            dl:AddText(V(sx, 52), C(pal.dim), u8(trf('%d found', #ui.results)))
            imgui.PopFont()
            dl:AddRectFilled(V(LAY.SIDE, 79), V(LAY.W - 1, 80), C(pal.border))
        else
        for j, sname in ipairs(tb.subs) do
            imgui.PushFont(fonts.bold)
            local tw = imgui.CalcTextSize(u8(tr(sname))).x
            imgui.PopFont()
            imgui.SetCursorScreenPos(V(sx, 50))
            if imgui.InvisibleButton('##sub' .. ui.tab .. j, imgui.ImVec2(tw, 26)) and ui.sub[ui.tab] ~= j then
                ui.sub[ui.tab] = j
                ui.contentT = 0
                ui.popOpen = false
            end
            local ha = animTo('subh' .. ui.tab .. j, imgui.IsItemHovered() and 1 or 0, 14)
            local sel = (ui.sub[ui.tab] == j) and 1 or 0
            local sa = animTo('subs' .. ui.tab .. j, sel, 14)
            imgui.PushFont(fonts.bold)
            dl:AddText(V(sx, 52), C(mix(pal.dim, pal.text, math.max(sa, ha * 0.7))), u8(tr(sname)))
            imgui.PopFont()
            pos[j] = {x = sx, w = tw}
            sx = sx + tw + 28
        end
        local cur = pos[ui.sub[ui.tab]]
        local ux = animTo('ulx', cur.x, 16)
        local uw = animTo('ulw', cur.w, 16)
        dl:AddRectFilled(V(LAY.SIDE, 79), V(LAY.W - 1, 80), C(pal.border))
        dl:AddRectFilled(V(ux, 78), V(ux + uw, 80), C(tmain), 1)
        end

        -- плашка с клавишей меню (справа, на уровне подвкладок)
        imgui.PushFont(fonts.small)
        local mk = u8(tr('Menu key') .. ': ' .. ctl.bindName(binds.menu))
        local mw = imgui.CalcTextSize(mk).x
        dl:AddRectFilled(V(LAY.W - 24 - mw - 18, 52), V(LAY.W - 24, 72), C(pal.field), 10)
        dl:AddText(V(LAY.W - 24 - mw - 9, 55), C(pal.dim), mk)
        imgui.PopFont()

        -- ===== поиск по функциям =====
        local sbw, sbh = 260, 30
        local sbx, sby = math.floor(LAY.SIDE + (LAY.W - LAY.SIDE - sbw) / 2), 14   -- по центру шапки
        local sf = animTo('sfocus', ui.searchActive and 1 or 0, 14)
        dl:AddRectFilled(V(sbx - 1, sby - 1), V(sbx + sbw + 1, sby + sbh + 1), C(mix(pal.border, tmain, sf)), 9)
        dl:AddRectFilled(V(sbx, sby), V(sbx + sbw, sby + sbh), C(pal.field), 8)
        local lcx, lcy = wp.x + sbx + 17, wp.y + sby + 14
        local lcol = C(mix(pal.dim, tmain, sf))
        dl:AddCircle(imgui.ImVec2(lcx, lcy), 5, lcol, 16, 1.6)
        dl:AddLine(imgui.ImVec2(lcx + 3.6, lcy + 3.6), imgui.ImVec2(lcx + 8, lcy + 8), lcol, 1.8)
        if not searching then
            dl:AddText(V(sbx + 34, sby + 6), C(pal.dim, 0.75), u8(tr('Search functions...')))
        end
        imgui.SetCursorScreenPos(V(sbx + 32, sby + 3))
        imgui.SetNextItemWidth(sbw - 32 - 30)
        if ui.focusSearch then
            imgui.SetKeyboardFocusHere()
            ui.focusSearch = false
        end
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0, 0, 0, 0))
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(2, 4))
        imgui.InputText('##collapse_search', ui.search, ffi.sizeof(ui.search))
        ui.searchActive = imgui.IsItemActive()
        if ui.searchActive and not listening and binds.menu.key ~= 0
            and (not searchConsumesMenuKey(binds.menu.key) or (binds.menu.mod or 0) ~= 0)
            and imgui.IsKeyPressed(binds.menu.key) and ctl.modOk(binds.menu) then
            ui.open[0] = false
            ui.searchActive = false
            ui.menuKeyBlock = true
        end
        imgui.PopStyleVar()
        imgui.PopStyleColor(3)
        if searching then
            imgui.SetCursorScreenPos(V(sbx + sbw - 28, sby + 3))
            if imgui.InvisibleButton('##collapse_sclear', imgui.ImVec2(24, 24)) then clearSearch() end
            local xh = animTo('sclear', imgui.IsItemHovered() and 1 or 0, 14)
            local xc = C(mix(pal.dim, pal.text, xh))
            local cx2, cy2 = wp.x + sbx + sbw - 16, wp.y + sby + 15
            dl:AddLine(imgui.ImVec2(cx2 - 4, cy2 - 4), imgui.ImVec2(cx2 + 4, cy2 + 4), xc, 1.6)
            dl:AddLine(imgui.ImVec2(cx2 + 4, cy2 - 4), imgui.ImVec2(cx2 - 4, cy2 + 4), xc, 1.6)
        end

        -- переключатель языка (кнопка в правом верхнем углу; сам список рисуется ниже, поверх содержимого)
        LangButton(wp)

        -- бегущая линия по периметру окна (бесконечный круг)
        if not LUI.perim then LUI.perim = buildPerimeter() end
        ui.runD = (ui.runD + dt * 300 * ui.animSpeed[0]) % LUI.perim.total
        local N, STEP = 48, 6                      -- хвост: 48 * 6 = 288 px
        local ax, ay = perimPoint(ui.runD)
        for k = 1, N do
            local bx, by = perimPoint(ui.runD - k * STEP)
            local fade = (1 - (k - 1) / N) ^ 2
            dl:AddLine(V(ax, ay), V(bx, by), C(tmain, 0.95 * fade), 2)
            ax, ay = bx, by
        end

        -- ===== содержимое =====
        ui.contentT = math.min(1, ui.contentT + dt * 4.2 * ui.animSpeed[0])
        local e = easeOut(ui.contentT)
        gfx.galpha = ui.alpha * e
        ui.offY = (1 - e) * 18
        ui.cpos = V(LAY.SIDE + 24, 98)
        imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, ui.alpha * e)
        if searching then drawSearchResults() else content[ui.tab][ui.sub[ui.tab]]() end
        imgui.PopStyleVar()
        gfx.galpha = ui.alpha

        DrawPopup(wp)
        LangList(wp)
        DrawLogWindow(wp)
        SIDE.draw(wp)
        WORDS.draw(wp)
        SOFT.adm.draw(wp)
        if ctl.far.draw then ctl.far.draw(wp) end

        imgui.End()
        imgui.PopStyleVar(2)

        -- ===== подсказка: пауза перед появлением, плавное появление, небольшая задержка перед скрытием =====
        local now = os.clock()
        local want = 0
        local hintsOn = ui.open[0] and B('m_hints', true)[0]
        local hintBlocked = gfx.hintBlock                  -- курсор над квадратом цвета: своя подсказка не нужна
        gfx.hintBlock = false
        if hintBlocked then gfx.hintState.text, gfx.hintState.seen = nil, nil end
        if gfx.hintState.text and hintsOn then
            if gfx.hintState.id ~= gfx.hintState.title then
                gfx.hintState.id = gfx.hintState.title
                -- если подсказка уже видна - переключаемся без паузы
                gfx.hintState.t0 = ((gfx.anim['hint'] or 0) > 0.3) and (now - 10) or now
            end
            if now - gfx.hintState.t0 > CONST.HINT_DELAY then want = 1 end
            gfx.hintState.lastText, gfx.hintState.lastTitle = gfx.hintState.text, gfx.hintState.title
            gfx.hintState.seen = now
        else
            gfx.hintState.id = nil
            -- курсор ушёл: подсказка ещё чуть-чуть остаётся на экране
            if hintsOn and gfx.hintState.seen and now - gfx.hintState.seen < CONST.HINT_LINGER and (gfx.anim['hint'] or 0) > 0.5 then
                want = 1
            end
        end
        gfx.hintState.text = nil
        local ha = animTo('hint', want, want == 1 and 18 or 34)
        if ha > 0.01 and gfx.hintState.lastText and not hintBlocked then DrawHint(ha) end
    end
)

-- ----------------------------------------------------------------------------
--  Уведомления (toast)
-- ----------------------------------------------------------------------------

-- Иконка уведомления: круглая плашка с символом по виду уведомления
--   info - буква "i", success - галочка, error - восклицательный знак.
-- cx, cy - центр, r - радиус плашки, k - масштаб символа (для анимации появления).
local function ToastIcon(dl, kind, cx, cy, r, col, k)
    local P = imgui.ImVec2
    local function q(x, y) return P(cx + x * k, cy + y * k) end
    dl:AddCircleFilled(P(cx, cy), r + 4, C(col, 0.10), 28)         -- мягкое свечение
    dl:AddCircleFilled(P(cx, cy), r, C(col, 0.20), 28)             -- плашка
    dl:AddCircle(P(cx, cy), r, C(col, 0.90), 28, 1.5)              -- кольцо
    if kind == 'success' then
        dl:PathLineTo(q(-5, 0.5)); dl:PathLineTo(q(-1.8, 4)); dl:PathLineTo(q(5, -3.8))
        dl:PathStroke(C(col), false, 2.2)
    elseif kind == 'error' then
        dl:AddLine(q(0, -5.5), q(0, 1.5), C(col), 2.2)
        dl:AddCircleFilled(q(0, 5.2), 1.5 * k, C(col), 10)
    else
        dl:AddCircleFilled(q(0, -5.2), 1.5 * k, C(col), 10)
        dl:AddLine(q(0, -1.5), q(0, 5.5), C(col), 2.2)
    end
end

imgui.OnFrame(
    function() return #gfx.toasts > 0 end,
    function()
        if FNT.rebuildReq then FNT.rebuild() end        -- запрос на загрузку выбранного шрифта может прийти и при закрытом меню
    end,
    function(self)
        applyUiFont()                  -- заодно создаёт ключ шрифта в конфиге, даже если меню ещё не открывали
        -- состояние курсора должно совпадать с главным окном, иначе два окна спорят за курсор и он мерцает
        self.HideCursor = not ui.open[0]
        local dl = imgui.GetBackgroundDrawList()
        local ds = imgui.GetIO().DisplaySize
        local now = os.clock()
        local P = imgui.ImVec2
        for i = #gfx.toasts, 1, -1 do
            if now - gfx.toasts[i].t0 > gfx.toasts[i].life then table.remove(gfx.toasts, i) end
        end
        local y = ds.y - 30
        for i = #gfx.toasts, 1, -1 do
            local t = gfx.toasts[i]
            local age = now - t.t0
            local inT = easeOut(clamp(age / 0.35, 0, 1))
            local outT = clamp((t.life - age) / 0.35, 0, 1)
            gfx.galpha = math.min(inT, outT)
            local col = CONST.TOAST_COL[t.kind] or CONST.TOAST_COL.info   -- обычное уведомление - синее

            -- размеры считаем один раз: заголовок "COLLAPSE" (для ошибки + " | Ошибка") и текст с переносом по ширине
            if not t.lines then
                -- шрифт выбирается при создании уведомления и дальше не меняется (иначе размеры разъедутся)
                local fs = FNT.FONTSETS[selFontIdx('font_toast', FNT.DEFAULT_FONT) + 1]
                if fs and fs.lazy then                       -- шрифт уведомлений ещё не загружен: пока обычный, загрузка запрошена
                    if not FNT.tried[fs.name] then FNT.rebuildReq, FNT.quiet = true, true end
                    fs = nil
                end
                t.font = fs and {reg = fs.toast, bold = fs.toastb} or {reg = fonts.toast, bold = fonts.toastb}
                imgui.PushFont(t.font.bold)
                t.head = {{'COLLAPSE', 'text'}}
                if t.kind == 'error' then
                    t.head[2] = {' | ', 'dim'}
                    t.head[3] = {tr('Error'), 'err'}
                end
                t.hw = 0
                for _, part in ipairs(t.head) do
                    part.w = imgui.CalcTextSize(u8(part[1])).x
                    t.hw = t.hw + part.w
                end
                t.hh = imgui.GetTextLineHeight()
                imgui.PopFont()

                imgui.PushFont(t.font.reg)
                t.lines = wrapLines(t.text, math.min(CONST.TOAST_WRAP, ds.x * 0.5))
                t.tw = t.hw
                for _, ln in ipairs(t.lines) do
                    t.tw = math.max(t.tw, imgui.CalcTextSize(u8(ln)).x)
                end
                t.lh = imgui.GetTextLineHeight()
                imgui.PopFont()
            end

            local n = #t.lines
            local padL, padR, padT, padB, gap = 50, 28, 16, 20, 6
            local bw = t.tw + padL + padR
            local bh = padT + t.hh + gap + n * t.lh + (n - 1) * 3 + padB
            local x = ds.x - 24 - bw + (1 - inT) * 50
            local top = y - bh
            local cy0 = top + padT + (t.hh + gap + n * t.lh + (n - 1) * 3) / 2   -- центр по высоте всего текста (заголовок + все строки)
            dl:AddRectFilled(P(x - 1, top - 1), P(x + bw + 1, top + bh + 1), C(pal.border), 10)
            dl:AddRectFilled(P(x, top), P(x + bw, top + bh), C(pal.panel), 9)
            dl:AddRectFilled(P(x, top + 10), P(x + 4, top + bh - 10), C(col), 2)
            ToastIcon(dl, t.kind, x + 28, cy0, 13, col, 0.6 + 0.4 * inT)

            -- первая строка: COLLAPSE [| Ошибка]
            imgui.PushFont(t.font.bold)
            local hx = x + padL
            for _, part in ipairs(t.head) do
                local pc = (part[2] == 'err') and col or ((part[2] == 'dim') and pal.dim or pal.text)
                dl:AddText(P(hx, top + padT), C(pc), u8(part[1]))
                hx = hx + part.w
            end
            imgui.PopFont()

            -- ниже: текст уведомления
            imgui.PushFont(t.font.reg)
            for k, ln in ipairs(t.lines) do
                dl:AddText(P(x + padL, top + padT + t.hh + gap + (k - 1) * (t.lh + 3)), C(pal.text), u8(ln))
            end
            imgui.PopFont()

            local prog = clamp(1 - age / t.life, 0, 1)
            dl:AddRectFilled(P(x + 10, top + bh - 5), P(x + 10 + (bw - 20) * prog, top + bh - 3), C(col, 0.6), 1)
            y = top - 12
        end
        gfx.galpha = 1
    end
)

-- ----------------------------------------------------------------------------
--  main
-- ----------------------------------------------------------------------------
-- ----------------------------------------------------------------------------
--  Из MultiMenu.lua: сброс лимита (/limit 30 -> /limit 0), шар (/balloon + кликер мини-игры), тренер капчи (/asd).
--  CEF-события читаются тем же разбором пакетов 220, что и у журнала CEF (без arizona-events).
-- ----------------------------------------------------------------------------
do
    local MM = {}
    ctl.mm = MM
    binds.mm_limit_key = binds.mm_limit_key or {key = 0x43, mod = 0}       -- C
    binds.mm_balloon_key = binds.mm_balloon_key or {key = 0x4C, mod = 0x42}   -- B + L
    binds.cap_key = binds.cap_key or {key = 0, mod = 0}                    -- не назначена

    local function on(k) return B(k, false)[0] end
    math.randomseed(os.time())

    -- ---------- сброс лимита ----------
    function MM.limit()
        if MM.limitBusy then return end
        MM.limitBusy = true
        lua_thread.create(function()
            pcall(function()
                sampSendChat('/limit 30')
                wait(100)
                sampSendChat('/limit 0')
            end)
            MM.limitBusy = false
        end)
    end

    -- ---------- шар ----------
    -- сервер открывает мини-игру событием setActiveView со списком окон; пока среди них "Clicker", шлём клики
    MM.clicker, MM.clickT = false, 0
    function MM.onCef(text)
        local ev, data = text:match("^window%.executeEvent%('(.-)', [`'](%b[])[`']%);$")
        if ev == 'event.setActiveView' then MM.clicker = data:find('"Clicker"', 1, true) ~= nil end
    end

    local function cefSend(msg)                        -- клиентское CEF-событие: [220][18][len u16][текст][0 u32]
        local bs = raknetNewBitStream()
        pcall(function()
            raknetBitStreamWriteInt8(bs, 220)
            raknetBitStreamWriteInt8(bs, 18)
            raknetBitStreamWriteInt16(bs, #msg)
            raknetBitStreamWriteString(bs, msg)
            raknetBitStreamWriteInt32(bs, 0)
            raknetSendBitStream(bs)
        end)
        raknetDeleteBitStream(bs)
    end

    -- ---------- тренер капчи ----------
    -- копия текстдрава "Проверка на робота": фон, пять ячеек и цифры из белых прямоугольников.
    -- Элементы цифры: {сдвиг X, сдвиг Y, высота, конец рамки относительно X}. Пятая цифра всегда 0, как в оригинале.
    local DIG = {
        [0] = {{-5, 7, 3, 5}},
        [1] = {{-3, 0, 4.5, -17}, {3, 0, 4.5, 17}},
        [2] = {{8, 7, 0.8, -17}, {-6, 25, 0.8, 17}},
        [3] = {{10, 7, 1, -17}, {10, 25, 1, -17}},
        [4] = {{10, 0, 1.8, -10}, {10, 25, 2, -17}},
        [5] = {{-8, 7, 0.8, 17}, {10, 25, 1, -17}},
        [6] = {{-7.5, 7, 0.8, 17}, {10, 25, 1, -10}},
        [7] = {{-13, 7, 3.75, 5}},
        [8] = {{10, 7, 1, -10}, {10, 25, 1, -10}},
        [9] = {{10, 6, 1, -10}, {10, 25, 1, -17}},
    }
    local TD0, DLG = 2000, 8813                        -- высокие ID текстдравов, чтобы не задеть серверные
    local CAP = {n = 0, active = false, code = '', t0 = 0, hist = {}}
    MM.cap = CAP

    local function td(text, x, y, lh, color, bx, by)
        CAP.n = CAP.n + 1
        local id = TD0 + CAP.n
        sampTextdrawCreate(id, text, x, y)
        sampTextdrawSetLetterSizeAndColor(id, 0, lh, 0x80808080)
        sampTextdrawSetBoxColorAndSize(id, 1, color, bx, by)
        return id
    end

    function CAP.clear()
        for i = 1, CAP.n do pcall(sampTextdrawDelete, TD0 + i) end
        CAP.n = 0
    end

    function CAP.start()
        CAP.clear()
        td('LD_SPAC:white', 235, 120, 6.5, 0xFF1A2432, 395, 0)
        td('LD_SPAC:white', 240, 125, 5.5, 0xFF759DA3, 390, 0)
        local digits = {0, 0, 0, 0, 0}
        for i = 1, 4 do digits[i] = math.random(0, 9) end
        for i = 1, 5 do
            local x = 225 + i * 30
            sampTextdrawSetAlign(td('usebox', x, 130, 4.5, 0xFF1A2432, 30, 25.0), 2)
            for _, e in ipairs(DIG[digits[i]]) do td('LD_SPAC:white', x + e[1], 130 + e[2], e[3], 0xFF759DA3, x + e[4], 0) end
        end
        CAP.code = table.concat(digits)
        local best = F('cap_best', 0)[0]
        sampShowDialog(DLG, '{F89168}Проверка на робота', string.format('{FFFFFF}Введите {C6FB4A}5{FFFFFF} символов.\n{C0C0C0}Рекорд: {24ff86}%s',
            best > 0 and string.format('%.3f', best) or 'нет'), 'Принять', 'Отмена', 1)
        CAP.active, CAP.t0 = true, os.clock()
    end

    -- ответ на диалог (вызывается из onSendDialogResponse; на сервер ответ не уходит)
    function CAP.finish(button, input)
        local dt = os.clock() - CAP.t0
        CAP.clear()
        CAP.active = false
        if button ~= 1 then return end
        input = trim(input or '')
        local ok, best = input == CAP.code, F('cap_best', 0)
        if ok and (best[0] <= 0 or dt < best[0]) then
            best[0] = dt
            NotifyOk('New record: %.3f s', dt)
        elseif ok then
            Notify('Captcha: %.3f s (record %.3f s)', dt, best[0])
        else
            NotifyErr('Wrong code! %.3f s (%s | %s)', dt, CAP.code, input)
        end
        table.insert(CAP.hist, 1, {ts = os.time(), t = dt, ok = ok, code = input})
        if #CAP.hist > 10 then table.remove(CAP.hist) end
    end

    function CAP.cancel()
        if not CAP.active then return end
        pcall(sampCloseCurrentDialogWithButton, 0)
        CAP.clear()
        CAP.active = false
    end

    function CAP.startNow()
        ui.open[0] = false
        CAP.start()
    end

    function CAP.resetRecord()
        F('cap_best', 0)[0] = 0
        Notify('Record reset')
    end

    function MM.tick()
        if not isSampAvailable() then return end
        local limitOn, balloonOn, capOn = on('mm_limit_on'), on('mm_balloon_on'), on('cap_enable')
        local free = (limitOn or balloonOn or capOn) and ctl.keysFree()
        if limitOn and free and isCharInAnyCar(PLAYER_PED) and ctl.bindFire(binds.mm_limit_key) then MM.limit() end
        if balloonOn then
            if free and ctl.bindFire(binds.mm_balloon_key) then sampSendChat('/balloon') end
            if MM.clicker then
                local now = os.clock()
                if now - MM.clickT >= 0.01 then                       -- не чаще 100 раз в секунду
                    MM.clickT = now
                    cefSend('clickMinigame')
                end
            end
        else
            MM.clicker = false
        end
        if capOn then
            if CAP.active and os.clock() - CAP.t0 > 0.3 and not sampIsDialogActive() then      -- диалог закрыли, не ответив
                CAP.clear()
                CAP.active = false
            end
            if free and not CAP.active and ctl.bindFire(binds.cap_key) then CAP.start() end
        else
            CAP.cancel()
        end
    end

    -- ---------- страница Software -> Captcha trainer ----------
    SOFT.draw.captcha = function()
        Panel('Captcha trainer', 0, 0, LAY.COLW, LAY.CH, function()
            Keybind('Start key', binds.cap_key)
            if not SRCH.collecting then
                local best, last = F('cap_best', 0)[0], CAP.hist[1]
                InfoRow('Record', best > 0 and string.format('%.3f %s', best, tr('s')) or '-')
                InfoRow('Last result', last and string.format('%.3f %s', last.t, tr('s')) or '-')
            end
            imgui.Dummy(imgui.ImVec2(1, 6))
            Text('Turn the trainer on and assign a start key, or press Start now: the check appears and you type the digits in the dialog.', pal.dim)
            imgui.Dummy(imgui.ImVec2(1, 6))
            if Button('Start now', 34, true) then CAP.startNow() end
            if Button('Reset record', 34) then CAP.resetRecord() end
        end, nil, nil, function()
            SOFT.pageHeader('cap', LAY.COLW, 'Captcha trainer', B('cap_enable', false))
        end, 30)
        Panel('Attempts', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, function()
            if SRCH.collecting then return end
            if #CAP.hist == 0 then Text('No attempts yet', pal.dim) return end
            for _, h in ipairs(CAP.hist) do
                InfoRow(os.date('%H:%M:%S', h.ts), h.ok and string.format('%.3f %s', h.t, tr('s'))
                    or string.format('%s  (%s)', tr('Wrong'), h.code))
            end
        end)
    end

    -- ---------- подсказки и перевод ----------
    HINTS['Quick braking (ARZ)'] = 'Instant braking in a vehicle: sends /limit 30 and then /limit 0. The key is set in the gear menu.'
    HINTS['Auto balloon collection'] = 'The key sends /balloon. While the balloon mini-game is open, the clicks are sent automatically.'
    HINTS['Captcha trainer'] = 'Turns the trainer on or off.'
    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Quick braking (ARZ)'] = 'Быстрое торможение (ARZ)', ['Quick braking settings'] = 'Настройки быстрого торможения', ['Auto balloon collection'] = 'Автоматическая сборка шара', ['Auto balloon settings'] = 'Настройки автосборки шара',
        [HINTS['Quick braking (ARZ)']] = 'Мгновенное торможение в транспорте: отправляет /limit 30, а затем /limit 0. Клавиша задаётся в меню настроек.',
        [HINTS['Auto balloon collection']] = 'Клавиша отправляет /balloon. Пока открыта мини-игра с шаром, клики отправляются автоматически.',
        [HINTS['Captcha trainer']] = 'Включает и выключает тренер.',
        ['Captcha trainer'] = 'Тренер капчи', ['Check practice'] = 'Тренировка проверки', ['with a stopwatch'] = 'с секундомером',
        ['Start key'] = 'Клавиша запуска', ['Record'] = 'Рекорд', ['Last result'] = 'Последний результат', ['Start now'] = 'Запустить сейчас',
        ['Reset record'] = 'Сбросить рекорд', ['Attempts'] = 'Попытки', ['No attempts yet'] = 'Попыток ещё нет', ['Wrong'] = 'Неверно',
        ['Turn the trainer on and assign a start key, or press Start now: the check appears and you type the digits in the dialog.'] =
            'Включите тренер и назначьте клавишу запуска или нажмите «Запустить сейчас»: появится проверка, цифры вводятся в диалоге.',
        ['Record reset'] = 'Рекорд сброшен',
        ['New record: %.3f s'] = 'Новый рекорд: %.3f с', ['Captcha: %.3f s (record %.3f s)'] = 'Капча: %.3f с (рекорд %.3f с)',
        ['Wrong code! %.3f s (%s | %s)'] = 'Неверный код! %.3f с (%s | %s)',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Из ResHelper (Arzreshelper.lua): учёт дохода (сторонний доход, пейдеи, нефтевышки, такси) с привязкой к серверу
--  и автопиар. События читаются из строк чата (sampev.onServerMessage), без сторонних библиотек.
--  Данные: files\income_<сервер>.json (отдельный файл на каждый сервер), files\auto_ad.json, files\items_db.json.
-- ----------------------------------------------------------------------------
do
    local IR = {}
    ctl.ir = IR

    -- серверы Arizona 1-33: имя и IP; номер берём из списка админ-чекера (SOFT.adm.HOSTS), там нет только Home (33)
    local SERVERS = {
        {'Holiday', '80.66.82.132'}, {'Prescott', '185.169.134.166'}, {'Faraway', '80.66.82.82'}, {'Christmas', '80.66.82.54'},
        {'Queen-Creek', '80.66.82.200'}, {'Gilbert', '80.66.82.191'}, {'Page', '80.66.82.168'}, {'Yava', '80.66.82.113'},
        {'Surprise', '185.169.134.109'}, {'Wednesday', '80.66.82.128'}, {'Chandler', '185.169.134.44'}, {'Glendale', '185.169.134.171'},
        {'Show Low', '80.66.82.190'}, {'Sedona', '80.66.82.144'}, {'Payson', '185.169.134.174'}, {'Saint-Rose', '185.169.134.5'},
        {'Sun-City', '80.66.82.159'}, {'Kingman', '185.169.134.172'}, {'Winslow', '185.169.134.173'}, {'Scottdale', '185.169.134.43'},
        {'Red-Rock', '185.169.134.61'}, {'Brainburg', '185.169.134.45'}, {'Mirage', '80.66.82.39'}, {'Phoenix', '185.169.134.3'},
        {'Mesa', '185.169.134.59'}, {'Tucson', '185.169.134.4'}, {'Yuma', '185.169.134.107'}, {'Casa-Grande', '80.66.82.188'},
        {'Bumble Bee', '80.66.82.87'}, {'Love', '80.66.82.33'}, {'Drake', '80.66.82.22'}, {'Space', '80.66.82.199'},
        {'Home', '80.66.82.235'},
    }
    local HOSTS = SOFT.adm and SOFT.adm.HOSTS or {}
    IR.byHost, IR.names, IR.svItems = {}, {}, {'Current server'}
    for _, s in ipairs(SERVERS) do
        local host = s[1]:lower():gsub('[%s%-]', '') .. '.arizona-rp.com'
        s.num = HOSTS[s[2]] or HOSTS[host] or (s[1] == 'Home' and 33) or 99
        IR.byHost[s[2]], IR.byHost[host] = s[1], s[1]
    end
    table.sort(SERVERS, function(a, b) return a.num < b.num end)
    for _, s in ipairs(SERVERS) do
        IR.names[#IR.names + 1] = s[1]
        IR.svItems[#IR.svItems + 1] = string.format('%d. %s', s.num, s[1])
    end

    local CATS = {'im', 'shard', 'pay', 'oil', 'taxi'}
    local MAXLOG = 5000
    local SHARD_ORDER = {'Ведьмы', 'Лича', 'Медведя', 'Сердючки', 'Фрирен', 'NFT контейнера'}
    local SHARD_KEY, SHARD_ID = {}, {[9516] = 'Ведьмы', [9517] = 'Лича', [9680] = 'Медведя', [9681] = 'Сердючки', [9762] = 'Фрирен', [8089] = 'NFT контейнера'}
    for i, n in ipairs(SHARD_ORDER) do SHARD_KEY[n] = 'inc_sh' .. i end

    local function digits(s)
        local d = tostring(s or ''):gsub('%D', '')
        return tonumber(d)
    end
    local function fmt(n)
        local s = string.format('%.0f', math.abs(n or 0))
        s = s:reverse():gsub('(%d%d%d)', '%1.'):reverse():gsub('^%.', '')
        return (n and n < 0 and '-' or '') .. s
    end
    local function money(n) return fmt(n) .. '$' end

    -- ---------- файлы по серверам ----------
    local function path(name) return FNT.filesDir() .. '\\income_' .. name:gsub('[^%w]', '_') .. '.json' end
    local function load(name)
        local d = {}
        local f = io.open(path(name), 'rb')
        if f then
            local ok, t = pcall(decodeJson, f:read('*a'))
            f:close()
            if ok and type(t) == 'table' then d = t end
        end
        for _, k in ipairs(CATS) do d[k] = type(d[k]) == 'table' and d[k] or {} end
        return d
    end
    local function save(name, d)
        pcall(FNT.ensureFilesDir)
        local f = io.open(path(name), 'wb')
        if f then f:write(encodeJson(d)) f:close() end
    end

    IR.sv, IR.syncAt, IR.dirty, IR.rev, IR.view = nil, 0, false, 0, {}
    function IR.sync()                                           -- текущий сервер: при смене сохраняем старый файл и грузим новый
        local now = os.clock()
        if IR.sv and now - IR.syncAt < 2 then return IR.sv end
        IR.syncAt = now
        local ok, host = pcall(sampGetCurrentServerAddress)
        host = ok and type(host) == 'string' and host:match('^[^:]+') or ''
        local name = IR.byHost[host:lower()] or (host ~= '' and host) or 'Unknown'
        if name ~= IR.sv then
            if IR.sv and IR.dirty then save(IR.sv, IR.data) end
            IR.sv, IR.data, IR.dirty = name, load(name), false
            IR.rev = IR.rev + 1
        end
        return IR.sv
    end

    function IR.add(cat, e)
        IR.sync()
        local l = IR.data[cat]
        table.insert(l, 1, e)
        if #l > MAXLOG then l[#l] = nil end
        IR.dirty, IR.rev = true, IR.rev + 1
    end

    -- данные для показа: 0 - текущий сервер, иначе выбранный из списка
    function IR.dataFor(sel)
        IR.sync()
        local name = IR.names[sel]
        if not name or name == IR.sv then return IR.data, IR.sv end
        IR.view[name] = IR.view[name] or load(name)
        return IR.view[name], name
    end

    -- ---------- пейдей ----------
    local P = {active = false, sal = 0, dep = 0, az = 0, rub = 0, acc = {d = 0, a = 0, f = 0}, azb = {}, pend = {}, pendRub = {}, div = false, got = false}
    local function addAz(tbl, label, n)
        for _, e in ipairs(tbl) do
            if e.label == label then e.amount = e.amount + n return end
        end
        tbl[#tbl + 1] = {label = label, amount = n}
    end

    -- AZ / рубли, пришедшие вне чека: в текущий пейдей, в только что записанный (15 с) или в очередь до следующего
    local function coin(az, rub, label)
        if P.active then
            P.az, P.rub = P.az + az, P.rub + rub
            if az > 0 and label then addAz(P.azb, label, az) end
        elseif P.last and os.time() - P.lastT <= 15 and IR.data and IR.data.pay[1] == P.last then
            P.last.az, P.last.rub = (P.last.az or 0) + az, (P.last.rub or 0) + rub
            if az > 0 and label then
                P.last.azB = P.last.azB or {}
                addAz(P.last.azB, label, az)
            end
            IR.dirty, IR.rev = true, IR.rev + 1
        else
            local now = os.time()
            if az > 0 then P.pend[#P.pend + 1] = {n = az, t = now, label = label or 'Прочее'} end
            if rub > 0 then P.pendRub[#P.pendRub + 1] = {n = rub, t = now} end
        end
    end

    local function payFinish()
        P.active, P.endAt = false, nil
        local acc = P.acc.d + P.acc.a + P.acc.f
        if P.sal + P.dep + acc > 0 or P.az > 0 or P.rub > 0 then
            local e = {t = os.time(), salary = P.sal, deposit = P.dep, acc = acc, accB = {d = P.acc.d, a = P.acc.a, f = P.acc.f},
                       az = P.az, azB = P.azb, rub = P.rub}
            IR.add('pay', e)
            P.last, P.lastT = e, os.time()
        end
        P.acc, P.az, P.rub, P.azb = {d = 0, a = 0, f = 0}, 0, 0, {}
    end

    local function payLine(t)                                    -- строки внутри банковского чека
        if t:find('сумма в банке', 1, true) then
            local n = digits(t:match('%(([^%)]+)%)'))
            if n then P.sal = P.sal + n end
        elseif t:find('сумма на депозите', 1, true) then
            local n = digits(t:match('%(([^%)]+)%)'))
            if n then P.dep = n end
        elseif t:find('Баланс на донат', 1, true) then
            local n = tonumber(t:match('%+(%d+) AZ'))
            if n then P.az = P.az + n addAz(P.azb, 'Баланс доната', n) end
        elseif t:find('Семейные выплаты', 1, true) then
            local n = digits(t:match('Семейные выплаты[^%d]*([%d%.]+)'))
            if n then P.acc.f = P.acc.f + n end
        end
    end

    local function payroll(t)                                    -- true - строка обработана
        local az = t:match('Вы получили (%d+) AZ')
        if az and not t:find('донат', 1, true) then
            P.pend[#P.pend + 1] = {n = tonumber(az), t = os.time(), label = t:match('^%[([^%]]+)%]') or 'Прочее'}
            return true
        end
        if t:find('пенсию бывшего администратора', 1, true) then
            local n = tonumber(t:match('размере (%d+) AZ'))
            if n then coin(n, 0, 'Пенсия бывшего администратора') end
            return true
        end
        if t:find('AZ COINS на баланс аккаунта', 1, true) then
            local n = tonumber(t:match('%+(%d+) AZ COINS'))
            local label = (t:find('Монет Контейнера', 1, true) and 'Монеты Контейнера') or (t:find('Монет таксиста', 1, true) and 'Монеты таксиста') or 'Монеты (AZ COINS)'
            if n then coin(n, 0, label) end
            return true
        end
        if t:find('Монету Новой Мафии', 1, true) then
            local n = tonumber(t:match('%+(%d+) AZ'))
            if n then coin(n, 0, 'Монета Новой Мафии') end
            return true
        end
        if t:find('игровых рублей на баланс', 1, true) then
            local n = tonumber(t:match('%+(%d+) игровых рублей'))
            if n then coin(0, n) end
            return true
        end
        if t:find('аксессуара Космическое сердце', 1, true) and t:find('Вы получили', 1, true) then
            if not P.got then
                local n = digits(t:match('(%d+%.?%d*)'))
                if n and n > 0 then P.acc.a, P.got = P.acc.a + n, true end
            end
            return true
        end
        if t:find('Дивидентный договор', 1, true) then
            P.div = true
            local n = digits(t:match('%+[^%s]+'))
            if n then P.acc.d = n end
            if P.active then payFinish() end
            return true
        end
        if t:find('БАНКОВСКИЙ ЧЕК', 1, true) then
            P.active, P.sal, P.dep, P.div, P.endAt, P.got = true, 0, 0, false, nil, false
            P.acc.d, P.acc.f, P.azb = 0, 0, {}
            local az, rub, now = 0, 0, os.time()
            for _, e in ipairs(P.pend) do
                if now - e.t <= 60 then az = az + e.n addAz(P.azb, e.label, e.n) end
            end
            for _, e in ipairs(P.pendRub) do
                if now - e.t <= 60 then rub = rub + e.n end
            end
            P.pend, P.pendRub, P.az, P.rub = {}, {}, az, rub
            return true
        end
        if P.active then
            if t:find(('='):rep(30), 1, true) then               -- конец чека: ждём 3 с дивидендный договор, потом записываем
                if P.sal ~= 0 or P.dep ~= 0 then P.endAt = os.clock() + 3 end
                return true
            end
            if not (t:find('получили нефти', 1, true) or t:find('успешно продали бочку', 1, true) or t:find('доплату от электрокомпании', 1, true)) then
                payLine(t)
                return true
            end
        end
        return false
    end

    -- ---------- нефтевышки ----------
    local O = {pct = 0, az = 0, liters = 0}
    local function oilAdd(kind, m, az) IR.add('oil', {t = os.time(), kind = kind, money = m, az = az}) end
    local function oil(t)                                        -- true - строка продажи/покупки бочки обработана
        local pct = t:match('%[Бонус зарплаты%].+, %+(%d+)')
        if pct then O.pct = O.pct + tonumber(pct) end
        local baz = t:match('%[Бонус.+%] Вы получаете дополнительно (%d+) AZ.+') or t:match('%[Бонус.+%].+%+(%d+) AZ coins за активный.+')
        if baz then O.az = O.az + tonumber(baz) end
        local lit = t:match('Вы успешно продали бочку с ([%d%.]+) литров нефти')
        if lit then O.liters = tonumber(lit) or 0 end

        local dop = t:match('Вы получили доплату от электрокомпании за бочку в размере .-([%d%.]+)')
        if dop then
            oilAdd('ground_money', digits(dop) or 0, O.liters > 150 and 13 or 0)
            return true
        end
        local waterRaw = t:find('Вы успешно продали бочку', 1, true) and not t:find('AZ-Coins', 1, true) and t:match('получили .-([%d%.]+)')
        local azRaw = t:match('Вы успешно продали бочку с .+ литров нефти и получили (%d+) AZ%-Coins')
        if waterRaw then
            local m = digits(waterRaw)
            if m then
                local ground = O.liters > 150
                oilAdd(ground and 'ground_money' or 'water', m + (ground and I('inc_oil_comp', 40000)[0] or 0),
                       (ground and I('inc_oil_azb', 15)[0] or 0) + O.az)
                O.az, O.pct = 0, 0
            end
            return true
        elseif azRaw then
            oilAdd('ground_az', math.floor(I('inc_oil_ground', 270000)[0] * (100 + O.pct) / 100), tonumber(azRaw) + O.az)
            O.az, O.pct = 0, 0
            return true
        elseif t:find('Вы успешно купили бочку. Погрузите её в лодку или дирижабль!', 1, true) then
            oilAdd('buy_water', -I('inc_oil_buy', 40000)[0], 0)
            return true
        elseif t:find('Вы успешно купили бочку. Погрузите её в автомобиль!', 1, true) then
            oilAdd('buy_ground', 0, -I('inc_oil_azbuy', 12)[0])
            return true
        end
        return false
    end

    -- ---------- разбор строки чата ----------
    function IR.onMessage(color, text)
        if type(text) ~= 'string' then return end
        local t = text:gsub('{%x%x%x%x%x%x}', '')
        local player = t:find('%S+%[%d+%]') ~= nil                      -- строка игрока в чате
        if B('inc_pay', true)[0] and not player and payroll(t) then return end
        if t:match('^%[%d+%]') or t:match('^[%w_%[%]]+:%s') or t:find('сказал', 1, true) or t:find('говорит', 1, true) then return end

        if B('inc_other', true)[0] then
            local shard
            if t:match("^%[Хранилище предметов%] Добавлен новый предмет 'Осколок Тайника") then
                shard = t:match('Осколок Тайника (.+)%(%d+ шт')
                shard = shard and shard:gsub('%s+$', '')
            elseif t:match("^%[Хранилище предметов%] Добавлен новый предмет 'Осколок NFT контейнера") then
                shard = 'NFT контейнера'
            elseif not t:match('%[%d+%]%s*:%s') then
                shard = SHARD_ID[tonumber(t:match('В пункт выдачи пришла посылка :item(%d+):')) or 0]
            end
            if shard and SHARD_KEY[shard] then
                IR.add('shard', {t = os.time(), name = shard, amount = I(SHARD_KEY[shard], 0)[0]})
                return
            end
            if t:find('Arizona Rent', 1, true) and t:find('сдали комнату', 1, true) and t:find('аренду игроку', 1, true) then
                local nick, n = t:match('аренду игроку ([%w_]+)'), digits(t:match('([%d%.]+)%s*!'))
                if nick and n and n > 0 then IR.add('im', {t = os.time(), k = 'room', nick = nick, amount = n}) end
                return
            end
            if t:match('^%[Item Market%]') then
                local nick, after = t:match('^%[Item Market%] (.+) арендовал'), t:match('начислено (.+)$')
                local n = after and digits(after) or 0
                if after and after:find(':KK:', 1, true) and not after:find(':KK:.*:K:') then n = n * 1000000 end
                if nick and n > 0 then IR.add('im', {t = os.time(), k = 'im', nick = nick, amount = n}) end
                return
            end
        end
        if B('inc_oil', true)[0] and oil(t) then return end
        if B('inc_taxi', true)[0] and not player then
            local raw = t:match('^%[Такси%] Клиент оплатил:%s*%S-([%d%.]+)')
            local n = raw and digits(raw)
            if n and n > 0 then IR.add('taxi', {t = os.time(), money = n}) end
        end
    end

    function IR.tick()
        IR.sync()
        if IR.dirty and os.clock() - (IR.saveAt or 0) > 3 then
            IR.saveAt, IR.dirty = os.clock(), false
            save(IR.sv, IR.data)
        end
        if P.active and P.endAt and os.clock() >= P.endAt then
            P.endAt = nil
            if not P.div then payFinish() end
        end
    end

    -- ---------- статистика ----------
    local function periodStart(per)
        if per == 2 then return 0 end
        local idx = math.floor((os.time() + 10800 - 18000) / 86400)       -- игровой день начинается в 05:00 МСК
        if per == 1 then idx = idx - (idx + 3) % 7 end                    -- неделя с понедельника
        return idx * 86400 + 18000 - 10800
    end
    local function stamp(e) return os.date('%d.%m %H:%M', e.t) end
    local function cnt(n, s) return money(s) .. '  x' .. n end
    local CAT_KEYS = {'inc_c_other', 'inc_c_pay', 'inc_c_oil', 'inc_c_taxi'}

    -- строки: {label, value}, {head = раздел}, {line = последняя запись}; доход выбранных категорий складывается в общий итог
    function IR.build(sel, per)
        local d, svName = IR.dataFor(sel)
        local from = periodStart(per)
        local rows = {{'Server', svName}}
        local tm, ta, nsel = 0, 0, 0
        local function row(l, v) rows[#rows + 1] = {l, v} end
        local function sec(title) nsel = nsel + 1 rows[#rows + 1] = {head = title} end
        local function recent(list, n, fn)
            for i = 1, math.min(#list, n) do rows[#rows + 1] = {line = fn(list[i])} end
        end
        if B('inc_c_other', true)[0] then
            sec('Other income')
            local im, room, sh, by = {0, 0}, {0, 0}, {0, 0}, {}
            for _, e in ipairs(d.im) do
                if e.t < from then break end
                local c = e.k == 'room' and room or im
                c[1], c[2] = c[1] + 1, c[2] + e.amount
            end
            for _, e in ipairs(d.shard) do
                if e.t < from then break end
                sh[1], sh[2] = sh[1] + 1, sh[2] + e.amount
                by[e.name] = by[e.name] or {0, 0}
                by[e.name][1], by[e.name][2] = by[e.name][1] + 1, by[e.name][2] + e.amount
            end
            row('Item Market rent', cnt(im[1], im[2]))
            row('Room rent', cnt(room[1], room[2]))
            row('Cache shards', cnt(sh[1], sh[2]))
            for _, n in ipairs(SHARD_ORDER) do
                if by[n] then row('   ' .. n, cnt(by[n][1], by[n][2])) end
            end
            local sum = im[2] + room[2] + sh[2]
            row('Total', money(sum))
            tm = tm + sum
            recent(d.im, 3, function(a) return string.format('%s  %s  +%s  %s', stamp(a), a.k == 'room' and 'Room' or 'IM', money(a.amount), a.nick) end)
            recent(d.shard, 2, function(b) return string.format('%s  %s  +%s', stamp(b), b.name, money(b.amount)) end)
        end
        if B('inc_c_pay', true)[0] then
            sec('Payday')
            local s, order, azb = {n = 0, sal = 0, dep = 0, d = 0, a = 0, f = 0, az = 0, rub = 0}, {}, {}
            for _, e in ipairs(d.pay) do
                if e.t < from then break end
                s.n, s.sal, s.dep = s.n + 1, s.sal + (e.salary or 0), s.dep + (e.deposit or 0)
                local b = e.accB or {}
                s.d, s.a, s.f = s.d + (b.d or 0), s.a + (b.a or 0), s.f + (b.f or 0)
                s.az, s.rub = s.az + (e.az or 0), s.rub + (e.rub or 0)
                for _, x in ipairs(e.azB or {}) do
                    if not azb[x.label] then azb[x.label], order[#order + 1] = 0, x.label end
                    azb[x.label] = azb[x.label] + x.amount
                end
            end
            row('Paydays', tostring(s.n))
            row('Salary', money(s.sal))
            row('Deposit', money(s.dep))
            row('Accessories and items', money(s.d + s.a + s.f))
            if s.d > 0 then row('   Dividend contract', money(s.d)) end
            if s.a > 0 then row('   Accessory', money(s.a)) end
            if s.f > 0 then row('   Family payouts', money(s.f)) end
            row('AZ', fmt(s.az) .. ' AZ')
            for i = 1, math.min(#order, 8) do row('   ' .. order[i], fmt(azb[order[i]]) .. ' AZ') end
            if s.rub > 0 then row('Rubles', fmt(s.rub)) end
            local sum = s.sal + s.dep + s.d + s.a + s.f
            row('Total', money(sum))
            tm, ta = tm + sum, ta + s.az
            recent(d.pay, 3, function(e)
                return string.format('%s  +%s', stamp(e), money((e.salary or 0) + (e.deposit or 0) + (e.acc or 0))) .. ((e.az or 0) > 0 and ('  ' .. fmt(e.az) .. ' AZ') or '')
            end)
        end
        if B('inc_c_oil', true)[0] then
            sec('Oil rigs')
            local g = {water = {0, 0}, ground_money = {0, 0}, ground_az = {0, 0}, buy_water = {0, 0}, buy_ground = {0, 0}}
            local m, az = 0, 0
            for _, e in ipairs(d.oil) do
                if e.t < from then break end
                local c = g[e.kind]
                if c then c[1], c[2] = c[1] + 1, c[2] + (e.money or 0) end
                m, az = m + (e.money or 0), az + (e.az or 0)
            end
            row('Water barrels', cnt(g.water[1], g.water[2]))
            row('Ground barrels (company payment)', cnt(g.ground_money[1], g.ground_money[2]))
            row('Ground barrels (AZ-Coins)', cnt(g.ground_az[1], g.ground_az[2]))
            row('Barrels bought', tostring(g.buy_water[1] + g.buy_ground[1]))
            row('Total money', money(m))
            row('Total AZ', fmt(az) .. ' AZ')
            tm, ta = tm + m, ta + az
            recent(d.oil, 3, function(e)
                return string.format('%s  %s  %s', stamp(e), e.kind, money(e.money or 0)) .. ((e.az or 0) ~= 0 and ('  ' .. fmt(e.az) .. ' AZ') or '')
            end)
        end
        if B('inc_c_taxi', true)[0] then
            sec('Taxi')
            local n, sum, work, prev = 0, 0, 0, nil
            for _, e in ipairs(d.taxi) do
                if e.t < from then break end
                n, sum = n + 1, sum + e.money
                if prev and prev - e.t <= 600 then work = work + (prev - e.t) end        -- время между заказами подряд (до 10 минут)
                prev = e.t
            end
            row('Orders', tostring(n))
            row('Income', money(sum))
            row('Average per order', money(n > 0 and sum / n or 0))
            row('Working time', string.format('%d:%02d:%02d', math.floor(work / 3600), math.floor(work / 60) % 60, work % 60))
            if work > 0 then row('Income per hour', money(sum / work * 3600)) end
            tm = tm + sum
            recent(d.taxi, 3, function(e) return string.format('%s  +%s', stamp(e), money(e.money)) end)
        end
        if nsel == 0 then rows[#rows + 1] = {line = 'No categories selected'} end
        if nsel > 1 then                                         -- несколько категорий: общий итог
            sec('All selected categories')
            nsel = nsel - 1
            row('Total money', money(tm))
            row('Total AZ', fmt(ta) .. ' AZ')
        end
        return rows
    end

    function IR.stats(sel, per)                                  -- кэш на изменения данных, выбор категорий и границы периода
        local mask = {}
        for _, k in ipairs(CAT_KEYS) do mask[#mask + 1] = B(k, true)[0] and 1 or 0 end
        local key = table.concat({sel, per, IR.rev, periodStart(per), table.concat(mask)}, ':')
        if IR.cacheKey ~= key then IR.cacheKey, IR.cache = key, IR.build(sel, per) end
        return IR.cache
    end

    function IR.clear(sel)                                       -- очищает выбранные категории выбранного сервера
        local d, name = IR.dataFor(sel)
        local map = {{'im', 'shard'}, {'pay'}, {'oil'}, {'taxi'}}
        for i, k in ipairs(CAT_KEYS) do
            if B(k, true)[0] then
                for _, c in ipairs(map[i]) do d[c] = {} end
            end
        end
        if name == IR.sv then IR.dirty = true else save(name, d) end
        IR.rev = IR.rev + 1
        Notify('Statistics cleared')
    end

    -- выбор категорий статистики: окно со списком, как у фраз (несколько сразу)
    WORDS.register('inc_cats', 'Statistics categories', 'LIST_UL')
    WORDS.lists.inc_cats.solo = true
    WORDS.lists.inc_cats.toggle = {
        {key = 'inc_c_other', default = true, label = 'Other income'},
        {key = 'inc_c_pay',   default = true, label = 'Payday'},
        {key = 'inc_c_oil',   default = true, label = 'Oil rigs'},
        {key = 'inc_c_taxi',  default = true, label = 'Taxi'},
    }

    -- ---------- страница Software -> Income tracker ----------
    local bufs = {}
    local function numRow(label, key, def)
        local p = I(key, def)
        local b = bufs[key]
        if not b then
            b = imgui.new.char[16]()
            ffi.copy(b, tostring(p[0]))
            bufs[key] = b
        end
        TextRow(label, b, function()
            local n = digits(ffi.string(b))
            if n then p[0] = math.min(n, 2000000000) end
            ffi.copy(b, tostring(p[0]))
        end, nil, nil, 110)
    end
    local function head(s)
        if SRCH.collecting then return end
        imgui.Dummy(imgui.ImVec2(1, 4))
        imgui.PushFont(fonts.bold)
        imgui.TextColored(imgui.ImVec4(pal.text[1], pal.text[2], pal.text[3], gfx.galpha), u8(tr(s)))
        imgui.PopFont()
    end

    IR.edit = nil                                                -- окно цен: nil, 'shards' или 'oil'
    local function EditBody()
        if IR.edit == 'shards' then
            for i, n in ipairs(SHARD_ORDER) do numRow(tr('Shard price') .. ': ' .. n, 'inc_sh' .. i, 0) end
        else
            numRow('Water barrel purchase price', 'inc_oil_buy', 40000)
            numRow('Ground barrel purchase price (AZ)', 'inc_oil_azbuy', 12)
            numRow('Ground barrel value', 'inc_oil_ground', 270000)
            numRow('Ground barrel AZ bonus', 'inc_oil_azb', 15)
            numRow('Company payment', 'inc_oil_comp', 40000)
        end
    end

    local function LeftBody()
        Combo('Period', I('inc_per', 0), {'Today', 'Week', 'All time'})
        Combo('Server', I('inc_srv', 0), IR.svItems)
        Checkbox('Track other income', B('inc_other', true))
        Checkbox('Track payday', B('inc_pay', true))
        Checkbox('Track oil rigs', B('inc_oil', true))
        Checkbox('Track taxi', B('inc_taxi', true))
        imgui.Dummy(imgui.ImVec2(1, 4))
        if Button('Shard prices', 30, false, nil, nil, 'COINS') then IR.edit = 'shards' end
        if Button('Oil settings', 30, false, nil, nil, 'GEAR') then IR.edit = 'oil' end
        imgui.Dummy(imgui.ImVec2(1, 4))
        if Button('Clear statistics', 30, false, nil, 2, 'TRASH') then IR.clear(I('inc_srv', 0)[0]) end
    end

    local function RightBody()
        WORDS.row('Categories', 'inc_cats')
        imgui.Dummy(imgui.ImVec2(1, 2))
        if SRCH.collecting then return end
        for _, x in ipairs(IR.stats(I('inc_srv', 0)[0], I('inc_per', 0)[0])) do
            if x.head then head(x.head)
            elseif x.line then Text(x.line, pal.dim)
            else InfoRow(x[1], x[2]) end
        end
    end

    SOFT.draw.income = function()
        if IR.edit and not SRCH.collecting then
            SOFT.back = function() IR.edit = nil end                 -- «Назад» в шапке закрывает окно цен
            Panel(IR.edit == 'shards' and 'Shard prices' or 'Oil settings', 0, 0, LAY.COLW + 120, IR.edit == 'shards' and 270 or 240, EditBody, true, nil, function()
                SOFT.pageHeader('incedit', LAY.COLW + 120)
            end, 30)
            SOFT.back = nil
            return
        end
        Panel('Income tracker', 0, 0, LAY.COLW, LAY.CH, LeftBody, nil, true, function()
            SOFT.pageHeader('inc', LAY.COLW)
        end, 30)
        Panel('Statistics', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, RightBody, nil, true)
    end

    HINTS['Track other income'] = 'Records the rent from Item Market and rooms (Arizona Rent) and the cache shards you get.'
    HINTS['Track payday'] = 'Records every payday: salary, deposit, accessories and items, and the AZ and rubles received with it.'
    HINTS['Track oil rigs'] = 'Records the barrels sold for money or AZ-Coins, the company payments and the barrels you buy.'
    HINTS['Track taxi'] = 'Records the payment for every completed taxi order.'
    HINTS['Categories'] = 'Which categories the statistics show. When several are chosen, their income is added up in the total.'
    local ru = i18n.TR.ru
    for k, v in pairs({
        [HINTS['Track other income']] = 'Записывает доход от аренды Item Market и комнат (Arizona Rent) и полученные осколки тайников.',
        [HINTS['Track payday']] = 'Записывает каждый пейдей: зарплату, депозит, аксессуары и предметы, а также полученные AZ и рубли.',
        [HINTS['Track oil rigs']] = 'Записывает проданные за деньги или AZ-Coins бочки, доплаты компании и закупку бочек.',
        [HINTS['Track taxi']] = 'Записывает оплату за каждый выполненный заказ такси.',
        [HINTS['Categories']] = 'Какие категории показывает статистика. Если выбрано несколько, их доход складывается в общий итог.',
        ['Categories'] = 'Категории', ['Statistics categories'] = 'Категории статистики', ['Shard prices'] = 'Цены осколков', ['Oil settings'] = 'Настройки нефтевышек',
        ['Clear statistics'] = 'Очистить статистику', ['All selected categories'] = 'Все выбранные категории', ['No categories selected'] = 'Категории не выбраны',
    }) do ru[k] = v end
end

-- ----------------------------------------------------------------------------
--  Автопиар (из ResHelper): сообщения в /vr, /ad, /s, /fam и другие каналы по таймеру; в тексте можно вставлять предметы :itemN:
--  Диалоги /vr и /ad (реклама, радиостанция, тип объявления, подтверждение) проходят автоматически.
-- ----------------------------------------------------------------------------
do
    local AP = {}
    ctl.ap = AP
    local CHATS = {'/vr', '/ad', '/s', '/al', '/fam', '/r', '/rb', '/f', '/fb', '/g'}
    local RADIO = {'Automatic', 'Los Santos', 'Las Venturas', 'San Fierro'}
    AP.ads, AP.items, AP.found, AP.dirtyAt = {}, {}, {}, nil
    local vr, adq = {pending = false, t = 0, withAd = false}, {pending = false, t = 0, radio = 0, vip = false}

    local function adsPath() return FNT.filesDir() .. '\\auto_ad.json' end
    local function dbPath() return FNT.filesDir() .. '\\items_db.json' end

    local function newAd(d)
        d = d or {}
        local a = {active = d.active == true, chat = tonumber(d.chat) or 0, radio = tonumber(d.radio) or 0, buf = imgui.new.char[501](),
                   iv = imgui.new.int(math.max(5, tonumber(d.interval) or 300)), vr = imgui.new.bool(d.vrAd == true), vip = imgui.new.bool(d.vip == true)}
        ffi.copy(a.buf, u8(d.text or ''):sub(1, 500))
        a.nextAt = os.time() + a.iv[0]
        return a
    end

    function AP.save()
        local list = {}
        for i, a in ipairs(AP.ads) do
            list[i] = {text = u8:decode(ffi.string(a.buf)), interval = a.iv[0], chat = a.chat, active = a.active, vrAd = a.vr[0], radio = a.radio, vip = a.vip[0]}
        end
        pcall(FNT.ensureFilesDir)
        local f = io.open(adsPath(), 'wb')
        if f then f:write(encodeJson(list)) f:close() end
        AP.dirtyAt = nil
    end

    local f = io.open(adsPath(), 'rb')
    if f then
        local ok, t = pcall(decodeJson, f:read('*a'))
        f:close()
        if ok and type(t) == 'table' then
            for _, d in ipairs(t) do AP.ads[#AP.ads + 1] = newAd(d) end
        end
    end

    function AP.send(a)
        local text = u8:decode(ffi.string(a.buf))
        if text == '' then return end
        local cmd = CHATS[a.chat + 1] or '/vr'
        local now = os.time()
        if cmd == '/vr' then
            vr.pending, vr.withAd, vr.t = true, a.vr[0], now
        elseif cmd == '/ad' then
            adq.pending, adq.t, adq.radio, adq.vip = true, now, a.radio, a.vip[0]
        end
        pcall(sampProcessChatInput, cmd .. ' ' .. text)
    end

    function AP.toggle(a)
        a.active = not a.active
        if a.active then                                         -- таймер запускается заново: первая отправка сразу, дальше по интервалу
            AP.send(a)
            a.nextAt = os.time() + math.max(5, a.iv[0])
        end
        AP.save()
    end

    function AP.tick()
        if AP.dirtyAt and os.clock() > AP.dirtyAt then AP.save() end
        local now = os.time()
        if now == AP.lastT then return end                          -- таймеры считаются в секундах: проверка раз в секунду, а не каждый кадр
        AP.lastT = now
        local due
        for _, a in ipairs(AP.ads) do
            if a.active and now >= a.nextAt then due = true break end
        end
        if not due or sampIsChatInputActive() or sampIsDialogActive() then return end
        for _, a in ipairs(AP.ads) do
            if a.active and now >= a.nextAt then
                AP.send(a)
                a.nextAt = now + math.max(5, a.iv[0])
            end
        end
    end

    -- автоответы на диалоги; true - диалог скрыть
    function AP.onDialog(id, style, title, b1, b2, text)
        local now = os.time()
        title, text = title or '', text or ''
        if vr.pending then
            vr.pending = false
            if now - vr.t <= 5 then
                sampSendDialogResponse(id, vr.withAd and 1 or 0, -1, '')
                return true
            end
        end
        if not adq.pending then return false end
        if now - adq.t > 8 then
            adq.pending = false
        elseif title:find('Выберите радиостанцию', 1, true) and text:find('Радиостанция', 1, true) then
            local lines = {}
            for line in text:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
            local chosen, best = 0, math.huge
            for i = 2, #lines do
                if adq.radio > 0 then
                    if lines[i]:find(RADIO[adq.radio + 1], 1, true) then chosen = i - 2 break end
                else                                                        -- «автоматически»: станция, где недавно была активность
                    local h, m, s = lines[i]:match('(%d+)%s*час'), lines[i]:match('(%d+)%s*мин'), lines[i]:match('(%d+)%s*сек')
                    local el = (h or m or s) and (tonumber(h or 0) * 3600 + tonumber(m or 0) * 60 + tonumber(s or 0)) or math.huge
                    if el < best then best, chosen = el, i - 2 end
                end
            end
            adq.t = now
            sampSendDialogResponse(id, 1, chosen, '')
            return true
        elseif title:find('тип объявления', 1, true) then
            adq.t = now
            sampSendDialogResponse(id, 1, adq.vip and 1 or 0, '')
            return true
        elseif title:find('Подача объявления', 1, true) and title:find('Подтверждение', 1, true) then
            adq.pending = false
            sampSendDialogResponse(id, 1, 65535, '')
            return true
        end
        return false
    end

    -- ---------- список предметов для :itemN: ----------
    local function lower(s)                                      -- нижний регистр для CP1251
        return (s:gsub('[\192-\223\168A-Z]', function(c)
            local b = c:byte()
            if b == 168 then return string.char(184) end
            return string.char(b + 32)
        end))
    end
    function AP.dbParse(txt)
        local okd, conv = pcall(function() return u8:decode(txt) end)
        local ok, arr = pcall(decodeJson, okd and conv or txt)
        if not (ok and type(arr) == 'table') then return false end
        local list = {}
        for _, it in ipairs(arr) do
            if it.id and it.item_name then list[#list + 1] = {id = tonumber(it.id) or 0, name = it.item_name, low = lower(it.item_name)} end
        end
        table.sort(list, function(x, y) return x.id < y.id end)
        AP.items, AP.q = list, nil
        return #list > 0
    end
    function AP.dbLoad()
        AP.loaded = true
        local fh = io.open(dbPath(), 'rb')
        if fh then
            local txt = fh:read('*a')
            fh:close()
            if AP.dbParse(txt) then return end
        end
        AP.dbFetch()
    end
    function AP.dbFetch()
        if AP.fetching then return end
        local okM, ml = pcall(require, 'moonloader')
        if not okM or not ml.download_status then NotifyErr('The item list could not be loaded') return end
        AP.fetching = true
        pcall(FNT.ensureFilesDir)
        local tmp = dbPath() .. '.tmp'
        pcall(downloadUrlToFile, 'https://items.shinoa.tech/items.php', tmp, function(_, status)
            if status ~= ml.download_status.STATUSEX_ENDDOWNLOAD then return end
            AP.fetching = false
            local fh = io.open(tmp, 'rb')
            local txt = fh and fh:read('*a')
            if fh then fh:close() end
            if txt and AP.dbParse(txt) then
                os.remove(dbPath())
                os.rename(tmp, dbPath())
                Notify('Item list updated: %d', #AP.items)
            else
                NotifyErr('The item list could not be loaded')
            end
            os.remove(tmp)
        end)
    end

    function AP.insert(a, id)
        local s = ffi.string(a.buf)
        s = s .. (#s > 0 and ' ' or '') .. ':item' .. id .. ':'
        ffi.copy(a.buf, s:sub(1, 500))
        AP.dirtyAt = os.clock() + 1
    end

    -- ---------- интерфейс ----------
    local searchBuf = imgui.new.char[64]()
    local P = imgui.ImVec2
    local function pc(c, a) return imgui.ImVec4(c[1], c[2], c[3], a or 1) end

    local function Card(i, a, w)
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local tmain = THEME.main
        local isAd, isVr = CHATS[a.chat + 1] == '/ad', CHATS[a.chat + 1] == '/vr'
        local h = 112
        dl:AddRectFilled(p, P(p.x + w, p.y + h), C(pal.field), 8)
        dl:AddRect(p, P(p.x + w, p.y + h), C(pal.border), 8)
        dl:AddRectFilled(P(p.x + 1, p.y + 8), P(p.x + 4, p.y + h - 8), C(a.active and tmain or pal.border), 2)
        -- статус (клик - запуск / остановка) и отсчёт до отправки
        local st = u8(tr(a.active and 'Active' or 'Inactive'))
        local sw = imgui.CalcTextSize(st).x + 28
        imgui.SetCursorScreenPos(P(p.x + 14, p.y + 9))
        if imgui.InvisibleButton('##apt' .. i, P(sw, 22)) then AP.toggle(a) end
        local th = animTo('apt' .. i, imgui.IsItemHovered() and 1 or 0, 14)
        local col = a.active and tmain or pal.dim
        dl:AddRectFilled(P(p.x + 14, p.y + 9), P(p.x + 14 + sw, p.y + 31), C(mix(pal.panel, col, 0.15 + th * 0.12)), 11)
        dl:AddCircleFilled(P(p.x + 26, p.y + 20), 3.5, C(col), 12)
        dl:AddText(P(p.x + 36, p.y + 12), C(col), st)
        if a.active then
            local left = math.max(0, a.nextAt - os.time())
            dl:AddText(P(p.x + 24 + sw, p.y + 12), C(pal.dim), u8(string.format(tr('In %d s'), left)))
        end
        -- удалить
        local deleted = false
        imgui.SetCursorScreenPos(P(p.x + w - 34, p.y + 7))
        if imgui.InvisibleButton('##apd' .. i, P(26, 26)) then deleted = true end
        local dh = animTo('apd' .. i, imgui.IsItemHovered() and 1 or 0, 14)
        local xc, cx, cy = C(mix(pal.dim, CONST.BTN_DANGER, dh)), p.x + w - 21, p.y + 20
        dl:AddLine(P(cx - 5, cy - 5), P(cx + 5, cy + 5), xc, 1.8)
        dl:AddLine(P(cx + 5, cy - 5), P(cx - 5, cy + 5), xc, 1.8)
        -- текст и кнопка «вставить предмет»
        imgui.PushStyleColor(imgui.Col.FrameBg, pc(pal.panel))                         -- поля, флажки и списки карточки: тёмный фон и рамка
        imgui.PushStyleColor(imgui.Col.FrameBgHovered, pc(mix(pal.panel, tmain, 0.12)))
        imgui.PushStyleColor(imgui.Col.FrameBgActive, pc(mix(pal.panel, tmain, 0.22)))
        imgui.PushStyleColor(imgui.Col.Border, pc(mix(pal.border, tmain, 0.35)))
        imgui.PushStyleColor(imgui.Col.CheckMark, pc(tmain))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 1)
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6)
        imgui.SetCursorScreenPos(P(p.x + 10, p.y + 40))
        imgui.SetNextItemWidth(w - 20 - 34)
        if imgui.InputText('##apx' .. i, a.buf, 501) then AP.dirtyAt = os.clock() + 1 end
        if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
        imgui.SetCursorScreenPos(P(p.x + w - 38, p.y + 40))
        if imgui.InvisibleButton('##api' .. i, P(28, 24)) then
            AP.target, AP.picker = a, true
            if not AP.loaded then AP.dbLoad() end
        end
        Hint('Insert an item')
        local ih = animTo('api' .. i, imgui.IsItemHovered() and 1 or 0, 14)
        dl:AddRectFilled(P(p.x + w - 38, p.y + 40), P(p.x + w - 10, p.y + 64), C(mix(pal.panel, tmain, 0.15 + ih * 0.2)), 6)
        FNT.drawIcon(dl, 'MAGNIFYING_GLASS', 13, p.x + w - 24, p.y + 52, C(mix(pal.dim, tmain, 0.4 + ih * 0.6)))
        -- канал, интервал и параметры канала
        imgui.SetCursorScreenPos(P(p.x + 10, p.y + 76))
        imgui.SetNextItemWidth(72)
        if imgui.BeginCombo('##apc' .. i, CHATS[a.chat + 1]) then
            ui.popBusy = true
            for k, name in ipairs(CHATS) do
                if imgui.Selectable(name, a.chat == k - 1) then a.chat = k - 1 AP.save() end
            end
            imgui.EndCombo()
        end
        imgui.SameLine(nil, 8)
        imgui.SetNextItemWidth(70)
        if imgui.InputInt('##apv' .. i, a.iv, 0, 0) then
            if a.iv[0] < 5 then a.iv[0] = 5 end
            a.nextAt = os.time() + a.iv[0]
            AP.dirtyAt = os.clock() + 1
        end
        imgui.SameLine(nil, 4)
        imgui.AlignTextToFramePadding()
        imgui.TextColored(imgui.ImVec4(pal.dim[1], pal.dim[2], pal.dim[3], gfx.galpha), u8(tr('s')))
        if isVr then
            imgui.SameLine(nil, 14)
            if imgui.Checkbox(u8(tr('With advertising')) .. '##apa' .. i, a.vr) then AP.save() end
        elseif isAd then
            imgui.SameLine(nil, 14)
            imgui.SetNextItemWidth(130)
            if imgui.BeginCombo('##apr' .. i, u8(tr(RADIO[a.radio + 1] or RADIO[1]))) then
                ui.popBusy = true
                for k, name in ipairs(RADIO) do
                    if imgui.Selectable(u8(tr(name)), a.radio == k - 1) then a.radio = k - 1 AP.save() end
                end
                imgui.EndCombo()
            end
            imgui.SameLine(nil, 10)
            if imgui.Checkbox('VIP##apvip' .. i, a.vip) then AP.save() end
        end
        imgui.PopStyleVar(2)
        imgui.PopStyleColor(5)
        imgui.SetCursorScreenPos(P(p.x, p.y + h + 8))
        imgui.Dummy(P(w, 1))
        return deleted
    end

    local function AdsBody()
        local w = imgui.GetContentRegionAvail().x
        if Button('New ad', 34, true, nil, nil, 'PLUS') then
            AP.ads[#AP.ads + 1] = newAd()
            AP.save()
        end
        imgui.Dummy(P(1, 4))
        if #AP.ads == 0 then Text('No ads yet', pal.dim) return end
        local del
        for i, a in ipairs(AP.ads) do
            if Card(i, a, w) then del = i end
        end
        if del then
            table.remove(AP.ads, del)
            AP.save()
        end
    end

    local function PickerBody()
        local a = AP.target
        Text('Click an item to insert it into the ad text as :itemN:', pal.dim)
        imgui.Dummy(P(1, 4))
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
        imgui.InputTextWithHint('##apsearch', u8(tr('Search')), searchBuf, 64)
        if imgui.IsItemActive() and ui.open[0] then ui.fieldActive = true end
        if #AP.items == 0 then
            imgui.Dummy(P(1, 6))
            Text(AP.fetching and 'Loading the item list...' or 'The item list is empty', pal.dim)
            if not AP.fetching and Button('Update item list', 30) then AP.dbFetch() end
            return
        end
        local q = lower(u8:decode(ffi.string(searchBuf)))
        if AP.q ~= q then                                         -- результаты пересчитываем только при смене запроса
            AP.q, AP.found = q, {}
            for _, it in ipairs(AP.items) do
                if q == '' or it.low:find(q, 1, true) or tostring(it.id) == q then
                    AP.found[#AP.found + 1] = it
                    if #AP.found >= 200 then break end
                end
            end
        end
        imgui.Dummy(P(1, 4))
        imgui.BeginChild('##apitems', imgui.GetContentRegionAvail(), false)
        for _, it in ipairs(AP.found) do
            if imgui.Selectable(u8(string.format('[%d] %s', it.id, it.name)), false) and a then
                AP.insert(a, it.id)
                AP.picker = false
            end
        end
        imgui.EndChild()
    end

    SOFT.draw.autoad = function()
        if AP.picker then
            SOFT.back = function() AP.picker = false end
            Panel('Items', 0, 0, LAY.CW, LAY.CH, PickerBody, true, nil, function()
                SOFT.pageHeader('apx', LAY.CW)
            end, 30)
            SOFT.back = nil
        else
            Panel('Auto PR', 0, 0, LAY.CW, LAY.CH, AdsBody, true, true, function()
                SOFT.pageHeader('ap', LAY.CW)
            end, 30)
        end
    end

    -- ---------- подсказки и перевод ----------
    HINTS['Insert an item'] = 'Opens the list of all game items. Click an item to insert it into the ad text as :itemN:.'
    local ru = i18n.TR.ru
    ru[HINTS['Insert an item']] = 'Открывает список всех игровых предметов. Нажмите на предмет, чтобы вставить его в текст объявления как :itemN:.'
    ru['Insert an item'] = 'Вставить предмет'
    for k, v in pairs({
        ['Income tracker'] = 'Учёт дохода', ['Rent, payday, oil rigs'] = 'Аренда, пейдеи, нефть', ['and taxi per server'] = 'и такси по серверам',
        ['Category'] = 'Категория', ['Period'] = 'Период', ['Server'] = 'Сервер', ['Current server'] = 'Текущий сервер',
        ['Other income'] = 'Сторонний доход', ['Payday'] = 'Пейдей', ['Oil rigs'] = 'Нефтевышки', ['Taxi'] = 'Такси',
        ['Today'] = 'Сегодня', ['Week'] = 'Неделя', ['All time'] = 'Всё время', ['Tracking'] = 'Учёт',
        ['Track other income'] = 'Учитывать сторонний доход', ['Track payday'] = 'Учитывать пейдеи', ['Track oil rigs'] = 'Учитывать нефтевышки', ['Track taxi'] = 'Учитывать такси',
        ['Shard prices'] = 'Цены осколков', ['Shard price'] = 'Цена осколка', ['Statistics'] = 'Статистика', ['Recent'] = 'Последние',
        ['Water barrel purchase price'] = 'Цена покупки водной бочки', ['Ground barrel purchase price (AZ)'] = 'Цена покупки наземной бочки (AZ)',
        ['Ground barrel value'] = 'Стоимость наземной бочки', ['Ground barrel AZ bonus'] = 'Бонус AZ за наземную бочку', ['Company payment'] = 'Доплата электрокомпании',
        ['Clear selected category'] = 'Очистить выбранную категорию', ['Statistics cleared'] = 'Статистика очищена',
        ['Item Market rent'] = 'Аренда Item Market', ['Room rent'] = 'Аренда комнаты', ['Cache shards'] = 'Осколки тайников', ['Total'] = 'Итого',
        ['Paydays'] = 'Пейдеев', ['Salary'] = 'Зарплата', ['Deposit'] = 'Депозит', ['Accessories and items'] = 'Аксессуары и предметы',
        ['   Dividend contract'] = '   Дивидентный договор', ['   Accessory'] = '   Аксессуар', ['   Family payouts'] = '   Семейные выплаты', ['Rubles'] = 'Рубли',
        ['Water barrels'] = 'Водные бочки', ['Ground barrels (company payment)'] = 'Наземные бочки (доплата компании)', ['Ground barrels (AZ-Coins)'] = 'Наземные бочки (AZ-Coins)',
        ['Barrels bought'] = 'Куплено бочек', ['Total money'] = 'Всего денег', ['Total AZ'] = 'Всего AZ',
        ['Orders'] = 'Заказов', ['Income'] = 'Доход', ['Average per order'] = 'В среднем за заказ', ['Working time'] = 'Время работы', ['Income per hour'] = 'Доход в час',
        ['Auto PR'] = 'Автопиар', ['Auto messages to chat'] = 'Автоотправка в чат', ['with game items'] = 'с игровыми предметами',
        ['New ad'] = 'Новое объявление', ['No ads yet'] = 'Объявлений ещё нет', ['Active'] = 'Активно', ['Inactive'] = 'Неактивно', ['In %d s'] = 'Через %d с',
        ['With advertising'] = 'С рекламой', ['Automatic'] = 'Автоматически', ['Items'] = 'Предметы', ['Search'] = 'Поиск',
        ['Click an item to insert it into the ad text as :itemN:'] = 'Нажмите на предмет, чтобы вставить его в текст объявления как :itemN:',
        ['Update item list'] = 'Обновить список предметов', ['Loading the item list...'] = 'Загрузка списка предметов...', ['The item list is empty'] = 'Список предметов пуст',
        ['Item list updated: %d'] = 'Список предметов обновлён: %d', ['The item list could not be loaded'] = 'Не удалось загрузить список предметов',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Jobs Helper (Software): одна плитка для помощников по работам. Первый - Taxi Helper; новые работы добавляются в JOBS.list
--  (запись {id, icon, title, desc}), а их страница регистрируется как SOFT.draw[id].
-- ----------------------------------------------------------------------------
do
    local JOBS = {sub = nil}
    ctl.jobs = JOBS
    JOBS.list = {
        {id = 'taxihelper', icon = 'TAXI', title = 'Taxi', desc = {'Auto order pick', 'for the taxi job'}},
    }

    SOFT.draw.jobs = function()
        if SRCH.collecting then                                   -- поиск видит настройки всех работ
            for _, j in ipairs(JOBS.list) do
                if SOFT.draw[j.id] then pcall(SOFT.draw[j.id]) end
            end
            return
        end
        local cur
        for _, j in ipairs(JOBS.list) do
            if j.id == JOBS.sub then cur = j end
        end
        if cur and SOFT.draw[cur.id] then                         -- страница работы: кнопка «Назад» возвращает к списку работ
            SOFT.back = function() JOBS.sub, SOFT.t0 = nil, os.clock() end
            SOFT.draw[cur.id]()
            SOFT.back = nil
            return
        end
        Panel('Jobs Helper', 0, 0, LAY.CW, LAY.CH, function()
            local p = imgui.GetCursorScreenPos()
            local w = imgui.GetContentRegionAvail().x
            local tw = math.floor((w - (SOFT.COLS - 1) * SOFT.TILE_GAP) / SOFT.COLS)
            local rows = 0
            for i, j in ipairs(JOBS.list) do
                local col, row = (i - 1) % SOFT.COLS, math.floor((i - 1) / SOFT.COLS)
                rows = math.max(rows, row + 1)
                if SOFT.tile(j, col, row, p.x, p.y, tw) then JOBS.sub, SOFT.t0 = j.id, os.clock() end
            end
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + rows * (SOFT.TILE_H + SOFT.TILE_GAP)))
            imgui.Dummy(imgui.ImVec2(1, 1))
        end, nil, nil, function()
            SOFT.pageHeader('jobs', LAY.CW)
        end, 30)
    end

    local ru = i18n.TR.ru
    for k, v in pairs({
        ['Jobs Helper'] = 'Помощник работ', ['Helpers for different'] = 'Помощники для разных', ['jobs in one place'] = 'работ в одном месте',
    }) do if ru[k] == nil then ru[k] = v end end
end

-- ----------------------------------------------------------------------------
--  Обновления и магазин скриптов через GitHub (raw.githubusercontent.com).
--  Репозиторий задаётся в Settings -> Updates (owner/name и ветка). В репозитории нужны:
--    version.json  {"version": "1.1", "file": "Collapse.lua", "changelog": "что нового"}
--    scripts.json  {"scripts": [{"name": "Имя", "file": "путь/в/репозитории.lua", "version": "1.0", "desc": "описание", "target": "Имя.lua"}]}
--  Обновление скрипта ставится только если файл компилируется, это COLLAPSE и его script_version совпадает с version.json;
--  прежний файл сохраняется как Collapse.lua.bak (Settings -> Updates -> Restore previous version).
-- ----------------------------------------------------------------------------
do
    local UPD = {}
    ctl.upd = UPD
    -- Репозиторий GitHub (owner/name) и ветка, откуда берутся version.json, scripts.json и файлы. Меняются только здесь, в коде.
    UPD.cfg = {repo = 'Dipcool/Collapse', branch = 'main'}
    UPD.status, UPD.lines, UPD.t0 = 'idle', {}, os.clock()
    local okM, ml = pcall(require, 'moonloader')
    local P = imgui.ImVec2

    function UPD.say(text)
        table.insert(UPD.lines, 1, os.date('%H:%M:%S  ') .. text)
        if #UPD.lines > 12 then table.remove(UPD.lines) end
    end

    -- ---------- вспомогательное ----------
    local function vparts(v)
        local t = {}
        for n in tostring(v):gmatch('%d+') do t[#t + 1] = tonumber(n) end
        return t
    end
    local function vcmp(a, b)                                     -- 1: a новее, -1: старее, 0: равны
        local x, y = vparts(a), vparts(b)
        for i = 1, math.max(#x, #y) do
            local p, q = x[i] or 0, y[i] or 0
            if p ~= q then return p > q and 1 or -1 end
        end
        return 0
    end
    local function compiles(txt)
        return ((loadstring or load)(txt, '=chunk')) ~= nil
    end
    local function readFile(path)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local t = f:read('*a')
        f:close()
        return t
    end
    local function writeFile(path, txt)
        local f = io.open(path, 'wb')
        if not f then return false end
        f:write(txt)
        f:close()
        return true
    end

    -- адрес файла в репозитории; nil, если репозиторий не задан или путь подозрительный
    function UPD.url(file)
        local repo, br = UPD.cfg.repo, UPD.cfg.branch
        if not (repo:match('^[%w%-_%.]+/[%w%-_%.]+$') and br:match('^[%w%-_%./]+$')) then return nil end
        if type(file) ~= 'string' or file:find('..', 1, true) or not file:match('^[%w%-_%./ ]+$') then return nil end
        return 'https://raw.githubusercontent.com/' .. repo .. '/' .. br .. '/' .. file:gsub(' ', '%%20')
    end

    -- cb(текст или nil); временный файл в files, после чтения удаляется
    function UPD.download(url, cb)
        if not (okM and ml.download_status) then cb(nil) return end
        pcall(FNT.ensureFilesDir)
        UPD.seq = (UPD.seq or 0) + 1
        local tmp = FNT.filesDir() .. '\\upd_' .. UPD.seq .. '.tmp'
        os.remove(tmp)
        local ok = pcall(downloadUrlToFile, url .. '?t=' .. os.time(), tmp, function(_, status)
            if status ~= ml.download_status.STATUSEX_ENDDOWNLOAD then return end
            local txt = readFile(tmp)
            os.remove(tmp)
            cb(txt)
        end)
        if not ok then cb(nil) end
    end

    -- ---------- обновление самого скрипта ----------
    local function selfFile()
        local ok, v = pcall(function() return thisScript().path end)
        return ok and v or nil
    end

    function UPD.check(silent)
        if UPD.busy then return end
        UPD.checkedAt = os.time()
        local url = UPD.url('version.json')
        if not url then
            UPD.status = 'norepo'
            if not silent then NotifyErr('The GitHub repository is not set in the script') end
            return
        end
        UPD.busy, UPD.status = true, 'checking'
        UPD.download(url, function(txt)
            UPD.busy = false
            local ok, d = pcall(decodeJson, txt or '')
            if not (ok and type(d) == 'table' and d.version) then
                UPD.status = 'error'
                UPD.say('version.json: ' .. tr('could not be read'))
                if not silent then NotifyErr('Could not check for updates') end
                return
            end
            d.version = tostring(d.version)
            UPD.remote = d
            if vcmp(d.version, thisScript().version) > 0 then
                UPD.status = 'available'
                UPD.say(string.format(tr('Update available: %s'), d.version))
                Notify('Update available: %s', d.version)
                if B('upd_auto', true)[0] then UPD.install() end
            else
                UPD.status = 'uptodate'
                if not silent then Notify('You have the latest version') end
            end
        end)
    end

    local function validate(txt, want)
        if type(txt) ~= 'string' or #txt < 50000 then return false, 'the file is too small' end
        if not txt:find("script_name('COLLAPSE')", 1, true) then return false, 'this is not COLLAPSE' end
        local v = txt:match("script_version%s*%(%s*['\"]([^'\"]+)['\"]")
        if v ~= tostring(want) then return false, 'the version does not match version.json' end
        if not compiles(txt) then return false, 'the file has a syntax error' end
        return true
    end

    function UPD.install()
        local r, path = UPD.remote, selfFile()
        if not r or not path or UPD.busy then return end
        local url = UPD.url(type(r.file) == 'string' and r.file or 'Collapse.lua')
        if not url then NotifyErr('The GitHub repository is not set in the script') return end
        UPD.busy, UPD.status = true, 'installing'
        UPD.download(url, function(txt)
            UPD.busy = false
            local ok, why = validate(txt, r.version)
            if not ok then
                UPD.status = 'error'
                UPD.say(tr('Update rejected') .. ': ' .. tr(why))
                NotifyErr('Update rejected: %s', tr(why))
                return
            end
            local old = readFile(path)
            if old then writeFile(path .. '.bak', old) end
            if not writeFile(path .. '.new', txt) then
                UPD.status = 'error'
                NotifyErr('Could not write the update')
                return
            end
            os.remove(path)
            if not os.rename(path .. '.new', path) then                -- не получилось - возвращаем прежний файл
                if old then writeFile(path, old) end
                UPD.status = 'error'
                NotifyErr('Could not write the update')
                return
            end
            UPD.status = 'installed'
            UPD.say(string.format(tr('Updated to %s'), r.version))
            NotifyOk('Updated to %s. Reloading...', r.version)
            lua_thread.create(function()
                wait(1500)
                thisScript():reload()
            end)
        end)
    end

    function UPD.hasBackup()
        local path = selfFile()
        return path ~= nil and doesFileExist(path .. '.bak')
    end

    function UPD.restore()
        local path = selfFile()
        local old = path and readFile(path .. '.bak')
        if not old or not compiles(old) then NotifyErr('No valid backup found') return end
        if writeFile(path, old) then
            NotifyOk('The previous version is restored. Reloading...')
            lua_thread.create(function()
                wait(1000)
                thisScript():reload()
            end)
        end
    end

    -- проверка при запуске (через 15 с) и раз в 6 часов
    function UPD.tick()
        local now = os.time()
        if now == UPD.lastTick then return end
        UPD.lastTick = now
        if UPD.busy or UPD.cfg.repo == '' or not B('upd_check', true)[0] then return end
        if (not UPD.checkedAt and os.clock() - UPD.t0 > 15) or (UPD.checkedAt and now - UPD.checkedAt > 21600) then UPD.check(true) end
    end

    -- ---------- магазин скриптов ----------
    UPD.store = {list = {}, loaded = false}
    local function regPath() return FNT.filesDir() .. '\\scripts_installed.json' end
    UPD.reg = {}
    do
        local txt = readFile(regPath())
        local ok, d = pcall(decodeJson, txt or '')
        if ok and type(d) == 'table' then UPD.reg = d end
    end
    local function saveReg()
        pcall(FNT.ensureFilesDir)
        writeFile(regPath(), encodeJson(UPD.reg))
    end

    local function cp(s)                                          -- UTF-8 из манифеста -> CP1251 для уведомлений
        local ok, r = pcall(function() return u8:decode(s) end)
        return ok and r or s
    end
    local function target(e)                                      -- имя файла в папке moonloader; чужие пути и сам COLLAPSE не пускаем
        local t = e.target or tostring(e.file or ''):match('([^/]+)$')
        if type(t) ~= 'string' or not t:match('^[%w_%-%. ]+%.lua$') then return nil end
        local me = (selfFile() or ''):match('([^\\/]+)$')
        if me and t:lower() == me:lower() then return nil end
        return t
    end

    function UPD.storeFetch()
        local st = UPD.store
        if st.busy then return end
        local url = UPD.url('scripts.json')
        if not url then NotifyErr('The GitHub repository is not set in the script') return end
        st.busy = true
        UPD.download(url, function(txt)
            st.busy, st.loaded = false, true
            local ok, d = pcall(decodeJson, txt or '')
            st.list = {}
            if not (ok and type(d) == 'table' and type(d.scripts) == 'table') then
                NotifyErr('Could not load the script list')
                return
            end
            for _, e in ipairs(d.scripts) do
                local tgt = type(e) == 'table' and target(e)
                if tgt and UPD.url(e.file) and type(e.name) == 'string' then
                    st.list[#st.list + 1] = {name = e.name, nameC = cp(e.name), desc = tostring(e.desc or ''), file = e.file,
                                             version = tostring(e.version or '0'), tgt = tgt}
                end
            end
        end)
    end

    function UPD.scriptPath(e) return getWorkingDirectory() .. '\\' .. e.tgt end
    function UPD.scriptState(e)                                   -- 0 - не установлен, 1 - установлен, 2 - есть обновление
        if not doesFileExist(UPD.scriptPath(e)) then return 0 end
        return vcmp(e.version, UPD.reg[e.tgt] or '0') > 0 and 2 or 1
    end

    function UPD.scriptInstall(e)
        if e.busy then return end
        local url = UPD.url(e.file)
        if not url then return end
        e.busy = true
        UPD.download(url, function(txt)
            e.busy = false
            if type(txt) ~= 'string' or #txt < 20 or not compiles(txt) then
                NotifyErr('Download failed: %s', e.nameC)
                return
            end
            local path = UPD.scriptPath(e)
            if not writeFile(path, txt) then NotifyErr('Download failed: %s', e.nameC) return end
            UPD.reg[e.tgt] = e.version
            saveReg()
            NotifyOk('Installed: %s', e.nameC)
            pcall(function() script.load(path) end)                -- сразу запускаем (если он уже работал, MoonLoader перезагрузит файл сам)
        end)
    end

    function UPD.scriptRemove(e)
        local path = UPD.scriptPath(e)
        local ok, list = pcall(function() return script.list() end)
        if ok and type(list) == 'table' then
            for _, s in ipairs(list) do
                if tostring(s.path):lower() == path:lower() then pcall(function() s:unload() end) end
            end
        end
        os.remove(path)
        UPD.reg[e.tgt] = nil
        saveReg()
        Notify('Removed: %s', e.nameC)
    end

    -- ---------- Settings -> Updates ----------
    local STATUS = {idle = 'Not checked', norepo = 'Repository is not set', checking = 'Checking...', available = 'Update available',
                    uptodate = 'Up to date', installing = 'Installing...', installed = 'Installed, reloading...', error = 'Error'}

    local function UpdLeft()
        local r = UPD.remote
        InfoRow('Current version', tostring(thisScript().version))
        InfoRow('Latest version', r and tostring(r.version) or '-')
        InfoRow('Status', tr(STATUS[UPD.status] or 'Not checked'))
        imgui.Dummy(P(1, 4))
        InfoRow('Repository', UPD.cfg.repo ~= '' and (UPD.cfg.repo .. ' @ ' .. UPD.cfg.branch) or '-')
        imgui.Dummy(P(1, 4))
        Checkbox('Check for updates on start', B('upd_check', true))
        Checkbox('Install updates automatically', B('upd_auto', true))
        imgui.Dummy(P(1, 6))
        if Button('Check for updates', 32, true, nil, nil, 'ROTATE') then UPD.check(false) end
        if UPD.status == 'available' and Button('Install update', 32, false, nil, nil, 'DOWNLOAD') then UPD.install() end
        if UPD.hasBackup() and Button('Restore previous version', 32, false, nil, 2, 'CLOCK_ROTATE_LEFT') then UPD.restore() end
    end

    local function UpdRight()
        if SRCH.collecting then return end
        local r = UPD.remote
        if r and type(r.changelog) == 'string' and r.changelog ~= '' then
            Text(cp(r.changelog), pal.text)
            imgui.Dummy(P(1, 8))
        end
        for _, s in ipairs(UPD.lines) do Text(s, pal.dim) end
        if not r and #UPD.lines == 0 then Text('No update information yet', pal.dim) end
    end

    content[4][3] = function()
        Panel('Updates', 0, 0, LAY.COLW, LAY.CH, UpdLeft)
        Panel('Changelog', LAY.COLW + 14, 0, LAY.COLW, LAY.CH, UpdRight, true, true)
    end

    -- ---------- Software -> Script store ----------
    local function fitU8(s, maxW)
        if imgui.CalcTextSize(s).x <= maxW then return s end
        while #s > 1 and imgui.CalcTextSize(s .. '..').x > maxW do
            repeat s = s:sub(1, -2) until #s < 2 or s:byte(-1) < 0x80 or s:byte(-1) >= 0xC0
            if #s > 0 and s:byte(-1) >= 0xC0 then s = s:sub(1, -2) end
        end
        return s .. '..'
    end
    local function chip(id, x, y, w, h, label, accent)
        imgui.SetCursorScreenPos(P(x, y))
        local clicked = imgui.InvisibleButton(id, P(w, h))
        local hv = animTo(id, imgui.IsItemHovered() and 1 or 0, 14)
        local dl, tmain = imgui.GetWindowDrawList(), THEME.main
        dl:AddRectFilled(P(x, y), P(x + w, y + h), C(mix(pal.panel, tmain, (accent and 0.30 or 0.08) + hv * 0.2)), 7)
        dl:AddRect(P(x, y), P(x + w, y + h), C(mix(pal.border, tmain, accent and 0.7 or 0.3)), 7)
        local s = u8(tr(label))
        local sz = imgui.CalcTextSize(s)
        dl:AddText(P(x + (w - sz.x) / 2, y + (h - sz.y) / 2), C(mix(pal.text, tmain, accent and 0.5 or 0)), s)
        return clicked
    end

    local function Row(i, e, w)
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local h, bw = 60, 100
        local state = UPD.scriptState(e)
        dl:AddRectFilled(p, P(p.x + w, p.y + h), C(pal.field), 8)
        dl:AddRect(p, P(p.x + w, p.y + h), C(pal.border), 8)
        local vs = 'v' .. e.version .. ((state == 2 and UPD.reg[e.tgt]) and (' (' .. UPD.reg[e.tgt] .. ')') or '')
        local vw = imgui.CalcTextSize(vs).x
        local bx = p.x + w - bw - 12
        local rx = state > 0 and (bx - 90) or bx                  -- левее кнопки установки - «Удалить»
        imgui.PushFont(fonts.bold)
        dl:AddText(P(p.x + 14, p.y + 9), C(pal.text), fitU8(e.name, rx - vw - 24 - (p.x + 14)))
        imgui.PopFont()
        imgui.PushFont(fonts.small)
        dl:AddText(P(p.x + 14, p.y + 34), C(pal.dim), fitU8(e.desc, rx - 12 - (p.x + 14)))
        imgui.PopFont()
        dl:AddText(P(rx - vw - 12, p.y + 22), C(pal.dim), vs)
        local label = e.busy and '...' or (state == 0 and 'Install' or (state == 2 and 'Update' or 'Installed'))
        if chip('##stin' .. i, bx, p.y + 16, bw, 28, label, state ~= 1) and not e.busy and state ~= 1 then UPD.scriptInstall(e) end
        if state > 0 then
            local arm = e.confirm and os.clock() < e.confirm
            if chip('##strm' .. i, rx + 6, p.y + 16, 78, 28, arm and 'Confirm' or 'Remove', false) then
                if arm then
                    e.confirm = nil
                    UPD.scriptRemove(e)
                else
                    e.confirm = os.clock() + 3
                end
            end
        end
        imgui.SetCursorScreenPos(P(p.x, p.y + h + 8))
        imgui.Dummy(P(w, 1))
    end

    local function StoreBody()
        local st = UPD.store
        if not st.loaded and not st.busy and UPD.cfg.repo ~= '' then UPD.storeFetch() end
        if UPD.cfg.repo == '' then Text('The GitHub repository is not set in the script', pal.dim) return end
        if Button('Refresh list', 32, false, nil, nil, 'ROTATE') then UPD.storeFetch() end
        imgui.Dummy(P(1, 6))
        if st.busy then Text('Loading...', pal.dim) return end
        if #st.list == 0 then Text('No scripts in the repository', pal.dim) return end
        local w = imgui.GetContentRegionAvail().x
        for i, e in ipairs(st.list) do Row(i, e, w) end
    end

    SOFT.draw.scripts = function()
        Panel('Script store', 0, 0, LAY.CW, LAY.CH, StoreBody, true, true, function()
            SOFT.pageHeader('store', LAY.CW)
        end, 30)
    end

    -- ---------- подсказки и перевод ----------
    HINTS['Install updates automatically'] = 'When a newer version appears, it is downloaded and installed by itself, then the script reloads. The old file is kept as a backup.'
    local ru = i18n.TR.ru
    for k, v in pairs({
        [HINTS['Install updates automatically']] = 'Когда выходит новая версия, она скачивается и ставится сама, затем скрипт перезагружается. Старый файл сохраняется как резервная копия.',
        ['Updates'] = 'Обновления', ['Changelog'] = 'Что нового', ['Current version'] = 'Текущая версия', ['Latest version'] = 'Последняя версия', ['Status'] = 'Статус',
        ['Repository'] = 'Репозиторий', ['Check for updates on start'] = 'Проверять обновления при запуске',
        ['Install updates automatically'] = 'Устанавливать обновления автоматически', ['Check for updates'] = 'Проверить обновления', ['Install update'] = 'Установить обновление',
        ['Restore previous version'] = 'Вернуть прежнюю версию', ['Not checked'] = 'Не проверялось', ['Repository is not set'] = 'Репозиторий не задан',
        ['Checking...'] = 'Проверка...', ['Update available'] = 'Доступно обновление', ['Up to date'] = 'Актуальная версия', ['Installing...'] = 'Установка...',
        ['Installed, reloading...'] = 'Установлено, перезагрузка...', ['Error'] = 'Ошибка', ['No update information yet'] = 'Сведений об обновлении пока нет',
        ['The GitHub repository is not set in the script'] = 'Репозиторий GitHub не задан в скрипте', ['Could not check for updates'] = 'Не удалось проверить обновления',
        ['You have the latest version'] = 'У вас последняя версия', ['Update available: %s'] = 'Доступно обновление: %s', ['Update rejected'] = 'Обновление отклонено',
        ['Update rejected: %s'] = 'Обновление отклонено: %s', ['Updated to %s'] = 'Обновлено до %s', ['Updated to %s. Reloading...'] = 'Обновлено до %s. Перезагрузка...',
        ['Could not write the update'] = 'Не удалось записать обновление', ['No valid backup found'] = 'Резервная копия не найдена',
        ['The previous version is restored. Reloading...'] = 'Прежняя версия восстановлена. Перезагрузка...', ['could not be read'] = 'не удалось прочитать',
        ['the file is too small'] = 'файл слишком мал', ['this is not COLLAPSE'] = 'это не COLLAPSE', ['the version does not match version.json'] = 'версия не совпадает с version.json',
        ['the file has a syntax error'] = 'в файле синтаксическая ошибка',
        ['Script store'] = 'Магазин скриптов', ['Download scripts'] = 'Скачивание скриптов', ['from GitHub'] = 'из GitHub', ['Install'] = 'Установить', ['Update'] = 'Обновить',
        ['Installed'] = 'Установлен', ['Remove'] = 'Удалить', ['Confirm'] = 'Подтвердить', ['Refresh list'] = 'Обновить список', ['Loading...'] = 'Загрузка...',
        ['No scripts in the repository'] = 'В репозитории нет скриптов', ['Could not load the script list'] = 'Не удалось загрузить список скриптов', ['Download failed: %s'] = 'Не удалось скачать: %s',
        ['Installed: %s'] = 'Установлено: %s', ['Removed: %s'] = 'Удалено: %s',
    }) do if ru[k] == nil then ru[k] = v end end
end

function main()
    ui.search    = imgui.new.char[64]()
    ui.open      = imgui.new.bool(false)
    ui.animSpeed = imgui.new.float(1.0)
    ui.showFps   = imgui.new.bool(true)
    ui.cfgInput  = imgui.new.char[64]()
    ui.lang      = imgui.new.int(0)           -- 0 = English, 1 = Русский (дальше подхватится из конфига)
    ui.cmd       = imgui.new.char[32]()
    ffi.copy(ui.cmd, CMD.cmdName)                 -- команда активации (дальше подхватится из конфига)

    StartupConfig()
    syncLang()

    while not isSampAvailable() do wait(100) end

    CMD.cmdReady = true
    if ctl.cm then ctl.cm.registerCmd() end
    if ctl.uc then ctl.uc.register() end
    registerCmd()                              -- команда из конфига (по умолчанию /collapse)
    Notify('COLLAPSE loaded. Press %s', keyName(binds.menu.key))
    refreshNick()

    while true do
        wait(0)
        if ctl.main.tick then pcall(ctl.main.tick) end          -- Main: анти-лимит скорости, FOV
        if ctl.rd then pcall(ctl.rd.tick) end                      -- ID на радаре
        if ctl.uc then pcall(ctl.uc.tick) end                      -- Godmode, WH на транспорт и др.
        if ctl.upd then pcall(ctl.upd.tick) end                    -- проверка обновлений
        if ctl.ir then pcall(ctl.ir.tick) end                      -- учёт дохода: сохранение, конец пейдея
        if ctl.ap then pcall(ctl.ap.tick) end                      -- автопиар
        if ctl.mm then pcall(ctl.mm.tick) end                      -- сброс лимита, шар, тренер капчи
        if ctl.uf then pcall(ctl.uf.tick) end                      -- порт UltraFuck: функции для авто
        if ctl.ut then pcall(ctl.ut.tick) end                      -- порт UltraTool
        if ctl.fly then pcall(ctl.fly.tick) end                    -- Fly Car
        if ctl.taxi then pcall(ctl.taxi.tick) end                  -- Taxi Helper
        if ctl.cl then pcall(ctl.cl.tick) end                     -- время и погода
        if ctl.calc then pcall(ctl.calc.tick) end                 -- чат-калькулятор
        if ctl.sx then pcall(ctl.sx.tick) end                   -- Speed Boost: ускорение транспорта
        if ctl.far.tick then pcall(ctl.far.tick) end            -- Far chat: сохранение правил, позиция
        SOFT.tick()                                -- отложенное сохранение блокнота
        if SOFT.adm then pcall(SOFT.adm.tick); pcall(SOFT.adm.posTick) end   -- админ-чекер: проверка списка игроков раз в N секунд; выбор места панели

        if ui.open[0] and isKeyDown(0x11) and wasKeyPressed(0x46) then ui.focusSearch = true end   -- Ctrl+F
        if ui.menuKeyBlock and (binds.menu.key == 0 or not isKeyDown(binds.menu.key)) then ui.menuKeyBlock = false end

        if listening then
            local b, first = listening, ctl.lsFirst
            if first and not isKeyDown(first) then                      -- первую клавишу отпустили без второй: одиночная
                ctl.lsFirst, listening = nil, nil
            else
                for k = 3, 254 do
                    if wasKeyPressed(k) and k ~= first and (k < 0xA0 or k > 0xA5) then      -- left/right Shift/Ctrl/Alt duplicate the generic 0x10-0x12 codes
                        if k == 0x1B then
                            b.key, b.mod, ctl.lsFirst, listening = 0, 0, nil, nil
                        elseif first then                               -- вторая клавиша при зажатой первой: сочетание
                            b.mod, b.key, ctl.lsFirst, listening = first, k, nil, nil
                        else
                            b.key, b.mod, ctl.lsFirst = k, 0, k
                        end
                        break
                    end
                end
            end
        elseif not ui.menuKeyBlock and not ((ui.searchActive or ui.fieldActive) and searchConsumesMenuKey(binds.menu.key) and (binds.menu.mod or 0) == 0)
            and ctl.bindFire(binds.menu)
            and not sampIsChatInputActive() and not sampIsDialogActive() then
            ui.open[0] = not ui.open[0]
        end

        TickConfigSave()
    end
end

-- ============================================================================
--  Имена иконок FontAwesome (Font Awesome 6 Free Solid) -> коды символов. Сам шрифт: moonloader\config\xMercy\fa-solid-900.ttf.
--  Лежат в конце файла и читаются при инициализации шрифтов (OnInitialize), см. FNT.fa / FNT.drawIcon.
-- ============================================================================
FNT.faCodes = {
    FAUCET=0xe005, TRAILER=0xe041, BACTERIA=0xe059, BACTERIUM=0xe05a, BOX_TISSUE=0xe05b, HAND_HOLDING_MEDICAL=0xe05c,
    HAND_SPARKLES=0xe05d, HANDS_BUBBLES=0xe05e, HANDSHAKE_SIMPLE_SLASH=0xe05f, HANDSHAKE_SLASH=0xe060, HEAD_SIDE_COUGH=0xe061, HEAD_SIDE_COUGH_SLASH=0xe062,
    HEAD_SIDE_MASK=0xe063, HEAD_SIDE_VIRUS=0xe064, HOUSE_CHIMNEY_USER=0xe065, HOUSE_LAPTOP=0xe066, LUNGS_VIRUS=0xe067, PEOPLE_ARROWS=0xe068,
    PLANE_SLASH=0xe069, PUMP_MEDICAL=0xe06a, PUMP_SOAP=0xe06b, SHIELD_VIRUS=0xe06c, SINK=0xe06d, SOAP=0xe06e,
    STOPWATCH_20=0xe06f, SHOP_SLASH=0xe070, STORE_SLASH=0xe071, TOILET_PAPER_SLASH=0xe072, USERS_SLASH=0xe073, VIRUS=0xe074,
    VIRUS_SLASH=0xe075, VIRUSES=0xe076, VEST=0xe085, VEST_PATCHES=0xe086, MARTINI_GLASS_EMPTY=0xf000, MUSIC=0xf001,
    MAGNIFYING_GLASS=0xf002, HEART=0xf004, STAR=0xf005, USER=0xf007, FILM=0xf008, TABLE_CELLS_LARGE=0xf009,
    TABLE_CELLS=0xf00a, TABLE_LIST=0xf00b, CHECK=0xf00c, XMARK=0xf00d, MAGNIFYING_GLASS_PLUS=0xf00e, MAGNIFYING_GLASS_MINUS=0xf010,
    POWER_OFF=0xf011, SIGNAL=0xf012, GEAR=0xf013, HOUSE=0xf015, CLOCK=0xf017, ROAD=0xf018,
    DOWNLOAD=0xf019, INBOX=0xf01c, ARROW_ROTATE_RIGHT=0xf01e, ARROWS_ROTATE=0xf021, RECTANGLE_LIST=0xf022, LOCK=0xf023,
    FLAG=0xf024, HEADPHONES=0xf025, VOLUME_OFF=0xf026, VOLUME_LOW=0xf027, VOLUME_HIGH=0xf028, QRCODE=0xf029,
    BARCODE=0xf02a, TAG=0xf02b, TAGS=0xf02c, BOOK=0xf02d, BOOKMARK=0xf02e, PRINT=0xf02f,
    CAMERA=0xf030, FONT=0xf031, BOLD=0xf032, ITALIC=0xf033, TEXT_HEIGHT=0xf034, TEXT_WIDTH=0xf035,
    ALIGN_LEFT=0xf036, ALIGN_CENTER=0xf037, ALIGN_RIGHT=0xf038, ALIGN_JUSTIFY=0xf039, LIST=0xf03a, OUTDENT=0xf03b,
    INDENT=0xf03c, VIDEO=0xf03d, IMAGE=0xf03e, LOCATION_PIN=0xf041, CIRCLE_HALF_STROKE=0xf042, DROPLET=0xf043,
    PEN_TO_SQUARE=0xf044, BACKWARD_STEP=0xf048, BACKWARD_FAST=0xf049, BACKWARD=0xf04a, PLAY=0xf04b, PAUSE=0xf04c,
    STOP=0xf04d, FORWARD=0xf04e, FORWARD_FAST=0xf050, FORWARD_STEP=0xf051, EJECT=0xf052, CHEVRON_LEFT=0xf053,
    CHEVRON_RIGHT=0xf054, CIRCLE_PLUS=0xf055, CIRCLE_MINUS=0xf056, CIRCLE_XMARK=0xf057, CIRCLE_CHECK=0xf058, CIRCLE_QUESTION=0xf059,
    CIRCLE_INFO=0xf05a, CROSSHAIRS=0xf05b, BAN=0xf05e, ARROW_LEFT=0xf060, ARROW_RIGHT=0xf061, ARROW_UP=0xf062,
    ARROW_DOWN=0xf063, SHARE=0xf064, EXPAND=0xf065, COMPRESS=0xf066, PLUS=0xf067, MINUS=0xf068,
    ASTERISK=0xf069, CIRCLE_EXCLAMATION=0xf06a, GIFT=0xf06b, LEAF=0xf06c, FIRE=0xf06d, EYE=0xf06e,
    EYE_SLASH=0xf070, TRIANGLE_EXCLAMATION=0xf071, PLANE=0xf072, CALENDAR_DAYS=0xf073, SHUFFLE=0xf074, COMMENT=0xf075,
    MAGNET=0xf076, CHEVRON_UP=0xf077, CHEVRON_DOWN=0xf078, RETWEET=0xf079, CART_SHOPPING=0xf07a, FOLDER=0xf07b,
    FOLDER_OPEN=0xf07c, CHART_BAR=0xf080, CAMERA_RETRO=0xf083, KEY=0xf084, GEARS=0xf085, COMMENTS=0xf086,
    STAR_HALF=0xf089, THUMBTACK=0xf08d, TROPHY=0xf091, UPLOAD=0xf093, LEMON=0xf094, PHONE=0xf095,
    SQUARE_PHONE=0xf098, UNLOCK=0xf09c, CREDIT_CARD=0xf09d, RSS=0xf09e, HARD_DRIVE=0xf0a0, BULLHORN=0xf0a1,
    CERTIFICATE=0xf0a3, HAND_POINT_RIGHT=0xf0a4, HAND_POINT_LEFT=0xf0a5, HAND_POINT_UP=0xf0a6, HAND_POINT_DOWN=0xf0a7, CIRCLE_ARROW_LEFT=0xf0a8,
    CIRCLE_ARROW_RIGHT=0xf0a9, CIRCLE_ARROW_UP=0xf0aa, CIRCLE_ARROW_DOWN=0xf0ab, GLOBE=0xf0ac, WRENCH=0xf0ad, LIST_CHECK=0xf0ae,
    FILTER=0xf0b0, BRIEFCASE=0xf0b1, UP_DOWN_LEFT_RIGHT=0xf0b2, USERS=0xf0c0, LINK=0xf0c1, CLOUD=0xf0c2,
    FLASK=0xf0c3, SCISSORS=0xf0c4, COPY=0xf0c5, PAPERCLIP=0xf0c6, FLOPPY_DISK=0xf0c7, SQUARE=0xf0c8,
    BARS=0xf0c9, LIST_UL=0xf0ca, LIST_OL=0xf0cb, STRIKETHROUGH=0xf0cc, UNDERLINE=0xf0cd, TABLE=0xf0ce,
    WAND_MAGIC=0xf0d0, TRUCK=0xf0d1, MONEY_BILL=0xf0d6, CARET_DOWN=0xf0d7, CARET_UP=0xf0d8, CARET_LEFT=0xf0d9,
    CARET_RIGHT=0xf0da, TABLE_COLUMNS=0xf0db, SORT=0xf0dc, SORT_DOWN=0xf0dd, SORT_UP=0xf0de, ENVELOPE=0xf0e0,
    ARROW_ROTATE_LEFT=0xf0e2, GAVEL=0xf0e3, BOLT=0xf0e7, SITEMAP=0xf0e8, UMBRELLA=0xf0e9, PASTE=0xf0ea,
    LIGHTBULB=0xf0eb, USER_DOCTOR=0xf0f0, STETHOSCOPE=0xf0f1, SUITCASE=0xf0f2, BELL=0xf0f3, MUG_SAUCER=0xf0f4,
    HOSPITAL=0xf0f8, TRUCK_MEDICAL=0xf0f9, SUITCASE_MEDICAL=0xf0fa, JET_FIGHTER=0xf0fb, BEER_MUG_EMPTY=0xf0fc, SQUARE_H=0xf0fd,
    SQUARE_PLUS=0xf0fe, ANGLES_LEFT=0xf100, ANGLES_RIGHT=0xf101, ANGLES_UP=0xf102, ANGLES_DOWN=0xf103, ANGLE_LEFT=0xf104,
    ANGLE_RIGHT=0xf105, ANGLE_UP=0xf106, ANGLE_DOWN=0xf107, DESKTOP=0xf108, LAPTOP=0xf109, TABLET_BUTTON=0xf10a,
    MOBILE_BUTTON=0xf10b, QUOTE_LEFT=0xf10d, QUOTE_RIGHT=0xf10e, SPINNER=0xf110, CIRCLE=0xf111, FACE_SMILE=0xf118,
    FACE_FROWN=0xf119, FACE_MEH=0xf11a, GAMEPAD=0xf11b, KEYBOARD=0xf11c, FLAG_CHECKERED=0xf11e, TERMINAL=0xf120,
    CODE=0xf121, REPLY_ALL=0xf122, LOCATION_ARROW=0xf124, CROP=0xf125, CODE_BRANCH=0xf126, LINK_SLASH=0xf127,
    QUESTION=0xf128, INFO=0xf129, EXCLAMATION=0xf12a, SUPERSCRIPT=0xf12b, SUBSCRIPT=0xf12c, ERASER=0xf12d,
    PUZZLE_PIECE=0xf12e, MICROPHONE=0xf130, MICROPHONE_SLASH=0xf131, CALENDAR=0xf133, FIRE_EXTINGUISHER=0xf134, ROCKET=0xf135,
    CIRCLE_CHEVRON_LEFT=0xf137, CIRCLE_CHEVRON_RIGHT=0xf138, CIRCLE_CHEVRON_UP=0xf139, CIRCLE_CHEVRON_DOWN=0xf13a, ANCHOR=0xf13d, UNLOCK_KEYHOLE=0xf13e,
    BULLSEYE=0xf140, ELLIPSIS=0xf141, ELLIPSIS_VERTICAL=0xf142, SQUARE_RSS=0xf143, CIRCLE_PLAY=0xf144, SQUARE_MINUS=0xf146,
    SQUARE_CHECK=0xf14a, SQUARE_PEN=0xf14b, SHARE_FROM_SQUARE=0xf14d, COMPASS=0xf14e, SQUARE_CARET_DOWN=0xf150, SQUARE_CARET_UP=0xf151,
    SQUARE_CARET_RIGHT=0xf152, EURO_SIGN=0xf153, STERLING_SIGN=0xf154, DOLLAR_SIGN=0xf155, RUPEE_SIGN=0xf156, YEN_SIGN=0xf157,
    RUBLE_SIGN=0xf158, WON_SIGN=0xf159, FILE=0xf15b, FILE_LINES=0xf15c, ARROW_DOWN_A_Z=0xf15d, ARROW_UP_A_Z=0xf15e,
    ARROW_DOWN_WIDE_SHORT=0xf160, ARROW_UP_WIDE_SHORT=0xf161, ARROW_DOWN_1_9=0xf162, ARROW_UP_1_9=0xf163, THUMBS_UP=0xf164, THUMBS_DOWN=0xf165,
    PERSON_DRESS=0xf182, PERSON=0xf183, SUN=0xf185, MOON=0xf186, BOX_ARCHIVE=0xf187, BUG=0xf188,
    SQUARE_CARET_LEFT=0xf191, CIRCLE_DOT=0xf192, WHEELCHAIR=0xf193, LIRA_SIGN=0xf195, SHUTTLE_SPACE=0xf197, SQUARE_ENVELOPE=0xf199,
    BUILDING_COLUMNS=0xf19c, GRADUATION_CAP=0xf19d, LANGUAGE=0xf1ab, FAX=0xf1ac, BUILDING=0xf1ad, CHILD=0xf1ae,
    PAW=0xf1b0, CUBE=0xf1b2, CUBES=0xf1b3, RECYCLE=0xf1b8, CAR=0xf1b9, TAXI=0xf1ba,
    TREE=0xf1bb, DATABASE=0xf1c0, FILE_PDF=0xf1c1, FILE_WORD=0xf1c2, FILE_EXCEL=0xf1c3, FILE_POWERPOINT=0xf1c4,
    FILE_IMAGE=0xf1c5, FILE_ZIPPER=0xf1c6, FILE_AUDIO=0xf1c7, FILE_VIDEO=0xf1c8, FILE_CODE=0xf1c9, LIFE_RING=0xf1cd,
    CIRCLE_NOTCH=0xf1ce, PAPER_PLANE=0xf1d8, CLOCK_ROTATE_LEFT=0xf1da, HEADING=0xf1dc, PARAGRAPH=0xf1dd, SLIDERS=0xf1de,
    SHARE_NODES=0xf1e0, SQUARE_SHARE_NODES=0xf1e1, BOMB=0xf1e2, FUTBOL=0xf1e3, TTY=0xf1e4, BINOCULARS=0xf1e5,
    PLUG=0xf1e6, NEWSPAPER=0xf1ea, WIFI=0xf1eb, CALCULATOR=0xf1ec, BELL_SLASH=0xf1f6, TRASH=0xf1f8,
    COPYRIGHT=0xf1f9, AT=0xf1fa, EYE_DROPPER=0xf1fb, PAINTBRUSH=0xf1fc, CAKE_CANDLES=0xf1fd, CHART_AREA=0xf1fe,
    CHART_PIE=0xf200, CHART_LINE=0xf201, TOGGLE_OFF=0xf204, TOGGLE_ON=0xf205, BICYCLE=0xf206, BUS=0xf207,
    CLOSED_CAPTIONING=0xf20a, SHEKEL_SIGN=0xf20b, CART_PLUS=0xf217, CART_ARROW_DOWN=0xf218, SHIP=0xf21a, USER_SECRET=0xf21b,
    MOTORCYCLE=0xf21c, STREET_VIEW=0xf21d, HEART_PULSE=0xf21e, VENUS=0xf221, MARS=0xf222, MERCURY=0xf223,
    MARS_AND_VENUS=0xf224, TRANSGENDER=0xf225, VENUS_DOUBLE=0xf226, MARS_DOUBLE=0xf227, VENUS_MARS=0xf228, MARS_STROKE=0xf229,
    MARS_STROKE_UP=0xf22a, MARS_STROKE_RIGHT=0xf22b, NEUTER=0xf22c, GENDERLESS=0xf22d, SERVER=0xf233, USER_PLUS=0xf234,
    USER_XMARK=0xf235, BED=0xf236, TRAIN=0xf238, TRAIN_SUBWAY=0xf239, BATTERY_FULL=0xf240, BATTERY_THREE_QUARTERS=0xf241,
    BATTERY_HALF=0xf242, BATTERY_QUARTER=0xf243, BATTERY_EMPTY=0xf244, ARROW_POINTER=0xf245, I_CURSOR=0xf246, OBJECT_GROUP=0xf247,
    OBJECT_UNGROUP=0xf248, NOTE_STICKY=0xf249, CLONE=0xf24d, SCALE_BALANCED=0xf24e, HOURGLASS_START=0xf251, HOURGLASS_HALF=0xf252,
    HOURGLASS_END=0xf253, HOURGLASS=0xf254, HAND_BACK_FIST=0xf255, HAND=0xf256, HAND_SCISSORS=0xf257, HAND_LIZARD=0xf258,
    HAND_SPOCK=0xf259, HAND_POINTER=0xf25a, HAND_PEACE=0xf25b, TRADEMARK=0xf25c, REGISTERED=0xf25d, TV=0xf26c,
    CALENDAR_PLUS=0xf271, CALENDAR_MINUS=0xf272, CALENDAR_XMARK=0xf273, CALENDAR_CHECK=0xf274, INDUSTRY=0xf275, MAP_PIN=0xf276,
    SIGNS_POST=0xf277, MAP=0xf279, MESSAGE=0xf27a, CIRCLE_PAUSE=0xf28b, CIRCLE_STOP=0xf28d, BAG_SHOPPING=0xf290,
    BASKET_SHOPPING=0xf291, HASHTAG=0xf292, PERCENT=0xf295, UNIVERSAL_ACCESS=0xf29a, PERSON_WALKING_WITH_CANE=0xf29d, AUDIO_DESCRIPTION=0xf29e,
    PHONE_VOLUME=0xf2a0, BRAILLE=0xf2a1, EAR_LISTEN=0xf2a2, HANDS_ASL_INTERPRETING=0xf2a3, EAR_DEAF=0xf2a4, HANDS=0xf2a7,
    EYE_LOW_VISION=0xf2a8, HANDSHAKE=0xf2b5, ENVELOPE_OPEN=0xf2b6, ADDRESS_BOOK=0xf2b9, ADDRESS_CARD=0xf2bb, CIRCLE_USER=0xf2bd,
    ID_BADGE=0xf2c1, ID_CARD=0xf2c2, TEMPERATURE_FULL=0xf2c7, TEMPERATURE_THREE_QUARTERS=0xf2c8, TEMPERATURE_HALF=0xf2c9, TEMPERATURE_QUARTER=0xf2ca,
    TEMPERATURE_EMPTY=0xf2cb, SHOWER=0xf2cc, BATH=0xf2cd, PODCAST=0xf2ce, WINDOW_MAXIMIZE=0xf2d0, WINDOW_MINIMIZE=0xf2d1,
    WINDOW_RESTORE=0xf2d2, MICROCHIP=0xf2db, SNOWFLAKE=0xf2dc, SPOON=0xf2e5, UTENSILS=0xf2e7, ROTATE_LEFT=0xf2ea,
    TRASH_CAN=0xf2ed, ROTATE=0xf2f1, STOPWATCH=0xf2f2, RIGHT_FROM_BRACKET=0xf2f5, RIGHT_TO_BRACKET=0xf2f6, ROTATE_RIGHT=0xf2f9,
    POO=0xf2fe, IMAGES=0xf302, PENCIL=0xf303, PEN=0xf304, PEN_CLIP=0xf305, DOWN_LONG=0xf309,
    LEFT_LONG=0xf30a, RIGHT_LONG=0xf30b, UP_LONG=0xf30c, MAXIMIZE=0xf31e, CLIPBOARD=0xf328, LEFT_RIGHT=0xf337,
    UP_DOWN=0xf338, CIRCLE_DOWN=0xf358, CIRCLE_LEFT=0xf359, CIRCLE_RIGHT=0xf35a, CIRCLE_UP=0xf35b, UP_RIGHT_FROM_SQUARE=0xf35d,
    SQUARE_UP_RIGHT=0xf360, RIGHT_LEFT=0xf362, CLOUD_ARROW_DOWN=0xf381, CLOUD_ARROW_UP=0xf382, GEM=0xf3a5, TURN_DOWN=0xf3be,
    TURN_UP=0xf3bf, LOCK_OPEN=0xf3c1, LOCATION_DOT=0xf3c5, MICROPHONE_LINES=0xf3c9, MOBILE_SCREEN_BUTTON=0xf3cd, MONEY_BILL_1=0xf3d1,
    PHONE_SLASH=0xf3dd, IMAGE_PORTRAIT=0xf3e0, REPLY=0xf3e5, SHIELD_HALVED=0xf3ed, TABLET_SCREEN_BUTTON=0xf3fa, GAUGE_HIGH=0xf3fd,
    TICKET_SIMPLE=0xf3ff, USER_LARGE=0xf406, RECTANGLE_XMARK=0xf410, DOWN_LEFT_AND_UP_RIGHT_TO_CENTER=0xf422, UP_RIGHT_AND_DOWN_LEFT_FROM_CENTER=0xf424, BASEBALL=0xf433,
    BASKETBALL=0xf434, BOWLING_BALL=0xf436, CHESS=0xf439, CHESS_BISHOP=0xf43a, CHESS_BOARD=0xf43c, CHESS_KING=0xf43f,
    CHESS_KNIGHT=0xf441, CHESS_PAWN=0xf443, CHESS_QUEEN=0xf445, CHESS_ROOK=0xf447, DUMBBELL=0xf44b, FOOTBALL=0xf44e,
    GOLF_BALL_TEE=0xf450, HOCKEY_PUCK=0xf453, BROOM_BALL=0xf458, SQUARE_FULL=0xf45c, TABLE_TENNIS_PADDLE_BALL=0xf45d, VOLLEYBALL=0xf45f,
    HAND_DOTS=0xf461, BANDAGE=0xf462, BOX=0xf466, BOXES_STACKED=0xf468, BRIEFCASE_MEDICAL=0xf469, FIRE_FLAME_SIMPLE=0xf46a,
    CAPSULES=0xf46b, CLIPBOARD_CHECK=0xf46c, CLIPBOARD_LIST=0xf46d, PERSON_DOTS_FROM_LINE=0xf470, DNA=0xf471, DOLLY=0xf472,
    CART_FLATBED=0xf474, FILE_MEDICAL=0xf477, FILE_WAVEFORM=0xf478, KIT_MEDICAL=0xf479, HOSPITAL_ALT=0xf47d, CIRCLE_H=0xf47e,
    ID_CARD_CLIP=0xf47f, NOTES_MEDICAL=0xf481, PALLET=0xf482, PILLS=0xf484, PRESCRIPTION_BOTTLE=0xf485, PRESCRIPTION_BOTTLE_MEDICAL=0xf486,
    BED_PULSE=0xf487, TRUCK_FAST=0xf48b, SMOKING=0xf48d, SYRINGE=0xf48e, TABLETS=0xf490, THERMOMETER=0xf491,
    VIAL=0xf492, VIALS=0xf493, WAREHOUSE=0xf494, WEIGHT_SCALE=0xf496, X_RAY=0xf497, BOX_OPEN=0xf49e,
    COMMENT_DOTS=0xf4ad, COMMENT_SLASH=0xf4b3, COUCH=0xf4b8, CIRCLE_DOLLAR_TO_SLOT=0xf4b9, DOVE=0xf4ba, HAND_HOLDING=0xf4bd,
    HAND_HOLDING_HEART=0xf4be, HAND_HOLDING_DOLLAR=0xf4c0, HAND_HOLDING_DROPLET=0xf4c1, HANDS_HOLDING=0xf4c2, HANDSHAKE_ANGLE=0xf4c4, PARACHUTE_BOX=0xf4cd,
    PEOPLE_CARRY_BOX=0xf4ce, PIGGY_BANK=0xf4d3, RIBBON=0xf4d6, ROUTE=0xf4d7, SEEDLING=0xf4d8, SIGN_HANGING=0xf4d9,
    FACE_SMILE_WINK=0xf4da, TAPE=0xf4db, TRUCK_RAMP_BOX=0xf4de, TRUCK_MOVING=0xf4df, VIDEO_SLASH=0xf4e2, WINE_GLASS=0xf4e3,
    USER_LARGE_SLASH=0xf4fa, USER_ASTRONAUT=0xf4fb, USER_CHECK=0xf4fc, USER_CLOCK=0xf4fd, USER_GEAR=0xf4fe, USER_PEN=0xf4ff,
    USER_GROUP=0xf500, USER_GRADUATE=0xf501, USER_LOCK=0xf502, USER_MINUS=0xf503, USER_NINJA=0xf504, USER_SHIELD=0xf505,
    USER_SLASH=0xf506, USER_TAG=0xf507, USER_TIE=0xf508, USERS_GEAR=0xf509, SCALE_UNBALANCED=0xf515, SCALE_UNBALANCED_FLIP=0xf516,
    BLENDER=0xf517, BOOK_OPEN=0xf518, TOWER_BROADCAST=0xf519, BROOM=0xf51a, CHALKBOARD=0xf51b, CHALKBOARD_USER=0xf51c,
    CHURCH=0xf51d, COINS=0xf51e, COMPACT_DISC=0xf51f, CROW=0xf520, CROWN=0xf521, DICE=0xf522,
    DICE_FIVE=0xf523, DICE_FOUR=0xf524, DICE_ONE=0xf525, DICE_SIX=0xf526, DICE_THREE=0xf527, DICE_TWO=0xf528,
    DIVIDE=0xf529, DOOR_CLOSED=0xf52a, DOOR_OPEN=0xf52b, EQUALS=0xf52c, FEATHER=0xf52d, FROG=0xf52e,
    GAS_PUMP=0xf52f, GLASSES=0xf530, GREATER_THAN=0xf531, GREATER_THAN_EQUAL=0xf532, HELICOPTER=0xf533, INFINITY=0xf534,
    KIWI_BIRD=0xf535, LESS_THAN=0xf536, LESS_THAN_EQUAL=0xf537, MEMORY=0xf538, MICROPHONE_LINES_SLASH=0xf539, MONEY_BILL_WAVE=0xf53a,
    MONEY_BILL_1_WAVE=0xf53b, MONEY_CHECK=0xf53c, MONEY_CHECK_DOLLAR=0xf53d, NOT_EQUAL=0xf53e, PALETTE=0xf53f, SQUARE_PARKING=0xf540,
    PERCENTAGE=0xf541, DIAGRAM_PROJECT=0xf542, RECEIPT=0xf543, ROBOT=0xf544, RULER=0xf545, RULER_COMBINED=0xf546,
    RULER_HORIZONTAL=0xf547, RULER_VERTICAL=0xf548, SCHOOL=0xf549, SCREWDRIVER=0xf54a, SHOE_PRINTS=0xf54b, SKULL=0xf54c,
    BAN_SMOKING=0xf54d, STORE=0xf54e, SHOP=0xf54f, BARS_STAGGERED=0xf550, STROOPWAFEL=0xf551, TOOLBOX=0xf552,
    SHIRT=0xf553, PERSON_WALKING=0xf554, WALLET=0xf555, FACE_ANGRY=0xf556, ARCHWAY=0xf557, BOOK_ATLAS=0xf558,
    AWARD=0xf559, DELETE_LEFT=0xf55a, BEZIER_CURVE=0xf55b, BONG=0xf55c, BRUSH=0xf55d, BUS_SIMPLE=0xf55e,
    CANNABIS=0xf55f, CHECK_DOUBLE=0xf560, MARTINI_GLASS_CITRUS=0xf561, BELL_CONCIERGE=0xf562, COOKIE=0xf563, COOKIE_BITE=0xf564,
    CROP_SIMPLE=0xf565, TACHOGRAPH_DIGITAL=0xf566, FACE_DIZZY=0xf567, COMPASS_DRAFTING=0xf568, DRUM=0xf569, DRUM_STEELPAN=0xf56a,
    FEATHER_POINTED=0xf56b, FILE_CONTRACT=0xf56c, FILE_ARROW_DOWN=0xf56d, FILE_EXPORT=0xf56e, FILE_IMPORT=0xf56f, FILE_INVOICE=0xf570,
    FILE_INVOICE_DOLLAR=0xf571, FILE_PRESCRIPTION=0xf572, FILE_SIGNATURE=0xf573, FILE_ARROW_UP=0xf574, FILL=0xf575, FILL_DRIP=0xf576,
    FINGERPRINT=0xf577, FISH=0xf578, FACE_FLUSHED=0xf579, FACE_FROWN_OPEN=0xf57a, MARTINI_GLASS=0xf57b, EARTH_AFRICA=0xf57c,
    EARTH_AMERICAS=0xf57d, EARTH_ASIA=0xf57e, FACE_GRIMACE=0xf57f, FACE_GRIN=0xf580, FACE_GRIN_WIDE=0xf581, FACE_GRIN_BEAM=0xf582,
    FACE_GRIN_BEAM_SWEAT=0xf583, FACE_GRIN_HEARTS=0xf584, FACE_GRIN_SQUINT=0xf585, FACE_GRIN_SQUINT_TEARS=0xf586, FACE_GRIN_STARS=0xf587, FACE_GRIN_TEARS=0xf588,
    FACE_GRIN_TONGUE=0xf589, FACE_GRIN_TONGUE_SQUINT=0xf58a, FACE_GRIN_TONGUE_WINK=0xf58b, FACE_GRIN_WINK=0xf58c, GRIP=0xf58d, GRIP_VERTICAL=0xf58e,
    HEADPHONES_SIMPLE=0xf58f, HEADSET=0xf590, HIGHLIGHTER=0xf591, HOT_TUB_PERSON=0xf593, HOTEL=0xf594, JOINT=0xf595,
    FACE_KISS=0xf596, FACE_KISS_BEAM=0xf597, FACE_KISS_WINK_HEART=0xf598, FACE_LAUGH=0xf599, FACE_LAUGH_BEAM=0xf59a, FACE_LAUGH_SQUINT=0xf59b,
    FACE_LAUGH_WINK=0xf59c, CART_FLATBED_SUITCASE=0xf59d, MAP_LOCATION=0xf59f, MAP_LOCATION_DOT=0xf5a0, MARKER=0xf5a1, MEDAL=0xf5a2,
    FACE_MEH_BLANK=0xf5a4, FACE_ROLLING_EYES=0xf5a5, MONUMENT=0xf5a6, MORTAR_PESTLE=0xf5a7, PAINT_ROLLER=0xf5aa, PASSPORT=0xf5ab,
    PEN_FANCY=0xf5ac, PEN_NIB=0xf5ad, PEN_RULER=0xf5ae, PLANE_ARRIVAL=0xf5af, PLANE_DEPARTURE=0xf5b0, PRESCRIPTION=0xf5b1,
    FACE_SAD_CRY=0xf5b3, FACE_SAD_TEAR=0xf5b4, VAN_SHUTTLE=0xf5b6, SIGNATURE=0xf5b7, FACE_SMILE_BEAM=0xf5b8, SOLAR_PANEL=0xf5ba,
    SPA=0xf5bb, SPLOTCH=0xf5bc, SPRAY_CAN=0xf5bd, STAMP=0xf5bf, STAR_HALF_STROKE=0xf5c0, SUITCASE_ROLLING=0xf5c1,
    FACE_SURPRISE=0xf5c2, SWATCHBOOK=0xf5c3, PERSON_SWIMMING=0xf5c4, WATER_LADDER=0xf5c5, DROPLET_SLASH=0xf5c7, FACE_TIRED=0xf5c8,
    TOOTH=0xf5c9, UMBRELLA_BEACH=0xf5ca, VECTOR_SQUARE=0xf5cb, WEIGHT_HANGING=0xf5cd, WINE_GLASS_EMPTY=0xf5ce, SPRAY_CAN_SPARKLES=0xf5d0,
    APPLE_WHOLE=0xf5d1, ATOM=0xf5d2, BONE=0xf5d7, BOOK_OPEN_READER=0xf5da, BRAIN=0xf5dc, CAR_REAR=0xf5de,
    CAR_BATTERY=0xf5df, CAR_BURST=0xf5e1, CAR_SIDE=0xf5e4, CHARGING_STATION=0xf5e7, DIAMOND_TURN_RIGHT=0xf5eb, DRAW_POLYGON=0xf5ee,
    LAPTOP_CODE=0xf5fc, LAYER_GROUP=0xf5fd, LUNGS=0xf604, MICROSCOPE=0xf610, OIL_CAN=0xf613, POOP=0xf619,
    SHAPES=0xf61f, STAR_OF_LIFE=0xf621, TEETH=0xf62e, TEETH_OPEN=0xf62f, MASKS_THEATER=0xf630, TRAFFIC_LIGHT=0xf637,
    TRUCK_MONSTER=0xf63b, TRUCK_PICKUP=0xf63c, RECTANGLE_AD=0xf641, ANKH=0xf644, BOOK_BIBLE=0xf647, BUSINESS_TIME=0xf64a,
    CITY=0xf64f, COMMENT_DOLLAR=0xf651, COMMENTS_DOLLAR=0xf653, CROSS=0xf654, DHARMACHAKRA=0xf655, ENVELOPE_OPEN_TEXT=0xf658,
    FOLDER_MINUS=0xf65d, FOLDER_PLUS=0xf65e, FILTER_CIRCLE_DOLLAR=0xf662, GOPURAM=0xf664, HAMSA=0xf665, BAHAI=0xf666,
    JEDI=0xf669, BOOK_JOURNAL_WHILLS=0xf66a, KAABA=0xf66b, KHANDA=0xf66d, LANDMARK=0xf66f, ENVELOPES_BULK=0xf674,
    MENORAH=0xf676, MOSQUE=0xf678, OM=0xf679, SPAGHETTI_MONSTER_FLYING=0xf67b, PEACE=0xf67c, PLACE_OF_WORSHIP=0xf67f,
    SQUARE_POLL_VERTICAL=0xf681, SQUARE_POLL_HORIZONTAL=0xf682, PERSON_PRAYING=0xf683, HANDS_PRAYING=0xf684, BOOK_QURAN=0xf687, MAGNIFYING_GLASS_DOLLAR=0xf688,
    MAGNIFYING_GLASS_LOCATION=0xf689, SOCKS=0xf696, SQUARE_ROOT_VARIABLE=0xf698, STAR_AND_CRESCENT=0xf699, STAR_OF_DAVID=0xf69a, SYNAGOGUE=0xf69b,
    SCROLL_TORAH=0xf6a0, TORII_GATE=0xf6a1, VIHARA=0xf6a7, VOLUME_XMARK=0xf6a9, YIN_YANG=0xf6ad, BLENDER_PHONE=0xf6b6,
    BOOK_SKULL=0xf6b7, CAMPGROUND=0xf6bb, CAT=0xf6be, CHAIR=0xf6c0, CLOUD_MOON=0xf6c3, CLOUD_SUN=0xf6c4,
    DICE_D20=0xf6cf, DICE_D6=0xf6d1, DOG=0xf6d3, DRAGON=0xf6d5, DRUMSTICK_BITE=0xf6d7, DUNGEON=0xf6d9,
    FILE_CSV=0xf6dd, HAND_FIST=0xf6de, GHOST=0xf6e2, HAMMER=0xf6e3, HANUKIAH=0xf6e6, HAT_WIZARD=0xf6e8,
    PERSON_HIKING=0xf6ec, HIPPO=0xf6ed, HORSE=0xf6f0, HOUSE_CHIMNEY_CRACK=0xf6f1, HRYVNIA_SIGN=0xf6f2, MASK=0xf6fa,
    MOUNTAIN=0xf6fc, NETWORK_WIRED=0xf6ff, OTTER=0xf700, RING=0xf70b, PERSON_RUNNING=0xf70c, SCROLL=0xf70e,
    SKULL_CROSSBONES=0xf714, SLASH=0xf715, SPIDER=0xf717, TOILET_PAPER=0xf71e, TRACTOR=0xf722, USER_INJURED=0xf728,
    VR_CARDBOARD=0xf729, WIND=0xf72e, WINE_BOTTLE=0xf72f, CLOUD_MEATBALL=0xf73b, CLOUD_MOON_RAIN=0xf73c, CLOUD_RAIN=0xf73d,
    CLOUD_SHOWERS_HEAVY=0xf740, CLOUD_SUN_RAIN=0xf743, DEMOCRAT=0xf747, FLAG_USA=0xf74d, METEOR=0xf753, PERSON_BOOTH=0xf756,
    POO_STORM=0xf75a, RAINBOW=0xf75b, REPUBLICAN=0xf75e, SMOG=0xf75f, TEMPERATURE_HIGH=0xf769, TEMPERATURE_LOW=0xf76b,
    CHECK_TO_SLOT=0xf772, WATER=0xf773, BABY=0xf77c, BABY_CARRIAGE=0xf77d, BIOHAZARD=0xf780, BLOG=0xf781,
    CALENDAR_DAY=0xf783, CALENDAR_WEEK=0xf784, CANDY_CANE=0xf786, CARROT=0xf787, CASH_REGISTER=0xf788, MINIMIZE=0xf78c,
    DUMPSTER=0xf793, DUMPSTER_FIRE=0xf794, ETHERNET=0xf796, GIFTS=0xf79c, CHAMPAGNE_GLASSES=0xf79f, WHISKEY_GLASS=0xf7a0,
    EARTH_EUROPE=0xf7a2, GRIP_LINES=0xf7a4, GRIP_LINES_VERTICAL=0xf7a5, GUITAR=0xf7a6, HEART_CRACK=0xf7a9, HOLLY_BERRY=0xf7aa,
    HORSE_HEAD=0xf7ab, ICICLES=0xf7ad, IGLOO=0xf7ae, MITTEN=0xf7b5, MUG_HOT=0xf7b6, RADIATION=0xf7b9,
    CIRCLE_RADIATION=0xf7ba, RESTROOM=0xf7bd, SATELLITE=0xf7bf, SATELLITE_DISH=0xf7c0, SD_CARD=0xf7c2, SIM_CARD=0xf7c4,
    PERSON_SKATING=0xf7c5, PERSON_SKIING=0xf7c9, PERSON_SKIING_NORDIC=0xf7ca, SLEIGH=0xf7cc, COMMENT_SMS=0xf7cd, PERSON_SNOWBOARDING=0xf7ce,
    SNOWMAN=0xf7d0, SNOWPLOW=0xf7d2, TENGE_SIGN=0xf7d7, TOILET=0xf7d8, SCREWDRIVER_WRENCH=0xf7d9, CABLE_CAR=0xf7da,
    FIRE_FLAME_CURVED=0xf7e4, BACON=0xf7e5, BOOK_MEDICAL=0xf7e6, BREAD_SLICE=0xf7ec, CHEESE=0xf7ef, HOUSE_CHIMNEY_MEDICAL=0xf7f2,
    COMMENT_MEDICAL=0xf7f5, CRUTCH=0xf7f7, DISEASE=0xf7fa, EGG=0xf7fb, BURGER=0xf805, HAND_MIDDLE_FINGER=0xf806,
    HELMET_SAFETY=0xf807, HOSPITAL_USER=0xf80d, HOTDOG=0xf80f, ICE_CREAM=0xf810, LAPTOP_MEDICAL=0xf812, PAGER=0xf815,
    PEPPER_HOT=0xf816, PIZZA_SLICE=0xf818, TRASH_ARROW_UP=0xf829, TRASH_CAN_ARROW_UP=0xf82a, USER_NURSE=0xf82f, WAVE_SQUARE=0xf83e,
    PERSON_BIKING=0xf84a, BORDER_ALL=0xf84c, BORDER_NONE=0xf850, BORDER_TOP_LEFT=0xf853, FAN=0xf863, ICONS=0xf86d,
    PHONE_FLIP=0xf879, SQUARE_PHONE_FLIP=0xf87b, PHOTO_FILM=0xf87c, TEXT_SLASH=0xf87d, ARROW_DOWN_Z_A=0xf881, ARROW_UP_Z_A=0xf882,
    ARROW_DOWN_SHORT_WIDE=0xf884, ARROW_UP_SHORT_WIDE=0xf885, ARROW_DOWN_9_1=0xf886, ARROW_UP_9_1=0xf887, SPELL_CHECK=0xf891, VOICEMAIL=0xf897,
    HAT_COWBOY=0xf8c0, HAT_COWBOY_SIDE=0xf8c1, COMPUTER_MOUSE=0xf8cc, RECORD_VINYL=0xf8d9, CARAVAN=0xf8ff,
}
