--!optimize 2
-- Headless PowerPC64 foundation and an explicit, currently unavailable PS3 profile.
local CPU=script and require(script.Parent.RoEmu_PowerPC_CPU) or require("./RoEmu_PowerPC_CPU")
local Platform={VERSION="0.1.0",ARCH="powerpc64"}
Platform.CAPABILITIES={
	schema=1,architecture="powerpc64",profile="ps3-cell",endianness="big",
	maturity="integer-subset",headless=true,flatBinary=true,
	memory={model="flat-ram-window",translated=false,full64BitAddressSpace=false},
	cpu={registerBits=64,exactIntegerPairs=true,integerSubset=true,completeISA=false,
		mmu=false,privilegedMode=false,floatingPoint=false,altivec=false,smt=false,spu=false},
	devices={flatRAM=true,rsx=false,ps3Storage=false,interruptController=false,usb=false,audio=false},
	loaders={elf64=false,self=false,pup=false},
	ps3={lv1=false,lv2=false,secureBoot=false,cellOS=false,gameOS=false,bootSupported=false},
}
function Platform.new(options) return CPU.new(options) end
function Platform.Status()
	return {architecture=Platform.ARCH,profile="ps3-cell",phase="not-bootable",
		bootSupported=false,cellOSSupported=false,gameOSSupported=false,
		integerSubsetImplemented=true,firmwareIncluded=false,
		missing={"complete PPE/PowerPC64 ISA and MMU","Cell SPE/SPU and MFC/DMA",
			"RSX graphics","PS3 interrupt and storage devices","LV1/LV2 and PS3 boot platform"}}
end
function Platform.AttemptBoot()
	return false,{code="powerpc-platform-incomplete",
		message="El perfil PowerPC/PS3 esta preparado, pero CellOS/GameOS todavia no puede arrancar. Puedes iniciar RV32 o i386.",
		capabilities=Platform.Status()}
end
function Platform.SelfTest()
	local bit=bit32
	local function d(op,rt,ra,imm) return bit.bor(bit.lshift(op,26),bit.lshift(rt,21),bit.lshift(ra,16),bit.band(imm,65535)) end
	local words={d(14,3,0,7),d(14,4,0,35),0x7CA32214,d(36,5,0,0x200),
		d(58,6,0,0x208),d(14,6,6,1),d(62,6,0,0x210),d(14,7,0,3),
		0x7CE903A6,d(14,8,8,1),0x4200FFFC,0x60000000}
	local code=buffer.create(#words*4)
	for i,word in ipairs(words) do
		for byte=0,3 do buffer.writeu8(code,(i-1)*4+byte,bit.band(bit.rshift(word,(3-byte)*8),255)) end
	end
	local cpu=Platform.new({ramBytes=65536})
	cpu:load(code,0)
	-- 2^53 + 1 must survive exactly, beyond Luau's scalar integer precision.
	buffer.writeu8(cpu.ram,0x209,0x20)
	local result=cpu:run(16)
	local high,low=cpu:getRegister(6)
	local _,counter=cpu:getRegister(8)
	local passed=result.kind=="ok" and cpu.pcLo==#words*4 and cpu.pcHi==0
		and buffer.readu8(cpu.ram,0x203)==42 and high==0x00200000 and low==1
		and buffer.readu8(cpu.ram,0x217)==1 and counter==3 and cpu.ctrLo==0 and cpu.ctrHi==0
	return passed,{kind=result.kind,instructions=cpu.instructions,answer=buffer.readu8(cpu.ram,0x203),
		exact64=high==0x00200000 and low==1,countedBranch=counter==3,ps3BootSupported=false}
end
return Platform
