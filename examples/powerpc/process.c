/* Own PPU diagnostic: no Sony code, libc or SDK. */
typedef unsigned long long u64;
typedef unsigned int u32;
__thread volatile u64 roemu_tls_value=0x0020000000000001ULL;
__thread volatile u64 roemu_tls_zero;
volatile u64 roemu_process_observed[4];
static const char message[]="ROEMU_PPU_TLS_ARGS_OK\n";
__attribute__((noreturn)) static void finish(u64 status) {
    register u64 r3 __asm__("r3")=status;
    register u64 r11 __asm__("r11")=22;
    __asm__ volatile("sc" : "+r"(r3), "+r"(r11) : : "memory", "cr0");
    for (;;) __asm__ volatile("b .");
}
void roemu_entry(u64 argc, const char **argv, const char **envp, u64 envc,
                 u64 thread_id, u64 tls_image, u64 tls_file, u64 tls_memory) {
    if (!argc || !argv || !argv[0] || argv[0][0]!='/' || argv[argc] || !envp || envp[envc]) finish(1);
    if (!thread_id) finish(2);
    if (!tls_image) finish(5);
    if (tls_file<8) finish(6);
    if (tls_memory<16) finish(0x100+tls_memory);
    if (roemu_tls_value!=0x0020000000000001ULL || roemu_tls_zero!=0) finish(3);
    roemu_tls_value+=41;
    roemu_tls_zero=roemu_tls_value;
    roemu_process_observed[0]=roemu_tls_value;
    roemu_process_observed[1]=roemu_tls_zero;
    roemu_process_observed[2]=argc;
    roemu_process_observed[3]=envc;
    volatile u32 written=0;
    register u64 r3 __asm__("r3")=0;
    register u64 r4 __asm__("r4")=(u64)message;
    register u64 r5 __asm__("r5")=sizeof(message)-1;
    register u64 r6 __asm__("r6")=(u64)&written;
    register u64 r11 __asm__("r11")=403;
    __asm__ volatile("sc" : "+r"(r3), "+r"(r4), "+r"(r5), "+r"(r6), "+r"(r11) : : "memory", "cr0");
    if (r3 || written!=sizeof(message)-1) finish(4);
    finish(42);
}
