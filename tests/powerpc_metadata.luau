local Platform=require("../src/ServerStorage/RoEmu_PowerPC_Platform")
local SFO=require("../src/ServerStorage/RoEmu_PS3_SFO")
local report=require("./powerpc_metadata_cases")(Platform,SFO,require("./powerpc_metadata_owned_probe"))
print("POWERPC_METADATA",report.checks,report.exitStatus,report.compiledSFOProcess)
