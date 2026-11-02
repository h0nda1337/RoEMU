local Platform=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_fp_compute_cases")(Platform,require("./powerpc_fp_compute_vectors"),require("./powerpc_fp_exception_vectors"),require("./powerpc_floating_owned_probe"))
print("POWERPC_FP_COMPUTE",report.checks,report.computeVectors,report.exceptionVectors,report.exitStatus)
