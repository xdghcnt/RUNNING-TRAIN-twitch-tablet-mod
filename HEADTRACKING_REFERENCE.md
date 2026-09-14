# HeadTracking reference

Выжимка из `../HeadTracking` (рабочий мод для той же игры, того же UE4SS и того же
toolchain). Источники: `README.md`, `notes/progress.md`, `notes/camera-candidates.md`,
`Mods/RunningTrainHeadTracking/scripts/main.lua`, `src/RunningTrainHeadTrackingUDP/dllmain.cpp`,
`scripts/*.ps1`, реальный `UE4SS.log` игры и публичный исходник RE-UE4SS на коммите
`1c1a1497` (`../HeadTracking/third_party/RE-UE4SS`).

Цель файла — отделить **уже доказанное** от того, что для TwitchTablet
действительно придётся исследовать. Всё, помеченное *(исходник UE4SS)*, прочитано
в коде, но в игре HeadTracking'ом не проверялось.

---

## Игра и окружение

| | |
|---|---|
| Игра | RUNNING TRAIN / 走ル列車！, Steam AppID **4630570**, Early Access |
| Engine | **UE 5.7** (`++UE5+Release-5.7-CL-50162420`), D3D12, IoStore |
| Exe | `C:\Games\Steam\steamapps\common\RUNNING TRAIN\RunningTrain\Binaries\Win64\RunningTrain-Win64-Shipping.exe` |
| Anti-cheat / DRM | нет (проверено сканом) |
| Поиск игры | `HeadTracking/scripts/Find-RunningTrain.ps1` — реестр Steam + `libraryfolders.vdf`, без хардкода |
| Карта | одна persistent-карта `/Game/_MainMaps/_MainPresistent` (sic), маршруты грузятся через `LoadMap` |

## UE4SS/build setup

**Версия UE4SS.** `v3.0.1 Beta #0, Git SHA 1c1a1497`, `Game__Shipping__Win64 (MSVC)`.
Stable v3.0.1 UE 5.7 не поддерживает — нужен experimental. `UE4SS.dll` в zDEV и
standard пакетах побайтово одинаков (SHA256 `F31188D5…`, 16 473 088 байт, 4106 экспортов).

**Сейчас в игре стоит release-установка HeadTracking** (standard UE4SS, консоли выключены):
`Win64\dwmapi.dll` + `Win64\ue4ss\` с модами прямо в `ue4ss\Mods`.
`+ModsFolderPaths` сейчас **не** используется.

**Обязательная правка для UE 5.7:** `ue4ss/UE4SS_Signatures/FName_Constructor.lua`
(AOB на `FName::FName(const WIDECHAR*, EFindName)`, RVA `0x12C81D0`). Без неё
`Fatal Error: PS scan timed out`. Уже установлена; TwitchTablet её не трогает.
Старт UE4SS задерживается ~1–10 с на верификации FName — это норма.

**Известные предупреждения лога (не ошибки):** `FUObjectHashTables::Get()` и `GNatives`
не найдены (optional); `GNatives not found, you will experience limited hooking
functionality in certain scenarios`; `VTable and scan addresses differ for UGameEngine::Tick
... Using scan address`.

**Unreal C++ headers недоступны.** `deps/first/Unreal` = приватный `Re-UE4SS/UEPseudo`
(404 анонимно; повторно проверено 2026-09-14: ни SSH, ни HTTPS доступа нет).
Поэтому официальный `UE4SSCPPTemplate` не собирается, а **C++ мод не может трогать UObject**
через UE4SS C++ API. Вся работа с UObject в HeadTracking — в **Lua**.

**Как всё же собирается C++ мод** (`HeadTracking/scripts/Get-BuildDeps.ps1`, `Build-CppMod.ps1`):
1. публичный RE-UE4SS на `1c1a1497` (`git clone --filter=blob:none`, без сабмодулей) + `fmt` 10.2.1 headers;
2. **урезанный** `CppUserModBase.hpp` (скриптом): убраны невиртуальные `register_tab`,
   `register_keydown_event` и include `GUI/GUITab.hpp` (тянет UEPseudo). Layout и порядок
   виртуальных функций не меняются;
3. `UE4SS.lib` синтезируется из таблицы экспорта `UE4SS.dll` (`scripts/gen_ue4ss_def.py`,
   `lib /def:`). **Имена в `.def` без кавычек** — иначе пустая import lib и LNK2019;
4. `cl /MD /O2 /EHsc /std:c++20 /permissive- /DNOMINMAX /DWIN32_LEAN_AND_MEAN` + `link /DLL`.
   Только Release и `/MD` — иначе ABI/CRT расходится с UE4SS.
5. Toolchain: VS 2022 Build Tools, toolset `14.44.35207`, найден через `vswhere`.

Результат кладётся в `Mods/<Name>/dlls/main.dll`. Мод = `start_mod()` / `uninstall_mod()` экспорты.

**C++ ↔ Lua мост.** `CppUserModBase::on_lua_start(mod_name, lua, main_lua, async_lua, hook_lua)`
вызывается для каждого Lua-мода; внутри `lua.register_function("Name", &static_fn)`
во **все** четыре состояния. `LuaFunction` — голый указатель на функцию, инстанс через
static-указатель. Бинарный Lua-модуль через `require` невозможен: `UE4SS.dll` не
экспортирует `lua_*`. Сети в UE4SS Lua нет.

**Деплой.** Моды включаются строкой в `mods.txt` **или** `enabled.txt` в папке мода
(`enabled.txt` работает для всех каталогов из `ModsFolderPaths` *(исходник UE4SS)*).
Dev-вариант: `+ModsFolderPaths = <abs path>` в секции `[Overrides]` файла
`ue4ss/UE4SS-settings.ini` — исходники мода не копируются в игру.
`--disable-ue4ss` в параметрах запуска — ванильная игра без удаления файлов.

**PowerShell 5.1:** `Set-Content -Encoding UTF8` пишет BOM → первая строка `mods.txt`
ломается. Писать через `[IO.File]::WriteAllLines(..., New-Object Text.UTF8Encoding($false))`.

**Проверка Lua до запуска игры:** `python -c "import lupa"` (lupa 2.8, Lua 5.5; UE4SS — Lua 5.4.7).
В 5.4 переменная `for` константна — HeadTracking поймал это офлайн.

## Hooks/lifecycle

Что реально используется и работает:

| API | Где исполняется | Статус в RUNNING TRAIN |
|---|---|---|
| `RegisterKeyBind(key, {mods}, fn)` | поток event loop UE4SS, **под** `m_thread_actions_mutex` *(исходник)* | работает |
| `LoopAsync(ms, fn)` | async-поток мода, **без** мьютекса *(исходник)* | работает, основной цикл HeadTracking (8 мс) |
| `RegisterLoadMapPreHook` / `RegisterLoadMapPostHook` | — | работают, срабатывают на каждой смене маршрута/меню |
| `ExecuteInGameThread(fn)` (EngineTick по умолчанию) | game thread | **ненадёжно**: 2 колбэка дошли в начале сессии, дальше не доставлялись вообще |

Не проверено HeadTracking'ом, но есть в этой сборке *(исходник/доки UE4SS)*:
`ExecuteInGameThread(fn, EGameThreadMethod.ProcessEvent)`, `ExecuteInGameThreadWithDelay`,
`LoopInGameThreadWithDelay`, `LoopInGameThreadAfterFrames`, `RegisterHook` на UFunction
(pre/post; post для BP-функций не работает — у script hook один id), `NotifyOnNewObject`,
`RegisterBeginPlayPostHook`, `RegisterConsoleCommandHandler`, `IsInGameThread()`,
`EngineTickAvailable` / `ProcessEventAvailable`, `RegisterKeyBindAsync`.

**Устройство game-thread очередей** *(исходник `LuaMod.cpp`)*: колбэки EngineTick/ProcessEvent
вызываются **без** мьютекса; есть глобальный флаг `m_is_currently_executing_game_action` —
пока один game-action исполняется, остальные откладываются. `LoadAsset` разрешено
вызывать **только на game thread**. `UWorld:SpawnActor(Class, Loc, Rot)` =
`BeginDeferredActorSpawnFromClass` + `FinishSpawningActor`.

**Все Lua-контексты мода — `lua_newthread` одного `lua_State`** (hook_lua, async_lua,
main_lua) *(исходник)*. Мьютексом защищены только очереди, не исполнение. Отсюда
главный урок ниже.

## UWorld / PlayerController / Pawn lookup

Работающая цепочка (из async-потока и keybind-колбэков):

```lua
local pc  = FindFirstOf("PlayerController")      -- /Script/Engine.PlayerController_<n>
local pcm = pc.PlayerCameraManager               -- /Script/Engine.PlayerCameraManager
local pov = pcm:GetCameraLocation()              -- также GetCameraRotation(), GetFOVAngle()
                                                 -- и pcm.CameraCachePrivate.POV
local cams = FindAllOf("CameraComponent")
-- активная камера: c.bIsActive (или c:IsActive()), расстояние до POV — только tie-breaker
```

- ViewTarget = `PyBP_Base_Unten_Actor_C_<n>` (его Owner = PlayerController).
- `UObject:GetWorld()` существует в Lua API, HeadTracking его не использовал.
- Pawn явно не искали. `PyBP_Spectator_C` — отдельный актор спектатора/фоторежима.

## Useful Unreal classes/objects

```
PyBP_Base_Unten_Actor_C        /Game/Assets/Blueprints/_Train_BaseClass/PyBP_Base_Unten_Actor.PyBP_Base_Unten_Actor_C
  ("unten" 運転 — актор машиниста; ViewTarget; ДВИЖЕТСЯ ВМЕСТЕ С ПОЕЗДОМ)
  └─ DefaultSceneRoot   SceneComponent
      ├─ UntenSpringArm SpringArmComponent   TargetArmLength=10, bDoCollisionTest=true(Probe 12)
      │   └─ CameraUnten CameraComponent     камера кабины, FOV 100
      ├─ OutsideSpringArm → CameraOutside    внешний вид (неактивна)
      └─ CameraTransition CameraComponent    переходная, Relative (877.7, -96.2, 280.4)
PyBP_Spectator_C               спектатор: CineCamera, CameraTransition, CollisionComponent0 (SphereComponent)
PyBP_BaseEditor_C              упоминается в инвентаре камер
```

- Полное имя компонента: `CameraComponent /Game/_MainMaps/_MainPresistent._MainPresistent:PersistentLevel.PyBP_Base_Unten_Actor_C_2147480535.CameraUnten`
- Суффикс `_<n>` меняется при каждой загрузке маршрута — **имена не хардкодить**.
- Кастомных подклассов камеры нет; есть штатный camera shake (`CameraModifier_CameraShake`).
- Сработавшие сеттеры: `K2_SetRelativeRotation(rot, false, {}, false)`,
  `K2_SetRelativeLocationAndRotation`, `K2_GetComponentLocation()`, `K2_GetComponentRotation()`.
  Hit-result out-параметр передаётся пустой таблицей `{}`.
- Кандидат на систему координат кабины для TwitchTablet: `PyBP_Base_Unten_Actor_C`
  (или его `DefaultSceneRoot`) — **гипотеза**, не проверено, что он жёстко связан с кузовом.

## RUNNING TRAIN peculiarities

- **Клавиши:** F11 — fullscreen игры **даже с Ctrl**; F12 — скриншот Steam; Ctrl+F5 —
  внутренний бинд игры. HeadTracking занимает `-` (OEM_MINUS), `=` (OEM_PLUS), Ctrl+F6.
  На ранних этапах без конфликтов использовались Ctrl+F4, Ctrl+F7, Ctrl+F8, Ctrl+F9.
  Встроенный мод Keybinds UE4SS: Ctrl+J (object dump), Ctrl+H (SDK headers),
  Ctrl+Num9 (UHT headers), Ctrl+Num8 (static meshes), Ctrl+Num7 (all actors), Ctrl+Num6 (usmap).
- `CameraUnten.RelativeLocation` игра обнуляет каждый кадр; мышиный обзор — это поворот SpringArm.
- После рестарта маршрута игра сперва рендерит через `CameraTransition`, потом переключается
  на `CameraUnten`; при выходе в меню/спектатора — `PyBP_Spectator_C.CameraTransition`.
- Смена маршрута/возврат в меню = `LoadMap` pre/post; все акторы поезда пересоздаются.
- Краш-лог игры: `%LOCALAPPDATA%\RunningTrain\Saved\Crashes\…\CrashContext.runtime-xml`.
  **Успешный `UE4SS.log` ничего не говорит о крашах.** Смещения сверять с известными RVA.
- `print()` в UE4SS **не добавляет перевод строки** — в логе HeadTracking строки склеены. Всегда `\n`.

## UObject lifetime lessons

1. **Не трогать UObject во время загрузки.** `FindAllOf`/`FindFirstOf` в момент загрузки уровня
   дали `EXCEPTION_ACCESS_VIOLATION` в коде FName. `pcall` AV **не ловит**. Решение HeadTracking:
   5 с grace после старта, 3 с после `LoadMap` pre/post, сброс всех кэшированных указателей.
2. **Не хранить указатели через смену карты**; перепроверять `IsValid()` перед каждым использованием.
3. **Поиск троттлить** (`FindAllOf` не чаще 500 мс и только когда нужно).
4. **Несуществующее свойство возвращает `TrivialObject`, а не `nil`** — копировать поля с проверкой
   `type(x) == "number"`, иначе ошибка всплывёт позже в арифметике.
5. **Ошибки в цикле rate-limit'ить.** Один повторяющийся сбой дал 8265 строк лога и «убил» хоткеи.
6. **Любая защёлка вокруг отложенного колбэка — с таймаутом**: доставка не гарантирована на границах LoadMap.
7. **Lua не потокобезопасен, а все контексты мода делят один `lua_State`.** Реальная работа в keybind-колбэке
   параллельно с `LoopAsync` через некоторое время «заклинила» поток ввода. Решение: keybind только
   ставит флаг, всю работу делает один цикл.
8. Отказ от `ExecuteInGameThread` в HeadTracking — эмпирика: оба краша пришли с game thread
   (изнутри engine tick, скорее всего из-за FindAllOf во время загрузки), а доставка колбэков потом
   прекратилась. Чтение/запись свойств и `K2_Set*` из не-game потока работали стабильно.
   **Для TwitchTablet это неприменимо без проверки:** спавн акторов, создание компонентов,
   `LoadAsset` и работа с render-ресурсами вне game thread — заведомо опасны.

## Reusable patterns

- `Find-RunningTrain.ps1` — поиск игры (скопировать, не зависеть от HeadTracking).
- Схема сборки C++ мода без UEPseudo (скрипты выше) — при появлении C++ части.
- Install с манифестом и backup (`install.ps1` / `uninstall.ps1`).
- Мост C++ → Lua через `on_lua_start` + фоновый поток в C++, «только последний снимок» или очередь под мьютексом;
  UObject из фонового потока не трогаются вообще.
- Lua-утилиты из `main.lua`: `log` через `pcall(string.format)`, `try`, `isValid`, `fullName`, `copyVec`/`copyRot`,
  кватернионы с формулами **из исходника UE** (знак roll теряется молча), ini-парсер с типизацией по значению по умолчанию.
- «Assign, never accumulate»: каждое применение трансформа = база ∘ смещение, без накопления.
- Gate + throttle + rate-limited errors в периодическом цикле.
- Самопроверка `C++ мод загружен?`: Lua проверяет `RTHT_Start == nil` и логирует один раз.
- Запуск «инертным» (`autostart=false`) как путь восстановления, если сборка роняет игру.

## Head-tracking-specific things NOT to reuse

- Любая запись в `CameraUnten` / `UntenSpringArm` (`RelativeRotation`, `TargetOffset`) —
  **TwitchTablet не трогает камеру вообще**.
- Выбор активной камеры по POV/`bIsActive`: планшету камера не нужна (разве что для
  дебаг-спавна «перед камерой» в Milestone 1, только чтение).
- OpenTrack UDP-приёмник, маппинг осей, recenter, freeze/blend при потере трекинга.
- Схема «всё из async-потока без game thread» — для спавна и текстур не годится (см. урок 8).
- Хоткеи `-`, `=`, Ctrl+F6 — заняты HeadTracking.
- Ограничение «C++ только сокет» — для TwitchTablet C++ понадобится для Twitch/рендера,
  но граница «UObject только в Lua» остаётся, пока нет Unreal headers.
