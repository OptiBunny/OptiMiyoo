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
    public sealed class NativeNibCapture : IDisposable {
        public readonly Process Child=new Process();
        private NativeTextCapture output,error;
        public bool LimitExceeded {get {return (output!=null && output.LimitExceeded) || (error!=null && error.LimitExceeded);}}
        public bool CaptureFailed {get {return (output!=null && output.Failure!=null) || (error!=null && error.Failure!=null);}}
        public NativeNibCapture(string exe,string input,string destination) {
            string directory=Path.GetDirectoryName(Path.GetFullPath(input));
            if (!String.Equals(directory,Path.GetDirectoryName(Path.GetFullPath(destination)),StringComparison.OrdinalIgnoreCase))
                throw new IOException("Native NIB input and output must share the isolated staging directory.");
            Child.StartInfo=new ProcessStartInfo {
                FileName=exe,WorkingDirectory=directory,
                Arguments="-v \""+Path.GetFileName(input)+"\" \""+Path.GetFileName(destination)+"\"",
                UseShellExecute=false,CreateNoWindow=true,
                RedirectStandardOutput=true,RedirectStandardError=true,RedirectStandardInput=true
            };
            try {
                if (!Child.Start()) throw new IOException("Could not start nibconv.");
                Child.StandardInput.Close();
                output=new NativeTextCapture(Child.StandardOutput,1048576);
                error=new NativeTextCapture(Child.StandardError,1048576);
            } catch {Dispose();throw;}
        }
        public string NextLine() {return output.NextLine() ?? error.NextLine();}
        public bool WaitOutput(int milliseconds) {return output.Wait(milliseconds) && error.Wait(milliseconds);}
        public void Dispose() {
            try {if (!Child.HasExited) {Child.Kill();Child.WaitForExit(5000);}} catch {}
            if (output!=null) output.Dispose();if (error!=null) error.Dispose();
            Child.Dispose();
        }
    }
}
'@
}
