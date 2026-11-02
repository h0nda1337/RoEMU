/* Own FP instruction diagnostic. No SDK, libc or firmware. */
typedef unsigned long long u64;
typedef unsigned int u32;
static const u64 inputs[]={0x0020000000000001ULL,0x8000000000000000ULL,
    0x3ff0000000000000ULL,0x4008000000000000ULL,0xc008000000000000ULL,0};
static const u64 expected[]={0x4340000000000000ULL,0xc3e0000000000000ULL,
    0x3fd5555555555555ULL,0x3fd5555560000000ULL,0x3fd5555560000000ULL,0x8000000000000000ULL};
static const char message[]="ROEMU_PPU_FLOATING_OK\n";
__attribute__((noreturn)) static void finish(u64 status) {
    register u64 r3 __asm__("r3")=status;
    register u64 r11 __asm__("r11")=22;
    __asm__ volatile("sc" : "+r"(r3), "+r"(r11) : : "memory", "cr0");
    for (;;) __asm__ volatile("b .");
}
void roemu_entry(void) {
    u64 result[6];
    __asm__ volatile(
        "lfd 0,0(%0)\n\tfcfid 0,0\n\tstfd 0,0(%1)\n\t"
        "lfd 0,8(%0)\n\tfcfid 0,0\n\tstfd 0,8(%1)\n\t"
        "lfd 1,16(%0)\n\tlfd 2,24(%0)\n\tfdiv 3,1,2\n\tstfd 3,16(%1)\n\t"
        "fdivs 4,1,2\n\tstfd 4,24(%1)\n\tfrsp 5,3\n\tstfd 5,32(%1)\n\t"
        "lfd 1,40(%0)\n\tlfd 2,32(%0)\n\tfdiv 3,1,2\n\tstfd 3,40(%1)"
        : : "r"(inputs),"r"(result) : "f0","f1","f2","f3","f4","f5","memory");
    for (u32 i=0;i<6;i++) if (result[i]!=expected[i]) finish(0x100+i);
    volatile u32 written=0;
    register u64 r3 __asm__("r3")=0,r4 __asm__("r4")=(u64)message,
        r5 __asm__("r5")=sizeof(message)-1,r6 __asm__("r6")=(u64)&written,r11 __asm__("r11")=403;
    __asm__ volatile("sc" : "+r"(r3),"+r"(r4),"+r"(r5),"+r"(r6),"+r"(r11) : : "memory","cr0");
    if (r3 || written!=sizeof(message)-1) finish(1);
    finish(42);
}
