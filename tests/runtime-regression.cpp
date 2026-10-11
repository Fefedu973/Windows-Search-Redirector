// Real-desktop regression: a disposable edit control catches leaked input.
// No Enter key is sent to the launcher and the clipboard is left untouched.
#define wmain legacy_test_main
#include "wh-test-input.cpp"
#undef wmain
#include <atomic>
#include <thread>
#include <dwmapi.h>

static HWND sinkWindow;
static HWND sinkEdit;
static std::atomic<int> result{2};
static std::atomic<bool> finished{false};

static void CaptureDesktop() {
    int width = GetSystemMetrics(SM_CXSCREEN), height = GetSystemMetrics(SM_CYSCREEN);
    HDC screen = GetDC(nullptr), memory = CreateCompatibleDC(screen);
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    void* pixels = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    HGDIOBJ old = SelectObject(memory, bitmap);
    BitBlt(memory, 0, 0, width, height, screen, 0, 0, SRCCOPY);
    BITMAPFILEHEADER header = {};
    header.bfType = 0x4d42;
    header.bfOffBits = sizeof(header) + sizeof(info.bmiHeader);
    header.bfSize = header.bfOffBits + width * height * 4;
    FILE* file = _wfopen(L"build\\runtime-desktop.bmp", L"wb");
    if (file) {
        fwrite(&header, sizeof(header), 1, file);
        fwrite(&info.bmiHeader, sizeof(info.bmiHeader), 1, file);
        fwrite(pixels, width * height * 4, 1, file);
        fclose(file);
    }
    SelectObject(memory, old);
    DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(nullptr, screen);
}

static void PumpFor(DWORD milliseconds) {
    ULONGLONG end = GetTickCount64() + milliseconds;
    do {
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(1);
    } while (GetTickCount64() < end);
}

static std::wstring ForegroundName() {
    DWORD pid = 0;
    GetWindowThreadProcessId(GetForegroundWindow(), &pid);
    return GetProcessNameFromPid(pid);
}

static bool ShellForeground() {
    auto name = ForegroundName();
    return name == L"StartMenuExperienceHost.exe" || name == L"SearchHost.exe";
}

static bool StartVisible() {
    HWND hwnd = nullptr;
    while ((hwnd = FindWindowExW(nullptr, hwnd, L"Windows.UI.Core.CoreWindow", nullptr))) {
        DWORD pid = 0, cloaked = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (GetProcessNameFromPid(pid) != L"StartMenuExperienceHost.exe" || !IsWindowVisible(hwnd)) continue;
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
        RECT rect = {};
        GetWindowRect(hwnd, &rect);
        if (!cloaked && rect.right - rect.left > 100 && rect.bottom - rect.top > 100) {
            return true;
        }
    }
    return false;
}

static void FastText(const std::wstring& text, DWORD interval) {
    HKL layout = GetKeyboardLayout(GetWindowThreadProcessId(GetForegroundWindow(), nullptr));
    for (wchar_t ch : text) {
        SHORT key = VkKeyScanExW(ch, layout);
        if (key == -1) {
            SendUnicodeText(std::wstring(1, ch).c_str());
            continue;
        }
        const WORD mods[] = {VK_LSHIFT, VK_LCONTROL, VK_LMENU};
        for (int i = 0; i < 3; ++i) {
            if (HIBYTE(key) & (1 << i)) SendVirtualKey(mods[i], false);
        }
        SendVirtualKey(LOBYTE(key), false);
        SendVirtualKey(LOBYTE(key), true);
        for (int i = 2; i >= 0; --i) {
            if (HIBYTE(key) & (1 << i)) SendVirtualKey(mods[i], true);
        }
        Sleep(interval);
    }
}

static bool ClickSemanticStartSearch(IUIAutomation* automation) {
    HWND hwnd = nullptr;
    while ((hwnd = FindWindowExW(nullptr, hwnd, L"Windows.UI.Core.CoreWindow", nullptr))) {
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (GetProcessNameFromPid(pid) != L"StartMenuExperienceHost.exe") continue;
        IUIAutomationElement* root = nullptr;
        IUIAutomationCondition* all = nullptr;
        IUIAutomationElementArray* elements = nullptr;
        HRESULT rootHr = automation->ElementFromHandle(hwnd, &root);
        automation->CreateTrueCondition(&all);
        HRESULT treeHr = root && all ? root->FindAll(TreeScope_Descendants, all, &elements) : E_FAIL;
        bool clicked = false;
        int count = 0;
        if (elements) elements->get_Length(&count);
        std::printf("Start UIA descendants=%d root=%08lx tree=%08lx\n", count, rootHr, treeHr);
        for (int i = 0; i < count && !clicked; ++i) {
            IUIAutomationElement* element = nullptr;
            if (FAILED(elements->GetElement(i, &element)) || !element) continue;
            BSTR name = nullptr, id = nullptr;
            CONTROLTYPEID type = 0;
            BOOL offscreen = TRUE;
            RECT rect = {};
            element->get_CurrentName(&name);
            element->get_CurrentAutomationId(&id);
            element->get_CurrentControlType(&type);
            element->get_CurrentIsOffscreen(&offscreen);
            element->get_CurrentBoundingRectangle(&rect);
            if ((id && StrStrIW(id, L"Search")) || (name && (StrStrIW(name, L"Rechercher") || StrStrIW(name, L"Search"))))
                std::wprintf(L"candidate type=%d offscreen=%d id=%ls name=%ls\n", type, offscreen, id ? id : L"", name ? name : L"");
            if (!offscreen && (type == UIA_ButtonControlTypeId || type == UIA_EditControlTypeId) &&
                ((id && StrStrIW(id, L"Search")) || (name && StrStrIW(name, L"Rechercher")))) {
                std::wprintf(L"search control id=%ls name=%ls\n", id ? id : L"", name ? name : L"");
                ClickPoint((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2);
                clicked = true;
            }
            SysFreeString(name); SysFreeString(id); element->Release();
        }
        if (elements) elements->Release();
        if (all) all->Release();
        if (root) root->Release();
        if (clicked) return true;
    }
    return false;
}

static bool ReadLauncherText(IUIAutomation* automation, std::wstring* text, bool native = false) {
    IUIAutomationElement* focus = nullptr;
    if (FAILED(automation->GetFocusedElement(&focus)) || !focus) return false;
    int pid = 0;
    CONTROLTYPEID type = 0;
    focus->get_CurrentProcessId(&pid);
    focus->get_CurrentControlType(&type);
    bool launcher = GetProcessNameFromPid(pid) == (native ? L"SearchHost.exe" : L"Microsoft.CmdPal.UI.exe");
    bool ok = false;
    IUIAutomationValuePattern* value = nullptr;
    if (launcher && type == UIA_EditControlTypeId &&
        SUCCEEDED(focus->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&value))) && value) {
        BSTR raw = nullptr;
        if (SUCCEEDED(value->get_CurrentValue(&raw))) {
            *text = raw ? raw : L"";
            SysFreeString(raw);
            ok = true;
        }
        value->Release();
    }
    focus->Release();
    return ok;
}

int wmain(int argc, wchar_t** argv) {
    const std::wstring mode = argc > 1 ? argv[1] : L"typing";
    if (mode == L"shell-windows") {
        HWND hwnd = nullptr;
        while ((hwnd = FindWindowExW(nullptr, hwnd, L"Windows.UI.Core.CoreWindow", nullptr))) {
            DWORD pid = 0;
            GetWindowThreadProcessId(hwnd, &pid);
            auto name = GetProcessNameFromPid(pid);
            if (name == L"StartMenuExperienceHost.exe" || name == L"SearchHost.exe") {
                PrintWindowLine(hwnd, 0);
                DWORD cloaked = 0;
                DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
                std::printf("cloaked=%lu\n", cloaked);
            }
        }
        PrintFocusedAutomation();
        return 0;
    }
    const std::wstring expected = argc > 2 ? argv[2] : L"azertyAbC1234567890";
    WNDCLASSW wc = {};
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"WindhawkRegressionSink";
    RegisterClassW(&wc);
    sinkWindow = CreateWindowW(wc.lpszClassName, L"Windhawk regression - disposable input sink",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, 150, 150, 600, 180, nullptr, nullptr, wc.hInstance, nullptr);
    sinkEdit = CreateWindowW(L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL,
        20, 40, 540, 35, sinkWindow, nullptr, wc.hInstance, nullptr);
    SetForegroundWindow(sinkWindow);
    SetFocus(sinkEdit);
    PumpFor(150);
    {
        RECT rect = {};
        GetWindowRect(sinkEdit, &rect);
        ClickPoint(rect.left + 20, rect.top + 15);
        PumpFor(700);
    }
    if (GetForegroundWindow() != sinkWindow) {
        std::puts("BLOCKED: test sink did not receive foreground; no input sent");
        DestroyWindow(sinkWindow);
        return 2;
    }
    if (StartVisible()) {
        std::puts("BLOCKED: Start still visible after focusing the test sink");
        CaptureDesktop();
        DestroyWindow(sinkWindow);
        return 2;
    }

    std::thread worker([&] {
        struct Completion { ~Completion() { finished = true; } } completion;
        CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        IUIAutomation* automation = nullptr;
        CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&automation));
        if (!automation) { result = 1; CoUninitialize(); return; }
        IUIAutomation2* timeouts = nullptr;
        if (SUCCEEDED(automation->QueryInterface(IID_PPV_ARGS(&timeouts)))) {
            timeouts->put_ConnectionTimeout(200);
            timeouts->put_TransactionTimeout(mode == L"click" || mode == L"native-click" ? 2000 : 200);
            timeouts->Release();
        }
        if (mode == L"wins" || mode == L"native-wins") {
            SendWinS();
        } else {
            if (mode == L"ctrlesc") SendCtrlEsc();
            else if (mode == L"startbutton") ClickTaskbarStartButton();
            else { ReleaseModifiers(); TapVirtualKey(VK_LWIN); }
            ULONGLONG deadline = GetTickCount64() + 1500;
            while ((!StartVisible() || !ShellForeground()) && GetTickCount64() < deadline) Sleep(5);
            if (!StartVisible() || !ShellForeground()) {
                std::puts("FAIL: Start not visibly open with shell foreground"); PrintForeground();
                CaptureDesktop();
                automation->Release(); CoUninitialize(); result = 1; return;
            }
        }
        if (mode == L"start" || mode == L"ctrlesc" || mode == L"startbutton") {
            Sleep(800);
            result = StartVisible() && ForegroundName() != L"Microsoft.CmdPal.UI.exe" ? 0 : 1;
            std::printf("start-only %s\n", result == 0 ? "PASS" : "FAIL");
        } else if (mode == L"click" || mode == L"native-click") {
            Sleep(300);
            result = 1;
            if (ClickSemanticStartSearch(automation)) {
                auto deadline = GetTickCount64() + 5000;
                std::wstring actual;
                while (GetTickCount64() < deadline) {
                    if (ReadLauncherText(automation, &actual, mode == L"native-click")) {
                        result = 0;
                        break;
                    }
                    Sleep(10);
                }
            }
            std::printf("search-click %s (no typing)\n", result == 0 ? "PASS" : "FAIL");
            if (result != 0) { PrintFocusedAutomation(); CaptureDesktop(); }
        } else {
            const auto begin = GetTickCount64();
            std::thread typer([&] { FastText(expected, 8); });
            ULONGLONG focusMs = 0, completeMs = 0;
            std::wstring actual;
            while (GetTickCount64() - begin < 5000) {
                if (ReadLauncherText(automation, &actual, mode == L"native-wins" || mode == L"native-typing")) {
                    if (!focusMs) focusMs = GetTickCount64() - begin;
                    if (actual == expected) { completeMs = GetTickCount64() - begin; break; }
                }
                Sleep(5);
            }
            typer.join();
            std::wprintf(L"mode=%ls focus_ms=%llu complete_ms=%llu expected=%ls actual=%ls\n",
                mode.c_str(), focusMs, completeMs, expected.c_str(), actual.c_str());
            result = completeMs ? 0 : 1;
            if (!completeMs) CaptureDesktop();
        }
        PrintForeground();
        // Dismiss only the test surface, not an unrelated foreground application.
        auto name = ForegroundName();
        if (name == L"Microsoft.CmdPal.UI.exe" || name == L"StartMenuExperienceHost.exe" || name == L"SearchHost.exe") TapVirtualKey(VK_ESCAPE);
        automation->Release();
        CoUninitialize();
    });
    while (!finished) PumpFor(10);
    worker.join();
    SetForegroundWindow(sinkWindow);
    RECT sinkRect = {};
    GetWindowRect(sinkEdit, &sinkRect);
    ClickPoint(sinkRect.left + 20, sinkRect.top + 15);
    PumpFor(500);
    wchar_t leaked[1024] = {};
    GetWindowTextW(sinkEdit, leaked, ARRAYSIZE(leaked));
    if (*leaked) { std::wprintf(L"FAIL: leaked input into previous window: %ls\n", leaked); result = 1; }
    DestroyWindow(sinkWindow);
    return result;
}
