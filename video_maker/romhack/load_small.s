.set noreorder

load_small:
    addiu   $sp, $sp, -40
    sw      $ra, 36($sp)

    # 构造文件名 "\S.F;1\0\0" 到栈
    # LE: "\S.F" = 0x5C 0x53 0x2E 0x46 → 0x462E535C
    # LE: ";1\0\0" = 0x3B 0x31 0x00 0x00 → 0x0000313B
    li      $t0, 0x462e535c
    sw      $t0, 24($sp)
    li      $t0, 0x0000313b
    sw      $t0, 28($sp)

    addiu   $a0, $sp, 8
    jal     0x80072084              # CdSearchFile
    addiu   $a1, $sp, 24

    addiu   $a0, $sp, 8
    lui     $a1, 0x801b
    ori     $a1, $a1, 0x1000        # 目标地址: 0x801B1000
    jal     0x80030e3c              # CDBlockRead
    li      $a2, SMALL_COUNT         # sector 数, 由 --defsym 传入

    lw      $ra, 36($sp)
    nop                             # lw 延迟槽
    jr      $ra
    addiu   $sp, $sp, 40            # jr 延迟槽
