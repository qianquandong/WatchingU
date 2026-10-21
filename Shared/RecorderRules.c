#include "RecorderRules.h"
#include <string.h>
#include <math.h>
static int hex(char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
static int uuid(const char *s) {
    if (!s || strlen(s) != 36) return 0;
    for (int i=0; i<36; ++i) {
        if (i==8 || i==13 || i==18 || i==23) { if (s[i]!='-') return 0; }
        else if (!hex(s[i])) return 0;
    }
    return 1;
}
static int digest(const char *s) {
    if (!s || strlen(s)!=64) return 0;
    for (int i=0; i<64; ++i) if (!hex(s[i])) return 0;
    return 1;
}
int rr_receipt_matches(const char *id, const char *hash, uint64_t size,
                       const char *ack_id, const char *ack_hash, uint64_t ack_size) {
    return uuid(id) && uuid(ack_id) && digest(hash) && digest(ack_hash) && size>0 &&
           size==ack_size && strcmp(id,ack_id)==0 && strcmp(hash,ack_hash)==0;
}
int rr_should_enqueue(int confirmed, int outstanding, double now, double retry_after) {
    return !confirmed && !outstanding && isfinite(now) && isfinite(retry_after) && now>=retry_after;
}
double rr_retry_delay(uint32_t attempt) {
    if (attempt >= 6) return 1800.0;
    return 30.0 * (double)(1u << attempt);
}
int rr_budget_allows(uint64_t free_bytes, uint64_t pending_bytes, uint64_t next_bytes,
                     uint64_t minimum_free, uint64_t spool_limit) {
    if (free_bytes < minimum_free || next_bytes > free_bytes-minimum_free) return 0;
    return pending_bytes <= spool_limit && next_bytes <= spool_limit-pending_bytes;
}
int rr_can_purge_cloud_copy(int verified, int saved, int active, int keep) {
    return verified == 1 && saved == 1 && active == 0 && keep == 0;
}
int rr_archive_eligible(double end, double cutoff, int enabled) {
    return enabled == 1 && isfinite(end) && isfinite(cutoff) && end <= cutoff;
}
