#include <windows.h>
#include <shlwapi.h>
#include <initguid.h>
#include <uiautomation.h>

#include <cstdio>
#include <cwchar>
#include <string>

static std::wstring GetProcessNameFromPid(DWORD pid) {
    if (!pid) {
        return L"";
    }

    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
        return L"";
    }

    wchar_t path[MAX_PATH] = {};
    DWORD size = ARRAYSIZE(path);
    std::wstring result;
    if (QueryFullProcessImageNameW(process, 0, path, &size)) {
        result = PathFindFileNameW(path);
    }

    CloseHandle(process);
    return result;
}

static void PrintForeground() {
    HWND hwnd = GetForegroundWindow();
    DWORD pid = 0;
    if (hwnd) {
        GetWindowThreadProcessId(hwnd, &pid);
    }

    wchar_t className[256] = {};
    wchar_t title[512] = {};
    if (hwnd) {
        GetClassNameW(hwnd, className, ARRAYSIZE(className));
        GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    }

    std::wstring processName = GetProcessNameFromPid(pid);
    std::wprintf(L"foreground hwnd=0x%p pid=%lu process=%ls class=%ls title=%ls\n",
                 hwnd, pid, processName.c_str(), className, title);
}

static void PrintFocusedAutomation() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool coInitialized = SUCCEEDED(hr);

    IUIAutomation* automation = nullptr;
    hr = CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                          IID_PPV_ARGS(&automation));
    if (FAILED(hr) || !automation) {
        std::wprintf(L"uia focused unavailable hr=0x%08lx\n", hr);
        if (coInitialized) {
            CoUninitialize();
        }
        return;
    }

    IUIAutomationElement* element = nullptr;
    hr = automation->GetFocusedElement(&element);
    if (FAILED(hr) || !element) {
        std::wprintf(L"uia focused element unavailable hr=0x%08lx\n", hr);
        automation->Release();
        if (coInitialized) {
            CoUninitialize();
        }
        return;
    }

    BSTR name = nullptr;
    CONTROLTYPEID controlType = 0;
    element->get_CurrentName(&name);
    element->get_CurrentControlType(&controlType);

    std::wstring value;
    IUIAutomationValuePattern* valuePattern = nullptr;
    if (SUCCEEDED(element->GetCurrentPatternAs(UIA_ValuePatternId,
                                               IID_PPV_ARGS(&valuePattern))) &&
        valuePattern) {
        BSTR rawValue = nullptr;
        if (SUCCEEDED(valuePattern->get_CurrentValue(&rawValue)) && rawValue) {
            value = rawValue;
            SysFreeString(rawValue);
        }
        valuePattern->Release();
    }

    std::wprintf(L"uia focused controlType=%d name=%ls value=%ls\n", controlType,
                 name ? name : L"", value.c_str());

    if (name) {
        SysFreeString(name);
    }
    element->Release();
    automation->Release();
    if (coInitialized) {
        CoUninitialize();
    }
}

static void PrintWindowLine(HWND hwnd, int depth) {
    wchar_t className[256] = {};
    wchar_t title[512] = {};
    RECT rect = {};
    GetClassNameW(hwnd, className, ARRAYSIZE(className));
    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    GetWindowRect(hwnd, &rect);

    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    std::wstring processName = GetProcessNameFromPid(pid);

    for (int i = 0; i < depth; i++) {
        std::wprintf(L"  ");
    }

    std::wprintf(L"hwnd=0x%p pid=%lu process=%ls class=%ls title=%ls rect=%ld,%ld,%ld,%ld visible=%d\n",
                 hwnd, pid, processName.c_str(), className, title, rect.left,
                 rect.top, rect.right, rect.bottom, IsWindowVisible(hwnd) ? 1 : 0);
}

static void EnumChildWindowsRecursive(HWND parent, int depth) {
    EnumChildWindows(
        parent,
        [](HWND hwnd, LPARAM lParam) -> BOOL {
            int depth = static_cast<int>(lParam);
            PrintWindowLine(hwnd, depth);
            EnumChildWindowsRecursive(hwnd, depth + 1);
            return TRUE;
        },
        depth);
}

static void SendVirtualKey(WORD virtualKey, bool keyUp) {
    INPUT input = {};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = virtualKey;
    input.ki.dwFlags = keyUp ? KEYEVENTF_KEYUP : 0;
    SendInput(1, &input, sizeof(input));
}

static void TapVirtualKey(WORD virtualKey) {
    SendVirtualKey(virtualKey, false);
    Sleep(25);
    SendVirtualKey(virtualKey, true);
}

static void ReleaseModifiers() {
    SendVirtualKey(VK_CONTROL, true);
    SendVirtualKey(VK_LCONTROL, true);
    SendVirtualKey(VK_RCONTROL, true);
    SendVirtualKey(VK_MENU, true);
    SendVirtualKey(VK_LMENU, true);
    SendVirtualKey(VK_RMENU, true);
    SendVirtualKey(VK_LWIN, true);
    SendVirtualKey(VK_RWIN, true);
}

static void SendWinS() {
    ReleaseModifiers();
    SendVirtualKey(VK_LWIN, false);
    Sleep(40);
    TapVirtualKey(L'S');
    Sleep(40);
    SendVirtualKey(VK_LWIN, true);
}

static void SendCtrlV() {
    ReleaseModifiers();
    SendVirtualKey(VK_CONTROL, false);
    Sleep(30);
    TapVirtualKey(L'V');
    Sleep(30);
    SendVirtualKey(VK_CONTROL, true);
}

static void SendUnicodeText(PCWSTR text) {
    for (PCWSTR p = text; *p; p++) {
        INPUT inputs[2] = {};
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].ki.wScan = *p;
        inputs[0].ki.dwFlags = KEYEVENTF_UNICODE;
        inputs[1] = inputs[0];
        inputs[1].ki.dwFlags |= KEYEVENTF_KEYUP;
        SendInput(2, inputs, sizeof(INPUT));
        Sleep(15);
    }
}

static void SendKeyboardText(PCWSTR text) {
    HWND foreground = GetForegroundWindow();
    DWORD foregroundThreadId =
        foreground ? GetWindowThreadProcessId(foreground, nullptr) : 0;
    HKL layout = GetKeyboardLayout(foregroundThreadId ? foregroundThreadId
                                                      : GetCurrentThreadId());
    for (PCWSTR p = text; *p; p++) {
        SHORT vkAndShift = VkKeyScanExW(*p, layout);
        if (vkAndShift == -1) {
            SendUnicodeText(std::wstring(1, *p).c_str());
            continue;
        }

        BYTE vk = LOBYTE(vkAndShift);
        BYTE shiftState = HIBYTE(vkAndShift);
        if (shiftState & 1) {
            SendVirtualKey(VK_SHIFT, false);
        }
        if (shiftState & 2) {
            SendVirtualKey(VK_CONTROL, false);
        }
        if (shiftState & 4) {
            SendVirtualKey(VK_MENU, false);
        }

        TapVirtualKey(vk);

        if (shiftState & 4) {
            SendVirtualKey(VK_MENU, true);
        }
        if (shiftState & 2) {
            SendVirtualKey(VK_CONTROL, true);
        }
        if (shiftState & 1) {
            SendVirtualKey(VK_SHIFT, true);
        }

        Sleep(30);
    }
}

static bool SetClipboardText(PCWSTR text) {
    if (!OpenClipboard(nullptr)) {
        return false;
    }

    EmptyClipboard();
    size_t bytes = (wcslen(text) + 1) * sizeof(wchar_t);
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!data) {
        CloseClipboard();
        return false;
    }

    void* locked = GlobalLock(data);
    memcpy(locked, text, bytes);
    GlobalUnlock(data);
    SetClipboardData(CF_UNICODETEXT, data);
    CloseClipboard();
    return true;
}

static void OpenStartMenu() {
    ReleaseModifiers();
    TapVirtualKey(VK_LWIN);
    Sleep(600);
}

static void ClickPoint(int x, int y) {
    SetCursorPos(x, y);
    Sleep(80);

    INPUT inputs[2] = {};
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(2, inputs, sizeof(INPUT));
}

static void ClickStartSearchBox() {
    OpenStartMenu();

    HWND hwnd = GetForegroundWindow();
    RECT rect = {};
    if (!hwnd || !GetWindowRect(hwnd, &rect)) {
        PrintForeground();
        return;
    }

    int width = rect.right - rect.left;
    int x = rect.left + std::min(160, std::max(80, width / 5));
    int y = rect.top + 45;
    std::wprintf(L"clicking start search point x=%d y=%d\n", x, y);
    HWND hit = WindowFromPoint({x, y});
    PrintWindowLine(hit, 0);
    HWND root = hit ? GetAncestor(hit, GA_ROOT) : nullptr;
    if (root && root != hit) {
        PrintWindowLine(root, 1);
    }
    ClickPoint(x, y);
    Sleep(1600);
    PrintForeground();
}

static void PrintUsage() {
    std::puts("usage: wh-test-input <fg|uia|enumtaskbar|esc|cmdpal|wins|start|startclicksearch|starttype TEXT|startpaste TEXT|type TEXT|protocolsearch TEXT>");
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) {
        PrintUsage();
        return 2;
    }

    std::wstring command = argv[1];

    if (command == L"fg") {
        PrintForeground();
        return 0;
    }

    if (command == L"uia") {
        PrintForeground();
        PrintFocusedAutomation();
        return 0;
    }

    if (command == L"enumtaskbar") {
        HWND taskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
        PrintWindowLine(taskbar, 0);
        EnumChildWindowsRecursive(taskbar, 1);
        return 0;
    }

    if (command == L"esc") {
        TapVirtualKey(VK_ESCAPE);
        Sleep(300);
        PrintForeground();
        return 0;
    }

    if (command == L"cmdpal") {
        ShellExecuteW(nullptr, L"open", L"x-cmdpal:", nullptr, nullptr, SW_SHOWNORMAL);
        Sleep(1200);
        PrintForeground();
        return 0;
    }

    if (command == L"wins") {
        SendWinS();
        Sleep(1600);
        PrintForeground();
        return 0;
    }

    if (command == L"start") {
        OpenStartMenu();
        PrintForeground();
        return 0;
    }

    if (command == L"startclicksearch") {
        ClickStartSearchBox();
        return 0;
    }

    if (command == L"starttype" && argc >= 3) {
        OpenStartMenu();
        SendKeyboardText(argv[2]);
        Sleep(1800);
        PrintForeground();
        return 0;
    }

    if (command == L"startpaste" && argc >= 3) {
        SetClipboardText(argv[2]);
        OpenStartMenu();
        SendCtrlV();
        Sleep(1800);
        PrintForeground();
        return 0;
    }

    if (command == L"type" && argc >= 3) {
        SendKeyboardText(argv[2]);
        Sleep(500);
        PrintForeground();
        return 0;
    }

    if (command == L"protocolsearch" && argc >= 3) {
        std::wstring uri = L"ms-search:?query=";
        uri += argv[2];
        ShellExecuteW(nullptr, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        Sleep(1800);
        PrintForeground();
        return 0;
    }

    PrintUsage();
    return 2;
}
