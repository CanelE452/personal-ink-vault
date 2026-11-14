import ctypes
from ctypes import wintypes
import subprocess


class _BasicLimits(ctypes.Structure):
    _fields_ = [("processTime", ctypes.c_longlong), ("jobTime", ctypes.c_longlong),
                ("flags", wintypes.DWORD), ("minWorkingSet", ctypes.c_size_t),
                ("maxWorkingSet", ctypes.c_size_t), ("activeProcesses", wintypes.DWORD),
                ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD),
                ("scheduling", wintypes.DWORD)]


class _IoCounters(ctypes.Structure):
    _fields_ = [(name, ctypes.c_ulonglong) for name in
                ["readOps", "writeOps", "otherOps", "readBytes", "writeBytes", "otherBytes"]]


class _ExtendedLimits(ctypes.Structure):
    _fields_ = [("basic", _BasicLimits), ("io", _IoCounters),
                ("processMemory", ctypes.c_size_t), ("jobMemory", ctypes.c_size_t),
                ("peakProcess", ctypes.c_size_t), ("peakJob", ctypes.c_size_t)]


class _StartupInfo(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("reserved", wintypes.LPWSTR),
                ("desktop", wintypes.LPWSTR), ("title", wintypes.LPWSTR),
                *[(name, wintypes.DWORD) for name in ["x", "y", "xSize", "ySize", "xChars", "yChars", "fill", "flags"]],
                ("show", wintypes.WORD), ("reservedCount", wintypes.WORD),
                ("reservedBytes", ctypes.POINTER(ctypes.c_byte)),
                ("input", wintypes.HANDLE), ("output", wintypes.HANDLE), ("error", wintypes.HANDLE)]


class _ProcessInfo(ctypes.Structure):
    _fields_ = [("process", wintypes.HANDLE), ("thread", wintypes.HANDLE),
                ("pid", wintypes.DWORD), ("threadId", wintypes.DWORD)]


class OwnedOfficeProcess:
    """Start suspended, assign an owned kill-on-close Job, then resume."""

    def __init__(self, executable, arguments, directory, *, show_window=False):
        if type(show_window) is not bool:
            raise TypeError("show_window must be a boolean")
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self.kernel.CreateJobObjectW.restype = wintypes.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.TerminateJobObject.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        self.kernel.ResumeThread.argtypes = [wintypes.HANDLE]
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        self.kernel.CreateProcessW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR,
            ctypes.c_void_p, ctypes.c_void_p, wintypes.BOOL, wintypes.DWORD,
            ctypes.c_void_p, wintypes.LPCWSTR, ctypes.POINTER(_StartupInfo), ctypes.POINTER(_ProcessInfo)]
        self.job = self.kernel.CreateJobObjectW(None, None)
        if not self.job:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = _ExtendedLimits()
        limits.basic.flags = 0x2000
        if not self.kernel.SetInformationJobObject(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.get_last_error()
            self.close()
            raise ctypes.WinError(error)
        startup = _StartupInfo()
        startup.cb = ctypes.sizeof(startup)
        startup.flags = 1
        startup.show = 1 if show_window else 0
        info = _ProcessInfo()
        command = ctypes.create_unicode_buffer(subprocess.list2cmdline([str(executable), *arguments]))
        if not self.kernel.CreateProcessW(str(executable), command, None, None, False,
                0x00000004 | 0x08000000, None, str(directory), ctypes.byref(startup), ctypes.byref(info)):
            error = ctypes.get_last_error()
            self.close()
            raise ctypes.WinError(error)
        self.process = info.process
        self.pid = info.pid
        try:
            if not self.kernel.AssignProcessToJobObject(self.job, self.process):
                error = ctypes.get_last_error()
                self.kernel.TerminateProcess(self.process, 1)
                raise ctypes.WinError(error)
            if self.kernel.ResumeThread(info.thread) == 0xffffffff:
                raise ctypes.WinError(ctypes.get_last_error())
        except BaseException:
            self.close()
            raise
        finally:
            self.kernel.CloseHandle(info.thread)

    def exit_code(self):
        code = wintypes.DWORD()
        if not self.kernel.GetExitCodeProcess(self.process, ctypes.byref(code)):
            raise ctypes.WinError(ctypes.get_last_error())
        return None if code.value == 259 else code.value

    def close(self):
        if getattr(self, "job", None):
            self.kernel.CloseHandle(self.job)
            self.job = None
        if getattr(self, "process", None):
            self.kernel.WaitForSingleObject(self.process, 5000)
            self.kernel.CloseHandle(self.process)
            self.process = None
