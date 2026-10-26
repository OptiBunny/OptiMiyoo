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
