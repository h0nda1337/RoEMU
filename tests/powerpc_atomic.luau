local Platform=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local report=require("./powerpc_atomic_cases")(Platform)
print("POWERPC_ATOMIC",report.checks,report.exactTimebase,report.reservations)
