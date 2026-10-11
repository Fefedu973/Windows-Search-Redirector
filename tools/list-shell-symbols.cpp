// Read-only PDB inspection. Does not load or execute shell DLL code.
#include <windows.h>
#include <dbghelp.h>
#include <cstdio>
#include <cwchar>

static BOOL CALLBACK PrintSymbol(PSYMBOL_INFOW symbol, ULONG, PVOID context) {
    auto filter = static_cast<const wchar_t*>(context);
    wchar_t decoded[8192] = {};
    const wchar_t* name = UnDecorateSymbolNameW(symbol->Name, decoded, 8192, UNDNAME_COMPLETE) ? decoded : symbol->Name;
    if (!filter || wcsstr(name, filter)) {
        std::wprintf(L"%08llx %ls\n", symbol->Address - symbol->ModBase, name);
    }
    return TRUE;
}

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) return 2;
    HANDLE process = GetCurrentProcess();
    SymSetOptions(SYMOPT_DEFERRED_LOADS | SYMOPT_FAIL_CRITICAL_ERRORS);
    if (!SymInitializeW(process, argv[2], FALSE)) return 3;
    DWORD64 module = SymLoadModuleExW(process, nullptr, argv[1], nullptr, 0, 0, nullptr, 0);
    if (!module) { std::printf("load error=%lu\n", GetLastError()); return 4; }
    BOOL ok = SymEnumSymbolsW(process, module, L"*", PrintSymbol, argc > 3 ? argv[3] : nullptr);
    if (!ok) std::printf("enum error=%lu\n", GetLastError());
    SymCleanup(process);
    return ok ? 0 : 5;
}
