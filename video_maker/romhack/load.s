.set noreorder

ReadCustomFunc:
    addiu   $sp, $sp, -40       # 分配栈空间
    sw      $ra, 36($sp)        # 保护返回地址

    li      $t0, 0x462e435c     
    sw      $t0, 24($sp)        # 存入前4字节到栈
    li      $t0, 0x0000313b     

    jal     0x80030f40          # 调用第一个函数
    sw      $t0, 28($sp)        # 存入后4字节（含终止符）到栈


    addiu   $a0, $sp, 8         # $a0 = &file
    jal     0x80072084          # CdSearchFile
    addiu   $a1, $sp, 24        # 延迟槽：$a1 = filename 地址 (指向栈)

    addiu   $a0, $sp, 8         # $a0 = &file
    lui     $a1, 0x800d         # 构造目标地址 0x800D1000 (上半部分)
    ori     $a1, $a1, 0x1000    # (下半部分)
    jal     0x80030e3c          # CDBlockRead
    li      $a2, LOAD_COUNT     # 延迟槽：count = LOAD_COUNT

    lw      $ra, 36($sp)
    nop                         # lw 延迟槽
    j       LOAD_SMALL_ADDR     # 尾调用, load_small 的 jr $ra 返回到原 caller
    addiu   $sp, $sp, 40        # j 延迟槽
