# Archive resource limits apply before ZipArchive builds its entry collection.
# Zero-filled disk images can compress extremely well, so no ratio limit is used.
function Initialize-ArchiveLimits {
    if ('OptiMiyoo.ArchiveLimits' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
namespace OptiMiyoo {
    public static class ArchiveLimits {
        private static byte[] Read(BinaryReader reader, int count) {
            byte[] bytes=reader.ReadBytes(count);
            if (bytes.Length!=count) throw new InvalidDataException("Truncated ZIP metadata; source kept.");
            return bytes;
        }
        private static ushort U16(byte[] bytes,int offset) {return BitConverter.ToUInt16(bytes,offset);}
        private static uint U32(byte[] bytes,int offset) {return BitConverter.ToUInt32(bytes,offset);}
        private static ulong U64(byte[] bytes,int offset) {return BitConverter.ToUInt64(bytes,offset);}
        private static ulong Zip64Value(byte[] extra,ref int cursor,int end) {
            if (end-cursor<8) throw new InvalidDataException("Truncated ZIP64 entry size; source kept.");
            ulong value=U64(extra,cursor);cursor+=8;return value;
        }
        public static void Inspect(Stream stream,long maxTotal,long maxEntry,int maxEntries,long maxDirectory) {
            if (!stream.CanRead || !stream.CanSeek) throw new IOException("ZIP inspection requires a readable seekable stream.");
            long saved=stream.Position;
            try {
                if (stream.Length>maxTotal+maxDirectory+65557L) throw new InvalidDataException("ZIP exceeds the archive input-size limit; split the collection into smaller archives.");
                // Leave the caller's stream open and restore its position on all paths.
                using (BinaryReader reader=new BinaryReader(stream,System.Text.Encoding.UTF8,true)) {
                    int tailLength=(int)Math.Min(stream.Length,65557L);
                    stream.Position=stream.Length-tailLength;
                    byte[] tail=Read(reader,tailLength);int end=-1;
                    for (int i=tail.Length-4;i>=0;i--) {
                        if (U32(tail,i)!=0x06054b50U) continue;
                        // Framework ZipArchive can select a later end signature
                        // inside a comment even when its comment length is wrong.
                        // Never inspect one directory then open a different one.
                        if (tail.Length-i<22 || i+22+U16(tail,i+20)!=tail.Length)
                            throw new InvalidDataException("ZIP end record is ambiguous or truncated.");
                        end=i;break;
                    }
                    if (end<0) throw new InvalidDataException("ZIP end record is missing or truncated.");
                    long endPosition=stream.Length-tailLength+end;
                    if (U16(tail,end+4)!=0 || U16(tail,end+6)!=0) throw new InvalidDataException("Split ZIP archives are unsupported.");
                    ulong count=U16(tail,end+10),onDisk=U16(tail,end+8),size=U32(tail,end+12),offset=U32(tail,end+16);
                    long directoryLimit=endPosition;bool zip64=false;
                    if (endPosition>=20) {
                        stream.Position=endPosition-20;byte[] locator=Read(reader,20);
                        if (U32(locator,0)==0x07064b50U) {
                            zip64=true;
                            if (U32(locator,4)!=0 || U32(locator,16)!=1) throw new InvalidDataException("Split ZIP64 archives are unsupported.");
                            ulong position=U64(locator,8);
                            if (position>(ulong)(endPosition-20) || (ulong)(endPosition-20)-position<56) throw new InvalidDataException("Invalid ZIP64 directory location.");
                            stream.Position=(long)position;byte[] record=Read(reader,56);ulong recordSize=U64(record,4);
                            if (U32(record,0)!=0x06064b50U || recordSize<44 || recordSize!=(ulong)(endPosition-20)-position-12) throw new InvalidDataException("Invalid ZIP64 end record.");
                            if (U32(record,16)!=0 || U32(record,20)!=0) throw new InvalidDataException("Split ZIP64 archives are unsupported.");
                            ulong count64=U64(record,32),onDisk64=U64(record,24),size64=U64(record,40),offset64=U64(record,48);
                            // .NET versions differ in when they prefer ZIP64.
                            // Ordinary non-sentinel fields must describe the
                            // same directory as the extended record.
                            if ((count!=0xffffU && count!=count64) || (onDisk!=0xffffU && onDisk!=onDisk64) ||
                                (size!=0xffffffffU && size!=size64) || (offset!=0xffffffffU && offset!=offset64))
                                throw new InvalidDataException("ZIP and ZIP64 directory records disagree.");
                            onDisk=onDisk64;count=count64;size=size64;offset=offset64;directoryLimit=(long)position;
                        }
                    }
                    if (!zip64 && (size==0xffffffffU || offset==0xffffffffU)) throw new InvalidDataException("ZIP64 directory locator is missing.");
                    if (count>(ulong)maxEntries) throw new InvalidDataException("ZIP entry-count limit exceeded; split the collection into smaller archives.");
                    if (size>(ulong)maxDirectory) throw new InvalidDataException("ZIP metadata-size limit exceeded; source kept.");
                    if (onDisk!=count || count>size/46 || offset>(ulong)directoryLimit || size!=(ulong)directoryLimit-offset) throw new InvalidDataException("ZIP directory bounds are invalid.");
                    long directoryEnd=(long)(offset+size);stream.Position=(long)offset;ulong total=0;
                    for (ulong i=0;i<count;i++) {
                        if (directoryEnd-stream.Position<46) throw new InvalidDataException("Truncated ZIP directory entry.");
                        byte[] header=Read(reader,46);
                        if (U32(header,0)!=0x02014b50U) throw new InvalidDataException("Invalid ZIP directory entry.");
                        if ((U16(header,8)&0x2041)!=0) throw new InvalidDataException("Encrypted ZIP entries are unsupported.");
                        if (U16(header,34)!=0) throw new InvalidDataException("Split ZIP entries are unsupported.");
                        int nameLength=U16(header,28),extraLength=U16(header,30),commentLength=U16(header,32);
                        if (nameLength>4096) throw new InvalidDataException("ZIP entry name exceeds the safe path-length limit.");
                        if (nameLength+extraLength+commentLength>directoryEnd-stream.Position) throw new InvalidDataException("Truncated ZIP entry metadata.");
                        stream.Position+=nameLength;byte[] extra=Read(reader,extraLength);stream.Position+=commentLength;
                        ulong expanded=U32(header,24),compressed=U32(header,20),localOffset=U32(header,42);
                        bool needExpanded=expanded==0xffffffffU,needCompressed=compressed==0xffffffffU,needOffset=localOffset==0xffffffffU;
                        if (needExpanded || needCompressed || needOffset) {
                            bool found=false;
                            for (int field=0;field+4<=extra.Length;) {
                                int length=U16(extra,field+2),next=field+4+length;
                                if (next>extra.Length) throw new InvalidDataException("Truncated ZIP extra field.");
                                if (U16(extra,field)==1) {
                                    int cursor=field+4;
                                    if (needExpanded) expanded=Zip64Value(extra,ref cursor,next);
                                    if (needCompressed) compressed=Zip64Value(extra,ref cursor,next);
                                    if (needOffset) localOffset=Zip64Value(extra,ref cursor,next);
                                    // Framework ZipArchive ignores overlong
                                    // ZIP64 fields instead of using these sizes.
                                    if (cursor!=next) throw new InvalidDataException("ZIP64 entry contains unexpected size fields.");
                                    found=true;break;
                                }
                                field=next;
                            }
                            if (!found) throw new InvalidDataException("ZIP64 entry sizes are missing.");
                        }
                        if (expanded>(ulong)maxEntry) throw new InvalidDataException("ZIP entry expanded-size limit exceeded; source kept.");
                        if (expanded>(ulong)maxTotal-total) throw new InvalidDataException("ZIP expanded-size limit exceeded; split the collection into smaller archives.");
                        if (compressed>(ulong)stream.Length || localOffset>offset || compressed>offset-localOffset) throw new InvalidDataException("ZIP entry data bounds are invalid.");
                        total+=expanded;
                    }
                    // ZipArchive can read beyond a dishonest declared count.
                    // Require the inspected entries to consume the entire
                    // directory, so materialization cannot find extra entries.
                    if (stream.Position!=directoryEnd) throw new InvalidDataException("ZIP directory entry count does not match its metadata.");
                }
            } finally {stream.Position=saved;}
        }
        public static long CopyBounded(Stream input,Stream output,long maximum) {
            byte[] buffer=new byte[1048576];long total=0;int count;
            while ((count=input.Read(buffer,0,buffer.Length))>0) {
                if (count>maximum-total) throw new InvalidDataException("Expanded input exceeds its declared or allowed size; source kept.");
                output.Write(buffer,0,count);total+=count;
            }
            return total;
        }
    }
}
'@
}

function Assert-ArchiveBudget {
    param([Parameter(Mandatory=$true)][IO.Stream]$Stream,[ValidateSet('Media','Floppy')][string]$Profile='Media')
    Initialize-ArchiveLimits
    [long]$total=64GB;[long]$entry=16GB
    if ($Profile -eq 'Floppy') {$total=8GB;$entry=512MB}
    [OptiMiyoo.ArchiveLimits]::Inspect($Stream,$total,$entry,20000,64MB)
}

function Open-ArchiveWithBudget {
    param([Parameter(Mandatory=$true)][string]$Path,[ValidateSet('Media','Floppy')][string]$Profile='Media')
    Add-Type -AssemblyName System.IO.Compression
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        Assert-ArchiveBudget -Stream $stream -Profile $Profile
        return (New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Read,$false))
    } catch {$stream.Dispose();throw}
}
