--!native
--!optimize 2
-- Linux ya no necesita saltos por direcciones de una compilacion concreta.
-- El core implementa traps S/U, SBI a traves de OpenSBI, sret y sfence.vma.

print("[linuxStep] supervisor runtime v2")

task.spawn(function()
	while task.wait(0.05) do
		local core = rawget(_G, "RoEmuCore")
		if type(core) == "table" and core.__supervisor_v2 == true then
			print("[linuxStep] traps S/U, SBI y syscalls activos")
			return
		end
	end
end)
