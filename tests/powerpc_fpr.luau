local Platform=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_fpr_cases")(Platform,require("./powerpc_fpr_vectors"),require("./powerpc_threads_owned_probe"))
print("POWERPC_FPR",report.checks,report.rawBitVectors,report.threadSwitches,report.threadContexts)
