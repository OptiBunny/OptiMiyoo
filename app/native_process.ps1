. (Join-Path $PSScriptRoot 'native_sandbox.ps1')
# Bound diagnostics before they reach PowerShell or a log. Read fixed chunks,
# because line events and ReadToEndAsync can allocate without a size limit.
function Initialize-NativeTextCapture {
    if ('OptiMiyoo.NativeTextCapture' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
namespace OptiMiyoo {
    public sealed class NativeTextCapture : IDisposable {
        private readonly StreamReader reader;
        private readonly int maximum;
        private readonly object gate=new object();
        private readonly StringBuilder text=new StringBuilder();
        private readonly ConcurrentQueue<string> lines=new ConcurrentQueue<string>();
        private readonly Task worker;
        private int queued;
        private volatile bool exceeded;
        private string failure;
        public bool LimitExceeded {get {return exceeded;}}
        public string Failure {get {lock(gate) {return failure;}}}
        public NativeTextCapture(StreamReader source,int limit) {
            if (source==null || limit<1) throw new ArgumentException("A stream and positive output limit are required.");
            reader=source;maximum=limit;
            worker=Task.Factory.StartNew(Read, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }
        private void Line(StringBuilder line) {
            if (line.Length==0) return;
            if (Interlocked.Increment(ref queued)<=4096) lines.Enqueue(line.ToString());
            else {Interlocked.Decrement(ref queued);exceeded=true;}
            line.Length=0;
        }
        private void Read() {
            char[] buffer=new char[4096];StringBuilder line=new StringBuilder();
            try {
                int count;
                while ((count=reader.Read(buffer,0,buffer.Length))>0) {
                    int take;
                    lock(gate) {
                        take=Math.Min(count,maximum-text.Length);
                        if (take>0) text.Append(buffer,0,take);
                    }
                    for (int i=0;i<take;i++) {
                        char c=buffer[i];
                        if (c=='\r' || c=='\n') Line(line);
                        else {line.Append(c);if (line.Length==4096) Line(line);}
                    }
                    if (take<count) exceeded=true;
                }
                Line(line);
            } catch (Exception error) {lock(gate) {failure=error.Message;}}
        }
        public string NextLine() {
            string line;
            if (!lines.TryDequeue(out line)) return null;
            Interlocked.Decrement(ref queued);return line;
        }
        public string Text() {lock(gate) {return text.ToString();}}
        public bool Wait(int milliseconds) {return worker.Wait(milliseconds);}
        public void Dispose() {
            try {reader.Dispose();} catch {}
            try {worker.Wait(1000);} catch {}
        }
    }
}
'@
}

# The trusted host imports one output only after a successful isolated run.
# Native code never receives permission to write SRC, DST or the app directory.
function New-NativeNibCapture([string]$Executable,[string]$InputPath,[string]$OutputPath) {
    if ((Get-Command Test-ApplicationWorker -ErrorAction SilentlyContinue) -and (Test-ApplicationWorker)) {return (New-ApplicationNativeCapture Nib Convert $InputPath $OutputPath)}
    Initialize-NativeSandbox
    Initialize-NativeTextCapture
    $inputDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InputPath))
    $outputDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))
    if (-not $inputDirectory.Equals($outputDirectory,[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Native NIB input and output must share the staging directory.'
    }
    $job=$null;$stdout=$null;$stderr=$null
    try {
        $job=[OptiMiyoo.NativeSandboxJob]::Create($Executable,[string[]]@(),$InputPath,'output.g64',$true)
        $job.Start(('-v "'+$job.InputRelativePath+'" "'+$job.OutputName+'"'))
        $stdout=New-Object OptiMiyoo.NativeTextCapture($job.StandardOutput,1048576)
        $stderr=New-Object OptiMiyoo.NativeTextCapture($job.StandardError,1048576)
        $capture=[pscustomobject]@{Child=$job;Output=$stdout;Error=$stderr;Destination=$OutputPath}
        $capture | Add-Member ScriptProperty LimitExceeded {return ($this.Output.LimitExceeded -or $this.Error.LimitExceeded)}
        $capture | Add-Member ScriptProperty CaptureFailed {return ($this.Output.Failure -or $this.Error.Failure)}
        $capture | Add-Member ScriptMethod NextLine {
            $line=$this.Output.NextLine()
            if ($null -ne $line) {return $line}
            return $this.Error.NextLine()
        }
        $capture | Add-Member ScriptMethod WaitOutput {
            param([int]$Milliseconds)
            $outReady=$this.Output.Wait($Milliseconds);$errReady=$this.Error.Wait($Milliseconds)
            return ($outReady -and $errReady)
        }
        $capture | Add-Member ScriptMethod Export {$this.Child.Export($this.Destination)}
        $capture | Add-Member ScriptMethod Dispose {
            try {Close-NativeSandboxJob $this.Child} finally {$this.Output.Dispose();$this.Error.Dispose()}
        }
        return $capture
    } catch {
        if ($job) {Close-NativeSandboxJob $job}
        if ($stdout) {$stdout.Dispose()};if ($stderr) {$stderr.Dispose()}
        throw
    }
}

function Close-NativeSandboxJob($Job) {
    if (-not $Job) {return}
    $Job.Dispose()
    if ($Job.CleanupWarning) {
        Write-Warning ('Temporary sandbox files were kept at '+$Job.RootPath+'. '+$Job.CleanupWarning)
    }
}
