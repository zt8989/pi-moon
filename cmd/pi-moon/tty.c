// 与终端本身有关的三件小事。
//
// 1. stdin / stdout 是不是终端。
//    tui.mbt 的 `@io.is_tty()` 在 Windows 上会退到 CONIN$：管道输入时它仍然
//    返回 true，于是 `cat prompt.txt | pi-moon` 会被当成交互模式。这里只问
//    stdin / stdout 本身。
//
// 2. Windows 控制台的 ANSI 输出开关。
//    tui.mbt 只打开了输入的 VT 模式；输出侧的 `ENABLE_VIRTUAL_TERMINAL_PROCESSING`
//    在 Windows Terminal 里默认开，在旧 conhost 里不一定 —— 不打开的话整屏
//    都是转义序列的字面量。
//
// 3. 控制台代码页切到 UTF-8（退出时还原）。
//    tui.mbt 把 MoonBit 字符串按 UTF-8 字节写进控制台；中文系统的默认代码页是
//    936，于是「就绪」会显示成「灏辩华」。这件事必须在开屏之前做，之后每一帧
//    的宽字符（边框、CJK）都依赖它。

#include <stdio.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>

static int saved_console = 0;
static UINT saved_output_cp = 0;
static UINT saved_input_cp = 0;
static HANDLE saved_output_handle = INVALID_HANDLE_VALUE;
static DWORD saved_output_mode = 0;

int pi_stdin_is_tty(void) { return _isatty(_fileno(stdin)); }
int pi_stdout_is_tty(void) { return _isatty(_fileno(stdout)); }

void pi_enable_vt_output(void) {
  HANDLE handle = GetStdHandle(STD_OUTPUT_HANDLE);
  DWORD mode = 0;
  if (handle != INVALID_HANDLE_VALUE && GetConsoleMode(handle, &mode)) {
    if (!saved_console) {
      saved_output_handle = handle;
      saved_output_mode = mode;
    }
#ifdef ENABLE_VIRTUAL_TERMINAL_PROCESSING
    SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
#endif
  }
  if (!saved_console) {
    saved_output_cp = GetConsoleOutputCP();
    saved_input_cp = GetConsoleCP();
    saved_console = 1;
  }
  SetConsoleOutputCP(65001);
  SetConsoleCP(65001);
}

void pi_restore_vt_output(void) {
  if (!saved_console) return;
  SetConsoleOutputCP(saved_output_cp);
  SetConsoleCP(saved_input_cp);
  if (saved_output_handle != INVALID_HANDLE_VALUE) {
    SetConsoleMode(saved_output_handle, saved_output_mode);
  }
  saved_console = 0;
}
#else
#include <unistd.h>

int pi_stdin_is_tty(void) { return isatty(0); }
int pi_stdout_is_tty(void) { return isatty(1); }
void pi_enable_vt_output(void) {}
void pi_restore_vt_output(void) {}
#endif
