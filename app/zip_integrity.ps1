# ZIP CRCs are read from the central directory, including ZIP64 metadata.
# .NET Framework's ZipArchive does not expose or enforce these checksums.
# Format reference: https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
# Shared by playlist and converter workers; no extra runtime or DLL is needed.
function Initialize-ZipIntegrity {
    if ('OptiMiyoo.ZipCrc32' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
namespace OptiMiyoo {
    public sealed class ZipCrc32 {
        private uint state = 0xffffffffU;
        private static readonly uint[] table = MakeTable();
        private static uint[] MakeTable() {
            uint[] result = new uint[256];
            for (uint i = 0; i < 256; i++) {
                uint c = i;
                for (int b = 0; b < 8; b++) c = (c >> 1) ^ ((c & 1) == 0 ? 0 : 0xedb88320U);
                result[i] = c;
            }
            return result;
        }
        public void Update(byte[] bytes, int count) {
            if (count < 0 || count > bytes.Length) throw new ArgumentOutOfRangeException("count");
            uint c = state;
            for (int i = 0; i < count; i++) c = table[(c ^ bytes[i]) & 255] ^ (c >> 8);
            state = c;
        }
        public void Verify(uint expected, string name) {
            uint actual = state ^ 0xffffffffU;
            if (actual != expected) throw new InvalidDataException(
                "ZIP CRC mismatch: " + name + " (expected " + expected.ToString("X8") +
                ", read " + actual.ToString("X8") + "). Archive is damaged; source kept.");
        }
        private static byte[] ReadBytes(BinaryReader reader, int count) {
            byte[] bytes = reader.ReadBytes(count);
            if (bytes.Length != count) throw new InvalidDataException("Truncated ZIP directory.");
            return bytes;
        }
        private static ushort U16(byte[] bytes, int pos) { return BitConverter.ToUInt16(bytes, pos); }
        private static uint U32(byte[] bytes, int pos) { return BitConverter.ToUInt32(bytes, pos); }
        private static ulong U64(byte[] bytes, int pos) { return BitConverter.ToUInt64(bytes, pos); }
        public static uint[] ReadChecksums(string path, int expectedCount) {
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (BinaryReader reader = new BinaryReader(stream)) {
                int tailLength = (int)Math.Min(stream.Length, 65557L);
                stream.Position = stream.Length - tailLength;
                byte[] tail = ReadBytes(reader, tailLength);
                int end = -1;
                for (int i = tail.Length - 22; i >= 0; i--) {
                    if (U32(tail, i) == 0x06054b50U && i + 22 + U16(tail, i + 20) == tail.Length) {
                        end = i; break;
                    }
                }
                if (end < 0) throw new InvalidDataException("ZIP end record is missing or truncated.");
                long endPosition = stream.Length - tailLength + end;
                if (U16(tail, end + 4) != 0 || U16(tail, end + 6) != 0)
                    throw new InvalidDataException("Split ZIP archives are unsupported. Combine the parts first.");
                ulong count = U16(tail, end + 10), onDisk = U16(tail, end + 8);
                ulong size = U32(tail, end + 12), offset = U32(tail, end + 16);
                long directoryLimit = endPosition;
                bool zip64 = false;
                if (endPosition >= 20) {
                    stream.Position = endPosition - 20;
                    byte[] locator = ReadBytes(reader, 20);
                    if (U32(locator, 0) == 0x07064b50U) {
                        zip64 = true;
                        if (U32(locator, 4) != 0 || U32(locator, 16) != 1)
                            throw new InvalidDataException("Split ZIP64 archives are unsupported.");
                        ulong position = U64(locator, 8);
                        if (position > (ulong)(endPosition - 20) || (ulong)(endPosition - 20) - position < 56)
                            throw new InvalidDataException("Invalid ZIP64 directory location.");
                        stream.Position = (long)position;
                        byte[] record = ReadBytes(reader, 56);
                        ulong recordSize = U64(record, 4);
                        if (U32(record, 0) != 0x06064b50U || recordSize < 44 ||
                            recordSize != (ulong)(endPosition - 20) - position - 12)
                            throw new InvalidDataException("Invalid ZIP64 end record.");
                        if (U32(record, 16) != 0 || U32(record, 20) != 0)
                            throw new InvalidDataException("Split ZIP64 archives are unsupported.");
                        onDisk = U64(record, 24); count = U64(record, 32);
                        size = U64(record, 40); offset = U64(record, 48);
                        directoryLimit = (long)position;
                    }
                }
                if (!zip64 && (size == 0xffffffffU || offset == 0xffffffffU))
                    throw new InvalidDataException("ZIP64 directory locator is missing.");
                if (onDisk != count || count != (ulong)expectedCount || count > size / 46 ||
                    offset > (ulong)directoryLimit || size > (ulong)directoryLimit - offset)
                    throw new InvalidDataException("ZIP directory count or bounds mismatch.");
                long directoryEnd = (long)(offset + size);
                stream.Position = (long)offset;
                uint[] checksums = new uint[expectedCount];
                for (int i = 0; i < expectedCount; i++) {
                    if (directoryEnd - stream.Position < 46) throw new InvalidDataException("Truncated ZIP directory entry.");
                    byte[] header = ReadBytes(reader, 46);
                    if (U32(header, 0) != 0x02014b50U) throw new InvalidDataException("Invalid ZIP directory entry.");
                    if ((U16(header, 8) & 0x2041) != 0) throw new InvalidDataException("Encrypted ZIP entries are unsupported.");
                    if (U16(header, 34) != 0) throw new InvalidDataException("Split ZIP entries are unsupported.");
                    checksums[i] = U32(header, 16);
                    int remaining = U16(header, 28) + U16(header, 30) + U16(header, 32);
                    if (remaining > directoryEnd - stream.Position) throw new InvalidDataException("Truncated ZIP entry metadata.");
                    stream.Position += remaining;
                }
                return checksums;
            }
        }
    }
}
'@
}
function Get-ZipChecksums([string]$Path,[int]$EntryCount) {
    Initialize-ZipIntegrity
    return ,([OptiMiyoo.ZipCrc32]::ReadChecksums($Path,$EntryCount))
}
