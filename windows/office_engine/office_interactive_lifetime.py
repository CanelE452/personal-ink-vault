import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import stat
import threading
import time


class _FileInfo(ctypes.Structure):
    _fields_ = [('attributes', wintypes.DWORD), ('created', wintypes.FILETIME),
        ('accessed', wintypes.FILETIME), ('written', wintypes.FILETIME),
        ('volume', wintypes.DWORD), ('sizeHigh', wintypes.DWORD),
        ('sizeLow', wintypes.DWORD), ('links', wintypes.DWORD),
        ('indexHigh', wintypes.DWORD), ('indexLow', wintypes.DWORD)]


def kernel():
    value = ctypes.WinDLL('kernel32', use_last_error=True)
    value.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    value.OpenProcess.restype = wintypes.HANDLE
    value.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD,
        wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    value.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    value.WaitForSingleObject.restype = wintypes.DWORD
    value.CloseHandle.argtypes = [wintypes.HANDLE]
    value.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    value.CreateFileW.restype = wintypes.HANDLE
    value.GetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.POINTER(_FileInfo)]
    return value


def normalized(path):
    value = os.path.normcase(os.path.realpath(path))
    return value[4:] if value.startswith('\\\\?\\') else value


class ParentProcess:
    def __init__(self, pid, executable):
        self.api = kernel()
        self.handle = self.api.OpenProcess(0x100000 | 0x1000, False, pid)
        if not self.handle:
            raise OSError('The interactive parent could not be opened')
        try:
            size = wintypes.DWORD(32768)
            name = ctypes.create_unicode_buffer(size.value)
            if not self.api.QueryFullProcessImageNameW(self.handle, 0, name, ctypes.byref(size)):
                raise ctypes.WinError(ctypes.get_last_error())
            if normalized(name.value) != normalized(executable):
                raise ValueError('The interactive parent identity changed')
        except BaseException:
            self.close()
            raise

    def alive(self):
        status = self.api.WaitForSingleObject(self.handle, 0)
        if status not in (0, 258):
            raise ctypes.WinError(ctypes.get_last_error())
        return status == 258

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


class SessionLease:
    def __init__(self, request):
        self.request, self.api, self.handles = request, kernel(), []

    def _open(self, path, access, sharing, creation, flags, directory):
        handle = self.api.CreateFileW(str(path), access, sharing, None, creation, flags, None)
        if not handle or handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        self.handles.append(handle)
        info = _FileInfo()
        if not self.api.GetFileInformationByHandle(handle, ctypes.byref(info)):
            raise ctypes.WinError(ctypes.get_last_error())
        if info.attributes & 0x400 or bool(info.attributes & 0x10) != directory:
            raise ValueError('The session lease target is not plain')
        if not directory and (info.links != 1 or info.sizeHigh or info.sizeLow):
            raise ValueError('The session lock file must be a plain empty owned file')

    def __enter__(self):
        try:
            self._open(self.request.session, 0x80, 3, 3, 0x02000000 | 0x00200000, True)
            self._open(self.request.launch, 0x80, 3, 3, 0x02000000 | 0x00200000, True)
            self._open(self.request.session / 'interactive-editor.lock', 0x80000000 | 0x40000000,
                0, 4, 0x00200000, False)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def __exit__(self, *_):
        for handle in reversed(self.handles):
            self.api.CloseHandle(handle)
        self.handles.clear()


class Lifetime:
    def __init__(self, request):
        self.request = request
        self.cancelled = False
        self._parent = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._deadline = time.monotonic() + 90
        self._control_error = None

    def __enter__(self):
        self._parent = ParentProcess(self.request.data['parentProcessId'],
            self.request.data['parentExecutablePath'])
        self._thread = threading.Thread(target=self._watch, name='piv-interactive-owner', daemon=True)
        self._thread.start()
        return self

    def stage(self, _name, seconds):
        with self._lock:
            self._deadline = None if seconds is None else time.monotonic() + seconds

    def _watch(self):
        while not self._stop.wait(.1):
            try:
                with self._lock:
                    deadline = self._deadline
                if not self._parent.alive() or deadline is not None and time.monotonic() >= deadline:
                    os._exit(1)
                self._read_control()
            except BaseException:
                os._exit(1)

    def _read_control(self):
        path = self.request.launch / 'cancel.json'
        try:
            info = path.lstat()
        except FileNotFoundError:
            return
        except OSError:
            self._control_error, self.cancelled = 'interactive_invalid_control', True
            return
        if (not 0 < info.st_size <= 2048 or not stat.S_ISREG(info.st_mode) or
                info.st_nlink != 1 or getattr(info, 'st_file_attributes', 0) & 0x400 or
                path.is_symlink() or path.is_junction()):
            self._control_error, self.cancelled = 'interactive_invalid_control', True
            return
        try:
            with path.open('rb') as stream:
                raw = stream.read(2049)
            after = path.lstat()
            identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
            if len(raw) != info.st_size or len(raw) > 2048 or identity(info) != identity(after):
                raise ValueError('The control bytes changed during the read')
            def pairs(values):
                result = {}
                for key, value in values:
                    if key in result:
                        raise ValueError('Duplicate control key')
                    result[key] = value
                return result
            data = json.loads(raw.decode('utf-8'), object_pairs_hook=pairs)
        except (OSError, UnicodeError, ValueError):
            self._control_error, self.cancelled = 'interactive_invalid_control', True
            return
        expected = {'version': 1, 'sessionId': self.request.data['sessionId'],
            'controlNonce': self.request.data['controlNonce']}
        if type(data) is not dict or data != expected or type(data.get('version')) is not int:
            self._control_error, self.cancelled = 'interactive_invalid_control', True
            return
        self.cancelled = True

    def check(self):
        if not self._parent.alive():
            raise OSError('The interactive parent exited')

    def wait(self, seconds):
        self._stop.wait(min(seconds, .1))
        self.check()

    def __exit__(self, *_):
        self._stop.set()
        self._thread.join(1)
        self._parent.close()
