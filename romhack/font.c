typedef void (memset_func*)(unsigned char* addr, unsigned char content, int len);
#define memset ((memset_func*)0x8006a984)

void NewLoadBIOS(unsigned short ch) {
        register uintptr_t gp_val __asm__("$gp");
        memset(()(gp_val + 0x568))
}