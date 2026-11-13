-- ============================================================
--  Конвертер раскладки (замена Punto Switcher)
--
--  Нажать и отпустить Ctrl+Option (без других клавиш):
--    • есть выделение  → конвертирует выделенный текст
--    • нет выделения   → конвертирует последнее слово перед курсором
--  После конвертации раскладка переключается на нужную.
--
--  Обычные нажатия клавиш скрипт НЕ перехватывает: он слушает только
--  события модификаторов (Ctrl/Option/Shift/Cmd), а обычные клавиши
--  отслеживает лишь пока зажаты Ctrl+Option.
-- ============================================================

require("hs.ipc")        -- консольная утилита `hs` (нужна установщику для перезагрузки)
hs.autoLaunch(true)      -- запускать при входе в систему

local EN_LAYOUT = "com.apple.keylayout.US"
local RU_LAYOUT = "com.apple.keylayout.RussianWin"   -- «Русская – ПК»

-- Соответствие клавиш U.S. ↔ Русская – ПК (снято с системных раскладок)
local KEYS = {
  {"q","й"},{"w","ц"},{"e","у"},{"r","к"},{"t","е"},{"y","н"},{"u","г"},{"i","ш"},
  {"o","щ"},{"p","з"},{"[","х"},{"]","ъ"},{"a","ф"},{"s","ы"},{"d","в"},{"f","а"},
  {"g","п"},{"h","р"},{"j","о"},{"k","л"},{"l","д"},{";","ж"},{"'","э"},{"z","я"},
  {"x","ч"},{"c","с"},{"v","м"},{"b","и"},{"n","т"},{"m","ь"},{",","б"},{".","ю"},
  {"/","."},{"§","ё"},{"`","]"},
  {"Q","Й"},{"W","Ц"},{"E","У"},{"R","К"},{"T","Е"},{"Y","Н"},{"U","Г"},{"I","Ш"},
  {"O","Щ"},{"P","З"},{"{","Х"},{"}","Ъ"},{"A","Ф"},{"S","Ы"},{"D","В"},{"F","А"},
  {"G","П"},{"H","Р"},{"J","О"},{"K","Л"},{"L","Д"},{":","Ж"},{'"',"Э"},{"Z","Я"},
  {"X","Ч"},{"C","С"},{"V","М"},{"B","И"},{"N","Т"},{"M","Ь"},{"<","Б"},{">","Ю"},
  {"?",","},{"±","Ё"},{"~","["},
  {"@",'"'},{"#","№"},{"$",";"},{"^",":"},{"&","?"},{"|","/"},
}
local EN2RU, RU2EN = {}, {}
for _, p in ipairs(KEYS) do EN2RU[p[1]] = p[2]; RU2EN[p[2]] = p[1] end

-- Конвертирует строку; направление выбирается по тому, каких букв больше
function convertLayout(s)
  local cyr, lat = 0, 0
  for _, c in utf8.codes(s) do
    if (c >= 0x410 and c <= 0x44F) or c == 0x401 or c == 0x451 then cyr = cyr + 1
    elseif (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then lat = lat + 1 end
  end
  local map, target = EN2RU, RU_LAYOUT
  if cyr > lat then map, target = RU2EN, EN_LAYOUT end
  local out = {}
  for _, c in utf8.codes(s) do
    local ch = utf8.char(c)
    out[#out + 1] = map[ch] or ch
  end
  return table.concat(out), target
end

-- ---------- работа с выделением и буфером обмена ----------
local pb = hs.pasteboard
local S = {}   -- состояние (держим ссылки на таймеры/тапы, чтобы их не собрал GC)

-- в терминалах «последнее слово» не трогаем (Cmd+Shift+← там работает иначе)
local NO_LASTWORD = {
  ["com.apple.Terminal"] = true, ["com.googlecode.iterm2"] = true,
  ["dev.warp.Warp-Stable"] = true, ["com.mitchellh.ghostty"] = true,
}

local function key(mods, k) hs.eventtap.keyStroke(mods, k, 5000) end

local function waitClipboard(oldCount, timeout, cb)
  local t0 = hs.timer.secondsSinceEpoch()
  S.wait = hs.timer.doEvery(0.02, function()
    if pb.changeCount() ~= oldCount then S.wait:stop(); cb(true)
    elseif hs.timer.secondsSinceEpoch() - t0 > timeout then S.wait:stop(); cb(false) end
  end)
end

local function finish(saved, target)
  S.restore = hs.timer.doAfter(0.4, function()
    if saved then pcall(pb.writeAllData, saved) end
    if target then hs.keycodes.currentSourceID(target) end
    S.busy = false
  end)
end

local function paste(text, saved, target)
  pb.setContents(text)
  key({"cmd"}, "v")
  finish(saved, target)
end

function convertNow()
  if S.busy then return end
  S.busy = true
  local okSave, saved = pcall(pb.readAllData)
  if not okSave then saved = nil end

  -- 1) пробуем скопировать выделение
  local c0 = pb.changeCount()
  key({"cmd"}, "c")
  waitClipboard(c0, 0.25, function(changed)
    local sel = changed and pb.getContents() or nil
    if sel and sel ~= "" then
      local conv, target = convertLayout(sel)
      if conv ~= sel then paste(conv, saved, target) else finish(saved) end
      return
    end

    -- 2) выделения нет → берём последнее слово перед курсором
    local app = hs.application.frontmostApplication()
    if app and NO_LASTWORD[app:bundleID()] then finish(saved); return end

    key({"cmd", "shift"}, "left")              -- выделить до начала строки
    local c1 = pb.changeCount()
    key({"cmd"}, "c")
    waitClipboard(c1, 0.25, function(changed2)
      if not changed2 then finish(saved); return end   -- курсор в начале строки
      local line = pb.getContents() or ""
      key({}, "right")                          -- снять выделение, курсор на место
      local trail = line:match("%s*$")
      local word = line:sub(1, #line - #trail):match("(%S+)$")
      if not word then finish(saved); return end
      local conv, target = convertLayout(word)
      if conv == word then finish(saved); return end
      for _ = 1, utf8.len(word) + utf8.len(trail) do key({"shift"}, "left") end
      paste(conv .. trail, saved, target)
    end)
  end)
end

-- ---------- горячая клавиша: Ctrl+Option (нажать и отпустить) ----------
local types = hs.eventtap.event.types

local function mods(e)
  local f = e:getFlags()
  return f.ctrl, f.alt, (f.cmd or f.shift or f.fn)
end

local function disarm()
  S.armed = false
  if S.keyWatch then S.keyWatch:stop(); S.keyWatch = nil end
end

S.flagsTap = hs.eventtap.new({types.flagsChanged}, function(e)
  local ctrl, alt, other = mods(e)
  if other then disarm(); return false end
  if ctrl and alt then
    if not S.armed then
      S.armed, S.armedAt = true, hs.timer.secondsSinceEpoch()
      -- пока зажаты Ctrl+Option, следим: если нажата другая клавиша — это не наш хоткей
      S.keyWatch = hs.eventtap.new(
        {types.keyDown, types.leftMouseDown, types.rightMouseDown, types.otherMouseDown},
        function() disarm(); return false end)
      S.keyWatch:start()
    end
  elseif not ctrl and not alt then
    if S.armed and hs.timer.secondsSinceEpoch() - S.armedAt < 1.0 then
      disarm()
      hs.timer.doAfter(0.01, convertNow)
    else
      disarm()
    end
  end
  return false
end)
S.flagsTap:start()

-- macOS иногда отключает event tap; проверяем и включаем обратно
S.watchdog = hs.timer.doEvery(5, function()
  if not S.flagsTap:isEnabled() then S.flagsTap:start() end
end)

hs.alert.show("Конвертер раскладки: Ctrl+Option")
