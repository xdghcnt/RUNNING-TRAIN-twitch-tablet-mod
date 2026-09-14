# TwitchTablet — research log

Находки об игре и UE4SS, которые нужны именно для планшета. Уже доказанное
HeadTracking'ом — в [HEADTRACKING_REFERENCE.md](HEADTRACKING_REFERENCE.md), здесь не повторяется.

Метки: **[игра]** — подтверждено в запущенной RUNNING TRAIN; **[исходник]** — прочитано
в RE-UE4SS `1c1a1497`; **[гипотеза]** — не проверено.

---

## Архитектурное ограничение: UObject только из Lua

- **[проверено 2026-09-14]** Доступа к `Re-UE4SS/UEPseudo` нет (SSH: `Permission denied (publickey)`,
  HTTPS: `Repository not found`, `gh` не залогинен). Значит, C++ мод собирается только против
  публичных заголовков и **не может** вызывать UE4SS Unreal API (UObject, UFunction, FName…).
- Следствие для планируемой архитектуры:

  | слой | где живёт |
  |---|---|
  | lifecycle, поиск мира/поезда, спавн, attachment, материалы, текстуры, калибровка | **Lua** |
  | Twitch-клиент (сеть), очередь сообщений, ChatModel, возможно CPU-рендер текста/битмапа | **C++**, отдаёт данные в Lua через функции, зарегистрированные в `on_lua_start` |

- Путь снять ограничение: привязать GitHub-аккаунт к Epic Games (UEPseudo открыт для таких
  аккаунтов) и собирать UE4SS из исходников того же коммита. Но даже тогда C++ API UE4SS — это
  та же рефлексия, что и в Lua; нативные функции движка вроде `UTexture2D::UpdateTextureRegions`
  через него не доступны. Для Milestone 6 это не решение само по себе.

## Потоки и Lua-состояния **[исходник]**

`UE4SS/src/Mod/LuaMod.cpp`:

- `main_lua`, `async_lua`, `hook_lua` — это `lua_newthread` **одного** `lua_State` мода.
- `RegisterKeyBind`-колбэк исполняется в потоке event loop UE4SS **под** `m_thread_actions_mutex`.
- `LoopAsync` — в async-потоке, без мьютекса.
- `ExecuteInGameThread` / `*WithDelay` / `LoopInGameThread*` — в hook `UGameEngine::Tick` (pre) или
  `ProcessEvent` (pre), вызов колбэка **без** мьютекса. Глобальный флаг
  `m_is_currently_executing_game_action` не даёт game-action'ам вкладываться друг в друга.
- `LoadAsset` бросает исключение вне game thread.
- `UWorld:SpawnActor(UClass, {X,Y,Z}, {Pitch,Yaw,Roll})` → `BeginDeferredActorSpawnFromClass` + `FinishSpawningActor`.

**Вывод для дизайна [гипотеза, проверяется в M0]:** вся работа планшета должна идти в одном
контексте — game thread. Хоткеи в финальной версии лучше опрашивать на game thread
(`PlayerController:IsInputKeyDown`) вместо `RegisterKeyBind`, чтобы Lua вообще не исполнялся из
двух потоков. Это возможно только если game-thread доставка в этой игре надёжна — HeadTracking
видел обратное для `ExecuteInGameThread(EngineTick)`.

## Кандидаты для dynamic texture (к Milestone 5–6, пока не исследовались)

Все варианты — через рефлексию, т.к. нативный код движка недоступен:

1. **Render target + Canvas.** `KismetRenderingLibrary:CreateRenderTarget2D` один раз,
   затем `BeginDrawCanvasToRenderTarget` → `Canvas:K2_DrawText/K2_DrawBox/K2_DrawTexture` →
   `EndDrawCanvasToRenderTarget` на каждое обновление. Один постоянный UObject, рисует GPU, текст —
   движковым `UFont`. Не CPU-bitmap из ТЗ, но полностью рефлексивный. Главный кандидат.
2. **CPU bitmap → `ImportBufferAsTexture2D`.** Готовый PNG/BMP в `TArray<uint8>` — но это новый
   `UTexture2D` на каждое обновление (противоречит требованию) и дорогая передача байтов через Lua.
   Годится для кэшируемых картинок (эмоуты), не для экрана целиком.
3. **CPU bitmap → запись в память текстуры из C++ + нативный `UpdateTextureRegions` по AOB-сигнатуре**
   (как `FName_Constructor.lua`). Ближе всего к ТЗ, самый хрупкий.
4. **`TextRenderComponent`** — текст в 3D без текстуры вообще. Запасной вариант, не текстура.

Материал с текстурным параметром: кандидат `/Engine/EngineMaterials/Widget3DPassThrough`
(параметр `SlateUI`) — наличие в cooked-сборке проверяется в M0.

## Milestone 0 — что проверяет recon-сборка

`Mods/RunningTrainTwitchTablet/scripts/tt/recon.lua`, результаты пишутся в `UE4SS.log` с тегом `[Tablet]`.

| клавиша | вопрос |
|---|---|
| Ctrl+F9 | какие из `ExecuteInGameThread(EngineTick / ProcessEvent / default)`, `ExecuteInGameThreadWithDelay`, `LoopInGameThreadWithDelay` доставляются, с какой задержкой, на game thread ли |
| Ctrl+F7 | PlayerController → World → Pawn → PCM/ViewTarget; наличие классов и сигнатуры функций; наличие/загрузка `/Engine` мешей, материалов, текстур, шрифтов; гистограмма акторов, attachment-цепочка и BP-свойства `PyBP_Base_Unten_Actor_C`, прочие «поездные» акторы |
| Ctrl+F8 | `SpawnActor(Actor)` + `AddComponentByClass(SceneComponent)` + `K2_DestroyActor` на game thread (невидимо) |

## Результаты Milestone 0 — запуск 2026-09-14 13:22 (с HeadTracking, без краша)

### Game thread **[игра]**

| механизм | probe #1 (после загрузки) | probe #2 (после рестарта маршрута) |
|---|---|---|
| `ExecuteInGameThread(EngineTick)` | 3 мс, game thread | 4 мс, game thread |
| `ExecuteInGameThread(default)` (= EngineTick по конфигу) | 3 мс, game thread | 5 мс, game thread |
| `ExecuteInGameThread(ProcessEvent)` | 3 мс, game thread | 5 мс, **`IsInGameThread=false`** |
| `ExecuteInGameThreadWithDelay(250)` | 253 мс, game thread | 266 мс, game thread |
| `LoopInGameThreadWithDelay(100)` | 27 за 3040 мс | 27 за 3073 мс |

- **EngineTick надёжен**, в том числе после `LoadMap`. Сбой доставки из HeadTracking в этой
  конфигурации не воспроизвёлся (там колбэки ставились каждые 4 мс из `LoopAsync` на zDEV-сборке;
  причина не установлена).
- **ProcessEvent-метод запрещён для планшета:** хук `ProcessEvent` срабатывает и в не-game потоках,
  и game-action исполнился вне game thread.
- Loop с периодом 100 мс даёт ~9 Гц — таймер квантуется кадрами.
- `RegisterLoadMapPreHook` / `PostHook` исполняются на game thread.
- Полный recon (31 421 актор, `FindAllOf` по мешам/материалам/текстурам) занял ~270 мс на game thread — разовый фриз, для постоянной работы так нельзя.

### Мир и игрок **[игра]**

```
PlayerController_<n>                    FindFirstOf("PlayerController")
World  /Game/_MainMaps/_MainPresistent  pc:GetWorld()
GameMode RTS_PlayGameMode_C, GameState GameState
Pawn = PyBP_Base_Unten_Actor_C_<n>      pc.Pawn  (он же ViewTarget; Owner = PlayerController)
GameInstance GIns_RUNNING_TRAIN_C
```

Также есть `PyBP_FirstPerson_C` (с `FirstPersonCamera`) и `PyBP_Spectator_C`.

### Поезд и кабина — кандидаты для Milestone 2 **[игра]**

```
Cpy_KuHa115_C_<n>                       вагон (КуХа 115), actor
  Base_CHASIS   StaticMeshComponent     корень вагона
    ├─ PyBP_Base_Unten_Actor_C.DefaultSceneRoot   (актор машиниста/камеры прикреплён сюда)
    └─ BaseTrain StaticMeshComponent
         ├─ BP_TrainConnector_C ...
         └─ BaseUntendai StaticMeshComponent      (運転台 — пульт машиниста)
              └─ BP_UntenTeishiDevice ChildActorComponent → BP_UntenTeishiDevice_2_C
```

- `PyBP_Base_Unten_Actor_C.BaseTrain` (ObjectProperty) = тот же `Cpy_KuHa115_C_<n>` — прямая ссылка на вагон
  из Pawn, без поиска по миру.
- В мире одновременно несколько вагонов: `Cpy_KuHa115_C` ×2 (голова/хвост нашего состава), `Cpy_KuHa113_C`
  (другой состав, далеко). Брать надо именно `pawn.BaseTrain` / attach parent Pawn'а.
- Тележки `115_BogieFrontTC_C`, `115_BogieMid_C` — отдельные акторы со `SkeletalMeshComponent`, не прикреплены.
- Кандидаты на идентификатор состава (Milestone 12, **не использовать раньше**): класс вагона `Cpy_KuHa115_C` / `Cpy_KuHa113_C`.

### Классы, функции, ассеты **[игра]**

- Есть все проверенные классы: `StaticMeshActor`, `StaticMeshComponent`, `TextRenderComponent`, `WidgetComponent`,
  `MaterialInstanceDynamic`, `Texture2D`, `Texture2DDynamic`, `TextureRenderTarget2D`, `CanvasRenderTarget2D`, `Canvas`,
  `KismetRenderingLibrary`, `KismetMaterialLibrary`, `GameplayStatics`.
- Сигнатуры этого билда (порядок параметров):
  - `Actor:AddComponentByClass(Class, bManualAttachment, RelativeTransform, bDeferredFinish) -> ReturnValue`
  - `SceneComponent:K2_AttachToComponent(Parent, SocketName, LocationRule, RotationRule, ScaleRule, bWeldSimulatedBodies) -> bool`
  - `SceneComponent:K2_SetRelativeTransform(NewTransform, bSweep, SweepHitResult, bTeleport)`
  - `StaticMeshComponent:SetStaticMesh(NewMesh) -> bool`, `PrimitiveComponent:SetMaterial(ElementIndex, Material)`
  - `PrimitiveComponent:CreateDynamicMaterialInstance(ElementIndex, SourceMaterial, OptionalName) -> MID`
  - `MaterialInstanceDynamic:SetTextureParameterValue(ParameterName, Value)`
  - `KismetRenderingLibrary:CreateRenderTarget2D(WorldContextObject, Width, Height, Format, ClearColor, bAutoGenerateMipMaps, bSupportUAVs)`
  - `KismetRenderingLibrary:BeginDrawCanvasToRenderTarget(WorldContextObject, TextureRenderTarget, Canvas(out), Size(out), Context(out))`
  - `KismetRenderingLibrary:ImportBufferAsTexture2D(WorldContextObject, Buffer)`
  - `Canvas:K2_DrawText(RenderFont, RenderText, ScreenPosition, Scale, RenderColor, Kerning, ShadowColor, ShadowOffset, bCentreX, bCentreY, bOutlined, OutlineColor)`
  - `Canvas:K2_DrawTexture(RenderTexture, ScreenPosition, ScreenSize, CoordinatePosition, CoordinateSize, RenderColor, BlendMode, Rotation, PivotPoint)`
  - `PlayerController:IsInputKeyDown(Key) -> bool`
- В памяти после загрузки маршрута: `/Engine/BasicShapes/{Cube,Plane,Cylinder,Sphere}`, `/Engine/EngineMeshes/{Sphere,Cylinder}`,
  `BasicShapeMaterial`, `DefaultMaterial`, `WorldGridMaterial`, `EmissiveMeshMaterial`, `BlackUnlitMaterial`,
  `Widget3DPassThrough` + MIC `_Opaque/_Masked/_Translucent` (`_OneSided` варианты), `DefaultTextMaterialOpaque/Translucent`,
  текстуры `DefaultTexture`, `WhiteSquareTexture`, `Black`, `DefaultWhiteGrid`, `T_GridChecker_A`.
- `/Engine/EngineMeshes/Cube` — нет в cooked-сборке (`LoadAsset found=false`).
- Шрифты: `/Engine/EngineFonts/{Roboto,RobotoDistanceField,RobotoTiny}`, `DefaultTiny/Regular/MonoFont`,
  игровые `/Game/AssetUI/FONT/NotoSans/NotoSans`, `Poppins`, `Teko`, `Regular_Font`, `RobotoCondensed`.
  NotoSans — вероятный кандидат для кириллицы/японского (не проверено).

### Спавн **[игра]**

На EngineTick: `world:SpawnActor(Actor)` → валидный `Actor_<n>`; `AddComponentByClass(SceneComponent)` → валидный
компонент, он стал `RootComponent`; `K2_DestroyActor()` без ошибки.

- Координаты спавна **не применились** (актор в `(0,0,0)`): у голого `Actor` при спавне нет root-компонента, хранить
  трансформ негде. Позицию надо задавать после добавления компонента.
- После `K2_DestroyActor` `IsActorBeingDestroyed()` вернул `false`. Удалён ли актор — не подтверждено; проверить
  `IsValid()` на следующем тике (Milestone 1).

### Недостатки recon-сборки

- `K2_GetComponentsByClass` вернул значение, которое не является ни Lua-таблицей, ни рабочим `TArray:ForEach` —
  список компонентов пуст. Для M2 обходить дерево через `AttachChildren`.
- Строки HeadTracking в логе склеены (его `print` без `\n`), из-за этого одна строка `[Tablet]` приклеилась к чужой.

## Неудачные гипотезы

- «`ExecuteInGameThread` в RUNNING TRAIN не доставляет колбэки» (вывод HeadTracking) — **не подтвердилось**
  для EngineTick в текущей установке.
- «ProcessEvent-метод — равноценная замена EngineTick» — **опровергнуто**: колбэк исполнился вне game thread.

## Milestone 6 — наблюдения

### Краш: render target собран GC **[игра, 2026-09-14 14:23]**

Сценарий: динамический экран (RT 1024×768 в параметре `SlateUI`) → Ctrl+F9 статическая клетка → Ctrl+F9 дефолтная текстура →
Ctrl+F9 снова динамика (переиспользуется тот же Lua-указатель на RT). Последняя строка лога `screen mode -> dynamic test pattern`,
через ≤2 с после ухода RT из материала.

`CrashContext.runtime-xml`: `EXCEPTION_ACCESS_VIOLATION reading address 0x000000040000003b`, стек game thread:
`GameEngine tick (+415c8b2)` → UE4SS game-thread action / Lua (`UE4SS+3d7d4a … +93a11c …`) → `UE4SS+2666d7` →
`RunningTrain+149621d` (внутри `UObject::ProcessEvent`, RVA `0x1495DB0` = адрес ProcessEvent из лога 2026-08-31 минус база,
вычисленная по FName ctor `0x12C81D0`) → `+13b7a96` → `+3b7cccf` → `+3b78182` (AV).

Вывод: вызов UFunction с/на освобождённом объекте. Единственная ссылка на RT, которую видит GC Unreal, — `TextureParameterValues`
MID; после замены параметра RT стал недостижим и был собран. **Lua-ссылка (и UE4SS `IsValid`) объект не удерживает.**

Правило: каждый созданный модом UObject должен быть достижим через UPROPERTY-цепочку (компонент актора, параметр материала…),
пока Lua им пользуется; если цепочка разрывается — сразу забывать Lua-ссылку.

### Производительность (10 с, в движении, до краша)

| состояние | средний кадр | 1% худших | >33 мс |
|---|---|---|---|
| планшет выключен | 20,38 мс (49,1 fps) | 25,60 мс | 5 |
| статическая клетка | 18,74 мс (53,4 fps) | 22,71 мс | 4 |
| статическая клетка | 19,20 мс (52,1 fps) | 21,93 мс | 3 |

Пики 227–345 мс — по словам пользователя, скорее всего alt-tab. Замера в динамическом режиме до краша не было.

### Прочее

- Первый динамический прогон 14:21:03–14:22:47 (≈520 перерисовок) — ни одной ошибки.
- С поворотом экрана `Yaw 90 / Roll -90` тестовый паттерн был **перевёрнут на 180°**; остальное (кириллица, японский, счётчик,
  движение полосы) — «всё ок». Поворот сменён на `Yaw -90 / Roll 90`.

## Milestone 7 — наблюдения по UX **[игра, 2026-09-25]**

- **Хоткеи на F-клавишах постоянно пересекаются с биндами самой игры** (со слов пользователя). Переведены на цифры без
  модификаторов: 8 — планшет (затем по просьбе пользователя перенесено на F1), 9 — фейковое сообщение, 5/6 — шрифт −/+, 7 — замер кадров, 4 — dev reload.
- Клавиши **1–3 заняты игрой** (переключение камеры) — не использовать. Размер планшета — на numpad 4/6 (ширина), 2/8 (высота).
- Шрифт чата со scale 1,6 — «раза в три больше надо»; дефолт 4,8, подбирается клавишами 5/6 (×1,15).
- Фон экрана (0,015; 0,015; 0,03) выглядел как «реалистично плохой чёрный старого TFT с низким контрастом» — заменён на чистый чёрный.
- Сам рендер текста (перенос, цвета ников, кириллица/японский) — «ок».
- Офлайн-тест поймал до игры: `%s` в Lua-паттернах на Windows считает пробелом байт `0xA0` (второй байт кириллической «Р»),
  токенизатор резал символы пополам → `invalid UTF-8 code`. Теперь только ASCII-пробелы + очистка UTF-8 на входе ChatModel.

## UE4SS снимает EngineTick-хук при ошибке колбэка **[игра, 2026-09-25 07:40]**

Во время dev reload (правка нескольких файлов подряд) лог:

```
07:40:56.586 [Lua] [Tablet] loaded: ...                       <- новый main.lua ещё выполняется (поток event loop UE4SS)
07:40:56.587 [Lua] [Tablet] dev reload: watching 16 files ...   <- первый game-thread колбэк нового мода уже отработал
07:40:56.599 [UE4SS.EngineTick.LuaModImpl] Hook threw exception: "[Lua::Registry::get_function_ref] Ref was not function
             No traceback", removing hook!
```

После этого ни один game-thread колбэк мода больше не выполнялся (ни статус раз в минуту, ни опрос клавиш) до перезапуска игры:
**UE4SS удаляет EngineTick-хук целиком** при исключении в колбэке.

Причина: `main.lua` выполняется в потоке event loop, а поставленные им через `ExecuteInGameThread` колбэки game thread начинает
выполнять сразу — в том же `lua_State`, пока `main.lua` ещё не закончил. При обычном старте игры окно гонки не открывалось
(первый тик позже), при горячей перезагрузке — открылось.

Правило: `main.lua` ничего не ставит на game thread по ходу выполнения; весь запуск — один `ExecuteInGameThreadWithDelay(1000, init)`
в самом конце файла.

Оставшийся риск того же класса: запасной путь ввода (`RegisterKeyBind` при неработающем опросе `IsInputKeyDown`) ставит game-thread
колбэки из потока event loop. Сейчас не используется (опрос работает).

## Milestone 12 — идентификатор состава **[игра, 2026-09-14…2026-09-25]**

`tt/trainid.lua` логирует кандидатов один раз на каждый новый вагон (класс, путь ассета, меш кузова, скалярные BP-свойства вагона,
GameMode и GameInstance). Названия — со слов пользователя из меню выбора.

| название в меню | класс вагона (`pawn.BaseTrain`) | путь ассета | `gameinstance.TRAIN_Series` / `car.TrainType` | меш кузова | пульт |
|---|---|---|---|---|---|
| hr1500 | `Cpy_KuHa115_C` | `/Game/Assets/Blueprints/_Train_BaseClass/Train_Selection/Series115/Cpy_KuHa115` | 2 / 2 | `BP_Main_Train_115/Models/Tc115` | `BaseUntendai` |
| kr5000 | `Cpy_KC1000Tc_C` | `/Game/Assets/Blueprints/_Train_BaseClass/Train_Selection/KC1000/Cpy_KC1000Tc` | 5 / 5 | `BP_Main_TrainOBJ/Mesh/KC1000_Tc` | нет — приборы прямо на `BaseTrain` |
| hr1100 | `Cpy_KuMoHa113_C` | `/Game/Assets/Blueprints/_Train_BaseClass/Train_Selection/Series115/Cpy_KuMoHa113` | 0 / 0 | `BP_Main_Train_115/Models/Tc115` (тот же, что у hr1500) | `BaseUntendai` |
| DC8500 | `Cpy_Kiha85Head_C` | `/Game/Assets/Blueprints/_Train_BaseClass/Train_Selection/KiHa85/Cpy_Kiha85Head` | 7 / 7 | `BP_Main_Train_Kiha85/Models/kiha_85_main` | нет — приборы на `BaseTrain`; `Cabin_Camera_Init` X≈892, часы X≈969, нос X≈1085 |

- Названия в меню (hr1500, kr5000) с внутренними именами не совпадают — вероятно, вымышленные имена в UI поверх рабочих имён ассетов.
- hr1500: один и тот же класс во всех сессиях (M0 2026-09-14, 2026-09-25 ×несколько, после рестартов маршрута и меню); `TRAIN_Series=2` каждый раз. Контроль: после hr1100 пользователь снова выбрал hr1500 в меню (08:08) → снова `Cpy_KuHa115_C`, серия 2.
- `TRAIN_ColorIndex` / `TrainColorIndex` — окраска (у обоих 0); геометрию кабины не меняет → в ключ профиля не входит.
- `HokoIndex = 5` у обоих — смысл не ясен, не идентификатор состава. `SCENARIO_NUM` ("622A", "526F") — номер сценария/рейса, не поезда.
- GameMode (`RTS_PlayGameMode_C`) скалярных BP-свойств не имеет.
- **Геометрия kr5000:** пульт X≈810–850, Z≈180–250 относительно `BaseTrain`, нос на X≈900; у hr1500 пульт X≈905–930, Z≈225–280.
  Транcформ, подобранный на hr1500 (X=923.6), у kr5000 оказывается снаружи перед стеклом — вот почему там «планшет не заспаунился».

**Выбор ключа профиля:** короткое имя класса вагона (`Cpy_KuHa115_C`). Стабилен между сессиями, различает составы, читаем в конфиге,
не зависит от порядка внутреннего enum'а серий (номер `TRAIN_Series` может сдвинуться при добавлении составов в обновлении).
`TRAIN_Series` логируется рядом как справка.

## Встроенные хоткеи UE4SS и нампад **[исходник UE4SS release, 2026-09-28]**

Мод `Keybinds` из стандартной сборки (`Mods\Keybinds\Scripts\main.lua`, включён в `mods.txt`) вешает дампы на
Ctrl+J (ObjectDumper), Ctrl+H (CXX headers), Ctrl+Num9 (UHT headers), Ctrl+Num8 (static meshes), Ctrl+Num7
(all actors), Ctrl+Num6 (USMAP). Генерация заголовков может занять минуты. Поэтому Ctrl не используется как модификатор
к нампаду: мелкий шаг калибровки переключается отдельной клавишей (CalFine = Num7).

## Релиз рядом с HeadTracking **[игра, 2026-09-28 04:07]**

- UE4SS.dll в игре, в релизе HeadTracking и тот, против которого слинкован наш `main.dll`, — один файл
  (SHA256 `F31188D5…35BE1`). Архив HeadTracking и наш можно распаковывать друг поверх друга.
- Распаковка нашего архива заменила `mods.txt` стандартным (строки HeadTracking пропали). Оба мода HeadTracking
  и оба наших всё равно стартовали: `Starting mods (from enabled.txt ...)` → `has enabled.txt, starting mod`.
  C++ моды стартуют раньше Lua, как и при записи в `mods.txt`.
- Ассет `UE4SS_v3.0.1-1021-g1c1a1497.zip` в rolling-релизе `experimental-latest` больше не существует (404);
  источник для сборки — локальная копия, `Get-UE4SS.ps1` сверяет хэш UE4SS.dll.
- Первый запуск: создан `TwitchTablet.ini`, `[Twitch] no channel set`. Вписали канал в работающей игре — мод сам
  перезагрузился и за ~2 с вошёл в чат (`Joined #...`).

## Замирание IRC Twitch: DPI на прямом соединении **[игра + тесты, 2026-09-28]**

- Симптом: в игре после подключения приходит ~23–25 сообщений (~12–16 КБ), затем ни байта — ни чата, ни ответа на наш
  PING; сокет наш (`SO_TYPE`=TCP, `getpeername` = сервер Twitch), `FIONREAD`=0, в `netstat` ESTABLISHED.
- Одновременно отдельный клиент на той же машине принимал тот же чат без сбоев. Разница — маршрут: отдельный процесс шёл
  через VPN-адаптер пользователя (10.72.129.3), игра — напрямую через Wi-Fi (192.168.3.8): в VPN настроено раздельное
  туннелирование, игра исключена по пути (копия под именем игры всё равно шла через VPN).
- Воспроизведено вне игры, привязкой сокета к Wi-Fi-адресу: plain IRC 6667 — заморозка после 12 667 байт / 23 сообщений;
  TLS 6697 — 64 КБ / 136 сообщений за 2 минуты без сбоя. Поведение совпадает с известной «заморозкой после ~16 КБ»
  к зарубежным хостингам у российских провайдеров.
- Вывод: только TLS. Тестовый крючок `RTTT_BIND_IP=<локальный IPv4>` в `TwitchClient` позволяет повторить прямой
  маршрут пробой (`Test-TwitchProbe.ps1`).
- `SO_RCVTIMEO` заменён на `select()`: после тайм-аута блокирующего `recv` Windows считает состояние сокета
  неопределённым (документация) — не причина этой заморозки, но и опираться на него не стоит.
