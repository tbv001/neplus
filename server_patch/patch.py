import os
import shutil
import re

def hex_to_regex(hex_str):
    hex_str = hex_str.replace(" ", "")
    pattern = b""
    for i in range(0, len(hex_str), 2):
        byte = hex_str[i:i+2]
        if byte == "??":
            pattern += b"."
        else:
            pattern += re.escape(bytes.fromhex(byte))
    return pattern

def patch_binary(file_path):
    backup_path = file_path + ".bak"
    if not os.path.exists(backup_path):
        shutil.copy2(file_path, backup_path)
        
    if not os.path.exists(file_path):
        print(f"Error: {file_path} not found.")
        return
    
    patches = [
        # -------------------------------
        # --- AddNode (sub_18026EDE0) ---
        # -------------------------------
        
        # 1. AddNode Allocation (0x18026ee0c)
        # Context: ... call sub_180392390; mov ecx, 10000h; call sub_180392390 ...
        {
            "name":    "AddNode Allocation Size",
            "find":    "e8 ?? ?? ?? ?? b9 00 00 01 00 e8 ?? ?? ?? ??",
            "replace": "?? ?? ?? ?? ?? ?? 00 00 04 00 ?? ?? ?? ?? ??"
        },
        
        # 2. AddNode Limit Check (0x18026ee1a)
        # Context: mov [rbx+10h], rax; cmp dword ptr [rbx+8], 2000h; jl short loc_18026EE33
        {
            "name":    "AddNode Limit Check",
            "find":    "48 89 43 10 81 7b 08 00 20 00 00 7c ??",
            "replace": "?? ?? ?? ?? ?? ?? ?? ?? 80 00 00 ?? ??"
        },
        
        
        # -----------------------------------
        # --- LoadNetwork (sub_180275770) ---
        # -----------------------------------
        
        # 3. LoadNetwork Limit Check (0x180275a71)
        # Context: mov edi, eax; cmp eax, 2000h; ja loc_1802763B0
        {
            "name":    "LoadNetwork Limit Check",
            "find":    "8b f8 3d 00 20 00 00 0f 87 ?? ?? ?? ??",
            "replace": "?? ?? ?? 00 80 00 00 ?? ?? ?? ?? ?? ??"
        },
        
        
        # -----------------------------------------------------
        # --- NetworkManager Initialization (sub_180270510) ---
        # -----------------------------------------------------
        
        # 4. Structs Allocation Size (0x1802705a2)
        # Context: jz short loc_1802705D2; mov ecx, 18000h; call sub_180392390
        {
            "name":    "Manager Structs Allocation Size",
            "find":    "74 ?? b9 00 80 01 00 e8 ?? ?? ?? ??",
            "replace": "?? ?? ?? 00 06 00 00 ?? ?? ?? ?? ??"
        },
        
        # 5. Limit Constant for initialization (0x1802705b1)
        # Context: jz short loc_1802705D2; mov edx, 2000h; lea rcx, [rax+4]
        {
            "name":    "Manager Init Loop Constant",
            "find":    "74 ?? ba 00 20 00 00 48 8d 48 04",
            "replace": "?? ?? ?? 00 80 00 00 ?? ?? ?? ??"
        },
        
        # 6. Index Table Allocation Size (0x1802705dd)
        # Context: lea rsi, [rbp+18h]; mov ecx, 8000h; mov [r14], rbx
        {
            "name":    "Index Table Allocation Size",
            "find":    "4c 8d 76 18 b9 00 80 00 00 49 89 1e",
            "replace": "?? ?? ?? ?? ?? 00 02 00 00 ?? ?? ??"
        },
        
        # 7. LEA Offset for Index Table (0x7FFC -> 0x1FFFC) (0x1802705f0)
        # Context: mov [r14], rax; lea rcx, [rax+7FFCh]; cmp rcx, r14
        {
            "name":    "Index Table LEA Offset",
            "find":    "49 89 06 48 8d 88 fc 7f 00 00 49 3b c6",
            "replace": "?? ?? ?? ?? ?? ?? fc ff 01 00 ?? ?? ??"
        },
        
        # 8. Loop Limit for Index Table Clearing (0x18027061e)
        # Context: add rcx, 4; cmp rcx, 8000h; jl short loc_180270610
        {
            "name":    "Index Table Loop Limit",
            "find":    "83 c1 04 48 81 f9 00 80 00 00 7c ??",
            "replace": "?? ?? ?? ?? ?? ?? 00 02 00 00 ?? ??"
        },
        
        # 9. Memset Size for Index Table (0x18027062e)
        # Context: mov edx, 0FFFFFFFFh; mov r8d, 8000h; mov rcx, rax
        {
            "name":    "Index Table Memset Size",
            "find":    "ff ff ff ff 41 b8 00 80 00 00 48 8b c8 e8",
            "replace": "?? ?? ?? ?? ?? ?? 00 02 00 00 ?? ?? ?? ??"
        },
    ]

    print(f"Patching server.dll\n")
    
    with open(file_path, "rb") as f:
        data = bytearray(f.read())
    
    patchCount = 0
    modified = False
    
    for p in patches:
        regex_pattern = hex_to_regex(p["find"])
        matches = list(re.finditer(regex_pattern, data, re.DOTALL))
        
        count = len(matches)
        if count == 0:
            print(f"[-] Error: Pattern for '{p['name']}' not found.")
            continue
            
        if count > 1:
            print(f"[-] Error: Pattern for '{p['name']}' matched more than one.")
            continue
            
        match = matches[0]
        idx = match.start()
        
        replace_hex = p["replace"].replace(" ", "")
        for i in range(0, len(replace_hex), 2):
            byte_hex = replace_hex[i:i+2]
            if byte_hex != "??":
                data[idx + (i // 2)] = int(byte_hex, 16)
        
        print(f"[+] Applied patch: {p['name']} at {hex(idx)}")
        modified = True
        patchCount += 1

    if modified:
        with open(file_path, "wb") as f:
            f.write(data)
            
        print("\nPatching complete successfully.")
        
        if patchCount < len(patches):
            print("Warning: Some patches aren't applied. The game may crash during load or the modification will not behave as expected.")
    else:
        print("\nNo patches were applied.")

if __name__ == "__main__":
    dll_path = r".\server.dll"
    patch_binary(dll_path)
