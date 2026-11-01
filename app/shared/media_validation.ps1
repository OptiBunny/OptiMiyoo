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
                // The bundled aligner handles IDs 1..84. ID 85 is copied by its
                // reader but never assigned a track length, so it is silently lost.
                if (track < 2 || track > 84) throw Bad("track number is outside supported range 2..84");
                if (seen[track]) throw Bad("duplicate track number");
                seen[track] = true;
                count++;
            }
            if (!terminated || count == 0 || count > MaxTracks) throw Bad("empty or invalid track table");
            if (bytes.Length != 256 + count * TrackSize) throw Bad("track data length does not match the NIB header");
        }
        public static void Validate(Stream input, string extension, Action<long,long> progress) {
            if (input == null || !input.CanRead || !input.CanSeek)
                throw new ArgumentException("A readable, seekable NIB/NBZ stream is required.");
            long saved = input.Position;
            try {
                bool compressed = String.Equals(extension, ".nbz", StringComparison.OrdinalIgnoreCase);
                if (!compressed && !String.Equals(extension, ".nib", StringComparison.OrdinalIgnoreCase))
                    throw Bad("unexpected input extension");
                // Size and bytes come from the same borrowed, held stream. A
                // pathname length check followed by ReadAllBytes is not bounded.
                long length = input.Length;
                if (length < 1 || length > NativeBuffer) throw Bad("unsupported input size");
                input.Position = 0;
                if (progress != null) progress(0, length);
                byte[] bytes = new byte[(int)length];
                int total = 0;
                while (total < bytes.Length) {
                    int read = input.Read(bytes, total, Math.Min(65536, bytes.Length - total));
                    if (read <= 0) throw Bad("input changed during validation");
                    total += read;
                    if (progress != null) progress(total, length);
                }
                if (input.Length != length || input.ReadByte() != -1) throw Bad("input changed during validation");
                // Decoding is bounded by MaxNib (<1 MiB), including back-references.
                // Poll before and after that bounded work as well as each read.
                if (progress != null) progress(length, length);
                if (compressed) bytes = Decode(bytes);
                CheckNib(bytes);
                if (progress != null) progress(length, length);
            } finally {
                input.Position = saved;
            }
        }
        public static void Validate(string path) {
            using (FileStream input = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                Validate(input, Path.GetExtension(path), null);
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
using System.Collections.Generic;
using System.IO;
namespace OptiMiyoo {
    public static class IpfInputV1 {
        const long MaximumInput = 512L * 1024 * 1024;
        // A resource policy, not a geometry or maximum track-ID restriction.
        const int MaximumIdentifiers = 65536;
        struct IdentifierState {public byte Flags; public uint Cylinder, Head;}
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
                byte[] header = new byte[12], metadata = new byte[56], buffer = new byte[65536];
                // Ordered lookup avoids attacker-chosen hash-collision chains.
                SortedDictionary<uint,IdentifierState> identifiers = new SortedDictionary<uint,IdentifierState>();
                bool haveInfo = false, haveTracks = false;
                uint minCylinder = 0, maxCylinder = 0, minHead = 0, maxHead = 0;
                uint firstCylinder = uint.MaxValue, lastCylinder = 0, firstHead = uint.MaxValue, lastHead = 0;
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
                    bool image = header[0] == 'I' && header[1] == 'M' && header[2] == 'G' && header[3] == 'E';
                    bool track = header[0] == 'T' && header[1] == 'R' && header[2] == 'C' && header[3] == 'K';
                    bool descriptor = image || track;
                    bool info = header[0] == 'I' && header[1] == 'N' && header[2] == 'F' && header[3] == 'O';
                    uint payload = 0, dataCrc = 0, identifier = 0, cylinder = 0, side = 0;
                    header[8] = header[9] = header[10] = header[11] = 0;
                    uint crc = Update(0xffffffffU, header, header.Length);
                    long body = size - 12;
                    // IMGE ends its used fields with did; reserved/extension tails stay streamed.
                    int metadataLength = image ? 56 : (data || track ? 16 : (info ? 40 : 0));
                    // Bundled CAPS cannot load an INFO modifier larger than its 84-byte buffer.
                    if (info && body > 84) throw Bad("INFO metadata exceeds the supported native layout");
                    if (metadataLength != 0) {
                        if (body < metadataLength) throw Bad("track, INFO or DATA metadata is incomplete");
                        ReadExact(input, metadata, metadataLength, length, report);
                        crc = Update(crc, metadata, metadataLength);
                        if (descriptor || data) identifier = U32(metadata, image ? 52 : 12);
                        if (descriptor) {cylinder = U32(metadata, image ? 0 : 4); side = U32(metadata, image ? 4 : 8);}
                        if (info) {
                            // CAPS uses the last INFO record, including one following the tracks.
                            minCylinder = U32(metadata, 24); maxCylinder = U32(metadata, 28);
                            minHead = U32(metadata, 32); maxHead = U32(metadata, 36); haveInfo = true;
                        }
                        if (data) {payload = U32(metadata, 0); dataCrc = U32(metadata, 8);}
                        body -= metadataLength;
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
                    if (descriptor && identifier == 0) throw Bad("track has a zero DATA identifier");
                    if (descriptor) {
                        haveTracks = true;
                        firstCylinder = Math.Min(firstCylinder, cylinder); lastCylinder = Math.Max(lastCylinder, cylinder);
                        firstHead = Math.Min(firstHead, side); lastHead = Math.Max(lastHead, side);
                    }
                    if ((descriptor || data) && identifier != 0) {
                        IdentifierState state;
                        if (!identifiers.TryGetValue(identifier, out state) && identifiers.Count >= MaximumIdentifiers)
                            throw Bad("track/DATA identifier count exceeds its supported limit");
                        // CAPS retains the latest descriptor and DATA per ID. Before
                        // any DATA arrives, replacing a coordinate would lose that track.
                        if (descriptor) {
                            if (state.Flags == 1 && (state.Cylinder != cylinder || state.Head != side))
                                throw Bad("DATA identifier is reused before its pending track has data");
                            state.Cylinder = cylinder; state.Head = side;
                        }
                        state.Flags = (byte)(state.Flags | (descriptor ? 1 : 2));
                        identifiers[identifier] = state;
                    }
                }
                if (input.Length != length || input.ReadByte() != -1) throw Bad("input changed during validation");
                if (haveInfo && haveTracks && (firstCylinder < minCylinder || lastCylinder > maxCylinder ||
                    firstHead < minHead || lastHead > maxHead))
                    throw Bad("INFO geometry excludes a recorded track; conversion would omit it");
                int checkedIdentifiers = 0;
                foreach (IdentifierState state in identifiers.Values) {
                    if ((checkedIdentifiers++ & 1023) == 0) report.Poll(length, true);
                    if (state.Flags == 1) throw Bad("track has no matching DATA record");
                }
                report.Poll(length, true);
            } finally {
                input.Position = saved;
            }
        }
    }
}
'@
}
