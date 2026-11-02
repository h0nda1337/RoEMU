local Platform=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_wait_cases")(Platform,require("./powerpc_process_owned_probe"))
print("POWERPC_WAIT",report.checks,report.indefiniteWaitParks,report.timeoutReacquires)
