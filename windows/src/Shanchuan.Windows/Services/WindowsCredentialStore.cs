using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Shanchuan.Windows.Services;

public interface ICredentialStore
{
    string? Read();
    void Save(string password);
    void Delete();
}

/// <summary>Stores the FTP password in the current user's Windows Credential Manager vault.</summary>
public sealed class WindowsCredentialStore : ICredentialStore
{
    private const string Target = "Shanchuan/FTP";
    private const uint CredTypeGeneric = 1;
    private const uint CredPersistLocalMachine = 2;

    public string? Read()
    {
        if (!CredRead(Target, CredTypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            return error == 1168 ? null : throw new Win32Exception(error, "无法读取 Windows 凭据管理器。");
        }
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            if (credential.CredentialBlob == IntPtr.Zero || credential.CredentialBlobSize == 0) return "";
            return Marshal.PtrToStringUni(credential.CredentialBlob, checked((int)credential.CredentialBlobSize / 2));
        }
        finally { CredFree(pointer); }
    }

    public void Save(string password)
    {
        var bytes = Encoding.Unicode.GetBytes(password);
        var buffer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, buffer, bytes.Length);
            var credential = new Credential
            {
                Type = CredTypeGeneric,
                TargetName = Target,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = buffer,
                Persist = CredPersistLocalMachine,
                UserName = "FTP"
            };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastWin32Error(), "无法保存到 Windows 凭据管理器。");
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public void Delete()
    {
        if (!CredDelete(Target, CredTypeGeneric, 0))
        {
            var error = Marshal.GetLastWin32Error();
            if (error != 1168) throw new Win32Exception(error, "无法删除已保存的 FTP 密码。");
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public IntPtr Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string targetName, uint type, int reserved, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string targetName, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr credential);
}
