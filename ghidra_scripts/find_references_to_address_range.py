#@category Function Analysis
#@menupath Search.Find Direct References to Address

from ghidra.program.util import ProgramMemoryUtil
from ghidra.program.model.address import AddressSet

# Define the target address range start and end
start_addr_string = "0x800D0000"
end_addr_string = "0x800E0000"

# Get the address factory
addrFactory = currentProgram.getAddressFactory()
start_addr = addrFactory.getDefaultAddressSpace().getAddress(int(start_addr_string, 16))
end_addr = addrFactory.getDefaultAddressSpace().getAddress(int(end_addr_string, 16))

# Create an address set for the range
address_set = AddressSet(start_addr, end_addr)

# Iterate over addresses in the range and find references
print("Searching for references to memory range: {} - {}".format(start_addr, end_addr))

for addr in address_set.iterator():
    # Find direct references to the current address in the range
    references = ProgramMemoryUtil.findDirectReferences(currentProgram, 4, addr, monitor) # 4 is the alignment in bytes
    if references:
        for ref_addr in references:
            print("Reference found at: {}".format(ref_addr))

print("Search complete.")