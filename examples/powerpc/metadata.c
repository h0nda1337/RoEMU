/* Own freestanding SFO syscall diagnostic. No Sony SDK, firmware or libc. */
typedef unsigned long long u64;
typedef unsigned int u32;
static volatile unsigned char sfo_result[64];
static const char expected[]="ROEM00001";
static const char message[]="ROEMU_PPU_SFO_OK\n";
__attribute__((noreturn)) static void finish(u64 status) {
    register u64 r3 __asm__("r3")=status;
    register u64 r11 __asm__("r11")=22;
    __asm__ volatile("sc" : "+r"(r3), "+r"(r11) : : "memory", "cr0");
    for (;;) __asm__ volatile("b .");
}
void roemu_entry(u64 argc,const char **argv) {
    int title_present=0;
    for (u64 i=1;i<argc;i++) if (argv[i][0]=='T') title_present=1;
    for (u32 i=0;i<64;i++) sfo_result[i]=0xa5;
    register u64 r3 __asm__("r3")=(u64)sfo_result;
    register u64 r11 __asm__("r11")=30;
    __asm__ volatile("sc" : "+r"(r3), "+r"(r11) : : "memory", "cr0");
    if ((u32)r3!=(title_present?0:0x80010006U)) finish(1);
    for (u32 i=0;i<64;i++) {
        unsigned char want=0xa5;
        if (title_present) want=i>=1 && i<=9 ? expected[i-1] : 0;
        if (sfo_result[i]!=want) finish(0x100+i);
    }
    volatile u32 written=0;
    r3=0;
    register u64 r4 __asm__("r4")=(u64)message;
    register u64 r5 __asm__("r5")=sizeof(message)-1;
    register u64 r6 __asm__("r6")=(u64)&written;
    r11=403;
    __asm__ volatile("sc" : "+r"(r3), "+r"(r4), "+r"(r5), "+r"(r6), "+r"(r11) : : "memory", "cr0");
    if (r3 || written!=sizeof(message)-1) finish(2);
    finish(42);
}
