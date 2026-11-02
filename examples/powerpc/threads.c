/* Own direct-LV2 PPU synchronization diagnostic, without a Sony SDK/libc. */
typedef unsigned long long u64;
typedef unsigned int u32;
__thread volatile u64 main_tls=7;
static volatile u32 mutex_id,cond_id,release_id,phase;
static volatile u64 worker_id,worker_status;
static const char message[]="ROEMU_PPU_THREADS_COND_OK\n";
static volatile u64 atomic_value=0x0020000000000001ULL;
static __attribute__((always_inline)) inline u64 invoke(u64 number,u64 a,u64 b,u64 c,u64 d,u64 e,u64 f,u64 g,u64 h) {
    register u64 r3 __asm__("r3")=a,r4 __asm__("r4")=b,r5 __asm__("r5")=c,r6 __asm__("r6")=d;
    register u64 r7 __asm__("r7")=e,r8 __asm__("r8")=f,r9 __asm__("r9")=g,r10 __asm__("r10")=h;
    register u64 r11 __asm__("r11")=number;
    __asm__ volatile("sc" : "+r"(r3),"+r"(r4),"+r"(r5),"+r"(r6),"+r"(r7),"+r"(r8),"+r"(r9),"+r"(r10),"+r"(r11) : : "memory","cr0","r0","r12");
    return r3;
}
#define CALL(n,a,b,c) invoke(n,(u64)(a),(u64)(b),(u64)(c),0,0,0,0,0)
__attribute__((noreturn)) static void finish(u64 status) { CALL(22,status,0,0);for (;;) __asm__ volatile("b ."); }
static void worker(u64 arg) {
    if (arg!=0x0020000000000001ULL) finish(11);
    if (CALL(102,mutex_id,0,0)) finish(12);
    phase=42;
    if (CALL(108,cond_id,0,0)) finish(13);
    if (CALL(104,mutex_id,0,0)) finish(14);
    volatile u64 exact=arg;
    for (unsigned i=0;i<3;++i) { exact+=7;CALL(43,0,0,0); }
    if (exact!=0x0020000000000016ULL) finish(15);
    CALL(41,0xFEDCBA9876543210ULL,0,0);
    for (;;) __asm__ volatile("b .");
}
static void broadcast_worker(u64 arg) {
    if (CALL(102,mutex_id,0,0)) finish(20);
    phase++;
    if (CALL(108,cond_id,0,0)) finish(21);
    while (phase<3) if (CALL(107,release_id,0,0)) finish(22);
    if (CALL(104,mutex_id,0,0)) finish(23);
    CALL(41,arg,0,0);
    for (;;) __asm__ volatile("b .");
}
void roemu_entry(u64 argc,const char **argv,const char **envp,u64 envc,u64 main_id) {
    struct { u32 protocol,recursive,shared,adaptive;u64 key;u32 flags,pad;u64 name; } mutex={1,0x10,0x200,0x2000,0,0,0,0};
    struct { u32 shared,flags;u64 key,name; } condition={0x200,0,0,0};
    struct { u32 entry,tls; } param={(u32)(u64)&worker,0};
    int inherit=0;
    for (u64 i=1;i<argc;i++) if (argv[i][0]=='I') inherit=1;
    if (inherit) mutex.protocol=3;
    if (!__sync_bool_compare_and_swap(&atomic_value,0x0020000000000001ULL,0x002000000000002AULL)) finish(38);
    if (__sync_bool_compare_and_swap(&atomic_value,0x0020000000000001ULL,0) || atomic_value!=0x002000000000002AULL) finish(39);
    if (main_tls!=7) finish(1);
    if (CALL(100,&mutex_id,&mutex,0) || CALL(105,&cond_id,mutex_id,&condition)) finish(2);
    if (CALL(102,mutex_id,0,0) || CALL(102,mutex_id,0,0)) finish(3);
    if (invoke(52,(u64)&worker_id,(u64)&param,0x0020000000000001ULL,0,inherit?1000:1001,16384,1,0) || CALL(53,worker_id,0,0)) finish(4);
    while (!phase) if (CALL(107,cond_id,0,0)) finish(5);
    if (phase!=42) finish(6);
    if (CALL(104,mutex_id,0,0) || CALL(104,mutex_id,0,0)) finish(7);
    if ((u32)CALL(104,mutex_id,0,0)!=0x80010009U) finish(8);
    if (CALL(44,worker_id,&worker_status,0) || worker_status!=0xFEDCBA9876543210ULL) finish(9);
    if ((u32)CALL(44,main_id,0,0)!=0x80010008U || (u32)CALL(44,0,0,0)!=0x80010005U) finish(44);
    if ((u32)CALL(53,worker_id,0,0)!=0x80010005U || (u32)CALL(45,main_id,0,0)!=0x80010002U) finish(45);
    if ((u32)CALL(110,cond_id,main_id,0)!=0x80010009U || (u32)CALL(110,cond_id,worker_id,0)!=0x80010005U) finish(46);
    u32 stack[2],priority=0;
    if (CALL(49,stack,0,0) || !stack[0] || stack[1]<4096) finish(47);
    if (CALL(48,main_id,&priority,0) || priority!=1001 || CALL(47,main_id,1001,0)) finish(48);
    /* A timeout still returns owning the mutex at its original recursion depth. */
    if (CALL(102,mutex_id,0,0) || CALL(102,mutex_id,0,0)) finish(17);
    if ((u32)CALL(107,cond_id,1000,0)!=0x8001000BU) finish(18);
    if (CALL(104,mutex_id,0,0) || CALL(104,mutex_id,0,0)) finish(19);
    if ((u32)CALL(101,mutex_id,0,0)!=0x80010009U) finish(24);
    if (CALL(109,cond_id,0,0)) finish(25);
    /* Two waiters, one broadcast, then independent joins and 64-bit statuses. */
    if (CALL(105,&release_id,mutex_id,&condition)) finish(26);
    if (CALL(102,mutex_id,0,0)) finish(27);
    phase=0;
    u64 ids[2],status=0;
    param.entry=(u32)(u64)&broadcast_worker;
    for (u64 i=0;i<2;++i)
        if (invoke(52,(u64)&ids[i],(u64)&param,i+1,0,1001,16384,1,0) || CALL(53,ids[i],0,0)) finish(28);
    while (phase<2) if (CALL(107,cond_id,0,0)) finish(29);
    if ((u32)CALL(106,release_id,0,0)!=0x8001000AU) finish(49);
    phase=3;
    if (CALL(109,release_id,0,0) || CALL(104,mutex_id,0,0)) finish(30);
    for (u64 i=0;i<2;++i) if (CALL(44,ids[i],&status,0) || status!=i+1) finish(31);
    if (CALL(106,release_id,0,0)) finish(32);
    if (CALL(106,cond_id,0,0) || CALL(101,mutex_id,0,0)) finish(10);
    u32 light=0;
    if (CALL(95,&light,2,0) || (u32)CALL(99,light,0,0)!=0x8001000AU) finish(33);
    if (CALL(98,light,0,0) || CALL(99,light,0,0)) finish(34);
    if ((u32)CALL(99,light,0,0)!=0x8001000AU || CALL(117,light,0,0)) finish(35);
    if ((u32)CALL(99,light,0,0)!=0x8001000AU || (u32)CALL(97,light,0,0)!=0x8001000AU) finish(36);
    if ((u32)CALL(97,light,1000,0)!=0x8001000BU || CALL(96,light,0,0)) finish(37);
    if (CALL(147,0,0,0)!=80000000) finish(40);
    u64 before,after;
    __asm__ volatile("mftb %0" : "=r"(before));
    if (CALL(141,1000,0,0)) finish(41);
    __asm__ volatile("mftb %0" : "=r"(after));
    if (after-before<80000) finish(43);
    static const char inherited_message[]="ROEMU_PPU_THREADS_COND_INHERIT_OK\n";
    const char *output=inherit?inherited_message:message;
    u32 length=inherit?sizeof(inherited_message)-1:sizeof(message)-1;
    u32 written=0;
    if (invoke(403,0,(u64)output,length,(u64)&written,0,0,0,0) || written!=length) finish(16);
    finish(42);
}
