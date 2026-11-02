local Platform=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_process_cases")(Platform,require("./powerpc_process_owned_probe"))
print("POWERPC_PROCESS",report.checks,report.exitStatus,report.compiledTLSProcess)
