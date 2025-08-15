#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>

#if defined(__WIN32__)
#define EXE(name) name ".exe"
#else
#define EXE(name) name
#endif

static const char *get_c_compiler(void) {
    const char *cc = getenv("CC");
    return (cc == NULL) ? "cc" : cc;
}

static void panic(const char *reason) {
    fprintf(stderr, "%s\n", reason);
    abort();
}

#if defined(__WIN32__)

#include <windows.h>

static bool needs_quoting(const char *arg) {
    // Check if argument contains spaces or special characters that need quoting
    return strchr(arg, ' ') != NULL || strchr(arg, '\t') != NULL || 
           strchr(arg, '"') != NULL || strchr(arg, '\\') != NULL ||
           strchr(arg, '&') != NULL || strchr(arg, '|') != NULL ||
           strchr(arg, '<') != NULL || strchr(arg, '>') != NULL ||
           strchr(arg, '^') != NULL || strchr(arg, '%') != NULL;
}

static void run(char **argv) {
    static wchar_t cmdline[8000];
    int i;
    size_t pos = 0;
    
    // Build command line by concatenating arguments with spaces and selective quoting
    cmdline[0] = L'\0';
    
    for (i = 0; argv[i] && pos < sizeof(cmdline)/sizeof(wchar_t) - 1; ++i) {
        if (i > 0) {
            if (pos < sizeof(cmdline)/sizeof(wchar_t) - 2) {
                cmdline[pos++] = L' ';
                cmdline[pos] = L'\0';
            }
        }
        
        const char *arg = argv[i];
        bool quote_needed = needs_quoting(arg);
        
        // Add opening quote if needed
        if (quote_needed && pos < sizeof(cmdline)/sizeof(wchar_t) - 1) {
            cmdline[pos++] = L'"';
            cmdline[pos] = L'\0';
        }
        
        // Convert UTF-8 string to wide character
        int wide_len = MultiByteToWideChar(CP_UTF8, 0, arg, -1, NULL, 0);
        int space_needed = quote_needed ? 2 : 0; // space for quotes if needed
        if (wide_len > 0 && pos + wide_len + space_needed < sizeof(cmdline)/sizeof(wchar_t) - 1) {
            MultiByteToWideChar(CP_UTF8, 0, arg, -1, cmdline + pos, wide_len);
            pos += wide_len - 1; // -1 because MultiByteToWideChar includes null terminator
        }
        
        // Add closing quote if needed
        if (quote_needed && pos < sizeof(cmdline)/sizeof(wchar_t) - 1) {
            cmdline[pos++] = L'"';
            cmdline[pos] = L'\0';
        }
    }
        
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD exitCode;

    ZeroMemory(&si, sizeof(si));
    ZeroMemory(&pi, sizeof(pi));
    si.cb = sizeof(si);

    BOOL success = CreateProcessW(
        NULL,        // lpApplicationName
        cmdline,     // lpCommandLine
        NULL,        // lpProcessAttributes
        NULL,        // lpThreadAttributes
        FALSE,       // bInheritHandles
        0,           // dwCreationFlags
        NULL,        // lpEnvironment
        NULL,        // lpCurrentDirectory
        &si,         // lpStartupInfo
        &pi          // lpProcessInformation
    );

    if (!success) {
        DWORD error = GetLastError();
        // Convert wide string back to UTF-8 for debug output
        int utf8_len = WideCharToMultiByte(CP_UTF8, 0, cmdline, -1, NULL, 0, NULL, NULL);
        if (utf8_len > 0) {
            char *utf8_cmdline = malloc(utf8_len);
            if (utf8_cmdline) {
                WideCharToMultiByte(CP_UTF8, 0, cmdline, -1, utf8_cmdline, utf8_len, NULL, NULL);
                fprintf(stderr, "Command line: %s\n", utf8_cmdline);
                free(utf8_cmdline);
            }
        }
        fprintf(stderr, "CreateProcessW failed with error %lu\n", error);
        panic("CreateProcessW failed");
    }

    WaitForSingleObject(pi.hProcess, INFINITE);

    if (!GetExitCodeProcess(pi.hProcess, &exitCode)) {
        panic("GetExitCodeProcess failed");
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    if (exitCode != 0) {
        panic("child process failed");
    }
}


#else

#include <unistd.h>
#include <errno.h>
#include <sys/wait.h>

static void run(char **argv) {
    pid_t pid = fork();
    if (pid == -1)
        panic("fork failed");
    if (pid == 0) {
        // child
        execvp(argv[0], argv);
        exit(1);
    }

    // parent

    int status;
    waitpid(pid, &status, 0);

    if (!WIFEXITED(status))
        panic("child process crashed");

    if (WEXITSTATUS(status) != 0)
        panic("child process failed");
}
#endif

static void print_and_run(const char **argv) {
    fprintf(stderr, "%s", argv[0]);
    for (const char **arg = argv + 1; *arg; arg += 1) {
        fprintf(stderr, " %s", *arg);
    }
    fprintf(stderr, "\n");
    run((char **)argv);
}

static const char *get_host_os(void) {
    const char *host_os = getenv("ZIG_HOST_TARGET_OS");
    if (host_os != NULL) return host_os;
#if defined(__WIN32__)
    return "windows";
#elif defined(__APPLE__)
    return "macos";
#elif defined(__linux__)
    return "linux";
#elif defined(__FreeBSD__)
    return "freebsd";
#elif defined(__HAIKU__)
    return "haiku";
#else
    panic("unknown host os, specify with ZIG_HOST_TARGET_OS");
#endif
}

static const char *get_host_arch(void) {
    const char *host_arch = getenv("ZIG_HOST_TARGET_ARCH");
    if (host_arch != NULL) return host_arch;
#if defined(__x86_64__ )
    return "x86_64";
#elif defined(__aarch64__)
    return "aarch64";
#else
    panic("unknown host arch, specify with ZIG_HOST_TARGET_ARCH");
#endif
}

static const char *get_host_abi(void) {
    const char *host_abi = getenv("ZIG_HOST_TARGET_ABI");
    return (host_abi == NULL) ? "" : host_abi;
}

static const char *get_host_triple(void) {
    const char *host_triple = getenv("ZIG_HOST_TARGET_TRIPLE");
    if (host_triple != NULL) return host_triple;
    static char global_buffer[100];
    sprintf(global_buffer, "%s-%s%s", get_host_arch(), get_host_os(), get_host_abi());
    return global_buffer;
}

int main(int argc, char **argv) {
    const char *cc = get_c_compiler();
    const char *host_triple = get_host_triple();

    {
        const char *child_argv[] = {
            cc, "-o", EXE("zig-wasm2c"), "stage1/wasm2c.c", "-O2", "-std=c99", NULL,
        };
        print_and_run(child_argv);
    }
    {
        const char *child_argv[] = {

            EXE("./zig-wasm2c"), "stage1/zig1.wasm", "zig1.c", NULL,

        };
        print_and_run(child_argv);
    }
    {
        const char *child_argv[] = {
            cc, "-o", EXE("zig1"), "zig1.c", "stage1/wasi.c", "-std=c99", "-Os", "-lm", NULL,
        };
        print_and_run(child_argv);
    }
    {
        FILE *f = fopen("config.zig", "wb");
        if (f == NULL)
            panic("unable to open config.zig for writing");

        const char *zig_version = "0.14.0-dev.bootstrap";

        int written = fprintf(f,
            "pub const have_llvm = false;\n"
            "pub const llvm_has_m68k = false;\n"
            "pub const llvm_has_csky = false;\n"
            "pub const llvm_has_arc = false;\n"
            "pub const llvm_has_xtensa = false;\n"
            "pub const version: [:0]const u8 = \"%s\";\n"
            "pub const semver = @import(\"std\").SemanticVersion.parse(version) catch unreachable;\n"
            "pub const enable_debug_extensions = false;\n"
            "pub const enable_logging = false;\n"
            "pub const enable_link_snapshots = false;\n"
            "pub const enable_tracy = false;\n"
            "pub const value_tracing = false;\n"
            "pub const skip_non_native = false;\n"
            "pub const debug_gpa = false;\n"
            "pub const dev = .core;\n"
            "pub const value_interpret_mode = .direct;\n"
        , zig_version);
        if (written < 100)
            panic("unable to write to config.zig file");
        if (fclose(f) != 0)
            panic("unable to finish writing to config.zig file");
    }

    {
        const char *child_argv[] = {

            EXE("./zig1"), "lib", "build-exe",

            "-ofmt=c", "-lc", "-OReleaseSmall",
            "--name", "zig2", "-femit-bin=zig2.c",
            "-target", host_triple,
            "--dep", "build_options",
            "--dep", "aro",
            "-Mroot=src/main.zig",
            "-Mbuild_options=config.zig",
            "-Maro=lib/compiler/aro/aro.zig",
            NULL,
        };
        print_and_run(child_argv);
    }

    {
        const char *child_argv[] = {
            EXE("./zig1"), "lib", "build-obj",
            "-ofmt=c", "-ODebug",
            "--name", "compiler_rt", "-femit-bin=compiler_rt.c",
            "-target", host_triple,
            "-Mroot=lib/compiler_rt.zig",
            NULL,
        };
        print_and_run(child_argv);
    }

    {
        const char *child_argv[] = {
            cc, "-o", EXE("zig2"), "zig2.c", "compiler_rt.c",
            "-std=c99", "-O2", "-fno-stack-protector",
            "-Istage1",
#if defined(__APPLE__)
            "-Wl,-stack_size,0x10000000",
#else
            "-Wl,-z,stack-size=0x10000000",
#endif
#if defined(__GNUC__)
            "-pthread",
#endif
            NULL,
        };
        print_and_run(child_argv);
    }
}
