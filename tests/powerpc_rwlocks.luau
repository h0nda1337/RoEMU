local P=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_rwlocks_cases")(P,require("./powerpc_rwlocks_owned_probe"))
print("POWERPC_RWLOCKS",report.checks,report.quanta,report.protocolProfiles,report.compiledChildrenPerRun)
