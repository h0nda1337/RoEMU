typedef unsigned long long u64;
volatile u64 roemu_input[5] = {
    0x0020000000000001ULL, 0xFEDCBA9876543210ULL,
    0x0000000100000001ULL, 0xFFFFFFFFFFFFFFFFULL, 7ULL
};
volatile u64 roemu_output;
int roemu_entry(void) {
    u64 checksum = 0;
    for (unsigned i = 0; i < 5; ++i)
        checksum = (checksum ^ roemu_input[i]) + 17;
    roemu_output = checksum;
    return 42;
}
