--[[
    FName_Constructor.lua — UE4SS signature override for RUNNING TRAIN (UE 5.7)

    WHY THIS FILE EXISTS
    --------------------
    patternsleuth's FNameCtorWchar resolver
    (patternsleuth/src/resolvers/unreal/fname.rs, PEImage impl) matches a fixed set
    of code shapes around xrefs to the wide literals "MovementComponent0" /
    "TGPUSkinVertexFactoryUnlimited". In this UE 5.7 build none of those shapes are
    present -- e.g. the "MovementComponent0" site is

        lea rdx, [rip+<str>]      ; name
        lea rcx, [rip+<global>]   ; this
        jmp <FName ctor>

    which is the resolver's third pattern minus its required `41 B8 01 00 00 00`
    prefix. The resolver therefore yields zero candidates and reports
    "FNameCtorWchar: expected at least one value". Because `fname_ctor_wchar` is the
    only *non-optional* symbol among the three that failed (see
    deps/first/patternsleuth_bind/src/lib.rs -- `fuobject_hash_tables_get` and
    `gnatives` are declared optional), the whole scan fails and UE4SS aborts with
    "Fatal Error: PS scan timed out".

    HOW THE ADDRESS WAS FOUND
    -------------------------
    FNameHelper::Make(FName* out, FWideStringViewWithWidth& view, EFindName, int32 number)
    lives at RVA 0x12d29d0 and has 7 direct callers -- the FName constructor
    overloads. Of those, only one saves its incoming third argument (r8d) and
    forwards it to Make as the EFindName parameter:

        0x1412c81d0  mov  [rsp+8], rbx
                     push rdi
                     sub  rsp, 0x30
                     mov  rbx, rcx          ; this
                     mov  [rsp+0x20], rdx   ; view.Data = Name
                     xor  ecx, ecx
                     mov  edi, r8d          ; <-- save EFindName
                     mov  r10, rdx
                     mov  r9d, ecx
                     movzx eax, word [rdx]  ; 16-bit char -> WIDECHAR
                     ...
        0x1412c8268  mov  r8d, edi          ; <-- forward EFindName to Make
        0x1412c826e  call 0x1412d29d0

    The other overloads hardcode `mov r8d, 1` (FNAME_Add) and so would silently turn
    every FNAME_Find lookup into an insert; this one honours the requested mode.

        => FName::FName(FName* this, const WIDECHAR* Name, EFindName FindType)
           RVA 0x12c81d0   (preferred image base 0x140000000 -> 0x1412c81d0)

    The 32-byte prologue below occurs exactly once in the code section, and it
    contains no RIP-relative displacements or rel32 operands, so no wildcards are
    needed and it is stable regardless of ASLR.

    Regenerate with:
        python scripts/find_make_callers.py <shipping exe> 1412d29d0
]]

function Register()
    -- mov [rsp+8],rbx / push rdi / sub rsp,30 / mov rbx,rcx / mov [rsp+20],rdx
    -- xor ecx,ecx / mov edi,r8d / mov r10,rdx / mov r9d,ecx / test rdx,rdx
    return "48 89 5C 24 08 57 48 83 EC 30 48 8B D9 48 89 54 24 20 33 C9 41 8B F8 4C 8B D2 44 8B C9 48 85 D2"
end

function OnMatchFound(MatchAddress)
    -- The pattern starts at the first instruction of the function, so the match
    -- address is already the address UE4SS wants.
    return MatchAddress
end
