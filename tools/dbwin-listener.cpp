#include <windows.h>
#include <cstdio>
#include <string>

struct DbWinBuffer {
    DWORD pid;
    char data[4096 - sizeof(DWORD)];
};

int wmain(int argc, wchar_t** argv) {
    const wchar_t* outPath = argc >= 2 ? argv[1] : L"dbwin.log";
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(DbWinBuffer), L"DBWIN_BUFFER");
    if (!mapping) {
        std::printf("CreateFileMapping failed %lu\n", GetLastError());
        return 1;
    }
    auto* buffer = static_cast<DbWinBuffer*>(MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, sizeof(DbWinBuffer)));
    if (!buffer) {
        std::printf("MapViewOfFile failed %lu\n", GetLastError());
        return 1;
    }
    HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, L"DBWIN_BUFFER_READY");
    HANDLE dataReady = CreateEventW(nullptr, FALSE, FALSE, L"DBWIN_DATA_READY");
    if (!ready || !dataReady) {
        std::printf("CreateEvent failed %lu\n", GetLastError());
        return 1;
    }
    FILE* f = nullptr;
    _wfopen_s(&f, outPath, L"ab");
    if (!f) return 1;
    DWORD start = GetTickCount();
    DWORD duration = argc >= 3 ? _wtoi(argv[2]) : 30000;
    while (GetTickCount() - start < duration) {
        SetEvent(ready);
        DWORD wait = WaitForSingleObject(dataReady, 500);
        if (wait == WAIT_OBJECT_0) {
            SYSTEMTIME st;
            GetLocalTime(&st);
            std::fprintf(f, "%02u:%02u:%02u.%03u %lu %s\n", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, buffer->pid, buffer->data);
            std::fflush(f);
        }
    }
    fclose(f);
    return 0;
}
