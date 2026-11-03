local P=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_unaligned_cases")(P,require("./powerpc_unaligned_vectors"))
print("POWERPC_UNALIGNED",report.checks,report.vectors,report.cellFPAlignment)
