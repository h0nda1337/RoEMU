/* Own direct-LV2 reader/writer lock diagnostic; no SDK, libc or firmware. */
typedef unsigned long long u64;
typedef unsigned int u32;
static volatile u32 rw,control,changed,entered,left,release_readers,written,order_count;
static volatile u32 order[2];
static __attribute__((always_inline)) inline u64 invoke(u64 n,u64 a,u64 b,u64 c,u64 d,u64 e,u64 f,u64 g,u64 h) {
    register u64 r3 __asm__("r3")=a,r4 __asm__("r4")=b,r5 __asm__("r5")=c,r6 __asm__("r6")=d;
    register u64 r7 __asm__("r7")=e,r8 __asm__("r8")=f,r9 __asm__("r9")=g,r10 __asm__("r10")=h,r11 __asm__("r11")=n;
    __asm__ volatile("sc" : "+r"(r3),"+r"(r4),"+r"(r5),"+r"(r6),"+r"(r7),"+r"(r8),"+r"(r9),"+r"(r10),"+r"(r11) : : "memory","cr0","r0","r12");
    return r3;
}
#define CALL(n,a,b,c) invoke(n,(u64)(a),(u64)(b),(u64)(c),0,0,0,0,0)
__attribute__((noreturn)) static void finish(u64 status) { CALL(22,status,0,0);for (;;) __asm__ volatile("b ."); }
__attribute__((noreturn)) static void done(u64 status) { CALL(41,status,0,0);for (;;) __asm__ volatile("b ."); }
static u64 spawn(void (*entry)(u64),u64 arg,u32 priority) {
    struct { u32 entry,tls; } param={(u32)(u64)entry,0};
    u64 id=0;
    if (invoke(52,(u64)&id,(u64)&param,arg,0,priority,16384,1,0) || CALL(53,id,0,0)) finish(50);
    return id;
}
static void join(u64 id,u64 expected) { u64 value=0;if (CALL(44,id,&value,0) || value!=expected) finish(51); }
static void await_writer(void) {
    for (u32 i=0;i<100;i++) {
        u32 status=(u32)CALL(123,rw,0,0);
        if (status==0x8001000aU) return;
        if (status || CALL(124,rw,0,0) || CALL(141,100,0,0)) finish(52);
    }
    finish(53);
}
static void reader(u64 tag) {
    if (CALL(122,rw,0,0) || CALL(102,control,0,0)) finish(20);
    entered++;
    if (CALL(109,changed,0,0)) finish(21);
    while (!release_readers) if (CALL(107,changed,0,0)) finish(22);
    left++;
    if (CALL(104,control,0,0) || CALL(124,rw,0,0)) finish(23);
    done(tag);
}
static void writer(u64 tag) {
    if (CALL(125,rw,0,0)) finish(24);
    if (left!=2) finish(25);
    written=42;
    if (CALL(127,rw,0,0)) finish(26);
    done(tag);
}
static void late_reader(u64 tag) {
    if (CALL(122,rw,0,0)) finish(27);
    if (tag==9 && written!=42) finish(28);
    if (CALL(124,rw,0,0)) finish(29);
    done(tag);
}
static void timed_writer(u64 tag) {
    if ((u32)CALL(125,rw,200000,0)!=0x8001000bU) finish(30);
    done(tag);
}
static void foreign_reader_unlock(u64 tag) { if (CALL(124,rw,0,0)) finish(31);done(tag); }
static void order_writer(u64 tag) {
    if (CALL(125,rw,0,0)) finish(32);
    u32 at=order_count;
    if (at>=2) finish(33);
    order[at]=(u32)tag;order_count=at+1;
    if (CALL(127,rw,0,0)) finish(34);
    done(tag);
}
void roemu_entry(u64 argc,const char **argv) {
    int priority=0;for (u64 i=1;i<argc;i++) if (argv[i][0]=='P') priority=1;
    struct { u32 protocol,shared;u64 key;u32 flags,pad;u64 name; } attr={priority?2:1,0x200,0,0,0,0};
    struct { u32 protocol,recursive,shared,adaptive;u64 key;u32 flags,pad;u64 name; } mutex={1,0x20,0x200,0x2000,0,0,0,0};
    struct { u32 shared,flags;u64 key,name; } condition={0x200,0,0,0};
    if (CALL(120,&rw,&attr,0)) finish(1);
    if ((u32)CALL(121,0,0,0)!=0x80010005U || (u32)CALL(124,rw,0,0)!=0x80010009U || (u32)CALL(127,rw,0,0)!=0x80010009U) finish(2);
    if (CALL(122,rw,0,0) || CALL(123,rw,0,0)) finish(3);
    if ((u32)CALL(126,rw,0,0)!=0x8001000aU || (u32)CALL(121,rw,0,0)!=0x8001000aU) finish(4);
    if (CALL(124,rw,0,0) || CALL(124,rw,0,0) || (u32)CALL(124,rw,0,0)!=0x80010009U) finish(5);
    if (CALL(125,rw,0,0) || (u32)CALL(125,rw,0,0)!=0x80010008U || (u32)CALL(126,rw,0,0)!=0x80010008U) finish(6);
    if ((u32)CALL(123,rw,0,0)!=0x8001000aU || (u32)CALL(122,rw,1000,0)!=0x8001000bU || CALL(127,rw,0,0)) finish(7);
    if (CALL(122,rw,0,0) || (u32)CALL(125,rw,1000,0)!=0x8001000bU || CALL(124,rw,0,0)) finish(8);
    if (CALL(100,&control,&mutex,0) || CALL(105,&changed,control,&condition)) finish(9);
    u64 readers[2];
    readers[0]=spawn(reader,1,1001);readers[1]=spawn(reader,2,1001);
    if (CALL(102,control,0,0)) finish(10);
    while (entered!=2) if (CALL(107,changed,0,0)) finish(11);
    if (CALL(104,control,0,0)) finish(12);
    u64 w=spawn(writer,8,1001);await_writer();
    u64 late=spawn(late_reader,9,1001);
    if (CALL(102,control,0,0)) finish(13);
    release_readers=1;
    if (CALL(109,changed,0,0) || CALL(104,control,0,0)) finish(14);
    join(readers[0],1);join(readers[1],2);join(w,8);join(late,9);
    if (left!=2 || written!=42) finish(15);
    /* The last writer timeout admits pending readers without waiting for
       the existing reader (main) to unlock. */
    if (CALL(122,rw,0,0)) finish(16);
    w=spawn(timed_writer,10,1001);await_writer();
    late=spawn(late_reader,11,1001);
    join(late,11);join(w,10);
    if (CALL(124,rw,0,0)) finish(17);
    /* Read ownership is a global count, unlike writer ownership. */
    if (CALL(122,rw,0,0)) finish(18);
    join(spawn(foreign_reader_unlock,12,1001),12);
    if ((u32)CALL(124,rw,0,0)!=0x80010009U) finish(19);
    /* Both writers queue behind main; the protocol selects the next one. */
    if (CALL(125,rw,0,0)) finish(35);
    u64 a=spawn(order_writer,1,1001);
    if (CALL(141,1000,0,0)) finish(36);
    u64 b=spawn(order_writer,2,1000);
    if (CALL(141,1000,0,0) || CALL(127,rw,0,0)) finish(37);
    join(a,1);join(b,2);
    if (order_count!=2 || order[0]!=(priority?2:1) || order[1]!=(priority?1:2)) finish(38);
    if (CALL(106,changed,0,0) || CALL(101,control,0,0) || CALL(121,rw,0,0) || (u32)CALL(123,rw,0,0)!=0x80010005U) finish(39);
    static const char basic[]="ROEMU_PPU_RWLOCK_FIFO_OK\n",prio[]="ROEMU_PPU_RWLOCK_PRIORITY_OK\n";
    const char *message=priority?prio:basic;u32 length=priority?sizeof(prio)-1:sizeof(basic)-1,written_bytes=0;
    if (invoke(403,0,(u64)message,length,(u64)&written_bytes,0,0,0,0) || written_bytes!=length) finish(40);
    finish(42);
}
