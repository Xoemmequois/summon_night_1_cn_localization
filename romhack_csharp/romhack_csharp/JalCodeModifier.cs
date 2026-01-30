using System.Buffers.Binary;

namespace romhack_csharp;

public static class JalCodeModifier
{

    private const uint BaseAddress = 0x80010000;
    private const uint CodeStart = 0x800;
    private const uint AddressMask = 0xF0000000u;
    private const uint InstrOpMask = 0x3FFFFFFu;

    public static void ModifyCode(byte[] binary, uint address, uint newJumpAddress)
    {
        if ((address & AddressMask) != (newJumpAddress & AddressMask))
        {
            throw new ApplicationException("exceed jump range");
        }
        var fileAddr = address - BaseAddress + CodeStart;
        var span = binary.AsSpan((int)fileAddr);
        var oldInstr = BinaryPrimitives.ReadUInt32LittleEndian(span);
        var opCode = oldInstr >> 26;
        if (opCode != 0x3)
        {
            throw new ApplicationException($"old instruction is not JAL, file addr {fileAddr:X}");
        }
        var oldAddr = ((oldInstr & InstrOpMask) << 2) | (address & AddressMask);
        Console.WriteLine($"Modify JAL instruction at {address:X8} from {oldAddr:X8} to {newJumpAddress:X8}");
        var newInstrAddr = (newJumpAddress & (~AddressMask)) >> 2;
        var newInstr = 0x3 << 26 | newInstrAddr & InstrOpMask;
        BinaryPrimitives.WriteUInt32LittleEndian(span, newInstr);
    }
}