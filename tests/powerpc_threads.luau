local Platform=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_threads_cases")(Platform,require("./powerpc_threads_owned_probe"))
print("POWERPC_THREADS",report.checks,report.quanta,report.childrenPerRun)
