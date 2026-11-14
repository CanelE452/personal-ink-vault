if (-not ('PivOfficeWorkerJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class PivOfficeWorkerJob {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcess, PeakJob;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
        public uint Size;
        public string Reserved, Desktop, Title;
        public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
        public ushort Show, ReservedCount;
        public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
        public IntPtr Process, Thread;
        public uint Pid, ThreadId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits limits, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string executable, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint WaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint milliseconds);

    public static int Run(string executable, string arguments, string directory, uint timeout) {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        ProcessInfo process = new ProcessInfo();
        try {
            ExtendedLimits limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000;
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            StartupInfo startup = new StartupInfo();
            startup.Size = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.Flags = 1;
            startup.Show = 0;
            if (!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments),
                IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x08000000, IntPtr.Zero, directory, ref startup, out process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!AssignProcessToJobObject(job, process.Process)) {
                int error = Marshal.GetLastWin32Error();
                TerminateProcess(process.Process, 1);
                throw new Win32Exception(error);
            }
            if (ResumeThread(process.Thread) == 0xffffffff)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint waited = WaitForSingleObject(process.Process, timeout);
            if (waited == 0x102) throw new TimeoutException("The private Office worker timed out.");
            if (waited != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint code;
            if (!GetExitCodeProcess(process.Process, out code))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)code);
        } finally {
            CloseHandle(job);
            if (process.Process != IntPtr.Zero) {
                WaitForSingleObject(process.Process, 5000);
                CloseHandle(process.Process);
            }
            if (process.Thread != IntPtr.Zero) CloseHandle(process.Thread);
        }
    }

    static string ImagePath(string path) {
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path.Substring(8);
        else if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) path = path.Substring(4);
        return System.IO.Path.GetFullPath(path);
    }

    public static int RunParentBound(string executable, string arguments, string directory,
            uint parentPid, string parentExecutable) {
        if (parentPid == 0) throw new ArgumentOutOfRangeException("parentPid");
        IntPtr parent = OpenProcess(0x100000 | 0x1000, false, parentPid);
        if (parent == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        IntPtr job = IntPtr.Zero;
        ProcessInfo process = new ProcessInfo();
        try {
            StringBuilder image = new StringBuilder(32768);
            uint length = (uint)image.Capacity;
            if (!QueryFullProcessImageName(parent, 0, image, ref length))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!String.Equals(ImagePath(image.ToString()), ImagePath(parentExecutable), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The private Office worker parent identity changed.");
            uint parentState = WaitForSingleObject(parent, 0);
            if (parentState == 0) throw new InvalidOperationException("The private Office worker parent already exited.");
            if (parentState != 0x102) throw new Win32Exception(Marshal.GetLastWin32Error());
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ExtendedLimits limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000;
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            StartupInfo startup = new StartupInfo();
            startup.Size = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.Flags = 1;
            startup.Show = 0;
            if (!CreateProcess(executable, new StringBuilder("\"" + executable + "\" " + arguments),
                IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x08000000, IntPtr.Zero, directory, ref startup, out process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!AssignProcessToJobObject(job, process.Process)) {
                int error = Marshal.GetLastWin32Error();
                TerminateProcess(process.Process, 1);
                throw new Win32Exception(error);
            }
            parentState = WaitForSingleObject(parent, 0);
            if (parentState == 0) return 125;
            if (parentState != 0x102) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (ResumeThread(process.Thread) == 0xffffffff)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint waited = WaitForMultipleObjects(2, new IntPtr[] { process.Process, parent }, false, UInt32.MaxValue);
            if (waited == 1) return 125;
            if (waited != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint code;
            if (!GetExitCodeProcess(process.Process, out code))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)code);
        } finally {
            if (job != IntPtr.Zero) CloseHandle(job);
            if (process.Process != IntPtr.Zero) {
                WaitForSingleObject(process.Process, 5000);
                CloseHandle(process.Process);
            }
            if (process.Thread != IntPtr.Zero) CloseHandle(process.Thread);
            CloseHandle(parent);
        }
    }
}
'@
}
