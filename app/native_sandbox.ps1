# Windows AppContainer isolation for native converters and archive helpers.
# This helper never falls back to an unrestricted process.
function Initialize-NativeSandbox {
    if ('OptiMiyoo.NativeSandboxJob' -as [type]) {return}
    . (Join-Path $PSScriptRoot 'source_policy.ps1')
    Initialize-SourcePolicyNative
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace OptiMiyoo {
 internal sealed class NativeSandboxProcess : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct SA {public int n; public IntPtr descriptor; public int inherit;}
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct SI {
   public int cb; public string reserved,desktop,title; public int x,y,cx,cy,cxc,cyc,fill,flags; public short show,reserved2; public IntPtr reservedp,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)] struct SIX {public SI si;public IntPtr attributes;}
  [StructLayout(LayoutKind.Sequential)] struct PI {public IntPtr process,thread;public uint pid,tid;}
  [StructLayout(LayoutKind.Sequential)] struct Capabilities {public IntPtr sid,capabilities;public uint count,reserved;}
  [StructLayout(LayoutKind.Sequential)] struct JobBasic {public long processTime,jobTime;public uint flags;public UIntPtr min,max;public uint active;public UIntPtr affinity;public uint priority,scheduling;}
  [StructLayout(LayoutKind.Sequential)] struct IOCounts {public ulong read,write,other,readBytes,writeBytes,otherBytes;}
  [StructLayout(LayoutKind.Sequential)] struct JobExtended {public JobBasic basic;public IOCounts io;public UIntPtr processMemory,jobMemory,peakProcess,peakJob;}
  [DllImport("userenv.dll",CharSet=CharSet.Unicode)] static extern int CreateAppContainerProfile(string name,string display,string description,IntPtr caps,uint count,out IntPtr sid);
  [DllImport("userenv.dll",CharSet=CharSet.Unicode)] static extern int DeleteAppContainerProfile(string name);
  [DllImport("advapi32.dll")] static extern IntPtr FreeSid(IntPtr sid);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string value,uint revision,out IntPtr descriptor,out uint size);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetFileSecurity(string path,uint information,IntPtr descriptor);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode)] static extern uint SetNamedSecurityInfo(string path,int kind,uint information,IntPtr owner,IntPtr group,IntPtr dacl,IntPtr sacl);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetSecurityDescriptorDacl(IntPtr descriptor,out bool present,out IntPtr acl,out bool defaulted);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetSecurityDescriptorSacl(IntPtr descriptor,out bool present,out IntPtr acl,out bool defaulted);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr value);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr bytes);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr bytes,IntPtr previous,IntPtr returned);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSA,IntPtr threadSA,bool inherit,uint flags,IntPtr environment,string cwd,ref SIX startup,out PI result);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out IntPtr read,out IntPtr write,ref SA attributes,uint size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle,uint mask,uint flags);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr sa,string name);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int info,ref JobExtended value,uint size);
  [DllImport("kernel32.dll",EntryPoint="SetInformationJobObject",SetLastError=true)] static extern bool SetJobUiRestrictions(IntPtr job,int info,ref uint flags,uint size);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint exitCode);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr handle,out uint code);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int info,IntPtr data,uint bytes,out uint returned);
  public StreamReader StandardOutput,StandardError;
  private IntPtr process,job,sid;
  private string profile;
  public uint Id {get;private set;}
  public bool IsAppContainer {get;private set;}
  public string CleanupWarning {get;private set;}
  private static void Check(bool ok,string where) {if(!ok) {int code=Marshal.GetLastWin32Error();throw new Win32Exception(code,where+": "+code+" "+new Win32Exception(code).Message);}}
  private static IntPtr Value<T>(T value) {IntPtr p=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(T)));Marshal.StructureToPtr(value,p,false);return p;}
  private static void Attribute(IntPtr list,int id,IntPtr value,int bytes) {Check(UpdateProcThreadAttribute(list,0,new IntPtr(id),value,new IntPtr(bytes),IntPtr.Zero,IntPtr.Zero),"Update attribute "+id);}
  private static void Close(ref IntPtr handle) {if(handle!=IntPtr.Zero) {CloseHandle(handle);handle=IntPtr.Zero;}}
  internal static void Secure(string path,string package,bool write) {
   string user=WindowsIdentity.GetCurrent().User.Value;
   string rights=write?"0x1301bf":"0x1200a9";
   string sddl="D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+user+")(A;OICI;"+rights+";;;"+package+")"+(write?"S:(ML;OICI;NW;;;LW)":"");
   IntPtr sd;uint bytes;Check(ConvertStringSecurityDescriptorToSecurityDescriptor(sddl,1,out sd,out bytes),"Parse ACL");
   try {bool present,defaulted;IntPtr dacl,sacl;Check(GetSecurityDescriptorDacl(sd,out present,out dacl,out defaulted),"Read DACL");Check(GetSecurityDescriptorSacl(sd,out present,out sacl,out defaulted),"Read SACL");uint status=SetNamedSecurityInfo(path,1,0x80000004u|(write?0x10u:0u),IntPtr.Zero,IntPtr.Zero,dacl,sacl);if(status!=0) throw new Win32Exception((int)status,"Apply private scratch ACL");} finally {LocalFree(sd);}
  }
  public static NativeSandboxProcess Start(string exe,string args,string cwd,string[] readFolders,string[] writeFolders,bool lpac,bool allowChildren,int memoryMiB,int cpuSeconds,IntPtr[] extraHandles) {
   NativeSandboxProcess result=new NativeSandboxProcess();
   IntPtr attributes=IntPtr.Zero,cap=IntPtr.Zero,low=IntPtr.Zero,child=IntPtr.Zero,handles=IntPtr.Zero,environment=IntPtr.Zero;
   IntPtr outRead=IntPtr.Zero,outWrite=IntPtr.Zero,errRead=IntPtr.Zero,errWrite=IntPtr.Zero,inRead=IntPtr.Zero,inWrite=IntPtr.Zero;
   PI pi=new PI();
   try {
    result.profile="OptiMiyoo.Native."+Guid.NewGuid().ToString("N");
    int hr=CreateAppContainerProfile(result.profile,result.profile,"Temporary OptiMiyoo conversion sandbox",IntPtr.Zero,0,out result.sid);if(hr<0) Marshal.ThrowExceptionForHR(hr);
    string package=new SecurityIdentifier(result.sid).Value;
    foreach(string path in readFolders) Secure(path,package,false);
    foreach(string path in writeFolders) Secure(path,package,true);
    SA sa=new SA {n=Marshal.SizeOf(typeof(SA)),inherit=1};
    Check(CreatePipe(out outRead,out outWrite,ref sa,0),"stdout pipe");Check(SetHandleInformation(outRead,1,0),"stdout inheritance");
    Check(CreatePipe(out errRead,out errWrite,ref sa,0),"stderr pipe");Check(SetHandleInformation(errRead,1,0),"stderr inheritance");
    Check(CreatePipe(out inRead,out inWrite,ref sa,0),"stdin pipe");Check(SetHandleInformation(inWrite,1,0),"stdin inheritance");Close(ref inWrite);
    IntPtr bytes=IntPtr.Zero;int count=lpac?4:3;
    InitializeProcThreadAttributeList(IntPtr.Zero,count,0,ref bytes);attributes=Marshal.AllocHGlobal(bytes);
    Check(InitializeProcThreadAttributeList(attributes,count,0,ref bytes),"Initialize attributes");
    cap=Value(new Capabilities {sid=result.sid});Attribute(attributes,0x20009,cap,Marshal.SizeOf(typeof(Capabilities)));
    if(lpac) {low=Value(1u);Attribute(attributes,0x2000f,low,4);}
    child=Value(allowChildren?0u:1u);Attribute(attributes,0x2000e,child,4);
    int handleCount=3+extraHandles.Length;handles=Marshal.AllocHGlobal(handleCount*IntPtr.Size);Marshal.WriteIntPtr(handles,0,inRead);Marshal.WriteIntPtr(handles,IntPtr.Size,outWrite);Marshal.WriteIntPtr(handles,2*IntPtr.Size,errWrite);for(int i=0;i<extraHandles.Length;i++)Marshal.WriteIntPtr(handles,(3+i)*IntPtr.Size,extraHandles[i]);Attribute(attributes,0x20002,handles,handleCount*IntPtr.Size);
    SIX si=new SIX();si.si.cb=Marshal.SizeOf(typeof(SIX));si.si.flags=0x100;si.si.input=inRead;si.si.output=outWrite;si.si.error=errWrite;si.attributes=attributes;
    string windows=Environment.GetFolderPath(Environment.SpecialFolder.Windows);
    string env="APPDATA="+cwd+"\0LOCALAPPDATA="+cwd+"\0PATH="+Path.GetDirectoryName(exe)+";"+windows+"\\System32\0SystemRoot="+windows+"\0TEMP="+cwd+"\0TMP="+cwd+"\0USERPROFILE="+cwd+"\0WINDIR="+windows+"\0\0";
    environment=Marshal.StringToHGlobalUni(env);
    result.job=CreateJobObject(IntPtr.Zero,null);Check(result.job!=IntPtr.Zero,"Create job");
    JobExtended limits=new JobExtended();limits.basic.flags=0x2000|0x100|0x200|0x8|0x2;limits.basic.processTime=(long)cpuSeconds*10000000;limits.basic.active=allowChildren?8u:1u;limits.processMemory=new UIntPtr((ulong)memoryMiB*1024*1024);limits.jobMemory=limits.processMemory;
    Check(SetInformationJobObject(result.job,9,ref limits,(uint)Marshal.SizeOf(typeof(JobExtended))),"Job limits");
    uint uiRestrictions=0xff;Check(SetJobUiRestrictions(result.job,4,ref uiRestrictions,4),"Restrict sandbox desktop access");
    Check(CreateProcess(exe,new StringBuilder("\""+exe+"\" "+args),IntPtr.Zero,IntPtr.Zero,true,0x80000|0x400|0x4|0x8,environment,cwd,ref si,out pi),"Create isolated process");
    result.process=pi.process;result.Id=pi.pid;Check(AssignProcessToJobObject(result.job,result.process),"Assign job");
    IntPtr token;Check(OpenProcessToken(result.process,8,out token),"Inspect process token");
    try {uint returned;IntPtr flag=Marshal.AllocHGlobal(4);try {Check(GetTokenInformation(token,29,flag,4,out returned),"Inspect AppContainer token");result.IsAppContainer=Marshal.ReadInt32(flag)!=0;uint tokenBytes;GetTokenInformation(token,30,IntPtr.Zero,0,out tokenBytes);if(tokenBytes<4 || tokenBytes>65536)throw new IOException("Cannot verify sandbox capabilities.");IntPtr caps=Marshal.AllocHGlobal((int)tokenBytes);try{Check(GetTokenInformation(token,30,caps,tokenBytes,out returned),"Inspect sandbox capabilities");if(Marshal.ReadInt32(caps)!=0)throw new IOException("Sandbox capabilities must be empty.");}finally{Marshal.FreeHGlobal(caps);}}finally {Marshal.FreeHGlobal(flag);}}finally {CloseHandle(token);}
    if(!result.IsAppContainer) throw new IOException("Child lacks AppContainer token.");
    result.StandardOutput=new StreamReader(new FileStream(new SafeFileHandle(outRead,true),FileAccess.Read));outRead=IntPtr.Zero;
    result.StandardError=new StreamReader(new FileStream(new SafeFileHandle(errRead,true),FileAccess.Read));errRead=IntPtr.Zero;
    Check(ResumeThread(pi.thread)!=0xffffffff,"Resume isolated process");return result;
   } catch {result.Dispose();throw;}
   finally {
    Close(ref pi.thread);Close(ref outRead);Close(ref outWrite);Close(ref errRead);Close(ref errWrite);Close(ref inRead);Close(ref inWrite);
    if(attributes!=IntPtr.Zero) {DeleteProcThreadAttributeList(attributes);Marshal.FreeHGlobal(attributes);}
    foreach(IntPtr p in new IntPtr[]{cap,low,child,handles,environment}) if(p!=IntPtr.Zero) Marshal.FreeHGlobal(p);
   }
  }
  public bool HasExited {get {return WaitForSingleObject(process,0)==0;}}
  public int ExitCode {get {uint value;Check(GetExitCodeProcess(process,out value),"Read exit code");return unchecked((int)value);}}
  public bool WaitForExit(int milliseconds) {return WaitForSingleObject(process,unchecked((uint)milliseconds))==0;}
  public void Kill() {if(job!=IntPtr.Zero) Check(TerminateJobObject(job,137),"Terminate isolated job");}
  public void Dispose() {
   if(job!=IntPtr.Zero) {TerminateJobObject(job,137);Close(ref job);}
   if(process!=IntPtr.Zero) {if(WaitForSingleObject(process,0)!=0) TerminateProcess(process,137);WaitForSingleObject(process,5000);Close(ref process);}
   if(StandardOutput!=null) {StandardOutput.Dispose();StandardOutput=null;} if(StandardError!=null) {StandardError.Dispose();StandardError=null;}
   if(sid!=IntPtr.Zero) {FreeSid(sid);sid=IntPtr.Zero;}
   if(profile!=null) {int hr=DeleteAppContainerProfile(profile);for(int retry=0;hr<0 && retry<3;retry++){System.Threading.Thread.Sleep(50*(1<<retry));hr=DeleteAppContainerProfile(profile);}if(hr<0)CleanupWarning="Could not remove temporary AppContainer profile (HRESULT "+hr.ToString("X8")+").";profile=null;}
  }
 }


 public sealed class NativeSandboxJob : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct FileInfoNative {public uint attributes;public System.Runtime.InteropServices.ComTypes.FILETIME creation,access,write;public uint volume,sizeHigh,sizeLow,links,indexHigh,indexLow;}
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr sa,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInfoNative info);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr sourceProcess,SafeFileHandle source,IntPtr targetProcess,out IntPtr target,uint access,bool inherit,uint options);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  private NativeSandboxProcess child;
  private bool disposed,started;
  private bool lpac;
  private List<IntPtr> inherited=new List<IntPtr>();
  private List<FileStream> guards=new List<FileStream>();
  private List<SafeFileHandle> directories=new List<SafeFileHandle>();
  public string RootPath {get;private set;}
  public string WorkPath {get;private set;}
  public string ExecutablePath {get;private set;}
  public string InputRelativePath {get;private set;}
  public string OutputName {get;private set;}
  public string CleanupWarning {get;private set;}
  public int MemoryLimitMiB {get;set;}
  public int CpuTimeLimitSeconds {get;set;}
  public bool IsAppContainer {get {return child!=null && child.IsAppContainer;}}
  public bool RequestedLpac {get {return lpac;}}
  public uint Id {get {return child==null?0:child.Id;}}
  public StreamReader StandardOutput {get {return child.StandardOutput;}}
  public StreamReader StandardError {get {return child.StandardError;}}
  public bool HasExited {get {return child!=null && child.HasExited;}}
  public int ExitCode {get {return child.ExitCode;}}
  private static void Check(bool value,string context) {if(!value)throw new Win32Exception(Marshal.GetLastWin32Error(),context);}
  private static void PlainLeaf(string value) {if(String.IsNullOrEmpty(value)||value!=Path.GetFileName(value)||value.IndexOfAny(Path.GetInvalidFileNameChars())>=0||value=="."||value=="..")throw new IOException("A plain sandbox filename is required.");}
  private static void NoLinkedParents(string path) {
   string current=Path.GetFullPath(path);
   while(!String.IsNullOrEmpty(current)) {
    if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)throw new IOException("Sandbox input paths cannot contain links.");
    string parent=Path.GetDirectoryName(current.TrimEnd(Path.DirectorySeparatorChar));
    if(String.Equals(parent,current,StringComparison.OrdinalIgnoreCase))break;current=parent;
   }
  }
  private static FileStream ReadOrdinary(string path,long maximum) {
   NoLinkedParents(path);
   SafeFileHandle handle=CreateFile(path,0x80000000u,1,IntPtr.Zero,3,0x00200000u|0x08000000u,IntPtr.Zero);
   if(handle.IsInvalid){handle.Dispose();throw new Win32Exception(Marshal.GetLastWin32Error(),"Open sandbox input");}
   try {
    FileInfoNative info;Check(GetFileInformationByHandle(handle,out info),"Inspect sandbox input");
    long length=((long)info.sizeHigh<<32)|info.sizeLow;
    if((info.attributes&0x410)!=0||info.links!=1||length<0||length>maximum)throw new IOException("Sandbox input must be one bounded ordinary file.");
    return new FileStream(handle,FileAccess.Read,65536,false);
   }catch{handle.Dispose();throw;}
  }
  private static void CopyOrdinary(string from,string to,long maximum) {
   using(FileStream source=ReadOrdinary(from,maximum))
   using(FileStream destination=new FileStream(to,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536)) {
    long length=source.Length;byte[] buffer=new byte[65536];long copied=0;int count;
    while((count=source.Read(buffer,0,buffer.Length))>0){copied+=count;if(copied>length||copied>maximum)throw new IOException("Sandbox input grew during staging.");destination.Write(buffer,0,count);}
    if(copied!=length)throw new IOException("Sandbox input changed during staging.");destination.Flush(true);
   }
  }
  private void PinDirectory(string path) {
   SafeFileHandle handle=CreateFile(path,1,3,IntPtr.Zero,3,0x02000000u|0x00200000u,IntPtr.Zero);
   if(handle.IsInvalid){handle.Dispose();throw new Win32Exception(Marshal.GetLastWin32Error(),"Pin sandbox directory");}
   FileInfoNative info;try{Check(GetFileInformationByHandle(handle,out info),"Inspect sandbox directory");if((info.attributes&0x410)!=0x10)throw new IOException("Sandbox directory was replaced by a link.");}catch{handle.Dispose();throw;}
   directories.Add(handle);
   guards.Add(new FileStream(Path.Combine(path,".optimiyoo-guard"),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read,1,FileOptions.DeleteOnClose));
  }
  public static NativeSandboxJob Create(string exe,string[] runtimeFiles,string inputFile,string outputName,bool useLpac) {
   NativeSandboxJob result=new NativeSandboxJob();result.MemoryLimitMiB=1024;result.CpuTimeLimitSeconds=300;result.lpac=useLpac;result.OutputName=String.IsNullOrEmpty(outputName)?null:outputName;
   if(!String.IsNullOrEmpty(outputName))PlainLeaf(outputName);
   try {
    string temp=Path.GetFullPath(Path.GetTempPath());NoLinkedParents(temp);
    result.RootPath=Path.Combine(temp,"os_"+Guid.NewGuid().ToString("N"));
    if(Directory.Exists(result.RootPath)||File.Exists(result.RootPath))throw new IOException("Sandbox scratch name is occupied.");
    Directory.CreateDirectory(result.RootPath);
    // First protect the new empty root for the current account. The zero SID has no members.
    NativeSandboxProcess.Secure(result.RootPath,"S-1-0-0",false);
    string bin=Path.Combine(result.RootPath,"bin"),input=Path.Combine(result.RootPath,"input");result.WorkPath=Path.Combine(result.RootPath,"work");
    Directory.CreateDirectory(bin);Directory.CreateDirectory(input);Directory.CreateDirectory(result.WorkPath);
    result.PinDirectory(result.RootPath);result.PinDirectory(bin);result.PinDirectory(input);result.PinDirectory(result.WorkPath);
    string exeName=Path.GetFileName(exe);PlainLeaf(exeName);result.ExecutablePath=Path.Combine(bin,exeName);CopyOrdinary(exe,result.ExecutablePath,268435456);
    if(runtimeFiles!=null)foreach(string runtime in runtimeFiles){if(String.Equals(Path.GetFullPath(runtime),Path.GetFullPath(exe),StringComparison.OrdinalIgnoreCase))continue;string name=Path.GetFileName(runtime);PlainLeaf(name);CopyOrdinary(runtime,Path.Combine(bin,name),268435456);}
    if(!String.IsNullOrEmpty(inputFile)){string ext=Path.GetExtension(inputFile);if(ext.Length>16||ext.IndexOfAny(Path.GetInvalidFileNameChars())>=0)throw new IOException("Invalid sandbox input extension.");string name="input"+ext;CopyOrdinary(inputFile,Path.Combine(input,name),536870912L);result.InputRelativePath="..\\input\\"+name;}
    return result;
   }catch{result.Dispose();throw;}
  }
  public long AddReadHandle(SafeFileHandle source) {
   if(started||disposed||source==null||source.IsInvalid||source.IsClosed)throw new InvalidOperationException("A live read handle is required before sandbox start.");
   if(inherited.Count>=4)throw new IOException("Too many inherited sandbox inputs.");
   FileInfoNative info;Check(GetFileInformationByHandle(source,out info),"Inspect inherited archive input");
   if((info.attributes&0x410)!=0||info.links!=1)throw new IOException("Inherited input must be a single ordinary file.");
   IntPtr handle;Check(DuplicateHandle(GetCurrentProcess(),source,GetCurrentProcess(),out handle,0x120089u,true,0),"Duplicate read-only sandbox input");
   inherited.Add(handle);return handle.ToInt64();
  }
  public void Start(string arguments) {
   if(started||disposed)throw new InvalidOperationException("Sandbox sessions can start only once.");
   if(MemoryLimitMiB<64||MemoryLimitMiB>4096)throw new ArgumentOutOfRangeException("MemoryLimitMiB");
   if(CpuTimeLimitSeconds<1||CpuTimeLimitSeconds>1800)throw new ArgumentOutOfRangeException("CpuTimeLimitSeconds");
   started=true;
   try {child=NativeSandboxProcess.Start(ExecutablePath,arguments??"",WorkPath,new string[]{Path.Combine(RootPath,"bin"),Path.Combine(RootPath,"input")},new string[]{WorkPath},lpac,false,MemoryLimitMiB,CpuTimeLimitSeconds,inherited.ToArray());}
   finally {foreach(IntPtr handle in inherited)CloseHandle(handle);inherited.Clear();}
  }
  public bool WaitForExit(int milliseconds){if(child==null)throw new InvalidOperationException("Sandbox has not started.");return child.WaitForExit(milliseconds);}
  public void Kill(){if(child!=null)child.Kill();}
  public void Export(string destination) {
   if(!HasExited||ExitCode!=0||OutputName==null)throw new InvalidOperationException("Only a successful sandbox output can be exported.");
   CopyOrdinary(Path.Combine(WorkPath,OutputName),destination,536870912L);
  }
  private void BoundCleanupTree() {
   Queue<string> pending=new Queue<string>();pending.Enqueue(RootPath);int count=0;
   while(pending.Count!=0){string current=pending.Dequeue();if(++count>50000)throw new IOException("Sandbox cleanup entry limit exceeded; scratch retained.");FileAttributes attributes=File.GetAttributes(current);if((attributes&FileAttributes.ReparsePoint)!=0)throw new IOException("Sandbox cleanup contains a link; scratch retained.");if((attributes&FileAttributes.Directory)!=0)foreach(string entry in Directory.EnumerateFileSystemEntries(current)){if(pending.Count+count>=50000)throw new IOException("Sandbox cleanup entry limit exceeded; scratch retained.");pending.Enqueue(entry);}}
  }
  private void Cleanup() {
   if(RootPath==null||!Directory.Exists(RootPath))return;
   // The child is dead. Release staging pins before the deletion helper obtains
   // its own DELETE handles and pins every ancestor; never use a recursive path delete.
   foreach(FileStream guard in guards)guard.Dispose();guards.Clear();foreach(SafeFileHandle directory in directories)directory.Dispose();directories.Clear();
   BoundCleanupTree();
   Type helper=null;
   foreach(System.Reflection.Assembly assembly in AppDomain.CurrentDomain.GetAssemblies()){helper=assembly.GetType("OptiMiyoo.SourceRemovalLeaseV128",false);if(helper!=null)break;}
   if(helper==null)throw new IOException("Verified sandbox cleanup helper is unavailable; scratch retained.");
   System.Reflection.MethodInfo method=helper.GetMethod("DeleteOwned",System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static);
   if(method==null)throw new IOException("Verified sandbox cleanup method is unavailable; scratch retained.");
   for(int retry=0;;retry++){
    try{method.Invoke(null,new object[]{RootPath,Path.GetDirectoryName(RootPath)});break;}
    catch(System.Reflection.TargetInvocationException error){Exception cause=error.InnerException??error;Win32Exception native=cause as Win32Exception;bool transient=native!=null&&(native.NativeErrorCode==5||native.NativeErrorCode==32||native.NativeErrorCode==33||native.NativeErrorCode==145);if(!transient||retry>=7)throw cause;System.Threading.Thread.Sleep(Math.Min(100*(1<<retry),1000));if(!Directory.Exists(RootPath))break;BoundCleanupTree();}
   }

  }
  public void Dispose() {
   if(disposed)return;disposed=true;
   if(child!=null){child.Dispose();if(child.CleanupWarning!=null)CleanupWarning=child.CleanupWarning;child=null;}
   foreach(IntPtr handle in inherited)CloseHandle(handle);inherited.Clear();
   try{Cleanup();}catch(Exception error){CleanupWarning=(CleanupWarning==null?"":CleanupWarning+" ")+error.Message+" Retained scratch: "+RootPath;}
   finally{foreach(FileStream guard in guards)guard.Dispose();guards.Clear();foreach(SafeFileHandle directory in directories)directory.Dispose();directories.Clear();}
  }
 }
}
'@
}
