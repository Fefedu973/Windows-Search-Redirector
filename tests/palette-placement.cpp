#define SEARCH_REDIRECTOR_GEOMETRY_TEST
#include "../src/replace-windows-search.wh.cpp"
#include <cstdio>

static int failures = 0, checks = 0;
static void Check(POINT p, LONG x, LONG y, const char* name) {
    ++checks;
    if (p.x != x || p.y != y) {
        ++failures;
        std::printf("FAIL %s: (%ld,%ld), expected (%ld,%ld)\n", name, p.x, p.y, x, y);
    }
}

int main() {
    using namespace PalettePlacement;
    RECT work{0, 0, 1920, 1040}, window{300, 200, 1100, 800};
    const LONG xs[] = {16, 560, 1104}, ys[] = {16, 220, 424};
    for (int i = 0; i < 9; ++i) {
        Check(Calculate(static_cast<Mode>(int(Mode::TopLeft) + i), work, window, 16, 99, 99),
              xs[i % 3], ys[i / 3], "grid");
    }
    Check(Calculate(Mode::Default, work, window, 16, 0, 0), 300, 200, "default");
    Check(Calculate(ParseMode(L"unknown"), work, window, 16, 0, 0), 300, 200, "unknown");
    Check(Calculate(Mode::Custom, work, window, 16, 25, 75), 288, 322, "percentages");
    Check(Calculate(Mode::Custom, work, window, 16, -5, 120), 16, 424, "percent clamp");
    RECT negative{-1920, -200, 0, 840};
    Check(Calculate(Mode::BottomRight, negative, window, 16, 0, 0), -816, 224, "negative monitor");
    Check(Calculate(Mode::TopLeft, work, window, MulDiv(16, 192, 96), 0, 0), 32, 32, "200 percent DPI margin");
    RECT search{1100, 400, 1900, 450};
    Check(Calculate(Mode::FollowStart, work, window, 16, 0, 0, &search), 1100, 200, "follow Start");
    Check(Calculate(Mode::FollowStart, work, window, 16, 0, 0), 300, 200, "no Start fallback");
    RECT edge{0, 100, 500, 150};
    Check(Calculate(Mode::FollowStart, work, window, 16, 0, 0, &edge), 16, 200, "follow edge clamp");
    RECT huge{0, 0, 2000, 1200};
    Check(Calculate(Mode::BottomRight, work, huge, 200, 100, 100), 0, 0, "oversize");
    Check(Calculate(Mode::TopLeft, work, window, 900, 0, 0), 560, 220, "margin limited");
    RECT invalid{10, 10, 0, 0};
    Check(Calculate(Mode::TopLeft, invalid, window, 16, 0, 0), 300, 200, "invalid work area");
    std::printf("%d/%d geometry checks passed\n", checks - failures, checks);
    return failures ? 1 : 0;
}
