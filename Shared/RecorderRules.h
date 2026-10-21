#ifndef DAYTAPE_RULES_H
#define DAYTAPE_RULES_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int rr_receipt_matches(const char *local_id, const char *local_hash, uint64_t local_size,
                       const char *receipt_id, const char *receipt_hash, uint64_t receipt_size);
int rr_should_enqueue(int confirmed, int outstanding, double now, double retry_after);
double rr_retry_delay(uint32_t attempt);
int rr_budget_allows(uint64_t free_bytes, uint64_t pending_bytes, uint64_t next_bytes,
                     uint64_t minimum_free, uint64_t spool_limit);
int rr_can_purge_cloud_copy(int checksum_verified, int receipt_saved, int upload_active, int keep_local);
int rr_archive_eligible(double clip_end, double authorized_cutoff, int backup_enabled);
#ifdef __cplusplus
}
#endif
#endif
