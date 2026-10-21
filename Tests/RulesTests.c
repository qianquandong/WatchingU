#include "RecorderRules.h"
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    const char *id="2F9A0189-13C1-4E00-9FA1-1F47BF32F383";
    const char *other="3F9A0189-13C1-4E00-9FA1-1F47BF32F383";
    const char *hash="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    char changed[65]; strcpy(changed, hash); changed[0]='f';
    assert(rr_receipt_matches(id, hash, 2048, id, hash, 2048));
    assert(!rr_receipt_matches(id, hash, 2048, other, hash, 2048));
    assert(!rr_receipt_matches(id, hash, 2048, id, changed, 2048));
    assert(!rr_receipt_matches(id, hash, 2048, id, hash, 2047));
    assert(!rr_receipt_matches(id, hash, 0, id, hash, 0));
    assert(!rr_receipt_matches(NULL, hash, 1, id, hash, 1));
    assert(!rr_receipt_matches(id, "", 1, id, "", 1));
    assert(!rr_receipt_matches("garbage", hash, 1, "garbage", hash, 1));
    assert(!rr_receipt_matches(id, changed, 1, id, "x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", 1));
    assert(rr_should_enqueue(0, 0, 101, 100));
    assert(!rr_should_enqueue(0, 1, 101, 100));
    assert(!rr_should_enqueue(1, 0, 101, 100));
    assert(!rr_should_enqueue(0, 0, 99, 100));
    assert(!rr_should_enqueue(0, 0, NAN, 100));
    assert(!rr_should_enqueue(0, 0, INFINITY, 100));
    assert(rr_retry_delay(0)==30 && rr_retry_delay(1)==60);
    assert(rr_retry_delay(6)==1800 && rr_retry_delay(UINT32_MAX)==1800);
    assert(rr_budget_allows(1000, 100, 100, 100, 500));
    assert(!rr_budget_allows(99, 0, 1, 100, 500));
    assert(!rr_budget_allows(1000, 501, 1, 100, 500));
    assert(!rr_budget_allows(UINT64_MAX, UINT64_MAX, 1, 0, UINT64_MAX));
    assert(!rr_budget_allows(UINT64_MAX, 0, UINT64_MAX, 1, UINT64_MAX));
    assert(rr_budget_allows(1000, 400, 100, 100, 500));
    // Adversarial receipt order: every wrong clip ID/hash/size must retain the sender's file.
    for (uint64_t size=1; size<=10000; ++size) {
        assert(!rr_receipt_matches(id,hash,size,other,hash,size));
        assert(!rr_receipt_matches(id,hash,size,id,changed,size));
        assert(!rr_receipt_matches(id,hash,size,id,hash,size+1));
        assert(rr_receipt_matches(id,hash,size,id,hash,size));
    }
    for (int verified=0; verified<2; ++verified)
    for (int saved=0; saved<2; ++saved)
    for (int active=0; active<2; ++active)
    for (int keep=0; keep<2; ++keep)
        assert(rr_can_purge_cloud_copy(verified,saved,active,keep) == (verified && saved && !active && !keep));
    assert(rr_archive_eligible(100,100,1));
    assert(rr_archive_eligible(99,100,1));
    assert(!rr_archive_eligible(101,100,1));
    assert(!rr_archive_eligible(99,100,0));
    assert(!rr_archive_eligible(NAN,100,1));
    assert(!rr_archive_eligible(99,INFINITY,1));
    puts("PASS: 40,045 assertions: receipts, backoff, budget, all 16 cloud eviction combinations, archive cutoff");
    return 0;
}
