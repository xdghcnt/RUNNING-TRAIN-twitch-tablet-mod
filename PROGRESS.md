# TwitchTablet — progress

Новые записи снизу.

---

## Workspace — reorganize + knowledge transfer

Status:
PASS

Hypothesis:
Существующий HeadTracking можно перенести на уровень глубже без потери истории,
а TwitchTablet завести как независимый репозиторий рядом.

Tested:
- `running-train-headtracking/` → `HeadTracking/`: переименование каталога блокировалось
  (`Device or resource busy` — handle на саму папку), поэтому создан `HeadTracking/` и в него
  перенесено всё содержимое, включая `.git`; пустая старая папка удалена.
- В `HeadTracking/`: `git status` — clean, `main` up to date with `origin/main`;
  `git log` — те же 3 коммита (`f63be62`, `64ea1ec`, `d83cb06`); `git fsck` без ошибок.
- Проверено, что перенос не ломает игру: в игре стоит release-установка HeadTracking
  (моды скопированы в `ue4ss/Mods`), `+ModsFolderPaths` на старый путь не использовался.
- `TwitchTablet/`: `git init -b main`, отдельный репозиторий, без remote/submodule.

Observed:
- В рабочей папке `train/` роль `RunningTrainMods/` играет сама `train/`:
  `train/HeadTracking` и `train/TwitchTablet`.
- Git identity у HeadTracking задана локально (churuya), глобально нет — в TwitchTablet выставлена такая же локально.

Conclusion:
- Структура готова. HeadTracking не модифицировался.

Files changed:
- `HEADTRACKING_REFERENCE.md`, `README.md`, `.gitignore`
- `scripts/Find-RunningTrain.ps1` (копия), `scripts/Dev-Install.ps1`, `scripts/Dev-Uninstall.ps1`, `scripts/check_lua.py`

Known issues:
- `HeadTracking/build/build.bat` содержит старые абсолютные пути; он перегенерируется
  `Build-CppMod.ps1` при следующей сборке.

Next:
- Milestone 0.

---

## Milestone 0 — Reconnaissance

Status:
PASS

Hypothesis:
Существует рабочий путь UE4SS mod → gameplay UWorld → runtime-created object, и хотя бы один
механизм game-thread исполнения в RUNNING TRAIN доставляет колбэки стабильно.

Tested (офлайн):
- `python scripts/check_lua.py` — 3/3 файла компилируются Lua 5.4.
- `python scripts/smoke_lua.py` — полный сценарий M0 на заглушке UE4SS API: 171 строка лога, 0 ошибок.
- `Dev-Install.ps1` применён; `Dev-Uninstall.ps1` → хеш файла совпал с бэкапом → установлено снова.

Tested (игра, 2026-09-14 13:22–13:25, вместе с HeadTracking):
- Ctrl+F9 в кабине → Ctrl+F7 → Ctrl+F8 → рестарт маршрута → Ctrl+F9.

Observed:
- UE4SS подхватил `TwitchTablet/Mods` (`mods directories [1]`), мод стартовал по `enabled.txt`, краша нет.
- EngineTick-доставка: 3–5 мс, стабильна до и после `LoadMap`; `LoopInGameThreadWithDelay(100)` — 27 срабатываний за 3 с.
- ProcessEvent-доставка после рестарта маршрута исполнилась с `IsInGameThread=false`.
- Pawn = `PyBP_Base_Unten_Actor_C`, прикреплён к `Cpy_KuHa115_C.Base_CHASIS`; `pawn.BaseTrain` указывает на тот же вагон.
- Все нужные классы и функции есть, сигнатуры записаны; `/Engine/BasicShapes/Cube`, `Plane`, `BasicShapeMaterial`,
  `Widget3DPassThrough*` в памяти.
- `SpawnActor(Actor)` + `AddComponentByClass(SceneComponent)` + `K2_DestroyActor` на game thread — успешно.
- Координаты спавна голого `Actor` игнорируются (актор в 0,0,0).
Подробности — RESEARCH.md.

Conclusion:
- Рабочий путь: `FindFirstOf("PlayerController")` → `pc:GetWorld()` → на EngineTick `SpawnActor` →
  `AddComponentByClass` → позиция после создания компонента.
- Весь код, создающий/меняющий объекты, — только через `ExecuteInGameThread(..., EGameThreadMethod.EngineTick)`.
  ProcessEvent-метод не использовать.
- Систему координат кабины искать начиная с `pawn` → attach parent (`Base_CHASIS`) / `BaseUntendai`.

Files changed:
- `Mods/RunningTrainTwitchTablet/` (`enabled.txt`, `scripts/main.lua`, `scripts/tt/util.lua`, `scripts/tt/recon.lua`)
- `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`, `RESEARCH.md`, `PROGRESS.md`

Known issues:
- Не подтверждено визуально, что Ctrl+F7/F8/F9 не вызывают действий в самой игре.
- Recon не выводит список компонентов (`K2_GetComponentsByClass` не разобран в Lua).
- `IsActorBeingDestroyed()` после `K2_DestroyActor` = false — удаление не подтверждено.

Next:
- Milestone 1: видимый куб перед камерой по Ctrl+F8, проверка параллакса с HeadTracking.

---

## Milestone 1 — Первый видимый 3D-object

Status:
PASS

Hypothesis:
UE4SS мод может добавить в RUNNING TRAIN собственную видимую геометрию.

Tested:
- Ctrl+F8 несколько раз (спавн/удаление) в кабине, в том числе во время движения поезда; Ctrl+F7, Ctrl+F9 для сравнения.

Observed:
- Пользователь: «кубик появляется, к поезду не привязан, привязан к земле» — ровно ожидаемое поведение M1.
- Лог: `AddComponentByClass(StaticMeshComponent)` сразу даёт `Mobility=2` (Movable), `SetStaticMesh=true`,
  `K2_SetActorLocationAndRotation` применяется точно (target == actual). Камера между первым и последним спавном сместилась на ~47 м — поезд ехал.
- После `K2_DestroyActor` куб исчезает, но UE4SS `IsValid()` через 500 мс всё ещё `true` (объект помечен, но GC ещё не прошёл).
- Ctrl+F7 (полный recon) даёт заметный короткий фриз — ожидаемо (~270 мс, M0). Ctrl+F9 визуально ничего не делает — только лог.
- О реакциях самой игры на Ctrl+F7/F8/F9 пользователь не сообщал.
- Параллакс: пользователь смещал голову штатно правой кнопкой мыши (в игре это **смещение** точки обзора, не поворот —
  то же, что делает трансляция HeadTracking): «всё ок двигается», куб даёт естественный 3D-параллакс.

Conclusion:
- Рабочий рецепт: `SpawnActor(Actor)` → `AddComponentByClass(StaticMeshComponent)` → `SetStaticMesh(/Engine/BasicShapes/Cube)` →
  `SetCollisionEnabled(NoCollision)` → `SetWorldScale3D` → `K2_SetActorLocationAndRotation`, всё на EngineTick.
- `IsValid()` не означает «не уничтожен»: после Destroy ссылку обнулять самим и больше её не трогать.

Files changed:
- `scripts/tt/gamethread.lua` (новый), `scripts/tt/testobject.lua` (новый), `scripts/tt/recon.lua`, `scripts/main.lua`,
  `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`

Known issues:
- Одновременная работа с HeadTracking (OpenTrack) не проверялась — проверить на следующих milestones.

Next:
- Milestone 2: найти SceneComponent кабины и прикрепить к нему куб.

---

## Milestone 2 — Система координат кабины

Status:
PASS

Hypothesis:
Существует стабильный SceneComponent, который движется вместе с кабиной, и к нему работает штатный `AttachToComponent`.

Tested:
- Ctrl+F7 (дамп вагона + 20 с замеров качки) трижды во время движения, Ctrl+F8 с каждым из якорей
  `BaseUntendai`, `BaseTrain`, `Base_CHASIS`, `pawn attach parent` (Ctrl+F9), Ctrl+F4 (dev reload).

Observed:
- Вагон стабильно находится через `pawn.BaseTrain` → `Cpy_KuHa115_C_<n>`; все четыре якоря есть.
- Дерево (обход `AttachChildren` через `TArray:ForEach` — работает):
  `Base_CHASIS` (корень, меш `kiha_85_baseplane`, тележки и physics constraints) → `BaseTrain` (кузов, меш `Tc115`) →
  `BaseUntendai` (меш `Tc115NoNanite`: интерьер кабины; к нему прикреплены приборы `Instrument`, часы `UntenTokeiClock`,
  контроллер `Ms_Power`, кран `Ms_Brake`, реверс `Ms_Rev`, экран расписания `WidgetTimetables` (WidgetComponent),
  `BP_UntenTeishiDevice`, модель машиниста `Untenshi-san` на `BaseTrain`).
  Координаты кабины в системе `BaseTrain`/`BaseUntendai`: пульт X≈905–930, Y≈-60…-120, Z≈225–260; `Cabin_Camera_Init` (870, -89, 280).
- Замеры 100 мс × 20 с на ходу: `BaseUntendai` относительно `BaseTrain` — 0 изменений; **`BaseTrain` относительно шасси качается до 0,43°**
  (кузовная качка); шасси в мире: pitch −0,12…0,36°, roll −1,53…1,89°.
- `K2_AttachToComponent(anchor, FName("None"), KeepWorld×3, false)` → `true`, `AttachParent` совпадает для всех якорей.
- Камера (`PyBP_Base_Unten_Actor_C`) висит на `Base_CHASIS`, а не на кузове.
- Dev reload по Ctrl+F4: куб убран, `Reinstalling mod`, мод загрузился заново — работает.

Conclusion:
- Якорь планшета — **`BaseUntendai`**: это сам интерьер кабины, он качается вместе с кузовом так же, как приборы.
  `Base_CHASIS` для планшета неправильный (не повторяет качку кузова, в отличие от окружающего интерьера).
- Fallback-вычисление трансформа каждый тик не требуется.

Files changed:
- `scripts/tt/cab.lua` (новый), `scripts/tt/testobject.lua`, `scripts/tt/devreload.lua` (новый), `scripts/main.lua`,
  `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`

Known issues:
- Дерево компонентов — только для `Cpy_KuHa115_C`; у других составов имена якорей могут отличаться (M12/M15).

Next:
- Milestone 3: проверка движения вместе с составом.

---

## Milestone 3 — Объект едет вместе с составом

Status:
PASS

Hypothesis:
Прикреплённый объект стабильно существует в локальной системе координат вагона: не отстаёт, не прыгает, не дрейфует.

Tested:
- Куб, прикреплённый к каждому якорю, на ходу; самый длинный непрерывный прогон — 29 с на `Base_CHASIS`,
  за которые вагон прошёл ~1,35 км с поворотом на ~15°. Ежесекундный контроль относительного трансформа и родителя.

Observed:
- Пользователь: «всё ок» — куб едет с кабиной.
- Лог: во всех прогонах relative drift **0,0000 см / 0,0000°**, смен родителя 0.
- Относительный трансформ задаётся один раз при attach; мод его больше не пишет.
- Камера не читалась и не писалась после спавна.

Conclusion:
- Штатная иерархия attachment Unreal полностью решает «объект в координатах кабины»; per-tick код не нужен.

Files changed:
- — (проверка сборки Milestone 2)

Known issues:
- Самый длинный прогон при проверке M3 ~30 с; позже (при переходе на M4) куб на `BaseUntendai` провисел 197 с без дрейфа.
- Не проверено с активным трекингом HeadTracking (OpenTrack) — только штатное смещение взгляда мышью.

Next:
- Milestone 4: TabletRoot + Body + Screen на `BaseUntendai`.

---

## Milestone 4 — Минимальная геометрия планшета

Status:
PASS

Hypothesis:
Из движковых примитивов собирается тонкий планшет с отдельным экраном и независимыми материалами, корректно выглядящий в перспективе.

Tested:
- Код загружен в запущенную игру автоматическим dev reload (без перезапуска). Ctrl+F8 несколько раз, осмотр сбоку/сзади
  со штатным смещением взгляда.

Observed:
- Пользователь: «всё корректно» (тёмный корпус, синий экран, видна толщина, нет z-fighting, размер планшета).
- Лог: `TabletRoot` (SceneComponent) стал корнем актора; `Body`/`Screen` — `StaticMeshComponent`, `SetStaticMesh=true`;
  у каждой части свой `MID_BasicShapeMaterial`, `SetVectorParameterValue(Color)` работает.
- Attach к `BaseUntendai` = `true`; пример относительной позиции (920.3, −89.4, 280.4) — перед креслом машиниста.
- Побочный результат для M3: прикреплённый к `BaseUntendai` куб провисел 197 с на ходу — дрейф 0,0000 см / 0,0000°.

Conclusion:
- Иерархия TabletRoot → Body + Screen на рантайм-компонентах работает; экран — отдельный компонент со своим материалом.
- Plane `/Engine/BasicShapes/Plane` с `Pitch=-90` даёт нормаль +X (проверено вычислением).

Files changed:
- `scripts/tt/tablet.lua` (новый), `scripts/tt/testobject.lua` (удалён), `scripts/main.lua`, `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`

Known issues:
- Планшет спавнится перед камерой; осмысленная позиция — в M10/M11.

Next:
- Milestone 5: текстура на экране через материал с texture-параметром.

---

## Milestone 5 — Статическая texture

Status:
PASS

Hypothesis:
Можно управлять материалом экрана и вывести на Screen нашу texture.

Tested:
- Через dev reload в запущенной игре: Ctrl+F8, Ctrl+F9 по трём текстурам (`T_GridChecker_A`, `MiniFont`, `DefaultTexture`), два скриншота от пользователя.

Observed:
- Материал экрана — MID от `/Engine/EngineMaterials/Widget3DPassThrough_Opaque` (MIC, переопределяет только `RefractionDepthBias`).
  Параметр `SlateUI`: `SetTextureParameterValue` → `K2_GetTextureParameterValue` возвращает ровно записанную текстуру, для всех трёх.
- Пользователь: клетка и третья текстура на экране — ок; экран светится сам (unlit), корпус тёмный.
- **Исходное наблюдение (до поправки):** с поворотом плоскости `Pitch=-90` атлас `MiniFont` выглядел как много тонких
  **горизонтальных** полос и несколько широких блоков по горизонтали. Размер `MiniFont` оказался **512×8** — ось U (512) шла по высоте экрана,
  т.е. картинка была повёрнута на 90°. На симметричной клетке это не видно.
- После поворота `Yaw=90, Roll=-90` (нормаль по-прежнему +X, U по ширине, V по высоте) полосы стали **вертикальными** — U идёт по ширине.
- `MiniFont` — строка высотой 8 px, растянутая на 14 см, поэтому для проверки переворота/зеркала непригодна.

Conclusion:
- На ScreenMesh отображается наша texture; материал WidgetComponent с `SlateUI` — рабочий экранный материал.
- Ориентация осей исправлена. Переворот на 180° / зеркало **не проверены** — проверяются в M6 на читаемом тексте.

Files changed:
- `scripts/tt/screen.lua` (новый), `scripts/tt/tablet.lua`, `scripts/main.lua`, `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`

Known issues:
- Возможен переворот изображения на 180° (тогда `SCREEN_ROTATION = Yaw -90, Roll 90`).
- Яркость белого на скриншотах высокая; пользователь не жаловался, настройка — M16.

Next:
- Milestone 6: dynamic runtime texture.

---

## Milestone 6 — Dynamic runtime texture

Status:
PASS

Hypothesis:
Texture экрана можно обновлять в runtime без crash, leak и заметных frametime spikes, не создавая UObject на каждое обновление.

Tested:
- 2026-09-14: первый прогон, найден и исправлен краш (ниже). 2026-09-25: повторный прогон с исправлением — замер без планшета,
  динамический экран ~3 мин (05:54:04–05:56:49) в движении, три замера в динамике, два круга переключения
  динамика → клетка → дефолтная текстура → динамика.

Observed:
- **Реализация (отступление от предпочтительной схемы ТЗ):** вместо CPU bitmap → `UTexture2D` — один `TextureRenderTarget2D`
  1024×768 (`KismetRenderingLibrary:CreateRenderTarget2D`), перерисовываемый через `ClearRenderTarget2D` +
  `BeginDrawCanvasToRenderTarget` / `Canvas:K2_DrawText` / `K2_DrawTexture` / `EndDrawCanvasToRenderTarget`.
  Причина: запись пикселей в `UTexture2D` требует нативных функций движка, недоступных ни из Lua, ни из нашего C++ без UEPseudo.
  Slate/UMG не используется. Новых UObject на обновление нет.
- Out-параметры UE4SS: `Canvas` приходит в `table.Canvas`, `Size`/`Context` копируются в переданные таблицы; `Context` проходит обратно в End.
- 2026-09-14, **краш** при возврате в динамику после статического режима: `EXCEPTION_ACCESS_VIOLATION` внутри `ProcessEvent`.
  Причина — GC собрал RT, когда параметр материала перестал на него ссылаться; Lua-ссылка объект не держит (разбор — RESEARCH.md).
  Исправление: при уходе из динамики RT отпускается, при возврате создаётся новый (создание — только на смене режима).
- Тестовый паттерн был перевёрнут на 180° → поворот экрана `Yaw -90 / Roll 90`; пользователь: «всё ок».
- Кириллица и японский (`Привет, чат! ひらがな`) шрифтом `/Engine/EngineFonts/Roboto` — отображаются.
- Замеры (10 с): выключен — 19,20 мс, 1% 24,85 мс; динамика — 17,52 / 17,86 / 17,92 мс, 1% 20,4–24,4 мс, >33 мс: 0–2.
  Пики 400 мс есть и без планшета (alt-tab). Перерисовка — ~1 мс CPU (Lua wall clock, разрешение 1 мс), ~4,6 обновлений/с.
- Повторный прогон: 0 ошибок перерисовки, 0 крашей.

Conclusion:
- Dynamic texture стабильно работает несколько минут без заметного регресса frametime.
- Правило жизни UObject: всё, что создаёт мод, должно быть достижимо через UPROPERTY-цепочку, пока Lua им пользуется.

Files changed:
- `scripts/tt/dyntexture.lua`, `scripts/tt/perf.lua` (новые), `scripts/tt/tablet.lua`, `scripts/tt/screen.lua`, `scripts/main.lua`,
  `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`, `RESEARCH.md`

Known issues:
- GPU-стоимость перерисовки напрямую не измерена (виден только общий frametime).
- Утечка памяти не измерялась отдельно (кроме отсутствия новых UObject на обновление и стабильного frametime).
- Перерисовка идёт даже без изменений — для паттерна это нужно; в чате (M7) — только при изменениях.

Next:
- Milestone 7: fake chat renderer.

---

## Milestone 7 — Fake chat renderer

Status:
PASS

Hypothesis:
Список сообщений (ник, текст, цвет ника) с переносом слов и прокруткой нормально отображается на физическом 3D-экране.

Tested:
- 2026-09-25, dev reload в запущенной игре: фейковые сообщения клавишей (сначала Ctrl+F9, затем 9), длинные русские/английские/японские
  сообщения и слово без пробелов, подбор шрифта (5/6) и размера планшета (Num4/6/2/8), несколько итераций внешнего вида.

Observed:
- Архитектура: `ChatMessage {user, text, color}` → `ChatModel` (последние 60, счётчик версий, очистка UTF-8) → `ChatRenderer`
  (перенос слов по ширинам из `Canvas:K2_TextSize`, кэш по символу) → render target (M6). Источник — `FakeChat`; рендер о нём не знает.
- Перерисовка только при изменении чата (версия модели), проверка 5 раз в секунду.
- Офлайн-тест до игры поймал `invalid UTF-8`: Lua `%s` на Windows считает пробелом байт `0xA0` (половина кириллической «Р»).
- Пользователь: рендер текста «ок»; шрифт ×3 от начального → подобран 2,97 (дефолт 3,0); размер 16×12 см.
- Текст был растянут на 17 % по горизонтали (RT 1024×768 на экране 1,56:1) — RT теперь повторяет пропорции экрана при 53,3 px/см.
- Хоткеи: Ctrl+F-комбинации пересекались с игрой, 1–3 — камера игры. Итог: F1 планшет, Num4/6 ширина, Num2/8 высота, 5/6 шрифт,
  9 сообщение, 7 замер, 0 dev reload.
- Игра однажды **зависла** после серии нажатий F-клавиш (лог перезаписан при перезапуске, причина не установлена). Возможный механизм
  со стороны мода — Lua из потока keybind'ов параллельно с game thread в одном `lua_State`. Устранён: клавиши опрашиваются на game thread
  через `PlayerController:IsInputKeyDown` (с откатом на `RegisterKeyBind`, если опрос не работает); подтверждено `input: polling 10 keys`.
- Внешний вид: корпус 0,06 (серый), фон экрана 0,002 (почти чёрный), спавн в 30 см от камеры.
- На другом поезде (не в этой сессии) планшет не появился — поддержка других составов отложена до M12/M15; добавлены запасные якоря
  и логирование класса вагона.

Conclusion:
- Fake chat отображается и прокручивается на 3D-экране; модель, рендер и источник разделены.

Files changed:
- `scripts/tt/chatmodel.lua`, `scripts/tt/chatrender.lua`, `scripts/tt/fakechat.lua`, `scripts/tt/input.lua` (новые),
  `scripts/tt/tablet.lua`, `scripts/tt/dyntexture.lua`, `scripts/tt/devreload.lua`, `scripts/tt/cab.lua`, `scripts/main.lua`,
  `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`, `RESEARCH.md`

Known issues:
- Размер, шрифт и позиция не сохраняются между сессиями (M10/M11).
- Ручного скролла назад нет (в рендере предусмотрен `scrollLines`).
- Опрос клавиш через `IsInputKeyDown` в игре проверен только фактом запуска; работу всех клавиш подтвердить при следующей проверке.

Next:
- Milestone 8: фоновый producer в C++ → очередь → game thread.

---

## Milestone 8 — Threading / data producer

Status:
PASS

Hypothesis:
Фоновый поток может производить сообщения в потокобезопасную очередь, а game thread — забирать их в ChatModel, без обращения
к UObject/Lua из фона, стабильно несколько минут и с корректной остановкой.

Tested:
- 2026-09-25 06:51–07:00: запуск игры с новым C++ модом, ~8 мин работы синтетического источника (сообщение каждые 3 с,
  всплеск 20 каждые 30 с), 8 (выкл/вкл потока), 0 (dev reload при работающем потоке), 7 (замер), обычный выход из игры.

Observed:
- C++ мод `RunningTrainTwitchTabletNative` (`Mods/RunningTrainTwitchTabletNative/dlls/main.dll`, 31 КБ) стартует по `enabled.txt`
  из `+ModsFolderPaths`. Сборка — рецепт HeadTracking; урезанный `CppUserModBase.hpp` побайтово совпал с рабочим из HeadTracking;
  на своём коде `/W4` без предупреждений.
- `on_lua_start` вызывается после старта Lua-мода — `RTTT_*` появляются позже `main.lua`, `chatfeed` подключается лениво (через ~1 с).
- 468 сообщений за 8 мин: `pushed == drained` на каждом статусе, `queued=0`, `dropped=0`; всплеск 20 сообщений — за один тик.
- Клавиша 8: `stopped=true` → `started=true`. Dev reload: поток в C++ продолжил работу, новый Lua-мод подключился заново.
- Замер с потоком и чатом: 16,51 мс (60,6 fps), 1 % худших 25,05 мс, перерисовка ~1,7 мс.
- Выход из игры: краш-репорта нет.
- **Найдено:** клавиша 0, удерживаемая во время dev reload, в новом Lua-состоянии засчиталась как новое нажатие → вторая перезагрузка
  поверх стартующего мода (`dev reload watcher FAILED: calling 'close' on bad self`). Исправлено: первый опрос клавиш после старта/загрузки
  карты только запоминает состояние; перезагрузка игнорируется первые 2 с после старта мода.

Conclusion:
- Схема `producer thread → ChatQueue (mutex, лимит 500, счёт потерь) → game thread (≤50 за тик) → ChatModel` работает;
  фоновые потоки не касаются ни Lua, ни UObject.

Files changed:
- `src/Native/` (`dllmain.cpp`, `ChatQueue.*`, `SyntheticProducer.*`), `scripts/Build-CppMod.ps1`, `scripts/Get-BuildDeps.ps1`,
  `scripts/gen_ue4ss_def.py`, `Mods/RunningTrainTwitchTabletNative/enabled.txt`, `scripts/tt/chatfeed.lua` (новый),
  `scripts/tt/input.lua`, `scripts/tt/devreload.lua`, `scripts/main.lua`, `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`

Known issues:
- Что деструктор мода при выходе действительно вызывается и джойнит поток, напрямую не подтверждено (подтверждено только отсутствие краша).
- Исправление двойной перезагрузки проверено офлайн, в игре — при следующем запуске.
- C++ часть не перезагружается без перезапуска игры (ограничение UE4SS).

Next:
- Milestone 9: настоящий Twitch-чат (анонимное IRC-подключение только на чтение) в ту же очередь.

---

## Milestone 9 — Twitch chat

Status:
PASS

Hypothesis:
Настоящие сообщения Twitch можно получать в фоновом потоке и выводить на планшет через ту же очередь, без влияния на игру
при подключении, отключении, обрыве и завершении.

Tested:
- Вне игры: `scripts/Test-TwitchProbe.ps1` (тот же `TwitchClient.cpp`/`ChatQueue.cpp`, консольная утилита) против живого канала —
  вход, живые сообщения с ником/цветом, имитация обрыва на середине, остановка. Два прогона, оба `reconnected=yes`, `stop()` 0 мс.
- В игре 2026-09-25 07:20–07:25: автоподключение, ~5 мин живого чата, загрузка маршрута, 8 (выкл/вкл), 4 ×3 (имитация обрыва),
  0 (dev reload при активном соединении), 7, выход из игры.

Observed:
- Анонимный IRC без TLS: `irc.chat.twitch.tv:6667`, `CAP REQ :twitch.tv/tags twitch.tv/commands`, `NICK justinfan<случайное>`,
  `JOIN #канал`. Ник — тег `display-name`, цвет — тег `color` (`#RRGGBB`, у части зрителей пустой → палитра ChatModel).
- Сообщения на русском с кириллицей в нике/тексте проходят без искажений; эмоуты видны как текст (`TearGlove`).
- Вход за ~1 с; 33 сообщения, `pushed == received`, `dropped=0`.
- Выкл/вкл (8): `Stopped` → `Connecting → Connected → Joined` за ~1 с. Имитация обрыва (4) ×3: `Disconnected` → переподключение
  через 2 с каждый раз.
- Dev reload: C++ соединение не рвётся, новый Lua подхватил `connection #4` и продолжил принимать сообщения.
- LoadMap (загрузка маршрута) на соединение не влияет — сетевая часть живёт независимо от мира, как и требует ТЗ.
- Выход из игры — без краш-репорта.
- Логи — только переходы состояний `[Twitch] …` и статус раз в минуту; по кадрам ничего не пишется.

Conclusion:
- `TwitchClient → ChatQueue → game thread → ChatModel → ChatRenderer → render target` работает; рендер не знает источник.
- Ошибки сети изолированы в фоновом потоке и видны в логе, игру не роняют.

Files changed:
- `src/Native/TwitchClient.hpp/.cpp` (новые), `src/Native/ChatQueue.hpp` (цвет), `src/Native/dllmain.cpp` (0.9.0, `RTTT_Twitch*`),
  `scripts/gen_ue4ss_def.py`, `scripts/Test-TwitchProbe.ps1`, `tests/native/twitch_probe.cpp` (новые), `scripts/tt/chatfeed.lua`,
  `scripts/main.lua`, `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`

Known issues:
- Настоящее отключение сети в игре не проверялось (только имитация); обрыв DNS/connect проверен только кодом.
- Детектор «тишины» (нет данных 7 мин) в живую не срабатывал.
- Крупные всплески реального чата не встречались (max batch = 1); путь всплеска проверен в M8 синтетикой.
- Без TLS (порт 6667). Для чтения публичного чата анонимно этого достаточно; TLS — при необходимости позже.
- Для имитированного обрыва лог пишет «no error reported» — косметика.
- При старте в логе мелькает `[Twitch] Stopped` до `Connecting` (гонка чтения статуса) — косметика.
- Канал захардкожен до M10.

Next:
- Milestone 10: конфиг (позиция/поворот/размер планшета относительно кабины, канал).

---

## Milestone 10 — Один manual transform config

Status:
PASS

Hypothesis:
Позицию, поворот и размер планшета относительно кабины можно задать в одном конфиге, и этого достаточно, чтобы мод был usable
без автоопределения поезда.

Tested:
- 2026-09-25 07:33–07:38: автопоявление в кабине, Num5 (поставить перед взглядом + блок `[Tablet]` в лог), перенос последнего блока
  в `TwitchTablet.ini`, автоперезагрузка по изменению `.ini`, перезапуск маршрута.

Observed:
- `TwitchTablet.ini` рядом с модом: `[Twitch] Channel/Enabled`, `[Tablet] AutoSpawn, X/Y/Z, Pitch/Yaw/Roll, Scale, Width/Height`
  (относительно `BaseUntendai`, см/градусы), `[Screen] FontScale`. Неизвестные ключи и неверные типы логируются и пропускаются.
- **Найдено в игре:** UE4SS отдаёт путь к скриптам как `.../Scripts/tt/...` (заглавная S), а поиск папки мода был регистрозависимым →
  конфиг искался по пути `...\config.lua\TwitchTablet.ini`, мод молча работал на значениях по умолчанию. Исправлено; офлайн-тест этого
  не ловил (в нём путь в нижнем регистре).
- После исправления: `config: loaded ... (13 values, 0 ignored)`, планшет встал по конфигу `(925.6, -56.9, 266.6) (P=14.70 Y=-155.80)` —
  пользователь: «стоит».
- Правка `.ini` применяется сама (конфиг в списке dev reload; ~3 с).
- Перезапуск маршрута: `LoadMap pre` → `forgotten on map change` → через 3 с после `LoadMap post` → `placed (config) … auto-spawned`
  в той же точке.
- F1 прячет планшет и выключает автопоявление до следующего F1; пустой чат — подсказка `waiting for chat #канал`.

Conclusion:
- Мод usable: живой Twitch-чат на планшете в заданной точке кабины, переживает перезапуск маршрута.

Files changed:
- `scripts/tt/config.lua` (новый), `TwitchTablet.ini` (новый), `scripts/tt/tablet.lua`, `scripts/tt/chatfeed.lua`,
  `scripts/tt/devreload.lua`, `scripts/tt/chatrender.lua`, `scripts/main.lua`, `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`

Known issues:
- Изменения размера (Num4/6/2/8) и шрифта (5/6) в игре не сохраняются в файл — сохранение будет в M11 (Save).
- Позиция одна для всех составов (M13).
- Автопоявление ждёт фиксированные 3 с после `LoadMap`; полная устойчивость жизненного цикла — M15.

Next:
- Milestone 11: калибровка клавишами (сдвиг/поворот/масштаб, шаги Shift/Ctrl, Reset, Save в конфиг).

---

## Milestone 11 — Calibration mode

Status:
PASS

Hypothesis:
Позицию, поворот, размер и масштаб планшета можно подогнать клавишами в игре и сохранить в конфиг, не трогая файл руками.

Tested:
- 2026-09-25: Num0 (вход/выход), Num5 (режимы MOVE/ROTATE/SIZE), Num4/6 Num8/2 Num9/3, Num+/−, Ctrl (x0.1), удержание,
  NumEnter (сохранение), Num. (сброс), Num/ (поставить перед взглядом); офлайн — полный сценарий с сохранением во временную копию.

Observed:
- Пользователь: «всё остальное работает»; сохранение из игры записало в `TwitchTablet.ini` новые X/Y/Z, Pitch/Yaw/Roll, Scale 1.03,
  Height 21 — только эти значения, комментарии и порядок строк не тронуты, прежний файл — `.bak`.
- **Shift не работает на цифрах numpad:** при включённом NumLock Windows превращает Shift+Num8 в стрелку и т. п. — нажатие до игры
  приходит как `Up`, не `NumPadEight`. Крупный шаг ×10 перенесён на Alt (Shift оставлен для Num+/−).
- Строка режима: жёлтый мелкий текст на тёмном → чёрный на яркой жёлтой полосе (блюм засвечивал текст, скриншот) → итог: тёмная полоса, жёлтый текст размером как в чате, жёлтая линия снизу; пользователь: «отлично».
- **Найдено перед тестом:** при горячей перезагрузке UE4SS снял EngineTick-хук (`Hook threw exception: Ref was not function,
  removing hook!`) — `main.lua` ставил game-thread колбэки, которые начинали выполняться до окончания самого `main.lua`.
  Весь запуск теперь — один `ExecuteInGameThreadWithDelay(1000)` в конце `main.lua` (RESEARCH.md). После исправления — 0 таких ошибок.
- Numpad не опрашивается вне режима калибровки (ключи с условием `when`).
- Собственная запись конфига не вызывает dev reload (`DevReload.acknowledgeChanges`).

Conclusion:
- Калибровка клавишами с сохранением в конфиг работает; позиция переживает перезапуск маршрута (M10).

Files changed:
- `scripts/tt/calibration.lua` (новый), `scripts/tt/config.lua` (save), `scripts/tt/input.lua` (модификаторы, повтор, `when`),
  `scripts/tt/tablet.lua` (placement API, overlay), `scripts/tt/devreload.lua`, `scripts/main.lua`, `TwitchTablet.ini`,
  `tests/ue4ss_stub.lua`, `scripts/smoke_lua.py`, `RESEARCH.md`, `.gitignore`

Known issues:
- Экран эмиссивный: большие яркие площади дают блюм и съедают текст — держать яркими только буквы.
- NumEnter = обычный Enter (Unreal их не различает); сохранение только в режиме калибровки, но игра на Enter тоже может реагировать.
- Мышиная калибровка не делалась (не блокер по ТЗ).
- `TwitchTablet.ini` в репозитории содержит калибровку пользователя (для дева; дефолты для релиза — позже).

Next:
- Milestone 12: определение состава (исследование идентификатора, без автоприменения).

---

## Milestone 12 — Определение состава

Status:
PASS (все 4 состава из меню)

Hypothesis:
В игре есть стабильный идентификатор состава, пригодный как ключ профиля, без геометрических эвристик.

Tested:
- 2026-09-25 07:57–08:09: `tt/trainid.lua` логирует кандидатов на каждый новый вагон; пользователь садился в hr1500, kr5000, hr1100
  и снова hr1500 (контроль стабильности), затем DC8500, называя составы из меню.

Observed:

```text
Observed train (menu)   Candidate identifier (car class)   TRAIN_Series   anchor
hr1500                  Cpy_KuHa115_C                      2              BaseUntendai
kr5000                  Cpy_KC1000Tc_C                     5              — (приборы на BaseTrain)
hr1100                  Cpy_KuMoHa113_C                    0              BaseUntendai
hr1500 (повтор)         Cpy_KuHa115_C                      2              BaseUntendai
DC8500                  Cpy_Kiha85Head_C                   7              — (приборы на BaseTrain)
```

- Названия меню не совпадают с внутренними именами; hr1500 и hr1100 делят меш кузова `Tc115`, но это разные классы вагонов.
- Окраска (`TRAIN_ColorIndex`) и `HokoIndex` составы не различают; `SCENARIO_NUM` — номер сценария.
- Причина «планшет не появился» на kr5000: нет `BaseUntendai` (запасной якорь `BaseTrain` сработал), а транcформ от hr1500 ставит
  планшет перед лобовым стеклом снаружи — кабина kr5000 короче (пульт X≈810–850 против 905–930).

Conclusion:
- Ключ профиля — короткое имя класса вагона `pawn.BaseTrain` (`Cpy_KuHa115_C` и т. д.): стабилен, различает все проверенные составы,
  читаем в конфиге и не зависит от порядка внутреннего enum'а серий. `TRAIN_Series` — только справочно в логе.
- Автовыбор профиля по нему — M13.

Files changed:
- `scripts/tt/trainid.lua` (новый), `scripts/tt/tablet.lua`, `scripts/main.lua`, `RESEARCH.md`

Known issues:
- Для составов без `BaseUntendai` якорь — `BaseTrain`; координаты профиля для них будут в системе `BaseTrain`.

Next:
- Milestone 13: профили по составам (`default` + `[Train.<класс>]`), при неизвестном составе — `default`.

---

## Milestone 13 — Per-train profiles

Status:
PASS

Hypothesis:
По идентификатору из M12 можно выбрать профиль состава, а при неизвестном составе — оставить профиль по умолчанию, не отключая планшет.

Tested:
- 2026-09-25: DC8500 и kr5000 с профилями `[Train.<класс>]`, hr1500 — `[Tablet]`; офлайн — переопределение ключей и откат на default
  для неизвестного класса.

Observed:
- Формат: `[Tablet]` — default; `[Train.<класс вагона>]` переопределяет любые из X Y Z Pitch Yaw Roll Scale Width Height; прочие ключи
  в такой секции логируются и пропускаются. В логе при появлении: `tablet: train <класс> -> profile <имя>`.
- Стартовые профили kr5000 и DC8500 вычислены (не откалиброваны): позиция hr1500 перенесена с тем же смещением
  (+53.3, +31.5, −7.8 см) от `Cabin_Camera_Init` каждого состава. Пользователь: «примерно там», проверено на обоих.
- Раньше на kr5000 планшет оказывался за лобовым стеклом (транcформ hr1500 в короткой кабине) — теперь внутри.
- Неизвестный класс → `default`; ошибка определения не мешает появлению планшета.

Conclusion:
- Профиль выбирается автоматически по классу вагона.

Files changed:
- `scripts/tt/config.lua` (секции `[Train.*]`, `tabletFor`), `scripts/tt/tablet.lua`, `scripts/tt/calibration.lua` (reset по профилю),
  `TwitchTablet.ini` (профили kr5000, DC8500), `scripts/main.lua`, `scripts/smoke_lua.py`

Known issues:
- Сохранение калибровки пока пишет в `[Tablet]`, а не в профиль текущего состава — M14.

Next:
- Milestone 14: Save из калибровки — в профиль текущего состава.

---

## Milestone 14 — Save в профиль состава

Status:
PASS

Hypothesis:
Калибровку можно сохранять прямо в профиль текущего состава, так что каждый состав настраивается один раз в игре, без ручной правки ini.

Tested:
- 2026-09-25: пользователь откалибровал и сохранил все 4 состава (hr1500, hr1100, kr5000, DC8500); секция hr1100 создана сохранением.
- Состав с удалённым профилем: планшет появляется перед глазами с подсказкой, после калибровки и NumEnter профиль создаётся.
- Отклик на NumEnter: полоса на 2 с показывает `SAVED`.

Observed:
- NumEnter пишет в `[Train.<класс>]` текущего состава все ключи: X Y Z Pitch Yaw Roll Scale Width Height FontScale. Секция создаётся,
  если её нет; `[Tablet]` и другие составы не трогаются. Запись минимальным diff через `.tmp` → `.bak` → rename.
- Шрифт тоже хранится в профиле (раньше был глобальным в `[Screen]`; старый ключ читается как значение по умолчанию).
- `[Tablet]` больше не хранит позицию: только AutoSpawn и вид планшета для нового состава.
- Для состава без профиля позиция по умолчанию бессмысленна (из чужой кабины планшет оказывался снаружи или над головой), поэтому
  планшет ставится перед камерой, на полосе подсказка `NEW TRAIN: Num0 calibrate, Enter save`.
- Приписка «SAVED» в конце строки статуса не влезала на узком планшете, поэтому сохранение заменяет всю полосу на 2 с.
- Num. (reset) для состава без профиля возвращает планшет перед глазами.

Conclusion:
- Каждый состав калибруется в игре и сохраняется одной клавишей; пресеты для всех 4 известных составов идут в релиз.

Files changed:
- `scripts/tt/calibration.lua` (цель сохранения, flash), `scripts/tt/config.lua` (FontScale в профиле, создание секций),
  `scripts/tt/tablet.lua` (спаун перед глазами, подсказка), `scripts/main.lua`, `TwitchTablet.ini` (пресеты 4 составов,
  канал вынесен в конфиг игрока), `scripts/smoke_lua.py`

Known issues:
- NumEnter и обычный Enter для игры — одна клавиша (сохранение срабатывает только в режиме калибровки).
- Если состав не опознан, сохранять некуда: показывается `NOT SAVED: UNKNOWN TRAIN`.

Next:
- Milestone 15: устойчивость жизненного цикла (смена карты, выход в меню, повторные спауны, обрыв сети).

---

## Milestone 15 — Lifecycle hardening

Status:
PASS (без отдельного прогона: закрыт по итогам проверок M5–M14)

Hypothesis:
Мод переживает смену карты и состава, выход в меню, повторные спауны, перезагрузки и обрывы связи без падений и мусора.

Tested:
- Отдельного прогона не было. Пользователь подтвердил, что все сценарии в том или ином виде проходили при проверке прошлых
  milestones (2026-09-25).

Observed:
- Смена карты или маршрута: `LoadMap pre` выключает калибровку, ставит ввод и автоспаун на паузу и забывает планшет. Через 3 с после
  `LoadMap post` планшет появляется заново (M10). Сетевая часть от `LoadMap` не зависит (M9).
- Смена состава: 4 состава подряд из меню, в каждом свой профиль (M12–M14).
- Повторные спауны: F1 много раз; auto-spawn не возвращает скрытый планшет. После краша в M6 render target не держится из Lua,
  когда его нет в материале.
- Горячая перезагрузка (0 и правка файлов): hooks выгружаются, отложенные действия чистятся, первые 2 с после старта защищены,
  EngineTick hook не снимается (M8, M11).
- Twitch: вкл/выкл (8), имитация обрыва (4), серверный RECONNECT, 7 минут тишины → переподключение с backoff 2–60 с (M9).

Conclusion:
- Жизненный цикл устойчив в проверенных сценариях; новых изменений кода не потребовалось.

Files changed:
- `PROGRESS.md`

Known issues:
- Настоящее отключение сети в игре не проверялось, только имитация (4) и тишина сервера.
- Автопоявление ждёт фиксированные 3 с после `LoadMap`.

Next:
- Milestone 16: минимальный UX.

---

## Milestone 16 — Минимальный UX

Status:
PASS

Hypothesis:
Всё управление можно свести на нампад и вынести раскладку в конфиг, добавив недостающее по ТЗ: выключение экрана,
яркость, число сообщений, разрешение текстуры.

Tested:
- 2026-09-26/28: пользователь в игре — Num1/Num2/Num7/Num9, шрифт, калибровка, Num7 FINE в калибровке,
  переназначение в `[Keys]`. Офлайн — smoke (экран выкл/вкл, яркость, раскладка из конфига).

Observed:
- `[Keys]`: действие = имя клавиши Unreal, пусто = выключено. Одна клавиша делает разное вне калибровки и в ней;
  пересечения в одном режиме пишутся в лог. Подсказки на экране и в логе берут клавиши из конфига.
- По умолчанию всё на нампаде; 1–3 и F-клавиши заняты игрой.
- Экран выкл: чёрный фон, планшет на месте, чат копится; полоса калибровки видна.
- Яркость: множитель цветов при отрисовке, 0.05–1.0. Ярче 1.0 нельзя — материал unlit pass-through, RT 8-бит.
- `[Screen]`: Brightness, MaxMessages, PixelsPerCm.
- Ctrl как «мелкий шаг» убран: Ctrl+Num6..9 — дампы UE4SS (RESEARCH.md). Вместо него CalFine (Num7).
- Фейковые сообщения — нейтральный lorem ipsum.
- Конфиг разделён: `TwitchTablet.default.ini` (все опции, пресеты составов; заменяется обновлением) и
  `TwitchTablet.ini` игрока (создаётся при первом запуске, перекрывает defaults по ключам, сюда пишет Save).
- Пустой канал: не подключаемся, на экране «Set Channel in TwitchTablet.ini».

Conclusion:
- UX по ТЗ M16 закрыт; раскладка переносима на клавиатуру без нампада.

Files changed:
- `scripts/main.lua`, `scripts/tt/{config,input,tablet,dyntexture,calibration,chatfeed,fakechat}.lua`,
  `TwitchTablet.default.ini` (новый), `TwitchTablet.ini` (убран из git), `scripts/smoke_lua.py`

Known issues:
- Изменение яркости клавишами не сохраняется (только стартовое значение из конфига).

Next:
- Релизная упаковка.

---

## Release 1.0 — упаковка

Status:
PASS

Hypothesis:
Мод можно выпустить drag-and-drop архивом как HeadTracking, совместимым с ним в любом порядке установки.

Tested:
- 2026-09-28 04:07: dev-путь снят, архив распакован поверх установленного HeadTracking, игра запущена.

Observed:
- Оба мода HeadTracking и оба наших стартовали через `enabled.txt`, хотя `mods.txt` стал стандартным.
- Создан `TwitchTablet.ini`, канал не задан → «no channel set». Канал вписан в работающей игре → авто-перезагрузка,
  `Joined` через ~2 с.
- Кабину в релизной сборке не проверяли: код тот же, что в dev-проверке M16.
- После теста dev-установка восстановлена байт в байт (`backup/before-release-test`).

Conclusion:
- `dist/RunningTrain-TwitchTablet-1.0.zip` готов к публикации.

Files changed:
- `scripts/Build-Release.ps1`, `scripts/Get-UE4SS.ps1`, `signatures/FName_Constructor.lua`, `release-files/README.txt`,
  `README.md`, `LICENSE`, `.gitignore`

Known issues:
- Исходный архив UE4SS на GitHub больше не доступен; нужен локальный (хэш проверяется).

Next:
- Эмоуты Twitch до публикации (M17, частично).

---

## Milestone 17 (часть) — Эмоуты Twitch и TLS

Status:
PASS

Hypothesis:
Эмоуты Twitch можно показывать картинками: позиции даёт тег `emotes`, картинки — CDN Twitch, а GC-проблему M6 обходит
атлас, принадлежащий планшету.

Tested:
- 2026-09-28: вне игры — `Test-EmoteProbe.ps1` (Kappa, Keepo, 404, кэш), smoke (разбор тега после кириллицы, атлас).
- В игре на активном канале ~11 минут: эмоуты картинками, 137 эмоутов скачано, 1145 сообщений.

Observed:
- C++: `EmoteFetcher` — фоновый поток, WinHTTP, `static-cdn.jtvnw.net/emoticons/v2/<id>/static/dark/3.0` в
  `<мод>\emotecache\<id>.png` через `.tmp`; файл на диске = кэш. `RTTT_PopMessage` отдаёт тег `emotes`.
- Lua: `ImportFileAsTexture2D` → сразу рисуется в слот атласа 2048² (слоты 128 px, 256 штук) поверх фона чата и
  забывается; атлас стоит параметром материала скрытой плоскости внутри корпуса — держится компонентами планшета.
  Пока картинки нет, эмоут — слово. Пропорции из заголовка PNG (Kappa 75×84).
- Анимированные — первый кадр. BTTV/FFZ/7TV (`Clueless`, `catJAMJAM`) — текстом.
- Яркость по умолчанию 0.64 (два нажатия ниже полной): на эмоутах 1.0 слепила.
- **Замирание чата в игре** (было с M9, на тихих каналах незаметно): каждое соединение замерзало после ~12–16 КБ —
  ни данных, ни ответа на PING, сокет открыт. Причина — DPI провайдера на прямом соединении к серверам чата (AWS);
  отдельная программа шла через VPN пользователя, игра исключена из VPN (RESEARCH.md). Исправлено переходом на TLS
  (6697, Schannel). Заодно: ожидание через `select()` вместо `SO_RCVTIMEO`, свой PING после 60 с тишины,
  переподключение через 90 с (было 7 мин), диагностика сокета в сообщении об ошибке.
- После исправления: одно соединение, 11 минут, 1145 сообщений, 500 КБ.

Conclusion:
- Эмоуты Twitch работают; чат в игре стабилен и без VPN.

Files changed:
- `src/Native/{EmoteFetcher,TlsStream}.{hpp,cpp}` (новые), `TwitchClient.{hpp,cpp}`, `ChatQueue.hpp`, `dllmain.cpp` (1.0.0),
  `scripts/tt/emotes.lua` (новый), `chatmodel.lua`, `chatrender.lua`, `chatfeed.lua`, `tablet.lua`, `dyntexture.lua`,
  `config.lua`, `main.lua`, `TwitchTablet.default.ini`, тесты и скрипты сборки

Known issues:
- BTTV/FFZ/7TV, бейджи и анимация не поддерживаются.
- Атлас на 256 эмоутов; при заполнении начинается заново (картинки берутся из кэша на диске).

Next:
- Публикация 1.0.
