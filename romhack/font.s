.set noreorder
LoadBIOSFont2:
    # --- 提前开启栈空间 (Prologue) ---
    addiu   $sp, $sp, -0x38
    sw      $s0, 0x30($sp)
    sw      $ra, 0x34($sp)
    move    $s0, $a0            # 提前保存 a0 到 s0，以防 a0 在后续调用中被修改
    
    # 检查范围 1: 0x8500 到 0x87FF 
    li      $t0, 0x8500
    subu    $t1, $a0, $t0       # $t1 = a0 - 0x8500
    sltiu   $t2, $t1, 0x0300    # 0x87FF - 0x8500 + 1 = 0x0300
    bne     $t2, $zero, keep_going # 如果在范围 1，跳转到业务逻辑
    nop

    # 检查范围 2: 0x9900 到 0x9FFF
    li      $t0, 0x9900
    subu    $t1, $a0, $t0       # $t1 = a0 - 0x9900
    sltiu   $t2, $t1, 0x0700    # 0x9FFF - 0x9900 + 1 = 0x0700
    bne     $t2, $zero, keep_going # 如果在范围 2，跳转到业务逻辑
    nop

# --- 新增逻辑：如果都不满足，调用 0x80036920 后返回 ---

    # 此时 $a0 依然保持着进入函数时的值，直接调用
    jal     0x80036920                  
    nop                          # 延迟槽
    b       function_end
    nop

keep_going:

    lh      $a2, 0x7ae($gp)
    lh      $v0, 0x7ac($gp)
    sll     $a2, $a2,0x1
    mult    $v0, $a2
    lw      $a0, 0x568($gp)
    lh      $a1, 0x7b6($gp)
    mflo    $a2
    jal     0x8006a984              #memset
    nop
check_and_map:
    andi    $s0, $s0, 0xffff
    # --- 范围判断 ---
    li      $t0, 0x8500
    subu    $t1, $s0, $t0       # $t1 = s0 - 0x8500
    sltiu   $t2, $t1, 0x0300    # 判断是否在 [0, 0x02FF] 之间 (即原范围 0x8500~0x87FF)
    beq     $t2, $zero, map_second_range
    nop                         # 延迟槽

map_first_range:
    # 逻辑: v0 = 0x800D1000 + (s0 - 0x8500)
    # 此时 $t1 已经是 (s0 - 0x8500)

    sll     $t2, $t1, 5         # $t2 = Index * 32
    sll     $t1, $t1, 2         # $t1 = Index * 4
    subu    $t1, $t2, $t1       # $t1 = (Index * 32) - (Index * 4) = Index * 28

    lui     $v0, 0x800D         # 加载高 16 位
    ori     $v0, $v0, 0x1000    # 合并低 16 位，得到 0x800D1000
    addu    $v0, $v0, $t1       # 最终结果
    b       copy_to_stack       # 返回
    nop

map_second_range:
    # 逻辑: v0 = 0x800D1300 + (s0 - 0x9900)
    subu    $t1, $s0, 0x9900    # 注意：如果 0x9900 超过 16位有符号数范围，
                                # 某些编译器需要先 li $t0, 0x9900 再 subu
                                
    sll     $t2, $t1, 5         # $t2 = Index * 32
    sll     $t1, $t1, 2         # $t1 = Index * 4
    subu    $t1, $t2, $t1       # $t1 = (Index * 32) - (Index * 4) = Index * 28

    lui     $v0, 0x800D
    ori     $v0, $v0, 0x1300    # 得到 0x800D1300
    addu    $v0, $v0, $t1

copy_to_stack:
    move    $a2, $zero          # a2 = 0
    addiu   $a1, $sp, 0x10      # a1 = sp + 0x10
    move    $a0, $v0            # a0 = v0

loop:
    lhu     $v0, 0($a0)         # v0 = *a0
    addiu   $a0, $a0, 0x2       # a0 += 2
    addiu   $a2, $a2, 0x1       # a2++
    
    # --- 字节交换逻辑 (Endian Swap) ---
    srl     $v1, $v0, 0x8       # v1 = 高8位
    andi    $v0, $v0, 0xff      # v0 = 低8位
    sll     $v0, $v0, 0x8       # v0 移到高位
    or      $v1, $v1, $v0       # 拼接，完成字节交换
    
    sh      $v1, 0($a1)         # 存储交换后的半字到 dst
    slti    $v0, $a2, 0xe       # v0 = a2 < e
    bne     $v0, $zero, loop
    addiu   $a1, $a1, 0x2       # (延迟槽) 目标指针后移

    # --- 准备调用函数 ---
    sh      $zero, 0x2c($sp)    # 清零第14行
    addiu   $a0, $sp, 0x10      # a0 = sp + 0x10
    jal     0x800369fc          # FUN_800369fc(a0)
    sh      $zero, 0x2e($sp)    # （延迟槽）清零第15行
function_end:
    # --- 函数退出 ---
    lw      $ra, 0x34($sp)      # 恢复返回地址
    lw      $s0, 0x30($sp)      # 恢复 s0
    jr      $ra                 # 返回
    addiu   $sp, $sp, 0x38      # (延迟槽) 恢复栈指针
