. (Join-Path $PSScriptRoot 'compile_support.ps1')
# Validate native NIB/NBZ input before nibconv reads its fixed-size buffers.
# This is structural validation, not a guarantee that a game or dump is playable.
# NBZ decoding follows the bundled NIBTools LZ77 stream format, with explicit
# input, integer, back-reference and output bounds absent from the native reader.
function Initialize-NibValidation {
    if ('OptiMiyoo.NibInput' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
using System.Text;
namespace OptiMiyoo {
    public static class NibInput {
        const int TrackSize = 8192;
        const int MaxTracks = 84;
        const int MaxNib = 256 + MaxTracks * TrackSize;
        const int NativeBuffer = 86 * TrackSize;
        static InvalidDataException Bad(string reason) {
            return new InvalidDataException("Invalid or truncated NIB/NBZ: " + reason + ". Original kept.");
        }
        static uint ReadVariable(byte[] input, ref int position) {
            uint value = 0;
            for (int count = 0; count < 5; count++) {
                if (position >= input.Length) throw Bad("incomplete NBZ reference");
                byte next = input[position++];
                if (value > (UInt32.MaxValue >> 7)) throw Bad("NBZ reference overflow");
                value = (value << 7) | (uint)(next & 127);
                if ((next & 128) == 0) return value;
            }
            throw Bad("NBZ reference overflow");
        }
        static byte[] Decode(byte[] input) {
            if (input.Length < 2) throw Bad("empty NBZ stream");
            byte marker = input[0];
            byte[] output = new byte[MaxNib];
            int position = 1, written = 0;
            while (position < input.Length) {
                byte symbol = input[position++];
                if (symbol != marker) {
                    if (written >= output.Length) throw Bad("NBZ expands beyond the supported disk size");
                    output[written++] = symbol;
                    continue;
                }
                if (position >= input.Length) throw Bad("incomplete NBZ marker");
                if (input[position] == 0) {
                    position++;
                    if (written >= output.Length) throw Bad("NBZ expands beyond the supported disk size");
                    output[written++] = marker;
                    continue;
                }
                uint length = ReadVariable(input, ref position);
                uint offset = ReadVariable(input, ref position);
                if (length == 0 || offset == 0 || offset > (uint)written) throw Bad("invalid NBZ back-reference");
                if (length > (uint)(output.Length - written)) throw Bad("NBZ expands beyond the supported disk size");
                for (uint i = 0; i < length; i++) {
                    output[written] = output[written - (int)offset];
                    written++;
                }
            }
            Array.Resize(ref output, written);
            return output;
        }
        static void CheckNib(byte[] bytes) {
            if (bytes.Length < 256 || Encoding.ASCII.GetString(bytes, 0, 13) != "MNIB-1541-RAW") throw Bad("missing NIB header");
            bool[] seen = new bool[86];
            int count = 0;
            bool terminated = false;
            for (int position = 16; position < 256; position += 2) {
                int track = bytes[position];
                if (track == 0) { terminated = true; break; }
                if (track < 2 || track > 85 || seen[track]) throw Bad("invalid or duplicate track number");
                seen[track] = true;
                count++;
            }
            if (!terminated || count == 0 || count > MaxTracks) throw Bad("empty or invalid track table");
            if (bytes.Length != 256 + count * TrackSize) throw Bad("track data length does not match the NIB header");
        }
        public static void Validate(string path) {
            byte[] bytes;
            // Size and bytes must come from the same locked handle. A pathname
            // length check followed by ReadAllBytes can allocate an arbitrarily
            // grown/replaced input before its structural checks run.
            using (FileStream input = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                long length = input.Length;
                if (length < 1 || length > NativeBuffer) throw Bad("unsupported input size");
                bytes = new byte[(int)length];
                int total = 0;
                while (total < bytes.Length) {
                    int read = input.Read(bytes, total, bytes.Length - total);
                    if (read == 0) throw Bad("input changed during validation");
                    total += read;
                }
                if (input.ReadByte() != -1) throw Bad("input changed during validation");
            }
            if (String.Equals(Path.GetExtension(path), ".nbz", StringComparison.OrdinalIgnoreCase)) bytes = Decode(bytes);
            else if (!String.Equals(Path.GetExtension(path), ".nib", StringComparison.OrdinalIgnoreCase)) throw Bad("unexpected input extension");
            CheckNib(bytes);
        }
    }
}
'@
}

function Assert-NibSource([string]$Path) {
    Initialize-NibValidation
    [OptiMiyoo.NibInput]::Validate($Path)
}

# IPF container integrity follows the bundled CAPS CapsID/CapsData records.
# This verifies lengths and checksums, not media geometry or faithful conversion.
function Initialize-IpfValidation {
    if ('OptiMiyoo.IpfInputV1' -as [type]) {return}
    Add-OptiMiyooType -TypeDefinition @'
using System;
using System.IO;
namespace OptiMiyoo {
    public static class IpfInputV1 {
        const long MaximumInput = 512L * 1024 * 1024;
        static readonly uint[] Table = MakeTable();
        static uint[] MakeTable() {
            uint[] table = new uint[256];
            for (uint i = 0; i < table.Length; i++) {
                uint value = i;
                for (int bit = 0; bit < 8; bit++)
                    value = (value >> 1) ^ ((value & 1) != 0 ? 0xedb88320U : 0);
                table[i] = value;
            }
            return table;
        }
        static InvalidDataException Bad(string reason) {
            return new InvalidDataException("Invalid or truncated IPF: " + reason + ". Original kept.");
        }
        static uint U32(byte[] bytes, int offset) {
            return ((uint)bytes[offset] << 24) | ((uint)bytes[offset + 1] << 16) |
                   ((uint)bytes[offset + 2] << 8) | bytes[offset + 3];
        }
        static uint Update(uint crc, byte[] bytes, int count) {
            for (int i = 0; i < count; i++) crc = Table[(crc ^ bytes[i]) & 255] ^ (crc >> 8);
            return crc;
        }
        sealed class Progress {
            readonly Action<long,long> callback;
            readonly long length;
            long last;
            public Progress(Action<long,long> callback, long length) {this.callback = callback; this.length = length;}
            public int LimitRead(int count, long position) {
                return callback == null ? count : (int)Math.Min(count, 65536 - (position - last));
            }
            public void Poll(long position, bool force) {
                if (callback != null && (force || position - last >= 65536)) {
                    callback(position, length);
                    last = position;
                }
            }
        }
        static void ReadExact(Stream input, byte[] buffer, int count, long length, Progress progress) {
            int offset = 0;
            while (offset < count) {
                int read = input.Read(buffer, offset, progress.LimitRead(count - offset, input.Position));
                if (read <= 0) throw Bad("record or data payload is incomplete");
                offset += read;
                progress.Poll(input.Position, false);
            }
        }
        static uint ReadBody(Stream input, long count, byte[] buffer, uint crc, long length, Progress progress) {
            while (count > 0) {
                int take = (int)Math.Min(count, buffer.Length);
                ReadExact(input, buffer, take, length, progress);
                crc = Update(crc, buffer, take);
                count -= take;
            }
            return crc;
        }
        public static void Validate(Stream input, Action<long,long> progress) {
            if (input == null || !input.CanRead || !input.CanSeek)
                throw new ArgumentException("A readable, seekable IPF stream is required.");
            long saved = input.Position;
            try {
                long length = input.Length;
                if (length < 108 || length > MaximumInput) throw Bad("unsupported input size");
                input.Position = 0;
                Progress report = new Progress(progress, length);
                report.Poll(0, true);
                byte[] header = new byte[12], dataHeader = new byte[16], buffer = new byte[65536];
                bool first = true;
                while (input.Position < length) {
                    long start = input.Position;
                    if (length - start < header.Length) throw Bad("record header is incomplete");
                    ReadExact(input, header, header.Length, length, report);
                    uint size = U32(header, 4), expected = U32(header, 8);
                    if (size < 12 || size > length - start) throw Bad("record length exceeds its container");
                    if (first && (header[0] != 'C' || header[1] != 'A' || header[2] != 'P' || header[3] != 'S' || size != 12))
                        throw Bad("missing CAPS header");
                    first = false;
                    bool data = header[0] == 'D' && header[1] == 'A' && header[2] == 'T' && header[3] == 'A';
                    uint payload = 0, dataCrc = 0;
                    header[8] = header[9] = header[10] = header[11] = 0;
                    uint crc = Update(0xffffffffU, header, header.Length);
                    long body = size - 12;
                    if (data) {
                        if (body < dataHeader.Length) throw Bad("DATA metadata is incomplete");
                        ReadExact(input, dataHeader, dataHeader.Length, length, report);
                        crc = Update(crc, dataHeader, dataHeader.Length);
                        payload = U32(dataHeader, 0); dataCrc = U32(dataHeader, 8);
                        body -= dataHeader.Length;
                    }
                    // Unknown/extended records retain their declared byte layout.
                    crc = ReadBody(input, body, buffer, crc, length, report);
                    if ((crc ^ 0xffffffffU) != expected) throw Bad("record CRC does not match");
                    if (data) {
                        if (payload > length - input.Position) throw Bad("DATA payload exceeds its container");
                        uint actual = ReadBody(input, payload, buffer, 0xffffffffU, length, report) ^ 0xffffffffU;
                        // CAPS permits an absent (zero) DATA checksum.
                        if (dataCrc != 0 && actual != dataCrc) throw Bad("DATA CRC does not match");
                    }
                }
                if (input.Length != length || input.ReadByte() != -1) throw Bad("input changed during validation");
                report.Poll(length, true);
            } finally {
                input.Position = saved;
            }
        }
    }
}
'@
}
