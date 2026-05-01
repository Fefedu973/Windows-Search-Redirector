Oui, là c’est **nettement mieux**. Tu as corrigé beaucoup des gros problèmes : mutex inter-processus, logs moins dangereux, clamp des settings, suppression du vieux pending text, tracking des launch threads, `ShellExecuteExW` qui retourne maintenant un succès, gestion URI custom, cache availability, etc.

Mais il reste encore quelques points **vraiment importants** avant de considérer ça stable.

---

# Bilan rapide

Je dirais :

**Avant :** architecture bonne mais fragile.
**Maintenant :** architecture beaucoup plus propre, mais il reste 4 risques sérieux :

1. **data races sur les settings globaux** ;
2. **mutex partagé avec timeout de 2 secondes dans un low-level keyboard hook** ;
3. **race d’initialisation du shared memory** ;
4. **déchargement encore pas totalement safe sans flag `g_unloading`**.

Et il y a aussi deux petites régressions : le support legacy `launcher = 0..3` a disparu, et `g_ignoreInjectedUntilTick` est presque toujours inefficace.

---

# Ce qui est bien corrigé

Très bonne amélioration ici :

```cpp
constexpr wchar_t kSharedMutexName[] =
    L"Local\\Windhawk.ReplaceWindowsSearchWithApp.SharedState.Mutex.v4";
```

Le mutex nommé est beaucoup mieux que le spinlock maison. C’est exactement la bonne direction.

Tu as aussi bien corrigé le logging :

```cpp
log_if(L"Captured pending text length=%zu", ...);
```

Au lieu de logger le texte lui-même. Très bon choix.

Le retour de `ShellExecuteExW_Hook` est aussi beaucoup plus propre :

```cpp
SetLastError(ERROR_SUCCESS);
return TRUE;
```

Ça évite de faire croire au caller que l’action a échoué alors que tu l’as remplacée.

Et ceci est une bonne amélioration :

```cpp
if (!TryBeginLaunch()) {
    return true;
}
```

Maintenant, un trigger debounced ne laisse plus passer Windows Search par erreur. C’est mieux que l’ancienne version.

---

# Problème critique 1 : data races sur les settings globaux

Tu as beaucoup de variables globales modifiées ici :

```cpp
void Wh_ModSettingsChanged() {
    LoadSettings();
}
```

Et lues ailleurs, possiblement depuis :

* le hook clavier ;
* le hook souris ;
* le thread launcher ;
* le module watcher ;
* les hooks XAML / symboles.

Exemples dangereux :

```cpp
g_customHotkey
g_customCommand
g_customCommandArgs
g_customProcessName
g_launcherTarget
g_transitionCaptureMs
g_textCaptureDelayMs
g_requireLauncherAvailable
g_log
```

Le gros problème, ce ne sont pas seulement les `DWORD` ou les `bool`. Le vrai risque, ce sont les `std::wstring`.

Par exemple, pendant que `GetConfiguredReplacementProcessNames()` lit :

```cpp
SplitProcessNameList(g_customProcessName);
```

`Wh_ModSettingsChanged()` peut réassigner :

```cpp
g_customProcessName = readStringSetting(L"customProcessName");
```

Ça peut provoquer une race mémoire sur `std::wstring`. En C++, c’est de l’undefined behavior. Donc crash possible, même si rare.

## Correction recommandée

Ajoute un lock settings, ou mieux : un snapshot.

Exemple simple :

```cpp
static SRWLOCK g_settingsLock = SRWLOCK_INIT;

struct SettingsSnapshot {
    DWORD debounceMs = 300;
    DWORD textCaptureDelayMs = 180;
    DWORD transitionCaptureMs = 3500;
    DWORD transitionIdleMs = 80;
    bool allowInjectedInput = true;
    bool requireLauncherAvailable = true;
    bool log = false;
    LauncherTarget launcherTarget = LauncherTarget::CommandPalette;
    std::wstring customHotkey;
    std::wstring customCommand;
    std::wstring customCommandArgs;
    std::wstring customProcessName;
};

static SettingsSnapshot g_settings;
```

Puis dans `LoadSettings()`, tu lis tout dans une variable locale, puis tu remplaces en exclusif :

```cpp
static void LoadSettings() {
    SettingsSnapshot next;

    // Lire / parser tous les settings dans next...

    AcquireSRWLockExclusive(&g_settingsLock);
    g_settings = std::move(next);
    ReleaseSRWLockExclusive(&g_settingsLock);

    InvalidateReplacementTargetAvailabilityCache();
}
```

Et tu crées :

```cpp
static SettingsSnapshot GetSettingsSnapshot() {
    AcquireSRWLockShared(&g_settingsLock);
    SettingsSnapshot snapshot = g_settings;
    ReleaseSRWLockShared(&g_settingsLock);
    return snapshot;
}
```

Ensuite, les fonctions comme `GetConfiguredReplacementProcessNames()`, `OpenReplacementWindow()`, `SendLauncherHotkey()`, `IsReplacementTargetAvailableUncached()` devraient travailler sur un snapshot local.

C’est le plus gros chantier restant, mais c’est important.

---

# Problème critique 2 : `SharedStateLock` attend 2 secondes dans le hook clavier

Actuellement :

```cpp
DWORD wait = WaitForSingleObject(g_sharedMutex, 2000);
```

Mais `SharedStateLock` est utilisé dans le chemin du low-level keyboard hook :

```cpp
AppendPendingText()
RemoveLastPendingChar()
HasPendingText()
ClearPendingText()
```

Donc si un autre process garde le mutex trop longtemps, ton hook clavier peut bloquer jusqu’à **2 secondes**. Dans un `WH_KEYBOARD_LL`, c’est beaucoup trop.

Windows peut même considérer le hook comme non-réactif et l’enlever silencieusement.

## Correction recommandée

Fais un timeout court par défaut, genre 20 ou 50 ms, et éventuellement un timeout plus long hors hook.

Par exemple :

```cpp
class SharedStateLock {
public:
    explicit SharedStateLock(DWORD timeoutMs = 50) {
        if (!g_sharedMutex) {
            return;
        }

        DWORD wait = WaitForSingleObject(g_sharedMutex, timeoutMs);
        if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
            m_locked = true;
        }
    }

    ~SharedStateLock() {
        if (m_locked && g_sharedMutex) {
            ReleaseMutex(g_sharedMutex);
        }
    }

    bool locked() const {
        return m_locked;
    }

private:
    bool m_locked = false;
};
```

Puis dans le launcher thread, si tu veux attendre plus longtemps :

```cpp
SharedStateLock lock(500);
```

Mais dans le hook clavier, jamais 2000 ms. C’est trop.

---

# Problème critique 3 : race d’initialisation du shared memory

Dans `InitSharedState()` :

```cpp
g_sharedMapping = CreateFileMappingW(...);
DWORD createMappingLastError = GetLastError();
...
g_sharedState = reinterpret_cast<SharedState*>(MapViewOfFile(...));

if (createMappingLastError != ERROR_ALREADY_EXISTS) {
    ZeroMemory(g_sharedState, sizeof(*g_sharedState));
}
```

Le problème : tu crées le mutex, mais tu ne l’utilises pas pendant l’initialisation.

Scénario possible :

1. Process A crée le mapping.
2. Process B ouvre le mapping juste après.
3. Process B commence à utiliser `g_sharedState`.
4. Process A n’a pas encore fait `ZeroMemory`.

C’est rare, mais possible.

## Correction recommandée

Ajoute un champ `initialized` dans `SharedState` :

```cpp
struct SharedState {
    volatile LONG initialized;
    volatile LONG launchInProgress;
    volatile LONG64 lastLaunchTick;
    volatile LONG64 pendingTextTick;
    volatile LONG64 captureUntilTick;
    volatile LONG64 lastInputTick;
    volatile LONG pendingTextCanPasteOriginal;
    wchar_t pendingText[kMaxPendingTextLength];
};
```

Puis après `MapViewOfFile`, fais l’initialisation sous mutex :

```cpp
{
    SharedStateLock lock(2000);
    if (!lock.locked()) {
        Wh_Log(L"[ReplaceSearch] Failed to lock shared state during init");
        return false;
    }

    if (InterlockedCompareExchange(&g_sharedState->initialized, 0, 0) != 1) {
        ZeroMemory(g_sharedState, sizeof(*g_sharedState));
        InterlockedExchange(&g_sharedState->initialized, 1);
    }
}
```

Avec ça, même si plusieurs processus démarrent en même temps, l’état partagé est propre.

---

# Problème critique 4 : il manque un flag `g_unloading`

Tu as ajouté :

```cpp
WaitForLaunchThreadsAndCloseTracking();
UninitSharedState();
```

C’est bien. Mais il reste un cas dangereux : pendant `Wh_ModUninit()`, un hook symbole pourrait encore appeler `LaunchReplacement()` et créer un nouveau thread de lancement juste avant ou pendant le teardown.

Tu devrais ajouter :

```cpp
static volatile LONG g_unloading = 0;
```

Dans `Wh_ModUninit()` :

```cpp
void Wh_ModUninit() {
    InterlockedExchange(&g_unloading, 1);

    if (g_targetProcess == TargetProcess::Explorer) {
        StopKeyboardHookThread();
    }

    StopModuleWatcherThread();
    WaitForLaunchThreadsAndCloseTracking();
    UninitSharedState();
}
```

Et au début de `LaunchReplacement()` :

```cpp
static bool IsUnloading() {
    return InterlockedCompareExchange(&g_unloading, 0, 0) != 0;
}

static bool LaunchReplacement() {
    if (IsUnloading()) {
        return false;
    }

    ...
}
```

Tu peux aussi protéger `RequestReplacement()` :

```cpp
static bool RequestReplacement(PCWSTR reason) {
    if (IsUnloading()) {
        return false;
    }

    ...
}
```

Ça évite de créer un thread pendant que tu fermes le shared state.

---

# Bug : `g_ignoreInjectedUntilTick` est toujours mal utilisé

Tu as actuellement :

```cpp
if (injected && !g_allowInjectedInput &&
    IsLocalTickActive(&g_ignoreInjectedUntilTick)) {
    return CallNextHookEx(g_keyboardHook, nCode, wParam, lParam);
}

if (!g_allowInjectedInput && injected) {
    return CallNextHookEx(g_keyboardHook, nCode, wParam, lParam);
}
```

Le premier test ne sert presque à rien, parce que si `!g_allowInjectedInput`, le deuxième test ignore déjà tous les inputs injectés.

Le cas utile, c’est quand `g_allowInjectedInput == true`, mais que tu veux quand même ignorer les inputs injectés pendant la courte fenêtre où ton mod vient d’utiliser `SendInput`.

Donc il faut plutôt faire :

```cpp
if (injected && keyboardInfo->dwExtraInfo == kOwnInjectedInputMarker) {
    return CallNextHookEx(g_keyboardHook, nCode, wParam, lParam);
}

if (injected && IsLocalTickActive(&g_ignoreInjectedUntilTick)) {
    return CallNextHookEx(g_keyboardHook, nCode, wParam, lParam);
}

if (!g_allowInjectedInput && injected) {
    return CallNextHookEx(g_keyboardHook, nCode, wParam, lParam);
}
```

Là, `g_ignoreInjectedUntilTick` sert vraiment de filet de sécurité si `dwExtraInfo` n’est pas conservé comme prévu.

---

# Régression : tu as perdu la compatibilité `launcher = 0..3`

Avant tu gérais :

```cpp
launcher == L"0"
launcher == L"1"
launcher == L"2"
launcher == L"3"
```

Maintenant :

```cpp
if (launcher == L"powertoysrun") {
    ...
} else if (launcher == L"customhotkey") {
    ...
} else if (launcher == L"customcommand") {
    ...
} else {
    g_launcherTarget = LauncherTarget::CommandPalette;
}
```

Donc si un ancien setting contient `"0"`, il sera maintenant interprété comme `CommandPalette`, pas `PowerToysRun`.

Je remettrais les cas numériques, ça ne coûte rien :

```cpp
if (launcher == L"powertoysrun" || launcher == L"0") {
    g_launcherTarget = LauncherTarget::PowerToysRun;
} else if (launcher == L"commandpalette" || launcher == L"1") {
    g_launcherTarget = LauncherTarget::CommandPalette;
} else if (launcher == L"customhotkey" || launcher == L"2") {
    g_launcherTarget = LauncherTarget::CustomHotkey;
} else if (launcher == L"customcommand" || launcher == L"3") {
    g_launcherTarget = LauncherTarget::CustomCommand;
} else {
    g_launcherTarget = LauncherTarget::CommandPalette;
}
```

---

# Problème : `InitSharedState()` est ignoré

Dans `Wh_ModInit()` :

```cpp
InitLaunchThreadTracking();
InitSharedState();
```

Tu ignores le retour de `InitSharedState()`.

Si le mapping ou le mutex échoue, le mod continue quand même, mais sans état partagé fiable. Résultat possible :

* pas de pending text ;
* pas de verrou inter-processus ;
* plusieurs launchers lancés en même temps ;
* comportement partiel très difficile à comprendre.

Je recommanderais :

```cpp
if (!InitSharedState()) {
    Wh_Log(L"[ReplaceSearch] Shared state unavailable, disabling mod");
    WaitForLaunchThreadsAndCloseTracking();
    return FALSE;
}
```

Ou au minimum, désactiver les interceptions qui dépendent du shared state.

---

# Point encore fragile : `SearchBoxGetCommand_Hook`

Tu as gardé :

```cpp
if (value) {
    *value = nullptr;
}
return S_OK;
```

C’est une interception assez agressive. Si l’UI Start ne s’attend pas à recevoir un `ICommand` nul, tu peux créer des bugs bizarres.

Je comprends pourquoi tu l’as ajouté : pour bloquer certains chemins où le clic déclenche une commande interne. Mais je le garderais comme fallback expérimental.

Si tu veux fiabiliser :

* désactive temporairement ce hook ;
* teste si les hooks pointer/tapped suffisent ;
* ne garde `get_Command` que si tu observes vraiment un chemin non couvert.

À minima, documente-le comme “risky fallback”.

---

# Point encore fragile : `PointerEntered` / `PointerExited`

Tu as réduit :

```cpp
MarkStartSearchBoxPointerActivation(300);
```

C’est mieux que 5000 ms. Mais `PointerEntered` n’est toujours pas une activation. C’est juste un hover.

Et `PointerExited` fait encore :

```cpp
MarkStartSearchBoxPointerActivation(500);
```

Ça peut créer un faux positif : l’utilisateur survole la search box, sort, puis une mise à jour interne de `set_IsChecked` ou `get_Command` arrive dans la fenêtre de 500 ms.

Je mettrais plutôt :

```cpp
static void WINAPI SearchBoxOnPointerEntered_Hook(...) {
    log_if(L"StartDocked::SearchBoxToggleButton::OnPointerEntered");
    SearchBoxOnPointerEntered_Original(pThis, sender, args);
}

static void WINAPI SearchBoxOnPointerExited_Hook(...) {
    log_if(L"StartDocked::SearchBoxToggleButton::OnPointerExited");
    SearchBoxOnPointerExited_Original(pThis, sender, args);
}
```

Ou alors garde seulement un tout petit délai, genre 100 ms, mais pas plus.

---

# Point subtil : le cache foreground est correct, mais pas thread-safe

Tu as ajouté :

```cpp
static ForegroundSnapshot CaptureForegroundSnapshotCached(DWORD maxAgeMs) {
    static HWND cachedHwnd = nullptr;
    static ULONGLONG cachedTick = 0;
    static ForegroundSnapshot cachedSnapshot;
    ...
}
```

Dans la pratique, ça va probablement être appelé surtout depuis le thread clavier. Donc ça passe.

Mais si un jour tu l’utilises depuis plusieurs threads, `cachedSnapshot` contient une `std::wstring`, donc race possible.

Je laisserais comme ça pour l’instant, mais avec un commentaire :

```cpp
// Only used from the keyboard hook thread.
```

---

# Petit bug potentiel : `LaunchReplacement()` retourne `true` sur debounce même si aucun lancement n’est actif

Tu as :

```cpp
if (!TryBeginLaunch()) {
    return true;
}
```

C’est mieux pour ne pas laisser Windows Search s’ouvrir. Mais ça peut masquer un cas :

1. un lancement vient d’échouer ;
2. `lastLaunchTick` est encore récent ;
3. l’utilisateur réessaie dans les 300 ms ;
4. `TryBeginLaunch()` retourne false à cause du debounce ;
5. `LaunchReplacement()` retourne true ;
6. l’action native est bloquée, mais aucun launcher ne s’ouvre.

Ce n’est pas dramatique, parce que 300 ms est court. Mais si tu veux être propre, remplace `TryBeginLaunch()` par un enum :

```cpp
enum class BeginLaunchResult {
    Started,
    AlreadyInProgress,
    Debounced,
    Failed,
};
```

Puis tu peux décider différemment selon le cas.

---

# Tests que je ferais maintenant

Tu devrais tester précisément ces scénarios :

```powershell
# 1. Typing rapide depuis Start
wh-test-input.exe starttype AZERTY123

# 2. Paste simple
wh-test-input.exe startpaste "hello world"

# 3. Paste avec newline, doit devenir une seule ligne
wh-test-input.exe startpaste "hello`nworld"

# 4. Win+S répété rapidement
wh-test-input.exe wins
wh-test-input.exe wins

# 5. Command Palette non lancée avec requireLauncherAvailable=true
# attendu : Windows Search doit rester utilisable

# 6. Command Palette lancée, requireLauncherAvailable=true
# attendu : interception OK

# 7. CustomHotkey sans customProcessName
# attendu : le mod doit refuser proprement et laisser Windows Search

# 8. CustomCommand avec URI + customProcessName
# attendu : URI lancée, args ignorés, texte transféré

# 9. Désactivation du mod pendant qu’une transaction est en cours
# attendu : pas de crash explorer/start/searchhost

# 10. Changement de settings pendant que tu tapes vite
# attendu : pas de crash, pas de corruption
```

Le test 10 est celui qui peut révéler les data races.

---

# Priorité des corrections restantes

Je ferais ça dans cet ordre :

1. **Ajouter un lock/snapshot pour les settings globaux.**
2. **Réduire le timeout du `SharedStateLock` dans les hooks clavier/souris.**
3. **Ajouter `g_unloading` pour empêcher les threads créés pendant `Wh_ModUninit()`.**
4. **Corriger l’initialisation du shared memory avec un champ `initialized`.**
5. **Corriger `g_ignoreInjectedUntilTick`.**
6. **Remettre la compatibilité `launcher = 0..3`.**
7. **Réduire ou supprimer `PointerEntered` / `PointerExited` comme activation probable.**
8. **Reconsidérer `SearchBoxGetCommand_Hook`.**

---

# Verdict final

Cette version est **beaucoup plus sérieuse** que la précédente. Les grosses corrections sont bonnes, surtout :

* `log: false` par défaut ;
* mutex nommé ;
* retour `TRUE` dans `ShellExecuteExW_Hook` ;
* suppression du vieux pending text au lieu de le réinjecter plus tard ;
* custom command URI mieux traité ;
* cache de disponibilité ;
* thread tracking.

Mais je ne publierais pas encore sans corriger au minimum :

```text
settings snapshot / lock
SharedStateLock timeout court dans le hook clavier
g_unloading
shared memory initialized flag
g_ignoreInjectedUntilTick
```

Après ça, on serait sur une base vraiment propre.
