#requires -Version 5.1
# The parent owns this session and all host-file authority. The child only uses RPC.
function Get-ApplicationRpcClientSource {
    return @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace OptiMiyoo {
 public static class ApplicationRpcClient {
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr value);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int info,IntPtr data,uint bytes,out uint returned);
  private static bool Confined(){IntPtr token;if(!OpenProcessToken(GetCurrentProcess(),8,out token))return false;try{uint returned;IntPtr flag=Marshal.AllocHGlobal(4);try{if(!GetTokenInformation(token,29,flag,4,out returned)||Marshal.ReadInt32(flag)!=1)return false;}finally{Marshal.FreeHGlobal(flag);}uint bytes;GetTokenInformation(token,30,IntPtr.Zero,0,out bytes);if(bytes<4||bytes>65536)return false;IntPtr caps=Marshal.AllocHGlobal((int)bytes);try{return GetTokenInformation(token,30,caps,bytes,out returned)&&Marshal.ReadInt32(caps)==0;}finally{Marshal.FreeHGlobal(caps);}}finally{CloseHandle(token);}}
  public static bool IsIsolated {get{return request!=null&&response!=null&&Confined();}}
  public static string WorkPath {get;private set;}
  private const int Limit=1048576;
  private static readonly object Gate=new object();
  private static readonly UTF8Encoding Utf8=new UTF8Encoding(false,true);
  private static FileStream request,response;
  private static uint nextId;
  public static void Initialize(long requestHandle,long responseHandle){lock(Gate){if(!Confined()||request!=null||requestHandle<=0||responseHandle<=0||requestHandle==responseHandle)throw new InvalidOperationException("Invalid application broker handles.");string work=Environment.GetEnvironmentVariable("OPTIMIYOO_SESSION_WORK");if(String.IsNullOrEmpty(work)||!Path.IsPathRooted(work)||!Directory.Exists(work))throw new IOException("Application work directory is unavailable.");WorkPath=Path.GetFullPath(work);request=new FileStream(new SafeFileHandle(new IntPtr(requestHandle),true),FileAccess.Write);response=new FileStream(new SafeFileHandle(new IntPtr(responseHandle),true),FileAccess.Read);}}
  private static byte[] Read(int size){byte[] data=new byte[size];int done=0;while(done<size){int n=response.Read(data,done,size-done);if(n==0)throw new IOException("Application broker disconnected.");done+=n;}return data;}
  public static string Call(string operation,string payload){lock(Gate){
   if(request==null)throw new InvalidOperationException("Application broker is not initialized.");
   if(String.IsNullOrEmpty(operation)||operation.Length>64)throw new IOException("Invalid application broker operation.");foreach(char c in operation)if(!(c>='A'&&c<='Z')&&!(c>='a'&&c<='z')&&!(c>='0'&&c<='9')&&c!='.')throw new IOException("Invalid application broker operation.");
   byte[] name=Utf8.GetBytes(operation),data=Utf8.GetBytes(payload??"null");if(data.Length+name.Length+6>Limit||nextId==UInt32.MaxValue)throw new IOException("Application broker request limit exceeded.");uint id=++nextId;byte[] header=new byte[10];Buffer.BlockCopy(BitConverter.GetBytes((uint)(6+name.Length+data.Length)),0,header,0,4);Buffer.BlockCopy(BitConverter.GetBytes(id),0,header,4,4);Buffer.BlockCopy(BitConverter.GetBytes((ushort)name.Length),0,header,8,2);request.Write(header,0,header.Length);request.Write(name,0,name.Length);request.Write(data,0,data.Length);request.Flush();
   uint length=BitConverter.ToUInt32(Read(4),0);if(length<5||length>Limit)throw new IOException("Invalid application broker response length.");byte[] body=Read((int)length);if(BitConverter.ToUInt32(body,0)!=id||(body[4]!=0&&body[4]!=1))throw new IOException("Application broker response does not match request.");string result=Utf8.GetString(body,5,body.Length-5);if(body[4]==0)throw new IOException("Application broker rejected the operation: "+result);return result;
  }}
 }
}
'@
}

function Initialize-ApplicationSession {
    if ('OptiMiyoo.ApplicationSession' -as [type]) {return}
    . (Join-Path $PSScriptRoot '../shared/source_policy.ps1')
    Initialize-SourcePolicyNative
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
using System.Diagnostics;
using Microsoft.Win32.SafeHandles;

namespace OptiMiyoo {
 // Size the owning console once, before any display or isolated session starts.
 // Terminal hosts receive a size request; native consoles use their work area.
 public static class ApplicationConsoleWindow {
  [StructLayout(LayoutKind.Sequential)] struct Rectangle {public int Left,Top,Right,Bottom;}
  [StructLayout(LayoutKind.Sequential)] struct Monitor {public int Size;public Rectangle Bounds,Work;public uint Flags;}
  [StructLayout(LayoutKind.Sequential)] struct Coordinate {public short X,Y;}
  [StructLayout(LayoutKind.Sequential)] struct Font {public uint Index;public Coordinate Size;}
  [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
  [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
  [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr handle,uint mode);
  [DllImport("kernel32.dll")] static extern bool GetCurrentConsoleFont(IntPtr output,bool maximum,out Font font);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr window);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window,out Rectangle rectangle);
  [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr window,out Rectangle rectangle);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr window,uint flags);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor,ref Monitor info);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int width,int height,uint flags);
  // Only the trusted interactive host owns the alternate screen. Workers
  // cannot switch buffers through their filtered terminal output.
  public static IDisposable OpenScreen() {
   try {
    if(Console.IsInputRedirected||Console.IsOutputRedirected)return null;
    IntPtr output=GetStdHandle(-11);uint mode;
    if(!GetConsoleMode(output,out mode))return null;
    bool cursor=true;try{cursor=Console.CursorVisible;}catch{}
    if(!SetConsoleMode(output,mode|4))return null;
    ScreenLease lease=new ScreenLease(output,mode,cursor);
    try {Console.Write("\x1b[?1049h");return lease;}
    catch {lease.Dispose();return null;}
   } catch {return null;}
  }
  sealed class ScreenLease : IDisposable {
   readonly IntPtr output;readonly uint mode;readonly bool cursor;bool disposed;
   public ScreenLease(IntPtr output,uint mode,bool cursor){this.output=output;this.mode=mode;this.cursor=cursor;}
   public void Dispose(){
    if(disposed)return;disposed=true;
    try {Console.Write("\x1b[0m\x1b[r\x1b[?1049l"+(cursor?"\x1b[?25h":"\x1b[?25l"));}
    catch {} finally {try{SetConsoleMode(output,mode);}catch{}}
   }
  }
  public static void EnsureRoom() {
   try {
    if(Console.IsInputRedirected||Console.IsOutputRedirected)return;
    IntPtr window=GetConsoleWindow();Rectangle bounds;
    if(window==IntPtr.Zero||!IsWindowVisible(window)||!GetWindowRect(window,out bounds)||bounds.Right<=bounds.Left||bounds.Bottom<=bounds.Top) {
     // Windows Terminal 1.23+ honors XTWINOPS; older hosts can ignore it.
     // Request only at startup, never on a later user resize or screen change.
     if(Console.WindowHeight>=35&&Console.WindowWidth>=100)return;
     IntPtr output=GetStdHandle(-11);uint mode;
     if(!GetConsoleMode(output,out mode)||!SetConsoleMode(output,mode|4))return;
     try {Console.Write("\x1b[8;"+Math.Max(35,Console.WindowHeight)+";"+Math.Max(100,Console.WindowWidth)+"t");}
     finally {SetConsoleMode(output,mode);}
     return;
    }
    if(IsZoomed(window))return;
    Rectangle client;Font font;Monitor monitor=new Monitor();monitor.Size=Marshal.SizeOf(typeof(Monitor));
    if(!GetWindowRect(window,out bounds)||!GetClientRect(window,out client)||!GetCurrentConsoleFont(GetStdHandle(-11),false,out font)||font.Size.X<=0||font.Size.Y<=0||!GetMonitorInfo(MonitorFromWindow(window,2),ref monitor))return;
    int frameWidth=(bounds.Right-bounds.Left)-(client.Right-client.Left);
    int frameHeight=(bounds.Bottom-bounds.Top)-(client.Bottom-client.Top);
    // Work excludes the taskbar. Leave a small margin on every side as well.
    int maxWidth=Math.Min(Console.LargestWindowWidth,(monitor.Work.Right-monitor.Work.Left-frameWidth-16)/font.Size.X);
    int maxHeight=Math.Min(Console.LargestWindowHeight,(monitor.Work.Bottom-monitor.Work.Top-frameHeight-16)/font.Size.Y);
    if(maxWidth<20||maxHeight<10)return;
    int width=Math.Min(maxWidth,Math.Max(100,Console.WindowWidth));
    int height=Math.Min(maxHeight,Math.Max(35,Console.WindowHeight));
    if(width>Console.BufferWidth||height>Console.BufferHeight)Console.SetBufferSize(Math.Max(width,Console.BufferWidth),Math.Max(height,Console.BufferHeight));
    if(width!=Console.WindowWidth||height!=Console.WindowHeight)Console.SetWindowSize(width,height);
    if(GetWindowRect(window,out bounds)) {
     int x=Math.Max(monitor.Work.Left+8,Math.Min(bounds.Left,monitor.Work.Right-8-(bounds.Right-bounds.Left)));
     int y=Math.Max(monitor.Work.Top+8,Math.Min(bounds.Top,monitor.Work.Bottom-8-(bounds.Bottom-bounds.Top)));
     if(x!=bounds.Left||y!=bounds.Top)SetWindowPos(window,IntPtr.Zero,x,y,0,0,0x15);
    }
   } catch { /* A restricted host keeps its existing responsive layout. */ }
  }
 }
 public sealed class ApplicationRequest {
  public uint Id {get;internal set;}
  public string Operation {get;internal set;}
  public string Payload {get;internal set;}
 }
 // Stateful across chunks: unrecognized control strings never reach the host terminal.
 public sealed class TerminalSequenceFilter {
  private int state;
  private readonly StringBuilder sequence=new StringBuilder();
  public void Reset(){state=0;sequence.Length=0;}
  public string Feed(string text){
   StringBuilder output=new StringBuilder(text.Length);
   foreach(char c in text){
    if(state==3||state==4){if(c=='\a'||c=='\u009c'){state=0;}else if(c=='\x1b'){state=5;}continue;}
    if(state==5){if(c=='\\'||c=='\u009c'||c=='\a')state=0;else if(c!='\x1b')state=3;continue;}
    if(state==1){if(c=='['){state=2;sequence.Length=0;}else if(c==']'||c=='P'||c=='X'||c=='^'||c=='_'){state=3;}else{if(c=='7'||c=='8'||c=='D'||c=='E'||c=='M')output.Append('\x1b').Append(c);state=0;}continue;}
    if(state==2){
     if(c>='@'&&c<='~'){string value=sequence.ToString();if(Allowed(value,c))output.Append("\x1b[").Append(value).Append(c);state=0;sequence.Length=0;}
     else if((c>='0'&&c<='9')||c==';'||c==':'||c=='?'){if(sequence.Length<128)sequence.Append(c);else{state=6;sequence.Length=0;}}
     else if(c=='\x1b'){state=1;sequence.Length=0;}else{state=6;sequence.Length=0;}continue;
    }
    if(state==6){if(c>='@'&&c<='~')state=0;else if(c=='\x1b')state=1;continue;}
    if(c=='\x1b'){state=1;continue;}if(c=='\u009b'){state=2;sequence.Length=0;continue;}if(c=='\u009d'||c=='\u0090'||c=='\u0098'||c=='\u009e'||c=='\u009f'){state=3;continue;}
    if(c=='\r'||c=='\n'||c=='\t'||c=='\b'||(c>=' '&&(c<'\u007f'||c>'\u009f')))output.Append(c);
   }
   return output.ToString();
  }
  private static bool Allowed(string p,char final){
   if(p.StartsWith("?",StringComparison.Ordinal))return p=="?25"&&(final=='h'||final=='l');
   if(p.IndexOf('?')>=0)return false;
   if(final=='m')return true;
   if(p.IndexOf(':')>=0)return false;
   string[] parts=p.Split(';');foreach(string part in parts){int n;if(part.Length!=0&&(!Int32.TryParse(part,out n)||n<0||n>4096))return false;}
   if(final=='J'||final=='K')return parts.Length==1&&(p==""||p=="0"||p=="1"||p=="2");
   if(final=='H'||final=='f'||final=='r')return parts.Length<=2;
   if(final=='s'||final=='u')return p.Length==0;
   return parts.Length==1&&"ABCDEFGSTLMPX@ade".IndexOf(final)>=0;
  }
 }
 public sealed class ApplicationSession : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct SA {public int n;public IntPtr descriptor;public int inherit;}
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct SI {public int cb;public string reserved,desktop,title;public int x,y,cx,cy,cxc,cyc,fill,flags;public short show,reserved2;public IntPtr reservedp,input,output,error;}
  [StructLayout(LayoutKind.Sequential)] struct SIX {public SI si;public IntPtr attributes;}
  [StructLayout(LayoutKind.Sequential)] struct PI {public IntPtr process,thread;public uint pid,tid;}
  [StructLayout(LayoutKind.Sequential)] struct COORD {public short X,Y;}
  [StructLayout(LayoutKind.Sequential)] struct Capabilities {public IntPtr sid,capabilities;public uint count,reserved;}
  [StructLayout(LayoutKind.Sequential)] struct JobBasic {public long processTime,jobTime;public uint flags;public UIntPtr min,max;public uint active;public UIntPtr affinity;public uint priority,scheduling;}
  [StructLayout(LayoutKind.Sequential)] struct IOCounts {public ulong read,write,other,readBytes,writeBytes,otherBytes;}
  [StructLayout(LayoutKind.Sequential)] struct JobExtended {public JobBasic basic;public IOCounts io;public UIntPtr processMemory,jobMemory,peakProcess,peakJob;}
  [StructLayout(LayoutKind.Sequential)] struct FileInformation {public uint attributes;public System.Runtime.InteropServices.ComTypes.FILETIME creation,access,write;public uint volume,sizeHigh,sizeLow,links,indexHigh,indexLow;}
  [DllImport("userenv.dll",CharSet=CharSet.Unicode)] static extern int CreateAppContainerProfile(string name,string display,string description,IntPtr caps,uint count,out IntPtr sid);
  [DllImport("userenv.dll",CharSet=CharSet.Unicode)] static extern int DeleteAppContainerProfile(string name);
  [DllImport("advapi32.dll")] static extern IntPtr FreeSid(IntPtr sid);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string value,uint revision,out IntPtr descriptor,out uint size);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern uint SetNamedSecurityInfo(string path,int kind,uint information,IntPtr owner,IntPtr group,IntPtr dacl,IntPtr sacl);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetSecurityDescriptorDacl(IntPtr descriptor,out bool present,out IntPtr acl,out bool defaulted);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetSecurityDescriptorSacl(IntPtr descriptor,out bool present,out IntPtr acl,out bool defaulted);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr bytes);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr bytes,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr psa,IntPtr tsa,bool inherit,uint flags,IntPtr environment,string cwd,ref SIX startup,out PI result);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SA attributes,uint size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr sa,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,ref JobExtended value,uint size);
  [DllImport("kernel32.dll",EntryPoint="SetInformationJobObject",SetLastError=true)] static extern bool SetUiRestrictions(IntPtr job,int info,ref uint value,uint size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint ms);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int info,IntPtr data,uint bytes,out uint returned);
  [DllImport("kernel32.dll")] static extern int CreatePseudoConsole(COORD size,IntPtr input,IntPtr output,uint flags,out IntPtr console);
  [DllImport("kernel32.dll")] static extern int ResizePseudoConsole(IntPtr console,COORD size);
  [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr console);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool PeekNamedPipe(SafeFileHandle pipe,IntPtr buffer,uint bytes,IntPtr read,out uint available,IntPtr remaining);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr sa,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FileInformation info);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr sourceProcess,IntPtr sourceHandle,IntPtr targetProcess,out IntPtr targetHandle,uint desired,bool inherit,uint options);
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetConsoleMode(IntPtr handle,out uint mode);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetConsoleMode(IntPtr handle,uint mode);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool FlushConsoleInputBuffer(IntPtr handle);

  [StructLayout(LayoutKind.Explicit,CharSet=CharSet.Unicode,Size=20)] struct InputRecord {
   [FieldOffset(0)] public ushort EventType;[FieldOffset(4)] public int KeyDown;[FieldOffset(8)] public ushort Repeat;[FieldOffset(10)] public ushort VirtualKey;[FieldOffset(12)] public ushort ScanCode;[FieldOffset(14)] public char Character;[FieldOffset(16)] public uint Control;
  }
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetNumberOfConsoleInputEvents(IntPtr handle,out uint count);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ReadConsoleInput(IntPtr handle,[Out] InputRecord[] records,uint length,out uint read);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool WriteConsole(IntPtr handle,string text,uint length,out uint written,IntPtr reserved);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CancelIoEx(SafeFileHandle handle,IntPtr overlapped);
  public const int MaximumFrameBytes=1048576;
  private static readonly UTF8Encoding Utf8=new UTF8Encoding(false,true);
  private readonly object consoleGate=new object(),rpcGate=new object(),inputGate=new object(),eventGate=new object();
  private readonly Queue<ApplicationRequest> requests=new Queue<ApplicationRequest>();
  private readonly AutoResetEvent requestReady=new AutoResetEvent(false);
  private readonly AutoResetEvent inputReady=new AutoResetEvent(false);
  private int eventWaiters;
  private bool eventDisposalRequested,eventHandlesClosed;
  private readonly Queue<string> inputQueue=new Queue<string>();
  private int queuedInputCharacters;
  private char pendingInputHighSurrogate;
  private readonly TerminalSequenceFilter filter=new TerminalSequenceFilter();
  private readonly object outcomeGate=new object();
  private readonly List<SafeFileHandle> pins=new List<SafeFileHandle>();
  private IDisposable parentLease;
  private IntPtr process,job,pseudo,sid;
  private string profile,controlPath,rootIdentity;
  private FileStream terminalOutput,terminalInput,requestInput,responseOutput;
  private SafeFileHandle terminalReadHandle;
  private StreamWriter keyWriter;
  private Thread outputThread,inputThread,inputWriterThread,rpcThread;
  private HashSet<string> operations;
  private volatile bool stopping,paused;
  private bool started,disposed,consoleSaved;
  private uint previousInputMode,previousOutputMode,lastRequest,pendingResponse;
  private string previousTitle;
  private ConsoleColor previousForeground,previousBackground;
  private bool previousControlC,previousCursor;
  private long lastOutput,lastDrained,pauseStarted;
  private int outputInFlight;
  private int cleanupEntryLimit=120000;
  private short columns,rows;
  public string RootPath {get;private set;}
  public string CodePath {get;private set;}
  public string WorkPath {get;private set;}
  public string CleanupWarning {get;private set;}
  public string Failure {get;private set;}
  public uint ProcessId {get;private set;}
  public bool IsAppContainer {get;private set;}
  public bool IsRelayPaused {get{return paused;}}
  public bool CancellationRequested {get;private set;}
  public bool Interactive {get;set;}
  public int StagedEntryCount {get;private set;}
  public int CleanupEntryLimit {get{return cleanupEntryLimit;}}
  public int MemoryLimitMiB {get;set;}
  public int CpuTimeLimitSeconds {get;set;}
  public bool HasExited {get{return process!=IntPtr.Zero&&WaitForSingleObject(process,0)==0;}}
  public int ExitCode {get{uint value=0;Check(process!=IntPtr.Zero&&GetExitCodeProcess(process,out value),"Read application exit code");return unchecked((int)value);}}
  public bool WaitForExit(int milliseconds){return process!=IntPtr.Zero&&WaitForSingleObject(process,unchecked((uint)milliseconds))==0;}
  private static void Check(bool ok,string where){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error(),where);}
  private static void Close(ref IntPtr handle){if(handle!=IntPtr.Zero){CloseHandle(handle);handle=IntPtr.Zero;}}
  private static IntPtr Value<T>(T value){IntPtr p=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(T)));Marshal.StructureToPtr(value,p,false);return p;}
  private static void Attribute(IntPtr list,int id,IntPtr value,int bytes){Check(UpdateProcThreadAttribute(list,0,new IntPtr(id),value,new IntPtr(bytes),IntPtr.Zero,IntPtr.Zero),"Configure application process attribute");}
  private static Type PolicyType(){foreach(System.Reflection.Assembly a in AppDomain.CurrentDomain.GetAssemblies()){Type t=a.GetType("OptiMiyoo.SourceRemovalLeaseV128",false);if(t!=null)return t;}throw new IOException("Verified source policy helper is unavailable.");}
  private static object Policy(string name,params object[] args){try{return PolicyType().GetMethod(name,System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static).Invoke(null,args);}catch(System.Reflection.TargetInvocationException e){throw e.InnerException??e;}}
  private static string NativePath(string path){
   string full=Path.GetFullPath(path);
   if(full.StartsWith(@"\\?\",StringComparison.Ordinal)||full.StartsWith(@"\\.\",StringComparison.Ordinal))throw new IOException("Device paths are not supported.");
   return full.StartsWith(@"\\",StringComparison.Ordinal)?@"\\?\UNC\"+full.Substring(2):@"\\?\"+full;
  }
  private static void Secure(string path,string package,bool write){
   string user=WindowsIdentity.GetCurrent().User.Value;
   string sddl="D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+user+")(A;OICI;"+(write?"0x1301bf":"0x1200a9")+";;;"+package+")"+(write?"S:(ML;OICI;NW;;;LW)":"");
   IntPtr sd;uint size;Check(ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out sd,out size),"Prepare application ACL");
   try{bool present,defaulted;IntPtr dacl,sacl;Check(GetSecurityDescriptorDacl(sd,out present,out dacl,out defaulted),"Read application DACL");Check(GetSecurityDescriptorSacl(sd,out present,out sacl,out defaulted),"Read application SACL");uint status=SetNamedSecurityInfo(NativePath(path),1,0x80000004u|(write?0x10u:0u),IntPtr.Zero,IntPtr.Zero,dacl,sacl);if(status!=0)throw new Win32Exception((int)status,"Protect application staging");}finally{LocalFree(sd);}
  }
  private void Pin(string path,bool directory){
   SafeFileHandle h=CreateFile(NativePath(path),directory?1u:0x80000000u,directory?3u:1u,IntPtr.Zero,3,0x00200000u|(directory?0x02000000u:0u),IntPtr.Zero);
   if(h.IsInvalid){h.Dispose();throw new Win32Exception(Marshal.GetLastWin32Error(),"Pin application staging");}
   try{FileInformation info;Check(GetFileInformationByHandle(h,out info),"Inspect application staging");if((info.attributes&0x400)!=0||((info.attributes&0x10)!=0)!=directory||(!directory&&info.links!=1))throw new IOException("Application staging must contain ordinary unlinked files/directories.");if(directory&&path==RootPath&&rootIdentity==null)rootIdentity=info.volume.ToString("X8")+":"+info.indexHigh.ToString("X8")+info.indexLow.ToString("X8");pins.Add(h);}catch{h.Dispose();throw;}
  }
  private void PinTree(string path){Queue<string> queue=new Queue<string>();queue.Enqueue(path);int count=0;long bytes=0;while(queue.Count>0){string current=queue.Dequeue();if(++count>12000)throw new IOException("Application code staging has too many entries.");FileAttributes attr=File.GetAttributes(current);bool directory=(attr&FileAttributes.Directory)!=0;Pin(current,directory);if(directory){foreach(string child in Directory.EnumerateFileSystemEntries(current)){if(queue.Count+count>=12000)throw new IOException("Application code staging has too many entries.");queue.Enqueue(child);}}else{long length=new FileInfo(current).Length;if(length>268435456L||(bytes+=length)>1073741824L)throw new IOException("Application code staging exceeds its size limit.");}}}
  public static ApplicationSession Create(){
   ApplicationSession result=new ApplicationSession();result.Interactive=!Console.IsInputRedirected&&!Console.IsOutputRedirected;result.MemoryLimitMiB=1024;result.CpuTimeLimitSeconds=1800;
   try{
    string temp=Path.GetFullPath(Path.GetTempPath());if(temp.StartsWith("\\\\",StringComparison.Ordinal)||!String.Equals(new DriveInfo(Path.GetPathRoot(temp)).DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase))throw new IOException("Application isolation needs a local NTFS temporary directory.");
    result.parentLease=(IDisposable)Policy("OpenDirectory",temp);
    string root=Path.Combine(temp,"as_"+Guid.NewGuid().ToString("N").Substring(0,16));if(root.Length+2>247)throw new IOException("Application working path is too long. Move OptiMiyoo to a shorter folder, then retry. Originals kept.");Policy("CreateOwnedDirectory",root);result.RootPath=root;Secure(result.RootPath,"S-1-0-0",false);result.Pin(result.RootPath,true);
    result.CodePath=Path.Combine(result.RootPath,"c");result.WorkPath=Path.Combine(result.RootPath,"w");result.controlPath=Path.Combine(result.RootPath,"p");Directory.CreateDirectory(result.CodePath);Directory.CreateDirectory(result.WorkPath);Directory.CreateDirectory(result.controlPath);result.Pin(result.WorkPath,true);return result;
   }catch{result.Dispose();throw;}
  }
  private string CodeFile(string relative){if(String.IsNullOrEmpty(relative)||Path.IsPathRooted(relative)||relative.IndexOf(':')>=0)throw new IOException("A relative staged code path is required.");string full=Path.GetFullPath(Path.Combine(CodePath,relative));if(!full.StartsWith(CodePath+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)||!File.Exists(full))throw new IOException("Application code is outside its staging root.");return full;}
  private static string PsQuote(string text){return "'"+text.Replace("'","''")+"'";}
  public void Start(string entryRelativePath,string[] assemblyRelativePaths,string[] allowedOperations){
   if(started||disposed)throw new InvalidOperationException("Application sessions can start only once.");
   if(MemoryLimitMiB<128||MemoryLimitMiB>4096||CpuTimeLimitSeconds<1||CpuTimeLimitSeconds>7200)throw new ArgumentOutOfRangeException("Application job limits");
   if(Interactive&&(Console.IsInputRedirected||Console.IsOutputRedirected))throw new IOException("Application isolation needs an interactive console.");
   started=true;operations=new HashSet<string>(StringComparer.Ordinal);if(allowedOperations==null||allowedOperations.Length>64)throw new IOException("A bounded operation allowlist is required.");foreach(string op in allowedOperations){ValidateOperation(op);if(!operations.Add(op))throw new IOException("Duplicate broker operation.");}
   string entry=CodeFile(entryRelativePath);StringBuilder bootstrap=new StringBuilder("$ErrorActionPreference='Stop'\r\n");
   if(assemblyRelativePaths==null||assemblyRelativePaths.Length>64)throw new IOException("Precompiled application helpers are required.");foreach(string assembly in assemblyRelativePaths)bootstrap.Append("[void][Reflection.Assembly]::Load([IO.File]::ReadAllBytes(").Append(PsQuote(CodeFile(assembly))).Append("))\r\n");
   bootstrap.Append("$rpcHandles=[IO.File]::ReadAllLines(").Append(PsQuote(Path.Combine(controlPath,"rpc-handles.txt"))).Append(")\r\n[OptiMiyoo.ApplicationRpcClient]::Initialize([long]$rpcHandles[0],[long]$rpcHandles[1])\r\n$null=New-PSDrive -Name Session -PSProvider FileSystem -Root $env:OPTIMIYOO_SESSION_WORK\r\nSet-Location 'Session:\\'\r\n& ").Append(PsQuote(entry)).Append("\r\nif($null-ne$LASTEXITCODE){exit $LASTEXITCODE}\r\n");
   string boot=Path.Combine(controlPath,"start.ps1");File.WriteAllText(boot,bootstrap.ToString(),new UTF8Encoding(true));
   StagedEntryCount=CountScratch(120000);cleanupEntryLimit=checked(StagedEntryCount+50000);
   IntPtr attributes=IntPtr.Zero,cap=IntPtr.Zero,child=IntPtr.Zero,list=IntPtr.Zero,environment=IntPtr.Zero;
   IntPtr termRead=IntPtr.Zero,termWrite=IntPtr.Zero,keyRead=IntPtr.Zero,keyWrite=IntPtr.Zero,reqRead=IntPtr.Zero,reqWrite=IntPtr.Zero,resRead=IntPtr.Zero,resWrite=IntPtr.Zero;PI pi=new PI();
   try{
    profile="OptiMiyoo.Session."+Guid.NewGuid().ToString("N");int hr=CreateAppContainerProfile(profile,profile,"Temporary OptiMiyoo application session",IntPtr.Zero,0,out sid);if(hr<0)Marshal.ThrowExceptionForHR(hr);string package=new SecurityIdentifier(sid).Value;
    Secure(CodePath,package,false);Secure(controlPath,package,false);Secure(WorkPath,package,true);PinTree(CodePath);PinTree(controlPath);
    SA sa=new SA{n=Marshal.SizeOf(typeof(SA)),inherit=0};Check(CreatePipe(out termRead,out termWrite,ref sa,0),"Create terminal output pipe");Check(CreatePipe(out keyRead,out keyWrite,ref sa,0),"Create terminal input pipe");
    columns=Interactive?(short)Math.Max(20,Math.Min(300,Console.WindowWidth)):(short)100;rows=Interactive?(short)Math.Max(6,Math.Min(120,Console.WindowHeight)):(short)34;hr=CreatePseudoConsole(new COORD{X=columns,Y=rows},keyRead,termWrite,0,out pseudo);if(hr<0)Marshal.ThrowExceptionForHR(hr);
    sa.inherit=0;Check(CreatePipe(out reqRead,out reqWrite,ref sa,0),"Create broker request pipe");Check(SetHandleInformation(reqRead,1,0),"Protect broker request reader");Check(CreatePipe(out resRead,out resWrite,ref sa,0),"Create broker response pipe");Check(SetHandleInformation(resWrite,1,0),"Protect broker response writer");
    IntPtr bytes=IntPtr.Zero;InitializeProcThreadAttributeList(IntPtr.Zero,3,0,ref bytes);attributes=Marshal.AllocHGlobal(bytes);Check(InitializeProcThreadAttributeList(attributes,3,0,ref bytes),"Initialize application attributes");cap=Value(new Capabilities{sid=sid});Attribute(attributes,0x20009,cap,Marshal.SizeOf(typeof(Capabilities)));child=Value(1u);Attribute(attributes,0x2000e,child,4);Attribute(attributes,0x20016,pseudo,IntPtr.Size);
    SIX si=new SIX();si.si.cb=Marshal.SizeOf(typeof(SIX));si.attributes=attributes;si.si.flags=0x100;si.si.input=new IntPtr(-1);si.si.output=new IntPtr(-1);si.si.error=new IntPtr(-1);
    string windows=Environment.GetFolderPath(Environment.SpecialFolder.Windows);string exe=Path.Combine(windows,"System32\\WindowsPowerShell\\v1.0\\powershell.exe");
    SortedDictionary<string,string> cleanEnvironment=new SortedDictionary<string,string>(StringComparer.OrdinalIgnoreCase);
    foreach(string name in new string[]{"APPDATA","LOCALAPPDATA","USERPROFILE","TEMP","TMP"})cleanEnvironment[name]=WorkPath;
    cleanEnvironment["OPTIMIYOO_SESSION_CODE"]=CodePath;cleanEnvironment["OPTIMIYOO_SESSION_WORK"]=WorkPath;cleanEnvironment["OS"]="Windows_NT";cleanEnvironment["PATH"]=windows+"\\System32";cleanEnvironment["PSModulePath"]="";cleanEnvironment["PSModuleAnalysisCachePath"]="NUL";cleanEnvironment["SystemRoot"]=windows;cleanEnvironment["WINDIR"]=windows;
    Guid terminalProfile;string profileValue=Environment.GetEnvironmentVariable("WT_PROFILE_ID");if(Guid.TryParse(profileValue,out terminalProfile))cleanEnvironment["WT_PROFILE_ID"]="{"+terminalProfile.ToString()+"}";
    StringBuilder env=new StringBuilder();foreach(KeyValuePair<string,string> item in cleanEnvironment)env.Append(item.Key).Append('=').Append(item.Value).Append('\0');env.Append('\0');environment=Marshal.StringToHGlobalUni(env.ToString());
    job=CreateJobObject(IntPtr.Zero,null);Check(job!=IntPtr.Zero,"Create application job");JobExtended limits=new JobExtended();limits.basic.flags=0x2000|0x100|0x200|0x8|0x2;limits.basic.active=1;limits.basic.processTime=(long)CpuTimeLimitSeconds*10000000;limits.processMemory=new UIntPtr((ulong)MemoryLimitMiB*1048576);limits.jobMemory=limits.processMemory;Check(SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(JobExtended))),"Set application job limits");uint ui=0xff;Check(SetUiRestrictions(job,4,ref ui,4),"Set application UI restrictions");
    Check(CreateProcess(exe,new StringBuilder("\""+exe+"\" -NoLogo -NoProfile -ExecutionPolicy Bypass -File \""+boot+"\""),IntPtr.Zero,IntPtr.Zero,false,0x80000|0x400|0x4,environment,WorkPath,ref si,out pi),"Create isolated application");process=pi.process;ProcessId=pi.pid;Check(AssignProcessToJobObject(job,process),"Assign isolated application job");ValidateToken();
    IntPtr childRequest,childResponse;Check(DuplicateHandle(GetCurrentProcess(),reqWrite,process,out childRequest,0,false,2),"Transfer request handle");Check(DuplicateHandle(GetCurrentProcess(),resRead,process,out childResponse,0,false,2),"Transfer response handle");string handlesFile=Path.Combine(controlPath,"rpc-handles.txt");File.WriteAllLines(handlesFile,new string[]{childRequest.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture),childResponse.ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture)},Encoding.ASCII);Pin(handlesFile,false);
    terminalReadHandle=new SafeFileHandle(termRead,true);terminalOutput=new FileStream(terminalReadHandle,FileAccess.Read,1,false);termRead=IntPtr.Zero;terminalInput=new FileStream(new SafeFileHandle(keyWrite,true),FileAccess.Write);keyWrite=IntPtr.Zero;keyWriter=new StreamWriter(terminalInput,new UTF8Encoding(false),1024);keyWriter.AutoFlush=true;
    requestInput=new FileStream(new SafeFileHandle(reqRead,true),FileAccess.Read,1,false);reqRead=IntPtr.Zero;responseOutput=new FileStream(new SafeFileHandle(resWrite,true),FileAccess.Write);resWrite=IntPtr.Zero;
    if(Interactive)SaveConsole();outputThread=ThreadFor(OutputLoop);rpcThread=ThreadFor(RequestLoop);inputWriterThread=ThreadFor(InputWriterLoop);if(Interactive)inputThread=ThreadFor(InputLoop);Check(ResumeThread(pi.thread)!=0xffffffff,"Resume isolated application");
   }catch{Dispose();throw;}
   finally{Close(ref pi.thread);Close(ref termRead);Close(ref termWrite);Close(ref keyRead);Close(ref keyWrite);Close(ref reqRead);Close(ref reqWrite);Close(ref resRead);Close(ref resWrite);if(attributes!=IntPtr.Zero){DeleteProcThreadAttributeList(attributes);Marshal.FreeHGlobal(attributes);}foreach(IntPtr p in new IntPtr[]{cap,child,list,environment})if(p!=IntPtr.Zero)Marshal.FreeHGlobal(p);}
  }
  private void ValidateToken(){IntPtr token;Check(OpenProcessToken(process,8,out token),"Inspect application token");try{uint returned;IntPtr flag=Marshal.AllocHGlobal(4);try{Check(GetTokenInformation(token,29,flag,4,out returned),"Inspect AppContainer flag");IsAppContainer=Marshal.ReadInt32(flag)==1;}finally{Marshal.FreeHGlobal(flag);}uint bytes;GetTokenInformation(token,30,IntPtr.Zero,0,out bytes);if(bytes<4||bytes>65536)throw new IOException("Cannot verify application capabilities.");IntPtr caps=Marshal.AllocHGlobal((int)bytes);try{Check(GetTokenInformation(token,30,caps,bytes,out returned),"Inspect application capabilities");if(!IsAppContainer||Marshal.ReadInt32(caps)!=0)throw new IOException("Application must have a zero-capability AppContainer token.");}finally{Marshal.FreeHGlobal(caps);}}finally{CloseHandle(token);}}
  private static Thread ThreadFor(ThreadStart action){Thread thread=new Thread(action);thread.IsBackground=true;thread.Start();return thread;}
  // A relay can outlive its bounded join. Reject late signals/waits, and let
  // the last admitted waiter close the handles without blocking disposal.
  private void CloseEventsIfIdle(){if(eventDisposalRequested&&eventWaiters==0&&!eventHandlesClosed){eventHandlesClosed=true;requestReady.Dispose();inputReady.Dispose();}}
  private void SignalEvent(AutoResetEvent ready){lock(eventGate){if(!eventDisposalRequested)ready.Set();}}
  private void WaitForEvent(AutoResetEvent ready,int milliseconds){lock(eventGate){if(eventDisposalRequested)return;eventWaiters++;}try{ready.WaitOne(milliseconds);}finally{lock(eventGate){eventWaiters--;CloseEventsIfIdle();}}}
  private void DisposeEvents(){lock(eventGate){eventDisposalRequested=true;CloseEventsIfIdle();}}
  private void SaveConsole(){Check(GetConsoleMode(GetStdHandle(-10),out previousInputMode),"Read host input mode");Check(GetConsoleMode(GetStdHandle(-11),out previousOutputMode),"Read host output mode");previousControlC=Console.TreatControlCAsInput;previousCursor=Console.CursorVisible;previousTitle=Console.Title;previousForeground=Console.ForegroundColor;previousBackground=Console.BackgroundColor;consoleSaved=true;Check(SetConsoleMode(GetStdHandle(-10),(previousInputMode|0x80u)&~0x40u),"Disable host QuickEdit");Check(SetConsoleMode(GetStdHandle(-11),previousOutputMode|4u),"Enable host terminal output");Console.TreatControlCAsInput=true;Console.Title="OptiMiyoo";}
  private void Fail(string reason){lock(outcomeGate){if(Failure==null)Failure=reason;}stopping=true;paused=true;if(job!=IntPtr.Zero)TerminateJobObject(job,137);SignalEvent(requestReady);}
  private void FailResponse(string reason){lock(outcomeGate){if(!CancellationRequested)Fail(reason);}}
  public void Stop(){lock(outcomeGate){CancellationRequested=true;stopping=true;paused=true;}if(job!=IntPtr.Zero)TerminateJobObject(job,137);SignalEvent(requestReady);}
  // Finish an accepted broker handoff without manufacturing user cancellation.
  // Synchronize with the last native input batch; unread keys belong to the host.
  public void StopForHandoff(){lock(consoleGate){lock(outcomeGate){stopping=true;paused=true;}}if(job!=IntPtr.Zero)TerminateJobObject(job,137);SignalEvent(requestReady);}
  // A decoder can carry bytes from a previous read, producing more UTF-16
  // units than the next byte chunk alone (a split supplementary character).
  private void OutputLoop(){
   try{byte[] bytes=new byte[8192];char[] chars=new char[Utf8.GetMaxCharCount(bytes.Length)];Decoder decoder=Utf8.GetDecoder();int count;Stopwatch rate=Stopwatch.StartNew();long received=0;
    while(true){uint available;if(!PeekNamedPipe(terminalReadHandle,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero))break;if(available==0){lock(consoleGate){lastDrained=Stopwatch.GetTimestamp();}Thread.Sleep(5);continue;}count=terminalOutput.Read(bytes,0,(int)Math.Min((uint)bytes.Length,available));if(count==0)break;Interlocked.Exchange(ref outputInFlight,1);int length=decoder.GetChars(bytes,0,count,chars,0);received+=count;if(rate.ElapsedMilliseconds>=1000){received=0;rate.Restart();}if(received>16777216)throw new IOException("Application terminal output limit exceeded.");lock(consoleGate){lastOutput=Stopwatch.GetTimestamp();if(!paused&&!stopping){string safe=filter.Feed(new string(chars,0,length));if(safe.Length!=0)WriteTerminal(safe);}else filter.Reset();Interlocked.Exchange(ref outputInFlight,0);}}
   }catch(Exception){if(!stopping&&!HasExited)Fail("Application terminal channel failed.");try{byte[] drain=new byte[8192];while(terminalOutput.Read(drain,0,drain.Length)>0){}}catch{}}finally{Interlocked.Exchange(ref outputInFlight,0);}
  }
  // Never write the ConPTY pipe while holding the trusted prompt/display gate.
  // A stalled consumer gets bounded buffering, then termination, not a frozen UI.
  private void SendKeys(string text){
   if(text==null||text.Length==0)return;bool overflow=false;
   lock(inputGate){
    if(stopping||paused)return;
    // Native console records carry one UTF-16 unit at a time. Keep a high
    // surrogate until the next unit so per-item flushing cannot corrupt it.
    if(pendingInputHighSurrogate!='\0')text=pendingInputHighSurrogate+text;
    if(text.Length>8192-queuedInputCharacters)overflow=true;
    else{
     pendingInputHighSurrogate='\0';
     if(Char.IsHighSurrogate(text[text.Length-1])){pendingInputHighSurrogate=text[text.Length-1];text=text.Substring(0,text.Length-1);}
     if(text.Length!=0){inputQueue.Enqueue(text);queuedInputCharacters+=text.Length;}
    }
   }
   if(overflow){Fail("Application stopped consuming keyboard input.");return;}SignalEvent(inputReady);
  }
  private void ClearQueuedInput(){lock(inputGate){inputQueue.Clear();queuedInputCharacters=0;pendingInputHighSurrogate='\0';}}
  private void InputWriterLoop(){try{while(!stopping&&!HasExited){string text=null;lock(inputGate){if(!paused&&inputQueue.Count>0){text=inputQueue.Dequeue();queuedInputCharacters-=text.Length;}}if(text==null){WaitForEvent(inputReady,50);continue;}keyWriter.Write(text);keyWriter.Flush();}}catch(Exception){if(!stopping&&!HasExited)Fail("Application keyboard channel failed.");}}
  private static string KeyText(ConsoleKeyInfo key){
   bool control=(key.Modifiers&ConsoleModifiers.Control)!=0,alt=(key.Modifiers&ConsoleModifiers.Alt)!=0;string value=null;
   switch(key.Key){case ConsoleKey.Enter:value="\r";break;case ConsoleKey.Backspace:value="\x7f";break;case ConsoleKey.Escape:value="\x1b";break;case ConsoleKey.UpArrow:value="\x1b[A";break;case ConsoleKey.DownArrow:value="\x1b[B";break;case ConsoleKey.RightArrow:value="\x1b[C";break;case ConsoleKey.LeftArrow:value="\x1b[D";break;case ConsoleKey.Home:value="\x1b[H";break;case ConsoleKey.End:value="\x1b[F";break;case ConsoleKey.Delete:value="\x1b[3~";break;case ConsoleKey.Insert:value="\x1b[2~";break;case ConsoleKey.PageUp:value="\x1b[5~";break;case ConsoleKey.PageDown:value="\x1b[6~";break;default:if(key.KeyChar!=0)value=key.KeyChar.ToString();break;}
   if(control&&key.Key>=ConsoleKey.A&&key.Key<=ConsoleKey.Z)value=((char)(1+(int)key.Key-(int)ConsoleKey.A)).ToString();
   if(value!=null&&alt)value="\x1b"+value;return value;
  }
  private void WriteTerminal(string text){if(!Interactive){Console.Write(text);return;}uint written;Check(WriteConsole(GetStdHandle(-11),text,(uint)text.Length,out written,IntPtr.Zero)&&written==text.Length,"Write host terminal");}
  private void InputLoop(){try{InputRecord[] records=new InputRecord[1];while(!stopping&&!HasExited){lock(consoleGate){if(!paused){
   // Leave unread records in the native queue for trusted prompts and publication.
   for(int batch=0;batch<32;batch++){
    if(stopping||HasExited)return;
    uint available;Check(GetNumberOfConsoleInputEvents(GetStdHandle(-10),out available),"Inspect host input");if(available==0)break;
    uint count;Check(ReadConsoleInput(GetStdHandle(-10),records,1,out count),"Read host input");InputRecord record=records[0];
    if(count==1&&record.EventType==1&&record.KeyDown!=0){ConsoleKeyInfo key=new ConsoleKeyInfo(record.Character,(ConsoleKey)record.VirtualKey,(record.Control&0x10)!=0,(record.Control&3)!=0,(record.Control&12)!=0);if(key.Key==ConsoleKey.C&&(key.Modifiers&ConsoleModifiers.Control)!=0){Stop();return;}string text=KeyText(key);for(int repeat=0;repeat<Math.Max(1,Math.Min(32,(int)record.Repeat));repeat++)SendKeys(text);}
   }
   if(stopping||HasExited)return;
   short w=(short)Math.Max(20,Math.Min(300,Console.WindowWidth)),h=(short)Math.Max(6,Math.Min(120,Console.WindowHeight));if(w!=columns||h!=rows){int hr=ResizePseudoConsole(pseudo,new COORD{X=w,Y=h});if(hr<0)Marshal.ThrowExceptionForHR(hr);columns=w;rows=h;}
  }}Thread.Sleep(8);}}catch(Exception){if(!stopping&&!HasExited)Fail("Application keyboard/resize channel failed.");}}
  public void PauseRelay(){PauseRelayCore(false);}
  public void PauseRelayForPublication(){PauseRelayCore(true);}
  private void PauseRelayCore(bool publication){
   if(!Interactive||!started||disposed||stopping)throw new InvalidOperationException("An interactive application relay is required for a trusted prompt.");
   lock(consoleGate){
    if(publication&&!HasExited)throw new InvalidOperationException("Publication requires a finished application worker.");
    paused=true;ClearQueuedInput();pauseStarted=Stopwatch.GetTimestamp();filter.Reset();WriteTerminal("\x1b[0m\x1b[r\x1b[?25h\x1b[2J\x1b[H");Console.Title="OptiMiyoo";
    // After worker exit, the parent must still observe queued cancellation
    // before publication. Trusted prompts retain their usual input flush.
    if(!publication)Check(FlushConsoleInputBuffer(GetStdHandle(-10)),"Flush pre-prompt input");
   }
  }
  public void ResumeRelay(){
   if(!paused||disposed||stopping)throw new InvalidOperationException("The application relay cannot resume.");Stopwatch watch=Stopwatch.StartNew();
   while(watch.ElapsedMilliseconds<2000){lock(consoleGate){double quiet=(Stopwatch.GetTimestamp()-lastOutput)*1000.0/Stopwatch.Frequency;if(lastDrained>=pauseStarted&&Interlocked.CompareExchange(ref outputInFlight,0,0)==0&&quiet>=50){Check(FlushConsoleInputBuffer(GetStdHandle(-10)),"Flush prompt input");filter.Reset();WriteTerminal("\x1b[0m\x1b[r\x1b[2J\x1b[H");Console.Title="OptiMiyoo";paused=false;return;}}Thread.Sleep(10);}
   Fail("Application kept producing output during a trusted prompt.");throw new IOException(Failure);
  }
  private static void ValidateOperation(string op){if(String.IsNullOrEmpty(op)||op.Length>64)throw new IOException("Invalid broker operation.");foreach(char c in op)if(!(c>='A'&&c<='Z')&&!(c>='a'&&c<='z')&&!(c>='0'&&c<='9')&&c!='.')throw new IOException("Invalid broker operation.");}
  private byte[] ReadExact(int count,bool initial,Stopwatch deadline){
   byte[] data=new byte[count];int offset=0;
   while(offset<count){if(stopping)throw new IOException("Application session ended.");uint available;bool ok=PeekNamedPipe(requestInput.SafeFileHandle,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero);if(!ok){if(initial&&offset==0)return null;throw new EndOfStreamException("Truncated broker frame.");}if(available==0){if(HasExited){if(initial&&offset==0)return null;throw new EndOfStreamException("Truncated broker frame.");}if(deadline.IsRunning&&deadline.ElapsedMilliseconds>10000)throw new IOException("Broker request frame timed out.");Thread.Sleep(5);continue;}if(!deadline.IsRunning)deadline.Start();int n=requestInput.Read(data,offset,Math.Min(count-offset,(int)Math.Min(available,1048576u)));if(n==0)throw new EndOfStreamException("Truncated broker frame.");offset+=n;if(deadline.ElapsedMilliseconds>10000)throw new IOException("Broker request frame timed out.");}
   return data;
  }
  private void RequestLoop(){
   try{while(!stopping){Stopwatch deadline=new Stopwatch();byte[] prefix=ReadExact(4,true,deadline);if(prefix==null){if(!HasExited){WaitForExit(250);if(!HasExited)throw new EndOfStreamException("Application closed its broker channel early.");}break;}uint length=BitConverter.ToUInt32(prefix,0);if(length<7||length>MaximumFrameBytes)throw new IOException("Invalid broker frame length.");byte[] body=ReadExact((int)length,false,deadline);uint id=BitConverter.ToUInt32(body,0);int opLength=BitConverter.ToUInt16(body,4);if(opLength<1||opLength>64||6+opLength>body.Length)throw new IOException("Invalid broker operation length.");string op=Utf8.GetString(body,6,opLength);ValidateOperation(op);string payload=Utf8.GetString(body,6+opLength,body.Length-6-opLength);
    lock(rpcGate){if(id==0||id!=lastRequest+1||lastRequest==UInt32.MaxValue||pendingResponse!=0||requests.Count!=0||!operations.Contains(op))throw new IOException("Unknown, concurrent or replayed broker request.");lastRequest=id;pendingResponse=id;requests.Enqueue(new ApplicationRequest{Id=id,Operation=op,Payload=payload});}SignalEvent(requestReady);
   }}catch(Exception){if(!stopping&&!HasExited)Fail("Application sent an invalid broker request or closed its channel.");}finally{SignalEvent(requestReady);}
  }
  public ApplicationRequest ReadRequest(int milliseconds){if(milliseconds<0||milliseconds>1000)throw new ArgumentOutOfRangeException("milliseconds");lock(rpcGate){if(requests.Count>0)return requests.Dequeue();}WaitForEvent(requestReady,milliseconds);lock(rpcGate){if(requests.Count>0)return requests.Dequeue();return null;}}
  public void Respond(uint id,bool success,string payload){
   byte[] data=Utf8.GetBytes(payload??"null");
   if(data.Length>MaximumFrameBytes-5)throw new IOException("Broker response exceeds its limit.");
   lock(rpcGate){
    if(id==0||pendingResponse!=id)throw new InvalidOperationException("Response does not match the outstanding request.");
    if(stopping||HasExited)throw new IOException("Application session ended before its response.");
    byte[] header=new byte[9];Buffer.BlockCopy(BitConverter.GetBytes((uint)(data.Length+5)),0,header,0,4);Buffer.BlockCopy(BitConverter.GetBytes(id),0,header,4,4);header[8]=success?(byte)1:(byte)0;
    try{
     Exception writeError=null;
     Thread writer=ThreadFor(delegate{try{responseOutput.Write(header,0,header.Length);responseOutput.Write(data,0,data.Length);responseOutput.Flush();}catch(Exception error){writeError=error;}});
     // Join bounds the write and its termination drain without an event which
     // a still-running writer could signal after the waiting thread disposes it.
     if(!writer.Join(10000)){FailResponse("Application did not read its broker response.");writer.Join(3000);throw new IOException("Application broker response did not finish.");}
     if(writeError!=null)throw writeError;
     pendingResponse=0;
    }catch{
     // Stop closes the child's pipe intentionally. Preserve genuine failures,
     // but do not turn that expected broken pipe into a new channel failure.
     FailResponse("Application broker response channel failed.");
     if(Failure!=null)throw new IOException(Failure);
     if(CancellationRequested)throw new OperationCanceledException("Application cancelled.");
     throw;
    }
   }
  }
  private int CountScratch(int maximum){Queue<string> pending=new Queue<string>();pending.Enqueue(RootPath);int count=0;while(pending.Count>0){string path=pending.Dequeue();if(++count>maximum)throw new IOException("Application scratch entry limit exceeded; files retained.");FileAttributes attributes=File.GetAttributes(path);if((attributes&FileAttributes.ReparsePoint)!=0)throw new IOException("Application scratch contains a link; files retained.");if((attributes&FileAttributes.Directory)!=0)foreach(string child in Directory.EnumerateFileSystemEntries(path)){if(pending.Count+count>=maximum)throw new IOException("Application scratch entry limit exceeded; files retained.");pending.Enqueue(child);}}return count;}
  private void Cleanup(){
   foreach(SafeFileHandle pin in pins)pin.Dispose();pins.Clear();if(RootPath==null||(!Directory.Exists(RootPath)&&!File.Exists(RootPath)))return;
   for(int retry=0;;retry++){try{Policy("DeleteOwnedVerified",RootPath,Path.GetDirectoryName(RootPath),rootIdentity,cleanupEntryLimit);break;}catch(Win32Exception e){if(retry>=7||(e.NativeErrorCode!=5&&e.NativeErrorCode!=32&&e.NativeErrorCode!=33&&e.NativeErrorCode!=145))throw;Thread.Sleep(Math.Min(100*(1<<retry),1000));if(!Directory.Exists(RootPath))break;}}
  }
  public void Dispose(){
   lock(eventGate){if(disposed)return;disposed=true;}
   try{
   stopping=true;paused=true;SignalEvent(requestReady);SignalEvent(inputReady);ClearQueuedInput();if(job!=IntPtr.Zero)TerminateJobObject(job,137);if(process!=IntPtr.Zero){if(!HasExited)TerminateProcess(process,137);WaitForExit(5000);}
   if(terminalInput!=null){try{CancelIoEx(terminalInput.SafeFileHandle,IntPtr.Zero);}catch{}}
   if(terminalInput!=null){try{terminalInput.Dispose();}catch{}}if(requestInput!=null){try{requestInput.Dispose();}catch{}}if(responseOutput!=null){try{responseOutput.Dispose();}catch{}}
   if(pseudo!=IntPtr.Zero){ClosePseudoConsole(pseudo);pseudo=IntPtr.Zero;}if(terminalOutput!=null){try{terminalOutput.Dispose();}catch{}}
   foreach(Thread thread in new Thread[]{inputThread,inputWriterThread,outputThread,rpcThread})if(thread!=null&&thread!=Thread.CurrentThread)thread.Join(1000);
   Close(ref process);Close(ref job);if(sid!=IntPtr.Zero){FreeSid(sid);sid=IntPtr.Zero;}if(profile!=null){int hr=DeleteAppContainerProfile(profile);for(int retry=0;hr<0 && retry<3;retry++){Thread.Sleep(50*(1<<retry));hr=DeleteAppContainerProfile(profile);}if(hr<0)CleanupWarning="Application profile cleanup failed ("+hr.ToString("X8")+").";profile=null;}
   try{Cleanup();}catch(Exception e){CleanupWarning=(CleanupWarning==null?"":CleanupWarning+" ")+e.Message+" Retained application scratch: "+RootPath;}finally{foreach(SafeFileHandle pin in pins)pin.Dispose();pins.Clear();if(parentLease!=null){parentLease.Dispose();parentLease=null;}}
   if(consoleSaved){lock(consoleGate){
    try{WriteTerminal("\x1b[0m\x1b[r\x1b[?25h");}catch{}
    // The ANSI reset selects terminal defaults, not the caller's native colors.
    try{Console.ForegroundColor=previousForeground;Console.BackgroundColor=previousBackground;}catch{}
    try{Console.CursorVisible=previousCursor;Console.TreatControlCAsInput=previousControlC;Console.Title=previousTitle;SetConsoleMode(GetStdHandle(-10),previousInputMode);SetConsoleMode(GetStdHandle(-11),previousOutputMode);}catch{}
    consoleSaved=false;
   }}
   }finally{DisposeEvents();}
  }
 }
}
'@
}

function Invoke-ApplicationRpc {
    param([Parameter(Mandatory=$true)][string]$Operation,[AllowNull()][object]$Payload=$null)
    $json=if($null-eq$Payload){'null'}else{ConvertTo-Json -InputObject $Payload -Depth 24 -Compress}
    $reply=[OptiMiyoo.ApplicationRpcClient]::Call($Operation,$json)
    if($reply-ceq'null'){return $null}
    return (ConvertFrom-Json -InputObject $reply)
}
